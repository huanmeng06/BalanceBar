# INT-2 Mod 前端还原清单

参考历史未合并 PR #565（`cd923e5d`）中的 Mod 视图、原生窗口和高级设置。只迁移展示结构与可兼容的交互，继续消费 #603 的当前控制器和可信状态。

## 已还原

| 部分 | 当前效果 |
| --- | --- |
| 高级设置 | 高级页顶部独立「Claude 实时增强」原生圆角卡片，状态圆点、状态/最近时间分行、安装/查看说明/管理按钮；搜索与进度实时更新 |
| 说明页 | 居中 56pt 应用图标、原版 17pt 标题、副标题、四个 30pt SF Symbols 对齐框、13/12pt 主副说明、24pt 留白与14pt间距 |
| 底部按钮 | 恢复大号原生按钮；左侧复制，右侧稍后/一键安装，默认同一行，长语言按原版方式换行；撤掉新增的大状态底色卡和双排工具栏 |
| 原生窗口 | 原版隐藏标题栏文字、可拖动背景、隐藏缩放/最小化按钮；按标题与按钮测量 380–640pt 宽度，内容变化时保持顶部位置调整高度 |
| 安装/待数据 | 原版图标化三步进度、等待新会话/可信数据页面、reload 命令块和关闭入口；关闭后操作继续 |
| 可信成功页 | 绿色大勾成功页，当前真实受理后停留2秒自动关闭；命令结束不触发成功，窗口已关不重新弹出 |
| 已安装管理 | 原版独立管理标题与状态副标题、reload 提示/命令、移除说明、左侧卸载和右侧关闭，不再重复安装说明的四条特点 |
| 失败与排查 | 原版橙色警告头、原因、最多两行 CLI 摘要、命令块与重试；10分钟静默恢复三条检查项；账号/周期拒绝继续显示当前真实原因 |
| 卸载页面 | 原版管理/卸载进度、绿色卸载成功与 reload 提示、橙色卸载失败与复制回退 |
| 命令与反馈 | 原版小圆角等宽命令块，右上固定22pt复制图标、指针/悬停/按下反馈、短暂绿色勾；保持可选中文本 |
| 多语言/键盘 | 原版标题、说明、按钮等15项补充文案复用12语言翻译；Return/Esc与长文案换行回归通过 |
| 菜单提示 | 配额卡下方蓝色提示行（INT-2）：官方 Claude 直连、Mod 确认未安装且未被关闭时显示；点击只弹独立说明窗，不打开主窗口 |

## 保留的必要差异

1. 当前账号/周期验证、可信数据受理、官方兜底和300秒限流原样保留。因此第三条说明仍为「官方兜底」，不复用旧版「不再请求 Usage API / 告别429」的承诺；覆盖文案按当前 CLI/Desktop Code 能力展示。
2. 保留本次已实现的安全卸载确认、父窗 ownership、普通窗口层级与语言布局所需的缩放/滚动。未恢复旧版全局置顶、抢焦点或孤儿窗口风险；Return 不默认卸载。
3. 菜单提示行已按 INT-2 恢复：官方 Claude 直连、Mod 确认未安装且未被关闭时，在配额卡下方显示蓝色提示；点击只弹独立说明窗，不打开主窗口。旧“在菜单中提示实时增强”开关、隐藏提示后的菜单入口和“打开高级设置”按钮仍未接回。HUD、Codex、多端、估算/调度及图标动画不在本 Mod 前端还原范围。

## 截图

[用户反馈前的真实截图](user-window-before.png)。以下新图为固定测试状态的离屏渲染，不是实机 GUI/真实 CLI 验收。

| 页面 | 浅色 | 深色 |
| --- | --- | --- |
| 说明/未安装 | [截图](int2-window-not-installed-light.png) | [截图](int2-window-not-installed-dark.png) |
| 安装中 | [截图](int2-window-installing-light.png) | [截图](int2-window-installing-dark.png) |
| 等待可信数据 | [截图](int2-window-waiting-light.png) | [截图](int2-window-waiting-dark.png) |
| 可信数据成功 | [截图](int2-window-trusted-success-light.png) | [截图](int2-window-trusted-success-dark.png) |
| 待数据时重开管理 | [截图](int2-window-waiting-management-light.png) | [截图](int2-window-waiting-management-dark.png) |
| 已安装管理 | [截图](int2-window-normal-light.png) | [截图](int2-window-normal-dark.png) |
| 静默排查 | [截图](int2-window-silent-light.png) | [截图](int2-window-silent-dark.png) |
| 已停用 | [截图](int2-window-disabled-light.png) | [截图](int2-window-disabled-dark.png) |
| 账号拒绝 | [截图](int2-window-account-rejected-light.png) | [截图](int2-window-account-rejected-dark.png) |
| 周期拒绝 | [截图](int2-window-cycle-rejected-light.png) | [截图](int2-window-cycle-rejected-dark.png) |
| 安装失败 | [截图](int2-window-failed-light.png) | [截图](int2-window-failed-dark.png) |
| 卸载中 | [截图](int2-window-uninstalling-light.png) | [截图](int2-window-uninstalling-dark.png) |
| 卸载成功 | [截图](int2-window-uninstalled-light.png) | [截图](int2-window-uninstalled-dark.png) |
| 卸载失败 | [截图](int2-window-uninstall-failed-light.png) | [截图](int2-window-uninstall-failed-dark.png) |

[安全卸载确认浅色](confirmation-light.png) / [深色](confirmation-dark.png) · [12语言浅色总览](languages-light.png) / [深色](languages-dark.png)。

## 如何人工测试

开发版：本 worktree 的 `build/dev/BalanceBar-dev.app`，Bundle ID `com.huanmeng06.BalanceBar.dev`。按 [高级卡片验收](advanced-card.md) 从设置 → 高级 → 查看说明/管理进入。

1. 对照 #565：检查小窗的标题栏、图标、标题/副标题、四条要点和单行左右分组按钮。检查 12 语言与浅深色；窄语言宽度由标题/按钮测量，长文案可换行。
2. 安装中关闭/Esc再打开应保留进度；命令完成应留在待可信数据页；受理首份可信数据才出现绿色成功页，2秒后关闭。已关闭的窗口不能重新弹出。
3. 完成后重开是管理页；复制 reload/启用/安装/卸载命令应显示勾选反馈并保留准确命令。失败时查看原因和重试可用；静默、账号或周期拒绝如实显示。
4. 卸载继续明确确认，Return默认取消；父窗口关闭不得残留子窗。检查 Tab/Shift-Tab、Return/Esc、VoiceOver、缩放与滚动。

实际 GUI、VoiceOver 与真实 CLI/Desktop Code 验收仍待维护者；反馈 PASS 或 FAIL + 步骤 + 实际/预期 + SHA。
