# Dashboard 原生 UI 基线与验收矩阵

本文记录 **当前** Dashboard 的窗口外壳、导航、代表页面和交互契约，供后续原生 AppKit 重构 Issue 做回归对照。它只描述 `Sources/UI/Dashboard/` 里已经落地的行为，不是目标视觉，也不授权改实现。

- 基线提交：`origin/main` 的 Dashboard 代码与本文件一并审阅；后续重构必须说明每一项是保持、有意改变，还是仍待人工确认。
- 历史审计 [`docs/archive/native-macos-ui-audit.md`](archive/native-macos-ui-audit.md) 针对旧单文件 `work/balance-bar/BalanceBar.swift`，**已过期，不得当作当前事实**。
- 本仓库没有截图/快照测试框架。本 Issue **不新增**视觉快照基础设施；可代码证明的事实由 XCTest 锁定，像素级外观由人工矩阵确认。

## 如何本地复现

从仓库根目录：

```sh
./scripts/build.sh dev
open -n build/dev/BalanceBar-dev.app
```

开发版 Bundle ID 为 `com.huanmeng06.BalanceBar.dev`，不会覆盖生产版。打开 Dashboard 后，按下文矩阵逐页核对。自动化只证明编译和代码级契约：

```sh
xcodebuild -project BalanceBar.xcodeproj -scheme BalanceBar
```

以及 `DashboardNativeUIBaselineTests`、`DashboardWindowControllerTests`、`DashboardWindowDragRegionTests` 等现有 Dashboard XCTest。Worker / CI 不得用 Computer Use、`open` 或激活窗口来代替人工验收。

## 当前结构（入口）

| 职责 | 当前路径 |
| --- | --- |
| 窗口、标题栏拖拽、缩放状态 | `Sources/UI/Dashboard/DashboardWindowController.swift` |
| 侧栏 source-list 导航 | `Sources/UI/Dashboard/DashboardSourceListController.swift` |
| 页面装配与 Provider/偏好页生命周期 | `Sources/UI/Dashboard/DashboardCompositionController.swift` |
| 通用/刷新/启动/应用设置 | `Pages/Preferences/DashboardGeneralAndRefreshPages.swift` |
| 菜单栏 / 菜单 / 高级 / 关于 | `DashboardMenuBarPage.swift` 与同目录 `DashboardMenuBar*Section.swift` / `DashboardMenuBarRepeatControls.swift` 的结构拆分；`DashboardMenuPage.swift`、`DashboardAdvancedPage.swift`、`DashboardAboutPage.swift` |
| Provider 详情（生产路径） | `Pages/Providers/DashboardProviderPages.swift` 的 `makeDetailPage` |
| 设置页滚动与卡片行 | `Components/DashboardSettingsComponents.swift`；原生试点在 `Settings/Components/`（`SettingsRowView`、`SettingsSectionView`） |
| 浅色/深色自适应色 | `Components/DashboardComponents.swift` 的 `dashboardUsesDarkAppearance` |

侧栏导航枚举只有五页：`DashboardSection` = General、Menu Bar、Menu、Advanced、About。Issue 要求覆盖的 **Refresh 不是独立侧栏页**：它是 General 上的「刷新」卡片。未挂载的 `DashboardRefreshPage`（Provider fallback polling / 任务状态检测）和 `makeOverviewPage` 仍存在于源码，但当前窗口路径不会打开它们。

## 共享窗口外壳

所有代表页共用同一个 `NSWindow`。生产创建参数：

