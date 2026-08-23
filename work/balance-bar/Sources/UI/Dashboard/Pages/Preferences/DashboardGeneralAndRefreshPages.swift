import AppKit

extension UpdateChannel {
    func localizedTitle(using language: AppLanguage = .selected) -> String {
        switch self {
        case .stable:
            return tr("正式版", "Stable", "正式版", "正式版", language: language)
        case .beta:
            return tr("Beta 测试版", "Beta Test", "Beta 測試版", "ベータテスト", language: language)
        }
    }
}

struct DashboardUpdatePresentation: Equatable {
    let subtitle: String
    let buttonTitle: String
    let buttonEnabled: Bool
    let performsInstall: Bool

    static func make(for state: UpdateCheckState, language: AppLanguage = .selected) -> DashboardUpdatePresentation {
        switch state {
        case .idle:
            return DashboardUpdatePresentation(
                subtitle: tr(
                    "点击检查 GitHub Releases",
                    "Click to check GitHub Releases",
                    "點擊檢查 GitHub Releases",
                    "クリックして GitHub Releases を確認",
                    language: language
                ),
                buttonTitle: tr("检查更新", "Check for Updates", "檢查更新", "アップデートを確認", language: language),
                buttonEnabled: true,
                performsInstall: false
            )
        case .checking:
            return DashboardUpdatePresentation(
                subtitle: tr("正在检查更新…", "Checking for updates…", "正在檢查更新…", "アップデートを確認中…", language: language),
                buttonTitle: tr("检查中…", "Checking…", "檢查中…", "確認中…", language: language),
                buttonEnabled: false,
                performsInstall: false
            )
        case .latest:
            return DashboardUpdatePresentation(
                subtitle: tr("当前为最新版本", "You are up to date", "目前為最新版本", "最新バージョンです", language: language),
                buttonTitle: tr("检查更新", "Check for Updates", "檢查更新", "アップデートを確認", language: language),
                buttonEnabled: true,
                performsInstall: false
            )
        case .available(let current, let latest):
            return DashboardUpdatePresentation(
                subtitle: tr(
                    "新版本可用：\(current) -> \(latest)",
                    "New version available: \(current) -> \(latest)",
                    "新版本可用：\(current) -> \(latest)",
                    "新しいバージョンがあります：\(current) -> \(latest)",
                    language: language
                ),
                buttonTitle: tr("下载并安装", "Download and Install", "下載並安裝", "ダウンロードしてインストール", language: language),
                buttonEnabled: true,
                performsInstall: true
            )
        case .downloading(_, _, let progress):
            return DashboardUpdatePresentation(
                subtitle: tr("正在下载新版本…", "Downloading the new version…", "正在下載新版本…", "新しいバージョンをダウンロード中…", language: language),
                buttonTitle: tr("下载中 \(progress)% …", "Downloading \(progress)% …", "下載中 \(progress)% …", "ダウンロード中 \(progress)% …", language: language),
                buttonEnabled: false,
                performsInstall: false
            )
        case .installing(_, _, let progress):
            return DashboardUpdatePresentation(
                subtitle: tr("正在安装新版本…", "Installing the new version…", "正在安裝新版本…", "新しいバージョンをインストール中…", language: language),
                buttonTitle: tr("安装中 \(progress)% …", "Installing \(progress)% …", "安裝中 \(progress)% …", "インストール中 \(progress)% …", language: language),
                buttonEnabled: false,
                performsInstall: false
            )
        case .restarting:
            return DashboardUpdatePresentation(
                subtitle: tr("安装完成，正在重新启动…", "Installed; restarting…", "安裝完成，正在重新啟動…", "インストール完了。再起動中…", language: language),
                buttonTitle: tr("重新启动中…", "Restarting…", "重新啟動中…", "再起動中…", language: language),
                buttonEnabled: false,
                performsInstall: false
            )
        case .failed(let failure):
            let subtitle: String
            switch failure {
            case .assetUnavailable:
                subtitle = tr("没有可验证的安装包，请重试", "No verifiable installer is available; try again", "沒有可驗證的安裝包，請重試", "検証可能なインストーラーがありません。再試行してください", language: language)
            case .verificationFailed:
                subtitle = tr("下载校验失败，当前版本未更改", "Download verification failed; the current version was not changed", "下載驗證失敗，目前版本未變更", "ダウンロードの検証に失敗しました。現在のバージョンは変更されていません", language: language)
            case .installationFailed:
                subtitle = tr("安装失败，当前版本未更改，请重试", "Installation failed; the current version was not changed", "安裝失敗，目前版本未變更，請重試", "インストールに失敗しました。現在のバージョンは変更されていません", language: language)
            case .invalidCurrentVersion:
                subtitle = tr("无法读取当前版本，请重试", "The current version could not be read; try again", "無法讀取目前版本，請重試", "現在のバージョンを読み取れません。再試行してください", language: language)
            default:
                subtitle = tr("检查更新失败，请重试", "Update check failed; try again", "檢查更新失敗，請重試", "アップデートの確認に失敗しました。再試行してください", language: language)
            }
            return DashboardUpdatePresentation(
                subtitle: subtitle,
                buttonTitle: tr("重试", "Retry", "重試", "再試行", language: language),
                buttonEnabled: true,
                performsInstall: false
            )
        }
    }
}

