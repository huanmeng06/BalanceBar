import AppKit
import CoreImage
import XCTest
@testable import BalanceBar

private final class FixedPreviewRowAccessory: NSView, SettingsRowAccessoryLayout {
    let allowsTextDrivenDedicatedRow = false
    let minimumInlineLabelWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 190),
            heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateAvailableRowWidth(_ width: CGFloat) {
        _ = width
    }

    var naturalAccessoryWidth: CGFloat { 190 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 190, height: 42)
    }
}

/// Isolates native window presentation from the mandatory background host
/// policy. Content, anchor, ownership and timing still use production code.
@MainActor
private final class QuotaPacePopoverProbe: NSPopover {
    private var showing = false
    private var controller: NSViewController?
    private var size = NSSize.zero
    private var rect = NSRect.zero
    private(set) var showCount = 0
    private(set) var showAnimationFlags: [Bool] = []
    private(set) var closeAnimationFlags: [Bool] = []
    var delaysCloseCompletion = false
    weak var anchorView: NSView?
    private(set) var preferredEdge: NSRectEdge?

    override var isShown: Bool { showing }
    override var contentViewController: NSViewController? {
        get { controller }
        set { controller = newValue }
    }
    override var contentSize: NSSize {
        get { size }
        set { size = newValue }
    }
    override var positioningRect: NSRect {
        get { rect }
        set { rect = newValue }
    }
    override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        rect = positioningRect
        anchorView = positioningView
        self.preferredEdge = preferredEdge
        showing = true
        showCount += 1
        showAnimationFlags.append(animates)
    }
    override func close() {
        closeAnimationFlags.append(animates)
        delegate?.popoverWillClose?(Notification(name: NSPopover.willCloseNotification, object: self))
        if !delaysCloseCompletion { completeClose() }
    }
    func completeClose() {
        showing = false
        delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
    }
}

private final class PaceDismissalWindowProbe: NSWindow {
    var reportedOcclusionState: NSWindow.OcclusionState = .visible
    override var occlusionState: NSWindow.OcclusionState { reportedOcclusionState }
}

private final class PacePresentationProbeLayer: CALayer {
    var presented: PacePresentationProbeLayer?
    override func presentation() -> Self? { presented as? Self }
}

@MainActor
final class DashboardComponentsTests: XCTestCase {
    private func paceWindow(remaining: Double = 50, reset: Date, kind: OfficialQuotaWindow.Kind = .fiveHour) -> OfficialQuotaWindow {
        OfficialQuotaWindow(kind: kind, remaining: remaining, label: "quota", daysText: "quota",
            reset: "obsolete", durationSeconds: kind == .sevenDay ? 604_800 : 18_000, resetAt: reset)
    }

    func testPaceTickLayerMetricsSpringReverseAndCopy() throws {
        let tick = PaceTickLayer()
        XCTAssertEqual(tick.bodyLayer.bounds.size, CGSize(width: 2, height: 8))
        XCTAssertEqual(tick.strokeLayer.bounds.size, CGSize(width: 3.5, height: 9.5))
        XCTAssertEqual(tick.bodyLayer.cornerRadius, 1)
        XCTAssertEqual(tick.bodyLayer.opacity, 0.85)
        tick.updateGeometry(center: CGPoint(x: 100, y: 9), scale: 2)
        XCTAssertEqual(tick.bodyLayer.position, tick.strokeLayer.position)
        tick.setHovered(true, reduceMotion: false)
        XCTAssertEqual(tick.bodyLayer.bounds.size, CGSize(width: 3.5, height: 11))
        XCTAssertEqual(tick.strokeLayer.bounds.size, CGSize(width: 5.5, height: 13))
        XCTAssertEqual(tick.bodyLayer.cornerRadius, 1.75)
        XCTAssertEqual(tick.strokeLayer.cornerRadius, 2.75)
        XCTAssertEqual(tick.bodyLayer.opacity, 1)
        XCTAssertTrue(CATransform3DIsIdentity(tick.bodyLayer.transform))
        for child in [tick.bodyLayer, tick.strokeLayer] {
            for key in ["bounds", "cornerRadius", "opacity"] {
                let animation = try XCTUnwrap(child.animation(forKey: "pace.\(key)") as? CASpringAnimation)
                XCTAssertEqual(animation.keyPath, key)
                XCTAssertEqual(animation.damping, 18)
                XCTAssertEqual(animation.stiffness, 320)
                XCTAssertEqual(animation.mass, 1)
                XCTAssertEqual(animation.initialVelocity, 0)
                XCTAssertEqual(animation.duration, animation.settlingDuration)
                XCTAssertNotNil(animation.fromValue)
                XCTAssertNotNil(animation.toValue)
            }
        }
        tick.setHovered(true, reduceMotion: false)
        let unchanged = try XCTUnwrap(tick.bodyLayer.animation(forKey: "pace.bounds") as? CABasicAnimation)
        XCTAssertEqual((unchanged.fromValue as? NSValue)?.rectValue.size, CGSize(width: 2, height: 8), "Repeated hover must not restart from the model target")
        tick.setHovered(false, reduceMotion: false)
        let exit = try XCTUnwrap(tick.bodyLayer.animation(forKey: "pace.bounds") as? CABasicAnimation)
        XCTAssertFalse(exit is CASpringAnimation)
        XCTAssertEqual(exit.duration, 0.15)
        XCTAssertEqual((exit.fromValue as? NSValue)?.rectValue.size, CGSize(width: 3.5, height: 11))
        XCTAssertEqual((exit.toValue as? NSValue)?.rectValue.size, CGSize(width: 2, height: 8))
        tick.setHovered(true, reduceMotion: false)
        XCTAssertEqual(tick.bodyLayer.animationKeys()?.count, 3)
        let copy = PaceTickLayer(layer: tick)
        XCTAssertEqual(copy.sublayers?.count, 2)
        XCTAssertEqual(copy.bodyLayer.bounds, tick.bodyLayer.bounds)
        XCTAssertTrue(copy.isHovered)
        XCTAssertFalse(copy.bodyLayer === tick.bodyLayer)
        copy.setHovered(false, reduceMotion: true)
        XCTAssertEqual(tick.bodyLayer.bounds.size, PaceTickLayer.hoverSize)
        tick.setHovered(false, reduceMotion: false, immediately: true)
        XCTAssertNil(tick.bodyLayer.animationKeys())
        XCTAssertNil(tick.strokeLayer.animationKeys())
        XCTAssertEqual(tick.bodyLayer.bounds.size, PaceTickLayer.restSize)
    }

    func testPaceReverseAnimationUsesPresentationInsteadOfModelTarget() throws {
        let tick = PaceTickLayer()
        let model = PacePresentationProbeLayer()
        model.name = "pace.body"
        model.bounds = CGRect(origin: .zero, size: PaceTickLayer.restSize)
        let visible = PacePresentationProbeLayer()
        visible.bounds = CGRect(x: 0, y: 0, width: 2.8, height: 9.9)
        visible.cornerRadius = 1.4
        visible.opacity = 0.93
        model.presented = visible
        tick.sublayers = [tick.strokeLayer, model]
        tick.setHovered(true, reduceMotion: false)
        tick.setHovered(false, reduceMotion: false)
        let bounds = try XCTUnwrap(model.animation(forKey: "pace.bounds") as? CABasicAnimation)
        XCTAssertEqual((bounds.fromValue as? NSValue)?.rectValue, visible.bounds)
        XCTAssertEqual((bounds.toValue as? NSValue)?.rectValue.size, PaceTickLayer.restSize)
        let radius = try XCTUnwrap(model.animation(forKey: "pace.cornerRadius") as? CABasicAnimation)
        XCTAssertEqual((radius.fromValue as? NSNumber)?.doubleValue, 1.4)
        let opacity = try XCTUnwrap(model.animation(forKey: "pace.opacity") as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(opacity.fromValue as? NSNumber).doubleValue, 0.93, accuracy: 0.001)
    }

