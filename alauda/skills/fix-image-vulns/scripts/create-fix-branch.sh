#!/usr/bin/env bash
# 步骤 2a：为目标分支创建修复分支（git worktree，不打扰主工作区当前检出）。
# 用法: create-fix-branch.sh <目标分支>   例如: create-fix-branch.sh istio-1.28.1
# 分支命名沿用仓库惯例（如 fix-1.28.1/cve-20260417）: fix-<版本>/cve-<UTC日期>
# worktree 放在 out/fix-image-vulns/worktrees/<目标分支>/（gitignore 内）。
# 幂等：worktree 已在对应修复分支上时直接复用（回归轮追加 commit 用）。
# 输出: WORKTREE= / BRANCH= / BASE=

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  load_state

  local T="${1:-}"
  valid_target_branch "$T" || die "用法: create-fix-branch.sh <istio-X.Y[.Z]>"
  local FIX_BRANCH="fix-${T#istio-}/cve-$(date -u +%Y%m%d)"
  local WT="$STATE_DIR/worktrees/$T"
  local BR_TSV="$STATE_DIR/branches.tsv"

  info "fetch origin/$T ..."
  git fetch -q origin "refs/heads/$T:refs/remotes/origin/$T" \
    || die "fetch origin/$T 失败（origin 上没有该分支？）"

  if [[ -e "$WT" ]]; then
    local cur
    cur="$(git -C "$WT" branch --show-current 2>/dev/null || true)"
    if [[ "$cur" == "$FIX_BRANCH" ]]; then
      info "worktree 已在分支 $FIX_BRANCH 上，直接复用"
    elif [[ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ]]; then
      info "移除残留的干净 worktree（原分支 ${cur:-未知}）"
      git worktree remove --force "$WT"
    else
      die "$WT 已存在且有未提交改动（分支 ${cur:-未知}），请人工确认后再处理"
    fi
  fi

  if [[ ! -e "$WT" ]]; then
    if git rev-parse --verify --quiet "refs/heads/$FIX_BRANCH" >/dev/null; then
      # 同日重跑：本地已有该修复分支（如上次中断），挂载 worktree 继续用
      warn "本地已存在分支 $FIX_BRANCH，直接挂载（其提交历史保留）"
      git worktree add -q "$WT" "$FIX_BRANCH"
    else
      git worktree add -q "$WT" -b "$FIX_BRANCH" "refs/remotes/origin/$T"
    fi
  fi

  # 记录 目标分支 → 修复分支/worktree 映射
  touch "$BR_TSV"
  grep -v "^${T}	" "$BR_TSV" >"$BR_TSV.tmp" || true
  printf '%s\t%s\t%s\n' "$T" "$FIX_BRANCH" "$WT" >>"$BR_TSV.tmp"
  mv "$BR_TSV.tmp" "$BR_TSV"

  echo
  echo "BRANCH_READY"
  echo "WORKTREE=$WT"
  echo "BRANCH=$FIX_BRANCH"
  echo "BASE=origin/$T（$(git -C "$WT" rev-parse --short "refs/remotes/origin/$T")）"
  echo "下一步: 在该 worktree 中执行 gomod-bump.sh / update-gotoolchain.sh"
}

main "$@"
