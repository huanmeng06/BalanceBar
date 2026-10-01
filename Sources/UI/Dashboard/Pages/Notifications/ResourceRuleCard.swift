import AppKit

enum ThresholdFormat {
    /// Display/parse helper only. Do not attach this to `NSTextField.formatter`:
    /// `zeroSymbol = ""` makes AppKit reject the next typed number after a
    /// field has been cleared back to "no reminder".
    static var placeholder: String { tr("notifications.no_reminder") }

    static func parsedValue(_ raw: String, kind: BalanceNotificationResourceKind) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == placeholder { return 0 }
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .decimal
        formatter.isLenient = true
        if let number = formatter.number(from: trimmed) {
            return number.doubleValue
        }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    static func displayString(_ value: Double, kind: BalanceNotificationResourceKind) -> String {
        guard value > 0 else { return "" }
        switch kind {
        case .quotaPercent:
            return String(format: "%.0f", value)
        case .balance:
            return String(format: "%.2f", value)
        }
    }

    static func committedValue(from field: NSTextField, kind: BalanceNotificationResourceKind) -> Double {
        parsedValue(field.currentEditor()?.string ?? field.stringValue, kind: kind) ?? 0
    }
}

struct ResourceRuleState: Equatable {
    var resourceEnabled: Bool
    var usesGlobalDefaults: Bool
    var currentRemaining: Double
    var firstThreshold: Double
    var secondThreshold: Double

    var secondEnabled: Bool { secondThreshold > 0 }
}

enum ResourceRuleEvent {
    case resourceToggled(Bool)
    case sourceChanged(usesGlobalDefaults: Bool)
    case thresholdEdited(index: Int, value: Double)
    case editDefaultsTapped
}

private final class OpticalTrailingLabel: NSTextField {
    var extraTrailing: CGFloat = SettingsLayout.trailingLabelOpticalCompensation

    override var alignmentRectInsets: NSEdgeInsets {
        var insets = super.alignmentRectInsets
        insets.right += extraTrailing
        return insets
    }
}

final class ThresholdAccessory: NSStackView {
    let field = NSTextField()
    private let valueLabel = OpticalTrailingLabel(labelWithString: "")
    private let unitLabel: OpticalTrailingLabel
    private let kind: BalanceNotificationResourceKind

    var unitLabelForTesting: NSTextField { unitLabel }
    var valueLabelForTesting: NSTextField { valueLabel }

    init(
        kind: BalanceNotificationResourceKind,
        unitText: String
    ) {
        self.kind = kind
        self.unitLabel = OpticalTrailingLabel(labelWithString: unitText)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        detachesHiddenViews = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        clipsToBounds = false

        field.placeholderString = ThresholdFormat.placeholder
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
        let numericTemplate = kind == .quotaPercent
            ? "000"
            : DashboardSettingsComponents.amountCapacityTemplate
        let fieldWidth = max(
            DashboardSettingsComponents.compactNumericWidth(for: field, capacityTemplate: numericTemplate),
            DashboardSettingsComponents.compactNumericWidth(for: field, capacityTemplate: ThresholdFormat.placeholder)
        )
        field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        field.setContentHuggingPriority(.required, for: .horizontal)
        // Keep the explicit width in charge when the placeholder is wider than
        // the current digits, otherwise the empty "不提醒" field jumps right.
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
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
        let unitWidth = ceil(unitLabel.fittingSize.width)
        if unitWidth > 0 {
            unitLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: unitWidth).isActive = true
        }

        [field, unitLabel, valueLabel].forEach(addArrangedSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(value: Double, displayText: String, editable: Bool) {
        field.isHidden = !editable
        field.isEnabled = editable
        field.stringValue = ThresholdFormat.displayString(value, kind: kind)
        // Empty custom values still show a gray unit so first/second fields
        // share one trailing column instead of the empty field jumping right.
        unitLabel.isHidden = !editable
        valueLabel.isHidden = editable
        valueLabel.stringValue = value > 0 ? displayText : ThresholdFormat.placeholder
    }

    func committedValue() -> Double {
        ThresholdFormat.committedValue(from: field, kind: kind)
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
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private let editButton: NSButton

    var resourceSwitchForTesting: NSSwitch { resourceSwitch }
    var sourcePopUpForTesting: NSPopUpButton { sourcePopUp }
    var firstFieldForTesting: NSTextField { firstAccessory.field }
    var firstUnitLabelForTesting: NSTextField { firstAccessory.unitLabelForTesting }
    var firstValueLabelForTesting: NSTextField { firstAccessory.valueLabelForTesting }
    var secondFieldForTesting: NSTextField { secondAccessory.field }
    var secondUnitLabelForTesting: NSTextField { secondAccessory.unitLabelForTesting }
    var secondValueLabelForTesting: NSTextField { secondAccessory.valueLabelForTesting }
    var sectionHiddenForTesting: Bool { section.isHidden }
    var footerHiddenForTesting: Bool { footer.isHidden }
    var footerHintForTesting: String { footerLabel.stringValue }
    var titleForTesting: String { titleLabel.stringValue }
    var titleLabelForTesting: NSTextField { titleLabel }
    var currentLabelForTesting: NSTextField { currentLabel }
    var footerLabelForTesting: NSTextField { footerLabel }
    var editButtonForTesting: NSButton { editButton }

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
            kind: kind,
            unitText: unitText
        )
        self.secondAccessory = ThresholdAccessory(
            kind: kind,
            unitText: unitText
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
        self.editButton = NSButton(
            title: tr("notifications.edit_defaults"),
            target: nil,
            action: nil
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
        self.section = SettingsSectionView(
            title: nil,
            contentViews: [sourceRow, firstRow, secondRow]
        )
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
        currentLabel.font = SettingsLayout.secondaryFont
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

        footerLabel.font = SettingsLayout.secondaryFont
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.maximumNumberOfLines = 0
        footerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editButton.target = self
        editButton.action = #selector(editDefaultsTapped)
        editButton.isBordered = false
        editButton.font = SettingsLayout.secondaryFont
        editButton.contentTintColor = .controlAccentColor
        editButton.setContentHuggingPriority(.required, for: .horizontal)
        footer.orientation = .horizontal
        footer.alignment = .firstBaseline
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
            editable: editable
        )

        footerLabel.stringValue = new.usesGlobalDefaults
            ? tr("notifications.default_readonly_hint")
            : tr("notifications.global_rules_hint")
        editButton.isHidden = !new.usesGlobalDefaults

        let updates = {
            self.section.isHidden = !showBody
            self.footer.isHidden = !showBody
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

    @objc private func firstEdited() {
        onEvent?(.thresholdEdited(index: 0, value: max(0, firstAccessory.committedValue())))
    }

    @objc private func secondEdited() {
        var value = max(0, secondAccessory.committedValue())
        if value > 0, state.firstThreshold > 0, value >= state.firstThreshold {
            let step: Double = kind == .quotaPercent ? 1 : 0.01
            value = max(0, state.firstThreshold - step)
        }
        onEvent?(.thresholdEdited(index: 1, value: value))
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
