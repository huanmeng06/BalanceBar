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

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onEditingEnded?()
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        onEditingEnded?()
    }

}

final class DashboardMenuBarPage {
    static let iconOffsetsResetIdentifier = "menuBarIconOffsetsReset"
    static let amountOffsetsResetIdentifier = "menuBarAmountOffsetsReset"
    static let iconOffsetSummaryIdentifier = "menuBarIconOffsetSummary"
    static let amountOffsetSummaryIdentifier = "menuBarAmountOffsetSummary"
    static let widthAdjustmentSummaryIdentifier = "menuBarStatusItemWidthAdjustmentSummary"
    static let fontSizePresetIdentifier = AppPreferences.menuBarFontSizePresetKey
    static let widthAdjustmentSliderMinimumIdentifier = "menuBarStatusItemWidthAdjustmentMinimum"
    static let widthAdjustmentSliderMaximumIdentifier = "menuBarStatusItemWidthAdjustmentMaximum"
    static let widthAdjustmentSliderWidth: CGFloat = 140
    // Match the compact native popup used by the Application settings page.
    // Screenshots are commonly captured at 2x scale, so this is 100 points
    // (about 200 pixels), not the previous 180-point control.
    static let fontSizePresetWidth: CGFloat = 100
    /// Extra default lift for the amount text in the Dashboard preview only
    /// (visual, positive = up). The real menu bar layout is unchanged; user
    /// fine-tune offsets stack on top.
    static let previewAmountDefaultYOffset: CGFloat = 0.5
    static let previewPrimaryIdentifier = "menuBarPreviewPrimary"
    static let previewSecondaryIdentifier = "menuBarPreviewSecondary"

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
        resolving snapshotResolver: (Snapshot) -> Snapshot
    ) -> Presentation {
        let effective = snapshotResolver(snapshot)
        let secondary = effective.kind == .official ? effective.menuBarSecondary : ""
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

    struct Input {
        let preferences: AppPreferences
        let snapshot: Snapshot
        let menuBarSnapshot: (Snapshot) -> Snapshot
        let iconImage: NSImage?
        let relay: DashboardPreferencePageRelay
    }

    private struct WidthSliderControls {
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
    private var capsuleLeadingConstraint: NSLayoutConstraint?
    private var capsuleTrailingConstraint: NSLayoutConstraint?
    private var previewWidthConstraint: NSLayoutConstraint?
    private var textWidthConstraint: NSLayoutConstraint?
    private var iconOffsetSummaryLabel: NSTextField?
    private var amountOffsetSummaryLabel: NSTextField?
    private var widthAdjustmentSummaryLabel: NSTextField?
    private var iconOffsetButtons: [NSButton] = []
    private var amountOffsetButtons: [NSButton] = []
    private weak var widthAdjustmentSlider: NSSlider?
    private weak var fontSizePresetControl: NSPopUpButton?
    private var transientWidthAdjustment: Double?
    private let chromeInset: CGFloat = 10
    private var isBuilt = false

    func make(_ input: Input) -> NSView {
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
        iconSwitch = iconToggle
        amountSwitch = amountToggle
        let previewSection = DashboardSettingsComponents.makeSettingsSection(tr("预览", "Preview", "預覽", "プレビュー"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("当前布局", "Current Layout", "目前版面", "現在のレイアウト"),
                subtitle: tr("菜单栏会随供应商数据实时更新", "The menu bar updates with Provider data in real time", "選單列會隨供應商資料即時更新", "メニューバーはプロバイダーデータに応じてリアルタイムに更新されます"),
                control: preview,
                minimumHeight: 66
            )
        ])
        let displaySection = DashboardSettingsComponents.makeSettingsSection(tr("显示项目", "Display Items", "顯示項目", "表示項目"), rows: [
            DashboardSettingsComponents.makeSettingsRow(tr("Agent 图标", "Agent Icon", "Agent 圖示", "エージェントアイコン"), subtitle: tr("显示当前任务运行状态", "Shows the current task status", "顯示目前任務執行狀態", "現在のタスク実行状態を表示"), control: iconToggle),
            DashboardSettingsComponents.makeSettingsRow(tr("额度数字", "Balance Amount", "額度數字", "残高の数値"), subtitle: tr("显示百分比或 API 余额", "Shows a percentage or API balance", "顯示百分比或 API 餘額", "パーセンテージまたは API 残高を表示"), control: amountToggle),
            DashboardSettingsComponents.makeSettingsRow(tr("重置倒计时", "Reset Countdown", "重設倒數計時", "リセットカウントダウン"), subtitle: tr("仅在官方额度可用时显示", "Only shown when official quota data is available", "僅在官方額度可用時顯示", "公式クォータが利用可能な場合のみ表示"), control: resetToggle)
        ])
        let iconOffsetSummary = NSTextField(
            labelWithString: Self.iconOffsetSummaryText(y: input.preferences.menuBarIconOffsetY)
        )
        iconOffsetSummary.identifier = NSUserInterfaceItemIdentifier(Self.iconOffsetSummaryIdentifier)
        let amountOffsetSummary = NSTextField(
            labelWithString: Self.amountOffsetSummaryText(y: input.preferences.menuBarAmountOffsetY)
        )
        amountOffsetSummary.identifier = NSUserInterfaceItemIdentifier(Self.amountOffsetSummaryIdentifier)
        let widthAdjustment = transientWidthAdjustment
            ?? input.preferences.menuBarStatusItemWidthAdjustment
        let widthAdjustmentSummary = NSTextField(labelWithString: Self.widthAdjustmentSummaryText(widthAdjustment))
        widthAdjustmentSummary.identifier = NSUserInterfaceItemIdentifier(Self.widthAdjustmentSummaryIdentifier)
        let iconOffsetControls = makeOffsetControls(
            keyY: AppPreferences.menuBarIconOffsetYKey,
            resetIdentifier: Self.iconOffsetsResetIdentifier,
            relay: input.relay
        )
        let amountOffsetControls = makeOffsetControls(
            keyY: AppPreferences.menuBarAmountOffsetYKey,
            resetIdentifier: Self.amountOffsetsResetIdentifier,
            relay: input.relay
        )
        let widthAdjustmentControls = makeWidthSliderControls(
            value: widthAdjustment,
            key: AppPreferences.menuBarStatusItemWidthAdjustmentKey,
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
        iconOffsetButtons = iconOffsetControls
        amountOffsetButtons = amountOffsetControls
        widthAdjustmentSlider = widthAdjustmentControls.slider
        fontSizePresetControl = fontSizeControls.control
        let typographyAndPositionSection = DashboardSettingsComponents.makeSettingsSection(
            tr("字号与位置", "Font Size & Position", "字號與位置", "フォントサイズと位置"),
            rows: [
                DashboardSettingsComponents.makeSettingsRow(
                    tr("菜单栏字号", "Menu Bar Font Size", "選單列字號", "メニューバーのフォントサイズ"),
                    subtitle: tr(
                        "调整菜单栏字体大小",
                        "Adjusts the menu bar font size",
                        "調整選單列字體大小",
                        "メニューバーのフォントサイズを調整"
                    ),
                    control: fontSizeControls.view,
                    minimumHeight: 66
                ),
                DashboardSettingsComponents.makeSettingsRow(
                    tr("图标偏移", "Icon Offset", "圖示偏移", "アイコンの位置調整"),
                    subtitle: Self.iconOffsetSummaryText(y: input.preferences.menuBarIconOffsetY),
                    subtitleLabel: iconOffsetSummary,
                    control: makeOffsetControlStack(buttons: iconOffsetControls),
                    minimumHeight: 66
                ),
                DashboardSettingsComponents.makeSettingsRow(
                    tr("金额偏移", "Amount Offset", "金額偏移", "金額の位置調整"),
                    subtitle: Self.amountOffsetSummaryText(y: input.preferences.menuBarAmountOffsetY),
                    subtitleLabel: amountOffsetSummary,
                    control: makeOffsetControlStack(buttons: amountOffsetControls),
                    minimumHeight: 66
                ),
                DashboardSettingsComponents.makeSettingsRow(
                    tr("菜单栏宽度", "Menu Bar Width", "選單列寬度", "メニューバーの幅"),
                    subtitle: Self.widthAdjustmentSummaryText(widthAdjustment),
                    subtitleLabel: widthAdjustmentSummary,
                    control: widthAdjustmentControls.view,
                    minimumHeight: 66
                )
            ]
        )
        isBuilt = true
        refresh(snapshot: input.snapshot, preferences: input.preferences, menuBarSnapshot: input.menuBarSnapshot, iconImage: input.iconImage)
        return DashboardSettingsComponents.makeSettingsPage([
            previewSection,
            displaySection,
            typographyAndPositionSection
        ])
    }

    func refresh(
        snapshot: Snapshot,
        preferences: AppPreferences,
        menuBarSnapshot: (Snapshot) -> Snapshot,
        iconImage: NSImage?
    ) {
        guard isBuilt else { return }
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
            resolving: menuBarSnapshot
        )
        previewPrimary.stringValue = presentation.primary
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
        iconOffsetSummaryLabel?.stringValue = Self.iconOffsetSummaryText(y: iconOffsetY)
        amountOffsetSummaryLabel?.stringValue = Self.amountOffsetSummaryText(y: amountOffsetY)
        iconOffsetButtons.forEach { $0.isEnabled = preferences.showMenuBarIcon }
        amountOffsetButtons.forEach { $0.isEnabled = preferences.showMenuBarAmount }
        fontSizePresetControl?.selectItem(at: fontSizePreset.segmentIndex)
        fontSizePresetControl?.isEnabled = preferences.showMenuBarAmount
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
            widthAdjustmentSummaryLabel?.stringValue = Self.widthAdjustmentSummaryText(widthAdjustment)
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
        return "\(sign) \(String(format: "%.1f", abs(value))) pt"
    }

    private static func iconOffsetSummaryText(y: Double) -> String {
        let valueText = signedPointText(y)
        return tr(
            "微调图标上下像素位置：Y 轴 \(valueText)",
            "Fine-tune the icon's vertical position: Y axis \(valueText)",
            "微調圖示上下像素位置：Y 軸 \(valueText)",
            "アイコンの上下位置を微調整：Y 軸 \(valueText)"
        )
    }

    private static func amountOffsetSummaryText(y: Double) -> String {
        let valueText = signedPointText(y)
        return tr(
            "微调金额上下像素位置：Y 轴 \(valueText)",
            "Fine-tune the amount's vertical position: Y axis \(valueText)",
            "微調金額上下像素位置：Y 軸 \(valueText)",
            "金額の上下位置を微調整：Y 軸 \(valueText)"
        )
    }

    private static func widthAdjustmentSummaryText(_ value: Double) -> String {
        let valueText = signedPointText(value)
        return tr(
            "调整 BalanceBar 与其他菜单栏项目的空隙：宽度 \(valueText)",
            "Adjusts the gap between BalanceBar and other menu bar items: Width \(valueText)",
            "調整 BalanceBar 與其他選單列項目的間距：寬度 \(valueText)",
            "BalanceBar と他のメニューバー項目との間隔を調整：幅 \(valueText)"
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
                    representedObject: NSNumber(value: preset.segmentIndex)
                )
            },
            selectedIndex: value.segmentIndex,
            target: relay,
            action: #selector(DashboardPreferencePageRelay.selectMenuBarFontSizePreset(_:))
        )
        control.toolTip = tr(
            "大 13/10 pt；中 11.7/9 pt；小 10.4/8 pt",
            "Large 13/10 pt; Medium 11.7/9 pt; Small 10.4/8 pt",
            "大 13/10 pt；中 11.7/9 pt；小 10.4/8 pt",
            "大 13/10 pt；中 11.7/9 pt；小 10.4/8 pt"
        )
        control.widthAnchor.constraint(equalToConstant: Self.fontSizePresetWidth).isActive = true
        return FontPresetControls(view: control, control: control)
    }

    private static func fontSizePresetLabel(_ preset: MenuBarFontSizePreset) -> String {
        switch preset {
        case .large: return tr("大", "Large", "大", "大")
        case .medium: return tr("中", "Medium", "中", "中")
        case .small: return tr("小", "Small", "小", "小")
        }
    }

    private func makeOffsetControls(
        keyY: String,
        resetIdentifier: String,
        relay: DashboardPreferencePageRelay
    ) -> [NSButton] {
        [
            makeOffsetButton(
                title: tr("上", "Up", "上", "上"),
                key: keyY,
                delta: 1,
                relay: relay
            ),
            makeOffsetButton(
                title: tr("下", "Down", "下", "下"),
                key: keyY,
                delta: -1,
                relay: relay
            ),
            makeOffsetResetButton(identifier: resetIdentifier, relay: relay)
        ]
    }

    private func makeWidthSliderControls(
        value: Double,
        key: String,
        relay: DashboardPreferencePageRelay
    ) -> WidthSliderControls {
        let range = AppPreferences.menuBarStatusItemWidthAdjustmentRange
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
        slider.toolTip = tr(
            "从 -10.0 pt（窄）调整到 +10.0 pt（宽），默认 0 pt",
            "Adjusts menu bar width from -10.0 pt (narrow) to +10.0 pt (wide); default 0 pt",
            "從 -10.0 pt（窄）調整到 +10.0 pt（寬），預設 0 pt",
            "メニューバーの幅を -10.0 pt（狭い）から +10.0 pt（広い）まで調整（デフォルト 0 pt）"
        )
        slider.onEditingEnded = { [weak relay, weak slider] in
            guard let relay, let slider else { return }
            relay.finishOffsetValue(slider)
        }
        slider.widthAnchor.constraint(equalToConstant: Self.widthAdjustmentSliderWidth).isActive = true

        let minimumLabel = makeWidthSliderEndpointLabel(
            tr("窄", "Narrow", "窄", "狭い"),
            identifier: Self.widthAdjustmentSliderMinimumIdentifier
        )
        let maximumLabel = makeWidthSliderEndpointLabel(
            tr("宽", "Wide", "寬", "広い"),
            identifier: Self.widthAdjustmentSliderMaximumIdentifier
        )
        let stack = NSStackView(views: [minimumLabel, slider, maximumLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return WidthSliderControls(view: stack, slider: slider)
    }

    private func makeWidthSliderEndpointLabel(
        _ title: String,
        identifier: String
    ) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.identifier = NSUserInterfaceItemIdentifier(identifier)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func makeOffsetButton(
        title: String,
        key: String,
        delta: Int,
        relay: DashboardPreferencePageRelay
    ) -> NSButton {
        let button = RepeatOffsetButton(
            title: title,
            policy: MenuBarOffsetRepeatPolicy.standard,
            target: relay,
            action: #selector(DashboardPreferencePageRelay.adjustOffset(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.tag = delta
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func makeOffsetResetButton(
        identifier: String,
        relay: DashboardPreferencePageRelay
    ) -> NSButton {
        let button = NSButton(
            title: tr("归零", "Reset", "歸零", "リセット"),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.resetOffset(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func makeOffsetControlStack(buttons: [NSButton]) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }
}
