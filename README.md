# BalanceBar

BalanceBar is a macOS menu bar utility that mirrors CC Switch provider state and quota information. It supports provider synchronization, official OpenAI quota display, API balance display, quick provider switching, refresh controls, and Codex activity indication.

## Requirements

- macOS 14 or newer
- CC Switch installed locally
- Swift command-line tools

## Build

From the repository root, the default command builds the production app with the fixed Bundle ID `com.huanmeng06.BalanceBar.app`:

```sh
./work/balance-bar/build.sh
codesign --force --sign - work/balance-bar/build/BalanceBar.app
```

For repeatable local GUI verification, use the explicit development variant. It uses the fixed Bundle ID `com.huanmeng06.BalanceBar.dev`, writes to a separate path, and stages a temporary plist inside the ignored build output:

```sh
./work/balance-bar/build.sh dev
codesign --force --sign - work/balance-bar/build/dev/BalanceBar-dev.app
```

The production and development commands never edit the tracked `work/balance-bar/Info.plist` and never remove the other variant's app. Production output is `work/balance-bar/build/BalanceBar.app`; development output is `work/balance-bar/build/dev/BalanceBar-dev.app`. The development bundle is also named `BalanceBar Dev` so it is distinguishable when launched. The development variant's Dashboard About page shows the version with a `· Dev` suffix (for example `版本 0.10.7 · Dev` / `Version 0.10.7 · Dev`); the production About page keeps the plain version.

The build entry point recursively collects all Swift sources under `work/balance-bar`, sorts their paths deterministically, clears only the selected variant's generated output and module cache, and packages the executable, plist, `BalanceBar.icns`, `CodexIcon.svg`, `Claude.svg`, and `ClaudeThinking.svg`. Both bundles are unsigned until the ad-hoc signing command above is run.

### Development GUI verification commands

Run these after the development build when handing the app to a user for manual testing:

```sh
dev_app=work/balance-bar/build/dev/BalanceBar-dev.app
plutil -extract CFBundleIdentifier raw -o - "$dev_app/Contents/Info.plist"
open -n "$dev_app"
osascript -e 'tell application id "com.huanmeng06.BalanceBar.dev" to quit'
```

The expected identifier is `com.huanmeng06.BalanceBar.dev`. To build and inspect production, substitute `./work/balance-bar/build.sh` and `work/balance-bar/build/BalanceBar.app`; its expected identifier is `com.huanmeng06.BalanceBar.app`.

The source reads the existing local CC Switch database and configuration. Credentials are not stored in this repository.
