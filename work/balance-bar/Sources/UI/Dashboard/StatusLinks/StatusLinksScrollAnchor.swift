import AppKit

final class StatusLinksWeakViewReference {
    weak var view: NSView?

    init(_ view: NSView?) {
        self.view = view
    }
}

struct StatusLinksScrollPosition {
    let operation: String
    let visibleDocumentOffset: CGFloat
    let contentOriginY: CGFloat
    let distanceFromBottom: CGFloat
    let previousMaximumOffset: CGFloat
    let bottomAnchorView: StatusLinksWeakViewReference?
    let bottomAnchorViewportY: CGFloat?
}

enum StatusLinksScrollAnchor {
    static func visualOffsetPreservingDistanceFromBottom(
        _ distanceFromBottom: CGFloat,
        geometry: DashboardScrollGeometry
    ) -> CGFloat {
        geometry.clampedVisualOffset(
            geometry.maximumOffset - max(0, distanceFromBottom)
        )
    }

    static func isViewportYVisible(
        _ viewportY: CGFloat,
        in bounds: NSRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        viewportY >= bounds.minY - tolerance
            && viewportY <= bounds.maxY + tolerance
    }
}

final class StatusLinksScrollAnchorController {
    private let dashboardProvider: () -> NSWindow?
    private let contentHostProvider: () -> NSView?
    private let sectionTitleProvider: () -> String
    private let linksCountProvider: () -> Int
    private var maintenanceGeneration = 0
    private weak var observedScrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private var liveScrollObserver: NSObjectProtocol?
    private var previousPostsBoundsChangedNotifications = false
    private var isApplyingAnchorBounds = false
    private var anchorTransactionActive = false
    private var lastObservedDocumentHeight: CGFloat?

    init(
        dashboardProvider: @escaping () -> NSWindow?,
        contentHostProvider: @escaping () -> NSView?,
        sectionTitleProvider: @escaping () -> String,
        linksCountProvider: @escaping () -> Int
    ) {
        self.dashboardProvider = dashboardProvider
        self.contentHostProvider = contentHostProvider
        self.sectionTitleProvider = sectionTitleProvider
        self.linksCountProvider = linksCountProvider
    }

    var isMaintainingAnchor: Bool {
        anchorTransactionActive
    }

    func stop() {
        maintenanceGeneration &+= 1
        if let contentView = observedScrollView?.contentView {
            contentView.postsBoundsChangedNotifications =
                previousPostsBoundsChangedNotifications
        }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        if let liveScrollObserver {
            NotificationCenter.default.removeObserver(liveScrollObserver)
        }
        boundsObserver = nil
        liveScrollObserver = nil
        observedScrollView = nil
        anchorTransactionActive = false
    }

    deinit {
        stop()
    }

    func logEditorGeometry(label: String) {
        guard let page = currentPage,
              let editor = firstStatusLinksEditor(in: page) else {
            return
        }
        editor.logGeometry(label: label)
    }

