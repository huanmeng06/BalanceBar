import AppKit
import QuartzCore
import CoreImage

/// Process-local development controls for single-variable comparison runs.
/// Production ignores diagnostic overrides and uses B: animated show, immediate close.
enum PaceDismissalExperiment: String {
    case full
    case focusOff = "focus-off"
    case popoverCloseOff = "popover-close-off"

    static let current = resolve(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: ProcessInfo.processInfo.arguments)

    static func resolve(bundleIdentifier: String?, arguments: [String]) -> Self {
        guard MenuDismissalTrace.isEnabled(bundleIdentifier: bundleIdentifier),
              let index = arguments.firstIndex(of: "--pace-dismissal-experiment"),
              arguments.indices.contains(index + 1),
              let mode = Self(rawValue: arguments[index + 1]) else { return .popoverCloseOff }
        return mode
    }
}

/// Event-boundary diagnostics only: capture time/state on the main thread,
/// then let the existing log writer persist asynchronously. No animation polling.
@MainActor
final class MenuDismissalTrace {
    static var sinkForTesting: ((String) -> Void)?
    private static var nextRound = 0
    let round: Int
    private var sequence = 0
    private let start = DispatchTime.now().uptimeNanoseconds
    private weak var menu: NSMenu?
    weak var host: MenuHoverLinkHostView?

    nonisolated static func isEnabled(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.huanmeng06.BalanceBar.dev"
            || bundleIdentifier?.hasPrefix("com.huanmeng06.BalanceBar.dev.") == true
    }

    static func beginRound(menu: NSMenu? = nil) -> MenuDismissalTrace? {
        guard isEnabled(bundleIdentifier: Bundle.main.bundleIdentifier) || sinkForTesting != nil else { return nil }
        return MenuDismissalTrace(menu: menu)
    }

    private init(menu: NSMenu?) {
        Self.nextRound += 1
        round = Self.nextRound
        self.menu = menu
    }

    static func id(_ object: AnyObject?) -> String {
        object.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    }

    nonisolated func record(_ event: String, view: NSView? = nil, popover: NSPopover? = nil, details: String = "") {
        // Legacy controller entry points are not annotated, but all menu
        // mutation is synchronous on the main actor. Do not enqueue capture.
        MainActor.assumeIsolated { capture(event, view: view, popover: popover, details: details) }
    }

    private func capture(_ event: String, view: NSView?, popover: NSPopover?, details: String) {
        sequence += 1
        let now = DispatchTime.now().uptimeNanoseconds
        let source = view ?? host
        let window = source?.window ?? host?.outgoingMenuWindow
        let sectionCount = host?.subviews.filter { $0 is OpenCodexOverviewSectionView }.count ?? 0
        let message = "event=\(event); experiment=\((host?.dismissalExperiment ?? .current).rawValue); round=\(round); seq=\(sequence); mono_ns=\(now); elapsed_ms=\(Double(now - start) / 1_000_000); wall_s=\(Date().timeIntervalSince1970); host_round=\(host?.dismissalTrace?.round ?? 0); view=\(Self.id(source)); host=\(Self.id(host)); window=\(Self.id(window)); attached_window=\(Self.id(source?.window)); popover=\(Self.id(popover)); tracking=\(host?.isPaceMenuTracking ?? false); content_visible=\(host?.isMenuContentVisible ?? false); dismissing=\(host?.isMenuDismissing ?? false); window_visible=\(window?.isVisible ?? false); occlusion=\(window?.occlusionState.rawValue ?? 0); items=\(menu?.numberOfItems ?? 0); sections=\(sectionCount); \(details)"
        if let sink = Self.sinkForTesting { sink(message) }
        else { SwitchLog.write(message, level: .debug, category: "ui.menu.dismissal") }
    }
}

final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum SectionFocusState { case normal, focused, receded }

enum PaceHoverTiming {
    static let tickToBlurDelay: TimeInterval = 0.12
    static let blurDuration: TimeInterval = 0.18
    static let tooltipDelay = tickToBlurDelay + blurDuration
    static let exitDebounce: TimeInterval = 0.08
    static let restoreDuration: TimeInterval = 0.2
}

/// One tracking-mode timeline owns focus and Popover requests for a card.
@MainActor
final class SectionFocusController {
    private(set) var sections: [OpenCodexOverviewSectionID: OpenCodexOverviewSectionView] = [:]
    private(set) var hoveredID: OpenCodexOverviewSectionID?
    private(set) var focusedID: OpenCodexOverviewSectionID?
    private weak var targetPace: QuotaProgressPaceView?
    private weak var presentedPace: QuotaProgressPaceView?
    private enum Phase { case focus, tooltip, exit }
    private var phase: Phase?
    private var timer: Timer?
    private var generation = 0
    private var isMenuDismissing = false
    var dismissalTrace: MenuDismissalTrace?
    var experiment = PaceDismissalExperiment.current
    var isActive = false
    var pendingTimerForTesting: Timer? { timer }
    /// Fires when this card gains or loses a focused section, so peer cards in
    /// the same menu can recede with it.
    var onFocusActiveChanged: ((Bool) -> Void)?

    func update(sections next: [OpenCodexOverviewSectionID: OpenCodexOverviewSectionView]) {
        guard !isMenuDismissing else { return }
        let previous = sections
        for (id, view) in previous where next[id] !== view { view.setFocusState(.normal, animated: false) }
        sections = next
        if let id = focusedID, next[id] == nil { reset(); return }
        if let id = hoveredID, next[id] == nil { reset(); return }
        for (id, view) in next where previous[id] !== view {
            view.setFocusState(state(for: id), animated: false)
        }
    }

    func hoverChanged(_ id: OpenCodexOverviewSectionID, isHovering: Bool, pace: QuotaProgressPaceView? = nil) {
        guard isActive, !isMenuDismissing, sections[id] != nil || pace != nil else { return }
        if isHovering {
            if hoveredID == id {
                // A matching replacement adopts the outstanding phase, not a new delay.
                if let pace, targetPace !== pace {
                    targetPace = pace
                    if phase == nil { schedule(.tooltip, after: PaceHoverTiming.tooltipDelay, target: id) }
                }
                return
            }
            hoveredID = id
            targetPace = pace
            cancelPending()
            if let pace, let previous = presentedPace, previous.isTooltipVisible {
                setFocus(id)
                if previous !== pace { pace.adoptVisibleTooltip(from: previous) }
                presentedPace = pace
            } else if focusedID != nil {
                setFocus(id)
                if pace != nil { schedule(.tooltip, after: PaceHoverTiming.tooltipDelay, target: id) }
            } else {
                schedule(.focus, after: PaceHoverTiming.tickToBlurDelay, target: id)
            }
        } else {
            guard hoveredID == id, pace == nil || targetPace === pace else { return }
            hoveredID = nil
            cancelPending()
            schedule(.exit, after: PaceHoverTiming.exitDebounce, target: nil)
        }
    }

