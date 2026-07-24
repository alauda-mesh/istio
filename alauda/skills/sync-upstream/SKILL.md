---
name: sync-upstream
description: 同步上游 istio/istio 指定 tag 到本仓库（alauda-mesh/istio）。小版本同步：merge 上游 tag 到现有 istio-1.XX 分支、更新流水线 IMAGE_VERSION、创建升级 PR、把旧小版本留档为 istio-1.XX.Y 分支；大版本同步：基于上游 tag 新建 istio-1.XX 分支并设为默认分支、迁移 Alauda 构建定制（workflows/alauda/构建配置）、cherry-pick samples 改动、创建构建 PR。两种场景最后都更新 istio-base-images 的 DEFAULT_ISTIO_BRANCHES 并创建 PR。仅限用户显式通过 /sync-upstream 调用。
argument-hint: "[上游 tag] [目标分支]，例如: 1.28.7 istio-1.28（小版本）或 1.30.0 istio-1.30（大版本）"
disable-model-invocation: true
---

# 同步上游代码（istio/istio → alauda-mesh/istio）

把 https://github.com/istio/istio 的指定 tag 同步到本仓库的目标分支。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。本仓库内真身为 `alauda/skills/sync-upstream`，`.claude/skills/sync-upstream` 是指向它的 symlink（Claude Code 接入点），调用时提示的路径可能是后者，两者等价。

## 参数与模式判定

- 上游 tag：`$0`（形如 `1.28.7`，istio tag 无 v 前缀）
- 目标分支：`$1`（形如 `istio-1.28`）

两个参数都必须明确。若任一为空，用 AskUserQuestion 向用户询问（可先用 `git ls-remote --tags https://github.com/istio/istio.git` 查出最新 tag 作为推荐项），不要自行猜测。

模式由目标分支是否已存在决定，脚本会强校验，你只需选对入口并在开跑前向用户播报判定结果：

- `git ls-remote --exit-code --heads origin <目标分支>` 退出码 0（**存在**）→ **小版本同步**（tag 的大版本必须与分支一致，如 `1.28.7` → `istio-1.28`）
- 退出码非 0（**不存在**）→ **大版本同步**（分支名必须是 `istio-<tag 大版本>`，如 `1.30.0` → `istio-1.30`）

注意必须带 `--exit-code` 或检查输出是否为空：`git ls-remote --heads` 对不存在的分支同样退出 0。

## 背景知识

- 本仓库是 istio/istio 的 fork（remote `upstream`）。Alauda 定制集中在：
  1. `.github/workflows/` 两条流水线（pr-builder.yaml、release.yaml；上游 tag 中无此目录）；
  2. `alauda/` 目录（release.sh 发布脚本、README.md、本 skill）；
  3. 6 个构建文件的小改动（迁移意图见下，脚本会自动套用 diff）：
     - `Makefile.core.mk`：RELEASE_LDFLAGS 支持注入 `EXTRA_RELEASE_LDFLAGS`
     - `common/scripts/report_build_info.sh`：`GIT_DESCRIBE_TAG` 允许环境变量覆盖
     - `istioctl/docker/Dockerfile.istioctl`：支持 `BASE_DISTRIBUTION=debug/distroless` 两种基础镜像
     - `tools/docker-builder/docker.go`、`types.go`：default variant 改为 distroless 的别名（PrimaryVariant=Distroless）
     - `tools/docker-copy.sh`：`cp` 加 `-f` 强制覆盖
  4. samples 定制（tcp-echo、bookinfo），cherry-pick 清单维护在 `alauda/README.md` 的「Alaude Istio 源码改动历史」章节。
- 分支模型：`istio-1.XX` 大版本分支始终指向该大版本的**最新**小版本，最新大版本分支同时是 GitHub 默认分支；升级小版本前的旧状态留档为 `istio-1.XX.Y` 分支；**只维护最新两个大版本**。
- 基础镜像来自 alauda-mesh/istio-base-images，其 cve-check 流水线按 `DEFAULT_ISTIO_BRANCHES` 巡检各分支并构建基础镜像；本仓库 workflows 里的 `BASE_VERSION` 由 bot 自动更新，**同步时不要手动改**。
- 脚本间通过 `out/sync-upstream/state.env` 传递状态（`out/` 已在 gitignore 中）。
- 入口脚本会在改动工作区之前探测 github.com 推送凭据（devcontainer 的 credential helper/askpass 可能随宿主 IDE 会话失效，而 gh 认证仍正常）；探测失败时按报错提示执行 `gh auth setup-git` 后重试即可。
- 全程禁止 `git commit --amend`，一律创建新 commit。升级 PR 建立之前不要 push 同步分支。两个例外（脚本内置）：大版本的 `istio-1.XX` 分支创建后立即 push（内容与上游 tag 完全一致）；小版本的历史分支 push 的是远端已有的旧提交。

