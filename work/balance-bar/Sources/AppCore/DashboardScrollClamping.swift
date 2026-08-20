import AppKit

struct DashboardScrollTraceEvent: Equatable {
    let sequence: Int
    let kind: String
    let source: String
    let proposedOriginY: CGFloat?
    let resultOriginY: CGFloat?
    let visualOffset: CGFloat?
    let legalMaximum: CGFloat?
    let documentHeight: CGFloat?
    let viewportHeight: CGFloat?
    let flags: String
}

enum DashboardScrollTrace {
    static let capacity = 256
    private static let persistencePreferenceKey = "debugDashboardScrollTrace"

    private static var sequence = 0
    private static var events: [DashboardScrollTraceEvent] = []

    static func reset() {
        sequence = 0
        events.removeAll(keepingCapacity: true)
    }

    static func snapshot() -> [DashboardScrollTraceEvent] {
        events
    }

    static func record(
        kind: String,
        source: String,
        proposedOriginY: CGFloat? = nil,
        resultOriginY: CGFloat? = nil,
        visualOffset: CGFloat? = nil,
        legalMaximum: CGFloat? = nil,
        documentHeight: CGFloat? = nil,
        viewportHeight: CGFloat? = nil,
        flags: String = ""
    ) {
        sequence += 1
        let event = DashboardScrollTraceEvent(
            sequence: sequence,
            kind: kind,
            source: source,
            proposedOriginY: proposedOriginY,
            resultOriginY: resultOriginY,
            visualOffset: visualOffset,
            legalMaximum: legalMaximum,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight,
            flags: flags
        )
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }

        // The persisted diagnostic is opt-in so tracing cannot add a disk
        // write per scroll frame. The in-memory ring is always bounded and
        // keeps the exact order available to production-style replay tests.
        guard UserDefaults.standard.bool(forKey: persistencePreferenceKey) else {
            return
        }
        SwitchLog.write(
            "dashboard-scroll-trace; seq=\(sequence); kind=\(kind); source=\(source); proposed_y=\(format(proposedOriginY)); result_y=\(format(resultOriginY)); visual=\(format(visualOffset)); max=\(format(legalMaximum)); document_h=\(format(documentHeight)); viewport_h=\(format(viewportHeight)); flags=\(flags)",
            category: "ui.scroll.trace"
        )
    }

    static func marker(
        _ kind: String,
        source: String,
        flags: String = ""
    ) {
        record(kind: kind, source: source, flags: flags)
    }

    private static func format(_ value: CGFloat?) -> String {
        value.map(DashboardLogging.number) ?? "na"
    }
}

enum DashboardScrollClampingPolicy {
    // AppKit can produce fractional origins on adjacent frames while a clip
    // view is settling at an edge. Treat that small interval as one edge so
    // the clamp cannot alternate between the edge and a near-edge origin.
    static let edgeTolerance: CGFloat = 0.5
    static let boundsOriginTolerance: CGFloat = 0.001

    static func clampedVisualOffset(
        _ proposedOffset: CGFloat,
        maximumOffset: CGFloat
    ) -> CGFloat {
        guard proposedOffset.isFinite else { return 0 }
        let maximumOffset = max(0, maximumOffset)
        guard maximumOffset > 0 else { return 0 }
        if proposedOffset <= edgeTolerance { return 0 }
        if proposedOffset >= maximumOffset - edgeTolerance {
            return maximumOffset
        }
        return min(max(0, proposedOffset), maximumOffset)
    }
}

/// Describes the vertical geometry of a document inside a clip view.
///
/// `visualOffset` is measured from the document's visual top edge. Keeping
/// that value independent from AppKit's coordinate direction lets the same
/// clamp work for flipped and unflipped document views.
struct DashboardScrollGeometry {
    let documentBounds: NSRect
    let viewportHeight: CGFloat
    let isDocumentFlipped: Bool

