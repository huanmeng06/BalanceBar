# BalanceBar development workflow

This workflow is based on the checked-in BalanceBar.xcodeproj,
scripts/build.sh, and
[.github/workflows/build-and-test.yml](../.github/workflows/build-and-test.yml).
Run commands from the repository root. It contains no personal paths, signing
identities, credentials, tokens, cookies, or machine-specific project settings.

## Prerequisites and source layout

- macOS 14 or newer;
- Swift command-line tools;
- Xcode with the shared BalanceBar scheme;
- CC Switch installed only when manually testing the running app's provider
  integration. Tests use fixtures, stubs, temporary files, or nonexistent
  paths and should not require a user's provider database.

The application source is under Sources/. The Xcode target also
includes source files under Sources/ and the test target includes
Tests/BalanceBarTests/. The CLI build discovers Swift files recursively, so new
source files below Sources/ (except LaunchAgent) are included in the CLI build; the Xcode
project source list must also be updated when a new file is added to the Xcode
target.

Before editing, check the current branch and worktree without discarding any
existing user changes:

~~~sh
git status --short --branch
git branch --show-current
~~~

## Three verification levels (single source of truth)

Choose the smallest sufficient verification based on behavior and risk, not a
mechanical filename-to-test map. Report actual commands, pass/fail/skip counts,
unexecuted coverage and reasons after each change. A build is not a test PASS.

- **Level 1, each edit:** `git diff --check`, syntax checks for changed scripts
  (`bash -n path/to/script.sh`), and an unsigned Debug Xcode `build` when Swift,
  resources, project configuration or dependencies change. Documentation-only
  edits need no app build. For CI edits run `actionlint -shellcheck=` (1.7.7 or
  newer, configured to recognize macos-26),
  `python3 .github/scripts/ci-policy-test.py` and
  `bash .github/scripts/classify-version-only-diff-test.sh`.
- **Level 2, affected behavior:** select real XCTest classes/methods and probes
  after tracing affected callers. Examples currently include `ResponseParsersTests`,
  `OpenCodexCardLayoutTests`, `DashboardWindowControllerTests`; localization uses
  the three probes below. Check current `Tests/BalanceBarTests` when names change.
  Expand coverage for persistence, redaction, credentials/permissions, concurrency,
  state machines, shared Provider logic, infrastructure and test facilities.
  Add tests or explicit manual steps when targeted tests cannot establish behavior.
- **Level 3, Ready/merge acceptance:** run the complete checks below; GitHub Full
  CI is the final enforcement lane. If infrastructure changes make targeted testing
  unreliable, expand to Full. Document GUI acceptance separately.

Reuse a **task-specific** DerivedData directory across local iterations, never a
shared directory concurrently cleaned by other workers. For example:

~~~sh
TASK_DERIVED_DATA=/tmp/BalanceBar-Issue498-DerivedData
xcodebuild -project BalanceBar.xcodeproj -scheme BalanceBar \
  -configuration Debug -derivedDataPath "$TASK_DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -parallel-testing-enabled NO \
  -only-testing:BalanceBarTests/ResponseParsersTests test
~~~

Select a different unique directory for your Issue. `test` incrementally builds
in that directory; `test-without-building` is appropriate only after a compatible
`build-for-testing` at the same source/configuration. CLI swiftc and Xcode compile
independently: they do not share a build cache. Do not enable parallel AppKit tests
or introduce cross-runner DerivedData caching.

## Level 3 local reference commands

### 1. CLI package build

The production build is the same entry point used by CI. It compiles all Swift
sources, copies the tracked plist/resources, ad-hoc signs the bundle, and
verifies the signature:

~~~sh
./scripts/build.sh
~~~

The output is build/BalanceBar.app. For a separate manual GUI
build, use the development variant; it has a distinct bundle identifier and
output path:

~~~sh
./scripts/build.sh dev
~~~

The output is build/dev/BalanceBar-dev.app. The build script
cleans only the selected generated output. It does not modify the tracked
Resources/Info.plist.

