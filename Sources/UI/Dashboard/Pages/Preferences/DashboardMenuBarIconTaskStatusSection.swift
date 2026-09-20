import AppKit

/// Commits the FPS field on Return and focus loss.
private final class AnimationFrameRateEditor: NSObject, NSTextFieldDelegate {
    weak var field: NSTextField?
    var onChange: ((Int) -> Void)?
    private var isRewritingDisplayedValue = false

    func setDisplayedValue(_ fps: Int) {
        let clamped = MenuBarAnimationTiming.clampedFrameRate(fps)
        if field?.currentEditor() == nil {
            field?.integerValue = clamped
        }
    }

    @objc func fieldAction(_ sender: NSTextField) {
        commit(MenuBarAnimationFrameRateInput.resolve(sender.stringValue))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isRewritingDisplayedValue, let field = obj.object as? NSTextField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed),
              value > MenuBarAnimationTiming.maximumFrameRate else {
            return
        }
        isRewritingDisplayedValue = true
        commit(MenuBarAnimationTiming.maximumFrameRate)
        isRewritingDisplayedValue = false
        if let editor = field.currentEditor() {
            let end = (field.stringValue as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        commit(MenuBarAnimationFrameRateInput.resolve(field.stringValue))
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            commit(MenuBarAnimationFrameRateInput.step(1, from: control.stringValue))
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            commit(MenuBarAnimationFrameRateInput.step(-1, from: control.stringValue))
            return true
        }
        return false
    }

    private func commit(_ fps: Int) {
        let clamped = MenuBarAnimationTiming.clampedFrameRate(fps)
        field?.integerValue = clamped
        onChange?(clamped)
    }
}

/// Task-status icon and animation settings for the Menu Bar page.
final class DashboardMenuBarIconTaskStatusSection {
    private(set) var iconTaskCardLayoutCountForTesting = 0
    var animationFallbackActive = false
    var animationFrameRate = MenuBarAnimationTiming.defaultFrameRate
    var relaunchApplication: () -> Void = DashboardMenuBarPage.relaunchCurrentApplication
    var restoreSnapshotProvider: () -> DashboardRestoreToken = {
        DashboardRestoreToken(section: .menuBar, scrollOffsetY: 0)
    }
    var persistRestoreToken: (DashboardRestoreToken) -> Void = { token in
        DashboardRestoreStore.record(token)
    }
    var onDelayVisibilityChanged: ((Bool) -> Void)?

    private let animationFrameRateEditor = AnimationFrameRateEditor()
    private weak var iconSwitch: NSSwitch?
    private weak var animationSwitch: NSSwitch?
    private weak var animationModeControl: NSPopUpButton?
    private weak var animationModeTitleLabel: NSTextField?
    private weak var animationModeSubtitleLabel: InlineRangeLinkTextField?
    private var restartConfirmationAlert: NSAlert?
    var restartConfirmationAlertForTesting: NSAlert? {
        restartConfirmationAlert
    }
    private weak var animationFrameRateField: NSTextField?
    private weak var animationFrameRateUnitLabel: NSTextField?
    private weak var animationFrameRateSubtitleLabel: NSTextField?
    private weak var taskStatusIconRow: NSView?
    private weak var animationRow: NSView?
    private weak var animationModeRow: NSView?
    private weak var animationFrameRateRow: NSView?
    private weak var animationFallbackWarningLabel: NSTextField?
    private weak var animationFallbackWarningRow: NSView?
    private var iconTaskStatusSeparators: [NSView] = []
    private weak var iconTaskStatusSection: SettingsSectionView?
    private struct IconTaskVisibilitySignature: Equatable {
        let showIcon: Bool
        let showDelay: Bool
        let showAnimationMode: Bool
        let showFallbackWarning: Bool
    }

    private var lastIconTaskVisibilitySignature: IconTaskVisibilitySignature?

    func resetRefreshSignatures() {
        lastIconTaskVisibilitySignature = nil
    }

    func restoreIconToggle() {
        iconSwitch?.state = .on
    }

    func setIconSwitchEnabled(_ isEnabled: Bool) {
        iconSwitch?.isEnabled = isEnabled
    }

    func teardown() {
        removeRevealHighlight()
        dismissRestartConfirmation()
    }

    func removeRevealHighlight() {
        let animationKey = DashboardMenuBarPage.iconDisplayModeRevealHighlightAnimationKey
        taskStatusIconRow?.layer?.removeAnimation(forKey: animationKey)
    }

