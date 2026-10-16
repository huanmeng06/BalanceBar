# PR #506: review Block 1 on `6b250e8a` — title bubble after section replacement

ChatGPT P1: with the menu open, a forecast presentation change makes
`reconcileOverviewSections` move a new `resetProbability` section from the
proposal host into the visible host. Its title link was tracked on the
proposal host, and the visible host then re-tracked only the first
`HoverLinkTextField` in the card. `installMetric` adds amount before title, so
that was never the new title (and the amount is intentionally inert):
hovering "重置概率" did nothing after the replacement. Confirmed in code.

Fix: after replacement, re-register every `HoverLinkTextField` still in the
card with the visible host, matching the initial build where each link is
tracked. Re-tracking is idempotent; the inert amount stays inert.

## Actual verification

- `testOfficialSignalSubtitleChangesReplaceOnlyProbabilitySection` now hovers
  the replacement title (underline, link color, bubble scheduled), leaves, and
  hovers the amount (no style, nothing scheduled) after each of its three
  presentation changes with the menu open.
- Red on committed `6b250e8a` source: 9 assertion failures, i.e. the title did
  not react in all three replacements (`/private/tmp/issue493-retrack-red.log`).
- Green: affected classes 194 tests / 0 failures; complete serial XCTest
  **1469 total / 1468 passed / 1 skipped / 0 failed**
  (`/private/tmp/issue493-retrack-full.log`); `ci-policy-test.py` passes.

# PR #506: reset-probability bubble above the title, inert amount, blue title

User feedback on `fe192dea`:
1. The bubble opened below "重置概率" (flipped text field, `.maxY`) and covered
   the subtitle and any progress bar. `HoverLinkTextField.opensHoverHintAbove`
   now requests the top edge; only the probability title sets it. The
   last-top-up bubble keeps its default below placement by user decision.
2. The amount could still show the blue link style: untracked it stayed in
   `.normal` mode with its own tracking area and cursor rect, and the card
   reconcile path can register the first `HoverLinkTextField` (the amount) with
   the host. The amount is now `.menuHosted` with `decoratesOnHover = false`, so
   neither path styles it.
3. The title uses the default link style again (blue and underlined on hover).

## Actual verification

- Red on the committed card code: the signal test failed 6 assertions,
  reproducing the reported blue amount after a host registration
  (`/private/tmp/issue493-placement-red.log`).
- Test windows are parked offscreen, where AppKit may flip a popover to any
  side with room, so screen placement is not asserted; the requested edge and
  the flipped-coordinate assumption are. On-screen placement is manual.
- Affected classes 208 tests; complete serial XCTest **1469 total / 1468 passed /
  1 skipped / 0 failed** (`/private/tmp/issue493-placement-full.log`);
  `ci-policy-test.py` passes.

# PR #506: forecast bubble triggers from the "重置概率" title

User request after `114335ed`: hovering the four-character "重置概率" title,
not the percentage, opens the source bubble. The section-blur focus effect
belongs to PR #505's focus infrastructure and is intentionally not ported here.

The title is now a `HoverLinkTextField` hosted by its `AccountMarqueeView`
(`codex.bankedReset.probabilityTitleLink`). It owns the forecast bubble,
0.5 s delay and codex-reset.com activation, and underlines in place on hover
in label color like the last-top-up phrase. The amount (numeric animation and
reduced percent sign retained) is no longer a hover target or link. The
confirmed state keeps no bubble, as before. In-place title text updates also
update the hover phrase.

Updated tests in DashboardProductionPathRegressionTests now assert the title
is the bubble/link host and the amount has no hint or activation, including a
hover check that the amount schedules nothing while the title underlines and
schedules the bubble.

Correction to the two records below: their focused runs did not include
DashboardProductionPathRegressionTests (it lives in
DashboardWindowControllerTests.swift). Run separately on committed `114335ed`
it passed **72/72** (`/private/tmp/issue493-prodpath-head.log`), including the
card-level reduced-percent assertion.

## Actual verification

- Before updating tests, this change failed 52 assertions in the
  production-path classes, all of which asserted the amount was the link
  (`/private/tmp/issue493-title-prodpath.log` was then overwritten by the
  passing run).
