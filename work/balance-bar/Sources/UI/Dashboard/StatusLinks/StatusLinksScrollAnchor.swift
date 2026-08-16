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

final class StatusLinksScrollAnchorTimer {
    private var timer: Timer?

    var isRunning: Bool {
        timer?.isValid == true
    }

    func start(
        interval: TimeInterval = 1.0 / 60.0,
        tick: @escaping () -> Void
    ) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            tick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        stop()
    }
}

final class StatusLinksScrollAnchorController {
    private let dashboardProvider: () -> NSWindow?
    private let contentHostProvider: () -> NSView?
    private let sectionTitleProvider: () -> String
    private let linksCountProvider: () -> Int
    private let maintenanceTimer = StatusLinksScrollAnchorTimer()
    private var maintenanceGeneration = 0

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
        maintenanceTimer.isRunning
    }

    func stop() {
        maintenanceGeneration &+= 1
        maintenanceTimer.stop()
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
        if let scrollPosition, operation != "add" {
            startMaintenance(scrollPosition, operation: operation)
        } else {
            stop()
        }
        editor.updateLinks(
            links,
            animated: true,
            revealAddedRowsAtCompletion: operation == "add"
        ) { [weak self, weak page, weak editor] in
            guard let self, let page, let editor else { return }
            self.stop()
            page.layoutSubtreeIfNeeded()
            editor.superview?.layoutSubtreeIfNeeded()
            self.clampDashboardScrollViewBounds()
            SwitchLog.write(
                "in-place status-link refresh animation completed; action=\(operation); rows=\(editor.rowCount); editor_frame=\(DashboardLogging.rect(editor.frame)); page_frame=\(DashboardLogging.rect(page.frame))",
                category: "ui.layout"
            )
            editor.logGeometry(label: "after \(operation) animation")
            if let scrollPosition, operation != "add" {
                self.restore(scrollPosition, attempt: 0)
            } else {
                SwitchLog.write(
                    "in-place status-link refresh preserves viewport offset; action=\(operation)",
                    category: "ui.scroll"
                )
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
        if let scrollPosition, operation != "add" {
            maintain(scrollPosition)
        }
        // Capture one state during the transition so the log distinguishes a
        // smooth layout animation from a late, discrete jump.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.logScrollState(label: "during \(operation) animation")
        }
        return true
    }

    func clampDashboardScrollViewBounds() {
        guard let page = currentPage,
              let scrollView = firstScrollView(in: page),
              let documentView = scrollView.documentView else {
            return
        }
        page.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        setDashboardScrollBounds(
            scrollView.contentView.bounds,
            scrollView: scrollView,
            documentView: documentView
        )
    }

    func startMaintenance(
        _ position: StatusLinksScrollPosition,
        operation: String
    ) {
        stop()
        let generation = maintenanceGeneration
        SwitchLog.write(
            "scroll anchor maintenance started; action=\(operation); interval=0.0167s; distanceFromBottom=\(DashboardLogging.number(position.distanceFromBottom))",
            category: "ui.scroll"
        )
        maintenanceTimer.start { [weak self] in
            guard let self, self.maintenanceGeneration == generation else { return }
            self.maintain(position)
        }
        // Apply once immediately so the first layout pass does not wait for
        // the first timer tick before the viewport begins following the card.
        maintain(position)
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

    private func maintain(_ position: StatusLinksScrollPosition) {
        guard let page = currentPage,
              let scrollView = firstScrollView(in: page),
              let documentView = scrollView.documentView else {
            return
        }

        dashboardProvider()?.displayIfNeeded()
        contentHostProvider()?.layoutSubtreeIfNeeded()
        page.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let contentView = scrollView.contentView
        // A removal shrinks the document from the bottom. Restore the clip
        // view through the shared visual-offset clamp so the new document
        // range, rather than the old coordinate origin, decides the result.
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
            var bounds = contentView.bounds
            guard abs(bounds.origin.y - targetContentOriginY) > 0.01 else { return }
            bounds.origin.y = targetContentOriginY
            setDashboardScrollBounds(
                bounds,
                scrollView: scrollView,
                documentView: documentView
            )
            return
        }

        if let anchorView = position.bottomAnchorView?.view,
           let targetViewportY = position.bottomAnchorViewportY,
           anchorView === page || anchorView.isDescendant(of: page) {
            let currentViewportY = anchorView.convert(
                statusLinksBottomAnchorPoint(in: anchorView),
                to: contentView
            ).y
            let correction = currentViewportY - targetViewportY
            guard abs(correction) > 0.01 else { return }
            var bounds = contentView.bounds
            // Changing the clip-view bounds origin translates the document in
            // the viewport. Correct by the exact amount the red card edge
            // moved, so the edge stays visually fixed throughout the height
            // animation instead of letting the blue top edge win by default.
            bounds.origin.y += correction
            setDashboardScrollBounds(
                bounds,
                scrollView: scrollView,
                documentView: documentView
            )
            return
        }

        var bounds = contentView.bounds
        let targetContentOriginY = dashboardScrollContentOrigin(
            scrollView: scrollView,
            documentView: documentView,
            visualOffset: position.visibleDocumentOffset
        )
        guard abs(bounds.origin.y - targetContentOriginY) > 0.01 else { return }
        bounds.origin.y = targetContentOriginY
        setDashboardScrollBounds(
            bounds,
            scrollView: scrollView,
            documentView: documentView
        )
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
            if attempt < 2 {
                restore(position, attempt: attempt + 1)
            }
            return
        }

        if let anchorView = position.bottomAnchorView?.view,
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
            if attempt < 2 {
                restore(position, attempt: attempt + 1)
            }
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

        // A second pass handles the case where Auto Layout updates the
        // document frame immediately after the first bounds assignment.
        if attempt < 2 {
            restore(position, attempt: attempt + 1)
        }
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
        contentView.bounds = dashboardClampedContentBounds(
            proposedBounds: proposedBounds,
            contentView: contentView,
            documentView: documentView
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
