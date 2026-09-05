import AppKit
import XCTest
@testable import BalanceBar

final class MenuBarAnimationTests: XCTestCase {
    func testCodexAnimationKeepsItsDiscreteFrameCountDurationAndOrder() {
        XCTAssertEqual(RotatingTemplateImageView.frameCount, MenuBarAnimationTiming.frameCount)
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

    func testCodexBackendsShareTheFixedThirtyHertzTimingContract() {
        XCTAssertEqual(MenuBarAnimationTiming.frameCount, 36)
        XCTAssertEqual(MenuBarAnimationTiming.rotationDuration, 1.2, accuracy: 0.000_001)
        XCTAssertEqual(
            Double(MenuBarAnimationTiming.frameCount) / MenuBarAnimationTiming.rotationDuration,
            30,
            accuracy: 0.000_001
        )
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
        XCTAssertEqual(RotatingTemplateImageView.rotationDuration, 1.2, accuracy: 0.000_001)
        XCTAssertEqual(
            Double(RotatingTemplateImageView.frameCount)
                / RotatingTemplateImageView.rotationDuration,
            30,
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
        XCTAssertEqual(animation.duration, 1.2, accuracy: 0.000_001)
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
    }

    func testGrokThinkingSpriteUsesBundledMultiFrameStripAndGIFDurations() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pngURL = repositoryRoot.appendingPathComponent(
            "work/balance-bar/GrokThinking.png"
        )
        let gifURL = repositoryRoot.appendingPathComponent(
            "work/balance-bar/GrokThinking.gif"
        )

        let sprite = try XCTUnwrap(
            GrokThinkingSprite.make(
                fromPNG: pngURL,
                outputSize: NSSize(width: 16, height: 16)
            )
        )
        XCTAssertEqual(
            sprite.size,
            NSSize(width: 16, height: 16 * CGFloat(GrokThinkingAnimationTiming.frameCount))
        )
        XCTAssertTrue(sprite.isTemplate)
        XCTAssertGreaterThan(GrokThinkingAnimationTiming.frameCount, 1)
        XCTAssertEqual(GrokThinkingAnimationTiming.frameCount, 23)
        XCTAssertEqual(GrokThinkingAnimationTiming.frameDurations[11], 0.48, accuracy: 0.000_001)
        XCTAssertEqual(GrokThinkingAnimationTiming.frameDurations[22], 0.24, accuracy: 0.000_001)
        XCTAssertEqual(GrokThinkingAnimationTiming.duration, 2.40, accuracy: 0.000_001)
        XCTAssertEqual(MenuBarSpriteAnimationTiming.claude.frameCount, 9)
        XCTAssertEqual(MenuBarSpriteAnimationTiming.claude.duration, 0.81, accuracy: 0.000_001)
        XCTAssertEqual(MenuBarSpriteAnimationTiming.grok.frameCount, 23)
        XCTAssertEqual(
            MenuBarSpriteAnimationTiming.grok.keyTimes[11].doubleValue,
            0.88 / 2.40,
            accuracy: 0.000_001
        )

        let frames = try XCTUnwrap(GrokThinkingSprite.makeFrames(fromGIF: gifURL))
        XCTAssertEqual(frames.frames.count, 23)
        XCTAssertEqual(frames.durations.count, 23)
        XCTAssertEqual(frames.durations[11], 0.48, accuracy: 0.02)
        XCTAssertEqual(frames.durations[22], 0.24, accuracy: 0.02)
    }

    func testGrokThinkingSpritePNGUsesBottomOriginOrderAndTopRightSlash() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pngURL = repositoryRoot.appendingPathComponent(
            "work/balance-bar/GrokThinking.png"
        )
        let gifURL = repositoryRoot.appendingPathComponent(
            "work/balance-bar/GrokThinking.gif"
        )
        let frameSize = NSSize(width: 16, height: 16)
        let frameCount = GrokThinkingAnimationTiming.frameCount

        let pngSprite = try XCTUnwrap(
            GrokThinkingSprite.make(fromPNG: pngURL, outputSize: frameSize)
        )
        let gifSprite = try XCTUnwrap(
            GrokThinkingSprite.make(fromGIF: gifURL, outputSize: frameSize)
        )
        let gifFrames = try XCTUnwrap(GrokThinkingSprite.makeFrames(fromGIF: gifURL))
        let pngStrip = try XCTUnwrap(
            pngSprite.representations.compactMap { $0 as? NSBitmapImageRep }.first
        )
        XCTAssertEqual(pngStrip.pixelsWide, 32)
        XCTAssertEqual(pngStrip.pixelsHigh, 32 * frameCount)

        // CALayer translation 0 shows the bottom of the unflipped strip, which
        // is the last pixel rows of the PNG (bitmap y=0 is the visual top).
        let pngResting = try spriteFrameFromBottom(
            of: pngStrip,
            frameIndex: 0,
            frameCount: frameCount
        )
        let pngRestingInk = quadrantInk(of: pngResting)
        XCTAssertLessThan(
            pngRestingInk.topRight - pngRestingInk.topLeft,
            0.02,
            "translation 0 must show the closed ring (GIF frame 0), not a slash"
        )

        for slashIndex in [5, 8, 11] {
            let pngSlash = try spriteFrameFromBottom(
                of: pngStrip,
                frameIndex: slashIndex,
                frameCount: frameCount
            )
            let pngSlashInk = quadrantInk(of: pngSlash)
            XCTAssertGreaterThan(
                pngSlashInk.topRight,
                pngSlashInk.topLeft,
                "GIF slash frame \(slashIndex) must keep the spike in the top-right"
            )
            if slashIndex != 5 {
                XCTAssertGreaterThan(
                    pngSlashInk.topRight - pngSlashInk.topLeft,
                    pngRestingInk.topRight - pngRestingInk.topLeft + 0.03,
                    "slash frame \(slashIndex) must add more top-right ink than the closed ring"
                )
            }
        }

        let gifStrip = try rasterizeSpriteStrip(gifSprite)
        for index in [0, 5, 8, 11, frameCount - 1] {
            let pngFrame = try spriteFrameFromBottom(
                of: pngStrip,
                frameIndex: index,
                frameCount: frameCount
            )
            let gifFrame = try spriteFrameFromBottom(
                of: gifStrip,
                frameIndex: index,
                frameCount: frameCount
            )
            XCTAssertLessThan(
                meanAbsAlphaDelta(pngFrame, gifFrame),
                0.08,
                "committed PNG frame \(index) must match fromGIF bottom-origin stacking"
            )
        }

        let pngLast = try spriteFrameFromBottom(
            of: pngStrip,
            frameIndex: frameCount - 1,
            frameCount: frameCount
        )
        let gifResting = try spriteFrameFromBottom(
            of: gifStrip,
            frameIndex: 0,
            frameCount: frameCount
        )
        let gifLast = try spriteFrameFromBottom(
            of: gifStrip,
            frameIndex: frameCount - 1,
            frameCount: frameCount
        )
        let alignedRestingDelta = meanAbsAlphaDelta(pngResting, gifResting)
        let reversedRestingDelta = meanAbsAlphaDelta(pngResting, gifLast)
        XCTAssertLessThan(
            alignedRestingDelta,
            reversedRestingDelta,
            "PNG must not be stacked top-down; that would pair translation 0 with the last GIF frame"
        )
        XCTAssertLessThan(meanAbsAlphaDelta(pngLast, gifLast), 0.08)

        let gifFrameZero = try rasterizeImage(gifFrames.frames[0], size: frameSize)
        let gifFrameEight = try rasterizeImage(gifFrames.frames[8], size: frameSize)
        XCTAssertLessThan(
            meanAbsAlphaDelta(pngResting, gifFrameZero),
            meanAbsAlphaDelta(pngResting, gifFrameEight),
            "the visible translation-0 frame must be the closed ring, not a mid slash"
        )
        let gifEightInk = quadrantInk(of: gifFrameEight)
        XCTAssertGreaterThan(
            gifEightInk.topRight,
            gifEightInk.topLeft,
            "GIF frame 8 itself must have the / spike in the top-right"
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

    private func rasterizeSpriteStrip(
        _ sprite: NSImage,
        scale: CGFloat = 2
    ) throws -> NSBitmapImageRep {
        let size = sprite.size
        let rep = try makeBitmap(size: size, scale: scale)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = sprite
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layoutSubtreeIfNeeded()
        imageView.cacheDisplay(in: imageView.bounds, to: rep)
        return rep
    }

    private func spriteFrameFromBottom(
        of strip: NSBitmapImageRep,
        frameIndex: Int,
        frameCount: Int
    ) throws -> NSBitmapImageRep {
        XCTAssertGreaterThan(frameCount, 0)
        XCTAssertEqual(strip.pixelsHigh % frameCount, 0)
        let framePixels = strip.pixelsHigh / frameCount
        let frameSize = NSSize(
            width: strip.size.width,
            height: strip.size.height / CGFloat(frameCount)
        )
        let scale = frameSize.width > 0
            ? CGFloat(strip.pixelsWide) / frameSize.width
            : 2
        let frame = try makeBitmap(size: frameSize, scale: scale)
        let sourceY = (frameCount - 1 - frameIndex) * framePixels
        for y in 0..<framePixels {
            for x in 0..<strip.pixelsWide {
                if let color = strip.colorAt(x: x, y: sourceY + y) {
                    frame.setColor(color, atX: x, y: y)
                }
            }
        }
        return frame
    }

    private func rasterizeImage(
        _ image: NSImage,
        size: NSSize,
        scale: CGFloat = 2
    ) throws -> NSBitmapImageRep {
        let rep = try makeBitmap(size: size, scale: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func makeBitmap(size: NSSize, scale: CGFloat) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int((size.width * scale).rounded()),
                pixelsHigh: Int((size.height * scale).rounded()),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        rep.size = size
        return rep
    }

    private struct QuadrantInk {
        let topLeft: CGFloat
        let topRight: CGFloat
    }

    private func quadrantInk(of rep: NSBitmapImageRep) -> QuadrantInk {
        let midX = rep.pixelsWide / 2
        let midY = rep.pixelsHigh / 2
        return QuadrantInk(
            topLeft: meanAlpha(of: rep, x: 0..<midX, y: 0..<midY),
            topRight: meanAlpha(of: rep, x: midX..<rep.pixelsWide, y: 0..<midY)
        )
    }

    private func meanAlpha(
        of rep: NSBitmapImageRep,
        x: Range<Int>,
        y: Range<Int>
    ) -> CGFloat {
        var total: CGFloat = 0
        var count: CGFloat = 0
        for row in y {
            for column in x {
                total += CGFloat(rep.colorAt(x: column, y: row)?.alphaComponent ?? 0)
                count += 1
            }
        }
        return count == 0 ? 0 : total / count
    }

    private func meanAbsAlphaDelta(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep) -> CGFloat {
        XCTAssertEqual(left.pixelsWide, right.pixelsWide)
        XCTAssertEqual(left.pixelsHigh, right.pixelsHigh)
        var total: CGFloat = 0
        var count: CGFloat = 0
        for y in 0..<left.pixelsHigh {
            for x in 0..<left.pixelsWide {
                let leftAlpha = CGFloat(left.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                let rightAlpha = CGFloat(right.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                total += abs(leftAlpha - rightAlpha)
                count += 1
            }
        }
        return count == 0 ? 0 : total / count
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
        XCTAssertTrue(statusItemSource.contains("grokAnimationStateChanged"))
        XCTAssertFalse(statusItemSource.contains("case .codex, .grok:"))

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
    }
}
