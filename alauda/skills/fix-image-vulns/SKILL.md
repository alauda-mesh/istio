---
name: fix-image-vulns
description: 修复 alauda-mesh/istio 流水线（Release Alauda Istio / Pull Request Builder）构建的 istio 镜像安全漏洞。输入一个或多个流水线 run（ID/URL，可混多个 istio 小版本），完成：推断各 run 的目标分支（istio-X.Y[.Z]）、调内网扫描服务扫描 install-cni/pilot/proxyv2/ztunnel 的 -distroless 镜像并按修复责任分类、逐分支修复（go stdlib → 升级两条 workflow 的 GOTOOLCHAIN；go.mod 依赖 → 升级库版本，多小版本间复用修复记录）、创建 PR 并监控流水线、回归扫描（最多 3 轮修复）；os 级与 ztunnel 镜像的漏洞只扫描报告不修复。仅限用户显式通过 /fix-image-vulns 调用。
argument-hint: "[RUN_ID | run URL ...]，例如: /fix-image-vulns 30178633704 30063689478"
disable-model-invocation: true
---

# 修复 istio 镜像漏洞

对指定流水线 run 构建的 istio 镜像做漏洞扫描，按修复责任分类处理，直到镜像干净或达到轮次上限。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。

## 参数

- `$ARGUMENTS`：一个或多个流水线 run（纯数字 ID 或 run URL，空格分隔），只接受 **Release Alauda Istio** 与 **Pull Request Builder** 两条流水线的成功 run，可混多个 istio 小版本（如 1.28.1、1.28.3、1.28.6 各一个 run）。
- 参数里可能混有给助手的备注文字，只把 run 部分传给脚本，备注按用户附加要求执行。
- 参数为空时用 AskUserQuestion 向用户询问，不要自行猜测。

## 背景知识

**镜像与修复责任**（扫描范围 = 四个镜像的 `-distroless` 变体；istioctl、debug 变体等其余产物不在范围）：

| 镜像 | 内容 | 漏洞处理 |
| --- | --- | --- |
| asm/pilot、asm/install-cni | go 二进制（共用仓库根 `go.mod`） | stdlib → 升 GOTOOLCHAIN；依赖库 → 升 go.mod |
| asm/proxyv2 | go 二进制（pilot-agent，同一 go.mod）+ envoy（C++） | go 部分同上；envoy/基础层按 os 报告 |
| asm/ztunnel | rust 二进制 | **只扫不修**，如实报告 |
| （所有镜像的基础层） | distroless/ubuntu os 包 | **不修复**，如实报告 |

- 三个 go 镜像共用同一 `go.mod`，同一分支的 go.mod 漏洞**统一分析、一次修复**即可覆盖三个镜像（scan 脚本已按分支聚合去重）。
- **GOTOOLCHAIN 机制**：两条 workflow 的 Build env 中 `GOTOOLCHAIN: go1.X.Y` pin 决定编译用的 go 版本（覆盖 build-tools 内置版本与 runner 的 `GOTOOLCHAIN=local`）。修 stdlib 漏洞就是升这个 pin，**两个文件必须同改且值一致**（仓库惯例）。升级策略：优先当前 minor 内的 patch（如 go1.25.12 → go1.25.13）；patch 版满足不了修复版本要求时才跨 minor/大版本，此时**必须在最终报告中着重强调说明**。pin 附近的注释记录着上次 pin 的缘由（CVE 编号等），升级后要一并改写。
- workflow env 里的 `GOBUILDFLAGS: "-buildvcs=false"` 用于消除 istio.io/istio 主模块伪版本导致的 Trivy 误报——若扫描结果出现 `istio.io/istio` 自身的老 CVE，先检查该 flag 是否还在，而不是去改依赖。
- **多分支/多小版本**：每个目标分支独立 worktree + 修复分支 + PR（互不阻塞，也不打扰主工作区当前检出）。不同小版本的漏洞高度重复，**不要机械地逐版本从头修**：把每个分支验证过的落位版本记入 `out/fix-image-vulns/fix-records.md`，修下一个分支时先读它，同名漏洞直接用已验证版本，省掉 go get 试错。
- PR 流水线只做镜像构建（无 lint/gen 校验），go.mod + go.sum 变更即可通过。
- gh 命令必须显式 `--repo alauda-mesh/istio`（脚本已内置）；全程禁止 `git commit --amend`，一律新建 commit。
- 修复轮次上限 **3 轮**（首轮 + 回归后最多再修 2 次），修不完就如实汇报。
- 状态目录 `out/fix-image-vulns/`（gitignore 内），各脚本经 `state.env` 与若干 tsv 串联。

## 步骤 1：漏洞检测

```bash
bash "$SKILL_DIR/scripts/resolve-runs.sh" <run ...>     # Bash timeout 设 300000（要下载 run 日志）
bash "$SKILL_DIR/scripts/scan-images.sh"                # Bash timeout 设 600000（服务端拉镜像+扫描）
```

