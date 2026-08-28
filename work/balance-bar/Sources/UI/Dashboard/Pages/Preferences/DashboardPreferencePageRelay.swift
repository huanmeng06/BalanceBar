import AppKit

/// The page modules own their controls; AppDelegate supplies these callbacks
/// so preference writes and application actions remain explicit and testable.
final class DashboardPreferencePageRelay: NSObject {
    var onToggle: ((String, Bool) -> Void)?
    var onInterval: ((String, TimeInterval) -> Void)?
    var onLanguage: ((AppLanguage) -> Void)?
    var onMenuBarFontSizePreset: ((MenuBarFontSizePreset) -> Void)?
    var onMenuBarIconDisplayModeChanged: ((MenuBarIconDisplayMode) -> Void)?
    var onMenuBarIconDisplayDelayChanged: ((MenuBarIconDisplayDelay) -> Void)?
    var onMenuBarQuotaWindowPreferenceChanged: ((OfficialQuotaWindowPreference) -> Void)?
    var onMenuBarQuotaResetDisplayModeChanged: ((OfficialQuotaResetDisplayMode) -> Void)?
    var onLunaReserveDisplayModeChanged: ((LunaReserveDisplayMode) -> Void)?
    var onUpdateChannelChanged: ((UpdateChannel) -> Void)?
    var onOpenCCSwitch: (() -> Void)?
    var onOpenSystemMenuBarSettings: (() -> Void)?
    var onManualRefresh: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onInstallUpdate: (() -> Void)?
    var onOpenUpdateNotes: (() -> Void)?
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

    @objc func menuBarFontSizePreset(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let preset = MenuBarFontSizePreset(rawValue: rawValue) else { return }
        onMenuBarFontSizePreset?(preset)
    }

    @objc func menuBarIconDisplayMode(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let mode = MenuBarIconDisplayMode(rawValue: rawValue) else { return }
        onMenuBarIconDisplayModeChanged?(mode)
    }

    @objc func menuBarIconDisplayDelay(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let delay = MenuBarIconDisplayDelay(rawValue: rawValue) else { return }
        onMenuBarIconDisplayDelayChanged?(delay)
    }

    @objc func menuBarQuotaWindowPreference(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let preference = OfficialQuotaWindowPreference(rawValue: rawValue) else { return }
        onMenuBarQuotaWindowPreferenceChanged?(preference)
    }

    @objc func menuBarQuotaResetDisplayMode(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let mode = OfficialQuotaResetDisplayMode(rawValue: rawValue) else { return }
        onMenuBarQuotaResetDisplayModeChanged?(mode)
    }

    @objc func lunaReserveDisplayMode(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let mode = LunaReserveDisplayMode(rawValue: rawValue) else { return }
        onLunaReserveDisplayModeChanged?(mode)
    }

    @objc func updateChannel(_ sender: NSPopUpButton) {
        guard sender.identifier?.rawValue == AppPreferences.updateChannelKey,
              let rawValue = sender.selectedItem?.representedObject as? String,
              let channel = UpdateChannel(rawValue: rawValue) else { return }
        onUpdateChannelChanged?(channel)
    }

    @objc func openCCSwitch(_ sender: NSButton) {
        onOpenCCSwitch?()
    }

    @objc func openSystemMenuBarSettings(_ sender: NSButton) {
        onOpenSystemMenuBarSettings?()
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

    @objc func openUpdateNotes(_ sender: NSButton) {
        onOpenUpdateNotes?()
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
