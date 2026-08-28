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
        taskRunning && preferenceEnabled
    }
}

final class RotatingTemplateImageView: PassthroughImageView {
    private static let frameCount = 36
    private static let rotationDuration: TimeInterval = 1.15
    private var sourceImage: NSImage?
    private var rotationFrames: [NSImage] = []
    private var rotationTimer: Timer?
    private var animationState = MenuBarAnimationState()
    /// Reports source-image changes that can affect the Dashboard preview.
    var onImageChanged: ((NSImage?) -> Void)?
    var isRotating: Bool { rotationTimer != nil }

    func setSourceImage(_ image: NSImage) {
        if sourceImage !== image {
            rotationFrames = Self.makeRotationFrames(from: image)
        }
        sourceImage = image
        self.image = image
        onImageChanged?(image)
    }

    func displayImage(_ image: NSImage) {
        // Animation frames keep the existing status-item geometry; semantic
        // callbacks remain reserved for source-image changes.
        self.image = image
    }

    func startRotating() {
        guard rotationTimer == nil, !rotationFrames.isEmpty else { return }
        animationState.reset()
        let interval = Self.rotationDuration / Double(Self.frameCount)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceRotation()
        }
        timer.tolerance = 0.002
        rotationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopRotating() {
        let wasRotating = rotationTimer != nil
        rotationTimer?.invalidate()
        rotationTimer = nil
        animationState.reset()
        image = sourceImage
        if wasRotating { onImageChanged?(sourceImage) }
    }

    private func advanceRotation() {
        guard let frameIndex = animationState.advance(frameCount: rotationFrames.count) else {
            return
        }
        let frame = rotationFrames[frameIndex]
        image = frame
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
        frameDuration: TimeInterval = 0.09,
        outputSize: NSSize = NSSize(width: 16, height: 16)
    ) {
        guard
            let svg = try? String(contentsOf: animatedSVGURL, encoding: .utf8),
            let frames = Self.makeFrames(from: svg),
            frames.count == 9
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
        timer?.invalidate()
        timer = nil
        animationState.reset()
        imageView?.setSourceImage(staticImage)
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
