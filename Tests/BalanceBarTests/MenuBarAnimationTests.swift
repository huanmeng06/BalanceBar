import AppKit
import XCTest
@testable import BalanceBar

final class MenuBarAnimationTests: XCTestCase {
    func testCodexAnimationKeepsItsDiscreteFrameCountDurationAndOrder() {
        XCTAssertEqual(RotatingTemplateImageView.frameCount, 36)
        XCTAssertEqual(RotatingTemplateImageView.rotationDuration, 1.15, accuracy: 0.000_001)
        XCTAssertEqual(
            RotatingTemplateImageView.rotationFrameInterval,
            1.15 / 36,
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

    func testFrameDisplayDoesNotEmitSemanticSourceChangesAndStopRestoresSource() {
        let imageView = RotatingTemplateImageView(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16)
        )
        let source = NSImage(size: NSSize(width: 16, height: 16))
        let frame = NSImage(size: NSSize(width: 16, height: 16))
        var sourceChanges: [NSImage?] = []
        imageView.onSourceImageChanged = { sourceChanges.append($0) }

        imageView.setSourceImage(source)
        XCTAssertEqual(sourceChanges.count, 1)
        XCTAssertTrue(imageView.image === source)

        imageView.displayImage(frame)
        XCTAssertEqual(sourceChanges.count, 1)
        XCTAssertTrue(imageView.image === frame)

        imageView.stopRotating()
        imageView.stopRotating()
        XCTAssertFalse(imageView.isRotating)
        XCTAssertEqual(sourceChanges.count, 1)
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
        XCTAssertTrue(framePath.contains("displayImage(frame)"))
        XCTAssertFalse(framePath.contains("onSourceImageChanged"))
        XCTAssertFalse(framePath.contains("layoutStatusItem"))
        XCTAssertFalse(framePath.contains("iconChanged"))

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
    }
}
