#!/usr/bin/env bash
# fix-image-vulns 公共函数与状态管理。
# 状态目录 out/fix-image-vulns/（out/ 在 .gitignore 内）：
#   state.env        键值状态（ROUND、BRANCHES 等），脚本间传递
#   runs.tsv         输入 run 解析结果
#   images-roundN.tsv  第 N 轮待扫描镜像（round/run/目标分支/镜像）
#   scans/roundN/    扫描原始 JSON 与分类 TSV
#   branches.tsv     目标分支 → 修复分支/worktree
#   prs.tsv          目标分支 → PR
#   worktrees/       各目标分支的修复 worktree
set -euo pipefail

REPO="${FIX_REPO:-alauda-mesh/istio}"
SCAN_API="${SCAN_API:-http://192.168.25.100:8888}"
# 扫描范围：流水线产物中只扫这四个镜像的 -distroless 变体（istioctl、debug 变体等不在范围）
SCAN_REPOS="install-cni pilot proxyv2 ztunnel"
# 修复范围：ztunnel（rust）只扫不修
FIX_REPOS="install-cni pilot proxyv2"

die()  { echo "错误: $*" >&2; exit 1; }
warn() { echo "警告: $*" >&2; }
info() { echo "==> $*" >&2; }

STATE_DIR_REL="out/fix-image-vulns"

repo_root() {
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
  # worktree 中执行时回到主仓库根（状态目录只放主仓库）。
  # --git-common-dir 在主仓库根返回相对的 ".git"，必须转成绝对路径再比较，
  # 否则主仓库会被误判、ROOT 退化成 "."（cd 进 worktree 后相对路径全部失效）
  local common; common="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
  [[ "$common" != "$ROOT/.git" ]] && ROOT="$(dirname "$common")"
  [[ -f "$ROOT/common/scripts/setup_env.sh" && -d "$ROOT/alauda" ]] \
    || die "当前仓库不是 alauda istio 仓库: $ROOT"
  cd "$ROOT"
  STATE_DIR="$ROOT/$STATE_DIR_REL"
  STATE_FILE="$STATE_DIR/state.env"
  mkdir -p "$STATE_DIR"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "状态文件不存在: $STATE_FILE（先执行 resolve-runs.sh）"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

set_state() { # set_state KEY VALUE
  touch "$STATE_FILE"
  grep -v "^${1}=" "$STATE_FILE" >"$STATE_FILE.tmp" || true
  echo "${1}=\"${2}\"" >>"$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

require_gh() {
  command -v gh >/dev/null 2>&1 || die "找不到 gh CLI"
  gh auth status >/dev/null 2>&1 || die "gh 未认证。请提示用户在会话中执行: ! gh auth login"
}

# push/建 PR 前的安全守卫：测试克隆环境的 origin 不是 alauda 仓库时拒绝外发
origin_is_alauda() {
  local url; url="$(git remote get-url origin 2>/dev/null || true)"
  [[ "$url" =~ github\.com[:/]${REPO}(\.git)?$ ]]
}

valid_target_branch() { [[ "$1" =~ ^istio-1\.[0-9]+(\.[0-9]+)?$ ]]; }

# 镜像地址 → 安全文件名
img_slug() { tr '/:' '__' <<<"$1"; }

# 镜像地址 → 短仓库名（build-harbor.alauda.cn/asm/pilot:tag → pilot）
img_repo() { local p="${1%%:*}"; echo "${p##*/}"; }

# 从 branches.tsv 解析目标分支的 worktree（参数可为目标分支或 worktree 路径本身）
resolve_worktree() {
  local arg="$1" wt=""
  if [[ -d "$arg" && -f "$arg/go.mod" ]]; then
    wt="$arg"
  elif [[ -f "$STATE_DIR/branches.tsv" ]]; then
    wt="$(awk -F'\t' -v b="$arg" '$1==b {print $3; exit}' "$STATE_DIR/branches.tsv")"
  fi
  [[ -n "$wt" && -d "$wt" ]] || die "找不到 '$arg' 对应的修复 worktree（先执行 create-fix-branch.sh）"
  echo "$wt"
}
