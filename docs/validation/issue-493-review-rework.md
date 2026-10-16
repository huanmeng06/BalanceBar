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
| B7 | After known aggregation, a missing state file or missing `apps.codex` stays untrusted for 3 seconds, then becomes inactive and releases Quick Switch protection. Transient unreadable/corrupt state remains untrusted. |

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
| Block 1 | Missing-state timeout can hide stale aggregation cards after 3 seconds, but it no longer clears the independent Quick Switch write-protection flag. Only a verified direct/ordinary state releases protection. |
| Block 2 | `clientSnapshots` now stores `configurationRevision`; client switching reuses a cached snapshot only when client, Provider ID, and revision all match. |
| Block 3 | A non-current response must still match the Provider's current database configuration revision before it may update Quick Switch summaries. Database read failure is treated as invalid, not as a provider switch. |
| Block 4 | Configuration-revision invalidation now publishes `quickSwitchSummaryChanged` when an existing summary is removed, so an open menu clears stale text immediately. |

Focused verification:

- Affected repository/refresh classes: **86 / 0 failures** (`/private/tmp/issue493-blocks4-focused-final3.log`).
- Direct Block regression cases: **3 / 0 failures** (`/private/tmp/issue493-blocks4-focused2.log`).
- Targeted Debug compilation: PASS (`/private/tmp/issue493-blocks4-build2.log`).