| 项目 | 当前事实 | 证据 |
| --- | --- | --- |
| 默认内容尺寸 | `contentRect` 880×620 | `createDashboardWindow` |
| 最小尺寸 | 代码写入 `minSize` 800×540；安装 unified toolbar 后 AppKit 把 frame 高度下限抬到 **560**（XCTest 在 macOS 26.5 上测得）。宽度下限仍为 800。 | 创建窗口后的运行时 `window.minSize` |
| 样式 | `.titled` `.closable` `.miniaturizable` `.resizable` `.fullSizeContentView` | 同上 |
| 标题 | `titleVisibility = .hidden`；`window.title` 仍写入当前页标题 | 同上；`showSection` / `showProvider` |
| 标题栏 | 透明、无分隔线；`toolbarStyle = .unified`；icon-only、不可自定义、不自动保存的 `NSToolbar`。默认系统项：`.flexibleSpace`、`.toggleSidebar`、`.sidebarTrackingSeparator`。`.flexibleSpace` 是 AppKit 系统 flexible space（`NSToolbarItem.Identifier.flexibleSpace`），不是应用手写 spacer / 固定宽度 / magic number；它把 toggle 推到侧栏 toolbar 段 trailing，靠近 tracking separator / divider。由独立 `DashboardToolbarController` 作为 delegate 提供；toggle 走 `NSSplitViewController` responder chain，separator 由 AppKit 跟踪 split divider。 | 同上；`DashboardToolbarController` |
| 背景 | `isOpaque = false`，`backgroundColor = .clear`，`hasShadow = true` | 同上；测试宿主会改 alpha/shadow，不能用 XCTest 证明最终像素 |
| 外观 | `appearance = nil`，跟随系统；`AppleInterfaceThemeChangedNotification` 后异步 `rebuild()` | `start()` / `createDashboardWindow` |
| 缩放按钮 | **可见且 `isEnabled = true`**；使用系统标准 zoom 按钮 | `createDashboardWindow` |
| 红黄绿 | 使用系统 `standardWindowButton`；不手动排除热区、不另做自定义拖拽覆盖层 | `standardWindowButton` |
| 拖拽 | `isMovableByWindowBackground = false`；`DashboardContentRootView.mouseDownCanMoveWindow = false`，内容区不拖窗口；拖动由原生标题栏 / AppKit 处理，无全窗口 drag overlay | `createDashboardWindow` / `DashboardContentRootView` |
| 双击标题栏 | `DashboardContentRootView.hitTest` 对 `contentLayoutRect` 以上返回 `nil`，让 NSThemeFrame 执行系统 `AppleActionOnDoubleClick`；不再调用 `toggleWindowZoom()` | `DashboardContentRootView.hitTest` |
| 全屏 | 使用标准 zoom / 全屏行为；不再在 `.fullScreen` 时用自定义 `hitTest` 抑制双击 | AppKit |
| 根视图 | `window.contentViewController` 为 `DashboardSplitViewController`（`NSSplitViewController`）。其 `view` 是挂载中的 `DashboardContentRootView`：material `.underWindowBackground`，圆角 16。全宽 `contentSurface` 叠在透明 `NSSplitView` 下方；左侧 `NSSplitViewItem(sidebarWithViewController:)`，右侧普通 content item。原生 `NSSplitView` 为 `isVertical = true`、`.thin` divider。打开时侧栏约 216pt（sidebar 视图一次性 frame seed，不是 `preferredThicknessFraction`）；`minimumThickness` 约 212、`maximumThickness` 320；`canCollapse = true`。折叠/展开走 `isCollapsed` 与 `toggleSidebar(_:)`；用户可见的系统 toolbar toggle 由 `DashboardToolbarController` 接入同一 responder chain。不把 divider 厚度锁成 0，也不另造 hit strip；`holdingPriority` 为 sidebar 251 / content `.defaultLow`。 | `installLayout` / `DashboardSplitViewController` / `DashboardToolbarController` |
| 侧栏材质 | 由 `NSSplitViewItem(sidebarWithViewController:)` 提供系统 sidebar chrome；侧栏根视图透明，仅承载 source-list | `makeSidebar` / `DashboardSplitViewController` |
| 点击编辑 | 窗口级 `leftMouseDown` monitor：点在可编辑 `NSTextField` 内保持编辑，点在标签/卡片/空白处 `makeFirstResponder(nil)` | `installMouseMonitor` |

测试宿主（`ApplicationWindowPresentation`）会把窗口停到屏幕外并关闭阴影、设为透明。下面标为「代码已锁定」的项可以在 XCTest 里断言；标为「人工」的项必须看开发版。

## 侧栏选择

打开时宽度约 216pt（sidebar 初始 frame，不是 `widthAnchor`，也不是 min=max 锁定）。分组顺序：

1. General（无组标题）
2. Appearance 组：Menu Bar、Menu
3. System 组：Advanced、About

侧栏导航是 `NSOutlineView` source-list（`DashboardSourceListController`）。可导航项是 `DashboardSidebarNode` 数据模型；Appearance / System 是不可选择的 group header。选中由 outline view 原生管理，不再维护平行的 `navigationButtons` / `navigationRows` 或自定义 `isSelected` 背景。source-list 随侧栏宽度拉伸；#385 的 split-view 尺寸/折叠契约不变。鼠标点击 group 行（含标题右侧空白）不得改变 selection、不得导航。↑/↓ 由 outline 的 `moveUp`/`moveDown` 在五个可选项间移动并跳过 group；不得把 group proposal 重映射到相邻 section（那条路径同样处理鼠标）。

- 打开窗口默认选中 General。
- `showSection` 同步原生 selection，但不通过 delegate 再次切页。
- `showProvider` **清空全部侧栏选中**，`window.title` 改为 Provider 名称。Provider **不出现在侧栏**（#386 Issue 正文曾提到 Provider 行，以本基线与现行生产路径为准）。
- General 行可显示更新红点（18×18，「1」），由更新状态驱动；窗口打开前、打开后和 rebuild 后均有效。

