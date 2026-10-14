import AppKit
import QuartzCore
import CoreImage

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

/// Owns only selection and cancellable menu-tracking delays.
@MainActor
final class SectionFocusController {
    private(set) var sections: [OpenCodexOverviewSectionID: OpenCodexOverviewSectionView] = [:]
    private(set) var hoveredID: OpenCodexOverviewSectionID?
    private(set) var focusedID: OpenCodexOverviewSectionID?
    private var timer: Timer?
    private var generation = 0
    var isActive = false
    var pendingTimerForTesting: Timer? { timer }

    func update(sections next: [OpenCodexOverviewSectionID: OpenCodexOverviewSectionView]) {
        let previous = sections
        for (id, view) in previous where next[id] !== view { view.setFocusState(.normal, animated: false) }
        sections = next
        if let id = focusedID, next[id] == nil { reset(); return }
        if let id = hoveredID, next[id] == nil { reset(); return }
        for (id, view) in next where previous[id] !== view {
            view.setFocusState(state(for: id), animated: false)
        }
    }

    func hoverChanged(_ id: OpenCodexOverviewSectionID, isHovering: Bool) {
        guard isActive, sections[id] != nil else { return }
        if isHovering {
            guard hoveredID != id else { return }
            hoveredID = id
            cancelPending()
            if focusedID != nil { setFocus(id) }
            else { schedule(after: 0.15, target: id) }
        } else {
            guard hoveredID == id else { return } // Retired/old leaves cannot cancel a new target.
            hoveredID = nil
            cancelPending()
            if focusedID != nil { schedule(after: 0.08, target: nil) }
        }
    }

    private func schedule(after delay: TimeInterval, target: OpenCodexOverviewSectionID?) {
        let token = generation
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            // Installed only on RunLoop.main; keep the mutation synchronous in tracking mode.
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.generation == token, self.hoveredID == target,
                      target.map({ self.sections[$0] != nil }) ?? true else { return }
                self.timer = nil
                self.setFocus(target)
            }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
        RunLoop.main.add(next, forMode: .eventTracking)
    }

    private func cancelPending() { generation += 1; timer?.invalidate(); timer = nil }
    private func state(for id: OpenCodexOverviewSectionID) -> SectionFocusState {
        focusedID == nil ? .normal : (focusedID == id ? .focused : .receded)
    }
    private func setFocus(_ id: OpenCodexOverviewSectionID?) {
        guard focusedID != id else { return }
        focusedID = id
        for (key, view) in sections { view.setFocusState(state(for: key), animated: true) }
    }
    func refreshAccessibility() {
        for (id, view) in sections { view.setFocusState(state(for: id), animated: false) }
    }
    func reset() {
        cancelPending()
        hoveredID = nil
        focusedID = nil
        sections.values.forEach { $0.setFocusState(.normal, animated: false) }
    }
    deinit { timer?.invalidate() }
}

/// Section controls always use local coordinates; the menu host owns placement
/// and event forwarding. Stable IDs also survive value-only refreshes.
class OpenCodexOverviewSectionView: NSView {
    let sectionID: OpenCodexOverviewSectionID
    private(set) var focusState: SectionFocusState = .normal
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
        let duration = receded ? 0.25 : 0.2
        let animate = animated && !reduceMotion
        let visibleAlpha = CGFloat(layer?.presentation()?.opacity ?? Float(alphaValue))
        if ownsOpacityAnimation { layer?.removeAnimation(forKey: "opacity"); ownsOpacityAnimation = false }
        if animate {
            // Start the AppKit opacity animator at the current visible alpha.
            alphaValue = visibleAlpha
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
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
        guard hasOwnFocusFilter, let node = layer else { return } // No invalid KVC on an absent filter.
        let cleanup: () -> Void = { [weak self, weak filter] in
            guard let self, self.focusGeneration == token, self.targetRadius == 0,
                  let filter, self.ownFocusFilter === filter else { return }
            self.contentFilters = self.contentFilters.filter { $0.name != Self.blurName }
            self.ownFocusFilter = nil
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
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if radius == 0 {
                focusRestoreCompletionForTesting = cleanup
                CATransaction.setCompletionBlock(cleanup)
            }
            node.add(animation, forKey: "sectionFocus.radius")
        }
        CATransaction.commit()
        if !animate, radius == 0 { cleanup() }
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
        (superview as? MenuHoverLinkHostView)?.focusSectionWillBeRemoved(self)
        setFocusState(.normal, animated: false)
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

final class BankedResetChromeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: OpenCodexCardLayout.bankedResetChromeCornerRadius,
            yRadius: OpenCodexCardLayout.bankedResetChromeCornerRadius
        ).fill()
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
