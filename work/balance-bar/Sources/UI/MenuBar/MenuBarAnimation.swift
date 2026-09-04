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

/// Supported animation cadences for the native status-item renderer. The
/// duration is the single source of truth for frame count and timer interval,
/// so changing cadence never leaves the renderer with mismatched timing and
/// frame data. This is intentionally a typed backend value rather than a
/// boolean so additional cadences can be added without changing the API shape.
enum MenuBarAnimationFrameRate: Int, CaseIterable, Equatable {
    case fps15 = 15
    case fps30 = 30

    static let defaultValue: Self = .fps30
    static let rotationDuration: TimeInterval = 1.2

    var framesPerSecond: Double { Double(rawValue) }

    var frameCount: Int {
        Int((Self.rotationDuration * framesPerSecond).rounded())
    }

    var frameInterval: TimeInterval {
        Self.rotationDuration / Double(frameCount)
    }
}

/// Selects the Codex animation implementation used by a status-item
/// controller.  The native Core Animation case is intentionally injectable so
/// the stacked Issue #300 experiment can be exercised without deleting the D0
/// bitmap backend or changing the production candidate branch.
enum MenuBarCodexAnimationBackend: Equatable {
    case stableBitmap
    case nativeCoreAnimation
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
    /// The default is 36 discrete frames over a 1.2 s rotation = 30 fps. Pixel updates
    /// are the only way the macOS 26 status-item replicant snapshot can show
    /// motion (it renders model state via renderInContext, so render-server-
    /// side animations are invisible), so this animation intentionally keeps
    /// a fixed, bounded update cadence.
    static let defaultFrameRate = MenuBarAnimationFrameRate.defaultValue
    static let frameCount = defaultFrameRate.frameCount
    static let rotationDuration: TimeInterval = MenuBarAnimationFrameRate.rotationDuration
    static let rotationFrameInterval = defaultFrameRate.frameInterval
    private(set) var frameRate: MenuBarAnimationFrameRate
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

    init(frame frameRect: NSRect, frameRate: MenuBarAnimationFrameRate = .defaultValue) {
        self.frameRate = frameRate
        super.init(frame: frameRect)
    }

    override init(frame frameRect: NSRect) {
        self.frameRate = .defaultValue
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        self.frameRate = .defaultValue
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
        if sourceChanged {
            rotationFrames = prepareAnimationFrames
                ? Self.makeRotationFrames(from: image, frameRate: frameRate)
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

    /// Changes the backend cadence without creating a second timer. When the
    /// animation is already running, retain its normalized phase and install
    /// exactly one replacement timer using the new interval.
    func setFrameRate(_ frameRate: MenuBarAnimationFrameRate) {
        guard self.frameRate != frameRate else { return }

        let wasRotating = rotationTimer != nil
        let oldFrameCount = rotationFrames.count
        let normalizedPhase = oldFrameCount > 0
            ? Double(animationState.frameIndex) / Double(oldFrameCount)
            : 0

        rotationTimer?.invalidate()
        rotationTimer = nil
        self.frameRate = frameRate
        if let sourceImage {
            rotationFrames = Self.makeRotationFrames(from: sourceImage, frameRate: frameRate)
        } else {
            rotationFrames.removeAll(keepingCapacity: false)
        }
        animationState.setFrameIndex(
            Int((normalizedPhase * Double(frameRate.frameCount)).rounded()),
            frameCount: rotationFrames.count
        )

        if wasRotating {
            installRotationTimer()
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
        let runningTimer = Timer(timeInterval: frameRate.frameInterval, repeats: true) { [weak self] _ in
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
        from sourceImage: NSImage,
        frameRate: MenuBarAnimationFrameRate
    ) -> [NSImage] {
        (0..<frameRate.frameCount).map { index in
            let angle = -(2 * .pi * CGFloat(index) / CGFloat(frameRate.frameCount))
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
