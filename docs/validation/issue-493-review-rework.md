# PR #506: device-local Quick Switch safety (review baseline 8fb97e76)

This section supersedes the older database-zero unlock rules recorded below.
`proxy_config.enabled` is a synchronized setting, not device-mode authority.
Neither enabled=0, empty backups, absent schema nor the UI absence timeout
independently authorizes a write or clears an observed-proxy protection marker.

## Block disposition

| Review item | Current implementation |
| --- | --- |
| Block 1 / P0 | Shared typed decision: verified direct, verified legacy direct, protected aggregation, protected routing, untrusted. Reads local mode plus effective Codex route/auth strategy; database signals are auxiliary. Proxy observations persist under a path/client-scoped hashed key. Only consistent local direct evidence releases historical protection. |
| Block 2 / P1 | Rechecks at request start, immediately before termination, after exit, and inside the repository write transaction. Captures current/target revisions, rejects stale client/target, stages file contents, verifies fingerprints before publishing/pointer changes, and conditionally restores only files still matching this transaction's bytes. |
| Native menu | Quick Switch submenu disables AppKit auto-enabling; all protected Provider actions/targets are removed and native disabled styling covers the name plus summary. Parent remains expandable, disabled status hint remains, separate enabled management action opens CCS. Updates reconcile only the submenu. |

Valid local proxy is protected whether stack is on/off or attached is true/false.
Missing files and missing Codex nodes share the same fallback. A legacy direct
allowance requires readable database, no positive proxy evidence/history, and
live routing/credential evidence matching the current direct Provider. Synced
enabled=1 cannot permanently lock a consistent explicit direct state.

The route reader intentionally accepts an unambiguous single-line TOML routing
subset. Profiles, inline/dotted route declarations, multiline strings, or other
unsupported routing syntax cannot be assumed direct: Quick Switch remains
protected and offers the CCS management action. Ordinary MCP/project sections
and normal official token refresh do not determine routing. Keys/configuration
contents are neither logged nor persisted in safety state. Only a Boolean proxy
observation and hashed local-scope key persist.

Process-control tests inject a fake runtime. A denied termination never counts
as a stopped instance, and an already replaced/running instance is not blindly
reopened. There is no shared cross-process lock with CCS: repeated guards and
fingerprint recovery address the reviewed windows, not a mathematical guarantee
against every external write between a check and publication. No private Tauri
invocation, route-database edit or process freezing was introduced.

## Final local verification

- Final affected classes: **355 tests / 0 failures**. Classes:
  CCSwitchRepositoryTests, ProviderRefreshCoordinatorTests, StatusItemControllerTests,
  AppDelegateCompositionTests, DomainModelsTests, LocalizationTests.
  Log `/private/tmp/issue493-safety-focused-delivery.log`.
- Final complete serial XCTest: **1456 total / 1455 passed / 1 skipped / 0 failed**.
  Log `/private/tmp/issue493-safety-full-delivery.log`; result bundle
  `Test-BalanceBar-2026.10.16_10-29-05--0400.xcresult` in the dedicated DerivedData.
  The previous UpdateTests exception did not recur in this final run. This does
  not establish that its unrelated intermittent behavior has been fixed.
- Final explicit unsigned Debug build PASS:
  `/private/tmp/issue493-safety-debug-delivery.log`.
- Localization (525 keys / 12 languages), balance-query, network-error localization,
  balance-card layout and menu-bar geometry probes all PASS. Diff check PASS.
- Dedicated DerivedData: `/private/tmp/BalanceBar-issue493-proxy-state-full-DerivedData`.
  Command: `xcodebuild test -project BalanceBar.xcodeproj -scheme BalanceBar
  -configuration Debug -derivedDataPath <above> -destination 'platform=macOS,arch=arm64'
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -parallel-testing-enabled NO`.
- Initial focused runs exposed obsolete direct fixtures (direct+attached), the
  old route-mode allowance, and a transient fixture SQLite disk-I/O error. The
  direct fixture/expectations were corrected to the agreed contract; mutation,
  fingerprint and process side-effect assertions remain. Intermediate all-suite
  passes (1453 then 1455 tests) preceded additional boundary regressions and are
  not substituted for the final 1456-test result above.
