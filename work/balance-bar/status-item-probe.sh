#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-status-item-probe.XXXXXX")"
probe_binary="$probe_dir/status-item-probe"
trap 'rm -rf "$probe_dir"' EXIT

{
    printf '%s\n' 'import Foundation' 'import CoreGraphics'
    awk '
        /^struct StatusItemLengthPolicy \{/ { capture = 1 }
        /^private enum SwitchLog \{/ { exit }
        capture { print }
    ' "$source_dir/BalanceBar.swift"
    cat <<'SWIFT'

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

// The real failed launch changed the natural status-item length from 61pt to
// 82pt. The slot must be registered at 82pt before the first AppKit layout.
let placeholderNaturalLength: CGFloat = 61
let firstSnapshotNaturalLength: CGFloat = 82
require(
    StatusItemLengthPolicy.startupLength(for: placeholderNaturalLength) == 82,
    "placeholder reserves the final 82pt registration width"
)
require(
    StatusItemLengthPolicy.startupLength(for: firstSnapshotNaturalLength) == 82,
    "first 82pt snapshot does not change the registered width"
)
require(
    StatusItemLengthPolicy.settledLength(for: placeholderNaturalLength) == 61,
    "settled natural placeholder geometry remains 61pt"
)
require(
    StatusItemLengthPolicy.settledLength(for: firstSnapshotNaturalLength) == 82,
    "settled first snapshot geometry is 82pt"
)

// Keep the concrete diagnostic geometry from the user report. The expanded
// converted button extends past screen.maxX, but that fact alone is not a
// visibility failure: AppKit owns the host window and menu-bar slot.
let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
let initialButton = CGRect(x: 1641, y: 1090, width: 61, height: 22)
let expandedButton = CGRect(x: 1641, y: 1090, width: 82, height: 22)
require(initialButton.maxX == 1702, "61pt diagnostic button right edge")
require(expandedButton.maxX == 1723, "82pt diagnostic button right edge")
require(expandedButton.maxX > screen.maxX, "reported expanded diagnostic geometry")
require(StatusItemAttachmentGeometry.isAppKitReady(
    buttonFrame: initialButton,
    windowVisible: true,
    statusItemVisible: true,
    buttonHidden: false,
    screenAvailable: true
), "61pt AppKit object is ready")
require(StatusItemAttachmentGeometry.isAppKitReady(
    buttonFrame: expandedButton,
    windowVisible: true,
    statusItemVisible: true,
    buttonHidden: false,
    screenAvailable: true
), "82pt AppKit object remains ready without edge math")
require(!StatusItemAttachmentGeometry.isAppKitReady(
    buttonFrame: expandedButton,
    windowVisible: true,
    statusItemVisible: true,
    buttonHidden: false,
    screenAvailable: false
), "screen=nil remains a real readiness failure")

var policy = StatusItemAttachmentPolicy()
require(
    abs(StatusItemAttachmentPolicy.normalPathUpperBound - 1.7) < 0.001,
    "recovery path is 1.7s"
)
require(StatusItemAttachmentPolicy.normalPathUpperBound < 3, "first recovery is below 3s")
require(
    StatusItemAttachmentPolicy.initialAttachmentCheckDelay
        < StatusItemAttachmentPolicy.confirmationDelays[0]
        && StatusItemAttachmentPolicy.confirmationDelays[0]
            < StatusItemAttachmentPolicy.confirmationDelays[1]
        && StatusItemAttachmentPolicy.confirmationDelays[1]
            < StatusItemAttachmentPolicy.recoveryDelay
        && StatusItemAttachmentPolicy.recoveryDelay
            < StatusItemAttachmentPolicy.postRecoveryCheckDelay,
    "wait and recovery delays increase monotonically"
)
require(
    policy.observe(.waitingForFrame)
        == .waitForAppKitLayout(confirmation: 1, delay: 0.25),
    "first confirmation"
)
require(
    policy.observe(.waitingForFrame)
        == .waitForAppKitLayout(confirmation: 2, delay: 0.35),
    "second confirmation"
)
require(
    policy.observe(.waitingForFrame) == .recover(attempt: 1, delay: 0.40),
    "one same-item recovery is scheduled"
)
require(
    policy.observe(.waitingForFrame) == .alreadyScheduled,
    "continuous snapshots coalesce the recovery chain"
)
policy.markRecoveryPerformed()
require(
    policy.observe(.waitingForFrame) == .finalUnresolved,
    "deadline records one final unresolved result"
)
require(
    policy.observe(.waitingForFrame) == .alreadyFinalUnresolved,
    "final unresolved result does not repeat forever"
)
require(policy.observe(.appKitReady) == .stable, "readiness resets the state")
policy.resetForLayoutChange()
require(
    policy.observe(.waitingForScreen)
        == .waitForAppKitLayout(confirmation: 1, delay: 0.25),
    "layout change permits one new bounded attempt"
)

print("status-item registration probe: PASS; startup=82pt; natural=61pt->82pt without first jump; AppKit-managed readiness; recovery=1.7s; coalesced; quiescent")
SWIFT
} | swiftc -framework Foundation -framework CoreGraphics -o "$probe_binary" -

"$probe_binary"
