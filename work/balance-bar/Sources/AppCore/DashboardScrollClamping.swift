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
    static let boundsOriginTolerance: CGFloat = 0.001

    static func clampedVisualOffset(
        _ proposedOffset: CGFloat,
        maximumOffset: CGFloat
    ) -> CGFloat {
        guard proposedOffset.isFinite else { return 0 }
        let maximumOffset = max(0, maximumOffset)
        guard maximumOffset > 0 else { return 0 }
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

enum DashboardPageScrollPosition {
    static func firstScrollView(in root: NSView) -> NSScrollView? {
        if let scrollView = root as? NSScrollView {
            return scrollView
        }
        for child in root.subviews {
            if let scrollView = firstScrollView(in: child) {
                return scrollView
            }
        }
        return nil
    }

    static func visualOffsetY(in root: NSView) -> CGFloat {
        guard let scrollView = firstScrollView(in: root),
              let document = scrollView.documentView
        else { return 0 }
        let visible = scrollView.contentView.convert(
            scrollView.contentView.bounds,
            to: document
        )
        return DashboardScrollGeometry(
            documentBounds: document.bounds,
            viewportHeight: scrollView.contentView.bounds.height,
            isDocumentFlipped: document.isFlipped
        ).visualOffset(for: visible)
    }

    static func restore(visualOffsetY: CGFloat, in root: NSView) {
        guard let scrollView = firstScrollView(in: root),
              let document = scrollView.documentView
        else { return }
        let contentView = scrollView.contentView
        let geometry = DashboardScrollGeometry(
            documentBounds: document.bounds,
            viewportHeight: contentView.bounds.height,
            isDocumentFlipped: document.isFlipped
        )
        let targetRect = geometry.visibleDocumentRect(forVisualOffset: visualOffsetY)
        let targetDocumentY = geometry.contentOriginDocumentY(
            for: targetRect,
            contentViewIsFlipped: contentView.isFlipped
        )
        let targetContentY = document.convert(
            NSPoint(x: document.bounds.minX, y: targetDocumentY),
            to: contentView
        ).y
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: targetContentY))
        scrollView.reflectScrolledClipView(contentView)
    }
}

/// Kept as a named type for composition/test seams. It intentionally has no
/// scrolling overrides: ordinary settings pages use AppKit's native
/// NSClipView momentum, deceleration, and legal-bounds behavior.
final class DashboardClipView: NSClipView {}
