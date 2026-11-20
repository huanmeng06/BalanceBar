import AppKit

/// Font, icon size, offset, and spacing controls for the Menu Bar page.
final class DashboardMenuBarLayoutSection {
    /// Keep the endpoint and value slots aligned; the settings row decides when the
    /// group moves below its labels. Use a plain host for bounds-based centering.
    private final class MenuBarSliderControls: NSView, SettingsRowAccessoryLayout {
        private static let spacing: CGFloat = 6

        let allowsTextDrivenDedicatedRow = true
        let minimumInlineLabelWidth = SettingsRowView.minimumInlineLabelWidth
        private(set) var stacksControlsVertically = false
        private let labelsWidth: CGFloat
        private let trackWidth: NSLayoutConstraint

        init(views: [NSView], slider: NSSlider, labelsWidth: CGFloat) {
            self.labelsWidth = labelsWidth + CGFloat(views.count - 1) * Self.spacing
            trackWidth = slider.widthAnchor.constraint(equalToConstant: DashboardMenuBarPage.widthAdjustmentSliderWidth)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            var previous: NSView?
            var constraints: [NSLayoutConstraint] = []
            for view in views {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
                constraints.append(contentsOf: [
                    view.centerYAnchor.constraint(equalTo: centerYAnchor),
                    view.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
                    view.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
                    heightAnchor.constraint(greaterThanOrEqualTo: view.heightAnchor)
                ])
                if let previous {
                    constraints.append(
                        view.leadingAnchor.constraint(
                            equalTo: previous.trailingAnchor,
                            constant: Self.spacing
                        )
                    )
                } else {
                    constraints.append(view.leadingAnchor.constraint(equalTo: leadingAnchor))
                }
                previous = view
            }
            if let previous {
                constraints.append(previous.trailingAnchor.constraint(equalTo: trailingAnchor))
            }
            NSLayoutConstraint.activate(constraints + [trackWidth])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var alignmentRectInsets: NSEdgeInsets { .init() }

        override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }

        override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }

        func updateAvailableRowWidth(_ width: CGFloat) {
            guard width > 0 else { return }
            let fittingWidth = min(DashboardMenuBarPage.widthAdjustmentSliderWidth, max(1, floor(width - labelsWidth)))
            if trackWidth.constant != fittingWidth { trackWidth.constant = fittingWidth }
        }

