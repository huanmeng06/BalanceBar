# Claude Code Mod spike (BB-02 / Issue #512)

状态：实现了可审计的原型与本地无会话测试；七项真实运行验证仍需在有权使用 Claude Code 的测试配置中按下文执行。本文把官方文档推断、实现检查和运行时实测分开，不把推断写成实测。

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
| 1 | `$.session.usage()` 的接口文档形状为 `{ startedAt, context, rateLimits, cost }`；每个 rate limit 文档字段为 `kind`、`percentUsed`、`resetsAt`。实际 kind 和实际时间格式尚未确认。 | 官方 API 参考是文档证据，不是本机 Mod 输出。原型会把原始三字段放进 `mod_observation.raw_rate_limits`，同时按明显别名映射 v1 的 `windows`。 | 启动原型，完成至少一个 turn，执行 `/balancebar-mod-spike`；查看输出文件的 `mod_observation.raw_rate_limits`。记录每个 `kind` 的精确字符串、`typeof percentUsed` 与 `typeof resetsAt`。 | 部分确认；实测阻塞 |
| 2 | `session.measure` 按文档在每次 turn 后，以及 plan limit 的 percent changed 时触发；其在交互式终端、`claude -p`、Agent SDK、Desktop Code、并行会话的实际触发矩阵尚未确认。 | 官方文档说明 hooks 在 CLI、Desktop Code、VS Code、`claude -p` 和 Agent SDK 运行；是否每个目标表面都产生该事件仍需现场观测。原型仅在事件回调中增加 `measure_events`，不靠推断写快照。 | 分别执行终端、`claude -p`、Agent SDK、Desktop Code Code tab；每个会话完成 2 个 turn 后执行命令或读取显式临时 inbox，记录 `event`、`measure_events` 与 `surfaces`。并行开两个独立会话，比较各自计数。 | 部分确认；实测阻塞 |
| 3 | `$.fs.write`、`$.http.fetch` 是可用 API；对 BalanceBar inbox、`~/.claude` fallback、loopback HTTP 的权限和成功条件尚未实测。 | 官方 API 参考说明 Mod 以用户权限读写文件和发请求；这不是对本机路径的写权限承诺。原型默认不写，只有显式命令才尝试。 | 预先创建临时目录并以 `BALANCEBAR_MOD_INBOX=/tmp/...` 启动；执行 `/balancebar-mod-spike`。再在受控测试配置中测试目标 inbox、已存在的 `~/.claude/balancebar-inbox` 和 `BALANCEBAR_MOD_LOCAL_URL=http://127.0.0.1:<port>/...`；保存每次的 `write.status`、退出码和 HTTP 状态。 | API 已实现；实测阻塞 |
| 4 | 原型将观测、读取、哈希、写入全部包在捕获边界内，并始终 `next(event)`；这说明实现意图是失败不阻断，但 Claude Code 会话级实际不受影响尚未确认。 | 代码检查可证明 `session.start`/`session.measure` 的 probe 异常被吞并，不能替代真实会话。`BALANCEBAR_MOD_FORCE_FAILURE=1` 只用于制造受控错误。 | 以 `BALANCEBAR_MOD_FORCE_FAILURE=1` 启动交互会话，完成一个 turn；同时把 `BALANCEBAR_MOD_INBOX` 指向不存在或不可写目录。预期 Claude 仍可继续、命令返回 blocked、没有未处理异常。记录终端和会话日志。 | 代码层防护；实测阻塞 |
| 5 | 官方 CLI 语法为 `claude plugin marketplace add <source>`、`claude plugin install <plugin>@<marketplace>`；打开的会话可用 `/reload-plugins`，新会话自动加载。实际退出码和输出尚未在 disposable profile 中运行。 | 文档给出了子命令、scope、JSON 输出字段；本仓库不持有发布 marketplace，原型只提供本地 marketplace manifest。 | 在 disposable Claude 配置中运行 `claude plugin marketplace add ./mod-prototype --scope local --json`，再运行 `claude plugin install balancebar-mod-spike@balancebar-mods --scope local --json`；保存 stdout/stderr/退出码，打开新会话检查 `/plugin`，修改文件后检查 `/reload-plugins`。 | 命令已定稿；实测阻塞 |
| 6 | 原型只在显式命令中读取 `~/.claude.json`，仅尝试白名单字段并输出 SHA-256 哈希，不输出原值；本机文件是否存在、字段名是否稳定、是否代表账号而非组织尚未确认。 | 代码是安全边界证据；未读本机真实配置，避免泄露凭据。`oauthAccount.accountUuid` 等字段是探测候选，不是事实声明。 | 在专用测试账号中执行 `/balancebar-mod-spike`，检查 `account_probe.status` 与 `account.identity_hash`；手工确认重启/切换账号后的 hash 是否稳定且不同。不得把 `.claude.json` 原文或邮箱放入报告。 | 代码已就绪；实测阻塞 |
| 7 | 当前终端版本为 2.1.291；文档给出终端门槛 v2.1.287，Desktop Code v2.1.286。低于 v2.1.287 的终端行为没有实证。 | `claude --version` 是本机实测；版本门槛来自官方文档。没有可安全切换的旧版运行时。 | 在 v2.1.286 及更低终端上重复 #1、#2、#4、#5；若无法提供版本，记录 `not tested`，不要把 Desktop 2.1.286 的门槛外推到终端。 | 当前版本确认；旧版阻塞 |

### 不能提前写成“已验证”的项目

`docs/research/mod-spike.md` 的结论表 deliberately 保留“实测阻塞”：官方文档能确认能力和 API 形状，但没有授权在本轮自动启动真实 Claude 会话、读取用户账号文件、修改插件设置或访问网络。#510 中关于 Claude HUD `statusLine` 的 `rate_limits`/Unix 秒证据属于另一条输入路径，不能冒充 `$.session.usage()` 的实测结果。

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
