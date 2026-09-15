# Issue #298 implementation plan

This document is the implementation specification for #298. The goal is to add a second, independent warning under Menu Bar > Preview when the status item is intentionally hidden by the `Only While Running` policy, while preserving the existing menu-bar-space warning and allowing both warnings to appear at the same time.

## 1. Treat menu-bar-space visibility and runtime-policy visibility as independent facts

The current implementation has two distinct state machines:

- `StatusItemVisibilityStateMachine` determines whether AppKit/WindowServer has hidden the item because there is not enough menu-bar space.
- `MenuBarIconDisplayStateMachine` determines whether BalanceBar itself should display the item under `MenuBarIconDisplayMode.onlyWhileRunning`, including idle confirmation and the selected post-task delay.

Do not duplicate the task-end timestamp or delay calculation in the Dashboard. The authoritative runtime-policy result is already `MenuBarIconDisplayStateMachine.shouldDisplay`.

The Dashboard needs to represent two independent facts:

- hidden because menu-bar space is insufficient;
- hidden because `Only While Running` reached its post-task hide point.

The implementation must therefore avoid a mutually exclusive `if / else if` presentation. If both facts are true, both rows are visible.

A low-plumbing implementation may extend the published status presentation so it can represent the product of those two booleans, for example with explicit combined cases plus helpers:

```swift
enum StatusItemVisibility: Equatable {
    case unknown
    case visible
    case hiddenByMenuBarSpace
    case hiddenByRuntimePolicy
    case hiddenByMenuBarSpaceAndRuntimePolicy

    var isHiddenByMenuBarSpace: Bool {
        self == .hiddenByMenuBarSpace || self == .hiddenByMenuBarSpaceAndRuntimePolicy
    }

    var isHiddenByRuntimePolicy: Bool {
        self == .hiddenByRuntimePolicy || self == .hiddenByMenuBarSpaceAndRuntimePolicy
    }
}
```

The important invariant is that `StatusItemVisibilityStateMachine` remains responsible only for AppKit/menu-bar-space evidence. Runtime-policy state must be combined when the controller publishes presentation state; do not feed runtime-policy hiding back into the space-detection state machine.

## 2. Publish runtime-policy transitions immediately

`MenuBarIconDisplayStateMachine` already becomes authoritative when its `shouldDisplay` changes. `StatusItemController.applyMenuBarIconDisplayPolicy()` must publish a Dashboard-visible state transition whenever the policy changes the item from visible to intentionally hidden or back to visible.

When `iconDisplayMode` or `iconDisplayDelay` changes through `StatusItemController.update(...)`, apply the display policy immediately after updating the state machine. In particular, switching from `Only While Running` back to `Always Visible` must restore the menu-bar item and remove the warning without waiting for a later activity sample.

Do not introduce an additional Dashboard timer.

## 3. Preserve confirmed overflow evidence while the item is intentionally hidden

There is a subtle interaction between the two conditions. Today `verifyStatusItemAttachment(...)` feeds `statusItem.isVisible` into `StatusItemVisibilityStateMachine`. Once runtime policy intentionally sets `NSStatusItem.isVisible = false`, that evidence is no longer valid for deciding whether the item would fit in the menu bar. Feeding the intentional hidden state into the space detector can collapse a previously confirmed `.hiddenByMenuBarSpace` state to `.unknown`, making the two warnings unable to coexist reliably.

When `menuBarIconDisplayStateMachine.shouldDisplay == false`, attachment verification should therefore skip AppKit space-evidence ingestion and retain the last confirmed space state. It should also skip re-anchoring, because an intentionally hidden item is not an attachment failure.

When the item becomes displayable again, the existing attachment check must run and refresh the real space state. This is preferable to inventing a probe item while the real item is intentionally hidden.

## 4. Add an independent Preview warning row

`DashboardMenuBarPage` currently builds the Preview card as:

```text
Current Layout
Overflow Warning (conditional)
```

Extend it to:

```text
Current Layout
Overflow Warning (conditional)
Runtime Policy Warning (conditional)
```

Keep the existing overflow row and its `Open Settings` action unchanged. Add dedicated identifiers for the new row, label, and button so AppKit tests can locate them deterministically.

Suggested Simplified Chinese copy:

> 当前已启用「仅在运行时显示」，任务结束后的隐藏延迟已到期，因此菜单栏图标暂时隐藏。

