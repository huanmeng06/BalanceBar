#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-provider-cache-probe.XXXXXX")"
probe_binary="$probe_dir/provider-balance-snapshot-cache-probe"
trap 'rm -rf "$probe_dir"' EXIT

{
    printf '%s\n' 'import Foundation' 'enum OfficialQuotaWindowPreference { case fiveHour, sevenDay }' 'enum OfficialQuotaResetDisplayMode { case remaining, resetAt, both; static let defaultValue: Self = .both }' 'enum LunaReserveDisplayMode: String, CaseIterable, Equatable { case disabled, whenQuotaExhausted, always; static let defaultValue: Self = .always }' 'enum LunaReserveResetTimeMode: String, CaseIterable, Equatable { case originalQuota, lunaReserve; static let defaultValue: Self = .originalQuota }'
    cat "$source_dir/Sources/AppCore/LocalizationKeys.swift"
    printf '%s\n' 'func tr(_ key: LocalizationKey, arguments: [String] = []) -> String { key.rawValue }'
    cat "$source_dir/Sources/Domain/Snapshot.swift"
    awk '
        /^struct ProviderBalanceSnapshotCache \{/ { capture = 1 }
        /^struct ProviderChoice \{/ { exit }
        capture { print }
    ' "$source_dir/Sources/Domain/ProviderModels.swift"
    cat <<'SWIFT'

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let firstDate = Date(timeIntervalSince1970: 1_700_000_001)
let secondDate = Date(timeIntervalSince1970: 1_700_000_099)
let errorOccurredAt = Date(timeIntervalSince1970: 1_800_000_000)
let first = Snapshot.balance("Provider One", 12.34, "USD", nil, firstDate)
let replacement = Snapshot.balance("Provider One Renamed", 56.78, "CNY", nil, secondDate)
let official = Snapshot.official("Official", 88, "7-Day Quota", nil, firstDate)
var cache = ProviderBalanceSnapshotCache()

cache.store(first, clientID: "codex", providerID: "provider-one")
let sameProvider = cache.errorSnapshot(
    clientID: "codex",
    providerID: "provider-one",
    providerName: "Provider One",
    reason: "Network request timed out"
)
require(sameProvider.kind == .error, "fallback remains an error state")
require(sameProvider.overviewProvider == "Provider One", "error title uses the Provider name")
require(sameProvider.message == "Network request timed out", "error detail contains only the reason")
require(sameProvider.amount == 12.34 && sameProvider.unit == "USD", "same Provider reuses amount and unit")
require(sameProvider.date == firstDate, "same Provider reuses the exact successful date")
require(sameProvider.date != errorOccurredAt, "error occurrence time is never used as success time")
require(sameProvider.hasCachedBalance, "same Provider error reports a complete cached balance")
let timeFormatter = DateFormatter()
timeFormatter.locale = Locale(identifier: "en_US_POSIX")
timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
timeFormatter.dateFormat = "HH:mm:ss"
require(timeFormatter.string(from: sameProvider.date!) == timeFormatter.string(from: firstDate), "error time text comes from the exact cached success date")
require(timeFormatter.string(from: sameProvider.date!) != timeFormatter.string(from: errorOccurredAt), "error time text does not use the error occurrence date")

let otherProvider = cache.errorSnapshot(
    clientID: "codex",
    providerID: "provider-two",
    providerName: "Provider Two",
    reason: "Unrecognized balance format"
)
require(otherProvider.amount == nil && otherProvider.unit == nil, "cross-Provider balance is isolated")
require(otherProvider.date == nil, "cross-Provider successful date is isolated")
require(otherProvider.overviewLargeAmount == "—", "cross-Provider error displays no amount")
require(!otherProvider.hasCachedBalance, "cross-Provider error does not report cached balance")

let otherClient = cache.errorSnapshot(
    clientID: "claude",
    providerID: "provider-one",
    providerName: "Provider One",
    reason: "The balance endpoint returned an error"
)
require(otherClient.amount == nil && otherClient.date == nil, "cross-client cache is isolated")

let empty = ProviderBalanceSnapshotCache().errorSnapshot(
    clientID: "codex",
    providerID: "missing",
    providerName: "Missing Provider",
    reason: "Balance query is unavailable"
)
require(empty.provider == "Missing Provider" && empty.message == "Balance query is unavailable", "no-cache error preserves Provider and pure reason")
require(empty.amount == nil && empty.unit == nil && empty.date == nil, "no-cache error has no balance or successful date")
require(empty.overviewLargeAmount == "—", "no-cache error displays the em dash")
require(!empty.hasCachedBalance, "no-cache error keeps the empty-time state")

cache.store(official, clientID: "codex", providerID: "official")
let officialMiss = cache.errorSnapshot(
    clientID: "codex",
    providerID: "official",
    providerName: "Official",
    reason: "Synthetic reason"
)
require(officialMiss.amount == nil && officialMiss.date == nil, "official Snapshot is never cached as third-party balance")

cache.store(replacement, clientID: "codex", providerID: "provider-one")
let replaced = cache.errorSnapshot(
    clientID: "codex",
    providerID: "provider-one",
    providerName: "Provider One Renamed",
    reason: "Network request failed"
)
require(replaced.amount == 56.78 && replaced.unit == "CNY", "new success replaces the old cached balance")
require(replaced.date == secondDate, "replacement keeps the new success date exactly")
require(replaced.overviewProvider == "Provider One Renamed", "current Provider name is independent from cached display name")

print("provider balance snapshot cache probe: PASS; same-key fallback; Provider/client isolation; empty and official misses; replacement; exact success date; pure error content")
SWIFT
} | swiftc -framework Foundation -o "$probe_binary" -

"$probe_binary"