### 2. Localization probes

Standalone Swift probes compile the production localization sources
(`Sources/AppCore/Localization.swift` plus the relevant production file) and
verify the balance-query failure mapping and the network-error mapping across
all concrete supported languages, including the two Traditional Chinese
regional resources and the unknown-error fallback. The
resource probe checks key parity for every source language and, when given an
app bundle, checks that every language is packaged:

~~~sh
./scripts/probes/localization-resource-probe.sh
./scripts/probes/balance-query-probe.sh
./scripts/probes/balance-network-error-localization-probe.sh
~~~

### 3. Xcode project/build target

Confirm the shared project and scheme are visible:

~~~sh
xcodebuild -list -project BalanceBar.xcodeproj
~~~

Run an unsigned Debug build into a disposable DerivedData directory:

~~~sh
xcodebuild -project BalanceBar.xcodeproj \
  -scheme BalanceBar \
  -configuration Debug \
  -derivedDataPath /tmp/BalanceBar-YourIssue-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
~~~

The Xcode app is written below
/tmp/BalanceBar-YourIssue-DerivedData/Build/Products/Debug/BalanceBar.app.

### 4. XCTest

Build the project and run the test target with the same DerivedData path used
by CI. The test runner stays serial because this target launches an AppKit
host application and parallel runners conflict through macOS LaunchServices:

~~~sh
xcodebuild -project BalanceBar.xcodeproj \
  -scheme BalanceBar \
  -configuration Debug \
  -derivedDataPath /tmp/BalanceBar-YourIssue-DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build-for-testing

xcodebuild -project BalanceBar.xcodeproj \
  -scheme BalanceBar \
  -configuration Debug \
  -derivedDataPath /tmp/BalanceBar-YourIssue-DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  -parallel-testing-enabled NO \
  test-without-building
~~~

The test target is BalanceBarTests. Its files cover composition-root wiring,
AppKit dashboard/window behavior, menu-bar geometry, preferences and
localization, pure domain models, response parsers, CC Switch repository and
watcher behavior, credential readers, balance/quota clients, and
Codex/Claude activity monitoring. Network-facing tests inject URL loading
stubs; they are not a substitute for GUI testing.

The XCTest host is patched at build time to `LSUIElement` so LaunchServices
does not activate it on launch, and `LSMultipleInstancesProhibited` is cleared
so tests can run while the production app is open. `main()` then switches the
host to accessory and yields key focus before XCTest attaches. Layout and Core
Animation still run, but test windows stay transparent, below other apps'
normal windows, and must not become key. Do not add
`NSApp.activate(ignoringOtherApps:)`, `setActivationPolicy(.regular)`,
`makeKeyAndOrderFront`, `makeKey()`, `orderFront`, or `orderFrontRegardless`
to tests; use `ApplicationWindowPresentation` when a window must be connected
to the window server. `orderFrontRegardless` is swizzled because it stacks a
window above every other app. Already-visible windows are re-parked without
that call so each test case cannot force them back to the top.

### 5. Repository hygiene and path checks

Run these checks after the build/test commands:

~~~sh
git diff --check
for path in \
  docs/architecture.md \
  docs/development.md \
  docs/dashboard-platform-compatibility.md \
  BalanceBar.xcodeproj/project.pbxproj \
  BalanceBar.xcodeproj/xcshareddata/xcschemes/BalanceBar.xcscheme \
  scripts/build.sh \
  scripts/probes \
  scripts/probes/deployment-artifact-smoke.sh \
  Sources/App/BalanceBar.swift \
  Sources/AppCore \
  Sources/Domain \
  Sources/Services \
  Sources/Monitoring \
  Sources/UI \
  Sources/LaunchAgent \
  Resources \
  Resources/images \
  Resources/lang \
  Tests/BalanceBarTests \
  .github/workflows/build-and-test.yml \
  .github/workflows/dashboard-forward-sdk.yml
