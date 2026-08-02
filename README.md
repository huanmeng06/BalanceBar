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
