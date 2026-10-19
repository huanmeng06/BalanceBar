## BalanceBar 性能报告：`idle`

- 场景：空闲：不产生任何 transcript 写入
- 提交：`ae0a78f3`；App：`BalanceBar-dev.app`
- 时间：2026-10-18T23:51:38-04:00；macOS 26.5.1
- 环境：隔离的临时 HOME，网络沙盒，预热 15 s

| 指标 | 数值 |
| --- | --- |
| 实际采样时长 | 1804 s（358 个样本，间隔 5 s） |
| CPU 平均 / p95 / 峰值 | 0.61% / 0.66% / 17.81% |
| CPU 总时间 | 10.90 s |
| 内存 footprint 起始 / 结束 / 峰值 | 64.1 / 86.0 / 86.1 MB |
| 磁盘读取量 | 4.01 MB |
| 唤醒次数 | 8013 |
| 菜单打开耗时 | 未测量（使用 --menu 启用，需要辅助功能权限） |
| 外部网络 socket | 0（sandbox-exec 拒绝远程 IP，已验证） |
| 模拟 Claude CLI | 无（空闲场景不启动） |

> 注：`idle` 报告在 `ae0a78f3`（main `37f8d504`）上测量，当时第 1 轮 bench 修复（网络沙盒、隔离副本）已在工作区生效，后来提交为 `67f2735b`。它早于第 2 轮 Terminal 前台检查（只影响写入场景）和 main `726e2d17` 的合并。这次合并只在 `Sources/Quota/`、`Sources/UI/Quota/` 新增了尚未接入 App 的独立模块，没有删改现有代码，因此可以和下面三个在 `fb00e6dc` 上测得的写入场景报告对比。

## BalanceBar 性能报告：`single-writer`

- 场景：单会话持续写入 transcript
- 提交：`fb00e6dc`；App：`BalanceBar-dev.app`
- 时间：2026-10-19T09:57:18-04:00；macOS 26.5.1
- 环境：隔离的临时 HOME，网络沙盒，预热 15 s

| 指标 | 数值 |
| --- | --- |
| 实际采样时长 | 301 s（60 个样本，间隔 5 s） |
| CPU 平均 / p95 / 峰值 | 7.78% / 9.16% / 10.02% |
| CPU 总时间 | 23.35 s |
| 内存 footprint 起始 / 结束 / 峰值 | 62.5 / 60.8 / 62.8 MB |
| 磁盘读取量 | 0.49 MB |
| 唤醒次数 | 1617 |
| 菜单打开耗时 | 未测量（使用 --menu 启用，需要辅助功能权限） |
| 外部网络 socket | 0（sandbox-exec 拒绝远程 IP，已验证） |
| transcript 读取证据 | 59 次 / 60 个样本，按文件 [59]（atime 前进） |
| Terminal 前台样本 | 60/60（100%） |
| 模拟 Claude CLI | 运行中（临时 `claude` 进程，Terminal 置前） |

## BalanceBar 性能报告：`multi-writer`

- 场景：4 个并发写入方各写一个会话 transcript
- 提交：`fb00e6dc`；App：`BalanceBar-dev.app`
- 时间：2026-10-19T10:02:35-04:00；macOS 26.5.1
- 环境：隔离的临时 HOME，网络沙盒，预热 15 s

| 指标 | 数值 |
| --- | --- |
| 实际采样时长 | 302 s（60 个样本，间隔 5 s） |
| CPU 平均 / p95 / 峰值 | 7.63% / 8.83% / 9.76% |
| CPU 总时间 | 22.89 s |
| 内存 footprint 起始 / 结束 / 峰值 | 62.0 / 60.4 / 62.0 MB |
| 磁盘读取量 | 1.19 MB |
| 唤醒次数 | 1602 |
| 菜单打开耗时 | 未测量（使用 --menu 启用，需要辅助功能权限） |
| 外部网络 socket | 0（sandbox-exec 拒绝远程 IP，已验证） |
| transcript 读取证据 | 59 次 / 60 个样本，按文件 [59, 0, 0, 0]（atime 前进） |
| Terminal 前台样本 | 60/60（100%） |
| 模拟 Claude CLI | 运行中（临时 `claude` 进程，Terminal 置前） |

## BalanceBar 性能报告：`sleep-wake`

- 场景：模拟休眠唤醒：1 个写入方 + SIGSTOP 暂停进程后 SIGCONT 恢复
- 提交：`fb00e6dc`；App：`BalanceBar-dev.app`
- 时间：2026-10-19T10:07:53-04:00；macOS 26.5.1
- 环境：隔离的临时 HOME，网络沙盒，预热 15 s

| 指标 | 数值 |
| --- | --- |
| 实际采样时长 | 302 s（60 个样本，间隔 5 s） |
| CPU 平均 / p95 / 峰值 | 3.78% / 8.18% / 10.02% |
| CPU 总时间 | 11.35 s |
| 内存 footprint 起始 / 结束 / 峰值 | 62.0 / 61.5 / 62.2 MB |
| 磁盘读取量 | 0.20 MB |
| 唤醒次数 | 817 |
| 菜单打开耗时 | 未测量（使用 --menu 启用，需要辅助功能权限） |
| 外部网络 socket | 0（sandbox-exec 拒绝远程 IP，已验证） |
| transcript 读取证据 | 34 次 / 60 个样本，按文件 [34]（atime 前进） |
| Terminal 前台样本 | 60/60（100%） |
| 模拟 Claude CLI | 运行中（临时 `claude` 进程，Terminal 置前） |
| 休眠/唤醒周期 | 5 次（每 60 s 暂停 30 s） |
