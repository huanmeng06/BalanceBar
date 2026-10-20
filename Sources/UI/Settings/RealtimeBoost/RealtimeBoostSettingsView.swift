import AppKit

/// Text for Settings > Advanced > Realtime boost.
enum RealtimeBoostText: String, CaseIterable {
    case title = "mod.settings.title"
    case statusNotInstalled = "mod.settings.status.not_installed"
    case statusWaiting = "mod.settings.status.waiting"
    case statusActive = "mod.settings.status.active"
    case statusSilent = "mod.settings.status.silent"
    case statusUnsupported = "mod.settings.status.unsupported"
    case install = "mod.settings.action.install"
    case copyCommands = "mod.settings.action.copy"
    case viewNote = "mod.settings.action.view_note"
    case promptToggle = "mod.settings.prompt_toggle"
    case uninstallNote = "mod.settings.uninstall_note"

    var defaultText: String {
        switch self {
        case .title: return "实时增强"
        case .statusNotInstalled: return "未安装"
        case .statusWaiting: return "已安装，等待新会话的数据"
        case .statusActive: return "已启用 · 最近数据 %@"
        case .statusSilent: return "已安装，但 10 分钟内没有收到数据。请新开会话，或在已有会话运行 /reload-plugins"
        case .statusUnsupported: return "Claude Code %@ 过旧，需要 v2.1.287 或更高版本"
        case .install: return "一键安装"
        case .copyCommands: return "复制命令"
        case .viewNote: return "查看说明"
        case .promptToggle: return "在菜单中显示安装提示"
        case .uninstallNote: return "卸载：在 Claude Code 中输入 /plugin 即可移除。"
        }
    }

    static let defaultLocalize: (RealtimeBoostText) -> String = { $0.defaultText }

    /// Routes copy through the app's localization tables. Status formats keep a literal `%1$@`.
    static let appLocalize: (RealtimeBoostText) -> String = { text in
        guard let key = LocalizationKey(rawValue: text.rawValue) else { return text.defaultText }
        switch text {
        case .statusActive, .statusUnsupported: return tr(key, arguments: ["%1$@"])
        default: return tr(key)
        }
    }
}

/// The color of the dot in front of the status text.
enum RealtimeBoostStatusTone: Equatable {
    case gray, orange, green, red

    var color: NSColor {
        switch self {
        case .gray: return .tertiaryLabelColor
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .red: return .systemRed
        }
    }
}

/// What the settings page shows for a status; tests assert on it without rendering.
struct RealtimeBoostPresentation: Equatable {
    var statusText: String
    var statusTone: RealtimeBoostStatusTone = .gray
    var showsInstallAction: Bool
    var showsCopyAction: Bool
    /// How to remove the Mod, shown once it is installed.
    var showsUninstallNote: Bool = false

    static func make(
        status: ModEnhancementStatus,
        timeZone: TimeZone = .current,
        localize: (RealtimeBoostText) -> String = RealtimeBoostText.defaultLocalize
    ) -> RealtimeBoostPresentation {
        switch status {
        case .notInstalled:
            return .init(statusText: localize(.statusNotInstalled), statusTone: .gray,
                         showsInstallAction: true, showsCopyAction: true)
        case .waitingForData:
            return .init(statusText: localize(.statusWaiting), statusTone: .orange,
                         showsInstallAction: false, showsCopyAction: false, showsUninstallNote: true)
        case let .active(last):
            return .init(statusText: String(format: localize(.statusActive), StatusSlotAppearance.timeText(last, timeZone: timeZone)),
                         statusTone: .green, showsInstallAction: false, showsCopyAction: false, showsUninstallNote: true)
        case .enabledButSilent:
            return .init(statusText: localize(.statusSilent), statusTone: .orange,
                         showsInstallAction: false, showsCopyAction: true, showsUninstallNote: true)
        case let .unsupportedClaudeCode(version):
            return .init(statusText: String(format: localize(.statusUnsupported), "\(version.major).\(version.minor).\(version.patch)"),
                         statusTone: .red, showsInstallAction: false, showsCopyAction: false)
        }
    }
}

