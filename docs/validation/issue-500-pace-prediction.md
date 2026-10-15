# Issue 500: cycle-average quota prediction

## Historical evidence checked on 2026-10-14

- [OpenAI usage guidance](https://help.openai.com/en/articles/20001516-managing-usage-with-gpt-6-astra-in-work-and-codex) describes the five-hour window starting with the first request after the preceding window ends. It distinguishes this limit from a weekly allowance.
- [OpenAI banked reset guidance](https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work) says a full reset refreshes eligible five-hour/weekly windows and changes the weekly reset schedule. Automatic reset scope varies by announcement, and the usage dashboard can lag.
- [Upstream Codex display model](https://github.com/openai/codex/blob/main/codex-rs/tui/src/status/rate_limits.rs) labels `used_percent` as percent used for the window, with server-supplied window duration and reset timestamp. [Upstream rate-limit adapter](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/rate_limits.rs) preserves these fields.
- BalanceBar's existing parser recognizes Codex 5h/7d by `limit_window_seconds`, maps `used_percent` to remaining quota, and retains a future absolute reset timestamp. Existing fixtures cover this field mapping; non-finite `used_percent` values are rejected before the existing remaining clamp so they cannot become a false full/empty quota; no extra usage requests were added.

## Standard-window metadata inference (2026-10-15 contract)

The approved contract now enables the recognized **18,000-second 5h and 604,800-second 7d Codex windows**. Both starts are explicitly inferred as `resetAt - durationSeconds`. This is a metadata interpretation and linear reference, not independent verification of all backend weekly/special-reset semantics, nor a measured activity start. Announcement time, local detection time and request completion time are never used as the prediction origin. Nonstandard/missing/invalid windows remain ineligible.

Eligibility belongs to the quota coordinator and CodexResetObservationStore. The existing independent quota journal is updated at the accepted account-scoped quota-response boundary, before credit/forecast requests. Prediction contexts read this journal, so a failed/missing announcement is not a prerequisite and watching/notEligible alone does not invalidate a cycle. Existing complete-snapshot reset recognition (prior consumption, both windows full, weekly reset jump at least 24 hours), credentials/response ownership and episode rules are unchanged. Quick-switch quota evidence uses the same boundary; no new request is added.

A separate `.predictionCycles` property-list payload under the existing provider/account key stores only the current 5h/7d cycle identities, last valid remaining values, suppression flags, last accepted sample time and last processed quota-event ID. Original event/journal encoding is untouched. Missing legacy prediction records initialize from the first valid quota. A newly observed journal event invalidates existing old bases once, including missing windows; current windows with newer deadlines create new bases. Same-cycle quota increases suppress that window until a newer cycle; an event cannot clear its suppression. Duplicate events, missing/invalid windows, errors, stale timestamps and older deadlines do not resurrect an old basis. State is account/provider/window-kind isolated and survives restart; it is not a usage history or recent-rate sampler.

Snapshot carries QuotaPredictionContext plus account scope through compact/Reserve derivation. The menu accepts only matching account/client/window contexts; it has no refill/reset detector or Set<Date>. Missing/ineligible context means qualitative copy. Minute ticks recompute from the same stored origin and the current tick time without requests or persistence writes. Reset-event IDs use detectedAt only for identity/deduplication. First-time legacy initialization has no invented past counter history; unobserved reset discontinuities remain an inherent metadata-model limitation.

## Calculation and presentation

- Require a valid live standard window, an eligible finite metadata-inferred start matching its duration, at least 3% of the cycle elapsed, and at least 1% consumed (7d time threshold: 5h 2m 24s).
- Average use = `(100 - remaining) / elapsed`; remaining time = `remaining / average use`.
- Compare unrounded predicted seconds with the time to reset. Equality counts as lasting until reset in the calculator, but the UI makes no coverage promise for normal/slow states.
- Titles follow the existing rounded integer difference (fast below -5, slow above +5, normal otherwise), with only full/actually empty quota taking factual precedence. Normal titles are never overridden by prediction.
- Only a fast state with an eligible early-exhaustion result displays a forecast. The body explicitly says this cycle's average pace; it is a linear reference, not a recent rate or a guarantee of future activity.
- Round the raw absolute exhaustion instant to the nearest local five-minute mark for 5h, thirty-minute mark for 7d (ties forward); if it falls at/before now, use the next future mark. If the rounded instant is not before reset, use qualitative fast copy instead.
- Reset times are factual and remain minute-precise. Same-day clock, localized tomorrow, weekday for days 2–6, and month/day (year across years) use the configured display timezone. Weekly forecast dates use the same localized day/weekday/year rules; factual reset times are never rounded to the forecast interval.
- Full allowance gets calm factual copy; empty quota gives its valid reset time or an unavailable message. Normal/slow and unpredicted fast states get the approved qualitative sentences, without exhaustion or lasts-until-reset promises for normal/slow.
- Tooltip contains just a title and optional sentence, at most 260pt wide. A vertical NSStackView, native label intrinsic sizes, preferredMaxLayoutWidth and fittingSize determine height, with no manual cell-height slack or fixed row height. VoiceOver receives the same content.

## AppKit verification boundary

The tooltip switches 5h/7d by transferring one NSPopover anchored to their common menu host, updating its content and positioning rectangle without closing/reopening native windows. Synthetic menu tests assert shared presentation/controller identity across minute refreshes and switching, actual replacement content, anchor coordinates, unified phase timing, rapid reentry and teardown. Matching refresh content skips layout; mouse tracking/monitor registration is idempotent, and marker movement closes only after it leaves the pointer’s current heat rect.

The background XCTest host deliberately parks windows offscreen and denies key focus. A native menu/popover diagnostic was intermittent (2 of 5 repetitions ended menu tracking early, at first presentation or switching); this does **not** establish whether production has the same behavior. Even a long presentation-probe run had one of five native menu loops end early. Deterministic coverage is split: a short real NSMenu tracking-loop probe checks routing/content/anchor/ownership/teardown with controlled timer firing; a standalone pace view in a parked window separately verifies real nominal 300ms entry / 80ms exit delays and cancellation while running the event-tracking mode. Both use a presentation probe instead of changing the host policy. Native window stability is not claimed PASS; it remains a required manual gate with the development bundle.

## Tick hover animation

The marker overlay uses two CALayers above the unchanged progress track. Body rest/hover dimensions are 2×8pt / 3.5×11pt, opacity 0.85 / 1, outline 0.75pt / 1pt with 40% white/black contrast. Entry uses damping 18, stiffness 320, mass 1, zero initial velocity and settlingDuration; exit is 150ms ease-out. Bounds, corner radius and opacity animate from presentation values to explicit model targets without transform scaling. Local frame/scale/color updates disable implicit animation.

The clipped 16×18pt heat rect never grows with animation. The activeAlways/menu-tracking guards remain; the card coordinator now owns the nominal 300ms show / 80ms exit timing. Ordinary exits and 5h/7d transfers animate; lifecycle invalidation removes animations and snaps rest. Existing workspace accessibility observation applies runtime Reduce Motion: immediate state changes, no replay when disabled. Layer copy initialization explicitly preserves child identities, geometry, colors and scale.

Unit/integration checks establish model geometry, animation configuration, presentation-start selection, copies, timing and cleanup. They do not establish native animation appearance or a particular overshoot percentage; evaluate responsiveness and menu stability with the development bundle.

## Official-card module focus

Hovering a valid 5h/7d tick keeps its own section clear. All other actual section views within that official card (account, other quotas, reserve and reset modules) recede to alpha 0.5 and Gaussian radius 3. The common host, external section outlines, menu commands and independent Popover remain outside the section focus filters. First entry waits 120ms, then transitions for 180ms with ease-out; departure waits 80ms and restores over 200ms with ease-out. An active focus transfers immediately to the next module. Timers run in common/eventTracking modes with target and generation guards.

The host registers its actual owned sections after replacement, checks the quota identity/cycle and current heat rect, and rejects retired-view callbacks. Value-only refreshes neither reinstall monitors nor replay focus transitions. Hard interaction/identity/lifecycle cleanup cancels pending work and restores all owned effects immediately. The existing workspace accessibility observer reapplies focus: Reduce Motion completes transitions immediately while retaining debounce; Reduce Transparency removes blur and retains only alpha 0.5.

Each section appends its named CIGaussianBlur through [NSView.contentFilters](https://developer.apple.com/documentation/appkit/nsview/contentfilters). This lets AppKit configure rendering. Attached filter radius changes use the named layer key path as required by [CALayer.filters](https://developer.apple.com/documentation/quartzcore/calayer/filters), with explicit animation from presentation radius and guarded cleanup. Restoration removes only this effect's filter; unrelated filters/animations are retained. Failed filter creation degrades to alpha-only without a material overlay.

Tests check timing, state distribution, native filter attachment/key-path access, stale completion rejection, actual-host callbacks, replacement/removal, idempotent refresh and accessibility/fallback state. The short real NSMenu tracking-loop probe now owns independent quota sections and checks focus transfer alongside existing Popover behavior. None of these background tests establishes visible Gaussian rendering, edge quality, animation continuity or performance. Actual blur and the 3/0.5 strength require user testing; alpha-only fallback must never be recorded as Gaussian PASS. The earlier intermittent native-menu diagnostic remains an unresolved manual gate.

## Unified hover timeline and native Popover animation

PaceHoverTiming centralizes the 120ms entry delay, 180ms background transition, nominal 300ms Tooltip delay, 80ms exit debounce and 200ms restoration. One host-owned SectionFocusController schedules the focus, Tooltip and exit phases with a single cancellable tracking-mode Timer and generation. The Tooltip phase is scheduled when focus actually starts, so a delayed event-loop callback cannot compress the background and bubble into the same frame. Detached views use the same coordinator, not a separate timing algorithm. If a focused target is reentered before any bubble has appeared, Tooltip waits a fresh uninterrupted 300ms; an already-visible bubble instead transfers immediately with no new delay.

Ordinary departure requests native bubble close at the same 80ms boundary that starts restoring background. A native close already requested is never reversed or reused; reentry starts a new hover and later creates a new Popover. Initial show/ordinary close set animates according to Reduce Motion. Existing-bubble content/size/anchor updates suppress animation without closing/reopening. The shared Tooltip factory remains nonanimated for other callers. Hard cleanup disables animation and immediately issues close. The existing workspace observer updates the policy without replay or new observers. No private window class, custom window-opacity animation, material overlay or exact native fade duration is used or promised. [NSPopover.animates is a system hint](https://developer.apple.com/documentation/appkit/nspopover/animates), including for moves and resizing; it is not a guaranteed animation contract.

Regression probes record show/close animation policy and verify ordering, late callbacks, reentry, stale tasks, stable presentation/controller identity and module replacement preserving the outstanding phase. These establish requests/state, not visible native fades. A background native link-menu reopen probe intermittently failed to attach on the fifth popup during this iteration; its source path is unchanged and a subsequent focused class run passed, but that is not proof of a fixed or harmless native interaction issue. Preserve both this observation and earlier menu/Popover early-exit evidence for the user manual gate. If native animation is ineffective or causes regression, record FAIL and continue in the same PR; do not silently add custom window opacity.

## Release evidence still required

Actual cursor hit testing, compact visual layout, all language wrapping, screen-edge placement, quota refresh, menu close/reopen and identity changes require the user development-bundle checklist. Both standard windows now use the approved metadata-inference contract. When evidence suppresses a cycle or its clock/counter pair is invalid, retain qualitative copy. Real global-reset, same-deadline refill and restart scenarios require manual acceptance; mathematical/API fixtures are not backend-semantic proof.


## Menu dismissal blank-background rework (2026-10-15)

User video `PixPin_2026-10-15_04-03-43.mp4` at base `8a92db54` shows all menu content (including commands outside the blurred card) disappearing around 4.00s, while the translucent panel remains for at least approximately 180ms. This is an observed manual FAIL; it is not merely the alpha 0.5-to-1 brightness change. Exact AppKit compositor causation is not established by frames alone.

The close path previously dispatched a full `removeAllItems()` rebuild on the next main-queue turn whenever tracking-time updates marked the menu dirty. That turn is not proof that the native menu is offscreen. Rebuild is now retained as pending until the next `menuWillOpen`. Updates received during the outgoing host's dismissal also defer structure changes.

The host separates stopping interaction from restoring visuals. Menu close/application deactivation cancels phase timers and monitors, disables tracking and closes the active bubble without adding an animation. Outgoing section opacity/radius are frozen from presentation values; restoration completions are invalidated before removing owned animations, retaining the named filter rather than swapping rendering configuration during exit. A window occlusion notification showing no visible region, detachment, or the next open completes normal-state cleanup. If AppKit emits no occlusion change, only bounded view/filter state is retained until detachment/reopen; no repeating timer or input monitor remains. No guessed delay, private window access, material overlay or custom window fade is introduced.

Animated departing Popovers remain owned until `popoverDidClose`. They cannot transfer to a new target or receive a duplicate close request. A late close callback removes only its matching old instance; transfer updates the delegate, and native transient outside-click dismissal also clears the active reference. Changing `animates` during a close is not claimed to reverse/cancel AppKit's existing animation.

Verification: unsigned Debug build PASS; five affected XCTest classes (DashboardComponentsTests, StatusItemControllerTests, OverviewNumericTransitionTests, OverviewNumericPresentationControllerTests, OpenCodexCardLayoutTests), **166 tests / 0 failures**, serial. Seven key tests each repeated five times, **35 / 0 failures**, including controlled real NSMenu routing, tracking-loop delays, cancellation, outgoing-state preservation, window-occlusion notification guards, app deactivation, old completion isolation, Popover ownership and next-open rebuild. Probe windows and the background host do not verify visible native fading. Logs: `/tmp/BalanceBar-Issue500-Close-build.log`, `...-tests-final.log`, `...-stress.log`.

`./scripts/build.sh dev`, bundle signature verification, 517-key / 12-language bundled-resource probe and `git diff --check` PASS. Logs: `/tmp/BalanceBar-Issue500-Close-dev.log`, `...-resource.log`. Development executable SHA-256: `3979d52e6a72063e07daed459927b2e38cf935d7a785074729da2c728b6f5ed4`. Full CI remains deferred while Draft. Prior native-menu early-exit observations above remain unresolved manual gates.

Manual retest PENDING (prior acceptance invalidated): launch the rebuilt `build/dev/BalanceBar-dev.app`, hover until blur and Tooltip appear, then click the desktop/another app to dismiss. All content and panel should leave coherently, without a blank milky panel remaining. Repeat after quota refresh and a minute tick, during entry/ordinary-exit transitions, and with rapid close/reopen or 5h/7d transfer. Reopen must show current values and restored module opacity/filter state; normal hover must work again. Check light/dark, screen edges, Reduce Motion and Reduce Transparency. Do not call this visible white-flash fix PASS from the background tests; user confirmation on the new artifact is required.


## Continued white-flash FAIL: diagnostic development build (2026-10-15)

The user explicitly reported **“仍然闪白”** on `082f0700`. Its GUI acceptance is FAIL, and the previous automated 166/35 results never established visual success. This iteration delivers instrumentation plus confirmed update-gate corrections, not a claim that the flash is fixed.

All tracking-time content mutations now use one gate: controller tracking, host content visible, and host not dismissing. This includes structural section replacement, numeric/progress refresh, the delayed opening-number animation, quota pace, and reset countdown. During application deactivation before `menuDidClose`, current data is retained for next-open rebuilding while outgoing controls remain unchanged. Ordinary full rebuild also defers whenever the host's window is still `isVisible`, independently of the auxiliary occlusion cleanup flag. The next-open path intentionally rebuilds before presentation; actual application teardown remains separate.

`MenuDismissalTrace` uses the existing asynchronous `SwitchLog` writer under **`ui.menu.dismissal`**. It is enabled by default for the development bundle identifier (and dev subidentifiers), disabled for production; no preference page, polling, new timer, window-opacity manipulation or animation parameter change is added. Each opening gets a process-local round and sequence. Monotonic nanoseconds, elapsed milliseconds and wall-clock seconds are captured synchronously at the event boundary before asynchronous persistence. The log contains process-local object identifiers, host-round association, tracking/visibility/dismissal flags, window-visible/occlusion snapshots, item/section counts, and section model/presentation alpha/radius/filter/animation state. It never reads account/header/Tooltip text or credentials.

Events cover menu opening/close callbacks, app deactivation, marker enter/leave, hover-phase scheduling/firing/ignored generations, Popover show/transfer/close request/willClose/didClose, dismissal begin/cleanup, view attachment changes, full rebuild and its deferral, content-update gate acceptance/deferral, actual section add/remove and owned-filter removal. Window visibility is sampled at those boundaries; it is not a continuous recording or proof that occlusion equals animation completion. Popovers retain their originating trace through transfer/closing so a callback after reopen still logs the old round, with the current host round shown separately. Existing log rotation/export applies. Tracing has nonzero event-boundary overhead; it does not itself establish compositor causation.

### Automated evidence

- unsigned Debug build PASS, `/tmp/BalanceBar-Issue500-Trace-build-final.log`; final source compiled again by targeted XCTest.
- **171 tests / 0 failures**, serial, `/tmp/BalanceBar-Issue500-Trace-tests-final.log`: DashboardComponentsTests, StatusItemControllerTests, OverviewNumericTransitionTests, OverviewNumericPresentationControllerTests, OpenCodexCardLayoutTests, plus the two DashboardProductionPathRegressionTests for official countdown text/progress.
- **50 executions / 0 failures**, ten key methods repeated five times, `/tmp/BalanceBar-Issue500-Trace-stress-final.log`. Covers diagnostic policy/order/no-content logging, originating-round close callback, deactivation before delegate close, actual delayed numeric callback, latest values applied on reopen, still-visible rebuild deferral, filter freeze/late completion, stable Popover ownership, native menu routing, real tracking-loop delays and rapid reentry. These are background state/routing tests, not visual native-menu PASS.
- Dev build, signature, `git diff --check`, and **517-key / 12-language** bundled-resource probe PASS; `/tmp/BalanceBar-Issue500-Trace-dev.log`, `...-resource.log`. Bundle ID `com.huanmeng06.BalanceBar.dev`; executable SHA-256 **`15023488ff1b968015477dbafc4ca9693c18b308ee385ef73bc47b9ef1154b65`**.
- Initial diagnostic compile exposed explicit MainActor isolation versus legacy unannotated controller methods. Fixed by synchronous MainActor capture, without queueing the state read. An initial stress selector referenced the file's other test class and selected zero executions for the deactivation method; the corrected final run above verifies all 50 executions, not the empty suite. Earlier logs are retained under `...-build.log`, `...-stress.log`, `...-deactivation-stress.log`.
- Full CI remains deferred while Draft. Earlier intermittent real-menu early exits and the user's new visible FAIL remain unresolved manual evidence.

### How to collect the next reproduction

Development app: `/Users/huan_meeng/.codex/worktrees/7d8e/BalanceBar/build/dev/BalanceBar-dev.app`. Quit the old development process and launch this bundle manually. Existing Logs page exports the log; the default development path is `~/Library/Logs/BalanceBar/Development/debug.log`. No diagnostic switch needs enabling.

Target **20 trials**: light 8, dark 8, Reduce Transparency 4. In each group run four scenarios (twice for light/dark, once for Reduce Transparency):

1. Hover until blur and Tooltip appear, then immediately click desktop/another app.
2. Close during entry/ordinary-exit transition, including a quick leave/reenter.
3. Transfer 5h/7d then close and quickly reopen.
4. Close after quota refresh; include at least one real minute tick while hovering across the complete session.

Record the screen and note the approximate time/trial of a white panel. If FAIL occurs, preserve that recording and export the log; do not discard it to chase a clean 20-run result. Reopen must display latest values, with no resumed outgoing callback or stale Tooltip. This is user-operated GUI testing; Worker does not automate foreground UI.

Analyze events by round and `mono_ns` (not asynchronous writer timestamps alone). `content.update` records gate acceptance, not proof that every call changed a value. If menu/section destruction occurs during exit, fix its actual caller; if an effect restoration runs early, fix that task/completion; if application content/effects remain stable during a recorded flash, plan a separate single-variable native-Popover-animation comparison. Do not infer that absent destruction proves a system bug, add guessed closing delays, or alter private/native menu window opacity. New diagnostic GUI result remains **PENDING**, and the previous `082f0700` result remains FAIL.


## Freeze before native detachment; development A/B/C comparison (2026-10-15)

The user supplied a new review report for `b2b52c29`: it reports twelve closes with host `viewWillMove(nil)` before `menuDidClose`, filter removal while the outgoing window remained visible, and no `focus.suspend`. The quoted 09:25:04 UTC sequence and ~535ms Popover close durations are evidence supplied by that report, not independent reanalysis of a raw log file available in this round. Static source confirms the host, pace child and section removal callbacks could restore effects before the late close delegate callback. This evidence supersedes menu reconstruction as the leading explanation for that reported batch (which kept its item/section counts). WindowServer causation and the independent Popover contribution remain unproven.

The host now starts dismissal in the earliest applicable `removeFromSuperview` or `viewWillMove(nil)` entry while the old menu window is still visible, before super triggers child callbacks. It stops interaction and freezes effects before detach. `viewDidMoveToWindow`, repeated tracking changes, direct child invalidation/removal, section removal, accessibility reconciliation and old animation completions cannot restore a suspended effect. Section suspension is independent of the host still being attached. Ordinary removal/replacement of a component in a live menu retains normal cleanup; it does not initiate whole-menu dismissal.

The outgoing window is retained by weak identity across host detachment. `host.window == nil` and occlusion changes are not completion criteria. Ordinary cleanup requires the retained window no longer report `isVisible`, or its object to be gone; the next `menuWillOpen` explicitly restores before presentation when no notification arrived. Window notifications check window identity and a dismissal generation. Captured pace views remain owned through retirement so removed children can be reset at that safe point; phase timers and input monitors stop immediately. No repeating cleanup timer, guessed wait, private window access or WindowServer-completion claim is introduced. Logs now include `view.removeFromSuperview`, `attached_window` separately from the retained outgoing-window snapshot, the experiment mode, and deferred cleanup. A suspend may correctly precede the willMove log when removeFromSuperview was the first entry.

### Single-bundle comparisons

`--pace-dismissal-experiment` is process-local, development-only and not persisted. Production ignores it. Defaults and unknown/missing values use **C / full**. All three modes share the lifecycle fix and otherwise unchanged Tooltip content, appearance, show animation, anchor, spring and timing:

- **A / focus-off**: Tooltip remains; module Gaussian blur and alpha recession are disabled. Marker hover animation remains.
- **B / popover-close-off**: Module effects remain; initial Tooltip show animation remains, but close requests set animates=false from the start, including ordinary hover departure. This does not claim to reverse an already-started native animation or guarantee a zero close duration.
- **C / full**: Full module effect and original native Popover animation policy. This is also a normal Finder launch with no arguments.

Quit the old development process before each group, then run exactly one command (never start these concurrently):

```sh
# A
open -n "/Users/huan_meeng/.codex/worktrees/7d8e/BalanceBar/build/dev/BalanceBar-dev.app" --args --pace-dismissal-experiment focus-off
# B
open -n "/Users/huan_meeng/.codex/worktrees/7d8e/BalanceBar/build/dev/BalanceBar-dev.app" --args --pace-dismissal-experiment popover-close-off
# C (default)
open -n "/Users/huan_meeng/.codex/worktrees/7d8e/BalanceBar/build/dev/BalanceBar-dev.app" --args --pace-dismissal-experiment full
```

Use the same appearance/account/menu configuration for the primary A/B/C groups; Reduce Motion and Reduce Transparency must be off so the comparison isolates the intended effect. Each group targets 20 fast closes: four scenarios five times each (fully shown hover then desktop click; close during restoration; 5h/7d transfer then immediate close; quick close/reopen including at least one quota refresh/minute tick over the session). Record the screen and export the existing development log. Verify experiment=focus-off/popover-close-off/full in the trace before assigning results. Afterwards separately regress C in dark mode, Reduce Transparency and Reduce Motion; do not mix those settings changes into the single-variable conclusion. A visible FAIL should be preserved, not discarded to chase clean trials.

The required trace property is suspension before child reset/filter removal on detach while departing_visible=true, with no focus.reset/filter.remove before the safe cleanup or explicit next-open boundary. Reopen must restore alpha1/no owned filter and working hover. Compare actual close-request/didClose timing per instance, not the animates hint alone. GUI and each A/B/C result remain PENDING until user-operated testing. If C still flashes with application effect state preserved, use the comparisons to select the next investigation; do not declare the OS the cause merely because app-level mutation is absent.

### Automated evidence

Unsigned Debug build PASS, `/tmp/BalanceBar-Issue500-Detach-build.log`; final source also compiled in **174 serial affected XCTest / 0 failures**, `/tmp/BalanceBar-Issue500-Detach-tests-final.log`. Same five UI classes and two official-countdown production paths as the preceding iteration. New cases exercise actual parent/child detachment before the delegate close while the old window stays visible, all cleanup/invalidation paths, stale restoration completion, retained old-window notification after detach, removed children restoration, real rebuilt 5h/7d rows, a separate direct-willMove route without an earlier removal entry, next-open fallback and all three development policies. Existing active component removal, native menu event forwarding, identity, refresh, accessibility and timing tests pass.

Thirteen key methods each repeated five times: **65 / 0 failures**, `/tmp/BalanceBar-Issue500-Detach-stress.log`. An initial regression assertion incorrectly required willMove before suspend; actual contentView detachment first invoked removeFromSuperview and suspended earlier. The test now checks the earliest removal entry, suspend, actual detach and then delegate close, and a separate test covers willMove-first. Its initial failed log `/tmp/BalanceBar-Issue500-Detach-tests.log` is retained; it is not counted as PASS.

`./scripts/build.sh dev`, signature verification, `git diff --check` and the bundled **517-key / 12-language** resource probe PASS. Logs `/tmp/BalanceBar-Issue500-Detach-dev.log`, `...-resource.log`. Development executable SHA-256 **`24bdf5ea123a1e0668cceb9e661b2c0fb3aa8a8719a434bec9ee91147235bb9f`**. Background state/routing tests do not establish native visual success; previous early-exit observations and the b2b52c29 user FAIL remain retained. Full CI remains deferred while Draft.


## 用户选择 B：默认关闭气泡退出动画（2026-10-15）

基准 c7f627971fd252d5ddae0ecb6b64b1defaf756c1。用户选择 B，本轮默认策略替代此前默认 C：保留模块模糊、刻度动画和气泡出现动画，仅禁用使用节奏 Popover 退出动画。开发包无参数即 B；生产包忽略诊断参数并采用 B。A/C 仅保留为开发诊断覆盖。保留提前冻结与退出保护。

用户选择不等同 GUI PASS；此前白闪 FAIL 和原生菜单提前退出历史继续保留。新开发包人工 PENDING：正常启动无需参数，检查模糊与出现效果、移出及点击外部关闭、快速重入、5h/7d 切换、刷新和关闭重开，并覆盖深浅色及辅助功能。日志应为 experiment=popover-close-off。

验证：unsigned Debug XCTest 构建通过；DashboardComponentsTests、StatusItemControllerTests 共122项／0失败；默认B、显式A/B/C和退出冻结3例各5轮，共15次／0失败。开发包构建、签名验证、517键／12语言资源probe及git diff --check通过。使用原专属DerivedData，日志为 /tmp/BalanceBar-Issue500-BDefault-{tests,repeat,dev,resource}.log。可执行文件SHA-256：3a3db94f6671eb92ce4c075984453a7fbd3febec1278358572cd64e8c47dcb40。自动测试不证明真实GUI白闪消除，Full CI未启动。