- After updating: production-path classes **72/72**; complete serial XCTest
  **1468 total / 1467 passed / 1 skipped / 0 failed**
  (`/private/tmp/issue493-title-full.log`).

# PR #506: reduced percent sign (user request after `6f3c8d1d`)

Menu percentages now draw the trailing "%" in the same reduced font as the
`$`/`¥` currency symbol (`currencySymbolFont`, 0.65× medium), baseline aligned:
`OverviewNumericTextView` for quota rows, and `HoverLinkTextField.percentSignFont`
for the banked-reset probability link, which keeps the reduced sign through
value animation, hover and restyling. Other suffixes (e.g. " EUR") and
non-percent text are unchanged. Dashboard pages are not changed.

Verification: DashboardComponentsTests, StatusItemControllerTests,
DashboardWindowControllerTests, OpenCodexCardLayoutTests and
OverviewNumericTransitionTests, **180 tests / 0 failures**
(`/private/tmp/issue493-percent-focused.log`). The SwiftUI quota-row suffix has
no font read-back; it was checked with an offscreen before/after render at
the menu's 31 pt size (`/tmp/bb493-preview/percent.png`) and needs manual GUI
confirmation.

# PR #506: unified menu hover bubbles (user request after `c3f606b3`)

Rework baseline: `c3f606b3434c523f3ab960a707e6e2327fa3e2df`.

The banked-reset forecast bubble ("24 小时内重置概率") differed from the
last-top-up bubble in two ways. It never animated: `HoverLinkTextField`
enabled popover animation only for titled text tooltips. It also flashed:
the source line contains the forecast's `updated_at`, and
`updateForecastTooltipContent` closed any pending or open bubble on every
content change, so a time-only refresh closed the bubble under the pointer
and the hover delay reopened it.

All menu-hosted `HoverLinkTextField` bubbles now animate on presentation
(respecting Reduce Motion) and close without animation, matching the
recharge and account-email bubbles. A forecast update that changes only the
source/update-time line keeps a pending or open bubble; the next presentation
uses the latest content, as the recharge bubble resolves elapsed time on open.
A change of title, body or disclaimer (for example probability vs. official
signal) still invalidates the bubble. A visible bubble no longer re-installs
the native tooltip underneath itself. The Dashboard threshold slider's value
bubble follows the thumb during drags and stays unanimated intentionally.

## Actual verification

- New tests on the old source (test hooks only): 4 assertion failures, i.e.
  no animation, pending hint cancelled, open bubble closed by a time-only
  refresh (`/private/tmp/issue493-bubble-red.log`).
- New source: DashboardComponentsTests, StatusItemControllerTests,
  DashboardWindowControllerTests and OpenCodexCardLayoutTests,
  **165 tests / 0 failures**; the real-window bubble test executed rather than
  skipped (`/private/tmp/issue493-bubble-focused.log`).
- `git diff --check` and `.github/scripts/ci-policy-test.py` (20/20) pass.
- Full XCTest was not rerun locally for this UI-only change; Full CI on Ready
  remains the final gate.

# PR #506: real-menu mount test failure (review of `a7b48311`)

Review baseline: `a7b48311a5d3d087d1db2bdbd3473e6788bee59a`.
This section supersedes the "Remaining failure" entry below.

## Root cause: unobserved AppKit menu sessions

`testRealMenuRebuildCreatesFreshViewportRemountsCardsAndRestoresScroll` failed
in the prior Full run, but it passed alone and passed in a run of the whole
StatusItemControllerTests class (86/86). With
`-test-iterations -run-tests-until-failure`, it reproduced intermittently on
unchanged production code. The failing popup moves between runs (the last
popup in the Full log, the second post-rebuild popup in a stress run), and the
sibling `testQuickSwitchReorderAddRenameAndRemoveKeepRealMenuHostMounted`
failed in the same way.

Diagnostics added to the helper recorded, for the failing popup:

```
began=1; probes=0; popUp=0.036s; item=true; appActive=false; mounts=1->2
```