    private func schedule(_ nextPhase: Phase, after delay: TimeInterval, target: OpenCodexOverviewSectionID?) {
        let token = generation
        let trace = dismissalTrace
        trace?.record("hover.timer.schedule", details: "phase=\(nextPhase); generation=\(token); delay=\(delay)")
        phase = nextPhase
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.generation == token, self.hoveredID == target else {
                    trace?.record("hover.timer.ignored", details: "phase=\(nextPhase); generation=\(token)")
                    return
                }
                trace?.record("hover.timer.fire", details: "phase=\(nextPhase); generation=\(token)")
                self.timer = nil
                self.phase = nil
                switch nextPhase {
                case .focus:
                    self.setFocus(target)
                    if self.targetPace != nil {
                        // Start this delay when focus actually starts. A late tracking-loop
                        // callback must not compress both phases into the same frame.
                        self.schedule(.tooltip, after: PaceHoverTiming.blurDuration, target: target)
                    }
                case .tooltip:
                    guard let pace = self.targetPace else { return }
                    pace.showTooltip()
                    if pace.isTooltipVisible { self.presentedPace = pace }
                case .exit:
                    self.setFocus(nil)
                    self.presentedPace?.dismissTooltip(animated: true)
                    self.presentedPace = nil
                    self.targetPace = nil
                }
            }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
        RunLoop.main.add(next, forMode: .eventTracking)
    }

    func hasPendingShow(for pace: QuotaProgressPaceView) -> Bool {
        targetPace === pace && (phase == .focus || phase == .tooltip)
    }
    func hasPendingClose(for pace: QuotaProgressPaceView) -> Bool {
        phase == .exit && (targetPace === pace || presentedPace === pace)
    }
    func firePendingShowForTesting(for pace: QuotaProgressPaceView) {
        guard targetPace === pace else { return }
        if phase == .focus { timer?.fire() }
        if phase == .tooltip { timer?.fire() }
    }
    func firePendingCloseForTesting(for pace: QuotaProgressPaceView) {
        if hasPendingClose(for: pace) { timer?.fire() }
    }
    func invalidateInteraction(for pace: QuotaProgressPaceView) {
        if targetPace === pace || presentedPace === pace { reset() }
    }
    private func cancelPending() { generation += 1; timer?.invalidate(); timer = nil; phase = nil }
    private func state(for id: OpenCodexOverviewSectionID) -> SectionFocusState {
        experiment == .focusOff || focusedID == nil ? .normal : (focusedID == id ? .focused : .receded)
    }
    private func setFocus(_ id: OpenCodexOverviewSectionID?) {
        guard focusedID != id else { return }
        let wasActive = focusedID != nil
        focusedID = id
        for (key, view) in sections { view.setFocusState(state(for: key), animated: true) }
        if wasActive != (id != nil) { onFocusActiveChanged?(id != nil) }
    }
    func refreshAccessibility() {
        guard !isMenuDismissing else { return }
        for (id, view) in sections { view.setFocusState(state(for: id), animated: false) }
        presentedPace?.refreshMarkerAccessibility()
    }
    func suspendForMenuDismissal() {
        guard !isMenuDismissing else { return }
        dismissalTrace?.record("focus.suspend")
        isActive = false
        isMenuDismissing = true
        cancelPending()
        hoveredID = nil
        focusedID = nil
        presentedPace?.dismissTooltip(animated: false)
        presentedPace = nil
        targetPace = nil
        sections.values.forEach { $0.suspendFocusTransition() }
    }
    func finishMenuDismissal() {
        isMenuDismissing = false
        reset()
    }
    func reset() {
        guard !isMenuDismissing else { return }
        dismissalTrace?.record("focus.reset")
        let wasActive = focusedID != nil
        cancelPending()
        hoveredID = nil
        focusedID = nil
        presentedPace?.dismissTooltip(animated: false)
        presentedPace = nil
        targetPace = nil
        sections.values.forEach { $0.restoreFocusAfterDismissal() }
        if wasActive { onFocusActiveChanged?(false) }
    }
    deinit { timer?.invalidate() }
}

/// Section controls always use local coordinates; the menu host owns placement
/// and event forwarding. Stable IDs also survive value-only refreshes.
class OpenCodexOverviewSectionView: NSView {
    let sectionID: OpenCodexOverviewSectionID
    private(set) var focusState: SectionFocusState = .normal
    private(set) var isFocusSuspended = false
    var dismissalTrace: MenuDismissalTrace?
    private var focusGeneration = 0
    private var ownFocusFilter: CIFilter?
    private var targetRadius: CGFloat = 0
    private var targetAlpha: CGFloat = 1
    private var ownsOpacityAnimation = false
    private var blurUnavailable = false
    var focusReduceMotionForTesting: Bool?
    var focusReduceTransparencyForTesting: Bool?
    var focusFilterFactoryForTesting: (() -> CIFilter?)?
    private(set) var focusTransitionCountForTesting = 0
    var focusRestoreCompletionForTesting: (() -> Void)?
    private static let blurName = "balancebarSectionFocusBlur"
    private static let radiusPath = "filters.balancebarSectionFocusBlur.inputRadius"

    private var hasOwnFocusFilter: Bool {
        ownFocusFilter != nil && contentFilters.contains { $0.name == Self.blurName }
    }

