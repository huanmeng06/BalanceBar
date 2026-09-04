# Issue #300 — Native status-item animation performance plan

This is an engineering record for Issue #300. It does not change the version,
alter monitoring semantics, or authorize a merge/release.

## Production direction

The production path remains the native AppKit status item:

```text
NSStatusItem → NSStatusBarButton → one bitmap-backed menu-bar content image
```

The custom content hierarchy is retained only in an offscreen render container
that produces the button image. The button never carries that hierarchy, which
avoids the macOS 26 replicant resnapshot loop caused by attaching custom views
to the status item.

## Rendering evolution

The relevant performance boundary evolved as follows:

```text
old:             compose a complete menu-bar bitmap on every animation tick
C/B:             precompose complete frames, then button.image = frame per tick
D0-prime:        stable NSImage + mutable NSBitmapImageRep backing
                 + prebuilt raw frame pixels + redraw invalidation per tick
```

In D0-prime, the button keeps one stable `NSImage` while a running Codex
animation copies the selected raw pixel buffer into its stable bitmap
representation and requests a display. The frame tick does not assign a new
`button.image`, allocate a final image, lock focus, compose the menu-bar
content, or call the offscreen view renderer. Rebuilds happen only at semantic
or visual invalidation boundaries such as text, geometry, icon, appearance,
font, provider, or animation-backend changes.

The controller now materializes the raw buffers directly from one complete
frame at a time. Complete frame images are therefore temporary rebuild inputs,
not a second long-lived cache beside the raw buffers.

## Product animation modes

Issue #300 now exposes two user-facing Codex animation modes:

```text
性能       → BalanceBar-owned icon layer + Core Animation
同步       → D0 stable bitmap + native timer-backed pixel updates
```

Both modes use the same fixed visual contract: 36 discrete states over a
1.2-second clockwise revolution. Performance is the default and pauses the
animation on non-active displays; Synchronized is an explicit resource
trade-off that keeps all displays in sync. The persisted user preference is
separate from the internal backend enum and invalid/missing values resolve to
Performance.

When efficient setup fails for a running task, the controller temporarily uses
the synchronized backend without changing the saved preference and exposes a
localized warning in the Menu Bar settings page. The next task starts a fresh
efficient-mode attempt.

Claude's existing bitmap-backed animator retains its existing behavior.

## Dashboard handling

Dashboard menu-bar refreshes are independent from the native animation frame
tick. `DashboardCompositionController` already exits immediately when the
Dashboard is hidden or another page is mounted. The mounted menu-bar page now
uses a value signature for visible presentation, settings, icon identity,
geometry, appearance, and visibility inputs. Repeated refreshes with the same
visible inputs (including timestamp-only snapshot changes) return before text
measurement, intrinsic-size work, warning/card layout, or constraint updates.

The native animation callback may still mirror an icon frame to an already
visible preview, but it does not call the full Dashboard refresh path. The
Dashboard optimization does not introduce an overlay window or change the
native status-item renderer.

## E renderer experiment

The independent Core Animation overlay experiment is intentionally separate from
the production native implementation. Its history is preserved in Draft PR
[#302](https://github.com/huanmeng06/BalanceBar/pull/302) and branch
`experiment/issue-300-e-overlay`. It is not the current production pipeline.
Any future Beta treatment requires a separate
Issue and PR.

## Scope and validation boundary

Issue #288 activity lifecycle, provider/network polling, and Claude behavior
are outside this plan. Automated tests can verify stable image identity,
bounded composition, fixed timing, backend switching, fallback state, and
Dashboard refresh idempotence. Runtime CPU/sample and visual behavior on real
menu bars, displays, Spaces, and appearance changes still require maintainer
manual validation before this Draft PR can be accepted.
