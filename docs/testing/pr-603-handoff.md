# PR #603 交接文档

更新时间：2026-10-25（America/New_York）
交接范围：BalanceBar Mod M2 / PR #603

## 1. 工作标识

- 仓库：`huanmeng06/BalanceBar`
- PR：[#603](https://github.com/huanmeng06/BalanceBar/pull/603)
- PR 状态：Open / Draft
- Head 分支：`codex/issue-597-mod-user-install`
- Base 分支：`main`
- 已验证应用源码 HEAD：`9a655f1d712ddca57b2d4256778f5c2068a3a354`
- 交接文档本身会在该源码 HEAD 之后增加 docs-only 提交；接手时以 `git rev-parse origin/codex/issue-597-mod-user-install` 和 PR 实时 HEAD 为准。
- 已合入的最新 main：`285fab11dffd585c64f2f32fa82d6bd3c744cff2`（#608）
- main 合入提交：`b7123abbc005b77d2c4f4d52937b310940aaa8ec`
- 工作树：`/Users/huan_meeng/Documents/GitHub/BalanceBar/.claude/worktrees/issue-597-mod-user-install`
- 记录本文件时工作树干净，HEAD 与 `origin/codex/issue-597-mod-user-install` 一致。
- `origin/main` 是 HEAD 的祖先；分支相对 main 的落后提交数为 0。

不要新开重复分支或 PR。后续修改继续使用该工作树、分支和 PR，保持 Draft，等待组合验收。

## 2. 当前交付内容

- M1 #602 已合入 main，提供 Mod 快照、Inbox、Claude 管线及可信数据通路。
- M2 #603 提供用户级 marketplace/plugin 安装、检测、可信状态、安全卸载。
- UI #605 / Issue #604 已合入 #603 分支，恢复 INT-2 风格的高级设置卡片与原生说明/管理窗口。
- main #606 和 #608 已合入 #603，未覆盖 Mod 或 main 新功能。
- 应用版本继承 main，为 `1.7.40 / 209`。本次 PR 没有另行准备发布或升版本。

关键安全边界：

- 安装、启用和卸载都显式使用 `--scope user`。
- 只管理 `balancebar-mod@balancebar-mods` 和 BalanceBar 自有 marketplace。
- 不改 statusLine、其它插件、账号/周期校验、快照可信度、300 秒官方限流。
- 不把安装命令成功、快照文件写入或同值重写当成“可信实时数据”。
- 卸载必须是显式二次确认；Return 不能直接执行危险操作。

## 3. 已完成并验证

### 3.1 INT-2 前端恢复

- 设置 → 高级 → Claude 实时增强独立卡片。
- 原生说明窗口、四类要点、三步安装/等待数据、可信成功页、管理/静默/失败/卸载页面。
- 命令块内复制反馈、12 语言、浅深色、键盘默认动作和父窗口生命周期。
- 详细还原项及保留差异见 [Issue #604 UI 还原清单](../issue-604-ui/restoration.md)。

### 3.2 卸载后高级卡片陈旧状态修复

问题：主窗口在 General 页时执行卸载，管理窗口显示已卸载，但 Advanced 卡片仍为“已启用”及旧时间。

根因：

- Mod 卡片已迁到 Advanced，但 `DashboardCompositionController.refreshModSync()` 仍以 `canUpdateSettingsPage(.general)` 为刷新门槛。
- 重新进入缓存的 Advanced 页时，没有从当前 coordinator 拉取最新状态。

修复：

- `refreshModSync()` 改为针对 `.advanced`。
- `.advanced` 页面激活时调用 `dashboardPreferencePages.refreshModSync()`。
- 精确回归覆盖可见 Advanced、离开后返回缓存 Advanced、全局搜索投影，以及新可信数据时间更新。

提交：

- 修复提交：`1fe3ed4d`
- 回归与问题记录：`1fe3ed4d`、`9a655f1d`

证据：

- 修复前：3 tests，6 failures。
- 修复后：3 tests，0 failures。
- 相关完整回归：128 tests，0 failures。
- 合入最新 main 后再次运行三条回归：3 tests，0 failures。
- 用户人工复测 PASS：先设为主窗口 General，在管理窗口卸载，再回 Advanced，卡片立即变为“未开启”，旧时间和绿点消失；页面往返和全局搜索结果一致。

问题详情见 [pending-bugs.md](../pending-bugs.md) 中 `BUG-20261025-02`。

## 4. 当前本机状态

- 当前有开发版运行：
  `/Users/huan_meeng/Documents/GitHub/BalanceBar/.claude/worktrees/issue-597-mod-user-install/build/dev/BalanceBar-dev.app`
- Bundle ID：`com.huanmeng06.BalanceBar.dev`
- 版本：`1.7.40 / 209`
- 可执行文件 SHA-256：
  `bc559d80221ee49db46ddde5c4d1c2fde9cd9212de2bbc999cb851f5712e418a`
- App 源码对应合并提交 `b7123abb`；之后只有文档提交，应用源码未变。
- 签名验证已在交接前通过。
- **当前 Mod 已重新安装并为启用状态**：
  - `balancebar-mod@balancebar-mods`
  - scope：`user`
  - enabled：`true`
  - marketplace source：directory
  - marketplace path：当前 #603 工作树
- 不要因为 `pending-bugs.md` 里记录过“卸载 PASS”就误以为现在仍未安装；以交接前只读查询结果为准。

## 5. 测试结果

- 合入 main #608 后应用源码状态的三项定向回归：3/3 PASS。
- 设置搜索与 Mod UI/协调器完整相关回归：128/128 PASS。
- 合入 main #606 后更大范围聚焦回归：304/304 PASS。
- Debug Xcode build：PASS。
- `./scripts/build.sh dev`、`codesign --verify --deep --strict`：PASS。
- 本地化探针：676 keys × 12 languages，PASS。
- 根 marketplace 和 `mod/ --strict` 校验：PASS。
- `claude plugin test ./mod`：9 PASS，0 fail。
- `git diff --check`：PASS。

未执行：

- 未运行 Full CI / 完整 XCTest。
- 未把 Draft 或 Fast CI 结果称为 Full PASS。

交接时 CI 快照：

- Scope：PASS。
- Fast CI：可能仍在运行，接手后重新查询，不能沿用本快照。
- Full CI、artifact smoke：Draft 下 skipped。

完整测试记录见 [pr-603-main-sync-verification.md](pr-603-main-sync-verification.md)。

## 6. 剩余工作与风险

### A. “最新数据”时间语义仍待决定

`BUG-20261025-01` 仍在 [pending-bugs.md](../pending-bugs.md)。

已确认事实：

- Mod 会更新快照文件的 `updated_at`。
- 同值窗口（kind、百分比、重置时间都相同）会被现有 replay suppression 去重，不再发射新 observation。
- 卡片“最新数据”当前展示最后可信受理时间，而不是最后文件写入时间。

需要维护者决定：

- 如果产品期望显示最后收到的数据，需要明确新增独立展示口径；不能把文件 mtime 当可信受理证据。
- 如果产品期望显示最后可信更新，应修改文案，使其明确区别于“收到快照时间”。
- 不得删除 replay suppression 或让同值重写延长可信新鲜度。

### B. 组合验收

#603 仍是 Draft。Full CI 和真实 CLI/Desktop Code 完整闭环需要在组合代码上统一执行：

- 从公开默认分支安装路径。
- 新 CLI 会话与 Desktop Code 本地会话。
- 真实可信受理、错误恢复、账号/周期拒绝。
- 卸载后 statusLine 和其它插件保持不变。
- 若进入 Ready，再等待当前 HEAD 的新 Full CI；不要用旧 Full 或 Fast 代替。

### C. GUI/VoiceOver

已有人工验证卸载状态、页面往返和搜索结果。仍需按需要补：

- 12 语言与浅深色完整巡检。
- VoiceOver 顺序和可操作性。
- 不同窗口高度下的滚动与长文案。
- 详细步骤见 [pr-603-local-mod-manual-test.md](pr-603-local-mod-manual-test.md)。

## 7. 接手后的第一批命令

```sh
cd "/Users/huan_meeng/Documents/GitHub/BalanceBar/.claude/worktrees/issue-597-mod-user-install"

git status --short --branch
git fetch origin main codex/issue-597-mod-user-install
git rev-parse HEAD origin/main origin/codex/issue-597-mod-user-install
git merge-base --is-ancestor origin/main HEAD

gh pr view 603 --json url,title,state,isDraft,baseRefName,headRefOid
gh pr checks 603 --json name,state,link

claude plugin list --json
claude plugin marketplace list --json

codesign --verify --deep --strict build/dev/BalanceBar-dev.app
./scripts/probes/localization-resource-probe.sh
git diff --check
```

如果 main 在上次交接后前进：

```sh
git fetch origin main
git merge --no-ff origin/main
git diff --check
```

发生冲突时不要 force-push、rebase 或丢弃另一方修改；先根据业务归属解决并运行相关回归。main 更新后需要重建测试 App，并重新运行受影响测试。

## 8. 定向回归命令

```sh
xcodebuild -project BalanceBar.xcodeproj -scheme BalanceBar \
  -configuration Debug \
  -derivedDataPath /tmp/BalanceBar-Issue603-ModStatus-DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -parallel-testing-enabled NO \
  -only-testing:BalanceBarTests/DashboardPageSearchTests/testVisibleAdvancedModCardUpdatesAfterUninstallAndNewEvidence \
  -only-testing:BalanceBarTests/DashboardPageSearchTests/testCachedAdvancedModCardRefreshesWhenReturningFromAnotherPage \
  -only-testing:BalanceBarTests/DashboardPageSearchTests/testGlobalSearchModCardReceivesLiveStatusUpdates \
  test
```

更完整的 UI/搜索/协调器回归：

```sh
xcodebuild -project BalanceBar.xcodeproj -scheme BalanceBar \
  -configuration Debug \
  -derivedDataPath /tmp/BalanceBar-Issue603-ModStatus-DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -parallel-testing-enabled NO \
  -only-testing:BalanceBarTests/DashboardPageSearchTests \
  -only-testing:BalanceBarTests/RealtimeBoostAdvancedCardTests \
  -only-testing:BalanceBarTests/ModInt2WindowRestorationTests \
  -only-testing:BalanceBarTests/ModManagementUITests \
  -only-testing:BalanceBarTests/ModSyncCoordinatorTests \
  test
```

## 9. 禁止事项

- 不新建第二个 #603 执行任务、分支、worktree 或 PR。
- 不把 base 改成非 `main`；不要直接合并 main。
- 不未经授权关闭 PR、转 Ready、合并、发布或升版本。
- 不改 `--scope user`，不恢复旧 HUD/Codex/多端逻辑。
- 不删除现有回归测试来“修绿”。
- 不造假快照、修改账号/周期验证或绕过 replay suppression。
- 不提交 token、邮箱、完整 Claude 配置或对话内容。

## 10. DS Harness 可直接使用的提示词

```text
你接手 BalanceBar PR #603（Issue #597，M2）。请先完整阅读仓库中的：
docs/testing/pr-603-handoff.md
docs/testing/pr-603-main-sync-verification.md
docs/pending-bugs.md
docs/issue-604-ui/restoration.md

固定上下文：
- 仓库：huanmeng06/BalanceBar
- 使用已有工作树：/Users/huan_meeng/Documents/GitHub/BalanceBar/.claude/worktrees/issue-597-mod-user-install
- 分支：codex/issue-597-mod-user-install
- PR：https://github.com/huanmeng06/BalanceBar/pull/603
- 已验证应用源码 HEAD：9a655f1d712ddca57b2d4256778f5c2068a3a354（交接文档可能随后增加 docs-only 提交，需以远程实时 HEAD 核对）
- 交接时已合入 main：285fab11dffd585c64f2f32fa82d6bd3c744cff2
- PR 必须保持 Draft、base=main，除非用户之后明确授权转 Ready、合并或发布。

开工先做只读检查：
1. 确认当前工作树、分支、HEAD 和是否有用户未提交修改。
2. 重新 fetch origin/main 与 origin/codex/issue-597-mod-user-install，确认 PR 的远程 HEAD 和 CI，不要只信交接文档快照。
3. 查询 claude plugin list --json、claude plugin marketplace list --json 和当前 inbox；不要把“曾经卸载过”误认为当前未安装。
4. 阅读 docs/pending-bugs.md，将 BUG-20261025-01 与已修复的 BUG-20261025-02 分开处理。

当前主要待办：
- BUG-20261025-01：“最新数据”展示的是最后可信受理时间，而同值快照只有文件 updated_at 变化时会被 replay suppression 去重。先做根因确认和产品语义判断，不得删除去重、伪造可信数据或让同值重写延长新鲜度。给出最小、可验证的修复方案并记录假设。
- 按用户指示继续组合验收：Full CI、真实 CLI/Desktop Code 数据受理、失败恢复和卸载安全。不要在 Draft 阶段声称 Full PASS。
- 如 main 已前进，用普通 merge 合入最新 main，解决冲突并运行受影响回归；不要 rebase/force-push。
- 保留 Installer CLI 参数、--scope user、账号/周期验证、官方 300 秒限流、statusLine 和 M1 管线语义。

任何代码修改前先说明最小范围和验收标准。完成后运行风险匹配的定向 XCTest、本地化 probes、build.sh dev、codesign 和 git diff --check。真实 GUI/CLI 结果必须区分自动测试与人工 PASS。使用原 worktree、原分支、原 PR，不要创建重复任务。
```
