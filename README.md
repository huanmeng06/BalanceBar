# BalanceBar

BalanceBar is a macOS menu bar utility that mirrors CC Switch provider state and quota information. It supports provider synchronization, official OpenAI quota display, API balance display, quick provider switching, refresh controls, and Codex activity indication.

## Requirements

- macOS 14 or newer
- CC Switch installed locally
- Swift command-line tools

## Build

From the repository root:

```sh
mkdir -p work/balance-bar/build/BalanceBar.app/Contents/MacOS
mkdir -p work/balance-bar/swift-module-cache
swiftc -parse-as-library \
  work/balance-bar/BalanceBar.swift \
  -o work/balance-bar/build/BalanceBar.app/Contents/MacOS/BalanceBar \
  -framework AppKit \
  -framework Foundation \
  -framework SwiftUI \
  -lsqlite3 \
  -module-cache-path work/balance-bar/swift-module-cache
cp work/balance-bar/Info.plist \
  work/balance-bar/build/BalanceBar.app/Contents/Info.plist
mkdir -p work/balance-bar/build/BalanceBar.app/Contents/Resources
cp work/balance-bar/BalanceBar.icns \
  work/balance-bar/build/BalanceBar.app/Contents/Resources/BalanceBar.icns
cp work/balance-bar/CodexIcon.svg \
  work/balance-bar/build/BalanceBar.app/Contents/Resources/CodexIcon.svg
cp work/balance-bar/Claude.svg \
  work/balance-bar/build/BalanceBar.app/Contents/Resources/Claude.svg
cp work/balance-bar/ClaudeThinking.svg \
  work/balance-bar/build/BalanceBar.app/Contents/Resources/ClaudeThinking.svg
codesign --force --sign - work/balance-bar/build/BalanceBar.app
```

The source reads the existing local CC Switch database and configuration. Credentials are not stored in this repository.
