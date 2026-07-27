#!/usr/bin/env bash
# 步骤 4：监控全部修复 PR 触发的 Pull Request Builder run，成功后收集新镜像供回归扫描。
# 按各 PR 当前 head sha 精确匹配 run（回归轮多次 push 也不会误拿旧 run）。
# 全部成功: ROUND+1，生成 images-round<N+1>.tsv（PR 构建的 -distroless 镜像）。
# 退出码: 0=全部成功  1=前置失败  2=有 run 失败（附失败日志摘要，成功者的镜像仍已收集）
#         3=等待超时  4=有 PR 找不到对应 run
# 环境变量: FIX_WATCH_INTERVAL=60  FIX_WATCH_TIMEOUT=5400  FIX_WATCH_APPEAR_TIMEOUT=300
# 注意: 多平台镜像构建通常 30~60 分钟，必须用后台方式运行（Bash 的 run_in_background: true）。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INTERVAL="${FIX_WATCH_INTERVAL:-60}"
TIMEOUT="${FIX_WATCH_TIMEOUT:-5400}"
APPEAR_TIMEOUT="${FIX_WATCH_APPEAR_TIMEOUT:-300}"
WORKFLOW="Pull Request Builder"

main() {
  repo_root
  load_state
  require_gh
  local PRS_TSV="$STATE_DIR/prs.tsv"
  [[ -s "$PRS_TSV" ]] || die "没有 PR 记录: $PRS_TSV（先执行 create-pr.sh）"
  local SCAN_PAT="/(${SCAN_REPOS// /|}):[^:]*-distroless$"

  # ---------- 每个 PR：按 head sha 找到对应 run ----------
  local -a TARGETS=() FIXBRS=() PRNUMS=() RUNIDS=()
  local t fb pr url sha rid start
  while IFS=$'\t' read -r t fb pr url; do
    local state
    state="$(gh pr view "$pr" --repo "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    if [[ "$state" != "OPEN" ]]; then
      warn "PR #$pr（$t）状态为 $state，跳过监控"
      continue
    fi
    sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)"
    info "等待 PR #$pr（$t，head ${sha:0:10}）的 '$WORKFLOW' run 出现（最长 ${APPEAR_TIMEOUT}s）..."
    start="$(date +%s)"
    rid=""
    while :; do
      rid="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$fb" --limit 10 \
        --json databaseId,headSha --jq "[.[] | select(.headSha == \"$sha\")][0].databaseId // empty" 2>/dev/null || true)"
      [[ -n "$rid" ]] && break
      if (( $(date +%s) - start > APPEAR_TIMEOUT )); then
        echo "RESULT: RUN_NOT_FOUND PR #$pr（$t）在 ${APPEAR_TIMEOUT}s 内没有出现对应 run"
        echo "  可能原因: PR base 分支的 pr-builder 分支过滤不匹配 / self-hosted runner 不在线"
        exit 4
      fi
      sleep 10
    done
    info "PR #$pr → run $rid"
    TARGETS+=("$t"); FIXBRS+=("$fb"); PRNUMS+=("$pr"); RUNIDS+=("$rid")
  done <"$PRS_TSV"
  [[ ${#RUNIDS[@]} -ge 1 ]] || die "没有可监控的 open PR"

  # ---------- 轮询直至全部完成 ----------
  local -a DONE=() CONC=()
  local i all_done st cc
  for i in "${!RUNIDS[@]}"; do DONE[$i]=""; CONC[$i]=""; done
  start="$(date +%s)"
  while :; do
    all_done=1
    for i in "${!RUNIDS[@]}"; do
      [[ -n "${DONE[$i]}" ]] && continue
      read -r st cc < <(gh run view "${RUNIDS[$i]}" --repo "$REPO" --json status,conclusion \
        --jq '"\(.status) \(.conclusion // "-")"' 2>/dev/null || echo "unknown -")
      if [[ "$st" == "completed" ]]; then
        DONE[$i]=1; CONC[$i]="$cc"
        echo "[$(date -u +%H:%M:%S)] run ${RUNIDS[$i]}（${TARGETS[$i]} PR #${PRNUMS[$i]}）completed: $cc"
      else
        all_done=0
      fi
    done
    [[ "$all_done" == 1 ]] && break
    if (( $(date +%s) - start > TIMEOUT )); then
      echo "RESULT: PIPELINE_TIMEOUT 等待超过 ${TIMEOUT}s 仍有 run 未完成，请稍后重跑本脚本或人工查看"
      for i in "${!RUNIDS[@]}"; do
        [[ -z "${DONE[$i]}" ]] && echo "  未完成: ${TARGETS[$i]} PR #${PRNUMS[$i]} run ${RUNIDS[$i]}"
      done
      exit 3
    fi
    sleep "$INTERVAL"
  done

  # ---------- 收集结果 ----------
  local NEXT=$((ROUND + 1))
  local IMG_TSV="$STATE_DIR/images-round${NEXT}.tsv"
  : >"$IMG_TSV"   # 重跑时整体重建，保持幂等
  local FAILED=0 imgs
  for i in "${!RUNIDS[@]}"; do
    if [[ "${CONC[$i]}" == "success" ]]; then
      imgs="$(gh run view "${RUNIDS[$i]}" --repo "$REPO" --log 2>/dev/null \
        | grep -oE 'BUILD_IMAGE=[^"$[:space:]][^[:space:]]*' | cut -d= -f2- | sort -u \
        | grep -E "$SCAN_PAT" || true)"
      [[ -n "$imgs" ]] || { warn "run ${RUNIDS[$i]} 成功但未提取到扫描范围内的镜像"; }
      while IFS= read -r img; do
        [[ -n "$img" ]] && printf '%s\t%s\t%s\t%s\n' "$NEXT" "${RUNIDS[$i]}" "${TARGETS[$i]}" "$img" >>"$IMG_TSV"
      done <<<"$imgs"
      echo "OK: ${TARGETS[$i]} PR #${PRNUMS[$i]} 构建成功，新镜像:"
      sed 's/^/    /' <<<"${imgs:-（无）}"
    else
      FAILED=$((FAILED + 1))
      echo
      echo "FAIL: ${TARGETS[$i]} PR #${PRNUMS[$i]} run ${RUNIDS[$i]} conclusion=${CONC[$i]}"
      echo "  失败 step 概览:"
      gh run view "${RUNIDS[$i]}" --repo "$REPO" 2>/dev/null | grep -E '^(X|✓|-|\*)' | head -15 | sed 's/^/    /' || true
      echo "  失败日志摘要（完整: gh run view ${RUNIDS[$i]} --repo $REPO --log-failed）:"
      gh run view "${RUNIDS[$i]}" --repo "$REPO" --log-failed 2>/dev/null | tail -80 | sed 's/^/    /' \
        || echo "    （拉取失败日志出错，请人工查看）"
    fi
  done

  echo
  if [[ "$FAILED" -gt 0 ]]; then
    echo "RESULT: PIPELINE_FAILED（$FAILED 个 run 失败，分析原因后修复重推，再重跑本脚本）"
    exit 2
  fi
  set_state ROUND "$NEXT"
  echo "RESULT: ALL_SUCCESS"
  echo "回归轮镜像清单: $IMG_TSV"
  echo "下一步: 执行 scan-images.sh 做第 ${NEXT} 轮回归扫描（Bash timeout 600000）"
}

main "$@"
