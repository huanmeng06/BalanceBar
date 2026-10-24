import AppKit

/// User-visible copy. Defaults are Simplified Chinese; the integration layer can inject `localize`.
enum ModOnboardingText: String, CaseIterable {
    case promptRow = "mod.prompt.row"
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

    var defaultText: String {
        switch self {
        case .promptRow: return "启用实时增强 ›"
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
        case .reloadHint: return "已有会话可选运行 /reload-plugins。"
        case .failureTitle: return "无法自动安装"
        case .failureClaudeMissing: return "没有找到 claude 命令。请在终端中运行下面的命令："
        case .failureCommandFailed: return "命令未成功完成。请在终端中运行下面的命令："
        case .copyCommands: return "复制命令"
        case .copied: return "已复制"
        case .dismissedTitle: return "已关闭提示"
        case .dismissedNote: return "菜单底部改为显示“数据来源”。可在 设置 › 高级 › 实时增强 中重新开启。"
        case .undoDismiss: return "撤销"
        case .uninstallButton: return "卸载实时同步"
        case .uninstallStep1: return "卸载 Mod"
        case .uninstallStep2: return "移除安装来源"
        case .uninstallDone: return "已卸载 ✓"
        case .uninstallDoneNote: return "额度显示回退到官方路径；statusLine 与其他插件配置保持不变。"
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
        didSet { if state != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

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

    func resetToIntro() {
        guard !installInFlight else { return }
        state = .intro(dismissChecked: false)
    }

    func setDismissChecked(_ checked: Bool) {
        guard case .intro = state else { return }
        state = .intro(dismissChecked: checked)
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
    /// install flow created. Nothing else is touched: no other plugin, no statusLine.
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
