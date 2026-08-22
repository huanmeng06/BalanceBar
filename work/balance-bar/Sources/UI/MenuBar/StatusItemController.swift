import AppKit
import Foundation

final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        let manualRefresh: () -> Void
        let openDashboard: () -> Void
        let openChatGPT: () -> Void
        let openCCSwitch: () -> Void
        let openOpenCodex: () -> Void
        let quit: () -> Void
        let switchProvider: (String) -> Void
        let switchOpenCodexPreference: (OpenCodexPreference) -> Void
        let openProviderWebsite: () -> Void
        let openStatusLink: (URL) -> Void
        let iconChanged: (NSImage?) -> Void
    }

    struct MenuBarSettings {
        let showIcon: Bool
        let showAmount: Bool
        let showReset: Bool
        let horizontalPadding: CGFloat
        let keepMenuOpenAfterRefresh: Bool
        let iconOffsetX: CGFloat
        let iconOffsetY: CGFloat
        let amountOffsetX: CGFloat
        let amountOffsetY: CGFloat
        var widthAdjustment: CGFloat

        init(
            showIcon: Bool,
            showAmount: Bool,
            showReset: Bool,
            horizontalPadding: CGFloat,
            keepMenuOpenAfterRefresh: Bool,
            iconOffsetX: CGFloat = 0,
            iconOffsetY: CGFloat = 0,
            amountOffsetX: CGFloat = 0,
            amountOffsetY: CGFloat = 0,
            widthAdjustment: CGFloat = 0
        ) {
            self.showIcon = showIcon
            self.showAmount = showAmount
            self.showReset = showReset
            self.horizontalPadding = horizontalPadding
            self.keepMenuOpenAfterRefresh = keepMenuOpenAfterRefresh
            self.iconOffsetX = iconOffsetX
            self.iconOffsetY = iconOffsetY
            self.amountOffsetX = amountOffsetX
            self.amountOffsetY = amountOffsetY
            self.widthAdjustment = widthAdjustment
        }
    }

    struct MenuInput {
        let openCodexCards: [OpenCodexModelCard]
        let openCodexState: OpenCodexRuntimeState?
        let openCodexSwitchInFlight: Bool
        let choices: [ProviderChoice]
        let quickSwitchSummaries: [String: String]
        let activeClient: AssistantClient
        let statusLinks: [StatusLink]
        let showQuickSwitchMenu: Bool
        let showOpenChatGPTMenu: Bool
        let showOpenCCSwitchMenu: Bool
        let showOpenCodexMenu: Bool
        let showStatusMenu: Bool
    }

    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var statusItemAttachmentCheckScheduled = false
    private var statusItemReanchorAttempts = 0
    private var isStatusMenuTracking = false
    private var statusMenuNeedsRebuild = false
    private let menuBarIconView = RotatingTemplateImageView()
    private let menuBarIconSlot = PassthroughView()
    private let menuBarTextStack = MenuBarTextView()
    private let menuBarContentStack = MenuBarContentView()
    private let menuBarPrimaryLabel = PassthroughTextField(labelWithString: "…")
    private let menuBarSecondaryLabel = PassthroughTextField(labelWithString: "")
    private var isMenuBarContentStackConfigured = false
    private var lastMenuBarIconFrameDiagnostic: String?
    private var codexIconImage: NSImage?
    private var claudeIconImage: NSImage?
    private var claudeThinkingAnimator: ClaudeThinkingAnimator?
    private var snapshot = Snapshot.placeholder
    private var refreshDate: Date?
    private var menuInput = MenuInput(
        openCodexCards: [],
        openCodexState: nil,
        openCodexSwitchInFlight: false,
        choices: [],
        quickSwitchSummaries: [:],
        activeClient: .codex,
        statusLinks: [],
        showQuickSwitchMenu: true,
        showOpenChatGPTMenu: true,
        showOpenCCSwitchMenu: true,
        showOpenCodexMenu: true,
        showStatusMenu: true
    )
    private var settings = MenuBarSettings(
        showIcon: true,
        showAmount: true,
        showReset: true,
        horizontalPadding: 6,
        keepMenuOpenAfterRefresh: true
    )
    private var activeClient: AssistantClient = .codex
    private var isCodexTaskRunning = false
    private var isClaudeTaskRunning = false
    private var animationEnabled = true
    private var lastMenuBarGeometry: MenuBarGeometry?
    private var lastMenuBarIconYOffset: CGFloat = 0
    private var lastMenuBarOfficialTextYOffset: CGFloat = 0
    private var lastMenuBarEffectiveSnapshot = Snapshot.placeholder
    private var pendingWidthAdjustment: CGFloat?
    private var widthAdjustmentUpdateTimer: Timer?
    private let actions: Actions
    private var lifecycleGeneration = 0
    private(set) var statusItemInstallCount = 0

    var isVisible: Bool { statusItem?.isVisible ?? false }
    var isMenuTracking: Bool { isStatusMenuTracking }
    var iconImage: NSImage? { menuBarIconView.image }

    // Exposes the controller's current outer footprint for headless layout
    // tests without exposing the underlying NSStatusItem.
    var statusItemLengthForTesting: CGFloat? { statusItem?.length }

    // Exposes the controller's actual menu for headless production-path tests.
    // The application still owns and renders this same NSMenu instance.
    var menuItemsForTesting: [NSMenuItem] { statusMenu.items }

    var startupDiagnostic: String {
        let statusWindow = statusItem?.button?.window
        return "status_visible=\(isVisible); menu_bound=\(statusItem?.menu === statusMenu); menu_items=\(statusMenu.items.count); button_window=\(statusWindow != nil)"
    }

    init(actions: Actions) {
        self.actions = actions
        super.init()
    }

    func start(
        snapshot: Snapshot,
        refreshDate: Date?,
        menuInput: MenuInput,
        settings: MenuBarSettings
    ) {
        lifecycleGeneration += 1
        statusMenu.delegate = self
        if statusItem == nil {
            installStatusItem()
        }
        update(
            snapshot: snapshot,
            refreshDate: refreshDate,
            menuInput: menuInput,
            settings: settings
        )
    }

    func teardown() {
        lifecycleGeneration += 1
        statusItemAttachmentCheckScheduled = false
        statusItemReanchorAttempts = 0
        statusMenuNeedsRebuild = false
        isStatusMenuTracking = false
        lastMenuBarIconFrameDiagnostic = nil
        lastMenuBarGeometry = nil
        cancelPendingWidthAdjustment()
        menuBarIconView.stopRotating()
        claudeThinkingAnimator?.stop()
        menuBarIconView.onImageChanged = nil
        menuBarContentStack.removeFromSuperview()
        statusMenu.delegate = nil
        statusMenu.removeAllItems()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func update(
        snapshot: Snapshot,
        refreshDate: Date?,
        menuInput: MenuInput,
        settings: MenuBarSettings
    ) {
        cancelPendingWidthAdjustment()
        self.snapshot = snapshot
        self.refreshDate = refreshDate
        self.menuInput = menuInput
        self.settings = settings
        layoutStatusItem(for: snapshot)
        rebuildOrDeferMenu()
    }

    /// Updates only the status item's outer width while a continuous width
    /// slider is being dragged. Rebuilding the menu or restarting activity
    /// animation for every slider event makes the main-thread interaction
    /// visibly stutter, so the existing content geometry is reused here.
    func updateWidthAdjustment(_ widthAdjustment: CGFloat) {
        settings.widthAdjustment = widthAdjustment
        pendingWidthAdjustment = widthAdjustment
        guard widthAdjustmentUpdateTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
            self?.applyPendingWidthAdjustment()
        }
        widthAdjustmentUpdateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyPendingWidthAdjustment() {
        widthAdjustmentUpdateTimer = nil
        guard let widthAdjustment = pendingWidthAdjustment else { return }
        pendingWidthAdjustment = nil
        guard let statusItem,
              let button = statusItem.button,
              let geometry = lastMenuBarGeometry else {
            return
        }

        let requestedLength = MenuBarLayout.statusItemLength(
            contentWidth: geometry.contentWidth,
            horizontalPadding: settings.horizontalPadding,
            widthAdjustment: widthAdjustment
        )
        guard requestedLength != statusItem.length else { return }
        statusItem.length = requestedLength
        button.layoutSubtreeIfNeeded()
        applyMenuBarContentFrames(
            button: button,
            geometry: geometry,
            iconViewYOffset: lastMenuBarIconYOffset,
            effectiveSnapshot: lastMenuBarEffectiveSnapshot,
            officialTextYOffset: lastMenuBarOfficialTextYOffset
        )
    }

    private func cancelPendingWidthAdjustment() {
        widthAdjustmentUpdateTimer?.invalidate()
        widthAdjustmentUpdateTimer = nil
        pendingWidthAdjustment = nil
    }

    func updateMenu(input: MenuInput) {
        menuInput = input
        rebuildOrDeferMenu()
    }

    func updateActivity(
        activeClient: AssistantClient,
        codexTaskRunning: Bool,
        claudeTaskRunning: Bool,
        animationEnabled: Bool
    ) {
        self.activeClient = activeClient
        self.isCodexTaskRunning = codexTaskRunning
        self.isClaudeTaskRunning = claudeTaskRunning
        self.animationEnabled = animationEnabled
        updateActivityIcon()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        isStatusMenuTracking = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        isStatusMenuTracking = false
        guard statusMenuNeedsRebuild else { return }
        statusMenuNeedsRebuild = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStatusMenuTracking else { return }
            self.rebuildStatusMenu()
        }
    }

    private func rebuildOrDeferMenu() {
        guard statusItem != nil else { return }
        if isStatusMenuTracking {
            statusMenuNeedsRebuild = true
        } else {
            rebuildStatusMenu()
        }
    }

    private func configureStatusItem() {
        guard let statusItem, let button = statusItem.button else { return }
        statusItem.isVisible = true
        statusItem.length = 56
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = nil
        button.toolTip = "BalanceBar"

        if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = true
            codexIconImage = icon
            menuBarIconView.setSourceImage(icon)
        }
        if let iconURL = Bundle.main.url(forResource: "Claude", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = true
            claudeIconImage = icon
            if let thinkingURL = Bundle.main.url(
                forResource: "ClaudeThinking",
                withExtension: "svg"
            ) {
                claudeThinkingAnimator = ClaudeThinkingAnimator(
                    imageView: menuBarIconView,
                    staticImage: icon,
                    animatedSVGURL: thinkingURL
                )
            }
        }
        menuBarIconView.onImageChanged = { [weak self] image in
            guard let self else { return }
            self.menuBarIconView.image = image
            self.layoutStatusItem(for: self.snapshot)
            self.actions.iconChanged(image)
        }
        actions.iconChanged(menuBarIconView.image)
        menuBarIconView.imageScaling = .scaleProportionallyDown
        menuBarIconView.contentTintColor = .labelColor
        menuBarPrimaryLabel.font = MenuBarLayout.primaryFont
        menuBarPrimaryLabel.textColor = .labelColor
        menuBarPrimaryLabel.lineBreakMode = .byClipping
        menuBarSecondaryLabel.font = MenuBarLayout.secondaryFont
        menuBarSecondaryLabel.textColor = .labelColor
        menuBarSecondaryLabel.lineBreakMode = .byClipping
        configureMenuBarContentStackIfNeeded()
        button.addSubview(menuBarContentStack)
        layoutStatusItem(for: snapshot)
        SwitchLog.write(
            "status item configured; visible=\(statusItem.isVisible); length=\(statusItem.length)",
            category: "ui.status-item"
        )
        let generation = lifecycleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.lifecycleGeneration == generation,
                  let statusItem = self.statusItem,
                  let button = statusItem.button else { return }
            let statusWindow = button.window
            let windowFrame = statusWindow.map { DashboardLogging.rect($0.frame) } ?? "none"
            let screenFrame = statusWindow?.screen.map { DashboardLogging.rect($0.frame) } ?? "none"
            SwitchLog.write(
                "status item presentation; visible=\(statusItem.isVisible); window_visible=\(statusWindow?.isVisible ?? false); button_window=\(statusWindow != nil); button_hidden=\(button.isHidden); image=\(button.image != nil); title=\(button.title); attributed_title=\(button.attributedTitle.string); frame=\(DashboardLogging.rect(button.frame)); window_frame=\(windowFrame); screen_frame=\(screenFrame)",
                category: "ui.status-item"
            )
        }
        scheduleStatusItemAttachmentCheck(reason: "initial registration")
    }

    private func installStatusItem() {
        statusItemInstallCount += 1
        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        self.statusItem = statusItem
        statusItem.menu = statusMenu
        configureStatusItem()
    }

    private func scheduleStatusItemAttachmentCheck(reason: String) {
        guard !statusItemAttachmentCheckScheduled else { return }
        statusItemAttachmentCheckScheduled = true
        let generation = lifecycleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.statusItemAttachmentCheckScheduled = false
            self.verifyStatusItemAttachment(reason: reason)
        }
    }

    private func verifyStatusItemAttachment(reason: String) {
        guard let item = statusItem, let button = item.button else {
            SwitchLog.write(
                "status item attachment failed; reason=missing item or button",
                level: .error,
                category: "ui.status-item"
            )
            return
        }

        let window = button.window
        let windowFrame = window.map { DashboardLogging.rect($0.frame) } ?? "none"
        let screen = window?.screen
        let screenFrame = screen.map { DashboardLogging.rect($0.frame) } ?? "none"
        let attached = window.map { window in
            guard let screen else { return false }
            let frame = window.frame
            let screenFrame = screen.frame
            return window.isVisible
                && frame.minX >= screenFrame.minX
                && frame.maxX <= screenFrame.maxX
                && frame.maxY >= screenFrame.maxY - 4
                && frame.minY >= screenFrame.maxY - 48
        } ?? false

        SwitchLog.write(
            "status item attachment checked; reason=\(reason); attached=\(attached); visible=\(item.isVisible); window_visible=\(window?.isVisible ?? false); window_frame=\(windowFrame); screen_frame=\(screenFrame); length=\(item.length)",
            level: attached ? .debug : .warning,
            category: "ui.status-item",
            throttleKey: "status-item-attachment-\(reason)",
            minimumInterval: 0.5
        )

        guard !attached else {
            statusItemReanchorAttempts = 0
            return
        }
        guard statusItemReanchorAttempts < 3 else {
            SwitchLog.write(
                "status item attachment unresolved after retries; reason=\(reason); window_frame=\(windowFrame); screen_frame=\(screenFrame)",
                level: .error,
                category: "ui.status-item"
            )
            return
        }

        statusItemReanchorAttempts += 1
        let desiredLength = max(CGFloat(30), item.length)
        NSStatusBar.system.removeStatusItem(item)
        let replacement = NSStatusBar.system.statusItem(withLength: desiredLength)
        statusItem = replacement
        replacement.menu = statusMenu
        configureStatusItem()
        scheduleStatusItemAttachmentCheck(reason: "re-registered-\(statusItemReanchorAttempts)-\(reason)")
    }

    private func updateActivityIcon() {
        switch activeClient {
        case .codex:
            claudeThinkingAnimator?.stop()
            if let codexIconImage {
                menuBarIconView.setSourceImage(codexIconImage)
            }
            if MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: isCodexTaskRunning,
                preferenceEnabled: animationEnabled
            ) {
                menuBarIconView.startRotating()
            } else {
                menuBarIconView.stopRotating()
            }
        case .claude:
            menuBarIconView.stopRotating()
            if let claudeIconImage {
                menuBarIconView.setSourceImage(claudeIconImage)
            }
            if MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: isClaudeTaskRunning,
                preferenceEnabled: animationEnabled
            ) {
                claudeThinkingAnimator?.start()
            } else {
                claudeThinkingAnimator?.stop()
            }
        }
    }

    private func configureMenuBarContentStackIfNeeded() {
        guard !isMenuBarContentStackConfigured else { return }
        isMenuBarContentStackConfigured = true
        menuBarIconView.translatesAutoresizingMaskIntoConstraints = true
        menuBarIconSlot.translatesAutoresizingMaskIntoConstraints = true
        menuBarIconSlot.addSubview(menuBarIconView)
        menuBarTextStack.addSubview(menuBarPrimaryLabel)
        menuBarTextStack.addSubview(menuBarSecondaryLabel)
        menuBarTextStack.wantsLayer = true
        menuBarTextStack.layer?.setAffineTransform(.identity)
        menuBarContentStack.addSubview(menuBarIconSlot)
        menuBarContentStack.addSubview(menuBarTextStack)
        menuBarContentStack.translatesAutoresizingMaskIntoConstraints = true
    }

    private func logMenuBarIconFrames(
        snapshot: Snapshot,
        button: NSStatusBarButton,
        hasSecondary: Bool,
        iconYOffset: CGFloat
    ) {
        guard settings.showIcon else { return }
        let kind: String
        switch snapshot.kind {
        case .placeholder: kind = "placeholder"
        case .official: kind = "official"
        case .balance: kind = "balance"
        case .openCodex: kind = "open-codex"
        case .error: kind = "error"
        }
        let stackInButton = menuBarContentStack.convert(menuBarContentStack.bounds, to: button)
        let slotInButton = menuBarIconSlot.convert(menuBarIconSlot.bounds, to: button)
        let iconInButton = menuBarIconView.convert(menuBarIconView.bounds, to: button)
        let iconInWindow = menuBarIconView.convert(menuBarIconView.bounds, to: nil)
        let iconInScreen = button.window?.convertToScreen(iconInWindow)
        let diagnostic = "menu bar icon frames; kind=\(kind); show_amount=\(settings.showAmount); has_secondary=\(hasSecondary); offset=\(DashboardLogging.number(iconYOffset)); flipped=button:\(button.isFlipped),stack:\(menuBarContentStack.isFlipped),slot:\(menuBarIconSlot.isFlipped),icon:\(menuBarIconView.isFlipped); button=\(DashboardLogging.rect(button.bounds)); stack_local=\(DashboardLogging.rect(menuBarContentStack.frame)); stack_button=\(DashboardLogging.rect(stackInButton)); slot_local=\(DashboardLogging.rect(menuBarIconSlot.frame)); slot_button=\(DashboardLogging.rect(slotInButton)); icon_local=\(DashboardLogging.rect(menuBarIconView.frame)); icon_button=\(DashboardLogging.rect(iconInButton)); icon_window=\(DashboardLogging.rect(iconInWindow)); icon_screen=\(iconInScreen.map { DashboardLogging.rect($0) } ?? "none"); center_button=\(DashboardLogging.number(iconInButton.midY)); center_window=\(DashboardLogging.number(iconInWindow.midY))"
        guard diagnostic != lastMenuBarIconFrameDiagnostic else { return }
        lastMenuBarIconFrameDiagnostic = diagnostic
        SwitchLog.write(diagnostic, level: .debug, category: "ui.geometry")
    }

    private func layoutStatusItem(for snapshot: Snapshot) {
        guard let statusItem, let button = statusItem.button else { return }
        let effectiveSnapshot = menuBarSnapshot(for: snapshot)
        let reservedSecondary = settings.showAmount && effectiveSnapshot.kind == .official
            ? effectiveSnapshot.menuBarSecondary
            : ""
        let hasSecondary = settings.showAmount
            && settings.showReset
            && !reservedSecondary.isEmpty

        menuBarPrimaryLabel.stringValue = settings.showAmount ? effectiveSnapshot.menuBarPrimary : ""
        menuBarSecondaryLabel.stringValue = reservedSecondary
        menuBarIconSlot.isHidden = !settings.showIcon
        menuBarTextStack.isHidden = !settings.showAmount
        let geometry = MenuBarLayout.geometry(
            primarySize: menuBarPrimaryLabel.intrinsicContentSize,
            secondarySize: menuBarSecondaryLabel.intrinsicContentSize,
            showIcon: settings.showIcon,
            showAmount: settings.showAmount,
            hasSecondary: hasSecondary,
            isBalance: effectiveSnapshot.kind == .balance
        )
        MenuBarLayout.applyTextLayout(
            container: menuBarTextStack,
            primary: menuBarPrimaryLabel,
            secondary: menuBarSecondaryLabel,
            geometry: geometry,
            showAmount: settings.showAmount,
            hasSecondary: hasSecondary
        )

        statusItem.length = MenuBarLayout.statusItemLength(
            contentWidth: geometry.contentWidth,
            horizontalPadding: settings.horizontalPadding,
            widthAdjustment: settings.widthAdjustment
        )
        button.layoutSubtreeIfNeeded()

        let buttonHeight = button.bounds.height
        let apiIconYOffset = settings.showIcon && settings.showAmount
            ? MenuBarLayout.singleLineIconYOffset
            : 0
        let iconYOffset: CGFloat
        if effectiveSnapshot.kind == .official, settings.showIcon {
            let apiGeometry = MenuBarLayout.geometry(
                primarySize: menuBarPrimaryLabel.intrinsicContentSize,
                secondarySize: menuBarSecondaryLabel.intrinsicContentSize,
                showIcon: settings.showIcon,
                showAmount: settings.showAmount,
                hasSecondary: false,
                isBalance: true
            )
            iconYOffset = geometry.iconViewYOffset(
                alignedTo: apiGeometry,
                buttonHeight: buttonHeight,
                referenceIconViewYOffset: apiIconYOffset
            )
        } else if effectiveSnapshot.kind == .balance {
            iconYOffset = apiIconYOffset
        } else {
            iconYOffset = 0
        }
        let officialTextYOffset: CGFloat
        if effectiveSnapshot.kind == .official, settings.showAmount {
            officialTextYOffset = MenuBarLayout.officialTextYOffset(
                hasSecondary: hasSecondary
            )
        } else {
            officialTextYOffset = 0
        }
        lastMenuBarGeometry = geometry
        lastMenuBarIconYOffset = iconYOffset
        lastMenuBarOfficialTextYOffset = officialTextYOffset
        lastMenuBarEffectiveSnapshot = effectiveSnapshot
        applyMenuBarContentFrames(
            button: button,
            geometry: geometry,
            iconViewYOffset: iconYOffset,
            effectiveSnapshot: effectiveSnapshot,
            officialTextYOffset: officialTextYOffset
        )
        logMenuBarIconFrames(
            snapshot: effectiveSnapshot,
            button: button,
            hasSecondary: hasSecondary,
            iconYOffset: iconYOffset
        )
        button.toolTip = effectiveSnapshot.menuBarToolTip
        button.isHidden = false
        button.isEnabled = true
        statusItem.isVisible = true
    }

    private func applyMenuBarContentFrames(
        button: NSStatusBarButton,
        geometry: MenuBarGeometry,
        iconViewYOffset: CGFloat,
        effectiveSnapshot: Snapshot,
        officialTextYOffset: CGFloat
    ) {
        let frames = MenuBarLayout.frames(
            buttonSize: NSSize(width: button.bounds.width, height: button.bounds.height),
            geometry: geometry,
            iconViewYOffset: iconViewYOffset,
            iconOffset: NSSize(
                width: settings.iconOffsetX,
                height: settings.iconOffsetY
            ),
            textOffset: NSSize(
                width: settings.amountOffsetX,
                height: settings.amountOffsetY + officialTextYOffset
            )
        )
        menuBarContentStack.frame = frames.content
        menuBarIconSlot.frame = frames.iconSlot
        menuBarIconView.frame = frames.icon
        menuBarTextStack.frame = frames.text
        menuBarTextStack.layer?.setAffineTransform(.identity)
        if effectiveSnapshot.kind == .balance,
           settings.showIcon,
           settings.showAmount {
            menuBarTextStack.layer?.setAffineTransform(CGAffineTransform(
                translationX: 0,
                y: -MenuBarLayout.singleLineTextYOffset
            ))
        }
    }

    private func menuBarSnapshot(for snapshot: Snapshot) -> Snapshot {
        let effective = OpenCodexCardPresentation.menuBarSnapshot(
            for: snapshot,
            cards: menuInput.openCodexCards
        )
        guard snapshot.kind == .openCodex else { return effective }
        let match = OpenCodexCardPresentation.menuBarCardMatch(from: menuInput.openCodexCards)
        let cardSummary = menuInput.openCodexCards.enumerated()
            .map { index, card in
                "\(index){selector=\(card.selector),isCurrent=\(card.isCurrent),data=\(card.data.diagnosticName)}"
            }
            .joined(separator: ";")
        let selection = match.card?.selector ?? "none"
        let signature = [
            snapshot.unit ?? "none",
            cardSummary,
            match.diagnosticReason,
            snapshotKindDiagnosticName(effective.kind),
            effective.menuBarPrimary,
            effective.menuBarSecondary
        ].joined(separator: "|")
        SwitchLog.write(
            "OpenCodex menu bar resolution; runtime_selector=\(snapshot.unit ?? "none"); cards=[\(cardSummary)]; match=\(match.diagnosticReason); selected_selector=\(selection); effective_kind=\(snapshotKindDiagnosticName(effective.kind)); primary=\(effective.menuBarPrimary); secondary=\(effective.menuBarSecondary)",
            level: .debug,
            category: "open-codex.menu-bar",
            throttleKey: "open-codex-menu-resolution-\(signature)",
            minimumInterval: 1
        )
        return effective
    }

    private func snapshotKindDiagnosticName(_ kind: Snapshot.Kind) -> String {
        switch kind {
        case .placeholder: return "placeholder"
        case .official: return "official"
        case .balance: return "balance"
        case .openCodex: return "openCodex"
        case .error: return "error"
        }
    }

    @objc private func manualRefresh() {
        actions.manualRefresh()
        if settings.keepMenuOpenAfterRefresh {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.statusItem?.button?.performClick(nil)
            }
        }
    }

    @objc private func openDashboard() { actions.openDashboard() }
    @objc private func openChatGPT() { actions.openChatGPT() }
    @objc private func openCCSwitch() { actions.openCCSwitch() }
    @objc private func openOpenCodex() { actions.openOpenCodex() }
    @objc private func quit() { actions.quit() }

    @objc private func switchProvider(_ sender: NSMenuItem) {
        guard let providerID = sender.representedObject as? String else { return }
        actions.switchProvider(providerID)
    }

    @objc private func switchOpenCodexPreference(_ sender: NSMenuItem) {
        guard let preference = sender.representedObject as? OpenCodexPreference else { return }
        actions.switchOpenCodexPreference(preference)
    }

    @objc private func openStatusLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        actions.openStatusLink(url)
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()
        if snapshot.kind == .openCodex {
            if menuInput.openCodexCards.isEmpty {
                statusMenu.addItem(makeOpenCodexEmptyMenuItem())
            } else {
                for (index, card) in menuInput.openCodexCards.enumerated() {
                    statusMenu.addItem(makeOpenCodexCardMenuItem(card))
                    if index < menuInput.openCodexCards.count - 1 {
                        statusMenu.addItem(.separator())
                    }
                }
            }
        } else {
            statusMenu.addItem(makeOverviewMenuItem(for: snapshot))
        }
        statusMenu.addItem(.separator())
        if menuInput.showQuickSwitchMenu {
            statusMenu.addItem(makeQuickSwitchMenuItem())
        }
        statusMenu.addItem(
            withTitle: tr("立即刷新", "Refresh Now", "立即重新整理", "今すぐ更新"),
            action: #selector(manualRefresh),
            keyEquivalent: "r"
        ).target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: tr("打开主窗口", "Open Main Window", "開啟主視窗", "メインウインドウを開く"),
            action: #selector(openDashboard),
            keyEquivalent: ""
        ).target = self
        if menuInput.showOpenChatGPTMenu {
            statusMenu.addItem(
                withTitle: tr("打开 ChatGPT", "Open ChatGPT", "開啟 ChatGPT", "ChatGPT を開く"),
                action: #selector(openChatGPT),
                keyEquivalent: ""
            ).target = self
        }
        if menuInput.showOpenCCSwitchMenu {
            statusMenu.addItem(
                withTitle: tr("打开 CC Switch", "Open CC Switch", "開啟 CC Switch", "CC Switch を開く"),
                action: #selector(openCCSwitch),
                keyEquivalent: ""
            ).target = self
        }
        if menuInput.showOpenCodexMenu {
            statusMenu.addItem(
                withTitle: tr("打开 OpenCodex", "Open OpenCodex", "開啟 OpenCodex", "OpenCodex を開く"),
                action: #selector(openOpenCodex),
                keyEquivalent: ""
            ).target = self
        }
        if menuInput.showStatusMenu {
            statusMenu.addItem(makeStatusLinksMenuItem())
        }
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: tr("退出 BalanceBar", "Quit BalanceBar", "結束 BalanceBar", "BalanceBar を終了"),
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self
        let menuTitles = statusMenu.items.map { item in
            item.title.isEmpty ? "<custom>" : item.title
        }.joined(separator: "|")
        let statusWindow = statusItem?.button?.window
        let windowFrame = statusWindow.map { DashboardLogging.rect($0.frame) } ?? "none"
        let screenFrame = statusWindow?.screen.map { DashboardLogging.rect($0.frame) } ?? "none"
        let buttonTitle = statusItem?.button?.title ?? ""
        SwitchLog.write(
            "status menu rendered; item_count=\(statusMenu.items.count); items=\(menuTitles); status_visible=\(isVisible); button_window=\(statusWindow != nil); window_visible=\(statusWindow?.isVisible ?? false); image=\(statusItem?.button?.image != nil); title=\(buttonTitle); window_frame=\(windowFrame); screen_frame=\(screenFrame)",
            level: .debug,
            category: "ui.status-menu",
            throttleKey: "status-menu-render",
            minimumInterval: 1
        )
    }

    private func makeStatusLinksMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: tr("查看状态", "View Status", "檢視狀態", "ステータスを表示"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: tr("查看状态", "View Status", "檢視狀態", "ステータスを表示"))
        for link in menuInput.statusLinks {
            let title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let url = URL(string: address),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else { continue }
            let item = NSMenuItem(
                title: title,
                action: #selector(openStatusLink(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            let empty = NSMenuItem(
                title: tr("尚未添加状态链接", "No status links configured", "尚未新增狀態連結", "ステータスリンクが設定されていません"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        parent.submenu = submenu
        return parent
    }

    private func makeQuickSwitchMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: tr("快速切换", "Quick Switch", "快速切換", "クイック切り替え"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: tr("快速切换", "Quick Switch", "快速切換", "クイック切り替え"))
        submenu.minimumWidth = 210
        let choiceSummary = menuInput.choices.map {
            "id=\($0.id),name=\($0.name),current=\($0.isCurrent)"
        }.joined(separator: "|")
        let menuChoices = QuickSwitchMenuModel.entries(from: menuInput.choices)
        if menuChoices.isEmpty {
            let empty = NSMenuItem(title: tr("未找到 Codex 供应商", "No Codex Provider Found", "找不到 Codex 供應商", "Codex プロバイダーが見つかりません"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for choice in menuChoices {
                let item = NSMenuItem(
                    title: "",
                    action: #selector(switchProvider(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = choice.id
                item.state = choice.isCurrent ? .on : .off
                applyQuickSwitchTitle(to: item, providerID: choice.id, providerName: choice.name)
                submenu.addItem(item)
            }
        }
        SwitchLog.write(
            "quick-switch menu built; app_type=\(menuInput.activeClient.appType); choice_count=\(menuInput.choices.count); submenu_item_count=\(submenu.items.count); choices=\(choiceSummary.isEmpty ? "<empty>" : choiceSummary); empty_state=\(menuInput.choices.isEmpty)",
            level: .debug,
            category: "provider.menu",
            throttleKey: "quick-switch-menu-\(menuInput.activeClient.appType)",
            minimumInterval: 1
        )
        parent.submenu = submenu
        return parent
    }

    private func applyQuickSwitchTitle(to item: NSMenuItem, providerID: String, providerName: String) {
        let title = "\(providerName)\t\(menuInput.quickSwitchSummaries[providerID] ?? "…")"
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 170)]
        paragraph.defaultTabInterval = 170
        item.title = title
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .paragraphStyle: paragraph
            ]
        )
    }

    private func makeOverviewMenuItem(for snapshot: Snapshot) -> NSMenuItem {
        if snapshot.kind == .error {
            return makeOverviewErrorMenuItem(for: snapshot)
        }
        let item = NSMenuItem()
        item.isEnabled = snapshot.kind == .balance && snapshot.websiteURL != nil
        let isBalance = snapshot.kind == .balance
        let layout = OpenCodexCardLayout.frames(
            for: isBalance ? .balance : .quota,
            linkPrefixWidth: AppLanguage.resolved.overviewLinkPrefixWidth
        )
        let view = NSView(frame: NSRect(origin: .zero, size: layout.cardSize))
        let provider = makeOverviewLabel(snapshot.overviewProvider, font: .systemFont(ofSize: 15, weight: .semibold))
        provider.frame = layout.title

        if snapshot.kind == .official || snapshot.kind == .balance {
            let timeText = refreshDate.map { Self.timeFormatter.string(from: $0) } ?? "--:--:--"
            let refreshTime = makeOverviewLabel(timeText, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
            refreshTime.textColor = .secondaryLabelColor
            refreshTime.alignment = .right
            refreshTime.frame = layout.refreshTime
            view.addSubview(refreshTime)
        }
        if let percentage = snapshot.progressPercentage, let progressFrame = layout.progress {
            let progress = QuotaProgressView(percentage: percentage)
            progress.frame = progressFrame
            view.addSubview(progress)
        }

        let quotaDetail = makeOverviewLabel(snapshot.overviewQuotaDetail, font: .systemFont(ofSize: 13, weight: .medium))
        let amount = makeOverviewLabel(snapshot.overviewLargeAmount, font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold))
        amount.alignment = .right
        if isBalance {
            quotaDetail.frame = layout.quotaDetail
            amount.frame = layout.amount
            let linkPrefix = makeOverviewLabel(tr("官方链接：", "Official Link:", "官方連結：", "公式リンク："), font: .systemFont(ofSize: 12, weight: .regular))
            linkPrefix.textColor = .secondaryLabelColor
            linkPrefix.frame = layout.linkPrefix ?? .zero
            view.addSubview(linkPrefix)
            if snapshot.websiteURL != nil, let linkFrame = layout.link {
                let link = HoverLinkTextField(text: snapshot.provider)
                link.frame = linkFrame
                link.onActivate = { [weak self] in self?.actions.openProviderWebsite() }
                view.addSubview(link)
            }
        } else {
            quotaDetail.frame = layout.quotaDetail
            let reset = makeOverviewLabel(snapshot.overviewReset(refreshDate: refreshDate, formatter: Self.timeFormatter), font: .systemFont(ofSize: 13, weight: .regular))
            reset.textColor = .secondaryLabelColor
            reset.frame = layout.reset ?? .zero
            amount.frame = layout.amount
            view.addSubview(reset)
        }
        [provider, quotaDetail, amount].forEach(view.addSubview)
        item.view = view
        return item
    }

    private func makeOpenCodexEmptyMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 68))
        let title = makeOverviewLabel(
            tr("OpenCodex", "OpenCodex", "OpenCodex", "OpenCodex"),
            font: .systemFont(ofSize: 15, weight: .semibold)
        )
        title.frame = NSRect(x: 14, y: 38, width: 220, height: 20)
        let status: String
        if let state = menuInput.openCodexState?.managementAvailable, !state {
            status = tr("OpenCodex 管理接口不可用", "OpenCodex management API is unavailable", "OpenCodex 管理介面不可用", "OpenCodex 管理 API を利用できません")
        } else if menuInput.openCodexState?.preferenceDataAvailable == false {
            status = tr("暂未读取到 OpenCodex 精选模型", "OpenCodex chosen models are not available yet", "尚未讀取到 OpenCodex 精選模型", "OpenCodex の選択モデルはまだ利用できません")
        } else {
            status = tr("没有配置 OpenCodex 精选模型", "No OpenCodex chosen models are configured", "未設定 OpenCodex 精選模型", "OpenCodex の選択モデルが設定されていません")
        }
        let detail = makeOverviewLabel(status, font: .systemFont(ofSize: 12))
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 14, y: 14, width: 312, height: 18)
        [title, detail].forEach(view.addSubview)
        item.view = view
        return item
    }

    private func makeOpenCodexCardMenuItem(_ card: OpenCodexModelCard) -> NSMenuItem {
        let item = NSMenuItem()
        let category = card.data.category
        let layout = OpenCodexCardLayout.frames(
            for: category,
            linkPrefixWidth: AppLanguage.resolved.overviewLinkPrefixWidth
        )
        let view = NSView(frame: NSRect(origin: .zero, size: layout.cardSize))
        let titleText = OpenCodexCardPresentation.identity(for: card)
            + (card.isCurrent ? tr(" · 当前", " · Current", " · 目前", " · 現在") : "")
        let provider = makeOverviewLabel(titleText, font: .systemFont(ofSize: 15, weight: .semibold))
        provider.frame = layout.title
        let updatedAt: Date?
        switch card.data {
        case .official(_, _, _, let date), .balance(_, _, _, let date):
            updatedAt = date
        case .loading, .unavailable:
            updatedAt = nil
        }
        let refreshTime = makeOverviewLabel(
            updatedAt.map { Self.timeFormatter.string(from: $0) } ?? "--:--:--",
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        )
        refreshTime.textColor = .secondaryLabelColor
        refreshTime.alignment = .right
        refreshTime.frame = layout.refreshTime

        let primary: NSTextField
        let detail: NSTextField
        let secondary: NSTextField
        var progress: QuotaProgressView?
        var websiteLink: HoverLinkTextField?
        switch card.data {
        case .official(let remaining, let label, let reset, _):
            progress = QuotaProgressView(percentage: remaining)
            progress?.frame = layout.progress ?? .zero
            primary = makeOverviewLabel("\(Int(remaining))%", font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold))
            primary.alignment = .right
            primary.frame = layout.amount
            detail = makeOverviewLabel(label, font: .systemFont(ofSize: 13, weight: .medium))
            detail.frame = layout.quotaDetail
            secondary = makeOverviewLabel(
                reset.map { tr("重置：\($0)", "Reset: \($0)", "重設：\($0)", "リセット：\($0)") } ?? tr("重置时间不可用", "Reset time unavailable", "重設時間不可用", "リセット時刻を利用できません"),
                font: .systemFont(ofSize: 13, weight: .regular)
            )
            secondary.textColor = .secondaryLabelColor
            secondary.frame = layout.reset ?? .zero
        case .balance(let amount, let unit, let websiteURL, _):
            primary = makeOverviewLabel(Self.formatBalanceSummary(amount, unit: unit), font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold))
            primary.alignment = .right
            primary.frame = layout.amount
            detail = makeOverviewLabel(tr("剩余额度", "Remaining Balance", "剩餘額度", "残りのクォータ"), font: .systemFont(ofSize: 13, weight: .medium))
            detail.frame = layout.quotaDetail
            secondary = makeOverviewLabel(tr("官方链接：", "Official Link:", "官方連結：", "公式リンク："), font: .systemFont(ofSize: 12, weight: .regular))
            secondary.textColor = .secondaryLabelColor
            secondary.frame = layout.linkPrefix ?? .zero
            if let websiteURL, let linkFrame = layout.link {
                let link = HoverLinkTextField(text: card.provider)
                link.frame = linkFrame
                link.onActivate = { NSWorkspace.shared.open(websiteURL) }
                websiteLink = link
            }
        case .loading:
            primary = makeOverviewLabel("—", font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold))
            primary.alignment = .right
            primary.frame = layout.amount
            detail = makeOverviewLabel(
                category == .quota ? tr("正在读取额度…", "Reading quota…", "正在讀取額度…", "クォータを読み込み中…") : tr("正在读取余额…", "Reading balance…", "正在讀取餘額…", "残高を読み込み中…"),
                font: .systemFont(ofSize: 13, weight: .medium)
            )
            detail.frame = layout.quotaDetail
            secondary = makeOverviewLabel(tr("尚未获得真实数据", "No live data received yet", "尚未獲得真實資料", "実際のデータはまだ受信されていません"), font: .systemFont(ofSize: 13, weight: .regular))
            secondary.textColor = .secondaryLabelColor
            secondary.frame = layout.reset ?? layout.linkPrefix ?? .zero
        case .unavailable(_, let reason):
            primary = makeOverviewLabel("—", font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold))
            primary.alignment = .right
            primary.frame = layout.amount
            detail = makeOverviewLabel(category.unavailableTitle, font: .systemFont(ofSize: 13, weight: .medium))
            detail.frame = layout.quotaDetail
            secondary = makeOverviewLabel(reason, font: .systemFont(ofSize: 12, weight: .regular))
            secondary.textColor = .secondaryLabelColor
            secondary.lineBreakMode = .byTruncatingTail
            secondary.frame = layout.reset ?? layout.linkPrefix ?? .zero
        }
        [provider, refreshTime, primary, detail, secondary].forEach(view.addSubview)
        if let progress { view.addSubview(progress) }
        if let websiteLink { view.addSubview(websiteLink) }
        let preference = menuInput.openCodexState?.preferences.first { $0.selector == card.selector }
        item.target = self
        item.action = #selector(switchOpenCodexPreference(_:))
        item.representedObject = preference
        item.state = card.isCurrent ? .on : .off
        item.isEnabled = preference != nil
            && menuInput.openCodexState?.managementAvailable == true
            && !menuInput.openCodexSwitchInFlight
        item.view = view
        return item
    }

    private func makeOverviewErrorMenuItem(for snapshot: Snapshot) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let message = snapshot.overviewReset(refreshDate: nil, formatter: Self.timeFormatter)
        let frames = ErrorCardLayout.errorFrames(for: message)
        let view = NSView(frame: NSRect(origin: .zero, size: frames.cardSize))
        let provider = makeOverviewLabel(snapshot.overviewProvider, font: ErrorCardLayout.titleFont)
        provider.frame = frames.title
        view.addSubview(provider)
        let timeText = refreshDate.map { Self.timeFormatter.string(from: $0) } ?? "--:--:--"
        let refreshTime = ErrorCardLayout.makeRefreshTimeLabel(
            timeText,
            showsCachedBalance: snapshot.hasCachedBalance
        )
        refreshTime.frame = frames.refreshTime
        view.addSubview(refreshTime)
        let quotaDetail = makeOverviewLabel(snapshot.overviewQuotaDetail, font: ErrorCardLayout.quotaFont)
        quotaDetail.frame = frames.quotaDetail
        view.addSubview(quotaDetail)
        let amount = makeOverviewLabel(snapshot.overviewLargeAmount, font: ErrorCardLayout.amountFont)
        amount.alignment = .right
        amount.frame = frames.amount
        view.addSubview(amount)
        let detail = ErrorCardLayout.makeDetailLabel(
            frames.detailText,
            textColor: snapshot.provider.isEmpty ? .secondaryLabelColor : .systemRed
        )
        detail.frame = frames.detail
        view.addSubview(detail)
        item.view = view
        return item
    }

    private func makeOverviewLabel(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func formatBalanceSummary(_ amount: Double, unit: String) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        switch unit.uppercased() {
        case "USD":
            return "$\(number)"
        case "CNY", "CNH", "RMB":
            return "¥\(number)"
        default:
            return "\(number) \(unit)"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