    func setFocusState(_ state: SectionFocusState, animated: Bool) {
        guard !isFocusSuspended else { return }
        let reduceMotion = focusReduceMotionForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let reduceTransparency = focusReduceTransparencyForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let receded = state == .receded
        let alpha: CGFloat = receded ? 0.5 : 1
        var radius: CGFloat = receded && !reduceTransparency ? 3 : 0
        focusState = state
        if blurUnavailable { radius = 0 }
        if radius > 0, !hasOwnFocusFilter {
            let filter: CIFilter?
            if let factory = focusFilterFactoryForTesting { filter = factory() }
            else { filter = CIFilter(name: "CIGaussianBlur") }
            if let filter, !contentFilters.contains(where: { $0.name == Self.blurName }) {
                wantsLayer = true
                filter.name = Self.blurName
                filter.setValue(0, forKey: kCIInputRadiusKey) // Configure before attaching.
                ownFocusFilter = filter
                contentFilters = contentFilters + [filter]
            } else { radius = 0; blurUnavailable = true } // Supported alpha-only fallback, never pretend blur passed.
        }
        guard !animated || targetRadius != radius || targetAlpha != alpha else { return }
        focusGeneration += 1
        focusTransitionCountForTesting += 1
        let token = focusGeneration
        let filter = ownFocusFilter
        let duration = receded ? PaceHoverTiming.blurDuration : PaceHoverTiming.restoreDuration
        let animate = animated && !reduceMotion
        let visibleAlpha = CGFloat(layer?.presentation()?.opacity ?? Float(alphaValue))
        if ownsOpacityAnimation { layer?.removeAnimation(forKey: "opacity"); ownsOpacityAnimation = false }
        if animate {
            // Start the AppKit opacity animator at the current visible alpha.
            alphaValue = visibleAlpha
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = alpha
            }
            ownsOpacityAnimation = true
        } else { alphaValue = alpha }
        var from = targetRadius
        if hasOwnFocusFilter, let node = layer {
            if let visible = node.presentation(), (visible.filters as? [CIFilter])?.contains(where: { $0.name == Self.blurName }) == true {
                from = (visible.value(forKeyPath: Self.radiusPath) as? NSNumber)?.doubleValue ?? targetRadius
            } else { from = (node.value(forKeyPath: Self.radiusPath) as? NSNumber)?.doubleValue ?? targetRadius }
            node.removeAnimation(forKey: "sectionFocus.radius")
        }
        targetAlpha = alpha
        targetRadius = radius
        defer { traceFocus("section.focus") }
        guard hasOwnFocusFilter, let node = layer else { return } // No invalid KVC on an absent filter.
        let cleanup: () -> Void = { [weak self, weak filter] in
            guard let self, !self.isFocusSuspended, self.focusGeneration == token, self.targetRadius == 0,
                  let filter, self.ownFocusFilter === filter else { return }
            self.contentFilters = self.contentFilters.filter { $0.name != Self.blurName }
            self.ownFocusFilter = nil
            self.traceFocus("filter.remove")
            self.focusRestoreCompletionForTesting = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        node.setValue(radius, forKeyPath: Self.radiusPath)
        if animate {
            let animation = CABasicAnimation(keyPath: Self.radiusPath)
            animation.fromValue = from
            animation.toValue = radius
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if radius == 0 {
                focusRestoreCompletionForTesting = cleanup
                CATransaction.setCompletionBlock(cleanup)
            }
            node.add(animation, forKey: "sectionFocus.radius")
        }
        CATransaction.commit()
        if !animate, radius == 0 { cleanup() }
    }

    /// Freeze the visible state while the native menu exits. Do not detach a
    /// content filter or brighten a still-visible outgoing menu.
    func suspendFocusTransition() {
        guard !isFocusSuspended else { return }
        isFocusSuspended = true
        defer { traceFocus("section.suspend") }
        focusGeneration += 1 // Retire any restoration completion before removing its animation.
        focusRestoreCompletionForTesting = nil
        let visibleAlpha = CGFloat(layer?.presentation()?.opacity ?? Float(alphaValue))
        if ownsOpacityAnimation {
            layer?.removeAnimation(forKey: "opacity")
            ownsOpacityAnimation = false
            alphaValue = visibleAlpha
            targetAlpha = visibleAlpha
        }
        guard hasOwnFocusFilter, let node = layer else { return }
        let visible = node.presentation()
        let source: CALayer
        if let visible, (visible.filters as? [CIFilter])?.contains(where: { $0.name == Self.blurName }) == true {
            source = visible
        } else { source = node }
        let radius = (source.value(forKeyPath: Self.radiusPath) as? NSNumber)?.doubleValue ?? targetRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        node.removeAnimation(forKey: "sectionFocus.radius")
        node.setValue(radius, forKeyPath: Self.radiusPath)
        CATransaction.commit()
        targetRadius = radius
    }

    func restoreFocusAfterDismissal() {
        isFocusSuspended = false
        setFocusState(.normal, animated: false)
    }

    private func traceFocus(_ event: String) {
        guard let dismissalTrace else { return }
        var radius = targetRadius
        if hasOwnFocusFilter, let layer {
            radius = (layer.value(forKeyPath: Self.radiusPath) as? NSNumber)?.doubleValue ?? targetRadius
        }
        var visibleRadius: Double?
        if let visible = layer?.presentation(), (visible.filters as? [CIFilter])?.contains(where: { $0.name == Self.blurName }) == true {
            visibleRadius = (visible.value(forKeyPath: Self.radiusPath) as? NSNumber)?.doubleValue
        }
        dismissalTrace.record(event, view: self,
            details: "section=\(sectionID.identifier); alpha=\(alphaValue); presentation_alpha=\(layer?.presentation()?.opacity ?? Float(alphaValue)); radius=\(radius); presentation_radius=\(visibleRadius.map { String($0) } ?? "na"); target_radius=\(targetRadius); suspended=\(isFocusSuspended); owned_filter=\(hasOwnFocusFilter); filters=\(contentFilters.count); opacity_animation=\(layer?.animation(forKey: "opacity") != nil); blur_animation=\(layer?.animation(forKey: "sectionFocus.radius") != nil); generation=\(focusGeneration)")
    }

    var measuredHeight: CGFloat { frame.height }
    override var intrinsicContentSize: NSSize { NSSize(width: frame.width, height: measuredHeight) }

    func updatePlacement(_ layout: OpenCodexOverviewSectionLayout) {
        precondition(layout.id == sectionID)
        frame = layout.frame
        invalidateIntrinsicContentSize()
    }

    init(layout: OpenCodexOverviewSectionLayout) {
        sectionID = layout.id
        super.init(frame: layout.frame)
        identifier = NSUserInterfaceItemIdentifier("codex.overview.section.\(layout.id.identifier)")
    }

