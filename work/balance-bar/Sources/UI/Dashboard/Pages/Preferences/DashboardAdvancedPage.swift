import AppKit

enum DashboardAdvancedPageLayout {
    static let compactTwoLineRowHeight: CGFloat = 66
    static let compactTwoLineRowVerticalPadding: CGFloat = 8
    static let invalidPortRowHeight: CGFloat = 112
}

final class DashboardAdvancedPage: NSObject, NSTextFieldDelegate {
    struct Input {
        let preferences: AppPreferences
        let mode: OpenCodexDashboardMode
        let currentResolution: OpenCodexDashboardResolution?
        let runtimeCandidate: OpenCodexEndpointCandidate?
        let relay: DashboardPreferencePageRelay
        let logViewer: NSView
        let onModeChanged: (OpenCodexDashboardMode) -> Void
        let onClamp: () -> Void
    }

    private var state = OpenCodexDashboardInteractionState(
        mode: OpenCodexDashboardMode(automaticDetection: true, manualPort: nil)
    )
    private weak var automaticSwitch: NSSwitch?
    private weak var portField: NSTextField?
    private weak var manualPortRow: NSView?
    private weak var manualPortHeightConstraint: NSLayoutConstraint?
    private weak var portStatusLabel: NSTextField?
    private weak var portErrorLabel: NSTextField?
    private weak var openButton: NSButton?
    private weak var settingsRowsStack: NSStackView?
    private weak var settingsCardHeightConstraint: NSLayoutConstraint?
    private var settingsSeparators: [NSView] = []
    private var portInputHasError = false
    private var isEndingPortEditing = false
    private var onModeChanged: ((OpenCodexDashboardMode) -> Void)?
    private var onClamp: (() -> Void)?
    private var runtimeCandidate: OpenCodexEndpointCandidate?