    init(
        documentBounds: NSRect,
        viewportHeight: CGFloat,
        isDocumentFlipped: Bool
    ) {
        self.documentBounds = documentBounds
        self.viewportHeight = viewportHeight.isFinite ? max(0, viewportHeight) : 0
        self.isDocumentFlipped = isDocumentFlipped
    }

    var maximumOffset: CGFloat {
        max(0, documentBounds.height - viewportHeight)
    }

    func clampedVisualOffset(_ proposedOffset: CGFloat) -> CGFloat {
        DashboardScrollClampingPolicy.clampedVisualOffset(
            proposedOffset,
            maximumOffset: maximumOffset
        )
    }

    func visualOffset(for visibleDocumentRect: NSRect) -> CGFloat {
        if isDocumentFlipped {
            return visibleDocumentRect.minY - documentBounds.minY
        }
        return documentBounds.maxY - visibleDocumentRect.maxY
    }

    func clampedVisualOffset(for visibleDocumentRect: NSRect) -> CGFloat {
        clampedVisualOffset(visualOffset(for: visibleDocumentRect))
    }

    /// Returns the document rect that should occupy the viewport at the
    /// requested visual offset. For an unflipped document, the rect's origin
    /// is its visual bottom edge; for a flipped document, it is its visual
    /// top edge. That distinction is intentional and is kept here instead of
    /// leaking into each scroll-maintenance call site.
    func visibleDocumentRect(forVisualOffset proposedOffset: CGFloat) -> NSRect {
        let offset = clampedVisualOffset(proposedOffset)
        let originY: CGFloat
        if isDocumentFlipped {
            originY = documentBounds.minY + offset
        } else {
            originY = documentBounds.minY + maximumOffset - offset
        }
        return NSRect(
            x: documentBounds.minX,
            y: originY,
            width: documentBounds.width,
            height: viewportHeight
        )
    }

    func contentOriginDocumentY(
        for visibleDocumentRect: NSRect,
        contentViewIsFlipped: Bool
    ) -> CGFloat {
        if contentViewIsFlipped {
            return isDocumentFlipped
                ? visibleDocumentRect.minY
                : visibleDocumentRect.maxY
        }
        return isDocumentFlipped
            ? visibleDocumentRect.maxY
            : visibleDocumentRect.minY
    }
}

/// Converts the legal document range back to an NSClipView bounds rect.
///
/// The conversion is deliberately supplied by AppKit rather than recreated
/// from frame origins. This keeps the clamp correct when the document or clip
/// view has a non-zero bounds origin, a different flipped state, or a future
/// layout transform.
func dashboardClampedContentBounds(
    proposedBounds: NSRect,
    contentView: NSClipView,
    documentView: NSView,
    forcedVisualOffset: CGFloat? = nil
) -> NSRect {
    guard proposedBounds.height.isFinite else { return proposedBounds }

    let geometry = DashboardScrollGeometry(
        documentBounds: documentView.bounds,
        viewportHeight: proposedBounds.height,
        isDocumentFlipped: documentView.isFlipped
    )
    let visibleDocumentRect = contentView.convert(proposedBounds, to: documentView)
    let proposedVisualOffset = geometry.visualOffset(for: visibleDocumentRect)
    let clampedVisualOffset = forcedVisualOffset.map {
        geometry.clampedVisualOffset($0)
    } ?? geometry.clampedVisualOffset(proposedVisualOffset)

    // Keep AppKit's legal, non-edge proposal in its original coordinate
    // system. Only edge-equivalent or out-of-range proposals need a
    // conversion back to a rigid edge origin.
    if proposedVisualOffset.isFinite,
       proposedVisualOffset == clampedVisualOffset {
        return proposedBounds
    }

    let legalDocumentRect = geometry.visibleDocumentRect(
        forVisualOffset: clampedVisualOffset
    )
    let legalDocumentY = geometry.contentOriginDocumentY(
        for: legalDocumentRect,
        contentViewIsFlipped: contentView.isFlipped
    )
    let legalOriginY = documentView.convert(
        NSPoint(x: documentView.bounds.minX, y: legalDocumentY),
        to: contentView
    ).y
    guard legalOriginY.isFinite else { return proposedBounds }

    var clampedBounds = proposedBounds
    clampedBounds.origin.y = legalOriginY
    return clampedBounds
}