- Draft Scope/Fast and exact Dev artifact identities are recorded in the GitHub
  handoff after committing. Hosted Ready Full, GUI, CPU and white-screen P0 remain
  pending; local Full and native menu tests do not replace manual acceptance.

## 如何人工测试（本轮）

开发包：原工作树 `build/dev/BalanceBar-dev.app`，交接记录最终内嵌 SHA。
由用户退出旧 Dev，再打开新包；不要手动改生产数据库、凭据或制造进程故障。

1. CCS Codex 聚合：展开 Quick Switch，顶部提示不可点，全部供应商与右侧摘要
   均为原生灰色，鼠标/键盘不能选择；“在 CC Switch 中管理”可以打开 CCS。
2. 普通路由模式同样保护并引导 CCS，状态文案明确为路由，不误标聚合。
3. 经 CCS 正常退出代理回到直连，配置一致后恢复原供应商动作和当前勾选。
4. 反复开关菜单、刷新摘要、在 CCS 调整排序；保护不能被重建或自动验证覆盖。
   聚合顶部宿主、卡片与两层滚动保持，不因置灰重建聚合视图。
5. 自动化临时 fixture 覆盖缺状态、读忙、代理/直连冲突与时序变化；真实 GUI
   不需要手工破坏状态文件。实际白屏、动画、CPU 和 Ready Full 仍单独待验收。

反馈 PASS + SHA + 范围，或 FAIL + 步骤 + 实际/预期 + 日志。

---

## Historical validation records (superseded safety semantics)

# Issue #493 / PR #506: identity and grouping follow-up

Review baseline: `6e7b3578fb60e79406156c7f861d397cdaabd1f0`.
This round keeps the original worktree, branch and Draft PR. No version change,
merge, new Issue/task, independent review or interactive GUI test is included.

## Follow-up disposition

| Item | Implementation / evidence |
| --- | --- |
| B1 | A newly added same-name, same-currency member inherits the sole existing partition. Already-split groups keep their identities, and the newcomer stays separate until two aligned rounds confirm a new partition. |
| B2 | Standard balance/official fetches capture `configurationRevision`, cancel the previous in-flight request for that Provider, and drop late results before ledger, notification, cache, Quick Switch summary and render. |
| B3 | Balance snapshot cache keys include `configurationRevision`. An error for a new key cannot reuse the previous account's cached amount. |
| B4 | Deleted sources notify and drop their Quick Switch summaries. A changed configuration revision drops the old payload silently, then a failed replacement fetch keeps it cleared. Cadence reset and name-only events do not wake waiters before the new result. |
| B5 | Direct-card identity/notes use the current CC Switch choice, not the last successful snapshot. |
| B6 | Split confirmation uses each member's own refresh window instead of a shared 30-second span. |
| B7 | After known aggregation, a missing state file or missing `apps.codex` can downgrade the UI to stable inactive after the confirmation window, but Quick Switch write protection remains until direct/ordinary mode or explicit inactive proxy evidence is verified. |

Local verification for this follow-up used `/private/tmp/BalanceBar-Issue493-DerivedData`.

- Focused identity/cadence tests: 7/7 PASS (`/private/tmp/issue493-block-fix2.log`).
- Broader classes: ProviderRefreshCoordinatorTests, CCSwitchRepositoryTests, DomainModelsTests, StatusItemControllerTests, 228/228 PASS (`/private/tmp/issue493-block-broader2.log`).
- Unsigned Debug build PASS (`/private/tmp/issue493-debug-build.log`).
- Localization probes PASS (521 keys / 12 languages).
- Full serial XCTest: **1438 / 1 skip / 0 failures** (`/private/tmp/issue493-full-serial2.log`). An earlier full run had a 0.02s deferred-rebuild flake; the isolated method and this rerun both passed.


# Issue #493 / PR #506: data and lifecycle rework

Review baseline: `00aa44828aa62164b1b43dacc7e7a0e576c169dd`.
The original worktree, branch and Draft PR are retained. No version change,
merge, new Issue/task, independent review or interactive GUI test is included.

## Review disposition

