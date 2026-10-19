# 后台性能基准

`bench.py` 启动一个已构建的 BalanceBar，驱动一个场景并采样，输出 Markdown 报告。仅依赖
macOS 自带 `python3` 标准库。隔离与有效性保证：

- **临时 App 副本**：bundle id 改为 `<id>.perf` 并 ad-hoc 重签名，不与正在运行的 BalanceBar 冲突，也不共享 UserDefaults。
- **临时 HOME**：不读写真实 `~/.claude`、`~/.codex`。
- **网络沙盒**：App 在 `sandbox-exec` 下运行，拒绝一切远程 IP 收发（例如启动时的 GitHub 更新检查）。只有 `/bin/ps` 不进沙盒运行：它是 setuid 程序，App 用它检测 CLI 进程。每次运行前用同一配置跑一次 `curl --noproxy '*' https://api.github.com`，必须失败。采样期间每个样本都用 `lsof -i` 检查 App，发现任何外部 socket 就中止、不写报告。
- **写入场景确实触发读取**：App 只在检测到 `claude` 进程且终端 App 在前台时读取 Claude transcript（`ActivityCoordinator`）。因此写入场景会启动一个临时 `claude` 进程（复制 `/bin/sleep`），并用 `open -b com.apple.Terminal` 把 Terminal 置前。**采样期间请保持 Terminal 在前台。** 判断依据是 transcript 的 atime：写入方只追加，不更新 atime，atime 前进就说明 App 读过文件。判定场景无效（以非零码退出、不写报告）的条件有两条：
  - 读取次数少于样本数的 1/4；
  - Terminal（`com.apple.Terminal`）在前台的样本少于 75%。每个样本用 `lsappinfo front` 检查。这条单独检查是因为 Terminal 前台过一次之后，App 会一直跟随 Claude 客户端读取 transcript，切走焦点后仍会继续，读取证据单独无法发现焦点丢失。App 只读取最新的主会话，所以多写入方场景通常集中在一个文件上。

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
| `sleep-wake` | 300 s | 1 个写入方；每 60 s 用 SIGSTOP 暂停进程 30 s 再 SIGCONT，模拟休眠唤醒 |

其他参数：`--app`（默认 `build/dev/BalanceBar-dev.app`）、`--interval`（采样间隔，默认 5 s）、
`--warmup`（启动预热，默认 15 s）、`--append`（追加到已有报告）、`--no-fake-cli`（调试：不启动临时 `claude` 进程）、
`--menu`（测量菜单打开耗时，需要给终端授予辅助功能和自动化权限）。

`--menu` 的测量方式：在同一个 JXA 进程里先预热 System Events 连接，不计时；然后在点击前记 t0，轮询到菜单出现时记 t1。
重复 5 次，报告中位数和最大值。这样 osascript 启动和连接开销不计入，但数值仍包含 AX 往返延迟。
如果点击阻塞、超时或 2 s 内没有观察到菜单，报告记为“未测量（原因）”，不给数值。不加 `--menu` 时同样记为“未测量”。
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
