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

/// Arranged result stacks preserve AppKit's visibility-priority collapse
/// semantics for filtered sections and whole-page groups.
private final class DashboardGlobalSearchResultsView: NSStackView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .leading
        spacing = DashboardSettingsComponents.settingsSectionSpacing
        distribution = .gravityAreas
        // Search projection groups must collapse with their arranged spacing;
        // keeping hidden groups attached leaves a fixed outer gap per stale
        // query result.
        detachesHiddenViews = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addGroup(_ group: NSView, spacing _: CGFloat) {
        addArrangedSubview(group)
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

private final class DashboardGlobalSearchGroupView: NSStackView {
    var settingsSection: DashboardSection = .general
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = DashboardPageSearch.globalSearchGroupIdentifier
        orientation = .vertical
        alignment = .leading
        spacing = DashboardSettingsComponents.settingsSectionSpacing
        distribution = .gravityAreas
        // Hidden sections are removed from the layout contribution, including
        // the stack spacing between them.
        detachesHiddenViews = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addPage(_ page: NSView) {
        addArrangedSubview(page)
        page.translatesAutoresizingMaskIntoConstraints = false
        page.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    func addSection(_ section: NSView, spacing _: CGFloat) {
        addArrangedSubview(section)
        section.translatesAutoresizingMaskIntoConstraints = false
        section.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

private final class DashboardSearchCancellationState {
    var workItem: DispatchWorkItem?
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
    private var isGlobalSettingsSearchActive = false
    private weak var globalSettingsSearchContent: NSView?
    private var globalSearchOriginContent: NSView?
    private var globalSettingsSearchSections: Set<DashboardSection> = []
    private var globalSearchGroupsBySection: [DashboardSection: DashboardGlobalSearchGroupView] = [:]
    private var isBuildingGlobalSearchPage = false
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
    private var pendingDashboardSearchWorkItem: DispatchWorkItem?
    private var pendingSearchMatchWorkItem: DispatchWorkItem?
    private var dashboardSearchGeneration: UInt64 = 0
    private var searchDataRevision: UInt64 = 0
    private var lastAppliedSearchQuery: String?
    private var lastAppliedSearchRevision: UInt64 = 0
    private weak var lastAppliedSearchRoot: NSView?
    private var synchronousSearchForTesting = false
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
                // Page replacement invokes this callback synchronously. The
                // toolbar's searchQuery is the live accepted editor value, so
                // the search page cannot be cleared by an older submission.
                if self?.isBuildingGlobalSearchPage != true {
                    self?.applyMountedPageSearch()
                }
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
    func rebuild() {
        invalidateSearchData()
        pageSession.rebuild(on: windowController)
    }
    func showSection(_ section: DashboardSection) { pageSession.showSection(section) }
    func showProvider(_ providerID: String) { pageSession.showProvider(providerID) }
    func teardown() {
        invalidateSearchData()
        isGlobalSettingsSearchActive = false
        globalSettingsSearchContent = nil
        globalSearchOriginContent = nil
        globalSettingsSearchSections.removeAll()
        globalSearchGroupsBySection.removeAll()
        dashboardProviderPages.teardown()
        dashboardPreferencePages.teardown()
        pageSession.teardown()
        windowController.teardown()
    }

    func refreshMountedPage(snapshot: Snapshot, refreshDate: Date?, revision: UInt64) {
        invalidateSearchData()
        _ = dashboardProviderPages.refreshMountedPage(
            input: makeProviderPageInput(
                snapshot: snapshot,
                refreshDate: refreshDate,
                useLastSuccessfulRefresh: false,
                revision: revision
            )
        )
        refreshMenuBarPage(
            snapshot: snapshot,
            invalidateSearchData: false,
            reapplySearch: false
        )
        if !pageSession.toolbarController.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyMountedPageSearch()
        }
    }

    func refreshMenuBarPage(snapshot: Snapshot) {
        refreshMenuBarPage(
            snapshot: snapshot,
            invalidateSearchData: true,
            reapplySearch: true
        )
    }

    private func refreshMenuBarPage(
        snapshot: Snapshot,
        invalidateSearchData: Bool,
        reapplySearch: Bool
    ) {
        guard canUpdateSettingsPage(.menuBar) else { return }
        if invalidateSearchData {
            self.invalidateSearchData()
        }
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
        if reapplySearch,
           !pageSession.toolbarController.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyMountedPageSearch()
        }
    }

    func refreshMenuPage() {
        guard canUpdateSettingsPage(.menu) else { return }
        invalidateSearchData()
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
        guard canUpdateSettingsPage(.menuBar) else { return }
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
        guard canUpdateSettingsPage(.menuBar) else { return }
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
        guard canUpdateSettingsPage(.menuBar) else { return }
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
        guard canUpdateSettingsPage(.menuBar) else { return }
        dashboardPreferencePages.updateMenuBarAnimationFallback(active: active)
    }

    func refreshMenuBarWidthAdjustment(
        _ widthAdjustment: Double,
        horizontalPadding: CGFloat
    ) {
        guard canUpdateSettingsPage(.menuBar) else { return }
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
        guard canUpdateSettingsPage(.general) else { return }
        dashboardPreferencePages.refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin(_ state: LaunchAtLoginState) {
        guard canUpdateSettingsPage(.general) else { return }
        dashboardPreferencePages.refreshLaunchAtLogin(state)
    }

    func refreshLaunchWithChatGPT() {
        guard canUpdateSettingsPage(.general) else { return }
        dashboardPreferencePages.refreshLaunchWithChatGPT()
    }

    func refreshLaunchWithChatGPT(_ state: LaunchWithChatGPTState) {
        guard canUpdateSettingsPage(.general) else { return }
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
        synchronousSearchForTesting = true
        defer { synchronousSearchForTesting = false }
        pageSession.toolbarController.setQuery(query)
        pendingDashboardSearchWorkItem?.cancel()
        dashboardSearchGeneration &+= 1
        handleDashboardSearch(query)
    }

    func currentHostedPageContentForTesting() -> NSView {
        pageSession.currentHostedPageContent()
    }

    private func bindDashboardSearch() {
        pageSession.toolbarController.onSearchQueryChanged = { [weak self] query in
            self?.scheduleDashboardSearch(query)
        }
    }

    private func scheduleDashboardSearch(_ query: String) {
        pendingDashboardSearchWorkItem?.cancel()
        dashboardSearchGeneration &+= 1
        let generation = dashboardSearchGeneration
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            handleDashboardSearch(query)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dashboardSearchGeneration == generation else { return }
            self.handleDashboardSearch(query)
        }
        pendingDashboardSearchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(45), execute: work)
    }

    private func invalidateSearchData() {
        searchDataRevision &+= 1
        pendingSearchMatchWorkItem?.cancel()
        pendingSearchMatchWorkItem = nil
        pageSearchFilter.prepareForDataRefresh()
        lastAppliedSearchQuery = nil
        lastAppliedSearchRoot = nil
    }

    private func handleDashboardSearch(_ query: String) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            if isGlobalSettingsSearchActive {
                clearGlobalSettingsSearch()
                return
            }
            applyMountedPageSearch()
            return
        }
        if selectedProviderID != nil || section == .about {
            isGlobalSettingsSearchActive = false
            globalSettingsSearchContent = nil
            globalSearchOriginContent = nil
            globalSettingsSearchSections.removeAll()
            globalSearchGroupsBySection.removeAll()
            applyMountedPageSearch(queryOverride: query)
            return
        }
        if !isGlobalSettingsSearchActive {
            isGlobalSettingsSearchActive = true
            showGlobalSettingsSearchPage(initialQuery: needle)
            return
        }
        applyMountedPageSearch(queryOverride: query)
    }

    private func applyMountedPageSearch(queryOverride: String? = nil) {
        let query = queryOverride ?? pageSession.toolbarController.searchQuery
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty, isGlobalSettingsSearchActive {
            clearGlobalSettingsSearch()
            return
        }
        if selectedProviderID != nil || section == .about {
            isGlobalSettingsSearchActive = false
            globalSettingsSearchContent = nil
            globalSearchOriginContent = nil
            globalSettingsSearchSections.removeAll()
        } else if !needle.isEmpty, !isGlobalSettingsSearchActive {
            isGlobalSettingsSearchActive = true
            showGlobalSettingsSearchPage(initialQuery: query)
            return
        } else if !needle.isEmpty, isGlobalSettingsSearchActive,
                  pageSession.currentHostedPageContent() !== globalSettingsSearchContent {
            guard !isBuildingGlobalSearchPage else { return }
            showGlobalSettingsSearchPage(initialQuery: query)
            return
        }
        pageSearchFilter.statusLinks = state.statusLinks()
        if !needle.isEmpty, isGlobalSettingsSearchActive {
            addGlobalSettingsSearchPages(matching: needle)
        }
        let root = pageSession.currentHostedPageContent()
        if lastAppliedSearchQuery == query,
           lastAppliedSearchRevision == searchDataRevision,
           lastAppliedSearchRoot === root {
            return
        }
        submitSearch(
            query: query,
            root: root,
            pageTitle: currentSearchPageTitle(),
            mode: currentSearchMode()
        )
        DashboardKeyViewLoop.resignUnreachableFirstResponder(window)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
    }

    private func submitSearch(
        query: String,
        root: NSView,
        pageTitle: String,
        mode: DashboardPageSearchMode
    ) {
        pendingSearchMatchWorkItem?.cancel()
        let documents = pageSearchFilter.searchDocuments(for: root)
        let queryRevision = searchDataRevision
        let queryGeneration = dashboardSearchGeneration
        let rootID = ObjectIdentifier(root)

        if synchronousSearchForTesting || AutomatedTestHost.isRunning {
            let matches = DashboardPageSearch.matchDocuments(documents, query: query)
            _ = pageSearchFilter.apply(
                query: query,
                to: root,
                pageTitle: pageTitle,
                mode: mode,
                matchedDocumentIDs: Set(matches.map(\.documentID))
            )
            lastAppliedSearchQuery = query
            lastAppliedSearchRevision = queryRevision
            lastAppliedSearchRoot = root
            return
        }

        let cancellationState = DashboardSearchCancellationState()
        let workItem = DispatchWorkItem { [weak self] in
            let matches = DashboardPageSearch.matchDocuments(
                documents,
                query: query,
                isCancelled: { cancellationState.workItem?.isCancelled == true }
            )
            guard cancellationState.workItem?.isCancelled != true else { return }
            let matchedDocumentIDs = Set(matches.map(\.documentID))
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      cancellationState.workItem?.isCancelled != true,
                      self.dashboardSearchGeneration == queryGeneration,
                      self.searchDataRevision == queryRevision,
                      self.pageSession.toolbarController.searchQuery == query else {
                    return
                }
                let currentRoot = self.pageSession.currentHostedPageContent()
                guard ObjectIdentifier(currentRoot) == rootID else { return }
                _ = self.pageSearchFilter.apply(
                    query: query,
                    to: currentRoot,
                    pageTitle: pageTitle,
                    mode: mode,
                    matchedDocumentIDs: matchedDocumentIDs
                )
                self.lastAppliedSearchQuery = query
                self.lastAppliedSearchRevision = queryRevision
                self.lastAppliedSearchRoot = currentRoot
            }
        }
        cancellationState.workItem = workItem
        pendingSearchMatchWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private func showGlobalSettingsSearchPage(initialQuery: String? = nil) {
        guard !isBuildingGlobalSearchPage else { return }
        isBuildingGlobalSearchPage = true
        defer { isBuildingGlobalSearchPage = false }
        if pageSession.currentHostedPageContent() !== globalSettingsSearchContent {
            globalSearchOriginContent = pageSession.currentHostedPageContent()
        }
        pageSearchFilter.resetSearchState()
        lastAppliedSearchQuery = nil
        lastAppliedSearchRoot = nil
        globalSettingsSearchContent = nil
        globalSettingsSearchSections.removeAll()
        globalSearchGroupsBySection.removeAll()
        pageSearchFilter.statusLinks = state.statusLinks()
        pageSession.showSearchResults(makeContent: { [weak self] in
            guard let self else {
                return DashboardSettingsComponents.makeSettingsPageContent([])
            }
            let content = self.makeGlobalSettingsSearchContent()
            self.globalSettingsSearchContent = content
            return content
        }, preservingCurrentPage: true)
        // The first committed query must build its complete candidate set in
        // the same turn. Otherwise a direct query can miss dynamic sections
        // until a later edit happens to broaden or change the query.
        let initialQuery = (initialQuery ?? pageSession.toolbarController.searchQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !initialQuery.isEmpty {
            addGlobalSettingsSearchPages(matching: initialQuery)
            let root = pageSession.currentHostedPageContent()
            submitSearch(
                query: initialQuery,
                root: root,
                pageTitle: "",
                mode: .titles
            )
        }
    }

    private func clearGlobalSettingsSearch() {
        let origin = globalSearchOriginContent
        if let current = globalSettingsSearchContent {
            _ = pageSearchFilter.apply(
                query: "",
                to: current,
                pageTitle: "",
                mode: .titles
            )
        }
        isGlobalSettingsSearchActive = false
        globalSettingsSearchContent = nil
        globalSettingsSearchSections.removeAll()
        globalSearchGroupsBySection.removeAll()
        globalSearchOriginContent = nil
        lastAppliedSearchQuery = nil
        lastAppliedSearchRoot = nil
        if let origin {
            pageSession.showHostedSettingsContent(origin)
        } else {
            pageSession.showSection(section)
        }
    }

    private func makeGlobalSettingsSearchContent() -> NSView {
        let content = DashboardGlobalSearchResultsView()
        content.translatesAutoresizingMaskIntoConstraints = false
        return content
    }

    private func addGlobalSettingsSearchPages(matching query: String) {
        guard let searchContent = globalSettingsSearchContent,
              let resultStack = searchContent as? DashboardGlobalSearchResultsView else { return }
        // Materialize only catalog/runtime candidates for this query. Every
        // candidate uses the same real-row projection so changing query
        // length never changes the representation of an existing result.
        let allSettingsSections = DashboardSection.allCases.filter { $0 != .about }
        let runtimeTexts: [DashboardSection: [String]] = [
            .general: [state.currentProviderName()],
            .menu: state.statusLinks().flatMap { [$0.title, $0.url] }
        ]
        let ranked = DashboardSettingsSearchCatalog.rankedSections(
            query: query,
            statusLinks: state.statusLinks(),
            runtimeTexts: runtimeTexts,
            includeSupportingTexts: !isSingleCharacterAlphabeticQuery(query),
            singleCharacterWordBoundaryOnly: isSingleCharacterAlphabeticQuery(query)
        )
        var candidateSections = ranked.map(\.section)
        if !isSingleCharacterAlphabeticQuery(query), !candidateSections.contains(section) {
            candidateSections.append(section)
        }
        let candidateSet = Set(candidateSections)
        var structureChanged = false
        if isSingleCharacterAlphabeticQuery(query) {
            let staleSections = globalSearchGroupsBySection.keys.filter {
                !candidateSet.contains($0)
            }
            if !staleSections.isEmpty {
                pageSearchFilter.resetSearchState()
                for staleSection in staleSections {
                    if let group = globalSearchGroupsBySection.removeValue(forKey: staleSection) {
                        resultStack.removeArrangedSubview(group)
                        group.removeFromSuperview()
                    }
                    globalSettingsSearchSections.remove(staleSection)
                }
                structureChanged = true
            }
        }
        let missingSections = allSettingsSections.filter {
            candidateSet.contains($0) && !globalSettingsSearchSections.contains($0)
        }
        guard !missingSections.isEmpty || structureChanged else { return }

        for settingsSection in missingSections {
            let group = DashboardGlobalSearchGroupView()
            group.settingsSection = settingsSection
            group.translatesAutoresizingMaskIntoConstraints = false
            populateGlobalSearchGroup(group, for: settingsSection)
            resultStack.addGroup(group, spacing: DashboardSettingsComponents.settingsSectionSpacing)
            globalSettingsSearchSections.insert(settingsSection)
            globalSearchGroupsBySection[settingsSection] = group
            DashboardPageSearchDiagnostics.globalSearchPagesMaterializedCount += 1
        }
        if structureChanged || !missingSections.isEmpty {
            pageSearchFilter.markSearchStructureChanged()
        }

        let orderedGroups = resultStack.arrangedSubviews
            .compactMap { $0 as? DashboardGlobalSearchGroupView }
            .sorted { lhs, rhs in
                let lhsIndex = allSettingsSections.firstIndex(of: lhs.settingsSection) ?? .max
                let rhsIndex = allSettingsSections.firstIndex(of: rhs.settingsSection) ?? .max
                return lhsIndex < rhsIndex
            }
        resultStack.setViews(orderedGroups, in: .top)
        resultStack.needsLayout = true
    }

    private func populateGlobalSearchGroup(
        _ group: DashboardGlobalSearchGroupView,
        for settingsSection: DashboardSection
    ) {
        if settingsSection == section, let origin = globalSearchOriginContent {
            group.addPage(origin)
            return
        }
        let page = makeSectionPage(for: settingsSection, forSearch: true)
        let sourceStack: NSStackView? = {
            if let stack = page as? NSStackView { return stack }
            return page.subviews.compactMap { $0 as? NSStackView }.first
        }()
        for sourceSection in sourceStack?.arrangedSubviews ?? [] {
            sourceStack?.removeView(sourceSection)
            sourceSection.removeFromSuperview()
            group.addSection(sourceSection, spacing: DashboardSettingsComponents.settingsSectionSpacing)
        }
    }

    private func isSingleCharacterAlphabeticQuery(_ query: String) -> Bool {
        let normalized = DashboardPageSearch.normalize(query)
        guard normalized.unicodeScalars.count == 1 else { return false }
        return normalized.rangeOfCharacter(from: .letters) != nil
    }

    private func currentSearchPageTitle() -> String {
        if isGlobalSettingsSearchActive { return "" }
        if let selectedProviderID,
           let name = state.providerChoices().first(where: { $0.id == selectedProviderID })?.name {
            return name
        }
        return section.title
    }

    private func currentSearchMode() -> DashboardPageSearchMode {
        selectedProviderID != nil || section == .about ? .visibleCopy : .titles
    }

    private func canUpdateSettingsPage(_ target: DashboardSection) -> Bool {
        window?.isVisible == true && (section == target || isGlobalSettingsSearchActive)
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

    private func makeSectionPage(for section: DashboardSection, forSearch: Bool = false) -> NSView {
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
            updateState: state.updateState(),
            forSearch: forSearch
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
        invalidateSearchData()
        SwitchLog.write(
            "status link edited; index=\(index); field=\(field == .title ? "title" : "url"); length=\(value.count)",
            category: "configuration"
        )
        actions.onStatusLinksChanged()
    }

    private func addStatusLink(at index: Int) {
        guard section == .menu || isGlobalSettingsSearchActive else { return }
        var links = state.statusLinks()
        guard links.indices.contains(index) || index == links.endIndex else { return }
        links.insert(StatusLink(title: "", url: ""), at: index)
        state.setStatusLinks(links)
        invalidateSearchData()
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
        guard section == .menu || isGlobalSettingsSearchActive else { return }
        var links = state.statusLinks()
        guard index >= 0, index < links.count else { return }
        links.remove(at: index)
        state.setStatusLinks(links)
        invalidateSearchData()
        SwitchLog.write("status link removed; index=\(index); count=\(links.count)", category: "configuration")
        actions.onStatusLinksChanged()
        dashboardPreferencePages.updateMenuStatusLinks(links, mutation: .remove(index))
    }

    private func moveStatusLink(from: Int, to: Int) {
        guard section == .menu || isGlobalSettingsSearchActive else { return }
        var links = state.statusLinks()
        guard links.indices.contains(from), links.indices.contains(to), from != to else { return }
        let movedLink = links.remove(at: from)
        links.insert(movedLink, at: to)
        state.setStatusLinks(links)
        invalidateSearchData()
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
        guard section == .menu || isGlobalSettingsSearchActive else { return }
        var links = state.statusLinks()
        guard links.indices.contains(index) else { return }
        links.insert(links[index], at: index + 1)
        state.setStatusLinks(links)
        invalidateSearchData()
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
        guard section == .menu || isGlobalSettingsSearchActive else { return }
        let links = state.defaultStatusLinks()
        state.setStatusLinks(links)
        invalidateSearchData()
        SwitchLog.write("status links restored to defaults; count=\(links.count)", category: "configuration")
        actions.onStatusLinksChanged()
        dashboardPreferencePages.updateMenuStatusLinks(links)
    }
}