- resolve 退出码 2（`UNKNOWN_BRANCH`）：某 run 推断不出目标分支，用 AskUserQuestion 和用户确认，然后带 `--branch RUN_ID=istio-X.Y[.Z]` 把**所有 run** 重新传入重跑。
- **无论有无漏洞，都先向用户输出扫描摘要**（每镜像漏洞数、SUMMARY 分类计数、各分支修复目标表）。然后按 `RESULT:` 分支：
  - **CLEAN**：无漏洞，汇报后直接结束；
  - **REPORT_ONLY**：剩余均为不修复项（os 级 / ztunnel / 无修复版本），列出明细并说明不修复的原因，结束；
  - **FIX_NEEDED**：对 `FIX_BRANCHES` 中的每个分支执行步骤 2～3。

## 步骤 2：修复（逐分支）

```bash
bash "$SKILL_DIR/scripts/create-fix-branch.sh" <目标分支>    # 输出 WORKTREE= / BRANCH=
```

修复前先看 `out/fix-image-vulns/fix-records.md`（如存在）：已在其他分支验证过的同名包，直接用记录中的落位版本。连带钉子（非 CVE 目标但编译/tidy 需要的包）也是配方的一部分，复用时把整套 spec 原样带上——同系列小版本分支通常能一次通过。

**go.mod 依赖**（升级目标以 scan 输出的"修复目标"表为准；候选没有 v 前缀，`go get` 时要加上）：

```bash
bash "$SKILL_DIR/scripts/gomod-bump.sh" <目标分支> <module@vX.Y.Z> [...]   # timeout 600000
```

首个分支冷缓存时（go get 全量下载 + 首次编译新依赖图）常超过 Bash 600000 上限，直接 `run_in_background: true` 跑；后续分支缓存已热，几分钟内能完成。

- 库之间有依赖约束，实际落位版本可能高于扫描给的修复候选，属正常，脚本会打印实际版本；
- `go get` 报 `A@vX requires B@vY, not B@vZ`：把 B 的目标提到 vY 重跑（vY 更高，CVE 覆盖不受影响），`golang.org/x/*` 系列互相牵制时常见；
- 同一发布系列的包（如 `go.opentelemetry.io/otel` 与 `otel/sdk`）版本要对齐，统一取其中最高者；
- 升 otel 主系列时**必须连带升** `go.opentelemetry.io/otel/exporters/prometheus` 到配套 0.x 版（版本规律 = otel minor+22，如 otel 1.43 ↔ exporters/prometheus 0.65.0）。扫描不会报它（无 CVE），但不升会因连带升上来的 `prometheus/otlptranslator` v1.0.0 API 变更编译失败（症状：`labelNamer.Build ... in single-value context`）；
- `go mod tidy` 报 `github.com/go-openapi/testify/v2/assert/yaml ... does not contain package`：swag 被 MVS 拖到 ≥0.25 后其测试依赖解析坑，钉 `github.com/go-openapi/testify/v2@v2.5.1` 与 `github.com/go-openapi/testify/enable/yaml/v2@v2.4.2` 即可（与上游 istio-1.30 钉法一致）。同类间接依赖崩时，优先参考更高版本上游分支（如 istio-1.30）go.mod 里的钉法，而不是自己试版本；
- 构建失败时分析原因（版本冲突、新版本要求更高 go、API 变更），能明确解决就解决，拿不准就带着报错向用户提问，不要凭猜测大版本连锁升级；
- 无修复版本的 CVE 升级修不了，记入最终汇报的"未修复项"；
- **tidy 后必须审查连带升级面**：`git diff go.mod` 检查 k8s.io/api、apimachinery、client-go 等基础库是否被连带拉升 minor 版本；k8s.io 系列一旦超过同分支上游 istio（`istio/istio@release-1.XX` 的 go.mod）的钉定版本必须回钉。教训（2026-07，1.28 系）：prometheus/prometheus v0.311.3 强拉 k8s.io v0.35.3，而 k8s 1.35 把生成类型的 `ProtoMessage()` 移入 opt-in 构建标签（gogo 移除过渡），istio 1.28 的 operator values proto 仍引用 k8s proto 类型，istiod 启动即 panic（`message *v1.Affinity is neither a v1 or v2 Message`），带毒版本 1.28.6-asm-r4 随流水线发布，线上升级事故；修复见 #40/#41/#42。istio 1.30+ 已解耦（upstream istio#58632），无此约束；
- prometheus/prometheus 在 1.28 系分支必须用 **v0.311.3 + replace 钉 k8s.io 三件套 v0.34.1**（`replace k8s.io/{api,apimachinery,client-go} => v0.34.1`，replace 不参与 MVS 传递，可压住 prometheus 对 k8s v0.35 的强拉，钉定值与上游 release-1.28 一致）。不要试图用 v0.305.3（3.5 LTS）绕开：语义上它同样修复那批 CVE，但 trivy DB 对 Go module 只收录 0.311.3 一条修复线，线性版本比较下 LTS 仍被判 vulnerable，镜像扫描无法清零（2026-07-29 实测否决）；
- 落位版本以扫描器给的修复候选为准，**勿基于 advisory 原文自行换用其他修复分支**（LTS/多分支修复线 Go 漏洞库常只收录主线）；确需偏离候选钉法时，推流水线前先本地 trivy 预扫（`trivy rootfs` 扫本地构建的二进制；本地构建时主模块 istio.io/istio 是伪版本，其自身的老 CVE 属误报可忽略，CI 镜像无此问题），别把试错留给回归轮——那要多烧一次 30～60 分钟流水线，还占 3 轮修复上限。

