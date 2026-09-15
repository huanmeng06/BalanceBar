# BalanceBar 原生 macOS UI / 架构审计

审计基线：`origin/main` 的 `692c1e35890fff0669b959522e8833b78b9864a8`。

本文件只记录当前仓库的证据、公开 AppKit/SwiftUI 能力边界和可独立排期的后续建议；本 Issue 不修改 Swift、`Info.plist`、资源、构建配置或版本号，也不实现下述建议。

## 结论摘要

1. **单文件不是“不能使用原生 API”的原因。** [`BalanceBar.swift`](../work/balance-bar/BalanceBar.swift#L1-L5) 已导入 AppKit、SwiftUI 和 Foundation；代码实际创建并使用 `NSStatusItem`、`NSMenu`、`NSWindow`、`NSVisualEffectView`、`NSButton`、`NSSwitch`、`NSPopUpButton`、`NSScrollView` 和 `NSHostingView`。文件数量主要影响职责隔离、测试落点和改动安全性，不会限制 AppKit API 的可用性。
2. 当前“不像原生”的感受主要来自**手工组合的外观和交互策略**：透明全尺寸标题栏、自绘/自设约束的侧栏和卡片、菜单栏自定义布局、状态菜单中的自定义卡片、hover/cursor 追踪、窗口级点击监听，以及 AppKit 与 SwiftUI 两套布局同时维护。这些都是公开 API 可以实现的行为，但不会自动获得系统的间距、语义、焦点和辅助功能表现。
3. **公开 API 足够支撑后续改进。** 可以在不使用私有 API、反射或标题栏内部层级技巧的前提下，逐步采用 `NSWindowController`、`NSViewController`、`NSSplitViewController`、`NSTitlebarAccessoryViewController`、`NSAccessibilityProtocol` 和系统 appearance 生命周期。迁移到 Xcode 工程会改善导航、构建和调试工作流，但不会自动改变运行时 UI 行为。
4. 代码证据能确认结构和 API 使用；无法仅靠静态阅读确认 VoiceOver 树、键盘焦点顺序、不同显示器菜单栏表现、Reduce Transparency 下的最终视觉效果。这些项目在文末列为用户可验收项，没有在本 Issue 中宣称通过。

## 审计方法与范围

- 逐段阅读 `BalanceBar.swift` 中的类型、入口、状态栏、菜单、Dashboard、设置控件、SwiftUI bridge、tracking/animation 和生命周期符号。
- 用 `Info.plist` 核对 `NSPrincipalClass`、最低系统版本、bundle 标识、单实例声明和版本来源。
- 对每个结论同时给出仓库符号/行号和 Apple 公开 API 文档；无法从源码确定的运行时结论标为“待确认”。
- 不以任何闭源应用的内部实现作为事实依据，也不推荐私有 API。

## 当前结构证据

| 事实 | 证据 | 对“原生”的含义 |
| --- | --- | --- |
| 单一生产 Swift 文件 | `BalanceBar.swift` 当前 6,640 行；`AppDelegate` 覆盖约 4,437 行（[第 1,407–5,843 行](../work/balance-bar/BalanceBar.swift#L1407-L5843)） | 增加维护和测试风险，但不限制 AppKit 能力 |
| AppKit 与 SwiftUI 同时使用 | [`import AppKit`、`import SwiftUI`](../work/balance-bar/BalanceBar.swift#L1-L5)；`StatusLinksHostingView` 持有 `NSHostingView`（[第 281–329 行](../work/balance-bar/BalanceBar.swift#L281-L329)） | 两套公开 UI 工具包并存；边界需要明确，不等于非原生 |
| 原生 App 入口 | `@main BalanceBarMain` 创建 `NSApplication.shared`、设置 `AppDelegate` 并调用 `run()`（[第 5,845–5,864 行](../work/balance-bar/BalanceBar.swift#L5845-L5864)） | 不需要 Xcode 才能调用 AppKit |
| Bundle 配置 | [`Info.plist`](../work/balance-bar/Info.plist#L1-L32) 声明 `NSPrincipalClass=NSApplication`、`LSMinimumSystemVersion=14.0`、`LSMultipleInstancesProhibited=true` | 系统生命周期和最低版本已有明确入口；版本本次不改 |

## 八类系统集成点

### 1. 状态栏与菜单栏内容

**当前证据。** `AppDelegate.installStatusItem()` 通过 `NSStatusBar.system.statusItem(withLength:)` 创建 `NSStatusItem`，绑定 `statusMenu`，再由 `configureStatusItem()` 使用 `statusItem.button` 承载 `RotatingTemplateImageView`、`PassthroughView`、`MenuBarTextView` 和两个 `NSTextField`（[第 4,203–4,280 行](../work/balance-bar/BalanceBar.swift#L4203-L4280)）。`layoutStatusItem(for:)` 手工计算宽度、两行高度、icon/text 间距、padding 和光学位移（[第 4,589–4,721 行](../work/balance-bar/BalanceBar.swift#L4589-L4721)）。`verifyStatusItemAttachment` 根据按钮窗口和屏幕坐标做启发式检查，失败时移除并重新注册 status item（[第 4,292–4,345 行](../work/balance-bar/BalanceBar.swift#L4292-L4345)）。

**公开原生选项。** `NSStatusBar`/`NSStatusItem`/`NSStatusItem.button`/`NSMenu` 已是 Apple 的公开状态栏能力（[NSStatusBar](https://developer.apple.com/documentation/appkit/nsstatusbar)、[NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)）。后续可继续使用系统分配位置和 `NSStatusItem.variableLength`，只把内容布局、菜单模型和状态栏所有权移到独立 controller；不需要访问状态栏内部窗口。

**收益、风险与视觉取舍。** 保留当前 API 能保持系统菜单栏的放置、菜单弹出和模板图标着色；拆出 controller 可减少 `AppDelegate` 与刷新/动画状态的耦合。风险是两行文字、固定 16/18pt 图标槽、`menuBarHorizontalPadding` 和状态菜单宽度都可能改变现有视觉，且菜单栏空间本身受系统可用宽度影响。是否保留双行余额、icon 与数字的密度、padding 和活动旋转速度，需要用户视觉取舍。`verifyStatusItemAttachment` 是当前行为策略，不是公开 API 缺失的证据；若继续保留，重注册时序和多显示器行为必须单独验收。

### 2. 主菜单与命令路由

**当前证据。** `configureApplicationMenu()` 手工建立 `NSMenu`、Application/Edit/Window 菜单，使用 `NSApplication`、`NSWindow`、`NSText` 的公开 selector，并设置 `NSApp.mainMenu` 与 `NSApp.windowsMenu`（[第 1,877–1,965 行](../work/balance-bar/BalanceBar.swift#L1877-L1965)）。状态栏菜单由 `rebuildStatusMenu` 重建，包含 `NSMenuItem`、submenu、快捷键和一个自定义 overview `NSMenuItem.view`（[第 5,623–5,677 行](../work/balance-bar/BalanceBar.swift#L5623-L5677)；[第 5,748–5,826 行](../work/balance-bar/BalanceBar.swift#L5748-L5826)）。

**公开原生选项。** `NSApplication.mainMenu`、`NSApplication.windowsMenu`、`NSMenu`、`NSMenuItem` 和 responder/action 机制就是公开原生命令路由（[NSApplication](https://developer.apple.com/documentation/appkit/nsapplication)、[NSMenu](https://developer.apple.com/documentation/appkit/nsmenu)）。命令菜单不需要迁移到另一套 UI；后续可以只把菜单构建和可用性校验从 `AppDelegate` 抽成 `MenuBarMenuController`。

**收益、风险与视觉取舍。** 系统菜单和标准 selector 保留 Undo、Copy、Hide、Quit、Window 等 macOS 习惯，风险主要是语言切换时重建菜单、状态菜单追踪期间延迟重建以及自定义 overview 卡片与标准菜单项的语义差异。若后续追求更强的系统一致性，可把 overview 变成标准标题/状态 `NSMenuItem`，但会牺牲当前卡片式信息密度；这必须由用户选择。

### 3. Dashboard 窗口、标题栏与侧栏

**当前证据。** `showDashboard()` 创建一个程序化 `NSWindow`，使用 `.titled`、`.closable`、`.miniaturizable`、`.resizable`、`.fullSizeContentView`，隐藏标题、透明标题栏、允许背景拖动并禁用 zoom（[第 2,464–2,492 行](../work/balance-bar/BalanceBar.swift#L2464-L2492)）。`installDashboardLayout` 放置 `NSVisualEffectView`、内容 surface 和固定 216pt 侧栏（[第 2,523–2,568 行](../work/balance-bar/BalanceBar.swift#L2523-L2568)）。`makeDashboardSidebar` 再以 8/12/14/58pt 等固定 inset 建立 panel、导航分组和自定义 `DashboardNavigationRowView`；macOS 26+ 使用 `NSGlassEffectView`，否则使用 `.sidebar` 的 `NSVisualEffectView`（[第 2,584–2,673 行](../work/balance-bar/BalanceBar.swift#L2584-L2673)）。

**公开原生选项。** `NSWindow` 的 `contentLayoutGuide`/`contentLayoutRect` 可以表达标题栏下的安全内容区域；`NSTitlebarAccessoryViewController` 用于标题栏/工具栏区域的 accessory（[NSWindow](https://developer.apple.com/documentation/appkit/nswindow)、[NSTitlebarAccessoryViewController](https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller)）。窗口所有权可由 `NSWindowController` 管理，左右内容与 sidebar 可由 `NSSplitViewController`/`NSSplitViewItem` 管理（[NSWindowController](https://developer.apple.com/documentation/appkit/nswindowcontroller)、[NSSplitViewController](https://developer.apple.com/documentation/appkit/nssplitviewcontroller)）。继续使用 `NSVisualEffectView` 和公开的 `NSGlassEffectView` availability 分支也是合法选择；AppKit 的 visual effect material 应按用途选择，而不是按静态颜色猜测（[NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)）。

**收益、风险与视觉取舍。** `NSWindowController` 可以让窗口、delegate、local monitor、appearance observer 和页面生命周期有明确所有者；`NSSplitViewController` 可以减少手工处理 sidebar/content resize 的约束。风险是系统 sidebar 宽度、分隔线、titlebar inset、全屏和窗口恢复行为会变化；controller 本身不会自动产生目标视觉。当前禁用 zoom、透明标题栏、圆角、阴影和侧栏顶部 58pt 间距都属于明确视觉决策，改动前需用户确认并进行开关/关闭/重开/resize/最小化人工验收。

### 4. 设置控件与页面布局

**当前证据。** 页面使用原生 `NSSwitch`、`NSPopUpButton`、`NSSearchField`、`NSSlider`、`NSButton`、`NSTextField`、`NSScrollView`、`NSTextView` 和 `NSStackView`；例如 `makeDashboardSwitch` 设置 control identifier、target/action（[第 2,023–2,030 行](../work/balance-bar/BalanceBar.swift#L2023-L2030)），`makeIntervalPopup` 使用 `NSPopUpButton`（[第 4,142–4,157 行](../work/balance-bar/BalanceBar.swift#L4142-L4157)）。非原生观感主要来自 `makeSettingsPage`/`makeSettingsSection`/`makeSettingsRow` 的自定义 card、CALayer 圆角/阴影、固定行高和 20/34/62pt 等手工约束（[第 3,250–3,438 行](../work/balance-bar/BalanceBar.swift#L3250-L3438)）。侧栏和 provider button 还将 `focusRingType` 设为 `.none`（[第 2,694–2,703 行](../work/balance-bar/BalanceBar.swift#L2694-L2703)、[第 3,201–3,226 行](../work/balance-bar/BalanceBar.swift#L3201-L3226)）。

**公开原生选项。** 保留 AppKit 标准 controls、`NSStackView` 和 Auto Layout；只把每个页面放进 `NSViewController`，把通用 row/card 变成可测试的组件。`NSVisualEffectView` 的 `.sidebar`、`.menu`、`.underWindowBackground` 等 material 是公开选项，不应以私有层级技巧替代。

**收益、风险与视觉取舍。** 标准 controls 自带 target/action、键盘操作、焦点和基础辅助功能；controller/component 边界可降低页面重建时丢失状态的风险。自定义 card 可以保持当前圆角、阴影和密度，但会增加动态类型、不同语言、Reduce Transparency、键盘焦点 ring 与窗口缩放的验收成本。尤其是关闭 focus ring 不能静态证明键盘体验正确，应由用户决定是保留无 ring 的视觉，还是恢复系统焦点反馈。

### 5. SwiftUI bridge

**当前证据。** `StatusLinksEditorSwiftUI` 使用 `TextField`、`.textFieldStyle(.roundedBorder)`、SwiftUI `Button`、`@ObservedObject` 和 `ForEach`（[第 156–278 行](../work/balance-bar/BalanceBar.swift#L156-L278)）。`StatusLinksHostingView` 在 AppKit 中嵌入 `NSHostingView<StatusLinksEditorSwiftUI>`，以 `112 + links.count * 35` 的固定公式驱动高度，并同步祖先 card 的约束（[第 281–415 行](../work/balance-bar/BalanceBar.swift#L281-L415)）。AppKit 侧刻意避免编辑期间重建页面，以保护 focus、selection 和 insertion point（[第 2,087–2,113 行](../work/balance-bar/BalanceBar.swift#L2087-L2113)）。

**公开原生选项。** `NSHostingView` 是 Apple 明确提供的 AppKit/SwiftUI bridge，会把 SwiftUI hierarchy 放入 `NSView` 并协调事件和内容尺寸（[NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview)）。后续可以选择继续把它限制在 status-link editor，或者以 `NSHostingController` 承担整个设置页；也可以把 editor 完全改为 AppKit `NSTextField`。三者都是公开 API，不应将“使用 SwiftUI”或“使用 Xcode”直接等同于获得更原生的视觉。

**收益、风险与视觉取舍。** 当前 bridge 让 rounded-border text field、focus ring 和 appearance 适配由 SwiftUI 系统 style 负责，适合保留。风险是 AppKit 固定高度、SwiftUI intrinsic size、动画期间的 card height 和滚动锚点同时存在，导致重建、增删行、窗口 resize 需要更多状态同步。若改为单一 toolkit，布局和焦点更容易测试，但 text field 行高、按钮 glyph、padding 和增删动画都会改变，需用户视觉验收。

### 6. Hover、tracking、cursor 与动画

**当前证据。** `DashboardNavigationRowView` 和 `HoverLinkTextField` 在 `updateTrackingAreas()` 中创建/替换 `NSTrackingArea`，处理 `mouseEntered`/`mouseExited`/`mouseMoved`/`cursorUpdate`（[第 418–487 行](../work/balance-bar/BalanceBar.swift#L418-L487)、[第 711–786 行](../work/balance-bar/BalanceBar.swift#L711-L786)）。Dashboard 另注册 `NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown)` 以决定何时结束输入（[第 2,494–2,521 行](../work/balance-bar/BalanceBar.swift#L2494-L2521)）。旋转 icon、Claude thinking 和 status-link 滚动锚点使用 `Timer` 加入 main run loop；例如 60Hz scroll anchor timer 位于 [第 2,882–2,899 行](../work/balance-bar/BalanceBar.swift#L2882-L2899)。

**公开原生选项。** `NSTrackingArea`、`NSView.updateTrackingAreas()`、`NSEvent.addLocalMonitorForEvents`/`removeMonitor` 和 `NSCursor` 都是公开 AppKit 输入能力（[NSTrackingArea](https://developer.apple.com/documentation/appkit/nstrackingarea)、[NSEvent](https://developer.apple.com/documentation/appkit/nsevent)）。几何过渡可继续使用 `NSAnimationContext`、`NSView.animator()` 或公开 Core Animation，而不需要拦截标题栏内部事件。

**收益、风险与视觉取舍。** tracking area 可以随 view 几何更新，适合 sidebar hover；local monitor 可以在不改变标准事件分发的情况下提交编辑。风险是 monitor 的所有权、cursor push/pop 平衡、timer 失效、窗口关闭后残留监听以及 60Hz 约束修正都必须有明确 teardown。当前 `applicationWillTerminate` 会移除 monitor 和 timer（[第 1,679–1,694 行](../work/balance-bar/BalanceBar.swift#L1679-L1694)），但“窗口关闭后是否应立即移除/重新安装”仅凭静态代码不能判定，标为待确认。hover 颜色、下划线、pointer cursor、动画时长和增删行是否保持视觉锚点，均需用户决定。

### 7. 应用生命周期与外部系统事件

**当前证据。** `BalanceBarMain` 负责单实例检查和 `NSApplication.shared.run()`；`AppDelegate` 实现 `NSApplicationDelegate`、`NSWindowDelegate`、`NSMenuDelegate`，在 `applicationDidFinishLaunching` 中配置菜单、appearance、activation policy、Dashboard、status item、数据库 watcher、workspace observer 和 refresh timers（[第 1,407–1,677 行](../work/balance-bar/BalanceBar.swift#L1407-L1677)）。关闭窗口后通过 `windowWillClose` 把 activation policy 切回 `.accessory`，重开窗口时切回 `.regular`（[第 1,696–1,714 行](../work/balance-bar/BalanceBar.swift#L1696-L1714)、[第 2,422–2,431 行](../work/balance-bar/BalanceBar.swift#L2422-L2431)）。

**公开原生选项。** `NSApplicationDelegate` 本来就是 AppKit 的生命周期入口；Apple 也明确建议把特殊行为放入 controller，而不是让 `NSApplication` 子类承载全部逻辑（[NSApplication](https://developer.apple.com/documentation/appkit/nsapplication)）。后续可让 `AppDelegate` 只负责 composition root，把 Dashboard 交给 `NSWindowController`，把状态栏交给 status-item controller，把 observer/timer 与其拥有者绑定。外部应用激活继续使用 `NSWorkspace.didActivateApplicationNotification` 等公开通知。

**收益、风险与视觉取舍。** 结构拆分能让启动、关闭、重开、appearance、status item 和页面生命周期分别测试；不会自动改变 UI。主要风险是打破当前 `regular`/`accessory` 切换、窗口保持、数据库 watcher、活动刷新和客户端切换的时序。此处无必须的视觉取舍，但用户应在后续实现中人工确认 Dashboard 关闭后菜单栏仍在、重开能恢复、最小化/resize 不改变现有意图。

### 8. 辅助功能、appearance 与动效偏好

**当前证据。** 代码为 SF Symbol 设置了 `accessibilityDescription`，为若干按钮设置了 `toolTip`，标准 AppKit controls 保留了部分默认语义（例如 `NSSwitch`、`NSPopUpButton` 和 `NSButton`），并在 `ClaudeThinkingAnimator.start()` 中检查 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`（[第 610–625 行](../work/balance-bar/BalanceBar.swift#L610-L625)）。但源码检索未发现显式 `accessibilityLabel`、`accessibilityRole`、`accessibilityValue` 或自定义 accessibility children 的实现；自定义 row 使用透明 button 覆盖在 label/icon 之上（[第 2,685–2,735 行](../work/balance-bar/BalanceBar.swift#L2685-L2735)），`Passthrough*` view 又重写 `hitTest` 返回 `nil`（[第 86–97 行](../work/balance-bar/BalanceBar.swift#L86-L97)）。这不能单凭静态阅读判定 VoiceOver 结果，实际层级和焦点顺序为待确认。

**公开原生选项。** AppKit 标准 controls 自带基础 accessibility；自定义 `NSView` 可采用 role-based `NSAccessibilityProtocol`，或为需要的元素明确设置 `accessibilityLabel`、`accessibilityRole`、`accessibilityValue`、`accessibilityIdentifier` 和 children（[Accessibility for AppKit](https://developer.apple.com/documentation/appkit/accessibility-for-appkit)、[NSAccessibilityProtocol](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol)、[accessibilityLabel](https://developer.apple.com/documentation/appkit/nsaccessibility-c.protocol/accessibilitylabel)、[accessibilityRole](https://developer.apple.com/documentation/appkit/nsaccessibility-c.protocol/accessibilityrole)）。appearance 可用 `NSAppearance`/`effectiveAppearance`，自定义 view 可响应 `viewDidChangeEffectiveAppearance()`，而不依赖未在此审计中作为稳定契约的字符串通知（[NSAppearance](https://developer.apple.com/documentation/appkit/nsappearance)、[viewDidChangeEffectiveAppearance](https://developer.apple.com/documentation/appkit/nsview/viewdidchangeeffectiveappearance%28%29)）。Reduce Motion、Reduce Transparency、Increase Contrast 和 Differentiate Without Color 可由 `NSWorkspace` 的公开 accessibility 属性/通知处理（[NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)、[accessibilityDisplayShouldReduceMotion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion)）。

**收益、风险与视觉取舍。** 明确的 label/role/value 能把自定义 sidebar、status menu card、progress view 和链接控件变成可读、可操作的语义元素；统一 appearance 生命周期可减少 CALayer 颜色重建。风险是重复读出、不可聚焦的透明 button、缺少 selected/value 状态、透明/振动背景在 Reduce Transparency 下对比度不足，以及仅关闭动效但仍保留大幅布局动画。VoiceOver、键盘 Tab/箭头、Reduce Motion、Reduce Transparency、Increase Contrast 和不同语言/窗口尺寸必须由用户在后续实现中验收；本 Issue 不宣称这些运行时结果。

## 根因分类

| 类别 | 已有证据 | 判断 |
| --- | --- | --- |
| 单文件造成的维护困难 | `AppDelegate` 同时拥有 application/window/menu delegate、状态栏、页面 factory、控件 action、observer、timer、数据库刷新和网络刷新状态 | **真实的架构成本**：影响职责隔离、测试和改动安全；不影响 API 可用性 |
| 当前自定义实现造成的行为偏差 | 手工 titlebar/sidebar/card、固定几何、status menu 自定义 view、local event monitor、cursor/tracking、Timer scroll correction、AppKit/SwiftUI height bridge | **主要的“不原生”来源**：行为仍由公开 API 实现，但需要自行维护系统语义、焦点、appearance 和生命周期 |
| 公开 AppKit 能力边界 | 状态栏、菜单、窗口标题栏 accessory、split view、原生 controls、SwiftUI hosting、tracking 和 accessibility 都有公开 API | **没有发现必须使用私有 API 的需求**；后续应优先采用 documented API，并把未知运行时效果标成待确认 |

## 后续建议（按风险/收益排序）

| 优先级 | 独立候选 | 收益 | 风险/前置条件 |
| --- | --- | --- | --- |
| P0 | 建立 UI 语义与 appearance 复核清单：每个 custom view 都记录 accessibility label/role/value、focus、Reduce Motion/Transparency、light/dark 行为 | 低成本暴露真实“非原生”问题，减少只看截图的误判 | 需要用户做 VoiceOver、键盘和辅助功能设置验收 |
| P1 | 新增 `DashboardWindowController`，由它拥有 `NSWindow`、delegate、local monitor、appearance 处理和页面选择；`AppDelegate` 只做组合与生命周期协调 | 降低 4,437 行 AppDelegate 的跨职责耦合，便于后续测试 | 必须保持当前窗口尺寸、交通灯、activation policy、section/provider 恢复语义 |
| P1 | 新增 status-item controller，集中 `NSStatusItem`、菜单模型、菜单栏几何和活动 icon teardown | 把菜单栏空间策略与 Dashboard 解耦，减少重注册/刷新时序风险 | 需要验证多显示器、菜单栏空间不足、两行文字和状态菜单视觉 |
| P2 | 选择单一页面 toolkit：保留 SwiftUI editor 为明确边界，或将整个 status-link editor 改为 AppKit；不要继续扩大混合区域 | 减少 intrinsic-size、固定高度和滚动锚点的交叉状态 | 会改变 text field、focus ring、增删动画或 padding，必须用户确认 |
| P2 | 评估 `NSSplitViewController`/`NSWindowController`/titlebar accessory 的渐进替换 | 让窗口、侧栏和 titlebar 的系统行为有明确所有者 | 不是“换类名”即可完成；需要独立的视觉回归和状态迁移方案 |

这些建议是后续 Issue 的候选，不在本 Issue 中合并实现，也不改变版本号。

## 只能由用户视觉/交互验收的项目

本 Issue 没有 GUI 测试要求；以下清单用于后续实现完成后的人工验收边界，不能由文档或 `swiftc` 结果替代：

1. Dashboard 打开、关闭、重开、最小化、resize；标题栏交通灯、拖动区域、禁用 zoom 和侧栏 8/58pt 视觉是否符合预期。
2. 状态栏在不同屏幕/空间和空间不足时的 icon、两行数字、padding、菜单弹出位置与状态菜单卡片。
3. 键盘导航、focus ring、链接编辑时的 insertion point、sidebar 选中状态，以及 VoiceOver 对自定义 row、progress、status link 和菜单 overview 的读出。
4. Light/Dark、Reduce Motion、Reduce Transparency、Increase Contrast、Differentiate Without Color，以及中英文切换后的对比度、动效和布局。

本审计未执行上述交互，也不声称其通过；用户只需阅读本文件并确认后续优先级。

## Apple 公开 API 参考

本文只引用 Apple 公开文档：

- [NSStatusBar](https://developer.apple.com/documentation/appkit/nsstatusbar) / [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [NSApplication](https://developer.apple.com/documentation/appkit/nsapplication) / [NSMenu](https://developer.apple.com/documentation/appkit/nsmenu)
- [NSWindow](https://developer.apple.com/documentation/appkit/nswindow) / [NSTitlebarAccessoryViewController](https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller) / [NSWindowController](https://developer.apple.com/documentation/appkit/nswindowcontroller)
- [NSSplitViewController](https://developer.apple.com/documentation/appkit/nssplitviewcontroller) / [NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview) / [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview) / [NSHostingController](https://developer.apple.com/documentation/swiftui/nshostingcontroller)
- [NSTrackingArea](https://developer.apple.com/documentation/appkit/nstrackingarea) / [NSEvent](https://developer.apple.com/documentation/appkit/nsevent)
- [Accessibility for AppKit](https://developer.apple.com/documentation/appkit/accessibility-for-appkit) / [NSAccessibilityProtocol](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol)
- [NSAppearance](https://developer.apple.com/documentation/appkit/nsappearance) / [NSView.viewDidChangeEffectiveAppearance()](https://developer.apple.com/documentation/appkit/nsview/viewdidchangeeffectiveappearance%28%29) / [NSWorkspace accessibility options](https://developer.apple.com/documentation/appkit/nsworkspace)
