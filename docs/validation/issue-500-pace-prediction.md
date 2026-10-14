# Issue 500: cycle-average quota prediction

## Evidence checked on 2026-10-14

- [OpenAI usage guidance](https://help.openai.com/en/articles/20001516-managing-usage-with-gpt-6-astra-in-work-and-codex) describes the five-hour window starting with the first request after the preceding window ends. It distinguishes this limit from a weekly allowance.
- [OpenAI banked reset guidance](https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work) says a full reset refreshes eligible five-hour/weekly windows and changes the weekly reset schedule. Automatic reset scope varies by announcement, and the usage dashboard can lag.
- [Upstream Codex display model](https://github.com/openai/codex/blob/main/codex-rs/tui/src/status/rate_limits.rs) labels `used_percent` as percent used for the window, with server-supplied window duration and reset timestamp. [Upstream rate-limit adapter](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/rate_limits.rs) preserves these fields.
- BalanceBar's existing parser recognizes Codex 5h/7d by `limit_window_seconds`, maps `used_percent` to remaining quota, and retains a future absolute reset timestamp. Existing fixtures cover this field mapping; non-finite `used_percent` values are rejected before the existing remaining clamp so they cannot become a false full/empty quota; no extra usage requests were added.

## Enabled and withheld cases

The normal, recognized **exactly 18,000-second Codex window** is treated as a fixed request-started cycle whose deadline and cumulative counter describe the same period. Its inferred start is `resetAt - duration`. This is a documented-window interpretation, not a measurement of recent activity or a private backend guarantee.

The calculator requires an explicit trusted cycle start. UI callers default to no start. The menu controller only supplies a start for the five-hour rule above; **7d and nonstandard windows receive none**. Existing reference geometry/status remains separate from prediction eligibility.

A remaining-quota increase with an unchanged deadline means the counter could have been restored or recalibrated without a confirmed new cycle start. The controller suppresses prediction for that deadline, including updates while the menu is closed. This flag survives menu rebuilds and temporary missing/error snapshots, is cleared by identity/new-deadline changes, and stores no history or rate samples. A new valid clock still has to meet the observation threshold.

Unobserved special resets before app startup cannot be established from the available fields. No general seven-day or special-reset rule is claimed verified. Confirm updated API state during manual reset scenarios before release; do not turn a synthetic fixture or green build into backend-semantic evidence.

## Calculation and presentation

- Require a valid live pace window, a finite trusted start matching its duration, at least 3% of the cycle elapsed, and at least 1% consumed.
- Average use = `(100 - remaining) / elapsed`; remaining time = `remaining / average use`.
- Compare unrounded predicted seconds with the time to reset. Equality counts as lasting until reset in the calculator, but the UI makes no coverage promise for normal/slow states.
- Titles follow the existing rounded integer difference (fast below -5, slow above +5, normal otherwise), with only full/actually empty quota taking factual precedence. Normal titles are never overridden by prediction.
- Only a fast state with a trustworthy early-exhaustion result displays a forecast. The body explicitly says this cycle's average pace; it is a linear reference, not a recent rate or a guarantee of future activity.
- Round the raw absolute exhaustion instant to the nearest local five-minute mark (ties forward); if it falls at/before now, use the next future mark. If the rounded instant is not before reset, use qualitative fast copy instead.
- Reset times are factual and remain minute-precise. Same-day clock, localized tomorrow, weekday for days 2–6, and month/day (year across years) use the configured display timezone. Seven-day exhaustion prediction stays disabled; seven-day factual reset time remains available.
- Full allowance gets calm factual copy; empty quota gives its valid reset time or an unavailable message. Normal/slow and unpredicted fast states get the approved qualitative sentences, without exhaustion or lasts-until-reset promises for normal/slow.
- Tooltip contains just a title and optional sentence, at most 260pt wide. A vertical NSStackView, native label intrinsic sizes, preferredMaxLayoutWidth and fittingSize determine height, with no manual cell-height slack or fixed row height. VoiceOver receives the same content.

## AppKit verification boundary

The tooltip switches 5h/7d by transferring one NSPopover anchored to their common menu host, updating its content and positioning rectangle without closing/reopening native windows. Synthetic menu tests assert shared presentation/controller identity across minute refreshes and switching, actual replacement content, anchor coordinates, 300ms/100ms timing, rapid reentry and teardown. Matching refresh content skips layout; mouse tracking/monitor registration is idempotent, and marker movement closes only after it leaves the pointer’s current heat rect.

The background XCTest host deliberately parks windows offscreen and denies key focus. A native menu/popover diagnostic was intermittent (2 of 5 repetitions ended menu tracking early, at first presentation or switching); this does **not** establish whether production has the same behavior. Even a long presentation-probe run had one of five native menu loops end early. Deterministic coverage is split: a short real NSMenu tracking-loop probe checks routing/content/anchor/ownership/teardown with controlled timer firing; a standalone pace view in a parked window separately verifies real 300ms/100ms delays and cancellation while running the event-tracking mode. Both use a presentation probe instead of changing the host policy. Native window stability is not claimed PASS; it remains a required manual gate with the development bundle.

## Tick hover animation

The marker overlay uses two CALayers above the unchanged progress track. Body rest/hover dimensions are 2×8pt / 3.5×11pt, opacity 0.85 / 1, outline 0.75pt / 1pt with 40% white/black contrast. Entry uses damping 18, stiffness 320, mass 1, zero initial velocity and settlingDuration; exit is 150ms ease-out. Bounds, corner radius and opacity animate from presentation values to explicit model targets without transform scaling. Local frame/scale/color updates disable implicit animation.

The clipped 16×18pt heat rect never grows with animation. Existing activeAlways/menu-tracking guards and 300ms show / 100ms close timing remain. Ordinary exits and 5h/7d transfers animate; lifecycle invalidation removes animations and snaps rest. Existing workspace accessibility observation applies runtime Reduce Motion: immediate state changes, no replay when disabled. Layer copy initialization explicitly preserves child identities, geometry, colors and scale.

Unit/integration checks establish model geometry, animation configuration, presentation-start selection, copies, timing and cleanup. They do not establish native animation appearance or a particular overshoot percentage; evaluate responsiveness and menu stability with the development bundle.

## Release evidence still required

Actual cursor hit testing, compact visual layout, all language wrapping, screen-edge placement, quota refresh, menu close/reopen and identity changes require the user development-bundle checklist. Weekly prediction stays withheld. When a reset scenario cannot establish a trustworthy clock/counter pair, keep its prediction withheld.