    func testPaceTickColorsScaleAndReduceMotion() throws {
        let tick = PaceTickLayer()
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            tick.updateColors(for: appearance)
            var expected: CGColor?
            appearance.performAsCurrentDrawingAppearance { expected = NSColor.labelColor.cgColor }
            XCTAssertEqual(tick.bodyLayer.backgroundColor, expected)
            let outline = try XCTUnwrap(tick.strokeLayer.backgroundColor)
            XCTAssertEqual(outline.alpha, 0.4, accuracy: 0.0001)
            let color = try XCTUnwrap(NSColor(cgColor: outline)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, name == .darkAqua ? 0 : 1, accuracy: 0.0001)
        }
        for scale in [1.0, 2.0] {
            tick.updateGeometry(center: CGPoint(x: 75, y: 9), scale: scale)
            XCTAssertEqual(tick.position, CGPoint(x: 75, y: 9))
            for child in [tick, tick.bodyLayer, tick.strokeLayer] { XCTAssertEqual(child.contentsScale, scale) }
        }
        tick.setHovered(true, reduceMotion: true)
        XCTAssertEqual(tick.bodyLayer.bounds.size, PaceTickLayer.hoverSize)
        XCTAssertNil(tick.bodyLayer.animationKeys())
        tick.setHovered(false, reduceMotion: true)
        XCTAssertEqual(tick.bodyLayer.bounds.size, PaceTickLayer.restSize)
        XCTAssertNil(tick.strokeLayer.animationKeys())
    }

    func testPaceHoverAnimationKeepsHeatRectAndRuntimeReduceMotion() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = paceProbeFixture(now: now)
        let window = NSWindow(contentRect: fixture.host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = fixture.host
        defer { fixture.host.setMenuContentVisible(false); window.orderOut(nil) }
        fixture.host.layoutSubtreeIfNeeded()
        let view = fixture.views[0]
        view.markerReduceMotionForTesting = false
        fixture.host.setPaceMenuTracking(true)
        let heat = view.markerHitRect
        let overlay = try XCTUnwrap(view.subviews.last)
        overlay.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        overlay.viewDidChangeEffectiveAppearance()
        let outline = try XCTUnwrap(view.markerLayerForTesting.strokeLayer.backgroundColor)
        XCTAssertEqual(try XCTUnwrap(NSColor(cgColor: outline)?.usingColorSpace(.deviceRGB)).redComponent, 0, accuracy: 0.001)
        view.updateHover(at: NSPoint(x: view.markerCenterX, y: 9))
        XCTAssertEqual(view.markerLayerForTesting.bodyLayer.bounds.size, PaceTickLayer.hoverSize)
        XCTAssertEqual(view.markerHitRect, heat)
        XCTAssertTrue(view.hasPendingShowForTesting)
        XCTAssertNotNil(view.markerLayerForTesting.bodyLayer.animationKeys())
        view.markerReduceMotionForTesting = true
        view.refreshMarkerAccessibility()
        XCTAssertNil(view.markerLayerForTesting.bodyLayer.animationKeys())
        XCTAssertEqual(view.markerLayerForTesting.bodyLayer.bounds.size, PaceTickLayer.hoverSize)
        view.markerReduceMotionForTesting = false
        view.refreshMarkerAccessibility()
        XCTAssertNil(view.markerLayerForTesting.bodyLayer.animationKeys(), "Disabling Reduce Motion does not replay")
        view.updateHover(at: NSPoint(x: -100, y: -100))
        XCTAssertEqual(view.markerLayerForTesting.bodyLayer.bounds.size, PaceTickLayer.restSize)
        XCTAssertEqual(view.markerHitRect, heat)
        XCTAssertFalse(view.hasPendingShowForTesting)
        XCTAssertTrue(view.hasPendingCloseForTesting)
        XCTAssertEqual(view.markerLayerForTesting.bodyLayer.animation(forKey: "pace.bounds")?.duration, 0.15)
        view.updateHover(at: NSPoint(x: view.markerCenterX, y: 9))
        XCTAssertFalse(view.hasPendingCloseForTesting)
        view.clearInteraction()
        XCTAssertNil(view.markerLayerForTesting.bodyLayer.animationKeys())
        XCTAssertNil(view.markerLayerForTesting.strokeLayer.animationKeys())
        XCTAssertEqual(view.markerLayerForTesting.bodyLayer.bounds.size, PaceTickLayer.restSize)
        XCTAssertFalse(view.hasPendingShowForTesting)
    }

    private func focusSections() -> [OpenCodexOverviewSectionID: OpenCodexOverviewSectionView] {
        Dictionary(uniqueKeysWithValues: [OpenCodexOverviewSectionID.account, .fiveHour, .sevenDay, .lunaReserve, .resetProbability, .bankedReset].map { id in
            let view = OpenCodexOverviewSectionView(layout: OpenCodexOverviewSectionLayout(id: id,
                frame: NSRect(x: 0, y: 0, width: 220, height: 40), row: nil))
            view.focusReduceMotionForTesting = true
            // Do not inherit the host's Reduce Transparency (CI runners may set it).
            view.focusReduceTransparencyForTesting = false
            return (id, view)
        })
    }

    @MainActor
    func testOpenLinkBubbleFocusesItsSectionAndRecedesTheRest() throws {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        let probability = OpenCodexOverviewSectionView(layout: OpenCodexOverviewSectionLayout(id: .resetProbability,
            frame: NSRect(x: 0, y: 0, width: 220, height: 40), row: nil))
        let quota = OpenCodexOverviewSectionView(layout: OpenCodexOverviewSectionLayout(id: .fiveHour,
            frame: NSRect(x: 0, y: 40, width: 220, height: 40), row: nil))
        [probability, quota].forEach {
            $0.focusReduceMotionForTesting = true
            host.addSubview($0)
        }
        let link = HoverLinkTextField(text: "重置概率")
        probability.addSubview(link)
        host.track(link)
        host.setPaceMenuTracking(true)

        link.onHoverHintVisibilityChanged?(true)

        XCTAssertEqual(host.sectionFocus.focusedID, .resetProbability)
        XCTAssertEqual(probability.focusState, .focused)
        XCTAssertEqual(quota.focusState, .receded)

        link.onHoverHintVisibilityChanged?(false)

        XCTAssertNil(host.sectionFocus.focusedID)
        XCTAssertEqual(probability.focusState, .normal)
        XCTAssertEqual(quota.focusState, .normal)
    }

    @MainActor
    func testStalePeerRestoreCompletionCannotDropANewerRestoresFilter() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "restores are not animated")
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, "no blur filter is attached")
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        host.wantsLayer = true
        func hasBlur() -> Bool { host.contentFilters.contains { $0.name == "balancebarPeerFocusBlur" } }

        host.setPeerReceded(true, animated: true)
        host.setPeerReceded(false, animated: true)
        let firstRestore = try XCTUnwrap(host.peerRestoreCompletionForTesting)
        host.setPeerReceded(true, animated: true)
        host.setPeerReceded(false, animated: true)
        let secondRestore = try XCTUnwrap(host.peerRestoreCompletionForTesting)

        firstRestore()
        XCTAssertTrue(hasBlur(), "the first restore's late completion must not cut the second restore short")
        secondRestore()
        XCTAssertFalse(hasBlur())
    }

    func testPaceExitKeepsAnOpenLinkBubbleFocused() throws {
        let controller = SectionFocusController()
        let sections = focusSections()
        controller.update(sections: sections)
        controller.isActive = true

        controller.hoverChanged(.fiveHour, isHovering: true)
        controller.setHintFocus(.resetProbability, from: .resetProbability)
        controller.hoverChanged(.fiveHour, isHovering: false)
        try XCTUnwrap(controller.pendingTimerForTesting).fire()

        XCTAssertEqual(controller.focusedID, .resetProbability)
        XCTAssertEqual(sections[.resetProbability]?.focusState, .focused)
        XCTAssertEqual(sections[.fiveHour]?.focusState, .receded)

        controller.setHintFocus(nil, from: .resetProbability)
        XCTAssertNil(controller.focusedID)
        XCTAssertTrue(sections.values.allSatisfy { $0.focusState == .normal })
    }

    func testSectionFocusTrackingDelaysSwitchAndRetiredEvents() throws {
        let controller = SectionFocusController()
        let sections = focusSections()
        controller.update(sections: sections)
        controller.isActive = true
        func run(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { _ = RunLoop.current.run(mode: .eventTracking, before: end) }
        }
        controller.hoverChanged(.fiveHour, isHovering: true)
        let cancelled = try XCTUnwrap(controller.pendingTimerForTesting)
        controller.hoverChanged(.fiveHour, isHovering: false)
        cancelled.fire()
        XCTAssertNil(controller.focusedID)
        controller.hoverChanged(.fiveHour, isHovering: true)
        run(0.1)
        XCTAssertNil(controller.focusedID)
        run(0.08)
        XCTAssertEqual(controller.focusedID, .fiveHour)
        for (id, section) in sections {
            XCTAssertEqual(section.focusState, id == .fiveHour ? .focused : .receded)
            XCTAssertEqual(section.alphaValue, id == .fiveHour ? 1 : 0.5)
        }
        controller.hoverChanged(.fiveHour, isHovering: false)
        let staleExit = try XCTUnwrap(controller.pendingTimerForTesting)
        controller.hoverChanged(.sevenDay, isHovering: true)
        controller.hoverChanged(.fiveHour, isHovering: false)
        staleExit.fire()
        XCTAssertEqual(controller.focusedID, .sevenDay)
        XCTAssertNil(controller.pendingTimerForTesting)
        controller.hoverChanged(.sevenDay, isHovering: false)
        run(0.04)
        XCTAssertEqual(controller.focusedID, .sevenDay)
        run(0.06)
        XCTAssertNil(controller.focusedID)
        XCTAssertTrue(sections.values.allSatisfy { $0.alphaValue == 1 && $0.contentFilters.isEmpty })
        controller.hoverChanged(.fiveHour, isHovering: true)
        let staleEnter = try XCTUnwrap(controller.pendingTimerForTesting)
        controller.reset()
        controller.isActive = false
        staleEnter.fire()
        XCTAssertNil(controller.focusedID)
    }

    func testSectionFocusFilterOwnershipLateCompletionAndAccessibility() throws {
        let section = try XCTUnwrap(focusSections()[.account])
        section.focusReduceMotionForTesting = false
        // CI runners may report Reduce Transparency, which skips the blur.
        section.focusReduceTransparencyForTesting = false
        section.wantsLayer = true
        let foreign = try XCTUnwrap(CIFilter(name: "CISepiaTone"))
        foreign.name = "unrelated"
        section.contentFilters = [foreign]
        section.setFocusState(.normal, animated: false)
        XCTAssertEqual(section.contentFilters.count, 1)
        section.setFocusState(.receded, animated: true)
        let node = try XCTUnwrap(section.layer)
        XCTAssertEqual((node.value(forKeyPath: "filters.balancebarSectionFocusBlur.inputRadius") as? NSNumber)?.doubleValue, 3)
        XCTAssertEqual(node.animation(forKey: "sectionFocus.radius")?.duration, PaceHoverTiming.blurDuration)
        let count = section.focusTransitionCountForTesting
        section.setFocusState(.receded, animated: true)
        XCTAssertEqual(section.focusTransitionCountForTesting, count)
        section.setFocusState(.normal, animated: true)
        XCTAssertEqual(node.animation(forKey: "sectionFocus.radius")?.duration, 0.2)
        let oldCompletion = try XCTUnwrap(section.focusRestoreCompletionForTesting)
        section.setFocusState(.receded, animated: true)
        oldCompletion()
        XCTAssertTrue(section.contentFilters.contains { $0.name == "balancebarSectionFocusBlur" })
        section.focusReduceMotionForTesting = true
        section.setFocusState(.receded, animated: false)
        XCTAssertNil(node.animation(forKey: "sectionFocus.radius"))
        XCTAssertEqual(section.alphaValue, 0.5)
        section.focusReduceTransparencyForTesting = true
        section.setFocusState(.receded, animated: false)
        XCTAssertEqual(section.contentFilters.map(\.name), ["unrelated"])
        section.focusReduceTransparencyForTesting = false
        section.setFocusState(.receded, animated: false)
        XCTAssertTrue(section.contentFilters.contains { $0.name == "balancebarSectionFocusBlur" })
        section.setFocusState(.normal, animated: false)
        XCTAssertEqual(section.alphaValue, 1)
        XCTAssertEqual(section.contentFilters.map(\.name), ["unrelated"])
        oldCompletion()
        XCTAssertEqual(section.contentFilters.map(\.name), ["unrelated"])
        let fallback = try XCTUnwrap(focusSections()[.fiveHour])
        var attempts = 0
        fallback.focusFilterFactoryForTesting = { attempts += 1; return nil }
        fallback.setFocusState(.receded, animated: true)
        fallback.setFocusState(.receded, animated: true)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(fallback.alphaValue, 0.5)
        XCTAssertTrue(fallback.contentFilters.isEmpty)
    }

    func testSectionFocusHostRefreshInvalidationAndRetiredCallback() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = paceProbeFixture(now: now)
        let window = NSWindow(contentRect: fixture.host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = fixture.host
        defer { fixture.host.setPaceMenuTracking(false); window.orderOut(nil) }
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.setPaceMenuTracking(true)
        let view = fixture.views[0]
        let section = try XCTUnwrap(view.superview as? OpenCodexOverviewSectionView)
        let other = try XCTUnwrap(fixture.views[1].superview as? OpenCodexOverviewSectionView)
        section.focusReduceMotionForTesting = true
        other.focusReduceMotionForTesting = true
        view.updateHover(at: NSPoint(x: view.markerCenterX, y: 9))
        fixture.host.sectionFocus.pendingTimerForTesting?.fire()
        XCTAssertEqual(fixture.host.sectionFocus.focusedID, .fiveHour)
        let count = other.focusTransitionCountForTesting
        let monitor = fixture.host.monitorRegistrationCountForTesting
        for _ in 0..<10 { fixture.host.reconcilePaceMenuTracking() }
        XCTAssertEqual(other.focusTransitionCountForTesting, count)
        XCTAssertEqual(fixture.host.monitorRegistrationCountForTesting, monitor)
        let oldCallback = try XCTUnwrap(view.onHoverChanged)
        view.invalidatePresentation()
        XCTAssertNil(fixture.host.sectionFocus.focusedID)
        XCTAssertEqual(other.alphaValue, 1)
        XCTAssertTrue(other.contentFilters.isEmpty)
        section.removeFromSuperview()
        fixture.host.reconcileSectionFocus()
        fixture.views[1].updateHover(at: NSPoint(x: fixture.views[1].markerCenterX, y: 9))
        fixture.host.sectionFocus.pendingTimerForTesting?.fire()
        oldCallback(true)
        oldCallback(false)
        XCTAssertEqual(fixture.host.sectionFocus.focusedID, .sevenDay)
        fixture.views[1].removeFromSuperview()
        XCTAssertNil(fixture.host.sectionFocus.focusedID)
        XCTAssertNil(fixture.host.sectionFocus.pendingTimerForTesting)
        XCTAssertEqual(other.alphaValue, 1)
    }

    func testSectionFocusHostReplacementChecksActualViewsCycleAndHeatRect() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = paceProbeFixture(now: now)
        let host = fixture.host
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { host.setPaceMenuTracking(false); window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        host.setPaceMenuTracking(true)
        let old = fixture.views[0]
        let oldSection = try XCTUnwrap(old.superview as? OpenCodexOverviewSectionView)
        host.focusPointerLocationForTesting = host.convert(NSPoint(x: old.markerCenterX, y: 9), from: old)
        old.updateHover(at: NSPoint(x: old.markerCenterX, y: 9))
        host.sectionFocus.pendingTimerForTesting?.fire()
        XCTAssertEqual(host.sectionFocus.focusedID, .fiveHour)
        let pendingTooltip = try XCTUnwrap(host.sectionFocus.pendingTimerForTesting)
        let stale = try XCTUnwrap(old.onHoverChanged)
        host.beginFocusSectionReplacement()
        oldSection.removeFromSuperview()
        let replacement = OpenCodexMetricSectionView(layout: OpenCodexOverviewSectionLayout(
            id: .fiveHour, frame: oldSection.frame, row: nil))
        let pace = QuotaProgressPaceView(percentage: 50, window: old.quotaWindow,
            identity: old.numericIdentity, now: now, colorConfiguration: .default)
        pace.frame = old.frame
        replacement.addSubview(pace)
        host.addSubview(replacement)
        host.finishFocusSectionReplacement()
        XCTAssertTrue(host.sectionFocus.sections[.fiveHour] === replacement)
        XCTAssertEqual(host.sectionFocus.focusedID, .fiveHour)
        XCTAssertTrue(pace.isHovered)
        XCTAssertTrue(host.sectionFocus.pendingTimerForTesting === pendingTooltip, "Replacement keeps the outstanding tooltip phase")
        XCTAssertTrue(pace.hasPendingShowForTesting)
        stale(false)
        XCTAssertEqual(host.sectionFocus.focusedID, .fiveHour)
        // A new cycle cannot inherit the active focus from the replaced quota.
        host.beginFocusSectionReplacement()
        pace.update(window: paceWindow(reset: now.addingTimeInterval(8_000)), now: now)
        host.focusPointerLocationForTesting = host.convert(NSPoint(x: pace.markerCenterX, y: 9), from: pace)
        host.finishFocusSectionReplacement()
        XCTAssertNil(host.sectionFocus.focusedID)
        XCTAssertNotNil(host.sectionFocus.pendingTimerForTesting)
        host.sectionFocus.pendingTimerForTesting?.fire()
        XCTAssertEqual(host.sectionFocus.focusedID, .fiveHour)
        host.beginFocusSectionReplacement()
        host.focusPointerLocationForTesting = NSPoint(x: -100, y: -100)
        host.finishFocusSectionReplacement()
        XCTAssertNil(host.sectionFocus.focusedID)
        XCTAssertNil(host.sectionFocus.pendingTimerForTesting)
    }

    func testSectionFocusRegistryReplacementAndRemovalPreserveOrReset() throws {
        let controller = SectionFocusController()
        var sections = focusSections()
        controller.update(sections: sections)
        controller.isActive = true
        controller.hoverChanged(.fiveHour, isHovering: true)
        controller.pendingTimerForTesting?.fire()
        let old = try XCTUnwrap(sections[.fiveHour])
        let untouched = try XCTUnwrap(sections[.sevenDay])
        let transitions = untouched.focusTransitionCountForTesting
        controller.update(sections: sections)
        XCTAssertEqual(untouched.focusTransitionCountForTesting, transitions)
        sections[.fiveHour] = OpenCodexOverviewSectionView(layout: OpenCodexOverviewSectionLayout(id: .fiveHour,
            frame: old.frame, row: nil))
        controller.update(sections: sections)
        XCTAssertEqual(controller.focusedID, .fiveHour)
        XCTAssertEqual(sections[.fiveHour]?.focusState, .focused)
        XCTAssertTrue(old.contentFilters.isEmpty)
        sections.removeValue(forKey: .fiveHour)
        controller.update(sections: sections)
        XCTAssertNil(controller.focusedID)
        XCTAssertTrue(sections.values.allSatisfy { $0.alphaValue == 1 && $0.contentFilters.isEmpty })
    }

    func testPaceMarkerOverlayAndExactTrackingBoundary() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quota = paceWindow(reset: now.addingTimeInterval(9_000))
        let view = QuotaProgressPaceView(percentage: 50, window: quota,
            identity: OverviewNumericPresentation.identity(for: quota, provider: "Official"),
            now: now, colorConfiguration: .default)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 18)
        view.layoutSubtreeIfNeeded()
        view.updateTrackingAreas()
        XCTAssertNil(view.hitTest(NSPoint(x: 100, y: 9)))
        XCTAssertTrue(view.subviews.first === view.progress)
        XCTAssertTrue(view.subviews.last?.isHidden == false)
        XCTAssertEqual(view.progress.frame.height, 5)
        XCTAssertEqual(view.markerHitRect, NSRect(x: 92, y: 0, width: 16, height: 18))
        let area = try XCTUnwrap(view.trackingAreas.first)
        XCTAssertEqual(area.rect, view.markerHitRect)
        XCTAssertTrue(area.options.contains(.activeAlways))
        XCTAssertFalse(area.options.contains(.inVisibleRect))
        XCTAssertFalse(area.options.contains(.activeInKeyWindow))
        for seconds in [18_000.0, 1.0] {
            view.update(window: paceWindow(reset: now.addingTimeInterval(seconds)), now: now)
            XCTAssertGreaterThanOrEqual(view.markerHitRect.minX, 0)
            XCTAssertLessThanOrEqual(view.markerHitRect.maxX, 200)
            XCTAssertGreaterThanOrEqual(view.markerCenterX, 1)
            XCTAssertLessThanOrEqual(view.markerCenterX, 199)
        }
    }

    func testPaceHostForwardsHoverAndCancelsReentryAndRemovalTasks() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 70))
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = host
        menu.addItem(item)
        window.contentView = host
        let section = NSView(frame: host.bounds)
        host.addSubview(section)
        let quota = paceWindow(reset: now.addingTimeInterval(9_000))
        let view = QuotaProgressPaceView(percentage: 50, window: quota,
            identity: OverviewNumericPresentation.identity(for: quota, provider: "Official"),
            now: now, colorConfiguration: .default)
        view.frame = NSRect(x: 10, y: 10, width: 200, height: 18)
        section.addSubview(view)
        view.layoutSubtreeIfNeeded()
        host.setPaceMenuTracking(true)
        let inside = host.convert(NSPoint(x: view.markerCenterX, y: 9), from: view)
        host.forwardHover(atHostPoint: NSPoint(x: 5, y: 5))
        XCTAssertFalse(view.hasPendingShowForTesting)
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered,
            location: view.convert(NSPoint(x: view.markerCenterX, y: 9), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, trackingNumber: 1, userData: nil))
        view.mouseEntered(with: enter)
        XCTAssertTrue(view.isHovered)
        XCTAssertTrue(view.hasPendingShowForTesting)
        host.forwardHover(atHostPoint: NSPoint(x: 5, y: 5))
        XCTAssertFalse(view.hasPendingShowForTesting)
        XCTAssertTrue(view.hasPendingCloseForTesting)
        host.forwardHover(atHostPoint: inside)
        XCTAssertFalse(view.hasPendingCloseForTesting)
        view.firePendingCloseForTesting()
        XCTAssertTrue(view.isHovered)
        view.firePendingShowForTesting()
        XCTAssertFalse(view.hasPendingShowForTesting)
        XCTAssertFalse(view.isTooltipVisible, "An invisible window must not show a popover")
        let weekly = paceWindow(reset: now.addingTimeInterval(302_400), kind: .sevenDay)
        let weeklyView = QuotaProgressPaceView(percentage: 50, window: weekly,
            identity: OverviewNumericPresentation.identity(for: weekly, provider: "Official"),
            now: now, colorConfiguration: .default)
        weeklyView.frame = NSRect(x: 10, y: 40, width: 200, height: 18)
        section.addSubview(weeklyView)
        host.setPaceMenuTracking(true)
        weeklyView.mouseMoved(with: makeMouseEvent(type: .mouseMoved,
            location: weeklyView.convert(NSPoint(x: weeklyView.markerCenterX, y: 9), to: nil)))
        XCTAssertFalse(view.hasPendingShowForTesting)
        XCTAssertTrue(weeklyView.hasPendingShowForTesting)
        host.setPaceMenuTracking(false)
        XCTAssertFalse(weeklyView.hasPendingShowForTesting)
        XCTAssertFalse(weeklyView.hasPendingCloseForTesting)
        XCTAssertFalse(view.isHovered)
        XCTAssertFalse(view.hasPendingShowForTesting)
        XCTAssertFalse(view.hasPendingCloseForTesting)
        host.setPaceMenuTracking(true)
        host.forwardHover(atHostPoint: inside)
        view.removeFromSuperview()
        XCTAssertFalse(view.hasPendingShowForTesting)
        XCTAssertFalse(view.hasPendingCloseForTesting)
        XCTAssertFalse(view.isTooltipVisible)
    }

    private func paceProbeFixture(now: Date, experiment: PaceDismissalExperiment = .full) -> (menu: NSMenu, host: MenuHoverLinkHostView,
                                               views: [QuotaProgressPaceView], popovers: [QuotaPacePopoverProbe]) {
        let menu = NSMenu(title: "Quota pace tracking regression")
        let item = NSMenuItem()
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        // Existing native-close regressions explicitly exercise C; default B is tested separately.
        host.dismissalExperiment = experiment
        let quotas = [paceWindow(reset: now.addingTimeInterval(9_000)),
                      paceWindow(reset: now.addingTimeInterval(302_400), kind: .sevenDay)]
        let views = quotas.enumerated().map { index, quota in
            let view = QuotaProgressPaceView(percentage: 50, window: quota,
                identity: OverviewNumericPresentation.identity(for: quota, provider: "Official"),
                now: now, colorConfiguration: .default,
                cycleStart: OfficialQuotaUsagePrediction.inferredCycleStart(for: quota))
            let section = OpenCodexMetricSectionView(layout: OpenCodexOverviewSectionLayout(
                id: index == 0 ? .fiveHour : .sevenDay,
                frame: NSRect(x: 0, y: CGFloat(index) * 30, width: 220, height: 30), row: nil))
            host.addSubview(section)
            view.frame = NSRect(x: 10, y: 10, width: 200, height: 18)
            section.addSubview(view)
            return view
        }
        let popovers = views.map { _ in QuotaPacePopoverProbe() }
        for (index, view) in views.enumerated() { view.makePopoverForTesting = { popovers[index] } }
        item.view = host
        menu.addItem(item)
        return (menu, host, views, popovers)
    }

    private func enterPace(_ view: QuotaProgressPaceView) {
        let event = NSEvent.enterExitEvent(with: .mouseEntered,
            location: view.convert(NSPoint(x: view.markerCenterX, y: 9), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, trackingNumber: 1, userData: nil)!
        view.mouseEntered(with: event)
    }

    func testPacePopoverCoordinationInsideRealMenuTrackingLoop() {
        let (menu, host, views, popovers) = paceProbeFixture(now: Date(timeIntervalSince1970: 1_700_000_000))
        host.setMenuContentVisible(true)
        var completed = false
        var attempts = 0
        let probe = Timer(timeInterval: 0.02, repeats: true) { timer in
            attempts += 1
            guard attempts < 50 else { timer.invalidate(); menu.cancelTracking(); return }
            guard host.window != nil else { return }
            timer.invalidate()
            host.layoutSubtreeIfNeeded()
            host.forwardHover(atHostPoint: NSPoint(x: 5, y: 5))
            XCTAssertFalse(views[0].isHovered)
            self.enterPace(views[0])
            XCTAssertTrue(views[0].hasPendingShowForTesting)
            views[0].firePendingShowForTesting()
            XCTAssertTrue(views[0].isTooltipVisible)
            XCTAssertEqual(views[0].markerLayerForTesting.bodyLayer.bounds.size, PaceTickLayer.hoverSize)
            XCTAssertNotNil(views[0].tooltipContent?.body)
            host.sectionFocus.pendingTimerForTesting?.fire()
            XCTAssertEqual(host.sectionFocus.focusedID, .fiveHour)
            XCTAssertTrue(popovers[0].anchorView === host)
            XCTAssertEqual(popovers[0].preferredEdge, .minY)
            let contentController = popovers[0].contentViewController
            views[0].pointerLocationForTesting = NSPoint(x: views[0].markerCenterX, y: 9)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            for minute in 1...3 {
                views[0].update(window: views[0].quotaWindow, now: now.addingTimeInterval(Double(minute) * 60),
                    cycleStart: OfficialQuotaUsagePrediction.inferredCycleStart(for: views[0].quotaWindow))
                XCTAssertTrue(views[0].isTooltipVisible)
                XCTAssertTrue(popovers[0].contentViewController === contentController)
                XCTAssertEqual(popovers[0].showCount, 1)
            }
            host.forwardHover(atHostPoint: NSPoint(x: 5, y: 5))
            XCTAssertTrue(views[0].hasPendingCloseForTesting)
            self.enterPace(views[0])
            views[0].firePendingCloseForTesting()
            XCTAssertTrue(views[0].isTooltipVisible)
            self.enterPace(views[1])
            XCTAssertFalse(views[0].isTooltipVisible)
            XCTAssertTrue(views[1].isTooltipVisible)
            XCTAssertEqual(views[0].markerLayerForTesting.bodyLayer.bounds.size, PaceTickLayer.restSize)
            XCTAssertEqual(views[1].markerLayerForTesting.bodyLayer.bounds.size, PaceTickLayer.hoverSize)
            XCTAssertEqual(host.sectionFocus.focusedID, .sevenDay)
            XCTAssertEqual(popovers[0].showCount, 1)
            XCTAssertEqual(popovers[1].showCount, 0)
            XCTAssertEqual((popovers[0].contentViewController as? QuotaPaceTooltipViewController)?.content,
                views[1].tooltipContent)
            XCTAssertNotNil(views[1].tooltipContent?.body)
            XCTAssertEqual(popovers[0].positioningRect, host.convert(views[1].markerHitRect, from: views[1]))
            host.forwardHover(atHostPoint: NSPoint(x: 5, y: 5))
            views[1].firePendingCloseForTesting()
            XCTAssertFalse(views[1].isTooltipVisible)
            self.enterPace(views[0])
            XCTAssertTrue(views[0].hasPendingShowForTesting)
            host.setMenuContentVisible(false)
            completed = true
            menu.cancelTracking()
        }
        RunLoop.main.add(probe, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: .zero, in: nil)
        probe.invalidate()
        host.setMenuContentVisible(false)
        XCTAssertTrue(completed, "The real menu must attach and execute the event-routing probe")
        for view in views {
            XCTAssertFalse(view.isTooltipVisible)
            XCTAssertFalse(view.hasPendingShowForTesting)
            XCTAssertFalse(view.hasPendingCloseForTesting)
        }
        menu.removeAllItems()
    }

    func testPaceRealDelaysReentryAndCloseInEventTrackingMode() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quota = paceWindow(reset: now.addingTimeInterval(9_000))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        let view = QuotaProgressPaceView(percentage: 50, window: quota,
            identity: OverviewNumericPresentation.identity(for: quota, provider: "Official"),
            now: now, colorConfiguration: .default,
            cycleStart: OfficialQuotaUsagePrediction.inferredCycleStart(for: quota))
        view.frame = NSRect(x: 10, y: 10, width: 200, height: 18)
        root.addSubview(view)
        let window = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = root
        ApplicationWindowPresentation.presentInBackground(window)
        defer { view.setMenuTracking(false); window.orderOut(nil) }
        root.layoutSubtreeIfNeeded()
        view.makePopoverForTesting = { QuotaPacePopoverProbe() }
        view.setMenuTracking(true)
        func runTracking(until deadline: Date) {
            while Date() < deadline { _ = RunLoop.current.run(mode: .eventTracking, before: deadline) }
        }
        func exitPace() { view.updateHover(at: NSPoint(x: -100, y: -100)) }
        enterPace(view)
        XCTAssertTrue(view.hasPendingShowForTesting)
        let entered = Date()
        runTracking(until: entered.addingTimeInterval(0.2))
        XCTAssertFalse(view.isTooltipVisible, "The 300ms delay must not fire early")
        runTracking(until: entered.addingTimeInterval(0.36))
        XCTAssertTrue(view.isTooltipVisible)
        exitPace()
        let exited = Date()
        runTracking(until: exited.addingTimeInterval(0.04))
        XCTAssertTrue(view.isTooltipVisible, "The unified 80ms exit debounce must not fire early")
        enterPace(view)
        runTracking(until: Date().addingTimeInterval(0.14))
        XCTAssertTrue(view.isTooltipVisible, "The cancelled old close must not dismiss after reentry")
        exitPace()
        runTracking(until: Date().addingTimeInterval(0.14))
        XCTAssertFalse(view.isTooltipVisible)
        enterPace(view)
        view.setMenuTracking(false)
        runTracking(until: Date().addingTimeInterval(0.36))
        XCTAssertFalse(view.isTooltipVisible)
        XCTAssertFalse(view.hasPendingShowForTesting)
        XCTAssertFalse(view.hasPendingCloseForTesting)
    }

    func testDismissalTracePolicyMonotonicCaptureAndNoContentLogging() throws {
        XCTAssertTrue(MenuDismissalTrace.isEnabled(bundleIdentifier: "com.huanmeng06.BalanceBar.dev"))
        XCTAssertTrue(MenuDismissalTrace.isEnabled(bundleIdentifier: "com.huanmeng06.BalanceBar.dev.test"))
        XCTAssertFalse(MenuDismissalTrace.isEnabled(bundleIdentifier: "com.huanmeng06.BalanceBar.app"))
        XCTAssertFalse(MenuDismissalTrace.isEnabled(bundleIdentifier: nil))
        var lines: [String] = []
        MenuDismissalTrace.sinkForTesting = { lines.append($0) }
        defer { MenuDismissalTrace.sinkForTesting = nil }
        let fixture = paceProbeFixture(now: Date(timeIntervalSince1970: 1_700_000_000))
        let host = fixture.host
        let window = PaceDismissalWindowProbe(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        ApplicationWindowPresentation.presentInBackground(window)
        defer { window.orderOut(nil); host.finishMenuDismissal() }
        let trace = try XCTUnwrap(MenuDismissalTrace.beginRound(menu: fixture.menu))
        host.setDismissalTrace(trace)
        host.quotaPaceAccount = OpenAIAccountPresentation(email: "secret@example.invalid")
        host.addSubview(NSTextField(labelWithString: "secret tooltip text"))
        host.setMenuContentVisible(true)
        host.layoutSubtreeIfNeeded()
        fixture.views[0].markerReduceMotionForTesting = false
        host.sectionFocus.sections.values.forEach {
            $0.focusReduceMotionForTesting = false
            $0.focusReduceTransparencyForTesting = false
        }
        enterPace(fixture.views[0])
        fixture.views[0].firePendingShowForTesting()
        fixture.views[0].updateHover(at: NSPoint(x: -100, y: -100))
        fixture.views[0].firePendingCloseForTesting()
        let exitStart = lines.count
        host.setMenuContentVisible(false)
        XCTAssertGreaterThan(lines.count, exitStart)
        XCTAssertFalse(lines[exitStart...].contains { $0.contains("event=filter.remove;") })
        host.finishMenuDismissal(beforeOpening: true)
        XCTAssertTrue(lines.contains { $0.contains("event=filter.remove;") })
        for event in ["marker.enter", "marker.leave", "hover.timer.fire", "popover.show.request",
                      "popover.willClose", "popover.didClose", "dismissal.begin", "dismissal.cleanup", "section.suspend"] {
            XCTAssertTrue(lines.contains { $0.contains("event=\(event);") }, event)
        }
        func field(_ line: String, _ key: String) -> String? {
            line.components(separatedBy: "; ").first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let sequences = lines.compactMap { field($0, "seq").flatMap(Int.init) }
        let times = lines.compactMap { field($0, "mono_ns").flatMap(UInt64.init) }
        XCTAssertEqual(sequences, Array(1...lines.count))
        XCTAssertEqual(times.count, lines.count)
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(lines.allSatisfy { field($0, "round") == String(trace.round) })
        XCTAssertTrue(lines.contains { $0.contains("sections=2;") && $0.contains("items=1;") })
        XCTAssertFalse(lines.joined().contains("secret"))
        XCTAssertFalse(lines.joined().contains("@example"))
    }

    func testOldPopoverCloseTraceKeepsOriginalRoundAfterReopen() throws {
        var lines: [String] = []
        MenuDismissalTrace.sinkForTesting = { lines.append($0) }
        defer { MenuDismissalTrace.sinkForTesting = nil }
        let fixture = paceProbeFixture(now: Date(timeIntervalSince1970: 1_700_000_000))
        let host = fixture.host
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        ApplicationWindowPresentation.presentInBackground(window)
        defer { window.orderOut(nil); host.finishMenuDismissal() }
        host.layoutSubtreeIfNeeded()
        let old = try XCTUnwrap(MenuDismissalTrace.beginRound(menu: fixture.menu))
        host.setDismissalTrace(old)
        host.setMenuContentVisible(true)
        let view = fixture.views[0]
        let departing = fixture.popovers[0]
        departing.delaysCloseCompletion = true
        enterPace(view)
        view.firePendingShowForTesting()
        view.dismissTooltip(animated: true)
        host.setMenuContentVisible(false)
        host.finishMenuDismissal(beforeOpening: true)
        let next = try XCTUnwrap(MenuDismissalTrace.beginRound(menu: fixture.menu))
        XCTAssertGreaterThan(next.round, old.round)
        host.setDismissalTrace(next)
        host.setMenuContentVisible(true)
        let newPopover = QuotaPacePopoverProbe()
        view.makePopoverForTesting = { newPopover }
        enterPace(view)
        view.firePendingShowForTesting()
        departing.completeClose()
        XCTAssertTrue(view.isTooltipVisible)
        let callback = try XCTUnwrap(lines.last { $0.contains("event=popover.didClose;") })
        XCTAssertTrue(callback.contains("round=\(old.round);"))
        XCTAssertTrue(callback.contains("host_round=\(next.round);"))
        XCTAssertTrue(callback.contains("active_matches=false;"))
    }

    func testWillMoveWithoutEarlierRemoveFreezesUntilExplicitNextOpen() throws {
        let fixture = paceProbeFixture(now: Date(timeIntervalSince1970: 1_700_000_000))
        let host = fixture.host
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        ApplicationWindowPresentation.presentInBackground(window)
        defer { window.orderOut(nil); host.finishMenuDismissal() }
        host.layoutSubtreeIfNeeded()
        host.setMenuContentVisible(true)
        let view = fixture.views[0]
        let other = try XCTUnwrap(host.sectionFocus.sections[.sevenDay])
        other.focusReduceTransparencyForTesting = false
        other.focusReduceMotionForTesting = false
        enterPace(view)
        host.sectionFocus.pendingTimerForTesting?.fire()
        let count = other.focusTransitionCountForTesting
        host.viewWillMove(toWindow: nil)
        view.viewWillMove(toWindow: nil)
        host.viewDidMoveToWindow()
        host.setPaceMenuTracking(false)
        XCTAssertTrue(host.isMenuDismissing)
        XCTAssertFalse(view.isMenuTracking)
        XCTAssertTrue(other.isFocusSuspended)
        XCTAssertFalse(other.contentFilters.isEmpty)
        XCTAssertEqual(other.focusTransitionCountForTesting, count)
        XCTAssertNil(host.sectionFocus.pendingTimerForTesting)
        // If the hidden-window notification is absent, next-open is the
        // explicit safe reset point. It must resume the same surviving views.
        host.setMenuContentVisible(true)
        XCTAssertFalse(host.isMenuDismissing)
        XCTAssertFalse(other.isFocusSuspended)
        XCTAssertTrue(other.contentFilters.isEmpty)
        XCTAssertEqual(other.alphaValue, 1)
        XCTAssertTrue(view.isMenuTracking)
        enterPace(view)
        XCTAssertTrue(view.hasPendingShowForTesting)
        host.setMenuContentVisible(false)
    }

    func testDefaultDismissalPolicyKeepsFocusAndShowButClosesWithoutAnimation() throws {
        XCTAssertEqual(PaceDismissalExperiment.resolve(bundleIdentifier: "com.huanmeng06.BalanceBar.dev", arguments: ["app"]), .popoverCloseOff)
        XCTAssertEqual(MenuHoverLinkHostView(frame: .zero).dismissalExperiment, .popoverCloseOff)
        let fixture = paceProbeFixture(now: Date(timeIntervalSince1970: 1_700_000_000), experiment: .current)
        let host = fixture.host
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        ApplicationWindowPresentation.presentInBackground(window)
        host.layoutSubtreeIfNeeded()
        host.setMenuContentVisible(true)
        defer { window.orderOut(nil); host.setMenuContentVisible(false); host.finishMenuDismissal() }
        fixture.views.forEach { $0.markerReduceMotionForTesting = false }
        host.sectionFocus.sections.values.forEach {
            $0.focusReduceMotionForTesting = false
            $0.focusReduceTransparencyForTesting = false
        }
        enterPace(fixture.views[0])
        fixture.views[0].firePendingShowForTesting()
        let other = try XCTUnwrap(host.sectionFocus.sections[.sevenDay])
        XCTAssertFalse(other.contentFilters.isEmpty)
        XCTAssertEqual(other.alphaValue, 0.5)
        XCTAssertEqual(fixture.popovers[0].showAnimationFlags, [true])
        fixture.views[0].updateHover(at: NSPoint(x: -100, y: -100))
        fixture.views[0].firePendingCloseForTesting()
        XCTAssertEqual(fixture.popovers[0].closeAnimationFlags, [false])
    }

    func testDismissalExperimentsAreDevelopmentOnlyAndKeepShowAnimation() throws {
        for mode in [PaceDismissalExperiment.full, .focusOff, .popoverCloseOff] {
            let args = ["app", "--pace-dismissal-experiment", mode.rawValue]
            XCTAssertEqual(PaceDismissalExperiment.resolve(bundleIdentifier: "com.huanmeng06.BalanceBar.dev", arguments: args), mode)
            XCTAssertEqual(PaceDismissalExperiment.resolve(bundleIdentifier: "com.huanmeng06.BalanceBar.app", arguments: args), .popoverCloseOff)
            let fixture = paceProbeFixture(now: Date(timeIntervalSince1970: 1_700_000_000))
            let host = fixture.host
            host.dismissalExperiment = mode
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            ApplicationWindowPresentation.presentInBackground(window)
            host.layoutSubtreeIfNeeded()
            host.setMenuContentVisible(true)
            defer { window.orderOut(nil); host.setMenuContentVisible(false); host.finishMenuDismissal() }
            fixture.views.forEach { $0.markerReduceMotionForTesting = false }
            host.sectionFocus.sections.values.forEach {
                $0.focusReduceMotionForTesting = false
                $0.focusReduceTransparencyForTesting = false
            }
            enterPace(fixture.views[0])
            fixture.views[0].firePendingShowForTesting()
            let other = try XCTUnwrap(host.sectionFocus.sections[.sevenDay])
            XCTAssertEqual(other.contentFilters.isEmpty, mode == .focusOff)
            XCTAssertEqual(other.alphaValue, mode == .focusOff ? 1 : 0.5)
            XCTAssertEqual(fixture.popovers[0].showAnimationFlags, [true])
            enterPace(fixture.views[1])
            XCTAssertTrue(fixture.views[1].isTooltipVisible)
            XCTAssertEqual(fixture.popovers[0].showCount, 1)
            fixture.views[1].updateHover(at: NSPoint(x: -100, y: -100))
            fixture.views[1].firePendingCloseForTesting()
            XCTAssertEqual(fixture.popovers[0].closeAnimationFlags, [mode != .popoverCloseOff])
        }
        XCTAssertEqual(PaceDismissalExperiment.resolve(bundleIdentifier: "com.huanmeng06.BalanceBar.dev", arguments: ["app", "--pace-dismissal-experiment"]), .popoverCloseOff)
        XCTAssertEqual(PaceDismissalExperiment.resolve(bundleIdentifier: "com.huanmeng06.BalanceBar.dev", arguments: ["app", "--pace-dismissal-experiment", "unknown"]), .popoverCloseOff)
    }

    func testMenuDismissalPreservesOutgoingFiltersAndCancelsAllHoverWork() throws {
        let fixture = paceProbeFixture(now: Date(timeIntervalSince1970: 1_700_000_000))
        let host = fixture.host
        let window = PaceDismissalWindowProbe(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        ApplicationWindowPresentation.presentInBackground(window)
        defer { window.orderOut(nil); host.finishMenuDismissal() }
        host.layoutSubtreeIfNeeded()
        host.setMenuContentVisible(true)
        let view = fixture.views[0]
        let other = try XCTUnwrap(host.sectionFocus.sections[.sevenDay])
        other.focusReduceMotionForTesting = false
        other.focusReduceTransparencyForTesting = false
        enterPace(view)
        view.firePendingShowForTesting()
        XCTAssertTrue(view.isTooltipVisible)
        XCTAssertFalse(other.contentFilters.isEmpty)
        // A pending exit's completion must not remove filters during menu fade.
        other.setFocusState(.normal, animated: true)
        let oldCompletion = try XCTUnwrap(other.focusRestoreCompletionForTesting)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(host.isMenuContentVisible)
        XCTAssertTrue(host.isMenuDismissing)
        XCTAssertFalse(view.isMenuTracking)
        XCTAssertFalse(view.isTooltipVisible)
        XCTAssertNil(host.sectionFocus.pendingTimerForTesting)
        XCTAssertFalse(other.contentFilters.isEmpty)
        XCTAssertNil(other.layer?.animation(forKey: "sectionFocus.radius"))
        oldCompletion()
        XCTAssertFalse(other.contentFilters.isEmpty)
        let alpha = other.alphaValue
        let registrations = host.monitorRegistrationCountForTesting
        // The controller's stop call, a late monitor and an accessibility event
        // must not restore or reinstall anything in an outgoing menu.
        host.setPaceMenuTracking(false)
        host.clearPaceHover()
        host.reconcilePaceMenuTracking()
        host.sectionFocus.refreshAccessibility()
        XCTAssertEqual(other.alphaValue, alpha)
        XCTAssertFalse(other.contentFilters.isEmpty)
        XCTAssertEqual(host.monitorRegistrationCountForTesting, registrations)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertTrue(host.isMenuDismissing, "A still-visible window must retain outgoing visuals")
        window.reportedOcclusionState = []
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertTrue(host.isMenuDismissing, "Occlusion is not proof the old window finished exiting")
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertFalse(host.isMenuDismissing)
        XCTAssertTrue(other.contentFilters.isEmpty)
        XCTAssertEqual(other.alphaValue, 1)
        XCTAssertEqual(view.markerLayerForTesting.bodyLayer.bounds.size, PaceTickLayer.restSize)
        ApplicationWindowPresentation.presentInBackground(window)
        host.setMenuContentVisible(true)
        XCTAssertTrue(view.isMenuTracking)
        enterPace(view)
        XCTAssertTrue(view.hasPendingShowForTesting)
        host.setMenuContentVisible(false)
        // Reopen before an old hidden-window notification: the notification
        // cannot clear the new interaction or wait a second entry delay.
        host.setMenuContentVisible(true)
        enterPace(view)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertTrue(view.hasPendingShowForTesting)
        host.setMenuContentVisible(false)
        host.removeFromSuperview()
        XCTAssertTrue(host.isMenuDismissing)
        window.orderOut(nil)
        host.finishMenuDismissal()
        XCTAssertFalse(host.isMenuDismissing)
        XCTAssertTrue(other.contentFilters.isEmpty)
    }

    func testAnimatedPopoverCloseStaysOwnedUntilCompletionAndCannotClearNewBubble() throws {
        let fixture = paceProbeFixture(now: Date(timeIntervalSince1970: 1_700_000_000))
        let window = NSWindow(contentRect: fixture.host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = fixture.host
        ApplicationWindowPresentation.presentInBackground(window)
        defer { fixture.host.setPaceMenuTracking(false); window.orderOut(nil) }
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.setPaceMenuTracking(true)
        let view = fixture.views[0]
        view.markerReduceMotionForTesting = false
        let departing = fixture.popovers[0]
        departing.delaysCloseCompletion = true
        enterPace(view)
        view.firePendingShowForTesting()
        view.updateHover(at: NSPoint(x: -100, y: -100))
        view.firePendingCloseForTesting()
        XCTAssertEqual(view.closingPopoverCountForTesting, 1)
        XCTAssertEqual(departing.closeAnimationFlags, [true])
        XCTAssertFalse(view.isTooltipVisible)
        let next = QuotaPacePopoverProbe()
        view.makePopoverForTesting = { next }
        enterPace(view)
        view.firePendingShowForTesting()
        departing.completeClose()
        XCTAssertEqual(view.closingPopoverCountForTesting, 0)
        XCTAssertTrue(view.isTooltipVisible, "An old didClose must not clear the new Popover")
        next.delaysCloseCompletion = true
        view.updateHover(at: NSPoint(x: -100, y: -100))
        view.firePendingCloseForTesting()
        fixture.host.clearPaceHover()
        fixture.host.clearPaceHover()
        XCTAssertEqual(next.closeAnimationFlags, [true], "Do not send a second close during native animation")
        XCTAssertFalse(next.animates)
        XCTAssertEqual(view.closingPopoverCountForTesting, 1)
        next.completeClose()
        XCTAssertEqual(view.closingPopoverCountForTesting, 0)
        enterPace(view)
        view.firePendingShowForTesting()
        next.completeClose() // Native transient outside-click dismissal.
        XCTAssertFalse(view.isTooltipVisible)
    }

    func testPaceUnifiedTimelineOrderingAndNativeAnimationPolicy() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = paceProbeFixture(now: now)
        let window = NSWindow(contentRect: fixture.host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = fixture.host
        ApplicationWindowPresentation.presentInBackground(window)
        defer { fixture.host.setPaceMenuTracking(false); window.orderOut(nil) }
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.setPaceMenuTracking(true)
        fixture.views.forEach { $0.markerReduceMotionForTesting = false }
        fixture.host.sectionFocus.sections.values.forEach {
            $0.focusReduceMotionForTesting = false
            $0.focusReduceTransparencyForTesting = false
        }
        let view = fixture.views[0]
        let probe = fixture.popovers[0]
        func run(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { _ = RunLoop.current.run(mode: .eventTracking, before: end) }
        }
        // Brief pass: neither background nor bubble is shown.
        view.updateHover(at: NSPoint(x: view.markerCenterX, y: 9))
        let oldEnter = try XCTUnwrap(fixture.host.sectionFocus.pendingTimerForTesting)
        view.updateHover(at: NSPoint(x: -100, y: -100))
        oldEnter.fire()
        run(0.14)
        XCTAssertNil(fixture.host.sectionFocus.focusedID)
        XCTAssertEqual(probe.showCount, 0)
        // A deliberately late focus callback must still allow a full blur phase.
        view.updateHover(at: NSPoint(x: view.markerCenterX, y: 9))
        Thread.sleep(forTimeInterval: 0.16) // Block only this test's main loop; no UI automation.
        XCTAssertNil(fixture.host.sectionFocus.focusedID)
        fixture.host.sectionFocus.pendingTimerForTesting?.fire()
        XCTAssertEqual(fixture.host.sectionFocus.focusedID, .fiveHour)
        let other = try XCTUnwrap(fixture.host.sectionFocus.sections[.sevenDay])
        let animation = try XCTUnwrap(other.layer?.animation(forKey: "sectionFocus.radius"))
        XCTAssertEqual(animation.duration, PaceHoverTiming.blurDuration)
        XCTAssertEqual(animation.timingFunction, CAMediaTimingFunction(name: .easeOut))
        run(0.1)
        XCTAssertFalse(view.isTooltipVisible, "Late focus must not catch up by showing in the same frame")
        run(0.12)
        XCTAssertTrue(view.isTooltipVisible)
        XCTAssertEqual(probe.showAnimationFlags, [true])
        // Refresh and transfer retain the same Popover and suppress resize/move animations.
        view.pointerLocationForTesting = NSPoint(x: view.markerCenterX, y: 9)
        let controller = probe.contentViewController
        view.update(window: view.quotaWindow, now: now)
        XCTAssertFalse(probe.animates)
        enterPace(fixture.views[1])
        XCTAssertTrue(fixture.views[1].isTooltipVisible)
        XCTAssertTrue(probe.contentViewController === controller)
        XCTAssertEqual(probe.showCount, 1)
        XCTAssertTrue(probe.closeAnimationFlags.isEmpty)
        XCTAssertFalse(probe.animates)
        XCTAssertNil(fixture.host.sectionFocus.pendingTimerForTesting)
        // Both exit operations begin after the same debounce.
        fixture.views[1].updateHover(at: NSPoint(x: -100, y: -100))
        run(0.04)
        XCTAssertTrue(fixture.views[1].isTooltipVisible)
        XCTAssertEqual(fixture.host.sectionFocus.focusedID, .sevenDay)
        run(0.07)
        XCTAssertNil(fixture.host.sectionFocus.focusedID)
        XCTAssertEqual(probe.closeAnimationFlags, [true])
        XCTAssertEqual(other.alphaValue, 1)
        XCTAssertEqual(other.layer?.animation(forKey: "sectionFocus.radius")?.duration, PaceHoverTiming.restoreDuration)
        XCTAssertFalse(DashboardTextTooltip.makePopover().animates, "Shared factory remains unchanged")
    }

    func testPaceUnifiedCancellationFreshEntryAndReduceMotion() throws {
        let fixture = paceProbeFixture(now: Date(timeIntervalSince1970: 1_700_000_000))
        let window = NSWindow(contentRect: fixture.host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = fixture.host
        ApplicationWindowPresentation.presentInBackground(window)
        defer { fixture.host.setPaceMenuTracking(false); window.orderOut(nil) }
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.setPaceMenuTracking(true)
        let view = fixture.views[0]
        view.markerReduceMotionForTesting = false
        var created: [QuotaPacePopoverProbe] = []
        view.makePopoverForTesting = { let p = QuotaPacePopoverProbe(); created.append(p); return p }
        func enter() { view.updateHover(at: NSPoint(x: view.markerCenterX, y: 9)) }
        func leave() { view.updateHover(at: NSPoint(x: -100, y: -100)) }
        enter()
        fixture.host.sectionFocus.pendingTimerForTesting?.fire() // Focus starts, bubble still pending.
        let staleShow = try XCTUnwrap(fixture.host.sectionFocus.pendingTimerForTesting)
        leave()
        staleShow.fire()
        XCTAssertTrue(created.isEmpty)
        enter()
        let reentry = try XCTUnwrap(fixture.host.sectionFocus.pendingTimerForTesting)
        XCTAssertGreaterThan(reentry.fireDate.timeIntervalSinceNow, PaceHoverTiming.tooltipDelay - 0.03)
        XCTAssertLessThanOrEqual(reentry.fireDate.timeIntervalSinceNow, PaceHoverTiming.tooltipDelay)
        view.firePendingShowForTesting()
        XCTAssertEqual(created.count, 1)
        leave()
        let staleClose = try XCTUnwrap(fixture.host.sectionFocus.pendingTimerForTesting)
        enter()
        staleClose.fire()
        XCTAssertTrue(view.isTooltipVisible)
        XCTAssertTrue(created[0].closeAnimationFlags.isEmpty)
        XCTAssertNil(fixture.host.sectionFocus.pendingTimerForTesting)
        leave()
        view.firePendingCloseForTesting()
        XCTAssertEqual(created[0].closeAnimationFlags, [true])
        enter()
        XCTAssertTrue(view.hasPendingShowForTesting, "A native close already requested is followed by a fresh entry")
        view.firePendingShowForTesting()
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created[1].showAnimationFlags, [true])
        // Runtime policy changes neither reset the timeline nor re-show the bubble.
        view.markerReduceMotionForTesting = true
        fixture.host.sectionFocus.refreshAccessibility()
        XCTAssertFalse(created[1].animates)
        leave()
        view.firePendingCloseForTesting()
        XCTAssertEqual(created[1].closeAnimationFlags, [false])
        enter()
        view.firePendingShowForTesting()
        XCTAssertEqual(created[2].showAnimationFlags, [false])
        view.markerReduceMotionForTesting = false
        fixture.host.sectionFocus.refreshAccessibility()
        XCTAssertEqual(created[2].showCount, 1)
        fixture.host.clearPaceHover()
        XCTAssertEqual(created[2].closeAnimationFlags, [false], "Lifecycle cleanup closes without animation")
        XCTAssertFalse(view.hasPendingShowForTesting)
        XCTAssertFalse(view.hasPendingCloseForTesting)
    }

    func testFullQuotaMarkerShowsPopoverAtRightEdgeForBothWindows() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for kind: OfficialQuotaWindow.Kind in [.fiveHour, .sevenDay] {
            let duration: TimeInterval = kind == .fiveHour ? 18_000 : 604_800
            for remaining in [100.0, 99.99995] {
                let quota = paceWindow(remaining: remaining, reset: now.addingTimeInterval(duration), kind: kind)
                let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 60))
                let section = OpenCodexMetricSectionView(layout: OpenCodexOverviewSectionLayout(
                    id: kind == .fiveHour ? .fiveHour : .sevenDay,
                    frame: NSRect(x: 0, y: 0, width: 220, height: 40), row: nil))
                host.addSubview(section)
                let view = QuotaProgressPaceView(percentage: remaining, window: quota,
                    identity: OverviewNumericPresentation.identity(for: quota, provider: "Official"),
                    now: now, colorConfiguration: .default)
                view.frame = NSRect(x: 10, y: 10, width: 200, height: 18)
                section.addSubview(view)
                let menu = NSMenu()
                let item = NSMenuItem()
                item.view = host
                menu.addItem(item)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                    backing: .buffered, defer: false)
                window.contentView = host
                ApplicationWindowPresentation.presentInBackground(window)
                defer {
                    host.setPaceMenuTracking(false)
                    window.orderOut(nil)
                    menu.removeAllItems()
                }
                host.layoutSubtreeIfNeeded()

                XCTAssertEqual(view.pace?.status, .unused)
                let content = try XCTUnwrap(view.tooltipContent)
                XCTAssertEqual(content.body, tr(.keyQuotaPaceBodyUnused))
                XCTAssertEqual(view.accessibilityLabel(),
                    [content.title, content.body].compactMap { $0 }.joined(separator: "\n"))
                XCTAssertEqual(view.markerCenterX, view.bounds.maxX - 1, accuracy: 0.001)
                XCTAssertEqual(view.markerHitRect.maxX, view.bounds.maxX)

                let popover = QuotaPacePopoverProbe()
                view.makePopoverForTesting = { popover }
                host.setPaceMenuTracking(true)
                let point = host.convert(NSPoint(x: view.bounds.maxX - 1, y: view.bounds.midY), from: view)
                host.forwardHover(atHostPoint: point)
                XCTAssertTrue(view.isHovered)
                XCTAssertTrue(view.hasPendingShowForTesting)
                view.firePendingShowForTesting()
                XCTAssertTrue(view.isTooltipVisible)
                XCTAssertEqual(popover.showCount, 1)
                XCTAssertEqual((popover.contentViewController as? QuotaPaceTooltipViewController)?.content, content)
                XCTAssertTrue(popover.anchorView === host)

                host.forwardHover(atHostPoint: NSPoint(x: 5, y: 5))
                view.firePendingCloseForTesting()
                XCTAssertFalse(view.isTooltipVisible)
            }
        }
    }

    func testPaceUpdateInvalidationAndCompactPredictionCopy() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quota = paceWindow(remaining: 60, reset: now.addingTimeInterval(11_160))
        let start = OfficialQuotaUsagePrediction.inferredCycleStart(for: quota)
        let view = QuotaProgressPaceView(percentage: 60, window: quota,
            identity: OverviewNumericPresentation.identity(for: quota, provider: "Official"),
            now: now, colorConfiguration: .default, cycleStart: start)
        let pace = try XCTUnwrap(view.pace)
        XCTAssertEqual(pace.status, .normal)
        XCTAssertEqual(QuotaPaceTooltipContent(pace: pace, prediction: view.prediction, resetAt: quota.resetAt,
            language: .simplifiedChinese, now: now, timeZone: TimeZone(secondsFromGMT: 0)!),
            QuotaPaceTooltipContent(title: "用得刚刚好", body: "和时间进度基本同步。"))
        let original = view.prediction
        view.update(window: quota, now: now.addingTimeInterval(60), cycleStart: start)
        XCTAssertNotEqual(view.prediction, original)
        view.update(window: quota, now: quota.resetAt!, cycleStart: start)
        XCTAssertNil(view.pace)
        XCTAssertNil(view.prediction)
        XCTAssertTrue(view.markerHitRect.isEmpty)
        XCTAssertEqual(view.accessibilityLabel(), "")
        view.update(window: quota, now: now)
        XCTAssertNotNil(view.tooltipContent?.body)
        XCTAssertEqual(view.accessibilityLabel(), [view.tooltipContent!.title, view.tooltipContent!.body!].joined(separator: "\n"))
        let unused = try XCTUnwrap(OfficialQuotaUsagePace.make(for: paceWindow(remaining: 100, reset: quota.resetAt!), now: now))
        XCTAssertEqual(QuotaPaceTooltipContent(pace: unused, prediction: nil, language: .simplifiedChinese).body, "这一轮额度还是满的。")
        XCTAssertEqual(QuotaPaceTooltipContent(pace: unused, prediction: nil, language: .english).body, "This cycle’s quota is still full.")
        let week = paceWindow(remaining: 50, reset: now.addingTimeInterval(302_400), kind: .sevenDay)
        view.update(window: week, now: now)
        XCTAssertNotNil(view.pace)
        XCTAssertNil(view.prediction)
        XCTAssertNotNil(view.tooltipContent?.body)
        let fastWeek = paceWindow(remaining: 20, reset: now.addingTimeInterval(302_400), kind: .sevenDay)
        view.update(window: fastWeek, now: now)
        XCTAssertEqual(view.pace?.status, .fast)
        XCTAssertNil(view.prediction)
        XCTAssertFalse(view.tooltipContent!.body!.contains(":"))
        let emptyWeek = paceWindow(remaining: 0, reset: now.addingTimeInterval(302_400), kind: .sevenDay)
        view.update(window: emptyWeek, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertNil(view.prediction)
        XCTAssertEqual(view.tooltipContent?.title, tr(.keyQuotaPaceStatusExhausted))
        XCTAssertTrue(view.tooltipContent!.body!.contains(":"), "Weekly reset time is factual and still available")
    }

    func testCompactPaceTooltipHasOnlyTitleAndOptionalSentenceAcrossAllLanguages() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for language in AppLanguage.allCases where language != .system {
            for remaining in [0.0, 40, 60, 80, 100] {
                let pace = try XCTUnwrap(OfficialQuotaUsagePace.make(for: paceWindow(remaining: remaining, reset: now.addingTimeInterval(11_160)), now: now))
                for prediction: OfficialQuotaUsagePrediction? in [nil, .runsOut(after: 10_260), .lastsUntilReset] {
                    let content = QuotaPaceTooltipContent(pace: pace, prediction: prediction, resetAt: now.addingTimeInterval(11_160), language: language,
                        now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
                    let controller = QuotaPaceTooltipViewController(content: content)
                    controller.loadViewIfNeeded()
                    let labels = controller.visibleLabelsForTesting
                    XCTAssertEqual(labels.map(\.stringValue), [content.title, try XCTUnwrap(content.body)])
                    XCTAssertEqual(labels.count, 2)
                    XCTAssertLessThanOrEqual(controller.contentSize.width, 260)
                    for label in labels {
                        XCTAssertTrue(controller.view.bounds.contains(label.convert(label.bounds, to: controller.view)))
                        XCTAssertEqual(label.superview!.convert(label.alignmentRect(forFrame: label.frame), to: controller.view).minX, 14, accuracy: 0.01)
                        XCTAssertEqual(controller.view.bounds.maxX - label.superview!.convert(label.alignmentRect(forFrame: label.frame), to: controller.view).maxX, 14, accuracy: 0.01)
                        XCTAssertEqual(label.maximumNumberOfLines, 0)
                        XCTAssertFalse(label.cell!.truncatesLastVisibleLine)
                        let measured = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 100_000))
                        XCTAssertGreaterThanOrEqual(label.frame.height, ceil(measured.height), language.rawValue)
                        XCTAssertFalse(label.stringValue.contains("%@"))
                        XCTAssertFalse(label.stringValue.contains("%1$@"))
                    }
                    let revision = controller.layoutRevision
                    controller.update(content: content)
                    XCTAssertEqual(controller.layoutRevision, revision)
                }
            }
        }
        let titleOnly = QuotaPaceTooltipViewController(content: QuotaPaceTooltipContent(title: "用量刚刚好", body: nil))
        titleOnly.loadViewIfNeeded()
        let label = try XCTUnwrap(titleOnly.visibleLabelsForTesting.first)
        XCTAssertEqual(label.stringValue, "用量刚刚好")
        XCTAssertLessThan(titleOnly.contentSize.width, 200)
        XCTAssertLessThan(titleOnly.contentSize.height, 76)
        XCTAssertGreaterThanOrEqual(label.frame.width, label.intrinsicContentSize.width)
        let compact = titleOnly.contentSize
        titleOnly.update(content: QuotaPaceTooltipContent(title: "用得有点快", body: "照这一轮的平均速度，大约明天 00:20 会用完，早于重置时间。"))
        XCTAssertEqual(titleOnly.visibleLabelsForTesting.count, 2)
        XCTAssertGreaterThan(titleOnly.contentSize.height, compact.height)
        titleOnly.update(content: QuotaPaceTooltipContent(title: "用量刚刚好", body: nil))
        XCTAssertEqual(titleOnly.visibleLabelsForTesting.count, 1)
        XCTAssertEqual(titleOnly.contentSize, compact)
    }

    func testPaceTitlesFollowRoundedDifferenceAndForecastOnlyFast() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(9000)
        let utc = TimeZone(secondsFromGMT: 0)!
        for (remaining, status) in [(44.0, OfficialQuotaUsagePace.Status.fast), (45, .normal), (55, .normal), (56, .slow)] {
            let pace = try XCTUnwrap(OfficialQuotaUsagePace.make(for: paceWindow(remaining: remaining, reset: reset), now: now))
            XCTAssertEqual(pace.status, status)
            let content = QuotaPaceTooltipContent(pace: pace, prediction: .runsOut(after: 6000), resetAt: reset,
                language: .simplifiedChinese, now: now, timeZone: utc)
            if status == .fast {
                XCTAssertEqual(content.title, "用得有点快")
                XCTAssertEqual(content.body, "照这一轮的平均速度，大约 23:55 会用完，早于重置时间。")
            } else {
                XCTAssertEqual(content.title, status == .normal ? "用得刚刚好" : "用得很从容")
                XCTAssertFalse(content.body!.contains("用完"))
                XCTAssertFalse(content.body!.contains("撑到"))
            }
        }
        let fast = try XCTUnwrap(OfficialQuotaUsagePace.make(for: paceWindow(remaining: 40, reset: reset), now: now))
        for prediction: OfficialQuotaUsagePrediction? in [nil, .lastsUntilReset, .runsOut(after: .nan), .runsOut(after: .infinity), .runsOut(after: -1), .runsOut(after: 0), .runsOut(after: 9000)] {
            let content = QuotaPaceTooltipContent(pace: fast, prediction: prediction, resetAt: reset,
                language: .simplifiedChinese, now: now, timeZone: utc)
            XCTAssertEqual(content.body, "比时间进度快一些，可以适当放慢。")
        }
        let nearReset = now.addingTimeInterval(70)
        let inconsistent = QuotaPaceTooltipContent(pace: fast, prediction: .runsOut(after: 60), resetAt: nearReset,
            language: .simplifiedChinese, now: now, timeZone: utc)
        XCTAssertEqual(inconsistent.body, "比时间进度快一些，可以适当放慢。", "Rounded time past reset must fall back")
        let exhausted = try XCTUnwrap(OfficialQuotaUsagePace.make(for: paceWindow(remaining: 0, reset: now.addingTimeInterval(540)), now: now))
        XCTAssertEqual(exhausted.status, .normal)
        XCTAssertEqual(QuotaPaceTooltipContent(pace: exhausted, prediction: nil, resetAt: reset,
            language: .simplifiedChinese, now: now, timeZone: utc),
            QuotaPaceTooltipContent(title: "额度已用完", body: "将在明天 00:43重置。"))
        for invalid: Date? in [nil, now, now.addingTimeInterval(-1), Date(timeIntervalSince1970: .infinity)] {
            XCTAssertEqual(QuotaPaceTooltipContent(pace: exhausted, prediction: nil, resetAt: invalid,
                language: .simplifiedChinese, now: now, timeZone: utc).body, "重置时间暂不可用。")
        }
        let tiny = try XCTUnwrap(OfficialQuotaUsagePace.make(for: paceWindow(remaining: 0.1, reset: now.addingTimeInterval(540)), now: now))
        XCTAssertEqual(tiny.roundedActual, 0)
        XCTAssertEqual(QuotaPaceTooltipContent(pace: tiny, prediction: nil, language: .simplifiedChinese).title, "用得刚刚好")
    }

    func testPaceFiveMinuteRoundingAndCalendarLabels() throws {
        let iso = ISO8601DateFormatter()
        func date(_ value: String) -> Date { iso.date(from: value)! }
        let utc = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-10-14T18:00:00Z")
        func rounded(_ value: String, relativeTo current: Date = now, zone: TimeZone = utc) -> Date {
            QuotaPaceTooltipContent.roundedExhaustionDate(date(value), now: current, timeZone: zone)!
        }
        XCTAssertEqual(rounded("2026-10-14T19:21:00Z"), date("2026-10-14T19:20:00Z"))
        XCTAssertEqual(rounded("2026-10-14T19:22:30Z"), date("2026-10-14T19:25:00Z"))
        XCTAssertEqual(rounded("2026-10-14T18:01:00Z"), date("2026-10-14T18:05:00Z"))
        XCTAssertNil(QuotaPaceTooltipContent.roundedExhaustionDate(now, now: now, timeZone: utc))
        XCTAssertNil(QuotaPaceTooltipContent.roundedExhaustionDate(Date(timeIntervalSince1970: .nan), now: now, timeZone: utc))
        let midnight = rounded("2026-10-14T23:58:00Z")
        XCTAssertEqual(QuotaPaceTooltipContent.displayTime(midnight, now: now, timeZone: utc, language: .simplifiedChinese), "明天 00:00")
        XCTAssertEqual(QuotaPaceTooltipContent.displayTime(date("2026-10-14T19:20:00Z"), now: now, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!, language: .simplifiedChinese), "03:20")
        XCTAssertEqual(QuotaPaceTooltipContent.displayTime(date("2026-10-16T14:00:00Z"), now: now, timeZone: utc, language: .simplifiedChinese), "周五 14:00")
        let crossYear = QuotaPaceTooltipContent.displayTime(date("2027-01-10T14:00:00Z"), now: date("2026-12-30T18:00:00Z"), timeZone: utc, language: .simplifiedChinese)
        XCTAssertTrue(crossYear.contains("2027"))
        XCTAssertTrue(crossYear.hasSuffix("14:00"))
        let ny = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(rounded("2026-03-08T06:58:00Z", relativeTo: date("2026-03-08T06:00:00Z"), zone: ny), date("2026-03-08T07:00:00Z"))
        XCTAssertEqual(rounded("2026-11-01T05:58:00Z", relativeTo: date("2026-11-01T05:00:00Z"), zone: ny), date("2026-11-01T06:00:00Z"))
        XCTAssertEqual(rounded("2026-11-01T06:21:00Z", relativeTo: date("2026-11-01T06:00:00Z"), zone: ny), date("2026-11-01T06:20:00Z"))
    }

    func testWeeklyThirtyMinuteRoundingCalendarAndForecastFallback() throws {
        let iso = ISO8601DateFormatter()
        func date(_ value: String) -> Date { iso.date(from: value)! }
        let utc = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-10-14T18:00:00Z")
        func rounded(_ value: String, now: Date = now, zone: TimeZone = utc) -> Date? {
            QuotaPaceTooltipContent.roundedExhaustionDate(date(value), now: now, timeZone: zone, windowKind: .sevenDay)
        }
        XCTAssertEqual(rounded("2026-10-14T19:14:00Z"), date("2026-10-14T19:00:00Z"))
        XCTAssertEqual(rounded("2026-10-14T19:15:00Z"), date("2026-10-14T19:30:00Z"))
        XCTAssertEqual(rounded("2026-10-14T19:02:00Z", now: date("2026-10-14T19:01:00Z")), date("2026-10-14T19:30:00Z"))
        XCTAssertEqual(rounded("2026-10-14T23:55:00Z"), date("2026-10-15T00:00:00Z"))
        let kathmandu = TimeZone(secondsFromGMT: 5 * 3600 + 45 * 60)!
        XCTAssertEqual(rounded("2026-10-14T13:29:00Z", now: date("2026-10-14T12:00:00Z"), zone: kathmandu), date("2026-10-14T13:15:00Z"))
        XCTAssertEqual(rounded("2026-10-14T13:30:00Z", now: date("2026-10-14T12:00:00Z"), zone: kathmandu), date("2026-10-14T13:45:00Z"))
        let ny = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(rounded("2026-03-08T06:58:00Z", now: date("2026-03-08T06:00:00Z"), zone: ny), date("2026-03-08T07:00:00Z"))
        XCTAssertEqual(rounded("2026-11-01T05:58:00Z", now: date("2026-11-01T05:00:00Z"), zone: ny), date("2026-11-01T06:00:00Z"))
        XCTAssertEqual(rounded("2026-11-01T06:15:00Z", now: date("2026-11-01T05:00:00Z"), zone: ny), date("2026-11-01T06:30:00Z"))
        let fast = OfficialQuotaUsagePace(actualRemaining: 40, expectedRemaining: 60, difference: -20, status: .fast)
        let tooLate = QuotaPaceTooltipContent(pace: fast, prediction: .runsOut(after: 4560), resetAt: now.addingTimeInterval(5100),
            windowKind: .sevenDay, language: .simplifiedChinese, now: now, timeZone: utc)
        XCTAssertEqual(tooLate.body, "比时间进度快一些，可以适当放慢。")
        let body = QuotaPaceTooltipContent(pace: fast, prediction: .runsOut(after: 158_400), resetAt: now.addingTimeInterval(302_400),
            windowKind: .sevenDay, language: .simplifiedChinese, now: now, timeZone: utc).body
        XCTAssertEqual(body, "照这一轮的平均速度，大约 周五 14:00 会用完，早于重置时间。")
        for language in AppLanguage.allCases where language != .system {
            for status: OfficialQuotaUsagePace.Status in [.unused, .fast, .normal, .slow] {
                let pace = OfficialQuotaUsagePace(actualRemaining: status == .unused ? 100 : 40,
                    expectedRemaining: 60, difference: -20, status: status)
                for prediction: OfficialQuotaUsagePrediction? in [nil, .runsOut(after: 158_400), .lastsUntilReset] {
                    let content = QuotaPaceTooltipContent(pace: pace, prediction: prediction,
                        resetAt: now.addingTimeInterval(302_400), windowKind: .sevenDay, language: language, now: now, timeZone: utc)
                    let controller = QuotaPaceTooltipViewController(content: content)
                    controller.loadViewIfNeeded()
                    XCTAssertLessThanOrEqual(controller.contentSize.width, 260)
                    for label in controller.visibleLabelsForTesting {
                        let fit = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 100_000))
                        XCTAssertGreaterThanOrEqual(label.frame.height, ceil(fit.height), language.rawValue)
                        XCTAssertFalse(label.cell!.truncatesLastVisibleLine)
                    }
                }
            }
        }
    }

    func testPaceContinuousRefreshKeepsPresentationAndSkipsIdenticalLayout() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quota = paceWindow(remaining: 40, reset: now.addingTimeInterval(9000))
        let view = QuotaProgressPaceView(percentage: 40, window: quota,
            identity: OverviewNumericPresentation.identity(for: quota, provider: "Official"), now: now,
            colorConfiguration: .default, cycleStart: now.addingTimeInterval(-9000))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
        let window = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = root
        view.frame = NSRect(x: 10, y: 10, width: 200, height: 18)
        root.addSubview(view)
        ApplicationWindowPresentation.presentInBackground(window)
        defer { view.setMenuTracking(false); window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        let probe = QuotaPacePopoverProbe()
        view.makePopoverForTesting = { probe }
        view.pointerLocationForTesting = NSPoint(x: view.markerCenterX, y: 9)
        view.setMenuTracking(true)
        view.updateHover(at: view.pointerLocationForTesting!)
        view.firePendingShowForTesting()
        let controller = try XCTUnwrap(probe.contentViewController as? QuotaPaceTooltipViewController)
        let revision = controller.layoutRevision
        let tracking = try XCTUnwrap(view.trackingAreas.first)
        view.update(window: quota, now: now, cycleStart: now.addingTimeInterval(-9000))
        XCTAssertEqual(controller.layoutRevision, revision)
        XCTAssertTrue(view.trackingAreas.first === tracking)
        for tick in 1...5 {
            view.update(window: quota, now: now.addingTimeInterval(Double(tick) * 60), cycleStart: now.addingTimeInterval(-9000))
            XCTAssertTrue(probe.contentViewController === controller)
            if tick == 1 { XCTAssertEqual(controller.layoutRevision, revision) }
            XCTAssertEqual(probe.contentSize, controller.contentSize)
            XCTAssertTrue(view.isTooltipVisible)
            XCTAssertFalse(view.hasPendingShowForTesting)
            XCTAssertEqual(probe.showCount, 1)
        }
        XCTAssertGreaterThan(controller.layoutRevision, revision)
        view.update(window: quota, now: now.addingTimeInterval(1200), cycleStart: now.addingTimeInterval(-9000))
        XCTAssertFalse(view.isTooltipVisible, "Moved marker no longer contains the stationary pointer")
        view.updateHover(at: NSPoint(x: view.markerCenterX, y: 9))
        XCTAssertTrue(view.hasPendingShowForTesting)
        view.update(window: paceWindow(remaining: 40, reset: now.addingTimeInterval(10_000)), now: now,
            cycleStart: now.addingTimeInterval(-8000))
        XCTAssertFalse(view.hasPendingShowForTesting, "A new cycle cancels the old pending tooltip")
        XCTAssertFalse(view.isTooltipVisible)
        view.invalidatePresentation()
        XCTAssertFalse(view.hasPendingShowForTesting)
    }

    func testWeeklyContinuousRefreshKeepsPresentationAndSkipsIdenticalLayout() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quota = paceWindow(remaining: 40, reset: now.addingTimeInterval(302_400), kind: .sevenDay)
        let view = QuotaProgressPaceView(percentage: 40, window: quota,
            identity: OverviewNumericPresentation.identity(for: quota, provider: "Official"), now: now,
            colorConfiguration: .default, cycleStart: now.addingTimeInterval(-302_400))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
        let window = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = root
        view.frame = NSRect(x: 10, y: 10, width: 200, height: 18)
        root.addSubview(view)
        ApplicationWindowPresentation.presentInBackground(window)
        defer { view.setMenuTracking(false); window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        let probe = QuotaPacePopoverProbe()
        view.makePopoverForTesting = { probe }
        view.pointerLocationForTesting = NSPoint(x: view.markerCenterX, y: 9)
        view.setMenuTracking(true)
        view.updateHover(at: view.pointerLocationForTesting!)
        view.firePendingShowForTesting()
        let controller = try XCTUnwrap(probe.contentViewController as? QuotaPaceTooltipViewController)
        let revision = controller.layoutRevision
        let tracking = try XCTUnwrap(view.trackingAreas.first)
        view.update(window: quota, now: now, cycleStart: now.addingTimeInterval(-302_400))
        XCTAssertEqual(controller.layoutRevision, revision)
        XCTAssertTrue(view.trackingAreas.first === tracking)
        for tick in 1...5 {
            let previousContent = controller.content
            let previousRevision = controller.layoutRevision
            view.update(window: quota, now: now.addingTimeInterval(Double(tick) * 60), cycleStart: now.addingTimeInterval(-302_400))
            if controller.content == previousContent { XCTAssertEqual(controller.layoutRevision, previousRevision) }
            XCTAssertTrue(probe.contentViewController === controller)
            XCTAssertEqual(probe.contentSize, controller.contentSize)
            XCTAssertTrue(view.isTooltipVisible)
            XCTAssertFalse(view.hasPendingShowForTesting)
            XCTAssertEqual(probe.showCount, 1)
        }
        view.update(window: quota, now: now.addingTimeInterval(3600), cycleStart: now.addingTimeInterval(-302_400))
        XCTAssertTrue(probe.contentViewController === controller)
        XCTAssertGreaterThan(controller.layoutRevision, revision)
        view.update(window: quota, now: now.addingTimeInterval(3660), cycleStart: nil)
        XCTAssertNil(view.prediction)
        XCTAssertTrue(view.isTooltipVisible)
        XCTAssertTrue(probe.contentViewController === controller)
        XCTAssertEqual(probe.showCount, 1, "Withholding prediction updates the existing bubble")
        XCTAssertEqual(view.accessibilityLabel(), [view.tooltipContent!.title, view.tooltipContent!.body!].joined(separator: "\n"))
        view.update(window: quota, now: now.addingTimeInterval(40_000), cycleStart: now.addingTimeInterval(-302_400))
        XCTAssertFalse(view.isTooltipVisible, "Moved marker no longer contains the stationary pointer")
        view.updateHover(at: NSPoint(x: view.markerCenterX, y: 9))
        XCTAssertTrue(view.hasPendingShowForTesting)
        view.update(window: paceWindow(remaining: 40, reset: now.addingTimeInterval(320_000), kind: .sevenDay), now: now,
            cycleStart: now.addingTimeInterval(-284_800))
        XCTAssertFalse(view.hasPendingShowForTesting, "A new cycle cancels the old pending tooltip")
        XCTAssertFalse(view.isTooltipVisible)
        view.invalidatePresentation()
        XCTAssertFalse(view.hasPendingShowForTesting)
    }

    func testPaceListenerRegistrationIsIdempotentAndReconcilesViewChanges() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = paceProbeFixture(now: now)
        let window = NSWindow(contentRect: fixture.host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = fixture.host
        fixture.host.setPaceMenuTracking(true)
        let count = fixture.host.monitorRegistrationCountForTesting
        for _ in 0..<10 { fixture.host.setPaceMenuTracking(true) }
        XCTAssertEqual(fixture.host.monitorRegistrationCountForTesting, count)
        fixture.views[1].removeFromSuperview()
        fixture.host.setPaceMenuTracking(true)
        XCTAssertEqual(fixture.host.monitorRegistrationCountForTesting, count + 1)
        fixture.host.setPaceMenuTracking(false)
        fixture.host.setPaceMenuTracking(false)
        XCTAssertEqual(fixture.host.monitorRegistrationCountForTesting, count + 1)
        window.orderOut(nil)
    }

    func testDashboardSectionsPreserveNavigationOrderAndMetadata() {
        let sections = DashboardSection.allCases

        XCTAssertEqual(sections.map(\.rawValue), Array(0..<5))
        XCTAssertEqual(sections.map(\.symbolName), [
            "gearshape.fill",
            "menubar.rectangle",
            "filemenu.and.selection",
            "slider.horizontal.3",
            "info.circle.fill"
        ])
        XCTAssertTrue(sections.allSatisfy { !$0.title.isEmpty })
        XCTAssertEqual(DashboardSection(rawValue: 2), .menu)
        XCTAssertNil(DashboardSection(rawValue: 5))
    }

    func testSettingsSectionSeparatorsMatchRowsAndPreserveSelectionRules() throws {
        let rows = [
            DashboardSettingsComponents.makeSettingsRow("First"),
            DashboardSettingsComponents.makeSettingsRow("Second"),
            DashboardSettingsComponents.makeSettingsRow("Third")
        ]
        var rowsStack: NSStackView?
        var separators: [NSView] = []
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Layout",
            rows: rows,
            onLayoutCreated: { stack, _, createdSeparators in
                rowsStack = stack
                separators = createdSeparators
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = section
        window.layoutIfNeeded()

        let stack = try XCTUnwrap(rowsStack)
        XCTAssertEqual(separators.count, rows.count - 1)
        assertSettingsSeparatorWidths(
            separators,
            rows: rows,
            matching: stack
        )

        window.setContentSize(NSSize(width: 680, height: 280))
        window.layoutIfNeeded()
        assertSettingsSeparatorWidths(
            separators,
            rows: rows,
            matching: stack
        )

        let singleRow = DashboardSettingsComponents.makeSettingsRow("Single")
        var singleSeparators: [NSView] = []
        _ = DashboardSettingsComponents.makeSettingsSection(
            "Single row",
            rows: [singleRow],
            onLayoutCreated: { _, _, createdSeparators in
                singleSeparators = createdSeparators
            }
        )
        XCTAssertTrue(singleSeparators.isEmpty)

        let selectiveRows = [
            DashboardSettingsComponents.makeSettingsRow("Visible"),
            DashboardSettingsComponents.makeSettingsRow("Hidden"),
            DashboardSettingsComponents.makeSettingsRow("Last")
        ]
        selectiveRows[1].isHidden = true
        var selectiveStack: NSStackView?
        var selectiveSeparators: [NSView] = []
        let selectiveSection = DashboardSettingsComponents.makeSettingsSection(
            "Selective",
            rows: selectiveRows,
            separatorIndices: [0],
            onLayoutCreated: { stack, _, createdSeparators in
                selectiveStack = stack
                selectiveSeparators = createdSeparators
            }
        )
        window.contentView = selectiveSection
        window.layoutIfNeeded()

        let selectiveRowsStack = try XCTUnwrap(selectiveStack)
        XCTAssertEqual(selectiveSeparators.count, 1)
        assertSettingsSeparatorWidths(
            selectiveSeparators,
            rows: selectiveRows,
            matching: selectiveRowsStack
        )
    }

    func testSettingsRowsAdaptToLocalizedSubtitleHeightAcrossWindowWidths() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        let fixtures: [(AppLanguage, String)] = [
            (.simplifiedChinese, "这是用于验证窗口缩放后副标题完整换行并同步更新卡片高度的长说明文字示例。"),
            (.traditionalChineseTaiwan, "這是用於驗證視窗縮放後副標題完整換行並同步更新卡片高度的長說明文字範例。"),
            (.traditionalChineseHongKong, "這是用於驗證視窗縮放後副標題完整換行並同步更新卡片高度的長說明文字範例。"),
            (.japanese, "これはウィンドウ幅の変更後も副題が完全に折り返され、カードの高さが更新されることを確認する説明文です。"),
            (.english, "This subtitle verifies resized-window wrapping and keeps the full settings text visible."),
            (.korean, "이 부제목은 창 너비를 바꾼 뒤에도 전체 설정 설명이 잘 줄바꿈되고 카드 높이가 갱신되는지 확인합니다."),
            (.spanish, "Este subtítulo comprueba que el texto completo de ajustes se ajuste al cambiar el ancho de la ventana."),
            (.german, "Dieser Untertitel prüft, dass der vollständige Einstellungstext bei geänderter Fensterbreite umbricht."),
            (.french, "Ce sous-titre vérifie que le texte complet des réglages s’adapte lorsque la largeur de la fenêtre change.")
        ]

        for (language, longSubtitle) in fixtures {
            AppLanguage.selected = language
            let subtitle = NSTextField(wrappingLabelWithString: longSubtitle)
            let control = NSSwitch()
            let longRow = DashboardSettingsComponents.makeSettingsRow(
                "Localized title",
                subtitle: longSubtitle,
                subtitleLabel: subtitle,
                control: control
            )
            let shortRow = DashboardSettingsComponents.makeSettingsRow("Short title")
            var rowsStack: NSStackView?
            var separators: [NSView] = []
            let section = DashboardSettingsComponents.makeSettingsSection(
                "Localized settings",
                rows: [longRow, shortRow],
                onLayoutCreated: { stack, _, createdSeparators in
                    rowsStack = stack
                    separators = createdSeparators
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 516, height: 360),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = section
            defer { window.orderOut(nil) }

            func layout(at width: CGFloat) throws -> (rowHeight: CGFloat, cardHeight: CGFloat) {
                layoutSettingsSection(section, in: window, width: width, height: 360)
                let stack = try XCTUnwrap(rowsStack)
                let card = try XCTUnwrap(stack.superview)
                return (longRow.frame.height, card.frame.height)
            }

            let narrow = try layout(at: 516)
            XCTAssertGreaterThan(narrow.rowHeight, 62, "(language) long subtitle should grow at narrow width")
            XCTAssertEqual(
                narrow.cardHeight,
                DashboardSettingsComponents.settingsSectionIntrinsicHeight(
                    rowsStack: try XCTUnwrap(rowsStack),
                    separators: separators
                ),
                accuracy: 0.5,
                "(language) card height must follow visible row and separator heights"
            )
            XCTAssertEqual(shortRow.frame.height, 62, accuracy: 0.5, "(language) short row minimum height")

            let nativeRow = try XCTUnwrap(longRow as? SettingsRowView)
            let subtitleFrame = subtitle.convert(subtitle.bounds, to: longRow)
            let labelsFrame = nativeRow.labelsStack.convert(nativeRow.labelsStack.bounds, to: longRow)
            XCTAssertTrue(longRow.bounds.insetBy(dx: 0, dy: -0.5).contains(labelsFrame), "(language) labels must stay in row")
            XCTAssertEqual(
                subtitle.lineBreakMode,
                language == .english || language == .spanish || language == .german || language == .french
                    ? .byWordWrapping
                    : .byCharWrapping,
                "(language) subtitle should use the script-appropriate wrapping mode"
            )
            XCTAssertLessThanOrEqual(
                subtitle.cell!.cellSize(
                    forBounds: NSRect(x: 0, y: 0, width: subtitle.bounds.width, height: .greatestFiniteMagnitude)
                ).height,
                subtitleFrame.height + 0.5,
                "(language) subtitle must fit its frame"
            )
            XCTAssertEqual(
                control.convert(control.bounds, to: longRow).midY,
                longRow.bounds.midY,
                accuracy: 0.5,
                "(language) control must stay centered"
            )
            XCTAssertEqual(separators.count, 1)
            XCTAssertEqual(separators[0].frame.width, rowsStack!.frame.width, accuracy: 0.5)

            let wide = try layout(at: 740)
            XCTAssertLessThan(wide.rowHeight, narrow.rowHeight, "(language) row should shrink after widening")
            XCTAssertLessThan(wide.cardHeight, narrow.cardHeight, "(language) card should shrink after widening")

            let narrowAgain = try layout(at: 516)
            XCTAssertEqual(narrowAgain.rowHeight, narrow.rowHeight, accuracy: 0.5, "(language) narrow layout must be reversible")
            XCTAssertEqual(narrowAgain.cardHeight, narrow.cardHeight, accuracy: 0.5, "(language) card height must be reversible")

            subtitle.stringValue = "Short subtitle"
            subtitle.invalidateIntrinsicContentSize()
            nativeRow.invalidateAfterContentChange()
            layoutSettingsSection(section, in: window, width: 516, height: 360)
            XCTAssertEqual(longRow.frame.height, 62, accuracy: 0.5, "(language) content changes must shrink the row")
            XCTAssertEqual(shortRow.frame.height, 62, accuracy: 0.5, "(language) sibling minimum height must remain stable")
        }
    }

    func testLocalizedSettingsTitlesWrapLikeSubtitlesAcrossLanguages() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        let fixtures: [(AppLanguage, String)] = [
            (.english, "Animate the menu bar icon while a task runs"),
            (.korean, "작업 실행 중 메뉴 막대 아이콘 애니메이션"),
            (.spanish, "Anima el icono de la barra de menús mientras se ejecuta una tarea"),
            (.german, "Menüleistensymbol während einer Aufgabe animieren"),
            (.french, "Animer l’icône de la barre des menus pendant une tâche")
        ]

        for (language, longTitle) in fixtures {
            AppLanguage.selected = language
            let control = NSSwitch()
            let row = DashboardSettingsComponents.makeSettingsRow(
                longTitle,
                subtitle: "Short subtitle",
                control: control
            )
            var rowsStack: NSStackView?
            let section = DashboardSettingsComponents.makeSettingsSection(
                "Localized titles",
                rows: [row],
                onLayoutCreated: { stack, _, _ in
                    rowsStack = stack
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = section
            defer { window.orderOut(nil) }

            func titleLabel() throws -> NSTextField {
                try XCTUnwrap(row as? SettingsRowView).titleLabel
            }

            func layout(at width: CGFloat) throws -> CGFloat {
                layoutSettingsSection(section, in: window, width: width, height: 260)
                _ = try XCTUnwrap(rowsStack)
                return row.frame.height
            }

            let narrowHeight = try layout(at: 300)
            let title = try titleLabel()
            XCTAssertFalse(title.usesSingleLineMode, "title must be multiline for \(language)")
            XCTAssertEqual(
                title.lineBreakMode,
                DashboardSettingsComponents.settingsSubtitleLineBreakMode(for: longTitle),
                "title wrapping mode for \(language)"
            )
            XCTAssertEqual(
                title.maximumNumberOfLines,
                DashboardSettingsComponents.settingsTitleMaximumNumberOfLines,
                "title line budget for \(language)"
            )
            XCTAssertTrue(title.cell?.wraps == true, "title cell wrapping for \(language)")
            XCTAssertFalse(title.cell?.isScrollable == true, "title cell must not scroll for \(language)")
            XCTAssertGreaterThan(narrowHeight, 62, "long title should grow its row for \(language)")
            XCTAssertLessThanOrEqual(
                title.cell!.cellSize(
                    forBounds: NSRect(
                        x: 0,
                        y: 0,
                        width: title.bounds.width,
                        height: .greatestFiniteMagnitude
                    )
                ).height,
                title.bounds.height + 0.5,
                "title must fit its wrapped frame for \(language)"
            )
            let nativeRow = try XCTUnwrap(row as? SettingsRowView)
            let labelsFrame = nativeRow.labelsStack.convert(nativeRow.labelsStack.bounds, to: row)
            let controlFrame = control.convert(control.bounds, to: row)
            XCTAssertFalse(labelsFrame.intersects(controlFrame), "text and control must not overlap for \(language)")
            if controlFrame.maxY > labelsFrame.minY + 0.5 {
                XCTAssertEqual(controlFrame.midY, row.bounds.midY, accuracy: 0.5)
            }

            let wideHeight = try layout(at: 740)
            XCTAssertLessThan(wideHeight, narrowHeight, "title row should shrink after widening for \(language)")
            let narrowAgainHeight = try layout(at: 300)
            XCTAssertEqual(narrowAgainHeight, narrowHeight, accuracy: 0.5)
        }
    }

    func testPreviewRowKeepsNaturalLabelGeometryBesideFixedAccessory() throws {
        let row = SettingsRowView(
            title: "当前布局",
            detail: "菜单栏会随服务商数据实时更新",
            accessoryView: FixedPreviewRowAccessory(),
            minimumHeight: DashboardMenuBarPage.previewRowHeight,
            verticalPadding: DashboardMenuBarPage.previewRowVerticalPadding
        )
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Preview fixture",
            rows: [row]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = section
        defer { window.orderOut(nil) }

        let nativeRow = try XCTUnwrap(row as? SettingsRowView)
        let widths: [CGFloat] = [720, 516, 320]
        var heights: [CGFloat] = []
        for width in widths {
            layoutSettingsSection(section, in: window, width: width, height: 360)
            heights.append(row.frame.height)

            XCTAssertEqual(nativeRow.contentStack.alignment, .centerY)
            XCTAssertEqual(nativeRow.titleLabel.bounds.height,
                           nativeRow.titleLabel.intrinsicContentSize.height,
                           accuracy: 1,
                           "title must keep its natural height at width \(width)")
            XCTAssertEqual(nativeRow.detailLabel.bounds.height,
                           nativeRow.detailLabel.intrinsicContentSize.height,
                           accuracy: 1,
                           "detail must keep its natural height at width \(width)")

            let titleFrame = nativeRow.titleLabel.convert(nativeRow.titleLabel.bounds, to: row)
            let detailFrame = nativeRow.detailLabel.convert(nativeRow.detailLabel.bounds, to: row)
            let labelsFrame = nativeRow.labelsStack.convert(nativeRow.labelsStack.bounds, to: row)
            let accessory = try XCTUnwrap(nativeRow.accessoryView)
            let accessoryFrame = accessory.convert(accessory.bounds, to: row)

            XCTAssertEqual(
                nativeRow.labelsStack.bounds.height,
                nativeRow.titleLabel.bounds.height
                    + SettingsRowView.labelSpacing
                    + nativeRow.detailLabel.bounds.height,
                accuracy: 1,
                "labels column must equal its two natural fields plus spacing at width \(width)"
            )
            XCTAssertGreaterThanOrEqual(
                titleFrame.minY,
                detailFrame.maxY - 0.5,
                "title and detail must stay ordered at width \(width)"
            )
            XCTAssertEqual(
                titleFrame.minY - detailFrame.maxY,
                SettingsRowView.labelSpacing,
                accuracy: 1,
                "title/detail visual gap must remain compact at width \(width)"
            )
            XCTAssertEqual(labelsFrame.midY, accessoryFrame.midY, accuracy: 0.5)
            XCTAssertEqual(labelsFrame.midY, row.bounds.midY, accuracy: 0.5)
            XCTAssertEqual(accessoryFrame.midY, row.bounds.midY, accuracy: 0.5)
            XCTAssertEqual(accessoryFrame.height, 42, accuracy: 0.5)
            XCTAssertTrue(row.bounds.insetBy(dx: 0, dy: -0.5).contains(labelsFrame))
            XCTAssertTrue(row.bounds.insetBy(dx: 0, dy: -0.5).contains(accessoryFrame))
            XCTAssertFalse(labelsFrame.intersects(accessoryFrame))
        }

        XCTAssertEqual(heights[0], DashboardSettingsComponents.standardRowHeight, accuracy: 0.5)
        XCTAssertGreaterThan(heights[2], heights[0], "narrow preview text must grow naturally")
    }

    func testSettingsRowsKeepControlsAtFourNaturalTextLinesAndMoveAfterWithoutTruncatingLabels() throws {
        let shortButton = NSButton(title: "Action", target: nil, action: nil)
        let thresholdButton = NSButton(title: "Action", target: nil, action: nil)
        let overflowButton = NSButton(title: "Action", target: nil, action: nil)
        let shortRow = DashboardSettingsComponents.makeSettingsRow(
            "Title",
            subtitle: "first line\nsecond line",
            control: shortButton
        )
        let thresholdRow = DashboardSettingsComponents.makeSettingsRow(
            "Title",
            subtitle: "first line\nsecond line\nthird line",
            control: thresholdButton
        )
        let overflowRow = DashboardSettingsComponents.makeSettingsRow(
            "Title",
            subtitle: "first line\nsecond line\nthird line\nfourth line",
            control: overflowButton
        )
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Line reflow",
            rows: [shortRow, thresholdRow, overflowRow]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = section
        defer { window.orderOut(nil) }
        layoutSettingsSection(section, in: window, width: 520, height: 420)

        func labels(in row: NSView) throws -> NSStackView {
            try XCTUnwrap(row as? SettingsRowView).labelsStack
        }

        func assertUncappedText(in row: NSView) throws {
            let nativeRow = try XCTUnwrap(row as? SettingsRowView)
            let title = nativeRow.titleLabel
            let subtitle = nativeRow.detailLabel
            XCTAssertEqual(title.maximumNumberOfLines, 0)
            XCTAssertEqual(subtitle.maximumNumberOfLines, 0)
            XCTAssertLessThanOrEqual(
                title.cell!.cellSize(
                    forBounds: NSRect(
                        x: 0,
                        y: 0,
                        width: title.bounds.width,
                        height: .greatestFiniteMagnitude
                    )
                ).height,
                title.bounds.height + 0.5
            )
            XCTAssertLessThanOrEqual(
                subtitle.cell!.cellSize(
                    forBounds: NSRect(
                        x: 0,
                        y: 0,
                        width: subtitle.bounds.width,
                        height: .greatestFiniteMagnitude
                    )
                ).height,
                subtitle.bounds.height + 0.5
            )
        }

        let shortLabels = try labels(in: shortRow)
        let thresholdLabels = try labels(in: thresholdRow)
        let overflowLabels = try labels(in: overflowRow)
        let shortLabelsFrame = shortLabels.convert(shortLabels.bounds, to: shortRow)
        let thresholdLabelsFrame = thresholdLabels.convert(thresholdLabels.bounds, to: thresholdRow)
        let overflowLabelsFrame = overflowLabels.convert(overflowLabels.bounds, to: overflowRow)
        let shortButtonFrame = shortButton.convert(shortButton.bounds, to: shortRow)
        let thresholdButtonFrame = thresholdButton.convert(thresholdButton.bounds, to: thresholdRow)
        let overflowButtonFrame = overflowButton.convert(overflowButton.bounds, to: overflowRow)

        XCTAssertGreaterThanOrEqual(shortButtonFrame.minX, shortLabelsFrame.maxX + 19.5)
        XCTAssertEqual(shortButtonFrame.midY, shortRow.bounds.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(thresholdButtonFrame.minX, thresholdLabelsFrame.maxX + 19.5)
        XCTAssertEqual(thresholdButtonFrame.midY, thresholdRow.bounds.midY, accuracy: 0.5)
        XCTAssertFalse(overflowLabelsFrame.intersects(overflowButtonFrame))
        XCTAssertGreaterThanOrEqual(overflowRow.frame.height, thresholdRow.frame.height)
        try assertUncappedText(in: shortRow)
        try assertUncappedText(in: thresholdRow)
        try assertUncappedText(in: overflowRow)
    }

    func testSettingsRowsProtectTextBeforeOrdinaryControlsAcrossLanguages() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        XCTAssertEqual(DashboardSettingsComponents.settingsTextLineReflowThreshold, 4)
        let languages: [AppLanguage] = [
            .simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .japanese,
            .english,
            .korean,
            .spanish,
            .german,
            .french
        ]

        for language in languages {
            AppLanguage.selected = language
            let title = [
                tr(.keyDashboardMenuBarPagePlayTheIconAnimationWhileATaskIsRunning, language: language),
                tr(.keyDashboardGeneralAndRefreshPagesBalanceUpdatesDuringTasks, language: language)
            ].joined(separator: " · ")
            let subtitle = [
                tr(.keyDashboardGeneralAndRefreshPagesRequestsTheCurrentProviderSBalanceWhileAnAgentIsRunning, language: language),
                tr(.keyDashboardGeneralAndRefreshPagesUpdateChannelDescription, language: language)
            ].joined(separator: " · ")

            for controlIndex in 0..<3 {
                let relay = DashboardPreferencePageRelay()
                let control: NSView
                switch controlIndex {
                case 0:
                    control = DashboardSettingsComponents.makeSwitch(
                        identifier: "lineBudgetSwitch",
                        isOn: true,
                        target: relay,
                        action: #selector(DashboardPreferencePageRelay.toggle(_:))
                    )
                case 1:
                    control = DashboardSettingsComponents.makePopUpButton(
                        identifier: "lineBudgetPopup",
                        items: [
                            DashboardSettingsComponents.PopUpItem(
                                title: [
                                    tr(.keyDashboardGeneralAndRefreshPagesRefreshNow, language: language),
                                    tr(.keyDashboardGeneralAndRefreshPagesRefreshNow, language: language)
                                ].joined(separator: " · "),
                                representedObject: "selected"
                            )
                        ],
                        selectedIndex: 0,
                        target: relay,
                        action: #selector(DashboardPreferencePageRelay.interval(_:))
                    )
                default:
                    let button = NSButton(
                        title: [
                            tr(.keyDashboardGeneralAndRefreshPagesRefreshNow, language: language),
                            tr(.keyDashboardGeneralAndRefreshPagesRefreshNow, language: language)
                        ].joined(separator: " · "),
                        target: relay,
                        action: #selector(DashboardPreferencePageRelay.manualRefresh(_:))
                    )
                    button.bezelStyle = .rounded
                    control = button
                }

                let row = DashboardSettingsComponents.makeSettingsRow(
                    title,
                    subtitle: subtitle,
                    control: control
                )
                let section = DashboardSettingsComponents.makeSettingsSection(
                    "Line budget",
                    rows: [row]
                )
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 280, height: 360),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = section
                defer { window.orderOut(nil) }
                layoutSettingsSection(section, in: window, width: 280, height: 360)

                let nativeRow = try XCTUnwrap(row as? SettingsRowView)
                let titleLabel = nativeRow.titleLabel
                let subtitleLabel = nativeRow.detailLabel
                let labelsFrame = nativeRow.labelsStack.convert(nativeRow.labelsStack.bounds, to: row)
                let controlFrame = control.convert(control.bounds, to: row)

                XCTAssertEqual(
                    titleLabel.maximumNumberOfLines,
                    DashboardSettingsComponents.settingsTitleMaximumNumberOfLines,
                    "title budget for \(language), control \(controlIndex)"
                )
                XCTAssertEqual(
                    subtitleLabel.maximumNumberOfLines,
                    DashboardSettingsComponents.settingsSubtitleMaximumNumberOfLines,
                    "subtitle budget for \(language), control \(controlIndex)"
                )
                XCTAssertLessThanOrEqual(
                    titleLabel.cell!.cellSize(
                        forBounds: NSRect(
                            x: 0,
                            y: 0,
                            width: titleLabel.bounds.width,
                            height: .greatestFiniteMagnitude
                        )
                    ).height,
                    titleLabel.bounds.height + 0.5,
                    "title must fit its measured frame for \(language), control \(controlIndex)"
                )
                XCTAssertLessThanOrEqual(
                    subtitleLabel.cell!.cellSize(
                        forBounds: NSRect(
                            x: 0,
                            y: 0,
                            width: subtitleLabel.bounds.width,
                            height: .greatestFiniteMagnitude
                        )
                    ).height,
                    subtitleLabel.bounds.height + 0.5,
                    "subtitle must fit its measured frame for \(language), control \(controlIndex)"
                )
                XCTAssertFalse(
                    labelsFrame.intersects(controlFrame),
                    "text and control must not overlap for \(language), control \(controlIndex)"
                )
                XCTAssertTrue(
                    row.bounds.insetBy(dx: 0, dy: -0.5).contains(labelsFrame),
                    "text must stay inside the row for \(language), control \(controlIndex)"
                )
                XCTAssertTrue(
                    row.bounds.insetBy(dx: 0, dy: -0.5).contains(controlFrame),
                    "control must stay inside the row for \(language), control \(controlIndex)"
                )
                let naturalWidth: CGFloat
                let minimumLabelWidth: CGFloat
                if let adaptive = control as? SettingsRowAccessoryLayout {
                    naturalWidth = adaptive.naturalAccessoryWidth
                    minimumLabelWidth = adaptive.minimumInlineLabelWidth
                } else {
                    naturalWidth = control.fittingSize.width
                    minimumLabelWidth = SettingsRowView.minimumInlineLabelWidth
                }
                if minimumLabelWidth > 0 {
                    let leftover = max(0, row.bounds.width - SettingsRowView.horizontalPadding * 2)
                        - max(1, naturalWidth)
                        - SettingsRowView.contentSpacing
                    if leftover + 0.5 < minimumLabelWidth {
                        XCTAssertLessThanOrEqual(
                            controlFrame.maxY,
                            labelsFrame.minY + 0.5,
                            "long control must use a dedicated row for \(language), control \(controlIndex)"
                        )
                    }
                }
            }
        }
    }

    func testCallerProvidedSubtitleLabelsStayMultilineForFutureRows() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english
        let longSubtitle = "This future settings entry has a deliberately long summary so a caller-created labelWithString label must wrap beside its control instead of truncating."
        let subtitle = NSTextField(labelWithString: longSubtitle)
        let row = DashboardSettingsComponents.makeSettingsRow(
            "Future entry",
            subtitle: longSubtitle,
            subtitleLabel: subtitle,
            control: NSSwitch()
        )
        var rowsStack: NSStackView?
        var separators: [NSView] = []
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Future settings",
            rows: [row],
            onLayoutCreated: { stack, _, createdSeparators in
                rowsStack = stack
                separators = createdSeparators
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 516, height: 260),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = section
        defer { window.orderOut(nil) }

        func layout(at width: CGFloat) throws -> (rowHeight: CGFloat, cardHeight: CGFloat) {
            layoutSettingsSection(section, in: window, width: width, height: 260)
            let stack = try XCTUnwrap(rowsStack)
            let card = try XCTUnwrap(stack.superview)
            return (row.frame.height, card.frame.height)
        }

        let narrow = try layout(at: 516)
        XCTAssertFalse(subtitle.usesSingleLineMode)
        XCTAssertEqual(subtitle.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(
            subtitle.maximumNumberOfLines,
            DashboardSettingsComponents.settingsSubtitleMaximumNumberOfLines
        )
        XCTAssertTrue(subtitle.cell?.wraps == true)
        XCTAssertGreaterThan(narrow.rowHeight, 62)
        let subtitleFrame = subtitle.convert(subtitle.bounds, to: row)
        XCTAssertLessThanOrEqual(
            subtitle.cell!.cellSize(
                forBounds: NSRect(
                    x: 0,
                    y: 0,
                    width: subtitle.bounds.width,
                    height: .greatestFiniteMagnitude
                )
            ).height,
            subtitleFrame.height + 0.5
        )
        XCTAssertEqual(
            narrow.cardHeight,
            DashboardSettingsComponents.settingsSectionIntrinsicHeight(
                rowsStack: try XCTUnwrap(rowsStack),
                separators: separators
            ),
            accuracy: 0.5
        )

        let wide = try layout(at: 740)
        XCTAssertLessThan(wide.rowHeight, narrow.rowHeight)
        XCTAssertLessThan(wide.cardHeight, narrow.cardHeight)

        subtitle.stringValue = "Short summary"
        subtitle.invalidateIntrinsicContentSize()
        (row as? SettingsRowView)?.invalidateAfterContentChange()
        row.needsLayout = true
        section.needsLayout = true
        let short = try layout(at: 516)
        XCTAssertEqual(short.rowHeight, 62, accuracy: 0.5)
        XCTAssertEqual(short.cardHeight, 62, accuracy: 0.5)
    }

    func testSemanticSubtitleGroupsUseScriptWrappingAndStayAtomicAcrossResizes() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let cases: [(AppLanguage, String, String)] = [
            (.simplifiedChinese, "这是一段很长的本地化前缀，会在语义后缀之前换行：", "宽度 - 10.0 pt"),
            (.traditionalChineseTaiwan, "這是一段很長的本地化前綴，會在語義後綴之前換行：", "寬度 - 10.0 pt"),
            (.traditionalChineseHongKong, "這是一段很長的本地化前綴，會在語義後綴之前換行：", "寬度 - 10.0 pt"),
            (.japanese, "これは意味のある接尾辞の前で折り返す長いローカライズ済み接頭辞です：", "幅 - 10.0 pt"),
            (.english, "This localized prefix deliberately wraps before the semantic suffix: ", "Width - 10.0 pt"),
            (.french, "Ce préfixe localisé volontairement long se replie avant le suffixe sémantique : ", "Largeur - 10.0 pt")
        ]

        func normalized(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{2060}", with: "")
                .replacingOccurrences(of: "\n", with: "")
        }

        func renderedLines(for field: NSTextField) -> [String] {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = field.lineBreakMode
            if #available(macOS 10.15, *) {
                paragraphStyle.lineBreakStrategy = field.lineBreakStrategy
            }
            let storage = NSTextStorage(
                string: field.stringValue,
                attributes: [
                    .font: field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .paragraphStyle: paragraphStyle
                ]
            )
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(
                size: NSSize(width: max(1, field.bounds.width), height: .greatestFiniteMagnitude)
            )
            textContainer.lineFragmentPadding = 0
            textContainer.lineBreakMode = field.lineBreakMode
            layoutManager.addTextContainer(textContainer)
            storage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: textContainer)

            var lines: [String] = []
            var glyphIndex = 0
            while glyphIndex < layoutManager.numberOfGlyphs {
                var glyphRange = NSRange()
                layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: &glyphRange,
                    withoutAdditionalLayout: true
                )
                let characterRange = layoutManager.characterRange(
                    forGlyphRange: glyphRange,
                    actualGlyphRange: nil
                )
                lines.append((field.stringValue as NSString).substring(with: characterRange))
                glyphIndex = NSMaxRange(glyphRange)
            }
            return lines
        }

        for (language, prefix, suffix) in cases {
            AppLanguage.selected = language
            let fullText = prefix + suffix
            let fullNSString = fullText as NSString
            let suffixRange = fullNSString.range(of: suffix)
            let atomicRange = NSRange(
                location: suffixRange.location + (suffix as NSString).range(of: " - 10.0 pt").location,
                length: (" - 10.0 pt" as NSString).length
            )
            let content = LocalizedSubtitle(
                text: fullText,
                semanticGroups: [suffixRange],
                atomicGroups: [atomicRange],
                lineBreakBeforeSemanticGroups: [suffixRange]
            )
            XCTAssertEqual(
                DashboardSettingsComponents.settingsSubtitleLineBreakMode(for: content),
                .byWordWrapping,
                "script wrapping for \(language)"
            )

            let groupWidth = suffix.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            let displayText = DashboardSettingsComponents.subtitleDisplayText(
                content,
                constrainedTo: groupWidth + 0.1,
                font: .systemFont(ofSize: 12)
            )
            XCTAssertTrue(
                displayText.contains("\u{00A0}"),
                "a fitting semantic group should use non-breaking layout spacing for \(language)"
            )
            XCTAssertTrue(
                displayText.contains("\n"),
                "the explicit semantic line break must remain independent of available width for \(language)"
            )
            XCTAssertTrue(
                displayText.split(separator: "\n").contains { normalized(String($0)) == normalized(suffix) },
                "the complete semantic suffix must be the second line for \(language)"
            )

            let label = DashboardSettingsComponents.makeSubtitleLabel(content)
            let control = NSSwitch()
            let row = DashboardSettingsComponents.makeSettingsRow(
                "Semantic subtitle",
                subtitleContent: content,
                subtitleLabel: label,
                control: control
            )
            var rowsStack: NSStackView?
            var separators: [NSView] = []
            let section = DashboardSettingsComponents.makeSettingsSection(
                "Semantic fixture",
                rows: [row],
                onLayoutCreated: { stack, _, createdSeparators in
                    rowsStack = stack
                    separators = createdSeparators
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 260),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = section
            defer { window.orderOut(nil) }

            func layout(at width: CGFloat) throws -> (rowHeight: CGFloat, cardHeight: CGFloat) {
                layoutSettingsSection(section, in: window, width: width, height: 260)
                let stack = try XCTUnwrap(rowsStack)
                let card = try XCTUnwrap(stack.superview)
                return (row.frame.height, card.frame.height)
            }

            let narrow = try layout(at: 280)
            let normalizedSuffix = normalized(suffix)
            XCTAssertEqual(label.font?.pointSize ?? 0, 12, accuracy: 0.01, "subtitle font for \(language)")
            XCTAssertTrue(label.textColor?.isEqual(NSColor.secondaryLabelColor) == true, "subtitle color for \(language)")
            XCTAssertFalse(label.isBezeled, "subtitle must not add a visual container for \(language)")
            XCTAssertFalse(label.drawsBackground, "subtitle must not add a background for \(language)")
            XCTAssertFalse(label.wantsLayer, "subtitle must not add a layer wrapper for \(language)")
            XCTAssertTrue(label.superview is NSStackView, "subtitle remains a normal row label for \(language)")
            let lines = renderedLines(for: label).map { normalized($0) }
            let logicalRenderedText = normalized(label.stringValue)
            XCTAssertTrue(
                logicalRenderedText.contains(normalized(prefix.trimmingCharacters(in: .whitespacesAndNewlines))),
                "the description must remain in the first semantic block for \(language): \(lines)"
            )
            XCTAssertTrue(
                renderedLines(for: label).contains { normalized($0).contains(normalizedSuffix) },
                "semantic suffix must remain one line for \(language): \(renderedLines(for: label))"
            )
            let nativeRow = try XCTUnwrap(row as? SettingsRowView)
            let labelsFrame = nativeRow.labelsStack.convert(nativeRow.labelsStack.bounds, to: row)
            let controlFrame = control.convert(control.bounds, to: row)
            XCTAssertFalse(labelsFrame.intersects(controlFrame), "text and control must not overlap for \(language)")
            if controlFrame.maxY > labelsFrame.minY + 0.5 {
                XCTAssertEqual(
                    controlFrame.midY,
                    row.bounds.midY,
                    accuracy: 0.5,
                    "slider/control stays centered for \(language)"
                )
            }
            XCTAssertEqual(
                narrow.cardHeight,
                DashboardSettingsComponents.settingsSectionIntrinsicHeight(
                    rowsStack: try XCTUnwrap(rowsStack),
                    separators: separators
                ),
                accuracy: 0.5
            )

            let wide = try layout(at: 560)
            XCTAssertLessThan(wide.rowHeight, narrow.rowHeight, "row shrinks when widened for \(language)")
            XCTAssertLessThan(wide.cardHeight, narrow.cardHeight, "card shrinks when widened for \(language)")
            let narrowAgain = try layout(at: 280)
            XCTAssertEqual(narrowAgain.rowHeight, narrow.rowHeight, accuracy: 0.5)
            XCTAssertEqual(narrowAgain.cardHeight, narrow.cardHeight, accuracy: 0.5)

            let updated = LocalizedSubtitle(
                text: prefix + suffix.replacingOccurrences(of: "10.0", with: "0.0"),
                semanticGroups: [NSRange(location: prefix.utf16.count, length: suffix.replacingOccurrences(of: "10.0", with: "0.0").utf16.count)],
                atomicGroups: [NSRange(location: prefix.utf16.count + (suffix.replacingOccurrences(of: "10.0", with: "0.0") as NSString).range(of: " - 0.0 pt").location, length: (" - 0.0 pt" as NSString).length)],
                lineBreakBeforeSemanticGroups: [NSRange(location: prefix.utf16.count, length: suffix.replacingOccurrences(of: "10.0", with: "0.0").utf16.count)]
            )
            DashboardSettingsComponents.updateSubtitleLabel(label, with: updated)
            row.needsLayout = true
            section.needsLayout = true
            _ = try layout(at: 280)
            XCTAssertTrue(normalized(label.stringValue).contains("0.0 pt"))
        }

        let longSuffix = "This semantic suffix is intentionally longer than one complete line before - 10.0 pt"
        let longText = "Prefix: " + longSuffix
        let longRange = (longText as NSString).range(of: longSuffix)
        let longAtomicRange = NSRange(
            location: longRange.location + (longSuffix as NSString).range(of: " - 10.0 pt").location,
            length: (" - 10.0 pt" as NSString).length
        )
        let longContent = LocalizedSubtitle(
            text: longText,
            semanticGroups: [longRange],
            atomicGroups: [longAtomicRange],
            lineBreakBeforeSemanticGroups: [longRange]
        )
        let longDisplay = DashboardSettingsComponents.subtitleDisplayText(
            longContent,
            constrainedTo: 90,
            font: .systemFont(ofSize: 12)
        )
        XCTAssertTrue(
            normalized(longDisplay).contains("- 10.0 pt"),
            "an oversized semantic group must retain its atomic numeric suffix"
        )
        XCTAssertTrue(
            longDisplay.contains("\n"),
            "an oversized suffix may wrap normally only after the complete suffix starts on line two"
        )
    }

    func testSettingsMeasurementCachesIgnoreSameRegimeWidthSweepsAndViewportOrigin() throws {
        let shortRow = DashboardSettingsComponents.makeSettingsRow(
            "Short title",
            subtitle: "Short subtitle",
            control: NSSwitch()
        )
        let peerRow = DashboardSettingsComponents.makeSettingsRow("Peer")
        var rowsStack: NSStackView?
        let section = DashboardSettingsComponents.makeSettingsSection(
            "Cache",
            rows: [shortRow, peerRow],
            onLayoutCreated: { stack, _, _ in
                rowsStack = stack
            }
        )
        let page = DashboardSettingsComponents.makeSettingsPage([section])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = page
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        SettingsRowView.flushPendingWrappingHeightCommits(in: page)
        window.layoutIfNeeded()

        DashboardSettingsLayoutMetrics.reset()
        for offset in 0..<24 {
            window.setContentSize(NSSize(width: 640 - CGFloat(offset), height: 520))
            window.layoutIfNeeded()
            SettingsRowView.flushPendingWrappingHeightCommits(in: page)
            window.layoutIfNeeded()
        }

        XCTAssertLessThan(
            DashboardSettingsLayoutMetrics.textLineMeasurements,
            8,
            "same-regime width steps must reuse wrapping ranges instead of rebuilding TextKit"
        )
        XCTAssertLessThan(
            DashboardSettingsLayoutMetrics.preferredHeightMeasurements,
            8,
            "short rows already at the height floor must not refit on every width step"
        )
        XCTAssertLessThan(
            DashboardSettingsLayoutMetrics.cardHeightMeasurements,
            8,
            "card height aggregation must not run on every live-resize width step"
        )
        XCTAssertLessThan(
            DashboardSettingsLayoutMetrics.controlFittingMeasurements,
            8,
            "control fitting size is independent of row width"
        )
        XCTAssertEqual(shortRow.frame.height, 62, accuracy: 0.5)
        XCTAssertEqual(peerRow.frame.height, 62, accuracy: 0.5)

        let scrollView = try XCTUnwrap(findScrollView(in: page))
        DashboardSettingsLayoutMetrics.reset()
        scrollView.contentView.bounds.origin = CGPoint(x: 0, y: 40)
        scrollView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        XCTAssertEqual(
            DashboardSettingsLayoutMetrics.textLineMeasurements,
            0,
            "viewport origin changes must not remeasure text"
        )
        XCTAssertEqual(
            DashboardSettingsLayoutMetrics.preferredHeightMeasurements,
            0,
            "viewport origin changes must not remeasure row height"
        )
        XCTAssertEqual(
            DashboardSettingsLayoutMetrics.cardHeightMeasurements,
            0,
            "viewport origin changes must not recompute card height"
        )

        let card = try XCTUnwrap(rowsStack?.superview)
        XCTAssertEqual(card.layerContentsRedrawPolicy, .onSetNeedsDisplay)
    }

    func testSettingsLayoutRemeasuresWhenWrappingBreakpointOrContentChanges() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .german
        let longTitle = "Menüleistensymbol während einer Aufgabe animieren und den vollständigen Text anzeigen"
        let row = DashboardSettingsComponents.makeSettingsRow(
            longTitle,
            subtitle: "Kurzbeschreibung die bei schmaler Breite umbrechen muss, damit die Zeilenhöhe wächst.",
            control: NSSwitch()
        )
        let section = DashboardSettingsComponents.makeSettingsSection("Breakpoint", rows: [row])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = section
        defer { window.orderOut(nil) }

        func layout(at width: CGFloat) -> CGFloat {
            layoutSettingsSection(section, in: window, width: width, height: 360)
            return row.frame.height
        }

        let wideHeight = layout(at: 760)
        DashboardSettingsLayoutMetrics.reset()
        let narrowHeight = layout(at: 280)
        XCTAssertGreaterThan(narrowHeight, wideHeight, "crossing a wrapping breakpoint must grow the row")
        XCTAssertEqual(
            DashboardSettingsLayoutMetrics.textLineMeasurements,
            0,
            "legacy wrapping-cache measurements must stay at the 0-trace sentinel"
        )
        XCTAssertEqual(
            DashboardSettingsLayoutMetrics.preferredHeightMeasurements,
            0,
            "legacy preferred-row-height measurements must stay at the 0-trace sentinel"
        )
        XCTAssertEqual(
            DashboardSettingsLayoutMetrics.cardHeightMeasurements,
            0,
            "legacy card-height measurements must stay at the 0-trace sentinel"
        )

        let wideAgain = layout(at: 760)
        XCTAssertEqual(wideAgain, wideHeight, accuracy: 0.5)

        let nativeRow = try XCTUnwrap(row as? SettingsRowView)
        let subtitle = nativeRow.detailLabel
        DashboardSettingsLayoutMetrics.reset()
        subtitle.stringValue = "Short"
        subtitle.invalidateIntrinsicContentSize()
        nativeRow.invalidateAfterContentChange()
        row.needsLayout = true
        section.needsLayout = true
        layoutSettingsSection(section, in: window, width: 760, height: 360)
        XCTAssertEqual(
            DashboardSettingsLayoutMetrics.preferredHeightMeasurements,
            0,
            "content changes must not re-enter the removed preferred-height engine"
        )
        XCTAssertEqual(row.frame.height, 62, accuracy: 0.5)
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func layoutSettingsSection(
        _ section: NSView,
        in window: NSWindow,
        width: CGFloat,
        height: CGFloat
    ) {
        window.setContentSize(NSSize(width: width, height: height))
        window.layoutIfNeeded()
        section.layoutSubtreeIfNeeded()
        SettingsRowView.flushPendingWrappingHeightCommits(in: section)
        window.layoutIfNeeded()
        section.layoutSubtreeIfNeeded()
    }

    func testSourceListTreePreservesNavigationOrderWithoutProviderOrRefresh() {
        let roots = DashboardSidebarNode.makeNavigationTree()
        XCTAssertEqual(roots.map(\.isGroup), [false, true, true])
        XCTAssertEqual(roots[0].section, .general)
        XCTAssertEqual(roots[1].group, .appearance)
        XCTAssertEqual(roots[1].children.compactMap(\.section), [.menuBar, .menu])
        XCTAssertEqual(roots[2].group, .system)
        XCTAssertEqual(roots[2].children.compactMap(\.section), [.advanced, .about])
        XCTAssertEqual(
            roots.flatMap { node -> [DashboardSection] in
                if let section = node.section { return [section] }
                return node.children.compactMap(\.section)
            },
            Array(DashboardSection.allCases)
        )
        XCTAssertTrue(roots.allSatisfy { node in
            node.title != tr(.keyDashboardGeneralAndRefreshPagesRefresh)
                && node.children.allSatisfy { $0.title != tr(.keyDashboardGeneralAndRefreshPagesRefresh) }
        })
    }

    func testQuotaProgressClampsValuesAndPreservesColorBoundaries() {
        XCTAssertEqual(QuotaProgressView(percentage: -1).percentage, 0)
        XCTAssertEqual(QuotaProgressView(percentage: 101).percentage, 100)

        XCTAssertTrue(QuotaProgressView.progressColor(for: 0).isEqual(NSColor.systemRed))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 9.99).isEqual(NSColor.systemRed))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 10).isEqual(NSColor.systemOrange))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 24.99).isEqual(NSColor.systemOrange))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 25).isEqual(NSColor.systemYellow))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 50).isEqual(NSColor.systemYellow))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 50.01).isEqual(NSColor.systemGreen))
    }

    func testQuotaProgressTrailingFillGrowsFromTheRight() throws {
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 5)
        XCTAssertNil(
            QuotaProgressView.fillRect(in: bounds, percentage: 0, fillOrigin: .trailing)
        )
        XCTAssertNil(
            QuotaProgressView.fillRect(in: bounds, percentage: 0, fillOrigin: .leading)
        )
        let trailingHalf = try XCTUnwrap(
            QuotaProgressView.fillRect(
                in: bounds,
                percentage: 50,
                fillOrigin: .trailing
            )
        )
        XCTAssertEqual(trailingHalf.maxX, 100, accuracy: 0.001)
        XCTAssertEqual(trailingHalf.width, 50, accuracy: 0.001)
        XCTAssertEqual(trailingHalf.minX, 50, accuracy: 0.001)
        let leadingHalf = try XCTUnwrap(
            QuotaProgressView.fillRect(
                in: bounds,
                percentage: 50,
                fillOrigin: .leading
            )
        )
        XCTAssertEqual(leadingHalf.minX, 0, accuracy: 0.001)
        XCTAssertEqual(leadingHalf.width, 50, accuracy: 0.001)
        let trailingStart = try XCTUnwrap(
            QuotaProgressView.fillRect(
                in: bounds,
                percentage: 1,
                fillOrigin: .trailing
            )
        )
        XCTAssertEqual(trailingStart.maxX, 100, accuracy: 0.001)
        XCTAssertEqual(trailingStart.width, 5, accuracy: 0.001)

        let view = QuotaProgressView(percentage: 0, fillOrigin: .trailing)
        XCTAssertEqual(view.fillOrigin, .trailing)
        XCTAssertEqual(view.colorPercentage, 100)
        view.setPercentage(80, animated: false)
        XCTAssertEqual(view.percentage, 80)
        XCTAssertEqual(view.colorPercentage, 20)
        XCTAssertEqual(view.fillRatio, 0.8, accuracy: 0.0001)
    }

    func testQuotaProgressSetPercentageUpdatesFillRatioWithoutAnimation() {
        let view = QuotaProgressView(percentage: 84)
        XCTAssertEqual(view.percentage, 84)
        XCTAssertEqual(view.fillRatio, 0.84, accuracy: 0.0001)

        view.setPercentage(71, animated: false)
        XCTAssertEqual(view.percentage, 71)
        XCTAssertEqual(view.fillRatio, 0.71, accuracy: 0.0001)

        view.setPercentage(71, animated: true)
        XCTAssertEqual(view.percentage, 71)
        XCTAssertEqual(view.fillRatio, 0.71, accuracy: 0.0001)
    }

    func testLunaReserveCardShowsLocalizedStatusRemainingResetAndCollapsesWithoutProgress() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let card = LunaReserveCardView()
        card.update(
            quota: LunaReserveQuota(
                status: .available,
                remaining: 45,
                reset: "1h30m"
            )
        )
        let fields: (String) -> NSTextField? = { identifier in
            func find(in view: NSView) -> NSTextField? {
                for child in view.subviews {
                    if child.identifier?.rawValue == identifier, let field = child as? NSTextField {
                        return field
                    }
                    if let field = find(in: child) { return field }
                }
                return nil
            }
            return find(in: card)
        }

        XCTAssertEqual(fields("lunaReserveTitle")?.stringValue, tr(.keyLunaReserveTitle))
        XCTAssertEqual(fields("lunaReserveStatus")?.stringValue, tr(.keyLunaReserveStatusAvailable))
        XCTAssertEqual(
            fields("lunaReserveRemaining")?.stringValue,
            tr(.keyLunaReserveRemainingValue, arguments: ["45"])
        )
        XCTAssertEqual(
            fields("lunaReserveReset")?.stringValue,
            tr(.keyLunaReserveResetValue, arguments: ["1h30m"])
        )

        card.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(descendantViews(of: card, as: QuotaProgressView.self).count, 1)
        let progressHost = try XCTUnwrap(
            descendantViews(of: card, as: NSView.self).first {
                $0.identifier?.rawValue == "lunaReserveProgressHost"
            }
        )
        XCTAssertFalse(progressHost.isHidden)
        XCTAssertEqual(progressHost.frame.height, 6, accuracy: 0.5)

        card.update(
            quota: LunaReserveQuota(
                status: .unavailable,
                remaining: nil,
                reset: nil
            )
        )
        XCTAssertEqual(fields("lunaReserveStatus")?.stringValue, tr(.keyLunaReserveStatusUnavailable))
        XCTAssertEqual(fields("lunaReserveRemaining")?.stringValue, tr(.keyLunaReserveRemainingUnavailable))
        XCTAssertEqual(fields("lunaReserveReset")?.stringValue, tr(.keyLunaReserveResetUnavailable))
        XCTAssertTrue(descendantViews(of: card, as: QuotaProgressView.self).isEmpty)
        card.layoutSubtreeIfNeeded()
        XCTAssertTrue(progressHost.isHidden)
        XCTAssertEqual(progressHost.frame.height, 0, accuracy: 0.5)

        card.update(
            quota: LunaReserveQuota(
                status: .loading,
                remaining: nil,
                reset: nil
            )
        )
        XCTAssertEqual(fields("lunaReserveStatus")?.stringValue, tr(.keyLunaReserveStatusLoading))
        XCTAssertEqual(fields("lunaReserveRemaining")?.stringValue, tr(.keyLunaReserveRemainingUnavailable))
        XCTAssertEqual(fields("lunaReserveReset")?.stringValue, tr(.keyLunaReserveResetUnavailable))
        XCTAssertTrue(descendantViews(of: card, as: QuotaProgressView.self).isEmpty)
        card.layoutSubtreeIfNeeded()
        XCTAssertTrue(progressHost.isHidden)
        XCTAssertEqual(progressHost.frame.height, 0, accuracy: 0.5)

        card.update(
            quota: LunaReserveQuota(
                status: .available,
                remaining: 45,
                reset: "1h30m"
            )
        )
        card.layoutSubtreeIfNeeded()
        XCTAssertFalse(progressHost.isHidden)
        XCTAssertEqual(progressHost.frame.height, 6, accuracy: 0.5)

        card.showsProgressBar = false
        card.update(
            quota: LunaReserveQuota(
                status: .available,
                remaining: 45,
                reset: "1h30m"
            )
        )
        card.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendantViews(of: card, as: QuotaProgressView.self).isEmpty)
        XCTAssertTrue(progressHost.isHidden)
        XCTAssertEqual(progressHost.frame.height, 0, accuracy: 0.5)
    }

    func testInlineRangeLinkStylesOnlyThePhraseAndActivatesOnThatRange() {
        let field = InlineRangeLinkTextField()
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 40)
        var activations = 0
        field.setContent(
            "Beta: restart BalanceBar to fix it",
            linkPhrase: "restart BalanceBar",
            onActivate: { activations += 1 }
        )
        field.layout()

        XCTAssertTrue(field.hasLink)
        XCTAssertEqual(
            field.linkRange,
            ("Beta: restart BalanceBar to fix it" as NSString).range(of: "restart BalanceBar")
        )
        XCTAssertFalse(field.linkHitRect.isEmpty)

        let attributed = field.attributedStringValue
        let linkColor = attributed.attribute(
            .foregroundColor,
            at: field.linkRange.location,
            effectiveRange: nil
        ) as? NSColor
        let bodyColor = attributed.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(linkColor, NSColor.linkColor)
        XCTAssertEqual(bodyColor, NSColor.secondaryLabelColor)
        XCTAssertNil(
            attributed.attribute(.underlineStyle, at: field.linkRange.location, effectiveRange: nil)
        )

        field.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: 4, y: field.bounds.midY)
        ))
        XCTAssertEqual(activations, 0)

        let beforePhrase = NSPoint(x: field.linkHitRect.minX - 20, y: field.linkHitRect.midY)
        XCTAssertFalse(
            field.linkHitRects.contains { $0.contains(beforePhrase) },
            "same-line text before the phrase must stay outside the glyph hit fragments"
        )
        field.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: beforePhrase))
        XCTAssertEqual(activations, 0)
        XCTAssertLessThan(field.linkHitRect.width, field.bounds.width * 0.7)

        let phraseRect = field.linkHitRects.first { !$0.isEmpty } ?? field.linkHitRect
        field.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: phraseRect.midX, y: phraseRect.midY)
        ))
        XCTAssertEqual(activations, 1)
    }

    func testInlineRangeLinkHitTestingStaysOnChineseRestartPhrase() {
        let field = InlineRangeLinkTextField()
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 96)
        field.preferredMaxLayoutWidth = 280
        var activations = 0
        let text = DashboardMenuBarPage.animationModeDescription(
            mode: .efficient,
            language: .simplifiedChinese
        )
        let phrase = DashboardMenuBarPage.animationModeRestartLinkPhrase(language: .simplifiedChinese)
        field.setContent(text, linkPhrase: phrase, onActivate: { activations += 1 })
        field.layout()

        XCTAssertEqual(phrase, "重启 BalanceBar")
        XCTAssertTrue(text.contains("时候"))
        XCTAssertTrue(field.hasLink)
        XCTAssertFalse(field.linkHitRects.isEmpty)
        XCTAssertLessThan(field.linkHitRect.width, field.bounds.width)

        let beforePhrase = NSPoint(x: field.linkHitRect.minX - 16, y: field.linkHitRect.midY)
        XCTAssertTrue(field.bounds.contains(beforePhrase) || beforePhrase.x >= 0)
        XCTAssertFalse(
            field.linkHitRects.contains { $0.contains(beforePhrase) },
            "gray text on the same line as 重启 BalanceBar must not be inside the link"
        )
        field.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: beforePhrase))
        XCTAssertEqual(activations, 0)

        let phraseRect = field.linkHitRects.first { !$0.isEmpty } ?? field.linkHitRect
        field.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: phraseRect.midX, y: phraseRect.midY)
        ))
        XCTAssertEqual(activations, 1)
    }

    func testDashboardTextTooltipLayoutKeepsShortHintsCompactAndWrapsLongHints() throws {
        let font = DashboardTextTooltip.font
        let short = DashboardTextTooltipLayout.make(for: "codex-reset.com", font: font)
        XCTAssertFalse(short.wraps)
        XCTAssertLessThan(
            short.contentSize.width,
            AccountEmailTooltipLayout.minimumTextWidth
        )
        XCTAssertLessThanOrEqual(short.textWidth, DashboardTextTooltipLayout.maximumTextWidth)
        XCTAssertEqual(
            short.textHeight,
            max(
                ceil(font.ascender - font.descender + 2),
                ceil(("codex-reset.com" as NSString).size(withAttributes: [.font: font]).height)
            ),
            accuracy: 0.001
        )

        let shortController = DashboardTextTooltipViewController(text: "codex-reset.com")
        shortController.loadViewIfNeeded()
        XCTAssertEqual(shortController.view.frame.size, short.contentSize)
        let shortLabel = try XCTUnwrap(shortController.view.subviews.first as? NSTextField)
        XCTAssertNotEqual(shortLabel.lineBreakMode, .byWordWrapping)
        XCTAssertLessThan(shortController.view.frame.width, 160)

        let longHint = tr(
            .keyCodexBankedResetProbabilityHint,
            arguments: ["2026-09-13 22:35"],
            language: .simplifiedChinese
        )
        let long = DashboardTextTooltipLayout.make(for: longHint, font: font)
        XCTAssertTrue(long.wraps)
        XCTAssertEqual(long.textWidth, DashboardTextTooltipLayout.maximumTextWidth)
        XCTAssertGreaterThan(long.textHeight, short.textHeight)
        XCTAssertEqual(
            long.contentSize.width,
            DashboardTextTooltipLayout.maximumTextWidth
                + DashboardTextTooltipLayout.horizontalInset * 2
        )
        XCTAssertGreaterThan(long.contentSize.height, short.contentSize.height)

        let longController = DashboardTextTooltipViewController(text: longHint)
        longController.loadViewIfNeeded()
        XCTAssertEqual(longController.view.frame.size, long.contentSize)
        XCTAssertLessThanOrEqual(
            longController.view.frame.width,
            DashboardTextTooltipLayout.maximumTextWidth
                + DashboardTextTooltipLayout.horizontalInset * 2
        )
        let longLabel = try XCTUnwrap(longController.view.subviews.first as? NSTextField)
        XCTAssertFalse(longLabel is InlineRangeLinkTextField)
        XCTAssertEqual(longLabel.stringValue, longHint)
        XCTAssertEqual(longLabel.textColor, NSColor.labelColor)
        let hostRange = (longHint as NSString).range(of: "codex-reset.com")
        XCTAssertNotEqual(hostRange.location, NSNotFound)
        XCTAssertNil(
            longLabel.attributedStringValue.attribute(
                .link,
                at: hostRange.location,
                effectiveRange: nil
            )
        )
        XCTAssertEqual(longLabel.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(longLabel.maximumNumberOfLines, 0)
        XCTAssertEqual(longLabel.preferredMaxLayoutWidth, long.textWidth)

        for language in AppLanguage.allCases where language != .system {
            let localizedHint = tr(
                .keyCodexBankedResetProbabilityHint,
                arguments: ["2026-09-13 22:35"],
                language: language
            )
            let layout = DashboardTextTooltipLayout.make(for: localizedHint, font: font)
            XCTAssertTrue(layout.wraps, "hint should wrap for \(language.rawValue)")
            XCTAssertEqual(layout.textWidth, DashboardTextTooltipLayout.maximumTextWidth)
            XCTAssertGreaterThan(
                layout.textHeight,
                short.textHeight,
                "wrapped hint height for \(language.rawValue)"
            )
        }
        XCTAssertEqual(AccountEmailTextField.tooltipDelay, 0.15, accuracy: 0.001)
    }

    func testForecastTooltipColorsResolveAgainstDisplayAppearanceAfterCreation() throws {
        let content = DashboardForecastTooltipContent(title: "Official reset signal", body: "Body text",
            source: "Source", disclaimer: "Disclaimer")
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        for creationName in appearances {
            let creation = try XCTUnwrap(NSAppearance(named: creationName))
            var controller: DashboardForecastTooltipViewController!
            creation.performAsCurrentDrawingAppearance {
                controller = DashboardForecastTooltipViewController(content: content)
                controller.loadViewIfNeeded()
            }
            let labels = controller.view.subviews.compactMap { $0 as? NSTextField }
            XCTAssertEqual(labels.count, 4)
            for displayName in appearances + [.aqua, .darkAqua, .aqua] {
                controller.view.appearance = try XCTUnwrap(NSAppearance(named: displayName))
                for (index, label) in labels.enumerated() {
                    var actual: NSColor!
                    var expected: NSColor!
                    label.effectiveAppearance.performAsCurrentDrawingAppearance {
                        actual = label.textColor?.usingColorSpace(.deviceRGB)
                        expected = (index < 2 ? NSColor.labelColor : NSColor.secondaryLabelColor).usingColorSpace(.deviceRGB)
                    }
                    let color = try XCTUnwrap(actual)
                    let semantic = try XCTUnwrap(expected)
                    XCTAssertEqual(color.redComponent, semantic.redComponent, accuracy: 0.001)
                    XCTAssertEqual(color.greenComponent, semantic.greenComponent, accuracy: 0.001)
                    XCTAssertEqual(color.blueComponent, semantic.blueComponent, accuracy: 0.001)
                    XCTAssertEqual(color.alphaComponent, semantic.alphaComponent, accuracy: 0.001)
                    if index == 1 {
                        let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        if displayName == .aqua || displayName == .accessibilityHighContrastAqua {
                            XCTAssertLessThan(brightness, 0.5, "Body must not remain white after dark creation")
                        } else {
                            XCTAssertGreaterThan(brightness, 0.5, "Body must not remain black after light creation")
                        }
                    }
                }
            }
        }
    }

    func testForecastTooltipHasHierarchyAndFitsEveryLanguage() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-07T09:21:00Z"))
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        for language in AppLanguage.allCases where language != .system {
            let content = StatusItemController.codexResetForecastTooltip(
                for: .demo(updatedAt: date), language: language, now: date, timeZone: timeZone
            )
            let controller = DashboardForecastTooltipViewController(content: content)
            controller.loadViewIfNeeded()
            let fields = controller.view.subviews.compactMap { $0 as? NSTextField }
            XCTAssertEqual(fields.count, 4)
            XCTAssertEqual(fields.map(\.stringValue), [content.title, content.body, content.source, content.disclaimer])
            XCTAssertEqual(fields.map { $0.font?.pointSize }, [13, 12, 12, 11])
            XCTAssertEqual(fields[0].font, .systemFont(ofSize: 13, weight: .semibold))
            XCTAssertEqual(fields[2].textColor, .secondaryLabelColor)
            XCTAssertEqual(fields[3].textColor, .secondaryLabelColor)
            XCTAssertEqual(fields[0].frame.minY - fields[1].frame.maxY, 5, accuracy: 0.001)
            XCTAssertEqual(fields[1].frame.minY - fields[2].frame.maxY, 10, accuracy: 0.001)
            XCTAssertEqual(fields[2].frame.minY - fields[3].frame.maxY, 10, accuracy: 0.001)
            for field in fields {
                XCTAssertTrue(controller.view.bounds.contains(field.frame), language.rawValue)
                let needed = try XCTUnwrap(field.cell).cellSize(forBounds: field.bounds).height
                XCTAssertGreaterThanOrEqual(field.frame.height, needed, language.rawValue)
                XCTAssertFalse(field.cell?.truncatesLastVisibleLine ?? true)
                XCTAssertFalse(field.stringValue.contains("\n"))
            }
            XCTAssertLessThanOrEqual(controller.view.frame.width, 386)
            XCTAssertTrue(content.source.contains("codex-reset.com"))
            if language == .simplifiedChinese {
                XCTAssertEqual(content.title, "24 小时内重置概率")
                XCTAssertEqual(content.source, "来源：codex-reset.com · 更新于 10月7日 09:21")
                XCTAssertLessThanOrEqual(fields[2].frame.height, 20, "Chinese source must fit one line")
            }
        }
    }

    func testStrongSignalTooltipExplainsSignalSeparatelyInEveryLanguage() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var forecast = CodexResetForecast.demo(updatedAt: date)
        for language in AppLanguage.allCases where language != .system {
            let ordinary = StatusItemController.codexResetForecastTooltip(for: forecast, language: language, now: date)
            forecast.officialSignal = CodexResetOfficialSignal(probability: .percent(93))
            let signal = StatusItemController.codexResetForecastTooltip(for: forecast, language: language, now: date)
            XCTAssertNotEqual(signal.title, ordinary.title, language.rawValue)
            XCTAssertNotEqual(signal.body, ordinary.body, language.rawValue)
            XCTAssertEqual(signal.source, ordinary.source, language.rawValue)
            if language == .simplifiedChinese { XCTAssertEqual(signal.title, "官方重置信号") }
            let controller = DashboardForecastTooltipViewController(content: signal)
            controller.loadViewIfNeeded()
            for field in controller.view.subviews.compactMap({ $0 as? NSTextField }) {
                XCTAssertTrue(controller.view.bounds.contains(field.frame), language.rawValue)
                XCTAssertFalse(field.cell?.truncatesLastVisibleLine ?? true)
                XCTAssertGreaterThanOrEqual(field.frame.height, try XCTUnwrap(field.cell).cellSize(forBounds: field.bounds).height, language.rawValue)
            }
            forecast.officialSignal = nil
        }
    }

    func testCountdownTooltipExplainsResetWindowInEveryLanguage() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var forecast = CodexResetForecast.demo(updatedAt: date)
        forecast.officialSignal = CodexResetOfficialSignal(
            probability: .percent(93),
            targetAt: date.addingTimeInterval(3_600),
            publishedAt: date.addingTimeInterval(-3_600)
        )
        for language in AppLanguage.allCases where language != .system {
            let content = StatusItemController.codexResetForecastTooltip(
                for: forecast, language: language, now: date, timeZone: timeZone
            )
            XCTAssertEqual(
                content.title,
                tr(.keyCodexBankedResetWindowDeadlineCountdown, language: language),
                language.rawValue
            )
            XCTAssertEqual(
                content.body,
                tr(.keyCodexResetSignalWindowTooltipBody, language: language),
                language.rawValue
            )
            XCTAssertEqual(
                content.disclaimer,
                tr(.keyCodexResetSignalWindowTooltipDisclaimer, language: language),
                language.rawValue
            )
            XCTAssertNotEqual(
                content.disclaimer,
                tr(.keyCodexResetSignalTooltipDisclaimer, language: language),
                language.rawValue
            )
            let controller = DashboardForecastTooltipViewController(content: content)
            controller.loadViewIfNeeded()
            for field in controller.view.subviews.compactMap({ $0 as? NSTextField }) {
                XCTAssertTrue(controller.view.bounds.contains(field.frame), language.rawValue)
                XCTAssertFalse(field.cell?.truncatesLastVisibleLine ?? true, language.rawValue)
                XCTAssertGreaterThanOrEqual(
                    field.frame.height,
                    try XCTUnwrap(field.cell).cellSize(forBounds: field.bounds).height,
                    language.rawValue
                )
            }
        }
    }

    func testForecastTooltipKeepsYearForOlderUpdatesAndUnknownDate() throws {
        let formatter = ISO8601DateFormatter()
        let date = try XCTUnwrap(formatter.date(from: "2025-10-07T09:21:00Z"))
        let now = try XCTUnwrap(formatter.date(from: "2026-10-07T09:21:00Z"))
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let older = StatusItemController.codexResetForecastTooltip(
            for: .demo(updatedAt: date), language: .simplifiedChinese, now: now, timeZone: zone
        )
        XCTAssertTrue(older.source.contains("2025年10月7日 09:21"))
        let missing = StatusItemController.codexResetForecastTooltip(
            for: .unavailable, language: .simplifiedChinese, now: now, timeZone: zone
        )
        XCTAssertTrue(missing.source.hasSuffix("更新于 --"))
    }

    func testHoverLinkHoverHintSetsNativeTooltip() {
        let link = HoverLinkTextField(text: "24%")
        XCTAssertEqual(link.hoverHint, "")
        XCTAssertNil(link.toolTip)
        link.hoverHint = "数据来源：codex-reset.com"
        XCTAssertEqual(link.toolTip, "数据来源：codex-reset.com")
        link.hoverHint = ""
        XCTAssertNil(link.toolTip)
        XCTAssertFalse(link.isHoverHintVisible)
    }

    func testHoverLinkDelayedHintCancelsBeforeFireAndDoesNotUseNativeTooltip() {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let link = HoverLinkTextField(text: tr(.keyCodexBankedResetProbabilityPrefix))
        link.frame = NSRect(x: 8, y: 2, width: 200, height: 20)
        link.hoverHintDelay = OpenCodexCardLayout.bankedResetProbabilityHoverHintDelay
        link.hoverHint = "codex-reset.com"
        host.addSubview(link)
        link.layout()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(host)
        ApplicationWindowPresentation.presentInBackground(window)
        defer { window.orderOut(nil) }
        host.track(link)
        XCTAssertEqual(link.hoverHintDelay, 0.5, accuracy: 0.001)
        XCTAssertNil(link.toolTip)
        XCTAssertEqual(AccountEmailTextField.tooltipDelay, 0.15, accuracy: 0.001)

        let glyphPoint = host.convert(link.visibleTextHitRect.center, from: link)
        host.forwardHover(atHostPoint: glyphPoint)
        XCTAssertTrue(link.isHoverHintScheduled)
        XCTAssertFalse(link.isHoverHintVisible)
        XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))

        host.forwardHover(atHostPoint: glyphPoint)
        XCTAssertTrue(link.isHoverHintScheduled)
        XCTAssertFalse(link.isHoverHintVisible)

        let blankPoint = host.convert(
            NSPoint(x: link.visibleTextHitRect.maxX + 12, y: link.visibleTextHitRect.midY),
            from: link
        )
        host.forwardHover(atHostPoint: blankPoint)
        XCTAssertFalse(link.isHoverHintScheduled)
        XCTAssertFalse(link.isHoverHintVisible)

        host.forwardHover(atHostPoint: glyphPoint)
        XCTAssertTrue(link.isHoverHintScheduled)
        link.firePendingHoverHintForTesting()
        XCTAssertFalse(link.isHoverHintScheduled)
        XCTAssertNil(link.toolTip)

        var activations = 0
        link.onActivate = { activations += 1 }
        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: link.visibleTextHitRect.center))
        XCTAssertEqual(activations, 1)

        host.removeFromSuperview()
        XCTAssertFalse(link.isHoverHintScheduled)
        XCTAssertFalse(link.isHoverHintVisible)
    }

    func testForecastSourceTimeRefreshPreservesHintButMeaningChangeCancelsIt() {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let link = HoverLinkTextField(text: "83%")
        link.frame = NSRect(x: 8, y: 2, width: 200, height: 20)
        link.hoverHintDelay = 0.5
        let first = DashboardForecastTooltipContent(title: "Source", body: "Forecast", source: "11:00", disclaimer: "Hint")
        link.updateForecastTooltipContent(first)
        host.addSubview(link)
        link.layout()
        host.track(link)
        let point = host.convert(link.visibleTextHitRect.center, from: link)
        host.forwardHover(atHostPoint: point)
        XCTAssertTrue(link.isHoverHintScheduled)
        link.updateForecastTooltipContent(first)
        XCTAssertTrue(link.isHoverHintScheduled)
        // Only the update time moved: keep the pending hint; it presents the latest content.
        let latest = DashboardForecastTooltipContent(title: "Source", body: "Forecast", source: "11:05", disclaimer: "Hint")
        link.updateForecastTooltipContent(latest)
        XCTAssertTrue(link.isHoverHintScheduled)
        XCTAssertEqual(link.forecastTooltipContent, latest)
        XCTAssertEqual(link.hoverHint, latest.plainText)
        XCTAssertNil(link.toolTip)
        // A different forecast kind is a new meaning and invalidates the hint.
        let signal = DashboardForecastTooltipContent(title: "Signal", body: "Official", source: "11:05", disclaimer: "Hint")
        link.updateForecastTooltipContent(signal)
        XCTAssertFalse(link.isHoverHintScheduled)
        XCTAssertFalse(link.isHoverHintVisible)
        XCTAssertEqual(link.forecastTooltipContent, signal)
        host.forwardHover(atHostPoint: NSPoint(x: 219, y: 23))
        host.forwardHover(atHostPoint: point)
        XCTAssertTrue(link.isHoverHintScheduled)
        host.forwardHover(atHostPoint: NSPoint(x: 219, y: 23))
    }

    func testOpenForecastBubbleSurvivesSourceTimeRefreshAndAnimates() throws {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let link = HoverLinkTextField(text: "50%")
        link.frame = NSRect(x: 8, y: 2, width: 200, height: 20)
        link.hoverHintDelay = 0.5
        link.updateForecastTooltipContent(DashboardForecastTooltipContent(
            title: "Source", body: "Forecast", source: "13:31", disclaimer: "Hint"))
        host.addSubview(link)
        link.layout()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(host)
        ApplicationWindowPresentation.presentInBackground(window)
        defer { window.orderOut(nil) }
        host.track(link)
        host.forwardHover(atHostPoint: host.convert(link.visibleTextHitRect.center, from: link))
        link.firePendingHoverHintForTesting()
        try XCTSkipUnless(link.isHoverHintVisible, "AppKit did not show a popover for a background test window")
        XCTAssertEqual(link.hoverHintAnimatesForTesting, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let popover = link.hoverHintPopoverForTesting
        link.updateForecastTooltipContent(DashboardForecastTooltipContent(
            title: "Source", body: "Forecast", source: "13:36", disclaimer: "Hint"))
        XCTAssertTrue(link.isHoverHintVisible)
        XCTAssertTrue(link.hoverHintPopoverForTesting === popover, "a time-only refresh must not close and reopen the bubble")
        XCTAssertNil(link.toolTip)
        host.removeFromSuperview()
        XCTAssertFalse(link.isHoverHintVisible)
    }

    func testHoverHintOpensAboveOnlyWhenRequested() {
        // Test windows are parked offscreen, where AppKit may flip a popover to
        // whichever side has room, so this checks the requested edge itself.
        let link = HoverLinkTextField(text: "重置概率")
        XCTAssertTrue(link.isFlipped, "a flipped field opens a .maxY popover below its text")
        XCTAssertEqual(link.hoverHintPreferredEdge, .maxY, "default placement stays below the anchor")
        link.opensHoverHintAbove = true
        XCTAssertEqual(link.hoverHintPreferredEdge, .minY, "requested placement is above the title")
    }

    func testHoverLinkPercentSignFontSurvivesValueChangesAndHover() {
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 31, weight: .semibold)
        let symbol = OverviewNumericTextView.currencySymbolFont(for: digits)
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        let link = HoverLinkTextField(text: "50%")
        link.font = digits
        link.percentSignFont = symbol
        link.frame = NSRect(x: 8, y: 2, width: 200, height: 37)
        link.hoverHint = "codex-reset.com"
        host.addSubview(link)
        link.layout()
        host.track(link)
        func fonts() -> (NSFont?, NSFont?) {
            let text = link.attributedStringValue
            return (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                    text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont)
        }
        XCTAssertEqual(fonts().0?.pointSize, 31)
        XCTAssertEqual(fonts().1?.pointSize, symbol.pointSize)
        link.stringValue = "7%"
        XCTAssertEqual(fonts().0?.pointSize, 31)
        XCTAssertEqual(fonts().1?.pointSize, symbol.pointSize)
        host.forwardHover(atHostPoint: host.convert(link.visibleTextHitRect.center, from: link))
        XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(fonts().1?.pointSize, symbol.pointSize)
        link.stringValue = "--"
        XCTAssertEqual(fonts().1?.pointSize, 31, "only a trailing percent sign is reduced")
        host.forwardHover(atHostPoint: NSPoint(x: 219, y: 39))
    }

    func testHoverLinkAlignmentChangesUpdateDrawingParagraphAndHoverGeometry() throws {
        let link = HoverLinkTextField(text: "--%")
        link.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        link.restingTextColor = .labelColor
        link.frame = NSRect(x: 0, y: 0, width: 212, height: 37)
        link.alignment = .right
        link.layout()
        var paragraph = try XCTUnwrap(link.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment, .right)
        XCTAssertGreaterThan(link.visibleTextHitRect.minX, link.bounds.midX)
        let rightRect = link.visibleTextHitRect
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 240, height: 50))
        host.addSubview(link)
        host.track(link)
        host.forwardHover(atHostPoint: host.convert(rightRect.center, from: link))
        XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(link.visibleTextHitRect.minX, rightRect.minX, accuracy: 0.001)
        paragraph = try XCTUnwrap(link.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment, .right)
        host.forwardHover(atHostPoint: NSPoint(x: -1, y: -1))
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(link.visibleTextHitRect.minX, rightRect.minX, accuracy: 0.001)

        link.alignment = .left
        paragraph = try XCTUnwrap(link.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment, .left)
        XCTAssertLessThan(link.visibleTextHitRect.maxX, link.bounds.midX)

        link.alignment = .right
        link.restingTextColor = .secondaryLabelColor
        paragraph = try XCTUnwrap(link.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment, .right)
        XCTAssertEqual(link.visibleTextHitRect, rightRect)
    }

    func testHoverLinkInvokesActivationCallbackOnMouseDown() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.layout()
        var activationCount = 0
        link.onActivate = { activationCount += 1 }

        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: link.visibleTextHitRect.center))

        XCTAssertEqual(activationCount, 1)
    }

    func testHoverLinkActivatesOnlyInsideVisibleTextHitRect() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 220, height: 20)
        link.layout()

        XCTAssertLessThan(link.visibleTextHitRect.maxX, link.bounds.maxX)

        var activationCount = 0
        link.onActivate = { activationCount += 1 }
        for x in [
            link.visibleTextHitRect.minX + 1,
            link.visibleTextHitRect.midX,
            link.visibleTextHitRect.maxX - 1
        ] {
            link.mouseDown(with: makeMouseEvent(
                type: .leftMouseDown,
                location: NSPoint(x: x, y: link.visibleTextHitRect.midY)
            ))
        }
        link.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: link.visibleTextHitRect.maxX + 20, y: link.visibleTextHitRect.midY)
        ))

        XCTAssertEqual(activationCount, 3)
    }

    func testHoverLinkTruncationUsesOnlyVisibleRenderedText() {
        let link = HoverLinkTextField(text: "A very long provider name that must truncate")
        link.frame = NSRect(x: 0, y: 0, width: 90, height: 20)
        link.layout()

        XCTAssertGreaterThan(link.visibleTextHitRect.width, 0)
        XCTAssertLessThan(link.visibleTextHitRect.maxX, link.bounds.maxX)

        var activationCount = 0
        link.onActivate = { activationCount += 1 }
        link.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: link.visibleTextHitRect.maxX + 6, y: link.visibleTextHitRect.midY)
        ))

        XCTAssertEqual(activationCount, 0)
    }

    func testHoverLinkBlankAreaUsesArrowCursorAndDoesNotUnderline() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 220, height: 20)
        link.layout()

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        NSCursor.arrow.set()

        let blankEvent = makeMouseEvent(
            type: .mouseMoved,
            location: NSPoint(x: link.visibleTextHitRect.maxX + 20, y: link.visibleTextHitRect.midY)
        )
        link.cursorUpdate(with: blankEvent)
        link.mouseEntered(with: blankEvent)

        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.arrow))
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testHoverLinkRebuildsOneCursorTrackingArea() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)

        link.updateTrackingAreas()
        XCTAssertEqual(link.trackingAreas.count, 1)
        XCTAssertEqual(link.trackingAreas[0].rect, link.visibleTextHitRect)
        XCTAssertTrue(link.trackingAreas[0].options.contains(.cursorUpdate))
        XCTAssertTrue(link.trackingAreas[0].options.contains(.activeInKeyWindow))
        XCTAssertFalse(link.trackingAreas[0].options.contains(.activeAlways))
        XCTAssertFalse(link.trackingAreas[0].options.contains(.inVisibleRect))

        link.updateTrackingAreas()
        XCTAssertEqual(link.trackingAreas.count, 1)
    }

    func testMenuHostForwardsCoordinatesThroughVisibleGlyphHitTest() {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 40, y: 30, width: 220, height: 20))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 20, y: 0, width: 180, height: 20)
        host.addSubview(link)
        link.layout()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(host)
        host.track(link)
        host.updateTrackingAreas()

        XCTAssertEqual(link.interactionMode, .menuHosted)
        XCTAssertEqual(link.trackingAreas.count, 0)
        XCTAssertEqual(host.trackingAreas.count, 1)
        XCTAssertTrue(host.trackingAreas[0].options.contains(.mouseMoved))
        XCTAssertFalse(host.trackingAreas[0].options.contains(.cursorUpdate))
        XCTAssertTrue(host.trackingAreas[0].options.contains(.activeAlways))

        let cursorBefore = NSCursor.current

        let glyphPoint = host.convert(link.visibleTextHitRect.center, from: link)
        host.forwardHover(atHostPoint: glyphPoint)
        XCTAssertTrue(NSCursor.current.isEqual(cursorBefore))
        XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: link.visibleTextHitRect.center))
        XCTAssertTrue(NSCursor.current.isEqual(cursorBefore))

        let blankPoint = host.convert(
            NSPoint(x: link.visibleTextHitRect.maxX + 12, y: link.visibleTextHitRect.midY),
            from: link
        )
        host.forwardHover(atHostPoint: blankPoint)
        XCTAssertTrue(NSCursor.current.isEqual(cursorBefore))
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testMenuHostHoverRemainsStableAcrossRepeatedMovementAndBoundaryCrossings() {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 20, y: 2, width: 180, height: 20)
        host.addSubview(link)
        link.layout()
        host.track(link)
        host.updateTrackingAreas()

        let glyphPoint = host.convert(link.visibleTextHitRect.center, from: link)
        let blankPoint = host.convert(
            NSPoint(x: link.visibleTextHitRect.maxX + 12, y: link.visibleTextHitRect.midY),
            from: link
        )
        for _ in 0..<30 {
            host.mouseMoved(with: makeMouseEvent(type: .mouseMoved, location: glyphPoint))
            XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))

            host.mouseMoved(with: makeMouseEvent(type: .mouseMoved, location: blankPoint))
            XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))

            host.mouseMoved(with: makeMouseEvent(type: .mouseMoved, location: glyphPoint))
            XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        }
    }

    func testMenuHostTrackingRefreshAndTeardownAreStable() {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 20))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = host.bounds
        host.addSubview(link)
        link.layout()
        host.track(link)

        host.updateTrackingAreas()
        host.updateTrackingAreas()
        XCTAssertEqual(host.trackingAreas.count, 1)

        let glyphPoint = host.convert(link.visibleTextHitRect.center, from: link)
        host.forwardHover(atHostPoint: glyphPoint)
        XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))

        host.removeFromSuperview()
        XCTAssertEqual(host.trackingAreas.count, 0)
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testMenuHostedLinkSurvivesFivePopupReopens() {
        let menu = NSMenu(title: "Issue 265 reopen")
        let item = NSMenuItem()
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 20, y: 2, width: 180, height: 20)
        host.addSubview(link)
        link.layout()
        host.track(link)
        item.view = host
        menu.addItem(item)

        defer { menu.removeAllItems() }
        for openNumber in 1...5 {
            var attached = false
            var underlined = false
            var trackingAreaCount = 0
            var retainedLink = false
            var probeAttempts = 0
            let probe = Timer(timeInterval: 0.02, repeats: true) { timer in
                probeAttempts += 1
                guard host.window != nil else {
                    if probeAttempts >= 50 {
                        timer.invalidate()
                        menu.cancelTracking()
                    }
                    return
                }
                attached = true
                let glyphPoint = host.convert(link.visibleTextHitRect.center, from: link)
                host.mouseMoved(with: self.makeMouseEvent(
                    type: .mouseMoved,
                    location: host.convert(glyphPoint, to: nil)
                ))
                underlined = link.attributedStringValue.attribute(
                    .underlineStyle,
                    at: 0,
                    effectiveRange: nil
                ) != nil
                trackingAreaCount = host.trackingAreas.count
                retainedLink = host.trackedLink === link
                timer.invalidate()
                menu.cancelTracking()
            }
            RunLoop.main.add(probe, forMode: .eventTracking)
            menu.popUp(positioning: nil, at: .zero, in: nil)

            XCTAssertTrue(attached, "menu open \(openNumber) did not attach the host")
            XCTAssertTrue(retainedLink)
            XCTAssertEqual(trackingAreaCount, 1)
            XCTAssertTrue(underlined, "menu open \(openNumber) did not forward the visible glyph")
            link.clearHoverState()
        }

        var activationCount = 0
        link.onActivate = { activationCount += 1 }
        host.forwardHover(atHostPoint: host.convert(
            NSPoint(x: link.visibleTextHitRect.maxX + 8, y: link.visibleTextHitRect.midY),
            from: link
        ))
        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: NSPoint(
            x: link.visibleTextHitRect.maxX + 8,
            y: link.visibleTextHitRect.midY
        )))
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(activationCount, 0)

        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: link.visibleTextHitRect.center))
        XCTAssertEqual(activationCount, 1)
    }

    func testHoverLinkGeometryRefreshInstallsTrackingWhenAttachedToWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let link = HoverLinkTextField(text: "Provider")
        window.contentView?.addSubview(link)
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.layout()

        XCTAssertEqual(link.trackingAreas.count, 1)
        XCTAssertEqual(link.trackingAreas[0].rect, link.visibleTextHitRect)
    }

    func testHoverLinkRemovalClearsHoverStyleAndTrackingArea() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.updateTrackingAreas()

        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) else {
            return XCTFail("Expected to create a mouse event")
        }

        link.mouseEntered(with: event)
        XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))

        link.removeFromSuperview()

        XCTAssertEqual(link.trackingAreas.count, 0)
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testHoverLinkCursorUpdateUsesPointingHandWithoutClick() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.layout()

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        NSCursor.arrow.set()

        link.cursorUpdate(with: makeMouseEvent(type: .mouseMoved, location: link.visibleTextHitRect.center))

        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: type == .leftMouseDown ? 1 : 0,
            pressure: type == .leftMouseDown ? 1 : 0
        ) else {
            fatalError("Expected to create a mouse event")
        }
        return event
    }

    private func assertSettingsSeparatorWidths(
        _ separators: [NSView],
        rows: [NSView],
        matching rowsStack: NSStackView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for row in rows {
            XCTAssertEqual(row.frame.width, rowsStack.frame.width, accuracy: 0.5, file: file, line: line)
        }
        for separator in separators {
            XCTAssertEqual(separator.frame.width, rowsStack.frame.width, accuracy: 0.5, file: file, line: line)
        }
    }

    private func descendantViews<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        root.subviews.flatMap { child in
            ([child].compactMap { $0 as? T }) + descendantViews(of: child, as: type)
        }
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

