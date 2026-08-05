#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-status-item-probe.XXXXXX")"
probe_binary="$probe_dir/status-item-probe"
trap 'rm -rf "$probe_dir"' EXIT

{
    printf '%s\n' 'import Foundation' 'import CoreGraphics'
    awk '
        /^struct StatusItemAttachmentGeometry \{/ { capture = 1 }
        /^private enum SwitchLog \{/ { exit }
        capture { print }
    ' "$source_dir/BalanceBar.swift"
    cat <<'SWIFT'

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
let initialWindow = CGRect(x: 1633, y: 1087, width: 77, height: 39)
let expandedWindow = CGRect(x: 1633, y: 1087, width: 98, height: 39)
let initialButton = CGRect(x: 1641, y: 1090, width: 61, height: 22)
let expandedButton = CGRect(x: 1641, y: 1090, width: 82, height: 22)

let initialAligned = StatusItemAttachmentGeometry.rightEdgeAlignedWindowFrame(
    windowFrame: initialWindow,
    screenFrame: screen
)
require(initialAligned == initialWindow, "61pt window already fits")
require(initialAligned.maxX <= screen.maxX, "initial window right edge")

let expandedAligned = StatusItemAttachmentGeometry.rightEdgeAlignedWindowFrame(
    windowFrame: expandedWindow,
    screenFrame: screen
)
require(expandedAligned.origin.x == 1612, "82pt window must shift left by 21pt")
require(expandedAligned.width == 98, "window width must remain 98pt")
require(expandedAligned.maxX <= screen.maxX, "expanded window must fit the screen")

let shiftedButton = expandedButton.offsetBy(
    dx: expandedAligned.minX - expandedWindow.minX,
    dy: 0
)
require(shiftedButton.origin.x == 1620, "same button must move left with its host")
require(shiftedButton.width == 82, "button width must remain 82pt")
require(shiftedButton.maxX == 1702, "shifted button right edge")
require(StatusItemAttachmentGeometry.isAttached(
    buttonFrame: initialButton,
    screenFrame: screen,
    windowVisible: true,
    statusItemVisible: true
), "61pt button is attached")
require(StatusItemAttachmentGeometry.isAttached(
    buttonFrame: shiftedButton,
    screenFrame: screen,
    windowVisible: true,
    statusItemVisible: true
), "shifted 82pt button is attached")

var policy = StatusItemAttachmentPolicy()
require(StatusItemAttachmentPolicy.normalPathUpperBound == 1.3, "normal path is 1.3s")
require(StatusItemAttachmentPolicy.normalPathUpperBound < 3, "normal path is below 3s")
require(policy.observe(.waitingForFrame) == .waitForAppKitLayout(confirmation: 1, delay: 0.25), "first confirmation")
require(policy.observe(.waitingForFrame) == .waitForAppKitLayout(confirmation: 2, delay: 0.35), "second confirmation")
require(policy.observe(.waitingForFrame) == .reanchor(attempt: 1, delay: 0.20), "one reanchor scheduled")
require(policy.observe(.waitingForFrame) == .alreadyScheduled, "refreshes coalesce the reanchor")
policy.markRecoveryPerformed()
require(policy.observe(.waitingForFrame) == .finalUnresolved, "deadline logs once")
require(policy.observe(.waitingForFrame) == .alreadyFinalUnresolved, "deadline does not repeat every probe")
policy.resetForLayoutChange()
require(policy.observe(.waitingForFrame) == .waitForAppKitLayout(confirmation: 1, delay: 0.25), "width change permits a new bounded attempt")
require(policy.observe(.attached) == .stable, "attachment resets the state")

print("status-item reanchor probe: PASS; 1641/61 -> 1620/82, window.maxX=1710, deadline=1.3s, coalesced recovery, one final error")
SWIFT
} | swiftc -framework Foundation -framework CoreGraphics -o "$probe_binary" -

"$probe_binary"
