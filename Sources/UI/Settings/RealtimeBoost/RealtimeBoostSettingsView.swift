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
    case statusDetecting = "mod.sync.status.detecting"
    case statusClaudeMissing = "mod.sync.status.claude_missing"
    case statusVersionTooOld = "mod.sync.status.version_too_old"
    case statusInboxNotReady = "mod.sync.status.inbox_not_ready"
    case statusOtherScope = "mod.sync.status.other_scope"
    case statusDisabled = "mod.sync.status.disabled"
    case statusRejectedAccount = "mod.sync.status.rejected_account"
    case statusRejectedCycle = "mod.sync.status.rejected_cycle"
    case statusInstallationUnknown = "mod.sync.status.installation_unknown"

    case statusTitleFormat = "mod.settings.status.title_format"
    case statusEnabledShort = "mod.settings.status.enabled_short"
    case lastData = "mod.settings.status.last_data"
    case viewNote = "mod.settings.action.view_note"
    case manage = "mod.settings.action.manage"
    case viewError = "mod.settings.action.view_error"
    case statusSilentShort = "mod.settings.status.silent_short"
    case silentHint = "mod.settings.status.silent_hint"

    var defaultText: String {
        switch self {
        case .title: return "Claude 实时增强"
        case .statusTitleFormat: return "BalanceBar Mod 状态：%1$@"
        case .statusEnabledShort: return "已启用"
        case .lastData: return "最近可信数据（同值快照不会刷新）：%1$@"
        case .viewNote: return "查看说明"
        case .manage: return "管理"
        case .viewError: return "查看原因"
        case .statusSilentShort: return "已安装，但 10 分钟内没有收到数据"
        case .silentHint: return "请新开会话，或在已有会话运行 /reload-plugins"

        case .statusNotInstalled: return "未开启"
        case .statusWaiting: return "已安装，等待新会话的数据"
        case .statusActive: return "已开启，最近可信数据 %@"
        case .statusSilent: return "已安装，但 10 分钟内没有收到数据。请新开会话，或在已有会话运行 /reload-plugins"
        case .statusUnsupported: return "Claude Code %@ 过旧，需要 v2.1.287 或更高版本"
        case .install: return "一键安装"
        case .copyCommands: return "复制命令"
        case .promptToggle: return "在菜单中提示实时增强"
        case .statusDetecting: return "正在检测…"
        case .statusClaudeMissing: return "未找到 claude 命令。请安装 Claude Code 后重试"
        case .statusVersionTooOld: return "Claude Code %@ 过旧，需要 v2.1.287 或更高版本"
        case .statusInboxNotReady: return "快照收件箱不可用（权限不足或所有者不符）。点击安装可重建"
        case .statusOtherScope: return "用户级未安装（检测到项目级安装，仅该项目生效）"
        case .statusDisabled: return "已安装但已停用，实时同步不会运行"
        case .statusRejectedAccount: return "快照被拒：Claude 登录账号与 BalanceBar 当前账号不一致"
        case .statusRejectedCycle: return "快照被拒：周期与官方数据不一致，已回退官方额度"
        case .statusInstallationUnknown: return "无法确认 Mod 是否已安装（插件列表读取失败）"
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

    /// The settings entry's honest status text for `ModSyncStatus`. Only the merge
    /// engine's acceptance of a trusted snapshot produces the "active" wording; every
    /// failure state names its cause and the action that addresses it.
    static func make(
        status: ModSyncStatus,
        timeZone: TimeZone = .current,
        localize: (RealtimeBoostText) -> String = RealtimeBoostText.defaultLocalize
    ) -> RealtimeBoostPresentation {
        switch status {
        case .detecting:
            return .init(statusText: localize(.statusDetecting), showsInstallAction: false, showsCopyAction: false)
        case .claudeMissing:
            return .init(statusText: localize(.statusClaudeMissing), showsInstallAction: true, showsCopyAction: true)
        case let .claudeVersionTooOld(version):
            return .init(
                statusText: String(format: localize(.statusVersionTooOld), "\(version.major).\(version.minor).\(version.patch)"),
                showsInstallAction: false, showsCopyAction: false)
        case .inboxNotReady:
            return .init(statusText: localize(.statusInboxNotReady), showsInstallAction: true, showsCopyAction: false)
        case let .notInstalled(hasOtherScopeInstall):
            if hasOtherScopeInstall {
                return .init(statusText: localize(.statusOtherScope), showsInstallAction: true, showsCopyAction: true)
            }
            return .init(statusText: localize(.statusNotInstalled), showsInstallAction: true, showsCopyAction: true)
        case .disabled:
            return .init(statusText: localize(.statusDisabled), showsInstallAction: false, showsCopyAction: false)
        case .waitingForData:
            return .init(statusText: localize(.statusWaiting), showsInstallAction: false, showsCopyAction: false)
        case let .active(last):
            return .init(statusText: String(format: localize(.statusActive), StatusSlotAppearance.timeText(last, timeZone: timeZone)),
                         showsInstallAction: false, showsCopyAction: false)
        case .silent:
            return .init(statusText: localize(.statusSilent), showsInstallAction: false, showsCopyAction: true)
        case let .snapshotRejected(event):
            let text: RealtimeBoostText = event.rejection == .accountMismatch ? .statusRejectedAccount : .statusRejectedCycle
            return .init(statusText: localize(text), showsInstallAction: false, showsCopyAction: false)
        case .installationUnknown:
            // A failed probe is not "not installed": do not offer a reinstall.
            return .init(statusText: localize(.statusInstallationUnknown), showsInstallAction: false, showsCopyAction: false)
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

/// The INT-2 Advanced card, rendered from the current sync facts and operation.
/// It owns no controller or extra state machine; actions return to composition.
final class RealtimeBoostSettingsRows {
    let statusRow: SettingsRowView
    let installButton: NSButton
    let descriptionButton: NSButton
    let spinner = NSProgressIndicator()
    private let dot = RealtimeBoostStatusDot()
    private let localize: (RealtimeBoostText) -> String
    private let modLocalize: (ModOnboardingText) -> String
    private let onInstall: (NSButton) -> Void
    private let onShowDescription: (NSButton) -> Void

    init(
        status: ModSyncStatus,
        operation: ModPanelState = .intro(dismissChecked: false),
        localize: @escaping (RealtimeBoostText) -> String = realtimeBoostLocalize,
        modLocalize: @escaping (ModOnboardingText) -> String = modOnboardingLocalize,
        onInstall: @escaping (NSButton) -> Void,
        onShowDescription: @escaping (NSButton) -> Void
    ) {
        self.localize = localize
        self.modLocalize = modLocalize
        self.onInstall = onInstall
        self.onShowDescription = onShowDescription
        installButton = NSButton(title: localize(.install), target: nil, action: nil)
        descriptionButton = NSButton(title: localize(.viewNote), target: nil, action: nil)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        installButton.bezelStyle = .rounded
        installButton.bezelColor = .controlAccentColor
        descriptionButton.bezelStyle = .rounded
        installButton.identifier = NSUserInterfaceItemIdentifier("realtimeBoost.install")
        descriptionButton.identifier = NSUserInterfaceItemIdentifier("realtimeBoost.description")
        let actions = NSStackView(views: [spinner, installButton, descriptionButton])
        actions.spacing = 8
        statusRow = SettingsRowView(title: Self.title(for: Self.stateText(for: status, localize: localize), localize: localize),
                                    detail: nil, titleAccessory: dot, accessoryView: actions)
        installButton.target = self; installButton.action = #selector(install(_:))
        descriptionButton.target = self; descriptionButton.action = #selector(showDescription(_:))
        update(status: status, operation: operation)
    }

    func makeSection() -> SettingsSectionView {
        let section = SettingsSectionView(title: localize(.title), contentViews: [statusRow])
        let heading = section.headingLabel
        heading.usesSingleLineMode = false
        heading.lineBreakMode = .byWordWrapping
        heading.maximumNumberOfLines = 0
        heading.cell?.wraps = true
        heading.cell?.isScrollable = false
        heading.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    func update(status: ModSyncStatus, operation: ModPanelState) {
        let stateText = Self.stateText(for: status, localize: localize)
        var detail: String? = nil
        switch status {
        case let .active(at):
            detail = String(format: localize(.lastData), StatusSlotAppearance.timeText(at, timeZone: .current))
        case .silent:
            detail = localize(.silentHint)
        default: break
        }
        var busy = false
        var failed = false
        switch operation {
        case let .installing(step):
            busy = true
            detail = modLocalize([.step1, .step2, .waitingStep][step.rawValue]) + "…"
        case let .uninstalling(step):
            busy = true
            detail = modLocalize([.uninstallStep1, .uninstallStep2, .step3][step.rawValue]) + "…"
        case .failed: failed = true; detail = modLocalize(.failureTitle)
        case .uninstallFailed: failed = true; detail = modLocalize(.uninstallFailureTitle)
        default: break
        }
        let canInstall: Bool
        switch status {
        case .notInstalled, .inboxNotReady: canInstall = true
        default: canInstall = false
        }
        statusRow.titleLabel.stringValue = Self.title(for: stateText, localize: localize)
        statusRow.updateDetail(detail)
        installButton.isHidden = !canInstall || busy
        descriptionButton.title = failed ? localize(.viewError)
            : busy || ModPanelContent.isInstalled(status) ? localize(.manage) : localize(.viewNote)
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        dot.color = failed ? .systemRed : Self.color(for: status)
        statusRow.invalidateAfterContentChange()
    }

    private static func stateText(for status: ModSyncStatus, localize: (RealtimeBoostText) -> String) -> String {
        switch status {
        case .active: return localize(.statusEnabledShort)
        case .silent: return localize(.statusSilentShort)
        default: return RealtimeBoostPresentation.make(status: status, localize: localize).statusText
        }
    }

    static func title(for stateText: String, localize: (RealtimeBoostText) -> String = realtimeBoostLocalize) -> String {
        String(format: localize(.statusTitleFormat), stateText)
    }

    private static func color(for status: ModSyncStatus) -> NSColor {
        switch status {
        case .active: return .systemGreen
        case .detecting, .notInstalled: return .tertiaryLabelColor
        case .waitingForData, .silent, .disabled: return .systemOrange
        default: return .systemRed
        }
    }
    @objc private func install(_ sender: NSButton) { onInstall(sender) }
    @objc private func showDescription(_ sender: NSButton) { onShowDescription(sender) }
}

private final class RealtimeBoostStatusDot: NSView {
    var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
