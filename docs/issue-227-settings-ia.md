# Issue #227 Dashboard 设置 IA 变更说明

## 基线与约束

- 复核基线：`origin/main` at `7f79efc`（Issue #223 已合并，版本为 1.2.17 / 60）。
- 本次只调整 Dashboard 设置的分组、顺序和用户可见标题；不改变偏好 key、默认值、迁移、控件类型、回调、导航目标、可访问性标识、动态显隐或业务逻辑。
- 9 个本地化资源继续使用相同的 `LocalizationKey` 集合；新增的分组标题和调整后的标题只通过资源文件提供。
- `DashboardSettingsComponents` 的卡片、行、滚动和自适应布局原语保持不变。动态行仍在原卡片内更新，以保留窄/宽窗口和隐藏行的测量行为。

## 导航和页面总览

Dashboard 主导航仍为 General（通用）、Menu Bar（菜单栏）、Menu（菜单）、Advanced（高级）和 About（关于）。侧栏的 Appearance / System 分组、页面路由和 Provider / Status Links 入口均不变。

| 页面或入口 | 旧层级 | 新层级 | 决策 |
| --- | --- | --- | --- |
| General | System、Refresh、Application | System、Refresh、Application | 页面已经按连接、刷新和应用设置分开；保持现有 #223 术语和测试契约，避免把刷新策略与应用更新混为一谈。 |
| Menu Bar | Preview、Display content、Animation、Font Size & Position | Preview、Quota & Reset、Icon & Task Status、Animation、Font Size & Position、Spacing & Width | 以用户任务拆分最拥挤的 Display content，并把宽度/间距从字体和位置中独立出来。 |
| Menu | Balance Display、Dropdown Menu、Quick links（其中混入 Status Links） | Balance Display、Menu behavior、Quick links、Status Links | 菜单行为、菜单快捷入口和状态链接是三种不同目标；编辑器与开关归入同一 Status Links 卡片。 |
| Advanced | OpenCodex、Diagnostics | OpenCodex、Diagnostics | 两块已经分别对应连接设置和诊断；保留动态端口行、日志查看器及其导航/回调。 |
| Providers | Provider Overview 或 Provider detail；Usage、CC Switch | 同一层级和术语 | Provider 详情已经按用量和 CC Switch 同步分开；不把 Provider 状态复制到通用或菜单栏页面。 |
| Status Links | 编辑器标题、Name/URL、链接行、Add、Restore Defaults | 同一编辑器，挂在 Menu 的 Status Links 卡片下 | 保留内部标题、锚点标识、编辑/新增/删除/恢复回调和动态高度。 |
| About | 应用信息、版本、说明、GitHub | 同一内容和动作 | 非设置项，不改变打开 GitHub 的行为。 |

## 逐项清单：旧分组 → 新分组

### General（通用）

| 条目 | 旧分组 → 新分组 | 归属与排序依据 | 未采用的方案 |
| --- | --- | --- | --- |
| CC Switch | System → System | Provider 连接入口，放在 General 首卡；保留当前 Provider 副标题和 Open CC Switch 按钮。 | 不移到 Providers：它是连接入口而非某个 Provider 的用量详情。 |
| Balance Updates During Tasks | Refresh → Refresh | 运行中轮询策略，排在手动刷新前，先说明持续更新时机。 | 不与 Application 合并：刷新频率和更新通道的生命周期不同。 |
| Balance Data | Refresh → Refresh | 当前 Provider 的即时刷新动作，紧随持续刷新策略。 | 不移到 Menu Bar：菜单栏预览消费结果但不拥有刷新偏好。 |
| Language | Application → Application | 全局界面语言，位于应用级设置首位。 | 不放入独立 Localization 页面：会增加导航层级。 |
| Update Channel | Application → Application | 版本通道选择，位于更新动作之前。 | 不放到 Advanced：它是普通应用偏好。 |
| Check for Updates | Application → Application | 更新检查、安装、忽略和 Release Notes 动作保持为一个动态行。 | 不拆成多个卡片：会破坏更新状态和按钮的联动语义。 |

`DashboardRefreshPage` 的 Provider fallback polling 和 Claude task status detection 是现有未挂载的辅助页面；本次不新增导航、不删除实现，并在代码盘点中作为 dormant support surface 保留。General 的动态更新、更新检查和 Release Notes 逻辑不变。

