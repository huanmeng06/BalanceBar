import AppKit

/// Text for Settings > Advanced > Realtime boost.
enum RealtimeBoostText: String, CaseIterable {
    case title = "mod.settings.title"
    case statusTitleFormat = "mod.settings.status.title_format"
    case statusNotInstalled = "mod.settings.status.not_installed"
    case statusWaiting = "mod.settings.status.waiting"
    case statusActive = "mod.settings.status.active"
    case statusSilent = "mod.settings.status.silent"
    case statusUnsupported = "mod.settings.status.unsupported"
    case lastData = "mod.settings.status.last_data"
    case silentHint = "mod.settings.status.silent_hint"
    case unsupportedDetail = "mod.settings.status.unsupported_detail"
    case install = "mod.settings.action.install"
    case viewNote = "mod.settings.action.view_note"
    case manage = "mod.settings.action.manage"
    case promptToggle = "mod.settings.prompt_toggle"

    var defaultText: String {
        switch self {
        case .title: return "Claude 实时增强"
        case .statusTitleFormat: return "BalanceBar Mod 状态：%@"
        case .statusNotInstalled: return "未安装"
        case .statusWaiting: return "已安装，等待新会话的数据"
        case .statusActive: return "已启用"
        case .statusSilent: return "已安装，但 10 分钟内没有收到数据"
        case .statusUnsupported: return "Claude Code 版本过旧"
        case .lastData: return "最新数据：%@"
        case .silentHint: return "请新开会话，或在已有会话运行 /reload-plugins"
        case .unsupportedDetail: return "当前 %@，需要 v2.1.287 或更高版本"
        case .install: return "一键安装"
        case .viewNote: return "查看说明"
        case .manage: return "管理"
        case .promptToggle: return "在菜单中显示安装提示"
        }
    }

    static let defaultLocalize: (RealtimeBoostText) -> String = { $0.defaultText }

    /// Routes copy through the app's localization tables. Formats keep a literal `%1$@` for `String(format:)` later.
    static let appLocalize: (RealtimeBoostText) -> String = { text in
        guard let key = LocalizationKey(rawValue: text.rawValue) else { return text.defaultText }
        switch text {
        case .statusTitleFormat, .lastData, .unsupportedDetail: return tr(key, arguments: ["%1$@"])
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
    /// "BalanceBar Mod status: <state>", the title of the status row.
    var statusText: String
    /// Just the state ("Enabled"), for the explanation window.
    var stateText: String
    /// The second line: the latest data time, a hint, or the version problem.
    var detailText: String?
    var statusTone: RealtimeBoostStatusTone = .gray
    var showsInstallAction: Bool
    /// The Mod is installed: the button opens the management view.
    var isInstalled: Bool = false

    /// The state and its detail on two lines (the explanation window's subtitle).
    var stateAndDetail: String { detailText.map { stateText + "\n" + $0 } ?? stateText }

    static func make(
        status: ModEnhancementStatus,
        timeZone: TimeZone = .current,
        localize: (RealtimeBoostText) -> String = RealtimeBoostText.defaultLocalize
    ) -> RealtimeBoostPresentation {
        func titled(_ state: String) -> String { String(format: localize(.statusTitleFormat), state) }
        switch status {
        case .notInstalled:
            let state = localize(.statusNotInstalled)
            return .init(statusText: titled(state), stateText: state, statusTone: .gray,
                         showsInstallAction: true)
        case .waitingForData:
            let state = localize(.statusWaiting)
            return .init(statusText: titled(state), stateText: state, statusTone: .orange,
                         showsInstallAction: false, isInstalled: true)
        case let .active(last):
            let state = localize(.statusActive)
            return .init(statusText: titled(state), stateText: state,
                         detailText: String(format: localize(.lastData), StatusSlotAppearance.timeText(last, timeZone: timeZone)),
                         statusTone: .green, showsInstallAction: false, isInstalled: true)
        case .enabledButSilent:
            let state = localize(.statusSilent)
            return .init(statusText: titled(state), stateText: state, detailText: localize(.silentHint), statusTone: .orange,
                         showsInstallAction: false, isInstalled: true)
        case let .unsupportedClaudeCode(version):
            let state = localize(.statusUnsupported)
            return .init(statusText: titled(state), stateText: state,
                         detailText: String(format: localize(.unsupportedDetail), "\(version.major).\(version.minor).\(version.patch)"),
                         statusTone: .red, showsInstallAction: false)
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
        // Same size and style as the other buttons on this page (for example "export log").
        installButton.bezelColor = .controlAccentColor
        let actions = NSStackView(views: [spinner, installButton, descriptionButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        statusRow = SettingsRowView(title: presentation.statusText, detail: nil, titleAccessory: dot, accessoryView: actions)
        promptRow = SettingsRowView(title: localize(.promptToggle), detail: nil, accessoryView: promptSwitch)

        installButton.target = self; installButton.action = #selector(install)
        descriptionButton.target = self; descriptionButton.action = #selector(showDescription)
        promptSwitch.target = self; promptSwitch.action = #selector(togglePrompt)
        if observesController { controller.onStateChange = { [weak self] in self?.apply() } }
        apply()
    }

    func update(status: ModEnhancementStatus) {
        presentation = RealtimeBoostPresentation.make(status: status, localize: localize)
        apply()
    }

    /// The step in progress while the install commands run (or a failure notice), otherwise the status detail.
    var detailText: String {
        switch controller.state {
        case let .installing(step):
            let labels = [modLocalize(.step1), modLocalize(.step2), modLocalize(.step3)]
            return labels[step.rawValue] + "…"
        case .failed: return modLocalize(.failureTitle)
        default: return presentation.detailText ?? ""
        }
    }

    private func apply() {
        var installing = false
        switch controller.state {
        case .installing: installing = true
        default: break
        }
        statusRow.titleLabel.stringValue = presentation.statusText
        statusRow.updateDetail(detailText)
        statusRow.invalidateAfterContentChange()
        dot.effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = presentation.statusTone.color.cgColor
        }
        installButton.isHidden = !presentation.showsInstallAction || installing
        descriptionButton.isHidden = installing
        // An installed Mod opens its management view, not the install pitch.
        descriptionButton.title = presentation.isInstalled ? localize(.manage) : localize(.viewNote)
        if installing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        promptSwitch.state = controller.isPromptDismissed ? .off : .on
    }

    @objc private func install() { controller.startInstall() }
    @objc private func showDescription() { onShowDescription?() }
    @objc private func togglePrompt() { controller.setPromptEnabled(promptSwitch.state == .on) }
}
