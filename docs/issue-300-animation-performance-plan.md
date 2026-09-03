# Issue #300 — Status Item Animation Performance: Root Cause and Implementation Plan

This document is intentionally **analysis and implementation guidance only**. It does not change production behavior, animation timing, rendering, monitoring, lifecycle semantics, polling, versioning, or release state.

## Scope and decision boundary

Issue #300 is a performance follow-up to #284. The #284 bitmap-backed `NSStatusItem` architecture must remain intact. Issue #288 task lifecycle semantics must also remain intact. The target of #300 is narrower: reduce the continuous CPU cost paid while a task is already logically running and the task icon animation is active.

The current evidence supports a two-layer cause:

1. BalanceBar performs per-frame full status-item bitmap composition even though the rotating icon frames themselves are already cached.
2. Every resulting frame is assigned to `NSStatusBarButton.image` at 30 Hz, which causes AppKit/CoreAnimation/status-item invalidation and can wake replicant/shadow work.

A correct fix therefore needs both **final-frame precomposition** and **lower image replacement frequency**. Caching icon-only frames without reducing final `button.image` updates is insufficient.

## Current code path and complete causal chain

The current Codex rotation path is centered in `work/balance-bar/Sources/UI/MenuBar/MenuBarAnimation.swift` and `StatusItemController.swift`.

`RotatingTemplateImageView` currently defines:

- `frameCount = 36`
- `rotationDuration = 1.2`
- `rotationFrameInterval = 1.2 / 36`

This produces exactly 30 timer callbacks per second. `makeRotationFrames(from:)` already pre-renders the 36 rotated icon images, so the raw rotation transform itself is not performed on every tick.

The timer calls `advanceRotation()`, which selects the next cached icon frame and calls `displayImage(frame)`. `displayImage` updates the image view and then invokes `onFrameImageChanged`.

`StatusItemController.configureStatusItem()` wires `onFrameImageChanged` to:

```text
if usesBitmapContent {
    composeMenuBarContentBitmap(iconImage: image)
}
actions.frameImageChanged(image)
```

The default bitmap-backed mode therefore crosses from an icon-only cached frame into a fresh **full status-item image composition** every animation tick.

`refreshMenuBarContentBitmap()` currently does two useful things after semantic/layout changes:

1. renders the full offscreen content tree and assigns it to the status button;
2. hides the icon and renders an icon-free `cachedMenuBarTextBitmap` for later animation composition.

However, `composeMenuBarContentBitmap(iconImage:)` then executes on every animation tick. It allocates a new `NSImage`, locks graphics focus, redraws the cached text bitmap, computes icon placement, draws the current icon frame, unlocks focus, and finally assigns the new image to `button.image`.

The effective chain is therefore:

```text
30 Hz Timer
→ RotatingTemplateImageView.advanceRotation
→ cached icon frame selected
→ displayImage
→ onFrameImageChanged
→ StatusItemController.composeMenuBarContentBitmap
→ allocate complete NSImage
→ draw cached text bitmap
→ draw current icon frame
→ unlockFocus
→ NSStatusBarButton.image replacement
→ AppKit button/cell invalidation
→ status-item window / scene update
→ CoreAnimation transaction + display cycle
→ some updates wake status-item replicant snapshot / shadow / blur work
```

This matches Issue #300's runtime `sample`: the timer path reaches `composeMenuBarContentBitmap` and `NSStatusBarButton setImage:`, while the same sample contains substantial AppKit/QuartzCore transaction work and status-item replicant/shadow paths.

## Why #284 is not the regression

#284 changed the default rendering architecture from a live custom view hierarchy attached directly to the status item to a bitmap-backed status button. That removed the severe macOS 26 replicant resnapshot loop caused by a live custom hierarchy. The current source still preserves this design in `configureMenuBarContentPresentation()`:

- bitmap mode keeps `menuBarContentStack` in `bitmapRenderContainer` and makes the button image-only;
- traditional rendering remains an explicit fallback path.

