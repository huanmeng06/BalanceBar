import AppKit
import QuartzCore

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
    static let rightClickActionIdentifier = AppPreferences.menuBarRightClickActionKey
    static let reverseMouseButtonsIdentifier = AppPreferences.menuBarReverseMouseButtonsKey
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
    static let previewRowVerticalPadding: CGFloat = 10
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
        let rightClickAction: String
        let reverseMouseButtons: Bool
        let animationEnabled: Bool
        let animationMode: String
        let animationFrameRate: Int
        let widthAdjustment: Double
        let horizontalPadding: CGFloat
        let synchronizeWidthSlider: Bool
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

    private let previewSection = DashboardMenuBarPreviewSection()
    private let quotaSection = DashboardMenuBarQuotaSection()
    private let iconTaskSection = DashboardMenuBarIconTaskStatusSection()
    private let behaviorSection = DashboardMenuBarBehaviorSection()
    private let layoutSection = DashboardMenuBarLayoutSection()

    var relaunchApplication: () -> Void = DashboardMenuBarPage.relaunchCurrentApplication {
        didSet { iconTaskSection.relaunchApplication = relaunchApplication }
    }
    var restoreSnapshotProvider: () -> DashboardRestoreToken = {
        DashboardRestoreToken(section: .menuBar, scrollOffsetY: 0)
    } {
        didSet { iconTaskSection.restoreSnapshotProvider = restoreSnapshotProvider }
    }
    var persistRestoreToken: (DashboardRestoreToken) -> Void = { token in
        DashboardRestoreStore.record(token)
    } {
        didSet { iconTaskSection.persistRestoreToken = persistRestoreToken }
    }
    var restartConfirmationAlertForTesting: NSAlert? {
        iconTaskSection.restartConfirmationAlertForTesting
    }
    private var transientWidthAdjustment: Double?
    private var lastRefreshSignature: RefreshSignature?
    private var lastWarningRefreshSignature: WarningRefreshSignature?
    private var lastSettingsRefreshSignature: SettingsRefreshSignature?
    private var lastPreviewRefreshSignature: PreviewRefreshSignature?
    private(set) var refreshCallCountForTesting = 0
    private(set) var refreshApplyCountForTesting = 0
    private(set) var refreshSkipCountForTesting = 0
    var warningRefreshCountForTesting: Int {
        previewSection.warningRefreshCountForTesting
    }
    private(set) var settingsRefreshCountForTesting = 0
    private(set) var previewRefreshCountForTesting = 0
    var previewCardLayoutCountForTesting: Int {
        previewSection.previewCardLayoutCountForTesting
    }
    var quotaCardLayoutCountForTesting: Int {
        quotaSection.quotaCardLayoutCountForTesting
    }
    var iconTaskCardLayoutCountForTesting: Int {
        iconTaskSection.iconTaskCardLayoutCountForTesting
    }
    private var isBuilt = false

    var previewAnimationHostForTesting: MenuBarNativeAnimatedIconHostView {
        previewSection.previewAnimationHostForTesting
    }

    var previewClaudeAnimationHostForTesting: MenuBarClaudeAnimatedIconHostView {
        previewSection.previewClaudeAnimationHostForTesting
    }

    deinit {
        previewSection.removeIconDisplayModeRevealHighlight()
        iconTaskSection.removeRevealHighlight()
        layoutSection.teardown()
    }

    func teardown() {
        previewSection.teardown()
        iconTaskSection.teardown()
        layoutSection.teardown()
        resetRefreshSignatures()
    }

    /// Cached pages remain mounted in memory but detached from the content
    /// pane. Stop compositor work while the page is hidden and force the next
    /// activation through the normal bounded refresh path.
    func suspend() {
        previewSection.suspend()
        resetRefreshSignatures()
    }

    func activate() {
        previewSection.activate()
    }

    private func resetRefreshSignatures() {
        lastRefreshSignature = nil
        lastWarningRefreshSignature = nil
        lastSettingsRefreshSignature = nil
        lastPreviewRefreshSignature = nil
        quotaSection.resetRefreshSignatures()
        iconTaskSection.resetRefreshSignatures()
        previewSection.resetWarningSignature()
    }

    func updatePreviewIcon(_ image: NSImage?) {
        previewSection.updatePreviewIcon(image)
    }

    func updatePreviewAnimation(
        kind: MenuBarCompositorAnimationKind,
        iconImage: NSImage?,
        spriteImage: NSImage?
    ) {
        previewSection.animationFrameRate = iconTaskSection.animationFrameRate
        previewSection.updatePreviewAnimation(
            kind: kind,
            iconImage: iconImage,
            spriteImage: spriteImage
        )
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
        iconTaskSection.animationFallbackActive = active
        guard isBuilt else { return }
        iconTaskSection.updateVisibility(
            showTaskStatusIcon: showTaskStatusIcon,
            displayMode: displayMode,
            animationEnabled: animationEnabled,
            animationMode: animationMode
        )
    }

    func make(_ input: Input) -> NSView {
        resetRefreshSignatures()
        iconTaskSection.animationFallbackActive = input.animationFallbackActive
        iconTaskSection.relaunchApplication = relaunchApplication
        iconTaskSection.restoreSnapshotProvider = restoreSnapshotProvider
        iconTaskSection.persistRestoreToken = persistRestoreToken
        iconTaskSection.onDelayVisibilityChanged = { [weak self] showDelay in
            self?.previewSection.updateDelayVisibility(showDelay: showDelay)
        }
        previewSection.animationFrameRate = input.preferences.menuBarAnimationFrameRate

        let previewSectionView = previewSection.make(input: input)
        let quotaAndResetSection = quotaSection.make(input: input)
        let iconAndTaskStatusSection = iconTaskSection.make(input: input)
        let behaviorSectionView = behaviorSection.make(input: input)
        let layoutSectionView = layoutSection.make(
            input: input,
            transientWidthAdjustment: transientWidthAdjustment
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
        return DashboardSettingsComponents.makeSettingsPageContent([
            previewSectionView,
            quotaAndResetSection,
            iconAndTaskStatusSection,
            behaviorSectionView,
            layoutSectionView
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
            rightClickAction: preferences.menuBarRightClickAction.rawValue,
            reverseMouseButtons: preferences.menuBarReverseMouseButtons,
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
            previewBackgroundBounds: previewSection.resolvedPreviewBackgroundBounds(fallbackWidth: 0),
            previewIconBounds: previewSection.previewIconBounds,
            backingScale: max(previewSection.previewIconBackingScale, 1),
            appearance: previewSection.previewIconAppearanceName,
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
        let presentation = Self.presentation(
            for: snapshot,
            showAmount: preferences.showMenuBarAmount,
            showReset: preferences.showMenuBarReset,
            quotaResetDisplayMode: preferences.menuBarQuotaResetDisplayMode,
            lunaReserveResetTimeMode: preferences.menuBarLunaReserveResetTimeMode,
            resolving: menuBarSnapshot
        )
        previewSection.updateWarnings(statusItemVisibility)
        previewSection.animationFrameRate = preferences.menuBarAnimationFrameRate
        iconTaskSection.setIconSwitchEnabled(preferences.showMenuBarAmount)
        quotaSection.setAmountSwitchEnabled(preferences.showMenuBarIcon)
        previewSection.refreshVisuals(
            preferences: preferences,
            presentation: presentation,
            iconImage: iconImage,
            animationIconImage: animationIconImage,
            animationKind: animationKind,
            animationSpriteImage: animationSpriteImage
        )
        let widthAdjustment = transientWidthAdjustment
            ?? preferences.menuBarStatusItemWidthAdjustment
        layoutSection.refresh(
            preferences: preferences,
            widthAdjustment: widthAdjustment,
            synchronizeWidthSlider: transientWidthAdjustment == nil
        )
        quotaSection.refresh(preferences: preferences)
        previewSection.applyIconDisplayControls(
            mode: preferences.menuBarIconDisplayMode,
            delay: preferences.menuBarIconDisplayDelay
        )
        behaviorSection.refresh(
            rightClickAction: preferences.menuBarRightClickAction,
            reverseMouseButtons: preferences.menuBarReverseMouseButtons
        )
        iconTaskSection.refresh(preferences: preferences)
        applyWidthAdjustment(
            widthAdjustment,
            horizontalPadding: preferences.menuBarHorizontalPadding,
            synchronizeSlider: transientWidthAdjustment == nil
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
            previewSection.applyCapsuleWidth(
                widthAdjustment,
                horizontalPadding: horizontalPadding
            )
            layoutSection.applyWidthAdjustment(
                widthAdjustment,
                synchronizeSlider: synchronizeSlider
            )
        }
    }

    func restoreRequiredToggle(identifier: String) {
        switch identifier {
        case "showMenuBarIcon":
            iconTaskSection.restoreIconToggle()
        case "showMenuBarAmount":
            quotaSection.restoreAmountToggle()
        default:
            break
        }
    }

    func presentAnimationRestartConfirmation() {
        iconTaskSection.presentAnimationRestartConfirmation()
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
}