do
  test -e "$path" || { echo "missing documented path: $path" >&2; exit 1; }
done
~~~

The path check verifies the architectural and workflow entry points referenced
by these documents. It does not claim that every runtime behavior is covered
by a filesystem check.

## CI equivalence

[Build and Test](../.github/workflows/build-and-test.yml) explicitly subscribes
to `opened`, `synchronize`, `reopened`, `ready_for_review`, and
`converted_to_draft`, and `edited`. It has no path filter. Every validation run performs diff, tracked
shell syntax, classifier/policy tests and actionlint checks on Ubuntu.

| Event/state | Validation | Merge result |
| --- | --- | --- |
| Draft open/push/reopen/convert | Fast Debug build + localization probes for non-documentation changes; documentation adds/edits skip app build | PR merge gate fails deliberately; Draft cannot merge |
| Ready open/push/reopen/convert | Full CLI + probes + build-for-testing + all serial XCTest + artifact/smoke | Gate requires this run's successful Full |
| Ready, entire PR version-only | Explicit `PR-wide version-only exemption (no XCTest)` | Gate accepts the named exemption, never reports XCTest PASS |
| Ready target-branch edit | Force Full, including version-only PRs | Fresh gate checks base ref and SHA |
| Draft target-branch edit | Fast | Gate fails for Draft |
| Title/body edit only | Separate metadata acknowledgement; no compilation | No new merge credential; active validation unaffected |
| workflow_dispatch, any branch/state | Always Full, no version exemption | Separate `Manual Full result`, never a PR merge credential |

Fast uses one unsigned Debug Xcode compilation, no CLI packaging, XCTest,
upload or old-runtime smoke. Tests or Xcode project changes select
`build-for-testing` to compile affected test code too, without executing XCTest;
other changes use `build`. Unknown paths, CI/scripts/project/resources/tests,
adds of non-documentation files, deletions/type changes/renames expand to build
and all lightweight localization probes. Only Markdown additions/edits and a few
explicit metadata paths avoid compilation. This is deliberately conservative.
The scope is the entire PR from merge base to event head, including earlier commits.

Full retains macos-26 / SDK 26 / minos 14 checks, independent CLI/probe/Xcode
builds in parallel, then serial XCTest reusing **that run's** DerivedData. Test
summary records head and checkout SHA plus xcresult total/passed/failed/skipped
counts, or explicitly states that no result exists. CLI, probes and Xcode each
report elapsed seconds; step timestamps cover setup, XCTest and artifact work.

The SDK 26 CLI app is tarred before upload to preserve execute bits. macos-15
`Pre-Liquid-Glass artifact smoke` restores it and checks load commands/signature;
its `continue-on-error: true` behavior is retained. It is advisory, not GUI
acceptance; a smoke failure is not a new required failure. A cancelled/skipped
smoke after a successful Full does fail the gate because that run did not finish
its contracted scope; version-only exemptions intentionally skip smoke. Full version exemptions
skip artifact/smoke, just as before.

`PR merge gate` has no job dependencies: it is created immediately for validation events, so same-SHA
Draft/Ready transitions replace the old check with a pending result while Full
runs. It has no `always()` cancellation override, so cancelling the workflow
cancels the gate too. It polls current-attempt evidence via the read-only Actions jobs API. Only scope
may be reused: when absent in the current attempt, the most recent prior scope
in the same run must have succeeded with the same head SHA. A newer failed,
cancelled or skipped scope blocks reuse. Full/version exemption/smoke are never
borrowed from another attempt or run. Existing current-attempt scope takes
precedence, including its queued/failure state. Evidence job IDs and attempts are
reported in the summary. GitHub may assign carried jobs a new attempt/job ID
while preserving old execution timestamps; only scope may use that carry.
Full/version/smoke must start and finish at or after the current attempt start.
API calls are bounded and fail closed on failure. It accepts
only same-run Full success or the successful explicit version exemption after
scope validation (current or explicitly reused) and independently repeating the PR-wide version classifier. It re-reads live PR state and fails for Draft/closed or changed
head/base SHA and **base ref**, rejecting missing identity fields. Hosted check-run API shows checks attached to the PR **head SHA**. Checkout
tests GitHub's synthetic merge commit (`GITHUB_SHA`), and summaries identify both
SHAs. Do not confuse check attachment with the integrated commit under test.
Failure/cancellation/queued/missing/skipped Full never becomes a Full credential.
Target changes subscribe to `edited`: Ready requires Full even when version-only;
Draft retains Fast. Title/body-only edits publish `PR metadata edit (no merge
credential)` in a unique metadata concurrency group and do not replace/cancel
PR merge gate. Edited events lacking reliable change information revalidate.

