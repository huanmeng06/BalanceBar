import AppKit

/// User-visible copy. Defaults are Simplified Chinese; the integration layer can inject `localize`.
enum ModOnboardingText: String, CaseIterable {
    case promptRow = "mod.prompt.row"
    case promptWhy = "mod.prompt.why"
    case panelTitle = "mod.panel.title"
    case panelSubtitle = "mod.panel.subtitle"
    case point1Title = "mod.panel.point1.title"
    case point1Detail = "mod.panel.point1.detail"
    case point2Title = "mod.panel.point2.title"
    case point2Detail = "mod.panel.point2.detail"
    case point3Title = "mod.panel.point3.title"
    case point3Detail = "mod.panel.point3.detail"
    case point4Title = "mod.panel.point4.title"
    case point4Detail = "mod.panel.point4.detail"
    case installButton = "mod.panel.install"
    case dismissCheckbox = "mod.panel.dismiss_checkbox"
    case laterButton = "mod.panel.later"
    case closeButton = "mod.panel.close"
    case step1 = "mod.install.step1"
    case step2 = "mod.install.step2"
    case step3 = "mod.install.step3"
    case enabled = "mod.install.enabled"
    case enabledNote = "mod.install.enabled_note"
    case reloadHint = "mod.install.reload_hint"
    case silentTitle = "mod.silent.title"
    case silentIntro = "mod.silent.intro"
    case silentItem1 = "mod.silent.item1"
    case silentItem2 = "mod.silent.item2"
    case silentItem3 = "mod.silent.item3"
    case failureTitle = "mod.failure.title"
    case failureClaudeMissing = "mod.failure.claude_missing"
    case failureCommandFailed = "mod.failure.command_failed"
    case copyCommands = "mod.failure.copy"
    case copied = "mod.failure.copied"
    case dismissedTitle = "mod.dismissed.title"
    case dismissedNote = "mod.dismissed.note"
    case dismissedOpenSettings = "mod.dismissed.open_settings"
    case dismissedOk = "mod.dismissed.ok"
    case manageTitle = "mod.manage.title"
    case manageRemoveNote = "mod.manage.remove_note"
    case uninstallButton = "mod.manage.uninstall"
    case uninstalling = "mod.manage.uninstalling"
    case uninstalledTitle = "mod.manage.uninstalled_title"
    case uninstalledNote = "mod.manage.uninstalled_note"
    case uninstallFailureTitle = "mod.manage.failure_title"
    case uninstallFailureNote = "mod.manage.failure_note"