| Item | Implementation / evidence |
| --- | --- |
| B1 | Untrusted reads retain trusted members, cached amounts and switch protection; only confirmed inactive clears membership. Responses cannot publish against an unverified read. One owner-queue retry resumes refresh after a consistent read. Real SQLite exclusive lock, corrupt JSON, missing state and automatic recovery tests cover this. |
| B2 | Codex ledger keys include Provider ID and full authenticated query identity. Visual name/currency grouping does not share histories. The menu uses two aligned successful rounds before repartitioning; failed/loading samples preserve the partition. Member-set/configuration identity prevents split cards inheriting other members' views. Partial failure appears in the group's warning and tooltip with the affected member. |
| B3 | Menu-bar default selection and change comparison find the `.default` role, independently of array/display order. Tests include members preceding the default. |
| B4 | Both balance publication paths check `Observation.accepted`. A rejected sample does not publish, notify or advance displayed time. Discarded aggregation attempts release their concurrency slot. |
| B5 | Product-owner exception: after explicitly resolving the review's conflict with the latest request, retain the shared “since last top-up” subtitle and time bubble for both the initial baseline and real increases. This remains a display convention; no synthetic recharge event is written to the ledger. |
| B6 | Menu input reads published notes/identity caches only. The injectable metadata reader performs SQLite reads on a utility queue. Lock failure preserves the published cache; no extra summary-source query is made for direct notes while aggregation is displayed. |
| B7 | Credit-list tasks share the frozen official request context and cancellation key. The registry generation prevents a late old completion removing a replacement task. Cancellation observes URLProtocol `stopLoading`; existing late credit/account regressions remain. |
| B8 | Direct numeric scope includes client and Provider ID; identical service names no longer share numeric identities. |
| B9 | Summary payload keys are `(client, Provider ID)`. A composite-key database fixture tests identical IDs in Codex and Claude. |
| B10 | Metadata delivery is latest-request-wins, with the request generation reserved before background I/O. Old completions and failed reads cannot clear/overwrite newer metadata. Dashboard search refreshes on semantic cache changes. |

## Grouping evidence policy

- Exact nonblank names; case and whitespace remain significant. Official cards
  are independent. Currencies are separate, and balance equality uses integer cents.
- A confirmation round requires all peers to be successful/fresh, every peer to
  have a new fetched timestamp, and each sample to remain within its own refresh
  window (`max(intervalMinutes * 60, 120)` seconds). There is no shared 30-second
  span across members. Repaints do not advance confirmation.
- Two rounds agreeing on the same member partition confirm a split or remerge.
  A three-member group may become a pair plus a singleton. Amounts are selected,
  never summed. Existing order, member notes and each split member's website remain.
- Confirmation state is presentation-only and not persisted. API requests,
  notifications and ledger records retain Provider identity. No extra balance
  requests are added for grouping confirmation.

## History and compatibility

Unknown legacy name-shared records are retained in storage but not assigned to
new Provider-owned scopes. The original API query/credentials are not recoverable
from a name-only key. A new scope establishes a live baseline without inventing
recharge amount/time. Verifiable Provider-owned records survive restart and
renaming; different credentials/parsing or Provider IDs start separate scopes.
Old CNY recharge history previously reported missing is **not recovered**.

A state file never observed on legacy CCS remains compatible with direct mode.
After known aggregation, temporary missing/partial state cannot enable switching.
Negative balances return an explicit invalid-data result rather than becoming zero.
Quick Switch remains reconciled in place; native menu mount/scroll tests and
per-Provider notification identity tests remain in the full suite.

## Validation

Final unsigned Debug build and complete serial XCTest: **1,431 executed,
one skipped, zero failures** (174.9 seconds). Command:

```sh
xcodebuild test -project BalanceBar.xcodeproj -scheme BalanceBar \
  -configuration Debug \
  -derivedDataPath /private/tmp/BalanceBar-Issue493-unified-direct2-DerivedData \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -parallel-testing-enabled NO
```

Log: `/private/tmp/issue493-review-full-final.log`. The two final incremental
cases cover legacy direct fallback and automatic recovery without manual refresh.

