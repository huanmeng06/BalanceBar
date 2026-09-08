import AppKit
import XCTest
@testable import BalanceBar

final class MenuBarAnimationTests: XCTestCase {
    func testCodexAnimationKeepsItsDiscreteFrameCountDurationAndOrder() {
        XCTAssertEqual(RotatingTemplateImageView.frameCount, MenuBarAnimationTiming.frameCount)
        XCTAssertEqual(RotatingTemplateImageView.frameCount, 36)
        XCTAssertEqual(RotatingTemplateImageView.rotationDuration, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(
            RotatingTemplateImageView.rotationFrameInterval,
            1.5 / 36,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            Double(RotatingTemplateImageView.frameCount)
                / RotatingTemplateImageView.rotationDuration,
            24,
            accuracy: 0.000_001
        )

        var state = MenuBarAnimationState()
        let sequence = (0..<RotatingTemplateImageView.frameCount).compactMap { _ in
            state.advance(frameCount: RotatingTemplateImageView.frameCount)
        }
        XCTAssertEqual(sequence, Array(1..<RotatingTemplateImageView.frameCount) + [0])
        XCTAssertEqual(state.frameIndex, 0)
    }

    func testTemplateIconEmphasisRaisesMidtoneCoverageWithoutFillingTransparentPixels() throws {
        let size = NSSize(width: 16, height: 16)
        let faint = NSImage(size: size, flipped: true) { rect in
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            return true
        }
        faint.isTemplate = true

        let strengthened = try XCTUnwrap(
            MenuBarTemplateIconEmphasis.strengthenedTemplateImage(
                faint,
                drawingSize: size,
                scale: 2
            )
        )
        XCTAssertTrue(strengthened.isTemplate)
        XCTAssertEqual(strengthened.size, size)

        let originalAlpha = meanVisibleAlpha(of: faint, size: size)
        let boostedAlpha = meanVisibleAlpha(of: strengthened, size: size)
        XCTAssertGreaterThan(
            boostedAlpha,
            originalAlpha + 0.05,
            "inactive-display GPT marks must gain coverage, not an opaque backdrop"
        )
        XCTAssertLessThan(boostedAlpha, 1, "transparent holes in the GPT silhouette must remain")
        XCTAssertEqual(meanAlpha(of: faint, size: size, onlyZero: true), 0, accuracy: 0.001)
        XCTAssertEqual(
            meanAlpha(of: strengthened, size: size, onlyZero: true),
            0,
            accuracy: 0.001,
            "emphasis must not paint the empty template background"
        )
    }

    func testCodexBackendsShareTheDiscreteThirtySixStateCadenceContract() {
        XCTAssertEqual(MenuBarAnimationTiming.frameCount, 36)
        XCTAssertEqual(MenuBarAnimationTiming.defaultFrameRate, 24)
        XCTAssertEqual(MenuBarAnimationTiming.rotationDuration, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(
            Double(MenuBarAnimationTiming.frameCount) / MenuBarAnimationTiming.rotationDuration,
            24,
            accuracy: 0.000_001
        )
        XCTAssertEqual(MenuBarAnimationTiming.frameInterval(fps: 10), 0.1, accuracy: 0.000_001)
        XCTAssertEqual(MenuBarAnimationTiming.rotationDuration(fps: 10), 3.6, accuracy: 0.000_001)
        XCTAssertEqual(MenuBarAnimationTiming.clampedFrameRate(5), 6)
        XCTAssertEqual(MenuBarAnimationTiming.clampedFrameRate(61), 60)
        XCTAssertEqual(
            MenuBarCodexAnimationBackend(mode: .efficient),
            .nativeCoreAnimation
        )
        XCTAssertEqual(
            MenuBarCodexAnimationBackend(mode: .synchronized),
            .stableBitmap
        )
    }

    func testSynchronizedCodexFramesAdvanceClockwiseThroughOneThirtySixStateRevolution() throws {
        XCTAssertEqual(
            MenuBarCodexAnimationBackend(mode: .synchronized),
            .stableBitmap,
            "D0 must continue to use the pre-rendered bitmap frame path"
        )
        XCTAssertEqual(RotatingTemplateImageView.frameCount, 36)
        XCTAssertEqual(RotatingTemplateImageView.rotationDuration, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(
            Double(RotatingTemplateImageView.frameCount)
                / RotatingTemplateImageView.rotationDuration,
            24,
            accuracy: 0.000_001
        )

        let imageView = RotatingTemplateImageView(
            frame: NSRect(x: 0, y: 0, width: 128, height: 128)
        )
        let sourceImage = makeClockwiseDirectionProbeImage()
        imageView.setSourceImage(sourceImage)

        let frames = imageView.animationFrames
        XCTAssertEqual(frames.count, RotatingTemplateImageView.frameCount)
        let markerCentroids = try frames.map(markerCentroid(in:))
        let center = CGPoint(
            x: sourceImage.size.width / 2,
            y: sourceImage.size.height / 2
        )
        // NSBitmapImageRep exposes rows from the top while AppKit's unflipped
        // drawing context rotates in a bottom-origin coordinate system.
        let vectors = markerCentroids.map {
            CGPoint(x: $0.x - center.x, y: center.y - $0.y)
        }

        let firstVector = try XCTUnwrap(vectors.first)
        let secondVector = try XCTUnwrap(vectors.dropFirst().first)
        let firstToSecondCrossProduct = Double(
            firstVector.x * secondVector.y - firstVector.y * secondVector.x
        )
        XCTAssertLessThan(
            firstToSecondCrossProduct,
            0,
            "the second generated D0 state must move clockwise from the first state"
        )

        let expectedClockwiseStep = 2 * Double.pi / Double(RotatingTemplateImageView.frameCount)
        let angles = vectors.map { vector in
            atan2(Double(vector.y), Double(vector.x))
        }
        var revolution = 0.0
        for index in angles.indices {
            let nextIndex = (index + 1) % angles.count
            let step = clockwiseAngularDelta(
                from: angles[index],
                to: angles[nextIndex]
            )
            XCTAssertEqual(
                step,
                expectedClockwiseStep,
                accuracy: 0.08,
                "D0 frame \(index) must advance clockwise by one of 36 equal states"
            )
            revolution += step
        }
        XCTAssertEqual(
            revolution,
            2 * Double.pi,
            accuracy: 0.16,
            "the 36-state D0 sequence must close after one clockwise revolution"
        )

        var state = MenuBarAnimationState()
        let sequence = (0..<RotatingTemplateImageView.frameCount).compactMap { _ in
            state.advance(frameCount: RotatingTemplateImageView.frameCount)
        }
        XCTAssertEqual(
            sequence,
            Array(1..<RotatingTemplateImageView.frameCount) + [0],
            "the synchronized frame state must visit all 36 states and wrap to zero"
        )
    }

    func testNativeCoreAnimationHostUsesDiscreteCenterPivotContract() throws {
        let host = MenuBarNativeAnimatedIconHostView(
            frame: NSRect(x: 7, y: 11, width: 16, height: 16)
        )
        host.updateGeometry(
            frame: NSRect(x: 19, y: 23, width: 18, height: 18),
            contentsScale: 2
        )

        XCTAssertEqual(host.iconLayer.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(host.iconLayer.bounds, NSRect(x: 0, y: 0, width: 18, height: 18))
        XCTAssertEqual(
            host.iconLayer.position,
            CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        )
        XCTAssertEqual(host.iconLayer.contentsScale, 2)
        XCTAssertTrue(host.subviews.isEmpty)

        let sourceImage = NSImage(size: NSSize(width: 16, height: 16))
        sourceImage.isTemplate = true
        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: NSAppearance(named: .aqua)!,
                contentsScale: 2
            )
        )
        let rasterizationCount = host.contentsRasterizationCount
        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: NSAppearance(named: .aqua)!,
                contentsScale: 2
            )
        )
        XCTAssertEqual(
            host.contentsRasterizationCount,
            rasterizationCount,
            "steady-state synchronization must not rerasterize the icon"
        )

        host.installRotationAnimation()
        let animation = try XCTUnwrap(host.rotationAnimationForTesting)
        XCTAssertEqual(animation.keyPath, "transform.rotation.z")
        let values = try XCTUnwrap(animation.values as? [NSNumber])
        XCTAssertEqual(values[0].doubleValue, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(
            values[1].doubleValue,
            0,
            "positive layer rotation is the clockwise screen-space direction"
        )
        XCTAssertEqual(animation.duration, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(animation.calculationMode, .discrete)
        XCTAssertEqual(animation.repeatCount, Float.infinity)
        XCTAssertEqual(animation.values?.count, 36)
        XCTAssertEqual(animation.keyTimes?.count, 36)
        let firstKeyTime = try XCTUnwrap(animation.keyTimes?.first)
        let lastKeyTime = try XCTUnwrap(animation.keyTimes?.last)
        XCTAssertEqual(firstKeyTime.doubleValue, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            lastKeyTime.doubleValue,
            35.0 / 36.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(host.rotationAnimationInstallCount, 1)

        host.installRotationAnimation()
        XCTAssertEqual(
            host.rotationAnimationInstallCount,
            1,
            "repeated synchronization must not install a second CA animation"
        )
        host.removeRotationAnimation()
        host.removeRotationAnimation()
        XCTAssertNil(host.rotationAnimationForTesting)
    }

    func testNativeCoreAnimationHostHasNoPerFrameSchedulerOrAppKitRedrawPath() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "work/balance-bar/Sources/UI/MenuBar/MenuBarViews.swift"
            ),
            encoding: .utf8
        )
        let hostStart = try XCTUnwrap(
            viewsSource.range(of: "final class MenuBarNativeAnimatedIconHostView")
        )
        let hostEnd = try XCTUnwrap(
            viewsSource.range(
                of: "final class MenuBarClaudeAnimatedIconHostView",
                range: hostStart.upperBound..<viewsSource.endIndex
            )
        )
        let hostSource = String(viewsSource[hostStart.lowerBound..<hostEnd.lowerBound])
        XCTAssertFalse(hostSource.contains("Timer"))
        XCTAssertFalse(hostSource.contains("CADisplayLink"))
        XCTAssertFalse(hostSource.contains("DispatchSourceTimer"))
        XCTAssertFalse(hostSource.contains("needsDisplay"))
        XCTAssertFalse(hostSource.contains("setNeedsDisplay"))
        XCTAssertFalse(hostSource.contains("NSVisualEffectView"))
        XCTAssertFalse(hostSource.contains("backgroundColor"))
    }