PR validation events share concurrency by PR number and cancel obsolete runs; dispatch uses
a separate group and check name. On a merge conflict GitHub may not trigger PR CI;
resolve/update and rerun, never bypass the missing gate.

Required jobs absent after their prerequisites succeed receive a **60-second**
grace period, then fail with `Re-run all jobs` instructions. Queued/in-progress
jobs are distinct from missing; downstream absence is not timed while its
prerequisite runs. Existing running/queued jobs retain the 23-minute overall
limit. Re-run failed jobs can reuse a successful scope, but gate-only or
smoke-only reruns without fresh current-attempt Full are unsupported and fail
quickly. SDK artifacts use `BalanceBar-macos26-sdk-attempt-<N>` for both upload
and download, preventing cross-attempt collisions or stale downloads.

Version classification requires the entire PR effective diff to modify only
`Resources/Info.plist`, with both nonempty string version fields changed and all
other text, mode and plist validity preserved. Code then version commits remain
Full. The classifier's one-argument form retains its legacy single-commit
interface; PR CI always uses two arguments. Release and Forward SDK
workflows are unchanged.

### Owner activation (not enforced until configured)

At implementation baseline (2026-10-13), main protection returned HTTP 404
`Branch not protected`; repository rulesets returned `[]`. CI alone does not
prevent merges. We intentionally do not enable a new required context while
open PR #495 still publishes the old `macOS build and test` context.

After this workflow is merged, update **every still-open PR**, including #495 if
still open, from main and verify the new gate exists and passes. Then an Owner:

1. Open repository Settings → Rules → Rulesets → New branch ruleset. Name it
   `main CI`, target branch `main`, enforcement `Active`.
2. Require a pull request and status checks; add **exactly `PR merge gate`**,
   source GitHub Actions. Enable requiring branches up to date before merging
   so main updates cannot reuse stale integration checks. Do not select Fast,
   conditional Full, version exemption, smoke or Manual Full result as required.
3. Preserve any separately configured review/bypass policy; do not add broad
   bypasses or remove existing protection. If using classic Branch protection
   instead, apply the same status name/source and strict up-to-date option there.
4. Verify a Ready PR with latest Full failure/cancellation is blocked and a fresh
   successful run passes. Verify #495 no longer waits for a missing context.

Until that Owner step is confirmed, report **gate implemented, required check
NOT activated**. Settings activation is a separate repository operation; a green
workflow alone does not prove enforcement. Merge queues are not configured here;
adding a queue requires `merge_group` support as a separate change.