The first full run had 1,428 tests, one skip and two failures: the runtime search
fixture assumed a synchronous metadata cache, and the localization test still
expected 519 keys instead of 521. Cache-driven page refresh, asynchronous fixture
waiting and the count were corrected. A subsequent compile identified missing
`Equatable` conformance on `ProviderChoice`; value equality now also avoids
unnecessary metadata-driven refreshes. The next full run passed 1,429 tests with
one skip and zero failures. Final incremental boundary tests are included in the
final result above. Earlier focused failures tied to obsolete name-shared ledger,
first-array-element default and unchanged-member-set assertions were replaced by
new-contract identity/notification/membership assertions, not suppressed.

Probes: balance layout, localization resource parity (521 keys / 12 languages),
balance-query and network-error localization. The balance layout probe now
extracts `balanceHeaderGap`; its timestamp/amount-frame assertion covers the
actual two-line production profiles. Legacy one-line helper bounds/slots remain
checked and its baseline fallback has separate controller XCTest coverage. This
probe adjustment is not a claim that production geometry was changed.

Ready Full CI, real GUI, CPU comparison and white-screen P0 acceptance remain
pending. Local XCTest and Fast CI are not substitutes for those gates.

## 如何人工测试

开发包为本工作树的 `build/dev/BalanceBar-dev.app`；交接评论记录精确 HEAD，
启动前退出旧 Dev 并核对内嵌 SHA。

1. 同名同币种同余额显示一份余额和各成员 TAG；改变其中一成员余额，在两轮
   有效对齐刷新后应拆分，分别保持自己的余额、TAG、网址和进度；再次一致并
   确认两轮后恢复合并。不同币种立即分卡，三个成员的“二同一异”应为两张。
2. 断网、局部失败、状态原子替换或数据库临时繁忙时，原可信卡片和切换保护保留，
   时间区域有警示；恢复后不点人工刷新也应恢复。明确切回直连后正常退出聚合。
3. 默认路由不在成员首位、拖动排序、切换默认、增删成员和更改备注时，菜单栏
   主值来自真正默认项，顶部菜单宿主保持，标题网址和 TAG 对应所属成员。
4. 修改 Key/实际账户后不得继承其他账户充值历史；普通改名不伪造充值。初始
   基线仍按用户选定规则显示“自上次充值已用”，气泡展示其基线起点。
5. 官方账号在二级重置卡请求期间移除/更换后，旧请求应停止且不覆盖新状态。
   检查直连/聚合官方卡、重置卡、长列表、内外滚动、深浅色、多语言及悬浮气泡。
6. 复测此前白屏路径，记录对应日志、内嵌 SHA、截图/视频及 CPU/滚动实际表现。

人工状态 PENDING；反馈 PASS 或 FAIL + 步骤和实际/预期结果。
# Issue #493 / PR #506: final identity and write-protection follow-up

Review baseline: `ed5db9bb7472fbad4136932ff47dee5b8728e6b2`.
This round keeps the original worktree, branch and Draft PR. No version change,
merge, new Issue/task, independent review or interactive GUI test is included.

## Final Block disposition

| Item | Implementation / evidence |
| --- | --- |
| Block 1 | Missing-state timeout can hide stale aggregation cards after 3 seconds, but it no longer clears the independent Quick Switch write-protection flag. Only a verified direct/ordinary state or explicitly inactive database proxy evidence releases protection. |
| Block 2 | `clientSnapshots` now stores `configurationRevision`; client switching reuses a cached snapshot only when client, Provider ID, and revision all match. |
| Block 3 | A non-current response must still match the Provider's current database configuration revision before it may update Quick Switch summaries. Database read failure is treated as invalid, not as a provider switch. |
| Block 4 | Configuration-revision invalidation now publishes `quickSwitchSummaryChanged` when an existing summary is removed, so an open menu clears stale text immediately. |

Focused verification:

- Affected repository/refresh classes: **86 / 0 failures** (`/private/tmp/issue493-blocks4-focused-final3.log`).
- Direct Block regression cases: **3 / 0 failures** (`/private/tmp/issue493-blocks4-focused2.log`).
- Targeted Debug compilation: PASS (`/private/tmp/issue493-blocks4-build2.log`).

# Issue #493 / PR #506: latest boundary follow-up

Review baseline: `0b805178e164638ec96604e7e81935035573e0a3`.

