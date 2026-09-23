import AppKit

/// Values read by Dashboard composition. The controller never reaches into
/// application state; the composition root supplies snapshots and callbacks.
struct DashboardCompositionState {
    let preferences: AppPreferences
    let devBundleIdentifier: String
    let providerPollInterval: TimeInterval
    let currentProviderName: () -> String
    let currentProviderIsOfficial: () -> Bool
    let providerChoices: () -> [ProviderChoice]
    let snapshot: () -> Snapshot
    let quickSwitchSummaries: () -> [String: String]
    let refreshDate: () -> Date?
    let menuBarSnapshot: (Snapshot) -> Snapshot
    let iconImage: () -> NSImage?
    let statusItemVisibility: () -> StatusItemVisibility
    let updateState: () -> UpdateCheckState
    let statusLinks: () -> [StatusLink]
    let defaultStatusLinks: () -> [StatusLink]
    let setStatusLinks: ([StatusLink]) -> Void
}

struct DashboardCompositionActions {
    let onManualRefresh: () -> Void
    let onSwitchProvider: (String) -> Void
    let onOpenProvider: (String) -> Void
    let onSelectProvider: (String) -> Void
    let isSortAlphabetically: () -> Bool
    let setSortAlphabetically: (Bool) -> Void
    let onToggle: (String, Bool) -> Void
    let onLaunchAtLogin: (Bool) -> Void
    let onLaunchWithChatGPT: (Bool) -> Void
    let onOpenLaunchWithChatGPTSettings: () -> Void
    let onInterval: (String, TimeInterval) -> Void
    let onBalanceDisplayThresholdChanged: (Double) -> Void
    let onQuotaProgressColorConfigurationChanged: (QuotaProgressColorConfiguration) -> Void
    let onOffsetAdjust: (String, Int) -> Void
    let onOffsetValue: (String, Double) -> Void
    let onOffsetValueEnded: (String, Double) -> Void
    let onOffsetReset: (String) -> Void
    let onLanguage: (AppLanguage) -> Void
    let onMenuBarFontSizePreset: (MenuBarFontSizePreset) -> Void
    let onMenuBarIconSizePreset: (MenuBarIconSizePreset) -> Void
    let onMenuBarIconDisplayModeChanged: (MenuBarIconDisplayMode) -> Void
    let onMenuBarIconDisplayDelayChanged: (MenuBarIconDisplayDelay) -> Void
    let onMenuBarRightClickActionChanged: (MenuBarRightClickAction) -> Void
    let onMenuBarAnimationModeChanged: (MenuBarAnimationMode) -> Void
    let onMenuBarAnimationFrameRateChanged: (Int) -> Void
    let onMenuBarQuotaWindowPreferenceChanged: (OfficialQuotaWindowPreference) -> Void
    let onMenuBarQuotaResetDisplayModeChanged: (OfficialQuotaResetDisplayMode) -> Void
    let onMenuBarLunaReserveResetTimeModeChanged: (LunaReserveResetTimeMode) -> Void
    let onLunaReserveDisplayModeChanged: (LunaReserveDisplayMode) -> Void
    let onBankedResetDisplayModeChanged: (CodexBankedResetDisplayMode) -> Void
    let onUpdateChannelChanged: (UpdateChannel) -> Void
    let onOpenCCSwitch: () -> Void
    let onOpenSystemMenuBarSettings: () -> Void
    let onCheckForUpdates: () -> Void
    let onInstallUpdate: () -> Void
    let onOpenUpdateNotes: () -> Void
    let onClamp: () -> Void
    let onStatusLinksChanged: () -> Void
    let onDidShowPage: () -> Void
    let onDidClose: () -> Void
    let onDidResize: () -> Void
}

