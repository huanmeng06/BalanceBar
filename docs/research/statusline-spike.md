# Claude Code statusLine 实机验证（Stage 1）

- 日期：2026-10-22
- Claude Code：2.1.291（终端版，`entrypoint: cli`），Claude Pro 账户
- 方法：用 `claude --settings <临时文件>` 只给本次会话挂载 statusLine，**不修改** `~/.claude/settings.json`（其中仍是用户的 claude-hud）。会话由 expect 驱动，网络经用户的 7897 代理；环境变量用 `env -i` 清理，避免继承宿主 Claude 会话的变量。
- 隐私：采集脚本只记录键名、`rate_limits` 数值，以及 `session_id`、`prompt_id` 的 sha256 前 8 位。用于逐字节对比的那一份完整输入只临时存在 `/tmp`，对比完已删除。

## 字段

| 观察 | 结果 |
|---|---|
| 首次 API 响应之前 | 没有 `rate_limits`。顶层键：`context_window, cost, cwd, effort, exceeds_200k_tokens, fast_mode, model, output_style, session_id, thinking, transcript_path, version, workspace` |
| 首次响应之后 | 同时出现 `five_hour` 和 `seven_day`，各含 `used_percentage`、`resets_at` |
| `used_percentage` | **整数**（25、26、27、80），不是小数 |
| `resets_at` | 整数 epoch 秒：5h 为 `1792740600`，7d 为 `1792922400` |
| `prompt_id` | 每次提交提示都会变；用量不变时也会变 |
| `refreshInterval: 5` | 每 5 秒重新执行一次，传入的 `rate_limits` 与上次**完全相同**（重放） |
| 权限模式切换 | 会重新执行，数据仍相同 |
| 父进程 | 命令进程的父进程是 `claude`（简单命令会被 shell 直接 exec） |

## 与官方 OAuth 读数对齐

dev 版 BalanceBar 保存的 OAuth 读数（`claude-quota-merge.json`）：

| 窗口 | OAuth `resets_at` | statusLine `resets_at` | 取整到秒后 |
|---|---|---|---|
| 5h | `1792740600.048` | `1792740600` | 一致 |
| 7d | `1792922400.048` | `1792922400` | 一致 |

OAuth 返回的时间带 48ms 小数，statusLine 给的是整数秒。`QuotaMergeEngine.sameCycle` 和 `ClaudeStatusLineSource.matchesGradeAFingerprint` 都会先把两边取整到秒再比较，所以 grade B 的同周期判定和“归属不明会话”的指纹匹配在真实数据上都成立。用量：OAuth 为 22（16 分钟前读取），statusLine 为 25，满足“grade B ≥ grade A − 2”。

**风险**：这只是一个账户、一个时间点上的结果。如果服务端以后不再在同一秒对齐（例如 OAuth 改为返回取整前的时间），指纹匹配会失效，原生同步会退化为只用官方查询。代码在这种情况下是安全降级（拒绝数据），不会显示错误额度。

## 对设计的影响

- 用量是整数，并且 `refreshInterval` 和权限切换都会重放相同数据，所以**不能**把 `prompt_id` 变化当成新证据（#567 第二轮已经去掉）。实测中，用量从 25 → 26 → 27 时才产生新证据；连续 3 条提示而用量一直是 25 时，没有新证据。
- 原生数据只在用量至少变化 1% 时更新，用量不变时由 300 秒的 OAuth 校准兜底，这符合预期。

## 透明转发（真实 claude-hud）

- 在同一份真实 statusLine 输入上，分别直接运行 claude-hud（bun）和经过 Wrapper 运行，连续 3 次 stdout、stderr、退出码**逐字节一致**（451 字节，含 ANSI 和 OSC 8 链接）。
- 真实会话的 TUI 中，经过 Wrapper 后 HUD 行显示照常。
- Wrapper 放在带空格的路径下（`/tmp/bb-spike2/bin dir/`），使用单引号写法的命令能被 Claude Code 正确执行，28 条 payload 都送到了监听器。payload 只含 `schemaVersion, sessionID, ccVersion, eventReceivedAt, fiveHour, sevenDay, promptMark`。

## 多会话

- 两个会话并行运行：各自上报 20 和 21 条，数值和重置时间完全一致，不会误判为身份冲突，也不会累加（上报的是绝对百分比）。
- 终端版会话运行期间，`~/.claude/sessions/<pid>.json` 中有 `kind: interactive`、`entrypoint: cli`、`sessionId`（与 payload 的 `sessionID` 一致）和毫秒级的 `startedAt`；会话退出后文件被删除。说明归属判断依赖的会话登记确实可用。

## 本轮没有覆盖的

- BalanceBar 应用内的端到端流程：开关安装到真实的 `~/.claude/settings.json`、菜单显示“本地同步”。需要用户授权修改真实配置，并且要先停掉正在运行的另一个 dev 构建（它们共用同一个 bundle id 和状态目录）。
- 账户切换（场景 G）：需要第二个账户。
- 30 分钟运行、CPU/内存与 main 对比、真实 429。
- 用量跨越重置周期时（5h 窗口到期）的表现。
