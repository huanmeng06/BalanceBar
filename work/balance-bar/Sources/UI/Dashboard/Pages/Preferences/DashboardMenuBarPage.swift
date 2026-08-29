import AppKit

/// Pure delay/interval policy for long-press auto-repeat of the fine-tune
/// direction buttons. Press-and-hold starts stepping after `initialDelay`,
/// then repeats every `initialInterval`, accelerating by `accelerationFactor`
/// per step and floored at `minimumInterval`.
struct MenuBarOffsetRepeatPolicy: Equatable {
    static let standard = MenuBarOffsetRepeatPolicy(
        initialDelay: 0.35,
        initialInterval: 0.1,
        accelerationFactor: 0.9,
        minimumInterval: 0.03
    )

    let initialDelay: TimeInterval
    let initialInterval: TimeInterval
    let accelerationFactor: Double
    let minimumInterval: TimeInterval

    /// Interval before the `step`-th repeat fires. `step == 0` is the initial
    /// press-and-hold delay before auto-repeat starts.
    func interval(afterStep step: Int) -> TimeInterval {
        guard step > 0 else { return initialDelay }
        let multiplier = pow(accelerationFactor, Double(step - 1))
        return max(minimumInterval, initialInterval * multiplier)
    }
}

/// Drives auto-repeat steps after a press-and-hold. Fires `onStep` once after
/// the policy's initial delay, then repeatedly at policy intervals on the main
/// run loop until stopped.
final class MenuBarOffsetRepeatDriver {
    private let policy: MenuBarOffsetRepeatPolicy
    private let onStep: () -> Void
    private var delayWorkItem: DispatchWorkItem?
    private var repeatTimer: Timer?
    private var stepCount = 0

    init(policy: MenuBarOffsetRepeatPolicy, onStep: @escaping () -> Void) {
        self.policy = policy
        self.onStep = onStep
    }

    var isRunning: Bool { delayWorkItem != nil || repeatTimer != nil }

