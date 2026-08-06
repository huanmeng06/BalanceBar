#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-error-card-layout-probe.XXXXXX")"
probe_binary="$probe_dir/error-card-layout-probe"
trap 'rm -rf "$probe_dir"' EXIT

{
    printf '%s\n' 'import AppKit' 'import CoreText'
    awk '
        /^private enum ErrorCardLayout \{/ { capture = 1 }
        /^private struct Snapshot \{/ { exit }
        capture { print }
    ' "$source_dir/BalanceBar.swift"
    cat <<'SWIFT'

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

// Sanitized display-only fixtures. This probe never touches the network, the
// real CC Switch database, credentials, or the running app. No real token,
// Bearer value, or auth configuration is used.

let longChinese = "tokenshop：未启用 usage script，无法查询余额，请先在 CC Switch 中启用对应的用量脚本后重试，本条消息用于验证错误详情多行换行与完整展示"
let longEnglish = "Failed to load balance because the configured usage script is not enabled; please enable it in CC Switch and try again, this text is intentionally long to verify wrapping"
let unbrokenURL = "https://tokenshop.example.test/v1/usage?error_code=E401_INVALID_TOKEN&detail=token_revoked&hint=reauthorize_via_cc_switch_settings"
let mixed = "tokenshop 未启用 usage script（error_code=E401_INVALID_TOKEN）https://tokenshop.example.test/v1/usage?code=12345 请检查后重试"
let short = "tokenshop：未启用"

// Independent CoreText wrapping cross-check: the number of lines the framesetter
// produces for the full string, times the font line height, is the height the
// label really needs. The layout helper must provide at least that much so no
// text is clipped (a truncated tail would be a hidden truncation).
func coreTextNeededHeight(_ text: String, width: CGFloat) -> CGFloat {
    let attributed = NSMutableAttributedString(string: text)
    attributed.addAttribute(.font, value: ErrorCardLayout.detailFont, range: NSRange(location: 0, length: attributed.length))
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byCharWrapping
    attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
    require(!lines.isEmpty, "framesetter produces at least one line for \(text.prefix(20))")
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    CTLineGetTypographicBounds(lines[0], &ascent, &descent, &leading)
    return CGFloat(lines.count) * (ascent + descent + leading)
}

let samples: [(String, String)] = [
    ("long-chinese", longChinese),
    ("long-english", longEnglish),
    ("unbroken-url", unbrokenURL),
    ("mixed", mixed),
    ("short", short)
]

for (name, sample) in samples {
    let detailH = ErrorCardLayout.detailHeight(for: sample, width: ErrorCardLayout.contentWidth)
    if name == "short" {
        require(detailH == ErrorCardLayout.singleLineDetailHeight, "short text keeps the compact single-line height")
    } else {
        require(detailH > ErrorCardLayout.singleLineDetailHeight, "\(name) wraps to multiple lines")
        // The full string must fit: helper height >= independent CoreText need.
        let needed = coreTextNeededHeight(sample, width: ErrorCardLayout.contentWidth)
        require(detailH + 0.5 >= needed, "\(name) detail height fits the full wrapped text (helper=\(detailH), needed=\(needed))")
    }

    let frames = ErrorCardLayout.errorFrames(for: sample)
    let card = NSRect(origin: .zero, size: frames.cardSize)

    // The card never shrinks below the compact size.
    require(frames.cardSize.height >= ErrorCardLayout.minimumCardHeight, "\(name) card height stays at or above the compact height")

    // The detail uses the full content width and its measured height.
    require(frames.detail.width == ErrorCardLayout.contentWidth, "\(name) detail spans the full content width")
    require(frames.detail.height == detailH, "\(name) detail frame uses the measured height")

    // No frame is clipped by the card boundary.
    for (labelName, rect) in [
        ("title", frames.title),
        ("quotaDetail", frames.quotaDetail),
        ("amount", frames.amount),
        ("detail", frames.detail)
    ] {
        require(card.contains(rect), "\(name) \(labelName) frame stays inside the card")
    }

    // No two labels overlap (edge touching is allowed).
    let pairs: [(String, NSRect, String, NSRect)] = [
        ("title", frames.title, "amount", frames.amount),
        ("title", frames.title, "quotaDetail", frames.quotaDetail),
        ("title", frames.title, "detail", frames.detail),
        ("quotaDetail", frames.quotaDetail, "amount", frames.amount),
        ("quotaDetail", frames.quotaDetail, "detail", frames.detail),
        ("amount", frames.amount, "detail", frames.detail)
    ]
    for (nameA, rectA, nameB, rectB) in pairs {
        require(!rectA.intersects(rectB), "\(name) \(nameA) does not overlap \(nameB)")
    }
}

// Empty message keeps the compact single-line layout.
require(ErrorCardLayout.detailHeight(for: "", width: ErrorCardLayout.contentWidth) == ErrorCardLayout.singleLineDetailHeight, "empty text keeps the compact height")

// The detail label never truncates and wraps at character boundaries.
let detailLabel = ErrorCardLayout.makeDetailLabel(longChinese)
require(detailLabel.lineBreakMode == .byCharWrapping, "detail label wraps at character boundaries")
require(detailLabel.maximumNumberOfLines == 0, "detail label is not limited to a single line")
require(detailLabel.usesSingleLineMode == false, "detail label does not force single-line mode")
require(detailLabel.cell?.wraps == true, "detail label cell wraps")
require(detailLabel.lineBreakMode != .byTruncatingTail && detailLabel.lineBreakMode != .byTruncatingHead && detailLabel.lineBreakMode != .byTruncatingMiddle, "detail label never truncates")

print("error card layout probe: PASS; long CJK/English/unbroken URL/mixed wrap without truncation or overflow; short/empty stay compact; frames inside card with no overlap; detail label uses char wrapping")
SWIFT
} | swiftc -framework AppKit -framework CoreText -o "$probe_binary" -

"$probe_binary"
