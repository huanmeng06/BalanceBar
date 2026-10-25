# INT-2 高级卡片

Mod 的单一设置入口恢复为 **设置 → 高级 → Claude 实时增强**，位于诊断区域之前，参考 #565 的 `RealtimeBoostSettingsRows`：标准圆角设置卡、状态圆点、主副文案、安装/查看说明/管理按钮。
正常时状态和最近数据时间分行；安装/卸载中卡片显示当前步骤；失败提供查看原因及重试。安装命令完成仍不等于可信数据受理。
设置卡片的安装按钮调用现有安装控制器，同时显示现有管理窗口；管理/说明继续复用同一窗口。用户明确要求将设置区域移回高级，取代最初 Issue 指定的通用行。

旧菜单安装提示开关依赖历史菜单提示业务，本轮只恢复卡片的真实状态与操作，不重新引入该业务。

所有图片均为固定测试状态的 AppKit 离屏渲染，非真实安装或 GUI 人工 PASS。浅深色截图同时设置应用 appearance，以符合现有 Dashboard chrome 的配色来源。

| 状态 | 浅色 | 深色 |
| --- | --- | --- |
| 未安装 | [截图](advanced-not-installed-light.png) | [截图](advanced-not-installed-dark.png) |
| 安装中 | [截图](advanced-installing-light.png) | [截图](advanced-installing-dark.png) |
| 已安装待数据 | [截图](advanced-waiting-light.png) | [截图](advanced-waiting-dark.png) |
| 正常（模拟可信受理） | [截图](advanced-active-light.png) | [截图](advanced-active-dark.png) |
| 10 分钟无数据 | [截图](advanced-silent-light.png) | [截图](advanced-silent-dark.png) |
| 失败／查看原因 | [截图](advanced-failed-light.png) | [截图](advanced-failed-dark.png) |
| 卸载中 | [截图](advanced-uninstalling-light.png) | [截图](advanced-uninstalling-dark.png) |

窄卡片长文案：[德语浅色](advanced-german-narrow-light.png) / [深色](advanced-german-narrow-dark.png)、[俄语浅色](advanced-russian-narrow-light.png) / [深色](advanced-russian-narrow-dark.png)。

## 如何人工测试

开发版：本 worktree 的 `build/dev/BalanceBar-dev.app`（`com.huanmeng06.BalanceBar.dev`，已重新构建并验证签名）。

1. 打开设置 → 高级：顶部应为「Claude 实时增强」独立区域，下方仍为诊断；通用刷新中不再重复显示 Mod 行。
2. 未安装时右侧应为「一键安装 / 查看说明」；说明打开同一管理窗口。点安装应立即开始原有安装流程，同时打开进度窗口。关闭管理窗后，高级卡片继续显示真实步骤，点击管理可重新打开。
3. 命令完成但尚无可信数据时显示待数据；现有管线采纳快照后，状态变为已启用，下面独立显示最近数据时间。停用、静默、账号或周期拒绝仍使用当前真实状态。
4. 失败后点「查看原因」应打开真实错误摘要和重试；重试走原安装/卸载路径。卸载继续要求确认，Return/Esc 不直接执行危险操作。
5. 从其它设置页搜索 Mod、Claude 实时增强、当前状态或按钮文案，应定位高级卡片。切换页、清空搜索和状态异步变化后布局保持正确；完成后重开管理仍进入当前管理页。
6. 浅深色与全部 12 语言检查标题、状态、时间及按钮；重点查看德语/俄语长文案。Tab、Return、Esc 和 VoiceOver 检查仍待人工验收。

真实公开来源安装和 CLI/Desktop Code 全闭环仍由组合后的 #603 继续验收。反馈 PASS，或 FAIL + 步骤 + 实际/预期 + 开发版 SHA。
