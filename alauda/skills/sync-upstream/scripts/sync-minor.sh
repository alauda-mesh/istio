#!/usr/bin/env bash
# 小版本同步 步骤 1：基于目标分支创建 feat/istio-<tag> 分支并 merge 上游 tag。
# 用法: sync-minor.sh <上游tag> <目标分支>   例如: sync-minor.sh 1.28.7 istio-1.28
# 退出码: 0=MERGED / UP_TO_DATE   1=前置条件失败   2=CONFLICT（需模型解决冲突后 git add + git commit --no-edit）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  local NEW_TAG="${1:-}" TARGET_BRANCH="${2:-}"
  [[ -n "$NEW_TAG" && -n "$TARGET_BRANCH" ]] || die "用法: sync-minor.sh <上游tag> <目标分支>"
  [[ "$NEW_TAG" =~ ^1\.[0-9]+\.[0-9]+$ ]] || die "tag 格式应为 1.X.Y（istio tag 无 v 前缀），实际: $NEW_TAG"
  [[ "$TARGET_BRANCH" =~ ^istio-1\.[0-9]+$ ]] || die "目标分支格式应为 istio-1.X，实际: $TARGET_BRANCH"

  local MAJOR
  MAJOR="$(tag_major "$NEW_TAG")"
  [[ "$TARGET_BRANCH" == "istio-$MAJOR" ]] \
    || die "tag $NEW_TAG 属于大版本 $MAJOR，与目标分支 $TARGET_BRANCH 不一致（该 tag 的小版本同步目标应为 istio-$MAJOR）"

  repo_root
  clean_tree_or_die
  git ls-remote --exit-code --heads origin "$TARGET_BRANCH" >/dev/null \
    || die "origin 不存在分支 $TARGET_BRANCH；若这是新大版本，请改用 sync-major.sh"

  local SYNC_BRANCH="feat/istio-$NEW_TAG"
  git rev-parse --verify --quiet "$SYNC_BRANCH" >/dev/null \
    && die "本地分支 $SYNC_BRANCH 已存在，请先处理（删除或换 tag）"

  ensure_upstream
  tag_exists "$NEW_TAG" || die "上游不存在 tag $NEW_TAG"
  git fetch origin "$TARGET_BRANCH" || die "fetch origin/$TARGET_BRANCH 失败"

  # 记录合并前的分支状态：历史 release 分支（istio-<旧版本>）就从这个提交创建
  local PRE_MERGE_SHA OLD_VERSION
  PRE_MERGE_SHA="$(git rev-parse "origin/$TARGET_BRANCH")"
  OLD_VERSION="$(latest_release_tag_of "$PRE_MERGE_SHA")"
  [[ -n "$OLD_VERSION" ]] || die "无法识别 origin/$TARGET_BRANCH 当前包含的上游版本（未找到已合入的 1.X.Y tag）"

  if ! version_lt "$OLD_VERSION" "$NEW_TAG"; then
    if [[ "$OLD_VERSION" == "$NEW_TAG" ]]; then
      echo "UP_TO_DATE"
      echo "origin/$TARGET_BRANCH 已包含上游 $NEW_TAG，无需同步"
      exit 0
    fi
    die "目标 tag $NEW_TAG 低于分支当前版本 $OLD_VERSION，不支持向旧版本同步"
  fi

  git checkout -b "$SYNC_BRANCH" "$PRE_MERGE_SHA"

  # 先写状态：冲突路径下后续脚本也要用
  mkdir -p "$STATE_DIR_REL"
  {
    echo "MODE=minor"
    echo "NEW_TAG=$NEW_TAG"
    echo "MAJOR=$MAJOR"
    echo "TARGET_BRANCH=$TARGET_BRANCH"
    echo "SYNC_BRANCH=$SYNC_BRANCH"
    echo "PRE_MERGE_SHA=$PRE_MERGE_SHA"
    echo "OLD_VERSION=$OLD_VERSION"
    echo "HISTORY_BRANCH=istio-$OLD_VERSION"
  } >"$STATE_FILE_REL"

  echo
  info "merge 上游 tag $NEW_TAG 到 $SYNC_BRANCH（$OLD_VERSION -> $NEW_TAG）..."
  if git merge --no-edit "$NEW_TAG"; then
    echo
    echo "MERGED"
    echo "分支: $SYNC_BRANCH（基于 origin/$TARGET_BRANCH @ ${PRE_MERGE_SHA:0:10}）"
    echo "版本: $OLD_VERSION -> $NEW_TAG，合入提交数: $(git rev-list --count "$PRE_MERGE_SHA..$NEW_TAG")"
    echo "变更概览:"
    git show --stat HEAD | tail -3
    echo
    echo "下一步: 执行 update-workflows.sh 更新流水线 IMAGE_VERSION"
  else
    if git ls-files -u | grep -q .; then
      echo
      echo "CONFLICT"
      echo "版本: $OLD_VERSION -> $NEW_TAG，以下文件存在合并冲突："
      git diff --name-only --diff-filter=U | sed 's/^/  - /'
      echo "请逐个文件解决（保留 Alauda 定制 + 合入上游新内容），然后 git add <文件>，"
      echo "最后 git commit --no-edit 完成合并（禁止 amend），再执行 update-workflows.sh。"
      exit 2
    fi
    die "merge 失败（非冲突原因），请查看上方 git 输出"
  fi
}

main "$@"