    func start() {
        stop()
        stepCount = 0
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performStep()
            self.scheduleNext()
        }
        delayWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + policy.initialDelay,
            execute: item
        )
    }

    func stop() {
        delayWorkItem?.cancel()
        delayWorkItem = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func performStep() {
        stepCount += 1
        onStep()
    }

    private func scheduleNext() {
        let interval = policy.interval(afterStep: stepCount)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.performStep()
            self.scheduleNext()
        }
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Direction button that auto-repeats while pressed and held. A short press
/// fires the action exactly once; holding past the policy delay starts
/// repeating the action at policy intervals. Releasing, dragging outside the
/// button, or the window losing key status stops the repeat immediately.
final class RepeatOffsetButton: NSButton {
    private enum PressPhase {
        case idle
        case waiting
        case repeating
    }

    private let policy: MenuBarOffsetRepeatPolicy
    private lazy var driver = MenuBarOffsetRepeatDriver(policy: policy) { [weak self] in
        guard let self,
              self.pressPhase == .waiting || self.pressPhase == .repeating else {
            return
        }
        if self.pressPhase == .waiting {
            self.pressPhase = .repeating
        }
        _ = self.sendAction(self.action, to: self.target)
    }
    private var pressPhase: PressPhase = .idle
    private var resignObserver: NSObjectProtocol?
    private var driverWasUsed = false

    init(
        title: String,
        policy: MenuBarOffsetRepeatPolicy,
        target: AnyObject?,
        action: Selector?
    ) {
        self.policy = policy
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if driverWasUsed {
            driver.stop()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isHighlighted = true
        pressPhase = .waiting
        driverWasUsed = true
        observeWindowResignIfNeeded()
        driver.start()
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressPhase != .idle else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !bounds.contains(point) {
            isHighlighted = false
            stopPress(removeObserver: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressPhase != .idle else { return }
        let wasRepeating = pressPhase == .repeating
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isHighlighted = false
        stopPress(removeObserver: true)
        if inside && !wasRepeating {
            _ = sendAction(action, to: target)
        }
    }

    private func observeWindowResignIfNeeded() {
        guard resignObserver == nil, let window else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.stopPress(removeObserver: true)
        }
    }

    private func stopPress(removeObserver: Bool) {
        isHighlighted = false
        pressPhase = .idle
        if driverWasUsed {
            driver.stop()
        }
        if removeObserver, let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}

final class MenuBarWidthSlider: NSSlider {
    var onEditingEnded: (() -> Void)?

    private var isPointerTracking = false
    private var lastPointerValue: Double?

    static func integerValuesCrossed(
        from previousValue: Double,
        to currentValue: Double,
        minimum: Double,
        maximum: Double
    ) -> [Int] {
        guard previousValue != currentValue else { return [] }

        let previous = snappedIntegerValue(previousValue)
        let current = snappedIntegerValue(currentValue)
        let first: Int
        let last: Int

        if current > previous {
            // Include an integer when arriving at it, but not when leaving
            // an integer that was already reached at the start of the drag.
            first = Int(floor(previous)) + 1
            last = Int(floor(current))
        } else {
            // Reverse the same rule for a leftward drag.
            first = Int(ceil(current))
            last = Int(ceil(previous)) - 1
        }

        let lowerBound = Int(ceil(minimum))
        let upperBound = Int(floor(maximum))
        guard first <= last else { return [] }

        let clampedFirst = max(first, lowerBound)
        let clampedLast = min(last, upperBound)
        guard clampedFirst <= clampedLast else { return [] }

        let values = Array(clampedFirst...clampedLast)
        return current > previous ? values : Array(values.reversed())
    }

    override func mouseDown(with event: NSEvent) {
        isPointerTracking = true
        lastPointerValue = doubleValue
        super.mouseDown(with: event)
        notifyIntegerBoundaryIfNeeded(for: doubleValue)
        isPointerTracking = false
        lastPointerValue = nil
        onEditingEnded?()
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if isPointerTracking {
            notifyIntegerBoundaryIfNeeded(for: doubleValue)
        }
        return super.sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        onEditingEnded?()
    }

    private func notifyIntegerBoundaryIfNeeded(for value: Double) {
        guard let previousValue = lastPointerValue else {
            lastPointerValue = value
            return
        }

        let crossedValues = Self.integerValuesCrossed(
            from: previousValue,
            to: value,
            minimum: minValue,
            maximum: maxValue
        )
        for _ in crossedValues {
            // The system performer silently suppresses this on devices that
            // do not provide Force Touch, such as a regular mouse.
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
        }
        lastPointerValue = value
    }

    private static func snappedIntegerValue(_ value: Double) -> Double {
        let rounded = value.rounded()
        return abs(value - rounded) < 0.000_001 ? rounded : value
    }
}

final class DashboardMenuBarPage {
    static let iconOffsetsResetIdentifier = "menuBarIconOffsetsReset"
    static let amountOffsetsResetIdentifier = "menuBarAmountOffsetsReset"
    static let iconOffsetSummaryIdentifier = "menuBarIconOffsetSummary"
    static let amountOffsetSummaryIdentifier = "menuBarAmountOffsetSummary"
    static let widthAdjustmentSummaryIdentifier = "menuBarStatusItemWidthAdjustmentSummary"
    static let fontSizePresetIdentifier = AppPreferences.menuBarFontSizePresetKey
    static let iconDisplayModeIdentifier = AppPreferences.menuBarIconDisplayModeKey
    static let iconDisplayDelayIdentifier = AppPreferences.menuBarIconDisplayDelayKey
    static let quotaWindowPreferenceIdentifier = AppPreferences.menuBarQuotaWindowPreferenceKey
    static let quotaResetDisplayModeIdentifier = AppPreferences.menuBarQuotaResetDisplayModeKey
    static let autoSwitchLunaReserveIdentifier = AppPreferences.menuBarAutoSwitchLunaReserveKey
    static let lunaReserveResetTimeModeIdentifier = AppPreferences.menuBarLunaReserveResetTimeModeKey
    static let widthAdjustmentSliderMinimumIdentifier = "menuBarStatusItemWidthAdjustmentMinimum"
    static let widthAdjustmentSliderMaximumIdentifier = "menuBarStatusItemWidthAdjustmentMaximum"
    static let iconOffsetSliderMinimumIdentifier = "menuBarIconOffsetSliderMinimum"
    static let iconOffsetSliderMaximumIdentifier = "menuBarIconOffsetSliderMaximum"
    static let amountOffsetSliderMinimumIdentifier = "menuBarAmountOffsetSliderMinimum"
    static let amountOffsetSliderMaximumIdentifier = "menuBarAmountOffsetSliderMaximum"
    static let widthAdjustmentSliderWidth: CGFloat = 140
    private struct SliderEndpointWidths {
        let minimum: CGFloat
        let maximum: CGFloat
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
    // Match the compact native popup used by the Application settings page.
    // Screenshots are commonly captured at 2x scale, so this is 100 points
    // (about 200 pixels), not the previous 180-point control.
    static let fontSizePresetWidth: CGFloat = 100
    /// Extra default lift for the amount text in the Dashboard preview only
    /// (visual, positive = up). The real menu bar layout is unchanged; user
    /// fine-tune offsets stack on top.
    static let previewAmountDefaultYOffset: CGFloat = 0.5
    /// Keep the preview and overflow-warning rows aligned with the standard
    /// settings rows. The preview control itself is 42 pt tall, so 10 pt of
    /// vertical padding on its adaptive row reaches the shared 62 pt height.
    static let previewRowHeight: CGFloat = DashboardSettingsComponents.standardRowHeight
    private static let previewRowVerticalPadding: CGFloat = 10
    static let previewPrimaryIdentifier = "menuBarPreviewPrimary"
    static let previewSecondaryIdentifier = "menuBarPreviewSecondary"
    static let overflowWarningIdentifier = "menuBarOverflowWarning"
    static let overflowWarningRowIdentifier = "menuBarOverflowWarningRow"
    static let overflowWarningSettingsButtonIdentifier = "menuBarOverflowWarningSettingsButton"
    static let systemMenuBarSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"
    )!

    struct Presentation: Equatable {
        let primary: String
        let secondary: String
        let hasSecondary: Bool
        let isBalance: Bool
        let isOfficial: Bool
    }

    static func presentation(
        for snapshot: Snapshot,
        showAmount: Bool,
        showReset: Bool,
        quotaResetDisplayMode: OfficialQuotaResetDisplayMode = .defaultValue,
        lunaReserveResetTimeMode: LunaReserveResetTimeMode = .defaultValue,
        resolving snapshotResolver: (Snapshot) -> Snapshot
    ) -> Presentation {
        let effective = snapshotResolver(snapshot)
        let secondary = effective.kind == .official
            ? effective.menuBarSecondary(
                displayMode: quotaResetDisplayMode,
                lunaReserveResetTimeMode: lunaReserveResetTimeMode
            )
            : ""
        return Presentation(
            primary: showAmount ? effective.menuBarPrimary : "",
            secondary: secondary,
            hasSecondary: showAmount
                && showReset
                && effective.kind == .official
                && !secondary.isEmpty,
            isBalance: effective.kind == .balance,
            isOfficial: effective.kind == .official
        )
    }

    static func overflowWarningText(for language: AppLanguage = .selected) -> String {
        tr(.keyDashboardMenuBarPageMenuBarSpaceIsFullSoBalancebarIsTemporarilyHiddenHideOrRemoveSomeMenuBarIconsAndTryAgain, language: language)
    }

    static func overflowWarningSettingsButtonText(
        for language: AppLanguage = .selected
    ) -> String {
        tr(.keyDashboardMenuBarPageOpenSettings, language: language)
    }

    struct Input {
        let preferences: AppPreferences
        let snapshot: Snapshot
        let menuBarSnapshot: (Snapshot) -> Snapshot
        let statusItemVisibility: StatusItemVisibility
        let iconImage: NSImage?
        let relay: DashboardPreferencePageRelay

        init(
            preferences: AppPreferences,
            snapshot: Snapshot,
            menuBarSnapshot: @escaping (Snapshot) -> Snapshot,
            iconImage: NSImage?,
            relay: DashboardPreferencePageRelay,
            statusItemVisibility: StatusItemVisibility = .unknown
        ) {
            self.preferences = preferences
            self.snapshot = snapshot
            self.menuBarSnapshot = menuBarSnapshot
            self.statusItemVisibility = statusItemVisibility
            self.iconImage = iconImage
            self.relay = relay
        }
    }

    private struct CenteredSliderControls {
        let view: NSView
        let slider: NSSlider
    }

    private struct FontPresetControls {
        let view: NSView
        let control: NSPopUpButton
    }

    private let previewIcon = PassthroughImageView()
    private let previewIconSlot = NSView()
    private let previewText = MenuBarTextView()
    private let previewPrimary = NSTextField(labelWithString: "…")
    private let previewSecondary = NSTextField(labelWithString: "")
    private let previewCapsule = NSView()
    private weak var iconSwitch: NSSwitch?
    private weak var amountSwitch: NSSwitch?
    private weak var previewBackground: NSView?
    private weak var overflowWarningLabel: NSTextField?
    private weak var overflowWarningSettingsButton: NSButton?
    private weak var overflowWarningRow: NSView?
    private weak var previewRowsStack: NSStackView?
    private weak var previewCardHeightConstraint: NSLayoutConstraint?
    private var previewSeparators: [NSView] = []
    private var capsuleLeadingConstraint: NSLayoutConstraint?
    private var capsuleTrailingConstraint: NSLayoutConstraint?
    private var previewWidthConstraint: NSLayoutConstraint?
    private var textWidthConstraint: NSLayoutConstraint?
    private var iconOffsetSummaryLabel: NSTextField?
    private var amountOffsetSummaryLabel: NSTextField?
    private var widthAdjustmentSummaryLabel: NSTextField?
    private weak var iconOffsetSlider: NSSlider?
    private weak var amountOffsetSlider: NSSlider?
    private weak var widthAdjustmentSlider: NSSlider?
    private weak var fontSizePresetControl: NSPopUpButton?
    private weak var iconDisplayModeControl: NSPopUpButton?
    private weak var iconDisplayDelayControl: NSPopUpButton?
    private weak var taskStatusIconRow: NSView?
    private weak var animationRow: NSView?
    private weak var iconDisplayModeRow: NSView?
    private weak var iconDisplayDelayRow: NSView?
    private weak var amountDisplayRow: NSView?
    private weak var resetCountdownRow: NSView?
    private weak var quotaWindowPreferenceRow: NSView?
    private weak var autoSwitchLunaReserveRow: NSView?
    private weak var lunaReserveResetTimeRow: NSView?
    private weak var quotaResetDisplayModeRow: NSView?
    private weak var quotaWindowPreferenceControl: NSPopUpButton?
    private weak var autoSwitchLunaReserveSwitch: NSSwitch?
    private weak var lunaReserveResetTimeModeControl: NSPopUpButton?
    private weak var quotaResetDisplayModeControl: NSPopUpButton?
    private weak var quotaRowsStack: NSStackView?
    private weak var quotaCardHeightConstraint: NSLayoutConstraint?
    private var quotaSeparators: [NSView] = []
    private weak var iconTaskStatusRowsStack: NSStackView?
    private weak var iconTaskStatusCardHeightConstraint: NSLayoutConstraint?
    private var iconTaskStatusSeparators: [NSView] = []
    private var fontSizePresetTrackingObserver: NSObjectProtocol?
    private var transientWidthAdjustment: Double?
    private let chromeInset: CGFloat = 10
    private var isBuilt = false

    deinit {
        removeFontSizePresetTrackingObserver()
    }

    func teardown() {
        removeFontSizePresetTrackingObserver()
    }

    /// Updates only the preview bitmap. Animation frames must not repeat the
    /// full settings-page refresh performed by refresh(...).
    func updatePreviewIcon(_ image: NSImage?) {
        guard isBuilt else { return }
        previewIcon.image = image
    }

    private static func makeOverflowWarningRow(
        label: NSTextField,
        settingsButton: NSButton
    ) -> NSView {
        let row = NSView()
        row.identifier = NSUserInterfaceItemIdentifier(Self.overflowWarningRowIdentifier)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: Self.previewRowHeight).isActive = true
        label.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(settingsButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: settingsButton.leadingAnchor,
                constant: -12
            ),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8),
            settingsButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            settingsButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    func make(_ input: Input) -> NSView {
        removeFontSizePresetTrackingObserver()
        quotaRowsStack = nil
        quotaCardHeightConstraint = nil
        quotaSeparators = []
        iconTaskStatusRowsStack = nil
        iconTaskStatusCardHeightConstraint = nil
        iconTaskStatusSeparators = []
        let previewContent = NSView()
        let preview: NSView
        if let glassPreview = makeDashboardGlassEffectView(contentView: previewContent, cornerRadius: 7) {
            preview = glassPreview
        } else {
            let visualEffectPreview = NSVisualEffectView()
            visualEffectPreview.material = .menu
            visualEffectPreview.state = .active
            visualEffectPreview.wantsLayer = true
            visualEffectPreview.layer?.cornerRadius = 7
            visualEffectPreview.layer?.backgroundColor = dashboardAdaptiveColor(
                light: NSColor.white.withAlphaComponent(0.64),
                dark: NSColor.black.withAlphaComponent(0.18)
            ).cgColor
            visualEffectPreview.layer?.borderColor = dashboardAdaptiveColor(
                light: NSColor.white.withAlphaComponent(0.72),
                dark: NSColor.white.withAlphaComponent(0.08)
            ).cgColor
            visualEffectPreview.layer?.borderWidth = 0.5
            previewContent.translatesAutoresizingMaskIntoConstraints = false
            visualEffectPreview.addSubview(previewContent)
            NSLayoutConstraint.activate([
                previewContent.topAnchor.constraint(equalTo: visualEffectPreview.topAnchor),
                previewContent.leadingAnchor.constraint(equalTo: visualEffectPreview.leadingAnchor),
                previewContent.trailingAnchor.constraint(equalTo: visualEffectPreview.trailingAnchor),
                previewContent.bottomAnchor.constraint(equalTo: visualEffectPreview.bottomAnchor)
            ])
            preview = visualEffectPreview
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        let previewWidthConstraint = preview.widthAnchor.constraint(equalToConstant: 190)
        previewWidthConstraint.isActive = true
        self.previewBackground = preview
        self.previewWidthConstraint = previewWidthConstraint
        previewIcon.imageScaling = .scaleProportionallyDown
        previewIcon.translatesAutoresizingMaskIntoConstraints = false
        previewIcon.wantsLayer = true
        previewIcon.identifier = NSUserInterfaceItemIdentifier("menuBarPreviewIcon")
        previewIcon.widthAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        previewIcon.heightAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        previewPrimary.font = MenuBarLayout.primaryFont
        previewPrimary.textColor = .labelColor
        previewPrimary.identifier = NSUserInterfaceItemIdentifier(Self.previewPrimaryIdentifier)
        previewSecondary.font = MenuBarLayout.secondaryFont
        previewSecondary.textColor = .labelColor
        previewSecondary.identifier = NSUserInterfaceItemIdentifier(Self.previewSecondaryIdentifier)
        previewText.addSubview(previewPrimary)
        previewText.addSubview(previewSecondary)
        previewText.wantsLayer = true
        previewText.identifier = NSUserInterfaceItemIdentifier("menuBarPreviewText")
        previewText.layer?.setAffineTransform(.identity)
        let previewTextWidth = previewText.widthAnchor.constraint(equalToConstant: 32)
        previewTextWidth.priority = .defaultHigh
        previewTextWidth.isActive = true
        textWidthConstraint = previewTextWidth
        previewIconSlot.translatesAutoresizingMaskIntoConstraints = false
        previewIconSlot.widthAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        previewIconSlot.heightAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        previewIconSlot.addSubview(previewIcon)
        NSLayoutConstraint.activate([
            previewIcon.centerXAnchor.constraint(equalTo: previewIconSlot.centerXAnchor),
            previewIcon.centerYAnchor.constraint(equalTo: previewIconSlot.centerYAnchor)
        ])
        let previewRow = NSStackView(views: [previewIconSlot, previewText])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = MenuBarLayout.iconTextSpacing
        previewRow.translatesAutoresizingMaskIntoConstraints = false
        previewCapsule.wantsLayer = true
        previewCapsule.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.black.withAlphaComponent(0.08),
            dark: NSColor.white.withAlphaComponent(0.12)
        ).cgColor
        previewCapsule.layer?.borderColor = dashboardAdaptiveColor(
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.white.withAlphaComponent(0.08)
        ).cgColor
        previewCapsule.layer?.borderWidth = 0.5
        previewCapsule.layer?.cornerRadius = 12
        previewCapsule.layer?.masksToBounds = true
        previewCapsule.isHidden = true
        previewCapsule.translatesAutoresizingMaskIntoConstraints = false
        previewContent.addSubview(previewCapsule)
        previewContent.addSubview(previewRow)
        let initialCapsuleInset = Self.previewCapsuleHorizontalInset(
            horizontalPadding: input.preferences.menuBarHorizontalPadding,
            widthAdjustment: input.preferences.menuBarStatusItemWidthAdjustment
                + AppPreferences.menuBarStatusItemWidthBaseline,
            additionalWidth: MenuBarLayout.menuBarStatusItemVisualOverhangX * 2
        )
        let capsuleLeading = previewCapsule.leadingAnchor.constraint(
            equalTo: previewRow.leadingAnchor,
            constant: -initialCapsuleInset
        )
        let capsuleTrailing = previewCapsule.trailingAnchor.constraint(
            equalTo: previewRow.trailingAnchor,
            constant: initialCapsuleInset
        )
        capsuleLeadingConstraint = capsuleLeading
        capsuleTrailingConstraint = capsuleTrailing
        NSLayoutConstraint.activate([
            previewRow.centerXAnchor.constraint(equalTo: previewContent.centerXAnchor),
            previewRow.centerYAnchor.constraint(equalTo: previewContent.centerYAnchor),
            previewRow.leadingAnchor.constraint(greaterThanOrEqualTo: previewContent.leadingAnchor, constant: 14),
            previewRow.trailingAnchor.constraint(lessThanOrEqualTo: previewContent.trailingAnchor, constant: -14),
            capsuleLeading,
            capsuleTrailing,
            previewCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: previewContent.leadingAnchor, constant: 6),
            previewCapsule.trailingAnchor.constraint(lessThanOrEqualTo: previewContent.trailingAnchor, constant: -6),
            previewCapsule.topAnchor.constraint(equalTo: previewRow.topAnchor, constant: -3),
            previewCapsule.bottomAnchor.constraint(equalTo: previewRow.bottomAnchor, constant: 3),
            preview.heightAnchor.constraint(equalToConstant: 42)
        ])
        let iconToggle = DashboardSettingsComponents.makeSwitch(
            identifier: "showMenuBarIcon",
            isOn: input.preferences.showMenuBarIcon,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let amountToggle = DashboardSettingsComponents.makeSwitch(
            identifier: "showMenuBarAmount",
            isOn: input.preferences.showMenuBarAmount,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let resetToggle = DashboardSettingsComponents.makeSwitch(
            identifier: "showMenuBarReset",
            isOn: input.preferences.showMenuBarReset,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let autoSwitchLunaReserve = DashboardSettingsComponents.makeSwitch(
            identifier: Self.autoSwitchLunaReserveIdentifier,
            isOn: input.preferences.menuBarAutoSwitchLunaReserve,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        self.autoSwitchLunaReserveSwitch = autoSwitchLunaReserve
        let quotaWindowPreferenceControl = makeQuotaWindowPreferenceControl(
            value: input.preferences.menuBarQuotaWindowPreference,
            relay: input.relay
        )
        self.quotaWindowPreferenceControl = quotaWindowPreferenceControl
        let lunaReserveResetTimeModeControl = makeLunaReserveResetTimeModeControl(
            value: input.preferences.menuBarLunaReserveResetTimeMode,
            relay: input.relay
        )
        self.lunaReserveResetTimeModeControl = lunaReserveResetTimeModeControl
        let iconDisplayModeControl = makeIconDisplayModeControl(
            value: input.preferences.menuBarIconDisplayMode,
            relay: input.relay
        )
        self.iconDisplayModeControl = iconDisplayModeControl
        let iconDisplayDelayControl = makeIconDisplayDelayControl(
            value: input.preferences.menuBarIconDisplayDelay,
            relay: input.relay
        )
        self.iconDisplayDelayControl = iconDisplayDelayControl
        let quotaResetDisplayModeControl = makeQuotaResetDisplayModeControl(
            value: input.preferences.menuBarQuotaResetDisplayMode,
            relay: input.relay
        )
        self.quotaResetDisplayModeControl = quotaResetDisplayModeControl
        let animationToggle = DashboardSettingsComponents.makeSwitch(
            identifier: "animateCodexActivity",
            isOn: input.preferences.animateCodexActivity,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        iconSwitch = iconToggle
        amountSwitch = amountToggle
        let overflowWarningLabel = NSTextField(
            wrappingLabelWithString: Self.overflowWarningText()
        )
        overflowWarningLabel.identifier = NSUserInterfaceItemIdentifier(
            Self.overflowWarningIdentifier
        )
        overflowWarningLabel.font = .systemFont(ofSize: 12)
        overflowWarningLabel.textColor = .secondaryLabelColor
        overflowWarningLabel.lineBreakMode = .byWordWrapping
        overflowWarningLabel.usesSingleLineMode = false
        overflowWarningLabel.maximumNumberOfLines = 0
        overflowWarningLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let overflowWarningSettingsButton = NSButton(
            title: Self.overflowWarningSettingsButtonText(),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openSystemMenuBarSettings(_:))
        )
        overflowWarningSettingsButton.identifier = NSUserInterfaceItemIdentifier(
            Self.overflowWarningSettingsButtonIdentifier
        )
        overflowWarningSettingsButton.bezelStyle = .rounded
        overflowWarningSettingsButton.controlSize = .regular
        overflowWarningSettingsButton.toolTip = Self.overflowWarningSettingsButtonText()
        overflowWarningSettingsButton.setAccessibilityLabel(
            Self.overflowWarningSettingsButtonText()
        )
        overflowWarningSettingsButton.setContentHuggingPriority(.required, for: .horizontal)
        overflowWarningSettingsButton.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )
        let overflowWarningRow = Self.makeOverflowWarningRow(
            label: overflowWarningLabel,
            settingsButton: overflowWarningSettingsButton
        )
        overflowWarningRow.isHidden = input.statusItemVisibility != .hiddenByMenuBarSpace
        self.overflowWarningLabel = overflowWarningLabel
        self.overflowWarningSettingsButton = overflowWarningSettingsButton
        self.overflowWarningRow = overflowWarningRow
        let quotaWindowPreferenceRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageQuotaDisplayPriority),
            subtitle: tr(.keyDashboardMenuBarPageQuotaDisplayPriorityDescription),
            control: quotaWindowPreferenceControl
        )
        self.quotaWindowPreferenceRow = quotaWindowPreferenceRow
        let autoSwitchLunaReserveRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageAutoSwitchLunaReserve),
            subtitle: tr(.keyDashboardMenuBarPageAutoSwitchLunaReserveDescription),
            control: autoSwitchLunaReserve
        )
        self.autoSwitchLunaReserveRow = autoSwitchLunaReserveRow
        let lunaReserveResetTimeRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageLunaReserveResetTime),
            subtitle: tr(.keyDashboardMenuBarPageLunaReserveResetTimeDescription),
            control: lunaReserveResetTimeModeControl
        )
        self.lunaReserveResetTimeRow = lunaReserveResetTimeRow
        let amountDisplayRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageBalanceAmount),
            subtitle: tr(.keyDashboardMenuBarPageShowsAPercentageOrApiBalance),
            control: amountToggle
        )
        self.amountDisplayRow = amountDisplayRow
        let resetCountdownRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageResetCountdown),
            subtitle: tr(.keyDashboardMenuBarPageOnlyShownWhenOfficialQuotaDataIsAvailable),
            control: resetToggle
        )
        self.resetCountdownRow = resetCountdownRow
        let iconDisplayModeRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageIconDisplayMode),
            subtitle: tr(.keyDashboardMenuBarPageIconDisplayModeDescription),
            control: iconDisplayModeControl
        )
        self.iconDisplayModeRow = iconDisplayModeRow
        let iconDisplayDelayRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageIconDisplayDelay),
            subtitle: tr(.keyDashboardMenuBarPageIconDisplayDelayDescription),
            control: iconDisplayDelayControl
        )
        self.iconDisplayDelayRow = iconDisplayDelayRow
        let quotaResetDisplayModeRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageQuotaResetDisplayMode),
            subtitle: tr(.keyDashboardMenuBarPageQuotaResetDisplayModeDescription),
            control: quotaResetDisplayModeControl
        )
        self.quotaResetDisplayModeRow = quotaResetDisplayModeRow
        let taskStatusIconRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageAgentIcon),
            subtitle: tr(.keyDashboardMenuBarPageShowsTheCurrentTaskStatus),
            control: iconToggle
        )
        self.taskStatusIconRow = taskStatusIconRow
        let animationRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPagePlayTheIconAnimationWhileATaskIsRunning),
            control: animationToggle
        )
        self.animationRow = animationRow
        let previewSection = DashboardSettingsComponents.makeSettingsSection(tr(.keyDashboardMenuBarPagePreview), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardMenuBarPageCurrentLayout),
                subtitle: tr(.keyDashboardMenuBarPageTheMenuBarUpdatesWithProviderDataInRealTime),
                control: preview,
                minimumHeight: Self.previewRowHeight,
                verticalPadding: Self.previewRowVerticalPadding
            ),
            overflowWarningRow
        ], onLayoutCreated: { [weak self] rowsStack, cardHeightConstraint, separators in
            self?.previewRowsStack = rowsStack
            self?.previewCardHeightConstraint = cardHeightConstraint
            self?.previewSeparators = separators
        })
        let quotaAndResetSection = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardMenuBarPageQuotaAndReset),
            rows: [
                amountDisplayRow,
                resetCountdownRow,
                quotaWindowPreferenceRow,
                quotaResetDisplayModeRow,
                autoSwitchLunaReserveRow,
                lunaReserveResetTimeRow
            ],
            onLayoutCreated: { [weak self] rowsStack, cardHeightConstraint, separators in
                self?.quotaRowsStack = rowsStack
                self?.quotaCardHeightConstraint = cardHeightConstraint
                self?.quotaSeparators = separators
                self?.updateQuotaVisibility(
                    showAmount: input.preferences.showMenuBarAmount,
                    showReset: input.preferences.showMenuBarReset,
                    autoSwitchLunaReserve: input.preferences.menuBarAutoSwitchLunaReserve
                )
            }
        )
        let iconAndTaskStatusSection = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardMenuBarPageIconAndTaskStatus),
            rows: [
                taskStatusIconRow,
                animationRow,
                iconDisplayModeRow,
                iconDisplayDelayRow
            ],
            onLayoutCreated: { [weak self] rowsStack, cardHeightConstraint, separators in
                self?.iconTaskStatusRowsStack = rowsStack
                self?.iconTaskStatusCardHeightConstraint = cardHeightConstraint
                self?.iconTaskStatusSeparators = separators
                self?.updateIconAndTaskStatusVisibility(
                    showTaskStatusIcon: input.preferences.showMenuBarIcon,
                    displayMode: input.preferences.menuBarIconDisplayMode
                )
            }
        )
        let iconOffsetSummaryContent = Self.iconOffsetSummarySubtitle(
            y: input.preferences.menuBarIconOffsetY
        )
        let iconOffsetSummary = DashboardSettingsComponents.makeSubtitleLabel(
            iconOffsetSummaryContent
        )
        iconOffsetSummary.identifier = NSUserInterfaceItemIdentifier(Self.iconOffsetSummaryIdentifier)
        let amountOffsetSummaryContent = Self.amountOffsetSummarySubtitle(
            y: input.preferences.menuBarAmountOffsetY
        )
        let amountOffsetSummary = DashboardSettingsComponents.makeSubtitleLabel(
            amountOffsetSummaryContent
        )
        amountOffsetSummary.identifier = NSUserInterfaceItemIdentifier(Self.amountOffsetSummaryIdentifier)
        let widthAdjustment = transientWidthAdjustment
            ?? input.preferences.menuBarStatusItemWidthAdjustment
        let widthAdjustmentSummaryContent = Self.widthAdjustmentSummarySubtitle(widthAdjustment)
        let widthAdjustmentSummary = DashboardSettingsComponents.makeSubtitleLabel(
            widthAdjustmentSummaryContent
        )
        widthAdjustmentSummary.identifier = NSUserInterfaceItemIdentifier(Self.widthAdjustmentSummaryIdentifier)
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
            minimumIdentifier: Self.iconOffsetSliderMinimumIdentifier,
            maximumIdentifier: Self.iconOffsetSliderMaximumIdentifier,
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
            minimumIdentifier: Self.amountOffsetSliderMinimumIdentifier,
            maximumIdentifier: Self.amountOffsetSliderMaximumIdentifier,
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
        iconOffsetSummaryLabel = iconOffsetSummary
        amountOffsetSummaryLabel = amountOffsetSummary
        widthAdjustmentSummaryLabel = widthAdjustmentSummary
        iconOffsetSlider = iconOffsetControls.slider
        amountOffsetSlider = amountOffsetControls.slider
        widthAdjustmentSlider = widthAdjustmentControls.slider
        fontSizePresetControl = fontSizeControls.control
        observeFontSizePresetTracking(
            for: fontSizeControls.control,
            preferences: input.preferences
        )
        let layoutSection = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardMenuBarPageLayout),
            rows: [
                DashboardSettingsComponents.makeSettingsRow(
                    tr(.keyDashboardMenuBarPageMenuBarFontSize),
                    subtitle: tr(.keyDashboardMenuBarPageAdjustsTheMenuBarFontSize),
                    control: fontSizeControls.view,
                    minimumHeight: 66
                ),
                DashboardSettingsComponents.makeSettingsRow(
                    tr(.keyDashboardMenuBarPageIconOffset),
                    subtitleContent: iconOffsetSummaryContent,
                    subtitleLabel: iconOffsetSummary,
                    control: iconOffsetControls.view,
                    minimumHeight: 66
                ),
                DashboardSettingsComponents.makeSettingsRow(
                    tr(.keyDashboardMenuBarPageAmountOffset),
                    subtitleContent: amountOffsetSummaryContent,
                    subtitleLabel: amountOffsetSummary,
                    control: amountOffsetControls.view,
                    minimumHeight: 66
                ),
                DashboardSettingsComponents.makeSettingsRow(
                    tr(.keyDashboardMenuBarPageMenuBarWidth),
                    subtitleContent: widthAdjustmentSummaryContent,
                    subtitleLabel: widthAdjustmentSummary,
                    control: widthAdjustmentControls.view,
                    minimumHeight: 66
                )
            ]
        )
        isBuilt = true
        refresh(
            snapshot: input.snapshot,
            preferences: input.preferences,
            menuBarSnapshot: input.menuBarSnapshot,
            iconImage: input.iconImage,
            statusItemVisibility: input.statusItemVisibility
        )
        return DashboardSettingsComponents.makeSettingsPage([
            previewSection,
            quotaAndResetSection,
            iconAndTaskStatusSection,
            layoutSection
        ])
    }

    func refresh(
        snapshot: Snapshot,
        preferences: AppPreferences,
        menuBarSnapshot: (Snapshot) -> Snapshot,
        iconImage: NSImage?,
        statusItemVisibility: StatusItemVisibility = .unknown
    ) {
        guard isBuilt else { return }
        updateOverflowWarning(statusItemVisibility)
        previewIconSlot.isHidden = !preferences.showMenuBarIcon
        previewText.isHidden = !preferences.showMenuBarAmount
        iconSwitch?.isEnabled = preferences.showMenuBarAmount
        amountSwitch?.isEnabled = preferences.showMenuBarIcon
        let fontSizePreset = preferences.menuBarFontSizePreset
        let fontSize = fontSizePreset.primarySize
        let secondaryFontSize = fontSizePreset.secondarySize
        previewPrimary.font = MenuBarLayout.primaryFont(
            size: CGFloat(fontSize)
        )
        previewSecondary.font = MenuBarLayout.secondaryFont(
            size: CGFloat(secondaryFontSize)
        )
        let presentation = Self.presentation(
            for: snapshot,
            showAmount: preferences.showMenuBarAmount,
            showReset: preferences.showMenuBarReset,
            quotaResetDisplayMode: preferences.menuBarQuotaResetDisplayMode,
            lunaReserveResetTimeMode: preferences.menuBarLunaReserveResetTimeMode,
            resolving: menuBarSnapshot
        )
        MenuBarLayout.applyPrimaryText(presentation.primary, to: previewPrimary)
        previewSecondary.stringValue = presentation.secondary
        let hasSecondary = presentation.hasSecondary
        let geometry = MenuBarLayout.geometry(
            primarySize: previewPrimary.intrinsicContentSize,
            secondarySize: previewSecondary.intrinsicContentSize,
            showIcon: preferences.showMenuBarIcon,
            showAmount: preferences.showMenuBarAmount,
            hasSecondary: hasSecondary,
            isBalance: presentation.isBalance
        )
        MenuBarLayout.applyTextLayout(
            container: previewText,
            primary: previewPrimary,
            secondary: previewSecondary,
            geometry: geometry,
            showAmount: preferences.showMenuBarAmount,
            hasSecondary: hasSecondary
        )
        textWidthConstraint?.constant = geometry.textWidth
        previewIcon.image = iconImage
        previewIcon.contentTintColor = .labelColor
        let iconOffsetX = preferences.menuBarIconOffsetX
        let iconOffsetY = preferences.menuBarIconOffsetY
        let amountOffsetX = preferences.menuBarAmountOffsetX
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
        updateQuotaVisibility(
            showAmount: preferences.showMenuBarAmount,
            showReset: preferences.showMenuBarReset,
            autoSwitchLunaReserve: preferences.menuBarAutoSwitchLunaReserve
        )
        if let quotaWindowPreferenceControl,
           let selectedIndex = OfficialQuotaWindowPreference.allCases.firstIndex(
               of: preferences.menuBarQuotaWindowPreference
           ) {
            if quotaWindowPreferenceControl.indexOfSelectedItem != selectedIndex {
                quotaWindowPreferenceControl.selectItem(at: selectedIndex)
            }
            quotaWindowPreferenceControl.synchronizeTitleAndSelectedItem()
        }
        if let iconDisplayModeControl,
           let selectedIndex = MenuBarIconDisplayMode.allCases.firstIndex(
               of: preferences.menuBarIconDisplayMode
           ) {
            if iconDisplayModeControl.indexOfSelectedItem != selectedIndex {
                iconDisplayModeControl.selectItem(at: selectedIndex)
            }
            iconDisplayModeControl.synchronizeTitleAndSelectedItem()
        }
        if let iconDisplayDelayControl,
           let selectedIndex = MenuBarIconDisplayDelay.allCases.firstIndex(
               of: preferences.menuBarIconDisplayDelay
           ) {
            if iconDisplayDelayControl.indexOfSelectedItem != selectedIndex {
                iconDisplayDelayControl.selectItem(at: selectedIndex)
            }
            iconDisplayDelayControl.synchronizeTitleAndSelectedItem()
        }
        updateIconAndTaskStatusVisibility(
            showTaskStatusIcon: preferences.showMenuBarIcon,
            displayMode: preferences.menuBarIconDisplayMode
        )
        if let quotaResetDisplayModeControl,
           let selectedIndex = OfficialQuotaResetDisplayMode.allCases.firstIndex(
               of: preferences.menuBarQuotaResetDisplayMode
           ) {
            if quotaResetDisplayModeControl.indexOfSelectedItem != selectedIndex {
                quotaResetDisplayModeControl.selectItem(at: selectedIndex)
            }
            quotaResetDisplayModeControl.synchronizeTitleAndSelectedItem()
        }
        autoSwitchLunaReserveSwitch?.state = preferences.menuBarAutoSwitchLunaReserve
            ? .on
            : .off
        if let lunaReserveResetTimeModeControl,
           let selectedIndex = LunaReserveResetTimeMode.allCases.firstIndex(
               of: preferences.menuBarLunaReserveResetTimeMode
           ) {
            if lunaReserveResetTimeModeControl.indexOfSelectedItem != selectedIndex {
                lunaReserveResetTimeModeControl.selectItem(at: selectedIndex)
            }
            lunaReserveResetTimeModeControl.synchronizeTitleAndSelectedItem()
        }
        let widthAdjustment = transientWidthAdjustment
            ?? preferences.menuBarStatusItemWidthAdjustment
        applyWidthAdjustment(
            widthAdjustment,
            horizontalPadding: preferences.menuBarHorizontalPadding,
            synchronizeSlider: transientWidthAdjustment == nil
        )
        let iconVisualX = CGFloat(iconOffsetX)
        let iconVisualY = CGFloat(iconOffsetY)
        let amountVisualX = CGFloat(amountOffsetX)
        let amountVisualY = CGFloat(amountOffsetY)
        let officialTextYOffset: CGFloat
        if presentation.isOfficial, preferences.showMenuBarAmount {
            officialTextYOffset = MenuBarLayout.officialTextYOffset(
                hasSecondary: presentation.hasSecondary
            )
        } else {
            officialTextYOffset = 0
        }
        let previewBackgroundBounds = resolvedPreviewBackgroundBounds(
            fallbackWidth: geometry.contentWidth
                + (preferences.menuBarHorizontalPadding + chromeInset) * 2
        )
        let singleLineBackgroundBounds = previewBackgroundBounds.height > 0
            ? previewBackgroundBounds
            : NSRect(
                x: previewBackgroundBounds.minX,
                y: previewBackgroundBounds.minY,
                width: previewBackgroundBounds.width,
                height: 42
            )
        let isSingleLinePrimaryAnchorMode = preferences.showMenuBarAmount
            && !hasSecondary
            && (presentation.isOfficial || presentation.isBalance)
        let horizontalCenteringCompensation = isSingleLinePrimaryAnchorMode
            ? 0
            : MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: previewBackgroundBounds,
                geometry: geometry,
                iconOffsetX: iconVisualX,
                textOffsetX: amountVisualX,
                centerVisibleUnionOnBackground: hasSecondary
            )
        previewIcon.layer?.setAffineTransform(.identity)
        previewText.layer?.setAffineTransform(.identity)
        if isSingleLinePrimaryAnchorMode {
            let iconTranslationY: CGFloat
            let textTranslationY: CGFloat
            if presentation.isBalance,
               preferences.showMenuBarIcon,
               preferences.showMenuBarAmount {
                iconTranslationY = MenuBarOffsetLayout.yDelta(
                    visualY: iconVisualY,
                    in: .unflippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: MenuBarLayout.singleLineIconYOffset,
                    in: .unflippedLayer
                )
                textTranslationY = MenuBarOffsetLayout.yDelta(
                    visualY: amountVisualY,
                    in: .unflippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: MenuBarLayout.singleLineTextYOffset,
                    in: .flippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: Self.previewAmountDefaultYOffset,
                    in: .unflippedLayer
                )
            } else {
                iconTranslationY = MenuBarOffsetLayout.yDelta(
                    visualY: iconVisualY,
                    in: .unflippedLayer
                )
                textTranslationY = MenuBarOffsetLayout.yDelta(
                    visualY: amountVisualY,
                    in: .unflippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: officialTextYOffset,
                    in: .flippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: Self.previewAmountDefaultYOffset,
                    in: .unflippedLayer
                )
            }
            let userAmountTranslationY = MenuBarOffsetLayout.yDelta(
                visualY: amountVisualY,
                in: .unflippedLayer
            )
            let zeroUserTextTranslationY = textTranslationY - userAmountTranslationY
            previewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: iconVisualX),
                y: iconTranslationY
            ))
            previewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: amountVisualX),
                y: zeroUserTextTranslationY
            ))
            previewBackground?.layoutSubtreeIfNeeded()

            var horizontalCorrection: CGFloat = 0
            var verticalCorrection: CGFloat = 0
            if let previewBackground,
               previewBackground.bounds.width > 0,
               previewBackground.bounds.height > 0,
               let primaryInk = previewPrimaryInkBounds(in: previewBackground) {
                let targetX = MenuBarLayout.singleLinePrimaryAnchorX(
                    backgroundBounds: singleLineBackgroundBounds,
                    primaryText: presentation.primary,
                    showIcon: preferences.showMenuBarIcon,
                    isBalance: presentation.isBalance
                )
                horizontalCorrection = targetX - primaryInk.midX
                let automaticAmountTranslationY = MenuBarOffsetLayout.yDelta(
                    visualY: MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                        fontSize: CGFloat(fontSize)
                    ),
                    in: .unflippedLayer
                )
                let targetY = singleLineBackgroundBounds.midY
                    + userAmountTranslationY
                    + automaticAmountTranslationY
                verticalCorrection = targetY - primaryInk.midY
            }
            previewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: iconVisualX)
                    + horizontalCorrection,
                y: iconTranslationY
            ))
            previewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: amountVisualX)
                    + horizontalCorrection,
                y: zeroUserTextTranslationY + verticalCorrection
            ))
        } else if presentation.isBalance, preferences.showMenuBarIcon, preferences.showMenuBarAmount {
            previewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: iconVisualX)
                    + horizontalCenteringCompensation,
                y: MenuBarOffsetLayout.yDelta(visualY: iconVisualY, in: .unflippedLayer)
                    + MenuBarOffsetLayout.yDelta(
                        visualY: MenuBarLayout.singleLineIconYOffset,
                        in: .unflippedLayer
                    )
            ))
            previewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: amountVisualX)
                    + horizontalCenteringCompensation,
                // User Y offsets use unflipped layer semantics (positive = up)
                // to match the real menu bar; the built-in single-line baseline
                // keeps its existing visual unchanged.
                y: MenuBarOffsetLayout.yDelta(
                    visualY: amountVisualY,
                    in: .unflippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: MenuBarLayout.singleLineTextYOffset,
                    in: .flippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: Self.previewAmountDefaultYOffset,
                    in: .unflippedLayer
                )
            ))
        } else {
            previewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: iconVisualX)
                    + horizontalCenteringCompensation,
                y: MenuBarOffsetLayout.yDelta(visualY: iconVisualY, in: .unflippedLayer)
            ))
            previewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: amountVisualX)
                    + horizontalCenteringCompensation,
                y: MenuBarOffsetLayout.yDelta(
                    visualY: amountVisualY,
                    in: .unflippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: officialTextYOffset,
                    in: .flippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: Self.previewAmountDefaultYOffset,
                    in: .unflippedLayer
                )
            ))
        }
    }

    private func updateOverflowWarning(_ statusItemVisibility: StatusItemVisibility) {
        guard let overflowWarningLabel,
              let overflowWarningRow else { return }
        let shouldShow = statusItemVisibility == .hiddenByMenuBarSpace
        overflowWarningLabel.stringValue = Self.overflowWarningText()
        overflowWarningSettingsButton?.title = Self.overflowWarningSettingsButtonText()
        overflowWarningSettingsButton?.toolTip = Self.overflowWarningSettingsButtonText()
        overflowWarningSettingsButton?.setAccessibilityLabel(
            Self.overflowWarningSettingsButtonText()
        )
        overflowWarningLabel.isHidden = !shouldShow
        overflowWarningRow.isHidden = !shouldShow
        if let separator = previewSeparators.first {
            separator.isHidden = !shouldShow
        }
        updatePreviewCardLayout()
    }

    private func updatePreviewCardLayout() {
        guard let previewRowsStack,
              let previewCardHeightConstraint else { return }
        previewCardHeightConstraint.constant = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: previewRowsStack,
            separators: previewSeparators
        )
    }

    private func updateQuotaVisibility(
        showAmount: Bool,
        showReset: Bool,
        autoSwitchLunaReserve: Bool
    ) {
        resetCountdownRow?.isHidden = !showAmount
        let showResetDetails = showAmount && showReset
        quotaWindowPreferenceRow?.isHidden = !showResetDetails
        autoSwitchLunaReserveRow?.isHidden = !showAmount
        lunaReserveResetTimeRow?.isHidden = !showAmount || !autoSwitchLunaReserve
        quotaResetDisplayModeRow?.isHidden = !showResetDetails
        autoSwitchLunaReserveSwitch?.isEnabled = showAmount
        lunaReserveResetTimeModeControl?.isEnabled = showAmount && autoSwitchLunaReserve

        // The separators describe visible row boundaries. When the dependent
        // Reserve row is hidden, keep exactly one separator after each visible
        // row that has another visible row later in the ordered list. This
        // collapses hidden rows without producing doubled lines.
        let rows = [
            amountDisplayRow,
            resetCountdownRow,
            quotaWindowPreferenceRow,
            quotaResetDisplayModeRow,
            autoSwitchLunaReserveRow,
            lunaReserveResetTimeRow
        ]
        for (index, separator) in quotaSeparators.enumerated() {
            guard index < rows.count,
                  index + 1 < rows.count else {
                separator.isHidden = true
                continue
            }
            let hasVisibleRowAfter = rows[(index + 1)...].contains { $0?.isHidden == false }
            separator.isHidden = !(rows[index]?.isHidden == false && hasVisibleRowAfter)
        }
        updateQuotaCardLayout()
    }

    private func updateQuotaCardLayout() {
        guard let quotaRowsStack,
              let quotaCardHeightConstraint else { return }
        quotaRowsStack.needsLayout = true
        quotaRowsStack.layoutSubtreeIfNeeded()
        quotaCardHeightConstraint.constant = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: quotaRowsStack,
            separators: quotaSeparators
        )
        quotaRowsStack.superview?.invalidateIntrinsicContentSize()
        quotaRowsStack.superview?.needsLayout = true
        quotaRowsStack.superview?.superview?.needsLayout = true
    }

    private func updateIconAndTaskStatusVisibility(
        showTaskStatusIcon: Bool,
        displayMode: MenuBarIconDisplayMode
    ) {
        let showDependentRows = showTaskStatusIcon
        let showDelay = showDependentRows && displayMode == .onlyWhileRunning
        animationRow?.isHidden = !showDependentRows
        iconDisplayModeRow?.isHidden = !showDependentRows
        iconDisplayDelayRow?.isHidden = !showDelay

        // Rows are ordered as task status → animation → display mode → delay.
        // A separator is visible only when it separates two visible rows.
        if iconTaskStatusSeparators.count > 2 {
            iconTaskStatusSeparators[0].isHidden = !showDependentRows
            iconTaskStatusSeparators[1].isHidden = !showDependentRows
            iconTaskStatusSeparators[2].isHidden = !showDelay
        }
        updateIconTaskStatusCardLayout()
    }

    private func updateIconTaskStatusCardLayout() {
        guard let iconTaskStatusRowsStack,
              let iconTaskStatusCardHeightConstraint else { return }
        iconTaskStatusRowsStack.needsLayout = true
        iconTaskStatusRowsStack.layoutSubtreeIfNeeded()
        iconTaskStatusCardHeightConstraint.constant = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: iconTaskStatusRowsStack,
            separators: iconTaskStatusSeparators
        )
        iconTaskStatusRowsStack.superview?.invalidateIntrinsicContentSize()
        iconTaskStatusRowsStack.superview?.needsLayout = true
        iconTaskStatusRowsStack.superview?.superview?.needsLayout = true
    }

    private func previewPrimaryInkBounds(in background: NSView) -> NSRect? {
        let frameSize = previewPrimary.bounds.size
        guard frameSize.width > 0, frameSize.height > 0,
              let localBounds = MenuBarLayout.appKitRenderedTextBounds(
                  for: previewPrimary,
                  frameSize: frameSize
              ) else {
            return nil
        }
        let baseBounds = previewPrimary.convert(localBounds, to: background)
        let textTransform = previewText.layer?.affineTransform() ?? .identity
        return baseBounds.offsetBy(dx: textTransform.tx, dy: textTransform.ty)
    }

    private func resolvedPreviewBackgroundBounds(fallbackWidth: CGFloat) -> NSRect {
        if let previewBackground, previewBackground.bounds.width > 0 {
            return previewBackground.bounds
        }
        let width = max(
            0,
            previewWidthConstraint?.constant ?? fallbackWidth
        )
        let height = previewBackground?.bounds.height ?? 42
        return NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(0, height)
        )
    }

    /// Refreshes only the width-specific presentation while a continuous
    /// slider is moving. The full page refresh also resolves snapshots and
    /// reapplies icon/text transforms, which is unnecessary for this field.
    func refreshWidthAdjustment(
        _ widthAdjustment: Double,
        horizontalPadding: CGFloat,
        synchronizeSlider: Bool = false
    ) {
        transientWidthAdjustment = AppPreferences.normalizedMenuBarStatusItemWidthAdjustment(widthAdjustment)
        applyWidthAdjustment(
            transientWidthAdjustment ?? 0,
            horizontalPadding: horizontalPadding,
            synchronizeSlider: synchronizeSlider
        )
    }

    func finishWidthAdjustment(
        _ widthAdjustment: Double,
        horizontalPadding: CGFloat
    ) {
        transientWidthAdjustment = nil
        applyWidthAdjustment(
            AppPreferences.normalizedMenuBarStatusItemWidthAdjustment(widthAdjustment),
            horizontalPadding: horizontalPadding,
            synchronizeSlider: true
        )
    }

    private func applyWidthAdjustment(
        _ widthAdjustment: Double,
        horizontalPadding: CGFloat,
        synchronizeSlider: Bool
    ) {
        guard isBuilt else { return }
        MenuBarWidthPerformance.measure("dashboard-preview") {
            let capsuleInset = Self.previewCapsuleHorizontalInset(
                horizontalPadding: horizontalPadding,
                widthAdjustment: widthAdjustment + AppPreferences.menuBarStatusItemWidthBaseline,
                additionalWidth: MenuBarLayout.menuBarStatusItemVisualOverhangX * 2
            )
            capsuleLeadingConstraint?.constant = -capsuleInset
            capsuleTrailingConstraint?.constant = capsuleInset
            DashboardSettingsComponents.updateSubtitleLabel(
                widthAdjustmentSummaryLabel,
                with: Self.widthAdjustmentSummarySubtitle(widthAdjustment)
            )
            if synchronizeSlider {
                widthAdjustmentSlider?.doubleValue = widthAdjustment
            }
            widthAdjustmentSlider?.isEnabled = true
        }
    }

    func restoreRequiredToggle(identifier: String) {
        switch identifier {
        case "showMenuBarIcon":
            iconSwitch?.state = .on
        case "showMenuBarAmount":
            amountSwitch?.state = .on
        default:
            break
        }
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

    private static func previewCapsuleHorizontalInset(
        horizontalPadding: CGFloat,
        widthAdjustment: Double,
        additionalWidth: CGFloat = 0
    ) -> CGFloat {
        horizontalPadding
            + 10
            + (CGFloat(widthAdjustment) / 2)
            + (max(0, additionalWidth) / 2)
    }

    private func makeFontSizePresetControls(
        value: MenuBarFontSizePreset,
        relay: DashboardPreferencePageRelay
    ) -> FontPresetControls {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.fontSizePresetIdentifier,
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
        control.widthAnchor.constraint(equalToConstant: Self.fontSizePresetWidth).isActive = true
        return FontPresetControls(view: control, control: control)
    }

    private func makeQuotaWindowPreferenceControl(
        value: OfficialQuotaWindowPreference,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.quotaWindowPreferenceIdentifier,
            items: OfficialQuotaWindowPreference.allCases.map { preference in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.quotaWindowPreferenceLabel(preference),
                    representedObject: preference.rawValue
                )
            },
            selectedIndex: OfficialQuotaWindowPreference.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarQuotaWindowPreference(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuBarPageQuotaDisplayPriorityDescription)
        return control
    }

    private func makeIconDisplayModeControl(
        value: MenuBarIconDisplayMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.iconDisplayModeIdentifier,
            items: MenuBarIconDisplayMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.iconDisplayModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: MenuBarIconDisplayMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarIconDisplayMode(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuBarPageIconDisplayModeDescription)
        return control
    }

    private func makeIconDisplayDelayControl(
        value: MenuBarIconDisplayDelay,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.iconDisplayDelayIdentifier,
            items: MenuBarIconDisplayDelay.allCases.map { delay in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.iconDisplayDelayLabel(delay),
                    representedObject: delay.rawValue
                )
            },
            selectedIndex: MenuBarIconDisplayDelay.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarIconDisplayDelay(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuBarPageIconDisplayDelayDescription)
        return control
    }

    private func makeQuotaResetDisplayModeControl(
        value: OfficialQuotaResetDisplayMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.quotaResetDisplayModeIdentifier,
            items: OfficialQuotaResetDisplayMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.quotaResetDisplayModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: OfficialQuotaResetDisplayMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarQuotaResetDisplayMode(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuBarPageQuotaResetDisplayModeDescription)
        return control
    }

    private func makeLunaReserveResetTimeModeControl(
        value: LunaReserveResetTimeMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.lunaReserveResetTimeModeIdentifier,
            items: LunaReserveResetTimeMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.lunaReserveResetTimeModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: LunaReserveResetTimeMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarLunaReserveResetTimeMode(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuBarPageLunaReserveResetTimeDescription)
        return control
    }

    private static func quotaWindowPreferenceLabel(
        _ preference: OfficialQuotaWindowPreference
    ) -> String {
        switch preference {
        case .fiveHour:
            return tr(.keyDashboardMenuBarPageFiveHourQuota)
        case .sevenDay:
            return tr(.keyDashboardMenuBarPageSevenDayQuota)
        }
    }

    private static func iconDisplayModeLabel(
        _ mode: MenuBarIconDisplayMode
    ) -> String {
        switch mode {
        case .alwaysVisible:
            return tr(.keyDashboardMenuBarPageIconDisplayModeAlwaysVisible)
        case .onlyWhileRunning:
            return tr(.keyDashboardMenuBarPageIconDisplayModeOnlyWhileRunning)
        }
    }

    private static func iconDisplayDelayLabel(
        _ delay: MenuBarIconDisplayDelay
    ) -> String {
        switch delay {
        case .zeroSeconds:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayZeroSeconds)
        case .tenSeconds:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayTenSeconds)
        case .thirtySeconds:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayThirtySeconds)
        case .oneMinute:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayOneMinute)
        case .twoMinutes:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayTwoMinutes)
        case .threeMinutes:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayThreeMinutes)
        }
    }

    private static func quotaResetDisplayModeLabel(
        _ mode: OfficialQuotaResetDisplayMode
    ) -> String {
        switch mode {
        case .remaining:
            return tr(.keyDashboardMenuBarPageQuotaResetDisplayRemaining)
        case .resetAt:
            return tr(.keyDashboardMenuBarPageQuotaResetDisplayTarget)
        case .both:
            return tr(.keyDashboardMenuBarPageQuotaResetDisplayBoth)
        }
    }

    private static func lunaReserveResetTimeModeLabel(
        _ mode: LunaReserveResetTimeMode
    ) -> String {
        switch mode {
        case .lunaReserve:
            return tr(.keyDashboardMenuBarPageLunaReserveResetTimeLunaReserve)
        case .originalQuota:
            return tr(.keyDashboardMenuBarPageLunaReserveResetTimeOriginalQuota)
        }
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

    private static func fontSizePresetLabel(_ preset: MenuBarFontSizePreset) -> String {
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
            minimumIdentifier: Self.widthAdjustmentSliderMinimumIdentifier,
            maximumIdentifier: Self.widthAdjustmentSliderMaximumIdentifier,
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
        slider.widthAnchor.constraint(equalToConstant: Self.widthAdjustmentSliderWidth).isActive = true

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
        let stack = NSStackView(views: [minimumLabel, slider, maximumLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return CenteredSliderControls(view: stack, slider: slider)
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
