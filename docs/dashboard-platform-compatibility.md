# Dashboard platform capabilities and compatibility matrix

This document is the product contract for Dashboard chrome ownership. Call
sites ask `DashboardPlatformCapabilities` whether the running system should
use native AppKit ownership. They do not ask whether the major version equals
26, 27, or 28.

Related reading:

- Current visual baseline: [dashboard-native-ui-baseline.md](dashboard-native-ui-baseline.md)
- Local verification commands: [development.md](development.md)

`MACOSX_DEPLOYMENT_TARGET = 14.0` and a green compile do **not** mean macOS 14
Dashboard GUI has been verified.

## Capability families

`Sources/AppCore/DashboardPlatformCapabilities.swift` is the only Dashboard
production file that reads `OperatingSystemVersion.majorVersion`. Future
majors inherit the native family until a public API changes semantics.

| Capability | Legacy compatibility (14 / 15) | Native AppKit ownership (26+) |
| --- | --- | --- |
| `usesNativeWindowSurface` | false: transparent titlebar, `clear` / non-opaque window | true: opaque titlebar, `windowBackgroundColor` |
| `usesAutomaticPageContentInsets` | false: 52pt non-scrolling page clearance, zero manual insets | true: page `NSScrollView` overlaps chrome; AppKit writes insets |
| `usesAutomaticSidebarContentInsets` | false: `titlebarHeight + 14` viewport gap | true: source-list scroll view overlaps chrome |
| `adjustsAdjacentContentSafeArea` | false | true, and the assignment still sits behind `#available(macOS 26.0, *)` |
| `supportsSplitItemAccessories` | false: skip, do not fabricate an overlay | true, and mounting still sits behind `#available(macOS 26.0, *)` |
| `usesLegacyTitlebarClearance` | true | false |

`#available` remains at the public API sites the compiler requires:

- [`NSSplitViewItem.automaticallyAdjustsSafeAreaInsets`](https://developer.apple.com/documentation/appkit/nssplitviewitem/automaticallyadjustssafeareainsets)
- [`NSSplitViewItemAccessoryViewController`](https://developer.apple.com/documentation/appkit/nssplitviewitemaccessoryviewcontroller)

Window surface flags use older AppKit (`titlebarAppearsTransparent`,
`NSColor.windowBackgroundColor`) and therefore must **not** be written as
`#available(macOS 26.0, *)`.

Do not add `if majorVersion == 27` because a screenshot looks different. Soft
and Hard scroll-edge styles are both valid system results, not product
switches. Do not invent empty accessories, `NSScrollPocket`, or a custom
Liquid Glass state machine.

## Product matrix

### macOS 14

Lowest supported system. Legacy compatibility family:

- transparent titlebar plus the existing `NSVisualEffectView` compatibility fill
- fixed old-style top clearance
- no split-item accessory

GitHub-hosted `macos-14` is deprecated as of the 2026-09-21 runner snapshot.
CI does not claim macOS 14 GUI. Confirm 14 on a real Mac before a release that
must keep that runtime.

### macOS 15

Same pre-Liquid-Glass compatibility family as 14. This family **must** be
exercised on a real runtime. CI old-runtime smoke uses GitHub-hosted
`macos-15` to load the SDK 26 / minos 14 artifact. That smoke does not replace
Dashboard visual checks.

### macOS 26

Native AppKit ownership:

- native window surface
- native Sidebar split item
- automatic page and sidebar content insets
- adjacent content safe-area adjustment
- split-item accessory when a page actually provides one

Required CI (`macos-26`) proves this family on the current official SDK and
runtime.

### Future SDK / next macOS

Default: inherit `nativeAppKitOwnership`. Add a new capability field only when
a public API changes behavior. Visual change alone is not a new branch.

## What each lane proves

| Lane | Workflow | Proves | Does not prove |
| --- | --- | --- | --- |
| Required | `.github/workflows/build-and-test.yml` job `build-and-test` on `macos-26` | SDK 26 build, probes, Dashboard XCTest on macOS 26 | macOS 14/15 GUI |
| Old-runtime smoke | same workflow, job `old-runtime-smoke` on `macos-15` | the SDK 26 / minos 14 artifact can be parsed and signature-checked on a pre-26 runner | Dashboard visual or interaction on 14/15 |
| Forward SDK | `.github/workflows/dashboard-forward-sdk.yml` | next available SDK still compiles and XCTest contracts hold | new macOS GUI |
| Policy / capability XCTest | required lane | 14.x / 15.x / 26.x / 27.x **semantic** families | pixels, scroll-edge Soft vs Hard |
| Manual checklist | development app | window chrome, scrolling, sidebar, appearance | CI green |

Old-runtime smoke is `continue-on-error` until the pre-26 label is a stable
required check. Forward SDK is `workflow_dispatch` plus an optional Monday
schedule. The schedule stays skipped until repository variable
`BALANCEBAR_FORWARD_SDK_RUNNER` is set to a label that exists at that time.

Do not disable `BALANCEBAR_REQUIRED_SDK_MAJOR` on the required lane to make an
old runner compile. Old-runtime must consume the SDK 26 artifact.

## CI runner snapshot

Recorded 2026-09-21 from
[actions/runner-images](https://github.com/actions/runner-images). Labels are
an implementation snapshot, not a frozen product contract. Re-check the table
before changing `runs-on`.

| Label | Role in this repository |
| --- | --- |
| `macos-26` (arm64) | required build + XCTest |
| `macos-15` (arm64) | old-runtime artifact smoke |
| `macos-14` | deprecated; not used as a required or matrix label |
| `xcode-27` | preview forward-SDK candidate; dispatch / optional schedule only |

Unknown labels must not be written into `runs-on`; GitHub cannot queue the
workflow.

## Manual Dashboard checklist

Use `./scripts/build.sh dev` and `build/dev/BalanceBar-dev.app`. Record macOS
version, SDK, SHA, and the exact app path. Worker / CI must not use Computer
Use, `open`, or window activation as a substitute.

Native family (macOS 26 and later, current developer machines):

1. Open Dashboard: system window background, opaque titlebar, system traffic
   lights, no legacy root `NSVisualEffectView` fill.
2. Scroll General and Menu Bar: content is pinned to the page top; AppKit
   owns insets and scroll-edge. Soft and Hard are both acceptable.
3. Collapse and expand the sidebar, enter and leave fullscreen, switch
   Light/Dark: page stays in the content item horizontal safe area.
4. Search toolbar still filters. This Issue does not change search.

Legacy family (macOS 14 or 15, real Mac only):

1. Open Dashboard: transparent titlebar and the existing compatibility fill;
   first row stays below the titlebar (page ~52pt, sidebar titlebar+14).
2. A page that asks for a content split-item accessory must skip; no fake
   overlay.
3. Light/Dark remains readable. Do not require macOS 26 scroll-edge.

If 14 or 15 was not run, the handoff must say so explicitly.
