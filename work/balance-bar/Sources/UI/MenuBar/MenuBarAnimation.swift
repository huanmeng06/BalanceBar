import AppKit
import Foundation

struct MenuBarAnimationState: Equatable {
    private(set) var frameIndex = 0

    mutating func reset() {
        frameIndex = 0
    }

    mutating func advance(frameCount: Int) -> Int? {
        guard frameCount > 0 else {
            reset()
            return nil
        }
        frameIndex = (frameIndex + 1) % frameCount
        return frameIndex
    }
}

enum MenuBarActivityAnimationPolicy {
    static func shouldAnimate(taskRunning: Bool, preferenceEnabled: Bool) -> Bool {
        shouldAnimate(
            taskRunning: taskRunning,
            preferenceEnabled: preferenceEnabled,
            reduceMotionEnabled: false
        )
    }

    static func shouldAnimate(
        taskRunning: Bool,
        preferenceEnabled: Bool,
        reduceMotionEnabled: Bool
    ) -> Bool {
        taskRunning && preferenceEnabled && !reduceMotionEnabled
    }
}

/// Rendering choices for the Codex activity icon. The overlay case is an
/// intentionally isolated experiment; normal builds keep the native cached
/// frame path unless the build explicitly opts into the experiment.
enum MenuBarAnimationRenderingMode: Equatable {
    case nativeCachedFrames
    case overlayCoreAnimation

    static var configured: Self {
#if BALANCEBAR_EXPERIMENTAL_OVERLAY
        .overlayCoreAnimation
#else
        .nativeCachedFrames
#endif
    }
}

/// A borderless, non-activating window used only by the overlay experiment.
/// Keeping the key/main overrides here makes the stacking experiment unable to
/// steal activation even if AppKit changes the default for borderless windows.
final class MenuBarAnimationOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MenuBarAnimationOverlayRootView: NSView {
    override var isFlipped: Bool { false }
}

/// Presents the Codex icon above the native status item without mutating the
/// status button during the animation. Geometry and appearance are updated by
/// the controller at state/layout boundaries; the rotation itself is owned by
/// the independent window's Core Animation layer.
final class MenuBarAnimationOverlayController {
    private static let rotationAnimationKey = "balancebar.menu-bar-overlay.rotation"
    private static let rotationDuration: CFTimeInterval = 1.2

    private let window: MenuBarAnimationOverlayWindow
    private let rootView: MenuBarAnimationOverlayRootView
    private let rootLayer: CALayer
    /// This is deliberately a layer owned by BalanceBar rather than an
    /// AppKit-managed NSImageView backing layer. Its geometry is established
    /// before the compositor animation is installed, so the pivot is always
    /// the icon's own center.
    private let iconLayer: CALayer
    private var animationRequested = false
    private var sourceImage: NSImage?
    private var renderedSourceImageIdentity: ObjectIdentifier?
    private var renderedAppearanceName: NSAppearance.Name?
    private var renderedIconSize: NSSize = .zero
    private var renderedContentsScale: CGFloat = 0

    private(set) var animationStartCount = 0
    private(set) var animationStopCount = 0
    private(set) var geometrySyncCount = 0
    private(set) var appearanceUpdateCount = 0

    var isAnimating: Bool { animationRequested }
    var isVisible: Bool { window.isVisible }

    var ignoresMouseEventsForTesting: Bool { window.ignoresMouseEvents }
    var isOpaqueForTesting: Bool { window.isOpaque }
    var hasShadowForTesting: Bool { window.hasShadow }
    var canBecomeKeyForTesting: Bool { window.canBecomeKey }
    var canBecomeMainForTesting: Bool { window.canBecomeMain }
    var windowLevelForTesting: NSWindow.Level { window.level }
    var animationKeysForTesting: [String] { iconLayer.animationKeys() ?? [] }
    var rootLayerAnimationKeysForTesting: [String] { rootLayer.animationKeys() ?? [] }
    var rootLayerBoundsForTesting: NSRect { rootLayer.bounds }
    var iconLayerAnchorPointForTesting: CGPoint { iconLayer.anchorPoint }
    var iconLayerPositionForTesting: CGPoint { iconLayer.position }
    var iconLayerBoundsSizeForTesting: NSSize { iconLayer.bounds.size }
    var iconLayerHasContentsForTesting: Bool { iconLayer.contents != nil }