extension DashboardComponentsTests {
    @MainActor
    func testRechargeTooltipUsesOnlyPhraseAndCoexistsWithProviderLink() throws {
        let host = MenuHoverLinkHostView(frame: NSRect(x: 0, y: 0, width: 280, height: 70))
        let title = HoverLinkTextField(text: "Provider")
        title.frame = NSRect(x: 10, y: 40, width: 200, height: 20)
        host.addSubview(title)
        host.track(title)
        let subtitle = HoverLinkTextField(text: "Since last top-up: $2.50 used")
        subtitle.frame = NSRect(x: 10, y: 10, width: 250, height: 20)
        subtitle.hoverPhrase = "last top-up"
        subtitle.decoratesOnHover = false
        subtitle.underlinesHoverPhrase = true
        subtitle.hoverHintDelay = 0.3
        subtitle.updateTextTooltip(title: "Last top-up", text: "10/16 13:50")
        host.addSubview(subtitle)
        host.track(subtitle)
        subtitle.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(subtitle.visibleTextHitRect.minX, 0)
        XCTAssertLessThan(subtitle.visibleTextHitRect.maxX, subtitle.bounds.maxX)
        host.forwardHover(atHostPoint: host.convert(subtitle.visibleTextHitRect.center, from: subtitle))
        XCTAssertTrue(subtitle.isHoverHintScheduled)
        let phrase = (subtitle.stringValue as NSString).range(of: "last top-up")
        XCTAssertEqual(subtitle.attributedStringValue.attribute(.underlineStyle, at: phrase.location, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertNil(subtitle.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        XCTAssertNil(subtitle.attributedStringValue.attribute(.underlineStyle, at: phrase.location + phrase.length, effectiveRange: nil))
        host.forwardHover(atHostPoint: host.convert(NSPoint(x: 1, y: 10), from: subtitle))
        XCTAssertFalse(subtitle.isHoverHintScheduled)
        XCTAssertNil(subtitle.attributedStringValue.attribute(.underlineStyle, at: phrase.location, effectiveRange: nil))
        host.forwardHover(atHostPoint: host.convert(subtitle.visibleTextHitRect.center, from: subtitle))
        host.setMenuContentVisible(false)
        XCTAssertFalse(subtitle.isHoverHintScheduled)
        var opens = 0
        title.onActivate = { opens += 1 }
        title.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: title.visibleTextHitRect.center))
        XCTAssertEqual(opens, 1)
        let bubble = DashboardTextTooltipViewController(text: "10/16 13:50", title: "Last top-up")
        bubble.loadViewIfNeeded()
        let rows = bubble.view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(rows.map(\.stringValue), ["Last top-up", "10/16 13:50"])
        XCTAssertGreaterThan(rows[0].font?.pointSize ?? 0, rows[1].font?.pointSize ?? 0)
    }
}