    func make(_ input: Input) -> NSView {
        onModeChanged = input.onModeChanged
        onClamp = input.onClamp
        runtimeCandidate = input.runtimeCandidate
        state = OpenCodexDashboardInteractionState(mode: input.mode)
        portInputHasError = false
        settingsSeparators = []

        let automaticDetection = input.preferences.openCodexDashboardAutomaticDetection
        let currentResolution = input.currentResolution
        let initialResolution = currentResolution ?? OpenCodexDashboardResolver.resolve(
            manualPort: input.mode.effectiveManualPort,
            runtimeCandidate: nil
        )
        let statusLabel = NSTextField(wrappingLabelWithString: tr(.keyDashboardAdvancedPageCurrentPortValue, arguments: [String(describing: initialResolution.port)]))
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let automaticSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "openCodexAutomaticDetection",
            isOn: automaticDetection,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let automaticRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardAdvancedPageDetectPortAutomatically),
            subtitle: statusLabel.stringValue,
            subtitleLabel: statusLabel,
            control: automaticSwitch,
            minimumHeight: DashboardAdvancedPageLayout.compactTwoLineRowHeight,
            verticalPadding: DashboardAdvancedPageLayout.compactTwoLineRowVerticalPadding
        )
        automaticRow.identifier = NSUserInterfaceItemIdentifier("openCodexAutomaticDetectionRow")

        let portField = NSTextField()
        portField.stringValue = String(input.mode.manualPort ?? initialResolution.port)
        portField.placeholderString = "10100"
        portField.alignment = .right
        portField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        portField.isEditable = true
        portField.isSelectable = true
        portField.delegate = self
        portField.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        let manualPortRow = makeManualPortRow(portField: portField, errorLabel: errorLabel)
        manualPortRow.identifier = NSUserInterfaceItemIdentifier("openCodexManualPortRow")
        manualPortRow.isHidden = automaticDetection

        let openButton = NSButton(
            title: tr(.keyDashboardAdvancedPageOpen),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openOpenCodex(_:))
        )
        openButton.isEnabled = currentResolution != nil
        automaticSwitchState(automaticSwitch, portField: portField, manualPortRow: manualPortRow, statusLabel: statusLabel, errorLabel: errorLabel, openButton: openButton)

        let openButtonRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardAdvancedPageOpenOpencodexDashboard),
            control: openButton,
            minimumHeight: 62
        )
        openButtonRow.identifier = NSUserInterfaceItemIdentifier("openCodexDashboardRow")
        let openCodex = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardAdvancedPageOpencodex),
            rows: [automaticRow, manualPortRow, openButtonRow],
            rowWidthReference: automaticRow,
            onLayoutCreated: { [weak self] rowsStack, cardHeightConstraint, separators in
                guard let self else { return }
                self.settingsRowsStack = rowsStack
                self.settingsCardHeightConstraint = cardHeightConstraint
                self.settingsSeparators = separators
                if automaticDetection, !separators.isEmpty { separators[0].isHidden = true }
            }
        )
        state.updateResolvedPort(initialResolution.port)
        applyResolution(initialResolution, canOpen: currentResolution != nil)
        // The automatic-mode separator is hidden in the section callback
        // above. Recalculate once after that visibility change so AppKit does
        // not distribute the stale separator space into the first row.
        updateCardLayout()

        let refreshLog = NSButton(
            title: tr(.keyDashboardAdvancedPageReload),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.refreshLog(_:))
        )
        let revealLog = NSButton(
            title: tr(.keyDashboardAdvancedPageShowInFinder),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.revealLog(_:))
        )
        let logButtons = NSStackView(views: [refreshLog, revealLog])
        logButtons.orientation = .horizontal
        logButtons.spacing = 8
        let logs = DashboardSettingsComponents.makeSettingsSection(tr(.keyDashboardAdvancedPageDiagnostics), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardAdvancedPageDebugLog),
                subtitle: tr(.keyDashboardAdvancedPageRecordsRuntimeStatusAndErrors),
                control: logButtons
            ),
            input.logViewer
        ])
        return DashboardSettingsComponents.makeSettingsPage([openCodex, logs])
    }

    func handleAutomaticDetection(_ enabled: Bool) {
        guard let field = portField else { return }
        if field.currentEditor() != nil {
            state.markPortEditorActive(true)
            isEndingPortEditing = true
            _ = field.abortEditing()
            _ = field.window?.makeFirstResponder(nil)
            isEndingPortEditing = false
            state.markPortEditorActive(false)
        }
        state.setAutomaticDetection(enabled)
        onModeChanged?(state.mode)
        portInputHasError = false
        portErrorLabel?.stringValue = ""
        portErrorLabel?.isHidden = true
        manualPortHeightConstraint?.constant = DashboardAdvancedPageLayout.compactTwoLineRowHeight
        updateModeUI()
        SwitchLog.write(
            "OpenCodex Dashboard detection mode changed; mode=\(enabled ? "automatic" : "manual")",
            category: "configuration"
        )
    }

    func refresh(currentResolution: OpenCodexDashboardResolution?, runtimeCandidate: OpenCodexEndpointCandidate?) {
        guard automaticSwitch?.window?.isVisible == true else { return }
        self.runtimeCandidate = runtimeCandidate
        let resolution = currentResolution ?? OpenCodexDashboardResolver.resolve(
            manualPort: state.mode.effectiveManualPort,
            runtimeCandidate: nil
        )
        applyResolution(resolution, canOpen: currentResolution != nil)
        let showsManualPortInput = state.mode.showsManualPortInput
        automaticSwitch?.state = showsManualPortInput ? .off : .on
        manualPortRow?.isHidden = !showsManualPortInput
        if settingsSeparators.count >= 2 {
            settingsSeparators[0].isHidden = !showsManualPortInput
            settingsSeparators[1].isHidden = false
        }
        updateCardLayout()
    }

    private func automaticSwitchState(
        _ automaticSwitch: NSSwitch,
        portField: NSTextField,
        manualPortRow: NSView,
        statusLabel: NSTextField,
        errorLabel: NSTextField,
        openButton: NSButton
    ) {
        self.automaticSwitch = automaticSwitch
        self.portField = portField
        self.manualPortRow = manualPortRow
        self.portStatusLabel = statusLabel
        self.portErrorLabel = errorLabel
        self.openButton = openButton
    }

    private func makeManualPortRow(portField: NSTextField, errorLabel: NSTextField) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = row.heightAnchor.constraint(
            equalToConstant: DashboardAdvancedPageLayout.compactTwoLineRowHeight
        )
        heightConstraint.isActive = true
        manualPortHeightConstraint = heightConstraint
        let title = NSTextField(labelWithString: tr(.keyDashboardAdvancedPageEnterPortManually))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.isEditable = false
        title.isSelectable = false
        let detail = NSTextField(wrappingLabelWithString: tr(.keyDashboardAdvancedPageOnlyTrimmedDecimal165535IsAcceptedClearTheFieldToRestoreAutomaticDetection))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.isEditable = false
        detail.isSelectable = false
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isEditable = false
        errorLabel.isSelectable = false
        errorLabel.isHidden = true
        let labels = NSStackView(views: [title, detail, errorLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        portField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(portField)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.topAnchor.constraint(
                greaterThanOrEqualTo: row.topAnchor,
                constant: DashboardAdvancedPageLayout.compactTwoLineRowVerticalPadding
            ),
            labels.bottomAnchor.constraint(
                lessThanOrEqualTo: row.bottomAnchor,
                constant: -DashboardAdvancedPageLayout.compactTwoLineRowVerticalPadding
            ),
            portField.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            portField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: portField.leadingAnchor, constant: -20)
        ])
        return row
    }

    private func updateModeUI() {
        let mode = state.mode
        automaticSwitch?.state = mode.automaticDetection ? .on : .off
        manualPortRow?.isHidden = !mode.showsManualPortInput
        if settingsSeparators.count >= 2 {
            settingsSeparators[0].isHidden = !mode.showsManualPortInput
            settingsSeparators[1].isHidden = false
        }
        let resolution = OpenCodexDashboardResolver.resolve(
            manualPort: mode.effectiveManualPort,
            runtimeCandidate: runtimeCandidate
        )
        applyResolution(resolution, canOpen: nil)
        updateCardLayout()
    }

    private func updateCardLayout() {
        guard let rowsStack = settingsRowsStack,
              let cardHeightConstraint = settingsCardHeightConstraint else { return }
        cardHeightConstraint.constant = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: rowsStack,
            separators: settingsSeparators
        )
        onClamp?()
    }

    private func applyResolution(_ resolution: OpenCodexDashboardResolution, canOpen: Bool?) {
        state.updateResolvedPort(resolution.port)
        let isEditing = portField?.currentEditor() != nil
        if !isEditing, !portInputHasError {
            portField?.stringValue = String(state.mode.manualPort ?? resolution.port)
        }
        if let canOpen { openButton?.isEnabled = canOpen }
        portStatusLabel?.stringValue = tr(.keyDashboardAdvancedPageCurrentPortValue2, arguments: [String(describing: resolution.port)])
        DashboardSettingsComponents.invalidateSettingsRowContent(containing: portStatusLabel)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === portField,
              !isEndingPortEditing else { return }
        handlePortChanged(field)
    }

    private func handlePortChanged(_ sender: NSTextField) {
        switch OpenCodexDashboardPortInput.parse(sender.stringValue) {
        case .success(let port):
            portInputHasError = false
            portErrorLabel?.isHidden = true
            manualPortHeightConstraint?.constant = DashboardAdvancedPageLayout.compactTwoLineRowHeight
            state.mode = OpenCodexDashboardMode(automaticDetection: port == nil, manualPort: port)
            onModeChanged?(state.mode)
            portErrorLabel?.stringValue = ""
            SwitchLog.write(
                "OpenCodex Dashboard port preference changed; mode=\(port == nil ? "automatic" : "manual")",
                category: "configuration"
            )
            updateModeUI()
        case .failure:
            portInputHasError = true
            portErrorLabel?.isHidden = false
            portErrorLabel?.stringValue = tr(.keyDashboardAdvancedPageEnterADecimalPortFrom1To65535ClearTheFieldToRestoreAutomaticDetection)
            manualPortHeightConstraint?.constant = DashboardAdvancedPageLayout.invalidPortRowHeight
            updateCardLayout()
        }
    }
}