AppKit began tracking (`NSMenu.didBeginTrackingNotification`), and the viewport
was attached to the real menu window (`viewDidMoveToWindow` with a window
incremented `mountCount`). The menu item still owned the viewport. AppKit then
ended the unfocused test-runner session on its own after ~36 ms, before the
20 ms `.eventTracking` probe timer fired once. The three failed assertions
(no mount, no visible card, distance -1) were the probe's empty defaults, not
observations. `NSMenuItem.view`, the mount and `restoreViewportAfterMount()`
behaved correctly in the failing session. This is a harness defect, not a
production lifecycle defect. No production code changed.

## Fix: distinguish unobserved sessions from failed mounts

`assertAggregationPopupMounts` now records each popup session. A session in
which the probe ran at least once is final: if it did not observe a mounted
viewport, the helper fails immediately with no reopen. Only a session that
ended before any probe ran (zero observations) is reopened, at most three
sessions in total; if all three are unobserved, the assertions still fail.
Every assertion (mount, visible card, mount count, restored distance 80 ± 2) is
unchanged, no wait or interval was added, and all session details are printed
in failure messages.

## Actual verification

- Original helper, both real-menu tests under `-run-tests-until-failure`:
  failed after 14 passing executions (`/private/tmp/issue493-menu-stress-red1.log`);
  with begin/mount diagnostics, failed at iteration 167 after 366 passing
  executions (`/private/tmp/issue493-menu-stress-red2.log`). Both failures
  had `probes=0`.
- Mutation check (viewport detached from the item before a popup, then
  reverted): fails in session 1 with `began=1; probes=50; item=false;
  mounts=0->0`, no reopen (`/private/tmp/issue493-menu-mutation.log`).
- New helper, both tests × 200 iterations: **400/400 passed**
  (`/private/tmp/issue493-menu-stress-green.log`).
- Complete serial XCTest: **1466 total / 1465 passed / 1 skipped / 0 failed**
  (`/private/tmp/issue493-menu-full.log`, DerivedData
  `/tmp/BalanceBar-Issue493-DerivedData`).
- Full CI remains skipped while the PR is Draft; GitHub Fast CI is not a
  substitute for the complete local run above.

# PR #506: preserve Claude user settings and close refresh test lifetimes

Review baseline: `5d598930a7c10cdfc8b57df352d6fb56765d4b7f`.
This section supersedes the later historical records. Prior failing Full runs
are retained below and are not substituted for the current run.

## Block 1: field ownership and lossless switch

Quick Switch owns the complete Claude Provider `env` block, not the whole user
settings document. It prepares a copy of the captured live JSON, replaces only
`env`, and removes the old block when the target Provider has no environment.
All other live keys (theme, permissions, hooks, MCP definitions, future keys)
remain semantically intact. A target template's independent settings do not
replace user settings. Route/auth matching still compares the whole environment;
malformed data and unsupported auth helpers still fail closed.

Existing transaction, revision and file-fingerprint checks remain in place.
Rollback restores the original complete bytes only if the file still belongs
to this transaction. The new regression covers nested independent fields,
conflicting template settings, custom-to-custom and return-to-official switches,
removal of stale auth variables, and complete-document rollback. On the review
baseline this regression failed two preservation assertions; it now passes.

## Block 2: ordered owner/transport/fixture shutdown

The prior teardown immediately invalidated URLSession and deleted SQLite files.
A summary-invalidated callback can fire before the same refresh queue finishes
launching replacement requests. Returning from a test after that callback did
not establish queue or network quiescence. A one-off queue barrier also cannot
prevent later completion callbacks and scheduled aggregation retries.

The coordinator now has a terminal `stop()` boundary: on its owner queue it
revokes a synchronized lifetime token, cancels aggregation retry/pending work
and invalidates pending publication generations. Off-queue callers wait for
already-running owner work to finish. All async entry points, late callbacks
and main-queue publications reject work from the stopped lifetime. Session
ownership remains with the caller; stop does not invalidate shared/injected
transports on its own.

All coordinator instances in ProviderRefreshCoordinatorTests are registered
through one factory and held until cleanup. Teardown now:

1. stops all owners;
2. invalidates/cancels the owned fixture session and awaits delegate confirmation;
3. awaits cancellation-aware URLProtocol workers, drains rejected late callbacks;
4. releases owners, resets the handler and deletes database/defaults fixtures.