The current performance issue is different. BalanceBar itself intentionally changes the button image at animation frequency. AppKit therefore receives legitimate visual mutations and has work to do. The existence of those updates does not imply that #284 failed; it means #284 removed the pathological self-sustaining resnapshot loop and exposed the residual cost of an intentionally high-frequency animation.

The fix for #300 must not restore a live custom view or otherwise bypass #284.

## Why #288 must remain untouched

#288 stabilizes the logical running/idle lifecycle and controls when the animation should be running. `StatusItemController.updateActivity(...)` receives already-resolved activity state and calls `updateActivityIcon()`. `observeCodexTaskSample(...)` deliberately avoids re-running the animation transition path for repeated stable samples.

That work reduces start/stop churn but cannot reduce the steady-state cost of an animation that remains active for tens of seconds. Once `isCodexTaskRunning == true` and animation policy allows motion, the 30 Hz timer continues independently.

#300 should therefore change only animation rendering/caching cadence, not activation confirmation, ambiguous-idle grace, compaction semantics, terminal handling, monitor polling, or refresh lifecycle.

## Recommended implementation

### 1. Change Codex rotation to 15 Hz while preserving 1.2 s rotation duration

In `MenuBarAnimation.swift`, reduce the Codex rotation frame count from 36 to 18 while leaving `rotationDuration = 1.2`.

Expected timing:

```text
18 frames / 1.2 s = 15 fps
```

The rotation angular velocity remains unchanged: one full turn still takes 1.2 seconds. Only angular sampling changes from 10° steps to 20° steps.

Do not introduce a user-facing FPS preference. The 15 fps value is an internal implementation decision already accepted by the Issue.

Do not change Claude animation timing unless profiling shows that Claude uses the same problematic final composition path and the Issue scope is explicitly extended. The safest initial implementation is to make the common final-frame cache support both sources while only changing the Codex cadence specified by #300.

### 2. Move the cache boundary from `cachedMenuBarTextBitmap` to complete button frames

The highest-value architectural change is in `StatusItemController`.

Today the cache boundary is:

```text
static text bitmap cached
+ current icon frame
→ compose a new full image every timer tick
```

The target should be:

```text
semantic/layout change
→ render static/text base once
→ precompose every final animation frame once
→ cache final button-ready NSImages

timer tick
→ choose cached final image
→ button.image = cachedFrame[index]
```

The per-tick path should contain no `NSImage(size:)`, no `lockFocus`, no text redraw, no placement calculation, and no full bitmap construction.

A practical representation is an internal bitmap animation cache owned by `StatusItemController`, containing at minimum:

- the final precomposed frames in display order;
- enough identity/signature data to know which semantic/layout state generated them;
- optionally a mapping from icon frame object identity to final frame index if retaining the current `onFrameImageChanged(NSImage?)` callback contract.

Do not make this cache a second source of semantic truth. `Snapshot`, `MenuBarSettings`, `activeClient`, and the existing icon source remain authoritative. The cache is derived rendering data only.

### 3. Rebuild complete frames only at real invalidation points

The simplest safe invalidation strategy is to rebuild the final animation frame cache whenever the existing bitmap content is regenerated by `refreshMenuBarContentBitmap()` and whenever the semantic icon frame source changes.

That existing method is already reached after the layout-affecting operations that matter, including snapshot/text changes, font changes, width changes, visibility of icon/amount/reset content, offsets, and bitmap/traditional rendering switches. Reusing this lifecycle minimizes the risk of maintaining a separate list of preferences.

After `refreshMenuBarContentBitmap()` has established:

- final `bitmapRenderContainer` bounds;
- `menuBarBitmapImagePlacement`;
- icon position and size;
- icon-free text bitmap;

it has all geometry required to generate the complete animation frames.

Recommended invalidation/rebuild triggers:

- menu-bar primary or secondary text change;
- Provider/effective snapshot change;
- width change;
- font size change;
- icon show/hide change;
- amount/reset display change;
- icon/amount X/Y offset change;
- source icon/client change;
- bitmap mode reconfiguration;
- backing scale or geometry change that causes bitmap regeneration;
- any existing call site that invokes `refreshMenuBarContentBitmap()` because final visual content changed.

