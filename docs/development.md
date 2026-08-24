# BalanceBar development workflow

This workflow is based on the checked-in BalanceBar.xcodeproj,
work/balance-bar/build.sh, and
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

The application source is under work/balance-bar/. The Xcode target also
includes source files under Sources/ and the test target includes
Tests/BalanceBarTests/. The CLI build discovers Swift files recursively, so new
source files below work/balance-bar/ are included in the CLI build; the Xcode
project source list must also be updated when a new file is added to the Xcode
target.

Before editing, check the current branch and worktree without discarding any
existing user changes:

~~~sh
git status --short --branch
git branch --show-current
~~~

## Local verification order

### 1. CLI package build

The production build is the same entry point used by CI. It compiles all Swift
sources, copies the tracked plist/resources, ad-hoc signs the bundle, and
verifies the signature:

~~~sh
./work/balance-bar/build.sh
~~~

The output is work/balance-bar/build/BalanceBar.app. For a separate manual GUI
build, use the development variant; it has a distinct bundle identifier and
output path:

~~~sh
./work/balance-bar/build.sh dev
~~~

The output is work/balance-bar/build/dev/BalanceBar-dev.app. The build script
cleans only the selected generated output. It does not modify the tracked
work/balance-bar/Info.plist.

### 2. Localization probes

Standalone Swift probes compile the production localization sources
(`Sources/AppCore/Localization.swift` plus the relevant production file) and
verify the balance-query failure mapping and the network-error mapping in all
four supported languages, including the unknown-error fallback:

~~~sh
./work/balance-bar/balance-query-probe.sh
./work/balance-bar/balance-network-error-localization-probe.sh
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
  -derivedDataPath /tmp/BalanceBar-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
~~~

The Xcode app is written below
/tmp/BalanceBar-DerivedData/Build/Products/Debug/BalanceBar.app.

### 4. XCTest

Build the project and run the test target with the same DerivedData path used
by CI. The test runner stays serial because this target launches an AppKit
host application and parallel runners conflict through macOS LaunchServices:

~~~sh
xcodebuild -project BalanceBar.xcodeproj \
  -scheme BalanceBar \
  -configuration Debug \
  -derivedDataPath /tmp/BalanceBar-DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build-for-testing

xcodebuild -project BalanceBar.xcodeproj \
  -scheme BalanceBar \
  -configuration Debug \
  -derivedDataPath /tmp/BalanceBar-DerivedData \
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
watcher behavior, credential readers, balance/quota/OpenCodex clients, and
Codex/Claude activity monitoring. Network-facing tests inject URL loading
stubs; they are not a substitute for GUI testing.

### 5. Repository hygiene and path checks

Run these checks after the build/test commands:

~~~sh
git diff --check
for path in \
  docs/architecture.md \
  docs/development.md \
  BalanceBar.xcodeproj/project.pbxproj \
  BalanceBar.xcodeproj/xcshareddata/xcschemes/BalanceBar.xcscheme \
  work/balance-bar/build.sh \
  work/balance-bar/BalanceBar.swift \
  work/balance-bar/Sources/Domain \
  work/balance-bar/Sources/Services \
  work/balance-bar/Sources/Monitoring \
  work/balance-bar/Sources/UI \
  Tests/BalanceBarTests \
  .github/workflows/build-and-test.yml
do
  test -e "$path" || { echo "missing documented path: $path" >&2; exit 1; }
done
~~~

The path check verifies the architectural and workflow entry points referenced
by these documents. It does not claim that every runtime behavior is covered
by a filesystem check.

## CI equivalence

The build-and-test job in
[.github/workflows/build-and-test.yml](../.github/workflows/build-and-test.yml)
runs on macos-26 for pull requests and manual dispatch. It starts the
independent build checks in parallel, then runs XCTest after they all pass:

1. `./work/balance-bar/build.sh`, the two localization probes, and an unsigned
   xcodebuild `build-for-testing` build run in parallel;
2. an unsigned, serial `test-without-building` run with destination
   platform=macOS,arch=arm64. The CI-only test build targets arm64 because
   that is the test destination; release builds remain universal.

The build and test commands share one DerivedData directory so the test run
does not compile the app and test bundle a second time.

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
5. Run the complete verification order above and review git diff to confirm
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
dev_app=work/balance-bar/build/dev/BalanceBar-dev.app
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