    override func removeFromSuperview() {
        dismissalTrace?.record("section.remove", view: self, details: "section=\(sectionID.identifier)")
        (superview as? MenuHoverLinkHostView)?.focusSectionWillBeRemoved(self)
        if !isFocusSuspended { setFocusState(.normal, animated: false) }
        super.removeFromSuperview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class OpenCodexAccountSectionView: OpenCodexOverviewSectionView {}
/// Shared title/subtitle/amount/progress template for all metric sections.
class OpenCodexMetricSectionView: OpenCodexOverviewSectionView {
    private(set) var titleView: NSView?
    private(set) var subtitleView: NSView?
    private(set) var amountView: NSView?
    private(set) var progressView: NSView?

    func updateText(title: String, subtitle: String) {
        (titleView as? AccountMarqueeView)?.updateText(title, preserveScrollPosition: true)
        (subtitleView as? AccountMarqueeView)?.updateText(subtitle, preserveScrollPosition: true)
    }

    func installMetric(title: NSView, subtitle: NSView?, amount: NSView, progress: NSView? = nil) {
        titleView = title
        subtitleView = subtitle
        amountView = amount
        progressView = progress
        [progress, amount, title, subtitle].compactMap { $0 }.forEach(addSubview)
    }
}

final class OpenCodexBankedResetSectionView: OpenCodexMetricSectionView {}

/// Thin, non-interactive outline used to make overview section boundaries
/// visible while exercising the modular card layout.
final class OverviewSectionOutlineView: PassthroughView {
    static let cornerRadius: CGFloat = 7
    static let borderWidth: CGFloat = 0.75

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Self.borderWidth
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        layer?.masksToBounds = false
        identifier = NSUserInterfaceItemIdentifier("codex.overview.sectionOutline")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Ticket background that also drives the hover "lift". A menu window clips
/// everything at its edges, so the lifted card is shown in a click-through
/// overlay window above the menu: the card is snapshotted, the originals are
/// hidden, and the snapshot springs up, tilts toward the pointer and gains a
/// shadow and glare, free to break past the menu margins. Once it settles back
/// the overlay goes away and the original views reappear.
final class BankedResetChromeView: NSView {
    static let hoverScale: CGFloat = 1.22
    /// Pitch (pointer above/below center).
    static let maxPitchDegrees: CGFloat = 18
    /// Yaw (pointer left/right of center); the card is wide, so keep it lower.
    static let maxYawDegrees: CGFloat = 12
    static let perspectiveDistance: CGFloat = 600
    static let springStiffness: CGFloat = 320
    static let springDamping: CGFloat = 19
    /// Below this lift the snapshot cross-fades with the original views. The
    /// snapshot loses the menu's vibrant text rendering, so a hard swap would
    /// make the labels visibly change color as the card lands.
    static let handoffLift: CGFloat = 0.2

    private struct Spring {
        var value: CGFloat
        var velocity: CGFloat = 0
        var target: CGFloat

        init(_ value: CGFloat) {
            self.value = value
            target = value
        }

        var isSettled: Bool { abs(value - target) < 0.0005 && abs(velocity) < 0.001 }

        mutating func step(_ dt: CGFloat) {
            let force = BankedResetChromeView.springStiffness * (target - value)
                - BankedResetChromeView.springDamping * velocity
            velocity += force * dt
            value += velocity * dt
        }

        mutating func snap() {
            value = target
            velocity = 0
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private(set) var isHovering = false
    /// 0 at rest, 1 fully lifted (overshoots slightly while springing).
    private var lift = Spring(0)
    /// Normalized pointer offset from the center, -1...1, y up.
    private var tiltX = Spring(0)
    private var tiltY = Spring(0)
    /// Pointer position in bounds, normalized to 0...1, y up.
    private var glarePoint = NSPoint(x: 0.5, y: 0.5)
    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval?
    /// Draws the opaque lifted surface; only set while taking a snapshot.
    private var drawsLiftedSurface = false
    private var overlay: BankedResetLiftOverlayWindow?
    /// Original views hidden behind the overlay, with their alpha to restore.
    private var hiddenViews: [(view: NSView, alpha: CGFloat)] = []
    private var scrollObserver: NSObjectProtocol?

    var liftOverlayForTesting: BankedResetLiftOverlayWindow? { overlay }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    deinit {
        displayLink?.invalidate()
        overlay?.orderOut(nil)
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = OpenCodexCardLayout.bankedResetChromeCornerRadius
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        guard drawsLiftedSurface else {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            path.fill()
            return
        }
        // Opaque surface so the shadow stays outside instead of tinting the card.
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(white: isDark ? 0.25 : 0.985, alpha: 1).setFill()
        path.fill()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        super.updateTrackingAreas()
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isMenuDismissing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        isHovering = true
        setPointer(convert(event.locationInWindow, from: nil))
        startAnimating()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard isHovering, !isMenuDismissing else { return }
        setPointer(convert(event.locationInWindow, from: nil))
        startAnimating()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovering, !isMenuDismissing else { return }
        resetHover(animated: true)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { resetHover(animated: false) }
    }

    /// Test seam mirroring the tracking-area path with a point in the
    /// superview's coordinate space; jumps straight to the settled state.
    func setHoverForTesting(at superviewPoint: NSPoint?) {
        guard let superviewPoint, let superview else {
            resetHover(animated: false)
            return
        }
        isHovering = true
        setPointer(convert(superviewPoint, from: superview))
        lift.snap()
        tiltX.snap()
        tiltY.snap()
        render()
    }

    /// Drops the card back into the menu; the host calls this when the menu
    /// starts dismissing so the overlay never outlives the menu window.
    func resetHover(animated: Bool) {
        isHovering = false
        lift.target = 0
        tiltX.target = 0
        tiltY.target = 0
        if animated && overlay != nil {
            startAnimating()
        } else {
            stopAnimating()
            lift.snap()
            tiltX.snap()
            tiltY.snap()
            render()
        }
    }

    private var isMenuDismissing: Bool {
        var node = superview
        while let current = node {
            if let host = current as? MenuHoverLinkHostView { return host.isMenuDismissing }
            node = current.superview
        }
        return false
    }

    private func setPointer(_ local: NSPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        lift.target = 1
        tiltX.target = max(-1, min(1, (local.x - bounds.midX) / (bounds.width / 2)))
        tiltY.target = max(-1, min(1, (local.y - bounds.midY) / (bounds.height / 2)))
        glarePoint = NSPoint(
            x: max(0, min(1, local.x / bounds.width)),
            y: max(0, min(1, local.y / bounds.height))
        )
    }

    private func startAnimating() {
        guard displayLink == nil, window != nil else { return }
        lastFrameTimestamp = nil
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard !isMenuDismissing else {
            resetHover(animated: false)
            return
        }
        let dt = CGFloat(min(1.0 / 30, link.timestamp - (lastFrameTimestamp ?? link.timestamp - 1.0 / 120)))
        lastFrameTimestamp = link.timestamp
        // Sub-step for a stable spring regardless of refresh rate.
        let substeps = 4
        for _ in 0..<substeps {
            lift.step(dt / CGFloat(substeps))
            tiltX.step(dt / CGFloat(substeps))
            tiltY.step(dt / CGFloat(substeps))
        }
        if lift.isSettled && tiltX.isSettled && tiltY.isSettled {
            lift.snap()
            tiltX.snap()
            tiltY.snap()
            stopAnimating()
        }
        render()
    }

    private func render() {
        guard lift.value != 0 || lift.target != 0 else {
            tearDownOverlay()
            return
        }
        guard let overlay = overlay ?? makeOverlay() else { return }
        positionOverlay()

        // The side under the pointer presses away from the viewer (y up).
        let scale = 1 + (Self.hoverScale - 1) * lift.value
        var transform = CATransform3DIdentity
        transform.m34 = -1 / Self.perspectiveDistance
        transform = CATransform3DRotate(transform, -tiltY.value * Self.maxPitchDegrees * .pi / 180, 1, 0, 0)
        transform = CATransform3DRotate(transform, tiltX.value * Self.maxYawDegrees * .pi / 180, 0, 1, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        overlay.apply(
            transform: transform,
            progress: max(0, min(1, lift.value)),
            glarePoint: glarePoint,
            glareAlpha: isDark ? 0.14 : 0.35
        )
        let handoff = max(0, min(1, lift.value / Self.handoffLift))
        overlay.alphaValue = handoff
        hiddenViews.forEach { $0.view.alphaValue = $0.alpha * (1 - handoff) }
    }

    /// Snapshots the card in its resting and lifted looks, hides the originals
    /// and shows the overlay exactly on top of them.
    private func makeOverlay() -> BankedResetLiftOverlayWindow? {
        guard window != nil else { return nil }
        let views = cardViews()
        guard let resting = snapshot() else { return nil }
        drawsLiftedSurface = true
        let lifted = snapshot()
        drawsLiftedSurface = false
        guard let lifted else { return nil }

        let overlay = BankedResetLiftOverlayWindow()
        overlay.install(
            resting: resting,
            lifted: lifted,
            cardSize: bounds.size,
            cornerRadius: OpenCodexCardLayout.bankedResetChromeCornerRadius,
            contentsScale: window?.backingScaleFactor ?? 2
        )
        self.overlay = overlay
        positionOverlay()
        overlay.orderFrontRegardless()

        hiddenViews = views.map { ($0, $0.alphaValue) }
        views.forEach { $0.alphaValue = 0 }

        if let clipView = enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
            ) { [weak self] _ in
                self?.positionOverlay()
            }
        }
        return overlay
    }

    private func tearDownOverlay() {
        guard let overlay else { return }
        overlay.orderOut(nil)
        self.overlay = nil
        hiddenViews.forEach { $0.view.alphaValue = $0.alpha }
        hiddenViews.removeAll()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
    }

    private func positionOverlay() {
        guard let overlay, let window else { return }
        overlay.place(cardScreenFrame: window.convertToScreen(convert(bounds, to: nil)))
    }

    /// Draws the superview region under this card (the chrome plus the views
    /// on top of it) through AppKit, which works whether or not the views have
    /// their own layers.
    private func snapshot() -> CGImage? {
        guard let superview, let rep = superview.bitmapImageRepForCachingDisplay(in: frame) else { return nil }
        superview.cacheDisplay(in: frame, to: rep)
        return rep.cgImage
    }

    /// The chrome plus every sibling drawn on top of this card.
    private func cardViews() -> [NSView] {
        guard let superview else { return [self] }
        return [self] + superview.subviews.filter { sibling in
            sibling !== self
                && !(sibling is BankedResetChromeView)
                && frame.contains(NSPoint(x: sibling.frame.midX, y: sibling.frame.midY))
        }
    }
}

/// Click-through window above the menu that hosts a lifted ticket snapshot,
/// padded so the card can scale, tilt and cast a shadow past the menu edges.
final class BankedResetLiftOverlayWindow: NSPanel {
    static let padding: CGFloat = 110

    let cardLayer = CALayer()
    private let restingLayer = CALayer()
    private let liftedLayer = CALayer()
    private let glareLayer = CAGradientLayer()
    private var cardSize: CGSize = .zero

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let content = NSView()
        content.wantsLayer = true
        contentView = content
        content.layer?.addSublayer(cardLayer)
        [restingLayer, liftedLayer, glareLayer].forEach(cardLayer.addSublayer)
        glareLayer.type = .radial
        glareLayer.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        glareLayer.masksToBounds = true
        cardLayer.shadowColor = NSColor.black.cgColor
        cardLayer.shadowRadius = 18
        cardLayer.shadowOffset = CGSize(width: 0, height: -12)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var restingImageForTesting: CGImage? {
        restingLayer.contents.map { $0 as! CGImage }
    }

    func install(resting: CGImage, lifted: CGImage, cardSize: CGSize, cornerRadius: CGFloat, contentsScale: CGFloat) {
        self.cardSize = cardSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: cardSize)
        cardLayer.bounds = bounds
        cardLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        cardLayer.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
        )
        for (layer, image) in [(restingLayer, resting), (liftedLayer, lifted)] {
            layer.frame = bounds
            layer.contents = image
            layer.contentsScale = contentsScale
            layer.contentsGravity = .resize
        }
        glareLayer.frame = bounds
        glareLayer.cornerRadius = cornerRadius
        glareLayer.cornerCurve = .continuous
        CATransaction.commit()
    }

    func place(cardScreenFrame: NSRect) {
        let target = cardScreenFrame.insetBy(dx: -Self.padding, dy: -Self.padding)
        if frame != target { setFrame(target, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.position = CGPoint(x: target.width / 2, y: target.height / 2)
        CATransaction.commit()
    }

    func apply(transform: CATransform3D, progress: CGFloat, glarePoint: NSPoint, glareAlpha: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.transform = transform
        cardLayer.shadowOpacity = Float(0.3 * progress)
        liftedLayer.opacity = Float(progress)
        glareLayer.opacity = Float(glareAlpha * progress)
        let radius = cardSize.width * 0.45
        glareLayer.startPoint = glarePoint
        glareLayer.endPoint = CGPoint(
            x: glarePoint.x + radius / max(1, cardSize.width),
            y: glarePoint.y + radius / max(1, cardSize.height)
        )
        CATransaction.commit()
    }
}

/// Nested ticket list inside the official Codex quota menu card.
/// NSMenu swallows wheel events unless this view consumes them.
final class BankedResetTicketScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        backgroundColor = .clear
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .allowed
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets()
        scrollerInsets = NSEdgeInsets()
        usesPredominantAxisScrolling = true

        let clipView = BankedResetTicketClipView(frame: bounds)
        clipView.drawsBackground = false
        clipView.backgroundColor = .clear
        contentView = clipView
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func scrollToTopOfDocument() {
        layoutSubtreeIfNeeded()
        guard let documentView else { return }
        let topY = max(0, documentView.bounds.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: topY))
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        let currentY = contentView.bounds.origin.y
        contentView.scroll(to: NSPoint(x: 0, y: currentY))
        reflectScrolledClipView(contentView)
    }
}

final class BankedResetTicketClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin.x = 0
        return constrained
    }
}

