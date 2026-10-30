import AppKit

/// User-visible copy. Defaults are Simplified Chinese; the integration layer can inject `localize`.
enum ModOnboardingText: String, CaseIterable {
    case promptRow = "mod.prompt.row"
    case promptWhy = "mod.prompt.why"
    case promptMenu = "mod.prompt.menu"
    case panelTitle = "mod.panel.title"
    case point1 = "mod.panel.point1"
    case point2 = "mod.panel.point2"
    case point3 = "mod.panel.point3"
    case point4 = "mod.panel.point4"
    case installButton = "mod.panel.install"
    case dismissCheckbox = "mod.panel.dismiss_checkbox"
    case closeButton = "mod.panel.close"
    case step1 = "mod.install.step1"
    case step2 = "mod.install.step2"
    case step3 = "mod.install.step3"
    case enabled = "mod.install.enabled"
    case enabledNote = "mod.install.enabled_note"
    case reloadHint = "mod.install.reload_hint"
    case failureTitle = "mod.failure.title"
    case failureClaudeMissing = "mod.failure.claude_missing"
    case failureCommandFailed = "mod.failure.command_failed"
    case copyCommands = "mod.failure.copy"
    case copied = "mod.failure.copied"
    case dismissedTitle = "mod.dismissed.title"
    case dismissedNote = "mod.dismissed.note"
    case undoDismiss = "mod.dismissed.undo"
    case uninstallButton = "mod.panel.uninstall"
    case uninstallStep1 = "mod.uninstall.step1"
    case uninstallStep2 = "mod.uninstall.step2"
    case uninstallDone = "mod.uninstall.done"
    case uninstallDoneNote = "mod.uninstall.done_note"
    case failureUninstall = "mod.failure.uninstall_command"
    case copyEnableCommands = "mod.failure.copy_enable"
    case failureInbox = "mod.failure.inbox"

    case subtitle = "mod.ui.subtitle"
    case benefitRealtime = "mod.ui.benefit_realtime"
    case benefitFallback = "mod.ui.benefit_fallback"
    case benefitPrivacy = "mod.ui.benefit_privacy"
    case coverageNote = "mod.ui.coverage_note"
    case fallbackNote = "mod.ui.fallback_note"
    case waitingTitle = "mod.ui.waiting_title"
    case waitingStep = "mod.ui.waiting_step"
    case backgroundNote = "mod.ui.background_note"
    case refresh = "mod.ui.refresh"
    case retry = "mod.ui.retry"
    case confirmUninstall = "mod.ui.confirm_uninstall"
    case confirmUninstallNote = "mod.ui.confirm_uninstall_note"
    case confirmUninstallAction = "mod.ui.confirm_uninstall_action"
    case uninstallReloadHint = "mod.ui.uninstall_reload_hint"
    case cancel = "mod.ui.cancel"
    case viewStatus = "mod.ui.view_status"
    case backToIntro = "mod.ui.back_to_intro"
    case lastDataNote = "mod.ui.last_data_note"
    case uninstallFailureTitle = "mod.ui.uninstall_failure_title"
    case accountAdvice = "mod.ui.account_advice"
    case cycleAdvice = "mod.ui.cycle_advice"

    case pitchTitle = "mod.ui.int2.pitch_title"
    case pitchSubtitle = "mod.ui.int2.pitch_subtitle"
    case laterButton = "mod.ui.int2.later_button"
    case feature1Title = "mod.ui.int2.feature1_title"
    case feature1Detail = "mod.ui.int2.feature1_detail"
    case feature2Title = "mod.ui.int2.feature2_title"
    case feature4Title = "mod.ui.int2.feature4_title"
    case feature4Detail = "mod.ui.int2.feature4_detail"
    case manageTitle = "mod.ui.int2.manage_title"
    case removeNote = "mod.ui.int2.remove_note"
    case silentTitle = "mod.ui.int2.silent_title"
    case uninstalledTitle = "mod.ui.int2.uninstalled_title"
    case silentCheckVersion = "mod.ui.int2.silent_check_version"
    case silentCheckSession = "mod.ui.int2.silent_check_session"
    case silentCheckPolicy = "mod.ui.int2.silent_check_policy"

