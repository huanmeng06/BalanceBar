#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-preferences-probe.XXXXXX")"
probe_binary="$probe_dir/preferences-migration-probe"
trap 'rm -rf "$probe_dir"' EXIT

{
    printf '%s\n' 'import Foundation' 'enum AppPreferences {' '    static let showOpenCodexMenuKey = "showOpenCodexMenu"' '    static let menuBarIconOffsetXKey = "menuBarIconOffsetX"' '    static let menuBarIconOffsetYKey = "menuBarIconOffsetY"' '    static let menuBarAmountOffsetXKey = "menuBarAmountOffsetX"' '    static let menuBarAmountOffsetYKey = "menuBarAmountOffsetY"' '}'
    awk '
        /^struct PreferencesMigrationPlan \{/ { capture = 1 }
        /^private func migrateLegacyPreferencesIfNeeded/ { exit }
        capture { print }
    ' "$source_dir/BalanceBar.swift"
    cat <<'SWIFT'

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let production: [String: Any] = [
    "showMenuBarIcon": NSNumber(value: false),
    "activityPollInterval": NSNumber(value: 0.5),
    "appLanguage": "en",
    "unknownSecret": "must not migrate",
    "NSStatusItem Preferred Position Item-0": "must not migrate"
]
let local: [String: Any] = [
    "showMenuBarIcon": NSNumber(value: true),
    "showMenuBarReset": NSNumber(value: false),
    "showMenuBarAmount": NSNumber(value: true),
    "unknownLocalValue": "must not migrate"
]

let emptyTarget: [String: Any] = [:]
let selected = PreferencesMigrationPlan.selectedValues(
    target: emptyTarget,
    production: production,
    local: local
)
require((selected["showMenuBarIcon"] as? NSNumber)?.boolValue == false, "production wins")
require((selected["activityPollInterval"] as? NSNumber)?.doubleValue == 0.5, "production value migrates")
require((selected["showMenuBarReset"] as? NSNumber)?.boolValue == false, "local fills missing production key")
require((selected["showMenuBarAmount"] as? NSNumber)?.boolValue == true, "local fallback value migrates")
require(selected["unknownSecret"] == nil, "unknown production key is excluded")
require(selected["unknownLocalValue"] == nil, "unknown local key is excluded")
require(selected["NSStatusItem Preferred Position Item-0"] == nil, "system position key is excluded")

let existingTarget: [String: Any] = [
    "showMenuBarIcon": NSNumber(value: true),
    "appLanguage": "zh-Hans"
]
let selectedWithExisting = PreferencesMigrationPlan.selectedValues(
    target: existingTarget,
    production: production,
    local: local
)
require(selectedWithExisting["showMenuBarIcon"] == nil, "existing target value is preserved")
require(selectedWithExisting["appLanguage"] == nil, "existing target language is preserved")

var mergedTarget = existingTarget
for (key, value) in selectedWithExisting { mergedTarget[key] = value }
let repeatedSelection = PreferencesMigrationPlan.selectedValues(
    target: mergedTarget,
    production: production,
    local: local
)
require(repeatedSelection.isEmpty, "migration is idempotent")

let noSources = PreferencesMigrationPlan.selectedValues(
    target: [:],
    production: [:],
    local: [:]
)
require(noSources.isEmpty, "missing source domains are safe")

print("preferences migration probe: PASS; production priority; local fallback; existing target preserved; whitelist only; system/unknown keys excluded; idempotent; missing sources safe")
SWIFT
} | swiftc -framework Foundation -o "$probe_binary" -

"$probe_binary"