The method-local special session stops its owner before its own defer invalidates
that session. The delayed URLProtocol respects stopLoading, suppresses delivery
after cancellation and exits a delayed gate wait on cancellation instead of
leaving a blocked worker. It is a test fixture change, not a production retry.

New regressions hold real asynchronous fixture requests, stop the owner, invalidate
the session, call refresh/prefetch/standard entry points and release late replies:
no further task, summary, render or notification is allowed. A separate controlled
queue gate verifies stop cannot return while owner work is still running. No
original late-response assertions or failing tests were removed, weakened or skipped.

The official same-token configuration-change test now performs its fixture UPDATE
on the coordinator owner queue while the old HTTP reply remains gated. This
serializes setup with its own background reads without changing the revision,
transport ordering or summary assertions. The old request is still in flight
when the configuration changes; this is fixture isolation, not a SQL retry.

## Actual verification

- Final complete serial XCTest: **1466 total / 1464 passed / 1 skipped / 1 failed**.
  `/private/tmp/issue493-lifecycle-full-delivery.log` and
  `/private/tmp/issue493-lifecycle-full-delivery-summary.json`;
  result `Test-BalanceBar-2026.10.16_12-16-38--0400.xcresult` under dedicated DerivedData.
- Remaining failure: StatusItemControllerTests.
  `testRealMenuRebuildCreatesFreshViewportRemountsCardsAndRestoresScroll`.
  One test failed three assertions: real popup did not mount its custom viewport,
  no visible card was observed, and missing distance (-1) did not equal 80.
  This is not a Full PASS. No UI assertion was relaxed, no test excluded and no
  identical-code retry was used to erase it. Its cause is not established by this
  bounded service patch; real-menu/white-screen acceptance remains blocked.
- ProviderRefreshCoordinatorTests **69/69** passed in that full run; the session
  invalidated exception and test-process crash did not recur. The reviewed
  session-lifetime path is fixed and tested, while the broader Full gate is still
  open because of the menu failure. Issue stays **ai:changes**, PR Draft.
- Unsigned Debug PASS: `/private/tmp/issue493-lifecycle-debug.log`.

- Final focused run: **188 tests / 0 failures** across CCSwitchRepositoryTests,
  ProviderRefreshCoordinatorTests, BalanceAPIClientTests, OfficialQuotaClientTests,
  AppDelegateCompositionTests. Log `/private/tmp/issue493-lifecycle-focused-delivery.log`.
- First complete run after the session fix: **1466 total / 1464 passed / 1 skipped / 1 failed**,
  `/private/tmp/issue493-lifecycle-full.log`. No session-invalidated exception or
  crash occurred. The remaining error was SQLite disk-I/O in the official
  same-token fixture UPDATE. Its setup was then serialized as described above;
  the complete suite was rerun on that changed test code, not by retrying a
  single test or borrowing a prior commit result.
- Regression-first config run on old code: 1 test / 2 expected assertion failures,
  `/private/tmp/issue493-lifecycle-config-red.log`.
- Intermediate focused run: 188 total / 175 passed / 13 failed. Added cleanup
  assertions exposed cancelled delayed workers that still waited on test gates;
  the initial stop guard also missed prefetch. Both paths were fixed before the
  final focused and complete runs. `/private/tmp/issue493-lifecycle-focused.log`.
  These intermediate failures are preserved, not reported as PASS.
- Localization (525 keys / 12 languages), balance query, network-error localization,
  balance-card layout, menu-bar geometry and diff check PASS.
  `/private/tmp/issue493-lifecycle-probes.log`.
- Dedicated DerivedData reused:
  `/private/tmp/BalanceBar-issue493-proxy-state-full-DerivedData`.
- Test command: `xcodebuild test -project BalanceBar.xcodeproj -scheme BalanceBar
  -configuration Debug -derivedDataPath <above> -destination 'platform=macOS,arch=arm64'
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -parallel-testing-enabled NO`.
- Dev precise SHA, signature, language resources, executable digest and exact-head
  Scope/Fast are recorded after commit in the PR/Issue handoff. Hosted Ready Full,
  artifact smoke and GUI/white-screen/CPU/scroll acceptance remain separate gates.

## 如何人工测试