## 小版本同步（如 1.28.6 → 1.28.7）

### 步骤 1：合并上游 tag

```bash
bash "$SKILL_DIR/scripts/sync-minor.sh" <上游tag> <目标分支>
```

脚本会自动：校验参数与前置条件 → fetch upstream/origin → 记录合并前 SHA（历史分支据此创建）→ 基于 `origin/<目标分支>` 创建 `feat/istio-<tag>` 分支 → merge 上游 tag。按结果处理：

- **MERGED（0）**：合并成功，继续步骤 2。
- **UP_TO_DATE（0）**：分支已包含该 tag，向用户汇报后结束。
- **CONFLICT（2）**：解决冲突。原则：
  - 先分类再动手：Alauda 定制文件（workflows、alauda/、上述 6 个构建文件、samples）以保留定制 + 合入上游新内容为主；我们 cherry-pick 过、上游新 tag 已正式包含的内容（上游修复、CVE 依赖升级）以上游为准；依赖 pin 冲突取较高版本。
  - 逐个文件看冲突上下文，不要机械选 ours/theirs；**每个文件的冲突点和解决方式记录下来，最终汇报和 PR 描述必须逐条说明**。
  - 只要有一个冲突拿不准，立即停下来向用户提问（附冲突片段和你的倾向方案）。
  - 解决完 `git add <文件>` 并 `git commit --no-edit` 完成合并（禁止 amend）。
- **其他失败（1）**：前置条件问题，把报错原样告知用户并询问如何处理，不要擅自 stash 或删分支。

### 步骤 2：更新流水线 IMAGE_VERSION

```bash
bash "$SKILL_DIR/scripts/update-workflows.sh"
```

脚本把两条流水线的 `IMAGE_VERSION` 更新为合并后 `common/scripts/setup_env.sh` 的默认值（上游 tag 会推进 build-tools 版本，流水线必须跟上，否则编译工具链与上游脱节）。保护逻辑：若现值是人为 pin（如 CVE 升级 build-tools）而本次上游默认值没有推进，脚本会保持 pin 不回退。输出语义：

- **OK**：已完成项；**NOTICE**：需要你审阅的信息——人为 pin 的保留/覆盖情况、IMAGE_VERSION 附近的过时注释（用 Edit 清理或改写）、GOTOOLCHAIN pin 是否仍需保留，这些都要写进汇报由用户定夺；
- **PATTERN_MISMATCH（2）**：列出的 FAIL 项用 Edit 按期望值手动完成，其余不要重复改。

review `git diff` 后把本步骤修改提交为一个新 commit（如 `chore: update IMAGE_VERSION to <新值>`）。

### 步骤 3：创建升级 PR