/// A settings-page clip view that applies the same legal range to AppKit's
/// own scrolling, resizing, and bounds-constraining paths.
final class DashboardClipView: NSClipView {
    private enum EdgeLatch: String {
        case top
        case bottom
    }

    private var isApplyingRigidBounds = false
    private var isApplyingProgrammaticBounds = false
    private var edgeLatch: EdgeLatch?
    private let edgeLatchReleaseDistance: CGFloat = 8

    var onUserBoundsMovement: (() -> Void)?
    var isAnchorMaintenanceActive = false

    func applyProgrammaticBoundsOrigin(_ origin: NSPoint) {
        trace(
            kind: "programmatic-write",
            source: "anchor",
            proposedBounds: bounds,
            resultOriginY: origin.y,
            flags: "suppressed-user-callback"
        )
        // Status Links maintenance is the authoritative writer during an
        // add/remove animation. It must be able to move a card-bottom anchor
        // even when the preceding user scroll reached an endpoint.
        edgeLatch = nil
        isApplyingProgrammaticBounds = true
        defer { isApplyingProgrammaticBounds = false }
        super.setBoundsOrigin(origin)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard !isApplyingRigidBounds else {
            return super.constrainBoundsRect(proposedBounds)
        }
        let constrainedBounds = rigidBounds(for: proposedBounds)
        trace(
            kind: "constrain-result",
            source: "appkit",
            proposedBounds: proposedBounds,
            resultOriginY: constrainedBounds.origin.y
        )
        return constrainedBounds
    }

    override func scroll(to newOrigin: NSPoint) {
        notifyUserBoundsMovementIfNeeded(newOrigin)
        var proposedBounds = bounds
        proposedBounds.origin = newOrigin
        writeRigidBounds(proposedBounds, source: "scroll(to:)")
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        notifyUserBoundsMovementIfNeeded(newOrigin)
        var proposedBounds = bounds
        proposedBounds.origin = newOrigin
        writeRigidBounds(proposedBounds, source: "setBoundsOrigin")
    }

    private func writeRigidBounds(
        _ proposedBounds: NSRect,
        source: String
    ) {
        guard !isApplyingRigidBounds else {
            super.setBoundsOrigin(proposedBounds.origin)
            return
        }

        let constrainedBounds = rigidBounds(for: proposedBounds)
        trace(
            kind: "edge-writer",
            source: source,
            proposedBounds: proposedBounds,
            resultOriginY: constrainedBounds.origin.y,
            flags: needsBoundsOriginUpdate(constrainedBounds.origin)
                ? "write"
                : "idempotent-no-write"
        )
        guard needsBoundsOriginUpdate(constrainedBounds.origin) else { return }
        isApplyingRigidBounds = true
        defer { isApplyingRigidBounds = false }
        // One writer is used for both AppKit entry paths. Calling the
        // superclass bounds primitive avoids a second scroll proposal from
        // re-entering the clamp during the same event.
        super.setBoundsOrigin(constrainedBounds.origin)
    }

