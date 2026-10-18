# Claude Code Mod spike (BB-02 / Issue #512)

状态：已完成可用终端和 Desktop Code 环境中的人工验证；针对审查意见增加了显式 opt-in 的 headless `session.measure` 记录机制。Agent SDK、低于 v2.1.287 的终端环境和跨账号 hash 稳定性不可用/未完成，相关项目保留为阻塞。本文把官方文档推断、实现检查和运行时实测分开，不把推断写成实测。

## 范围、基线与缺失输入

- Issue：[#512](https://github.com/huanmeng06/BalanceBar/issues/512)
- 基线：`89c03c5130fbd17d4adabdaac7a8fd4568faed71` (`origin/main`)
- 原型：[`mod-prototype/`](../../mod-prototype/)
- 允许修改路径：仅 `mod-prototype/` 与本报告。
- 相关上下文：[#511 Schema v1](https://github.com/huanmeng06/BalanceBar/issues/511)、[#525 BB-14](https://github.com/huanmeng06/BalanceBar/issues/525)、[#526 BB-15](https://github.com/huanmeng06/BalanceBar/issues/526)。
- 仓库和 GitHub 代码搜索没有找到 Issue 所称的《BalanceBar · Claude 官方额度读取：需求与架构方案》或《BalanceBar · Claude 官方额度：开发 Issue 拆分》原文，也没有找到 `mod-prototype/` 的既有实现。以下“架构影响”依据 Issue 中点名的章节、#511 的 Schema 摘录以及相关 Issue；缺失原文是需要补交的验收输入。

官方参考：

- [Mods overview](https://code.claude.com/docs/en/plugins/mods/overview)
- [Create a mod](https://code.claude.com/docs/en/plugins/mods/create)
- [Mods reference](https://code.claude.com/docs/en/plugins/mods/reference)
- [Use the mods API](https://code.claude.com/docs/en/plugins/mods/api)
- [Test a mod](https://code.claude.com/docs/en/plugins/mods/test)
- [Plugin commands reference](https://code.claude.com/docs/en/plugins/cli-reference)

## 当前可验证基线

在不启动会话、不读取真实账号、不访问网络的前提下执行：

```text
$ claude --version
2.1.291 (Claude Code)
```

官方文档说明终端 Mod 使用要求为 v2.1.287 或更高；Desktop Code 自带副本从 v2.1.286 起支持。当前环境只有 2.1.291，未安装低于 v2.1.287 的可切换版本，因此旧版本项只能标为阻塞，不能推断兼容性。

## 七项结论表

| # | 结论 | 证据边界 | 可复现命令/步骤 | 当前状态 |
|---|---|---|---|---|
| 1 | 实测 `$.session.usage()` 返回 `rateLimits`；当前终端输出的 kind 为 `five_hour` / `seven_day`，`percentUsed` 为数字 `1` / `0`，`resetsAt` 为 ISO 字符串。 | 这是当前账号、当前终端会话的实测，不外推到其他账号或版本。 | 通过 `/balancebar-mod-spike` 写出的 JSON 读取 `raw_rate_limits`；对应 `windows` 保留同样 kind 和 ISO `resets_at`。 | 当前终端 PASS |
| 2 | 交互式终端、两个并行会话和 Desktop Code 均观察到 `measureEvents=2`；审查后增加 `BALANCEBAR_MOD_RECORD_MEASURE=1`，使普通 `claude -p` turn 可显式写出 `session.measure` 快照。Agent SDK 不可用/未测。 | 交互式、并行和 Desktop 结果为用户实测；headless command-only 只证明 Mod 可加载和 API 可用；新的 opt-in recorder 使 headless turn 有可观察证据。 | `BALANCEBAR_MOD_INBOX=/tmp/... BALANCEBAR_MOD_RECORD_MEASURE=1 claude -p "..." --plugin-dir ./mod-prototype`，再检查 JSON 的 `mod_observation.event=session.measure`。 | CLI/并行/Desktop PASS；headless recorder 待用户运行，Agent SDK 阻塞 |
| 3 | `$.fs.write` 在两个交互式会话、`claude -p`、安装版新会话和 Desktop Code 的默认 BalanceBar inbox 均成功。`~/.claude` fallback、loopback HTTP 未测。 | 临时目录与默认收件箱结果是实测；不能外推到 fallback 或 HTTP 服务。 | Desktop 中第一次无目标目录时为 `blocked`；创建 `~/Library/Application Support/BalanceBar/inbox/` 后再次执行得到 `write=written`。 | 临时/默认路径 PASS；fallback/HTTP 阻塞 |
| 4 | 交互式终端和 `claude -p` 中设置 `BALANCEBAR_MOD_FORCE_FAILURE=1` 后，Claude 仍正常工作；命令返回 `blocked (forced probe failure for isolation test)`。 | 这是当前 Claude Code 2.1.291 的实测。 | 故障探针命令返回 blocked，但会话没有崩溃或中断。 | PASS |
| 5 | Marketplace add/install、安装版新会话自动加载和 `/reload-plugins` 均成功。 | 用户手动 transcript 已记录 JSON 输出；审查修复要求下一次重跑同时打印 shell exit code。 | `marketplace-add` 和 `install` 均返回 `outcome=ok`；新会话显示 `1 mod active`；reload 返回 `Reloaded: 3 plugins ...`。 | 功能 PASS；独立 exit code 记录待补 |
| 6 | 显式 probe 成功生成 `identity_source=account-id` 的 SHA-256 哈希，未输出原始值；新增测试证明同一输入的 hash 确定性，但未完成跨账号/重新登录实验。 | 账号 hash 属于当前本机隐私数据，不把 hash 本身写入报告。确定性测试不等于跨账号实测。 | 检查 JSON 的 `account` 和 `account_probe`，只记录 status/source；在两个专用账号或重新登录状态下私下比较 hash，不把 hash 贴入 Issue。 | 当前账号 PASS；跨账号稳定性阻塞 |
| 7 | 当前终端版本为 2.1.291；文档给出终端门槛 v2.1.287，Desktop Code v2.1.286。低于 v2.1.287 的终端行为没有实证。 | `claude --version` 是本机实测；版本门槛来自官方文档。没有可安全切换的旧版运行时。 | 兼容策略：终端 `<2.1.287` 视为不支持，不启用 Mod、不写入快照，BB-15 应提示升级或复制命令；有旧版环境时再重复实测。 | 当前版本确认；旧版阻塞，策略已明确 |

### 用户人工记录（2026-10-18 EDT）

- 交互式终端快照：`five_hour` 的 `percentUsed=1`、`resetsAt=2026-10-18T16:10:00.000Z`；`seven_day` 的 `percentUsed=0`、`resetsAt=2026-10-25T10:00:00.000Z`；surface 为 `terminal`。
- 两个并行 CLI 会话 A/B 均得到 `rateLimits=available`、`measureEvents=2`、`account=hashed`、`write=written`，且分别写入 A/B 临时 inbox。
- `claude -p "/balancebar-mod-spike" --plugin-dir ./mod-prototype` 得到 `rateLimits=available`、`measureEvents=0`、`account=hashed`、`write=written`；这是 command-only headless 检查，不是 `session.measure` turn 触发证据。
- 交互式与 headless 故障隔离均返回 `blocked (forced probe failure for isolation test)`，会话仍继续。
- local marketplace add/install 均返回 `outcome=ok`；安装版新会话显示 `1 mod active`；`/reload-plugins` 返回 `Reloaded: 3 plugins · 2 skills · 6 agents · 0 hooks · 0 plugin MCP servers · 1 plugin LSP server`。
- Desktop Code 第二次执行在创建默认收件箱后得到 `write=written`，路径为 `~/Library/Application Support/BalanceBar/inbox/`；未记录账号 hash 原文。Agent SDK、旧版本终端和跨账号 hash 稳定性保留阻塞。
- 审查修复增加 `BALANCEBAR_MOD_RECORD_MEASURE=1`；它仅在显式启用时于 `session.measure` 写入快照，避免普通会话产生持续文件写入。当前 rework 中尚未代用户运行新的普通 headless turn。
- 用户此前手动安装 transcript 的 JSON 为 `marketplace-add`/`install` 且 `outcome=ok`；审查要求的独立 shell exit code 将在下一次命令重跑时单独记录。Worker 沙箱重跑因共享 `.claude/settings.local.json` 权限受限而得到 `error_permission`，不作为用户命令结果。

### 不能提前写成“已验证”的项目

Agent SDK 和低于 v2.1.287 的终端环境不可用，因此这些子项仍是实测阻塞；终端版本兼容策略已明确为不支持时不启用/不写入并提示升级。#510 中关于 Claude HUD `statusLine` 的 `rate_limits`/Unix 秒证据属于另一条输入路径，不能冒充 `$.session.usage()` 的实测结果。

## 快照与 #511 Schema v1 对照

原型的导出快照保留 #511 的顶层字段顺序和语义：

```json
{
  "updated_at": "<runtime ISO timestamp>",
  "five_hour": { "used_percentage": 34.0, "resets_at": "<raw value>" },
  "seven_day": { "used_percentage": 61.5, "resets_at": "<raw value>" },
  "source": "balancebar-mod",
  "account": {
    "identity_hash": "sha256:<hex>",
    "identity_source": "account-id"
  },
  "windows": [
    { "kind": "<raw kind>", "used_percentage": 34.0, "resets_at": "<raw value>" }
  ],
  "mod_observation": {
    "event": "session.measure",
    "measure_events": 1,
    "rate_limits_available": true,
    "raw_rate_limits": [
      { "kind": "<raw kind>", "percentUsed": 34.0, "resetsAt": "<raw value>" }
    ]
  }
}
```

待 BB-01 确认的偏差：

1. #511 示例使用 `account.email_hash`，但 BB-02 不应把 UUID 哈希伪装成邮箱哈希；建议正式 Schema 增加 `identity_hash` 与 `identity_source`，或明确 `email_hash` 只能在候选值确实是邮箱时使用。
2. `windows[].kind` 必须允许保留 Claude 的原始取值，不能只接受预设的 `five_hour`/`seven_day`；原型只对明显的 `5h`/`5hour`/`five_hour` 和 `7d`/`7day`/`seven_day` 别名填充顶层窗口。
3. `resetsAt` 的单位/格式必须由 #1 实测后定稿。原型暂不把数字强行解释为 Unix 秒，也不把字符串强行重写为 ISO。
4. `mod_observation` 是研究扩展，不应未经 BB-01 同意进入正式应用契约；正式 Mod 是否保留它由 BB-14 决定。缺少 `rateLimits` 时原型不合成窗口，符合 #525 的能力检测要求。

## 对架构与 BB-14 / BB-15 的影响

由于架构原文缺失，以下是待原文复核的最小清单，不是对缺失文档的臆造替代：

| 目标 | 当前建议 |
|---|---|
| “关键事实与约束”中的 Mod 行 | 增加终端/Desktop/VS Code/headless 的实际支持矩阵、版本门槛、`session.measure` 触发条件、没有 `rateLimits` 时不写文件的规则；把文档推断和运行时证据分列。 |
| “Mod 引导设计” | 明确 `claude plugin marketplace add` → `claude plugin install` → 新会话或 `/reload-plugins` 的三步引导；失败时只复制命令，不直接改 Claude 配置；说明插件以用户权限运行及信任边界。 |
| #525 BB-14 | 只有 #512 的每个场景实测为可行后再进入正式实现；正式 Mod 应订阅 `session.measure`、检测 `usage()/rateLimits`、只写邮箱/账号哈希、不让写入异常传播，并用 `claude plugin test` 覆盖能力缺失和失败写入。路径与 `resetsAt` 单位必须以本报告后续实测结果定稿。 |
| #526 BB-15 | 不要在 UI 中硬编码未经实测的安装输出；依赖 `claude` 是否存在、命令退出码和版本门槛，提供复制命令 fallback；新会话自动生效，已有会话提示 `/reload-plugins`，并明确用户确认/信任和 scope。 |

## 复现步骤（人工验收）

### 准备

- 使用 Claude Code v2.1.291 或更高的终端；需要对 Desktop Code、Agent SDK、`claude -p` 和多会话分别准备可用测试配置。
- 从仓库根目录运行 `claude plugin validate ./mod-prototype --strict` 和 `claude plugin test ./mod-prototype`。
- 对写入验证使用已经创建的临时目录；不要把真实 token、邮箱、`.claude.json` 原文或账号配置复制进报告。

### 步骤

1. `claude --plugin-dir ./mod-prototype`，确认 `/plugin` 列出 `balancebar-mod-spike`。
2. 完成一次普通 turn，执行 `/balancebar-mod-spike`；观察 summary、临时 inbox 中的 JSON，以及 `raw_rate_limits` 的 kind/类型。
3. 分别在交互式终端、`claude -p`、Agent SDK、Desktop Code Code tab、两个并行会话中重复步骤 2；记录 `measure_events` 和 `surfaces`。
4. 将 `BALANCEBAR_MOD_INBOX` 指向存在的临时目录，验证 `write.status=written`；再让该路径不存在或不可写，验证 `blocked` 而会话继续。
5. 运行 `BALANCEBAR_MOD_FORCE_FAILURE=1` 的会话，完成一个 turn；确认 probe 错误不会阻止后续提示或 turn。
6. 在 disposable profile 中执行 README 的 marketplace add/install 命令，记录实际 stdout/stderr/退出码；新会话检查自动加载，编辑原型后在旧会话运行 `/reload-plugins`。
7. 仅在专用测试账号中执行显式账号 probe，确认只出现 hash；重复登录/切换账号并记录 hash 稳定性，不收集原值。
8. 在可控的 v2.1.286 及更低终端上重复受影响步骤；没有旧版时将该项保留为阻塞。

### 预期

- `rateLimits` 不存在或不可读时，报告明确显示 unavailable，原型不合成窗口。
- 所有写入/HTTP/账号读取失败都显示 blocked 或 unavailable，Claude 会话仍可继续。
- 窗口原始 kind 和 resetsAt 原始类型可追溯；正式 Schema 调整前不做无证据单位转换。

### 不做

- 不在本 Issue 接入 BalanceBar 应用、改动 `Sources/`、修改 Claude 配置、安装到生产 profile、访问真实网络或发布原型。

## 自动化检查记录

以下记录随 Worker 交付更新；未列出的运行时项目不是 PASS：

| 命令 | 结果 |
|---|---|
| `claude --version` | PASS：`2.1.291 (Claude Code)` |
| `claude plugin validate ./mod-prototype --strict` | PASS：manifest、hooks、3 个 hooks、10 个 API 调用和 4 个环境变量读取均通过严格校验 |
| `claude plugin test ./mod-prototype` | PASS：3 tests passed, 0 failed |
| `git diff --check` | PASS |
| `./scripts/build.sh dev` | PASS：创建 `/Users/huan_meeng/.codex/worktrees/c71c/BalanceBar/build/dev/BalanceBar-dev.app`；Swift 编译有既有 unused/deprecation warnings，无错误 |
| `codesign --verify --deep --strict /Users/huan_meeng/.codex/worktrees/c71c/BalanceBar/build/dev/BalanceBar-dev.app` | PASS：ad-hoc signed development artifact verified |

## 交付边界

本 Issue 的 Draft PR 只交付原型、文档和可执行人工验证步骤。没有真实 Claude 会话/旧版运行时/专用账号测试证据时，BB-14 与 BB-15 不应把对应假设标记为“已验证”。