先把 PR 描述写进临时文件（scratchpad 下，如 `pr-body.md`）：版本跨度与合入提交数、冲突文件及解决方式（无冲突则写明）、IMAGE_VERSION 变化、NOTICE 事项，结尾加一行 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <PR正文文件>
```

幂等（分支已有 open PR 时复用），输出 `PR_NUMBER=`/`PR_URL=`。gh 未认证时提示用户执行 `! gh auth login` 后重试。

### 步骤 4：留档历史 release 分支

```bash
bash "$SKILL_DIR/scripts/create-history-branch.sh"
```

把合并前的 `origin/istio-1.XX` 状态 push 为 `istio-<旧版本>` 分支（如 `istio-1.28.6`），使旧小版本在大版本分支前进后仍可追溯、可继续被 CVE 巡检。**EXISTS** 时不做修改（分支头与合并前状态不同说明带 hotfix，照实汇报）。

### 步骤 5：更新 istio-base-images 分支列表

```bash
bash "$SKILL_DIR/scripts/update-base-images.sh"
```

把新的历史分支加入 cve-check.yaml 的 `DEFAULT_ISTIO_BRANCHES` 并创建 PR（幂等：NO_CHANGE / PR_EXISTS 时直接汇报）。输出 `BASE_IMAGES_PR_URL=`。

## 大版本同步（如 1.28 → 1.30）

### 步骤 1：建分支并迁移定制

```bash
bash "$SKILL_DIR/scripts/sync-major.sh" <上游tag> <目标分支>
```

脚本会自动：基于上游 tag 创建 `istio-1.XX` 分支，将分支与上游 tag 原子 push（首个构建 PR 的 `gh-describe` 需要从 fork 查询该 tag）、用 gh 设为 GitHub 默认分支 → 创建 `chore/alauda-1.XX-build` 构建分支 → 从上一个大版本分支恢复 `.github/workflows/`、`alauda/` 与 `.claude`（skill 接入 symlink）→ 生成上一版对 6 个构建文件的定制 diff（`out/sync-upstream/build-config.diff`）并 `git apply --3way` 自动套用。按结果处理：

- **PREPARED（0）**：diff 干净套用，继续步骤 2。
- **APPLY_CONFLICT（2）**：上游重构导致三方合并冲突。对照「背景知识」里每个文件的定制意图，把等价改动改写到新版本代码上（不是机械保留旧代码），解决后 `git add`，继续步骤 2。
- **其他失败（1）**：把报错原样告知用户。若脚本在 checkout 之后中断，工作区里 skill 可能暂时消失：改用快照 `out/sync-upstream/skill-snapshot/scripts/` 继续执行，或先 `git checkout origin/<上一大版本分支> -- alauda` 找回。修复原因后如需整体重跑：先回到上一大版本分支并删除半成品目标分支（`git checkout <上一大版本分支> && git branch -D <目标分支>`；仅当目标分支尚未成功 push 且与上游 tag 指向完全一致时才可删，删前用 `git rev-parse` 核对），再重新执行本脚本。

然后核对遗漏：Read `out/sync-upstream/prev-custom.stat`（上一版的完整定制清单），逐个文件归类——workflows、alauda/ 与 .claude symlink（已恢复）、6 个构建文件（已套用）、samples（步骤 4 cherry-pick）、releasenotes/tests/依赖 pin 等（通常是旧版 CVE 修复或上游 cherry-pick 的残留，新版本已包含或不适用，**不迁移**）。判定「上游已包含」时要落到证据（对比目标 tag 的文件内容或搜对应测试/函数是否存在），不要只凭提交信息推断。清单之外拿不准的文件停下来向用户提问；全部归类结果写进最终汇报。

### 步骤 2：更新流水线配置

```bash
bash "$SKILL_DIR/scripts/update-workflows.sh"
```

major 模式额外完成：pr-builder 的 `branches` 过滤改为 `istio-1.XX*`、删除 GOTOOLCHAIN（历史 CVE pin 不带入新大版本）、release.yaml 的 go-version 保持 "1.24"、alauda/release.sh 的 tools 依赖分支改为 `release-1.XX`。输出语义与小版本步骤 2 相同（BASE_VERSION 保持继承值，bot 会自动更新）。

### 步骤 3：提交构建定制

review `git diff` 后，把步骤 1～2 的全部修改提交为一个新 commit（如 `chore: istio 1.XX build with alauda infra`）。必须先提交再进入步骤 4：cherry-pick 需要干净的工作区。

### 步骤 4：cherry-pick samples 定制

Read `alauda/README.md` 的「Alaude Istio 源码改动历史」章节，逐条执行其中的 `git cherry-pick <sha>`（这些提交在上一个大版本分支历史上，fetch origin 后本地可得；若恢复出的 alauda/ 里没有 README.md，用 `git show origin/<上一大版本分支>:alauda/README.md` 查看）。有冲突就按定制意图解决；cherry-pick 保持各自独立提交，不要 squash。

### 步骤 5：创建构建 PR

PR 描述写进临时文件（scratchpad 下）：定制迁移清单（恢复/套用/cherry-pick/放弃迁移各有哪些及原因）、流水线修改点、NOTICE 事项，结尾加 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <PR正文文件>
```

注意：新大版本的第一个 PR 流水线会先通过 fork 中镜像的上游 tag 生成镜像标签，之后仍**可能失败**——istio-base-images 尚未为新版本构建基础镜像、`BASE_VERSION` 要等 bot 更新。这是预期内的，向用户说明即可，**不要试图通过改用旧基础镜像来绕过**。

### 步骤 6：更新 istio-base-images 分支列表

```bash
bash "$SKILL_DIR/scripts/update-base-images.sh"
```

把 `istio-1.XX` 加入 `DEFAULT_ISTIO_BRANCHES`，同时裁剪掉不属于最新两个大版本的条目，创建 PR。

## 最终汇报

用清晰的列表向用户汇报（这是用户 review 的依据）：

1. 模式与版本跨度、同步分支名、合入提交数；
2. 冲突逐条说明（文件 → 冲突点 → 解决方式），无冲突则写明；大版本另附定制迁移归类结果；
3. 流水线修改：IMAGE_VERSION 新旧值、GOTOOLCHAIN/注释等 NOTICE 事项的处理建议；
4. 各 PR 链接（istio 升级 PR、istio-base-images PR）与历史分支/默认分支变更；
5. 遗留事项（如大版本首次流水线预期失败、需用户定夺的 pin）。

到此流程结束，等用户 review 与合并；不要自行 merge PR。
