import AppKit

/// Font, icon size, offset, and spacing controls for the Menu Bar page.
final class DashboardMenuBarLayoutSection {
    /// Slider groups have a stable natural width, but their labels should
    /// move below the row text when the Menu Bar page becomes narrow. The
    /// native settings row owns that placement decision through this contract.
    ///
    /// This is a plain `NSView` host so the native row can bounds-center the
    /// group. `NSStackView` derives `alignmentRect(forFrame:)` from arranged
    /// subviews and ignores `alignmentRectInsets`, which on CI macOS 26 showed
    /// up as `slider.midY` 39 vs row `midY` 38. The inner stack also reports
    /// identity alignment and is edge-pinned so Auto Layout `centerYAnchor`
    /// cannot reintroduce that inset. The legacy settings row pinned
    /// `control.centerY` with bounds anchors.
    private final class MenuBarSliderControls: NSView, DashboardSettingsRowControlLayout {
        let allowsTextDrivenDedicatedRow = true
        let minimumInlineLabelWidth = SettingsRowView.minimumInlineLabelWidth
        private(set) var stacksControlsVertically = false
        private let stack: InnerStack

        private final class InnerStack: NSStackView {
            override var alignmentRectInsets: NSEdgeInsets { .init() }

            override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }

            override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }
        }

        init(views: [NSView]) {
            stack = InnerStack(views: views)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var alignmentRectInsets: NSEdgeInsets { .init() }

        override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }

        override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }

        func updateAvailableRowWidth(_ width: CGFloat) {
            // The slider itself keeps its fixed track width. The row moves the
            // complete group below the labels when the remaining inline text
            // column would become too narrow.
            _ = width
        }

        var naturalAccessoryWidth: CGFloat {
            let visible = stack.arrangedSubviews.filter { !$0.isHidden }
            return visible.reduce(CGFloat(0)) { total, view in
                total + max(0, view.fittingSize.width)
            } + max(0, CGFloat(visible.count - 1)) * stack.spacing
        }
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
    ) -> NSView {
        removeFontSizePresetTrackingObserver()
        removeIconSizePresetTrackingObserver()
        let iconOffsetSummaryContent = Self.iconOffsetSummarySubtitle(
            y: input.preferences.menuBarIconOffsetY
        )
        let iconOffsetSummary = DashboardSettingsComponents.makeSubtitleLabel(
            iconOffsetSummaryContent
        )
        iconOffsetSummary.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.iconOffsetSummaryIdentifier
        )
        let amountOffsetSummaryContent = Self.amountOffsetSummarySubtitle(
            y: input.preferences.menuBarAmountOffsetY
        )
        let amountOffsetSummary = DashboardSettingsComponents.makeSubtitleLabel(
            amountOffsetSummaryContent
        )
        amountOffsetSummary.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.amountOffsetSummaryIdentifier
        )
        let widthAdjustment = transientWidthAdjustment
            ?? input.preferences.menuBarStatusItemWidthAdjustment
        let widthAdjustmentSummaryContent = Self.widthAdjustmentSummarySubtitle(widthAdjustment)
        let widthAdjustmentSummary = DashboardSettingsComponents.makeSubtitleLabel(
            widthAdjustmentSummaryContent
        )
        widthAdjustmentSummary.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.widthAdjustmentSummaryIdentifier
        )
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
            relay: input.relay
        )
        let widthAdjustmentControls = makeWidthSliderControls(
            value: widthAdjustment,
            key: AppPreferences.menuBarStatusItemWidthAdjustmentKey,
            endpointWidths: sliderEndpointWidths,
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
        return SettingsSectionView(
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
                ),
                SettingsRowView(
                    title: tr(.keyDashboardMenuBarPageIconOffset),
                    detail: iconOffsetSummaryContent.text,
                    detailLabel: iconOffsetSummary,
                    accessoryView: iconOffsetControls.view,
                    minimumHeight: 66
                ),
                SettingsRowView(
                    title: tr(.keyDashboardMenuBarPageAmountOffset),
                    detail: amountOffsetSummaryContent.text,
                    detailLabel: amountOffsetSummary,
                    accessoryView: amountOffsetControls.view,
                    minimumHeight: 66
                ),
                SettingsRowView(
                    title: tr(.keyDashboardMenuBarPageMenuBarWidth),
                    detail: widthAdjustmentSummaryContent.text,
                    detailLabel: widthAdjustmentSummary,
                    accessoryView: widthAdjustmentControls.view,
                    minimumHeight: 66
                )
            ]
        )
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
        DashboardSettingsComponents.updateSubtitleLabel(
            iconOffsetSummaryLabel,
            with: Self.iconOffsetSummarySubtitle(y: iconOffsetY)
        )
        DashboardSettingsComponents.updateSubtitleLabel(
            amountOffsetSummaryLabel,
            with: Self.amountOffsetSummarySubtitle(y: amountOffsetY)
        )
        iconOffsetSlider?.doubleValue = iconOffsetY
        amountOffsetSlider?.doubleValue = amountOffsetY
        iconOffsetSlider?.isEnabled = preferences.showMenuBarIcon
        amountOffsetSlider?.isEnabled = preferences.showMenuBarAmount
        if let fontSizePresetControl {
            if fontSizePresetControl.indexOfSelectedItem != fontSizePreset.segmentIndex {
                fontSizePresetControl.selectItem(at: fontSizePreset.segmentIndex)
            }
            updateFontSizePresetMenuItemStates(
                fontSizePresetControl,
                selectedIndex: fontSizePreset.segmentIndex
            )
        }
        fontSizePresetControl?.isEnabled = preferences.showMenuBarAmount
        if let iconSizePresetControl {
            if iconSizePresetControl.indexOfSelectedItem != iconSizePreset.segmentIndex {
                iconSizePresetControl.selectItem(at: iconSizePreset.segmentIndex)
            }
            updateIconSizePresetMenuItemStates(
                iconSizePresetControl,
                selectedIndex: iconSizePreset.segmentIndex
            )
        }
        iconSizePresetControl?.isEnabled = preferences.showMenuBarIcon
        applyWidthAdjustment(widthAdjustment, synchronizeSlider: synchronizeWidthSlider)
    }

    func applyWidthAdjustment(
        _ widthAdjustment: Double,
        synchronizeSlider: Bool
    ) {
        DashboardSettingsComponents.updateSubtitleLabel(
            widthAdjustmentSummaryLabel,
            with: Self.widthAdjustmentSummarySubtitle(widthAdjustment)
        )
        if synchronizeSlider {
            widthAdjustmentSlider?.doubleValue = widthAdjustment
        }
        widthAdjustmentSlider?.isEnabled = true
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

    private static func signedPointText(_ value: Double) -> String {
        let sign = value < 0 ? "-" : "+"
        // Keep the signed value as one layout word. AppKit's normal word
        // wrapping can otherwise leave a trailing `0.0 pt` fragment on the
        // next line while the localized descriptor/value group remains on the
        // previous line. Non-breaking spaces
        // are visually identical to ordinary spaces, but make the complete
        // descriptor/value group move together at narrow widths.
        let nonBreakingSpace = "\u{00A0}"
        return "\(nonBreakingSpace)\(sign)\(nonBreakingSpace)\(String(format: "%.1f", abs(value)))\(nonBreakingSpace)pt"
    }

    private static func iconOffsetSummarySubtitle(y: Double) -> LocalizedSubtitle {
        trSubtitle(
            .keyDashboardMenuBarPageFineTuneTheIconSVerticalPositionYaxisvalue,
            arguments: [signedPointText(y)]
        )
    }

    private static func amountOffsetSummarySubtitle(y: Double) -> LocalizedSubtitle {
        trSubtitle(
            .keyDashboardMenuBarPageFineTuneTheAmountSVerticalPositionYaxisvalue,
            arguments: [signedPointText(y)]
        )
    }

    private static func widthAdjustmentSummarySubtitle(_ value: Double) -> LocalizedSubtitle {
        trSubtitle(
            .keyDashboardMenuBarPageAdjustsTheGapBetweenBalancebarAndOtherItemsWidthvalue,
            arguments: [signedPointText(value)]
        )
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
        slider.widthAnchor.constraint(
            equalToConstant: DashboardMenuBarPage.widthAdjustmentSliderWidth
        ).isActive = true

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
        let controls = MenuBarSliderControls(views: [minimumLabel, slider, maximumLabel])
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