    var defaultText: String {
        switch self {
        case .pitchTitle: return "BalanceBar Mod 实时增强"
        case .pitchSubtitle: return "BalanceBar Mod 是运行在 Claude Code 里的小插件，每轮回复后把官方额度告诉 BalanceBar。"
        case .laterButton: return "稍后"
        case .feature1Title: return "实时、官方数据"
        case .feature1Detail: return "每轮回复后立即更新，不是估算"
        case .feature2Title: return "覆盖 Agent 场景"
        case .feature4Title: return "只读，可随时移除"
        case .feature4Detail: return "不读对话内容；在 /plugin 中即可卸载"
        case .manageTitle: return "BalanceBar Mod 已安装"
        case .removeNote: return "不想用了？卸载后，新会话不再向 BalanceBar 写入数据，额度回到定时查询。"
        case .silentTitle: return "已安装，但还没收到数据"
        case .uninstalledTitle: return "已卸载"
        case .silentCheckVersion: return "Claude Code 版本是否为 v2.1.287 或更高"
        case .silentCheckSession: return "是否是新会话，或已在会话中运行 /reload-plugins"
        case .silentCheckPolicy: return "组织策略是否只允许托管插件"
        case .subtitle: return "让 Claude Code 额度更新更及时"
        case .benefitRealtime: return "实时额度"
        case .benefitFallback: return "官方兜底"
        case .benefitPrivacy: return "本地与隐私"
        case .coverageNote: return "覆盖 Claude Code CLI 与 Desktop Code 会话。"
        case .fallbackNote: return "数据不可用或不可信时，继续使用官方额度。"
        case .waitingTitle: return "已安装，等待首份可信数据"
        case .waitingStep: return "等待可信数据"
        case .backgroundNote: return "关闭窗口不会中断操作，可随时重新打开查看进度。"
        case .refresh: return "重新检测"
        case .retry: return "重试"
        case .confirmUninstall: return "卸载 BalanceBar Mod？"
        case .confirmUninstallNote: return "卸载后，Claude 额度改为定时向官方查询，不再实时更新。其他插件不受影响。"
        case .confirmUninstallAction: return "卸载"
        case .uninstallReloadHint: return "已有会话可运行下面的命令，让卸载立即生效。"
        case .cancel: return "取消"
        case .viewStatus: return "查看当前状态"
        case .backToIntro: return "返回介绍"
        case .lastDataNote: return "「最近可信数据」是 BalanceBar 最后一次采用额度数据的时间；额度没变化时不会更新。"
        case .uninstallFailureTitle: return "卸载未完成"
        case .accountAdvice: return "请确认 Claude Code 与 BalanceBar 使用同一账号，再新开会话。"
        case .cycleAdvice: return "继续使用官方额度；新周期经官方确认后，再检查新会话的数据。"
        case .promptRow: return "启用实时增强 ›"
        case .promptWhy: return "为什么这么做？"
        case .promptMenu: return "为 Claude 安装 Mod，额度实时更新"
        case .panelTitle: return "实时增强"
        case .point1: return "只读取额度数据（5 小时 / 7 天用量），不读取对话内容。"
        case .point2: return "插件以你的用户权限在 Claude Code 内运行，可随时用 /plugin 卸载。"
        case .point3: return "数据只写入本机，不联网上传。"
        case .point4: return "新会话自动生效；已有会话可运行 /reload-plugins。"
        case .installButton: return "一键安装"
        case .dismissCheckbox: return "不再在菜单中提示"
        case .closeButton: return "关闭"
        case .step1: return "添加来源"
        case .step2: return "安装 Mod"
        case .step3: return "完成"
        case .enabled: return "已开启 ✓"
        case .enabledNote: return "新开的 Claude Code 会话会自动生效。"
        case .reloadHint: return "已有会话可选运行下面的命令。"
        case .failureTitle: return "无法自动安装"
        case .failureClaudeMissing: return "没有找到 claude 命令。请在终端中运行下面的命令："
        case .failureCommandFailed: return "命令未成功完成。请在终端中运行下面的命令："
        case .copyCommands: return "复制命令"
        case .copied: return "已复制"
        case .dismissedTitle: return "已隐藏提示"
        case .dismissedNote: return "之后可以在 设置 › 通用 › 刷新 中安装 BalanceBar Mod。"
        case .undoDismiss: return "撤销"
        case .uninstallButton: return "卸载 BalanceBar Mod"
        case .uninstallStep1: return "卸载 Mod"
        case .uninstallStep2: return "移除安装来源"
        case .uninstallDone: return "已卸载 ✓"
        case .uninstallDoneNote: return "额度已改为定时向官方查询。其他插件不受影响。"
        case .failureUninstall: return "卸载未完成。请在终端中运行下面的命令："
        case .copyEnableCommands: return "复制启用命令"
        case .failureInbox: return "快照收件箱无法创建（权限不足或所有者不符）。请检查 ~/Library/Application Support/BalanceBar/inbox 后重试。"
        }
    }

    static let defaultLocalize: (ModOnboardingText) -> String = { $0.defaultText }
}

protocol ModPromptPreferenceStoring: AnyObject {
    var isPromptDismissed: Bool { get set }
}

