import AppKit

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
    documentView: NSView
) -> NSRect {
    guard proposedBounds.height.isFinite else { return proposedBounds }

    let geometry = DashboardScrollGeometry(
        documentBounds: documentView.bounds,
        viewportHeight: proposedBounds.height,
        isDocumentFlipped: documentView.isFlipped
    )
    let visibleDocumentRect = contentView.convert(proposedBounds, to: documentView)
    let proposedVisualOffset = geometry.visualOffset(for: visibleDocumentRect)
    let clampedVisualOffset = geometry.clampedVisualOffset(proposedVisualOffset)

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
    private var isApplyingRigidBounds = false
    private var isApplyingProgrammaticBounds = false

    var onUserBoundsMovement: (() -> Void)?

    func applyProgrammaticBoundsOrigin(_ origin: NSPoint) {
        isApplyingProgrammaticBounds = true
        defer { isApplyingProgrammaticBounds = false }
        super.setBoundsOrigin(origin)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard !isApplyingRigidBounds else {
            return super.constrainBoundsRect(proposedBounds)
        }
        return rigidBounds(for: proposedBounds)
    }

    override func scroll(to newOrigin: NSPoint) {
        notifyUserBoundsMovementIfNeeded(newOrigin)
        guard !isApplyingRigidBounds else {
            super.scroll(to: newOrigin)
            return
        }

        var proposedBounds = bounds
        proposedBounds.origin = newOrigin
        let constrainedBounds = rigidBounds(for: proposedBounds)
        guard needsBoundsOriginUpdate(constrainedBounds.origin) else { return }
        isApplyingRigidBounds = true
        defer { isApplyingRigidBounds = false }
        super.scroll(to: constrainedBounds.origin)
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        guard !isApplyingRigidBounds else {
            super.setBoundsOrigin(newOrigin)
            return
        }

        var proposedBounds = bounds
        proposedBounds.origin = newOrigin
        let constrainedBounds = rigidBounds(for: proposedBounds)
        guard needsBoundsOriginUpdate(constrainedBounds.origin) else { return }
        isApplyingRigidBounds = true
        defer { isApplyingRigidBounds = false }
        super.setBoundsOrigin(constrainedBounds.origin)
    }

    private func rigidBounds(for proposedBounds: NSRect) -> NSRect {
        let constrainedBounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrainedBounds }
        return dashboardClampedContentBounds(
            proposedBounds: constrainedBounds,
            contentView: self,
            documentView: documentView
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
}