### Menu Bar（菜单栏）

新卡片顺序固定为：Preview → Quota & Reset → Icon & Task Status → Animation → Font Size & Position → Spacing & Width。

| 条目 | 旧分组 → 新分组 | 归属与排序依据 | 未采用的方案 |
| --- | --- | --- | --- |
| Current Layout | Preview → Preview | 先让用户看到设置结果；预览仍实时使用 Provider 数据。 | 不把预览复制到每个设置卡片，避免重复和高度膨胀。 |
| Menu bar space warning / Open Settings | Preview → Preview | 这是预览结果的动态异常提示，紧跟预览并保留原显隐和系统设置动作。 | 不移到 Advanced：问题发生在菜单栏布局上下文中。 |
| Priority quota window | Display content → Quota & Reset | 决定优先显示 5-hour 或 7-day quota，是额度展示入口，排在重置显示前。 | 不放到 Providers：这是菜单栏展示偏好，不是 Provider 数据源偏好。 |
| Quota reset display | Display content → Quota & Reset | 与额度窗口选择连续，负责剩余时长/重置时间的展示形式。 | 不与 Preview 合并：它是可持久化的展示选择，不是预览控件。 |
| Usage value | Display content → Quota & Reset | 决定菜单栏显示百分比或 API balance，属于额度结果的显示开关。 | 不放入 Icon & Task Status：它控制数值而非图标/任务状态。 |
| Reset Countdown | Display content → Quota & Reset | 与额度和重置相关，且仍保留“仅官方额度可用时显示”的副标题。 | 不单独建 Reset 卡片：单行卡片增加滚动成本。 |
| Icon display mode | Display content → Icon & Task Status | 控制图标始终显示或仅任务运行时显示；标题去掉重复的“Menu Bar”上下文，保持语义不变。 | 不与 Animation 合并：显示条件和动画效果是两个独立偏好。 |
| Hide Delay After Task | Display content → Icon & Task Status | 仅在 Only While Running 下可见的条件行，紧随显示模式，保持动态分隔线和卡片内高度更新。 | 不把条件行放到单独卡片：会造成模式与其依赖项分离。 |
| Task status icon | Display content → Icon & Task Status | 与图标显示条件相邻，说明是否显示当前任务状态图标。 | 不放入 Quota & Reset：任务状态不依赖额度数据。 |
| Animate the menu bar icon while a task runs | Animation → Animation | 任务运行时视觉反馈，单独保留以避免与显示条件混淆。 | 不并入 Icon & Task Status：动画是效果，不是是否显示/显示内容。 |
| Menu Bar Font Size | Font Size & Position → Font Size & Position | 先设置文字尺寸，再设置两个垂直位置，符合排版调整顺序。 | 不把字体单独成卡：与位置同属排版任务。 |
| Icon vertical position | Font Size & Position → Font Size & Position | 图标纵向微调，跟随字号。 | 不放入 Icon & Task Status：这是几何调整，不是显示语义。 |
| Amount vertical position | Font Size & Position → Font Size & Position | 数值纵向微调，紧随图标位置，保持预览与摘要更新。 | 不放入 Quota & Reset：调整的是几何位置，不是额度结果。 |
| Spacing from other menu bar icons | Font Size & Position → Spacing & Width | 宽度/间距是独立的布局目标；移到末卡后不再让“Font Size & Position”承担宽度语义。 | 不与两个 Y 轴滑块合并：横向间距与垂直定位的操作意图不同。 |

所有菜单栏条目仍使用原来的 preferences、控件 identifier 和 relay action。`iconDisplayDelayRow` 仍属于同一动态卡片，隐藏时只折叠其后分隔线；preview overflow row 仍由 status-item visibility 驱动。

### Menu（菜单）