final class BankedResetTicketDocumentView: NSView {}

final class MenuBarContentView: NSView {
    override var isFlipped: Bool { true }
}

/// Offscreen root for bitmap-backed status-item content. It must use the same
/// top-origin coordinate semantics as the live status button; otherwise the
/// shared menu-bar frames are interpreted upside down before rasterization.
final class MenuBarBitmapRenderView: NSView {
    var onEffectiveAppearanceChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChanged?()
    }
}

/// A BalanceBar-owned layer host for the native Codex animation.
///
/// The host is a transparent, non-hit-testing overlay. AppKit keeps the
/// complete static GPT+text bitmap on the status button so inactive-display
/// replicants stay visible. This view owns only the icon layer that Core
/// Animation rotates; it never fills an opaque background. The view never
/// schedules work for animation frames.
final class MenuBarNativeAnimatedIconHostView: NSView {
    static let rotationAnimationKey = "balancebar.nativeCodexRotation"
    static let rotationFrameCount = MenuBarAnimationTiming.frameCount
    static var rotationDuration: TimeInterval { MenuBarAnimationTiming.rotationDuration }

    var rotationDuration: TimeInterval = MenuBarAnimationTiming.rotationDuration {
        didSet {
            let normalized = max(rotationDuration, MenuBarAnimationTiming.frameInterval(fps: MenuBarAnimationTiming.maximumFrameRate))
            if abs(normalized - rotationDuration) > 0.000_001 {
                rotationDuration = normalized
                return
            }
            guard abs(oldValue - rotationDuration) > 0.000_001 else { return }
            guard hasRotationAnimation else { return }
            let phase = currentRotationPhaseForTesting ?? 0
            removeRotationAnimation()
            installRotationAnimation(phase: phase)
        }
    }