## 设置页滚动（General / Menu Bar / Menu / Advanced / Provider 详情）

`DashboardSettingsComponents.makeSettingsPage`：

- 垂直 overlay 滚动条，无水平滚动条，无弹性；
- 不自动继承标题栏 content inset；视口顶部另留 **52pt** 非滚动空白，使第一张卡片落在标题栏下方；
- 文档 `isFlipped`，初次挂载可见原点对准文档顶部；
- 卡片圆角 18，可见行高度至少 62pt（个别行另有更高最小值）。

About **不**走这套 scroll host，而是顶部 92pt 起居中堆叠。Advanced 页内日志查看器另有内部 `NSTextView` 滚动（固定深色 VS Code 配色），与页面滚动独立。

## 代表页面内容（当前分组）

| 页面 | 当前卡片/结构 | 备注 |
| --- | --- | --- |
| General | System → Refresh → Startup → Application | Refresh 卡片含任务中余额更新间隔、结束后持续时长、立即刷新，并已迁到原生 `SettingsSectionView`：立即刷新行是 `SettingsRowView`，双 interval 行是 Refresh 专用 `DashboardRefreshBalanceUpdatesRowView`（不把 fitting-size 布局决策放进通用 `SettingsRowView`）。Startup 卡片是原生 `SettingsSectionView` 试点；其中 Silent Launch 行是原生 `SettingsRowView`，另外两行仍走 `makeSettingsRow`。System / Application 卡片仍走 `makeSettingsSection`。 |
| Refresh | 不是侧栏页 | 见 General 的 Refresh 卡片；`DashboardRefreshPage` 未挂载 |
| Menu Bar | Preview → Quota & Reset → Icon & Task Status → Behavior → Layout | 若干行随开关折叠，不改已存偏好 |
| Menu | Balance Display（条件）→ Banked Reset → Progress Bar → Menu behavior → Open Project → Status Links | Status Links 编辑器始终存在，开关只改高度/透明度 |
| Advanced | Diagnostics（调试日志 + 日志查看器） | 当前无第二张设置卡 |
| About | 图标、名称、版本、说明、GitHub 按钮 | GitHub 按钮系统 focus ring 关闭，焦点时自绘圆圈描边 |
| Provider 详情 | 标题/状态 + Usage + CC Switch | 当前 Provider 显示 Refresh Now，其他显示 Switch；生产路径不打开 Overview |

## 键盘与焦点（代码能确认的部分）

| 控件 | 当前策略 |
| --- | --- |
| 侧栏 source-list | 原生 `NSOutlineView` 选中/焦点；group header 不可选；图标装饰不进入 VoiceOver |
| 标准 `NSSwitch` / `NSPopUpButton` / 圆角按钮 | 工厂方法不关闭 focus ring，沿用 AppKit 默认 |
| Status Links 文本框 | `focusRingType = .default` |
| About GitHub 按钮 | `focusRingType = .none`，`firstResponder` 时自绘 `keyboardFocusIndicatorColor` 描边 |
| 额度颜色滑块 | `focusRingType = .none`，但 `acceptsFirstResponder = true` |
| 恢复滚动打开 Menu Bar | 不得把 FPS 输入框变成 first responder（已有测试） |
| 点击空白 | 结束当前编辑 |

Tab 顺序、VoiceOver 树、全键盘控制是否覆盖每一行，静态代码不能证明，必须人工走一遍。

## 浅色 / 深色

窗口不锁定 `appearance`。重建时按 `NSApp.effectiveAppearance` 选择：

- 根层浅色白 8% / 深色黑 14%；
- 内容表面浅色 0.94×82% / 深色黑 20%；
- 侧栏阴影透明度浅 0.08 / 深 0.18；
- 设置卡片浅白 94% / 深白 6.5%，阴影浅 0.08 / 深 0.20。

系统外观切换会整页 `rebuild()`，滚动位置是否保持不在本基线里宣称（后续重构若改变，必须单独验收）。

## 验收矩阵（后续 Issue 回归）

对每个代表页/状态，下列项必须保持，除非该 Issue 明确改掉并更新本文。

图例：`代码` = XCTest / 源码契约；`人工` = 必须在开发版上观察。

