#!/usr/bin/env bash
# 大版本同步 步骤 1：
#   基于上游 tag 创建新大版本分支 istio-1.XX，将分支和 tag 原子 push、设为 GitHub 默认分支；
#   创建 chore/alauda-1.XX-build 构建分支；
#   从上一个大版本分支恢复 .github/workflows 与 alauda/；
#   生成"上一个大版本的构建配置定制 diff"并尝试 git apply --3way 自动套用。
# 用法: sync-major.sh <上游tag> <目标分支>   例如: sync-major.sh 1.30.0 istio-1.30
# 退出码: 0=PREPARED（diff 干净套用）  1=前置条件失败  2=APPLY_CONFLICT（需模型解决冲突）
#
# 注意：checkout 上游 tag 后 alauda/ 目录（含本 skill）会暂时从工作区消失，
# 脚本会先把 skill 快照到 out/sync-upstream/skill-snapshot/，中断后可从快照续跑。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Alauda 对上游构建体系的定制文件清单（历史迁移的既定范围，见 SKILL.md）
BUILD_FILES=(
  Makefile.core.mk
  common/scripts/report_build_info.sh
  istioctl/docker/Dockerfile.istioctl
  tools/docker-builder/docker.go
  tools/docker-builder/types.go
  tools/docker-copy.sh
)

