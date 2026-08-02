# BalanceBar

BalanceBar is a macOS menu bar utility that mirrors CC Switch provider state and quota information. It supports provider synchronization, official OpenAI quota display, API balance display, quick provider switching, refresh controls, and Codex activity indication.

## Requirements

- macOS 14 or newer
- CC Switch installed locally
- Swift command-line tools

## Build

From the repository root:

```sh
./work/balance-bar/build.sh
codesign --force --sign - work/balance-bar/build/BalanceBar.app
```

The build entry point recursively collects all Swift sources under `work/balance-bar`, sorts their paths deterministically, clears the previous build and module cache, and packages the executable, `Info.plist`, `BalanceBar.icns`, `CodexIcon.svg`, `Claude.svg`, and `ClaudeThinking.svg`. The unsigned bundle is written to `work/balance-bar/build/BalanceBar.app` before the ad-hoc signing command above.

The source reads the existing local CC Switch database and configuration. Credentials are not stored in this repository.

### Xcode

Open `BalanceBar.xcodeproj` in Xcode and use the shared `BalanceBar` scheme. The project target references the same `work/balance-bar/BalanceBar.swift`, `Info.plist`, and four bundle resources used by the CLI build; it does not copy those inputs into a second source tree or require a personal Team ID in the project file.

For a command-line, unsigned Debug build from the repository root:

```sh
xcodebuild -list -project BalanceBar.xcodeproj
xcodebuild -project BalanceBar.xcodeproj -scheme BalanceBar -configuration Debug -derivedDataPath /tmp/BalanceBar-DerivedData CODE_SIGNING_ALLOWED=NO build
```

The Xcode-built app is written under the supplied DerivedData path at `Build/Products/Debug/BalanceBar.app`. The existing `./work/balance-bar/build.sh` flow remains the CLI build and packaging entry point.
