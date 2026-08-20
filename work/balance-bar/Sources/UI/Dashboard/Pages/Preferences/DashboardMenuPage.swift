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

        let items = DashboardSettingsComponents.makeSettingsSection(tr("展开菜单", "Dropdown Menu"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("快速切换", "Quick Switch"),
                subtitle: tr("显示 CC Switch 供应商子菜单", "Show the CC Switch Provider submenu"),
                control: quickSwitch
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("刷新后保持展开", "Keep Open After Refresh"),
                subtitle: tr("点击立即刷新后重新打开菜单", "Reopen the menu after Refresh Now"),
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
            "The Open Main Window item is always shown"
        )

        var projectRows: [NSView] = [
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开主窗口", "Open Main Window"),
                control: openMainWindow
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开 ChatGPT", "Open ChatGPT"),
                subtitle: tr("显示 ChatGPT 启动项", "Show the ChatGPT launch item"),
                control: DashboardSettingsComponents.makeSwitch(
                    identifier: "showOpenChatGPTMenu",
                    isOn: input.preferences.showOpenChatGPTMenu,
                    target: input.relay,
                    action: #selector(DashboardPreferencePageRelay.toggle(_:))
                )
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开 CC Switch", "Open CC Switch"),
                subtitle: tr("显示 CC Switch 启动项", "Show the CC Switch launch item"),
                control: openCC
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("打开 OpenCodex", "Open OpenCodex"),
                subtitle: tr("显示 OpenCodex 启动项", "Show the OpenCodex launch item"),
                control: openCodex
            )
        ]
        let statusSubtitle = NSTextField(wrappingLabelWithString: "")
        statusSubtitleLabel = statusSubtitle
        let statusVisible = input.preferences.showStatusMenu
        updateStatusVisibility(statusVisible, animated: false)
        projectRows.append(DashboardSettingsComponents.makeSettingsRow(
            tr("查看状态", "View Status"),
            subtitle: statusVisible
                ? tr("显示可自定义的服务状态链接", "Show customizable service status links")
                : tr("在菜单栏中显示状态链接", "Show status links in the menu bar"),
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
            tr("打开项目", "Open Project"),
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
            ? tr("显示可自定义的服务状态链接", "Show customizable service status links")
            : tr("在菜单栏中显示状态链接", "Show status links in the menu bar")
        statusLinksEditor?.setVisible(visible, animated: animated)
    }

    func teardown() {
        statusLinksEditor?.teardown()
        statusLinksEditor = nil
        statusSubtitleLabel = nil
    }
}
