import AppKit
import Foundation

struct MenuBarAnimationState: Equatable {
    private(set) var frameIndex = 0

    mutating func reset() {
        frameIndex = 0
    }

    mutating func setFrameIndex(_ index: Int, frameCount: Int) {
        guard frameCount > 0 else {
            reset()
            return
        }
        frameIndex = ((index % frameCount) + frameCount) % frameCount
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

/// Product animation timing is fixed at 36 discrete states over one 1.2 s
/// revolution (30 Hz).  There is intentionally no user-selectable cadence:
/// both the efficient and synchronized Codex modes share the same visual
/// contract.
enum MenuBarAnimationTiming {
    static let frameCount = 36
    static let rotationDuration: TimeInterval = 1.2
    static let frameInterval = rotationDuration / Double(frameCount)
}

/// Strengthens the Codex template mark used by inactive-display replicants.
/// macOS dims template status items; the lacy GPT silhouette needs a little
/// extra coverage to stay readable without an opaque backdrop.
enum MenuBarTemplateIconEmphasis {
    static let midtoneAlphaGain: CGFloat = 1.55

    static func draw(_ image: NSImage, in rect: NSRect) {
        let mark = strengthenedTemplateImage(image, drawingSize: rect.size) ?? image
        mark.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    static func strengthenedTemplateImage(
        _ image: NSImage,
        drawingSize: NSSize,
        scale: CGFloat = 2
    ) -> NSImage? {
        guard drawingSize.width > 0, drawingSize.height > 0 else { return nil }
        let pixelDimensions = MenuBarBitmapImageLayout.pixelDimensions(
            for: drawingSize,
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
        rep.size = drawingSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: drawingSize),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
        boostTemplateAlpha(in: rep)
        let strengthened = NSImage(size: drawingSize)
        strengthened.addRepresentation(rep)
        strengthened.isTemplate = true
        return strengthened
    }

    static func boostTemplateAlpha(in rep: NSBitmapImageRep) {
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let alpha = color.alphaComponent
                guard alpha > 0, alpha < 1 else { continue }
                let boosted = min(1, alpha * midtoneAlphaGain)
                rep.setColor(
                    NSColor(
                        deviceRed: color.redComponent,
                        green: color.greenComponent,
                        blue: color.blueComponent,
                        alpha: boosted
                    ),
                    atX: x,
                    y: y
                )
            }
        }
    }
}

/// Selects the Codex animation implementation used by a status-item
/// controller.  The native Core Animation case is intentionally injectable so
/// the stacked Issue #300 experiment can be exercised without deleting the D0
/// bitmap backend or changing the production candidate branch.
enum MenuBarCodexAnimationBackend: Equatable {
    case stableBitmap
    case nativeCoreAnimation

    init(mode: MenuBarAnimationMode) {
        switch mode {
        case .efficient:
            self = .nativeCoreAnimation
        case .synchronized:
            self = .stableBitmap
        }
    }
}

/// Identifies the compositor primitive that a Dashboard preview must install.
/// It is intentionally separate from the Codex preference because Claude has
/// one fixed thinking animation and does not expose a second user-selectable
/// mode.
enum MenuBarCompositorAnimationKind: Equatable {
    case none
    case codexRotation
    case claudeThinking

    var isActive: Bool { self != .none }
}

/// Discrete vertical-sprite timing used by the Claude compositor host.
struct MenuBarSpriteAnimationTiming: Equatable {
    let frameCount: Int
    let restingFrameIndex: Int
    let frameDurations: [TimeInterval]
    let animationKey: String

    var duration: TimeInterval {
        frameDurations.reduce(0, +)
    }

    var keyTimes: [NSNumber] {
        let total = duration
        guard frameCount > 0, frameDurations.count == frameCount, total > 0 else {
            return (0..<max(frameCount, 0)).map { index in
                NSNumber(value: Double(index) / Double(max(frameCount, 1)))
            }
        }
        var elapsed: TimeInterval = 0
        return (0..<frameCount).map { index in
            let value = elapsed / total
            elapsed += frameDurations[index]
            return NSNumber(value: value)
        }
    }

    func translationValue(frameIndex: Int, frameHeight: CGFloat) -> CGFloat {
        -frameHeight * CGFloat(frameIndex)
    }

