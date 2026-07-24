#!/usr/bin/env bash
# 公共函数与常量，供各步骤脚本 source 使用。

set -euo pipefail

REPO="alauda-mesh/istio"
BASE_IMAGES_REPO="alauda-mesh/istio-base-images"
# 测试时可用 UPSTREAM_URL 指向本地仓库
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/istio/istio.git}"

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*"; }
info() { echo "INFO: $*"; }

# 定位仓库根目录并 cd 过去
repo_root() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "当前目录不在 git 仓库内"
  [[ -f "$root/common/scripts/setup_env.sh" ]] || die "当前仓库不是 istio（缺少 common/scripts/setup_env.sh）"
  cd "$root"
  ROOT="$root"
}

# out/ 在 istio 的 .gitignore 中，状态文件与中间产物都放这里
STATE_DIR_REL="out/sync-upstream"
STATE_FILE_REL="$STATE_DIR_REL/state.env"

# 加载 sync-minor.sh / sync-major.sh 写入的状态
load_state() {
  [[ -f "$ROOT/$STATE_FILE_REL" ]] || die "未找到 $STATE_FILE_REL，请先执行 sync-minor.sh 或 sync-major.sh"
  # shellcheck disable=SC1090
  source "$ROOT/$STATE_FILE_REL"
  [[ -n "${MODE:-}" && -n "${NEW_TAG:-}" ]] || die "$STATE_FILE_REL 内容不完整，请重新执行同步脚本"
}

# origin 是否指向真实的 alauda-mesh/istio（沙箱测试时 origin 是本地路径，跳过 gh 操作）
origin_is_alauda() {
  git remote get-url origin 2>/dev/null | grep -qE "github\.com[:/]${REPO}(\.git)?$"
}

clean_tree_or_die() {
  git diff --quiet && git diff --cached --quiet || die "工作区不干净，请先提交或 stash"
}

# 确保 upstream remote 存在并 fetch（含 tags）
ensure_upstream() {
  if ! git remote get-url upstream >/dev/null 2>&1; then
    info "添加 upstream remote: $UPSTREAM_URL"
    git remote add upstream "$UPSTREAM_URL"
  fi
  info "fetch upstream（含 tags，仓库较大可能需要几分钟）..."
  git fetch upstream --tags || die "git fetch upstream 失败"
}

# 1.28.3 -> 1.28（istio 语境下 1.28 即"大版本"）
tag_major() { echo "$1" | cut -d. -f1-2; }

tag_exists() { git rev-parse --verify --quiet "refs/tags/$1^{commit}" >/dev/null; }

# 某个提交所包含的最新上游正式版 tag（形如 1.X.Y），用于识别分支当前所处的小版本
latest_release_tag_of() {
  git tag --merged "$1" | grep -E '^1\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}

# 从 setup_env.sh（传文件路径）提取 IMAGE_VERSION 默认值
image_version_default() {
  sed -n 's/^[[:space:]]*IMAGE_VERSION=\([A-Za-z0-9._-]\{1,\}\)$/\1/p' "$1" | head -1
}

# 版本比较：$1 是否严格低于 $2（sort -V 语义）
version_lt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}