| Block | Implementation / evidence |
| --- | --- |
| 1 | Client switching clears mismatched provider/account/website state and renders `Snapshot.placeholder` immediately. |
| 2 | Confirmed state-file absence is sticky; repeated reads remain `.inactive` until valid aggregation state returns. |
| 3 | Official and third-party Quick Switch callbacks validate tracked and database configuration revisions before changing summaries or notifications. |
| 4 | Cold-start missing-state protection consults proxy takeover evidence; active or unavailable evidence blocks writes, explicit inactive evidence preserves direct-mode compatibility. |
| 5 | Configuration-revision SQLite reads close non-null handles on open failure. |

Verification:

- Affected classes: **137 / 0 failures** (`/private/tmp/issue493-boundaries-focused-final.log`).
- Broader domain/menu classes: **191 / 0 failures** (`/private/tmp/issue493-boundaries-broader.log`).
- New official stale-response and cold-start regressions: **2 / 0 failures** (`/private/tmp/issue493-boundaries-officialtest3.log`, `/private/tmp/issue493-boundaries-newtests.log`).
- Full serial XCTest: one unrelated transient `UpdateTests` failure; the exact test rerun passed (`/private/tmp/issue493-boundaries-full.log`, `/private/tmp/issue493-update-rerun.log`).
- Localization, balance query, network-error, balance-card layout and menu-bar geometry probes all PASS.


# PR #506: unified proxy evidence and cold-start protection

Review baseline: `4b3208796839856acd4f2a25ae585f28a52406cb`.

- `proxy_config.enabled` takes precedence over the retired takeover field;
  `enabled = 1, live_takeover_active = 0` is active. The retired field is read
  only when the enabled column is absent. A matching `proxy_live_backup` also
  establishes active evidence.
- A readable database without either proxy table is legacy inactive. Existing
  but incomplete schema, failed reads and exclusive locks are unavailable.
  SQLite handles and statements are released on failure as well as success.
- Missing files and missing `apps.codex` share the database evidence path, both
  when loading UI state and immediately before a Quick Switch write.
- Active/unavailable evidence blocks writes even at cold start. After the
  confirmation window the UI may remain inactive; that timeout never releases
  write protection. Explicit inactive database evidence clears historical
  protection and absence tracking on the same repository instance.
- The existing valid direct/ordinary-state path remains authoritative. No
  balance, layout, grouping, menu-host or version logic changed.

## 如何人工测试（本轮增量）

开发版：原工作树 `build/dev/BalanceBar-dev.app`。交接记录精确内嵌 SHA。
先退出旧 Dev，再由用户启动新包；不要改动真实凭据或手工编辑生产数据库。

1. CC Switch 保持代理接管、聚合开启；若状态文件暂时不可用或未提供 Codex
   节点，BalanceBar 可在确认窗口后降级 UI，但 Quick Switch 必须继续拒绝
   写入，不能修改供应商指针、停止 CC Switch 或改写路由。
2. 在 CC Switch 正常退出代理接管后，若数据库已明确 inactive，即使状态文件
   仍缺失，后续 Quick Switch 应恢复。旧版没有代理 schema 的直连库也可使用。
3. 数据库暂时锁定/不可读时仍拒绝 Quick Switch；恢复可读且明确 inactive 后
   解除保护。再次开启聚合并恢复有效状态后，聚合卡片应正常返回。
4. 聚合正常时检查直连切换保护；明确切回普通/直连模式后检查原切换流程。

人工 PENDING；反馈 PASS + SHA + 范围，或 FAIL + 步骤 + 实际/预期。
真实 GUI、CPU 对比、白屏 P0 和 Ready Full CI 均仍待单独验收。


## 本轮实际自动验证

- 五个要求的相关 XCTest 类：284 项，0 failures，日志
  `/private/tmp/issue493-proxy-final-focused.log`。
- 完整串行 XCTest：**1445 项，1443 passed，1 skipped，1 failed**。
  失败为 `UpdateTests.testUpdateServiceReportsLatestForOlderReleaseAndIgnoresDraftOrPrerelease`，
  更新服务创建 URLSession task 时抛出 `Task created in a session that has been invalidated`，
  导致宿主 abort。精确单测独立重跑 **1/1 PASS**。完整运行仍记为 FAILED，
  不将重跑视为全量通过。本轮未修改更新服务/URLSession 代码。
  日志 `/private/tmp/issue493-proxy-final-full.log`、
  `/private/tmp/issue493-proxy-final-update-rerun.log`；统计来自该轮 xcresult。
