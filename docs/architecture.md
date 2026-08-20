# BalanceBar architecture

This document describes the architecture present in the repository. It is a
working map for new changes, not a claim that the source tree is already split
into separate Swift modules. The Xcode project and CLI build compile the
sources into one BalanceBar target; the directories below are ownership and
dependency boundaries used by the codebase.

## Runtime composition

The application starts at BalanceBarMain in
[work/balance-bar/BalanceBar.swift](../work/balance-bar/BalanceBar.swift).
It performs the single-instance check, creates NSApplication, installs an
AppDelegate, and starts the AppKit run loop. AppDelegate is the current
composition root: it constructs repositories, clients, coordinators, the
menu-bar controller, and the dashboard composition controller, then connects
them with closures and action structs.

~~~text
BalanceBarMain
    -> AppDelegate (composition root and lifecycle owner)
        -> StatusItemController (menu-bar UI)
        -> DashboardCompositionController
            -> DashboardWindowController and page/component views
        -> ProviderRefreshCoordinator
        -> OpenCodexRefreshCoordinator
        -> ProviderSwitchCoordinator
        -> ActivityCoordinator
        -> CCSwitchDatabaseWatcher
        -> repositories, clients, and AppPreferences
~~~

The composition root owns application state and translates user actions into
service/coordinator calls. A page or view should receive a small input value or
action closure; it should not construct a repository, open a database, or start
a network request by itself.

## Current source map

| Area | Current paths | Responsibility |
| --- | --- | --- |
| Entry and app state | work/balance-bar/BalanceBar.swift, work/balance-bar/AppPreferences.swift | AppKit entry point, AppDelegate, lifecycle, shared application state, preferences, logging, and composition wiring. |
| AppCore | work/balance-bar/Sources/AppCore/ | Cross-cutting UI-independent rules such as localization and dashboard scroll-bound calculations. |
| Domain | work/balance-bar/Sources/Domain/ | Value types and pure planning rules: AssistantClient, BalanceQuery, provider models, Snapshot, StatusLink, and OpenCodex card planning. |
| Services | work/balance-bar/Sources/Services/ | CC Switch SQLite access/watchers, credential readers, URL sessions, balance/quota clients, response parsing, provider refresh, OpenCodex refresh, and provider switching. |
| Monitoring | work/balance-bar/Sources/Monitoring/ | Codex/Claude activity observation and ActivityCoordinator, including process, SQLite, NSWorkspace, timer, and notification integration. |
| Menu-bar UI | work/balance-bar/Sources/UI/MenuBar/ | NSStatusItem, status menu content, menu-bar geometry, views, and activity animation. |
| Dashboard UI | work/balance-bar/Sources/UI/Dashboard/ | Dashboard composition, native window/delegate, components, preference/provider pages, and the status-link editor. The status-link editor is the existing SwiftUI island hosted by AppKit. |
| Tests | Tests/BalanceBarTests/ | XCTest coverage for domain rules, parsers, clients, repositories, monitoring, menu-bar geometry, dashboard components/pages/window behavior, preferences, and composition wiring. |
| Packaging inputs | work/balance-bar/build.sh, work/balance-bar/Info.plist, and the four image files in work/balance-bar/ | CLI compilation, bundle metadata, and resources. These are build inputs, not feature ownership. |

The Xcode groups mirror these paths. The target source list is declared in
[BalanceBar.xcodeproj/project.pbxproj](../BalanceBar.xcodeproj/project.pbxproj);
the CLI build discovers all Swift files below work/balance-bar in sorted order.

## Dependency direction

The following is the allowed direction for new code. Because this is one Swift
target, the compiler cannot enforce the direction as separate modules; code
review and tests enforce it.

| Layer | May depend on | Must not own |
| --- | --- | --- |
| Entry/composition | Domain, services, monitoring, UI controllers, preferences, AppKit lifecycle | New feature-specific SQL, URLSession details, or page layout. |
| UI controllers and views | Domain value types, AppCore rules, AppKit/SwiftUI, injected inputs/actions | Repositories, credential lookup, URLSession, direct database writes, or unowned timers/observers. |
| Monitoring | Domain identifiers/state and the system/process APIs it monitors | Dashboard layout or menu action wiring. |
| Services and coordinators | Domain types, parsing, Foundation/AppKit system integration, injected transports/readers | View construction or presentation policy. |
| Parsing and domain | Foundation value operations and pure inputs | AppKit views, UserDefaults, network/database access, or credentials. |
| Tests | Any production type under test plus XCTest | Real credentials, personal files, or GUI interaction in place of a testable seam. |

