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
    static let frameDuration: TimeInterval = 0.09
    static let defaultFrameDuration = frameDuration
    static let duration: TimeInterval = frameDuration * Double(frameCount)

    static func translationValues(frameHeight: CGFloat) -> [NSNumber] {
        (0..<frameCount).map { index in
            NSNumber(value: -Double(frameHeight) * Double(index))
        }
    }
}

/// Builds the Claude thinking sprite once at a visual invalidation boundary.
/// The returned image contains the same nine discrete SVG view-box frames that
/// the old animator displayed, stacked from the first frame at the bottom to
/// the last frame at the top for a Core Animation Y translation.
enum ClaudeThinkingSprite {
    static func make(
        from animatedSVGURL: URL,
        outputSize: NSSize = NSSize(width: 16, height: 16)
    ) -> NSImage? {
        guard
            let svg = try? String(contentsOf: animatedSVGURL, encoding: .utf8),
            let frames = makeFrames(from: svg)
        else {
            return nil
        }
        return makeSprite(from: frames, outputSize: outputSize)
    }

    static func makeSprite(
        from frames: [NSImage],
        outputSize: NSSize = NSSize(width: 16, height: 16)
    ) -> NSImage? {
        guard
            frames.count == ClaudeThinkingAnimationTiming.frameCount,
            outputSize.width > 0,
            outputSize.height > 0
        else {
            return nil
        }

        let spriteSize = NSSize(
            width: outputSize.width,
            height: outputSize.height * CGFloat(ClaudeThinkingAnimationTiming.frameCount)
        )
        let sprite = NSImage(size: spriteSize, flipped: false) { _ in
            for (index, frame) in frames.enumerated() {
                let destination = NSRect(
                    x: 0,
                    y: outputSize.height * CGFloat(index),
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
            return true
        }
        sprite.isTemplate = true
        return sprite
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