final class DashboardGeneralPage {
    struct Input {
        let preferences: AppPreferences
        let currentProviderName: String
        let relay: DashboardPreferencePageRelay
        let updateState: UpdateCheckState
    }

    private var updateSubtitleLabel: NSTextField?
    private var updateButton: NSButton?

    func make(_ input: Input) -> NSView {
        let openButton = NSButton(
            title: tr("打开 CC Switch", "Open CC Switch", "開啟 CC Switch", "CC Switch を開く"),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openCCSwitch(_:))
        )
        let currentProviderText = tr(
            "当前供应商：\(input.currentProviderName)",
            "Current Provider: \(input.currentProviderName)",
            "目前供應商：\(input.currentProviderName)",
            "現在のプロバイダー：\(input.currentProviderName)"
        )
        let system = DashboardSettingsComponents.makeSettingsSection(tr("系统", "System", "系統", "システム"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                "CC Switch",
                subtitle: currentProviderText,
                control: openButton
            )
        ])

        let activeRefreshPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [
                (1, tr("每 1 秒", "Every 1 sec", "每 1 秒", "1秒ごと")),
                (2, tr("每 2 秒", "Every 2 sec", "每 2 秒", "2秒ごと")),
                (3, tr("每 3 秒", "Every 3 sec", "每 3 秒", "3秒ごと")),
                (5, tr("每 5 秒", "Every 5 sec", "每 5 秒", "5秒ごと")),
                (10, tr("每 10 秒", "Every 10 sec", "每 10 秒", "10秒ごと"))
            ],
            selected: input.preferences.codexUsageRefreshInterval,
            identifier: "codexUsageRefreshInterval",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let trailingRefreshPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [
                (0, tr("不继续", "Off", "不繼續", "オフ")),
                (6, tr("持续 6 秒", "For 6 sec", "持續 6 秒", "6秒間")),
                (12, tr("持续 12 秒", "For 12 sec", "持續 12 秒", "12秒間")),
                (30, tr("持续 30 秒", "For 30 sec", "持續 30 秒", "30秒間"))
            ],
            selected: input.preferences.postCodexRefreshDuration,
            identifier: "postCodexRefreshDuration",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let runningLabel = NSTextField(labelWithString: tr("运行中", "Running", "執行中", "実行中"))
        let trailingLabel = NSTextField(labelWithString: tr("结束后", "After", "結束後", "終了後"))
        [runningLabel, trailingLabel].forEach {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .right
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        [activeRefreshPopup, trailingRefreshPopup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 108).isActive = true
        }
        let runningControls = NSStackView(views: [runningLabel, activeRefreshPopup])
        runningControls.orientation = .horizontal
        runningControls.alignment = .centerY
        runningControls.spacing = 7
        let trailingControls = NSStackView(views: [trailingLabel, trailingRefreshPopup])
        trailingControls.orientation = .horizontal
        trailingControls.alignment = .centerY
        trailingControls.spacing = 7
        let activeRefreshControls = NSStackView(views: [runningControls, trailingControls])
        activeRefreshControls.orientation = .vertical
        activeRefreshControls.alignment = .trailing
        activeRefreshControls.spacing = 5
        let refreshButton = NSButton(
            title: tr("立即刷新", "Refresh Now", "立即重新整理", "今すぐ更新"),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.manualRefresh(_:))
        )
        let refreshing = DashboardSettingsComponents.makeSettingsSection(tr("刷新", "Refresh", "重新整理", "更新"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("任务期间余量更新频率", "Balance Updates During Tasks", "任務期間餘量更新頻率", "タスク中の残高更新頻度"),
                subtitle: tr(
                    "Agent 运行时请求当前供应商的余量",
                    "Requests the current Provider's balance while an Agent is running",
                    "Agent 執行時請求目前供應商的餘量",
                    "エージェント実行中に現在のプロバイダーの残高を要求します"
                ),
                control: activeRefreshControls,
                minimumHeight: 76
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("余额数据", "Balance Data", "餘額資料", "残高データ"),
                subtitle: tr("立即重新读取当前供应商", "Reload the current Provider now", "立即重新讀取目前供應商", "現在のプロバイダーをすぐに再読み込み"),
                control: refreshButton
            )
        ])

        let languagePopup = DashboardSettingsComponents.makePopUpButton(
            items: AppLanguage.allCases.map {
                DashboardSettingsComponents.PopUpItem(
                    title: $0.localizedTitle,
                    representedObject: $0.rawValue
                )
            },
            selectedIndex: AppLanguage.allCases.firstIndex(of: AppLanguage.selected),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.language(_:))
        )
        let updatePresentation = DashboardUpdatePresentation.make(for: input.updateState)
        let updateSubtitle = NSTextField(wrappingLabelWithString: updatePresentation.subtitle)
        updateSubtitle.identifier = NSUserInterfaceItemIdentifier("checkForUpdatesSubtitle")
        let updateButton = NSButton(
            title: updatePresentation.buttonTitle,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.update(_:))
        )
        updateButton.identifier = NSUserInterfaceItemIdentifier("checkForUpdatesButton")
        updateButton.bezelStyle = .rounded
        apply(updatePresentation, to: updateButton, subtitle: updateSubtitle)
        let updateChannelPopup = DashboardSettingsComponents.makePopUpButton(
            identifier: AppPreferences.updateChannelKey,
            items: UpdateChannel.allCases.map {
                DashboardSettingsComponents.PopUpItem(
                    title: $0.localizedTitle(),
                    representedObject: $0.rawValue
                )
            },
            selectedIndex: UpdateChannel.allCases.firstIndex(of: input.preferences.updateChannel),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.updateChannel(_:))
        )
        updateChannelPopup.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let updateControls = NSStackView(views: [updateChannelPopup, updateButton])
        updateControls.orientation = .horizontal
        updateControls.alignment = .centerY
        updateControls.spacing = 8
        self.updateSubtitleLabel = updateSubtitle
        self.updateButton = updateButton

        let app = DashboardSettingsComponents.makeSettingsSection(tr("应用", "Application", "應用程式", "アプリ"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("语言", "Language", "語言", "言語"),
                subtitle: tr("更改后立即应用到整个界面", "Changes apply to the entire interface immediately", "更改後立即套用到整個介面", "変更後すぐにすべての画面に適用されます"),
                control: languagePopup
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("检查更新", "Check for Updates", "檢查更新", "アップデートを確認"),
                subtitle: updatePresentation.subtitle,
                subtitleLabel: updateSubtitle,
                control: updateControls
            )
        ])
        return DashboardSettingsComponents.makeSettingsPage([system, refreshing, app])
    }

    func refresh(updateState: UpdateCheckState) {
        let presentation = DashboardUpdatePresentation.make(for: updateState)
        guard let updateSubtitleLabel, let updateButton else { return }
        apply(presentation, to: updateButton, subtitle: updateSubtitleLabel)
    }

    private func apply(
        _ presentation: DashboardUpdatePresentation,
        to button: NSButton,
        subtitle: NSTextField
    ) {
        button.title = presentation.buttonTitle
        button.isEnabled = presentation.buttonEnabled
        button.tag = presentation.performsInstall ? 1 : 0
        subtitle.stringValue = presentation.subtitle
    }
}

