import AppKit

/// Composite Displayed Colors accessory. Internal H/V stacking is independent
/// of SettingsRowView's inline / dedicated-row placement.
private final class QuotaColorSelectionStack: NSStackView, SettingsRowAccessoryLayout {
    private var availableRowWidth: CGFloat = .greatestFiniteMagnitude
    private(set) var stacksControlsVertically = false
    let allowsTextDrivenDedicatedRow = true
    let minimumInlineLabelWidth = SettingsRowView.minimumInlineLabelWidth

    func updateAvailableRowWidth(_ width: CGFloat) {
        let normalizedWidth = max(0, width)
        if abs(normalizedWidth - availableRowWidth) > 0.5 {
            availableRowWidth = normalizedWidth
        }
        updateOrientationIfNeeded()
    }

    var naturalAccessoryWidth: CGFloat {
        let visible = arrangedSubviews.filter { !$0.isHidden }
        let widths = visible.map(Self.naturalWidth(of:))
        if orientation == .vertical {
            return widths.max() ?? 0
        }
        return widths.reduce(0, +) + max(0, CGFloat(visible.count - 1)) * spacing
    }

    private var naturalHorizontalAccessoryWidth: CGFloat {
        let visible = arrangedSubviews.filter { !$0.isHidden }
        let widths = visible.map(Self.naturalWidth(of:))
        let widest = widths.max() ?? 0
        let total = widths.reduce(0, +) + max(0, CGFloat(visible.count - 1)) * spacing
        return max(widest, total) + 1
    }

    override func layout() {
        updateOrientationIfNeeded()
        super.layout()
    }

    private func updateOrientationIfNeeded() {
        let wantsVertical = availableRowWidth > 0
            && availableRowWidth + 0.5 < naturalHorizontalAccessoryWidth
        let desiredOrientation: NSUserInterfaceLayoutOrientation = wantsVertical ? .vertical : .horizontal
        let orientationChanged = orientation != desiredOrientation
        let stackingChanged = stacksControlsVertically != wantsVertical
        if orientationChanged {
            orientation = desiredOrientation
            alignment = wantsVertical ? .leading : .centerY
        }
        if stackingChanged {
            stacksControlsVertically = wantsVertical
        }
        if orientationChanged || stackingChanged {
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
            superview?.superview?.needsLayout = true
        }
    }

    override var intrinsicContentSize: NSSize {
        let visible = arrangedSubviews.filter { !$0.isHidden }
        guard !visible.isEmpty else { return .zero }
        if orientation == .vertical {
            return NSSize(
                width: naturalAccessoryWidth,
                height: visible.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
                    + max(0, CGFloat(visible.count - 1)) * spacing
            )
        }
        return NSSize(
            width: naturalAccessoryWidth,
            height: visible.map { $0.fittingSize.height }.max() ?? 0
        )
    }

    private static func naturalWidth(of view: NSView) -> CGFloat {
        if let stack = view as? NSStackView {
            let visible = stack.arrangedSubviews.filter { !$0.isHidden }
            let widths = visible.map(naturalWidth(of:))
            if stack.orientation == .vertical {
                return widths.max() ?? 0
            }
            return widths.reduce(0, +) + max(0, CGFloat(visible.count - 1)) * stack.spacing
        }
        let fitting = view.fittingSize.width
        return fitting.isFinite && fitting > 0 ? fitting : 0
    }
}

/// Dedicated Auto Layout row for a wide custom control that must sit below the
/// title, detail, and trailing action instead of beside them. The header uses
/// the same 62 pt standard-row content band and centerY relationship as
/// SettingsRowView; only the custom control extends the row below it.
private final class MenuDedicatedControlRow: NSView {
    let titleLabel: NSTextField
    let detailLabel: NSTextField
    private let labelsStack = NSStackView()
    private let headerBand = NSView()
    private let trailingControl: NSView?
    private let control: NSView

