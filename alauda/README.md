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
