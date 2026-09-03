import AppKit
import XCTest
@testable import BalanceBar

final class MenuBarAnimationTests: XCTestCase {
    func testCodexAnimationKeepsItsDiscreteFrameCountDurationAndOrder() {
        XCTAssertEqual(RotatingTemplateImageView.frameCount, 36)
        XCTAssertEqual(RotatingTemplateImageView.rotationDuration, 1.2, accuracy: 0.000_001)
        XCTAssertEqual(
            RotatingTemplateImageView.rotationFrameInterval,
            1.2 / 36,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            Double(RotatingTemplateImageView.frameCount)
                / RotatingTemplateImageView.rotationDuration,
            30,
            accuracy: 0.000_001
        )

        var state = MenuBarAnimationState()
        let sequence = (0..<RotatingTemplateImageView.frameCount).compactMap { _ in
            state.advance(frameCount: RotatingTemplateImageView.frameCount)
        }
        XCTAssertEqual(sequence, Array(1..<RotatingTemplateImageView.frameCount) + [0])
        XCTAssertEqual(state.frameIndex, 0)
    }

    func testClaudeAnimationKeepsItsDiscreteFrameCountAndTempo() {
        XCTAssertEqual(ClaudeThinkingAnimator.frameCount, 9)
        XCTAssertEqual(ClaudeThinkingAnimator.defaultFrameDuration, 0.09, accuracy: 0.000_001)

        var state = MenuBarAnimationState()
        let sequence = (0..<ClaudeThinkingAnimator.frameCount).compactMap { _ in
            state.advance(frameCount: ClaudeThinkingAnimator.frameCount)
        }
        XCTAssertEqual(sequence, Array(1..<ClaudeThinkingAnimator.frameCount) + [0])
    }

