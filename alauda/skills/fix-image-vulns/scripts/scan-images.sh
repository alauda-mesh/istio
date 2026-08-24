#!/usr/bin/env bash
# 步骤 1b / 步骤 5：调内网扫描服务扫当前轮镜像，并按修复责任分类。
# 用法: scan-images.sh [轮次]   缺省用状态里的 ROUND
# 分类:
#   OS_REPORT_ONLY  os 包（基础镜像层 / envoy 系统依赖）    → 不修复，如实报告
#   ZTUNNEL_REPORT  ztunnel 镜像的全部漏洞（rust 二进制）   → 只扫不修，如实报告
#   GO_STDLIB       go 二进制的 stdlib                     → 升级两条 workflow 的 GOTOOLCHAIN
#   GO_MODULE       go 二进制的依赖库                       → 升级 go.mod（三个 go 镜像共用
#                     同一 go.mod，已按分支聚合去重，一次修复覆盖三个镜像）
#   UNKNOWN         其他                                   → 人工判断
# 输出: 每镜像明细 + 每分支修复目标聚合（go.mod 目标 / stdlib 目标 + 该分支当前 GOTOOLCHAIN）
#       + SUMMARY + RESULT: CLEAN|REPORT_ONLY|FIX_NEEDED（附 FIX_BRANCHES=）
# 退出码: 0=扫描完成（无论结论） 1=失败
# 注意: 服务端要拉镜像再扫，首扫可能几分钟，调用方把 Bash timeout 设为 600000。
# 扫描服务: 主备两地址自动切换——先探测主服务（SCAN_API_PRIMARY，默认 http://192.168.141.42:8888），
#           可达则主为首选、备（SCAN_API_BACKUP，默认 http://192.168.25.100:8888）作后援；
#           主不可达则降级用备；均不可达直接失败。扫描阶段当前服务连续 MAX_ATTEMPTS 次失败即切换，
#           切换后持久生效（后续镜像直接用新服务）。
# 环境变量: SCAN_API_PRIMARY / SCAN_API_BACKUP、SCAN_API（显式指定单一服务，跳过主备探测与切换）、
#           MAX_ATTEMPTS=3、RETRY_DELAY=15、SCAN_TIMEOUT=240

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-15}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-240}"

# 服务是否可达：能返回任意 HTTP 状态码即算在线（连接被拒/超时时 curl 输出 000）
probe_api() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -m 10 "$1/" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "000" ]]
}