- 延续前次运行的另一 UpdateTests 失败也独立重跑 1/1 PASS：
  `/private/tmp/issue493-proxy-update-rerun.log`。该结果不替代最终完整运行。
- 显式 unsigned Debug build PASS：`/private/tmp/issue493-proxy-final-debug.log`。
- localization（521 keys / 12 languages）、balance query、network-error、
  balance-card 和 menu-bar geometry probes 均 PASS；`git diff --check` PASS。
- 命令配置：`xcodebuild test -project BalanceBar.xcodeproj -scheme BalanceBar
  -configuration Debug -derivedDataPath /private/tmp/BalanceBar-issue493-proxy-state-full-DerivedData
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES -parallel-testing-enabled NO`。聚焦运行额外指定
  CCSwitchRepositoryTests、ProviderRefreshCoordinatorTests、AppDelegateCompositionTests、
  DomainModelsTests、StatusItemControllerTests。
- Draft / ai:user-test 保持。人工与白屏 P0 未验收；Ready Full CI 未运行。


## Email tooltip refresh continuity follow-up

The email bubble keeps its existing compact content and appearance. Refreshes
that repeat the same email no longer reset native tooltip/popover state. A changed
account still invalidates the old bubble. Email popovers animate on presentation
unless Reduce Motion is enabled; dismissal stays immediate, matching the last
recharge bubble's lifecycle. The recharge subtitle and its two-line bubble are
unchanged. Direct and aggregation official cards use the same account field.

Verification: three focused account-email XCTest methods PASS, including unchanged
refresh/fallback preservation and changed-email/resize regressions. Log:
`/private/tmp/issue493-email-tooltip-tests-corrected.log`. The first invocation
selected the wrong XCTest class and ran zero tests; the corrected invocation
selected `DashboardProductionPathRegressionTests` and executed all three, with
zero failures. The targeted `xcodebuild test`
performed unsigned Debug compilation; `git diff --check` PASS. No new full local
XCTest run is claimed for this three-line production change.

如何人工测试：使用本轮重建的 Dev，在直连官方卡与聚合官方卡分别悬浮邮箱，
等候数次时间更新，气泡不应消失或反复弹出；首次出现有动画，鼠标移出立即关闭。
启用减少动态效果后不应播放弹出动画；账号变化不能继续显示旧邮箱。
充值气泡原样保留。实际 GUI/动画、白屏 P0 仍待用户验收。


## Recharge tooltip elapsed-time follow-up

The last-recharge bubble retains its title and adds a second-line value such as
`10/16 03:23 · 6 hours, 12 minutes ago`. Elapsed time is rounded down to whole
minutes, future timestamps clamp to zero, and the absolute timestamp uses the
application display time zone. System duration formatting plus a localized
suffix covers all 12 application languages (522 keys).

Elapsed content is resolved when the popover opens. Periodic card/timestamp
updates keep the absolute hint identity unchanged and do not dismiss the open
bubble; opening it again computes current elapsed time. Both direct and
aggregation balance cards share this implementation. The preceding email
continuity/animation fix remains in the same branch.

Validation: StatusItemControllerTests, DashboardComponentsTests and
LocalizationTests **185/185 PASS**, including deterministic six-hour/twelve-minute
and future-time cases. Log `/private/tmp/issue493-elapsed-tooltip-tests-final.log`.
An initial compile referenced the wrong locale owner and the first test run
rejected unnumbered localization placeholders; both were corrected before the
successful final run. Localization probe PASS (522 keys / 12 languages),
unsigned Debug compilation via targeted XCTest PASS, diff check PASS.
No new full local XCTest or Ready Full CI is claimed for these tooltip changes.

如何人工测试：直连与聚合余额卡分别悬浮“上次充值”，确认标题仍在，正文为
“10/16 03:23 · 6 小时 12 分钟前”这类日期与距今时长。保持悬浮经过刷新，
弹窗不能闪断；移出再进入时距今时长应重新计算。切换语言后使用对应语言，
邮箱气泡仍有弹出动画且不被相同内容刷新打断。GUI/白屏 P0 仍待人工。
