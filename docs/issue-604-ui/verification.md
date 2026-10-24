# Verification — Issue #604

## Scope and outcome

- Initial base: `882b39f2bd9fb8f94ae53e44ce23e711fd1c547e` (PR #603).
- Level 1 Debug Xcode build: PASS, SDK 26.5, arm64, unsigned.
- Development package: `./scripts/build.sh dev`; `codesign --verify --deep --strict build/dev/BalanceBar-dev.app`: PASS.
- `git diff --check`: PASS.
- All three localization probes: PASS. Resource parity: 653 keys × 12 languages.
- Final UI/search run: **131 tests, 0 failures**. Includes 10 new `ModManagementUITests`, 93 search tests and existing panel/context/coordinator/visibility regressions.
- Earlier core/localization run: **201 tests, 0 failures**, including 170 core/localization tests listed below and 31 panel/coordinator/render tests. One of the 31 was the temporary historical screenshot exporter; it was removed after generating the before images. Final UI tests supersede that run's overlapping UI evidence.
- Intermediate search expansion: 2 test methods failed with 6 assertions, identifying missing Mod catalog keys and pre-Mod row-count expectations. Both were fixed in this PR; all 93 search tests then passed in the final 131-test run. No tests skipped or deleted to mask a failure.
- Local complete XCTest / hosted Full CI: NOT RUN. This PR remains Draft; Full acceptance and real CLI/Desktop Code checks belong to the combined #603 lane.
- GUI, native window navigation/resizing, VoiceOver and real CLI acceptance: **pending maintainer testing**. Offscreen images are layout evidence only.

## Commands

Common Xcode prefix (task-specific DerivedData, serial AppKit):

```sh
xcodebuild -project BalanceBar.xcodeproj -scheme BalanceBar \
  -configuration Debug -derivedDataPath /tmp/BalanceBar-Issue604-DerivedData \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -parallel-testing-enabled NO
```

The initial build appended `build`. Test runs appended each applicable `-only-testing:BalanceBarTests/<Class>` below, then `test`.

Final run: `ModManagementUITests`, `ModOnboardingPanelTests`, `ModPanelSyncContextTests`, `ModSyncCoordinatorTests`, `ModPromptVisibilityTests`, `DashboardPageSearchTests`.

Earlier run: `ModManagementUITests`, `ModOnboardingPanelTests`, `ModPanelSyncContextTests`, `ModSyncCoordinatorTests`, plus these 170 core/localization tests:

| Class | Passed |
| --- | ---: |
| ClaudeQuotaPipelineTests | 40 |
| SnapshotInboxTests | 28 |
| QuotaMergeEngineTests | 17 |
| LocalizationTests | 61 |
| ModInstallPlanArgsTests | 2 |
| ModInstallerTests | 5 |
| ModInstallerUninstallTests | 5 |
| ModSyncDetectorTests | 4 |
| ModSyncStatusTests | 8 |

Probes and artifact checks:

```sh
./scripts/probes/localization-resource-probe.sh
./scripts/probes/balance-query-probe.sh
./scripts/probes/balance-network-error-localization-probe.sh
./scripts/build.sh dev
codesign --verify --deep --strict build/dev/BalanceBar-dev.app
git diff --check
```

The first un-escalated query probe could not write the default Swift module cache under the filesystem sandbox. Re-running with filesystem access succeeded; this was not a code/probe regression.

The protected implementation files (`ModInstaller`, `ModSyncStatus`, `ModSyncDetector`, quota sources/pipeline/merge code, `Info.plist`) have no diff from the initial base. `ModOnboardingController` changes only its copy enum; install/uninstall methods are unchanged. `ModSyncCoordinator` changes only presentation ownership and localization wiring.

See [manual acceptance and screenshots](README.md). No version bump, Ready transition, release, merge or deployment was performed.
