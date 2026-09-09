import AppKit
import QuartzCore

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

private final class DashboardMenuBarPageActionTarget: NSObject {
    var onRevealIconDisplayModeSetting: (() -> Void)?

    @objc func revealIconDisplayModeSetting(_ sender: Any?) {
        onRevealIconDisplayModeSetting?()
    }
}

/// Commits the FPS field on Return and focus loss.
private final class AnimationFrameRateEditor: NSObject, NSTextFieldDelegate {
    weak var field: NSTextField?
    var onChange: ((Int) -> Void)?
    private var isRewritingDisplayedValue = false

    func setDisplayedValue(_ fps: Int) {
        let clamped = MenuBarAnimationTiming.clampedFrameRate(fps)
        if field?.currentEditor() == nil {
            field?.integerValue = clamped
        }
    }

    @objc func fieldAction(_ sender: NSTextField) {
        commit(MenuBarAnimationFrameRateInput.resolve(sender.stringValue))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isRewritingDisplayedValue, let field = obj.object as? NSTextField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed),
              value > MenuBarAnimationTiming.maximumFrameRate else {
            return
        }
        isRewritingDisplayedValue = true
        commit(MenuBarAnimationTiming.maximumFrameRate)
        isRewritingDisplayedValue = false
        if let editor = field.currentEditor() {
            let end = (field.stringValue as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        commit(MenuBarAnimationFrameRateInput.resolve(field.stringValue))
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            commit(MenuBarAnimationFrameRateInput.step(1, from: control.stringValue))
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            commit(MenuBarAnimationFrameRateInput.step(-1, from: control.stringValue))
            return true
        }
        return false
    }

    private func commit(_ fps: Int) {
        let clamped = MenuBarAnimationTiming.clampedFrameRate(fps)
        field?.integerValue = clamped
        onChange?(clamped)
    }
}

final class DashboardMenuBarPage {
    static let iconOffsetsResetIdentifier = "menuBarIconOffsetsReset"
    static let amountOffsetsResetIdentifier = "menuBarAmountOffsetsReset"
    static let iconOffsetSummaryIdentifier = "menuBarIconOffsetSummary"
    static let amountOffsetSummaryIdentifier = "menuBarAmountOffsetSummary"
    static let widthAdjustmentSummaryIdentifier = "menuBarStatusItemWidthAdjustmentSummary"
    static let fontSizePresetIdentifier = AppPreferences.menuBarFontSizePresetKey
    static let iconSizePresetIdentifier = AppPreferences.menuBarIconSizePresetKey
    static let iconDisplayModeIdentifier = AppPreferences.menuBarIconDisplayModeKey
    static let iconDisplayDelayIdentifier = AppPreferences.menuBarIconDisplayDelayKey
    static let animationModeIdentifier = AppPreferences.menuBarAnimationModeKey
    static let animationModeTitleIdentifier = AppPreferences.menuBarAnimationModeKey + "Title"
    static let animationModeSubtitleIdentifier = AppPreferences.menuBarAnimationModeKey + "Subtitle"
    static let animationFrameRateIdentifier = AppPreferences.menuBarAnimationFrameRateKey
    static let animationFrameRateRowIdentifier = AppPreferences.menuBarAnimationFrameRateKey + "Row"
    static let animationFallbackWarningIdentifier = "menuBarAnimationFallbackWarning"
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
    static let iconSizePresetWidth: CGFloat = fontSizePresetWidth
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
    static let runtimeOnlyWarningIdentifier = "menuBarRuntimeOnlyWarning"
    static let runtimeOnlyWarningRowIdentifier = "menuBarRuntimeOnlyWarningRow"
    static let runtimeOnlyWarningSettingsButtonIdentifier = "menuBarRuntimeOnlyWarningSettingsButton"
    // Compatibility aliases keep the presentation concept easy to discover
    // for callers that refer to the state as a runtime warning.
    static let runtimeWarningIdentifier = runtimeOnlyWarningIdentifier
    static let runtimeWarningRowIdentifier = runtimeOnlyWarningRowIdentifier
    static let runtimeWarningSettingsButtonIdentifier = runtimeOnlyWarningSettingsButtonIdentifier
    static let iconDisplayModeRevealHighlightAnimationKey =
        "menuBarIconDisplayModeRevealHighlight"
    static let iconDisplayModeRevealHighlightDuration: TimeInterval = 0.72
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

    static func runtimeOnlyWarningText(for language: AppLanguage = .selected) -> String {
        tr(.keyDashboardMenuBarPageRuntimeOnlyWarning, language: language)
    }

    static func runtimeOnlyWarningSettingsButtonText(
        for language: AppLanguage = .selected
    ) -> String {
        tr(.keyDashboardMenuBarPageSetNow, language: language)
    }

    static func runtimeWarningText(for language: AppLanguage = .selected) -> String {
        runtimeOnlyWarningText(for: language)
    }

    static func runtimeWarningSettingsButtonText(
        for language: AppLanguage = .selected
    ) -> String {
        runtimeOnlyWarningSettingsButtonText(for: language)
    }

    static func animationModeDescription(
        mode: MenuBarAnimationMode,
        language: AppLanguage = .selected
    ) -> String {
        switch mode {
        case .efficient:
            return tr(
                .keyDashboardMenuBarPageAnimationModeDescriptionEfficient,
                language: language
            )
        case .synchronized:
            return tr(
                .keyDashboardMenuBarPageAnimationModeDescriptionSynchronized,
                language: language
            )
        }
    }

    static func animationModeRestartLinkPhrase(
        language: AppLanguage = .selected
    ) -> String {
        tr(.keyDashboardMenuBarPageAnimationModeRestartLink, language: language)
    }

    static func animationModeTitle(
        language: AppLanguage = .selected
    ) -> String {
        tr(.keyDashboardMenuBarPageAnimation, language: language)
    }

    static func relaunchCurrentApplication() {
        let relauncher = LiveUpdateApplicationRelauncher()
        try? relauncher.relaunchApplication(at: Bundle.main.bundleURL)
    }

    static func animationFallbackWarningText(
        for language: AppLanguage = .selected
    ) -> String {
        tr(.keyDashboardMenuBarPageAnimationModeFallback, language: language)
    }

    struct Input {
        let preferences: AppPreferences
        let snapshot: Snapshot
        let menuBarSnapshot: (Snapshot) -> Snapshot
        let statusItemVisibility: StatusItemVisibility
        let iconImage: NSImage?
        let animationActive: Bool
        let animationIconImage: NSImage?
        let animationKind: MenuBarCompositorAnimationKind
        let animationSpriteImage: NSImage?
        let animationFallbackActive: Bool
        let relay: DashboardPreferencePageRelay

