import AppKit

final class DashboardMenuPage: NSObject, NSTextFieldDelegate {
    struct Input {
        let preferences: AppPreferences
        let relay: DashboardPreferencePageRelay
        let makeStatusLinksEditor: () -> StatusLinksEditorHostingView
        let onBalanceDisplayThresholdChanged: (Double) -> Void
    }

    private weak var balanceDisplayThresholdField: NSTextField?
    private var statusSubtitleLabel: NSTextField?
    private var statusLinksEditor: StatusLinksEditorHostingView?
    private var balanceDisplayThresholdValue = AppPreferences.defaultBalanceDisplayThreshold
    private var onBalanceDisplayThresholdChanged: ((Double) -> Void)?

    func make(_ input: Input) -> NSView {
        balanceDisplayThresholdValue = input.preferences.balanceDisplayThreshold
        onBalanceDisplayThresholdChanged = input.onBalanceDisplayThresholdChanged

        let balanceDisplayThreshold = NSTextField()
        balanceDisplayThreshold.identifier = NSUserInterfaceItemIdentifier(
            AppPreferences.balanceDisplayThresholdKey
        )
        balanceDisplayThreshold.stringValue = Self.formattedBalanceDisplayThreshold(
            balanceDisplayThresholdValue
        )
        balanceDisplayThreshold.placeholderString = Self.formattedBalanceDisplayThreshold(
            AppPreferences.defaultBalanceDisplayThreshold
        )
        balanceDisplayThreshold.alignment = .right
        balanceDisplayThreshold.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        balanceDisplayThreshold.isEditable = true
        balanceDisplayThreshold.isSelectable = true
        balanceDisplayThreshold.usesSingleLineMode = true
        balanceDisplayThreshold.delegate = self
        balanceDisplayThreshold.toolTip = tr(
            "请输入大于等于 0.01 的金额，最多保留两位小数",
            "Enter an amount of at least 0.01 with up to two decimal places",
            "請輸入大於等於 0.01 的金額，最多保留兩位小數",
            "0.01 以上の金額を小数点以下 2 桁まで入力してください"
        )
        balanceDisplayThreshold.widthAnchor.constraint(equalToConstant: 92).isActive = true
        balanceDisplayThreshold.setContentHuggingPriority(.required, for: .horizontal)
        balanceDisplayThreshold.setContentCompressionResistancePriority(.required, for: .horizontal)
        balanceDisplayThresholdField = balanceDisplayThreshold

        let balanceDisplay = DashboardSettingsComponents.makeSettingsSection(
            tr("余额显示", "Balance Display", "餘額顯示", "残高表示"),
            rows: [
                DashboardSettingsComponents.makeSettingsRow(
                    tr("低余额显示阈值", "Low Balance Display Threshold", "低餘額顯示閾值", "低残高表示のしきい値"),
                    subtitle: tr(
                        "充值后余额仍未达到此金额时，进度条保持红色状态",
                        "After a recharge, keep the progress bar red while the balance remains below this amount",
                        "充值後餘額仍未達到此金額時，進度條保持紅色狀態",
                        "チャージ後の残高がこの金額に達しない場合、進捗バーを赤色で表示"
                    ),
                    control: balanceDisplayThreshold
                )
            ]
        )

        let quickSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "showQuickSwitchMenu",
            isOn: input.preferences.showQuickSwitchMenu,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let openCC = DashboardSettingsComponents.makeSwitch(
            identifier: "showOpenCCSwitchMenu",
            isOn: input.preferences.showOpenCCSwitchMenu,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let openCodex = DashboardSettingsComponents.makeSwitch(
            identifier: AppPreferences.showOpenCodexMenuKey,
            isOn: input.preferences.showOpenCodexMenu,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let keepOpen = DashboardSettingsComponents.makeSwitch(
            identifier: "keepMenuOpenAfterRefresh",
            isOn: input.preferences.keepMenuOpenAfterRefresh,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )

        let items = DashboardSettingsComponents.makeSettingsSection(tr("展开菜单", "Dropdown Menu", "展開選單", "ドロップダウンメニュー"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("快速切换", "Quick Switch", "快速切換", "クイック切り替え"),
                subtitle: tr("显示 CC Switch 供应商子菜单", "Show the CC Switch Provider submenu", "顯示 CC Switch 供應商子選單", "CC Switch プロバイダーのサブメニューを表示"),
                control: quickSwitch
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("刷新后保持展开", "Keep Open After Refresh", "重新整理後保持展開", "更新後も開いたままにする"),
                subtitle: tr("点击立即刷新后重新打开菜单", "Reopen the menu after Refresh Now", "按一下立即重新整理後重新開啟選單", "「今すぐ更新」後にメニューを再度開く"),
                control: keepOpen
            )
        ])

        let openMainWindow = DashboardSettingsComponents.makeSwitch(
            identifier: "showOpenDashboardMenu",
            isOn: true,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        openMainWindow.isEnabled = false
        openMainWindow.toolTip = tr(
            "打开主窗口入口始终显示",
            "The Open Main Window item is always shown",
            "開啟主視窗入口始終顯示",
            "「メインウインドウを開く」項目は常に表示されます"
        )

        var projectRows: [NSView] = [
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开主窗口", "Open Main Window", "開啟主視窗", "メインウインドウを開く"),
                subtitle: tr(
                    "显示 BalanceBar 主窗口",
                    "Show the BalanceBar main window",
                    "顯示 BalanceBar 主視窗",
                    "BalanceBar のメインウインドウを表示"
                ),
                control: openMainWindow
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开 ChatGPT", "Open ChatGPT", "開啟 ChatGPT", "ChatGPT を開く"),
                subtitle: tr("显示 ChatGPT", "Show ChatGPT", "顯示 ChatGPT", "ChatGPT を表示"),
                control: DashboardSettingsComponents.makeSwitch(
                    identifier: "showOpenChatGPTMenu",
                    isOn: input.preferences.showOpenChatGPTMenu,
                    target: input.relay,
                    action: #selector(DashboardPreferencePageRelay.toggle(_:))
                )
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开 CC Switch", "Open CC Switch", "開啟 CC Switch", "CC Switch を開く"),
                subtitle: tr(
                    "显示 CC Switch 主窗口",
                    "Show the CC Switch main window",
                    "顯示 CC Switch 主視窗",
                    "CC Switch のメインウインドウを表示"
                ),
                control: openCC
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开 OpenCodex", "Open OpenCodex", "開啟 OpenCodex", "OpenCodex を開く"),
                subtitle: tr("显示 OpenCodex 仪表盘", "Show the OpenCodex dashboard", "顯示 OpenCodex 儀表板", "OpenCodex ダッシュボードを表示"),
                control: openCodex
            )
        ]
        let statusSubtitle = NSTextField(wrappingLabelWithString: "")
        statusSubtitleLabel = statusSubtitle
        let statusVisible = input.preferences.showStatusMenu
        updateStatusVisibility(statusVisible, animated: false)
        projectRows.append(DashboardSettingsComponents.makeSettingsRow(
            tr("查看状态", "View Status", "檢視狀態", "ステータスを表示"),
            subtitle: statusVisible
                ? tr("显示可自定义的服务状态链接", "Show customizable service status links", "顯示可自訂的服務狀態連結", "カスタマイズ可能なサービスステータスリンクを表示")
                : tr("在菜单栏中显示状态链接", "Show status links in the menu bar", "在選單列中顯示狀態連結", "メニューバーにステータスリンクを表示"),
            subtitleLabel: statusSubtitle,
            control: DashboardSettingsComponents.makeSwitch(
                identifier: "showStatusMenu",
                isOn: statusVisible,
                target: input.relay,
                action: #selector(DashboardPreferencePageRelay.toggle(_:))
            )
        ))

        // Keep one editor instance in the page for both states so toggling
        // animates its height in place instead of rebuilding the whole page.
        let editor = input.makeStatusLinksEditor()
        statusLinksEditor = editor
        editor.setVisible(statusVisible, animated: false)
        projectRows.append(editor)
        let projects = DashboardSettingsComponents.makeSettingsSection(
            tr("打开项目", "Open Project", "開啟專案", "プロジェクトを開く"),
            rows: projectRows,
            separatorIndices: [0, 1, 2, 3],
            rowHeight: { row in
                (row as? StatusLinksEditorHostingView)?.currentHeight
            }
        )
        DispatchQueue.main.async { [weak editor] in
            editor?.logGeometry(label: "initial")
        }
        return DashboardSettingsComponents.makeSettingsPage([balanceDisplay, items, projects])
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === balanceDisplayThresholdField else { return }

        guard let normalized = Self.parseBalanceDisplayThreshold(field.stringValue) else {
            field.stringValue = Self.formattedBalanceDisplayThreshold(balanceDisplayThresholdValue)
            return
        }

        field.stringValue = Self.formattedBalanceDisplayThreshold(normalized)
        guard abs(normalized - balanceDisplayThresholdValue) > 0.000001 else { return }
        balanceDisplayThresholdValue = normalized
        onBalanceDisplayThresholdChanged?(normalized)
    }

    func updateStatusVisibility(_ visible: Bool, animated: Bool) {
        statusSubtitleLabel?.stringValue = visible
            ? tr("显示可自定义的服务状态链接", "Show customizable service status links", "顯示可自訂的服務狀態連結", "カスタマイズ可能なサービスステータスリンクを表示")
            : tr("在菜单栏中显示状态链接", "Show status links in the menu bar", "在選單列中顯示狀態連結", "メニューバーにステータスリンクを表示")
        statusLinksEditor?.setVisible(visible, animated: animated)
    }

    func teardown() {
        balanceDisplayThresholdField?.delegate = nil
        balanceDisplayThresholdField = nil
        onBalanceDisplayThresholdChanged = nil
        statusLinksEditor?.teardown()
        statusLinksEditor = nil
        statusSubtitleLabel = nil
    }

    private static func parseBalanceDisplayThreshold(_ text: String) -> Double? {
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalizedText), value.isFinite,
              value >= AppPreferences.minimumBalanceDisplayThreshold,
              value <= Double(Int.max) / 100 else { return nil }
        let normalized = AppPreferences.normalizedBalanceDisplayThreshold(value)
        return normalized >= AppPreferences.minimumBalanceDisplayThreshold ? normalized : nil
    }

    private static func formattedBalanceDisplayThreshold(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
