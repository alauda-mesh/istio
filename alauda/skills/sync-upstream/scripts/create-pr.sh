#!/usr/bin/env bash
# 步骤：push 同步/构建分支并创建 PR（幂等：分支已有 open PR 时直接复用）。
# 用法: create-pr.sh <PR正文文件>

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  load_state

  local BODY_FILE="${1:-}"
  [[ -n "$BODY_FILE" && -f "$BODY_FILE" ]] || die "用法: create-pr.sh <PR正文文件>（文件必须存在）"

  command -v gh >/dev/null || die "未安装 gh"
  gh auth status >/dev/null 2>&1 || die "gh 未认证，请提示用户执行: ! gh auth login"
  origin_is_alauda || die "origin 不是 github.com/$REPO（测试环境？），拒绝创建 PR"

  local CUR_BRANCH
  CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  [[ "$CUR_BRANCH" == "$SYNC_BRANCH" ]] || die "当前分支是 $CUR_BRANCH，应在 $SYNC_BRANCH 上执行"
  git diff --quiet && git diff --cached --quiet || die "有未提交的修改，请先 commit（禁止 amend）"

  local TITLE
  if [[ "$MODE" == "minor" ]]; then
    TITLE="feat: sync istio $NEW_TAG"
  else
    TITLE="chore: istio $MAJOR build with alauda infra"
  fi

  info "push $SYNC_BRANCH 到 origin ..."
  git push -u origin "$SYNC_BRANCH"

  local PR_NUMBER EXISTING
  EXISTING="$(gh pr list --repo "$REPO" --head "$SYNC_BRANCH" --state open --json number -q '.[0].number' 2>/dev/null || true)"
  if [[ -n "$EXISTING" ]]; then
    info "分支已有 open PR #$EXISTING，复用"
    PR_NUMBER="$EXISTING"
  else
    gh pr create --repo "$REPO" \
      --base "$TARGET_BRANCH" --head "$SYNC_BRANCH" \
      --title "$TITLE" --body-file "$BODY_FILE" >/dev/null
    PR_NUMBER="$(gh pr list --repo "$REPO" --head "$SYNC_BRANCH" --state open --json number -q '.[0].number')"
  fi
  [[ -n "$PR_NUMBER" ]] || die "PR 创建后未能查询到编号，请用 gh pr list --repo $REPO 排查"

  # 记录 PR 号（幂等：先删旧记录）
  sed -i '/^PR_NUMBER=/d' "$STATE_FILE_REL"
  echo "PR_NUMBER=$PR_NUMBER" >>"$STATE_FILE_REL"

  echo "PR_NUMBER=$PR_NUMBER"
  echo "PR_URL=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json url -q .url)"
  if [[ "$MODE" == "minor" ]]; then
    echo "下一步: 执行 create-history-branch.sh 创建历史 release 分支"
  else
    echo "下一步: 执行 update-base-images.sh 更新 istio-base-images 分支列表"
  fi
}

main "$@"