Button:

> 立即设置

The warning should be shown from the controller's published runtime-policy state, not inferred from `preferences.menuBarIconDisplayMode` alone.

All supported BalanceBar languages must receive localized copy using the existing localization system; do not introduce user-facing hard-coded language switches in `DashboardMenuBarPage`.

## 5. Preview separators and dynamic card height

Adding a third row means the Preview card has two separators. Update separator visibility from the visible row set rather than controlling only `previewSeparators.first`.

For the fixed row order `[currentLayout, overflowWarning, runtimeWarning]`, the required presentation is:

| Overflow | Runtime | Separator after Current Layout | Separator after Overflow |
| --- | --- | --- | --- |
| false | false | hidden | hidden |
| true | false | visible | hidden |
| false | true | visible | hidden |
| true | true | visible | visible |

Continue using `DashboardSettingsComponents.settingsCardHeight(...)` after row visibility changes; do not hard-code separate heights for zero/one/two warnings.

## 6. `立即设置` is same-page scrolling, not System Settings

The new button is intentionally different from the existing overflow warning's `Open Settings` button.

It must **not**:

- open macOS System Settings;
- switch the Dashboard sidebar section;
- reconstruct the page at a different section.

It must stay on the current Menu Bar page and scroll the page's existing `NSScrollView` downward until the `菜单栏图标显示` / `Menu Bar Icon Display` row (`iconDisplayModeRow`) is visible.

The settings page already uses `NSScrollView` with a flipped `DashboardSettingsDocumentView`. Use AppKit's native scrolling path rather than calculating a fixed Y offset. The target is a dynamic row whose position changes with localization, window width, hidden rows, and the number of Preview warnings.

Recommended behavior:

```swift
func revealIconDisplayModeSetting() {
    guard let row = iconDisplayModeRow else { return }
    row.window?.layoutIfNeeded()
    row.scrollToVisible(row.bounds)
}
```

A small local target/action helper or an equivalent page-local action is preferable to routing this navigation all the way through `AppDelegate`: the action is internal navigation within a page already owned by `DashboardMenuBarPage`.

If the destination row is not currently visible because its parent setting is disabled, fall back to the nearest visible controlling row instead of temporarily mutating preferences merely to make scrolling possible.

## 7. Required behavior matrix

The implementation is complete only if all of these transitions work without waiting for unrelated refreshes:

1. `Always Visible` + enough space: no warning.
2. `Always Visible` + insufficient space: existing overflow warning only.
3. `Only While Running` + task running: no runtime warning.
4. Task just ended but post-task delay has not expired: no runtime warning.
5. Delay expired and the display state machine hides the item: runtime warning appears immediately.
6. A new task begins: runtime warning disappears immediately and the item is shown.
7. User changes back to `Always Visible`: runtime warning disappears immediately and the item is shown.
8. Confirmed overflow and runtime-policy hidden are both active: both warning rows are visible at once.
9. Overflow clears while runtime policy remains hidden: only the runtime warning remains once the real status item can be re-evaluated.
10. Runtime policy clears while overflow remains: only the existing overflow warning remains.
11. `立即设置` scrolls the current page to `iconDisplayModeRow` and never invokes `openSystemMenuBarSettings`.

## 8. Tests

Add focused regression coverage rather than relying only on screenshots.

### `AppDelegateCompositionTests`

- The runtime display state becomes hidden only after idle confirmation and selected delay.
- Switching back to `.alwaysVisible` restores display immediately.
- Published presentation can represent menu-bar-space hidden + runtime-policy hidden simultaneously.
- Intentional runtime hiding does not erase previously confirmed overflow state.

### `DashboardPreferencePagesTests`

- Overflow-only, runtime-only, neither, and both warning combinations.
- Two independent rows and separator visibility for all four combinations.
- Preview card height grows/shrinks correctly as warnings appear and disappear.
- `立即设置` changes the actual `NSScrollView` position so `iconDisplayModeRow` intersects the clip view's visible bounds.
- The runtime-warning button does not route to the existing System Settings action.
- New copy exists for all supported languages.

Run the full test target after focused tests. The implementation should not change the task monitor's semantics, status-item rendering mode, activity animation path, or the existing menu-bar-space detector's confirmation thresholds.

Closes #298 when the implementation and tests above are present and passing.