/// Owns Dashboard shell, page composition, page lifecycle, and Status Links
/// editor coordination. It is deliberately independent of provider/network
/// refresh implementation and consumes only value/callback boundaries.
final class DashboardCompositionController {
    private let state: DashboardCompositionState
    private let actions: DashboardCompositionActions
    private let launchAtLoginController: LaunchAtLoginController
    private let launchWithChatGPTController: LaunchWithChatGPTController
    private var menuBarPreviewAnimationKind: MenuBarCompositorAnimationKind = .none
    private var menuBarPreviewAnimationIconImage: NSImage?
    private var menuBarPreviewAnimationSpriteImage: NSImage?
    private var menuBarAnimationFallbackActive = false
    private lazy var dashboardProviderPages = DashboardProviderPageCoordinator(
        actions: DashboardProviderPageActions(
            onRefresh: actions.onManualRefresh,
            onSwitchProvider: actions.onSwitchProvider,
            onOpenProvider: actions.onOpenProvider,
            onSelectProvider: actions.onSelectProvider,
            isSortAlphabetically: actions.isSortAlphabetically,
            setSortAlphabetically: actions.setSortAlphabetically
        )
    )
    private lazy var dashboardPreferencePages = DashboardPreferencePages(
        preferences: state.preferences,
        devBundleIdentifier: state.devBundleIdentifier,
        actions: DashboardPreferencePageActions(
            onToggle: actions.onToggle,
            onLaunchAtLogin: actions.onLaunchAtLogin,
            onLaunchWithChatGPT: actions.onLaunchWithChatGPT,
            onOpenLaunchWithChatGPTSettings: actions.onOpenLaunchWithChatGPTSettings,
            onInterval: actions.onInterval,
            onBalanceDisplayThresholdChanged: actions.onBalanceDisplayThresholdChanged,
            onQuotaProgressColorConfigurationChanged: actions.onQuotaProgressColorConfigurationChanged,
            onOffsetAdjust: actions.onOffsetAdjust,
            onOffsetValue: actions.onOffsetValue,
            onOffsetValueEnded: actions.onOffsetValueEnded,
            onOffsetReset: actions.onOffsetReset,
            onLanguage: actions.onLanguage,
            onMenuBarFontSizePreset: actions.onMenuBarFontSizePreset,
            onMenuBarIconSizePreset: actions.onMenuBarIconSizePreset,
            onMenuBarIconDisplayModeChanged: actions.onMenuBarIconDisplayModeChanged,
            onMenuBarIconDisplayDelayChanged: actions.onMenuBarIconDisplayDelayChanged,
            onMenuBarRightClickActionChanged: actions.onMenuBarRightClickActionChanged,
            onMenuBarAnimationModeChanged: actions.onMenuBarAnimationModeChanged,
            onMenuBarAnimationFrameRateChanged: actions.onMenuBarAnimationFrameRateChanged,
            onMenuBarQuotaWindowPreferenceChanged: actions.onMenuBarQuotaWindowPreferenceChanged,
            onMenuBarQuotaResetDisplayModeChanged: actions.onMenuBarQuotaResetDisplayModeChanged,
            onMenuBarLunaReserveResetTimeModeChanged: actions.onMenuBarLunaReserveResetTimeModeChanged,
            onLunaReserveDisplayModeChanged: actions.onLunaReserveDisplayModeChanged,
            onBankedResetDisplayModeChanged: actions.onBankedResetDisplayModeChanged,
            onUpdateChannelChanged: actions.onUpdateChannelChanged,
            onOpenCCSwitch: actions.onOpenCCSwitch,
            onOpenSystemMenuBarSettings: actions.onOpenSystemMenuBarSettings,
            onManualRefresh: actions.onManualRefresh,
            onCheckForUpdates: actions.onCheckForUpdates,
            onInstallUpdate: actions.onInstallUpdate,
            onOpenUpdateNotes: actions.onOpenUpdateNotes,
            makeStatusLinksEditor: { [weak self] in
                self?.makeStatusLinksEditor()
                    ?? StatusLinksEditorHostingView(links: [], onChange: { _, _, _ in }, onAdd: { _ in }, onRemove: { _ in }, onReset: {})
            },
            onClamp: actions.onClamp
        ),
        launchAtLoginController: launchAtLoginController,
        launchWithChatGPTController: launchWithChatGPTController
    )
    private let pageSearchFilter = DashboardPageSearchFilter()
    private lazy var pageSession = DashboardPageSession(
        actions: DashboardWindowControllerActions(
            makeSectionPage: { [weak self] section in
                self?.makeSectionPageController(for: section)
                    ?? DashboardHostedPageViewController()
            },
            makeProviderPage: { [weak self] choice in
                self?.makeProviderPageController(for: choice)
                    ?? DashboardHostedPageViewController()
            },
            providerChoices: { [weak self] in self?.state.providerChoices() ?? [] },
            prepareForPageReplacement: { [weak self] in self?.prepareForPageReplacement() },
            didShowPage: { [weak self] in
                self?.applyMountedPageSearch()
                self?.actions.onDidShowPage()
            },
            didClose: { [weak self] in
                self?.actions.onDidClose()
            },
            didResize: { [weak self] in
                self?.actions.onDidResize()
            }
        )
    )
    private lazy var windowController: DashboardWindowController = {
        let controller = DashboardWindowController()
        controller.didClose = { [weak self] in self?.actions.onDidClose() }
        controller.didResize = { [weak self] in self?.actions.onDidResize() }
        controller.onAppearanceDidChange = { [weak self] in self?.rebuild() }
        return controller
    }()