main() {
  local NEW_TAG="${1:-}" TARGET_BRANCH="${2:-}"
  [[ -n "$NEW_TAG" && -n "$TARGET_BRANCH" ]] || die "用法: sync-major.sh <上游tag> <目标分支>"
  [[ "$NEW_TAG" =~ ^1\.[0-9]+\.[0-9]+$ ]] || die "tag 格式应为 1.X.Y（istio tag 无 v 前缀），实际: $NEW_TAG"
  [[ "$TARGET_BRANCH" =~ ^istio-1\.[0-9]+$ ]] || die "目标分支格式应为 istio-1.X，实际: $TARGET_BRANCH"

  local MAJOR
  MAJOR="$(tag_major "$NEW_TAG")"
  [[ "$TARGET_BRANCH" == "istio-$MAJOR" ]] \
    || die "tag $NEW_TAG 属于大版本 $MAJOR，新大版本分支应命名为 istio-$MAJOR，实际: $TARGET_BRANCH"

  repo_root
  clean_tree_or_die
  ensure_push_credentials
  git ls-remote --exit-code --heads origin "$TARGET_BRANCH" >/dev/null 2>&1 \
    && die "origin 已存在分支 $TARGET_BRANCH；若是小版本升级请改用 sync-minor.sh"
  git rev-parse --verify --quiet "$TARGET_BRANCH" >/dev/null \
    && die "本地分支 $TARGET_BRANCH 已存在，请先处理"

  ensure_upstream
  tag_exists "$NEW_TAG" || die "上游不存在 tag $NEW_TAG"

  # 上一个大版本分支 = origin 上 istio-1.X 中版本号最高的（Alauda 定制内容从它恢复）
  local PREV_MAJOR_BRANCH
  PREV_MAJOR_BRANCH="$(git ls-remote --heads origin 'istio-1.*' | awk -F'refs/heads/' '{print $2}' \
    | grep -E '^istio-1\.[0-9]+$' | sort -V | tail -1)"
  [[ -n "$PREV_MAJOR_BRANCH" ]] || die "origin 上找不到任何 istio-1.X 大版本分支，无法确定定制内容来源"
  local PREV_MAJOR="${PREV_MAJOR_BRANCH#istio-}"
  version_lt "$PREV_MAJOR" "$MAJOR" \
    || die "目标大版本 $MAJOR 不高于现有最新大版本分支 $PREV_MAJOR_BRANCH，不支持向旧版本同步"

  git fetch origin "$PREV_MAJOR_BRANCH" || die "fetch origin/$PREV_MAJOR_BRANCH 失败"
  local PREV_SHA PREV_BASE_TAG
  PREV_SHA="$(git rev-parse "origin/$PREV_MAJOR_BRANCH")"
  PREV_BASE_TAG="$(latest_release_tag_of "$PREV_SHA")"
  [[ -n "$PREV_BASE_TAG" ]] || die "无法识别 origin/$PREV_MAJOR_BRANCH 所处的上游版本"

  # checkout 上游 tag 后本 skill 会暂时消失，先自我快照以便中断后续跑
  local SKILL_DIR SNAP="$STATE_DIR_REL/skill-snapshot"
  SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  rm -rf "$SNAP" && mkdir -p "$SNAP"
  cp -r "$SKILL_DIR/." "$SNAP/"

  # ---------- 新大版本分支（内容 = 上游 tag，分支与 tag 原子 push）----------
  info "基于上游 tag $NEW_TAG 创建分支 $TARGET_BRANCH ..."
  git checkout -b "$TARGET_BRANCH" "refs/tags/$NEW_TAG"
  # pr-builder 使用 gh-describe 从 fork 的 GitHub API 查询可达 tag。新大版本历史与
  # 上一版 ASM release tag 已分叉，因此必须把本次上游 tag 一并镜像到 origin；
  # 使用原子 push，避免只创建分支却没有 tag，导致首个构建 PR 无法生成镜像标签。
  git push --atomic --set-upstream origin \
    "$TARGET_BRANCH" "refs/tags/$NEW_TAG" \
    || die "原子 push $TARGET_BRANCH 与 tag $NEW_TAG 失败"
  if origin_is_alauda; then
    if gh repo edit "$REPO" --default-branch "$TARGET_BRANCH" >/dev/null; then
      info "已将 GitHub 默认分支设为 $TARGET_BRANCH"
    else
      warn "设置默认分支失败，请稍后手动执行: gh repo edit $REPO --default-branch $TARGET_BRANCH"
    fi
  else
    warn "origin 不是 github.com/$REPO（测试环境？），跳过设置默认分支"
  fi

  # ---------- Alauda 构建分支：恢复定制内容 ----------
  local BUILD_BRANCH="chore/alauda-$MAJOR-build"
  git rev-parse --verify --quiet "$BUILD_BRANCH" >/dev/null && die "本地分支 $BUILD_BRANCH 已存在，请先处理"
  git checkout -b "$BUILD_BRANCH"
  info "从 origin/$PREV_MAJOR_BRANCH 恢复 .github/workflows 与 alauda/ ..."
  git checkout "$PREV_SHA" -- .github/workflows alauda
  # .claude/skills/sync-upstream 是指向 alauda/skills 的 symlink（本 skill 的 Claude Code 接入点），一并恢复
  if git cat-file -e "$PREV_SHA:.claude" 2>/dev/null; then
    git checkout "$PREV_SHA" -- .claude
  fi

  # ---------- 生成构建配置参考 diff 并尝试自动套用 ----------
  # 参考 diff = 上一个大版本相对其上游基线对 BUILD_FILES 的定制；同时输出完整定制
  # stat 供模型核对是否有清单之外的定制文件。
  git diff "$PREV_BASE_TAG" "$PREV_SHA" -- "${BUILD_FILES[@]}" >"$STATE_DIR_REL/build-config.diff"
  git diff "$PREV_BASE_TAG" "$PREV_SHA" --stat >"$STATE_DIR_REL/prev-custom.stat"

  {
    echo "MODE=major"
    echo "NEW_TAG=$NEW_TAG"
    echo "MAJOR=$MAJOR"
    echo "TARGET_BRANCH=$TARGET_BRANCH"
    echo "SYNC_BRANCH=$BUILD_BRANCH"
    echo "PREV_MAJOR_BRANCH=$PREV_MAJOR_BRANCH"
    echo "PREV_MAJOR=$PREV_MAJOR"
    echo "PREV_SHA=$PREV_SHA"
    echo "PREV_BASE_TAG=$PREV_BASE_TAG"
  } >"$STATE_FILE_REL"

  local APPLY_RESULT=PREPARED
  if [[ -s "$STATE_DIR_REL/build-config.diff" ]]; then
    info "git apply --3way 套用构建配置定制 diff ..."
    if ! git apply --3way "$STATE_DIR_REL/build-config.diff"; then
      if git ls-files -u | grep -q .; then
        APPLY_RESULT=APPLY_CONFLICT
      else
        die "git apply 失败（非冲突原因），请检查 $STATE_DIR_REL/build-config.diff"
      fi
    fi
  else
    warn "构建配置定制 diff 为空（上一个大版本未定制这些文件？请人工确认）"
  fi

  echo
  echo "$APPLY_RESULT"
  echo "新大版本分支: $TARGET_BRANCH（= 上游 $NEW_TAG，分支与 tag 已原子 push）"
  echo "构建分支: $BUILD_BRANCH"
  echo "定制来源: origin/$PREV_MAJOR_BRANCH @ ${PREV_SHA:0:10}（其上游基线: $PREV_BASE_TAG）"
  echo "已恢复: .github/workflows/ alauda/ .claude"
  echo "构建配置参考 diff: $STATE_DIR_REL/build-config.diff"
  echo "上一版完整定制清单: $STATE_DIR_REL/prev-custom.stat（供核对遗漏）"
  if [[ "$APPLY_RESULT" == APPLY_CONFLICT ]]; then
    echo "以下文件三方合并存在冲突，请解决后 git add（先不要 commit）："
    git diff --name-only --diff-filter=U | sed 's/^/  - /'
    exit 2
  fi
  echo
  echo "下一步: 执行 update-workflows.sh 完成流水线机械修改"
}

main "$@"
