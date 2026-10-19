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

> 待补：`single-writer`、`multi-writer`、`sleep-wake` 需要在桌面解锁、Terminal 处于前台时运行，之后追加到本文件。
