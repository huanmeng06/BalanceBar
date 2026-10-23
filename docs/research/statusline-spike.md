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

**后续实测修正（2026-10-23）**：之后的一次 OAuth 读数是 `1792740600.483`，说明小数部分每次都可能不同。原先的“两边取整到秒再比较”在小数 ≥ 0.5 时会多出 1 秒，被判成不同周期，本地数据会被全部拒绝。现已改为 `QuotaMergeEngine.sameResetInstant`：两边相差不到 1 秒就视为同一时刻；合并引擎的 `sameCycle`、指纹匹配和冲突检测三处都使用它。相应测试用 `.6` 构造，去掉修复后会失败。

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

## BalanceBar 端到端（经用户授权，在真实 `~/.claude/settings.json` 上）

1. 先备份真实配置（sha256 `748bb77b…`，876 字节，0600）。停掉 #565 的 dev 构建，启动 #567 的 dev 构建。
2. 这次会话没有桌面操作和截图权限，没法点设置开关。所以把 #567 的 `ClaudeStatusLineInstaller.swift` 原样编译成命令行工具，依次执行 `installBundledWrapper` 和 `install()`（开关调用的就是这两个方法）；再把偏好设置 `claudeStatusLineEnabled` 设为开启并重启应用，走 `resumeClaudeStatusLineIfInstalled` 的真实路径。
3. 安装后：只有 `statusLine.command` 改变，权限 0600 不变，嵌入的原命令与备份一致；socket 在 `~/Library/Application Support/BalanceBar/run/sl.sock`（目录 0700）。
4. 不带 `--settings`、用真实配置跑一个 Claude Code 会话：dev 应用的合并状态中，5h 和 7d 都变成 `claude-statusline`、trust b；5h 从官方的 37 更新为 38，7d 为 82，重置时间与官方一致。
5. 执行 `uninstall()`：`~/.claude/settings.json` 与备份**逐字节一致**（sha256 相同、876 字节、0600），备份文件和 Helper 已删除。
6. 不抢回所有权：偏好设置仍为开启时重启应用，应用发现 Bridge 已不在配置里，把偏好设置自动改为关闭，**不修改**配置文件，也不再监听 socket。

**用户 GUI 验收（2026-10-23，由用户本人操作 #567 dev 构建）**：
- 在设置里打开开关：配置中只有 `statusLine.command` 改变，偏好设置为开启，socket 开始监听。
- 在 Claude Code 中聊天：菜单的 Claude 额度卡片显示「本地同步」，claude-hud 显示照常；应用合并状态中 5h 为 42%、7d 为 82%，均来自 `claude-statusline`。
- 关闭开关：偏好设置为关闭，配置与开启前逐字节一致（sha256 `748bb77b…`），备份、helper、socket 均已清理。
- 顺带发现：写入的命令中路径斜杠被转义成 `\/`（`JSONSerialization` 的默认行为）。JSON 合法、功能不受影响，但与用户原来的书写风格不一致，现已改为 `.withoutEscapingSlashes`。

**此前未验证（已由上面的用户 GUI 验收补齐）**：菜单界面的视觉显示（“本地同步”标签），因为没有截图权限。标签是由上面已经确认的数据状态推导出来的，这部分有单元测试覆盖，但不等于实际看过。

## 本轮没有覆盖的

- 通过设置界面点击开关、菜单里的“本地同步”标签（需要桌面操作或截图权限）。
- 账户切换（场景 G）：需要第二个账户。
- 30 分钟运行、CPU/内存与 main 对比、真实 429。
- 用量跨越重置周期时（5h 窗口到期）的表现。
