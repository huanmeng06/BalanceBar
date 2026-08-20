import AppKit

enum DashboardGeneralPage {
    struct Input {
        let preferences: AppPreferences
        let currentProviderName: String
        let relay: DashboardPreferencePageRelay
    }

    static func make(_ input: Input) -> NSView {
        let openButton = NSButton(
            title: tr("打开 CC Switch", "Open CC Switch"),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openCCSwitch(_:))
        )
        let currentProviderText = tr(
            "当前供应商：\(input.currentProviderName)",
            "Current Provider: \(input.currentProviderName)"
        )
        let system = DashboardSettingsComponents.makeSettingsSection(tr("系统", "System"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                "CC Switch",
                subtitle: currentProviderText,
                control: openButton
            )
        ])

        let activeRefreshPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [
                (1, tr("每 1 秒", "Every 1 sec")),
                (2, tr("每 2 秒", "Every 2 sec")),
                (3, tr("每 3 秒", "Every 3 sec")),
                (5, tr("每 5 秒", "Every 5 sec")),
                (10, tr("每 10 秒", "Every 10 sec"))
            ],
            selected: input.preferences.codexUsageRefreshInterval,
            identifier: "codexUsageRefreshInterval",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let trailingRefreshPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [
                (0, tr("不继续", "Off")),
                (6, tr("持续 6 秒", "For 6 sec")),
                (12, tr("持续 12 秒", "For 12 sec")),
                (30, tr("持续 30 秒", "For 30 sec"))
            ],
            selected: input.preferences.postCodexRefreshDuration,
            identifier: "postCodexRefreshDuration",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let runningLabel = NSTextField(labelWithString: tr("运行中", "Running"))
        let trailingLabel = NSTextField(labelWithString: tr("结束后", "After"))
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
            title: tr("立即刷新", "Refresh Now"),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.manualRefresh(_:))
        )
        let refreshing = DashboardSettingsComponents.makeSettingsSection(tr("刷新", "Refresh"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("任务期间余量更新频率", "Balance Updates During Tasks"),
                subtitle: tr(
                    "Agent 运行时请求当前供应商的余量",
                    "Requests the current Provider's balance while an Agent is running"
                ),
                control: activeRefreshControls,
                minimumHeight: 76
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr("余额数据", "Balance Data"),
                subtitle: tr("立即重新读取当前供应商", "Reload the current Provider now"),
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
        let app = DashboardSettingsComponents.makeSettingsSection(tr("应用", "Application"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("语言", "Language"),
                subtitle: tr("更改后立即应用到整个界面", "Changes apply to the entire interface immediately"),
                control: languagePopup
            )
        ])
        return DashboardSettingsComponents.makeSettingsPage([system, refreshing, app])
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
            tr("刷新设置", "Refresh Settings"),
            subtitle: tr(
                "文件监听始终开启，轮询用于防止遗漏系统事件",
                "File monitoring is always active; polling prevents missed system events"
            )
        )
        let pollingTitle = NSTextField(labelWithString: tr("CC Switch 轮询兜底", "CC Switch Fallback Polling"))
        pollingTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let pollingPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [
                (1, tr("每 1 秒", "Every 1 sec")),
                (3, tr("每 3 秒", "Every 3 sec")),
                (5, tr("每 5 秒", "Every 5 sec")),
                (10, tr("每 10 秒", "Every 10 sec"))
            ],
            selected: input.providerPollInterval,
            identifier: "providerPollInterval",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let pollingRow = NSStackView(views: [pollingTitle, NSView(), pollingPopup])
        pollingRow.orientation = .horizontal
        pollingRow.alignment = .centerY

        let activityTitle = NSTextField(labelWithString: tr("Codex 任务状态检测", "Codex Task Status Detection"))
        activityTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let activityPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [(0.25, tr("0.25 秒", "0.25 sec")), (0.5, tr("0.5 秒", "0.5 sec")), (1, tr("1 秒", "1 sec"))],
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
            "Rotate the menu bar icon while a Codex task is running"
        ))
        let animationRow = NSStackView(views: [animationTitle, NSView(), animationToggle])
        animationRow.orientation = .horizontal
        animationRow.alignment = .centerY
        let note = NSTextField(wrappingLabelWithString: tr(
            "供应商变化仍由 CC Switch 数据库事件即时触发；这里的秒数只是没有收到事件时的后备检查频率。",
            "Provider changes are still triggered immediately by CC Switch database events; this interval is only the fallback check frequency."
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