    func translationValues(frameHeight: CGFloat) -> [NSNumber] {
        (0..<frameCount).map { index in
            NSNumber(
                value: Double(translationValue(frameIndex: index, frameHeight: frameHeight))
            )
        }
    }

    static let claude = MenuBarSpriteAnimationTiming(
        frameCount: ClaudeThinkingAnimationTiming.frameCount,
        restingFrameIndex: ClaudeThinkingAnimationTiming.restingFrameIndex,
        frameDurations: Array(
            repeating: ClaudeThinkingAnimationTiming.frameDuration,
            count: ClaudeThinkingAnimationTiming.frameCount
        ),
        animationKey: "balancebar.claudeThinking"
    )
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

final class RotatingTemplateImageView: PassthroughImageView {
    /// D0 uses 36 discrete frames over a 1.2 s rotation = 30 fps. The native
    /// Core Animation backend uses the same visual timing without entering
    /// this timer path.
    static let frameCount = MenuBarAnimationTiming.frameCount
    static let rotationDuration: TimeInterval = MenuBarAnimationTiming.rotationDuration
    static let rotationFrameInterval = MenuBarAnimationTiming.frameInterval
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func animationFrameIndex(for image: NSImage?) -> Int? {
        guard let image else { return nil }
        return rotationFrames.firstIndex { $0 === image }
    }

    func animationFrame(at index: Int) -> NSImage? {
        guard rotationFrames.indices.contains(index) else { return nil }
        return rotationFrames[index]
    }

