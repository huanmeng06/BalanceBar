import AppKit

struct ResourceRuleState: Equatable {
    var resourceEnabled: Bool
    var usesGlobalDefaults: Bool
    var currentRemaining: Double
    var firstThreshold: Double
    var secondThreshold: Double
    var secondEnabled: Bool
}

enum ResourceRuleEvent {
    case resourceToggled(Bool)
    case sourceChanged(usesGlobalDefaults: Bool)
    case secondToggled(Bool)
    case thresholdEdited(index: Int, value: Double)
    case editDefaultsTapped
}

final class ThresholdAccessory: NSStackView {
    let toggle: NSSwitch?
    let field = NSTextField()
    private let valueLabel = NSTextField(labelWithString: "")
    private let unitLabel: NSTextField
    private let offText: String
    private let kind: BalanceNotificationResourceKind

    init(
        showsToggle: Bool,
        kind: BalanceNotificationResourceKind,
        unitText: String,
        offText: String = ""
    ) {
        self.toggle = showsToggle ? NSSwitch() : nil
        self.offText = offText
        self.kind = kind
        self.unitLabel = NSTextField(labelWithString: unitText)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        detachesHiddenViews = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        edgeInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: 0,
            right: -SettingsLayout.trailingLabelOpticalCompensation
        )

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        if kind == .quotaPercent {
            formatter.allowsFloats = false
            formatter.maximumFractionDigits = 0
            formatter.maximum = 100
        } else {
            formatter.allowsFloats = true
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
        }
        field.formatter = formatter
        field.placeholderString = "0"
        field.alignment = .right
        field.controlSize = .regular
        field.cell?.controlSize = .regular
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .regular),
            weight: .regular
        )
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.sendsActionOnEndEditing = true
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        let nativeHeight = ceil(field.cell?.cellSize.height ?? 0)
        if nativeHeight > 0 {
            field.heightAnchor.constraint(equalToConstant: nativeHeight).isActive = true
        }

        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        unitLabel.textColor = .secondaryLabelColor
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)
        unitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        [toggle, field, unitLabel, valueLabel].compactMap { $0 }.forEach(addArrangedSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(value: Double, displayText: String, editable: Bool, isOn: Bool = true) {
        toggle?.isHidden = !editable
        toggle?.state = isOn ? .on : .off
        let showEditor = editable && isOn
        field.isHidden = !showEditor
        unitLabel.isHidden = !showEditor
        field.isEnabled = showEditor
        if kind == .quotaPercent {
            field.integerValue = Int(value.rounded())
        } else {
            field.doubleValue = value
        }
        valueLabel.isHidden = showEditor
        valueLabel.stringValue = isOn ? displayText : offText
    }
}

final class ResourceRuleCard: NSStackView {
    private(set) var state: ResourceRuleState
    var onEvent: ((ResourceRuleEvent) -> Void)?

    private let kind: BalanceNotificationResourceKind
    private let unit: String?