enum DashboardRefreshPage {
    struct Input {
        let preferences: AppPreferences
        let providerPollInterval: TimeInterval
        let relay: DashboardPreferencePageRelay
    }

    static func make(_ input: Input) -> NSView {
        let root = NSView()
        let header = DashboardSettingsComponents.makePageHeader(
            tr("刷新设置", "Refresh Settings", "重新整理設定", "更新設定"),
            subtitle: tr(
                "文件监听始终开启，轮询用于防止遗漏系统事件",
                "File monitoring is always active; polling prevents missed system events",
                "檔案監聽始終開啟，輪詢用於防止遺漏系統事件",
                "ファイル監視は常に有効です。ポーリングはシステムイベントの取りこぼしを防ぐためのものです"
            )
        )
        let pollingTitle = NSTextField(labelWithString: tr("CC Switch 轮询兜底", "CC Switch Fallback Polling", "CC Switch 輪詢兜底", "CC Switch フォールバックポーリング"))
        pollingTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let pollingPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [
                (1, tr("每 1 秒", "Every 1 sec", "每 1 秒", "1秒ごと")),
                (3, tr("每 3 秒", "Every 3 sec", "每 3 秒", "3秒ごと")),
                (5, tr("每 5 秒", "Every 5 sec", "每 5 秒", "5秒ごと")),
                (10, tr("每 10 秒", "Every 10 sec", "每 10 秒", "10秒ごと"))
            ],
            selected: input.providerPollInterval,
            identifier: "providerPollInterval",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let pollingRow = NSStackView(views: [pollingTitle, NSView(), pollingPopup])
        pollingRow.orientation = .horizontal
        pollingRow.alignment = .centerY

        let activityTitle = NSTextField(labelWithString: tr("Codex 任务状态检测", "Codex Task Status Detection", "Codex 任務狀態偵測", "Codex タスクステータス検出"))
        activityTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let activityPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [(0.25, tr("0.25 秒", "0.25 sec", "0.25 秒", "0.25秒")), (0.5, tr("0.5 秒", "0.5 sec", "0.5 秒", "0.5秒")), (1, tr("1 秒", "1 sec", "1 秒", "1秒"))],
            selected: input.preferences.activityPollInterval,
            identifier: "activityPollInterval",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let activityRow = NSStackView(views: [activityTitle, NSView(), activityPopup])
        activityRow.orientation = .horizontal
        activityRow.alignment = .centerY

        let animationToggle = DashboardSettingsComponents.makeSwitch(
            identifier: "animateCodexActivity",
            isOn: input.preferences.animateCodexActivity,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let animationTitle = NSTextField(labelWithString: tr(
            "Codex 有任务运行时旋转菜单栏图标",
            "Rotate the menu bar icon while a Codex task is running",
            "Codex 有任務執行時旋轉選單列圖示",
            "Codex タスク実行中にメニューバーアイコンを回転"
        ))
        let animationRow = NSStackView(views: [animationTitle, NSView(), animationToggle])
        animationRow.orientation = .horizontal
        animationRow.alignment = .centerY
        let note = NSTextField(wrappingLabelWithString: tr(
            "供应商变化仍由 CC Switch 数据库事件即时触发；这里的秒数只是没有收到事件时的后备检查频率。",
            "Provider changes are still triggered immediately by CC Switch database events; this interval is only the fallback check frequency.",
            "供應商變化仍由 CC Switch 資料庫事件即時觸發；這裡的秒數只是沒有收到事件時的備援檢查頻率。",
            "プロバイダーの変更は引き続き CC Switch データベースイベントによって即時トリガーされます。ここでの秒数は、イベントを受信しなかった場合のバックアップチェック頻度にすぎません。"
        ))
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header, pollingRow, activityRow, animationRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(30, after: header)
        stack.setCustomSpacing(24, after: activityRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            pollingRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }
}
