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

/// Centralizes the visibility contract for the E overlay. Callers may request
/// animation while the status item is temporarily unavailable; visibility is
/// granted only when every independent piece of evidence is valid.
struct MenuBarAnimationOverlayVisibilityPolicy {
    static func shouldShow(
        animationRequested: Bool,
        statusItemVisible: Bool,
        hiddenByMenuBarSpace: Bool,
        hiddenByRuntimePolicy: Bool,
        statusWindowVisible: Bool,
        statusWindowOcclusionVisible: Bool,
        validGeometry: Bool,
        reduceMotionEnabled: Bool,
        menuBarActuallyVisible: Bool = true,
        lifecycleSuspended: Bool = false
    ) -> Bool {
        animationRequested
            && statusItemVisible
            && !hiddenByMenuBarSpace
            && !hiddenByRuntimePolicy
            && statusWindowVisible
            && statusWindowOcclusionVisible
            && validGeometry
            && !reduceMotionEnabled
            && menuBarActuallyVisible
            && !lifecycleSuspended
    }
}

/// A short-lived transition watcher is driven by AppKit lifecycle events. It
/// is intentionally a value type so its stop conditions remain deterministic
/// and testable without creating a real run-loop timer in XCTest.
struct MenuBarAnimationOverlayTransitionObservation: Equatable {
    let menuBarVisible: Bool
    let statusItemVisible: Bool
    let statusWindowVisible: Bool
    let statusWindowOcclusionVisible: Bool
    let validGeometry: Bool
    let overlayVisible: Bool
    let statusVisibilityStableHidden: Bool
}

struct MenuBarAnimationOverlayTransitionWatch {
    static let cadence: TimeInterval = 0.05
    static let timeout: TimeInterval = 0.75
    static let stableSampleCount = 2

    private(set) var isActive = false
    private var deadline: Date?
    private var lastObservation: MenuBarAnimationOverlayTransitionObservation?
    private var stableSampleCount = 0
    private var initialOverlayVisible: Bool?

    @discardableResult
    mutating func begin(
        at date: Date,
        initialObservation: MenuBarAnimationOverlayTransitionObservation? = nil
    ) -> Bool {
        guard !isActive else { return false }
        isActive = true
        deadline = date.addingTimeInterval(Self.timeout)
        lastObservation = nil
        stableSampleCount = 0
        initialOverlayVisible = initialObservation?.overlayVisible
        return true
    }

    @discardableResult
    mutating func observe(
        _ observation: MenuBarAnimationOverlayTransitionObservation,
        at date: Date
    ) -> Bool {
        guard isActive else { return false }
        if lastObservation == observation {
            stableSampleCount += 1
        } else {
            lastObservation = observation
            stableSampleCount = 1
        }

        let hiddenByMenuBar = !observation.menuBarVisible
            && !observation.overlayVisible
        let startedWhileOverlayWasHidden = initialOverlayVisible == false
        let shownWithValidState = startedWhileOverlayWasHidden
            && observation.menuBarVisible
            && observation.overlayVisible
        // A previously published hidden-by-space state can remain stale while
        // the menu bar is animating back in. Do not terminate a watcher that
        // began with a hidden overlay merely because that old state repeats;
        // wait for fresh visible evidence or the bounded timeout. For a
        // watcher that began with a visible overlay, repeated hidden evidence
        // is enough to finish the hide transition.
        let staleHiddenStateCanEndWatch = initialOverlayVisible != false
            && observation.statusVisibilityStableHidden
        let stablyUnavailable = stableSampleCount >= Self.stableSampleCount
            && (!observation.statusItemVisible || staleHiddenStateCanEndWatch)
        let timedOut = deadline.map { date >= $0 } ?? true
        if hiddenByMenuBar || shownWithValidState || stablyUnavailable || timedOut {
            stop()
        }
        return isActive
    }