    func setSourceImage(
        _ image: NSImage,
        prepareAnimationFrames: Bool = true
    ) {
        let sourceChanged = sourceImage !== image
        let framePreparationChanged = prepareAnimationFrames
            ? rotationFrames.count != Self.frameCount
            : !rotationFrames.isEmpty
        if sourceChanged || framePreparationChanged {
            rotationFrames = prepareAnimationFrames
                ? Self.makeRotationFrames(from: image)
                : []
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
        installRotationTimer()
    }

    private func installRotationTimer() {
        guard rotationTimer == nil, !rotationFrames.isEmpty else { return }
        let runningTimer = Timer(timeInterval: Self.rotationFrameInterval, repeats: true) { [weak self] _ in
            self?.advanceRotation()
        }
        runningTimer.tolerance = 0.002
        rotationTimer = runningTimer
        RunLoop.main.add(runningTimer, forMode: .common)
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

    private static func makeRotationFrames(
        from sourceImage: NSImage
    ) -> [NSImage] {
        (0..<Self.frameCount).map { index in
            let angle = -(2 * .pi * CGFloat(index) / CGFloat(Self.frameCount))
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

enum ClaudeThinkingAnimationTiming {
    static let frameCount = 9
    /// The SVG's center frame is the fully opened starburst.  A compositor
    /// consumer that reads the layer model state must see this canonical
    /// resting frame rather than the animation's first (minimal) frame.
    static let restingFrameIndex = 4
    static let frameDuration: TimeInterval = 0.09
    static let defaultFrameDuration = frameDuration
    static let duration: TimeInterval = frameDuration * Double(frameCount)

    static func translationValue(frameIndex: Int, frameHeight: CGFloat) -> CGFloat {
        -frameHeight * CGFloat(frameIndex)
    }

    static func translationValues(frameHeight: CGFloat) -> [NSNumber] {
        (0..<frameCount).map { index in
            NSNumber(
                value: Double(
                    translationValue(frameIndex: index, frameHeight: frameHeight)
                )
            )
        }
    }
}

private struct MenuBarSizedImageCacheKey: Hashable {
    let url: URL
    let width: CGFloat
    let height: CGFloat

    init(url: URL, outputSize: NSSize) {
        self.url = url
        self.width = outputSize.width
        self.height = outputSize.height
    }
}

/// Builds the Claude thinking sprite once at a visual invalidation boundary.
/// The returned image contains the same nine discrete SVG view-box frames that
/// the old animator displayed, stacked from the first frame at the bottom to
/// the last frame at the top for a Core Animation Y translation.
enum ClaudeThinkingSprite {
    private static let cacheLock = NSLock()
    private static var sourceFramesByURL: [URL: [NSImage]] = [:]
    private static var spritesByCacheKey: [MenuBarSizedImageCacheKey: NSImage] = [:]
    private static var sourceFrameBuildCount = 0

    static var sourceFrameBuildCountForTesting: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sourceFrameBuildCount
    }

    static func resetCachesForTesting() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        sourceFramesByURL = [:]
        spritesByCacheKey = [:]
        sourceFrameBuildCount = 0
    }

    static func make(
        from animatedSVGURL: URL,
        outputSize: NSSize = NSSize(width: 16, height: 16)
    ) -> NSImage? {
        let spriteKey = MenuBarSizedImageCacheKey(
            url: animatedSVGURL,
            outputSize: outputSize
        )
        cacheLock.lock()
        if let cachedSprite = spritesByCacheKey[spriteKey] {
            cacheLock.unlock()
            return cachedSprite
        }
        let cachedFrames = sourceFramesByURL[animatedSVGURL]
        cacheLock.unlock()

        let frames: [NSImage]
        if let cachedFrames {
            frames = cachedFrames
        } else {
            guard
                let svg = try? String(contentsOf: animatedSVGURL, encoding: .utf8),
                let made = makeFrames(from: svg)
            else {
                return nil
            }
            cacheLock.lock()
            if let existing = sourceFramesByURL[animatedSVGURL] {
                cacheLock.unlock()
                frames = existing
            } else {
                sourceFramesByURL[animatedSVGURL] = made
                sourceFrameBuildCount += 1
                cacheLock.unlock()
                frames = made
            }
        }

        guard let sprite = makeSprite(from: frames, outputSize: outputSize) else {
            return nil
        }
        cacheLock.lock()
        spritesByCacheKey[spriteKey] = sprite
        cacheLock.unlock()
        return sprite
    }

    static func makeSprite(
        from frames: [NSImage],
        outputSize: NSSize = NSSize(width: 16, height: 16)
    ) -> NSImage? {
        MenuBarThinkingSprite.makeSprite(
            from: frames,
            outputSize: outputSize,
            expectedFrameCount: ClaudeThinkingAnimationTiming.frameCount
        )
    }

    static func makeFrames(from animatedSVG: String) -> [NSImage]? {
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
        return (0..<ClaudeThinkingAnimationTiming.frameCount).compactMap { index in
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
}

enum MenuBarThinkingSprite {
    static func makeSprite(
        from frames: [NSImage],
        outputSize: NSSize = NSSize(width: 16, height: 16),
        expectedFrameCount: Int? = nil,
        contentsScale: CGFloat = 1
    ) -> NSImage? {
        let frameCount = expectedFrameCount ?? frames.count
        guard
            frameCount > 0,
            frames.count == frameCount,
            outputSize.width > 0,
            outputSize.height > 0
        else {
            return nil
        }

        let spriteSize = NSSize(
            width: outputSize.width,
            height: outputSize.height * CGFloat(frameCount)
        )
        // Claude keeps the historical 1x `NSImage(size:){draw}` path. Live
        // Grok thinking no longer uses this baker; it stays `_NSSVGImageRep`
        // until the animation host rasterizes at `backingScaleFactor`.
        if contentsScale > 1 {
            guard let sprite = makeRetinaSprite(
                from: frames,
                outputSize: outputSize,
                spriteSize: spriteSize,
                frameCount: frameCount,
                contentsScale: contentsScale
            ) else {
                return nil
            }
            sprite.isTemplate = true
            return sprite
        }

        let sprite = NSImage(size: spriteSize, flipped: false) { _ in
            drawFrames(
                frames,
                outputSize: outputSize,
                frameCount: frameCount,
                originAtBottom: true
            )
            return true
        }
        sprite.isTemplate = true
        return sprite
    }

    /// `NSBitmapImageRep` contexts are flipped (y=0 is the top). Frame 0 still
    /// has to land on the visual bottom so CALayer translation 0 shows it.
    private static func makeRetinaSprite(
        from frames: [NSImage],
        outputSize: NSSize,
        spriteSize: NSSize,
        frameCount: Int,
        contentsScale: CGFloat
    ) -> NSImage? {
        let scale = max(contentsScale, 2)
        let pixelsWide = max(1, Int((spriteSize.width * scale).rounded()))
        let pixelsHigh = max(1, Int((spriteSize.height * scale).rounded()))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
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
        representation.size = spriteSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: spriteSize).fill()
        drawFrames(
            frames,
            outputSize: outputSize,
            frameCount: frameCount,
            originAtBottom: false
        )

        let sprite = NSImage(size: spriteSize)
        sprite.addRepresentation(representation)
        return sprite
    }

    private static func drawFrames(
        _ frames: [NSImage],
        outputSize: NSSize,
        frameCount: Int,
        originAtBottom: Bool
    ) {
        for (index, frame) in frames.enumerated() {
            let originY = originAtBottom
                ? outputSize.height * CGFloat(index)
                : outputSize.height * CGFloat(frameCount - 1 - index)
            let destination = NSRect(
                x: 0,
                y: originY,
                width: outputSize.width,
                height: outputSize.height
            ).insetBy(dx: 0.3, dy: 0.3)
            frame.draw(
                in: destination,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
    }
}

/// Live idle Grok is the relocated thinking-pack Frame 16 SVG
/// (`GrokIdle.svg`). Loading keeps `_NSSVGImageRep` and applies the same
/// 1.12 centered crop; it must not redraw that SVG into an
/// `NSImage(size: slot)` bitmap. `Grok.png` remains a cropped fallback.
enum GrokIdleIcon {
    static let resourceName = "GrokIdle"
    static let sourceFrameSize = NSSize(width: 560, height: 560)
    static let opticalScale: CGFloat = 1.12

    static var opticalCropInset: Int {
        let frame = sourceFrameSize.width
        let cropSide = frame / opticalScale
        return Int(((frame - cropSide) / 2).rounded())
    }

    static var opticalCropSide: Int {
        Int(sourceFrameSize.width.rounded()) - (opticalCropInset * 2)
    }

    private static let cacheLock = NSLock()
    private static var idleSVGDataByURL: [URL: Data] = [:]
    private static var idleImagesByCacheKey: [MenuBarSizedImageCacheKey: NSImage] = [:]
    private static var croppedByURL: [URL: NSImage] = [:]
    private static var sizedByCacheKey: [MenuBarSizedImageCacheKey: NSImage] = [:]
    private static let alphaThreshold: UInt8 = 12

    static func resetCachesForTesting() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        idleSVGDataByURL = [:]
        idleImagesByCacheKey = [:]
        croppedByURL = [:]
        sizedByCacheKey = [:]
    }

    static func isVectorSVGRepresentation(_ image: NSImage) -> Bool {
        let hasBitmap = image.representations.contains { $0 is NSBitmapImageRep }
        guard !hasBitmap else { return false }
        return image.representations.contains { representation in
            String(describing: type(of: representation)).contains("SVG")
        }
    }

    static func bundledSVGURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: "svg")
    }

    static func make(
        fromSVG svgURL: URL,
        outputSize: NSSize
    ) -> NSImage? {
        let cacheKey = MenuBarSizedImageCacheKey(url: svgURL, outputSize: outputSize)
        cacheLock.lock()
        if let cached = idleImagesByCacheKey[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        let cachedData = idleSVGDataByURL[svgURL]
        cacheLock.unlock()

        let svgData: Data
        if let cachedData {
            svgData = cachedData
        } else {
            guard let made = makeIdleSVGMarkup(from: svgURL)?.data(using: .utf8) else {
                return nil
            }
            cacheLock.lock()
            if let existing = idleSVGDataByURL[svgURL] {
                cacheLock.unlock()
                svgData = existing
            } else {
                idleSVGDataByURL[svgURL] = made
                cacheLock.unlock()
                svgData = made
            }
        }

        guard let icon = NSImage(data: svgData) else {
            return nil
        }
        icon.size = outputSize
        icon.isTemplate = true
        cacheLock.lock()
        idleImagesByCacheKey[cacheKey] = icon
        cacheLock.unlock()
        return icon
    }

    static func makeIdleSVGMarkup(from svgURL: URL) -> String? {
        guard
            let svg = try? String(contentsOf: svgURL, encoding: .utf8),
            let inner = innerFrameMarkup(svg)
        else {
            return nil
        }
        let frame = Int(sourceFrameSize.width.rounded())
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(frame) \(frame)\"><defs><style>.cls-1{fill:none;}</style></defs>\(opticallyScaledInnerSVG(inner))</svg>"
    }

    static func opticallyScaledInnerSVG(_ inner: String) -> String {
        let frame = Int(sourceFrameSize.width.rounded())
        return "<svg overflow=\"hidden\" width=\"\(frame)\" height=\"\(frame)\" viewBox=\"\(opticalCropInset) \(opticalCropInset) \(opticalCropSide) \(opticalCropSide)\">\(inner)</svg>"
    }

    private static func innerFrameMarkup(_ svg: String) -> String? {
        guard
            let open = svg.range(of: "<svg"),
            let openEnd = svg[open.lowerBound...].range(of: ">"),
            let close = svg.range(of: "</svg>", options: [.backwards, .caseInsensitive])
        else {
            return nil
        }
        var inner = String(svg[openEnd.upperBound..<close.lowerBound])
        if let defsOpen = inner.range(of: "<defs>"),
           let defsClose = inner.range(of: "</defs>") {
            inner.removeSubrange(defsOpen.lowerBound..<defsClose.upperBound)
        }
        return inner
    }

    static func make(
        fromPNG pngURL: URL,
        outputSize: NSSize
    ) -> NSImage? {
        let cacheKey = MenuBarSizedImageCacheKey(url: pngURL, outputSize: outputSize)
        cacheLock.lock()
        if let cached = sizedByCacheKey[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        let cachedCrop = croppedByURL[pngURL]
        cacheLock.unlock()

        guard let cropped = cachedCrop ?? croppedTemplate(fromPNG: pngURL) else {
            return nil
        }
        cacheLock.lock()
        croppedByURL[pngURL] = cropped
        cacheLock.unlock()

        let sized = sizedTemplate(from: cropped, outputSize: outputSize)
        cacheLock.lock()
        sizedByCacheKey[cacheKey] = sized
        cacheLock.unlock()
        return sized
    }

    static func croppedTemplate(fromPNG pngURL: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: pngURL) else { return nil }
        if let cropped = croppedTemplate(from: image) {
            return cropped
        }
        image.isTemplate = true
        return image
    }

    static func croppedTemplate(from image: NSImage) -> NSImage? {
        guard
            let rep = bitmapRepresentation(of: image),
            let crop = squareOpaqueCrop(in: rep),
            let cgImage = rep.cgImage?.cropping(to: crop)
        else {
            return nil
        }
        let cropped = NSImage(
            cgImage: cgImage,
            size: NSSize(width: crop.width, height: crop.height)
        )
        cropped.isTemplate = true
        return cropped
    }

    /// Keeps the cropped bitmap and only changes the point size. Drawing into
    /// an `NSImage(size: slot)` block would bake an 18 px 1x image on Retina.
    private static func sizedTemplate(from image: NSImage, outputSize: NSSize) -> NSImage {
        var rect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            let sized = NSImage(cgImage: cgImage, size: outputSize)
            sized.isTemplate = true
            return sized
        }
        let sized = NSImage()
        for representation in image.representations {
            sized.addRepresentation(representation)
        }
        sized.size = outputSize
        sized.isTemplate = true
        return sized
    }

    private static func bitmapRepresentation(of image: NSImage) -> NSBitmapImageRep? {
        if let existing = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return existing
        }
        var rect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return NSBitmapImageRep(cgImage: cgImage)
        }
        return image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    }

    private static func squareOpaqueCrop(in rep: NSBitmapImageRep) -> CGRect? {
        guard
            let data = rep.bitmapData,
            rep.pixelsWide > 0,
            rep.pixelsHigh > 0,
            rep.bitsPerPixel >= 32
        else {
            return nil
        }
        let bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        let alphaOffset = rep.bitmapFormat.contains(.alphaFirst) ? 0 : bytesPerPixel - 1
        var minX = rep.pixelsWide
        var minY = rep.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<rep.pixelsHigh {
            let row = y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                let alpha = data[row + x * bytesPerPixel + alphaOffset]
                guard alpha > alphaThreshold else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let contentWidth = maxX - minX + 1
        let contentHeight = maxY - minY + 1
        let side = min(
            max(contentWidth, contentHeight),
            rep.pixelsWide,
            rep.pixelsHigh
        )
        var originX = minX - (side - contentWidth) / 2
        var originY = minY - (side - contentHeight) / 2
        originX = max(0, min(originX, rep.pixelsWide - side))
        originY = max(0, min(originY, rep.pixelsHigh - side))
        return CGRect(x: originX, y: originY, width: side, height: side)
    }
}