| 条目 | 旧分组 → 新分组 | 归属与排序依据 | 未采用的方案 |
| --- | --- | --- | --- |
| Low balance warning threshold | Balance Display → Balance Display | 余额警示阈值独立于菜单项目，保留输入校验和持久化。 | 不放到 Menu behavior：它改变余额警示结果，不是菜单结构。 |
| Quick Switch | Dropdown Menu → Menu behavior | 菜单内的 Provider 快速切换行为。 | 不放到 Quick links：它不是打开外部窗口的链接。 |
| Keep the menu open after refresh | Dropdown Menu → Menu behavior | 菜单刷新后的生命周期行为，和 Quick Switch 同卡。 | 不放到 General Refresh：它只决定菜单交互结果。 |
| Open Main Window | Quick links → Quick links | 固定存在的 BalanceBar 入口，排在快捷入口首位。 | 不移除或变为可选：原行为要求始终显示。 |
| Open ChatGPT | Quick links → Quick links | 外部应用入口，按现有顺序保留。 | 不与 OpenCodex 合并：两个目标和动作不同。 |
| Open CC Switch | Quick links → Quick links | 外部应用入口，按现有顺序保留。 | 不移到 General：这里控制菜单中是否显示入口。 |
| Open OpenCodex | Quick links → Quick links | 外部控制台入口，按现有顺序保留。 | 不移到 Advanced：Advanced 配置连接，Menu 控制菜单入口。 |
| View Status | Quick links → Status Links | 状态服务链接开关与其编辑器同卡，用户可直接理解开关影响的内容。 | 不继续留在 Quick links：会把外部窗口快捷入口和可编辑服务列表混在一起。 |
| Status Links editor | Quick links → Status Links | 始终保留一个 editor 实例；开关显隐只改变高度/透明度并保持滚动锚点。 | 不新建窗口或独立导航页：会改变现有编辑语义和导航结构。 |

### Advanced、Providers、Status Links、About

这些页面没有发现会妨碍扫描的混杂分组，因此旧分组与新分组保持一致。清单如下，作为“未遗漏现有条目”的基线：

- Advanced / OpenCodex：Detect Port Automatically、Manual Port（自动模式隐藏）、Open the OpenCodex dashboard；Advanced / Diagnostics：Debug Log（Reload、Show in Finder）和内嵌 log viewer。
- Providers overview：当前 Provider/刷新时间、quota/reset/amount/progress/status，以及 Providers 列表中每个 Provider 的选择或切换入口。
- Provider detail：Usage / Remaining Balance（含 reset 文案和 amount），CC Switch / Sync Status（含 Refresh Now 或 Switch to this provider）。
- Status Links editor：Status Links 标题、Restore Defaults、Name 列、URL 列、每条链接的编辑/删除控件、Add。
- About：BalanceBar 图标、名称、版本、描述和 GitHub 按钮。

Provider、Claude、更新、Release Notes、OpenCodex、status links 和日志相关入口均保持原页面/子页面归属，避免跨页面重复控制同一业务。

## 备选方案与取舍

1. 保留一个七行 `Display content` 大卡：实现改动最小，但 quota、图标、任务状态和显示开关仍需逐行辨认，未满足“按任务查找”。
2. 为每个菜单栏开关新增顶层导航：查找更直接，但会改变 General/Menu Bar 层级和导航契约，超出本 Issue 范围。
3. 把 Animation 合并进 Icon & Task Status：两者都提到图标，但一个是视觉效果、一个是显隐/任务状态，合并会造成语义歧义。
4. 把 Status Links 编辑器移到单独导航页：可获得更多空间，却改变现有 Menu 入口、动态显隐、滚动锚点和用户路径。
5. 删除编辑器内部标题以避免外层 Status Links 重复：会破坏 `statusLinks.title.anchor` / `statusLinks.header.anchor` 以及辅助定位契约，因此保留内部标题。

## 验证范围

- `localization-resource-probe.sh`：九种语言键集合一致，新增/调整标题无 Swift 硬编码。
- Dashboard preference/components/layout XCTest：验证新卡片顺序、动态隐藏行、长文案宽/窄布局、预览/overflow、Status Links 动态高度和滚动锚点。
- preference persistence/migration XCTest：验证所有原有 key、默认值、回调和重新构建后的选择保持不变。
- production build、dev build、`git diff --check`；手工检查 dev app 的九语种页面和窄/宽窗口。
- 若标准 XCTest runner 受 LaunchServices 或无 GUI 会话阻塞，在交付回执中记录原始命令和阻塞原因，不将其标记为通过。

实现阶段不修改版本文件，不合并，不部署；版本升号仅在 Scheduler 审核和手工 PASS 后按 Issue 合同执行。
