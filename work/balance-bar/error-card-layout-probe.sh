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

let englishSample = "More Code: The network connection was lost."
let longEnglish = "Failed to load balance because the configured usage script is not enabled; please enable it in CC Switch and try again, this text is intentionally long to verify wrapping"
let longChinese = "tokenshop：未启用 usage script，无法查询余额，请先在 CC Switch 中启用对应的用量脚本后重试，本条消息用于验证错误详情多行换行与完整展示"
let unbrokenURL = "https://tokenshop.example.test/v1/usage?error_code=E401_INVALID_TOKEN&detail=token_revoked&hint=reauthorize_via_cc_switch_settings"
let mixed = "tokenshop 未启用 usage script（error_code=E401_INVALID_TOKEN）https://tokenshop.example.test/v1/usage?code=12345 请检查后重试"
let short = "tokenshop：未启用"
let longToken = "ThisErrorCodeLooksLikeATokenThatIsFarTooLongToFitOnASingleLineWithoutBreaking"

func coreTextLines(_ text: String, width: CGFloat) -> [CTLine] {
    let attributed = NSMutableAttributedString(string: text)
    attributed.addAttribute(.font, value: ErrorCardLayout.detailFont, range: NSRange(location: 0, length: attributed.length))
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    return CTFrameGetLines(frame) as? [CTLine] ?? []
}

// Independent CoreText height: number of wrapped lines times the font line
// height is the height the label really needs.
func coreTextNeededHeight(_ text: String, width: CGFloat) -> CGFloat {
    let lines = coreTextLines(text, width: width)
    require(!lines.isEmpty, "framesetter produces at least one line")
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    CTLineGetTypographicBounds(lines[0], &ascent, &descent, &leading)
    return CGFloat(lines.count) * (ascent + descent + leading)
}

func isLatinLetterOrDigit(_ character: Character) -> Bool {
    return character.isASCII && (character.isLetter || character.isNumber)
}

// A Latin word must never be split mid-word: a break with a Latin letter or
// digit on both sides is the reported "lo" / "st." failure mode and is not
// allowed. Breaks at whitespace, at injected zero-width spaces, or between CJK
// characters (natural CJK word boundaries) are all valid.
func breakPointsAreValid(_ text: String, width: CGFloat) -> Bool {
    let lines = coreTextLines(text, width: width)
    let characters = Array(text)
    for line in lines {
        let range = CTLineGetStringRange(line)
        let end = range.location + range.length
        guard end > 0, end < characters.count else { continue }
        let before = characters[end - 1]
        let after = characters[end]
        if isLatinLetterOrDigit(before) && isLatinLetterOrDigit(after) {
            return false
        }
    }
    return true
}

// 1. Normal English words stay whole: no break opportunities are injected into
//    tokens that fit on a line, so word wrapping can never split "lost.".
require(ErrorCardLayout.detailText(for: englishSample, width: ErrorCardLayout.contentWidth) == englishSample, "normal English words are not force-broken")
require(!ErrorCardLayout.detailText(for: englishSample, width: ErrorCardLayout.contentWidth).contains("\u{200B}"), "no zero-width spaces inside fitting English words")
require(ErrorCardLayout.detailText(for: short, width: ErrorCardLayout.contentWidth) == short, "short text is unchanged")

// 2. Over-wide unbreakable tokens (URLs, continuous error codes, long tokens)
//    get the guaranteed character-level fallback so they cannot overflow.
require(ErrorCardLayout.detailText(for: unbrokenURL, width: ErrorCardLayout.contentWidth).contains("\u{200B}"), "over-wide URL gets character-level fallback")
require(ErrorCardLayout.detailText(for: longToken, width: ErrorCardLayout.contentWidth).contains("\u{200B}"), "over-wide unbroken token gets character-level fallback")

// 3. All rendered line breaks are at word boundaries or injected zero-width
//    spaces: no mid-word splits for English, CJK, URL, mixed, or long tokens.
for (name, sample) in [
    ("english", englishSample),
    ("long-english", longEnglish),
    ("long-chinese", longChinese),
    ("url", unbrokenURL),
    ("mixed", mixed),
    ("long-token", longToken)
] {
    let text = ErrorCardLayout.detailText(for: sample, width: ErrorCardLayout.contentWidth)
    require(breakPointsAreValid(text, width: ErrorCardLayout.contentWidth), "\(name) breaks only at word boundaries")
}

