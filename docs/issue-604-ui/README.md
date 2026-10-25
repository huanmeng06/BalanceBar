# Issue #604：Mod 管理 UI 交付证据

当前入口是 **设置 → 高级 → Claude 实时增强**，按 INT-2 #565 的独立设置卡片恢复。参见 [高级卡片截图及本轮验收](advanced-card.md)。下方原生管理窗对比图仍适用于说明/管理窗口。

Stacked Draft PR：`codex/issue-604-mod-ui-polish` → `codex/issue-597-mod-user-install`。
基线为 PR #603 的 `882b39f2bd9fb8f94ae53e44ce23e711fd1c547e`。参考 #565 的视觉层级，未恢复其历史业务逻辑。

## 截图说明

这些是 AppKit **离屏渲染**，使用固定测试状态，非真实安装、非 GUI 人工验收。
左侧为 #603 的原 320pt 管理视图，右侧为本 PR 的 INT-2 原生管理内容（按语言测量，380–640pt）。
说明/管理窗口的本轮还原清单见 [INT-2 前端还原记录](restoration.md)。

旧渲染器来自基线原文件，仅在生成截图时临时加入测试，未保留在产品或最终测试源码中。
比较图按相同比例缩放到 1x；窗口已恢复 INT-2 的隐藏标题栏文字、可拖动背景及紧凑排布；真实系统交互与滚动区域仍需人工验收。
新 UI 的原始图、22 个状态、12 语言窄布局与确认页也保存在 XCTest 结果附件中。

| 状态 | 浅色前后 | 深色前后 |
| --- | --- | --- |
| 未安装 | [截图](compare-not-installed-light.png) | [截图](compare-not-installed-dark.png) |
| 安装中 | [截图](compare-installing-light.png) | [截图](compare-installing-dark.png) |
| 安装命令完成，等待可信数据 | [截图](compare-waiting-light.png) | [截图](compare-waiting-dark.png) |
| 正常（模拟管线已受理） | [截图](compare-normal-light.png) | [截图](compare-normal-dark.png) |
| 安装失败／网络错误 | [截图](compare-failed-light.png) | [截图](compare-failed-dark.png) |
| 卸载中 | [截图](compare-uninstalling-light.png) | [截图](compare-uninstalling-dark.png) |
| 卸载完成 | [截图](compare-uninstalled-light.png) | [截图](compare-uninstalled-dark.png) |

[浅色卸载确认](confirmation-light.png) · [深色卸载确认](confirmation-dark.png)

[12 语言浅色总览](languages-light.png) · [12 语言深色总览](languages-dark.png)

窄布局 420pt 原图：[德语浅色](german-light.png) / [深色](german-dark.png)、[俄语浅色](russian-light.png) / [深色](russian-dark.png)。
布局测试遍历 22 个状态 × 12 语言 × 2 种外观 × 3 种宽度（420/480/760pt），检查文字和按钮边界、文本高度。确认页另外覆盖所有语言及外观。
这些几何断言无法证明系统字体渲染、窗口缩放体验或 VoiceOver 顺序均符合人工预期。

## 实现边界

- Mod 单一设置入口位于高级页顶部独立卡片；状态圆点、主副文案、安装/说明/管理按钮参考 INT-2，搜索归属同步移到高级。
- 新窗口由设置窗口持有；关闭父窗口时移除子窗口，重开重建视图并继续消费原控制器。
- 安装命令完成与可信快照受理分开显示；状态只读取 `ModSyncStatus`。
- 复制命令／启用／reload 有轻量反馈，失败提供原 CLI 摘要与重试。
- 卸载必须显式再次点击；Return 默认关闭或取消，Esc 关闭管理窗，不停止后台任务。
- 未改 Installer、Inbox、Pipeline、MergeEngine、账号／周期校验、300 秒限流、statusLine、默认配置或版本。

## 如何人工测试

开发版：在本 worktree 中运行 `./scripts/build.sh dev`，产物 `build/dev/BalanceBar-dev.app`；Bundle ID 为 `com.huanmeng06.BalanceBar.dev`。签名验证命令：`codesign --verify --deep --strict build/dev/BalanceBar-dev.app`。

准备：保留现有用户配置；使用独立开发版、Claude Code ≥ 2.1.287。真实安装／卸载请使用可接受改动的测试用户环境。
公开 `owner/repo` 安装来源读取 main；#603 合入 main 前没有根 marketplace，可能按预期失败，不能把这类失败算成 UI 或管线成功。
本 UI PR 阶段优先验收界面、生命周期与错误回退；真实 CLI + Desktop Code 全闭环由组合后的 #603 继续验收。

1. 打开设置 → 高级，确认顶部只有一张「Claude 实时增强」卡片。搜索 Mod、卡片标题、管理或当前状态，应定位高级卡片；通用页刷新区保留原四行，不重复提供 Mod 入口。
2. 点击「管理…」：应用图标、标题、副标题、状态卡、四条图标说明和操作区应对齐。重复点击应复用当前窗口。切换设置页后仍可管理，关闭主窗口后不得留下子窗口；重开主窗口和管理窗应可继续使用。
3. 未安装：Return 仅在有「安装」按钮时安装；检测中、CLI 缺失或版本不支持时不应默认安装。点击复制命令应短暂显示「已复制」，粘贴内容必须保留原命令和 `--scope user`。
4. 点击安装后观察三步进度。关闭或按 Esc，然后重新打开，应保留真实进度。命令完成后只能显示当前检测状态／待可信数据；未产生并受理可信快照时不得显示实时正常。完成后关闭重开，应回到当前管理页。
5. 在可用的测试安装环境中新开 CLI 会话、再开 Desktop Code 会话，各进行一轮交互。只有现有管线接受数据后才能显示正常及最近时间。已有会话可复制 `/reload-plugins`，复制后有反馈。
6. 验证停用、10 分钟无数据、账号不匹配及周期拒绝：状态应明确说明原因并提供启用／新会话／reload／检查账号等下一步。账号切换及重装后不得沿用旧账号的正常证据。不要通过修改真实快照或配置来伪造 PASS。
7. CLI 缺失、旧版本、权限和网络失败分别应有可读说明、复制回退或重试；点击「重新检测」应调用现有检测。错误排除后重试应可以继续。
8. 已安装时点击卸载，先出现确认页。Return 应取消，Esc 应关闭，均不得开始卸载。再次点击明确的卸载按钮后才开始；关闭重开不取消进行中任务。卸载后重新打开应可再次安装。失败时复制卸载命令、重试仍需确认；statusLine 与其它插件保持原样。
9. 依次切换 12 语言，在浅色／深色、420pt 窄窗、较宽及较矮窗口检查换行、按钮、滚动和命令选择复制。动态切换外观后文字与卡片仍清晰；语言切换后重新打开管理窗。
10. 用 Tab/Shift-Tab 遍历控件；用 Return、Esc 验证默认动作。开启 VoiceOver 检查状态、进度、命令与按钮名称，确认可操作且不依赖颜色理解状态。

避免测试：菜单栏新增提示、C/扣图标、HUD、Codex、多端 Chat/Cowork、调度或估算策略、版本发布；这些均不在本 PR 范围内。

反馈：`PASS`，或 `FAIL + 失败步骤 + 实际/预期结果 + 开发版 SHA`。当前人工结果为 **待维护者验收**；PR 保持 Draft，不升级版本、不发布、不合并。