/// Settings › Advanced › Real-time boost, as rows for a `SettingsSectionView`: the status (colored dot, text, the install
/// actions or progress) and the menu-prompt switch. One instance follows the live status; a detached copy serves search.
final class RealtimeBoostSettingsRows {
    private let controller: ModOnboardingController
    private let localize: (RealtimeBoostText) -> String
    private let modLocalize: (ModOnboardingText) -> String
    private(set) var presentation: RealtimeBoostPresentation

    let statusRow: SettingsRowView
    let promptRow: SettingsRowView
    let installButton: NSButton
    let copyButton: NSButton
    let descriptionButton: NSButton
    let spinner = NSProgressIndicator()
    let promptSwitch: NSSwitch
    private let dot = NSView()
    private let onShowDescription: (() -> Void)?

    var rows: [NSView] { [statusRow, promptRow] }

    /// - Parameters:
    ///   - observesController: `false` for a detached copy that must not take over the install-progress observer.
    ///   - onShowDescription: opens the explanation window ("show description").
    init(
        controller: ModOnboardingController,
        status: ModEnhancementStatus,
        localize: @escaping (RealtimeBoostText) -> String = RealtimeBoostText.defaultLocalize,
        modLocalize: @escaping (ModOnboardingText) -> String = ModOnboardingText.appLocalize,
        observesController: Bool = true,
        onShowDescription: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.localize = localize
        self.modLocalize = modLocalize
        self.onShowDescription = onShowDescription
        presentation = RealtimeBoostPresentation.make(status: status, localize: localize)
        installButton = NSButton(title: localize(.install), target: nil, action: nil)
        copyButton = NSButton(title: localize(.copyCommands), target: nil, action: nil)
        descriptionButton = NSButton(title: localize(.viewNote), target: nil, action: nil)
        promptSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "realtimeBoost.promptSwitch", isOn: !controller.isPromptDismissed, target: nil, action: nil)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        for button in [installButton, copyButton, descriptionButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        installButton.bezelColor = .controlAccentColor
        let actions = NSStackView(views: [spinner, installButton, copyButton, descriptionButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        statusRow = SettingsRowView(title: presentation.statusText, detail: nil, titleAccessory: dot, accessoryView: actions)
        promptRow = SettingsRowView(title: localize(.promptToggle), detail: nil, accessoryView: promptSwitch)

        installButton.target = self; installButton.action = #selector(install)
        copyButton.target = self; copyButton.action = #selector(copyCommands)
        descriptionButton.target = self; descriptionButton.action = #selector(showDescription)
        promptSwitch.target = self; promptSwitch.action = #selector(togglePrompt)
        if observesController { controller.onStateChange = { [weak self] in self?.apply() } }
        apply()
    }

    func update(status: ModEnhancementStatus) {
        presentation = RealtimeBoostPresentation.make(status: status, localize: localize)
        apply()
    }

    /// The step in progress while the install commands run (or a failure notice), otherwise the removal hint.
    var detailText: String {
        switch controller.state {
        case let .installing(step):
            let labels = [modLocalize(.step1), modLocalize(.step2), modLocalize(.step3)]
            return labels[step.rawValue] + "…"
        case .failed: return modLocalize(.failureTitle)
        default: return presentation.showsUninstallNote ? localize(.uninstallNote) : ""
        }
    }

    private func apply() {
        var installing = false
        var failed = false
        switch controller.state {
        case .installing: installing = true
        case .failed: failed = true
        default: break
        }
        statusRow.titleLabel.stringValue = presentation.statusText
        let detail = detailText
        statusRow.detailLabel.stringValue = detail
        statusRow.detailLabel.isHidden = detail.isEmpty
        dot.effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = presentation.statusTone.color.cgColor
        }
        installButton.isHidden = !presentation.showsInstallAction || installing
        // A failed install leaves the copyable commands as the way forward.
        copyButton.isHidden = !(presentation.showsCopyAction || failed)
        descriptionButton.isHidden = installing
        if installing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        promptSwitch.state = controller.isPromptDismissed ? .off : .on
    }

    @objc private func install() { controller.startInstall() }
    @objc private func copyCommands() { controller.copyInstallCommands() }
    @objc private func showDescription() { onShowDescription?() }
    @objc private func togglePrompt() { controller.setPromptEnabled(promptSwitch.state == .on) }
}
