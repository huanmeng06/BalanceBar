# 后台性能基准

`bench.py` 启动一个已构建的 BalanceBar，使用**隔离的临时 HOME**（不读写真实
`~/.claude`、`~/.codex`），驱动一个场景并采样，输出 Markdown 报告。仅依赖
macOS 自带 `python3` 标准库，无需网络。

## 先构建

```sh
./scripts/build.sh dev   # 产物：build/dev/BalanceBar-dev.app
```

## 一条命令生成报告

```sh
python3 scripts/perf/bench.py <场景> [--duration 秒] [--output 路径]
```

| 场景 | 默认时长 | 行为 |
| --- | --- | --- |
| `idle` | 1800 s | 空闲，不写任何 transcript |
| `single-writer` | 300 s | 1 个会话每秒追加一行 transcript |
| `multi-writer` | 300 s | 4 个并发写入方，各自一个会话 |
| `sleep-wake` | 300 s | 每 60 s 用 SIGSTOP 暂停进程 30 s 再 SIGCONT，模拟休眠唤醒 |

其他参数：`--app`（默认 `build/dev/BalanceBar-dev.app`）、`--interval`（采样间隔，默认 5 s）、
`--warmup`（启动预热，默认 15 s）、`--append`（追加到已有报告）、`--menu`（通过
System Events 点击状态栏测量菜单打开耗时，需要给终端授予辅助功能权限；不加时报告中标为“未测量”）。
默认输出 `build/perf/report.md`（不入库）。

全部场景顺序跑完（约 47 分钟）：

```sh
scripts/perf/run-all.sh build/perf/report.md
```

采样指标：CPU（平均 / p95 / 峰值，及总 CPU 时间）、内存 phys footprint、进程磁盘读取字节数
（`proc_pid_rusage`）、唤醒次数、菜单打开耗时（可选）。

## 在 PR 中附报告

1. 在 PR 分支构建 dev 版，运行与改动相关的场景（涉及后台扫描通常跑 `idle` 与 `multi-writer`）。
2. 在 PR 描述的“性能采样”小节粘贴报告内容，并与 [`Tests/Perf/baseline-main.md`](../../Tests/Perf/baseline-main.md)
   中同一场景对比，说明差异。
3. 尽量在同一台机器、同样负载下运行；数值只用于相对比较。
4. 若改动有意改变基线，可在该 PR 中用 `run-all.sh Tests/Perf/baseline-main.md` 刷新基线。