    private let titleLabel = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: "")
    private let resourceSwitch = NSSwitch()

    private let sourcePopUp: NSPopUpButton
    private let firstAccessory: ThresholdAccessory
    private let secondAccessory: ThresholdAccessory
    private let section: SettingsSectionView
    private let footer = NSStackView()

    var resourceSwitchForTesting: NSSwitch { resourceSwitch }
    var sourcePopUpForTesting: NSPopUpButton { sourcePopUp }
    var firstFieldForTesting: NSTextField { firstAccessory.field }
    var secondFieldForTesting: NSTextField { secondAccessory.field }
    var secondToggleForTesting: NSSwitch? { secondAccessory.toggle }
    var sectionHiddenForTesting: Bool { section.isHidden }
    var footerHiddenForTesting: Bool { footer.isHidden }
    var titleForTesting: String { titleLabel.stringValue }

    init(
        title: String,
        key: BalanceNotificationResourceKey,
        kind: BalanceNotificationResourceKind,
        unit: String?,
        initial: ResourceRuleState
    ) {
        self.state = initial
        self.kind = kind
        self.unit = unit
        let unitText = Self.unitText(kind: kind, unit: unit)
        self.firstAccessory = ThresholdAccessory(
            showsToggle: false,
            kind: kind,
            unitText: unitText
        )
        self.secondAccessory = ThresholdAccessory(
            showsToggle: true,
            kind: kind,
            unitText: unitText,
            offText: tr("notifications.second_off")
        )
        self.sourcePopUp = DashboardSettingsComponents.makePopUpButton(
            identifier: "source:\(key.agent.rawValue):\(key.providerID):\(key.resourceID)",
            items: [
                DashboardSettingsComponents.PopUpItem(
                    title: tr("notifications.use_default_rules"),
                    representedObject: NSNumber(value: true)
                ),
                DashboardSettingsComponents.PopUpItem(
                    title: tr("notifications.custom_rules"),
                    representedObject: NSNumber(value: false)
                )
            ],
            selectedIndex: initial.usesGlobalDefaults ? 0 : 1,
            target: nil,
            action: nil,
            ignoresScrollWheel: true
        )
        let sourceRow = SettingsRowView(
            title: tr("notifications.rule_source"),
            detail: nil,
            accessoryView: sourcePopUp
        )
        let firstRow = SettingsRowView(
            title: tr("notifications.resource_first_reminder"),
            detail: tr("notifications.remaining_below"),
            accessoryView: firstAccessory
        )
        let secondRow = SettingsRowView(
            title: tr("notifications.resource_second_reminder"),
            detail: tr("notifications.remaining_below"),
            accessoryView: secondAccessory
        )
        self.section = SettingsSectionView(title: nil, contentViews: [sourceRow, firstRow, secondRow])
        super.init(frame: .zero)

        identifier = NSUserInterfaceItemIdentifier(
            "resource-card:\(key.agent.rawValue):\(key.providerID):\(key.resourceID)"
        )
        resourceSwitch.identifier = NSUserInterfaceItemIdentifier(
            "resource:\(key.agent.rawValue):\(key.providerID):\(key.resourceID)"
        )
        firstAccessory.field.identifier = NSUserInterfaceItemIdentifier(
            "resource:\(key.agent.rawValue):\(key.providerID):\(key.resourceID)|first"
        )
        secondAccessory.field.identifier = NSUserInterfaceItemIdentifier(
            "resource:\(key.agent.rawValue):\(key.providerID):\(key.resourceID)|second"
        )

        orientation = .vertical
        alignment = .leading
        spacing = 8
        detachesHiddenViews = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.stringValue = title
        titleLabel.font = SettingsSectionView.headingFont
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        currentLabel.font = .systemFont(ofSize: 13)
        currentLabel.textColor = .secondaryLabelColor
        currentLabel.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = NSStackView(views: [titleLabel, currentLabel, spacer, resourceSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        header.edgeInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: 0,
            right: SettingsLayout.rowHorizontalInset
        )

        let footerLabel = NSTextField(labelWithString: tr("notifications.default_readonly_hint"))
        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let editButton = NSButton(
            title: tr("notifications.edit_defaults"),
            target: self,
            action: #selector(editDefaultsTapped)
        )
        editButton.isBordered = false
        editButton.font = .systemFont(ofSize: 12)
        editButton.contentTintColor = .controlAccentColor
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.detachesHiddenViews = true
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.setViews([footerLabel, editButton], in: .leading)

        [header, section, footer].forEach { view in
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }

        resourceSwitch.target = self
        resourceSwitch.action = #selector(resourceToggled)
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged)
        secondAccessory.toggle?.target = self
        secondAccessory.toggle?.action = #selector(secondToggled)
        firstAccessory.field.target = self
        firstAccessory.field.action = #selector(firstEdited)
        secondAccessory.field.target = self
        secondAccessory.field.action = #selector(secondEdited)

        apply(initial, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ new: ResourceRuleState, animated: Bool = true) {
        state = new
        let editable = !new.usesGlobalDefaults
        let showBody = new.resourceEnabled
        let showFooter = showBody && new.usesGlobalDefaults

        resourceSwitch.state = new.resourceEnabled ? .on : .off
        currentLabel.stringValue = remainingText(new.currentRemaining)
        sourcePopUp.selectItem(at: new.usesGlobalDefaults ? 0 : 1)

        firstAccessory.apply(
            value: new.firstThreshold,
            displayText: thresholdText(new.firstThreshold),
            editable: editable
        )
        secondAccessory.apply(
            value: new.secondThreshold,
            displayText: thresholdText(new.secondThreshold),
            editable: editable,
            isOn: new.secondEnabled
        )

        let updates = {
            self.section.isHidden = !showBody
            self.footer.isHidden = !showFooter
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                updates()
            }
        } else {
            updates()
        }
        section.reconcileSeparators()
    }

    @objc private func resourceToggled() {
        onEvent?(.resourceToggled(resourceSwitch.state == .on))
    }

    @objc private func sourceChanged() {
        onEvent?(.sourceChanged(usesGlobalDefaults: sourcePopUp.indexOfSelectedItem == 0))
    }

    @objc private func secondToggled() {
        onEvent?(.secondToggled(secondAccessory.toggle?.state == .on))
    }

    @objc private func firstEdited() {
        onEvent?(.thresholdEdited(index: 0, value: firstAccessory.field.doubleValue))
    }

    @objc private func secondEdited() {
        onEvent?(.thresholdEdited(index: 1, value: secondAccessory.field.doubleValue))
    }

    @objc private func editDefaultsTapped() {
        onEvent?(.editDefaultsTapped)
    }

    private func remainingText(_ value: Double) -> String {
        if kind == .quotaPercent {
            return tr(
                "notifications.current_remaining",
                arguments: [String(format: "%.0f", value)]
            )
        }
        return tr("notifications.balance_value", arguments: [Self.balanceText(value, unit: unit)])
    }

    private func thresholdText(_ value: Double) -> String {
        if kind == .quotaPercent {
            return "\(String(format: "%.0f", value))%"
        }
        return Self.balanceText(value, unit: unit)
    }

    static func localizedTitle(resourceID: String, fallback: String) -> String {
        switch resourceID {
        case "five-hour":
            return tr("notifications.five_hour_quota")
        case "weekly":
            return tr("notifications.seven_day_quota")
        case "balance":
            return tr("notifications.balance_resource")
        default:
            return fallback
        }
    }

    private static func unitText(kind: BalanceNotificationResourceKind, unit: String?) -> String {
        if kind == .quotaPercent { return "%" }
        let raw = unit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "USD" : raw
    }

    private static func balanceText(_ value: Double, unit: String?) -> String {
        let number = String(format: "%.2f", value)
        guard let unit, !unit.isEmpty else { return "\(number) USD" }
        if ["$", "€", "£", "¥"].contains(unit) {
            return "\(unit)\(number)"
        }
        return "\(number) \(unit)"
    }
}
