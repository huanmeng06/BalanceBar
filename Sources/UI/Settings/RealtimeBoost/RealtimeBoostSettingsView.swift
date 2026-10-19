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
    case promptToggle = "mod.settings.prompt_toggle"

    var defaultText: String {
        switch self {
        case .title: return "实时增强"
        case .statusNotInstalled: return "未开启"
        case .statusWaiting: return "已安装，等待新会话的数据"
        case .statusActive: return "已开启，最近数据 %@"
        case .statusSilent: return "已安装，但 10 分钟内没有收到数据。请新开会话，或在已有会话运行 /reload-plugins"
        case .statusUnsupported: return "Claude Code %@ 过旧，需要 v2.1.287 或更高版本"
        case .install: return "一键安装"
        case .copyCommands: return "复制命令"
        case .promptToggle: return "在菜单中提示实时增强"
        }
    }

    static let defaultLocalize: (RealtimeBoostText) -> String = { $0.defaultText }
}

/// What the settings page shows for a status; tests assert on it without rendering.
struct RealtimeBoostPresentation: Equatable {
    var statusText: String
    var showsInstallAction: Bool
    var showsCopyAction: Bool

    static func make(
        status: ModEnhancementStatus,
        timeZone: TimeZone = .current,
        localize: (RealtimeBoostText) -> String = RealtimeBoostText.defaultLocalize
    ) -> RealtimeBoostPresentation {
        switch status {
        case .notInstalled:
            return .init(statusText: localize(.statusNotInstalled), showsInstallAction: true, showsCopyAction: true)
        case .waitingForData:
            return .init(statusText: localize(.statusWaiting), showsInstallAction: false, showsCopyAction: false)
        case let .active(last):
            return .init(statusText: String(format: localize(.statusActive), StatusSlotAppearance.timeText(last, timeZone: timeZone)),
                         showsInstallAction: false, showsCopyAction: false)
        case .enabledButSilent:
            return .init(statusText: localize(.statusSilent), showsInstallAction: false, showsCopyAction: true)
        case let .unsupportedClaudeCode(version):
            return .init(statusText: String(format: localize(.statusUnsupported), "\(version.major).\(version.minor).\(version.patch)"),
                         showsInstallAction: false, showsCopyAction: false)
        }
    }
}

/// Settings > Advanced > Realtime boost: status, install/copy actions and the menu-prompt toggle.
final class RealtimeBoostSettingsView: NSView {
    private let controller: ModOnboardingController
    private let localize: (RealtimeBoostText) -> String
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    let installButton: NSButton
    let copyButton: NSButton
    let promptToggle: NSButton
    private(set) var presentation: RealtimeBoostPresentation

    init(
        controller: ModOnboardingController,
        status: ModEnhancementStatus,
        localize: @escaping (RealtimeBoostText) -> String = RealtimeBoostText.defaultLocalize
    ) {
        self.controller = controller
        self.localize = localize
        presentation = RealtimeBoostPresentation.make(status: status, localize: localize)
        installButton = NSButton(title: localize(.install), target: nil, action: nil)
        copyButton = NSButton(title: localize(.copyCommands), target: nil, action: nil)
        promptToggle = NSButton(checkboxWithTitle: localize(.promptToggle), target: nil, action: nil)
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: localize(.title))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        installButton.target = self; installButton.action = #selector(install)
        copyButton.target = self; copyButton.action = #selector(copyCommands)
        promptToggle.target = self; promptToggle.action = #selector(togglePrompt)
        let buttons = NSStackView(views: [installButton, copyButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [title, statusLabel, buttons, promptToggle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply()
    }

    required init?(coder: NSCoder) { nil }

    func update(status: ModEnhancementStatus) {
        presentation = RealtimeBoostPresentation.make(status: status, localize: localize)
        apply()
    }

    private func apply() {
        statusLabel.stringValue = presentation.statusText
        installButton.isHidden = !presentation.showsInstallAction
        copyButton.isHidden = !presentation.showsCopyAction
        promptToggle.state = controller.isPromptDismissed ? .off : .on
    }

    @objc private func install() { controller.startInstall() }
    @objc private func copyCommands() { controller.copyInstallCommands() }
    @objc private func togglePrompt() { controller.setPromptEnabled(promptToggle.state == .on) }
}
