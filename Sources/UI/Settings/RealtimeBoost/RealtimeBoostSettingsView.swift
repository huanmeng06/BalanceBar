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

    case statusEnabledShort = "mod.settings.status.enabled_short"
    case lastData = "mod.settings.status.last_data"
    case viewNote = "mod.settings.action.view_note"
    case manage = "mod.settings.action.manage"
    case viewError = "mod.settings.action.view_error"

    case cardNotInstalledTitle = "mod.card.not_installed.title"
    case cardNotInstalledReason = "mod.card.not_installed.reason"
    case cardOtherScopeTitle = "mod.card.other_scope.title"
    case cardOtherScopeReason = "mod.card.other_scope.reason"
    case cardOtherScopeAction = "mod.card.other_scope.action"
    case cardWaitingTitle = "mod.card.waiting.title"
    case cardWaitingReason = "mod.card.waiting.reason"
    case cardWaitingAction = "mod.card.waiting.action"
    case cardSilentTitle = "mod.card.silent.title"
    case cardSilentReason = "mod.card.silent.reason"
    case cardSilentAction = "mod.card.silent.action"
    case cardDisabledTitle = "mod.card.disabled.title"
    case cardDisabledReason = "mod.card.disabled.reason"
    case cardDisabledAction = "mod.card.disabled.action"
    case cardClaudeMissingTitle = "mod.card.claude_missing.title"
    case cardClaudeMissingReason = "mod.card.claude_missing.reason"
    case cardClaudeMissingAction = "mod.card.claude_missing.action"
    case cardVersionTooOldTitle = "mod.card.version_too_old.title"
    case cardVersionTooOldReason = "mod.card.version_too_old.reason"
    case cardVersionTooOldAction = "mod.card.version_too_old.action"
    case cardInboxTitle = "mod.card.inbox.title"
    case cardInboxReason = "mod.card.inbox.reason"
    case cardInboxAction = "mod.card.inbox.action"
    case cardRejectedTitle = "mod.card.rejected.title"
    case cardRejectedAccountReason = "mod.card.rejected.account_reason"
    case cardRejectedAccountAction = "mod.card.rejected.account_action"
    case cardRejectedCycleReason = "mod.card.rejected.cycle_reason"
    case cardRejectedCycleAction = "mod.card.rejected.cycle_action"
    case cardUnknownTitle = "mod.card.unknown.title"
    case cardUnknownReason = "mod.card.unknown.reason"
    case cardUnknownAction = "mod.card.unknown.action"
    case cardInstallFailedTitle = "mod.card.install_failed.title"
    case cardUninstallFailedTitle = "mod.card.uninstall_failed.title"
    case cardViewErrorAction = "mod.card.view_error_action"
    case cardRowTitle = "mod.card.row_title"
    case cardRowDescription = "mod.card.row_description"
    case cardLearnMore = "mod.card.learn_more"

    var defaultText: String {
        switch self {
        case .title: return "Claude 实时增强"
        case .statusEnabledShort: return "已启用"
        case .lastData: return "最近可信数据：%1$@"
        case .viewNote: return "查看说明"
        case .manage: return "管理"
        case .viewError: return "查看原因"

        case .cardNotInstalledTitle: return "未安装"
        case .cardNotInstalledReason: return "安装后可实时同步额度"
        case .cardOtherScopeTitle: return "仅项目级安装"
        case .cardOtherScopeReason: return "只在该项目内生效"
        case .cardOtherScopeAction: return "点「%@」装到用户级"
        case .cardWaitingTitle: return "等待数据"
        case .cardWaitingReason: return "已安装，还没收到会话数据"
        case .cardWaitingAction: return "新开一个 Claude 会话即可"
        case .cardSilentTitle: return "暂无数据"
        case .cardSilentReason: return "10 分钟内没有收到数据"
        case .cardSilentAction: return "新开会话，或运行 /reload-plugins"
        case .cardDisabledTitle: return "已停用"
        case .cardDisabledReason: return "插件已安装，但被停用"
        case .cardDisabledAction: return "点「%@」查看启用方法"
        case .cardClaudeMissingTitle: return "未找到 Claude Code"
        case .cardClaudeMissingReason: return "系统中没有 claude 命令"
        case .cardClaudeMissingAction: return "安装 Claude Code 后重试"
        case .cardVersionTooOldTitle: return "版本过旧"
        case .cardVersionTooOldReason: return "当前 Claude Code %1$@"
        case .cardVersionTooOldAction: return "请升级到 v2.1.287 或更高"
        case .cardInboxTitle: return "收件箱不可用"
        case .cardInboxReason: return "权限不足或所有者不符"
        case .cardInboxAction: return "点「%@」重建"
        case .cardRejectedTitle: return "数据被拒绝"
        case .cardRejectedAccountReason: return "Claude 与 BalanceBar 登录的账号不同"
        case .cardRejectedAccountAction: return "请切换到同一账号"
        case .cardRejectedCycleReason: return "周期与官方数据不一致"
        case .cardRejectedCycleAction: return "已改用官方额度"
        case .cardUnknownTitle: return "状态未知"
        case .cardUnknownReason: return "读取插件列表失败"
        case .cardUnknownAction: return "稍后重试"
        case .cardInstallFailedTitle: return "安装失败"
        case .cardUninstallFailedTitle: return "卸载失败"
        case .cardViewErrorAction: return "点「%@」了解详情"
        case .cardRowTitle: return "BalanceBar Mod 实时增强"
        case .cardRowDescription: return "推荐 Claude 桌面版用户，终端也可用；对话中实时推送额度"
        case .cardLearnMore: return "了解更多"

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

/// The row's subtitle: `status · reason · action`, one line, omitting what a state does not have.
struct RealtimeBoostCardCopy: Equatable {
    var status: String
    var reason: String?
    var action: String?

    var detail: String {
        [status, reason, action].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The INT-2 status row, rendered from the current sync facts and operation.
/// It owns no controller or extra state machine; actions return to composition.
final class RealtimeBoostSettingsRows {
    let statusRow: SettingsRowView
    let installButton: NSButton
    let descriptionButton: NSButton
    let spinner = NSProgressIndicator()
    private let localize: (RealtimeBoostText) -> String
    private let modLocalize: (ModOnboardingText) -> String
    private let onInstall: (NSButton) -> Void
    private let onShowDescription: (NSButton) -> Void

    static func cardCopy(
        status: ModSyncStatus,
        operation: ModPanelState,
        localize: (RealtimeBoostText) -> String = realtimeBoostLocalize,
        modLocalize: (ModOnboardingText) -> String = modOnboardingLocalize,
        timeZone: TimeZone = .current
    ) -> RealtimeBoostCardCopy {
        let base: RealtimeBoostCardCopy
        switch status {
        case .detecting:
            base = .init(status: localize(.statusDetecting))
        case let .notInstalled(hasOtherScopeInstall):
            if hasOtherScopeInstall {
                base = .init(
                    status: localize(.cardOtherScopeTitle),
                    reason: localize(.cardOtherScopeReason),
                    action: String(format: localize(.cardOtherScopeAction), localize(.install)))
            } else {
                base = .init(status: localize(.cardNotInstalledTitle), reason: localize(.cardNotInstalledReason))
            }
        case .waitingForData:
            base = .init(status: localize(.cardWaitingTitle), reason: localize(.cardWaitingReason),
                         action: localize(.cardWaitingAction))
        case let .active(at):
            base = .init(status: localize(.statusEnabledShort),
                         reason: String(format: localize(.lastData), StatusSlotAppearance.timeText(at, timeZone: timeZone)))
        case .silent:
            base = .init(status: localize(.cardSilentTitle), reason: localize(.cardSilentReason),
                         action: localize(.cardSilentAction))
        case .disabled:
            base = .init(status: localize(.cardDisabledTitle), reason: localize(.cardDisabledReason),
                         action: String(format: localize(.cardDisabledAction), localize(.cardLearnMore)))
        case .claudeMissing:
            base = .init(status: localize(.cardClaudeMissingTitle), reason: localize(.cardClaudeMissingReason),
                         action: localize(.cardClaudeMissingAction))
        case let .claudeVersionTooOld(version):
            base = .init(status: localize(.cardVersionTooOldTitle),
                         reason: String(format: localize(.cardVersionTooOldReason), "\(version.major).\(version.minor).\(version.patch)"),
                         action: localize(.cardVersionTooOldAction))
        case .inboxNotReady:
            base = .init(status: localize(.cardInboxTitle), reason: localize(.cardInboxReason),
                         action: String(format: localize(.cardInboxAction), localize(.install)))
        case let .snapshotRejected(event):
            let reason: RealtimeBoostText
            let action: RealtimeBoostText
            switch event.rejection {
            case .accountMismatch:
                reason = .cardRejectedAccountReason
                action = .cardRejectedAccountAction
            case .unverifiedCycle:
                reason = .cardRejectedCycleReason
                action = .cardRejectedCycleAction
            }
            base = .init(status: localize(.cardRejectedTitle), reason: localize(reason), action: localize(action))
        case .installationUnknown:
            base = .init(status: localize(.cardUnknownTitle), reason: localize(.cardUnknownReason),
                         action: localize(.cardUnknownAction))
        }

        switch operation {
        case let .installing(step):
            return .init(status: base.status,
                         reason: modLocalize([.step1, .step2, .waitingStep][step.rawValue]) + "…")
        case let .uninstalling(step):
            return .init(status: base.status,
                         reason: modLocalize([.uninstallStep1, .uninstallStep2, .step3][step.rawValue]) + "…")
        case .failed:
            return .init(status: localize(.cardInstallFailedTitle), reason: modLocalize(.failureTitle),
                         action: String(format: localize(.cardViewErrorAction), localize(.viewError)))
        case .uninstallFailed:
            return .init(status: localize(.cardUninstallFailedTitle), reason: modLocalize(.uninstallFailureTitle),
                         action: String(format: localize(.cardViewErrorAction), localize(.viewError)))
        default:
            return base
        }
    }

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
        let initialCopy = Self.cardCopy(status: status, operation: operation, localize: localize, modLocalize: modLocalize)
        statusRow = SettingsRowView(title: localize(.cardRowTitle),
                                    detail: Self.subtitle(description: localize(.cardRowDescription), status: initialCopy.detail),
                                    titleAccessory: DashboardRefreshPage.agentIconStrip(["Claude"]), accessoryView: actions)
        installButton.target = self; installButton.action = #selector(install(_:))
        descriptionButton.target = self; descriptionButton.action = #selector(showDescription(_:))
        update(status: status, operation: operation)
    }

    /// The status dot leads the status line, so it sits next to the status word it colours.
    static let dotPrefix = "● "

    /// Line one says who the Mod is for; line two is the live status, which nearly always has content.
    static func subtitle(description: String, status: String) -> String {
        description + "\n" + dotPrefix + status
    }

    private func applyDetail(_ detail: String, dotColor: NSColor) {
        let description = localize(.cardRowDescription)
        statusRow.updateDetail(Self.subtitle(description: description, status: detail))
        let dotLocation = (description as NSString).length + 1
        let label = statusRow.detailLabel
        let font = label.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSMutableAttributedString(string: label.stringValue, attributes: [
            .font: font, .foregroundColor: label.textColor ?? NSColor.secondaryLabelColor])
        let dotFont = NSFont.systemFont(ofSize: font.pointSize * 0.7)
        text.addAttributes([
            .font: dotFont, .foregroundColor: dotColor,
            .baselineOffset: (font.capHeight - dotFont.capHeight) / 2,
        ], range: NSRange(location: dotLocation, length: 1))
        label.attributedStringValue = text
    }

    func update(status: ModSyncStatus, operation: ModPanelState) {
        let copy = Self.cardCopy(status: status, operation: operation, localize: localize, modLocalize: modLocalize)
        var busy = false
        var failed = false
        switch operation {
        case .installing, .uninstalling:
            busy = true
        case .failed, .uninstallFailed: failed = true
        default: break
        }
        let canInstall: Bool
        switch status {
        case .notInstalled, .inboxNotReady: canInstall = true
        default: canInstall = false
        }
        statusRow.titleLabel.stringValue = localize(.cardRowTitle)
        applyDetail(copy.detail, dotColor: failed ? .systemRed : Self.color(for: status))
        installButton.isHidden = !canInstall || busy
        descriptionButton.title = failed ? localize(.viewError)
            : busy ? localize(.manage) : localize(.cardLearnMore)
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        statusRow.invalidateAfterContentChange()
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
