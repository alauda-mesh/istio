#!/usr/bin/env bash
# 步骤 1a：解析输入的流水线 run → 推断目标分支 + 提取待扫描镜像，初始化本次任务状态。
# 用法: resolve-runs.sh [--branch RUN_ID=istio-X.Y[.Z]]... <RUN_ID|run URL> ...
#   --branch 用于目标分支推断失败（UNKNOWN）后，按用户确认的结果重跑修正。
# 只接受两条流水线的成功 run：
#   Release Alauda Istio（release 事件，ref 是发布 tag）→ 目标分支 = release 的 target_commitish
#   Pull Request Builder（pull_request 事件）→ 目标分支 = head 分支对应 PR 的 base 分支
# 镜像提取：run 日志中的 BUILD_IMAGE= 行，只保留 install-cni/pilot/proxyv2/ztunnel 的 -distroless。
# 退出码: 0=OK  1=前置失败  2=存在 UNKNOWN 分支（模型和用户确认后用 --branch 重跑）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  require_gh

  declare -A OVERRIDE=()
  local RUNS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        shift; [[ "${1:-}" == *=* ]] || die "--branch 参数格式: RUN_ID=istio-X.Y[.Z]"
        valid_target_branch "${1#*=}" || die "--branch 的分支名不合法: ${1#*=}"
        OVERRIDE["${1%%=*}"]="${1#*=}" ;;
      *) RUNS+=("$1") ;;
    esac
    shift
  done
  [[ ${#RUNS[@]} -ge 1 ]] || die "用法: resolve-runs.sh [--branch RUN_ID=分支]... <RUN_ID|run URL> ..."

  # 残留上次任务状态时安全清理：worktree 有未提交改动则终止，交人工确认
  if [[ -f "$STATE_FILE" ]]; then
    local wt
    for wt in "$STATE_DIR"/worktrees/*/; do
      [[ -d "$wt" ]] || continue
      if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
        die "上次任务残留 worktree 有未提交改动: $wt
请人工确认（保留则提交，放弃则 git worktree remove --force）后重跑"
      fi
      info "清理上次任务的干净 worktree: $wt"
      git worktree remove --force "$wt" >/dev/null 2>&1 || true
    done
    git worktree prune >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR" && mkdir -p "$STATE_DIR"
  fi

  local RUNS_TSV="$STATE_DIR/runs.tsv" IMG_TSV="$STATE_DIR/images-round1.tsv"
  : >"$RUNS_TSV"; : >"$IMG_TSV"
  local UNKNOWNS=() SCAN_PAT="/(${SCAN_REPOS// /|}):[^:]*-distroless$"

  local arg id meta wf event ref status conclusion branch ver imgs kept total_n kept_n
  for arg in "${RUNS[@]}"; do
    id="$arg"
    [[ "$id" =~ /runs/([0-9]+) ]] && id="${BASH_REMATCH[1]}"
    [[ "$id" =~ ^[0-9]+$ ]] || die "无法从参数解析 run ID: $arg"

    meta="$(gh run view "$id" --repo "$REPO" --json workflowName,event,headBranch,status,conclusion,url)" \
      || die "读取 run $id 失败"
    wf="$(jq -r .workflowName <<<"$meta")"
    event="$(jq -r .event <<<"$meta")"
    ref="$(jq -r .headBranch <<<"$meta")"
    status="$(jq -r .status <<<"$meta")"
    conclusion="$(jq -r .conclusion <<<"$meta")"

    [[ "$wf" == "Release Alauda Istio" || "$wf" == "Pull Request Builder" ]] \
      || die "run $id 属于工作流「$wf」，本 skill 只处理 Release Alauda Istio / Pull Request Builder"
    [[ "$status" == "completed" && "$conclusion" == "success" ]] \
      || die "run $id 未成功完成（status=$status conclusion=$conclusion），镜像可能不完整，不纳入扫描"

    # ---------- 目标分支推断 ----------
    branch="${OVERRIDE[$id]:-}"
    if [[ -z "$branch" && "$event" == "release" ]]; then
      branch="$(gh api "repos/$REPO/releases/tags/$ref" --jq .target_commitish 2>/dev/null || true)"
      valid_target_branch "$branch" || branch=""
      if [[ -z "$branch" ]]; then
        # 兜底：按 tag 的版本前缀匹配分支（tag 形如 1.28.6-asm-rc.0）
        ver="${ref%%-*}"
        if [[ "$ver" =~ ^1\.[0-9]+\.[0-9]+$ ]]; then
          if git ls-remote --exit-code --heads origin "istio-$ver" >/dev/null 2>&1; then
            branch="istio-$ver"; warn "run $id 按版本前缀匹配到 $branch，请核对"
          elif git ls-remote --exit-code --heads origin "istio-${ver%.*}" >/dev/null 2>&1; then
            branch="istio-${ver%.*}"; warn "run $id 按大版本前缀匹配到 $branch，请核对该分支当前小版本确为 $ver"
          fi
        fi
      fi
    elif [[ -z "$branch" ]]; then
      branch="$(gh pr list --repo "$REPO" --head "$ref" --state all --limit 1 \
        --json baseRefName --jq '.[0].baseRefName // empty' 2>/dev/null || true)"
      valid_target_branch "$branch" || branch=""
    fi
    if [[ -z "$branch" ]]; then
      branch="UNKNOWN"; UNKNOWNS+=("$id（$wf @ $ref）")
    fi

    # ---------- 镜像提取 ----------
    info "拉取 run $id 日志提取镜像（Release 日志较大，可能需要几十秒）..."
    imgs="$(gh run view "$id" --repo "$REPO" --log 2>/dev/null \
      | grep -oE 'BUILD_IMAGE=[^"$[:space:]][^[:space:]]*' | cut -d= -f2- | sort -u || true)"
    total_n="$(grep -c . <<<"$imgs" || true)"
    kept="$(grep -E "$SCAN_PAT" <<<"$imgs" || true)"
    if [[ -z "$kept" ]]; then
      if [[ "$event" == "release" ]]; then
        # 旧版 workflow 的 run 日志没有 BUILD_IMAGE 行，release 可按 tag 规则构造
        warn "run $id 日志无 BUILD_IMAGE 行（旧版 workflow），按 release tag 构造镜像名，请核对镜像存在"
        kept="$(for r in $SCAN_REPOS; do echo "build-harbor.alauda.cn/asm/$r:$ref-distroless"; done)"
        total_n=0
      else
        die "run $id 日志无 BUILD_IMAGE 行（旧版 workflow 的 PR run 无法可靠推断镜像名）。请换带镜像输出的 run，或与用户确认镜像列表"
      fi
    fi
    kept_n="$(grep -c . <<<"$kept")"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$wf" "$event" "$ref" "$branch" "$kept_n" >>"$RUNS_TSV"
    while IFS= read -r img; do
      printf '1\t%s\t%s\t%s\n' "$id" "$branch" "$img" >>"$IMG_TSV"
    done <<<"$kept"

    echo
    echo "run $id [$wf] $ref → 目标分支: $branch"
    echo "  纳入扫描 $kept_n 个镜像$([[ "$total_n" -gt "$kept_n" ]] && echo "（另 $((total_n - kept_n)) 个产物不在扫描范围）")："
    sed 's/^/    /' <<<"$kept"
  done

  local BRANCHES
  BRANCHES="$(cut -f3 "$IMG_TSV" | grep -v '^UNKNOWN$' | sort -uV | paste -sd' ' -)"
  set_state ROUND 1
  set_state BRANCHES "$BRANCHES"

  echo
  if [[ ${#UNKNOWNS[@]} -gt 0 ]]; then
    echo "UNKNOWN_BRANCH"
    printf '以下 run 无法推断目标分支：\n'
    printf '  %s\n' "${UNKNOWNS[@]}"
    echo "请用 AskUserQuestion 和用户确认修复分支，然后带 --branch RUN_ID=istio-X.Y[.Z] 重跑本脚本（所有 run 都要重新传入）"
    exit 2
  fi
  echo "RUNS_RESOLVED"
  echo "目标分支: $BRANCHES"
  echo "下一步: 执行 scan-images.sh 扫描（Bash timeout 设 600000）"
}

main "$@"