        init(
            preferences: AppPreferences,
            snapshot: Snapshot,
            menuBarSnapshot: @escaping (Snapshot) -> Snapshot,
            iconImage: NSImage?,
            relay: DashboardPreferencePageRelay,
            statusItemVisibility: StatusItemVisibility = .unknown,
            animationActive: Bool = false,
            animationIconImage: NSImage? = nil,
            animationKind: MenuBarCompositorAnimationKind? = nil,
            animationSpriteImage: NSImage? = nil,
            animationFallbackActive: Bool = false
        ) {
            self.preferences = preferences
            self.snapshot = snapshot
            self.menuBarSnapshot = menuBarSnapshot
            self.statusItemVisibility = statusItemVisibility
            self.iconImage = iconImage
            self.animationActive = animationActive
            self.animationIconImage = animationIconImage
            self.animationKind = animationKind ?? (animationActive ? .codexRotation : .none)
            self.animationSpriteImage = animationSpriteImage
            self.animationFallbackActive = animationFallbackActive
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

    private struct WarningRefreshSignature: Equatable {
        let hiddenByMenuBarSpace: Bool
        let hiddenByRuntimePolicy: Bool
        let language: String
    }

    private struct SettingsRefreshSignature: Equatable {
        let language: String
        let showIcon: Bool
        let showAmount: Bool
        let showReset: Bool
        let fontSizePreset: String
        let iconSizePreset: String
        let iconOffsetY: Double
        let amountOffsetY: Double
        let quotaWindowPreference: String
        let quotaResetDisplayMode: String
        let autoSwitchLunaReserve: Bool
        let lunaReserveResetTimeMode: String
        let iconDisplayMode: String
        let iconDisplayDelay: String
        let animationEnabled: Bool
        let animationMode: String
        let animationFrameRate: Int
        let widthAdjustment: Double
        let horizontalPadding: CGFloat
        let synchronizeWidthSlider: Bool
    }

    private struct IconTaskVisibilitySignature: Equatable {
        let showIcon: Bool
        let showDelay: Bool
        let showAnimationMode: Bool
        let showFallbackWarning: Bool
    }

    private struct PreviewRefreshSignature: Equatable {
        let presentation: Presentation
        let showIcon: Bool
        let showAmount: Bool
        let fontSizePreset: String
        let iconSizePreset: String
        let iconOffsetX: Double
        let iconOffsetY: Double
        let amountOffsetX: Double
        let amountOffsetY: Double
        let horizontalPadding: CGFloat
        let iconImageIdentity: ObjectIdentifier?
        let iconImageSize: NSSize
        let iconImageIsTemplate: Bool
        let previewBackgroundBounds: NSRect
        let previewIconBounds: NSRect
        let backingScale: CGFloat
        let appearance: String
        let animationActive: Bool
        let animationKind: MenuBarCompositorAnimationKind
        let animationSpriteImageIdentity: ObjectIdentifier?
        let animationSpriteImageSize: NSSize
        let animationSpriteImageIsTemplate: Bool
        let animationFallbackActive: Bool
        let animationFrameRate: Int
    }

    private struct RefreshSignature: Equatable {
        let warning: WarningRefreshSignature
        let settings: SettingsRefreshSignature
        let preview: PreviewRefreshSignature
    }

    private let previewIcon = PassthroughImageView()
    private let previewIconSlot = NSView()
    private let previewAnimatedIconHost = MenuBarNativeAnimatedIconHostView(frame: .zero)
    private let previewClaudeAnimatedIconHost = MenuBarClaudeAnimatedIconHostView(frame: .zero)
    private let previewText = MenuBarTextView()
    private let previewPrimary = NSTextField(labelWithString: "…")
    private let previewSecondary = NSTextField(labelWithString: "")
    private let previewCapsule = NSView()
    private weak var iconSwitch: NSSwitch?
    private weak var amountSwitch: NSSwitch?
    private weak var animationSwitch: NSSwitch?
    private weak var previewBackground: NSView?
    private weak var overflowWarningLabel: NSTextField?
    private weak var overflowWarningSettingsButton: NSButton?
    private weak var overflowWarningRow: NSView?
    private weak var runtimeOnlyWarningLabel: NSTextField?
    private weak var runtimeOnlyWarningSettingsButton: NSButton?
    private weak var runtimeOnlyWarningRow: NSView?
    private weak var previewRowsStack: NSStackView?
    private weak var previewCardHeightConstraint: NSLayoutConstraint?
    private var previewSeparators: [NSView] = []
    private var capsuleLeadingConstraint: NSLayoutConstraint?
    private var capsuleTrailingConstraint: NSLayoutConstraint?
    private var previewWidthConstraint: NSLayoutConstraint?
    private var textWidthConstraint: NSLayoutConstraint?
    private var previewIconWidthConstraint: NSLayoutConstraint?
    private var previewIconHeightConstraint: NSLayoutConstraint?
    private var previewIconSlotWidthConstraint: NSLayoutConstraint?
    private var previewIconSlotHeightConstraint: NSLayoutConstraint?
    private var iconOffsetSummaryLabel: NSTextField?
    private var amountOffsetSummaryLabel: NSTextField?
    private var widthAdjustmentSummaryLabel: NSTextField?
    private weak var iconOffsetSlider: NSSlider?
    private weak var amountOffsetSlider: NSSlider?
    private weak var widthAdjustmentSlider: NSSlider?
    private weak var fontSizePresetControl: NSPopUpButton?
    private weak var iconSizePresetControl: NSPopUpButton?
    private weak var iconDisplayModeControl: NSPopUpButton?
    private weak var iconDisplayDelayControl: NSPopUpButton?
    private var animationFrameRate = MenuBarAnimationTiming.defaultFrameRate
    private let animationFrameRateEditor = AnimationFrameRateEditor()
    private weak var animationModeControl: NSPopUpButton?
    private weak var animationModeTitleLabel: NSTextField?
    private weak var animationModeSubtitleLabel: InlineRangeLinkTextField?
    var relaunchApplication: () -> Void = DashboardMenuBarPage.relaunchCurrentApplication
    var restoreSnapshotProvider: () -> DashboardRestoreToken = {
        DashboardRestoreToken(section: .menuBar, scrollOffsetY: 0)
    }
    var persistRestoreToken: (DashboardRestoreToken) -> Void = { token in
        DashboardRestoreStore.record(token)
    }
    private var restartConfirmationAlert: NSAlert?
    var restartConfirmationAlertForTesting: NSAlert? {
        restartConfirmationAlert
    }
    private weak var animationFrameRateField: NSTextField?
    private weak var animationFrameRateUnitLabel: NSTextField?
    private weak var animationFrameRateSubtitleLabel: NSTextField?
    private weak var taskStatusIconRow: NSView?
    private weak var animationRow: NSView?
    private weak var animationModeRow: NSView?
    private weak var animationFrameRateRow: NSView?
    private weak var animationFallbackWarningLabel: NSTextField?
    private weak var animationFallbackWarningRow: NSView?
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
    private var iconSizePresetTrackingObserver: NSObjectProtocol?
    private var transientWidthAdjustment: Double?
    private var lastRefreshSignature: RefreshSignature?
    private var lastWarningRefreshSignature: WarningRefreshSignature?
    private var lastSettingsRefreshSignature: SettingsRefreshSignature?
    private var lastPreviewRefreshSignature: PreviewRefreshSignature?
    private var lastQuotaVisibilitySignature: [Bool]?
    private var lastIconTaskVisibilitySignature: IconTaskVisibilitySignature?
    private(set) var refreshCallCountForTesting = 0
    private(set) var refreshApplyCountForTesting = 0
    private(set) var refreshSkipCountForTesting = 0
    private(set) var warningRefreshCountForTesting = 0
    private(set) var settingsRefreshCountForTesting = 0
    private(set) var previewRefreshCountForTesting = 0
    private(set) var previewCardLayoutCountForTesting = 0
    private(set) var quotaCardLayoutCountForTesting = 0
    private(set) var iconTaskCardLayoutCountForTesting = 0
    private let chromeInset: CGFloat = 10
    private var isBuilt = false
    private var previewAnimationActive = false
    private var previewAnimationKind: MenuBarCompositorAnimationKind = .none
    private var animationFallbackActive = false
    private var lastPreviewIconImage: NSImage?
    private var lastPreviewSpriteImage: NSImage?
    private let pageActionTarget = DashboardMenuBarPageActionTarget()

    deinit {
        removeIconDisplayModeRevealHighlight()
        removeFontSizePresetTrackingObserver()
        removeIconSizePresetTrackingObserver()
    }

    func teardown() {
        removeIconDisplayModeRevealHighlight()
        removeFontSizePresetTrackingObserver()
        removeIconSizePresetTrackingObserver()
        previewAnimationActive = false
        previewAnimationKind = .none
        animationFallbackActive = false
        previewAnimatedIconHost.removeRotationAnimation()
        previewAnimatedIconHost.isHidden = true
        previewAnimatedIconHost.removeFromSuperview()
        previewClaudeAnimatedIconHost.removeThinkingAnimation()
        previewClaudeAnimatedIconHost.isHidden = true
        previewClaudeAnimatedIconHost.removeFromSuperview()
        lastPreviewSpriteImage = nil
        resetRefreshSignatures()
        pageActionTarget.onRevealIconDisplayModeSetting = nil
        dismissRestartConfirmation()
    }

    private func resetRefreshSignatures() {
        lastRefreshSignature = nil
        lastWarningRefreshSignature = nil
        lastSettingsRefreshSignature = nil
        lastPreviewRefreshSignature = nil
        lastQuotaVisibilitySignature = nil
        lastIconTaskVisibilitySignature = nil
    }

    /// Updates only the preview bitmap. Animation frames must not repeat the
    /// full settings-page refresh performed by refresh(...).
    var previewAnimationHostForTesting: MenuBarNativeAnimatedIconHostView {
        previewAnimatedIconHost
    }

    var previewClaudeAnimationHostForTesting: MenuBarClaudeAnimatedIconHostView {
        previewClaudeAnimatedIconHost
    }

    func updatePreviewIcon(_ image: NSImage?) {
        guard isBuilt else { return }
        guard previewAnimationKind == .none else { return }
        lastPreviewIconImage = image
        guard previewIcon.image !== image else { return }
        previewIcon.image = image
    }

    /// Mirrors the native status-item compositor state into the already-visible
    /// Dashboard preview. Each animation kind owns a separate in-window host;
    /// no preview frame callback is needed.
    func updatePreviewAnimation(
        kind: MenuBarCompositorAnimationKind,
        iconImage: NSImage?,
        spriteImage: NSImage?
    ) {
        previewAnimationKind = kind
        previewAnimationActive = kind != .none
        if let iconImage {
            lastPreviewIconImage = iconImage
        }
        if let spriteImage {
            lastPreviewSpriteImage = spriteImage
        } else if kind != .claudeThinking, kind != .grokThinking, kind != .grokThinkingBitmap {
            lastPreviewSpriteImage = nil
        }
        guard isBuilt else { return }

        let staticImage = lastPreviewIconImage
        guard kind != .none,
              !previewIconSlot.isHidden,
              let iconImage = iconImage ?? staticImage,
              previewIcon.bounds.width > 0,
              previewIcon.bounds.height > 0 else {
            previewAnimatedIconHost.removeRotationAnimation()
            previewAnimatedIconHost.isHidden = true
            previewClaudeAnimatedIconHost.removeThinkingAnimation()
            previewClaudeAnimatedIconHost.isHidden = true
            if previewIcon.image !== staticImage {
                previewIcon.image = staticImage
            }
            return
        }

        previewIcon.image = nil
        let scale = max(previewIcon.window?.backingScaleFactor ?? 2, 1)
        switch kind {
        case .codexRotation:
            previewClaudeAnimatedIconHost.removeThinkingAnimation()
            previewClaudeAnimatedIconHost.isHidden = true
            previewAnimatedIconHost.updateGeometry(
                frame: previewIcon.frame,
                contentsScale: scale
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewAnimatedIconHost.layer?.setAffineTransform(
                previewIcon.layer?.affineTransform() ?? .identity
            )
            CATransaction.commit()
            guard previewAnimatedIconHost.updateContents(
                sourceImage: iconImage,
                appearance: previewIcon.effectiveAppearance,
                contentsScale: scale
            ) else {
                previewAnimatedIconHost.removeRotationAnimation()
                previewAnimatedIconHost.isHidden = true
                previewIcon.image = staticImage
                return
            }
            previewAnimatedIconHost.isHidden = false
            previewAnimatedIconHost.rotationDuration = MenuBarAnimationTiming.rotationDuration(
                fps: animationFrameRate
            )
            previewAnimatedIconHost.installRotationAnimation()
        case .claudeThinking, .grokThinking, .grokThinkingBitmap:
            previewAnimatedIconHost.removeRotationAnimation()
            previewAnimatedIconHost.isHidden = true
            previewClaudeAnimatedIconHost.timing = kind == .claudeThinking
                ? .claude
                : .grok(frameRate: animationFrameRate)
            guard let spriteImage = spriteImage ?? lastPreviewSpriteImage else {
                previewClaudeAnimatedIconHost.removeThinkingAnimation()
                previewClaudeAnimatedIconHost.isHidden = true
                previewIcon.image = staticImage
                return
            }
            previewClaudeAnimatedIconHost.updateGeometry(
                frame: previewIcon.frame,
                contentsScale: scale
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewClaudeAnimatedIconHost.layer?.setAffineTransform(
                previewIcon.layer?.affineTransform() ?? .identity
            )
            CATransaction.commit()
            let frameSize = NSSize(
                width: spriteImage.size.width,
                height: spriteImage.size.height
                    / CGFloat(previewClaudeAnimatedIconHost.timing.frameCount)
            )
            guard previewClaudeAnimatedIconHost.updateContents(
                spriteImage: spriteImage,
                frameSize: frameSize,
                appearance: previewIcon.effectiveAppearance,
                contentsScale: scale
            ) else {
                previewClaudeAnimatedIconHost.removeThinkingAnimation()
                previewClaudeAnimatedIconHost.isHidden = true
                previewIcon.image = staticImage
                return
            }
            previewClaudeAnimatedIconHost.isHidden = false
            previewClaudeAnimatedIconHost.installThinkingAnimation()
        case .none:
            break
        }
    }

    func updatePreviewAnimation(active: Bool, iconImage: NSImage?) {
        updatePreviewAnimation(
            kind: active ? .codexRotation : .none,
            iconImage: iconImage,
            spriteImage: nil
        )
    }

    /// Fallback is a semantic state transition, not an animation frame. Keep
    /// it on a small settings-row path so showing/hiding the warning does not
    /// rebuild the preview text or its layout.
    func updateAnimationFallback(
        active: Bool,
        showTaskStatusIcon: Bool,
        displayMode: MenuBarIconDisplayMode,
        animationEnabled: Bool,
        animationMode: MenuBarAnimationMode
    ) {
        animationFallbackActive = active
        guard isBuilt else { return }
        updateIconAndTaskStatusVisibility(
            showTaskStatusIcon: showTaskStatusIcon,
            displayMode: displayMode,
            animationEnabled: animationEnabled,
            animationMode: animationMode
        )
    }

    private static func makeWarningRow(
        label: NSTextField,
        settingsButton: NSButton,
        identifier: String
    ) -> NSView {
        let row = NSView()
        row.identifier = NSUserInterfaceItemIdentifier(identifier)
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

    private static func makeOverflowWarningRow(
        label: NSTextField,
        settingsButton: NSButton
    ) -> NSView {
        makeWarningRow(
            label: label,
            settingsButton: settingsButton,
            identifier: Self.overflowWarningRowIdentifier
        )
    }

    func make(_ input: Input) -> NSView {
        resetRefreshSignatures()
        previewAnimationActive = input.animationKind != .none
        previewAnimationKind = input.animationKind
        animationFallbackActive = input.animationFallbackActive
        lastPreviewIconImage = Self.displayedPreviewIconImage(
            animationKind: input.animationKind,
            iconImage: input.iconImage,
            animationIconImage: input.animationIconImage
        )
        lastPreviewSpriteImage = input.animationSpriteImage
        previewAnimatedIconHost.removeFromSuperview()
        previewAnimatedIconHost.removeRotationAnimation()
        previewAnimatedIconHost.isHidden = true
        previewClaudeAnimatedIconHost.removeFromSuperview()
        previewClaudeAnimatedIconHost.removeThinkingAnimation()
        previewClaudeAnimatedIconHost.isHidden = true
        pageActionTarget.onRevealIconDisplayModeSetting = { [weak self] in
            self?.revealIconDisplayModeSetting()
        }
        removeFontSizePresetTrackingObserver()
        removeIconSizePresetTrackingObserver()
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
        let initialIconSize = input.preferences.menuBarIconSize
        let previewIconWidth = previewIcon.widthAnchor.constraint(equalToConstant: initialIconSize)
        let previewIconHeight = previewIcon.heightAnchor.constraint(equalToConstant: initialIconSize)
        previewIconWidth.isActive = true
        previewIconHeight.isActive = true
        previewIconWidthConstraint = previewIconWidth
        previewIconHeightConstraint = previewIconHeight
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
        let previewIconSlotWidth = previewIconSlot.widthAnchor.constraint(equalToConstant: initialIconSize)
        let previewIconSlotHeight = previewIconSlot.heightAnchor.constraint(equalToConstant: initialIconSize)
        previewIconSlotWidth.isActive = true
        previewIconSlotHeight.isActive = true
        previewIconSlotWidthConstraint = previewIconSlotWidth
        previewIconSlotHeightConstraint = previewIconSlotHeight
        previewIconSlot.addSubview(previewIcon)
        NSLayoutConstraint.activate([
            previewIcon.centerXAnchor.constraint(equalTo: previewIconSlot.centerXAnchor),
            previewIcon.centerYAnchor.constraint(equalTo: previewIconSlot.centerYAnchor)
        ])
        previewAnimatedIconHost.isHidden = true
        previewIconSlot.addSubview(previewAnimatedIconHost)
        previewClaudeAnimatedIconHost.isHidden = true
        previewIconSlot.addSubview(previewClaudeAnimatedIconHost)
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
        self.autoSwitchLunaReserveSwitch = nil
        self.lunaReserveResetTimeModeControl = nil
        let showLunaReserveSettings = LunaReserveUserFacing.isCurrentlyEnabled
        let autoSwitchLunaReserve = showLunaReserveSettings
            ? DashboardSettingsComponents.makeSwitch(
                identifier: Self.autoSwitchLunaReserveIdentifier,
                isOn: input.preferences.menuBarAutoSwitchLunaReserve,
                target: input.relay,
                action: #selector(DashboardPreferencePageRelay.toggle(_:))
            )
            : nil
        self.autoSwitchLunaReserveSwitch = autoSwitchLunaReserve
        let quotaWindowPreferenceControl = makeQuotaWindowPreferenceControl(
            value: input.preferences.menuBarQuotaWindowPreference,
            relay: input.relay
        )
        self.quotaWindowPreferenceControl = quotaWindowPreferenceControl
        let lunaReserveResetTimeModeControl = showLunaReserveSettings
            ? makeLunaReserveResetTimeModeControl(
                value: input.preferences.menuBarLunaReserveResetTimeMode,
                relay: input.relay
            )
            : nil
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
        let animationModeControl = makeAnimationModeControl(
            value: input.preferences.menuBarAnimationMode,
            relay: input.relay
        )
        self.animationModeControl = animationModeControl
        let animationFrameRateControl = makeAnimationFrameRateControl(
            value: input.preferences.menuBarAnimationFrameRate,
            relay: input.relay
        )
        let animationFallbackWarningLabel = NSTextField(
            wrappingLabelWithString: Self.animationFallbackWarningText()
        )
        animationFallbackWarningLabel.identifier = NSUserInterfaceItemIdentifier(
            Self.animationFallbackWarningIdentifier
        )
        let animationFallbackWarningRow = DashboardSettingsComponents.makeSettingsRow(
            "",
            subtitle: Self.animationFallbackWarningText(),
            subtitleLabel: animationFallbackWarningLabel,
            minimumHeight: 58,
            verticalPadding: 11
        )
        animationFallbackWarningRow.identifier = NSUserInterfaceItemIdentifier(
            Self.animationFallbackWarningIdentifier + "Row"
        )
        self.animationFallbackWarningLabel = animationFallbackWarningLabel
        self.animationFallbackWarningRow = animationFallbackWarningRow
        animationFallbackWarningRow.isHidden = true
        iconSwitch = iconToggle
        amountSwitch = amountToggle
        animationSwitch = animationToggle
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
        let runtimeOnlyWarningLabel = NSTextField(
            wrappingLabelWithString: Self.runtimeOnlyWarningText()
        )
        runtimeOnlyWarningLabel.identifier = NSUserInterfaceItemIdentifier(
            Self.runtimeOnlyWarningIdentifier
        )
        runtimeOnlyWarningLabel.font = .systemFont(ofSize: 12)
        runtimeOnlyWarningLabel.textColor = .secondaryLabelColor
        runtimeOnlyWarningLabel.lineBreakMode = .byWordWrapping
        runtimeOnlyWarningLabel.usesSingleLineMode = false
        runtimeOnlyWarningLabel.maximumNumberOfLines = 0
        runtimeOnlyWarningLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let runtimeOnlyWarningSettingsButton = NSButton(
            title: Self.runtimeOnlyWarningSettingsButtonText(),
            target: pageActionTarget,
            action: #selector(DashboardMenuBarPageActionTarget.revealIconDisplayModeSetting(_:))
        )
        runtimeOnlyWarningSettingsButton.identifier = NSUserInterfaceItemIdentifier(
            Self.runtimeOnlyWarningSettingsButtonIdentifier
        )
        runtimeOnlyWarningSettingsButton.bezelStyle = .rounded
        runtimeOnlyWarningSettingsButton.controlSize = .regular
        runtimeOnlyWarningSettingsButton.toolTip = Self.runtimeOnlyWarningSettingsButtonText()
        runtimeOnlyWarningSettingsButton.setAccessibilityLabel(
            Self.runtimeOnlyWarningSettingsButtonText()
        )
        runtimeOnlyWarningSettingsButton.setContentHuggingPriority(.required, for: .horizontal)
        runtimeOnlyWarningSettingsButton.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )
        let runtimeOnlyWarningRow = Self.makeWarningRow(
            label: runtimeOnlyWarningLabel,
            settingsButton: runtimeOnlyWarningSettingsButton,
            identifier: Self.runtimeOnlyWarningRowIdentifier
        )
        overflowWarningRow.isHidden = !input.statusItemVisibility.isHiddenByMenuBarSpace
        runtimeOnlyWarningRow.isHidden = !input.statusItemVisibility.isHiddenByRuntimePolicy
        self.overflowWarningLabel = overflowWarningLabel
        self.overflowWarningSettingsButton = overflowWarningSettingsButton
        self.overflowWarningRow = overflowWarningRow
        self.runtimeOnlyWarningLabel = runtimeOnlyWarningLabel
        self.runtimeOnlyWarningSettingsButton = runtimeOnlyWarningSettingsButton
        self.runtimeOnlyWarningRow = runtimeOnlyWarningRow
        let quotaWindowPreferenceRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageQuotaDisplayPriority),
            subtitle: tr(.keyDashboardMenuBarPageQuotaDisplayPriorityDescription),
            control: quotaWindowPreferenceControl
        )
        self.quotaWindowPreferenceRow = quotaWindowPreferenceRow
        self.autoSwitchLunaReserveRow = nil
        self.lunaReserveResetTimeRow = nil
        let autoSwitchLunaReserveRow: NSView?
        let lunaReserveResetTimeRow: NSView?
        if let autoSwitchLunaReserve, let lunaReserveResetTimeModeControl {
            let autoSwitchRow = DashboardSettingsComponents.makeSettingsRow(
                tr(
                    .keyDashboardMenuBarPageAutoSwitchLunaReserve,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                subtitle: tr(
                    .keyDashboardMenuBarPageAutoSwitchLunaReserveDescription,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                control: autoSwitchLunaReserve
            )
            let resetTimeRow = DashboardSettingsComponents.makeSettingsRow(
                tr(
                    .keyDashboardMenuBarPageLunaReserveResetTime,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                subtitle: tr(
                    .keyDashboardMenuBarPageLunaReserveResetTimeDescription,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                control: lunaReserveResetTimeModeControl
            )
            self.autoSwitchLunaReserveRow = autoSwitchRow
            self.lunaReserveResetTimeRow = resetTimeRow
            autoSwitchLunaReserveRow = autoSwitchRow
            lunaReserveResetTimeRow = resetTimeRow
        } else {
            autoSwitchLunaReserveRow = nil
            lunaReserveResetTimeRow = nil
        }
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
        iconDisplayDelayRow.isHidden = input.preferences.menuBarIconDisplayMode != .onlyWhileRunning
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
            subtitle: tr(.keyDashboardMenuBarPagePlayTheIconAnimationWhileATaskIsRunningDescription),
            control: animationToggle
        )
        self.animationRow = animationRow
        let animationModeSubtitle = Self.animationModeDescription(
            mode: input.preferences.menuBarAnimationMode
        )
        let animationModeTitleLabel = NSTextField(
            wrappingLabelWithString: Self.animationModeTitle()
        )
        animationModeTitleLabel.identifier = NSUserInterfaceItemIdentifier(
            Self.animationModeTitleIdentifier
        )
        self.animationModeTitleLabel = animationModeTitleLabel
        let animationModeSubtitleLabel = InlineRangeLinkTextField()
        animationModeSubtitleLabel.identifier = NSUserInterfaceItemIdentifier(
            Self.animationModeSubtitleIdentifier
        )
        self.animationModeSubtitleLabel = animationModeSubtitleLabel
        let animationModeRow = DashboardSettingsComponents.makeSettingsRow(
            Self.animationModeTitle(),
            titleLabel: animationModeTitleLabel,
            subtitle: animationModeSubtitle,
            subtitleLabel: animationModeSubtitleLabel,
            control: animationModeControl
        )
        self.animationModeRow = animationModeRow
        applyAnimationModeSubtitle(mode: input.preferences.menuBarAnimationMode)
        let animationFrameRateSubtitle = Self.animationFrameRateSubtitleContent(
            mode: input.preferences.menuBarAnimationMode,
            fps: input.preferences.menuBarAnimationFrameRate
        )
        let animationFrameRateSubtitleLabel = DashboardSettingsComponents.makeSubtitleLabel(
            animationFrameRateSubtitle
        )
        animationFrameRateSubtitleLabel.identifier = NSUserInterfaceItemIdentifier(
            Self.animationFrameRateIdentifier + "Subtitle"
        )
        self.animationFrameRateSubtitleLabel = animationFrameRateSubtitleLabel
        let animationFrameRateRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuBarPageAnimationFrameRate),
            subtitleContent: animationFrameRateSubtitle,
            subtitleLabel: animationFrameRateSubtitleLabel,
            control: animationFrameRateControl
        )
        animationFrameRateRow.identifier = NSUserInterfaceItemIdentifier(
            Self.animationFrameRateRowIdentifier
        )
        self.animationFrameRateRow = animationFrameRateRow
        let previewSection = DashboardSettingsComponents.makeSettingsSection(tr(.keyDashboardMenuBarPagePreview), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardMenuBarPageCurrentLayout),
                subtitle: tr(.keyDashboardMenuBarPageTheMenuBarUpdatesWithProviderDataInRealTime),
                control: preview,
                minimumHeight: Self.previewRowHeight,
                verticalPadding: Self.previewRowVerticalPadding
            ),
            iconDisplayModeRow,
            iconDisplayDelayRow,
            overflowWarningRow,
            runtimeOnlyWarningRow
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
            ].compactMap { $0 },
            onLayoutCreated: { [weak self] rowsStack, cardHeightConstraint, separators in
                self?.quotaRowsStack = rowsStack
                self?.quotaCardHeightConstraint = cardHeightConstraint
                self?.quotaSeparators = separators
                self?.updateQuotaVisibility(
                    showAmount: input.preferences.showMenuBarAmount,
                    showReset: input.preferences.showMenuBarReset,
                    autoSwitchLunaReserve: LunaReserveUserFacing.isCurrentlyEnabled
                        && input.preferences.menuBarAutoSwitchLunaReserve
                )
            }
        )
        let iconAndTaskStatusSection = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardMenuBarPageIconAndTaskStatus),
            rows: [
                taskStatusIconRow,
                animationRow,
                animationModeRow,
                animationFrameRateRow,
                animationFallbackWarningRow
            ],
            onLayoutCreated: { [weak self] rowsStack, cardHeightConstraint, separators in
                self?.iconTaskStatusRowsStack = rowsStack
                self?.iconTaskStatusCardHeightConstraint = cardHeightConstraint
                self?.iconTaskStatusSeparators = separators
                self?.updateIconAndTaskStatusVisibility(
                    showTaskStatusIcon: input.preferences.showMenuBarIcon,
                    displayMode: input.preferences.menuBarIconDisplayMode,
                    animationEnabled: input.preferences.animateCodexActivity,
                    animationMode: input.preferences.menuBarAnimationMode
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
                    tr(.keyDashboardMenuBarPageMenuBarIconSize),
                    subtitle: tr(.keyDashboardMenuBarPageAdjustsTheMenuBarIconSize),
                    control: iconSizeControls.view,
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
            statusItemVisibility: input.statusItemVisibility,
            animationActive: input.animationActive,
            animationIconImage: input.animationIconImage,
            animationKind: input.animationKind,
            animationSpriteImage: input.animationSpriteImage,
            animationFallbackActive: input.animationFallbackActive
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
        statusItemVisibility: StatusItemVisibility = .unknown,
        animationActive: Bool = false,
        animationIconImage: NSImage? = nil,
        animationKind: MenuBarCompositorAnimationKind? = nil,
        animationSpriteImage: NSImage? = nil,
        animationFallbackActive: Bool = false
    ) {
        guard isBuilt else { return }
        refreshCallCountForTesting += 1

        let presentation = Self.presentation(
            for: snapshot,
            showAmount: preferences.showMenuBarAmount,
            showReset: preferences.showMenuBarReset,
            quotaResetDisplayMode: preferences.menuBarQuotaResetDisplayMode,
            lunaReserveResetTimeMode: preferences.menuBarLunaReserveResetTimeMode,
            resolving: menuBarSnapshot
        )
        let widthAdjustment = transientWidthAdjustment
            ?? preferences.menuBarStatusItemWidthAdjustment
        let warningSignature = WarningRefreshSignature(
            hiddenByMenuBarSpace: statusItemVisibility.isHiddenByMenuBarSpace,
            hiddenByRuntimePolicy: statusItemVisibility.isHiddenByRuntimePolicy,
            language: AppLanguage.resolved.rawValue
        )
        let settingsSignature = SettingsRefreshSignature(
            language: AppLanguage.resolved.rawValue,
            showIcon: preferences.showMenuBarIcon,
            showAmount: preferences.showMenuBarAmount,
            showReset: preferences.showMenuBarReset,
            fontSizePreset: preferences.menuBarFontSizePreset.rawValue,
            iconSizePreset: preferences.menuBarIconSizePreset.rawValue,
            iconOffsetY: preferences.menuBarIconOffsetY,
            amountOffsetY: preferences.menuBarAmountOffsetY,
            quotaWindowPreference: preferences.menuBarQuotaWindowPreference.rawValue,
            quotaResetDisplayMode: preferences.menuBarQuotaResetDisplayMode.rawValue,
            autoSwitchLunaReserve: preferences.menuBarAutoSwitchLunaReserve,
            lunaReserveResetTimeMode: preferences.menuBarLunaReserveResetTimeMode.rawValue,
            iconDisplayMode: preferences.menuBarIconDisplayMode.rawValue,
            iconDisplayDelay: preferences.menuBarIconDisplayDelay.rawValue,
            animationEnabled: preferences.animateCodexActivity,
            animationMode: preferences.menuBarAnimationMode.rawValue,
            animationFrameRate: preferences.menuBarAnimationFrameRate,
            widthAdjustment: widthAdjustment,
            horizontalPadding: preferences.menuBarHorizontalPadding,
            synchronizeWidthSlider: transientWidthAdjustment == nil
        )
        let previewSignature = PreviewRefreshSignature(
            presentation: presentation,
            showIcon: preferences.showMenuBarIcon,
            showAmount: preferences.showMenuBarAmount,
            fontSizePreset: preferences.menuBarFontSizePreset.rawValue,
            iconSizePreset: preferences.menuBarIconSizePreset.rawValue,
            iconOffsetX: preferences.menuBarIconOffsetX,
            iconOffsetY: preferences.menuBarIconOffsetY,
            amountOffsetX: preferences.menuBarAmountOffsetX,
            amountOffsetY: preferences.menuBarAmountOffsetY,
            horizontalPadding: preferences.menuBarHorizontalPadding,
            iconImageIdentity: iconImage.map(ObjectIdentifier.init),
            iconImageSize: iconImage?.size ?? .zero,
            iconImageIsTemplate: iconImage?.isTemplate ?? false,
            previewBackgroundBounds: resolvedPreviewBackgroundBounds(fallbackWidth: 0),
            previewIconBounds: previewIcon.bounds,
            backingScale: max(previewIcon.window?.backingScaleFactor ?? 2, 1),
            appearance: previewIcon.effectiveAppearance.name.rawValue,
            animationActive: animationKind?.isActive ?? animationActive,
            animationKind: animationKind ?? (animationActive ? .codexRotation : .none),
            animationSpriteImageIdentity: animationSpriteImage.map(ObjectIdentifier.init),
            animationSpriteImageSize: animationSpriteImage?.size ?? .zero,
            animationSpriteImageIsTemplate: animationSpriteImage?.isTemplate ?? false,
            animationFallbackActive: animationFallbackActive,
            animationFrameRate: preferences.menuBarAnimationFrameRate
        )
        let refreshSignature = RefreshSignature(
            warning: warningSignature,
            settings: settingsSignature,
            preview: previewSignature
        )
        guard refreshSignature != lastRefreshSignature else {
            refreshSkipCountForTesting += 1
            return
        }

        if settingsSignature != lastSettingsRefreshSignature {
            settingsRefreshCountForTesting += 1
        }
        if previewSignature != lastPreviewRefreshSignature {
            previewRefreshCountForTesting += 1
        }

        refreshUnconditionally(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: menuBarSnapshot,
            iconImage: iconImage,
            statusItemVisibility: statusItemVisibility,
            animationActive: animationKind?.isActive ?? animationActive,
            animationIconImage: animationIconImage,
            animationKind: animationKind ?? (animationActive ? .codexRotation : .none),
            animationSpriteImage: animationSpriteImage
        )
        lastRefreshSignature = refreshSignature
        lastWarningRefreshSignature = warningSignature
        lastSettingsRefreshSignature = settingsSignature
        lastPreviewRefreshSignature = previewSignature
        refreshApplyCountForTesting += 1
    }

    private func refreshUnconditionally(
        snapshot: Snapshot,
        preferences: AppPreferences,
        menuBarSnapshot: (Snapshot) -> Snapshot,
        iconImage: NSImage?,
        statusItemVisibility: StatusItemVisibility = .unknown,
        animationActive: Bool,
        animationIconImage: NSImage?,
        animationKind: MenuBarCompositorAnimationKind,
        animationSpriteImage: NSImage?
    ) {
        guard isBuilt else { return }
        updatePreviewWarnings(statusItemVisibility)
        previewIconSlot.isHidden = !preferences.showMenuBarIcon
        previewText.isHidden = !preferences.showMenuBarAmount
        iconSwitch?.isEnabled = preferences.showMenuBarAmount
        amountSwitch?.isEnabled = preferences.showMenuBarIcon
        let fontSizePreset = preferences.menuBarFontSizePreset
        let iconSizePreset = preferences.menuBarIconSizePreset
        let iconSize = iconSizePreset.pointSize
        applyPreviewIconSize(iconSize)
        let fontSize = fontSizePreset.primarySize
        let secondaryFontSize = fontSizePreset.secondarySize
        let primaryFont = MenuBarLayout.primaryFont(
            size: CGFloat(fontSize)
        )
        if previewPrimary.font != primaryFont {
            previewPrimary.font = primaryFont
        }
        let secondaryFont = MenuBarLayout.secondaryFont(
            size: CGFloat(secondaryFontSize)
        )
        if previewSecondary.font != secondaryFont {
            previewSecondary.font = secondaryFont
        }
        let presentation = Self.presentation(
            for: snapshot,
            showAmount: preferences.showMenuBarAmount,
            showReset: preferences.showMenuBarReset,
            quotaResetDisplayMode: preferences.menuBarQuotaResetDisplayMode,
            lunaReserveResetTimeMode: preferences.menuBarLunaReserveResetTimeMode,
            resolving: menuBarSnapshot
        )
        MenuBarLayout.applyPrimaryText(presentation.primary, to: previewPrimary)
        if previewSecondary.stringValue != presentation.secondary {
            previewSecondary.stringValue = presentation.secondary
        }
        let hasSecondary = presentation.hasSecondary
        let geometry = MenuBarLayout.geometry(
            primarySize: previewPrimary.intrinsicContentSize,
            secondarySize: previewSecondary.intrinsicContentSize,
            showIcon: preferences.showMenuBarIcon,
            showAmount: preferences.showMenuBarAmount,
            hasSecondary: hasSecondary,
            isBalance: presentation.isBalance,
            iconSlotWidth: iconSize
        )
        MenuBarLayout.applyTextLayout(
            container: previewText,
            primary: previewPrimary,
            secondary: previewSecondary,
            geometry: geometry,
            showAmount: preferences.showMenuBarAmount,
            hasSecondary: hasSecondary
        )
        if textWidthConstraint?.constant != geometry.textWidth {
            textWidthConstraint?.constant = geometry.textWidth
        }
        let displayedPreviewIcon = Self.displayedPreviewIconImage(
            animationKind: animationKind,
            iconImage: iconImage,
            animationIconImage: animationIconImage
        )
        lastPreviewIconImage = displayedPreviewIcon
        if let animationSpriteImage {
            lastPreviewSpriteImage = animationSpriteImage
        }
        if previewIcon.image !== displayedPreviewIcon {
            previewIcon.image = displayedPreviewIcon
        }
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
        updateQuotaVisibility(
            showAmount: preferences.showMenuBarAmount,
            showReset: preferences.showMenuBarReset,
            autoSwitchLunaReserve: LunaReserveUserFacing.isCurrentlyEnabled
                && preferences.menuBarAutoSwitchLunaReserve
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
        animationSwitch?.state = preferences.animateCodexActivity ? .on : .off
        if let animationModeControl,
           let selectedIndex = MenuBarAnimationMode.displayOrder.firstIndex(
               of: preferences.menuBarAnimationMode
           ) {
            if animationModeControl.indexOfSelectedItem != selectedIndex {
                animationModeControl.selectItem(at: selectedIndex)
            }
            animationModeControl.synchronizeTitleAndSelectedItem()
            animationModeControl.toolTip = Self.animationModeDescription(
                mode: preferences.menuBarAnimationMode
            )
        }
        applyAnimationModeSubtitle(mode: preferences.menuBarAnimationMode)
        animationFrameRate = preferences.menuBarAnimationFrameRate
        animationFrameRateEditor.setDisplayedValue(preferences.menuBarAnimationFrameRate)
        animationFrameRateUnitLabel?.stringValue = tr(
            .keyDashboardMenuBarPageAnimationFrameRateUnit
        )
        DashboardSettingsComponents.updateSubtitleLabel(
            animationFrameRateSubtitleLabel,
            with: Self.animationFrameRateSubtitleContent(
                mode: preferences.menuBarAnimationMode,
                fps: preferences.menuBarAnimationFrameRate
            )
        )
        updateIconAndTaskStatusVisibility(
            showTaskStatusIcon: preferences.showMenuBarIcon,
            displayMode: preferences.menuBarIconDisplayMode,
            animationEnabled: preferences.animateCodexActivity,
            animationMode: preferences.menuBarAnimationMode
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
                    isBalance: presentation.isBalance,
                    iconSlotWidth: iconSize
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
        updatePreviewAnimation(
            kind: animationKind,
            iconImage: displayedPreviewIcon,
            spriteImage: animationSpriteImage
        )
    }

    /// Idle preview must use the live source icon. A leftover animation cache
    /// can still hold the previous client's bitmap after Grok/Claude thinking
    /// stops (Issue #332).
    private static func displayedPreviewIconImage(
        animationKind: MenuBarCompositorAnimationKind,
        iconImage: NSImage?,
        animationIconImage: NSImage?
    ) -> NSImage? {
        animationKind.isActive ? (animationIconImage ?? iconImage) : iconImage
    }

    private func updatePreviewWarnings(_ statusItemVisibility: StatusItemVisibility) {
        guard let overflowWarningLabel,
              let overflowWarningRow,
              let runtimeOnlyWarningLabel,
              let runtimeOnlyWarningRow else { return }
        let signature = WarningRefreshSignature(
            hiddenByMenuBarSpace: statusItemVisibility.isHiddenByMenuBarSpace,
            hiddenByRuntimePolicy: statusItemVisibility.isHiddenByRuntimePolicy,
            language: AppLanguage.resolved.rawValue
        )
        guard signature != lastWarningRefreshSignature else { return }
        lastWarningRefreshSignature = signature
        warningRefreshCountForTesting += 1
        let shouldShowOverflowWarning = statusItemVisibility.isHiddenByMenuBarSpace
        let shouldShowRuntimeOnlyWarning = statusItemVisibility.isHiddenByRuntimePolicy
        overflowWarningLabel.stringValue = Self.overflowWarningText()
        overflowWarningSettingsButton?.title = Self.overflowWarningSettingsButtonText()
        overflowWarningSettingsButton?.toolTip = Self.overflowWarningSettingsButtonText()
        overflowWarningSettingsButton?.setAccessibilityLabel(
            Self.overflowWarningSettingsButtonText()
        )
        runtimeOnlyWarningLabel.stringValue = Self.runtimeOnlyWarningText()
        runtimeOnlyWarningSettingsButton?.title = Self.runtimeOnlyWarningSettingsButtonText()
        runtimeOnlyWarningSettingsButton?.toolTip = Self.runtimeOnlyWarningSettingsButtonText()
        runtimeOnlyWarningSettingsButton?.setAccessibilityLabel(
            Self.runtimeOnlyWarningSettingsButtonText()
        )
        overflowWarningLabel.isHidden = !shouldShowOverflowWarning
        overflowWarningRow.isHidden = !shouldShowOverflowWarning
        runtimeOnlyWarningLabel.isHidden = !shouldShowRuntimeOnlyWarning
        runtimeOnlyWarningRow.isHidden = !shouldShowRuntimeOnlyWarning
        updatePreviewSeparators()
    }

    private func updatePreviewSeparators() {
        // Current layout and menu bar display stay visible. Delay follows
        // Only While Running; warnings come last:
        // current layout → menu bar display → delay → overflow → runtime.
        let visibleRows = [
            true,
            true,
            iconDisplayDelayRow?.isHidden == false,
            overflowWarningRow?.isHidden == false,
            runtimeOnlyWarningRow?.isHidden == false
        ]
        for (index, separator) in previewSeparators.enumerated() {
            guard index + 1 < visibleRows.count else {
                separator.isHidden = true
                continue
            }
            let hasVisibleRowAfter = visibleRows[(index + 1)...].contains(true)
            separator.isHidden = !(visibleRows[index] && hasVisibleRowAfter)
        }
        updatePreviewCardLayout()
    }

    private func updatePreviewCardLayout() {
        guard let previewRowsStack,
              let previewCardHeightConstraint else { return }
        previewCardLayoutCountForTesting += 1
        previewRowsStack.needsLayout = true
        previewCardHeightConstraint.constant = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: previewRowsStack,
            separators: previewSeparators
        )
        previewRowsStack.superview?.invalidateIntrinsicContentSize()
        previewRowsStack.superview?.needsLayout = true
        previewRowsStack.superview?.superview?.needsLayout = true
    }

    private func revealIconDisplayModeSetting() {
        guard let destination = iconDisplayModeRow else { return }
        destination.window?.layoutIfNeeded()

        // Expand the requested rect by the available viewport margin so that
        // scrollToVisible places the row with comfortable space around it
        // instead of stopping as soon as its bottom edge becomes visible.
        guard let scrollView = destination.enclosingScrollView else {
            destination.scrollToVisible(destination.bounds)
            return
        }
        let viewportHeight = scrollView.contentView.bounds.height
        let verticalMargin = max(0, (viewportHeight - destination.bounds.height) / 2)
        let revealRect = destination.bounds.insetBy(dx: 0, dy: -verticalMargin)
        destination.scrollToVisible(revealRect)
        flashIconDisplayModeRevealDestination(destination)
    }

    private func flashIconDisplayModeRevealDestination(_ destination: NSView) {
        destination.wantsLayer = true
        guard let layer = destination.layer else { return }
        let animationKey = Self.iconDisplayModeRevealHighlightAnimationKey
        layer.removeAnimation(forKey: animationKey)

        let baseColor = layer.backgroundColor ?? NSColor.clear.cgColor
        let highlightColor = NSColor.controlAccentColor
            .withAlphaComponent(0.24)
            .cgColor
        let animation = CAKeyframeAnimation(keyPath: "backgroundColor")
        animation.values = [baseColor, highlightColor, baseColor]
        animation.keyTimes = [0, 0.25, 1]
        animation.duration = Self.iconDisplayModeRevealHighlightDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.backgroundColor = baseColor
        layer.add(animation, forKey: animationKey)
    }

    private func removeIconDisplayModeRevealHighlight() {
        let animationKey = Self.iconDisplayModeRevealHighlightAnimationKey
        iconDisplayModeRow?.layer?.removeAnimation(forKey: animationKey)
        taskStatusIconRow?.layer?.removeAnimation(forKey: animationKey)
    }

    private func updateQuotaVisibility(
        showAmount: Bool,
        showReset: Bool,
        autoSwitchLunaReserve: Bool
    ) {
        let signature = [showAmount, showReset, autoSwitchLunaReserve]
        guard signature != lastQuotaVisibilitySignature else { return }
        lastQuotaVisibilitySignature = signature
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
        quotaCardLayoutCountForTesting += 1
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
        displayMode: MenuBarIconDisplayMode,
        animationEnabled: Bool,
        animationMode: MenuBarAnimationMode
    ) {
        let showDependentRows = showTaskStatusIcon
        let showDelay = displayMode == .onlyWhileRunning
        let showAnimationMode = showDependentRows && animationEnabled
        let showFallbackWarning = showAnimationMode
            && animationMode == .efficient
            && animationFallbackActive
        let signature = IconTaskVisibilitySignature(
            showIcon: showTaskStatusIcon,
            showDelay: showDelay,
            showAnimationMode: showAnimationMode,
            showFallbackWarning: showFallbackWarning
        )
        guard signature != lastIconTaskVisibilitySignature else { return }
        lastIconTaskVisibilitySignature = signature
        animationRow?.isHidden = !showDependentRows
        iconDisplayDelayRow?.isHidden = !showDelay
        animationModeRow?.isHidden = !showAnimationMode
        animationModeControl?.isEnabled = showAnimationMode
        animationFrameRateRow?.isHidden = !showAnimationMode
        animationFrameRateField?.isEnabled = showAnimationMode
        animationFallbackWarningRow?.isHidden = !showFallbackWarning
        animationFallbackWarningLabel?.stringValue = Self.animationFallbackWarningText()
        updatePreviewSeparators()

        // Delay now lives on the preview card. Icon rows are task status →
        // animation → animation mode → frame rate → fallback warning.
        let visibleRows = [
            true,
            showDependentRows,
            showAnimationMode,
            showAnimationMode,
            showFallbackWarning
        ]
        for (index, separator) in iconTaskStatusSeparators.enumerated() {
            guard index < visibleRows.count - 1 else {
                separator.isHidden = true
                continue
            }
            let hasVisibleRowAfter = visibleRows[(index + 1)...].contains(true)
            separator.isHidden = !(visibleRows[index] && hasVisibleRowAfter)
        }
        updateIconTaskStatusCardLayout()
    }

    private func updateIconTaskStatusCardLayout() {
        guard let iconTaskStatusRowsStack,
              let iconTaskStatusCardHeightConstraint else { return }
        iconTaskCardLayoutCountForTesting += 1
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

    private func makeIconSizePresetControls(
        value: MenuBarIconSizePreset,
        relay: DashboardPreferencePageRelay
    ) -> FontPresetControls {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.iconSizePresetIdentifier,
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
        control.widthAnchor.constraint(equalToConstant: Self.iconSizePresetWidth).isActive = true
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

    private func applyAnimationModeSubtitle(mode: MenuBarAnimationMode) {
        animationModeTitleLabel?.stringValue = Self.animationModeTitle()
        let text = Self.animationModeDescription(mode: mode)
        let phrase = mode == .efficient ? Self.animationModeRestartLinkPhrase() : nil
        let subtitleChanged = animationModeSubtitleLabel?.stringValue != text
            || (animationModeSubtitleLabel?.hasLink ?? false) != (phrase != nil)
        animationModeSubtitleLabel?.setContent(
            text,
            linkPhrase: phrase,
            onActivate: { [weak self] in
                self?.presentAnimationRestartConfirmation()
            }
        )
        guard subtitleChanged else { return }
        DashboardSettingsComponents.notifySettingsRowContentChanged(animationModeSubtitleLabel)
        updateIconTaskStatusCardLayout()
    }

    func presentAnimationRestartConfirmation() {
        if restartConfirmationAlert?.window.sheetParent != nil {
            return
        }
        let hostWindow = animationModeSubtitleLabel?.window
            ?? animationModeRow?.window
        guard let hostWindow else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = tr(.keyDashboardMenuBarPageAnimationModeRestartConfirmation)
        alert.addButton(withTitle: tr(.keyDashboardMenuBarPageAnimationModeRestartConfirm))
        alert.addButton(withTitle: tr(.keyDashboardMenuBarPageAnimationModeRestartCancel))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.buttons[1].keyEquivalentModifierMask = []
        restartConfirmationAlert = alert
        alert.beginSheetModal(for: hostWindow) { [weak self] response in
            guard let self else { return }
            self.restartConfirmationAlert = nil
            if response == .alertFirstButtonReturn {
                self.persistRestoreToken(self.restoreSnapshotProvider())
                self.relaunchApplication()
            }
        }
    }

    private func dismissRestartConfirmation() {
        guard let alert = restartConfirmationAlert else { return }
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
        }
        restartConfirmationAlert = nil
    }

    private func makeAnimationModeControl(
        value: MenuBarAnimationMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.animationModeIdentifier,
            items: MenuBarAnimationMode.displayOrder.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.animationModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: MenuBarAnimationMode.displayOrder.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarAnimationMode(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = Self.animationModeDescription(mode: value)
        return control
    }

    private func makeAnimationFrameRateControl(
        value: Int,
        relay: DashboardPreferencePageRelay
    ) -> NSView {
        let clamped = MenuBarAnimationTiming.clampedFrameRate(value)
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier(Self.animationFrameRateIdentifier)
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.integerValue = clamped
        field.toolTip = tr(.keyDashboardMenuBarPageAnimationFrameRateDescription)
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.delegate = animationFrameRateEditor
        field.target = animationFrameRateEditor
        field.action = #selector(AnimationFrameRateEditor.fieldAction(_:))
        animationFrameRateField = field

        let unit = NSTextField(labelWithString: tr(.keyDashboardMenuBarPageAnimationFrameRateUnit))
        unit.font = .systemFont(ofSize: 13)
        unit.setContentHuggingPriority(.required, for: .horizontal)
        unit.setContentCompressionResistancePriority(.required, for: .horizontal)
        animationFrameRateUnitLabel = unit

        animationFrameRateEditor.field = field
        animationFrameRateEditor.onChange = { [weak relay] fps in
            relay?.commitMenuBarAnimationFrameRate(fps)
        }

        let stack = NSStackView(views: [field, unit])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    static func animationFrameRateSubtitle(
        mode: MenuBarAnimationMode,
        fps: Int,
        language: AppLanguage = .selected
    ) -> String {
        animationFrameRateSubtitleContent(mode: mode, fps: fps, language: language).text
    }

    static func animationFrameRateSubtitleContent(
        mode: MenuBarAnimationMode,
        fps: Int,
        language: AppLanguage = .selected
    ) -> LocalizedSubtitle {
        let line1 = tr(
            .keyDashboardMenuBarPageAnimationFrameRateDescription,
            language: language
        )
        let line2: String
        switch mode {
        case .synchronized:
            let range = MenuBarAnimationCPUEstimate.synchronizedRange(fps: fps)
            line2 = tr(
                .keyDashboardMenuBarPageAnimationFrameRateCPUEstimateRange,
                arguments: ["\(range.low)", "\(range.high)"],
                language: language
            )
        case .efficient:
            let estimate = MenuBarAnimationCPUEstimate.percent(mode: mode, fps: fps)
            line2 = tr(
                .keyDashboardMenuBarPageAnimationFrameRateCPUEstimate,
                arguments: ["\(estimate)"],
                language: language
            )
        }
        let text = "\(line1)\n\(line2)"
        let offset = (line1 as NSString).length + 1
        let emphasis = Self.cpuEstimatePercentRanges(in: line2).map { range in
            NSRange(location: range.location + offset, length: range.length)
        }
        return LocalizedSubtitle(text: text, emphasisGroups: emphasis)
    }

    private static let cpuEstimatePercentRegex = try! NSRegularExpression(
        pattern: #"\d+\s*%(?:–\d+\s*%)?"#
    )

    private static func cpuEstimatePercentRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        return cpuEstimatePercentRegex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ).map(\.range)
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
        control.toolTip = tr(
            .keyDashboardMenuBarPageLunaReserveResetTimeDescription,
            arguments: [tr(.keyLunaReserveTitle)]
        )
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

    private static func animationModeLabel(_ mode: MenuBarAnimationMode) -> String {
        switch mode {
        case .efficient:
            return tr(.keyDashboardMenuBarPageAnimationModeEfficient)
        case .synchronized:
            return tr(.keyDashboardMenuBarPageAnimationModeSynchronized)
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
            return tr(
                .keyDashboardMenuBarPageLunaReserveResetTimeLunaReserve,
                arguments: [tr(.keyLunaReserveTitle)]
            )
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

    private func applyPreviewIconSize(_ iconSize: CGFloat) {
        if previewIconWidthConstraint?.constant != iconSize {
            previewIconWidthConstraint?.constant = iconSize
        }
        if previewIconHeightConstraint?.constant != iconSize {
            previewIconHeightConstraint?.constant = iconSize
        }
        if previewIconSlotWidthConstraint?.constant != iconSize {
            previewIconSlotWidthConstraint?.constant = iconSize
        }
        if previewIconSlotHeightConstraint?.constant != iconSize {
            previewIconSlotHeightConstraint?.constant = iconSize
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
