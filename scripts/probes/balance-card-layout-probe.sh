#!/usr/bin/env bash
set -Eeuo pipefail

probe_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$probe_script_dir/../.." && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-balance-card-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

# Compile the production balance branch and its scalar metrics. Other quota
# sections are absent from this probe; XCTest covers their real DTOs/compositor.
python3 - "$repo_root/Sources/Domain/ProviderModels.swift" "$probe_dir/main.swift" <<'PY'
import re
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
layout = source[source.index('enum OpenCodexCardLayout {'):]

def declaration(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

metrics = declaration(source, 'struct OverviewLayoutMetrics:')
frames = declaration(source, 'struct OpenCodexCardFrames:')
names = ['cardWidth', 'metrics', 'horizontalInset', 'contentWidth', 'amountWidth',
         'amountX', 'refreshTimeX', 'quotaRowHeight', 'quotaProgressRowHeight',
         'quotaProgressHeight', 'lunaReserveNoProgressRowHeight', 'quotaAmountHeight',
         'quotaDetailHeight', 'quotaResetHeight', 'balanceHeaderGap']
constants = '\n'.join(re.search(r'^    static let ' + name + r'\b[^\n]*', layout, re.M).group() for name in names)
compression = declaration(layout, 'static var quotaProgressGapCompression:')
start = layout.index('        case .balance:\n            let linkWidth:') + len('        case .balance:')
end = layout.index('\n        }\n    }', start)
body = layout[start:end]
Path(sys.argv[2]).write_text('import AppKit\nimport Foundation\n' + metrics + '\n'
    + declaration(source, 'struct OpenCodexQuotaRowFrames:') + '\n'
    + 'struct OpenCodexOverviewSectionLayout: Equatable {}\n' + frames + '\n'
    + 'enum OpenCodexCardLayout {\n' + constants + '\n' + compression + '\n'
    + declaration(layout, 'static func quotaRowFrames(') + '\n'
    + 'static func balance(linkPrefixWidth: CGFloat = 62, includesQuotaProgress: Bool = true, includesBalanceSubtitle: Bool = true, includesBalanceRecharge: Bool = false) -> OpenCodexCardFrames {'
    + body + '\n}\n}\n')
PY

cat >> "$probe_dir/main.swift" <<'SWIFT'
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("balance card layout probe: FAIL: \(message)\n", stderr); exit(1) }
}
for progress in [false, true] {
    let ordinary = OpenCodexCardLayout.balance(includesQuotaProgress: progress)
    require(ordinary.link != nil && ordinary.linkPrefix != nil, "ordinary link row remains available")
    let compact = OpenCodexCardLayout.balance(includesQuotaProgress: progress, includesBalanceSubtitle: false)
    require(compact.link == nil && compact.linkPrefix == nil, "aggregation has no subtitle row")
    require(ordinary.cardSize.height - compact.cardSize.height == 8, "aggregation collapses subtitle space")
    require(ordinary.cardSize.height - ordinary.refreshTime.maxY == compact.cardSize.height - compact.refreshTime.maxY, "timestamp remains anchored to top")
    let recharge = OpenCodexCardLayout.balance(includesQuotaProgress: progress, includesBalanceSubtitle: false, includesBalanceRecharge: true)
    require(recharge.cardSize.height == compact.cardSize.height + 8, "recharge reuses the original subtitle slot")
    require(recharge.balanceRecharge != nil, "recharge row has a measured slot")
    if let row = recharge.balanceRecharge {
        require(row.maxY + 2 == recharge.quotaDetail.minY, "recharge sits directly below remaining balance")
        require(row.minY == ordinary.link!.minY, "recharge uses the original link subtitle baseline")
        require(recharge.amount == compact.amount, "recharge never pushes the amount into a separate row")
        if let bar = recharge.progress { require(row.minY > bar.maxY, "recharge stays above progress") }
    }
    for frames in [ordinary, compact, recharge] {
        let bounds = CGRect(origin: .zero, size: frames.cardSize)
        for rect in [frames.title, frames.refreshTime, frames.quotaDetail, frames.amount] {
            require(bounds.contains(rect), "all essential fields remain inside the card")
        }
        // Both production balance modes use a subtitle. Keep the legacy
        // one-line helper's bounds/slot checks above; its baseline fallback
        // has separate controller XCTest coverage.
        if frames.link != nil || frames.balanceRecharge != nil {
            require(frames.refreshTime.minY >= frames.amount.maxY, "timestamp does not overlap amount")
        }
        require(abs(frames.refreshTime.maxX - (frames.cardSize.width - OpenCodexCardLayout.horizontalInset)) < 0.5,
                "timestamp aligns with the shared right inset")
        if let prefix = frames.linkPrefix, let link = frames.link {
            require(prefix.minY == link.minY && prefix.height == link.height, "footer text aligns")
            require(prefix.maxY <= frames.quotaDetail.minY, "footer does not overlap detail")
            if let bar = frames.progress { require(bar.maxY <= prefix.minY, "progress does not overlap footer") }
        }
    }
}
print("balance card layout probe: PASS; production balance template, subtitle slot, bounds and amount spacing")
SWIFT
swiftc -framework AppKit -framework Foundation -o "$probe_dir/probe" "$probe_dir/main.swift"
"$probe_dir/probe"
