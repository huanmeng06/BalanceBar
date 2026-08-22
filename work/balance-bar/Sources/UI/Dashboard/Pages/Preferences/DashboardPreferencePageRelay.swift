import AppKit

/// The page modules own their controls; AppDelegate supplies these callbacks
/// so preference writes and application actions remain explicit and testable.
final class DashboardPreferencePageRelay: NSObject {
    var onToggle: ((String, Bool) -> Void)?
    var onInterval: ((String, TimeInterval) -> Void)?
    var onLanguage: ((AppLanguage) -> Void)?
    var onOpenCCSwitch: (() -> Void)?
    var onManualRefresh: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onInstallUpdate: (() -> Void)?
    var onOpenOpenCodex: (() -> Void)?
    var onRefreshLog: (() -> Void)?
    var onRevealLog: (() -> Void)?
    var onOffsetAdjust: ((String, Int) -> Void)?
    var onOffsetValue: ((String, Double) -> Void)?
    var onOffsetValueEnded: ((String, Double) -> Void)?
    var onOffsetReset: ((String) -> Void)?

    @objc func toggle(_ sender: NSSwitch) {
        guard let identifier = sender.identifier?.rawValue else { return }
        onToggle?(identifier, sender.state == .on)
    }

    @objc func interval(_ sender: NSPopUpButton) {
        guard let identifier = sender.identifier?.rawValue,
              let value = sender.selectedItem?.representedObject as? NSNumber else { return }
        onInterval?(identifier, value.doubleValue)
    }

    @objc func language(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue) else { return }
        onLanguage?(language)
    }

    @objc func openCCSwitch(_ sender: NSButton) {
        onOpenCCSwitch?()
    }

    @objc func manualRefresh(_ sender: NSButton) {
        onManualRefresh?()
    }

    @objc func update(_ sender: NSButton) {
        if sender.tag == 1 {
            onInstallUpdate?()
        } else {
            onCheckForUpdates?()
        }
    }

    @objc func openOpenCodex(_ sender: NSButton) {
        onOpenOpenCodex?()
    }

    @objc func refreshLog(_ sender: NSButton) {
        onRefreshLog?()
    }

    @objc func revealLog(_ sender: NSButton) {
        onRevealLog?()
    }

    @objc func adjustOffset(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        onOffsetAdjust?(identifier, sender.tag)
    }

    @objc func adjustOffsetValue(_ sender: NSSlider) {
        guard let identifier = sender.identifier?.rawValue else { return }
        onOffsetValue?(identifier, sender.doubleValue)
    }

    @objc func finishOffsetValue(_ sender: NSSlider) {
        guard let identifier = sender.identifier?.rawValue else { return }
        onOffsetValueEnded?(identifier, sender.doubleValue)
    }

    @objc func resetOffset(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        onOffsetReset?(identifier)
    }
}