    func refreshEditorInPlace(
        links: [StatusLink],
        scrollPosition: StatusLinksScrollPosition?,
        operation: String
    ) -> Bool {
        guard let page = currentPage,
              let editor = firstStatusLinksEditor(in: page)
        else {
            SwitchLog.write(
                "in-place status-link refresh failed; action=\(operation); reason=editor-not-found; host_subviews=\(contentHostProvider()?.subviews.count ?? 0)",
                level: .warning,
                category: "ui.layout"
            )
            return false
        }
        SwitchLog.write(
            "in-place status-link refresh started; action=\(operation); old_rows=\(editor.rowCount); new_rows=\(links.count); editor_frame=\(DashboardLogging.rect(editor.frame))",
            category: "ui.layout"
        )
        let transactionGeneration: Int?
        if scrollPosition != nil {
            beginAnchorTransaction(operation: operation)
            transactionGeneration = maintenanceGeneration
        } else {
            stop()
            transactionGeneration = nil
        }
        editor.updateLinks(
            links,
            animated: true,
            revealAddedRowsAtCompletion: operation == "add"
        ) { [weak self, weak page, weak editor] in
            guard let self, let page, let editor else { return }
            if let transactionGeneration,
               self.maintenanceGeneration != transactionGeneration {
                return
            }
            self.stop()
            page.layoutSubtreeIfNeeded()
            editor.superview?.layoutSubtreeIfNeeded()
            SwitchLog.write(
                "in-place status-link refresh animation completed; action=\(operation); rows=\(editor.rowCount); editor_frame=\(DashboardLogging.rect(editor.frame)); page_frame=\(DashboardLogging.rect(page.frame))",
                category: "ui.layout"
            )
            editor.logGeometry(label: "after \(operation) animation")
            if let scrollPosition {
                self.restore(scrollPosition, attempt: 0)
            }
            self.scheduleScrollLog(label: "after \(operation) animation")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.logScrollState(label: "after \(operation) settled")
                editor.logGeometry(label: "after \(operation) settled")
            }
        }
        // The height constraint starts animating synchronously above. Correct
        // the clip view once more before returning to the run loop so the
        // first layout pass cannot expose a one-frame jump before the timer
        // gets its first tick.
        // Capture one state during the transition so the log distinguishes a
        // smooth layout animation from a late, discrete jump.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.logScrollState(label: "during \(operation) animation")
        }
        return true
    }

    func clampDashboardScrollViewBounds() {
        // Native NSClipView/NSScrollView owns ordinary bounds enforcement.
        DashboardScrollTrace.marker("native-scroll-clamp-no-op", source: "StatusLinks")
    }

    func startMaintenance(
        _ position: StatusLinksScrollPosition,
        operation: String
    ) {
        beginAnchorTransaction(operation: operation)
        DashboardScrollTrace.marker(
            "anchor-maintenance-start",
            source: "StatusLinks",
            flags: "operation=\(operation)"
        )
        SwitchLog.write(
            "scroll anchor transaction started; action=\(operation); adjustment=one-shot-after-layout; distanceFromBottom=\(DashboardLogging.number(position.distanceFromBottom))",
            category: "ui.scroll"
        )
    }

    func capture(
        captureLabel: String,
        operation: String
    ) -> StatusLinksScrollPosition? {
        guard let page = currentPage,
              let scrollView = firstScrollView(in: page),
              let documentView = scrollView.documentView
        else {
            SwitchLog.write(
                "scroll position capture failed; label=\(captureLabel); action=\(operation); page=\(sectionTitleProvider()); reason=scroll-view-not-found",
                level: .warning,
                category: "ui.scroll"
            )
            return nil
        }
        page.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let geometry = dashboardScrollGeometry(
            scrollView: scrollView,
            documentView: documentView
        )
        let visibleDocumentRect = scrollView.contentView.convert(
            scrollView.contentView.bounds,
            to: documentView
        )
        let visibleDocumentOffset = geometry.clampedVisualOffset(
            for: visibleDocumentRect
        )
        let bottomAnchor = statusLinksBottomAnchor(
            in: page,
            scrollView: scrollView
        )
        let bottomAnchorIsVisible = bottomAnchor.map { anchor in
            StatusLinksScrollAnchor.isViewportYVisible(
                anchor.viewportY,
                in: scrollView.contentView.bounds
            )
        } ?? false
        let activeBottomAnchor = bottomAnchorIsVisible ? bottomAnchor : nil
        let position = StatusLinksScrollPosition(
            operation: operation,
            visibleDocumentOffset: visibleDocumentOffset,
            contentOriginY: scrollView.contentView.bounds.origin.y,
            distanceFromBottom: max(0, geometry.maximumOffset - visibleDocumentOffset),
            previousMaximumOffset: geometry.maximumOffset,
            bottomAnchorView: activeBottomAnchor.map {
                StatusLinksWeakViewReference($0.view)
            },
            bottomAnchorViewportY: activeBottomAnchor?.viewportY
        )
        SwitchLog.write(
            "scroll position captured; label=\(captureLabel); action=\(operation); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView)); visibleDocumentOffset=\(DashboardLogging.number(visibleDocumentOffset)); contentOriginY=\(DashboardLogging.number(position.contentOriginY)); distanceFromBottom=\(DashboardLogging.number(position.distanceFromBottom)); previousMaximumOffset=\(DashboardLogging.number(geometry.maximumOffset)); bottom_anchor=\(activeBottomAnchor.map { DashboardLogging.number($0.viewportY) } ?? "inactive")",
            category: "ui.scroll"
        )
        return position
    }

    func restore(
        _ position: StatusLinksScrollPosition,
        attempt: Int
    ) {
        let delay = attempt == 0 ? 0 : 0.06
        let generation = maintenanceGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.maintenanceGeneration == generation else { return }
            self.applyRestore(position, attempt: attempt)
        }
    }

    private var currentPage: NSView? {
        contentHostProvider()?.subviews.first
    }

    private func beginAnchorTransaction(operation: String) {
        stop()
        guard let page = currentPage,
              let scrollView = firstScrollView(in: page) else {
            anchorTransactionActive = true
            return
        }
        anchorTransactionActive = true
        observedScrollView = scrollView
        previousPostsBoundsChangedNotifications =
            scrollView.contentView.postsBoundsChangedNotifications
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isApplyingAnchorBounds else { return }
            self.cancelAnchorTransaction(reason: "user-bounds-movement")
        }
        liveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.cancelAnchorTransaction(reason: "live-scroll-started")
        }
        DashboardScrollTrace.marker(
            "anchor-transaction-start",
            source: "StatusLinks",
            flags: "operation=\(operation)"
        )
    }

    private func cancelAnchorTransaction(reason: String) {
        guard anchorTransactionActive else { return }
        SwitchLog.write(
            "scroll anchor transaction cancelled; reason=\(reason)",
            category: "ui.scroll"
        )
        stop()
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews {
            if let scrollView = firstScrollView(in: child) { return scrollView }
        }
        return nil
    }

    private func firstStatusLinksEditor(in view: NSView) -> StatusLinksEditorHostingView? {
        if let editor = view as? StatusLinksEditorHostingView { return editor }
        for child in view.subviews {
            if let editor = firstStatusLinksEditor(in: child) { return editor }
        }
        return nil
    }

    private func statusLinksBottomAnchor(
        in page: NSView,
        scrollView: NSScrollView
    ) -> (view: NSView, viewportY: CGFloat)? {
        guard let editor = firstStatusLinksEditor(in: page),
              let rowsStack = editor.superview as? NSStackView,
              let card = rowsStack.superview else {
            return nil
        }
        let edgeY = card.isFlipped ? card.bounds.maxY : card.bounds.minY
        let point = card.convert(
            NSPoint(x: card.bounds.midX, y: edgeY),
            to: scrollView.contentView
        )
        return (card, point.y)
    }

    private func statusLinksBottomAnchorPoint(in view: NSView) -> NSPoint {
        let edgeY = view.isFlipped ? view.bounds.maxY : view.bounds.minY
        return NSPoint(x: view.bounds.midX, y: edgeY)
    }

    private func applyRestore(
        _ position: StatusLinksScrollPosition,
        attempt: Int
    ) {
        guard let page = currentPage,
              let scrollView = firstScrollView(in: page),
              let documentView = scrollView.documentView
        else {
            SwitchLog.write(
                "scroll restore aborted; action=\(position.operation); attempt=\(attempt); reason=scroll-view-not-found",
                level: .warning,
                category: "ui.scroll"
            )
            return
        }
        SwitchLog.write(
            "scroll restore begin; action=\(position.operation); attempt=\(attempt); target_visibleDocumentOffset=\(DashboardLogging.number(position.visibleDocumentOffset)); captured_contentOriginY=\(DashboardLogging.number(position.contentOriginY)); target_distanceFromBottom=\(DashboardLogging.number(position.distanceFromBottom)); previousMaximumOffset=\(DashboardLogging.number(position.previousMaximumOffset)); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView))",
            category: "ui.scroll"
        )
        dashboardProvider()?.displayIfNeeded()
        contentHostProvider()?.layoutSubtreeIfNeeded()
        page.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        traceLayoutIfNeeded(documentView, source: "anchor-restore")
        DashboardScrollTrace.marker(
            "anchor-restore",
            source: "StatusLinks",
            flags: "operation=\(position.operation); attempt=\(attempt)"
        )
        if position.operation != "add" {
            let geometry = dashboardScrollGeometry(
                scrollView: scrollView,
                documentView: documentView
            )
            let targetVisualOffset = StatusLinksScrollAnchor
                .visualOffsetPreservingDistanceFromBottom(
                    position.distanceFromBottom,
                    geometry: geometry
                )
            let targetContentOriginY = dashboardScrollContentOrigin(
                scrollView: scrollView,
                documentView: documentView,
                visualOffset: targetVisualOffset
            )
            var bounds = scrollView.contentView.bounds
            let correction = targetContentOriginY - bounds.origin.y
            bounds.origin.y = targetContentOriginY
            setDashboardScrollBounds(
                bounds,
                scrollView: scrollView,
                documentView: documentView
            )
            SwitchLog.write(
                "scroll restore applied; action=\(position.operation); attempt=\(attempt); anchor=document-distance; target_contentOriginY=\(DashboardLogging.number(targetContentOriginY)); correction=\(DashboardLogging.number(correction)); actual_contentOriginY=\(DashboardLogging.number(scrollView.contentView.bounds.origin.y)); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView))",
                category: "ui.scroll"
            )
            return
        }

        if position.operation != "add",
           let anchorView = position.bottomAnchorView?.view,
           let targetViewportY = position.bottomAnchorViewportY,
           anchorView === page || anchorView.isDescendant(of: page) {
            let currentViewportY = anchorView.convert(
                statusLinksBottomAnchorPoint(in: anchorView),
                to: scrollView.contentView
            ).y
            let correction = currentViewportY - targetViewportY
            if abs(correction) > 0.01 {
                var bounds = scrollView.contentView.bounds
                bounds.origin.y += correction
                setDashboardScrollBounds(
                    bounds,
                    scrollView: scrollView,
                    documentView: documentView
                )
            }
            SwitchLog.write(
                "scroll restore applied; action=\(position.operation); attempt=\(attempt); anchor=card-bottom; target_viewportY=\(DashboardLogging.number(targetViewportY)); actual_viewportY=\(DashboardLogging.number(currentViewportY)); correction=\(DashboardLogging.number(correction)); actual_contentOriginY=\(DashboardLogging.number(scrollView.contentView.bounds.origin.y)); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView))",
                category: "ui.scroll"
            )
            return
        }

        var bounds = scrollView.contentView.bounds
        let targetContentOriginY = dashboardScrollContentOrigin(
            scrollView: scrollView,
            documentView: documentView,
            visualOffset: position.visibleDocumentOffset
        )
        let correction = targetContentOriginY - bounds.origin.y
        bounds.origin.y = targetContentOriginY
        setDashboardScrollBounds(
            bounds,
            scrollView: scrollView,
            documentView: documentView
        )
        SwitchLog.write(
            "scroll restore applied; action=\(position.operation); attempt=\(attempt); anchor=visible-document-offset; target_contentOriginY=\(DashboardLogging.number(targetContentOriginY)); correction=\(DashboardLogging.number(correction)); actual_contentOriginY=\(DashboardLogging.number(scrollView.contentView.bounds.origin.y)); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView))",
            category: "ui.scroll"
        )

    }

    private func dashboardScrollGeometry(
        scrollView: NSScrollView,
        documentView: NSView
    ) -> DashboardScrollGeometry {
        DashboardScrollGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: scrollView.contentView.bounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
    }

    private func setDashboardScrollBounds(
        _ proposedBounds: NSRect,
        scrollView: NSScrollView,
        documentView: NSView
    ) {
        let contentView = scrollView.contentView
        let geometry = dashboardScrollGeometry(
            scrollView: scrollView,
            documentView: documentView
        )
        let proposedVisibleRect = contentView.convert(proposedBounds, to: documentView)
        let targetVisualOffset = geometry.clampedVisualOffset(
            for: proposedVisibleRect
        )
        var legalBounds = proposedBounds
        legalBounds.origin.y = dashboardScrollContentOrigin(
            scrollView: scrollView,
            documentView: documentView,
            visualOffset: targetVisualOffset
        )
        guard abs(contentView.bounds.origin.y - legalBounds.origin.y) > 0.001 else {
            return
        }
        DashboardScrollTrace.marker(
            "anchor-transaction-write",
            source: "StatusLinks",
            flags: "programmatic=true; one-shot=true"
        )
        isApplyingAnchorBounds = true
        defer { isApplyingAnchorBounds = false }
        contentView.bounds = legalBounds
        let visibleRect = contentView.convert(contentView.bounds, to: documentView)
        DashboardScrollTrace.record(
            kind: "reflect-scrolled-clip-view",
            source: "StatusLinks",
            resultOriginY: contentView.bounds.origin.y,
            visualOffset: geometry.visualOffset(for: visibleRect),
            legalMaximum: geometry.maximumOffset,
            documentHeight: documentView.bounds.height,
            viewportHeight: contentView.bounds.height
        )
        scrollView.reflectScrolledClipView(contentView)
    }

    private func dashboardScrollContentOrigin(
        scrollView: NSScrollView,
        documentView: NSView,
        visualOffset: CGFloat
    ) -> CGFloat {
        let geometry = dashboardScrollGeometry(
            scrollView: scrollView,
            documentView: documentView
        )
        let targetDocumentRect = geometry.visibleDocumentRect(
            forVisualOffset: visualOffset
        )
        let targetDocumentY = geometry.contentOriginDocumentY(
            for: targetDocumentRect,
            contentViewIsFlipped: scrollView.contentView.isFlipped
        )
        return documentView.convert(
            NSPoint(
                x: documentView.bounds.minX,
                y: targetDocumentY
            ),
            to: scrollView.contentView
        ).y
    }

    private func dashboardScrollMetrics(
        scrollView: NSScrollView,
        documentView: NSView
    ) -> String {
        let contentView = scrollView.contentView
        let bounds = contentView.bounds
        let viewportRect = contentView.convert(bounds, to: documentView)
        let geometry = dashboardScrollGeometry(
            scrollView: scrollView,
            documentView: documentView
        )
        let visualOffset = geometry.clampedVisualOffset(for: viewportRect)
        return "page=\(sectionTitleProvider()); links=\(linksCountProvider()); content_originY=\(DashboardLogging.number(bounds.origin.y)); content_height=\(DashboardLogging.number(bounds.height)); document_frame=\(DashboardLogging.rect(documentView.frame)); document_bounds=\(DashboardLogging.rect(documentView.bounds)); viewport_document=\(DashboardLogging.rect(viewportRect)); visual_offset=\(DashboardLogging.number(visualOffset)); maxOffset=\(DashboardLogging.number(geometry.maximumOffset))"
    }

    private func traceLayoutIfNeeded(_ documentView: NSView, source: String) {
        let height = documentView.bounds.height
        guard let previousHeight = lastObservedDocumentHeight else {
            lastObservedDocumentHeight = height
            return
        }
        guard abs(previousHeight - height) >
                DashboardScrollClampingPolicy.boundsOriginTolerance else {
            return
        }
        lastObservedDocumentHeight = height
        DashboardScrollTrace.record(
            kind: "document-height-change",
            source: source,
            documentHeight: height,
            flags: "previous=\(DashboardLogging.number(previousHeight))"
        )
    }

    private func logScrollState(label: String) {
        guard let page = currentPage,
              let scrollView = firstScrollView(in: page),
              let documentView = scrollView.documentView else {
            SwitchLog.write(
                "scroll state; label=\(label); page=\(sectionTitleProvider()); reason=scroll-view-not-found",
                level: .warning,
                category: "ui.scroll"
            )
            return
        }
        page.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        SwitchLog.write(
            "scroll state; label=\(label); \(dashboardScrollMetrics(scrollView: scrollView, documentView: documentView))",
            category: "ui.scroll"
        )
    }

    private func scheduleScrollLog(label: String) {
        DispatchQueue.main.async { [weak self] in
            self?.logScrollState(label: label)
        }
    }
}
