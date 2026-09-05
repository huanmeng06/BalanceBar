import AppKit
import QuartzCore

final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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
    static let rotationDuration = MenuBarAnimationTiming.rotationDuration

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

    /// Installs the fixed 36-state, 1.2-second CA animation exactly once.
    /// `phase` is normalized to one cycle and is used only when a host is
    /// recreated at a visual boundary.
    func installRotationAnimation(phase: Double = 0) {
        guard !hasRotationAnimation else { return }
        let normalizedPhase = phase.truncatingRemainder(dividingBy: 1)
            .wrappedPositiveRemainder
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = Self.clockwiseRotationValues
        animation.keyTimes = (0..<Self.rotationFrameCount).map { index in
            NSNumber(value: Double(index) / Double(Self.rotationFrameCount))
        }
        animation.duration = Self.rotationDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.beginTime = iconLayer.convertTime(CACurrentMediaTime(), from: nil)
            - normalizedPhase * Self.rotationDuration
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

/// A BalanceBar-owned clipped sprite host for Claude's nine-frame thinking
/// animation. The status button carries only the static text bitmap while the
/// sprite layer owns the discrete Core Animation translation.
final class MenuBarClaudeAnimatedIconHostView: NSView {
    static let thinkingAnimationKey = "balancebar.claudeThinking"
    static let thinkingFrameCount = ClaudeThinkingAnimationTiming.frameCount
    static let thinkingFrameDuration = ClaudeThinkingAnimationTiming.frameDuration
    static let thinkingDuration = ClaudeThinkingAnimationTiming.duration

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
        spriteLayer.animation(forKey: Self.thinkingAnimationKey) != nil
    }

    var spriteRasterizationCount: Int { contentsRasterizationCount }

    var modelTranslationYForTesting: CGFloat {
        spriteLayer.affineTransform().ty
    }

    var thinkingAnimationForTesting: CAKeyframeAnimation? {
        spriteLayer.animation(forKey: Self.thinkingAnimationKey) as? CAKeyframeAnimation
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
            height: viewportSize.height * CGFloat(Self.thinkingFrameCount)
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

    /// Installs the fixed nine-frame, 810 ms discrete sprite translation.
    /// `phase` is used only when a host is recreated at a visual boundary.
    func installThinkingAnimation(phase: Double = 0) {
        guard !hasThinkingAnimation, spriteLayer.contents != nil else { return }
        applyRestingModelTransform()
        let normalizedPhase = phase.truncatingRemainder(dividingBy: 1)
            .wrappedPositiveRemainder
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = ClaudeThinkingAnimationTiming.translationValues(
            frameHeight: bounds.height
        )
        animation.keyTimes = (0..<Self.thinkingFrameCount).map { index in
            NSNumber(value: Double(index) / Double(Self.thinkingFrameCount))
        }
        animation.duration = Self.thinkingDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.beginTime = spriteLayer.convertTime(CACurrentMediaTime(), from: nil)
            - normalizedPhase * Self.thinkingDuration
        animation.isRemovedOnCompletion = false
        spriteLayer.add(animation, forKey: Self.thinkingAnimationKey)
        thinkingAnimationInstallCount += 1
    }

    func removeThinkingAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.removeAnimation(forKey: Self.thinkingAnimationKey)
        spriteLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func applyRestingModelTransform() {
        let restingTranslation = ClaudeThinkingAnimationTiming.translationValue(
            frameIndex: ClaudeThinkingAnimationTiming.restingFrameIndex,
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
            height: viewportSize.height * CGFloat(Self.thinkingFrameCount)
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
