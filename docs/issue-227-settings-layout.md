# Issue #227 Dashboard 设置布局

下面按“页面 → 栏目 → 设置项”展开，内容对应本次调整后的布局。

本次仅调整栏目归属和顺序；已有设置项标题、副标题和选项文案保持不变。新增的栏目标题统一放在九种语言资源中。

## 1. General（通用）

### 1.1 System（系统）

- CC Switch
  - 当前 Provider
  - Open CC Switch

### 1.2 Refresh（刷新）

- Balance refresh while tasks run
  - 运行中刷新间隔
  - 任务结束后继续刷新时间
- Balance information
  - Refresh Now

### 1.3 Application（应用）

- Language
- Update Channel
- Check for Updates
  - Check / Install Update
  - Ignore This Version
  - View Release Notes

## 2. Menu Bar（菜单栏）

### 2.1 Preview（预览）

- Current Layout
  - 实时菜单栏预览
- Menu bar space warning
  - 仅空间不足时显示
  - Open Settings

### 2.2 Quota & Reset（额度与重置）

- Priority quota window
  - 5-Hour Quota
  - 7-Day Quota
- Usage value
  - Percentage / API Balance
- Quota reset display
  - Remaining Time
  - Reset Time
  - Both
- Reset Countdown
  - 仅官方额度数据可用时显示

### 2.3 Icon & Task Status（图标与任务状态）

- Menu Bar Icon Display
  - Always Visible
  - Only While Running
- Hide Delay After Task
  - 仅选择 Only While Running 时显示
  - 10 seconds
  - 30 seconds
  - 1 minute
  - 2 minutes
  - 3 minutes
- Task status icon
  - 显示当前任务状态图标

- Animate the menu bar icon while a task runs

### 2.4 Layout（布局）

- Menu Bar Font Size
  - Large
  - Medium
  - Small
- Icon vertical position
- Amount vertical position
- Spacing from other menu bar icons
  - Narrow
  - Wide

## 3. Menu（菜单）

### 3.1 Balance Display（余额显示）

- Low balance warning threshold

### 3.2 Menu behavior（菜单行为）

- Quick Switch
- Keep the menu open after refresh

### 3.3 Quick links（快捷入口）

- Open Main Window
  - 始终显示，不可关闭
- Open ChatGPT
- Open CC Switch
- Open OpenCodex

### 3.4 Status Links（状态链接）

- View Status
  - 控制状态链接是否显示
- Status Links editor
  - Restore Defaults
  - Name
  - URL
  - 编辑链接
  - 删除链接
  - Add

## 4. Advanced（高级）

### 4.1 OpenCodex

- Detect Port Automatically
- Manual Port
  - 关闭自动检测时显示
- Open the OpenCodex dashboard

### 4.2 Diagnostics（诊断）

- Debug Log
  - Reload
  - Show in Finder
- Log viewer

## 5. About（关于）

- BalanceBar 图标
- BalanceBar 名称
- 版本号
- 应用说明
- GitHub

## 6. Providers（Provider 页面）

Providers 不是新的主设置栏目，而是现有的 Provider 概览/详情页面。

### 6.1 Provider Overview

- 当前 Provider
- 最近刷新时间
- Quota
- Reset
- Remaining Balance / Usage
- Progress
- Status
- Provider 列表
  - 选择 Provider
  - 切换 Provider

### 6.2 Provider Detail

#### Usage

- Remaining Balance
- Reset 信息
- Amount 信息

#### CC Switch

- Sync Status
- Refresh Now
- Switch to this provider

## 当前主导航结构

```text
Dashboard Settings
├── General
├── Menu Bar
├── Menu
├── Advanced
└── About
```

## 本次调整后的重点结构

```text
Menu Bar
├── Preview
├── Quota & Reset
├── Icon & Task Status
└── Layout

Menu
├── Balance Display
├── Menu behavior
├── Quick links
└── Status Links
```

`Status Links` 仍然属于 `Menu` 页面，没有新增独立的侧栏入口。
