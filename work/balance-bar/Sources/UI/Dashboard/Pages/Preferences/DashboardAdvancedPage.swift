import AppKit

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

        let animation = DashboardSettingsComponents.makeSwitch(
            identifier: "animateCodexActivity",
            isOn: input.preferences.animateCodexActivity,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let activity = DashboardSettingsComponents.makeSettingsSection(tr("任务状态", "Task Status"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("任务运行时播放图标动画", "Animate Icon While a Task Is Running"),
                control: animation
            )
        ])

        let automaticDetection = input.preferences.openCodexDashboardAutomaticDetection
        let currentResolution = input.currentResolution
        let initialResolution = currentResolution ?? OpenCodexDashboardResolver.resolve(
            manualPort: input.mode.effectiveManualPort,
            runtimeCandidate: nil
        )
        let statusLabel = NSTextField(wrappingLabelWithString: tr("正在解析…", "Resolving…"))
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
            tr("自动检测端口", "Detect Port Automatically"),
            subtitle: tr(
                "使用已验证的 OpenCodex runtime 端口；未检测时使用 10100",
                "Use the verified OpenCodex runtime port; use 10100 until one is detected"
            ),
            subtitleLabel: statusLabel,
            control: automaticSwitch,
            minimumHeight: 86
        )

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
        manualPortRow.isHidden = automaticDetection

        let openButton = NSButton(
            title: tr("打开 OpenCodex", "Open OpenCodex"),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openOpenCodex(_:))
        )
        openButton.isEnabled = currentResolution != nil
        automaticSwitchState(automaticSwitch, portField: portField, manualPortRow: manualPortRow, statusLabel: statusLabel, errorLabel: errorLabel, openButton: openButton)

        let openButtonRow = DashboardSettingsComponents.makeSettingsRow(
            tr("OpenCodex Dashboard", "OpenCodex Dashboard"),
            subtitle: tr(
                "使用当前解析到的本机地址；固定打开 /#dashboard",
                "Uses the resolved local address and always opens /#dashboard"
            ),
            control: openButton,
            minimumHeight: 78
        )
        let openCodex = DashboardSettingsComponents.makeSettingsSection(
            tr("OpenCodex", "OpenCodex"),
            rows: [automaticRow, manualPortRow, openButtonRow],
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

        let refreshLog = NSButton(
            title: tr("重新载入", "Reload"),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.refreshLog(_:))
        )
        let revealLog = NSButton(
            title: tr("在 Finder 中显示", "Show in Finder"),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.revealLog(_:))
        )
        let logButtons = NSStackView(views: [refreshLog, revealLog])
        logButtons.orientation = .horizontal
        logButtons.spacing = 8
        let logs = DashboardSettingsComponents.makeSettingsSection(tr("诊断", "Diagnostics"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("调试日志", "Debug Log"),
                subtitle: tr("记录运行状态与错误", "Records runtime status and errors"),
                control: logButtons
            ),
            input.logViewer
        ])
        return DashboardSettingsComponents.makeSettingsPage([activity, openCodex, logs])
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
        manualPortHeightConstraint?.constant = 86
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
        let heightConstraint = row.heightAnchor.constraint(equalToConstant: 86)
        heightConstraint.isActive = true
        manualPortHeightConstraint = heightConstraint
        let title = NSTextField(labelWithString: tr("手动输入端口号", "Enter Port Manually"))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: tr(
            "仅接受去空格后的十进制 1–65535；清空后恢复自动检测",
            "Only trimmed decimal 1–65535 is accepted; clear the field to restore automatic detection"
        ))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isEditable = false
        errorLabel.isSelectable = false
        errorLabel.isHidden = true
        let labels = NSStackView(views: [title, detail, errorLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        portField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(portField)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 11),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -11),
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
        rowsStack.layoutSubtreeIfNeeded()
        let visibleRows = rowsStack.arrangedSubviews.filter { !($0 is NSBox) && !$0.isHidden }
        let rowsHeight = visibleRows.reduce(CGFloat(0)) { partial, row in
            let explicitHeight = row.constraints.first {
                ($0.firstItem as? NSView) === row && $0.firstAttribute == .height && $0.relation == .equal
            }?.constant
            return partial + max(1, explicitHeight ?? row.fittingSize.height)
        }
        let separatorHeight = settingsSeparators.filter { !$0.isHidden }.reduce(CGFloat(0)) {
            $0 + max(1, $1.fittingSize.height)
        }
        cardHeightConstraint.constant = ceil(rowsHeight + separatorHeight)
        onClamp?()
    }

    private func applyResolution(_ resolution: OpenCodexDashboardResolution, canOpen: Bool?) {
        state.updateResolvedPort(resolution.port)
        let isEditing = portField?.currentEditor() != nil
        if !isEditing, !portInputHasError {
            portField?.stringValue = String(state.mode.manualPort ?? resolution.port)
        }
        if let canOpen { openButton?.isEnabled = canOpen }
        let currentPort = tr("当前端口：\(resolution.port)", "Current port: \(resolution.port)")
        switch resolution.source {
        case .manual:
            portStatusLabel?.stringValue = tr(
                "\(currentPort)\n手动端口只用于打开本机 Dashboard；不会修改 OpenCodex 配置",
                "\(currentPort)\nThe manual port only opens the local Dashboard; it does not modify OpenCodex configuration"
            )
        case .runtime:
            portStatusLabel?.stringValue = tr(
                "\(currentPort)\n已自动检测 OpenCodex runtime 端口",
                "\(currentPort)\nOpenCodex runtime port detected automatically"
            )
        case .fallback:
            portStatusLabel?.stringValue = tr(
                "\(currentPort)\n尚未自动检测；将使用默认端口 10100",
                "\(currentPort)\nNot detected yet; the default port 10100 will be used"
            )
        }
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
            manualPortHeightConstraint?.constant = 86
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
            portErrorLabel?.stringValue = tr(
                "请输入 1 到 65535 的十进制端口；空值恢复自动检测",
                "Enter a decimal port from 1 to 65535; clear the field to restore automatic detection"
            )
            manualPortHeightConstraint?.constant = 112
            updateCardLayout()
        }
    }
}