    func make(input: DashboardMenuBarPage.Input) -> NSView {
        iconTaskStatusSeparators = []
        iconTaskStatusSection = nil
        lastIconTaskVisibilitySignature = nil
        animationFallbackActive = input.animationFallbackActive
        animationFrameRate = input.preferences.menuBarAnimationFrameRate

        let iconToggle = DashboardSettingsComponents.makeSwitch(
            identifier: "showMenuBarIcon",
            isOn: input.preferences.showMenuBarIcon,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        iconSwitch = iconToggle
        let animationToggle = DashboardSettingsComponents.makeSwitch(
            identifier: "animateCodexActivity",
            isOn: input.preferences.animateCodexActivity,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        animationSwitch = animationToggle
        let animationModeControl = makeAnimationModeControl(
            value: input.preferences.menuBarAnimationMode,
            relay: input.relay
        )
        self.animationModeControl = animationModeControl
        let animationFrameRateControl = makeAnimationFrameRateControl(
            value: input.preferences.menuBarAnimationFrameRate,
            relay: input.relay
        )
        let animationFallbackWarningLabel = NSTextField(
            wrappingLabelWithString: DashboardMenuBarPage.animationFallbackWarningText()
        )
        animationFallbackWarningLabel.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.animationFallbackWarningIdentifier
        )
        let animationFallbackWarningRow = SettingsRowView(
            title: "",
            detail: DashboardMenuBarPage.animationFallbackWarningText(),
            detailLabel: animationFallbackWarningLabel,
            minimumHeight: 58,
            verticalPadding: 11
        )
        animationFallbackWarningRow.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.animationFallbackWarningIdentifier + "Row"
        )
        self.animationFallbackWarningLabel = animationFallbackWarningLabel
        self.animationFallbackWarningRow = animationFallbackWarningRow
        animationFallbackWarningRow.isHidden = true
        let taskStatusIconRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageAgentIcon),
            detail: tr(.keyDashboardMenuBarPageShowsTheCurrentTaskStatus),
            accessoryView: iconToggle
        )
        self.taskStatusIconRow = taskStatusIconRow
        let animationRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPagePlayTheIconAnimationWhileATaskIsRunning),
            detail: tr(.keyDashboardMenuBarPagePlayTheIconAnimationWhileATaskIsRunningDescription),
            accessoryView: animationToggle
        )
        self.animationRow = animationRow
        let animationModeSubtitle = DashboardMenuBarPage.animationModeDescription(
            mode: input.preferences.menuBarAnimationMode
        )
        let animationModeSubtitleLabel = InlineRangeLinkTextField()
        animationModeSubtitleLabel.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.animationModeSubtitleIdentifier
        )
        self.animationModeSubtitleLabel = animationModeSubtitleLabel
        let animationModeRow = SettingsRowView(
            title: DashboardMenuBarPage.animationModeTitle(),
            detail: animationModeSubtitle,
            detailLabel: animationModeSubtitleLabel,
            accessoryView: animationModeControl
        )
        animationModeRow.titleLabel.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.animationModeTitleIdentifier
        )
        self.animationModeTitleLabel = animationModeRow.titleLabel
        self.animationModeRow = animationModeRow
        applyAnimationModeSubtitle(mode: input.preferences.menuBarAnimationMode)
        let animationFrameRateSubtitle = DashboardMenuBarPage.animationFrameRateSubtitleContent(
            mode: input.preferences.menuBarAnimationMode,
            fps: input.preferences.menuBarAnimationFrameRate
        )
        let animationFrameRateSubtitleLabel = DashboardSettingsComponents.makeSubtitleLabel(
            animationFrameRateSubtitle
        )
        animationFrameRateSubtitleLabel.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.animationFrameRateIdentifier + "Subtitle"
        )
        self.animationFrameRateSubtitleLabel = animationFrameRateSubtitleLabel
        let animationFrameRateRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageAnimationFrameRate),
            detail: animationFrameRateSubtitle.text,
            detailLabel: animationFrameRateSubtitleLabel,
            accessoryView: animationFrameRateControl
        )
        animationFrameRateRow.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.animationFrameRateRowIdentifier
        )
        animationFrameRateControl.setContentHuggingPriority(.required, for: .vertical)
        animationFrameRateControl.setContentCompressionResistancePriority(.required, for: .vertical)
        self.animationFrameRateRow = animationFrameRateRow
        let iconTaskStatusSection = SettingsSectionView(
            title: tr(.keyDashboardMenuBarPageIconAndTaskStatus),
            contentViews: [
                taskStatusIconRow,
                animationRow,
                animationModeRow,
                animationFrameRateRow,
                animationFallbackWarningRow
            ]
        )
        self.iconTaskStatusSection = iconTaskStatusSection
        self.iconTaskStatusSeparators = iconTaskStatusSection.separators
        updateVisibility(
            showTaskStatusIcon: input.preferences.showMenuBarIcon,
            displayMode: input.preferences.menuBarIconDisplayMode,
            animationEnabled: input.preferences.animateCodexActivity,
            animationMode: input.preferences.menuBarAnimationMode
        )
        return iconTaskStatusSection
    }

    func refresh(preferences: AppPreferences) {
        animationSwitch?.state = preferences.animateCodexActivity ? .on : .off
        if let animationModeControl,
           let selectedIndex = MenuBarAnimationMode.displayOrder.firstIndex(
               of: preferences.menuBarAnimationMode
           ) {
            if animationModeControl.indexOfSelectedItem != selectedIndex {
                animationModeControl.selectItem(at: selectedIndex)
            }
            animationModeControl.synchronizeTitleAndSelectedItem()
            animationModeControl.toolTip = DashboardMenuBarPage.animationModeDescription(
                mode: preferences.menuBarAnimationMode
            )
        }
        applyAnimationModeSubtitle(mode: preferences.menuBarAnimationMode)
        animationFrameRate = preferences.menuBarAnimationFrameRate
        animationFrameRateEditor.setDisplayedValue(preferences.menuBarAnimationFrameRate)
        animationFrameRateUnitLabel?.stringValue = tr(
            .keyDashboardMenuBarPageAnimationFrameRateUnit
        )
        DashboardSettingsComponents.updateSubtitleLabel(
            animationFrameRateSubtitleLabel,
            with: DashboardMenuBarPage.animationFrameRateSubtitleContent(
                mode: preferences.menuBarAnimationMode,
                fps: preferences.menuBarAnimationFrameRate
            )
        )
        updateVisibility(
            showTaskStatusIcon: preferences.showMenuBarIcon,
            displayMode: preferences.menuBarIconDisplayMode,
            animationEnabled: preferences.animateCodexActivity,
            animationMode: preferences.menuBarAnimationMode
        )
    }

    func updateVisibility(
        showTaskStatusIcon: Bool,
        displayMode: MenuBarIconDisplayMode,
        animationEnabled: Bool,
        animationMode: MenuBarAnimationMode
    ) {
        let showDependentRows = showTaskStatusIcon
        let showDelay = displayMode == .onlyWhileRunning
        let showAnimationMode = showDependentRows && animationEnabled
        let showFallbackWarning = showAnimationMode
            && animationMode == .efficient
            && animationFallbackActive
        let signature = IconTaskVisibilitySignature(
            showIcon: showTaskStatusIcon,
            showDelay: showDelay,
            showAnimationMode: showAnimationMode,
            showFallbackWarning: showFallbackWarning
        )
        guard signature != lastIconTaskVisibilitySignature else { return }
        lastIconTaskVisibilitySignature = signature
        animationRow?.isHidden = !showDependentRows
        animationModeRow?.isHidden = !showAnimationMode
        animationModeControl?.isEnabled = showAnimationMode
        animationFrameRateRow?.isHidden = !showAnimationMode
        animationFrameRateField?.isEnabled = showAnimationMode
        animationFallbackWarningRow?.isHidden = !showFallbackWarning
        animationFallbackWarningLabel?.stringValue = DashboardMenuBarPage.animationFallbackWarningText()
        onDelayVisibilityChanged?(showDelay)

        // Delay now lives on the preview card. Icon rows are task status →
        // animation → animation mode → frame rate → fallback warning.
        let visibleRows = [
            true,
            showDependentRows,
            showAnimationMode,
            showAnimationMode,
            showFallbackWarning
        ]
        for (index, separator) in iconTaskStatusSeparators.enumerated() {
            guard index < visibleRows.count - 1 else {
                separator.isHidden = true
                continue
            }
            let hasVisibleRowAfter = visibleRows[(index + 1)...].contains(true)
            separator.isHidden = !(visibleRows[index] && hasVisibleRowAfter)
        }
        updateCardLayout()
    }

    private func updateCardLayout() {
        guard let iconTaskStatusSection else { return }
        iconTaskCardLayoutCountForTesting += 1
        iconTaskStatusSection.cardView.invalidateHostedSettingsRowHeight()
        iconTaskStatusSection.invalidateIntrinsicContentSize()
        iconTaskStatusSection.needsLayout = true
        iconTaskStatusSection.superview?.invalidateIntrinsicContentSize()
        iconTaskStatusSection.superview?.needsLayout = true
    }

    private func applyAnimationModeSubtitle(mode: MenuBarAnimationMode) {
        animationModeTitleLabel?.stringValue = DashboardMenuBarPage.animationModeTitle()
        let text = DashboardMenuBarPage.animationModeDescription(mode: mode)
        let phrase = mode == .efficient ? DashboardMenuBarPage.animationModeRestartLinkPhrase() : nil
        let subtitleChanged = animationModeSubtitleLabel?.stringValue != text
            || (animationModeSubtitleLabel?.hasLink ?? false) != (phrase != nil)
        animationModeSubtitleLabel?.setContent(
            text,
            linkPhrase: phrase,
            onActivate: { [weak self] in
                self?.presentAnimationRestartConfirmation()
            }
        )
        guard subtitleChanged else { return }
        DashboardSettingsComponents.notifySettingsRowContentChanged(animationModeSubtitleLabel)
        updateCardLayout()
    }

    func presentAnimationRestartConfirmation() {
        if restartConfirmationAlert?.window.sheetParent != nil {
            return
        }
        let hostWindow = animationModeSubtitleLabel?.window
            ?? animationModeRow?.window
        guard let hostWindow else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = tr(.keyDashboardMenuBarPageAnimationModeRestartConfirmation)
        alert.addButton(withTitle: tr(.keyDashboardMenuBarPageAnimationModeRestartConfirm))
        alert.addButton(withTitle: tr(.keyDashboardMenuBarPageAnimationModeRestartCancel))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.buttons[1].keyEquivalentModifierMask = []
        restartConfirmationAlert = alert
        alert.beginSheetModal(for: hostWindow) { [weak self] response in
            guard let self else { return }
            self.restartConfirmationAlert = nil
            if response == .alertFirstButtonReturn {
                self.persistRestoreToken(self.restoreSnapshotProvider())
                self.relaunchApplication()
            }
        }
    }

    private func dismissRestartConfirmation() {
        guard let alert = restartConfirmationAlert else { return }
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
        }
        restartConfirmationAlert = nil
    }

    private func makeAnimationModeControl(
        value: MenuBarAnimationMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: DashboardMenuBarPage.animationModeIdentifier,
            items: MenuBarAnimationMode.displayOrder.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.animationModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: MenuBarAnimationMode.displayOrder.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarAnimationMode(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = DashboardMenuBarPage.animationModeDescription(mode: value)
        return control
    }

    private func makeAnimationFrameRateControl(
        value: Int,
        relay: DashboardPreferencePageRelay
    ) -> NSView {
        let clamped = MenuBarAnimationTiming.clampedFrameRate(value)
        let field = DashboardSettingsComponents.makeNumericTextField(
            identifier: DashboardMenuBarPage.animationFrameRateIdentifier,
            value: String(clamped),
            delegate: animationFrameRateEditor,
            target: animationFrameRateEditor,
            action: #selector(AnimationFrameRateEditor.fieldAction(_:)),
            toolTip: tr(.keyDashboardMenuBarPageAnimationFrameRateDescription)
        )
        field.integerValue = clamped
        animationFrameRateField = field

        let unit = NSTextField(labelWithString: tr(.keyDashboardMenuBarPageAnimationFrameRateUnit))
        unit.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        unit.setContentHuggingPriority(.required, for: .horizontal)
        unit.setContentCompressionResistancePriority(.required, for: .horizontal)
        animationFrameRateUnitLabel = unit

        animationFrameRateEditor.field = field
        animationFrameRateEditor.onChange = { [weak relay] fps in
            relay?.commitMenuBarAnimationFrameRate(fps)
        }

        let stack = NSStackView(views: [field, unit])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        return stack
    }

    private static func animationModeLabel(_ mode: MenuBarAnimationMode) -> String {
        switch mode {
        case .efficient:
            return tr(.keyDashboardMenuBarPageAnimationModeEfficient)
        case .synchronized:
            return tr(.keyDashboardMenuBarPageAnimationModeSynchronized)
        }
    }
}
