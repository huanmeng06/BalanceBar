# PR #603：main 同步与测试包记录

- 同步前远程 #603：`adf511088770a72bf26651545ad480d15f9e5117`（已包含 #605）。
- 已合入 main：`285fab11dffd585c64f2f32fa82d6bd3c744cff2`（#608；其祖先包含 #606 `8afa7986`）。
- 正常 merge：`b7123abbc005b77d2c4f4d52937b310940aaa8ec`，**无冲突**，未 rebase/force-push。合并前也曾经由 `79a6fdfd` 合入 #606。
- main 的 #606/#608 改动完整保留；未手动覆盖 Mod 或 main 服务。`git merge-base --is-ancestor origin/main HEAD` 通过，落后 main 的提交数为0。
- 版本继承当前 main 的 `1.7.40 / 209`；未另做版本提升。#603 仍保持 Draft，未合入 main、未发布。

## 测试 App

在 #603 原工作树运行 `./scripts/build.sh dev`，产物 `build/dev/BalanceBar-dev.app`。

- Bundle ID：`com.huanmeng06.BalanceBar.dev`
- Short version/build：`1.7.40 / 209`
- `codesign --verify --deep --strict build/dev/BalanceBar-dev.app`：PASS
- `localization-resource-probe.sh build/dev/BalanceBar-dev.app`：PASS（676 keys，12 languages，已检查bundle打包）
- 修复版可执行文件 SHA-256：`bc559d80221ee49db46ddde5c4d1c2fde9cd9212de2bbc999cb851f5712e418a`。

## 自动验证

- Xcode 串行聚焦 XCTest：**304 tests，0 failures**。
- CLI Mod 清单校验：根 marketplace 与 `mod/ --strict` 均 PASS。
- `claude plugin test ./mod`：**9 PASS，0 fail**。
- 三项本地化 probes：PASS。
- `git diff --check`：PASS。
- 没有执行 Full CI/完整 XCTest，没有真实安装/卸载 Mod 或代替用户进行 GUI/CLI会话测试。

### 卸载后高级卡片状态回归

- 用户手测确认：CLI 的插件与 marketplace 均已移除，管理窗恢复安装说明，但高级卡片仍保留“已启用”和旧时间。
- 根因：Mod 卡片迁到 Advanced 后，`DashboardCompositionController.refreshModSync()` 仍以 General 可见作为刷新门槛；缓存的 Advanced 页重新激活时也未拉取最新状态。
- 修复：刷新门槛改为 Advanced，并在 Advanced 激活时同步当前 Mod 状态与操作进度。
- 新增三个回归，分别覆盖可见 Advanced、切页返回缓存 Advanced、全局搜索投影。修复前执行 3 tests，得到 6 failures；修复后 **3 tests，0 failures**。
- 随后运行完整 `DashboardPageSearchTests` 和 Mod UI/协调器相关类：**128 tests，0 failures**。修复后重新执行 `build.sh dev`，签名验证 PASS。
- 合入 main #608 后再次运行这三个回归：**3 tests，0 failures**；随后从最终分支重建 dev App，版本 `1.7.40 / 209`，签名验证 PASS。
- 用户使用该测试包完成人工回归：在 General 页期间卸载，返回 Advanced 后卡片立即变为“未开启”且旧时间消失；页面往返和全局搜索结果一致。随后 CLI 查询插件与 marketplace，均无 BalanceBar 条目。**人工回归 PASS**。
- 修复应用源码对应本轮 #603 修复提交；本记录所在提交之前，构建产物由该源码生成。仍待用户用修复版重新执行一次卸载人工验收。

Xcode 实际命令共用参数：

```sh
xcodebuild -project BalanceBar.xcodeproj -scheme BalanceBar \
  -configuration Debug -derivedDataPath /tmp/BalanceBar-PR603-MainSync-DerivedData \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -parallel-testing-enabled NO \
  -only-testing:BalanceBarTests/ResponseParsersTests \
  -only-testing:BalanceBarTests/OverviewNumericTransitionTests \
  -only-testing:BalanceBarTests/DashboardWindowControllerTests \
  -only-testing:BalanceBarTests/ModInt2WindowRestorationTests \
  -only-testing:BalanceBarTests/ModManagementUITests \
  -only-testing:BalanceBarTests/ModOnboardingPanelTests \
  -only-testing:BalanceBarTests/ModPanelSyncContextTests \
  -only-testing:BalanceBarTests/ModSyncCoordinatorTests \
  -only-testing:BalanceBarTests/RealtimeBoostAdvancedCardTests \
  -only-testing:BalanceBarTests/LocalizationTests \
  -only-testing:BalanceBarTests/ClaudeQuotaPipelineTests \
  -only-testing:BalanceBarTests/SnapshotInboxTests \
  -only-testing:BalanceBarTests/QuotaMergeEngineTests \
  -only-testing:BalanceBarTests/AppDelegateCompositionTests test
```

覆盖 main 新增解析/倒计时及相关窗口行为，和 Mod UI、生命周期、应用接线、可信状态与 Inbox/Pipeline/MergeEngine；不将该聚焦集合称为 Full。

[完整人工流程、本地命令与未发布边界](pr-603-local-mod-manual-test.md)。
