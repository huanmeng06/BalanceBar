import AppKit

/// Right-click and mouse-button behavior for the Menu Bar settings page.
final class DashboardMenuBarBehaviorSection {
    private weak var rightClickActionControl: NSPopUpButton?
    private weak var reverseMouseButtonsSwitch: NSSwitch?
    private weak var reverseMouseButtonsRow: SettingsRowView?
    func make(input: DashboardMenuBarPage.Input) -> NSView {
        let rightClickActionControl = makeRightClickActionControl(
            value: input.preferences.menuBarRightClickAction,
            relay: input.relay
        )
        self.rightClickActionControl = rightClickActionControl
        let reverseMouseButtonsSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: DashboardMenuBarPage.reverseMouseButtonsIdentifier,
            isOn: input.preferences.menuBarReverseMouseButtons,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        self.reverseMouseButtonsSwitch = reverseMouseButtonsSwitch
        let rightClickActionRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageRightClick),
            detail: tr(.keyDashboardMenuBarPageRightClickDescription),
            accessoryView: rightClickActionControl
        )
        let reverseMouseButtonsRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageReverseMouseButtons),
            detail: tr(.keyDashboardMenuBarPageReverseMouseButtonsDescription),
            accessoryView: reverseMouseButtonsSwitch
        )
        self.reverseMouseButtonsRow = reverseMouseButtonsRow
        let behaviorSection = SettingsSectionView(
            title: tr(.keyDashboardMenuBarPageBehavior),
            contentViews: [
                rightClickActionRow,
                reverseMouseButtonsRow
            ]
        )
        updateVisibility(rightClickAction: input.preferences.menuBarRightClickAction)
        return behaviorSection
    }

    func refresh(rightClickAction: MenuBarRightClickAction, reverseMouseButtons: Bool) {
        if let rightClickActionControl,
           let selectedIndex = MenuBarRightClickAction.allCases.firstIndex(
               of: rightClickAction
           ) {
            if rightClickActionControl.indexOfSelectedItem != selectedIndex {
                rightClickActionControl.selectItem(at: selectedIndex)
            }
            rightClickActionControl.synchronizeTitleAndSelectedItem()
        }
        reverseMouseButtonsSwitch?.state = reverseMouseButtons ? .on : .off
        updateVisibility(rightClickAction: rightClickAction)
    }

    private func updateVisibility(rightClickAction: MenuBarRightClickAction) {
        reverseMouseButtonsRow?.setDependencyEnabled(rightClickAction != .matchLeftClick)
    }

    private func makeRightClickActionControl(
        value: MenuBarRightClickAction,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: DashboardMenuBarPage.rightClickActionIdentifier,
            items: MenuBarRightClickAction.allCases.map { action in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.rightClickActionLabel(action),
                    representedObject: action.rawValue
                )
            },
            selectedIndex: MenuBarRightClickAction.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarRightClickAction(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuBarPageRightClickDescription)
        return control
    }

    private static func rightClickActionLabel(
        _ action: MenuBarRightClickAction
    ) -> String {
        switch action {
        case .matchLeftClick:
            return tr(.keyDashboardMenuBarPageRightClickMatchLeftClick)
        case .openMainWindow:
            return tr(.keyDashboardMenuBarPageRightClickOpenMainMenu)
        case .openAgent:
            return tr(.keyDashboardMenuBarPageRightClickOpenAgent)
        case .openCCSwitch:
            return tr(.keyDashboardMenuBarPageRightClickOpenCCSwitch)
        }
    }
}