    var defaultText: String {
        switch self {
        case .promptRow: return "为 Claude 安装 Mod，额度实时更新"
        case .promptWhy: return "为什么这么做？"
        case .panelTitle: return "让 Claude 额度实时更新"
        case .panelSubtitle: return "BalanceBar Mod 是运行在 Claude Code 里的小插件，每轮回复后把官方额度告诉 BalanceBar。"
        case .point1Title: return "实时、官方数据"
        case .point1Detail: return "每轮回复后立即更新，不是估算"
        case .point2Title: return "覆盖 Agent 场景"
        case .point2Detail: return "claude -p、Agent SDK、多会话并行同样有效"
        case .point3Title: return "不再占用查询额度"
        case .point3Detail: return "不请求 Usage API，告别 429"
        case .point4Title: return "只读，可随时移除"
        case .point4Detail: return "不读对话内容；在 /plugin 中即可卸载"
        case .installButton: return "一键安装"
        case .dismissCheckbox: return "不再在菜单中提示"
        case .laterButton: return "稍后"
        case .closeButton: return "关闭"
        case .step1: return "添加插件源"
        case .step2: return "安装 Mod"
        case .step3: return "等待首次数据"
        case .enabled: return "已开启 ✓"
        case .enabledNote: return "新开的 Claude Code 会话会自动启用，正在运行的会话可以不管。"
        case .reloadHint: return "想让当前会话也马上生效，可在其中输入："
        case .silentTitle: return "已安装，但还没收到数据"
        case .silentIntro: return "Claude Code 在运行，但 10 分钟内没有收到 Mod 的数据。请检查："
        case .silentItem1: return "Claude Code 版本是否为 v2.1.287 或更高"
        case .silentItem2: return "是否是新会话，或已在会话中运行 /reload-plugins"
        case .silentItem3: return "组织策略是否只允许托管插件"
        case .failureTitle: return "无法自动安装"
        case .failureClaudeMissing: return "没有找到 claude 命令。请在终端中运行下面的命令："
        case .failureCommandFailed: return "命令未成功完成。请在终端中运行下面的命令："
        case .copyCommands: return "复制命令"
        case .copied: return "已复制"
        case .dismissedTitle: return "已隐藏提示"
        case .dismissedNote: return "之后可以在 设置 › 高级 › Claude 实时增强 中安装 Mod，或重新显示提示。"
        case .dismissedOpenSettings: return "打开高级设置"
        case .dismissedOk: return "好"
        case .manageTitle: return "BalanceBar Mod 已安装"
        case .manageRemoveNote: return "不想用了？卸载后，新会话不再向 BalanceBar 写入数据，额度回到定时查询。"
        case .uninstallButton: return "卸载"
        case .uninstalling: return "正在卸载…"
        case .uninstalledTitle: return "已卸载"
        case .uninstalledNote: return "已在运行的会话会继续加载它，直到重开会话，或在其中输入："
        case .uninstallFailureTitle: return "无法自动卸载"
        case .uninstallFailureNote: return "请在终端中运行下面的命令："
        }
    }

    static let defaultLocalize: (ModOnboardingText) -> String = { $0.defaultText }

    /// Routes copy through the app's localization tables (see `LocalizationKey`).
    static let appLocalize: (ModOnboardingText) -> String = { text in
        LocalizationKey(rawValue: text.rawValue).map { tr($0) } ?? text.defaultText
    }
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

/// What the explanation window shows.
enum ModPanelState: Equatable {
    case intro(dismissChecked: Bool)
    /// The install commands are running (`current` is the step in progress).
    case installing(current: ModInstallStep)
    /// The commands succeeded; the install completes with the Mod's first snapshot.
    case awaitingFirstData
    /// The first snapshot arrived.
    case enabled
    /// Installed and Claude Code is active, but no snapshot arrived for `noDataWithActivityGrace`.
    case silent
    case failed(ModInstallFailure)
    case dismissConfirmed
    /// The Mod is installed: its status and how to remove it (`statusText` is the settings status line).
    case installed(statusText: String)
    case uninstalling
    case uninstalled
    case uninstallFailed(ModInstallFailure)
}

/// Drives the window and the settings block. Main-thread only; installation work runs on the installer's queue.
final class ModOnboardingController {
    private(set) var state: ModPanelState = .intro(dismissChecked: false) {
        didSet { if state != oldValue { onChange?(); onStateChange?() } }
    }
    /// Observer slot used by the explanation window.
    var onChange: (() -> Void)?
    /// Second observer slot, used by the Settings block so it can follow the install progress.
    var onStateChange: (() -> Void)?
    /// Called on the main thread when an install attempt ended, before the panel state changes.
    var onInstallFinished: ((ModInstallResult) -> Void)?
    /// Called on the main thread when an uninstall attempt ended, before the panel state changes.
    var onUninstallFinished: ((ModInstallResult) -> Void)?
    /// Asks the app to open Settings › Advanced.
    var onOpenSettings: (() -> Void)?
    /// Asks the coordinator whether the Mod is installed but silent (checked while the window waits for data).
    var silenceCheck: (() -> Bool)?

    let plan: ModInstallPlan
    private let installer: ModInstaller
    private let preference: ModPromptPreferenceStoring
    private let copyToPasteboard: (String) -> Void
    private var installInFlight = false
    private var uninstallInFlight = false