    private func rigidBounds(for proposedBounds: NSRect) -> NSRect {
        let constrainedBounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrainedBounds }
        let geometry = DashboardScrollGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: constrainedBounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
        let visibleDocumentRect = convert(constrainedBounds, to: documentView)
        let proposedVisualOffset = geometry.visualOffset(for: visibleDocumentRect)
        if isAnchorMaintenanceActive {
            edgeLatch = nil
        } else {
            updateEdgeLatch(for: proposedVisualOffset, geometry: geometry)
        }
        let latchedVisualOffset = isAnchorMaintenanceActive
            ? nil
            : edgeLatch.flatMap { latch in
            guard geometry.maximumOffset > 0 else { return CGFloat(0) }
            switch latch {
            case .top:
                return proposedVisualOffset <= edgeLatchReleaseDistance
                    ? CGFloat(0)
                    : nil
            case .bottom:
                return proposedVisualOffset >= geometry.maximumOffset - edgeLatchReleaseDistance
                    ? geometry.maximumOffset
                    : nil
            }
        }
        if !isAnchorMaintenanceActive,
           latchedVisualOffset == nil,
           edgeLatch != nil,
           !isApplyingProgrammaticBounds {
            edgeLatch = nil
        }
        return dashboardClampedContentBounds(
            proposedBounds: constrainedBounds,
            contentView: self,
            documentView: documentView,
            forcedVisualOffset: latchedVisualOffset
        )
    }

    private func needsBoundsOriginUpdate(_ proposedOrigin: NSPoint) -> Bool {
        abs(bounds.origin.x - proposedOrigin.x) >
            DashboardScrollClampingPolicy.boundsOriginTolerance ||
            abs(bounds.origin.y - proposedOrigin.y) >
            DashboardScrollClampingPolicy.boundsOriginTolerance
    }

    private func notifyUserBoundsMovementIfNeeded(_ proposedOrigin: NSPoint) {
        guard !isApplyingRigidBounds,
              !isApplyingProgrammaticBounds,
              needsBoundsOriginUpdate(proposedOrigin) else {
            return
        }
        onUserBoundsMovement?()
    }

    private func updateEdgeLatch(
        for proposedVisualOffset: CGFloat,
        geometry: DashboardScrollGeometry
    ) {
        guard !isApplyingProgrammaticBounds,
              proposedVisualOffset.isFinite,
              geometry.maximumOffset > 0 else {
            return
        }
        let nextLatch: EdgeLatch?
        if proposedVisualOffset <= 0 {
            nextLatch = .top
        } else if proposedVisualOffset >= geometry.maximumOffset {
            nextLatch = .bottom
        } else {
            nextLatch = edgeLatch
        }
        guard nextLatch != edgeLatch else { return }
        edgeLatch = nextLatch
        DashboardScrollTrace.record(
            kind: "edge-latch",
            source: "appkit",
            visualOffset: proposedVisualOffset,
            legalMaximum: geometry.maximumOffset,
            documentHeight: geometry.documentBounds.height,
            viewportHeight: geometry.viewportHeight,
            flags: "edge=\(nextLatch?.rawValue ?? "released"); release_distance=\(DashboardLogging.number(edgeLatchReleaseDistance))"
        )
    }

    private func trace(
        kind: String,
        source: String,
        proposedBounds: NSRect,
        resultOriginY: CGFloat,
        flags: String = ""
    ) {
        guard let documentView else {
            DashboardScrollTrace.record(
                kind: kind,
                source: source,
                proposedOriginY: proposedBounds.origin.y,
                resultOriginY: resultOriginY,
                flags: flags
            )
            return
        }
        let geometry = DashboardScrollGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: proposedBounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
        let proposedVisibleRect = convert(proposedBounds, to: documentView)
        let resultBounds = NSRect(
            origin: NSPoint(x: proposedBounds.origin.x, y: resultOriginY),
            size: proposedBounds.size
        )
        let resultVisibleRect = convert(resultBounds, to: documentView)
        DashboardScrollTrace.record(
            kind: kind,
            source: source,
            proposedOriginY: proposedBounds.origin.y,
            resultOriginY: resultOriginY,
            visualOffset: geometry.visualOffset(for: resultVisibleRect),
            legalMaximum: geometry.maximumOffset,
            documentHeight: documentView.bounds.height,
            viewportHeight: proposedBounds.height,
            flags: "proposed_visual=\(DashboardLogging.number(geometry.visualOffset(for: proposedVisibleRect))); \(flags)"
        )
    }
}