    func testAnimationPolicyHonorsPreferenceAndSystemReduceMotion() {
        XCTAssertTrue(
            MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: true,
                preferenceEnabled: true
            )
        )
        XCTAssertFalse(
            MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: false,
                preferenceEnabled: true,
                reduceMotionEnabled: false
            )
        )
        XCTAssertFalse(
            MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: true,
                preferenceEnabled: false,
                reduceMotionEnabled: false
            )
        )
        XCTAssertFalse(
            MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: true,
                preferenceEnabled: true,
                reduceMotionEnabled: true
            )
        )
        XCTAssertTrue(
            MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: true,
                preferenceEnabled: true,
                reduceMotionEnabled: false
            )
        )
    }

    func testOverlayIconRasterKeepsLogicalAndPixelGeometryCentered() throws {
        let logicalSize = NSSize(width: 16, height: 16)
        let contentsScale: CGFloat = 2
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let sourceImage = makeCenteredAsymmetricMarkerImage(size: logicalSize)

        let raster = try XCTUnwrap(
            MenuBarAnimationOverlayController.makeTintedLayerRaster(
                from: sourceImage,
                size: logicalSize,
                scale: contentsScale,
                appearance: appearance
            )
        )

        XCTAssertEqual(raster.logicalSize, logicalSize)
        XCTAssertEqual(raster.contentsScale, contentsScale, accuracy: 0.000_001)
        XCTAssertEqual(raster.cgImage.width, 32)
        XCTAssertEqual(raster.cgImage.height, 32)

        let metrics = try alphaMetrics(for: raster.cgImage)
        XCTAssertEqual(metrics.centroid.x, 16, accuracy: 0.5)
        XCTAssertEqual(metrics.centroid.y, 16, accuracy: 0.5)
        XCTAssertEqual(metrics.bounds.midX, 16, accuracy: 1)
        XCTAssertEqual(metrics.bounds.midY, 16, accuracy: 1)
    }

    func testOverlayIconRenderedRotationKeepsVisibleRasterCentroidAtLayerCenter() throws {
        let logicalSize = NSSize(width: 16, height: 16)
        let contentsScale: CGFloat = 2
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let sourceImage = makeCenteredAsymmetricMarkerImage(size: logicalSize)
        let raster = try XCTUnwrap(
            MenuBarAnimationOverlayController.makeTintedLayerRaster(
                from: sourceImage,
                size: logicalSize,
                scale: contentsScale,
                appearance: appearance
            )
        )

        let rootLayer = CALayer()
        rootLayer.frame = NSRect(origin: .zero, size: logicalSize)
        rootLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        rootLayer.position = CGPoint(
            x: logicalSize.width / 2,
            y: logicalSize.height / 2
        )
        rootLayer.contentsScale = contentsScale

        let iconLayer = CALayer()
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.bounds = NSRect(origin: .zero, size: logicalSize)
        iconLayer.position = CGPoint(
            x: logicalSize.width / 2,
            y: logicalSize.height / 2
        )
        iconLayer.contents = raster.cgImage
        iconLayer.contentsScale = raster.contentsScale
        iconLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        iconLayer.contentsGravity = .resize
        rootLayer.addSublayer(iconLayer)

        let expectedCenter = CGPoint(
            x: logicalSize.width * contentsScale / 2,
            y: logicalSize.height * contentsScale / 2
        )
        for angle in [0, Double.pi / 2, Double.pi, Double.pi * 1.5] {
            iconLayer.setAffineTransform(
                CGAffineTransform(rotationAngle: CGFloat(angle))
            )
            let rendered = try XCTUnwrap(
                renderLayer(
                    rootLayer,
                    logicalSize: logicalSize,
                    contentsScale: contentsScale
                )
            )
            let metrics = try alphaMetrics(for: rendered)
            XCTAssertEqual(metrics.centroid.x, expectedCenter.x, accuracy: 0.5)
            XCTAssertEqual(metrics.centroid.y, expectedCenter.y, accuracy: 0.5)
        }
    }

    func testFrameDisplayDoesNotEmitSemanticSourceChangesAndStopRestoresSource() {
        let imageView = RotatingTemplateImageView(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16)
        )
        let source = NSImage(size: NSSize(width: 16, height: 16))
        let frame = NSImage(size: NSSize(width: 16, height: 16))
        var sourceChanges: [NSImage?] = []
        var displayedImages: [NSImage?] = []
        imageView.onSourceImageChanged = { sourceChanges.append($0) }
        imageView.onFrameImageChanged = { displayedImages.append($0) }

        imageView.setSourceImage(source)
        XCTAssertEqual(sourceChanges.count, 1)
        XCTAssertEqual(displayedImages.count, 0)
        XCTAssertTrue(imageView.image === source)
        XCTAssertEqual(imageView.animationFrames.count, RotatingTemplateImageView.frameCount)

        imageView.displayImage(frame)
        XCTAssertEqual(sourceChanges.count, 1)
        XCTAssertEqual(displayedImages.count, 1)
        XCTAssertTrue(displayedImages.compactMap { $0 }.last === frame)
        XCTAssertTrue(imageView.image === frame)

        imageView.stopRotating()
        imageView.stopRotating()
        XCTAssertFalse(imageView.isRotating)
        XCTAssertEqual(sourceChanges.count, 1)
        XCTAssertEqual(displayedImages.count, 2)
        XCTAssertTrue(displayedImages.compactMap { $0 }.last === source)
        XCTAssertTrue(imageView.image === source)

        imageView.setSourceImage(source)
        XCTAssertEqual(sourceChanges.count, 1)

        let nextSource = NSImage(size: NSSize(width: 16, height: 16))
        imageView.setSourceImage(nextSource)
        XCTAssertEqual(sourceChanges.count, 2)
        XCTAssertTrue(imageView.image === nextSource)
    }

    func testStartingTheSameRotationTwiceKeepsOneLifecycleAndStoppingIsIdempotent() {
        let imageView = RotatingTemplateImageView(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16)
        )
        imageView.setSourceImage(NSImage(size: NSSize(width: 16, height: 16)))

        imageView.startRotating()
        imageView.startRotating()
        XCTAssertTrue(imageView.isRotating)

        imageView.stopRotating()
        imageView.stopRotating()
        XCTAssertFalse(imageView.isRotating)
    }

    func testStatusItemWiringKeepsLayoutAndDashboardRefreshOnSourcePathOnly() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let animationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "work/balance-bar/Sources/UI/MenuBar/MenuBarAnimation.swift"
            ),
            encoding: .utf8
        )
        let statusItemSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "work/balance-bar/Sources/UI/MenuBar/StatusItemController.swift"
            ),
            encoding: .utf8
        )

        let frameStart = try XCTUnwrap(animationSource.range(of: "private func advanceRotation()"))
        let frameEnd = try XCTUnwrap(
            animationSource.range(
                of: "private static func makeRotationFrames",
                range: frameStart.upperBound..<animationSource.endIndex
            )
        )
        let framePath = String(animationSource[frameStart.lowerBound..<frameEnd.lowerBound])
        XCTAssertTrue(framePath.contains("onAnimationFrameIndexChanged"))
        XCTAssertTrue(framePath.contains("displayImage(frame)"))
        XCTAssertFalse(framePath.contains("onSourceImageChanged"))
        XCTAssertFalse(framePath.contains("layoutStatusItem"))
        XCTAssertFalse(framePath.contains("iconChanged"))

        let displayStart = try XCTUnwrap(animationSource.range(of: "func displayImage"))
        let restoreStart = try XCTUnwrap(
            animationSource.range(
                of: "func restoreSourceImage",
                range: displayStart.upperBound..<animationSource.endIndex
            )
        )
        let displayPath = String(animationSource[displayStart.lowerBound..<restoreStart.lowerBound])
        XCTAssertTrue(displayPath.contains("onFrameImageChanged"))
        XCTAssertFalse(displayPath.contains("onSourceImageChanged"))

        let semanticStart = try XCTUnwrap(
            statusItemSource.range(of: "menuBarIconView.onSourceImageChanged = {")
        )
        let semanticEnd = try XCTUnwrap(
            statusItemSource.range(
                of: "actions.iconChanged(image)",
                range: semanticStart.upperBound..<statusItemSource.endIndex
            )
        )
        let semanticPath = String(
            statusItemSource[semanticStart.lowerBound..<semanticEnd.upperBound]
        )
        XCTAssertTrue(semanticPath.contains("layoutStatusItem"))
        XCTAssertTrue(semanticPath.contains("actions.iconChanged"))
        XCTAssertFalse(semanticPath.contains("menuBarIconView.image = image"))

        let frameCallbackStart = try XCTUnwrap(
            statusItemSource.range(of: "menuBarIconView.onFrameImageChanged = {")
        )
        let frameCallbackEnd = try XCTUnwrap(
            statusItemSource.range(
                of: "actions.frameImageChanged(image)",
                range: frameCallbackStart.upperBound..<statusItemSource.endIndex
            )
        )
        let frameCallbackPath = String(
            statusItemSource[frameCallbackStart.lowerBound..<frameCallbackEnd.upperBound]
        )
        XCTAssertFalse(frameCallbackPath.contains("applyCachedCodexAnimationFrame"))
        XCTAssertTrue(frameCallbackPath.contains("activeClient != .codex"))
        XCTAssertTrue(frameCallbackPath.contains("composeMenuBarContentBitmap"))

        let indexCallbackStart = try XCTUnwrap(
            statusItemSource.range(of: "menuBarIconView.onAnimationFrameIndexChanged = {")
        )
        let indexCallbackEnd = try XCTUnwrap(
            statusItemSource.range(
                of: "actions.frameImageChanged(frame)",
                range: indexCallbackStart.upperBound..<statusItemSource.endIndex
            )
        )
        let indexCallbackPath = String(
            statusItemSource[indexCallbackStart.lowerBound..<indexCallbackEnd.upperBound]
        )
        XCTAssertTrue(indexCallbackPath.contains("applyStableCodexAnimationFrame"))
        XCTAssertTrue(indexCallbackPath.contains("actions.frameImageChanged(frame)"))

        let compositionSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "work/balance-bar/Sources/UI/Dashboard/DashboardCompositionController.swift"
            ),
            encoding: .utf8
        )
        let previewUpdateStart = try XCTUnwrap(
            compositionSource.range(of: "func updateMenuBarPreviewIcon")
        )
        let previewUpdateEnd = try XCTUnwrap(
            compositionSource.range(
                of: "func refreshMenuBarWidthAdjustment",
                range: previewUpdateStart.upperBound..<compositionSource.endIndex
            )
        )
        let previewUpdatePath = String(
            compositionSource[previewUpdateStart.lowerBound..<previewUpdateEnd.lowerBound]
        )
        XCTAssertTrue(previewUpdatePath.contains("updateMenuBarPreviewIcon"))
        XCTAssertFalse(previewUpdatePath.contains("refreshMenuBarPage"))

        let menuBarPageSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "work/balance-bar/Sources/UI/Dashboard/Pages/Preferences/DashboardMenuBarPage.swift"
            ),
            encoding: .utf8
        )
        let pagePreviewStart = try XCTUnwrap(
            menuBarPageSource.range(of: "func updatePreviewIcon")
        )
        let pagePreviewEnd = try XCTUnwrap(
            menuBarPageSource.range(
                of: "private static func makeOverflowWarningRow",
                range: pagePreviewStart.upperBound..<menuBarPageSource.endIndex
            )
        )
        let pagePreviewPath = String(
            menuBarPageSource[pagePreviewStart.lowerBound..<pagePreviewEnd.lowerBound]
        )
        XCTAssertTrue(pagePreviewPath.contains("previewIcon.image = image"))
        XCTAssertFalse(pagePreviewPath.contains("layoutSubtreeIfNeeded"))
    }

    private struct AlphaMetrics {
        let centroid: CGPoint
        let bounds: CGRect
    }

    private func makeCenteredAsymmetricMarkerImage(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            let markerSize: CGFloat = 2
            NSRect(
                x: rect.midX - 5,
                y: rect.midY - 5,
                width: markerSize,
                height: markerSize
            ).fill()
            NSRect(
                x: rect.midX + 3,
                y: rect.midY + 3,
                width: markerSize,
                height: markerSize
            ).fill()
            return true
        }
    }

    private func renderLayer(
        _ layer: CALayer,
        logicalSize: NSSize,
        contentsScale: CGFloat
    ) -> CGImage? {
        let pixelsWide = Int((logicalSize.width * contentsScale).rounded())
        let pixelsHigh = Int((logicalSize.height * contentsScale).rounded())
        guard let context = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: pixelsWide * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.saveGState()
        context.scaleBy(x: contentsScale, y: contentsScale)
        layer.render(in: context)
        context.restoreGState()
        return context.makeImage()
    }

    private func alphaMetrics(for image: CGImage) throws -> AlphaMetrics {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var alphaTotal: CGFloat = 0
        var weightedX: CGFloat = 0
        var weightedY: CGFloat = 0
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1

        for y in 0..<image.height {
            for x in 0..<image.width {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                guard alpha > 0.01 else { continue }
                let weight = alpha
                alphaTotal += weight
                weightedX += (CGFloat(x) + 0.5) * weight
                weightedY += (CGFloat(y) + 0.5) * weight
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard alphaTotal > 0, maxX >= minX, maxY >= minY else {
            throw NSError(
                domain: "BalanceBarTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Rendered layer contains no alpha"]
            )
        }
        return AlphaMetrics(
            centroid: CGPoint(
                x: weightedX / alphaTotal,
                y: weightedY / alphaTotal
            ),
            bounds: CGRect(
                x: CGFloat(minX),
                y: CGFloat(minY),
                width: CGFloat(maxX - minX + 1),
                height: CGFloat(maxY - minY + 1)
            )
        )
    }
}