    init(
        state: DashboardCompositionState,
        actions: DashboardCompositionActions,
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        launchWithChatGPTController: LaunchWithChatGPTController = LaunchWithChatGPTController()
    ) {
        self.state = state
        self.actions = actions
        self.launchAtLoginController = launchAtLoginController
        self.launchWithChatGPTController = launchWithChatGPTController
    }

    var window: NSWindow? { windowController.window }
    var isVisible: Bool { window?.isVisible == true }
    var contentHost: NSView { pageSession.contentHost }
    var section: DashboardSection { pageSession.section }
    var selectedProviderID: String? { pageSession.selectedProviderID }
    var pageContainerForTesting: DashboardPageContainerViewController {
        pageSession.pageContainer
    }
    var scrollablePageForTesting: DashboardScrollablePageViewController? {
        pageSession.scrollablePage
    }

    func start() {
        bindDashboardSearch()
        windowController.start()
        installMenuBarRestoreSnapshotProvider()
    }
    func open(
        initialSection: DashboardSection = .general,
        scrollOffsetY: CGFloat? = nil
    ) {
        bindDashboardSearch()
        installMenuBarRestoreSnapshotProvider()
        let isNewWindow = windowController.window == nil
        windowController.open(initialSection: initialSection)
        if isNewWindow {
            pageSession.installShell(on: windowController)
            pageSession.showSection(initialSection)
            if let scrollOffsetY {
                window?.makeFirstResponder(nil)
                restorePageScrollOffsetY(scrollOffsetY)
            }
        }
        windowController.present()
        refreshLaunchAtLogin()
        refreshLaunchWithChatGPT()
    }
    func rebuild() { pageSession.rebuild(on: windowController) }
    func showSection(_ section: DashboardSection) { pageSession.showSection(section) }
    func showProvider(_ providerID: String) { pageSession.showProvider(providerID) }
    func teardown() {
        dashboardProviderPages.teardown()
        dashboardPreferencePages.teardown()
        pageSession.teardown()
        windowController.teardown()
    }