Appearance changes should be reviewed carefully. Because the final images are template images and AppKit applies tinting, light/dark appearance may not require pixel regeneration if only template tint changes. Do not add appearance invalidation unless tests or visual verification show it is necessary. Avoid speculative extra rebuilds.

### 4. Keep the timer callback minimal

In bitmap mode, `onFrameImageChanged` should no longer call the existing per-frame `composeMenuBarContentBitmap(iconImage:)` implementation.

The bitmap path should instead resolve the already-precomposed final frame and assign it to the button. The traditional rendering fallback should retain the existing `NSImageView` behavior and should not be forced through bitmap-only caches.

The desired hot path is approximately:

```text
Timer fires
→ advance frame index
→ retrieve cached final button image
→ assign button.image
```

`actions.frameImageChanged(image)` should be reviewed separately. It currently mirrors animation frames to downstream UI such as the Dashboard preview. Preserve its semantic role, but ensure that no downstream listener rebuilds the status item or triggers additional expensive layout work. Existing tests already assert that preview frame updates do not refresh the whole Dashboard menu-bar page.

### 5. Do not accidentally rebuild the cache at 15 Hz

A common implementation error would be to add a `precomposedFrames` array but rebuild it from `onFrameImageChanged` or from a method reached by every frame callback. That would merely move code without eliminating work.

The cache rebuild function should be callable only from semantic/layout/source invalidation paths. Timer-driven frame delivery must be read-only with respect to the frame cache.

### 6. Preserve static image restoration and restart semantics

`stopRotating()` currently invalidates the timer, resets animation state, and restores the semantic source image. That behavior must remain.

In bitmap mode, stopping an animation must display the current static menu-bar bitmap immediately and not leave the last rotated frame visible. Starting a later task must reuse or rebuild the correct frame cache for the current text, provider, offsets, and geometry.

The same constraints apply when switching between Codex and Claude: a stale cache from one icon source must never be reused for the other.

## Suggested implementation shape

A low-risk implementation can keep most existing APIs and change only rendering responsibilities:

1. `RotatingTemplateImageView` continues to own animation timing, source image, icon frame sequence, start/stop, and frame index.
2. Expose a narrow read-only seam for the current source's pre-rendered icon frames, or provide a callback when the source frame sequence changes.
3. `StatusItemController` owns a derived `[NSImage]` cache of complete button images in bitmap mode.
4. `refreshMenuBarContentBitmap()` renders the static state, updates the icon-free base bitmap, and rebuilds complete animation frames for the current animation source when appropriate.
5. `onFrameImageChanged` maps the icon frame to its corresponding cached complete image and assigns it directly.
6. When bitmap mode is disabled, no final-frame cache is used and the traditional rendering path remains unchanged.

Avoid coupling `StatusItemController` to timer internals. The controller should consume frame identity/order, not own a second animation timer.

## Tests that should be added or changed

### `MenuBarAnimationTests`

Update the Codex timing contract:

- `frameCount == 18`;
- `rotationDuration == 1.2`;
- `rotationFrameInterval == 1.2 / 18`;
- frame sequence still cycles deterministically back to zero;
- start/stop/restart remains idempotent.

Keep the reduce-motion and preference policy tests unchanged.

### Final-frame cache tests

Add focused `StatusItemController` or composition tests covering:

- bitmap mode generates exactly the expected number of precomposed Codex frames;
- the cache is reused when no semantic/layout/source input changed;
- changing primary/secondary text rebuilds the cache;
- changing provider/effective snapshot rebuilds the cache;
- changing width rebuilds the cache;
- changing font size rebuilds the cache;
- changing icon/amount offsets rebuilds the cache;
- hiding the icon removes/invalidates animated icon content;
- changing source icon/client invalidates old frames;
- stop restores static bitmap;
- restart uses frames matching the current state;
- traditional rendering does not depend on the bitmap animation cache.