final class UserDefaultsModPromptPreference: ModPromptPreferenceStoring {
    static let key = "modOnboarding.promptDismissed"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isPromptDismissed: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// What the explanation panel shows.
enum ModPanelState: Equatable {
    case intro(dismissChecked: Bool)
    case installing(current: ModInstallStep)
    case succeeded
    case failed(ModInstallFailure)
    case dismissConfirmed
    case uninstalling(current: ModUninstallStep)
    case uninstallSucceeded
    case uninstallFailed(ModUninstallFailure)
}

/// Drives the panel and the settings page. Main-thread only; installation work runs on the installer's queue.
final class ModOnboardingController {
    private(set) var state: ModPanelState = .intro(dismissChecked: false) {
        didSet {
            if state != oldValue { onChange?(); onPresentationChange?() }
        }
    }
    var onChange: (() -> Void)?
    /// Settings presentation observer, independent of the management window observer.
    var onPresentationChange: (() -> Void)?

    let plan: ModInstallPlan
    private let installer: ModInstaller
    private let preference: ModPromptPreferenceStoring
    private let copyToPasteboard: (String) -> Void
    private var installInFlight = false
    private var uninstallInFlight = false
    /// Fired when the install commands finish, so the owner can re-run detection.
    var onInstallCompleted: ((ModInstallResult) -> Void)?
    /// Fired when the uninstall commands finish, so the owner can re-run detection.
    var onUninstallCompleted: ((ModUninstallResult) -> Void)?

    init(
        plan: ModInstallPlan = .standard,
        installer: ModInstaller? = nil,
        preference: ModPromptPreferenceStoring = UserDefaultsModPromptPreference(),
        copyToPasteboard: @escaping (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.plan = plan
        self.installer = installer ?? ModInstaller(plan: plan)
        self.preference = preference
        self.copyToPasteboard = copyToPasteboard
    }

    var isPromptDismissed: Bool { preference.isPromptDismissed }

    /// Prepares the panel for a (re)presentation: finished install/uninstall/failure
    /// pages must not survive into the next management session. Operations that are
    /// still running keep their progress.
    func resetToIntro() {
        guard !installInFlight, !uninstallInFlight else { return }
        state = .intro(dismissChecked: false)
    }

    func setDismissChecked(_ checked: Bool) {
        guard case .intro = state else { return }
        state = .intro(dismissChecked: checked)
    }

    /// The panel's "don't show in the menu" box. Before "Later" the preference is not
    /// written yet, so the intro flag is the visible source of truth.
    var isDismissCheckboxChecked: Bool {
        if case .intro(true) = state { return true }
        return false
    }

    func startInstall() {
        guard !installInFlight, !uninstallInFlight else { return }
        installInFlight = true
        state = .installing(current: .addMarketplace)
        installer.install(
            progress: { [weak self] step in self?.state = .installing(current: step) },
            completion: { [weak self] result in
                guard let self else { return }
                self.installInFlight = false
                switch result {
                case .success: self.state = .succeeded
                case let .failure(failure): self.state = .failed(failure)
                }
                self.onInstallCompleted?(result)
            }
        )
    }

    /// Uninstalls this plugin's user-scope registration and the marketplace entry the
    /// install flow created. Nothing else is touched: no other plugin.
    func startUninstall() {
        guard !uninstallInFlight, !installInFlight else { return }
        uninstallInFlight = true
        state = .uninstalling(current: .uninstallPlugin)
        installer.uninstall(
            progress: { [weak self] step in self?.state = .uninstalling(current: step) },
            completion: { [weak self] result in
                guard let self else { return }
                self.uninstallInFlight = false
                switch result {
                case .success: self.state = .uninstallSucceeded
                case let .failure(failure): self.state = .uninstallFailed(failure)
                }
                self.onUninstallCompleted?(result)
            }
        )
    }

    func copyInstallCommands() { copyToPasteboard(plan.copyableCommands) }
    func copyUninstallCommands() { copyToPasteboard(plan.copyableUninstallCommands) }
    func copyEnableCommand() { copyToPasteboard(plan.copyableEnableCommand) }
    func copyReloadCommand() { copyToPasteboard(ModInstallPlan.reloadCommand) }
    func copyListCommand() { copyToPasteboard(plan.copyableListCommand) }

    /// Closing the panel. With "do not prompt again" checked this enters the confirmation state.
    func close() -> Bool {
        if case .intro(true) = state {
            preference.isPromptDismissed = true
            state = .dismissConfirmed
            return false
        }
        return true
    }

    /// Settings toggle and the confirmation state's undo.
    func setPromptEnabled(_ enabled: Bool) {
        preference.isPromptDismissed = !enabled
        if enabled, state == .dismissConfirmed { state = .intro(dismissChecked: false) }
        onChange?()
    }
}
