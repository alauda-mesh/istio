#!/usr/bin/env bash
# 步骤：更新 istio-base-images 仓库 cve-check.yaml 的 DEFAULT_ISTIO_BRANCHES 并创建 PR。
#   minor 模式: 把新建的历史 release 分支（如 istio-1.28.6）加入列表
#   major 模式: 加入新大版本分支（如 istio-1.30），并裁剪掉不属于最新两个大版本的条目
# 幂等：列表无变化时 NO_CHANGE；已有对应 open PR 时复用。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# 计算新的分支列表: compute_branch_list <当前逗号列表> <新增分支> <保留的大版本列表(空格分隔，空=不裁剪)>
compute_branch_list() {
  local cur="$1" add="$2" keep_majors="${3:-}" b m k keep
  {
    tr ',' '\n' <<<"$cur"
    echo "$add"
  } | tr -d ' ' | grep -v '^$' | sort -Vu | {
    while read -r b; do
      if [[ -n "$keep_majors" ]]; then
        m="${b#istio-}"
        m="$(cut -d. -f1-2 <<<"$m")"
        keep=false
        for k in $keep_majors; do [[ "$m" == "$k" ]] && keep=true; done
        [[ "$keep" == true ]] || continue
      fi
      echo "$b"
    done
  } | paste -sd, -
}

main() {
  repo_root
  load_state
  command -v gh >/dev/null || die "未安装 gh"
  gh auth status >/dev/null 2>&1 || die "gh 未认证，请提示用户执行: ! gh auth login"

  local ADD KEEP=""
  if [[ "$MODE" == "minor" ]]; then
    ADD="$HISTORY_BRANCH"
  else
    ADD="$TARGET_BRANCH"
    KEEP="$PREV_MAJOR $MAJOR" # 只维护最新两个大版本
  fi

  local BR="chore/istio-branches-$ADD"
  local EXISTING
  EXISTING="$(gh pr list --repo "$BASE_IMAGES_REPO" --head "$BR" --state open --json url -q '.[0].url' 2>/dev/null || true)"
  if [[ -n "$EXISTING" ]]; then
    echo "PR_EXISTS"
    echo "istio-base-images 已有对应 open PR，复用: $EXISTING"
    exit 0
  fi

  local WORKDIR="$ROOT/$STATE_DIR_REL/istio-base-images"
  rm -rf "$WORKDIR"
  info "clone $BASE_IMAGES_REPO ..."
  gh repo clone "$BASE_IMAGES_REPO" "$WORKDIR" -- --depth 1 >/dev/null 2>&1 || die "clone $BASE_IMAGES_REPO 失败"
  cd "$WORKDIR"
  local BASE_BRANCH
  BASE_BRANCH="$(gh repo view "$BASE_IMAGES_REPO" --json defaultBranchRef -q .defaultBranchRef.name)"

  local F=".github/workflows/cve-check.yaml"
  [[ -f "$F" ]] || die "istio-base-images 中缺少 $F（仓库结构可能变化）"
  local cur new
  cur="$(sed -n 's/^[[:space:]]*DEFAULT_ISTIO_BRANCHES:[[:space:]]*//p' "$F" | head -1)"
  [[ -n "$cur" ]] || die "未在 $F 中找到 DEFAULT_ISTIO_BRANCHES"

  new="$(compute_branch_list "$cur" "$ADD" "$KEEP")"
  if [[ "$new" == "$cur" ]]; then
    echo "NO_CHANGE"
    echo "DEFAULT_ISTIO_BRANCHES 已是: $cur"
    exit 0
  fi

  local added removed
  added="$(comm -13 <(tr ',' '\n' <<<"$cur" | sort) <(tr ',' '\n' <<<"$new" | sort) | paste -sd' ' - || true)"
  removed="$(comm -23 <(tr ',' '\n' <<<"$cur" | sort) <(tr ',' '\n' <<<"$new" | sort) | paste -sd' ' - || true)"

  sed -i "s|^\([[:space:]]*\)DEFAULT_ISTIO_BRANCHES:.*|\1DEFAULT_ISTIO_BRANCHES: $new|" "$F"
  grep -qF "DEFAULT_ISTIO_BRANCHES: $new" "$F" || die "DEFAULT_ISTIO_BRANCHES 替换未生效"

  git checkout -q -b "$BR"
  git add "$F"
  git commit -q -m "chore: update DEFAULT_ISTIO_BRANCHES (+$ADD)"
  git push -u origin "$BR" || die "push $BR 到 $BASE_IMAGES_REPO 失败"

  local BODY_FILE="$ROOT/$STATE_DIR_REL/base-images-pr-body.md"
  {
    echo "同步 istio $NEW_TAG 后维护 CVE 巡检分支列表："
    echo
    echo "- 新增: ${added:-无}"
    echo "- 移除: ${removed:-无}$([[ "$MODE" == "major" ]] && echo "（只维护最新两个大版本: $KEEP）")"
    echo "- DEFAULT_ISTIO_BRANCHES: \`$cur\` → \`$new\`"
    echo
    echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
  } >"$BODY_FILE"
  gh pr create --repo "$BASE_IMAGES_REPO" --base "$BASE_BRANCH" --head "$BR" \
    --title "chore: update DEFAULT_ISTIO_BRANCHES (+$ADD)" --body-file "$BODY_FILE" >/dev/null

  echo "BASE_IMAGES_PR_URL=$(gh pr list --repo "$BASE_IMAGES_REPO" --head "$BR" --state open --json url -q '.[0].url')"
  echo "DEFAULT_ISTIO_BRANCHES: $cur -> $new"
}

# 允许被 source 做函数级测试
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