Prefer behavior/state assertions over brittle source-string tests where possible. If an explicit test seam is necessary, expose only cache count/build generation or a small derived diagnostic under test access; do not expose mutable cache internals to production callers.

### Hot-path regression test

Add a source-level or injectable-compositor regression asserting that the timer-driven frame path does not call the full compositor. The key contract is not merely that a cache exists, but that `compose`/allocation is absent from the steady-state tick.

If feasible, extract pure composition into a helper with a counted test closure so tests can assert:

- N final frames are composed during cache build;
- advancing multiple animation ticks does not increase composition count;
- one real invalidation causes exactly one cache rebuild.

## Validation plan

Automated validation should include:

- focused animation/cache tests;
- full XCTest suite;
- `xcodebuild ... build-for-testing`;
- production build;
- dev build;
- `git diff --check`;
- existing bitmap/traditional rendering regression coverage.

Manual performance validation must use one BalanceBar instance and comparable Codex workload.

Record idle CPU first. Then run a task for at least 30 seconds and observe a stable animation interval. Capture a `sample` of the Dev process and compare against the #300 baseline.

Expected signatures after implementation:

- Codex animation timer / `advanceRotation` frequency approximately halves from 30 Hz to 15 Hz;
- the steady-state timer stack no longer contains full `composeMenuBarContentBitmap` work;
- `NSStatusBarButton setImage:` frequency is approximately halved;
- AppKit/CA display-cycle activity decreases materially;
- `_updateReplicantsUnlessMenuIsTracking` and `_redrawReplicantSnapshot` sample counts decrease materially;
- idle CPU remains unchanged;
- animation-disabled baseline remains unchanged;
- visual rotation still completes in about 1.2 seconds.

The Issue baseline to compare against is approximately 18–25% task-period CPU with animation enabled and approximately 1–5% with animation disabled. The implementation should be judged by measured reduction, not merely by the presence of a cache.

## Risks and failure modes

The primary correctness risk is stale derived frames. A cache keyed too narrowly can display old quota text, provider content, offsets, or geometry while the animation is running. Rebuilding from the existing `refreshMenuBarContentBitmap()` lifecycle is safer than inventing an independent preference-signature system.

The primary performance risk is rebuilding final frames too frequently. If periodic usage refreshes change text every few seconds, a rebuild of 18 frames is acceptable because it replaces 15 full compositions per second with a bounded burst only when content actually changes. However, avoid triggering the rebuild from monitor samples or any frame callback that does not change visible content.

The primary architectural risk is bypassing #284 by introducing a live custom status-item subview for animation. Do not do this.

The primary lifecycle risk is touching #288 state logic to make animations stop more aggressively. That would mix unrelated semantics into a rendering optimization and can regress compaction/grace behavior. Do not do this.

## Explicit non-goals

This Issue should not change:

- #288 activation/debounce/grace/compaction/terminal semantics;
- Codex or Claude monitor evidence detection;
- activity polling intervals;
- usage refresh cadence;
- Provider/OpenCodex network behavior;
- status-item bitmap-backed default architecture;
- the traditional rendering compatibility switch;
- user-facing FPS settings;
- app version/build number;
- release, merge, or deployment state.

## Recommended implementation order

1. Add/adjust tests that express 15 fps and final-frame cache behavior.
2. Reduce Codex frame count to 18 while retaining 1.2 s rotation duration.
3. Introduce a derived complete-frame cache in `StatusItemController` for bitmap mode.
4. Rebuild that cache only from existing semantic/layout/source invalidation points.
5. Replace per-tick full composition with cached final-image lookup and assignment.
6. Verify static restore, client switching, icon hiding, offsets, typography, provider/text updates, and traditional rendering.
7. Run full automated validation.
8. Perform the Issue's A/B performance measurement and `sample` comparison before marking the PR ready.

This plan intentionally leaves the PR in Draft until the runtime performance acceptance criteria are measured on macOS 26 under a real task workload.