| 检查项 | General | Refresh（General 卡片） | Menu Bar | Menu | Advanced | About | Provider 详情 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 默认内容 880×620；宽度不能小于 800，高度不能小于有效 frame 下限（代码 540，toolbar 后实测 560） | 共享窗口 `代码`+`人工` | 同左 | 同左 | 同左 | 同左 | 同左 | 同左 |
| 浅色 / 深色跟随系统，卡片与侧栏对比可读 | `人工` | `人工` | `人工` | `人工` | `人工`（日志查看器保持深色底） | `人工` | `人工` |
| 侧栏选中态 | General 选中 `代码` | 仍为 General `代码` | Menu Bar 选中 `代码` | Menu 选中 `代码` | Advanced 选中 `代码` | About 选中 `代码` | **全部不选中** `代码` |
| 窗口缩放（绿钮） | 绿钮可见且启用 `代码` | 同左 | 同左 | 同左 | 同左 | 同左 | 同左 |
| 页面滚动 | 顶 52pt 非滚动空白，可垂直滚到卡片底部 `代码`+`人工` | 同一 General 文档内 `人工` | 同 General；FPS 恢复滚动不得抢焦点 `代码` | Status Links 超出视口时可滚到 `代码`+`人工` | 页滚动 + 日志内部滚动互不替代 `人工` | 无设置页滚动；内容居中 `代码`+`人工` | 走设置页滚动 `代码` |
| 红黄绿位置 | 系统标题栏左侧；不另做自定义拖拽排除热区 `代码`；像素位置 `人工` | 同左 | 同左 | 同左 | 同左 | 同左 | 同左 |
| 全屏 | 标准 AppKit zoom / 全屏；不再用自定义拖拽 overlay 抑制双击 `代码`+`人工` | 同左 | 同左 | 同左 | 同左 | 同左 | 同左 |
| 双击标题栏 | 标题栏命中穿透到 NSThemeFrame，遵循系统 `AppleActionOnDoubleClick`，不再自定义 `setFrame` `代码`+`人工` | 同左 | 同左 | 同左 | 同左 | 同左 | 同左 |
| 键盘 / 焦点 | 侧栏 source-list 可成为 first responder；上下方向键在五个可选项间移动 `代码`+`人工` | 间隔弹出菜单可操作 `人工` | 滑块、弹出菜单、FPS 字段 `人工` | 阈值字段、Status Links 编辑器有系统 focus ring `人工` | 日志可选中、按钮可激活 `人工` | GitHub 按钮自定义焦点描边 `代码`+`人工` | Refresh/Switch 按钮可激活 `人工` |

共享窗口行为（尺寸、绿钮、双击、红黄绿、全屏）在每一页都应相同。后续 Issue 若只改某一页内容，仍需抽查窗口外壳未变。

## 后续重构不得静默打破的代码契约

这些已有或本次新增的测试是回归闸门，不是视觉通过证明：

- `DashboardNativeUIBaselineTests`：默认尺寸、`minSize`、styleMask、透明标题栏、unified toolbar 含系统 `.flexibleSpace` / `.toggleSidebar` / `.sidebarTrackingSeparator`、绿钮启用、无全窗口 drag overlay、`NSSplitViewController` 外壳、垂直 `NSSplitView`、侧栏 `.sidebar` item 与约 216pt 打开宽度、原生 min/max/collapse/`toggleSidebar` 契约、live `DashboardContentRootView`、内容表面浅 82% / 深 20%、默认 General、Provider 清空侧栏选中、Refresh 不是 `DashboardSection`、About 无设置页 `NSScrollView`。
- `DashboardWindowControllerTests.testWindowEnablesNativeZoomAndStaysResizable`
- `DashboardWindowControllerTests.testOpenRestoresInitialSectionAndScrollThenAFreshOpenStaysOnGeneral`
- `DashboardWindowDragRegionTests`：自定义拖拽/缩放类型已退役、全窗口 drag overlay 不存在、zoom 按钮启用、标题栏 hitTest 穿透到原生 chrome
- `DashboardComponentsTests.testDashboardSectionsPreserveNavigationOrderAndMetadata`
- `SettingsSectionViewTests`：原生 section 高度由子 View 约束推导，不走 `settingsCardHeight` / 父级 preferred-height 循环；General Startup 与 Refresh 卡片已迁到原生容器。Refresh 的双 interval 行由 `DashboardRefreshBalanceUpdatesRowView` 承担，通用 `SettingsRowView` 不识别 adaptive control 类型
- `DashboardPreferencePagesTests` 中 General 卡片顺序 System → Refresh → Startup → Application
- `DashboardProviderPagesTests.testAppDelegateWiringKeepsNativeSourceListResponsiveAfterPageReplacement`
- `DashboardSourceListContractTests`：原生 outline 选中、group 鼠标点击不改 selection、键盘 ↑↓ 跳过 group、Provider 清空 selection、badge / rebuild / teardown 所有权

## 明确不在本基线内

- 不重写窗口外壳、侧栏或设置行。
- 不新增模糊/阴影，也不把现有卡片/侧栏阴影解释成「本次要改掉」。
- 不把未挂载的 `DashboardRefreshPage` / Provider Overview 当成用户可见页面。
- 不把菜单栏、状态菜单、更新说明窗口算进 Dashboard 基线。
- 实现阶段不修改 `Resources/Info.plist` 版本号。
