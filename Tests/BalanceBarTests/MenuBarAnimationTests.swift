import AppKit
import XCTest
@testable import BalanceBar

final class MenuBarAnimationTests: XCTestCase {
    func testCodexAnimationKeepsItsDiscreteFrameCountDurationAndOrder() {
        XCTAssertEqual(MenuBarAnimationFrameRate.defaultValue, .fps30)
        XCTAssertEqual(
            RotatingTemplateImageView.frameCount,
            MenuBarAnimationFrameRate.fps30.frameCount
        )
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

    func testCodexBackendDerivesBothSupportedCadencesFromOneCycleDuration() {
        XCTAssertEqual(MenuBarAnimationFrameRate.allCases, [.fps15, .fps30])
        XCTAssertEqual(MenuBarAnimationFrameRate.rotationDuration, 1.2, accuracy: 0.000_001)

        XCTAssertEqual(MenuBarAnimationFrameRate.fps15.frameCount, 18)
        XCTAssertEqual(MenuBarAnimationFrameRate.fps30.frameCount, 36)
        XCTAssertEqual(
            MenuBarAnimationFrameRate.fps15.frameInterval,
            1.2 / 18,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MenuBarAnimationFrameRate.fps30.frameInterval,
            1.2 / 36,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            Double(MenuBarAnimationFrameRate.fps15.frameCount)
                / MenuBarAnimationFrameRate.rotationDuration,
            15,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            Double(MenuBarAnimationFrameRate.fps30.frameCount)
                / MenuBarAnimationFrameRate.rotationDuration,
            30,
            accuracy: 0.000_001
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
                of: "final class MenuBarTextView",
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

    func testChangingCadenceRebuildsOnlyTheFrameSetAndKeepsOneRunningLifecycle() {
        let imageView = RotatingTemplateImageView(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16),
            frameRate: .fps15
        )
        imageView.setSourceImage(NSImage(size: NSSize(width: 16, height: 16)))
        XCTAssertEqual(imageView.frameRate, .fps15)
        XCTAssertEqual(imageView.animationFrames.count, 18)

        imageView.startRotating()
        XCTAssertTrue(imageView.isRotating)
        XCTAssertEqual(imageView.currentAnimationFrameIndex, 0)

        imageView.setFrameRate(.fps30)
        XCTAssertEqual(imageView.frameRate, .fps30)
        XCTAssertEqual(imageView.animationFrames.count, 36)
        XCTAssertTrue(imageView.isRotating)
        XCTAssertEqual(imageView.currentAnimationFrameIndex, 0)

        imageView.startRotating()
        XCTAssertTrue(imageView.isRotating)
        imageView.setFrameRate(.fps15)
        XCTAssertEqual(imageView.frameRate, .fps15)
        XCTAssertEqual(imageView.animationFrames.count, 18)
        XCTAssertTrue(imageView.isRotating)

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
