import AppKit

/// Values read by Dashboard composition. The controller never reaches into
/// application state; the composition root supplies snapshots and callbacks.
struct DashboardCompositionState {
    let preferences: AppPreferences
    let devBundleIdentifier: String
    let providerPollInterval: TimeInterval
    let currentProviderName: () -> String
    let providerChoices: () -> [ProviderChoice]
    let snapshot: () -> Snapshot
    let quickSwitchSummaries: () -> [String: String]
    let refreshDate: () -> Date?
    let menuBarSnapshot: (Snapshot) -> Snapshot
    let iconImage: () -> NSImage?
    let currentOpenCodexResolution: () -> OpenCodexDashboardResolution?
    let runtimeCandidate: () -> OpenCodexEndpointCandidate?
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
    let onInterval: (String, TimeInterval) -> Void
    let onOffsetAdjust: (String, Int) -> Void
    let onOffsetValue: (String, Double) -> Void
    let onOffsetValueEnded: (String, Double) -> Void
    let onOffsetReset: (String) -> Void
    let onLanguage: (AppLanguage) -> Void
    let onOpenCCSwitch: () -> Void
    let onCheckForUpdates: () -> Void
    let onInstallUpdate: () -> Void
    let onOpenOpenCodex: () -> Void
    let onOpenCodexModeChanged: (OpenCodexDashboardMode) -> Void
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
    private var statusLinksScrollAnchorController: StatusLinksScrollAnchorController!
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
            onInterval: actions.onInterval,
            onOffsetAdjust: actions.onOffsetAdjust,
            onOffsetValue: actions.onOffsetValue,
            onOffsetValueEnded: actions.onOffsetValueEnded,
            onOffsetReset: actions.onOffsetReset,
            onLanguage: actions.onLanguage,
            onOpenCCSwitch: actions.onOpenCCSwitch,
            onManualRefresh: actions.onManualRefresh,
            onCheckForUpdates: actions.onCheckForUpdates,
            onInstallUpdate: actions.onInstallUpdate,
            onOpenOpenCodex: actions.onOpenOpenCodex,
            makeStatusLinksEditor: { [weak self] in
                self?.makeStatusLinksEditor()
                    ?? StatusLinksEditorHostingView(links: [], onChange: { _, _, _ in }, onAdd: {}, onRemove: { _ in }, onReset: {})
            },
            onOpenCodexModeChanged: actions.onOpenCodexModeChanged,
            onClamp: actions.onClamp
        )
    )
    private lazy var windowController = DashboardWindowController(
        actions: DashboardWindowControllerActions(
            makeSectionPage: { [weak self] section in
                self?.makeSectionPage(for: section) ?? NSView()
            },
            makeProviderPage: { [weak self] choice in
                self?.makeProviderPage(for: choice) ?? NSView()
            },
            providerChoices: { [weak self] in self?.state.providerChoices() ?? [] },
            prepareForPageReplacement: { [weak self] in self?.prepareForPageReplacement() },
            didShowPage: { [weak self] in
                self?.actions.onDidShowPage()
            },
            didClose: { [weak self] in
                self?.statusLinksScrollAnchorController.stop()
                self?.actions.onDidClose()
            },
            didResize: { [weak self] in
                self?.actions.onDidResize()
            }
        )
    )

    init(state: DashboardCompositionState, actions: DashboardCompositionActions) {
        self.state = state
        self.actions = actions
        statusLinksScrollAnchorController = StatusLinksScrollAnchorController(
            dashboardProvider: { [weak self] in self?.windowController.window },
            contentHostProvider: { [weak self] in self?.windowController.contentHost },
            sectionTitleProvider: { [weak self] in self?.windowController.section.title ?? "" },
            linksCountProvider: { [weak self] in self?.state.statusLinks().count ?? 0 }
        )
    }

    var window: NSWindow? { windowController.window }
    var isVisible: Bool { window?.isVisible == true }
    var contentHost: NSView { windowController.contentHost }
    var section: DashboardSection { windowController.section }
    var selectedProviderID: String? { windowController.selectedProviderID }

    func start() { windowController.start() }
    func open() { windowController.open() }
    func rebuild() { windowController.rebuild() }
    func showSection(_ section: DashboardSection) { windowController.showSection(section) }
    func showProvider(_ providerID: String) { windowController.showProvider(providerID) }
    func teardown() {
        statusLinksScrollAnchorController.stop()
        dashboardProviderPages.teardown()
        dashboardPreferencePages.teardown()
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
        refreshOpenCodexSettings()
    }

    func refreshMenuBarPage(snapshot: Snapshot) {
        guard window?.isVisible == true, section == .menuBar else { return }
        dashboardPreferencePages.refreshMenuBar(
            snapshot: snapshot,
            menuBarSnapshot: state.menuBarSnapshot,
            iconImage: state.iconImage()
        )
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

    func refreshOpenCodexSettings() {
        guard window?.isVisible == true, section == .advanced else { return }
        dashboardPreferencePages.refreshAdvanced(
            currentOpenCodexResolution: state.currentOpenCodexResolution(),
            runtimeCandidate: state.runtimeCandidate()
        )
    }

    func refreshUpdateState() {
        dashboardPreferencePages.refreshUpdateState(state.updateState())
    }

    func updateMenuStatusVisibility(_ visible: Bool, animated: Bool) {
        dashboardPreferencePages.updateMenuStatusVisibility(visible, animated: animated)
    }

    func restoreRequiredMenuBarToggle(identifier: String) {
        dashboardPreferencePages.restoreRequiredMenuBarToggle(identifier: identifier)
    }

    func handleAutomaticDetection(_ enabled: Bool) {
        dashboardPreferencePages.handleAutomaticDetection(enabled)
    }

    func clampScrollBounds() {
        statusLinksScrollAnchorController.clampDashboardScrollViewBounds()
    }

    func showSection(
        _ section: DashboardSection,
        restoringScrollPosition scrollPosition: StatusLinksScrollPosition? = nil
    ) {
        windowController.showSection(section)
        if let scrollPosition {
            statusLinksScrollAnchorController.restore(scrollPosition, attempt: 0)
        }
    }

    func addStatusLinkForTesting() { addStatusLink() }

    func makePageForTesting(_ section: DashboardSection) -> NSView {
        makeSectionPage(for: section)
    }

    func makeWindowForTesting(showing section: DashboardSection) -> NSWindow? {
        windowController.open()
        windowController.showSection(section)
        return windowController.window
    }

    func teardownForTesting() { teardown() }

    private func prepareForPageReplacement() {
        statusLinksScrollAnchorController.stop()
        dashboardProviderPages.unmount()
        dashboardPreferencePages.teardown()
    }

    private func makeSectionPage(for section: DashboardSection) -> NSView {
        dashboardPreferencePages.makePage(
            for: section,
            currentProviderName: state.currentProviderName(),
            providerPollInterval: state.providerPollInterval,
            snapshot: state.snapshot(),
            menuBarSnapshot: state.menuBarSnapshot,
            iconImage: state.iconImage(),
            currentOpenCodexResolution: state.currentOpenCodexResolution(),
            runtimeCandidate: state.runtimeCandidate(),
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
            selectedProviderID: windowController.selectedProviderID,
            snapshot: snapshot ?? state.snapshot(),
            quickSwitchSummaries: state.quickSwitchSummaries(),
            refreshDate: useLastSuccessfulRefresh ? state.refreshDate() : refreshDate,
            revision: revision
        )
    }

    private func makeStatusLinksEditor() -> StatusLinksEditorHostingView {
        StatusLinksEditorHostingView(
            links: state.statusLinks(),
            onChange: { [weak self] index, field, value in
                self?.statusLinkChanged(index: index, field: field, value: value)
            },
            onAdd: { [weak self] in self?.addStatusLink() },
            onRemove: { [weak self] index in self?.removeStatusLink(at: index) },
            onReset: { [weak self] in self?.resetStatusLinks() }
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

    private func addStatusLink() {
        let operation = "add"
        statusLinksScrollAnchorController.logEditorGeometry(label: "before add")
        let scrollPosition = statusLinksScrollAnchorController.capture(
            captureLabel: "before add",
            operation: operation
        )
        var links = state.statusLinks()
        links.append(StatusLink(title: "", url: ""))
        state.setStatusLinks(links)
        SwitchLog.write("status link added; count=\(links.count)", category: "configuration")
        actions.onStatusLinksChanged()
        if section == .menu,
           !statusLinksScrollAnchorController.refreshEditorInPlace(
               links: links,
               scrollPosition: scrollPosition,
               operation: operation
           ) {
            showSection(.menu, restoringScrollPosition: scrollPosition)
        }
    }

    private func removeStatusLink(at index: Int) {
        let operation = "remove"
        let scrollPosition = statusLinksScrollAnchorController.capture(
            captureLabel: "before remove",
            operation: operation
        )
        var links = state.statusLinks()
        guard index >= 0, index < links.count else { return }
        links.remove(at: index)
        state.setStatusLinks(links)
        SwitchLog.write("status link removed; index=\(index); count=\(links.count)", category: "configuration")
        actions.onStatusLinksChanged()
        if section == .menu,
           !statusLinksScrollAnchorController.refreshEditorInPlace(
               links: links,
               scrollPosition: scrollPosition,
               operation: operation
           ) {
            showSection(.menu, restoringScrollPosition: scrollPosition)
        }
    }

    private func resetStatusLinks() {
        guard section == .menu else { return }
        let operation = "reset"
        let scrollPosition = statusLinksScrollAnchorController.capture(
            captureLabel: "before reset",
            operation: operation
        )
        let links = state.defaultStatusLinks()
        state.setStatusLinks(links)
        SwitchLog.write("status links restored to defaults; count=\(links.count)", category: "configuration")
        actions.onStatusLinksChanged()
        if !statusLinksScrollAnchorController.refreshEditorInPlace(
            links: links,
            scrollPosition: scrollPosition,
            operation: operation
        ) {
            showSection(.menu, restoringScrollPosition: scrollPosition)
        }
    }
}