    func setDependencyEnabled(_ enabled: Bool) {
        titleLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
        detailLabel.textColor = enabled ? .secondaryLabelColor : .disabledControlTextColor
        trailingControl?.subviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = enabled }
        (control as? QuotaColorThresholdSlider)?.setEditingEnabled(enabled)
    }

    init(
        title: String,
        detail: String?,
        trailingControl: NSView?,
        control: NSView,
        minimumHeight: CGFloat
    ) {
        titleLabel = NSTextField(wrappingLabelWithString: title)
        detailLabel = NSTextField(wrappingLabelWithString: detail ?? "")
        self.trailingControl = trailingControl
        self.control = control
        super.init(frame: .zero)
        identifier = DashboardPageSearch.rowIdentifier
        DashboardPageSearch.markSearchableRow(self)
        configure(
            title: title,
            detail: detail,
            minimumHeight: max(SettingsRowView.minimumHeight, minimumHeight)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - bounds.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            applyWrappingWidths()
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        applyWrappingWidths()
    }

    private func configure(title: String, detail: String?, minimumHeight: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureLabel(
            titleLabel,
            text: title,
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .labelColor
        )
        let detailText = detail ?? ""
        configureLabel(
            detailLabel,
            text: detailText,
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
        )
        detailLabel.isHidden = detailText.isEmpty

        labelsStack.orientation = .vertical
        labelsStack.alignment = .leading
        labelsStack.spacing = SettingsRowView.labelSpacing
        labelsStack.translatesAutoresizingMaskIntoConstraints = false
        labelsStack.setHuggingPriority(.required, for: .vertical)
        labelsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelsStack.setContentHuggingPriority(.required, for: .vertical)
        labelsStack.setContentCompressionResistancePriority(.required, for: .vertical)
        labelsStack.addArrangedSubview(titleLabel)
        if !detailLabel.isHidden {
            labelsStack.addArrangedSubview(detailLabel)
        }

        headerBand.translatesAutoresizingMaskIntoConstraints = false
        headerBand.setContentHuggingPriority(.required, for: .vertical)
        headerBand.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(headerBand)
        headerBand.addSubview(labelsStack)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(control)

        var constraints: [NSLayoutConstraint] = [
            headerBand.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsRowView.horizontalPadding
            ),
            headerBand.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SettingsRowView.horizontalPadding
            ),
            headerBand.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsRowView.verticalPadding
            ),
            headerBand.heightAnchor.constraint(
                greaterThanOrEqualToConstant: SettingsRowView.minimumHeight
                    - SettingsRowView.verticalPadding * 2
            ),
            labelsStack.centerYAnchor.constraint(equalTo: headerBand.centerYAnchor),
            labelsStack.leadingAnchor.constraint(equalTo: headerBand.leadingAnchor),
            headerBand.heightAnchor.constraint(greaterThanOrEqualTo: labelsStack.heightAnchor),
            labelsStack.bottomAnchor.constraint(
                lessThanOrEqualTo: headerBand.bottomAnchor
            ),
            control.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsRowView.horizontalPadding
            ),
            control.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SettingsRowView.horizontalPadding
            ),
            control.topAnchor.constraint(
                greaterThanOrEqualTo: headerBand.bottomAnchor,
                constant: DashboardSettingsComponents.settingsRowContentControlSpacing
            ),
            control.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -SettingsRowView.verticalPadding
            ),
            heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight)
        ]

        if let trailingControl {
            trailingControl.translatesAutoresizingMaskIntoConstraints = false
            trailingControl.setContentHuggingPriority(.required, for: .horizontal)
            trailingControl.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(trailingControl)
            constraints.append(contentsOf: [
                labelsStack.trailingAnchor.constraint(
                    equalTo: trailingControl.leadingAnchor,
                    constant: -SettingsRowView.contentSpacing
                ),
                labelsStack.topAnchor.constraint(
                    greaterThanOrEqualTo: headerBand.topAnchor
                ),
                trailingControl.trailingAnchor.constraint(
                    equalTo: headerBand.trailingAnchor
                ),
                trailingControl.centerYAnchor.constraint(equalTo: headerBand.centerYAnchor)
            ])
        } else {
            constraints.append(
                labelsStack.trailingAnchor.constraint(
                    equalTo: headerBand.trailingAnchor
                )
            )
        }

        NSLayoutConstraint.activate(constraints)
        DashboardSettingsAccessibility.bind(
            titleLabel: titleLabel,
            detailLabel: detailLabel.isHidden ? nil : detailLabel,
            accessory: trailingControl
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DashboardSettingsAccessibility.bind(
            titleLabel: titleLabel,
            detailLabel: detailLabel.isHidden ? nil : detailLabel,
            accessory: trailingControl
        )
    }

    private func configureLabel(
        _ label: NSTextField,
        text: String,
        font: NSFont,
        color: NSColor
    ) {
        label.stringValue = text
        label.font = font
        label.textColor = color
        label.isEditable = false
        label.isSelectable = false
        label.usesSingleLineMode = false
        label.lineBreakMode = DashboardSettingsComponents.settingsSubtitleLineBreakMode(for: text)
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
    }

    private func applyWrappingWidths() {
        var reserved = SettingsRowView.horizontalPadding * 2
        if let trailingControl, !trailingControl.isHidden {
            let accessoryWidth = trailingControl.bounds.width > 1
                ? trailingControl.bounds.width
                : trailingControl.fittingSize.width
            reserved += accessoryWidth + SettingsRowView.contentSpacing
        }
        let wrappingWidth = bounds.width > 1 ? max(0, bounds.width - reserved) : 0
        guard wrappingWidth > 1 else { return }

        var wrappingChanged = false
        if abs(titleLabel.preferredMaxLayoutWidth - wrappingWidth) > 0.5 {
            titleLabel.preferredMaxLayoutWidth = wrappingWidth
            wrappingChanged = true
        }
        if !detailLabel.isHidden,
           abs(detailLabel.preferredMaxLayoutWidth - wrappingWidth) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = wrappingWidth
            wrappingChanged = true
        }
        guard wrappingChanged else { return }
        invalidateIntrinsicContentSize()
        SettingsSectionView.enclosing(self)?.cardView.invalidateHostedSettingsRowHeight()
    }
}