    init(
        plan: ModInstallPlan = .resolved(),
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

    /// An install is running or the first snapshot is awaited: reopening the window shows that progress.
    var isInstallInProgress: Bool {
        switch state {
        case .installing, .awaitingFirstData: return true
        default: return false
        }
    }

    /// A fresh intro, except while an install is in progress (`force` discards even that, for example when the
    /// plugin turned out not to be installed).
    func resetToIntro(force: Bool = false) {
        guard !installInFlight, !uninstallInFlight else { return }
        if !force, state == .awaitingFirstData || state == .silent { return }
        state = .intro(dismissChecked: false)
    }

    /// The window for an installed Mod: status and removal instead of the install pitch. Progress screens stay as they are.
    func showInstalled(statusText: String) {
        guard !installInFlight, !uninstallInFlight else { return }
        switch state {
        case .awaitingFirstData, .silent, .installing, .uninstalling: return
        default: state = .installed(statusText: statusText)
        }
    }

    /// Keeps the status line of an open management window current.
    func updateInstalledStatus(_ statusText: String) {
        if case .installed = state { state = .installed(statusText: statusText) }
    }

    func startUninstall() {
        switch state {
        case .installed, .awaitingFirstData, .silent: break
        default: return
        }
        guard !uninstallInFlight else { return }
        uninstallInFlight = true
        state = .uninstalling
        installer.uninstall { [weak self] result in
            guard let self else { return }
            self.uninstallInFlight = false
            self.onUninstallFinished?(result)
            switch result {
            case .success: self.state = .uninstalled
            case let .failure(failure): self.state = .uninstallFailed(failure)
            }
        }
    }

    func copyUninstallCommand() { copyToPasteboard(plan.uninstallCommand) }

    func setDismissChecked(_ checked: Bool) {
        guard case .intro = state else { return }
        state = .intro(dismissChecked: checked)
    }

    func startInstall() {
        guard !installInFlight else { return }
        installInFlight = true
        state = .installing(current: .addMarketplace)
        installer.install(
            progress: { [weak self] step in self?.state = .installing(current: step) },
            completion: { [weak self] result in
                guard let self else { return }
                self.installInFlight = false
                self.onInstallFinished?(result)
                switch result {
                // The commands are done; the install completes with the Mod's first snapshot.
                case .success: self.state = .awaitingFirstData
                case let .failure(failure): self.state = .failed(failure)
                }
            }
        )
    }

    /// The first Mod snapshot arrived: the "wait for first data" step is done.
    func markFirstDataReceived() {
        switch state {
        case .awaitingFirstData, .silent: state = .enabled
        default: break
        }
    }

    /// Called periodically while the window waits: ten minutes without data while Claude Code works.
    func checkSilence() {
        guard state == .awaitingFirstData, silenceCheck?() == true else { return }
        state = .silent
    }

    /// Copying the commands counts as leaving the intro: with "do not prompt again" ticked it confirms the dismissal.
    func copyInstallCommands() {
        copyToPasteboard(plan.copyableCommands)
        confirmDismissalIfChecked()
    }

    func copyReloadCommand() { copyToPasteboard(ModInstallPlan.reloadCommand) }

    func openSettings() { onOpenSettings?() }

    /// Test seam: shows any state without running an install.
    func setStateForTesting(_ state: ModPanelState) { self.state = state }

    /// "Later" / close. With "do not prompt again" ticked this enters the confirmation state instead of closing.
    /// Returns whether the window should close now.
    func close() -> Bool {
        !confirmDismissalIfChecked()
    }

    @discardableResult
    private func confirmDismissalIfChecked() -> Bool {
        guard case .intro(true) = state else { return false }
        preference.isPromptDismissed = true
        state = .dismissConfirmed
        return true
    }

    /// The Settings toggle.
    func setPromptEnabled(_ enabled: Bool) {
        preference.isPromptDismissed = !enabled
        if enabled, state == .dismissConfirmed { state = .intro(dismissChecked: false) }
        onChange?()
    }
}
