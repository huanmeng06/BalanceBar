# Issue #312 — Performance tint regression high-confidence fix plan

## Status

Plan only. This branch intentionally contains no production or test code changes.

Target issue: #312
Baseline: `main@ef1baeacdbbb326c98dc22829c251b01fe324782` (`1.3.10/build87`)
Known-good historical reference: early G experiment `a1c581e5cb331269a3b4ec9a4e270a253b65ee4c`
Primary regression introduction: G productization commit `488a87c09e3902ca00fbc20ac3f44e1f95ac4597`

## Diagnosis

### High confidence: click/open-close color inversion

Early G rasterized the Codex template icon with a stable `.labelColor` and did not make the icon texture depend on `NSStatusBarButton` highlight state.

During G productization, `MenuBarNativeAnimatedIconHostView` gained a `highlighted` input and changed the raster tint to:

```swift
highlighted ? .selectedMenuItemTextColor : .labelColor
```

`StatusItemController.menuWillOpen` and `menuDidClose` were also changed to refresh the native Codex host, while host synchronization samples:

```swift
button.isHighlighted || button.cell?.isHighlighted == true
```

This creates two independent tint authorities:

- the status-button text bitmap remains a template image whose presentation tint is owned by AppKit;
- the native Codex icon is pre-rasterized into a concrete CGImage color owned by BalanceBar.

The two can therefore diverge. In particular, `menuDidClose` can observe a transient/stale AppKit highlight state and preserve the selected tint in the icon texture after the button text has already returned to its normal template presentation. This directly matches the reported post-click color inversion.

### Medium-high confidence: inactive-display icon becomes extremely faint

Performance/G intentionally separates the animated icon into a BalanceBar-owned CALayer while the status item text remains AppKit-owned template content. A single source `NSStatusBarButton` highlight/appearance state is not a reliable per-presentation tint source for multiple menu-bar presentations across displays.

The early G build that was manually observed as good used a stable `.labelColor` texture. The later productized build introduced highlight-dependent pre-rasterization without adding a real per-display tint model. Returning Codex G to the stable tint model is therefore the highest-confidence minimal regression fix.

This plan does not claim that every multi-display WindowServer presentation limitation is proven solved until the real two-display acceptance test passes.

## Proposed minimal patch

The first implementation should be deliberately narrow and should restore the early-G tint contract without reverting the Performance compositor architecture.

1. Change only the Codex native host tint behavior in `MenuBarViews.swift`.
2. Keep the existing `highlighted` argument at the call boundary temporarily so `StatusItemController.swift` does not need to change while #311 owns that file.
3. Stop using `highlighted` as a Codex texture-cache key.
4. Stop passing highlight into the Codex rasterizer.
5. Rasterize the Codex native icon with `.labelColor` for both ordinary and menu-highlight states, matching the known-good early G behavior.
6. Preserve appearance, source-image, backing-scale and geometry invalidation. Light/Dark changes must still re-rasterize correctly.
7. Leave the existing menu open/close synchronization calls untouched in the first patch. Once highlight is no longer part of the Codex visual signature, those calls become stable no-ops for tint-only changes and cannot cache a selected color. Cleanup can happen later after the shared-file ownership conflict is gone.
8. Do not change Claude compositor tint behavior in this fix. #312 is a verified Codex Performance/G regression and Claude was introduced later; broadening the change would reduce confidence and increase regression risk.

Conceptually, Codex Performance returns from:

```text
button transient highlight
    -> labelColor / selectedMenuItemTextColor
    -> pre-rasterized CGImage
    -> independent CALayer
```

to:

```text
template Codex icon
    -> stable labelColor for current appearance
    -> pre-rasterized CGImage
    -> independent CALayer
```

The Core Animation contract remains unchanged:

```text
36 states / 1.2 s / clockwise / no per-frame AppKit mutation
```

## Explicit non-goals

- Do not revert Performance/G to bitmap frame replacement.
- Do not modify Synchronized/D0.
- Do not restore the traditional renderer.
- Do not introduce per-frame `button.image`, `setNeedsDisplay`, timers, display polling, mouse tracking, private APIs or global-opacity workarounds.
- Do not change task lifecycle semantics, provider logic, polling or menu-bar layout.
- Do not change Claude compositor in the first fix.
- Do not bump version or merge before manual dual-display PASS.

## Verification contract

The implementation PR should add visual-result tests, not only counters.

Required automated coverage:

- ordinary Codex native host produces the expected visible `.labelColor`-derived pixels;
- passing `highlighted=false` and `highlighted=true` produces the same Codex texture result;
- toggling highlight alone does not increment Codex rasterization count;
- Light -> Dark and Dark -> Light still invalidate and produce the correct new appearance result;
- source-image, geometry and backing-scale changes still invalidate;
- repeated stable synchronization does not re-rasterize or reinstall the CA animation;
- 36-state / 1.2-second / clockwise animation contract remains unchanged;
- Claude focused tests remain green to prove the Codex-only change did not disturb its compositor.

Preferred test isolation: add a dedicated Codex native tint regression test file rather than modifying `StatusItemControllerTests.swift` while #311 owns the shared controller test surface.

Required manual acceptance on a Dev artifact:

1. A active / B inactive: A rotates and B remains clearly visible while paused.
2. B active / A inactive: same behavior with displays reversed.
3. Open and close the status menu repeatedly from both displays: icon and adjacent text never remain in opposite tint states.
4. Repeat in Light and Dark appearance and with visually different wallpapers.
5. Stop/start Codex and switch Performance <-> Synchronized: no stale texture or wrong color remains.
6. Confirm CPU characteristics remain those of G: no 30 fps main-thread image replacement or redraw loop returns.

If click color inversion is fixed but the inactive display remains materially fainter than the known-good early G behavior, record the dual-display portion as still unresolved rather than expanding this patch with speculative per-display hacks.

## Confidence

- Click/open-close inversion root cause and fix direction: high confidence.
- Stable `.labelColor` restoration as the safest first patch: high confidence because it directly restores the known-good early-G tint contract.
- Full inactive-display visibility resolution: medium-high confidence pending real two-display validation; the plan explicitly requires that validation before acceptance.
