#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-menu-bar-geometry-probe.XXXXXX")"
probe_binary="$probe_dir/menu-bar-geometry-probe"
trap 'rm -rf "$probe_dir"' EXIT

{
    printf '%s\n' 'import AppKit'
    awk '
        /^private struct MenuBarGeometry \{/ { capture = 1 }
        /^private enum StatusLinkField \{/ { exit }
        capture {
            sub(/^private struct MenuBarGeometry/, "struct MenuBarGeometry")
            print
        }
    ' "$source_dir/BalanceBar.swift"
    cat <<'SWIFT'

func requireClose(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
    precondition(abs(actual - expected) < 0.0001, "\(message): actual=\(actual), expected=\(expected)")
}

private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}

private final class FlippedButtonView: NSView {
    override var isFlipped: Bool { true }
}

func geometry(showAmount: Bool, hasSecondary: Bool, isBalance: Bool) -> MenuBarGeometry {
    MenuBarGeometry(
        primarySize: NSSize(width: 38.5, height: 16),
        secondarySize: NSSize(width: 30, height: 13),
        showIcon: true,
        showAmount: showAmount,
        hasSecondary: hasSecondary,
        isBalance: isBalance,
        iconSlotWidth: 18,
        iconTextSpacing: 6,
        textRowSpacing: -2,
        textWidthSlack: 5,
        singleLineHeight: 18
    )
}

func appKitCenters(
    geometry: MenuBarGeometry,
    buttonHeight: CGFloat,
    iconViewYOffset: CGFloat
) -> (button: CGFloat, window: CGFloat) {
    let window = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: buttonHeight + 17))
    let button = FlippedButtonView(frame: NSRect(x: 8, y: 8.5, width: 120, height: buttonHeight))
    let content = FlippedContentView(frame: NSRect(
        x: 0,
        y: floor((buttonHeight - geometry.contentHeight) / 2),
        width: 100,
        height: geometry.contentHeight
    ))
    let slot = NSView(frame: NSRect(
        x: 0,
        y: floor(max(0, (geometry.contentHeight - geometry.iconWidth) / 2)),
        width: geometry.iconWidth,
        height: geometry.iconWidth
    ))
    let icon = NSImageView(frame: NSRect(
        x: 0,
        y: iconViewYOffset,
        width: geometry.iconWidth,
        height: geometry.iconWidth
    ))
    window.addSubview(button)
    button.addSubview(content)
    content.addSubview(slot)
    slot.addSubview(icon)
    return (
        icon.convert(icon.bounds, to: button).midY,
        icon.convert(icon.bounds, to: window).midY
    )
}

let apiWithAmount = geometry(showAmount: true, hasSecondary: false, isBalance: true)
let officialWithoutReset = geometry(showAmount: true, hasSecondary: false, isBalance: false)
let officialWithReset = geometry(showAmount: true, hasSecondary: true, isBalance: false)
let apiIconOnly = geometry(showAmount: false, hasSecondary: false, isBalance: true)
let officialIconOnly = geometry(showAmount: false, hasSecondary: false, isBalance: false)

requireClose(
    officialWithoutReset.iconViewYOffset(
        alignedTo: apiWithAmount,
        buttonHeight: 22,
        referenceIconViewYOffset: 0.25
    ),
    0.25,
    "22pt official without reset uses the API local offset"
)
requireClose(
    officialWithReset.iconViewYOffset(
        alignedTo: apiWithAmount,
        buttonHeight: 22,
        referenceIconViewYOffset: 0.25
    ),
    -0.75,
    "22pt official with reset compensates the rounded stack/slot delta"
)
requireClose(
    officialIconOnly.iconViewYOffset(
        alignedTo: apiIconOnly,
        buttonHeight: 22,
        referenceIconViewYOffset: 0
    ),
    0,
    "22pt official icon-only path needs no offset"
)

for buttonHeight in [CGFloat(22), 23, 24, 39] {
    let legacyAPIY = floor((buttonHeight - 18) / 2) - 0.25 + 9
    let apiY = apiWithAmount.iconCenterYInFlippedButton(
        buttonHeight: buttonHeight,
        iconViewYOffset: 0.25
    )
    requireClose(apiY, legacyAPIY, "API baseline frame is unchanged at height \(buttonHeight)")
    requireClose(
        appKitCenters(geometry: apiWithAmount, buttonHeight: buttonHeight, iconViewYOffset: 0.25).button,
        apiY,
        "pure API geometry matches AppKit conversion at height \(buttonHeight)"
    )

    for (name, official) in [
        ("without reset", officialWithoutReset),
        ("with reset", officialWithReset)
    ] {
        let offset = official.iconViewYOffset(
            alignedTo: apiWithAmount,
            buttonHeight: buttonHeight,
            referenceIconViewYOffset: 0.25
        )
        let officialY = official.iconCenterYInFlippedButton(
            buttonHeight: buttonHeight,
            iconViewYOffset: offset
        )
        requireClose(officialY, apiY, "official \(name) center matches API at height \(buttonHeight)")
        requireClose(
            appKitCenters(geometry: official, buttonHeight: buttonHeight, iconViewYOffset: offset).button,
            apiY,
            "official \(name) AppKit center matches API at height \(buttonHeight)"
        )
        requireClose(
            appKitCenters(geometry: official, buttonHeight: buttonHeight, iconViewYOffset: offset).window,
            appKitCenters(geometry: apiWithAmount, buttonHeight: buttonHeight, iconViewYOffset: 0.25).window,
            "official \(name) window center matches API at height \(buttonHeight)"
        )
    }

    let iconOnlyAPIY = apiIconOnly.iconCenterYInFlippedButton(
        buttonHeight: buttonHeight,
        iconViewYOffset: 0
    )
    let iconOnlyOffset = officialIconOnly.iconViewYOffset(
        alignedTo: apiIconOnly,
        buttonHeight: buttonHeight,
        referenceIconViewYOffset: 0
    )
    requireClose(
        officialIconOnly.iconCenterYInFlippedButton(
            buttonHeight: buttonHeight,
            iconViewYOffset: iconOnlyOffset
        ),
        iconOnlyAPIY,
        "official icon-only center matches API at height \(buttonHeight)"
    )
}

for cycle in 1...10 {
    let apiY = apiWithAmount.iconCenterYInFlippedButton(buttonHeight: 22, iconViewYOffset: 0.25)
    let offset = officialWithReset.iconViewYOffset(
        alignedTo: apiWithAmount,
        buttonHeight: 22,
        referenceIconViewYOffset: 0.25
    )
    let officialY = officialWithReset.iconCenterYInFlippedButton(
        buttonHeight: 22,
        iconViewYOffset: offset
    )
    requireClose(officialY, apiY, "cycle \(cycle) does not accumulate offset")
}

print("menu bar geometry probe: PASS; API baseline unchanged; official reset/no-reset and icon-only centers match API; AppKit frame conversion agrees; 10 cycles do not accumulate")
SWIFT
} | swiftc -framework AppKit -o "$probe_binary" -

"$probe_binary"