    mutating func stop() {
        isActive = false
        deadline = nil
        lastObservation = nil
        stableSampleCount = 0
        initialOverlayVisible = nil
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

struct MenuBarAnimationOverlayIconRaster {
    let cgImage: CGImage
    let contentsScale: CGFloat
    let logicalSize: NSSize
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
    private var appliedWindowFrame: NSRect?
    private var appliedRootBounds: NSRect = .zero
    private var appliedBackingScale: CGFloat = 0
    private var appliedVisibility = false

    private(set) var animationStartCount = 0
    private(set) var animationStopCount = 0
    private(set) var geometrySyncCount = 0
    private(set) var appearanceUpdateCount = 0
    private(set) var rasterUpdateCount = 0
    private(set) var visibilityMutationCount = 0

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
    var rootViewBoundsForTesting: NSRect { rootView.bounds }
    var iconLayerAnchorPointForTesting: CGPoint { iconLayer.anchorPoint }
    var iconLayerPositionForTesting: CGPoint { iconLayer.position }
    var iconLayerBoundsSizeForTesting: NSSize { iconLayer.bounds.size }
    var iconLayerHasContentsForTesting: Bool { iconLayer.contents != nil }
    var iconLayerContentsIsCGImageForTesting: Bool {
        guard let contents = iconLayer.contents else { return false }
        return CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
    }
    var iconLayerContentsPixelSizeForTesting: NSSize? {
        guard iconLayerContentsIsCGImageForTesting,
              let contents = iconLayer.contents else { return nil }
        let image = contents as! CGImage
        return NSSize(width: image.width, height: image.height)
    }
    var iconLayerContentsRectForTesting: CGRect { iconLayer.contentsRect }
    var iconLayerContentsGravityForTesting: CALayerContentsGravity {
        iconLayer.contentsGravity
    }
    var hasInstalledRotationAnimationForTesting: Bool {
        iconLayer.animation(forKey: Self.rotationAnimationKey) != nil
    }
    var iconLayerContentsScaleForTesting: CGFloat { iconLayer.contentsScale }

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
        iconLayer.contentsGravity = .resize
        iconLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
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
        _ = synchronize(
            image: image,
            animationRequested: true,
            screenFrame: screenFrame,
            appearance: appearance,
            backingScale: nil,
            shouldShow: true
        )
    }

    @discardableResult
    func synchronize(
        screenFrame: NSRect?,
        appearance: NSAppearance?,
        shouldShow: Bool
    ) -> Bool {
        synchronize(
            image: nil,
            animationRequested: animationRequested,
            screenFrame: screenFrame,
            appearance: appearance,
            backingScale: nil,
            shouldShow: shouldShow
        )
    }

    /// Applies one complete desired state. The caller may keep the animation
    /// requested while geometry or visibility evidence is temporarily invalid;
    /// in that case the window is hidden but an already-installed CA animation
    /// is retained for a seamless restore.
    @discardableResult
    func synchronize(
        image: NSImage?,
        animationRequested: Bool,
        screenFrame: NSRect?,
        appearance: NSAppearance?,
        backingScale: CGFloat?,
        shouldShow: Bool
    ) -> Bool {
        if let image, sourceImage !== image {
            sourceImage = image
            renderedSourceImageIdentity = nil
            renderedAppearanceName = nil
            renderedIconSize = .zero
            renderedContentsScale = 0
        } else if sourceImage == nil {
            sourceImage = image
        }

        self.animationRequested = animationRequested
        guard animationRequested, sourceImage != nil else {
            stop()
            return false
        }

        let resolvedScale = max(
            backingScale ?? window.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2,
            1
        )
        let validGeometry = screenFrame.map(Self.isValidGeometry) ?? false
        guard shouldShow, validGeometry, let screenFrame else {
            hideWindowIfNeeded()
            return false
        }

        let alignedFrame = Self.pixelAligned(screenFrame, scale: resolvedScale)
        guard Self.isValidGeometry(alignedFrame) else {
            hideWindowIfNeeded()
            return false
        }
        if appliedWindowFrame != alignedFrame || window.frame != alignedFrame {
            window.setFrame(alignedFrame, display: false)
            appliedWindowFrame = alignedFrame
            geometrySyncCount += 1
        }

        layoutLayersIfNeeded(backingScale: resolvedScale)
        update(appearance: appearance, contentsScale: resolvedScale)
        installRotationAnimationIfNeeded()

        if !window.isVisible {
            // `orderFrontRegardless` does not make the non-key window active;
            // the window class also rejects key/main status defensively.
            window.orderFrontRegardless()
            appliedVisibility = true
            visibilityMutationCount += 1
        } else if !appliedVisibility {
            appliedVisibility = true
        }
        return true
    }

    func stop() {
        guard animationRequested
                || iconLayer.animation(forKey: Self.rotationAnimationKey) != nil
                || window.isVisible else { return }
        let wasAnimating = animationRequested
        animationRequested = false
        if iconLayer.animation(forKey: Self.rotationAnimationKey) != nil {
            iconLayer.removeAnimation(forKey: Self.rotationAnimationKey)
        }
        hideWindowIfNeeded()
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

    private func update(
        appearance: NSAppearance? = nil,
        contentsScale: CGFloat? = nil
    ) {
        if let appearance,
           window.appearance?.name != appearance.name {
            window.appearance = appearance
            appearanceUpdateCount += 1
        }
        updateIconContentsIfNeeded(contentsScale: contentsScale)
    }

    private func installRotationAnimationIfNeeded() {
        guard iconLayer.animation(forKey: Self.rotationAnimationKey) == nil else {
            return
        }
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

    private func hideWindowIfNeeded() {
        guard window.isVisible || appliedVisibility else { return }
        if window.isVisible {
            window.orderOut(nil)
        }
        appliedVisibility = false
        visibilityMutationCount += 1
    }

    private func layoutLayersIfNeeded(backingScale: CGFloat) {
        let rootBounds = rootView.bounds.width > 0 && rootView.bounds.height > 0
            ? rootView.bounds
            : NSRect(origin: .zero, size: window.frame.size)
        guard appliedRootBounds != rootBounds || appliedBackingScale != backingScale else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.bounds = NSRect(origin: .zero, size: rootBounds.size)
        iconLayer.position = CGPoint(
            x: rootBounds.midX,
            y: rootBounds.midY
        )
        iconLayer.contentsScale = backingScale
        CATransaction.commit()
        appliedRootBounds = rootBounds
        appliedBackingScale = backingScale
    }

    /// Converts the template NSImage into one appearance-resolved CGImage at
    /// a layout boundary. The raster's pixel dimensions explicitly match its
    /// logical layer size and contentsScale, so CALayer does not need to
    /// select an NSImage representation or perform an additional aspect fit.
    private func updateIconContentsIfNeeded(contentsScale: CGFloat? = nil) {
        guard let sourceImage,
              iconLayer.bounds.width > 0,
              iconLayer.bounds.height > 0 else {
            return
        }

        let appearance = window.effectiveAppearance
        let sourceIdentity = ObjectIdentifier(sourceImage)
        let iconSize = iconLayer.bounds.size
        let resolvedContentsScale = max(
            contentsScale ?? window.backingScaleFactor,
            1
        )
        guard renderedSourceImageIdentity != sourceIdentity
                || renderedAppearanceName != appearance.name
                || renderedIconSize != iconSize
                || renderedContentsScale != resolvedContentsScale
                || iconLayer.contents == nil else {
            return
        }

        guard let raster = Self.makeTintedLayerRaster(
            from: sourceImage,
            size: iconSize,
            scale: resolvedContentsScale,
            appearance: appearance
        ) else {
            iconLayer.contents = nil
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = raster.cgImage
        iconLayer.contentsScale = raster.contentsScale
        iconLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        CATransaction.commit()

        renderedSourceImageIdentity = sourceIdentity
        renderedAppearanceName = appearance.name
        renderedIconSize = raster.logicalSize
        renderedContentsScale = raster.contentsScale
        rasterUpdateCount += 1
    }

    static func makeTintedLayerRaster(
        from image: NSImage,
        size: NSSize,
        scale: CGFloat,
        appearance: NSAppearance
    ) -> MenuBarAnimationOverlayIconRaster? {
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
        ) else {
            return nil
        }
        bitmap.size = size
        guard let bitmapData = bitmap.bitmapData,
              let bitmapContext = CGContext(
                data: bitmapData,
                width: pixelsWide,
                height: pixelsHigh,
                bitsPerComponent: 8,
                bytesPerRow: bitmap.bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        memset(bitmapData, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)

        let drawRect = NSRect(origin: .zero, size: size)
        let context = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Use a raw bitmap CGContext with a known identity CTM. Constructing
        // NSGraphicsContext directly from a bitmap rep whose logical size has
        // already been set installs its own point-to-pixel scale; applying a
        // second scale would zoom and clip the icon. This path owns exactly
        // one logical-point to pixel transform.
        bitmapContext.scaleBy(x: safeScale, y: safeScale)
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

        guard let cgImage = bitmapContext.makeImage() else { return nil }
        return MenuBarAnimationOverlayIconRaster(
            cgImage: cgImage,
            contentsScale: safeScale,
            logicalSize: size
        )
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

    private static func isValidGeometry(_ frame: NSRect) -> Bool {
        frame.width > 0
            && frame.height > 0
            && frame.minX.isFinite
            && frame.minY.isFinite
            && frame.maxX.isFinite
            && frame.maxY.isFinite
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
