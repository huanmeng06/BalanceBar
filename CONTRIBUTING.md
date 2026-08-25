# 为 BalanceBar 做贡献

感谢你愿意改进 BalanceBar。为了让问题能够复现、修改边界清晰、审阅结果可验证，请在提交前阅读本指南和[开发文档](docs/development.md)。参与社区交流即表示你同意遵守[社区行为准则](CODE_OF_CONDUCT.md)。

## 提交 Issue

请先搜索现有 Issue，避免重复报告。创建 Issue 时请选择最贴近的模板：

- **Bug 报告**：说明可观察到的实际结果、复现步骤、期望结果、应用与系统版本，并提供已脱敏的日志；
- **功能建议**：先描述要解决的问题和用户价值，再说明建议行为、范围及验收条件；
- **维护任务（结构化）**：供维护者把已经确认的工作整理为可独立交付的任务。

不要在公开 Issue 中粘贴 API Key、Token、Cookie、完整 endpoint、真实凭据、私人数据库或其他敏感信息。安全漏洞请按[安全策略](SECURITY.md)私下报告。

不需要先判断根因或设计技术方案。请把你知道的事实写清楚；不知道的内容可以留空或写“不清楚”。维护者会根据反馈补充范围、验收标准、验证方式、依赖和发布策略等内部信息。外部贡献者无需自行操作 `ai:*` 标签。

## 开发环境

项目要求 macOS 14 或更高版本、Swift 命令行工具及带有共享 `BalanceBar` Scheme 的 Xcode。运行时供应商集成的人工测试还需要已配置的 CC Switch；自动化测试不应依赖个人供应商数据库或真实凭据。

从仓库根目录确认工作区状态并创建独立分支：

```bash
git status --short --branch
git switch -c <类型>/<简短名称>
```

建议使用 `fix/`、`feat/`、`docs/` 或 `test/` 作为分支前缀。不要覆盖或清理不属于本次修改的本地更改。

## 修改原则

- 保持一次 Pull Request 只解决一个清晰问题，并关联对应 Issue；
- 先确认相关入口、数据/状态流和最小修改边界，再编辑代码；
- 避免顺手重构、无关格式化或扩大需求；
- 网络、文件系统、数据库、进程、定时器和通知中心等外部 I/O 应通过可注入边界隔离；
- 新增 Swift 文件时，同时确认 CLI 构建的递归发现和 Xcode target 的文件引用；
- 修改本地化文案时，保持八套具体语言资源的 key 一致，并运行本地化探针；
- 普通实现阶段不要修改 `work/balance-bar/Info.plist` 中的版本号，除非维护者明确把发布升号纳入当前任务。

代码结构与依赖方向请参阅[架构说明](docs/architecture.md)。

## 验证

至少运行与改动相称的检查，并在 Pull Request 中记录完整命令与结果。完整验证顺序见[开发文档](docs/development.md)，核心命令包括：

```bash
./work/balance-bar/build.sh
./work/balance-bar/localization-resource-probe.sh
./work/balance-bar/balance-query-probe.sh
./work/balance-bar/balance-network-error-localization-probe.sh

xcodebuild \
  -project BalanceBar.xcodeproj \
  -scheme BalanceBar \
  -configuration Debug \
  -derivedDataPath /tmp/BalanceBar-DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build-for-testing

xcodebuild \
  -project BalanceBar.xcodeproj \
  -scheme BalanceBar \
  -configuration Debug \
  -derivedDataPath /tmp/BalanceBar-DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  -parallel-testing-enabled NO \
  test-without-building

git diff --check
```

终端检查不能证明视觉和交互体验正确。涉及菜单栏、Dashboard、窗口行为、供应商切换、深浅色或无障碍体验时，请构建独立开发版，并把具体人工步骤与逐步预期写入 Pull Request：

```bash
./work/balance-bar/build.sh dev
```

开发版位于 `work/balance-bar/build/dev/BalanceBar-dev.app`，Bundle ID 为 `com.huanmeng06.BalanceBar.dev`，不会覆盖生产版。

## 提交 Pull Request

请填写仓库提供的简短 Pull Request 模板。知道多少写多少，维护者会协助补齐审阅所需的信息。提交前请尽量确保：

- 使用 `Closes #<Issue>` 或 `Fixes #<Issue>` 关联唯一的主要 Issue；
- 用几句话说明修改内容和原因；
- 写出实际运行过的验证命令和手动操作；
- 涉及界面时尽量提供已脱敏的截图或录屏；
- 如果知道可能的回归、数据、隐私、安全或兼容性影响，请主动说明；
- 确认没有提交凭据、个人绝对路径或生成产物。

实现者的自检不等于最终审阅。维护者会独立核对 Issue 契约、完整 diff、验证证据和人工测试结果，并可能要求在同一个分支与 Pull Request 中继续修改。
