# Alaude Release

## Alaude Istio 源码改动历史

```bash
# feat: tcp echo samples services add pod name prefix
git cherry-pick b0ca4455d5620a21754fd3c6b7432b84aafec97b
# feat: bookinfo samples add health check config
git cherry-pick 539b7ef386bbeab280603bb1bd2a676a5a7b1558
```

## 版本升级

上游同步通过 Claude Code skill [`/sync-upstream`](skills/sync-upstream/SKILL.md) 完成（仅限显式调用，参数：上游 tag + 目标分支，模式由目标分支是否已存在自动判定）：

```bash
# 小版本升级（目标分支已存在）：merge 上游 tag、更新流水线 IMAGE_VERSION、创建升级 PR、
# 旧小版本留档为 istio-1.28.6 分支、更新 istio-base-images 的 DEFAULT_ISTIO_BRANCHES
/sync-upstream 1.28.7 istio-1.28

# 大版本升级（目标分支不存在）：基于上游 tag 新建 istio-1.30 分支并设为默认分支、
# 迁移 Alauda 构建定制（workflows/alauda/构建文件）、cherry-pick samples 改动、
# 创建构建 PR、更新 istio-base-images 分支列表（只维护最新两个大版本）
/sync-upstream 1.30.0 istio-1.30
```

机械步骤已脚本化（见 [skills/sync-upstream/scripts/](skills/sync-upstream/scripts/)），合并冲突解决与定制迁移核对由模型执行并在 PR 描述中逐条说明。skill 通过 `.claude/skills/sync-upstream` 软链接接入 Claude Code。

## 漏洞修复

镜像漏洞修复通过 Claude Code skill [`/fix-image-vulns`](skills/fix-image-vulns/SKILL.md) 完成（仅限显式调用，参数：一个或多个 Release Alauda Istio / Pull Request Builder 流水线 run，可混多个小版本）：

```bash
# 扫描各 run 构建的 install-cni/pilot/proxyv2/ztunnel 四个 -distroless 镜像，
# 按目标分支逐个修复（go stdlib → 升 workflow 的 GOTOOLCHAIN；go.mod 依赖 → 升库版本，
# 多小版本间复用修复记录）、建 PR 并监控流水线、回归扫描，最多 3 轮修复；
# os 级与 ztunnel 镜像的漏洞只扫描报告、不修复
/fix-image-vulns 30178633704 30063689478 30063691266
```

目标分支自动从 run 推断（Release run → release 的目标分支；PR run → PR 的 base 分支），推断不出时会与用户确认。机械步骤已脚本化（见 [skills/fix-image-vulns/scripts/](skills/fix-image-vulns/scripts/)），漏洞分析、升级版本决策与失败原因分析由模型执行。skill 通过 `.claude/skills/fix-image-vulns` 软链接接入 Claude Code。
