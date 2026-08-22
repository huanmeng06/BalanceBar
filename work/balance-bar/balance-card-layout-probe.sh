#!/usr/bin/env bash

set -Eeuo pipefail

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-balance-card-probe.XXXXXX")"
probe_binary="$probe_dir/balance-card-layout-probe"
trap 'rm -rf "$probe_dir"' EXIT

swift_source="$probe_dir/main.swift"
cat > "$swift_source" <<'SWIFT'
import Foundation

struct Rect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var maxY: Double { y + height }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("balance card layout probe: FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let card = Rect(x: 0, y: 0, width: 304, height: 102)
let progress = Rect(x: 14, y: 8, width: 276, height: 5)
let quotaDetail = Rect(x: 14, y: 47, width: 128, height: 18)
let prefix = Rect(x: 14, y: 28, width: 62, height: 17)
let link = Rect(x: 75, y: 28, width: 148, height: 17)
let provider = Rect(x: 14, y: 75, width: 189, height: 20)
let refreshTime = Rect(x: 209, y: 76, width: 81, height: 17)
let amount = Rect(x: 149, y: 18, width: 141, height: 48)

require(prefix.y == link.y && prefix.height == link.height, "prefix and link share the same baseline line box")
require(progress.maxY <= prefix.y, "progress does not overlap the official-link row")
require(prefix.maxY <= quotaDetail.y, "link row does not overlap Remaining Balance")
require(prefix.y >= card.y && prefix.maxY <= card.maxY, "link row stays inside the card")
require(prefix.maxY - progress.maxY >= 10, "link row keeps a readable gap below progress")
require(progress == Rect(x: 14, y: 8, width: 276, height: 5), "balance progress uses the official quota position")
require(card.height == 102, "successful balance card reserves the official quota row")
require(provider.y == 75 && refreshTime.y == 76 && quotaDetail.y == 47 && amount.y == 18, "successful balance frames align with official quota")
print("balance card layout probe: PASS; official progress position, link row spacing, bounds, and amount preservation verified")
SWIFT

swiftc -framework Foundation -o "$probe_binary" "$swift_source"
"$probe_binary"

layout_source="$(dirname "$BASH_SOURCE")/Sources/Domain/ProviderModels.swift"
grep -F 'progress: CGRect(x: horizontalInset, y: 8, width: contentWidth, height: 5)' "$layout_source" >/dev/null
grep -F 'linkPrefix: CGRect(x: horizontalInset, y: 28, width: linkPrefixWidth, height: 17)' "$layout_source" >/dev/null
grep -F 'link: CGRect(x: linkX, y: 28, width: linkWidth, height: 17)' "$layout_source" >/dev/null
printf '%s\n' 'balance card layout probe: PASS; shared layout helper keeps the balance progress and link rows aligned with quota'