/// Pins the Status Links editor to its explicit height so the native section
/// card follows Auto Layout instead of the editor's unconstrained table fitting size.
private final class MenuStatusLinksEditorHost: NSView {
    private let makeEditor: () -> StatusLinksEditorHostingView
    private(set) var editor: StatusLinksEditorHostingView?
    private var heightConstraint: NSLayoutConstraint!

    init(makeEditor: @escaping () -> StatusLinksEditorHostingView) {
        self.makeEditor = makeEditor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        let heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            heightConstraint
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
    }

    @discardableResult
    func ensureEditor() -> StatusLinksEditorHostingView {
        if let editor { return editor }
        let editor = makeEditor()
        self.editor = editor
        editor.onLayoutHeightChange = { [weak self] in self?.syncHeight() }
        editor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: topAnchor),
            editor.leadingAnchor.constraint(equalTo: leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        syncHeight()
        return editor
    }

    func syncHeight() {
        let height = max(0, editor?.currentHeight ?? 0)
        heightConstraint.constant = height
        isHidden = height <= 0.5
        invalidateIntrinsicContentSize()
        needsLayout = true
        SettingsSectionView.enclosing(self)?.cardView.invalidateHostedSettingsRowHeight()
    }
}

final class DashboardMenuPage: NSObject, NSTextFieldDelegate {
    static let lunaReserveDisplayModeIdentifier = AppPreferences.menuLunaReserveDisplayModeKey
    static let lunaReserveHideExhaustedQuotaIdentifier = AppPreferences.menuLunaReserveHideExhaustedQuotaKey
    static let bankedResetDisplayModeIdentifier = AppPreferences.menuBankedResetDisplayModeKey

    struct Input {
        let preferences: AppPreferences
        let relay: DashboardPreferencePageRelay
        let makeStatusLinksEditor: () -> StatusLinksEditorHostingView
        let onBalanceDisplayThresholdChanged: (Double) -> Void
        let onQuotaProgressColorConfigurationChanged: (MenuBarQuotaValueMode, QuotaProgressColorConfiguration) -> Void

        init(
            preferences: AppPreferences,
            relay: DashboardPreferencePageRelay,
            makeStatusLinksEditor: @escaping () -> StatusLinksEditorHostingView,
            onBalanceDisplayThresholdChanged: @escaping (Double) -> Void,
            onQuotaProgressColorConfigurationChanged: @escaping (MenuBarQuotaValueMode, QuotaProgressColorConfiguration) -> Void = { _, _ in }
        ) {
            self.preferences = preferences
            self.relay = relay
            self.makeStatusLinksEditor = makeStatusLinksEditor
            self.onBalanceDisplayThresholdChanged = onBalanceDisplayThresholdChanged
            self.onQuotaProgressColorConfigurationChanged = onQuotaProgressColorConfigurationChanged
        }
    }

    private weak var balanceDisplayThresholdField: NSTextField?
    private weak var lunaReserveDisplayModeControl: NSPopUpButton?
    private weak var bankedResetDisplayModeControl: NSPopUpButton?
    private weak var lunaReserveHideExhaustedQuotaRow: NSView?
    private weak var lunaReserveHideExhaustedQuotaSwitch: NSSwitch?
    private var statusLinksEditor: StatusLinksEditorHostingView?
    private var statusLinksEditorHost: MenuStatusLinksEditorHost?
    private var balanceDisplayThresholdValue = AppPreferences.defaultBalanceDisplayThreshold
    private var onBalanceDisplayThresholdChanged: ((Double) -> Void)?
    private var onQuotaProgressColorConfigurationChanged: ((MenuBarQuotaValueMode, QuotaProgressColorConfiguration) -> Void)?
    private weak var quotaColorSlider: QuotaColorThresholdSlider?
    private var quotaColorButtons: [QuotaProgressColor: NSButton] = [:]
    private var editingMode: MenuBarQuotaValueMode = .defaultValue
    private var quotaColorConfigurations: [MenuBarQuotaValueMode: QuotaProgressColorConfiguration] = [:]
    private weak var colorRangesRow: MenuDedicatedControlRow?
    private var quotaColorConfiguration: QuotaProgressColorConfiguration {
        get { quotaColorConfigurations[editingMode] ?? .default }
        set { quotaColorConfigurations[editingMode] = newValue }
    }
    private weak var showQuotaProgressBarSwitch: NSSwitch?
    private weak var showQuotaPaceIndicatorSwitch: NSSwitch?
    private var progressBarDetailRows: [SettingsRowView] = []
    private weak var showBankedResetSwitch: NSSwitch?
    private var bankedResetDetailRows: [SettingsRowView] = []

