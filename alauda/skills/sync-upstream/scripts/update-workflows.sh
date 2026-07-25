#!/usr/bin/env bash
# 步骤：机械更新流水线配置（只改文件不 commit，便于 review 后统一提交）。
#   两种模式都做: pr-builder.yaml / release.yaml 的 IMAGE_VERSION ← common/scripts/setup_env.sh 默认值
#   major 模式额外: pr-builder 的 branches 过滤、删除 GOTOOLCHAIN（含其注释行）、
#                  release.yaml setup-go 改用 go-version-file、alauda/release.sh 的 tools 分支、
#                  NOTICE 提示核查 release-builder pin（BUILDER_SHA）对新大版本的兼容性
# 退出码: 0=OK   1=前置条件失败   2=PATTERN_MISMATCH（列出 FAIL 项，需模型用 Edit 手动完成）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PR_YAML=".github/workflows/pr-builder.yaml"
REL_YAML=".github/workflows/release.yaml"
FAILS=0

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
notice() { echo "NOTICE: $*"; }

main() {
  repo_root
  load_state
  [[ -f "$PR_YAML" && -f "$REL_YAML" ]] || die "缺少 $PR_YAML 或 $REL_YAML（大版本模式请先执行 sync-major.sh）"

  # ---------- IMAGE_VERSION ----------
  local NEW_IV
  NEW_IV="$(image_version_default common/scripts/setup_env.sh)"
  [[ -n "$NEW_IV" ]] || die "无法从 common/scripts/setup_env.sh 提取 IMAGE_VERSION 默认值（上游文件结构可能变化，需人工确认）"

  # 旧基线的默认值：用于识别旧值是否是人为 pin（如 CVE 临时升级 build-tools）
  local OLD_BASE_SHA OLD_IV_DEFAULT
  if [[ "$MODE" == "minor" ]]; then OLD_BASE_SHA="$PRE_MERGE_SHA"; else OLD_BASE_SHA="$PREV_SHA"; fi
  OLD_IV_DEFAULT="$(image_version_default <(git show "$OLD_BASE_SHA:common/scripts/setup_env.sh" 2>/dev/null) || true)"

  local f old_iv
  for f in "$PR_YAML" "$REL_YAML"; do
    old_iv="$(sed -n 's/^[[:space:]]*IMAGE_VERSION:[[:space:]]*\(.*\)$/\1/p' "$f" | head -1)"
    if [[ -z "$old_iv" ]]; then
      fail "$f 中未找到 IMAGE_VERSION 行"
      continue
    fi
    if [[ "$old_iv" == "$NEW_IV" ]]; then
      ok "$f IMAGE_VERSION 已是新默认值（$NEW_IV），无需修改"
      continue
    fi
    if [[ -n "$OLD_IV_DEFAULT" && "$old_iv" != "$OLD_IV_DEFAULT" && "$NEW_IV" == "$OLD_IV_DEFAULT" ]]; then
      # 现值是人为 pin（通常为 CVE 升级 build-tools）且本次上游默认值没有推进：
      # 重置会把 pin 回退到更老的 build-tools，属于降级，保持不动
      notice "$f IMAGE_VERSION（$old_iv）是人为 pin，且本次上游默认值未变化（仍为 $NEW_IV），已保持 pin 不回退。请在汇报中说明。"
      continue
    fi
    sed -i -E "s|^([[:space:]]*)IMAGE_VERSION:.*$|\1IMAGE_VERSION: $NEW_IV|" "$f"
    if grep -qF "IMAGE_VERSION: $NEW_IV" "$f"; then
      ok "$f IMAGE_VERSION: $old_iv -> $NEW_IV"
    else
      fail "$f IMAGE_VERSION 替换未生效"
    fi
    if [[ -n "$OLD_IV_DEFAULT" && "$old_iv" != "$OLD_IV_DEFAULT" ]]; then
      notice "$f 原 IMAGE_VERSION（$old_iv）是人为 pin（不同于旧基线默认值 $OLD_IV_DEFAULT）。\
上游默认值已推进，本次已更新为新默认值，请在汇报中说明，由用户判断是否需要重新 pin。"
    fi
    # IMAGE_VERSION 上方的注释多为历史 pin 的说明，值更新后可能过时，交给模型审阅
    if grep -B2 '^[[:space:]]*IMAGE_VERSION:' "$f" | grep -q '#'; then
      notice "$f 中 IMAGE_VERSION 附近有注释，请审阅是否已过时（过时则用 Edit 删除或改写）："
      grep -n -B2 '^[[:space:]]*IMAGE_VERSION:' "$f" | grep '#' | sed 's/^/    /'
    fi
  done

  if [[ "$MODE" == "major" ]]; then
    # ---------- pr-builder 分支过滤 ----------
    # 重写为规范形式 istio-1.XX*（* 通配同时覆盖 istio-1.XX.Y 历史分支的 hotfix PR）；
    # 旧版可能写作 [ "istio-1.26" ] 无通配，所以整行重写而不是只替换版本号
    if grep -qE '^[[:space:]]*branches:.*istio-1\.[0-9]+' "$PR_YAML"; then
      sed -i -E "s|^([[:space:]]*)branches:.*istio-1\.[0-9]+.*$|\1branches: [ \"istio-$MAJOR*\" ]|" "$PR_YAML"
      grep -qF "istio-$MAJOR*" "$PR_YAML" && ok "$PR_YAML 分支过滤 -> [ \"istio-$MAJOR*\" ]" \
        || fail "$PR_YAML 分支过滤替换未生效"
    else
      fail "$PR_YAML 中未找到 istio-1.X 分支过滤行（期望改为 branches: [ \"istio-$MAJOR*\" ]）"
    fi

    # ---------- 删除 GOTOOLCHAIN（历史 CVE pin 不带入新大版本；新版本 build-tools 自带新 Go）----------
    for f in "$PR_YAML" "$REL_YAML"; do
      if grep -qE '^[[:space:]]*GOTOOLCHAIN:' "$f"; then
        sed -i -E '/^[[:space:]]*#.*GOTOOLCHAIN/d; /^[[:space:]]*GOTOOLCHAIN:/d' "$f"
        grep -qE '^[[:space:]]*GOTOOLCHAIN:' "$f" && fail "$f GOTOOLCHAIN 删除未生效" \
          || ok "$f 已删除 GOTOOLCHAIN 环境变量"
      else
        ok "$f 无 GOTOOLCHAIN，无需删除"
      fi
    done

    # ---------- release.yaml setup-go 跟随 go.mod ----------
    # release-builder 以 BUILD_WITH_CONTAINER=0 在 runner 上直接跑 make（非 build-tools 容器），
    # runner Go 必须满足 istio go.mod 的最低要求，且 runner 带 GOTOOLCHAIN=local 不会自动下载
    # 新工具链（1.30 首战：固定 go-version "1.24" 遇 go.mod >=1.25.9，release 流水线直接失败）。
    # 用 go-version-file 让 setup-go 始终跟随当前分支 go.mod，大版本升级无需人工调整。
    if grep -qF 'go-version-file: go.mod' "$REL_YAML"; then
      ok "$REL_YAML setup-go 已使用 go-version-file: go.mod"
    elif grep -qE 'go-version: "[0-9.]+"' "$REL_YAML"; then
      sed -i -E 's|go-version: "[0-9.]+"|go-version-file: go.mod|' "$REL_YAML"
      grep -qF 'go-version-file: go.mod' "$REL_YAML" \
        && ok "$REL_YAML setup-go: 固定 go-version 改为 go-version-file: go.mod" \
        || fail "$REL_YAML go-version 替换未生效"
    else
      fail "$REL_YAML 未找到 setup-go 的 go-version 配置（期望改为 go-version-file: go.mod）"
    fi

    # ---------- alauda/release.sh 的 tools 依赖分支 ----------
    if grep -qE 'branch: release-1\.[0-9]+' alauda/release.sh; then
      sed -i "\|github.com/istio/tools|{n;s|branch: release-1\.[0-9]\+|branch: release-$MAJOR|;}" alauda/release.sh
      grep -A1 'github.com/istio/tools' alauda/release.sh | grep -qF "release-$MAJOR" \
        && ok "alauda/release.sh tools 分支 -> release-$MAJOR" \
        || fail "alauda/release.sh tools 分支替换未生效（请人工检查 tools 依赖块）"
    else
      fail "alauda/release.sh 中未找到 release-1.X 分支配置"
    fi
    # ---------- release-builder pin 兼容性（仅提示，无法在本仓库内自动校验）----------
    # alauda/release.sh 以 BUILDER_SHA pin 死 alauda-mesh/release-builder 提交，新大版本上游
    # 常有配套适配（1.30 首战：上游把 chart 默认 hub 改为 registry.istio.io/testing，旧 pin
    # 的 helm.go hubs 替换列表没有它，release 流水线构建完成后 validation 报 hub incorrect）。
    local builder_sha
    builder_sha="$(sed -n 's/^BUILDER_SHA=\([0-9a-fA-F]*\).*/\1/p' alauda/release.sh | head -1)"
    notice "人工核查 release-builder pin（BUILDER_SHA=${builder_sha:-未找到}）是否兼容 istio $MAJOR：\
对照上游 istio/release-builder 的 release-$MAJOR 分支查 pkg/build 适配改动（尤其 helm.go 的 hubs 替换列表、charts 清单），\
需要时 cherry-pick 到 alauda-mesh/release-builder 并更新 BUILDER_SHA。"
    notice "BASE_VERSION 保持从上一版继承的值即可：istio-base-images 构建出新版基础镜像后由 bot 自动更新。"
  else
    # 小版本：GOTOOLCHAIN pin 是否继续保留由用户判断（新 build-tools 的 Go 可能已追上）
    for f in "$PR_YAML" "$REL_YAML"; do
      if grep -qE '^[[:space:]]*GOTOOLCHAIN:' "$f"; then
        notice "$f 存在 GOTOOLCHAIN pin: $(grep -E '^[[:space:]]*GOTOOLCHAIN:' "$f" | head -1 | sed 's/^[[:space:]]*//')。\
IMAGE_VERSION 更新后请在汇报中提示用户评估该 pin 是否仍需保留。"
      fi
    done
  fi

  echo
  if [[ $FAILS -gt 0 ]]; then
    echo "PATTERN_MISMATCH"
    echo "共 $FAILS 项未能自动完成（见上方 FAIL），请用 Edit 按期望值手动修改；其余已完成项不要重复改。"
    exit 2
  fi
  echo "WORKFLOWS_UPDATED"
  echo "当前未提交修改概览:"
  git diff --stat | tail -10
  echo
  if [[ "$MODE" == "major" ]]; then
    echo "下一步: 核对 $STATE_DIR_REL/prev-custom.stat 遗漏项 -> 提交 -> cherry-pick samples -> create-pr.sh"
  else
    echo "下一步: review 修改并提交（如 chore: update IMAGE_VERSION），然后执行 create-pr.sh"
  fi
}

main "$@"