    func testClaudeCoreAnimationHostUsesDiscreteSpriteTranslationContract() throws {
        let host = MenuBarClaudeAnimatedIconHostView(
            frame: NSRect(x: 7, y: 11, width: 16, height: 16)
        )
        host.updateGeometry(
            frame: NSRect(x: 19, y: 23, width: 18, height: 18),
            contentsScale: 2
        )

        XCTAssertEqual(host.iconLayer.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(host.iconLayer.bounds, NSRect(x: 0, y: 0, width: 18, height: 18))
        XCTAssertEqual(
            host.iconLayer.position,
            CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        )
        XCTAssertEqual(host.spriteLayer.bounds.size, NSSize(width: 18, height: 162))
        XCTAssertEqual(host.spriteLayer.position, .zero)

        let sprite = NSImage(size: NSSize(width: 16, height: 144), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        sprite.isTemplate = true
        XCTAssertTrue(
            host.updateContents(
                spriteImage: sprite,
                frameSize: NSSize(width: 16, height: 16),
                appearance: NSAppearance(named: .aqua)!,
                contentsScale: 2
            )
        )
        let rasterizationCount = host.spriteRasterizationCount
        XCTAssertTrue(
            host.updateContents(
                spriteImage: sprite,
                frameSize: NSSize(width: 16, height: 16),
                appearance: NSAppearance(named: .aqua)!,
                contentsScale: 2
            )
        )
        XCTAssertEqual(
            host.spriteRasterizationCount,
            rasterizationCount,
            "steady-state synchronization must not rerasterize the sprite"
        )

        host.installThinkingAnimation()
        let animation = try XCTUnwrap(host.thinkingAnimationForTesting)
        XCTAssertEqual(animation.keyPath, "transform.translation.y")
        let values = try XCTUnwrap(animation.values as? [NSNumber])
        XCTAssertEqual(
            values.map(\.doubleValue),
            ClaudeThinkingAnimationTiming.translationValues(frameHeight: 18)
                .map(\.doubleValue)
        )
        XCTAssertEqual(
            host.modelTranslationYForTesting,
            ClaudeThinkingAnimationTiming.translationValue(
                frameIndex: ClaudeThinkingAnimationTiming.restingFrameIndex,
                frameHeight: 18
            ),
            accuracy: 0.000_001,
            "the model layer must rest on the peak frame for inactive-display replicants"
        )
        XCTAssertEqual(animation.duration, 0.81, accuracy: 0.000_001)
        XCTAssertEqual(animation.calculationMode, .discrete)
        XCTAssertEqual(animation.repeatCount, Float.infinity)
        XCTAssertEqual(values.count, 9)
        XCTAssertEqual(animation.keyTimes?.count, 9)
        let firstKeyTime = try XCTUnwrap(animation.keyTimes?.first)
        let lastKeyTime = try XCTUnwrap(animation.keyTimes?.last)
        XCTAssertEqual(firstKeyTime.doubleValue, 0, accuracy: 0.000_001)
        XCTAssertEqual(lastKeyTime.doubleValue, 8.0 / 9.0, accuracy: 0.000_001)
        XCTAssertEqual(host.thinkingAnimationInstallCount, 1)

        host.installThinkingAnimation()
        XCTAssertEqual(host.thinkingAnimationInstallCount, 1)
        host.removeThinkingAnimation()
        host.removeThinkingAnimation()
        XCTAssertNil(host.thinkingAnimationForTesting)
    }

    func testClaudeGeometryChangeReanchorsPeakModelAndPreservesAnimationPhase() throws {
        let host = MenuBarClaudeAnimatedIconHostView(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16)
        )
        host.updateGeometry(
            frame: NSRect(x: 0, y: 0, width: 18, height: 18),
            contentsScale: 2
        )
        let sprite = NSImage(size: NSSize(width: 16, height: 144), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        sprite.isTemplate = true
        XCTAssertTrue(
            host.updateContents(
                spriteImage: sprite,
                frameSize: NSSize(width: 16, height: 16),
                appearance: NSAppearance(named: .aqua)!,
                contentsScale: 2
            )
        )
        host.installThinkingAnimation(phase: 0.37)
        let phaseBefore = try XCTUnwrap(host.currentThinkingPhaseForTesting)

        host.updateGeometry(
            frame: NSRect(x: 0, y: 0, width: 20, height: 20),
            contentsScale: 2
        )

        let phaseAfter = try XCTUnwrap(host.currentThinkingPhaseForTesting)
        XCTAssertEqual(phaseAfter, phaseBefore, accuracy: 0.03)
        XCTAssertEqual(
            host.modelTranslationYForTesting,
            ClaudeThinkingAnimationTiming.translationValue(
                frameIndex: ClaudeThinkingAnimationTiming.restingFrameIndex,
                frameHeight: 20
            ),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(host.thinkingAnimationForTesting?.values as? [NSNumber])
                .map(\.doubleValue),
            ClaudeThinkingAnimationTiming.translationValues(frameHeight: 20)
                .map(\.doubleValue)
        )
    }

    func testClaudeCoreAnimationHostHasNoPerFrameSchedulerOrAppKitRedrawPath() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "work/balance-bar/Sources/UI/MenuBar/MenuBarViews.swift"
            ),
            encoding: .utf8
        )
        let hostStart = try XCTUnwrap(
            viewsSource.range(of: "final class MenuBarClaudeAnimatedIconHostView")
        )
        let hostEnd = try XCTUnwrap(
            viewsSource.range(
                of: "private extension Double",
                range: hostStart.upperBound..<viewsSource.endIndex
            )
        )
        let hostSource = String(viewsSource[hostStart.lowerBound..<hostEnd.lowerBound])
        XCTAssertFalse(hostSource.contains("Timer"))
        XCTAssertFalse(hostSource.contains("CADisplayLink"))
        XCTAssertFalse(hostSource.contains("DispatchSourceTimer"))
        XCTAssertFalse(hostSource.contains("needsDisplay"))
        XCTAssertFalse(hostSource.contains("setNeedsDisplay"))
    }

    func testClaudeAnimationKeepsItsDiscreteFrameCountAndTempo() {
        XCTAssertEqual(ClaudeThinkingAnimationTiming.frameCount, 9)
        XCTAssertEqual(ClaudeThinkingAnimationTiming.restingFrameIndex, 4)
        XCTAssertEqual(
            ClaudeThinkingAnimationTiming.frameDuration,
            0.09,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            ClaudeThinkingAnimationTiming.duration,
            0.81,
            accuracy: 0.000_001
        )

        var state = MenuBarAnimationState()
        let sequence = (0..<ClaudeThinkingAnimationTiming.frameCount).compactMap { _ in
            state.advance(frameCount: ClaudeThinkingAnimationTiming.frameCount)
        }
        XCTAssertEqual(sequence, Array(1..<ClaudeThinkingAnimationTiming.frameCount) + [0])
        XCTAssertEqual(
            ClaudeThinkingAnimationTiming.translationValues(frameHeight: 16).map(\.doubleValue),
            [0, -16, -32, -48, -64, -80, -96, -112, -128]
        )
    }

    func testClaudeRestingFrameIndexMatchesTheRenderedSVGPeak() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(
            "work/balance-bar/ClaudeThinking.svg"
        )
        let svg = try String(contentsOf: sourceURL, encoding: .utf8)
        let frames = try XCTUnwrap(ClaudeThinkingSprite.makeFrames(from: svg))
        let inkAreas = try frames.map(inkArea(in:))
        let peakArea = try XCTUnwrap(inkAreas.max())
        XCTAssertEqual(
            inkAreas[ClaudeThinkingAnimationTiming.restingFrameIndex],
            peakArea,
            "the centered resting frame must be on the SVG's maximum-ink peak plateau"
        )
        XCTAssertLessThan(inkAreas[0], peakArea)
    }

    private func inkArea(in image: NSImage) throws -> Int {
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init))
        var area = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.05 {
                    area += 1
                }
            }
        }
        return area
    }

    func testClaudeThinkingSpriteBuilderPreservesTheBundledNineFrameStrip() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(
            "work/balance-bar/ClaudeThinking.svg"
        )

        let sprite = try XCTUnwrap(
            ClaudeThinkingSprite.make(
                from: sourceURL,
                outputSize: NSSize(width: 16, height: 16)
            )
        )
        XCTAssertEqual(sprite.size, NSSize(width: 16, height: 144))
        XCTAssertTrue(sprite.isTemplate)

        for preset in MenuBarIconSizePreset.allCases {
            let sized = try XCTUnwrap(
                ClaudeThinkingSprite.make(
                    from: sourceURL,
                    outputSize: NSSize(width: preset.pointSize, height: preset.pointSize)
                )
            )
            XCTAssertEqual(
                sized.size,
                NSSize(
                    width: preset.pointSize,
                    height: preset.pointSize * CGFloat(ClaudeThinkingAnimationTiming.frameCount)
                )
            )
            XCTAssertTrue(sized.isTemplate)
        }
    }

    func testGrokIdleIconLoadsRelocatedFrame16VectorSVG() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let idleURL = repositoryRoot.appendingPathComponent(
            "work/balance-bar/GrokIdle.svg"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: idleURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appendingPathComponent(
                    "work/balance-bar/GrokThinking"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appendingPathComponent(
                    "work/balance-bar/GrokThinking.png"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appendingPathComponent(
                    "work/balance-bar/GrokThinking.gif"
                ).path
            )
        )
        let idleSource = try String(contentsOf: idleURL, encoding: .utf8)
        XCTAssertTrue(idleSource.contains("viewBox=\"0 0 560 560\""))
        XCTAssertTrue(idleSource.contains("m532.29,39.28"))

        let idleMarkup = try XCTUnwrap(GrokIdleIcon.makeIdleSVGMarkup(from: idleURL))
        XCTAssertEqual(GrokIdleIcon.opticalScale, 1.12, accuracy: 0.000_001)
        XCTAssertEqual(GrokIdleIcon.opticalCropInset, 30)
        XCTAssertEqual(GrokIdleIcon.opticalCropSide, 500)
        XCTAssertTrue(idleMarkup.contains("viewBox=\"30 30 500 500\""))
        XCTAssertTrue(idleMarkup.contains(".cls-1{fill:none;}"))
        XCTAssertFalse(idleMarkup.contains(".cls-1{fill:#fff;}"))
        XCTAssertTrue(idleMarkup.contains("m532.29,39.28"))
        XCTAssertFalse(
            idleMarkup.contains("Grok.svg"),
            "live idle must be relocated Frame 16, not the old G spark"
        )

        GrokIdleIcon.resetCachesForTesting()
        let frameSize = NSSize(width: 16, height: 16)
        let idle = try XCTUnwrap(
            GrokIdleIcon.make(fromSVG: idleURL, outputSize: frameSize)
        )
        XCTAssertEqual(idle.size, frameSize)
        XCTAssertTrue(idle.isTemplate)
        XCTAssertTrue(GrokIdleIcon.isVectorSVGRepresentation(idle))
        XCTAssertTrue(
            idle.representations.compactMap { $0 as? NSBitmapImageRep }.isEmpty,
            "idle Grok must stay _NSSVGImageRep"
        )

        for preset in MenuBarIconSizePreset.allCases {
            let sized = try XCTUnwrap(
                GrokIdleIcon.make(
                    fromSVG: idleURL,
                    outputSize: NSSize(width: preset.pointSize, height: preset.pointSize)
                )
            )
            XCTAssertEqual(
                sized.size,
                NSSize(width: preset.pointSize, height: preset.pointSize)
            )
            XCTAssertTrue(GrokIdleIcon.isVectorSVGRepresentation(sized))
        }
    }

    func testGrokThinkingSpriteLoadsVectorSVGPack() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directoryURL = repositoryRoot.appendingPathComponent(
            "work/balance-bar/GrokThinking"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryURL.path))
        XCTAssertEqual(GrokThinkingAnimationTiming.frameCount, 30)
        XCTAssertEqual(GrokThinkingAnimationTiming.duration, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(
            GrokThinkingAnimationTiming.duration(fps: 30),
            1.0,
            accuracy: 0.000_001
        )

        GrokThinkingSprite.resetCachesForTesting()
        let sprite = try XCTUnwrap(
            GrokThinkingSprite.make(
                fromDirectory: directoryURL,
                outputSize: NSSize(width: 16, height: 16)
            )
        )
        XCTAssertEqual(
            sprite.size,
            NSSize(width: 16, height: 16 * CGFloat(GrokThinkingAnimationTiming.frameCount))
        )
        XCTAssertTrue(sprite.isTemplate)
        XCTAssertTrue(GrokThinkingSprite.isVectorSVGRepresentation(sprite))
        XCTAssertEqual(GrokThinkingSprite.fromGIFCallCountForTesting, 0)
        XCTAssertEqual(GrokThinkingAnimationTiming.restingFrameIndex, 15)
        XCTAssertEqual(
            GrokThinkingAnimationTiming.restingFrameIndex,
            GrokThinkingSprite.idleFrameIndex - 1
        )
        XCTAssertEqual(GrokThinkingSprite.synchronizedStripIndex(for: 0), 29)
        XCTAssertEqual(GrokThinkingSprite.synchronizedStripIndex(for: 29), 0)
        XCTAssertEqual(GrokThinkingSprite.synchronizedStripIndex(for: 14), 15)
        XCTAssertEqual(
            MenuBarSpriteAnimationTiming.grok().restingFrameIndex,
            GrokThinkingAnimationTiming.restingFrameIndex
        )
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

    private func makeClockwiseDirectionProbeImage() -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            NSColor.red.setFill()
            NSBezierPath(
                ovalIn: NSRect(x: 88, y: 54, width: 20, height: 20)
            ).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func markerCentroid(in image: NSImage) throws -> CGPoint {
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var totalX = 0.0
        var totalY = 0.0
        var sampleCount = 0.0

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB),
                    color.redComponent > 0.55,
                    color.greenComponent < 0.25,
                    color.blueComponent < 0.25,
                    color.alphaComponent > 0.25
                else {
                    continue
                }
                totalX += Double(x)
                totalY += Double(y)
                sampleCount += 1
            }
        }

        XCTAssertGreaterThan(sampleCount, 0, "the direction probe marker must be present")
        return CGPoint(
            x: totalX / sampleCount,
            y: totalY / sampleCount
        )
    }

    private func clockwiseAngularDelta(from: Double, to: Double) -> Double {
        let fullTurn = 2 * Double.pi
        let rawDelta = (from - to).truncatingRemainder(dividingBy: fullTurn)
        return rawDelta >= 0 ? rawDelta : rawDelta + fullTurn
    }

    private func meanVisibleAlpha(of image: NSImage, size: NSSize) -> CGFloat {
        meanAlpha(of: image, size: size, includeTransparent: false)
    }

    private func meanAlpha(
        of image: NSImage,
        size: NSSize,
        onlyZero: Bool = false
    ) -> CGFloat {
        meanAlpha(of: image, size: size, includeTransparent: true, onlyZero: onlyZero)
    }

    private func meanAlpha(
        of image: NSImage,
        size: NSSize,
        includeTransparent: Bool,
        onlyZero: Bool = false
    ) -> CGFloat {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        var total: CGFloat = 0
        var count: CGFloat = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let alpha = CGFloat(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                if onlyZero {
                    if alpha < 0.02 {
                        total += alpha
                        count += 1
                    }
                    continue
                }
                if !includeTransparent && alpha < 0.02 {
                    continue
                }
                total += alpha
                count += 1
            }
        }
        return count == 0 ? 0 : total / count
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
        XCTAssertTrue(statusItemSource.contains("NSWindow.didChangeBackingPropertiesNotification"))
        XCTAssertTrue(statusItemSource.contains("NSWorkspace.accessibilityDisplayOptionsDidChangeNotification"))

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
        XCTAssertTrue(frameCallbackPath.contains("actions.frameImageChanged(image)"))
        XCTAssertFalse(frameCallbackPath.contains("composeMenuBarContentBitmap"))

        XCTAssertFalse(animationSource.contains("ClaudeThinkingAnimator"))
        XCTAssertTrue(statusItemSource.contains("MenuBarClaudeAnimatedIconHostView"))
        XCTAssertTrue(statusItemSource.contains("synchronizeClaudeThinkingAnimationHost"))
        XCTAssertTrue(statusItemSource.contains("claudeAnimationStateChanged"))
        XCTAssertTrue(statusItemSource.contains("synchronizeGrokThinkingAnimationHost"))
        XCTAssertTrue(statusItemSource.contains("installStableGrokThinkingImage"))
        XCTAssertTrue(statusItemSource.contains("synchronizedStripIndex"))
        XCTAssertTrue(statusItemSource.contains("grokAnimationStateChanged"))
        XCTAssertTrue(statusItemSource.contains("grokThinkingSpriteImage"))
        XCTAssertTrue(statusItemSource.contains("GrokThinkingSprite"))
        XCTAssertFalse(statusItemSource.contains("case .codex, .grok:"))
        XCTAssertTrue(statusItemSource.contains("GrokIdleIcon.make"))
        XCTAssertTrue(animationSource.contains("enum GrokThinkingSprite"))
        XCTAssertTrue(animationSource.contains("enum GrokThinkingAnimationTiming"))
        XCTAssertTrue(animationSource.contains("case grokThinking"))
        XCTAssertTrue(animationSource.contains("static func grok("))
        XCTAssertTrue(animationSource.contains("frameRate: Int = MenuBarAnimationTiming.defaultFrameRate"))
        let compositionPreviewSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "work/balance-bar/Sources/UI/Dashboard/DashboardCompositionController.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(compositionPreviewSource.contains("updateGrokMenuBarPreviewAnimation"))
        XCTAssertTrue(compositionPreviewSource.contains(".grokThinking"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appendingPathComponent(
                    "work/balance-bar/GrokThinking"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appendingPathComponent(
                    "work/balance-bar/GrokThinking.png"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appendingPathComponent(
                    "work/balance-bar/GrokThinking.gif"
                ).path
            )
        )

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
        XCTAssertFalse(indexCallbackPath.contains("button.image"))
        XCTAssertFalse(indexCallbackPath.contains("composeMenuBarContentBitmap"))

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
        XCTAssertTrue(pagePreviewPath.contains("previewIcon.image !== image"))
        XCTAssertFalse(pagePreviewPath.contains("layoutSubtreeIfNeeded"))

        let spritePreviewStart = try XCTUnwrap(
            compositionSource.range(of: "private func updateSpriteMenuBarPreviewAnimation")
        )
        let spritePreviewEnd = try XCTUnwrap(
            compositionSource.range(
                of: "func updateMenuBarAnimationFallback",
                range: spritePreviewStart.upperBound..<compositionSource.endIndex
            )
        )
        let spritePreviewPath = String(
            compositionSource[spritePreviewStart.lowerBound..<spritePreviewEnd.lowerBound]
        )
        let iconCacheAssign = try XCTUnwrap(
            spritePreviewPath.range(of: "menuBarPreviewAnimationIconImage = iconImage")
        )
        let activeGate = try XCTUnwrap(spritePreviewPath.range(of: "if active {"))
        XCTAssertGreaterThan(iconCacheAssign.lowerBound, activeGate.lowerBound)
        XCTAssertTrue(spritePreviewPath.contains("menuBarPreviewAnimationSpriteImage = nil"))
    }

    func testAnimationCPUEstimateUsesTheDocumentedStaticTable() {
        XCTAssertEqual(MenuBarAnimationCPUEstimate.percent(mode: .synchronized, fps: 6), 4)
        XCTAssertEqual(MenuBarAnimationCPUEstimate.percent(mode: .synchronized, fps: 10), 5)
        XCTAssertEqual(MenuBarAnimationCPUEstimate.percent(mode: .synchronized, fps: 24), 8)
        XCTAssertEqual(MenuBarAnimationCPUEstimate.percent(mode: .synchronized, fps: 30), 10)
        XCTAssertEqual(MenuBarAnimationCPUEstimate.percent(mode: .efficient, fps: 24), 4)
        XCTAssertEqual(MenuBarAnimationCPUEstimate.percent(mode: .efficient, fps: 30), 4)
        XCTAssertEqual(MenuBarAnimationCPUEstimate.percent(mode: .efficient, fps: 60), 6)
    }

    func testAnimationFrameRateInputClampsIntegersAndDefaultsInvalidValues() {
        XCTAssertEqual(MenuBarAnimationFrameRateInput.resolve(""), 24)
        XCTAssertEqual(MenuBarAnimationFrameRateInput.resolve("  "), 24)
        XCTAssertEqual(MenuBarAnimationFrameRateInput.resolve("abc"), 24)
        XCTAssertEqual(MenuBarAnimationFrameRateInput.resolve("24.5"), 24)
        XCTAssertEqual(MenuBarAnimationFrameRateInput.resolve("5"), 6)
        XCTAssertEqual(MenuBarAnimationFrameRateInput.resolve("61"), 60)
        XCTAssertEqual(MenuBarAnimationFrameRateInput.resolve("10"), 10)
        XCTAssertEqual(MenuBarAnimationFrameRateInput.resolve(" 30 "), 30)
    }

    func testSynchronizedRotationTimerFollowsFrameRateWithoutResettingFrameIndex() throws {
        let imageView = RotatingTemplateImageView(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16)
        )
        let source = NSImage(size: NSSize(width: 16, height: 16))
        source.isTemplate = true
        imageView.setSourceImage(source)
        imageView.startRotating()
        let timer = try XCTUnwrap(imageView.rotationTimerForTesting)
        XCTAssertEqual(timer.timeInterval, 1.0 / 24.0, accuracy: 0.000_001)

        imageView.setCurrentAnimationFrameIndexForTesting(12)
        imageView.setFrameRate(10)
        let retimed = try XCTUnwrap(imageView.rotationTimerForTesting)
        XCTAssertEqual(retimed.timeInterval, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(imageView.currentAnimationFrameIndex, 12)
        XCTAssertEqual(imageView.frameRateForTesting, 10)
        imageView.stopRotating()
    }

    func testNativeRotationDurationFollowsFrameRate() throws {
        let host = MenuBarNativeAnimatedIconHostView(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16)
        )
        host.updateGeometry(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16),
            contentsScale: 2
        )
        let sourceImage = NSImage(size: NSSize(width: 16, height: 16))
        sourceImage.isTemplate = true
        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: NSAppearance(named: .aqua)!,
                contentsScale: 2
            )
        )
        host.installRotationAnimation()
        XCTAssertEqual(
            try XCTUnwrap(host.rotationAnimationForTesting).duration,
            1.5,
            accuracy: 0.000_001
        )
        host.rotationDuration = MenuBarAnimationTiming.rotationDuration(fps: 12)
        XCTAssertEqual(
            try XCTUnwrap(host.rotationAnimationForTesting).duration,
            3.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(host.rotationAnimationForTesting?.values?.count, 36)
        host.removeRotationAnimation()
    }

    func testGrokThinkingCadenceFollowsFrameRateWhileClaudeStaysFixed() {
        XCTAssertEqual(
            MenuBarSpriteAnimationTiming.grok(frameRate: 24).duration,
            1.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MenuBarSpriteAnimationTiming.grok(frameRate: 30).duration,
            1.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(MenuBarSpriteAnimationTiming.grok(frameRate: 10).frameCount, 30)
        XCTAssertEqual(MenuBarSpriteAnimationTiming.claude.duration, 0.81, accuracy: 0.000_001)
        XCTAssertEqual(ClaudeThinkingAnimationTiming.frameCount, 9)
        XCTAssertEqual(ClaudeThinkingAnimationTiming.duration, 0.81, accuracy: 0.000_001)
    }
}
