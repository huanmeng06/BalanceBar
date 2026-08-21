import AppKit

final class DashboardMenuPage {
    struct Input {
        let preferences: AppPreferences
        let relay: DashboardPreferencePageRelay
        let makeStatusLinksEditor: () -> StatusLinksEditorHostingView
    }

    private var statusSubtitleLabel: NSTextField?
    private var statusLinksEditor: StatusLinksEditorHostingView?

    func make(_ input: Input) -> NSView {
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
                control: openMainWindow
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开 ChatGPT", "Open ChatGPT", "開啟 ChatGPT", "ChatGPT を開く"),
                subtitle: tr("显示 ChatGPT 启动项", "Show the ChatGPT launch item", "顯示 ChatGPT 啟動項目", "ChatGPT 起動項目を表示"),
                control: DashboardSettingsComponents.makeSwitch(
                    identifier: "showOpenChatGPTMenu",
                    isOn: input.preferences.showOpenChatGPTMenu,
                    target: input.relay,
                    action: #selector(DashboardPreferencePageRelay.toggle(_:))
                )
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开 CC Switch", "Open CC Switch", "開啟 CC Switch", "CC Switch を開く"),
                subtitle: tr("显示 CC Switch 启动项", "Show the CC Switch launch item", "顯示 CC Switch 啟動項目", "CC Switch 起動項目を表示"),
                control: openCC
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开 OpenCodex", "Open OpenCodex", "開啟 OpenCodex", "OpenCodex を開く"),
                subtitle: tr("显示 OpenCodex 启动项", "Show the OpenCodex launch item", "顯示 OpenCodex 啟動項目", "OpenCodex 起動項目を表示"),
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
                (row as? StatusLinksEditorHostingView)?.layoutHeight
            }
        )
        DispatchQueue.main.async { [weak editor] in
            editor?.logGeometry(label: "initial")
        }
        return DashboardSettingsComponents.makeSettingsPage([items, projects])
    }

    func updateStatusVisibility(_ visible: Bool, animated: Bool) {
        statusSubtitleLabel?.stringValue = visible
            ? tr("显示可自定义的服务状态链接", "Show customizable service status links", "顯示可自訂的服務狀態連結", "カスタマイズ可能なサービスステータスリンクを表示")
            : tr("在菜单栏中显示状态链接", "Show status links in the menu bar", "在選單列中顯示狀態連結", "メニューバーにステータスリンクを表示")
        statusLinksEditor?.setVisible(visible, animated: animated)
    }

    func teardown() {
        statusLinksEditor?.teardown()
        statusLinksEditor = nil
        statusSubtitleLabel = nil
    }
}
