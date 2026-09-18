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

/// Page-scroll chrome for the running OS.
///
/// macOS 26+ lets the scroll view overlap the transparent titlebar so AppKit
/// can write content insets and choose the system scroll-edge automatically.
/// Soft and Hard are both valid system results; this policy never forces
/// `NSScrollEdgeEffectStyle`. The public style API
/// (`preferredScrollEdgeEffectStyle`) is accessory-only (macOS 26.1+) and is
/// not installed here: production pages report no accessory. The window-level
/// `titlebarSeparatorStyle` must stay `.automatic` on 26+ because a forced
/// `.none` overrides `NSSplitViewItem.titlebarSeparatorStyle`. Content-pane
/// separators then use the existing `NSTrackingSeparatorToolbarItem`.
/// macOS 14/15 keep the pre-Tahoe 52pt non-scrolling clearance and `.none`
/// separators: `.fullSizeContentView` plus a transparent titlebar does not
/// reliably produce that inset, and this app still supports 14+.
struct DashboardPageScrollLayoutPolicy: Equatable {
    /// Non-scrolling gap above the page `NSScrollView`.
    let viewportTopInset: CGFloat
    let automaticallyAdjustsContentInsets: Bool
    /// When true, force zero `contentInsets` / `scrollerInsets` so AppKit
    /// cannot leave a stale titlebar inset on the old layout.
    let zerosManualInsets: Bool
    /// Window chrome. `.none` overrides every split-item preference.
    let windowTitlebarSeparatorStyle: NSTitlebarSeparatorStyle
    /// Sidebar pane only; `.none` keeps the separator off the source list.
    let sidebarTitlebarSeparatorStyle: NSTitlebarSeparatorStyle
    /// Content pane; `.automatic` is the public scroll-aware titlebar edge.
    let contentTitlebarSeparatorStyle: NSTitlebarSeparatorStyle

    /// Pre-#401 clearance that kept the first row out of the titlebar.
    static let preTahoeTitlebarClearanceInset: CGFloat = 52

    static let systemScrollEdge = DashboardPageScrollLayoutPolicy(
        viewportTopInset: 0,
        automaticallyAdjustsContentInsets: true,
        zerosManualInsets: false,
        windowTitlebarSeparatorStyle: .automatic,
        sidebarTitlebarSeparatorStyle: .none,
        contentTitlebarSeparatorStyle: .automatic
    )

    static let titlebarClearance = DashboardPageScrollLayoutPolicy(
        viewportTopInset: preTahoeTitlebarClearanceInset,
        automaticallyAdjustsContentInsets: false,
        zerosManualInsets: true,
        windowTitlebarSeparatorStyle: .none,
        sidebarTitlebarSeparatorStyle: .none,
        contentTitlebarSeparatorStyle: .none
    )

    static var current: DashboardPageScrollLayoutPolicy {
        forOperatingSystemVersion(ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func forOperatingSystemVersion(
        _ version: OperatingSystemVersion
    ) -> DashboardPageScrollLayoutPolicy {
        version.majorVersion >= 26 ? systemScrollEdge : titlebarClearance
    }

    func apply(to scrollView: NSScrollView) {
        scrollView.automaticallyAdjustsContentInsets = automaticallyAdjustsContentInsets
        guard zerosManualInsets else { return }
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    func applyTitlebarSeparators(
        to window: NSWindow,
        sidebarItem: NSSplitViewItem?,
        contentItem: NSSplitViewItem?
    ) {
        window.titlebarSeparatorStyle = windowTitlebarSeparatorStyle
        sidebarItem?.titlebarSeparatorStyle = sidebarTitlebarSeparatorStyle
        contentItem?.titlebarSeparatorStyle = contentTitlebarSeparatorStyle
    }
}

/// Describes the vertical geometry of a document inside a clip view.
///
/// `visualOffset` is measured from the document's rest position. For a
/// flipped document whose scroll view overlaps the titlebar, AppKit's rest
/// origin is `-contentInsets.top`; treating that as offset 0 keeps restore
/// and `isAtTop` aligned with the system scroll-edge inset.
struct DashboardScrollGeometry {
    let documentBounds: NSRect
    let viewportHeight: CGFloat
    let isDocumentFlipped: Bool
    let topContentInset: CGFloat

    init(
        documentBounds: NSRect,
        viewportHeight: CGFloat,
        isDocumentFlipped: Bool,
        topContentInset: CGFloat = 0
    ) {
        self.documentBounds = documentBounds
        self.viewportHeight = viewportHeight.isFinite ? max(0, viewportHeight) : 0
        self.isDocumentFlipped = isDocumentFlipped
        self.topContentInset = topContentInset.isFinite ? max(0, topContentInset) : 0
    }

    init(scrollView: NSScrollView) {
        let document = scrollView.documentView
        self.init(
            documentBounds: document?.bounds ?? .zero,
            viewportHeight: scrollView.contentView.bounds.height,
            isDocumentFlipped: document?.isFlipped ?? true,
            topContentInset: scrollView.contentInsets.top
        )
    }

    var restOriginY: CGFloat {
        isDocumentFlipped ? documentBounds.minY - topContentInset : documentBounds.minY
    }

    var maximumOffset: CGFloat {
        let inset = isDocumentFlipped ? topContentInset : 0
        return max(0, documentBounds.height + inset - viewportHeight)
    }

    func clampedVisualOffset(_ proposedOffset: CGFloat) -> CGFloat {
        DashboardScrollClampingPolicy.clampedVisualOffset(
            proposedOffset,
            maximumOffset: maximumOffset
        )
    }

    func visualOffset(for visibleDocumentRect: NSRect) -> CGFloat {
        if isDocumentFlipped {
            return visibleDocumentRect.minY - restOriginY
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
            originY = restOriginY + offset
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

    static func visualOffsetY(of scrollView: NSScrollView) -> CGFloat {
        guard let document = scrollView.documentView else { return 0 }
        let visible = scrollView.contentView.convert(
            scrollView.contentView.bounds,
            to: document
        )
        return DashboardScrollGeometry(scrollView: scrollView).visualOffset(for: visible)
    }

    static func visualOffsetY(in root: NSView) -> CGFloat {
        guard let scrollView = firstScrollView(in: root) else { return 0 }
        return visualOffsetY(of: scrollView)
    }

    static func restore(visualOffsetY: CGFloat, in scrollView: NSScrollView) {
        guard let document = scrollView.documentView else { return }
        let contentView = scrollView.contentView
        let geometry = DashboardScrollGeometry(scrollView: scrollView)
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

    static func restore(visualOffsetY: CGFloat, in root: NSView) {
        guard let scrollView = firstScrollView(in: root) else { return }
        restore(visualOffsetY: visualOffsetY, in: scrollView)
    }
}

/// Kept as a named type for composition/test seams. It intentionally has no
/// scrolling overrides: ordinary settings pages use AppKit's native
/// NSClipView momentum, deceleration, and legal-bounds behavior.
final class DashboardClipView: NSClipView {}
