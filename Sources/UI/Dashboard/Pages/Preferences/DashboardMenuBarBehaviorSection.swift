import AppKit

/// Right-click and mouse-button behavior for the Menu Bar settings page.
final class DashboardMenuBarBehaviorSection {
    private weak var rightClickActionControl: NSPopUpButton?
    private weak var reverseMouseButtonsSwitch: NSSwitch?
    private weak var rightClickActionRow: NSView?
    private weak var reverseMouseButtonsRow: NSView?
    private var behaviorRowsStack: NSStackView?
    private var behaviorCardHeightConstraint: NSLayoutConstraint?
    private var behaviorSeparators: [NSView] = []

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
        let rightClickActionRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageRightClick),
            subtitle: tr(.keyDashboardMenuBarPageRightClickDescription),
            control: rightClickActionControl
        )
        self.rightClickActionRow = rightClickActionRow
        let reverseMouseButtonsRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageReverseMouseButtons),
            subtitle: tr(.keyDashboardMenuBarPageReverseMouseButtonsDescription),
            control: reverseMouseButtonsSwitch
        )
        reverseMouseButtonsRow.isHidden = input.preferences.menuBarRightClickAction == .matchLeftClick
        self.reverseMouseButtonsRow = reverseMouseButtonsRow
        let behaviorSection = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardMenuBarPageBehavior),
            rows: [
                rightClickActionRow,
                reverseMouseButtonsRow
            ],
            onLayoutCreated: { [weak self] rowsStack, cardHeightConstraint, separators in
                self?.behaviorRowsStack = rowsStack
                self?.behaviorCardHeightConstraint = cardHeightConstraint
                self?.behaviorSeparators = separators
            }
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
        let showReverse = rightClickAction != .matchLeftClick
        reverseMouseButtonsRow?.isHidden = !showReverse
        let rows = [rightClickActionRow, reverseMouseButtonsRow]
        for (index, separator) in behaviorSeparators.enumerated() {
            guard index < rows.count,
                  index + 1 < rows.count else {
                separator.isHidden = true
                continue
            }
            let hasVisibleRowAfter = rows[(index + 1)...].contains { $0?.isHidden == false }
            separator.isHidden = !(rows[index]?.isHidden == false && hasVisibleRowAfter)
        }
        updateCardLayout()
    }

    private func updateCardLayout() {
        guard let behaviorRowsStack,
              let behaviorCardHeightConstraint else { return }
        behaviorRowsStack.needsLayout = true
        behaviorRowsStack.layoutSubtreeIfNeeded()
        behaviorCardHeightConstraint.constant = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: behaviorRowsStack,
            separators: behaviorSeparators
        )
        behaviorRowsStack.superview?.invalidateIntrinsicContentSize()
        behaviorRowsStack.superview?.needsLayout = true
        behaviorRowsStack.superview?.superview?.needsLayout = true
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
