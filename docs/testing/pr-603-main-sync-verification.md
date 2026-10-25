# PR #603：main 同步与测试包记录

- 同步前远程 #603：`adf511088770a72bf26651545ad480d15f9e5117`（已包含 #605）。
- 本轮最新 main：`8afa79864a67c84bfb3cc6abda0c0456a1cc1442`（#606）。
- 正常 merge：`79a6fdfd93c1808886e2d34213a3fcabd739519f`，两父提交正是上述两个提交，**无冲突**，未 rebase/force-push。
- main 的7个文件改动完整保留；未手动覆盖 Mod 或 #606 的实现。`git merge-base --is-ancestor origin/main HEAD` 通过，落后 main 的提交数为0。
- 版本继承 main 的 `1.7.39 / 208`；未另做版本提升。#603 仍保持 Draft，未合入 main、未发布。

## 测试 App

在 #603 原工作树运行 `./scripts/build.sh dev`，产物 `build/dev/BalanceBar-dev.app`。构建源为 `79a6fdfd`；后续手测文档提交不改变应用源码。

- Bundle ID：`com.huanmeng06.BalanceBar.dev`
- Short version/build：`1.7.39 / 208`
- `codesign --verify --deep --strict build/dev/BalanceBar-dev.app`：PASS
- `localization-resource-probe.sh build/dev/BalanceBar-dev.app`：PASS（676 keys，12 languages，已检查bundle打包）

## 自动验证

- Xcode 串行聚焦 XCTest：**304 tests，0 failures**。
- CLI Mod 清单校验：根 marketplace 与 `mod/ --strict` 均 PASS。
- `claude plugin test ./mod`：**9 PASS，0 fail**。
- 三项本地化 probes：PASS。
- `git diff --check`：PASS。
- 没有执行 Full CI/完整 XCTest，没有真实安装/卸载 Mod 或代替用户进行 GUI/CLI会话测试。

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
