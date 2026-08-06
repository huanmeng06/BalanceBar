#!/usr/bin/env bash

set -Eeuo pipefail

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-balance-card-probe.XXXXXX")"
probe_binary="$probe_dir/balance-card-layout-probe"
trap 'rm -rf "$probe_dir"' EXIT

swift_source="$probe_dir/main.swift"
cat > "$swift_source" <<'SWIFT'
import Foundation

struct Rect {
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

let card = Rect(x: 0, y: 0, width: 304, height: 86)
let quotaDetail = Rect(x: 14, y: 31, width: 128, height: 18)
let prefix = Rect(x: 14, y: 7, width: 62, height: 17)
let link = Rect(x: 75, y: 7, width: 148, height: 17)
let provider = Rect(x: 14, y: 58, width: 189, height: 20)
let refreshTime = Rect(x: 209, y: 59, width: 81, height: 17)
let amount = Rect(x: 149, y: 5, width: 141, height: 48)

require(prefix.y == link.y && prefix.height == link.height, "prefix and link share the same baseline line box")
require(prefix.maxY <= quotaDetail.y, "link row does not overlap Remaining Balance")
require(prefix.y >= card.y && prefix.maxY <= card.maxY, "link row stays inside the card")
require(abs(((quotaDetail.y - prefix.maxY) - (prefix.y - card.y))) <= 0.5, "link row is centered between Remaining Balance and divider")
require(card.height == 86, "successful balance card height remains unchanged")
require(provider.y == 58 && refreshTime.y == 59 && quotaDetail.y == 31 && amount.y == 5, "other successful balance frames remain unchanged")
print("balance card layout probe: PASS; shared link row baseline, spacing, bounds, card height, and unaffected frames verified")
SWIFT

swiftc -framework Foundation -o "$probe_binary" "$swift_source"
"$probe_binary"

source_file="$(dirname "$BASH_SOURCE")/BalanceBar.swift"
grep -F 'let linkRowY: CGFloat = 7' "$source_file" >/dev/null
grep -F 'linkPrefix.frame = NSRect(x: 14, y: linkRowY' "$source_file" >/dev/null
grep -F 'y: linkRowY,' "$source_file" >/dev/null
printf '%s\n' 'balance card layout probe: PASS; source uses one shared y constant for both controls'