    func make(_ input: Input) -> NSView {
        balanceDisplayThresholdValue = input.preferences.balanceDisplayThreshold
        onBalanceDisplayThresholdChanged = input.onBalanceDisplayThresholdChanged
        onQuotaProgressColorConfigurationChanged = input.onQuotaProgressColorConfigurationChanged
        editingMode = input.preferences.menuBarQuotaValueMode
        readQuotaColorConfigurations(from: input.preferences)
        lunaReserveDisplayModeControl = nil
        lunaReserveHideExhaustedQuotaRow = nil
        lunaReserveHideExhaustedQuotaSwitch = nil
        bankedResetDisplayModeControl = nil
        showQuotaProgressBarSwitch = nil
        showQuotaPaceIndicatorSwitch = nil
        progressBarDetailRows = []
        showBankedResetSwitch = nil
        bankedResetDetailRows = []

        let lunaReserveRows: [NSView]
        if LunaReserveUserFacing.isCurrentlyEnabled {
            let lunaReserveDisplayModeControl = makeLunaReserveDisplayModeControl(
                value: input.preferences.menuLunaReserveDisplayMode,
                relay: input.relay
            )
            self.lunaReserveDisplayModeControl = lunaReserveDisplayModeControl

            let lunaReserveHideExhaustedQuotaSwitch = DashboardSettingsComponents.makeSwitch(
                identifier: Self.lunaReserveHideExhaustedQuotaIdentifier,
                isOn: input.preferences.menuLunaReserveHideExhaustedQuota,
                target: input.relay,
                action: #selector(DashboardPreferencePageRelay.toggle(_:))
            )
            self.lunaReserveHideExhaustedQuotaSwitch = lunaReserveHideExhaustedQuotaSwitch

            let lunaReserveDisplayModeRow = makeRow(
                DashboardSettingsFormattedCopy.menuLunaReserveDisplayModeTitle(),
                subtitle: DashboardSettingsFormattedCopy.menuLunaReserveDisplayModeDescription(),
                control: lunaReserveDisplayModeControl
            )
            let lunaReserveHideExhaustedQuotaRow = makeRow(
                tr(.keyDashboardMenuPageHideExhaustedQuota),
                subtitle: DashboardSettingsFormattedCopy.hideExhaustedQuotaDescription(),
                control: lunaReserveHideExhaustedQuotaSwitch
            )
            self.lunaReserveHideExhaustedQuotaRow = lunaReserveHideExhaustedQuotaRow
            lunaReserveRows = [
                lunaReserveDisplayModeRow,
                lunaReserveHideExhaustedQuotaRow
            ]
        } else {
            lunaReserveRows = []
        }

        let balanceDisplayThreshold = DashboardSettingsComponents.makeNumericTextField(
            identifier: AppPreferences.balanceDisplayThresholdKey,
            value: Self.formattedBalanceDisplayThreshold(balanceDisplayThresholdValue),
            placeholder: Self.formattedBalanceDisplayThreshold(
                AppPreferences.defaultBalanceDisplayThreshold
            ),
            capacityTemplate: DashboardSettingsComponents.amountCapacityTemplate,
            delegate: self,
            toolTip: tr(.keyDashboardMenuPageEnterAnAmountOfAtLeast001WithUpToTwoDecimalPlaces)
        )
        balanceDisplayThresholdField = balanceDisplayThreshold.field

        let slider = QuotaColorThresholdSlider(configuration: quotaColorConfiguration)
        slider.axis = editingMode
        slider.onChange = { [weak self] configuration in
            guard let self else { return }
            let normalized = configuration.normalized()
            self.quotaColorConfiguration = normalized
            self.updateQuotaColorButtons()
            self.onQuotaProgressColorConfigurationChanged?(self.editingMode, normalized)
        }
        quotaColorSlider = slider
        let resetButton = NSButton(
            title: DashboardSettingsFormattedCopy.restoreDefaultsTitle(),
            target: self,
            action: #selector(resetQuotaProgressColors(_:))
        )
        Self.configureQuotaColorResetButton(resetButton)
        let modePicker = DashboardSettingsComponents.makePopUpButton(
            identifier: "quotaProgressColorEditingMode",
            items: MenuBarQuotaValueMode.allCases.map { mode in
                .init(title: tr(mode == .used ? .keyDashboardMenuBarPageQuotaValueUsed : .keyDashboardMenuBarPageQuotaValueRemaining),
                      representedObject: mode.rawValue)
            },
            selectedIndex: MenuBarQuotaValueMode.allCases.firstIndex(of: editingMode),
            target: self,
            action: #selector(changeQuotaColorEditingMode(_:))
        )
        let editingModeLabel = tr(.keyDashboardMenuPageProgressColorEditingMode)
        modePicker.setAccessibilityLabel(editingModeLabel)
        modePicker.toolTip = editingModeLabel
        let colorRangeControls = NSStackView(views: [modePicker, resetButton])
        colorRangeControls.orientation = .horizontal
        colorRangeControls.alignment = .centerY
        colorRangeControls.spacing = 8
        // The header reserves the whole accessory width for wrapping. Keep the
        // native stack from stretching its trailing gravity area on resize.
        let pickerWidth = ceil(modePicker.fittingSize.width)
        let resetWidth = ceil(resetButton.fittingSize.width)
        NSLayoutConstraint.activate([
            modePicker.widthAnchor.constraint(equalToConstant: pickerWidth),
            resetButton.widthAnchor.constraint(equalToConstant: resetWidth),
            colorRangeControls.widthAnchor.constraint(equalToConstant: pickerWidth + colorRangeControls.spacing + resetWidth)
        ])
        let colorControls = QuotaColorSelectionStack()
        colorControls.orientation = .horizontal
        colorControls.alignment = .centerY
        colorControls.spacing = 12
        colorControls.setContentHuggingPriority(.required, for: .horizontal)
        colorControls.setContentCompressionResistancePriority(.required, for: .horizontal)
        for color in QuotaProgressColor.allCases {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleQuotaColor(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("quotaProgressColor.\(color.rawValue)")
            button.setAccessibilityLabel(Self.colorLabel(color))
            button.state = quotaColorConfiguration.enabledColors.contains(color) ? .on : .off
            let swatch = NSImageView(image: NSImage(systemSymbolName: "square.fill", accessibilityDescription: nil) ?? NSImage())
            swatch.contentTintColor = color.nsColor
            swatch.setAccessibilityElement(false)
            let item = NSStackView(views: [button, swatch])
            item.orientation = .horizontal
            item.alignment = .centerY
            item.spacing = 4
            item.setContentHuggingPriority(.required, for: .horizontal)
            item.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            swatch.setContentHuggingPriority(.required, for: .horizontal)
            swatch.setContentCompressionResistancePriority(.required, for: .horizontal)
            let checkboxBounds = NSRect(origin: .zero, size: button.fittingSize)
            let indicatorRect = button.cell?.imageRect(forBounds: checkboxBounds) ?? checkboxBounds
            let side = max(1, min(indicatorRect.width, indicatorRect.height))
            swatch.widthAnchor.constraint(equalToConstant: side).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: side).isActive = true
            colorControls.addArrangedSubview(item)
            quotaColorButtons[color] = button
        }
        updateQuotaColorButtons()
        let balanceDisplay: SettingsSectionView? = lunaReserveRows.isEmpty
            ? nil
            : SettingsSectionView(
                title: tr(.keyDashboardMenuPageBalanceDisplay),
                contentViews: lunaReserveRows
            )
        if balanceDisplay != nil {
            updateLunaReserveDisplayModeVisibility(
                input.preferences.menuLunaReserveDisplayMode
            )
        }

        let showBankedResetSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: AppPreferences.showBankedResetKey,
            isOn: input.preferences.showBankedReset,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        self.showBankedResetSwitch = showBankedResetSwitch
        let showBankedResetRow = makeRow(
            tr(.keyDashboardMenuPageShowBankedReset),
            subtitle: tr(.keyDashboardMenuPageShowBankedResetDescription),
            control: showBankedResetSwitch
        )
        let bankedResetDisplayModeControl = makeBankedResetDisplayModeControl(
            value: input.preferences.menuBankedResetDisplayMode,
            relay: input.relay
        )
        self.bankedResetDisplayModeControl = bankedResetDisplayModeControl
        let bankedResetDisplayModeRow = makeRow(
            tr(.keyDashboardMenuPageBankedResetDisplayMode),
            subtitle: tr(.keyDashboardMenuPageBankedResetDisplayModeDescription),
            control: bankedResetDisplayModeControl
        )
        bankedResetDetailRows = [bankedResetDisplayModeRow]
        let bankedReset = SettingsSectionView(
            title: tr(.keyCodexBankedResetTitle),
            contentViews: [
                showBankedResetRow,
                bankedResetDisplayModeRow
            ]
        )
        updateBankedResetSettingsVisibility(input.preferences.showBankedReset)

        let showQuotaProgressBarSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: AppPreferences.showQuotaProgressBarKey,
            isOn: input.preferences.showQuotaProgressBar,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        self.showQuotaProgressBarSwitch = showQuotaProgressBarSwitch
        let showQuotaProgressBarRow = makeRow(
            tr(.keyDashboardMenuPageShowQuotaProgressBar),
            subtitle: tr(.keyDashboardMenuPageShowQuotaProgressBarDescription),
            control: showQuotaProgressBarSwitch
        )
        let showQuotaPaceIndicatorSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: AppPreferences.showQuotaPaceIndicatorKey,
            isOn: input.preferences.showQuotaPaceIndicator,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        self.showQuotaPaceIndicatorSwitch = showQuotaPaceIndicatorSwitch
        let showQuotaPaceIndicatorRow = makeRow(
            tr(.keyDashboardMenuPageShowQuotaPaceIndicator),
            subtitle: tr(.keyDashboardMenuPageShowQuotaPaceIndicatorDescription),
            control: showQuotaPaceIndicatorSwitch
        )
        let colorRangesRow = MenuDedicatedControlRow(
            title: tr(.keyDashboardMenuPageProgressColorRanges),
            detail: quotaColorRangesDescription,
            trailingControl: colorRangeControls,
            control: slider,
            minimumHeight: 90
        )
        self.colorRangesRow = colorRangesRow
        let displayedColorsRow = makeRow(
            tr(.keyDashboardMenuPageDisplayedColors),
            subtitle: tr(.keyDashboardMenuPageDisplayedColorsDescription),
            control: colorControls
        )
        let thresholdRow = makeRow(
            tr(.keyDashboardMenuPageLowBalanceDisplayThreshold),
            subtitle: tr(.keyDashboardMenuPageAfterARechargeKeepTheProgressBarRedWhileTheBalanceRemainsBelowThisAmount),
            control: balanceDisplayThreshold
        )
        progressBarDetailRows = [showQuotaPaceIndicatorRow, displayedColorsRow, thresholdRow]
        let progressBar = SettingsSectionView(
            title: tr(.keyDashboardMenuPageProgressBar),
            contentViews: [showQuotaProgressBarRow, showQuotaPaceIndicatorRow]
        )
        let progressColors = SettingsSectionView(
            title: "",
            contentViews: [
                colorRangesRow,
                displayedColorsRow,
                thresholdRow
            ]
        )
        updateProgressBarSettingsVisibility(input.preferences.showQuotaProgressBar)

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
        let keepOpen = DashboardSettingsComponents.makeSwitch(
            identifier: "keepMenuOpenAfterRefresh",
            isOn: input.preferences.keepMenuOpenAfterRefresh,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )

        let items = SettingsSectionView(
            title: tr(.keyDashboardMenuPageMenuBehavior),
            contentViews: [
                makeRow(
                    tr(.keyDashboardMenuPageQuickSwitch),
                    subtitle: tr(.keyDashboardMenuPageShowTheCcSwitchProviderSubmenu),
                    control: quickSwitch
                ),
                makeRow(
                    tr(.keyDashboardMenuPageKeepOpenAfterRefresh),
                    subtitle: tr(.keyDashboardMenuPageReopenTheMenuAfterRefreshNow),
                    control: keepOpen
                )
            ]
        )

        let openMainWindow = DashboardSettingsComponents.makeSwitch(
            identifier: "showOpenDashboardMenu",
            isOn: true,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        openMainWindow.isEnabled = false
        openMainWindow.toolTip = tr(.keyDashboardMenuPageTheOpenMainWindowItemIsAlwaysShown)

        let quickLinkRows: [NSView] = [
            makeRow(
                tr(.keyDashboardMenuPageOpenMainWindow),
                subtitle: tr(.keyDashboardMenuPageTheOpenMainWindowItemIsAlwaysShown),
                control: openMainWindow
            ),
            makeRow(
                tr(.keyDashboardMenuPageOpenChatgpt),
                subtitle: tr(.keyDashboardMenuPageShowChatgpt),
                control: DashboardSettingsComponents.makeSwitch(
                    identifier: "showOpenChatGPTMenu",
                    isOn: input.preferences.showOpenChatGPTMenu,
                    target: input.relay,
                    action: #selector(DashboardPreferencePageRelay.toggle(_:))
                )
            ),
            makeRow(
                tr(.keyDashboardMenuPageOpenCcSwitch),
                subtitle: tr(.keyDashboardMenuPageShowTheCcSwitchMainWindow),
                control: openCC
            )
        ]
        let statusVisible = input.preferences.showStatusMenu
        let statusRow = makeRow(
            tr(.keyDashboardMenuPageViewStatus),
            subtitle: tr(.keyDashboardMenuPageShowCustomizableServiceStatusLinks),
            control: DashboardSettingsComponents.makeSwitch(
                identifier: "showStatusMenu",
                isOn: statusVisible,
                target: input.relay,
                action: #selector(DashboardPreferencePageRelay.toggle(_:))
            )
        )

        let editorHost = MenuStatusLinksEditorHost(makeEditor: input.makeStatusLinksEditor)
        statusLinksEditorHost = editorHost
        let editor = editorHost.ensureEditor()
        statusLinksEditor = editor
        editor.setVisible(true, animated: false)
        editor.setEditingEnabled(statusVisible)
        let quickLinks = SettingsSectionView(
            title: tr(.keyDashboardMenuPageOpenProject),
            contentViews: quickLinkRows
        )
        let statusLinks = SettingsSectionView(title: "", contentViews: [statusRow, editorHost])
        var sections: [[NSView]] = [[progressBar, progressColors], [bankedReset], [items], [quickLinks, statusLinks]]
        if let balanceDisplay {
            sections.insert([balanceDisplay], at: 0)
        }
        // Return the sections stack only. Production wrapping in
        // `DashboardScrollablePageViewController` owns the unique page scroller;
        // a nested `makeSettingsPage` scroll would pin the outer document to
        // the clip height and leave the Status Links editor unreachable.
        return DashboardSettingsComponents.makeSettingsPageContent(groups: sections)
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

    func refresh(preferences: AppPreferences) {
        readQuotaColorConfigurations(from: preferences)
        quotaColorSlider?.configuration = quotaColorConfiguration
        updateQuotaColorButtons()
        showQuotaProgressBarSwitch?.state = preferences.showQuotaProgressBar ? .on : .off
        showQuotaPaceIndicatorSwitch?.state = preferences.showQuotaPaceIndicator ? .on : .off
        updateProgressBarSettingsVisibility(preferences.showQuotaProgressBar)
        showBankedResetSwitch?.state = preferences.showBankedReset ? .on : .off
        updateBankedResetSettingsVisibility(preferences.showBankedReset)
        let statusLinks = preferences.statusLinks
        if statusLinksEditor?.links != statusLinks {
            statusLinksEditor?.updateLinks(statusLinks)
        }
        balanceDisplayThresholdValue = preferences.balanceDisplayThreshold
        balanceDisplayThresholdField?.stringValue = Self.formattedBalanceDisplayThreshold(
            balanceDisplayThresholdValue
        )
        if let lunaReserveDisplayModeControl,
           let selectedIndex = LunaReserveDisplayMode.allCases.firstIndex(
               of: preferences.menuLunaReserveDisplayMode
           ) {
            if lunaReserveDisplayModeControl.indexOfSelectedItem != selectedIndex {
                lunaReserveDisplayModeControl.selectItem(at: selectedIndex)
            }
            lunaReserveDisplayModeControl.synchronizeTitleAndSelectedItem()
        }
        lunaReserveHideExhaustedQuotaSwitch?.state = preferences.menuLunaReserveHideExhaustedQuota
            ? .on
            : .off
        updateLunaReserveDisplayModeVisibility(preferences.menuLunaReserveDisplayMode)
        if let bankedResetDisplayModeControl,
           let selectedIndex = CodexBankedResetDisplayMode.allCases.firstIndex(
               of: preferences.menuBankedResetDisplayMode
           ) {
            if bankedResetDisplayModeControl.indexOfSelectedItem != selectedIndex {
                bankedResetDisplayModeControl.selectItem(at: selectedIndex)
            }
            bankedResetDisplayModeControl.synchronizeTitleAndSelectedItem()
        }
    }

    func updateStatusVisibility(_ visible: Bool, animated: Bool) {
        statusLinksEditor?.setEditingEnabled(visible)
        DashboardKeyViewLoop.invalidate(statusLinksEditorHost?.window ?? statusLinksEditor?.window)
    }

    func updateStatusLinks(
        _ links: [StatusLink],
        mutation: StatusLinksMutation = .reload,
        selectLastRow: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard let statusLinksEditor else {
            completion?()
            return
        }
        statusLinksEditor.updateLinks(
            links,
            mutation: mutation,
            selectLastRow: selectLastRow,
            completion: completion
        )
    }

    func teardown() {
        balanceDisplayThresholdField?.delegate = nil
        balanceDisplayThresholdField = nil
        lunaReserveDisplayModeControl = nil
        lunaReserveHideExhaustedQuotaRow = nil
        lunaReserveHideExhaustedQuotaSwitch = nil
        bankedResetDisplayModeControl = nil
        showBankedResetSwitch = nil
        bankedResetDetailRows = []
        onBalanceDisplayThresholdChanged = nil
        onQuotaProgressColorConfigurationChanged = nil
        quotaColorButtons = [:]
        quotaColorSlider?.teardown()
        quotaColorSlider = nil
        colorRangesRow = nil
        showQuotaProgressBarSwitch = nil
        progressBarDetailRows = []
        statusLinksEditor?.teardown()
        statusLinksEditor = nil
        statusLinksEditorHost = nil
    }

    private func readQuotaColorConfigurations(from preferences: AppPreferences) {
        quotaColorConfigurations = Dictionary(uniqueKeysWithValues: MenuBarQuotaValueMode.allCases.map {
            ($0, preferences.quotaProgressColorConfiguration(for: $0))
        })
    }

    private var quotaColorRangesDescription: String {
        tr(editingMode == .used ? .keyDashboardMenuPageProgressColorRangesUsedDescription
                               : .keyDashboardMenuPageProgressColorRangesDescription)
    }

    @objc private func changeQuotaColorEditingMode(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = MenuBarQuotaValueMode(rawValue: raw), mode != editingMode else { return }
        editingMode = mode
        quotaColorSlider?.axis = mode
        quotaColorSlider?.configuration = quotaColorConfiguration
        updateQuotaColorButtons()
        if let row = colorRangesRow {
            row.detailLabel.stringValue = quotaColorRangesDescription
            row.detailLabel.invalidateIntrinsicContentSize()
            row.invalidateIntrinsicContentSize()
            invalidateHostedSection(for: row)
        }
    }

    @objc private func toggleQuotaColor(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.split(separator: ".").last,
              let color = QuotaProgressColor(rawValue: String(raw)) else { return }
        applyQuotaColorConfiguration(quotaColorConfiguration.settingEnabled(color, to: sender.state == .on))
    }

    @objc private func resetQuotaProgressColors(_ sender: NSButton) {
        applyQuotaColorConfiguration(.default)
    }

    private func applyQuotaColorConfiguration(_ configuration: QuotaProgressColorConfiguration) {
        quotaColorConfiguration = configuration.normalized()
        quotaColorSlider?.configuration = quotaColorConfiguration
        updateQuotaColorButtons()
        onQuotaProgressColorConfigurationChanged?(editingMode, quotaColorConfiguration)
    }

    private func updateQuotaColorButtons() {
        for (color, button) in quotaColorButtons {
            button.state = quotaColorConfiguration.enabledColors.contains(color) ? .on : .off
            button.isEnabled = showQuotaProgressBarSwitch?.state != .off
                && (button.state == .off || quotaColorConfiguration.enabledColors.count > 2)
        }
    }

    static func configureQuotaColorResetButton(_ button: NSButton) {
        button.controlSize = .regular
        button.bezelStyle = .rounded
        // Resetting an already-default configuration is a harmless no-op; keep
        // the action visually consistent with the other settings buttons.
        button.isEnabled = true
    }

    private static func colorLabel(_ color: QuotaProgressColor) -> String {
        switch color { case .red: tr(.keyDashboardMenuPageColorRed); case .orange: tr(.keyDashboardMenuPageColorOrange); case .yellow: tr(.keyDashboardMenuPageColorYellow); case .green: tr(.keyDashboardMenuPageColorGreen) }
    }

    private func updateLunaReserveDisplayModeVisibility(_ mode: LunaReserveDisplayMode) {
        let shouldShowHideOption = mode != .disabled
        lunaReserveHideExhaustedQuotaRow?.isHidden = !shouldShowHideOption
        lunaReserveHideExhaustedQuotaSwitch?.isEnabled = shouldShowHideOption
        if let row = lunaReserveHideExhaustedQuotaRow {
            SettingsSectionView.enclosing(row)?.reconcileSeparators()
        }
        invalidateHostedSection(for: lunaReserveHideExhaustedQuotaRow)
        DashboardKeyViewLoop.invalidate(lunaReserveHideExhaustedQuotaRow?.window)
    }

    private func updateProgressBarSettingsVisibility(_ visible: Bool) {
        progressBarDetailRows.forEach { $0.setDependencyEnabled(visible) }
        colorRangesRow?.setDependencyEnabled(visible)
        updateQuotaColorButtons()
        DashboardKeyViewLoop.invalidate(showQuotaProgressBarSwitch?.window)
    }

    private func updateBankedResetSettingsVisibility(_ visible: Bool) {
        bankedResetDetailRows.forEach { $0.setDependencyEnabled(visible) }
        DashboardKeyViewLoop.invalidate(showBankedResetSwitch?.window)
    }

    private func invalidateHostedSection(for view: NSView?) {
        guard let view else { return }
        view.invalidateIntrinsicContentSize()
        guard let section = SettingsSectionView.enclosing(view) else { return }
        section.cardView.invalidateHostedSettingsRowHeight()
        section.invalidateIntrinsicContentSize()
        section.needsLayout = true
        section.superview?.needsLayout = true
        section.superview?.invalidateIntrinsicContentSize()
        section.layoutSubtreeIfNeeded()
    }

    private func makeRow(
        _ title: String,
        subtitle: String? = nil,
        control: NSView? = nil
    ) -> SettingsRowView {
        SettingsRowView(title: title, detail: subtitle, accessoryView: control)
    }

    private func makeLunaReserveDisplayModeControl(
        value: LunaReserveDisplayMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.lunaReserveDisplayModeIdentifier,
            items: LunaReserveDisplayMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.lunaReserveDisplayModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: LunaReserveDisplayMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.lunaReserveDisplayMode(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = DashboardSettingsFormattedCopy.menuLunaReserveDisplayModeTitle()
        return control
    }

    private func makeBankedResetDisplayModeControl(
        value: CodexBankedResetDisplayMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.bankedResetDisplayModeIdentifier,
            items: CodexBankedResetDisplayMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.bankedResetDisplayModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: CodexBankedResetDisplayMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.bankedResetDisplayMode(_:))
        )
        let minimumWidth: CGFloat = 88
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuPageBankedResetDisplayModeDescription)
        return control
    }

    private static func bankedResetDisplayModeLabel(_ mode: CodexBankedResetDisplayMode) -> String {
        switch mode {
        case .compact:
            return tr(.keyDashboardMenuPageBankedResetDisplayModeCompact)
        case .detailed:
            return tr(.keyDashboardMenuPageBankedResetDisplayModeDetailed)
        }
    }

    private static func lunaReserveDisplayModeLabel(_ mode: LunaReserveDisplayMode) -> String {
        DashboardSettingsFormattedCopy.lunaReserveDisplayModeTitle(mode)
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

    static func formattedBalanceDisplayThreshold(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