    /// CALayer's positive Z rotation advances clockwise in the menu-bar's
    /// screen presentation. Keeping the values in one helper makes the visual
    /// direction an explicit contract shared by the real item and Dashboard
    /// preview.
    static let clockwiseRotationValues: [NSNumber] = (0..<rotationFrameCount).map {
        NSNumber(value: 2 * Double.pi * Double($0) / Double(rotationFrameCount))
    }

    /// This is the only layer that receives the rotation animation.  It is a
    /// sublayer created and retained by BalanceBar, never the AppKit-managed
    /// status button or image view layer.
    let iconLayer = CALayer()

    private(set) var rotationAnimationInstallCount = 0
    private(set) var contentsRasterizationCount = 0
    private var configuredSourceImage: NSImage?
    private var configuredAppearanceKey: String?
    private var configuredHighlightState = false
    private var configuredContentsScale: CGFloat = 0
    private var configuredContentsSize: NSSize = .zero

    override var isFlipped: Bool { true }

    /// The host has no layout contribution.  Its frame is supplied from the
    /// already-resolved menu-bar icon draw rect at visual boundaries.
    override var intrinsicContentSize: NSSize { .zero }

    var hasRotationAnimation: Bool {
        iconLayer.animation(forKey: Self.rotationAnimationKey) != nil
    }

    var rotationAnimationForTesting: CAKeyframeAnimation? {
        iconLayer.animation(forKey: Self.rotationAnimationKey) as? CAKeyframeAnimation
    }

    var currentRotationPhaseForTesting: Double? {
        guard let animation = rotationAnimationForTesting,
              animation.duration > 0 else {
            return nil
        }
        let localNow = iconLayer.convertTime(CACurrentMediaTime(), from: nil)
        let elapsed = localNow - animation.beginTime
        let remainder = elapsed.truncatingRemainder(dividingBy: animation.duration)
        return (remainder < 0 ? remainder + animation.duration : remainder)
            / animation.duration
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHost()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureHost()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Updates the view and layer geometry once for a layout/backing-scale
    /// boundary.  All layer mutations are explicit and transaction-disabled,
    /// so changing the anchor point cannot create an implicit translation.
    func updateGeometry(frame: NSRect, contentsScale: CGFloat) {
        if self.frame != frame {
            self.frame = frame
        }
        updateLayerGeometry(contentsScale: contentsScale)
    }

    /// Renders the template image once for the current appearance and scale,
    /// then installs the resulting CGImage as layer contents.  Repeated calls
    /// with the same visual inputs are no-ops and never participate in the
    /// steady-state animation.
    @discardableResult
    func updateContents(
        sourceImage: NSImage,
        appearance: NSAppearance,
        contentsScale: CGFloat,
        highlighted: Bool = false
    ) -> Bool {
        let safeScale = contentsScale > 0 ? contentsScale : 2
        let appearanceKey = Self.appearanceKey(for: appearance)
        let size = bounds.size
        let needsRasterization = configuredSourceImage !== sourceImage
            || configuredAppearanceKey != appearanceKey
            || configuredHighlightState != highlighted
            || configuredContentsScale != safeScale
            || configuredContentsSize != size
            || iconLayer.contents == nil
        guard needsRasterization else { return true }

        guard let contents = Self.renderContents(
            sourceImage: sourceImage,
            size: size,
            appearance: appearance,
            scale: safeScale,
            highlighted: highlighted
        ) else {
            iconLayer.contents = nil
            configuredSourceImage = nil
            configuredAppearanceKey = nil
            configuredHighlightState = false
            configuredContentsScale = 0
            configuredContentsSize = .zero
            return false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = contents
        iconLayer.contentsScale = safeScale
        CATransaction.commit()
        configuredSourceImage = sourceImage
        configuredAppearanceKey = appearanceKey
        configuredHighlightState = highlighted
        configuredContentsScale = safeScale
        configuredContentsSize = size
        contentsRasterizationCount += 1
        return true
    }

    /// Installs the 36-state CA animation exactly once for the current
    /// duration. `phase` is normalized to one cycle and is used only when a
    /// host is recreated at a visual boundary or the FPS changes.
    func installRotationAnimation(phase: Double = 0) {
        guard !hasRotationAnimation else { return }
        let normalizedPhase = phase.truncatingRemainder(dividingBy: 1)
            .wrappedPositiveRemainder
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = Self.clockwiseRotationValues
        animation.keyTimes = (0..<Self.rotationFrameCount).map { index in
            NSNumber(value: Double(index) / Double(Self.rotationFrameCount))
        }
        animation.duration = rotationDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.beginTime = iconLayer.convertTime(CACurrentMediaTime(), from: nil)
            - normalizedPhase * rotationDuration
        animation.isRemovedOnCompletion = false
        iconLayer.add(animation, forKey: Self.rotationAnimationKey)
        rotationAnimationInstallCount += 1
    }

    func removeRotationAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.removeAnimation(forKey: Self.rotationAnimationKey)
        iconLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func configureHost() {
        isHidden = true
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0
        iconLayer.masksToBounds = false
        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)
        updateLayerGeometry(contentsScale: 2)
    }

    private func updateLayerGeometry(contentsScale: CGFloat) {
        let safeScale = contentsScale > 0 ? contentsScale : 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        iconLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        iconLayer.contentsScale = safeScale
        CATransaction.commit()
    }

    private static func appearanceKey(for appearance: NSAppearance) -> String {
        let bestMatch = appearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "none"
        return "\(appearance.name.rawValue)|\(bestMatch)"
    }

    private static func renderContents(
        sourceImage: NSImage,
        size: NSSize,
        appearance: NSAppearance,
        scale: CGFloat,
        highlighted: Bool
    ) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let pixelDimensions = MenuBarBitmapImageLayout.pixelDimensions(
            for: size,
            scale: scale
        )
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelDimensions.width,
            pixelsHigh: pixelDimensions.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = size
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.appearance = appearance
        imageView.image = sourceImage
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.contentTintColor = highlighted
            ? .selectedMenuItemTextColor
            : .labelColor
        imageView.wantsLayer = true
        imageView.layoutSubtreeIfNeeded()
        imageView.cacheDisplay(in: imageView.bounds, to: rep)
        return rep.cgImage
    }
}

/// A BalanceBar-owned clipped sprite host for discrete thinking animations.
/// Claude keeps its nine-frame 810 ms strip; Grok uses the 30-frame SVG
/// pack. Claude still puts a text-only bitmap on the status button. Grok
/// Performance keeps the complete static icon+text bitmap for replicants.
final class MenuBarClaudeAnimatedIconHostView: NSView {
    static let thinkingAnimationKey = MenuBarSpriteAnimationTiming.claude.animationKey
    static let thinkingFrameCount = ClaudeThinkingAnimationTiming.frameCount
    static let thinkingFrameDuration = ClaudeThinkingAnimationTiming.frameDuration
    static let thinkingDuration = ClaudeThinkingAnimationTiming.duration