// 4. Long text wraps to multiple lines and the layout height fits the full
//    wrapped text (independent CoreText cross-check); short/empty stay compact.
for (name, sample) in [
    ("long-english", longEnglish),
    ("long-chinese", longChinese),
    ("url", unbrokenURL),
    ("mixed", mixed)
] {
    let detailH = ErrorCardLayout.detailHeight(for: sample, width: ErrorCardLayout.contentWidth)
    require(detailH > ErrorCardLayout.singleLineDetailHeight, "\(name) wraps to multiple lines")
    let text = ErrorCardLayout.detailText(for: sample, width: ErrorCardLayout.contentWidth)
    let needed = coreTextNeededHeight(text, width: ErrorCardLayout.contentWidth)
    require(detailH + 0.5 >= needed, "\(name) detail height fits the full wrapped text (helper=\(detailH), needed=\(needed))")
}
require(ErrorCardLayout.detailHeight(for: short, width: ErrorCardLayout.contentWidth) == ErrorCardLayout.singleLineDetailHeight, "short text stays single-line")
require(ErrorCardLayout.detailHeight(for: "", width: ErrorCardLayout.contentWidth) == ErrorCardLayout.singleLineDetailHeight, "empty text stays single-line")

// 5. Layout: every frame stays inside the card, nothing overlaps, the detail
//    spans the full content width, and the top-right refresh time is present
//    in the standard format used by the other cards.
let layoutSamples: [(String, String)] = [
    ("english", englishSample),
    ("long-english", longEnglish),
    ("long-chinese", longChinese),
    ("url", unbrokenURL),
    ("mixed", mixed),
    ("short", short)
]
for (name, sample) in layoutSamples {
    let frames = ErrorCardLayout.errorFrames(for: sample)
    let card = NSRect(origin: .zero, size: frames.cardSize)

    require(frames.cardSize.height >= ErrorCardLayout.minimumCardHeight, "\(name) card height stays at or above the compact height")
    require(frames.detail.width == ErrorCardLayout.contentWidth, "\(name) detail spans the full content width")
    require(frames.detail.height == ErrorCardLayout.detailHeight(for: sample, width: ErrorCardLayout.contentWidth), "\(name) detail frame uses the measured height")
    require(frames.refreshTime.width == 81, "\(name) refresh time uses the standard width")
    require(abs(frames.refreshTime.maxX - (ErrorCardLayout.cardWidth - 14)) < 0.5, "\(name) refresh time is right-aligned with the standard inset")
    require(frames.refreshTime.minY > frames.detail.maxY, "\(name) refresh time sits above the detail")

    for (labelName, rect) in [
        ("title", frames.title),
        ("refreshTime", frames.refreshTime),
        ("quotaDetail", frames.quotaDetail),
        ("amount", frames.amount),
        ("detail", frames.detail)
    ] {
        require(card.contains(rect), "\(name) \(labelName) frame stays inside the card")
    }

    let pairs: [(String, NSRect, String, NSRect)] = [
        ("title", frames.title, "refreshTime", frames.refreshTime),
        ("title", frames.title, "quotaDetail", frames.quotaDetail),
        ("title", frames.title, "amount", frames.amount),
        ("title", frames.title, "detail", frames.detail),
        ("refreshTime", frames.refreshTime, "quotaDetail", frames.quotaDetail),
        ("refreshTime", frames.refreshTime, "amount", frames.amount),
        ("refreshTime", frames.refreshTime, "detail", frames.detail),
        ("quotaDetail", frames.quotaDetail, "amount", frames.amount),
        ("quotaDetail", frames.quotaDetail, "detail", frames.detail),
        ("amount", frames.amount, "detail", frames.detail)
    ]
    for (nameA, rectA, nameB, rectB) in pairs {
        require(!rectA.intersects(rectB), "\(name) \(nameA) does not overlap \(nameB)")
    }
}

// 6. The detail label uses word wrapping, unlimited lines, and never truncates.
let detailLabel = ErrorCardLayout.makeDetailLabel(
    ErrorCardLayout.detailText(for: longEnglish, width: ErrorCardLayout.contentWidth)
)
require(detailLabel.lineBreakMode == .byWordWrapping, "detail label uses word wrapping")
require(detailLabel.maximumNumberOfLines == 0, "detail label is not limited to a single line")
require(detailLabel.usesSingleLineMode == false, "detail label does not force single-line mode")
require(detailLabel.cell?.wraps == true, "detail label cell wraps")
require(detailLabel.lineBreakMode != .byTruncatingTail && detailLabel.lineBreakMode != .byTruncatingHead && detailLabel.lineBreakMode != .byTruncatingMiddle, "detail label never truncates")

print("error card layout probe: PASS; English words stay whole; URL/error-code tokens fall back to char breaks; all breaks at word boundaries; height fits full text; refresh time present top-right; frames inside card with no overlap; label uses word wrapping without truncation")
SWIFT
} | swiftc -framework AppKit -framework CoreText -o "$probe_binary" -

"$probe_binary"