    func refreshMountedPage(snapshot: Snapshot, refreshDate: Date?, revision: UInt64) {
        _ = dashboardProviderPages.refreshMountedPage(
            input: makeProviderPageInput(
                snapshot: snapshot,
                refreshDate: refreshDate,
                useLastSuccessfulRefresh: false,
                revision: revision
            )
        )
        refreshMenuBarPage(snapshot: snapshot)
        if !pageSession.toolbarController.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyMountedPageSearch()
        }
    }

    func refreshMenuBarPage(snapshot: Snapshot) {
        guard window?.isVisible == true, section == .menuBar else { return }
        dashboardPreferencePages.refreshMenuBar(
            snapshot: snapshot,
            menuBarSnapshot: state.menuBarSnapshot,
            statusItemVisibility: state.statusItemVisibility(),
            iconImage: state.iconImage(),
            animationIconImage: idleSafeMenuBarPreviewAnimationIconImage,
            animationKind: menuBarPreviewAnimationKind,
            animationSpriteImage: menuBarPreviewAnimationSpriteImage,
            animationFallbackActive: menuBarAnimationFallbackActive
        )
        if !pageSession.toolbarController.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyMountedPageSearch()
        }
    }

    func refreshMenuPage() {
        guard window?.isVisible == true, section == .menu else { return }
        dashboardPreferencePages.refreshMenu()
        if !pageSession.toolbarController.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyMountedPageSearch()
        } else {
            DashboardKeyViewLoop.invalidate(window)
        }
    }

    /// Mirrors an already-rendered menu bar frame into the visible preview.
    /// This must stay separate from refreshMenuBarPage so animation frames do
    /// not rebuild the Dashboard page or recalculate its layout.
    func updateMenuBarPreviewIcon(_ image: NSImage?) {
        if let image {
            menuBarPreviewAnimationIconImage = image
        }
        guard window?.isVisible == true, section == .menuBar else { return }
        dashboardPreferencePages.updateMenuBarPreviewIcon(image)
    }

    /// Stores the native CA animation state even while the Dashboard is
    /// closed.  A later page creation receives the current state in its input;
    /// a visible page only performs a lightweight host/layer update here.
    func updateMenuBarPreviewAnimation(active: Bool, iconImage: NSImage?) {
        menuBarPreviewAnimationKind = active ? .codexRotation : .none
        if let iconImage {
            menuBarPreviewAnimationIconImage = iconImage
        }
        menuBarPreviewAnimationSpriteImage = nil
        guard window?.isVisible == true, section == .menuBar else { return }
        dashboardPreferencePages.updateMenuBarPreviewAnimation(
            kind: menuBarPreviewAnimationKind,
            iconImage: iconImage ?? menuBarPreviewAnimationIconImage,
            spriteImage: nil
        )
    }

    func updateClaudeMenuBarPreviewAnimation(
        active: Bool,
        iconImage: NSImage?,
        spriteImage: NSImage?
    ) {
        updateSpriteMenuBarPreviewAnimation(
            kind: .claudeThinking,
            active: active,
            iconImage: iconImage,
            spriteImage: spriteImage
        )
    }

    func updateGrokMenuBarPreviewAnimation(
        active: Bool,
        iconImage: NSImage?,
        spriteImage: NSImage?
    ) {
        let kind: MenuBarCompositorAnimationKind
        switch state.preferences.menuBarAnimationMode {
        case .efficient:
            kind = .grokThinking
        case .synchronized:
            kind = .grokThinkingBitmap
        }
        updateSpriteMenuBarPreviewAnimation(
            kind: kind,
            active: active,
            iconImage: iconImage,
            spriteImage: spriteImage
        )
    }

    private func updateSpriteMenuBarPreviewAnimation(
        kind: MenuBarCompositorAnimationKind,
        active: Bool,
        iconImage: NSImage?,
        spriteImage: NSImage?
    ) {
        menuBarPreviewAnimationKind = active ? kind : .none
        if active {
            if let iconImage {
                menuBarPreviewAnimationIconImage = iconImage
            }
            if let spriteImage {
                menuBarPreviewAnimationSpriteImage = spriteImage
            }
        } else {
            menuBarPreviewAnimationSpriteImage = nil
        }
        guard window?.isVisible == true, section == .menuBar else { return }
        dashboardPreferencePages.updateMenuBarPreviewAnimation(
            kind: menuBarPreviewAnimationKind,
            iconImage: iconImage ?? menuBarPreviewAnimationIconImage,
            spriteImage: active ? (spriteImage ?? menuBarPreviewAnimationSpriteImage) : nil
        )
    }

    /// Idle Dashboard rebuilds must not reuse a previous client's thinking
    /// bitmap as the static preview source (Issue #332).
    private var idleSafeMenuBarPreviewAnimationIconImage: NSImage? {
        menuBarPreviewAnimationKind.isActive ? menuBarPreviewAnimationIconImage : nil
    }

    func updateMenuBarAnimationFallback(active: Bool) {
        menuBarAnimationFallbackActive = active
        guard window?.isVisible == true, section == .menuBar else { return }
        dashboardPreferencePages.updateMenuBarAnimationFallback(active: active)
    }

    func refreshMenuBarWidthAdjustment(
        _ widthAdjustment: Double,
        horizontalPadding: CGFloat
    ) {
        guard window?.isVisible == true, section == .menuBar else { return }
        dashboardPreferencePages.refreshMenuBarWidthAdjustment(
            widthAdjustment,
            horizontalPadding: horizontalPadding
        )
    }

    func finishMenuBarWidthAdjustment(
        _ widthAdjustment: Double,
        horizontalPadding: CGFloat
    ) {
        dashboardPreferencePages.finishMenuBarWidthAdjustment(
            widthAdjustment,
            horizontalPadding: horizontalPadding
        )
    }

    func refreshUpdateState() {
        let updateState = state.updateState()
        dashboardPreferencePages.refreshUpdateState(updateState)
        pageSession.setShowsUpdateAvailableBadge(
            DashboardUpdatePresentation.make(for: updateState).showsUpdateBadge
        )
    }

    func refreshLaunchAtLogin() {
        guard window?.isVisible == true, section == .general else { return }
        dashboardPreferencePages.refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin(_ state: LaunchAtLoginState) {
        guard window?.isVisible == true, section == .general else { return }
        dashboardPreferencePages.refreshLaunchAtLogin(state)
    }

    func refreshLaunchWithChatGPT() {
        guard window?.isVisible == true, section == .general else { return }
        dashboardPreferencePages.refreshLaunchWithChatGPT()
    }

    func refreshLaunchWithChatGPT(_ state: LaunchWithChatGPTState) {
        guard window?.isVisible == true, section == .general else { return }
        dashboardPreferencePages.refreshLaunchWithChatGPT(state)
    }

    func updateMenuStatusVisibility(_ visible: Bool, animated: Bool) {
        dashboardPreferencePages.updateMenuStatusVisibility(visible, animated: animated)
        DashboardKeyViewLoop.invalidate(window)
    }

    func restoreRequiredMenuBarToggle(identifier: String) {
        dashboardPreferencePages.restoreRequiredMenuBarToggle(identifier: identifier)
    }

    func clampScrollBounds() {
        // NSScrollView/NSClipView owns ordinary bounds clamping. This hook is
        // retained for the Advanced page's layout callback.
    }

    func addStatusLinkForTesting() { addStatusLink(at: state.statusLinks().count) }

    func makePageForTesting(_ section: DashboardSection) -> NSView {
        let pageView = makeSectionPage(for: section)
        switch section {
        case .about:
            return pageView
        default:
            return DashboardScrollablePageViewController.makePageView(hosting: pageView)
        }
    }

    func makeWindowForTesting(showing section: DashboardSection) -> NSWindow? {
        bindDashboardSearch()
        installMenuBarRestoreSnapshotProvider()
        open(initialSection: section)
        return windowController.window
    }

    func restorePageScrollOffsetY(_ offset: CGFloat) {
        window?.layoutIfNeeded()
        contentHost.layoutSubtreeIfNeeded()
        pageSession.restorePageScrollOffsetY(offset)
        window?.makeFirstResponder(nil)
    }

    func pageScrollOffsetY() -> CGFloat {
        pageSession.pageScrollOffsetY()
    }

    func setPersistRestoreTokenForTesting(
        _ persist: @escaping (DashboardRestoreToken) -> Void
    ) {
        dashboardPreferencePages.setPersistRestoreToken(persist)
    }

    func setRelaunchApplicationForTesting(_ relaunch: @escaping () -> Void) {
        dashboardPreferencePages.setRelaunchApplication(relaunch)
    }

    private func installMenuBarRestoreSnapshotProvider() {
        dashboardPreferencePages.setRestoreSnapshotProvider { [weak self] in
            guard let self else {
                return DashboardRestoreToken(section: .menuBar, scrollOffsetY: 0)
            }
            return DashboardRestoreToken(
                section: self.section,
                scrollOffsetY: Double(self.pageSession.pageScrollOffsetY())
            )
        }
    }

    func teardownForTesting() { teardown() }

    var searchQueryForTesting: String { pageSession.toolbarController.searchQuery }

    func applySearchQueryForTesting(_ query: String) {
        pageSession.toolbarController.setQuery(query)
    }

    func currentHostedPageContentForTesting() -> NSView {
        pageSession.currentHostedPageContent()
    }

    private func bindDashboardSearch() {
        pageSession.toolbarController.onSearchQueryChanged = { [weak self] query in
            self?.handleDashboardSearch(query)
        }
    }

    private func handleDashboardSearch(_ query: String) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            applyMountedPageSearch()
            return
        }
        if selectedProviderID != nil || section == .about {
            applyMountedPageSearch()
            return
        }
        let currentMatch = pageSearchFilter.pageMatch(
            query: needle,
            in: pageSession.currentHostedPageContent(),
            pageTitle: currentSearchPageTitle(),
            mode: currentSearchMode()
        )
        let originSection = section
        var rankedCandidates = DashboardSettingsSearchCatalog.rankedSections(query: needle)
        if rankedCandidates.isEmpty, let currentMatch {
            rankedCandidates = [(originSection, currentMatch)]
        }

        for (destination, _) in rankedCandidates {
            if destination == originSection {
                guard currentMatch != nil else { continue }
                applyMountedPageSearch()
                return
            }
            pageSession.showSection(destination)
            if currentPageContainsSearchMatch(needle) {
                return
            }
        }

        if section != originSection {
            pageSession.showSection(originSection)
        }
        applyMountedPageSearch()
    }

    private func applyMountedPageSearch() {
        let query = pageSession.toolbarController.searchQuery
        _ = pageSearchFilter.apply(
            query: query,
            to: pageSession.currentHostedPageContent(),
            pageTitle: currentSearchPageTitle(),
            mode: currentSearchMode()
        )
        DashboardKeyViewLoop.resignUnreachableFirstResponder(window)
        DashboardKeyViewLoop.invalidate(window)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        pageSession.restoreCurrentPageScrollToTop()
    }

    private func currentPageContainsSearchMatch(_ query: String) -> Bool {
        pageSearchFilter.pageContainsMatch(
            query: query,
            in: pageSession.currentHostedPageContent(),
            pageTitle: currentSearchPageTitle(),
            mode: currentSearchMode()
        )
    }

    private func currentSearchPageTitle() -> String {
        if let selectedProviderID,
           let name = state.providerChoices().first(where: { $0.id == selectedProviderID })?.name {
            return name
        }
        return section.title
    }

    private func currentSearchMode() -> DashboardPageSearchMode {
        selectedProviderID != nil || section == .about ? .visibleCopy : .titles
    }

    private func prepareForPageReplacement() {
        dashboardProviderPages.unmount()
        dashboardPreferencePages.teardown()
    }

    private func makeSectionPageController(for section: DashboardSection) -> NSViewController {
        let pageView = makeSectionPage(for: section)
        switch section {
        case .about:
            return DashboardHostedPageViewController(wrapping: pageView)
        default:
            return DashboardScrollablePageViewController(wrapping: pageView)
        }
    }

    private func makeProviderPageController(for choice: ProviderChoice) -> NSViewController {
        DashboardScrollablePageViewController(wrapping: makeProviderPage(for: choice))
    }

    private func makeSectionPage(for section: DashboardSection) -> NSView {
        dashboardPreferencePages.makePage(
            for: section,
            currentProviderName: state.currentProviderName(),
            providerPollInterval: state.providerPollInterval,
            snapshot: state.snapshot(),
            menuBarSnapshot: state.menuBarSnapshot,
            statusItemVisibility: state.statusItemVisibility(),
            iconImage: state.iconImage(),
            animationIconImage: idleSafeMenuBarPreviewAnimationIconImage,
            animationKind: menuBarPreviewAnimationKind,
            animationSpriteImage: menuBarPreviewAnimationSpriteImage,
            animationFallbackActive: menuBarAnimationFallbackActive,
            updateState: state.updateState()
        )
    }

    private func makeProviderPage(for choice: ProviderChoice) -> NSView {
        dashboardProviderPages.unmount()
        return dashboardProviderPages.makeDetailPage(
            choice: choice,
            input: makeProviderPageInput()
        )
    }

    private func makeProviderPageInput(
        snapshot: Snapshot? = nil,
        refreshDate: Date? = nil,
        useLastSuccessfulRefresh: Bool = true,
        revision: UInt64 = 0
    ) -> DashboardProviderPageInput {
        DashboardProviderPageInput(
            choices: state.providerChoices(),
            selectedProviderID: pageSession.selectedProviderID,
            snapshot: snapshot ?? state.snapshot(),
            quickSwitchSummaries: state.quickSwitchSummaries(),
            refreshDate: useLastSuccessfulRefresh ? state.refreshDate() : refreshDate,
            revision: revision,
            currentProviderIsOfficial: state.currentProviderIsOfficial(),
            quotaProgressColorConfiguration: state.preferences.quotaProgressColorConfiguration,
            showQuotaProgressBar: state.preferences.showQuotaProgressBar
        )
    }

    private func makeStatusLinksEditor() -> StatusLinksEditorHostingView {
        StatusLinksEditorHostingView(
            links: state.statusLinks(),
            onChange: { [weak self] index, field, value in
                self?.statusLinkChanged(index: index, field: field, value: value)
            },
            onAdd: { [weak self] index in self?.addStatusLink(at: index) },
            onRemove: { [weak self] index in self?.removeStatusLink(at: index) },
            onReset: { [weak self] in self?.resetStatusLinks() },
            onMove: { [weak self] from, to in self?.moveStatusLink(from: from, to: to) },
            onDuplicate: { [weak self] index in self?.duplicateStatusLink(at: index) }
        )
    }

    private func statusLinkChanged(index: Int, field: StatusLinkField, value: String) {
        var links = state.statusLinks()
        guard index >= 0, index < links.count else { return }
        switch field {
        case .title: links[index].title = value
        case .url: links[index].url = value
        }
        state.setStatusLinks(links)
        SwitchLog.write(
            "status link edited; index=\(index); field=\(field == .title ? "title" : "url"); length=\(value.count)",
            category: "configuration"
        )
        actions.onStatusLinksChanged()
    }

    private func addStatusLink(at index: Int) {
        guard section == .menu else { return }
        var links = state.statusLinks()
        guard links.indices.contains(index) || index == links.endIndex else { return }
        links.insert(StatusLink(title: "", url: ""), at: index)
        state.setStatusLinks(links)
        SwitchLog.write("status link added; count=\(links.count)", category: "configuration")
        dashboardPreferencePages.updateMenuStatusLinks(
            links,
            mutation: .insert(index),
            selectLastRow: true,
            completion: { [weak self] in
                self?.actions.onStatusLinksChanged()
            }
        )
    }

    private func removeStatusLink(at index: Int) {
        guard section == .menu else { return }
        var links = state.statusLinks()
        guard index >= 0, index < links.count else { return }
        links.remove(at: index)
        state.setStatusLinks(links)
        SwitchLog.write("status link removed; index=\(index); count=\(links.count)", category: "configuration")
        actions.onStatusLinksChanged()
        dashboardPreferencePages.updateMenuStatusLinks(links, mutation: .remove(index))
    }

    private func moveStatusLink(from: Int, to: Int) {
        guard section == .menu else { return }
        var links = state.statusLinks()
        guard links.indices.contains(from), links.indices.contains(to), from != to else { return }
        let movedLink = links.remove(at: from)
        links.insert(movedLink, at: to)
        state.setStatusLinks(links)
        SwitchLog.write(
            "status link moved; from=\(from); to=\(to)",
            category: "configuration"
        )
        actions.onStatusLinksChanged()
        dashboardPreferencePages.updateMenuStatusLinks(
            links,
            mutation: .move(from: from, to: to)
        )
    }

    private func duplicateStatusLink(at index: Int) {
        guard section == .menu else { return }
        var links = state.statusLinks()
        guard links.indices.contains(index) else { return }
        links.insert(links[index], at: index + 1)
        state.setStatusLinks(links)
        SwitchLog.write(
            "status link duplicated; index=\(index); count=\(links.count)",
            category: "configuration"
        )
        actions.onStatusLinksChanged()
        dashboardPreferencePages.updateMenuStatusLinks(
            links,
            mutation: .insert(index + 1)
        )
    }

    private func resetStatusLinks() {
        guard section == .menu else { return }
        let links = state.defaultStatusLinks()
        state.setStatusLinks(links)
        SwitchLog.write("status links restored to defaults; count=\(links.count)", category: "configuration")
        actions.onStatusLinksChanged()
        dashboardPreferencePages.updateMenuStatusLinks(links)
    }
}