        var naturalAccessoryWidth: CGFloat { labelsWidth + trackWidth.constant }
    }

    private struct SliderEndpointWidths {
        let minimum: CGFloat
        let maximum: CGFloat
    }

    private struct CenteredSliderControls {
        let view: NSView
        let slider: NSSlider
    }

    private struct FontPresetControls {
        let view: NSView
        let control: NSPopUpButton
    }

    private weak var resetPositionButton: NSButton?
    private var iconOffsetSummaryLabel: NSTextField?
    private var amountOffsetSummaryLabel: NSTextField?
    private var widthAdjustmentSummaryLabel: NSTextField?
    private weak var iconOffsetSlider: NSSlider?
    private weak var amountOffsetSlider: NSSlider?
    private weak var widthAdjustmentSlider: NSSlider?
    private weak var fontSizePresetControl: NSPopUpButton?
    private weak var iconSizePresetControl: NSPopUpButton?
    private var fontSizePresetTrackingObserver: NSObjectProtocol?
    private var iconSizePresetTrackingObserver: NSObjectProtocol?

    deinit {
        removeFontSizePresetTrackingObserver()
        removeIconSizePresetTrackingObserver()
    }

    func teardown() {
        removeFontSizePresetTrackingObserver()
        removeIconSizePresetTrackingObserver()
    }

    func make(
        input: DashboardMenuBarPage.Input,
        transientWidthAdjustment: Double?
    ) -> [NSView] {
        removeFontSizePresetTrackingObserver()
        removeIconSizePresetTrackingObserver()
        let widthAdjustment = transientWidthAdjustment ?? input.preferences.menuBarStatusItemWidthAdjustment
        let iconOffsetSummary = Self.makeValueLabel(input.preferences.menuBarIconOffsetY, identifier: DashboardMenuBarPage.iconOffsetSummaryIdentifier)
        let amountOffsetSummary = Self.makeValueLabel(input.preferences.menuBarAmountOffsetY, identifier: DashboardMenuBarPage.amountOffsetSummaryIdentifier)
        let widthAdjustmentSummary = Self.makeValueLabel(widthAdjustment, identifier: DashboardMenuBarPage.widthAdjustmentSummaryIdentifier)
        let minimumOffsetTitle = tr(.keyDashboardMenuBarPageDown)
        let maximumOffsetTitle = tr(.keyDashboardMenuBarPageUp)
        let minimumAmountOffsetTitle = tr(.keyDashboardMenuBarPageDown2)
        let maximumAmountOffsetTitle = tr(.keyDashboardMenuBarPageUp2)
        let minimumWidthTitle = tr(.keyDashboardMenuBarPageNarrow)
        let maximumWidthTitle = tr(.keyDashboardMenuBarPageWide)
        let sliderEndpointWidths = Self.sliderEndpointWidths(
            minimumTitles: [minimumOffsetTitle, minimumAmountOffsetTitle, minimumWidthTitle],
            maximumTitles: [maximumOffsetTitle, maximumAmountOffsetTitle, maximumWidthTitle]
        )
        let iconOffsetControls = makeCenteredSliderControls(
            value: input.preferences.menuBarIconOffsetY,
            key: AppPreferences.menuBarIconOffsetYKey,
            range: AppPreferences.menuBarOffsetRange,
            minimumTitle: minimumOffsetTitle,
            maximumTitle: maximumOffsetTitle,
            minimumIdentifier: DashboardMenuBarPage.iconOffsetSliderMinimumIdentifier,
            maximumIdentifier: DashboardMenuBarPage.iconOffsetSliderMaximumIdentifier,
            tooltip: tr(.keyDashboardMenuBarPageAdjustsVerticalPositionFrom100PtDownTo100PtUpDefault0Pt),
            endpointWidths: sliderEndpointWidths,
            valueLabel: iconOffsetSummary,
            relay: input.relay
        )
        let amountOffsetControls = makeCenteredSliderControls(
            value: input.preferences.menuBarAmountOffsetY,
            key: AppPreferences.menuBarAmountOffsetYKey,
            range: AppPreferences.menuBarOffsetRange,
            minimumTitle: minimumAmountOffsetTitle,
            maximumTitle: maximumAmountOffsetTitle,
            minimumIdentifier: DashboardMenuBarPage.amountOffsetSliderMinimumIdentifier,
            maximumIdentifier: DashboardMenuBarPage.amountOffsetSliderMaximumIdentifier,
            tooltip: tr(.keyDashboardMenuBarPageAdjustsVerticalPositionFrom100PtDownTo100PtUpDefault0Pt2),
            endpointWidths: sliderEndpointWidths,
            valueLabel: amountOffsetSummary,
            relay: input.relay
        )
        let widthAdjustmentControls = makeWidthSliderControls(
            value: widthAdjustment,
            key: AppPreferences.menuBarStatusItemWidthAdjustmentKey,
            endpointWidths: sliderEndpointWidths,
            valueLabel: widthAdjustmentSummary,
            relay: input.relay
        )
        let fontSizePreset = input.preferences.menuBarFontSizePreset
        let fontSizeControls = makeFontSizePresetControls(
            value: fontSizePreset,
            relay: input.relay
        )
        let iconSizePreset = input.preferences.menuBarIconSizePreset
        let iconSizeControls = makeIconSizePresetControls(
            value: iconSizePreset,
            relay: input.relay
        )
        iconOffsetSummaryLabel = iconOffsetSummary
        amountOffsetSummaryLabel = amountOffsetSummary
        widthAdjustmentSummaryLabel = widthAdjustmentSummary
        iconOffsetSlider = iconOffsetControls.slider
        amountOffsetSlider = amountOffsetControls.slider
        widthAdjustmentSlider = widthAdjustmentControls.slider
        fontSizePresetControl = fontSizeControls.control
        iconSizePresetControl = iconSizeControls.control
        observeFontSizePresetTracking(
            for: fontSizeControls.control,
            preferences: input.preferences
        )
        observeIconSizePresetTracking(
            for: iconSizeControls.control,
            preferences: input.preferences
        )
        let layout = SettingsSectionView(
            title: tr(.keyDashboardMenuBarPageLayout),
            contentViews: [
                SettingsRowView(
                    title: tr(.keyDashboardMenuBarPageMenuBarFontSize),
                    detail: tr(.keyDashboardMenuBarPageAdjustsTheMenuBarFontSize),
                    accessoryView: fontSizeControls.view,
                    minimumHeight: 66
                ),
                SettingsRowView(
                    title: tr(.keyDashboardMenuBarPageMenuBarIconSize),
                    detail: tr(.keyDashboardMenuBarPageAdjustsTheMenuBarIconSize),
                    accessoryView: iconSizeControls.view,
                    minimumHeight: 66
                )
            ]
        )
        let reset = NSButton(
            title: tr(.keyCommonRestoreDefaults), target: input.relay,
            action: #selector(DashboardPreferencePageRelay.resetOffset(_:))
        )
        reset.bezelStyle = .rounded
        reset.controlSize = .regular
        reset.identifier = NSUserInterfaceItemIdentifier(DashboardMenuBarPage.positionResetIdentifier)
        resetPositionButton = reset
        let position = SettingsSectionView(
            title: tr(.keyDashboardMenuBarPositionAdjustments),
            contentViews: [
                SettingsRowView(
                    title: tr(.keyDashboardMenuBarPageIconOffset),
                    detail: tr(.keyDashboardMenuBarIconVerticalPositionDetail),
                    accessoryView: iconOffsetControls.view,
                    minimumHeight: 66
                ),
                SettingsRowView(
                    title: tr(.keyDashboardMenuBarPageAmountOffset),
                    detail: tr(.keyDashboardMenuBarAmountVerticalPositionDetail),
                    accessoryView: amountOffsetControls.view,
                    minimumHeight: 66
                ),
                SettingsRowView(
                    title: tr(.keyDashboardMenuBarPageMenuBarWidth),
                    detail: tr(.keyDashboardMenuBarItemSpacingDetail),
                    accessoryView: widthAdjustmentControls.view,
                    minimumHeight: 66
                )
            ],
            headerAccessory: reset
        )
        applyWidthAdjustment(widthAdjustment, synchronizeSlider: false)
        return [layout, position]
    }

    func refresh(
        preferences: AppPreferences,
        widthAdjustment: Double,
        synchronizeWidthSlider: Bool
    ) {
        let fontSizePreset = preferences.menuBarFontSizePreset
        let iconSizePreset = preferences.menuBarIconSizePreset
        let iconOffsetY = preferences.menuBarIconOffsetY
        let amountOffsetY = preferences.menuBarAmountOffsetY
        iconOffsetSummaryLabel?.stringValue = Self.signedPointText(iconOffsetY)
        amountOffsetSummaryLabel?.stringValue = Self.signedPointText(amountOffsetY)
        iconOffsetSlider?.doubleValue = iconOffsetY
        amountOffsetSlider?.doubleValue = amountOffsetY
        iconOffsetSlider.flatMap(SettingsRowView.enclosing)?.setDependencyEnabled(preferences.showMenuBarIcon)
        amountOffsetSlider.flatMap(SettingsRowView.enclosing)?.setDependencyEnabled(preferences.showMenuBarAmount)
        if let fontSizePresetControl {
            if fontSizePresetControl.indexOfSelectedItem != fontSizePreset.segmentIndex {
                fontSizePresetControl.selectItem(at: fontSizePreset.segmentIndex)
            }
            updateFontSizePresetMenuItemStates(
                fontSizePresetControl,
                selectedIndex: fontSizePreset.segmentIndex
            )
        }
        fontSizePresetControl.flatMap(SettingsRowView.enclosing)?.setDependencyEnabled(preferences.showMenuBarAmount)
        if let iconSizePresetControl {
            if iconSizePresetControl.indexOfSelectedItem != iconSizePreset.segmentIndex {
                iconSizePresetControl.selectItem(at: iconSizePreset.segmentIndex)
            }
            updateIconSizePresetMenuItemStates(
                iconSizePresetControl,
                selectedIndex: iconSizePreset.segmentIndex
            )
        }
        iconSizePresetControl.flatMap(SettingsRowView.enclosing)?.setDependencyEnabled(preferences.showMenuBarIcon)
        applyWidthAdjustment(widthAdjustment, synchronizeSlider: synchronizeWidthSlider)
    }

    func applyWidthAdjustment(
        _ widthAdjustment: Double,
        synchronizeSlider: Bool
    ) {
        let value = Self.signedPointText(widthAdjustment)
        if widthAdjustmentSummaryLabel?.stringValue != value { widthAdjustmentSummaryLabel?.stringValue = value }
        if synchronizeSlider {
            widthAdjustmentSlider?.doubleValue = widthAdjustment
        }
        resetPositionButton?.isEnabled = iconOffsetSlider?.doubleValue != 0
            || amountOffsetSlider?.doubleValue != 0 || widthAdjustment != 0
    }

    /// Every slider row uses the same endpoint slots for the current
    /// localization. The width row has longer Japanese endpoints than the
    /// offset rows; measuring each control group independently would move its
    /// slider track horizontally. Deriving shared slots from the localized
    /// titles keeps all tracks aligned without a language-specific branch and
    /// lets new translated endpoint titles participate automatically.
    private static func sliderEndpointWidths(
        minimumTitles: [String],
        maximumTitles: [String]
    ) -> SliderEndpointWidths {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11)
        ]
        func width(of title: String) -> CGFloat {
            ceil(NSString(string: title).size(withAttributes: attributes).width)
        }
        return SliderEndpointWidths(
            minimum: minimumTitles.map(width).max() ?? 0,
            maximum: maximumTitles.map(width).max() ?? 0
        )
    }

    static func signedPointText(_ value: Double) -> String {
        let magnitude = String(format: "%.1f", abs(value))
        let sign = magnitude == "0.0" ? "" : value < 0 ? "−" : "+"
        return "\(sign)\(magnitude) pt"
    }

    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let valueWidth: CGFloat = {
        let offset = AppPreferences.menuBarOffsetRange
        let spacing = AppPreferences.menuBarStatusItemWidthAdjustmentRange
        let candidates = [offset.lowerBound, offset.upperBound, spacing.lowerBound, spacing.upperBound, 0]
        return candidates.map {
            ceil(NSAttributedString(string: signedPointText($0), attributes: [.font: valueFont]).size().width) + 4
        }.max() ?? 0
    }()

    private static func makeValueLabel(_ value: Double, identifier: String) -> NSTextField {
        let label = NSTextField(labelWithString: signedPointText(value))
        label.identifier = NSUserInterfaceItemIdentifier(identifier)
        label.font = valueFont
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: valueWidth).isActive = true
        return label
    }

    private func makeFontSizePresetControls(
        value: MenuBarFontSizePreset,
        relay: DashboardPreferencePageRelay
    ) -> FontPresetControls {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: DashboardMenuBarPage.fontSizePresetIdentifier,
            items: MenuBarFontSizePreset.allCases.map { preset in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.fontSizePresetLabel(preset),
                    representedObject: preset.rawValue
                )
            },
            selectedIndex: value.segmentIndex,
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarFontSizePreset(_:))
        )
        control.toolTip = tr(.keyDashboardMenuBarPageLarge1310PtMedium1179PtSmall1048Pt)
        control.widthAnchor.constraint(
            equalToConstant: DashboardMenuBarPage.fontSizePresetWidth
        ).isActive = true
        return FontPresetControls(view: control, control: control)
    }

    private func makeIconSizePresetControls(
        value: MenuBarIconSizePreset,
        relay: DashboardPreferencePageRelay
    ) -> FontPresetControls {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: DashboardMenuBarPage.iconSizePresetIdentifier,
            items: MenuBarIconSizePreset.allCases.map { preset in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.iconSizePresetLabel(preset),
                    representedObject: preset.rawValue
                )
            },
            selectedIndex: value.segmentIndex,
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarIconSizePreset(_:))
        )
        control.toolTip = tr(.keyDashboardMenuBarPageLarge20PtMedium18PtSmall16Pt)
        control.widthAnchor.constraint(
            equalToConstant: DashboardMenuBarPage.iconSizePresetWidth
        ).isActive = true
        return FontPresetControls(view: control, control: control)
    }

    private func observeFontSizePresetTracking(
        for control: NSPopUpButton,
        preferences: AppPreferences
    ) {
        guard let menu = control.menu else { return }
        fontSizePresetTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: menu,
            queue: .main
        ) { [weak self, weak control, weak preferences] _ in
            guard let self, let control, let preferences else { return }
            self.reconcileFontSizePresetControl(control, preferences: preferences)
        }
    }

    private func reconcileFontSizePresetControl(
        _ control: NSPopUpButton,
        preferences: AppPreferences
    ) {
        let preset = preferences.menuBarFontSizePreset
        control.selectItem(at: preset.segmentIndex)
        control.synchronizeTitleAndSelectedItem()
        updateFontSizePresetMenuItemStates(control, selectedIndex: preset.segmentIndex)
    }

    private func updateFontSizePresetMenuItemStates(
        _ control: NSPopUpButton,
        selectedIndex: Int
    ) {
        for (index, item) in control.itemArray.enumerated() {
            item.state = index == selectedIndex ? .on : .off
        }
    }

    private func removeFontSizePresetTrackingObserver() {
        if let fontSizePresetTrackingObserver {
            NotificationCenter.default.removeObserver(fontSizePresetTrackingObserver)
            self.fontSizePresetTrackingObserver = nil
        }
    }

    private func observeIconSizePresetTracking(
        for control: NSPopUpButton,
        preferences: AppPreferences
    ) {
        guard let menu = control.menu else { return }
        iconSizePresetTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: menu,
            queue: .main
        ) { [weak self, weak control, weak preferences] _ in
            guard let self, let control, let preferences else { return }
            self.reconcileIconSizePresetControl(control, preferences: preferences)
        }
    }

    private func reconcileIconSizePresetControl(
        _ control: NSPopUpButton,
        preferences: AppPreferences
    ) {
        let preset = preferences.menuBarIconSizePreset
        control.selectItem(at: preset.segmentIndex)
        control.synchronizeTitleAndSelectedItem()
        updateIconSizePresetMenuItemStates(control, selectedIndex: preset.segmentIndex)
    }

    private func updateIconSizePresetMenuItemStates(
        _ control: NSPopUpButton,
        selectedIndex: Int
    ) {
        for (index, item) in control.itemArray.enumerated() {
            item.state = index == selectedIndex ? .on : .off
        }
    }

    private func removeIconSizePresetTrackingObserver() {
        if let iconSizePresetTrackingObserver {
            NotificationCenter.default.removeObserver(iconSizePresetTrackingObserver)
            self.iconSizePresetTrackingObserver = nil
        }
    }

    private static func fontSizePresetLabel(_ preset: MenuBarFontSizePreset) -> String {
        switch preset {
        case .large: return tr(.keyDashboardMenuBarPageLarge)
        case .medium: return tr(.keyDashboardMenuBarPageMedium)
        case .small: return tr(.keyDashboardMenuBarPageSmall)
        }
    }

    private static func iconSizePresetLabel(_ preset: MenuBarIconSizePreset) -> String {
        switch preset {
        case .large: return tr(.keyDashboardMenuBarPageLarge)
        case .medium: return tr(.keyDashboardMenuBarPageMedium)
        case .small: return tr(.keyDashboardMenuBarPageSmall)
        }
    }

    private func makeWidthSliderControls(
        value: Double,
        key: String,
        endpointWidths: SliderEndpointWidths,
        valueLabel: NSTextField,
        relay: DashboardPreferencePageRelay
    ) -> CenteredSliderControls {
        makeCenteredSliderControls(
            value: value,
            key: key,
            range: AppPreferences.menuBarStatusItemWidthAdjustmentRange,
            minimumTitle: tr(.keyDashboardMenuBarPageNarrow),
            maximumTitle: tr(.keyDashboardMenuBarPageWide),
            minimumIdentifier: DashboardMenuBarPage.widthAdjustmentSliderMinimumIdentifier,
            maximumIdentifier: DashboardMenuBarPage.widthAdjustmentSliderMaximumIdentifier,
            tooltip: tr(.keyDashboardMenuBarPageAdjustsMenuBarWidthFrom100PtNarrowTo100PtWideDefault0Pt),
            endpointWidths: endpointWidths,
            valueLabel: valueLabel,
            relay: relay
        )
    }

    private func makeCenteredSliderControls(
        value: Double,
        key: String,
        range: ClosedRange<Double>,
        minimumTitle: String,
        maximumTitle: String,
        minimumIdentifier: String,
        maximumIdentifier: String,
        tooltip: String,
        endpointWidths: SliderEndpointWidths,
        valueLabel: NSTextField,
        relay: DashboardPreferencePageRelay
    ) -> CenteredSliderControls {
        let slider = MenuBarWidthSlider()
        slider.identifier = NSUserInterfaceItemIdentifier(key)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if #available(macOS 26.0, *) {
            slider.neutralValue = 0
            slider.tintProminence = .primary
        }
        slider.trackFillColor = .controlAccentColor
        slider.doubleValue = value
        slider.isContinuous = true
        slider.numberOfTickMarks = 21
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = false
        slider.target = relay
        slider.action = #selector(DashboardPreferencePageRelay.adjustOffsetValue(_:))
        slider.toolTip = tooltip
        slider.onEditingEnded = { [weak relay, weak slider] in
            guard let relay, let slider else { return }
            relay.finishOffsetValue(slider)
        }

        let minimumLabel = makeWidthSliderEndpointLabel(
            minimumTitle,
            identifier: minimumIdentifier,
            width: endpointWidths.minimum,
            alignment: AppLanguage.resolved == .english ? .left : .center
        )
        let maximumLabel = makeWidthSliderEndpointLabel(
            maximumTitle,
            identifier: maximumIdentifier,
            width: endpointWidths.maximum,
            alignment: AppLanguage.resolved == .english ? .right : .center
        )
        let controls = MenuBarSliderControls(
            views: [minimumLabel, slider, maximumLabel, valueLabel],
            slider: slider,
            labelsWidth: endpointWidths.minimum + endpointWidths.maximum + Self.valueWidth
        )
        controls.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return CenteredSliderControls(view: controls, slider: slider)
    }

    private func makeWidthSliderEndpointLabel(
        _ title: String,
        identifier: String,
        width: CGFloat?,
        alignment: NSTextAlignment
    ) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.identifier = NSUserInterfaceItemIdentifier(identifier)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = alignment
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let width {
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return label
    }
}