**go stdlib**（对照 scan 输出的当前 GOTOOLCHAIN 与修复候选选定版本）：

```bash
bash "$SKILL_DIR/scripts/update-gotoolchain.sh" <目标分支> <go1.X.Y>
```

按脚本 NOTICE 用 Edit 改写 GOTOOLCHAIN 附近的过时注释（写明本次升级对应的 CVE）。退出码 2 表示某文件没有 GOTOOLCHAIN 行，按脚本提示用 Edit 在 Build env 块补上。

**运行时最小验证**（go.mod 有变更时，提交前在 worktree 内跑）：

```bash
go test ./operator/pkg/apis/ ./pkg/kube/inject/ -count=1   # 热缓存约几十秒
```

gomod-bump 编译通过只证明能编译，抓不住依赖引入的运行时崩溃；values proto 解析路径覆盖 istiod 启动初始化，1.28.6-asm-r4 的启动 panic 本可被它拦住。

**提交**（在 worktree 内，两类修复各自独立 commit，禁止 amend）：

- go.mod：`fix: bump vulnerable go modules`
- GOTOOLCHAIN：`fix: bump GOTOOLCHAIN to go1.X.Y for <CVE编号>`

提交后把本分支的修复结果（包 → 实际落位版本、GOTOOLCHAIN 变化、连带调整与坑）追加到 `out/fix-image-vulns/fix-records.md`，供后续分支复用。

## 步骤 3：创建 PR（逐分支）

PR 正文写进 scratchpad 临时文件：扫描摘要（镜像、分类计数）+ 修复清单（每项：包/模块、版本变化、覆盖的 CVE）+ 本地构建验证说明 + 不修复项说明（os / ztunnel）+ 结尾一行 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <目标分支> <正文文件>    # 输出 PR_NUMBER= / PR_URL=
```

幂等：修复分支已有 open PR 时复用，回归轮 push 新 commit 后重跑即可。

## 步骤 4：监控 PR 流水线

全部分支的 PR 建完后统一监控（多平台镜像构建 30～60 分钟，**必须后台运行**，Bash 的 `run_in_background: true`）：

```bash
bash "$SKILL_DIR/scripts/watch-prs.sh"
```

脚本按各 PR 当前 head sha 精确匹配 run，全部成功时自动收集 PR 构建出的新镜像并把轮次 +1。按退出结果处理：

- **ALL_SUCCESS（0）**：进入步骤 5；
- **PIPELINE_FAILED（2）**：脚本已附失败 step 与日志摘要。**分析失败原因**：是本次修复引入（依赖升级编译错、GOTOOLCHAIN 版本 runner 下载不到）还是环境问题（self-hosted runner、registry、代理）。修复方向拿不准时向用户提问，不要盲目改了就重推；修好后在原 worktree 追加 commit → 重跑 create-pr.sh → 重跑本脚本；
- **PIPELINE_TIMEOUT（3）**：告知用户流水线仍在运行，附 run 链接，稍后可重跑本脚本继续等；
- **RUN_NOT_FOUND（4）**：按脚本提示排查，如实告知用户。

## 步骤 5：回归扫描与迭代

```bash
bash "$SKILL_DIR/scripts/scan-images.sh"    # ROUND 已 +1，自动扫 PR 构建的新镜像
```

- **CLEAN / REPORT_ONLY**：修复完成，进入最终汇报；
- **FIX_NEEDED**：先分析为什么还有漏洞（上轮目标版本仍带 CVE？升级未生效？新版本引入新漏洞？），再回到步骤 2 继续修——不新建分支，在原 worktree 追加 commit → create-pr.sh push → 后台 watch-prs.sh → 再扫描。

**最多 3 轮修复**。到限仍未清零时停止，如实汇报剩余漏洞、已尝试的措施和失败原因，让用户决策。

## 最终汇报

用清晰列表汇报：

1. 输入 run 与目标分支对应表；
2. 每个分支：首轮扫描摘要（总数、分类计数）→ 修复清单（包/模块、版本变化、覆盖的 CVE、commit）→ PR 链接与流水线结果 → 回归扫描结论；
3. ztunnel 镜像扫描结果（如实列出，注明只扫不修）；
4. 剩余不修复项：os 级漏洞明细、无修复版本或修不掉的项及原因（如实报告，注明不在修复范围）；
5. 若 GOTOOLCHAIN 跨了 go 大版本，**着重强调**该变化及原因。

不要自行 merge PR，等用户 review。
