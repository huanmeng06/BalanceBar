# BalanceBar

BalanceBar is a macOS menu bar utility that mirrors CC Switch provider state and quota information. It supports provider synchronization, official OpenAI quota display, API balance display, quick provider switching, refresh controls, and Codex activity indication.

## Requirements

- macOS 14 or newer
- CC Switch installed locally
- Swift command-line tools

## Build

From the repository root:

```sh
mkdir -p work/cc-switch-balance-bar/build/CCSwitchBalanceBar.app/Contents/MacOS
mkdir -p work/cc-switch-balance-bar/swift-module-cache
swiftc -parse-as-library \
  work/cc-switch-balance-bar/CCSwitchBalanceBar.swift \
  -o work/cc-switch-balance-bar/build/CCSwitchBalanceBar.app/Contents/MacOS/CCSwitchBalanceBar \
  -framework AppKit \
  -framework Foundation \
  -lsqlite3 \
  -module-cache-path work/cc-switch-balance-bar/swift-module-cache
cp work/cc-switch-balance-bar/Info.plist \
  work/cc-switch-balance-bar/build/CCSwitchBalanceBar.app/Contents/Info.plist
mkdir -p work/cc-switch-balance-bar/build/CCSwitchBalanceBar.app/Contents/Resources
cp work/cc-switch-balance-bar/CodexIcon.svg \
  work/cc-switch-balance-bar/build/CCSwitchBalanceBar.app/Contents/Resources/CodexIcon.svg
codesign --force --sign - work/cc-switch-balance-bar/build/CCSwitchBalanceBar.app
```

The source reads the existing local CC Switch database and configuration. Credentials are not stored in this repository.