The current AppDelegate is intentionally the composition root, so existing
wiring there is not evidence that every future behavior belongs there. Keep new
implementation behind the narrowest existing boundary and pass it into the
root through an initializer, coordinator, or action closure.

## Placement rules for common additions

### A new Dashboard page

Put page-specific layout and actions under
work/balance-bar/Sources/UI/Dashboard/. Use these existing subdirectories
where they fit:

- general/preferences pages: Pages/Preferences/;
- provider list/detail pages: Pages/Providers/;
- reusable dashboard rows/cards: Components/;
- status-link editing and scroll anchoring: StatusLinks/.

Register the page in the dashboard composition/page selection path and provide
only the state and actions it needs. The page may call an injected action that
the composition root wires to a service; it must not create a concrete client
or repository. A new page is not a reason to add another application delegate
or to move its business rules into BalanceBar.swift.

### A system service or external integration

Put reusable I/O and external-state access in Sources/Services/. Examples in
the current tree are CCSwitchRepository, CCSwitchDatabaseWatcher,
CredentialReader, BalanceAPIClient, OfficialQuotaClient, and
OpenCodexRepository. Keep transport and file/process seams injectable when the
behavior can be tested without the real system.

Put recurring activity observation in Sources/Monitoring/; the current
CodexActivityMonitor, ClaudeCodeActivityMonitor, and ActivityCoordinator own
that concern. A service may use documented AppKit system integration such as
NSWorkspace when that is part of the external operation, but its result must
flow back as domain state or an action rather than a view reference.

### Provider parsing

Keep provider-neutral value types and provider identifiers in
Sources/Domain/ProviderModels.swift and BalanceQuery.swift. Keep JSON/data
interpretation in Sources/Services/Parsing/ResponseParsers.swift, where the
parsers are pure and fixture-testable. Keep HTTP, credential, endpoint, and
retry behavior in the corresponding service client (BalanceAPIClient,
OfficialQuotaClient, or OpenCodexRepository). Provider pages consume the
resulting models; they do not parse response payloads.

### A native window or AppKit capability

Dashboard window creation, window delegate behavior, title-bar drag policy,
and window-owned teardown belong in
Sources/UI/Dashboard/DashboardWindowController.swift. Dashboard page selection
and page inputs belong in DashboardCompositionController.swift. Status-item and
menu-bar behavior belongs in Sources/UI/MenuBar/, especially
StatusItemController.swift.

Using AppKit is allowed and is already the main UI implementation. The status
link editor is the current, deliberately bounded SwiftUI host inside the AppKit
dashboard. New native behavior should use the public framework API that owns
it and should preserve the controller's lifecycle boundary. Do not turn the
composition root into a second window controller or add a global event monitor
without an explicit owner and teardown path.

## What is fact versus future design

The following are current facts: the app has one Swift target; AppDelegate
constructs the current services/coordinators; dashboard and menu-bar code has
been extracted into the paths above; and the Xcode target includes the listed
test target. A future split into Swift packages or framework targets is not
implemented by this document.

A later migration to additional native controllers, a different window
toolkit, or a fully separated dependency-injection module would be a new design
decision. Treat it as proposed until a code change, tests, and manual GUI
review establish it. This document does not claim that current runtime
behavior, accessibility, appearance, or visual layout has changed beyond the
source that is actually present.

## Anti-regression rules

- Do not put SQL, URLSession, credential lookup, or a concrete Dashboard page
  back into AppDelegate.
- Do not let a page or reusable view reach into global application state when an
  input/action boundary already exists.
- Do not move pure parsing or planning into AppKit controllers.
- Do not make a service depend on a view to report progress or errors.
- Add or extend an XCTest seam for new domain, parsing, service, coordinator, or
  controller behavior before relying on GUI-only confirmation.
