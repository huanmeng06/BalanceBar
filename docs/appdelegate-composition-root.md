# AppDelegate composition boundary

Issue #30's baseline is the merged `a3e2eb8` tree at version `0.11.22`.

## Before

The baseline `AppDelegate` occupied 2,707 lines. It combined application
lifecycle, Dashboard/page construction, Status Links editing, CC Switch file
watching and switching, activity polling, Provider balance/quota requests,
OpenCodex recognition/card requests, snapshot caching, and rendering.

The first implementation attempt only renamed that type to
`BalanceBarApplicationCoordinator`; Scheduler review rejected it as a
superficial wrapper. That approach was removed before this ownership split.

## After ownership map

`AppDelegate` remains the application composition root. Its 1,031 lines now
construct modules, own application-level presentation state, install the
status item, route lifecycle/cross-module callbacks, and preserve reopen/
terminate/menu semantics. It has no SQL, URLSession, activity-monitor, file
watcher, Provider request, concrete Dashboard page, NSView, or NSWindow
implementation.

| Type | Lines | Owns |
| --- | ---: | --- |
| `DashboardCompositionController` | 333 | Dashboard window/page composition, Provider/preference page mounting, Status Links editor and scroll lifecycle |
| `ProviderRefreshCoordinator` | 276 | Standard balance/quota requests, cadence, quick-switch summaries, fallback snapshots |
| `OpenCodexRefreshCoordinator` | 265 | OpenCodex recognition, preference switching, card planning and card requests |
| `ActivityCoordinator` | 171 | Codex/Claude monitor polling, frontmost-app observer and activity timer |
| `ProviderSwitchCoordinator` | 68 | CC Switch stop/write/reopen transaction and Provider validation |
| `CCSwitchDatabaseWatcher` | 73 | SQLite/WAL/directory file watchers and coalesced change callback |

Each module receives explicit values and callbacks. No service locator, DI
framework, third-party dependency, or cyclic ownership was introduced.

`AppDelegateCompositionTests` scans the complete AppDelegate class and verifies
the ownership map by checking the concrete module sources. It intentionally
does not use AppDelegate line count as the boundary proof.
