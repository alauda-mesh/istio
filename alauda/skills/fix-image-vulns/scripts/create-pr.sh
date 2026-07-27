#!/usr/bin/env bash
# 步骤 3：push 修复分支并创建 PR（base = 目标分支）。
# 用法: create-pr.sh <目标分支> <PR正文文件>
# 幂等：修复分支已有 open PR 时直接复用（回归轮 push 新 commit 即可）。
# 输出: PR_NUMBER= / PR_URL=，并记录到 prs.tsv（watch-prs.sh 用）。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  load_state
  require_gh

  local T="${1:-}" BODY_FILE="${2:-}"
  valid_target_branch "$T" || die "用法: create-pr.sh <istio-X.Y[.Z]> <PR正文文件>"
  [[ -n "$BODY_FILE" && -f "$BODY_FILE" ]] || die "PR 正文文件不存在: $BODY_FILE（先写好正文再执行）"
  origin_is_alauda || die "origin 不是 $REPO，拒绝 push/建 PR（测试环境守卫）"

  local WT FIX_BRANCH
  WT="$(resolve_worktree "$T")"
  FIX_BRANCH="$(awk -F'\t' -v b="$T" '$1==b {print $2; exit}' "$STATE_DIR/branches.tsv")"
  [[ -n "$FIX_BRANCH" ]] || die "branches.tsv 中没有 $T 的修复分支记录"

  cd "$WT"
  [[ "$(git branch --show-current)" == "$FIX_BRANCH" ]] || die "worktree 当前分支不是 $FIX_BRANCH"
  [[ -z "$(git status --porcelain)" ]] || die "worktree 有未提交改动，请先 commit（禁止 amend，一律新建 commit）"
  local n
  n="$(git rev-list --count "refs/remotes/origin/$T..HEAD")"
  [[ "$n" -ge 1 ]] || die "相对 origin/$T 没有新 commit，无内容可提 PR"

  info "push $FIX_BRANCH 到 origin ..."
  git push -u origin "$FIX_BRANCH" || die "push 失败"

  local PR_INFO
  PR_INFO="$(gh pr list --repo "$REPO" --head "$FIX_BRANCH" --state open \
    --json number,url --jq '.[0] | "\(.number) \(.url)"' 2>/dev/null || true)"
  if [[ -n "$PR_INFO" && "$PR_INFO" != "null null" ]]; then
    info "分支 $FIX_BRANCH 已有 open PR，直接复用"
  else
    # 标题沿用仓库惯例（fix: CVE on <日期>），日期取自修复分支名，多分支时附分支后缀区分
    local d="${FIX_BRANCH##*/cve-}" TITLE
    TITLE="fix: CVE on ${d:0:4}-${d:4:2}-${d:6:2} ($T)"
    gh pr create --repo "$REPO" --base "$T" --head "$FIX_BRANCH" \
      --title "$TITLE" --body-file "$BODY_FILE" >/dev/null || die "创建 PR 失败"
    PR_INFO="$(gh pr list --repo "$REPO" --head "$FIX_BRANCH" --state open \
      --json number,url --jq '.[0] | "\(.number) \(.url)"')"
  fi

  local PR_NUMBER="${PR_INFO%% *}" PR_URL="${PR_INFO##* }"
  local PRS_TSV="$STATE_DIR/prs.tsv"
  touch "$PRS_TSV"
  grep -v "^${T}	" "$PRS_TSV" >"$PRS_TSV.tmp" || true
  printf '%s\t%s\t%s\t%s\n' "$T" "$FIX_BRANCH" "$PR_NUMBER" "$PR_URL" >>"$PRS_TSV.tmp"
  mv "$PRS_TSV.tmp" "$PRS_TSV"

  echo
  echo "PR_NUMBER=$PR_NUMBER"
  echo "PR_URL=$PR_URL"
  echo "全部分支的 PR 建完后: 后台执行 watch-prs.sh 监控流水线"
}

main "$@"