main() {
  repo_root
  load_state
  command -v jq >/dev/null 2>&1 || die "找不到 jq"

  local N="${1:-$ROUND}"
  local IMG_TSV="$STATE_DIR/images-round${N}.tsv"
  [[ -s "$IMG_TSV" ]] || die "没有第 ${N} 轮镜像清单: $IMG_TSV（第 1 轮先执行 resolve-runs.sh；回归轮先执行 watch-prs.sh）"

  # ---------- 选定扫描服务：优先主地址，不可达时切备用 ----------
  local APIS=() API_IDX=0
  if [[ -n "${SCAN_API:-}" ]]; then
    APIS=("$SCAN_API")
    info "使用显式指定的扫描服务: $SCAN_API"
  elif probe_api "$SCAN_API_PRIMARY"; then
    APIS=("$SCAN_API_PRIMARY" "$SCAN_API_BACKUP")
    info "使用主扫描服务: $SCAN_API_PRIMARY（备用: $SCAN_API_BACKUP）"
  elif probe_api "$SCAN_API_BACKUP"; then
    APIS=("$SCAN_API_BACKUP")
    warn "主扫描服务不可达（$SCAN_API_PRIMARY），切换到备用: $SCAN_API_BACKUP"
  else
    die "主备扫描服务均不可达: $SCAN_API_PRIMARY / $SCAN_API_BACKUP"
  fi

  local SCAN_DIR="$STATE_DIR/scans/round${N}"
  mkdir -p "$SCAN_DIR"
  local TSV="$SCAN_DIR/vulns.tsv"
  : >"$TSV"

  # 同一（分支,镜像）可能来自多个 run，去重后扫描
  local branch img short out resp encoded api url i n rows
  while IFS=$'\t' read -r branch img; do
    short="$(img_repo "$img")"
    out="$SCAN_DIR/$(img_slug "$img").json"

    info "扫描 ${img} ..."
    encoded="$(jq -rn --arg v "$img" '$v|@uri')"
    # 当前服务连续 MAX_ATTEMPTS 次失败后换下一个服务；全部服务用尽才算失败
    resp=""
    while [[ -z "$resp" && "$API_IDX" -lt "${#APIS[@]}" ]]; do
      api="${APIS[$API_IDX]}"
      url="${api}/image/vulnerability/custom?image_full_address=${encoded}&trivy_db_date=latest&severity=low&vulnerability_type=os%2Clibrary&version=v4.4.0"
      for i in $(seq 1 "$MAX_ATTEMPTS"); do
        if resp="$(curl -sS --fail --max-time "$SCAN_TIMEOUT" -H 'accept: application/json' "$url")" \
           && jq -e 'has("os") and has("lang")' <<<"$resp" >/dev/null 2>&1; then
          break
        fi
        resp=""
        [[ "$i" -lt "$MAX_ATTEMPTS" ]] && { warn "本次扫描失败，${RETRY_DELAY}s 后重试（$i/$MAX_ATTEMPTS，服务 $api）"; sleep "$RETRY_DELAY"; }
      done
      if [[ -z "$resp" ]]; then
        API_IDX=$((API_IDX + 1))   # 切换后持久生效，后续镜像直接用新服务
        [[ "$API_IDX" -lt "${#APIS[@]}" ]] && warn "服务 $api 连续 $MAX_ATTEMPTS 次失败，切换到 ${APIS[$API_IDX]}"
      fi
    done
    [[ -n "$resp" ]] || die "所有扫描服务均连续 $MAX_ATTEMPTS 次失败: $img（已尝试: ${APIS[*]}）"
    printf '%s\n' "$resp" >"$out"

    # 提取为 TSV: 分支/镜像短名/分类/包/装机版本/修复候选(逗号分隔,去v前缀)/CVE/严重度
    # 注: 服务对无修复版本返回字符串 "null"，要当空处理，否则会算出 @vnull 的假目标
    rows="$(jq -r --arg b "$branch" --arg repo "$short" '
      def fixes: [(.FixedVersion // "") | split(",")[] | gsub("^\\s+|\\s+$";"") | sub("^v";"") | select(.!="" and .!="null")] | unique | join(",");
      def cat: if $repo == "ztunnel" then "ZTUNNEL_REPORT"
               elif .__src == "os" then "OS_REPORT_ONLY"
               elif .PkgName == "stdlib" then "GO_STDLIB"
               elif ((.Target // "") | contains("/")) then "GO_MODULE"
               else "UNKNOWN" end;
      ( [(.os // [])[] | . + {__src:"os"}] + [(.lang // [])[] | . + {__src:"lang"}] )
      | .[] | [$b, $repo, cat, .PkgName, (.InstalledVersion // "?"), fixes, .VulnerabilityID, (.Severity // "?")] | @tsv' "$out")"

    # 同一镜像可能含多个 go 二进制（如 install-cni 镜像里的 install-cni + istio-cni），
    # 同一漏洞按 Target 重复出现，这里按行去重
    n=0
    if [[ -n "$rows" ]]; then
      rows="$(sort -u <<<"$rows")"
      printf '%s\n' "$rows" >>"$TSV"
      n="$(grep -c . <<<"$rows")"
    fi
    echo
    echo "--- ${img}（漏洞 ${n} 条）---"
    [[ -n "$rows" ]] && sort <<<"$rows" | awk -F'\t' \
      '{printf "  [%s] %s %s %s %s → %s\n", $3, $4, $7, $8, $5, ($6 == "" ? "（无修复版本）" : $6)}'
  done < <(cut -f3,4 "$IMG_TSV" | sort -u)

  sort -u "$TSV" -o "$TSV"
  count_cat() { awk -F'\t' -v c="$1" '$3 == c' "$TSV" | grep -c . || true; }
  local TOTAL GOMOD STDLIB OS ZT UNK
  TOTAL="$(grep -c . "$TSV" || true)"
  GOMOD="$(count_cat GO_MODULE)"; STDLIB="$(count_cat GO_STDLIB)"
  OS="$(count_cat OS_REPORT_ONLY)"; ZT="$(count_cat ZTUNNEL_REPORT)"; UNK="$(count_cat UNKNOWN)"

  # ---------- 按分支聚合修复目标（GO_MODULE 三镜像共用 go.mod，按 分支/包 去重）----------
  local b pkg inst cves_fix cves_nofix cands target cur_toolchain stdlib_rows
  for b in $BRANCHES; do
    awk -F'\t' -v b="$b" '$1==b && ($3=="GO_MODULE" || $3=="GO_STDLIB")' "$TSV" | grep -q . || continue
    echo
    echo "--- 分支 $b 修复目标 ---"
    git fetch -q origin "refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null || true
    cur_toolchain="$(git show "origin/$b:.github/workflows/release.yaml" 2>/dev/null \
      | sed -n 's/^[[:space:]]*GOTOOLCHAIN:[[:space:]]*//p' | head -1)"
    echo "  当前 GOTOOLCHAIN: ${cur_toolchain:-（未设置，release.yaml 中无此环境变量）}"

    stdlib_rows="$(awk -F'\t' -v b="$b" '$1==b && $3=="GO_STDLIB"' "$TSV" | cut -f4- | sort -u)"
    if [[ -n "$stdlib_rows" ]]; then
      inst="$(head -1 <<<"$stdlib_rows" | cut -f2)"
      cands="$(cut -f3 <<<"$stdlib_rows" | tr ',' '\n' | grep -v '^$' | sort -uV | paste -sd'/' -)"
      echo "  [stdlib] 构建 go ${inst}  CVE×$(grep -c . <<<"$stdlib_rows")  修复候选: ${cands:-（无）} → update-gotoolchain.sh（优先同小版本线的 patch；需跨大版本时在最终报告中着重说明）"
    fi

    while IFS=$'\t' read -r pkg; do
      inst="$(awk -F'\t' -v b="$b" -v p="$pkg" '$1==b && $3=="GO_MODULE" && $4==p {print $5; exit}' "$TSV")"
      cves_fix="$(awk -F'\t' -v b="$b" -v p="$pkg" '$1==b && $3=="GO_MODULE" && $4==p && $6!="" {print $7}' "$TSV" | sort -u | grep -c . || true)"
      cves_nofix="$(awk -F'\t' -v b="$b" -v p="$pkg" '$1==b && $3=="GO_MODULE" && $4==p && $6=="" {print $7}' "$TSV" | sort -u | grep -c . || true)"
      cands="$(awk -F'\t' -v b="$b" -v p="$pkg" '$1==b && $3=="GO_MODULE" && $4==p {print $6}' "$TSV" \
        | tr ',' '\n' | grep -v '^$' | sort -uV || true)"
      if [[ -n "$cands" ]]; then
        target="$(tail -1 <<<"$cands")"
        echo "  [go.mod] $pkg $inst  CVE×${cves_fix}$([[ "$cves_nofix" -gt 0 ]] && echo "（另 ${cves_nofix} 个无修复版本）")  候选: $(paste -sd'/' - <<<"$cands")  → go get ${pkg}@v${target}"
      else
        echo "  [go.mod] $pkg $inst  CVE×${cves_nofix}  （无修复版本，升级修不了，最终汇报中如实说明）"
      fi
    done < <(awk -F'\t' -v b="$b" '$1==b && $3=="GO_MODULE" {print $4}' "$TSV" | sort -u)
  done

  echo
  echo "SUMMARY: ROUND=${N} TOTAL=${TOTAL} GO_MODULE=${GOMOD} GO_STDLIB=${STDLIB} ZTUNNEL_REPORT=${ZT} OS_REPORT_ONLY=${OS} UNKNOWN=${UNK}"
  # 可执行修复 = 有修复候选的 GO_MODULE / GO_STDLIB，或需人工判断的 UNKNOWN
  local FIX_BRANCHES
  FIX_BRANCHES="$(awk -F'\t' '(($3=="GO_MODULE" || $3=="GO_STDLIB") && $6!="") || $3=="UNKNOWN" {print $1}' "$TSV" \
    | grep -v '^UNKNOWN$' | sort -uV | paste -sd' ' - || true)"
  if [[ "$TOTAL" -eq 0 ]]; then
    echo "RESULT: CLEAN"
  elif [[ -n "$FIX_BRANCHES" ]]; then
    echo "RESULT: FIX_NEEDED"
    echo "FIX_BRANCHES=${FIX_BRANCHES}"
  else
    echo "RESULT: REPORT_ONLY（剩余均为不修复项：os 级 / ztunnel / 无修复版本的条目）"
  fi
  echo "明细 TSV: $TSV"
}

main "$@"
