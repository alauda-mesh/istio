#!/usr/bin/env bash
# 步骤 2b：在修复 worktree 中升级 go.mod 依赖并做本地构建验证。
# 用法: gomod-bump.sh <目标分支|worktree目录> <module@vX.Y.Z> [module@vX.Y.Z ...]
#   例: gomod-bump.sh istio-1.28.1 golang.org/x/net@v0.60.0
# 版本号必须带 v 前缀（扫描给的修复候选没有 v，拼参数时要加上）。
# 构建验证只编译三个修复镜像的 go 二进制入口（pilot-discovery/pilot-agent/install-cni/istio-cni），
# 会连带编译其依赖的全部包，足以验证升级未破坏构建，比 go build ./... 快得多。
# 退出码: 0=构建验证通过（RESULT: BUILD_OK） 非0=某一步失败（保留现场供分析）
# 注意: go get 下载依赖 + 编译可能要几分钟，Bash timeout 设 600000。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  [[ $# -ge 2 ]] || die "用法: gomod-bump.sh <目标分支|worktree目录> <module@vX.Y.Z ...>"
  local WT; WT="$(resolve_worktree "$1")"; shift
  command -v go >/dev/null 2>&1 || die "找不到 go 工具链"

  cd "$WT"
  # go.mod 要求的 go 版本可能高于本机默认，auto 允许按需获取工具链
  export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
  local before_go; before_go="$(sed -n 's/^go //p' go.mod)"

  info "go get $*"
  go get "$@"
  info "go mod tidy"
  go mod tidy
  info "构建验证: go build ./pilot/cmd/... ./cni/cmd/...（首次需下载依赖，可能几分钟）"
  go build ./pilot/cmd/... ./cni/cmd/...

  echo
  echo "实际落位版本（依赖间约束可能使其高于请求版本，属正常；记入 fix-records 供其他分支复用）:"
  local spec mod
  for spec in "$@"; do
    mod="${spec%@*}"
    echo "  $(go list -m "$mod" 2>/dev/null || echo "$mod （已不在依赖图中）")"
  done
  local after_go; after_go="$(sed -n 's/^go //p' go.mod)"
  [[ "$before_go" != "$after_go" ]] \
    && warn "go.mod 的 go directive 被连带提升: $before_go → $after_go（流水线 GOTOOLCHAIN 需 ≥ 该版本，PR 正文中说明一句）"
  echo
  echo "变更文件:"
  git status --short
  echo "RESULT: BUILD_OK"
}

main "$@"