    init() {
        let window = MenuBarAnimationOverlayWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        let rootView = MenuBarAnimationOverlayRootView(frame: .zero)
        rootView.wantsLayer = true
        guard let rootLayer = rootView.layer else {
            fatalError("MenuBarAnimationOverlayRootView must provide a backing layer")
        }
        let iconLayer = CALayer()
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.masksToBounds = false
        rootLayer.backgroundColor = NSColor.clear.cgColor
        rootLayer.addSublayer(iconLayer)

        self.window = window
        self.rootView = rootView
        self.rootLayer = rootLayer
        self.iconLayer = iconLayer

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .transient
        ]
        window.isExcludedFromWindowsMenu = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false

        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView
        window.orderOut(nil)
    }

    func start(
        image: NSImage,
        screenFrame: NSRect?,
        appearance: NSAppearance?
    ) {
        animationRequested = true
        sourceImage = image
        guard synchronize(
            screenFrame: screenFrame,
            appearance: appearance,
            shouldShow: true
        ) else {
            return
        }

        // The window frame, root-layer layout, icon contents, and appearance
        // are all stable before this is submitted to Core Animation.
        if iconLayer.animation(forKey: Self.rotationAnimationKey) == nil {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0.0
            animation.toValue = -Double.pi * 2
            animation.duration = Self.rotationDuration
            animation.repeatCount = .greatestFiniteMagnitude
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.isRemovedOnCompletion = false
            iconLayer.add(animation, forKey: Self.rotationAnimationKey)
            animationStartCount += 1
        }
    }

    @discardableResult
    func synchronize(
        screenFrame: NSRect?,
        appearance: NSAppearance?,
        shouldShow: Bool
    ) -> Bool {
        guard animationRequested,
              shouldShow,
              let screenFrame,
              screenFrame.width > 0,
              screenFrame.height > 0 else {
            if window.isVisible {
                window.orderOut(nil)
            }
            return false
        }

        let alignedFrame = Self.pixelAligned(
            screenFrame,
            scale: window.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
        )
        if window.frame != alignedFrame {
            window.setFrame(alignedFrame, display: false)
            geometrySyncCount += 1
        }
        layoutLayers()
        update(appearance: appearance)
        if !window.isVisible {
            // `orderFrontRegardless` does not make the non-key window active;
            // the window class also rejects key/main status defensively.
            window.orderFrontRegardless()
        }
        return true
    }

    func stop() {
        guard animationRequested || window.isVisible else { return }
        let wasAnimating = animationRequested
        animationRequested = false
        iconLayer.removeAnimation(forKey: Self.rotationAnimationKey)
        if window.isVisible {
            window.orderOut(nil)
        }
        animationStopCount += 1
#if BALANCEBAR_EXPERIMENTAL_OVERLAY
        if wasAnimating {
            SwitchLog.write(
                "menu bar overlay animation stopped; starts=\(animationStartCount); stops=\(animationStopCount); geometry_syncs=\(geometrySyncCount); appearance_updates=\(appearanceUpdateCount)",
                category: "ui.animation-overlay",
                throttleKey: "menu-bar-overlay-stop",
                minimumInterval: 0
            )
        }
#endif
    }

    func teardown() {
        stop()
        window.orderOut(nil)
    }

    private func update(appearance: NSAppearance? = nil) {
        if let appearance,
           window.appearance?.name != appearance.name {
            window.appearance = appearance
            appearanceUpdateCount += 1
        }
        updateIconContentsIfNeeded()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = rootView.bounds
        let rootBounds = rootLayer.bounds
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.bounds = NSRect(origin: .zero, size: rootBounds.size)
        iconLayer.position = CGPoint(
            x: rootBounds.midX,
            y: rootBounds.midY
        )
        iconLayer.contentsScale = max(window.backingScaleFactor, 1)
        CATransaction.commit()
    }

    /// Converts the template NSImage into one appearance-resolved bitmap at
    /// a layout boundary. The resulting NSImage is assigned directly to
    /// CALayer.contents, which lets AppKit manage its backing-resolution
    /// representation without bringing an NSImageView into the animation path.
    private func updateIconContentsIfNeeded() {
        guard let sourceImage,
              iconLayer.bounds.width > 0,
              iconLayer.bounds.height > 0 else {
            return
        }

        let appearance = window.effectiveAppearance
        let sourceIdentity = ObjectIdentifier(sourceImage)
        let iconSize = iconLayer.bounds.size
        let contentsScale = max(window.backingScaleFactor, 1)
        guard renderedSourceImageIdentity != sourceIdentity
                || renderedAppearanceName != appearance.name
                || renderedIconSize != iconSize
                || renderedContentsScale != contentsScale
                || iconLayer.contents == nil else {
            return
        }

        let contents = Self.makeTintedLayerImage(
            from: sourceImage,
            size: iconSize,
            scale: contentsScale,
            appearance: appearance
        )
        iconLayer.contents = contents ?? sourceImage
        renderedSourceImageIdentity = sourceIdentity
        renderedAppearanceName = appearance.name
        renderedIconSize = iconSize
        renderedContentsScale = contentsScale
    }

    private static func makeTintedLayerImage(
        from image: NSImage,
        size: NSSize,
        scale: CGFloat,
        appearance: NSAppearance
    ) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let safeScale = scale > 0 ? scale : 2
        let pixelsWide = max(1, Int((size.width * safeScale).rounded()))
        let pixelsHigh = max(1, Int((size.height * safeScale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        bitmap.size = size
        if let bitmapData = bitmap.bitmapData {
            memset(bitmapData, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        }

        let drawRect = NSRect(origin: .zero, size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            image.draw(
                in: drawRect,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            NSColor.labelColor.set()
            drawRect.fill(using: .sourceIn)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let tintedImage = NSImage(size: size)
        tintedImage.addRepresentation(bitmap)
        tintedImage.isTemplate = false
        return tintedImage
    }

    private static func pixelAligned(_ frame: NSRect, scale: CGFloat) -> NSRect {
        let safeScale = scale > 0 ? scale : 2
        func aligned(_ value: CGFloat) -> CGFloat {
            (value * safeScale).rounded() / safeScale
        }
        return NSRect(
            x: aligned(frame.minX),
            y: aligned(frame.minY),
            width: aligned(frame.width),
            height: aligned(frame.height)
        )
    }
}

final class RotatingTemplateImageView: PassthroughImageView {
    /// 36 discrete frames over a 1.2 s rotation = 30 fps. Pixel updates
    /// are the only way the macOS 26 status-item replicant snapshot can show
    /// motion (it renders model state via renderInContext, so render-server-
    /// side animations are invisible), so this animation intentionally keeps a
    /// fixed, bounded update cadence.
    static let frameCount = 36
    static let rotationDuration: TimeInterval = 1.2
    static let rotationFrameInterval = rotationDuration / Double(frameCount)
    private var sourceImage: NSImage?
    private var rotationFrames: [NSImage] = []
    private var rotationTimer: Timer?
    private var animationState = MenuBarAnimationState()
    /// Called only when the semantic source icon changes. Animation frames do
    /// not leave this view, so they cannot trigger layout or dashboard work.
    var onSourceImageChanged: ((NSImage?) -> Void)?
    /// Called after the displayed bitmap changes. Consumers must only mirror
    /// the bitmap; this is intentionally separate from semantic state work.
    var onFrameImageChanged: ((NSImage?) -> Void)?
    /// Called with the discrete frame index before the image view is mutated.
    /// Bitmap-backed Codex animation uses this seam to update a stable image
    /// backing without changing this detached view's image every tick.
    var onAnimationFrameIndexChanged: ((Int) -> Void)?
    var isRotating: Bool { rotationTimer != nil }
    var currentAnimationFrameIndex: Int { animationState.frameIndex }

    /// The already-rasterized frames for the current semantic source. The
    /// controller uses these to build complete button-ready bitmaps when the
    /// content changes, rather than composing one on every timer tick.
    var animationFrames: [NSImage] { rotationFrames }

    var sourceImageForRendering: NSImage? { sourceImage }

    func animationFrameIndex(for image: NSImage?) -> Int? {
        guard let image else { return nil }
        return rotationFrames.firstIndex { $0 === image }
    }

    func animationFrame(at index: Int) -> NSImage? {
        guard rotationFrames.indices.contains(index) else { return nil }
        return rotationFrames[index]
    }

    func setSourceImage(_ image: NSImage) {
        let sourceChanged = sourceImage !== image
        if sourceChanged {
            rotationFrames = Self.makeRotationFrames(from: image)
        }
        sourceImage = image
        if self.image !== image {
            // Activity state transitions re-send the same source image; only a
            // real bitmap change may dirty the image view.
            self.image = image
        }
        if sourceChanged {
            onSourceImageChanged?(image)
        }
    }

    func displayImage(_ image: NSImage) {
        self.image = image
        onFrameImageChanged?(image)
    }

    func restoreSourceImage() {
        guard image !== sourceImage else { return }
        image = sourceImage
        onFrameImageChanged?(sourceImage)
    }

    func startRotating() {
        guard rotationTimer == nil, !rotationFrames.isEmpty else { return }
        animationState.reset()
        let timer = Timer(timeInterval: Self.rotationFrameInterval, repeats: true) { [weak self] _ in
            self?.advanceRotation()
        }
        timer.tolerance = 0.002
        rotationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopRotating() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        animationState.reset()
        restoreSourceImage()
    }

    private func advanceRotation() {
        guard let frameIndex = animationState.advance(frameCount: rotationFrames.count) else {
            return
        }
        let frame = rotationFrames[frameIndex]
        if let onAnimationFrameIndexChanged {
            onAnimationFrameIndexChanged(frameIndex)
        } else {
            displayImage(frame)
        }
    }

    private static func makeRotationFrames(from sourceImage: NSImage) -> [NSImage] {
        (0..<frameCount).map { index in
            let angle = -(2 * .pi * CGFloat(index) / CGFloat(frameCount))
            let frame = NSImage(size: sourceImage.size, flipped: false) { rect in
                NSGraphicsContext.current?.imageInterpolation = .high
                let transform = NSAffineTransform()
                transform.translateX(by: rect.midX, yBy: rect.midY)
                transform.rotate(byRadians: angle)
                transform.translateX(by: -rect.midX, yBy: -rect.midY)
                transform.concat()
                sourceImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            frame.isTemplate = true
            return frame
        }
    }

    deinit {
        rotationTimer?.invalidate()
    }
}

final class ClaudeThinkingAnimator {
    static let frameCount = 9
    static let defaultFrameDuration: TimeInterval = 0.09

    private weak var imageView: RotatingTemplateImageView?
    private let staticImage: NSImage
    private let frames: [NSImage]
    private let frameDuration: TimeInterval
    private let outputSize: NSSize
    private var timer: Timer?
    private var animationState = MenuBarAnimationState()

    init?(
        imageView: RotatingTemplateImageView,
        staticImage: NSImage,
        animatedSVGURL: URL,
        frameDuration: TimeInterval = ClaudeThinkingAnimator.defaultFrameDuration,
        outputSize: NSSize = NSSize(width: 16, height: 16)
    ) {
        guard
            let svg = try? String(contentsOf: animatedSVGURL, encoding: .utf8),
            let frames = Self.makeFrames(from: svg),
            frames.count == Self.frameCount
        else {
            return nil
        }
        self.imageView = imageView
        self.staticImage = staticImage
        self.frames = frames.map { source in
            let output = NSImage(size: outputSize, flipped: false) { rect in
                source.draw(
                    in: rect.insetBy(dx: 0.3, dy: 0.3),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
                return true
            }
            output.isTemplate = true
            output.size = outputSize
            return output
        }
        self.frameDuration = frameDuration
        self.outputSize = outputSize
    }

    var isAnimating: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stop()
            return
        }
        animationState.reset()
        render(animationState.frameIndex)
        let timer = Timer(timeInterval: frameDuration, repeats: true) { [weak self] _ in
            guard let self,
                  let frameIndex = self.animationState.advance(frameCount: self.frames.count)
            else { return }
            self.render(frameIndex)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        animationState.reset()
        imageView?.setSourceImage(staticImage)
        imageView?.restoreSourceImage()
    }

    private func render(_ index: Int) {
        imageView?.displayImage(frames[min(max(index, 0), frames.count - 1)])
    }

    private static func makeFrames(from animatedSVG: String) -> [NSImage]? {
        guard
            let animationRegex = try? NSRegularExpression(
                pattern: #"<animateTransform\b[^>]*/>"#
            ),
            let viewBoxRegex = try? NSRegularExpression(
                pattern: #"viewBox="0 0 100 100""#
            )
        else {
            return nil
        }
        let fullRange = NSRange(animatedSVG.startIndex..., in: animatedSVG)
        let staticSVG = animationRegex.stringByReplacingMatches(
            in: animatedSVG,
            range: fullRange,
            withTemplate: ""
        )
        return (0..<9).compactMap { index in
            let range = NSRange(staticSVG.startIndex..., in: staticSVG)
            let frameSVG = viewBoxRegex.stringByReplacingMatches(
                in: staticSVG,
                range: range,
                withTemplate: #"viewBox="0 \#(index * 100) 100 100""#
            )
            guard
                let data = frameSVG.data(using: .utf8),
                let image = NSImage(data: data)
            else {
                return nil
            }
            image.size = NSSize(width: 100, height: 100)
            return image
        }
    }

    deinit {
        timer?.invalidate()
    }
}