开发版：原工作树 `build/dev/BalanceBar-dev.app`，精确 SHA 见本轮交接。
准备：使用测试 macOS 用户/配置；保留 Claude 设置副本，不破坏生产凭据。

1. 在 Claude 设置中保留 theme、permissions、hooks 等字段，两个直连供应商切换后，
   仅 env 变化；再切回无 env 的官方配置，旧 API 凭据移除，其他字段仍保留。
2. Claude 代理模式仍全部置灰；通过 CCS 正常退出代理后再切换，不能借本轮修复绕过保护。
3. 连续刷新、切换客户端、开关菜单，检查无异常退出；官方优先、同名即时拆分、
   TAG 顺序、两层滚动和白屏/关闭白闪仍需人工验收，自动测试不替代这些检查。

反馈 PASS + SHA + 范围，或 FAIL + 步骤 + 实际/预期 + 日志。
No version bump, merge, new task, interactive GUI or Ready Full is performed.

---

## Historical superseded validation records

# PR #506: three review fixes (baseline 9fd0c684)

This section is the current delivery; later sections are historical, superseded
validation records. Previous HEAD test PASS counts are not current evidence.

## Code and regression evidence

1. **Claude route/auth environment**: compare the entire parsed string-to-string
   `env` dictionary against the current Provider, rather than discarding fields
   through a prefix allowlist. Proxy variables (including lowercase), OAuth,
   TLS and unknown future variables therefore cannot silently disappear from
   the comparison. Unparseable environment/helper configurations still fail
   closed. Unrelated top-level theme settings remain independent. Matching
   proxy/OAuth settings continue to be accepted for a verified direct Provider;
   presence of a corporate proxy alone is not equated with CCS takeover.
   Regression checks mismatches for HTTPS_PROXY, HTTP_PROXY, ALL_PROXY, NO_PROXY,
   https_proxy, OAuth access/refresh tokens, custom CA and an unknown variable;
   direct repository calls must throw without pointer/file mutation. A positive
   matching proxy+OAuth case ensures this is not blanket proxy prohibition.
2. **Merged card source**: select the default-route member with a balance first,
   even when appended outside Stack and fetched earlier than another member.
   Provider metadata/link, amount, progress, recharge, baseline context and
   observed time all come from that same selected member. If the default has
   no balance, the fallback's source and complete snapshot move together; the
   failed member remains visible in the group's stale status/reason. Membership,
   notes order and group identity remain wallet-scoped and no balance is summed.
   Regression reads actual reader entries with a third-party default absent
   from Stack, distinct sites, both timestamp orders and fallback behavior.
3. **Split immediately, merge cautiously**: fresh, valid cent amounts within
   each Provider's own refresh window immediately refine a merged partition
   when they disagree. This does not wait for every peer or two refresh rounds;
   unknown/failing peers cannot bridge the observed different balances.
   Restoring a merged card still needs two complete new aligned fresh rounds;
   re-rendering cannot count as a sample. Existing tests now assert first-sample
   split, stability through failures, per-cent equivalence, third-member joins,
   and first-sample split even with a 30-minute member refresh interval.

