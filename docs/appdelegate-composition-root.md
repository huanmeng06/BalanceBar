# AppDelegate composition boundary

Issue #30 records this evidence-based before/after boundary. The baseline was
the merged `a3e2eb8` tree at version `0.11.22`.

Before this change, `AppDelegate` was 2,707 lines (the type began at line 162
and ended immediately before `BalanceBarMain`). It combined:

- application lifecycle and menu-bar/dashboard construction;
- concrete Dashboard page factories and Status Links editor wiring;
- CC Switch database access coordination and filesystem watchers;
- Codex/Claude activity polling and lifecycle state;
- balance, official quota, and OpenCodex network refresh orchestration;
- snapshot caching, rendering, and cross-module callbacks.

After this change, `AppDelegate` is the application composition boundary. It
constructs one `BalanceBarApplicationCoordinator`, forwards the
`NSApplicationDelegate` lifecycle, and exposes only existing test seams. The
coordinator owns the already-accepted runtime modules and their explicit
callbacks, so `AppDelegate` has no SQL, `URLSession`, activity-monitor, or
concrete Dashboard page implementation. `ApplicationLifecycleState` guards the
single startup and teardown transaction; existing controllers continue to own
single-install behavior for the status item and Dashboard window.

After this change, `AppDelegate` is 56 lines. That line count and the static
forbidden-API boundary are asserted by
`AppDelegateCompositionTests.testAppDelegateBoundaryContainsOnlyCompositionResponsibilities`.