    var timing: MenuBarSpriteAnimationTiming = .claude {
        didSet {
            guard oldValue != timing else { return }
            let wasAnimating = spriteLayer.animation(forKey: oldValue.animationKey) != nil
            let phase: Double
            if wasAnimating, oldValue.duration > 0 {
                let localNow = spriteLayer.convertTime(CACurrentMediaTime(), from: nil)
                if let animation = spriteLayer.animation(forKey: oldValue.animationKey)
                    as? CAKeyframeAnimation,
                   animation.duration > 0 {
                    let elapsed = localNow - animation.beginTime
                    let remainder = elapsed.truncatingRemainder(dividingBy: animation.duration)
                    phase = (remainder < 0 ? remainder + animation.duration : remainder)
                        / animation.duration
                } else {
                    phase = 0
                }
            } else {
                phase = 0
            }
            if wasAnimating {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                spriteLayer.removeAnimation(forKey: oldValue.animationKey)
                spriteLayer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            if oldValue.frameCount != timing.frameCount
                || oldValue.animationKey != timing.animationKey {
                configuredSpriteImage = nil
                configuredFrameSize = .zero
            }
            if wasAnimating, spriteLayer.contents != nil {
                installThinkingAnimation(phase: phase)
            }
        }
    }

    /// The viewport layer is clipped to one icon-sized frame. The sprite
    /// layer is positioned at its lower-left origin so negative Y translations
    /// expose successive frames without changing the viewport geometry.
    let iconLayer = CALayer()
    let spriteLayer = CALayer()

    private(set) var thinkingAnimationInstallCount = 0
    private(set) var contentsRasterizationCount = 0
    private var configuredSpriteImage: NSImage?
    private var configuredFrameSize = NSSize.zero
    private var configuredAppearanceKey: String?
    private var configuredHighlightState = false
    private var configuredContentsScale: CGFloat = 0
    private var configuredContentsSize = NSSize.zero

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { .zero }

    var hasThinkingAnimation: Bool {
        spriteLayer.animation(forKey: timing.animationKey) != nil
    }

    var spriteRasterizationCount: Int { contentsRasterizationCount }

    var modelTranslationYForTesting: CGFloat {
        spriteLayer.affineTransform().ty
    }

    var thinkingAnimationForTesting: CAKeyframeAnimation? {
        spriteLayer.animation(forKey: timing.animationKey) as? CAKeyframeAnimation
    }

    var currentThinkingPhaseForTesting: Double? {
        guard let animation = thinkingAnimationForTesting,
              animation.duration > 0 else {
            return nil
        }
        let localNow = spriteLayer.convertTime(CACurrentMediaTime(), from: nil)
        let elapsed = localNow - animation.beginTime
        let remainder = elapsed.truncatingRemainder(dividingBy: animation.duration)
        return (remainder < 0 ? remainder + animation.duration : remainder)
            / animation.duration
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateGeometry(frame: NSRect, contentsScale: CGFloat) {
        let shouldPreserveAnimation = hasThinkingAnimation && bounds.size != frame.size
        let preservedPhase = shouldPreserveAnimation
            ? currentThinkingPhaseForTesting ?? 0
            : 0
        if shouldPreserveAnimation {
            removeThinkingAnimation()
        }
        if self.frame != frame {
            self.frame = frame
        }
        updateLayerGeometry(contentsScale: contentsScale)
        if shouldPreserveAnimation {
            installThinkingAnimation(phase: preservedPhase)
        }
    }

    /// Rasterizes the complete sprite for the current visual inputs and
    /// installs it as one layer texture. Repeated calls with the same source,
    /// appearance, highlight, scale, and viewport are no-ops.
    @discardableResult
    func updateContents(
        spriteImage: NSImage,
        frameSize: NSSize,
        appearance: NSAppearance,
        contentsScale: CGFloat,
        highlighted: Bool = false
    ) -> Bool {
        let safeScale = contentsScale > 0 ? contentsScale : 2
        let appearanceKey = Self.appearanceKey(for: appearance)
        let viewportSize = bounds.size
        guard
            frameSize.width > 0,
            frameSize.height > 0,
            viewportSize.width > 0,
            viewportSize.height > 0
        else {
            return false
        }

        let needsRasterization = configuredSpriteImage !== spriteImage
            || configuredFrameSize != frameSize
            || configuredAppearanceKey != appearanceKey
            || configuredHighlightState != highlighted
            || configuredContentsScale != safeScale
            || configuredContentsSize != viewportSize
            || spriteLayer.contents == nil
        guard needsRasterization else { return true }

        let spriteSize = NSSize(
            width: viewportSize.width,
            height: viewportSize.height * CGFloat(timing.frameCount)
        )
        guard let contents = Self.renderContents(
            spriteImage: spriteImage,
            size: spriteSize,
            appearance: appearance,
            scale: safeScale,
            highlighted: highlighted
        ) else {
            removeThinkingAnimation()
            spriteLayer.contents = nil
            configuredSpriteImage = nil
            configuredFrameSize = .zero
            configuredAppearanceKey = nil
            configuredHighlightState = false
            configuredContentsScale = 0
            configuredContentsSize = .zero
            return false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = contents
        spriteLayer.contentsScale = safeScale
        CATransaction.commit()
        configuredSpriteImage = spriteImage
        configuredFrameSize = frameSize
        configuredAppearanceKey = appearanceKey
        configuredHighlightState = highlighted
        configuredContentsScale = safeScale
        configuredContentsSize = viewportSize
        contentsRasterizationCount += 1
        return true
    }

    /// Installs the discrete sprite translation for the current timing.
    /// `phase` is used only when a host is recreated at a visual boundary.
    func installThinkingAnimation(phase: Double = 0) {
        guard !hasThinkingAnimation, spriteLayer.contents != nil else { return }
        applyRestingModelTransform()
        let normalizedPhase = phase.truncatingRemainder(dividingBy: 1)
            .wrappedPositiveRemainder
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = timing.translationValues(frameHeight: bounds.height)
        animation.keyTimes = timing.keyTimes
        animation.duration = timing.duration
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.beginTime = spriteLayer.convertTime(CACurrentMediaTime(), from: nil)
            - normalizedPhase * timing.duration
        animation.isRemovedOnCompletion = false
        spriteLayer.add(animation, forKey: timing.animationKey)
        thinkingAnimationInstallCount += 1
    }

    func removeThinkingAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.removeAnimation(forKey: timing.animationKey)
        spriteLayer.removeAnimation(forKey: Self.thinkingAnimationKey)
        spriteLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func applyRestingModelTransform() {
        let restingTranslation = timing.translationValue(
            frameIndex: timing.restingFrameIndex,
            frameHeight: bounds.height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.setAffineTransform(
            CGAffineTransform(translationX: 0, y: restingTranslation)
        )
        CATransaction.commit()
    }

    private func configureLayers() {
        isHidden = true
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0
        iconLayer.masksToBounds = true
        iconLayer.isGeometryFlipped = false
        spriteLayer.masksToBounds = false
        spriteLayer.isGeometryFlipped = false
        spriteLayer.contentsGravity = .resize
        iconLayer.addSublayer(spriteLayer)
        layer?.addSublayer(iconLayer)
        updateLayerGeometry(contentsScale: 2)
    }

    private func updateLayerGeometry(contentsScale: CGFloat) {
        let safeScale = contentsScale > 0 ? contentsScale : 2
        let viewportSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.bounds = CGRect(origin: .zero, size: viewportSize)
        iconLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        iconLayer.contentsScale = safeScale
        spriteLayer.anchorPoint = CGPoint.zero
        spriteLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: viewportSize.width,
            height: viewportSize.height * CGFloat(timing.frameCount)
        )
        spriteLayer.position = .zero
        spriteLayer.contentsScale = safeScale
        CATransaction.commit()
    }

    private static func appearanceKey(for appearance: NSAppearance) -> String {
        let bestMatch = appearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "none"
        return "\(appearance.name.rawValue)|\(bestMatch)"
    }

    private static func renderContents(
        spriteImage: NSImage,
        size: NSSize,
        appearance: NSAppearance,
        scale: CGFloat,
        highlighted: Bool
    ) -> CGImage? {
        let pixelDimensions = MenuBarBitmapImageLayout.pixelDimensions(
            for: size,
            scale: scale
        )
        guard
            size.width > 0,
            size.height > 0,
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelDimensions.width,
                pixelsHigh: pixelDimensions.height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            return nil
        }
        rep.size = size
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.appearance = appearance
        imageView.image = spriteImage
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.contentTintColor = highlighted
            ? .selectedMenuItemTextColor
            : .labelColor
        imageView.wantsLayer = true
        imageView.layoutSubtreeIfNeeded()
        imageView.cacheDisplay(in: imageView.bounds, to: rep)
        return rep.cgImage
    }

    deinit {
        removeThinkingAnimation()
    }
}

private extension Double {
    var wrappedPositiveRemainder: Double {
        let remainder = truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}

final class MenuBarTextView: NSView {
    override var isFlipped: Bool { true }

    var layoutSize: NSSize = NSSize(width: 32, height: 18) {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize { layoutSize }
}

/// Native menus swallow ordinary wheel delivery. This viewport forwards only
/// events in its own visible bounds, leaving nested ticket scrolling to its host.
final class AggregationOverviewScrollView: NSScrollView {
    private var wheelMonitor: Any?
    private var isMenuContentVisible = false
    private var pendingDistanceFromTop: CGFloat?
    private var restoreOnMount = false
    private var isRestoringViewport = false
    private var lastGeometry: String?
    private(set) var mountCount = 0
    var diagnosticContext: (() -> String)?

    static var diagnosticsEnabled: Bool {
        Bundle.main.bundleIdentifier?.hasPrefix("com.huanmeng06.BalanceBar.dev") == true
            || ProcessInfo.processInfo.environment["BALANCEBAR_AGGREGATION_DIAGNOSTICS"] == "1"
    }

    func restoreViewport(distanceFromTop: CGFloat) {
        if !restoreOnMount { pendingDistanceFromTop = max(0, distanceFromTop) }
        tile()
        layoutSubtreeIfNeeded()
        constrainViewport(reason: "placement")
    }

    /// A replacement menu host has no final viewport until AppKit attaches it.
    func restoreViewportAfterMount(distanceFromTop: CGFloat) {
        pendingDistanceFromTop = max(0, distanceFromTop)
        restoreOnMount = true
        if window != nil { constrainViewport(reason: "mount-restore") }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        mountCount += 1
        tile()
        needsLayout = true
        layoutSubtreeIfNeeded()
        constrainViewport(reason: "mount")
    }

    override func layout() {
        super.layout()
        constrainViewport(reason: "layout")
    }

    private func constrainViewport(reason: String) {
        guard !isRestoringViewport, !restoreOnMount || window != nil, let documentView,
              contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        restoreOnMount = false
        isRestoringViewport = true
        defer { isRestoringViewport = false }
        let maximum = max(0, documentView.frame.height - contentView.bounds.height)
        let desired = pendingDistanceFromTop.map { maximum - $0 } ?? contentView.bounds.origin.y
        let origin = NSPoint(x: 0, y: min(maximum, max(0, desired)))
        pendingDistanceFromTop = nil
        if contentView.bounds.origin != origin { contentView.scroll(to: origin) }
        reflectScrolledClipView(contentView)
        logGeometry(reason: reason)
    }

    func logGeometry(reason: String) {
        guard Self.diagnosticsEnabled, let documentView else { return }
        let visible = contentView.documentVisibleRect
        let cards = documentView.subviews.filter { $0.identifier?.rawValue.hasPrefix("aggregation.provider.") == true }
        func cardRect(_ wrapper: NSView) -> NSRect {
            let card = wrapper.subviews.first { !($0 is NSTextField) } ?? wrapper
            return documentView.convert(card.bounds, from: card)
        }
        let count = cards.filter { !$0.isHidden && !cardRect($0).intersection(visible).isEmpty }.count
        let geometry = "scroll=\(frame); clip=\(contentView.bounds); document=\(documentView.frame); visible=\(visible); attached=\(window != nil); mounts=\(mountCount); window_visible=\(window?.isVisible ?? false); occlusion_visible=\(window?.occlusionState.contains(.visible) ?? false); document_hidden=\(documentView.isHidden); alpha=\(alphaValue); intersections=\(count); cards=\(cards.count)"
        let context = diagnosticContext?() ?? ""
        let signature = reason + "|" + geometry + "|" + context
        guard lastGeometry != signature else { return }
        lastGeometry = signature
        let frames = cards.prefix(16).enumerated().map {
            "index=\($0.offset),frame=\(cardRect($0.element)),hidden=\($0.element.isHidden),intersection=\(cardRect($0.element).intersection(visible))"
        }.joined(separator: "; ")
        SwitchLog.write("aggregation geometry; reason=\(reason); view=\(ObjectIdentifier(self)); \(geometry); \(context); [\(frames)]",
            level: .debug, category: "ui.aggregation", throttleKey: "aggregation-geometry-\(ObjectIdentifier(self))-\(reason)", minimumInterval: 0.25)
    }

    func setMenuContentVisible(_ visible: Bool) {
        guard isMenuContentVisible != visible else { return }
        isMenuContentVisible = visible
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        guard visible else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            func insideTicket(_ view: NSView) -> Bool {
                if view is BankedResetTicketScrollView,
                   view.visibleRect.contains(view.convert(event.locationInWindow, from: nil)) { return true }
                return view.subviews.contains(where: insideTicket)
            }
            if self.documentView.map(insideTicket) == true { return event }
            self.scrollWheel(with: event)
            return nil
        }
    }

    deinit { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }
}
