#!/usr/bin/env bash
# 步骤 2c：升级修复 worktree 中两条 workflow 的 GOTOOLCHAIN（修 go stdlib 漏洞）。
# 用法: update-gotoolchain.sh <目标分支|worktree目录> <go1.X.Y>
#   例: update-gotoolchain.sh istio-1.28.1 go1.25.13
# 两个文件必须同改（仓库惯例）：.github/workflows/pr-builder.yaml + release.yaml。
# 只改值不 commit；GOTOOLCHAIN 附近的历史注释（pin 原因、CVE 编号）可能过时，
# 脚本会打印出来，由模型判断改写。
# 退出码: 0=OK  1=前置失败  2=某文件缺少 GOTOOLCHAIN 行（需模型用 Edit 手动补，见输出提示）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

main() {
  repo_root
  [[ $# -eq 2 ]] || die "用法: update-gotoolchain.sh <目标分支|worktree目录> <go1.X.Y>"
  local WT V="$2"
  WT="$(resolve_worktree "$1")"
  [[ "$V" =~ ^go1\.[0-9]+\.[0-9]+$ ]] || die "GOTOOLCHAIN 版本格式应为 go1.X.Y，收到: $V"

  cd "$WT"
  local FAILS=0 f old
  for f in .github/workflows/pr-builder.yaml .github/workflows/release.yaml; do
    [[ -f "$f" ]] || die "缺少 $f"
    old="$(sed -n 's/^[[:space:]]*GOTOOLCHAIN:[[:space:]]*//p' "$f" | head -1)"
    if [[ -z "$old" ]]; then
      echo "FAIL: $f 中没有 GOTOOLCHAIN 行。请用 Edit 在 Build 步骤的 env 块（IMAGE_VERSION 附近）新增:"
      echo "          GOTOOLCHAIN: $V"
      FAILS=$((FAILS + 1))
      continue
    fi
    if [[ "$old" == "$V" ]]; then
      echo "OK: $f GOTOOLCHAIN 已是 $V"
    else
      sed -i -E "s|^([[:space:]]*)GOTOOLCHAIN:.*$|\1GOTOOLCHAIN: $V|" "$f"
      grep -qE "^[[:space:]]*GOTOOLCHAIN:[[:space:]]*$V$" "$f" \
        && echo "OK: $f GOTOOLCHAIN: $old → $V" \
        || { echo "FAIL: $f GOTOOLCHAIN 替换未生效"; FAILS=$((FAILS + 1)); }
    fi
    # pin 注释通常记录上次 CVE 的缘由，升级后需要模型审阅改写
    if grep -B3 '^[[:space:]]*GOTOOLCHAIN:' "$f" | grep -q '#'; then
      echo "NOTICE: $f 中 GOTOOLCHAIN 上方注释如下，请审阅并用 Edit 更新为本次升级的缘由（CVE 编号等）："
      grep -n -B3 '^[[:space:]]*GOTOOLCHAIN:' "$f" | grep '#' | sed 's/^/    /'
    fi
  done

  echo
  if [[ $FAILS -gt 0 ]]; then
    echo "PATTERN_MISMATCH"
    echo "共 $FAILS 项需要模型用 Edit 手动完成（两文件的 GOTOOLCHAIN 值必须一致）。"
    exit 2
  fi
  echo "GOTOOLCHAIN_UPDATED"
  git -C "$WT" diff --stat -- .github/workflows | tail -5
}

main "$@"