Event/check semantics: [GitHub PR events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request)
and [protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
Measured timings and validation evidence live in
[CI validation evidence](ci-validation-498.md); workflow duration includes queues
and is not XCTest duration.

[.github/workflows/dashboard-forward-sdk.yml](../.github/workflows/dashboard-forward-sdk.yml)
is a compile + XCTest probe for a later SDK. It is `workflow_dispatch` plus an
optional Monday schedule that stays skipped until repository variable
`BALANCEBAR_FORWARD_SDK_RUNNER` is set. Do not set
`BALANCEBAR_REQUIRED_SDK_MAJOR` on that lane. It is not new-macOS GUI
acceptance.

The product matrix that says what each lane proves is
[dashboard-platform-compatibility.md](dashboard-platform-compatibility.md).
`MACOSX_DEPLOYMENT_TARGET = 14.0` does not mean macOS 14 Dashboard GUI has
been verified.

Keep local verification aligned with those commands. Do not add a workflow
change as part of a documentation or feature change unless the Issue explicitly
includes CI work.

## Adding a feature

1. Identify the owning area in
   [docs/architecture.md](architecture.md). Keep the allowed dependency
   direction and avoid expanding AppDelegate by convenience.
2. Put pure values/planning in Sources/Domain or Sources/AppCore, external I/O
   in Sources/Services, recurring process/system observation in
   Sources/Monitoring, and presentation in the matching Sources/UI area.
3. Add an injectable action, transport, reader, or coordinator boundary when
   the behavior touches the network, filesystem, process, database, timer, or
   notification center.
4. Add focused XCTest coverage for the new pure rule or seam. Use the
   dashboard/window tests for controller wiring and layout ownership; reserve
   visual claims for the manual handoff.
5. Run the risk-appropriate Level 1/2 checks during iteration and Level 3 before
   merge acceptance. Review git diff to confirm
   that unrelated project, resource, workflow, and version files did not
   change.

## Terminal tests versus GUI tests

Terminal verification can establish that sources compile, the bundle is
packaged, paths and metadata exist, pure/service seams behave as asserted, and
the Xcode test target passes. It cannot establish the user's visual or
interactive experience.

Manual GUI verification is performed by the user with the development bundle
when a change affects the running app. Applicable checks include opening and
closing the menu-bar item and Dashboard, resizing/dragging the native window,
checking provider switching and refresh behavior, and confirming light/dark or
accessibility settings when those are in scope. The user may run the commands
below after building; a worker must not run them as a substitute for the user's
manual test:

~~~sh
dev_app=build/dev/BalanceBar-dev.app
plutil -extract CFBundleIdentifier raw -o - "$dev_app/Contents/Info.plist"
open -n "$dev_app"
osascript -e 'tell application id "com.huanmeng06.BalanceBar.dev" to quit'
~~~

The expected development bundle identifier is
com.huanmeng06.BalanceBar.dev. Do not treat open, AppleScript, browser UI
control, Computer Use, screenshots, or a successful build as proof that a GUI
acceptance step passed. The worker records the exact manual steps and waits for
the user's PASS or FAIL report.

## Safety and information boundaries

- Never commit API keys, tokens, cookies, credential contents, local database
  copies, Team IDs, or personal absolute paths.
- Do not document an unimplemented refactor as current behavior; label future
  architecture as proposed until code and tests establish it.
- Do not change a version number as part of ordinary implementation work when
  the Issue says versioning is a separate Scheduler decision.
- Keep generated build output untracked and use a separate development bundle
  for manual testing so it is distinguishable from production.

## External Codex skill migration (separate sync task)

This PR changes repository files only. Installed skills outside the repository
(e.g. `github-issue-worker/SKILL.md`) are not automatically updated. In a separate
user-authorized skill-sync task, replace any unconditional per-edit Full test
instruction with the following rule:

> Follow `docs/development.md` as the single verification contract. Each edit
> receives Level 1 and affected-behavior Level 2 checks; expand for high-risk or
> uncertain impact. Record exact commands, pass/fail/skip and unexecuted scope.
> Use task-specific reusable DerivedData and serial AppKit XCTest. Ready CI is
> Level 3 final enforcement; Fast success is not Full acceptance. Do not duplicate
> a test mapping or CI policy in the skill. Preserve existing user/manual review,
> release authorization and deployment boundaries.

No installed skill was modified, and no Scheduler review/deployment stage is added.

## Deferred Fast CI performance risks

`build-for-testing` still compiles the test target; test/project edits may cost
more as that target grows. `fetch-depth: 0` also downloads full history to find
merge bases reliably. Track these costs using existing step timings; split tests
or fetch history on demand only in a separately measured follow-up. This Issue
does not introduce either optimization.
