#!/usr/bin/env bash
# 步骤（仅小版本同步）：创建历史 release 分支。
# 把合并前的 origin/istio-1.XX 状态留档为 istio-<旧版本> 分支（如 istio-1.28.6），
# istio-1.XX 大版本分支始终保持为最新小版本。
# 直接 push 记录好的合并前 SHA，不受 PR 是否已合并影响。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  load_state
  [[ "$MODE" == "minor" ]] || die "仅小版本同步需要创建历史 release 分支（当前 MODE=$MODE）"
  [[ -n "${HISTORY_BRANCH:-}" && -n "${PRE_MERGE_SHA:-}" ]] || die "状态文件缺少 HISTORY_BRANCH/PRE_MERGE_SHA"

  local remote_sha
  remote_sha="$(git ls-remote --heads origin "$HISTORY_BRANCH" | awk '{print $1}')"
  if [[ -n "$remote_sha" ]]; then
    echo "EXISTS"
    echo "origin/$HISTORY_BRANCH 已存在（@ ${remote_sha:0:10}），不做修改"
    if [[ "$remote_sha" != "$PRE_MERGE_SHA" ]]; then
      warn "其指向与本次合并前的 $TARGET_BRANCH（${PRE_MERGE_SHA:0:10}）不同，可能带有 hotfix 提交，请在汇报中说明"
    fi
    exit 0
  fi

  info "创建 origin/$HISTORY_BRANCH @ ${PRE_MERGE_SHA:0:10}（合并 $NEW_TAG 前的 $TARGET_BRANCH）..."
  git push origin "$PRE_MERGE_SHA:refs/heads/$HISTORY_BRANCH" || die "push 失败"

  echo "CREATED"
  echo "历史分支: $HISTORY_BRANCH @ ${PRE_MERGE_SHA:0:10}（对应上游 $OLD_VERSION）"
  echo "下一步: 执行 update-base-images.sh 更新 istio-base-images 分支列表"
}

main "$@"