Official reference checked for the environment boundary:
[Claude environment variables](https://code.claude.com/docs/en/env-vars) and
[network configuration](https://code.claude.com/docs/en/network-config).
No credential values are logged or added to persistence; tests use fixtures.

## Actual verification

- Final complete serial XCTest: **1463 total / 1460 passed / 1 skipped / 2 failed**.
  Log `/private/tmp/issue493-three-block-full.log`, summary
  `/private/tmp/issue493-three-block-full-summary.json`, result bundle
  `Test-BalanceBar-2026.10.16_11-40-14--0400.xcresult` in dedicated DerivedData.
- Failing tests:
  `ProviderRefreshCoordinatorTests.testQuickSwitchSummaryIsClearedWhenConfigurationRevisionChangesAndRefreshFails`
  (`Task created in a session that has been invalidated`, NSGenericException),
  and `testSharedQueryRejectedLateResponseDoesNotPublishOrNotify` (ABRT crash).
  This reproduces the outstanding asynchronous session lifecycle failure;
  this bounded rework neither fixes it nor proves it unrelated. Full acceptance
  remains blocked; no single-test retry or old Full PASS replaces this run.
- Within this complete run CCSwitchRepositoryTests 40, StatusItemControllerTests
  86, DomainModelsTests 59 and AppDelegateCompositionTests 49 all passed;
  all three new regressions passed. Refresh class still has the failures above.
- Explicit unsigned Debug PASS: `/private/tmp/issue493-three-block-debug.log`.
  Issue remains **ai:changes** and PR Draft because of the full-suite blocker.

- Regression-first run on old implementation: 3 tests, all 3 failed, with 35
  assertion failures. These are expected reproduction evidence, not a delivery
  test PASS. `/private/tmp/issue493-three-block-red.log`.
- Focused run after fixes: 301 tests / 1 failure. All changed repository/menu
  tests passed (40 + 86); the failure was the existing official late-response
  fixture's SQLite disk-I/O error in ProviderRefreshCoordinatorTests.
  `/private/tmp/issue493-three-block-focused.log`. This failure is preserved.
- Localization (525 keys, 12 languages), balance-query, network-error,
  balance-card and menu-bar geometry probes PASS; diff check PASS.
  `/private/tmp/issue493-three-block-probes.log`.
- Dedicated DerivedData reused:
  `/private/tmp/BalanceBar-issue493-proxy-state-full-DerivedData`.
- Final command: `xcodebuild test -project BalanceBar.xcodeproj -scheme BalanceBar
  -configuration Debug -derivedDataPath <above> -destination 'platform=macOS,arch=arm64'
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -parallel-testing-enabled NO`.
- Dev identity/signature/resources and exact-head Scope/Fast are recorded after
  committing in the durable PR/Issue handoff. Hosted Full/artifact smoke and
  actual GUI/white-screen/CPU/scroll acceptance remain pending. No version/merge.

## 如何人工测试

开发版：原工作树 `build/dev/BalanceBar-dev.app`；核对本轮交接的精确内嵌 SHA。
准备：使用测试供应商与隔离配置，不更改或删除生产凭据来制造故障。

1. Claude 用户配置的代理/OAuth 与 CCS Provider 不一致时，Quick Switch 应置灰；
   通过 CCS 同步为可靠直连后再恢复。不要点击测试生产供应商来制造竞态。
2. 第三方默认路由 B 不在 Stack 成员内，另有同名 A，二者余额与币种相同但站点
   不同：合并标题链接应打开 B 的站点，充值时间/进度来自 B；刷新先后不改变它。
3. 同名成员第一次拿到可靠不同余额后立即分卡，无需等慢成员下一轮；后续报错
   不应重新错误合并。恢复一致余额后需两轮新采样才合并，反复开菜单不算采样。
4. 检查官方优先、备注顺序、菜单置灰及恢复；排序/刷新后顶部无白屏，两层滚动
   保持。真实 GUI/CPU 和关闭白闪仍需人工 PASS，自动测试不替代它们。

反馈：PASS + SHA + 范围，或 FAIL + 步骤 + 实际/预期 + 日志。

---

## Historical superseded validation records

# PR #506: Codex default-config and Claude proxy compatibility

Review baseline: `910c71808d9bfdf166b11404b5631ecfc0f2d27a`.
This section is the current rework result. All later sections are historical
records and their PASS counts do not apply to this source tree.

## Review disposition

- Block 1 / P1: a missing Codex `config.toml` is treated as the built-in official
  route only when the database current Provider is official and the remaining
  local mode, authentication parsing, routing and proxy evidence checks pass.
  Custom Providers still require their actual route. Invalid UTF-8, unreadable
  files and conflicting/proxy evidence remain blocked. The regression starts
  with only a fixture login, verifies malformed/custom/proxy rejection and then
  switches successfully to a third-party Provider, creating its first TOML.
- Block 2 / P1: shared safety accepts the client explicitly. Claude reads its
  own local mode, per-client proxy history and effective settings environment;
  it does not interpret Codex Stack as Claude aggregation. Its routing/auth
  environment must match the current direct Provider; unsupported apiKeyHelper
  or malformed environment fails closed. Synced database zero is not authority.
  The switch coordinator validates Claude before termination and after exit;
  the repository independently validates inside the write transaction and
  before pointer changes. The former query-error-as-false bypass was removed.
  Local state participates in Claude's file fingerprint/recovery checks.
- Menu protection is cached separately per client on the main thread; Claude
  safety is read on the existing background refresh queue. Codex callbacks
  cannot authorize a Claude menu. No card/tooltip/layout changes were made.
- Block 3 / P2: the final check and OS termination request are not atomic with
  CCS. A disposable `/bin/sleep` child process regression enters proxy after
  validation and before sending the actual termination signal, observes real
  asynchronous exit, and verifies zero client/config/pointer writes and one
  recovery request. It does not claim that no termination happened. The test
  never stops or opens real CCS; real CCS timing remains manual acceptance.

Upstream references: pinned `services/proxy.rs` get_takeover_status and
`mode/current.rs` proxy_flags at `daf442e5d71078b41677a34518f63159fc7393cf`.
Both clients use device mode, not the synchronized enabled setting.

## Actual verification and remaining blocker

- Complete serial XCTest: **1460 total / 1458 passed / 1 skipped / 1 failed**.
  `/private/tmp/issue493-compat-full.log` and
  `/private/tmp/issue493-compat-full-summary.json`.
  Result bundle: `Test-BalanceBar-2026.10.16_10-59-46--0400.xcresult` under the
  dedicated DerivedData `Logs/Test` directory.
- The failure is recorded against
  `UpdateTests.testUpdateServiceRequiresMatchingAssetAndPreventsDuplicateChecks`.
  Runtime exception: `Task created in a session that has been invalidated`;
  stack includes BalanceAPIClient.fetchBalance and
  ProviderRefreshCoordinator.refreshQuickSwitchSummaries. This asynchronous
  lifecycle failure is not fixed or proven unrelated by this narrow patch.
  Full-suite acceptance remains blocked. No successful single-test rerun or
  old HEAD's Full result substitutes for the failing full run.
- Within that full run the affected classes all passed: CCSwitchRepositoryTests
  38, ProviderRefreshCoordinatorTests 67, AppDelegateCompositionTests 49,
  StatusItemControllerTests 85: **239 / 0 failures**. Four new regressions cover
  the missing TOML, Claude history/config/write guard, Claude process boundaries,
  and a real disposable process exit race.
- Intermediate focused run: 238 tests / 1 fixture configuration failure; fixed
  the new test's target payload to include a complete auth/config pair.
  Next focused run: 239 / 1 SQLite disk-I/O fixture failure in the official
  late-response test. That affected test/class passed in the full run above;
  these failures are retained here, not reported as a clean focused run.
- Localization (525 keys, 12 languages), balance-query, network-error,
  balance-card and geometry probes PASS; git diff --check PASS.
- Unsigned Debug and committed Dev artifact details are recorded in the durable
  PR/Issue handoff after those commands complete. Existing task-specific
  DerivedData is reused; no Ready Full CI or GUI was executed.

## 如何人工测试

开发版：原工作树 `build/dev/BalanceBar-dev.app`，以 PR 最新交接中的内嵌 SHA 为准。
准备：只在测试账号/临时 Codex 配置目录验证首次安装；不要删除生产配置。

1. 官方直连且只有正常 auth.json、没有 config.toml 时，Quick Switch 应可用；
   首次切换第三方后生成有效配置。损坏文件/代理模式仍应禁用。
2. Claude 代理下展开 Quick Switch：供应商和摘要置灰，管理入口可打开 CCS；
   不停止 CCS、不改当前直连指针。通过 CCS 正常退出代理后恢复切换。
3. 在 Codex 与 Claude 间切换，禁用状态各自独立；刷新和反复打开菜单不得误解锁。
4. 真实 CCS 进入代理与切换请求的时序竞争仍待人工验证；不要在生产凭据上人为
   破坏文件。还需验证排序后的白屏、CPU 和两层滚动，不能以本轮子进程测试替代。

反馈：PASS + 精确 SHA + 范围，或 FAIL + 步骤 + 实际/预期 + 日志。
Full failure keeps Issue at **ai:changes**; PR stays Draft. Manual acceptance,
white-screen P0 and Ready Full/artifact smoke remain pending. No version/merge.

---

## Historical superseded validation records

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
