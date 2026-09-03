import AppKit
import XCTest
@testable import BalanceBar

final class StatusItemControllerTests: XCTestCase {
    /// The status item button must carry an image at all times (see
    /// `StatusItemController.placeholderButtonImage`), and that image must
    /// stay empty so it renders no pixels and does not affect item layout.
    func testPlaceholderButtonImageIsEmptySoItRendersNoPixels() {
        let image = StatusItemController.placeholderButtonImage
        XCTAssertEqual(image.size, .zero)
        XCTAssertTrue(image.representations.isEmpty)
        XCTAssertNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testCodexAnimationCachePrecomposesFiniteFramesAndReusesSteadyStateLookups() {
        let sourceFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        let signature = makeVisualSignature(
            primaryText: "80%",
            sourceFrames: sourceFrames
        )
        var cache = MenuBarBitmapAnimationFrameCache()
        var compositionCount = 0

        XCTAssertTrue(
            cache.rebuildIfNeeded(
                signature: signature,
                sourceFrames: sourceFrames
            ) { _ in
                compositionCount += 1
                return NSImage(size: NSSize(width: 56, height: 22))
            }
        )
        XCTAssertEqual(cache.count, RotatingTemplateImageView.frameCount)
        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(compositionCount, RotatingTemplateImageView.frameCount)

        let firstCompleteFrame = cache.image(forSourceFrame: sourceFrames[0])
        for sourceFrame in sourceFrames {
            XCTAssertNotNil(
                cache.image(forSourceFrame: sourceFrame),
                "every prepared source frame must resolve to a complete image"
            )
        }
        XCTAssertTrue(
            cache.rebuildIfNeeded(
                signature: signature,
                sourceFrames: sourceFrames
            ) { _ in
                XCTFail("a steady-state frame lookup must not compose")
                return nil
            }
        )
        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(compositionCount, RotatingTemplateImageView.frameCount)
        XCTAssertTrue(cache.image(forSourceFrame: sourceFrames[0]) === firstCompleteFrame)
    }

    func testCodexAnimationCacheInvalidatesForVisualSignatureAndSourceChanges() {
        let sourceFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        var cache = MenuBarBitmapAnimationFrameCache()
        var compositionCount = 0
        let initialSignature = makeVisualSignature(
            primaryText: "80%",
            sourceFrames: sourceFrames
        )

        XCTAssertTrue(
            cache.rebuildIfNeeded(
                signature: initialSignature,
                sourceFrames: sourceFrames
            ) { _ in
                compositionCount += 1
                return NSImage(size: NSSize(width: 56, height: 22))
            }
        )

        let changedTextSignature = makeVisualSignature(
            primaryText: "79%",
            sourceFrames: sourceFrames
        )
        XCTAssertTrue(
            cache.rebuildIfNeeded(
                signature: changedTextSignature,
                sourceFrames: sourceFrames
            ) { _ in
                compositionCount += 1
                return NSImage(size: NSSize(width: 56, height: 22))
            }
        )
        XCTAssertEqual(cache.rebuildCount, 2)
        XCTAssertEqual(compositionCount, RotatingTemplateImageView.frameCount * 2)

        let replacementFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        // Keep the visible signature equal while changing source-frame
        // identity. The cache must still reject the old complete images.
        let replacementSignature = makeVisualSignature(
            primaryText: "79%",
            sourceFrames: replacementFrames
        )
        XCTAssertTrue(
            cache.rebuildIfNeeded(
                signature: replacementSignature,
                sourceFrames: replacementFrames
            ) { _ in
                compositionCount += 1
                return NSImage(size: NSSize(width: 56, height: 22))
            }
        )
        XCTAssertEqual(cache.rebuildCount, 3)
        XCTAssertEqual(compositionCount, RotatingTemplateImageView.frameCount * 3)
        XCTAssertNil(cache.image(forSourceFrame: sourceFrames[0]))
        XCTAssertNotNil(cache.image(forSourceFrame: replacementFrames[0]))
    }

    func testCodexAnimationCacheClearsAfterCompositionFailure() {
        let sourceFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        let signature = makeVisualSignature(sourceFrames: sourceFrames)
        var cache = MenuBarBitmapAnimationFrameCache()

        XCTAssertFalse(
            cache.rebuildIfNeeded(
                signature: signature,
                sourceFrames: sourceFrames
            ) { _ in nil }
        )
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.signature)
        XCTAssertEqual(cache.rebuildCount, 0)
    }

    func testStableBitmapFrameBufferMutatesOneImageBackingAcrossManyTicks() throws {
        let sourceFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        let completeFrames = (0..<RotatingTemplateImageView.frameCount).map { index in
            makeSolidImage(
                size: NSSize(width: 56, height: 22),
                red: CGFloat(index + 1) / CGFloat(RotatingTemplateImageView.frameCount + 1),
                green: 0.25,
                blue: 0.75
            )
        }
        let signature = makeVisualSignature(sourceFrames: sourceFrames)
        var buffer = MenuBarStableBitmapAnimationFrameBuffer()

        XCTAssertTrue(
            buffer.rebuildIfNeeded(
                signature: signature,
                sourceFrames: sourceFrames,
                completeFrames: completeFrames
            )
        )
        let stableImage = try XCTUnwrap(buffer.image)
        let initialPixelData = try XCTUnwrap(buffer.backingPixelDataForTesting)
        XCTAssertEqual(buffer.count, RotatingTemplateImageView.frameCount)
        XCTAssertEqual(buffer.rebuildCount, 1)
        XCTAssertEqual(stableImage.cacheMode, .never)

        for tick in 0..<100 {
            XCTAssertTrue(buffer.apply(frameIndex: tick % completeFrames.count))
            XCTAssertTrue(buffer.image === stableImage)
        }

        XCTAssertEqual(buffer.rebuildCount, 1)
        XCTAssertEqual(buffer.pixelCopyCount, 100)
        XCTAssertNotEqual(buffer.backingPixelDataForTesting, initialPixelData)
        XCTAssertTrue(
            buffer.rebuildIfNeeded(
                signature: signature,
                sourceFrames: sourceFrames,
                completeFrames: completeFrames
            )
        )
        XCTAssertEqual(buffer.rebuildCount, 1)
    }

    func testBitmapVisualSignatureIncludesContentGeometryAppearanceAndRenderingInputs() {
        let sourceFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        let base = makeVisualSignature(sourceFrames: sourceFrames)
        let changedText = makeVisualSignature(
            primaryText: "changed",
            sourceFrames: sourceFrames
        )
        let changedGeometry = makeVisualSignature(
            sourceFrames: sourceFrames,
            contentFrame: NSRect(x: 1, y: 0, width: 56, height: 22)
        )
        let changedAppearance = makeVisualSignature(
            sourceFrames: sourceFrames,
            appearance: "darkAqua"
        )
        let changedProvider = makeVisualSignature(
            sourceFrames: sourceFrames,
            sourceProviderIdentity: "another-provider"
        )
        let changedMode = makeVisualSignature(
            sourceFrames: sourceFrames,
            usesBitmapContent: false
        )

        XCTAssertNotEqual(base, changedText)
        XCTAssertNotEqual(base, changedGeometry)
        XCTAssertNotEqual(base, changedAppearance)
        XCTAssertNotEqual(base, changedProvider)
        XCTAssertNotEqual(base, changedMode)
    }

    @MainActor
    func testBitmapControllerReusesCompleteCodexFramesAcrossTicksAndRestoresStaticImage() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController()
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = makeMenuInput()
        let settings = makeSettings(usesBitmapContent: true)

        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        controller.setCodexIconForTesting(
            NSImage(size: NSSize(width: 16, height: 16))
        )
        let staticImage = try XCTUnwrap(controller.menuBarButtonImageForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        let buildCount = controller.codexAnimationCacheBuildCountForTesting
        let compositionCount = controller.codexAnimationFrameCompositionCountForTesting
        let stableImage = try XCTUnwrap(controller.stableCodexAnimationImageForTesting)
        let stableImageAssignments = controller.stableCodexAnimationImageAssignmentCountForTesting
        let stableRebuildCount = controller.stableCodexAnimationRebuildCountForTesting
        XCTAssertEqual(
            controller.codexAnimationCacheFrameCountForTesting,
            RotatingTemplateImageView.frameCount
        )
        XCTAssertEqual(
            controller.stableCodexAnimationFrameCountForTesting,
            RotatingTemplateImageView.frameCount
        )
        XCTAssertEqual(compositionCount, RotatingTemplateImageView.frameCount)
        XCTAssertEqual(stableRebuildCount, 1)
        XCTAssertTrue(controller.menuBarButtonImageForTesting === stableImage)
        XCTAssertGreaterThanOrEqual(buildCount, 1)

        controller.update(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        XCTAssertEqual(controller.codexAnimationCacheBuildCountForTesting, buildCount)
        XCTAssertEqual(
            controller.codexAnimationFrameCompositionCountForTesting,
            compositionCount
        )
        XCTAssertEqual(
            controller.stableCodexAnimationImageAssignmentCountForTesting,
            stableImageAssignments
        )
        XCTAssertTrue(controller.menuBarButtonImageForTesting === stableImage)

        for tick in 0..<100 {
            controller.advanceCodexAnimationFrameForTesting(
                tick % RotatingTemplateImageView.frameCount
            )
            XCTAssertTrue(controller.menuBarButtonImageForTesting === stableImage)
        }
        XCTAssertEqual(
            controller.codexAnimationFrameCompositionCountForTesting,
            compositionCount,
            "100 stable-image ticks must not compose complete bitmaps"
        )
        XCTAssertEqual(
            controller.stableCodexAnimationImageAssignmentCountForTesting,
            stableImageAssignments,
            "100 stable-image ticks must not assign button.image"
        )
        XCTAssertEqual(
            controller.stableCodexAnimationPixelCopyCountForTesting,
            101,
            "initial frame plus 100 steady-state ticks should copy pixels"
        )

        let changedSnapshot = Snapshot.balance(
            "Provider",
            79,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        controller.update(
            snapshot: changedSnapshot,
            refreshDate: changedSnapshot.date,
            menuInput: input,
            settings: settings
        )
        let changedBuildCount = controller.codexAnimationCacheBuildCountForTesting
        let changedCompositionCount = controller.codexAnimationFrameCompositionCountForTesting
        let changedStableImage = try XCTUnwrap(controller.stableCodexAnimationImageForTesting)
        XCTAssertEqual(changedBuildCount, buildCount + 1)
        XCTAssertEqual(
            changedCompositionCount,
            compositionCount + RotatingTemplateImageView.frameCount
        )
        XCTAssertTrue(controller.menuBarButtonImageForTesting === changedStableImage)
        XCTAssertFalse(changedStableImage === stableImage)
        XCTAssertEqual(
            controller.stableCodexAnimationImageAssignmentCountForTesting,
            stableImageAssignments + 1
        )

        RunLoop.main.run(
            until: Date().addingTimeInterval(
                RotatingTemplateImageView.rotationFrameInterval * 2
            )
        )
        XCTAssertEqual(
            controller.codexAnimationFrameCompositionCountForTesting,
            changedCompositionCount,
            "steady-state timer ticks must not compose complete bitmaps"
        )

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        let restoredStaticImage = try XCTUnwrap(controller.menuBarButtonImageForTesting)
        XCTAssertFalse(
            restoredStaticImage === staticImage,
            "changed content must restore a newly composed static image"
        )

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertEqual(
            controller.codexAnimationCacheBuildCountForTesting,
            changedBuildCount,
            "restart with unchanged content must reuse the finite frame set"
        )
        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
    }

    @MainActor
    func testTraditionalControllerDoesNotUseBitmapAnimationCache() {
        let controller = makeController()
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: makeMenuInput(),
            settings: makeSettings(usesBitmapContent: false)
        )
        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertEqual(controller.codexAnimationCacheFrameCountForTesting, 0)
        XCTAssertEqual(controller.codexAnimationCacheBuildCountForTesting, 0)
        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
    }

    private func makeSolidImage(
        size: NSSize,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            NSColor(
                calibratedRed: red,
                green: green,
                blue: blue,
                alpha: 1
            ).setFill()
            rect.fill()
            return true
        }
    }

    private func makeController() -> StatusItemController {
        StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                openOpenCodex: {},
                quit: {},
                switchProvider: { _ in },
                switchOpenCodexPreference: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
    }

    private func makeMenuInput() -> StatusItemController.MenuInput {
        StatusItemController.MenuInput(
            openCodexCards: [],
            openCodexState: nil,
            openCodexSwitchInFlight: false,
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: nil,
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showOpenCodexMenu: false,
            showStatusMenu: false
        )
    }

    private func makeSettings(usesBitmapContent: Bool) -> StatusItemController.MenuBarSettings {
        StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true,
            usesBitmapContent: usesBitmapContent
        )
    }

    private func makeVisualSignature(
        primaryText: String = "…",
        sourceFrames: [NSImage],
        contentFrame: NSRect = NSRect(x: 0, y: 0, width: 56, height: 22),
        appearance: String = "aqua",
        sourceProviderIdentity: String = "provider",
        usesBitmapContent: Bool = true
    ) -> MenuBarBitmapAnimationVisualSignature {
        MenuBarBitmapAnimationVisualSignature(
            primaryText: primaryText,
            secondaryText: "reset",
            primaryFont: "Monospaced|13.0|1",
            secondaryFont: "Monospaced|10.4|1",
            contentFrame: contentFrame,
            iconSlotFrame: NSRect(x: 0, y: 3, width: 18, height: 18),
            iconFrame: NSRect(x: 0, y: 3, width: 18, height: 18),
            textFrame: NSRect(x: 24, y: 1, width: 32, height: 20),
            contentBounds: contentFrame,
            iconSlotBounds: NSRect(x: 0, y: 0, width: 18, height: 18),
            iconBounds: NSRect(x: 0, y: 0, width: 18, height: 18),
            textBounds: NSRect(x: 0, y: 0, width: 32, height: 20),
            bitmapBounds: NSRect(x: 0, y: 0, width: 56, height: 22),
            bitmapFrame: NSRect(x: 0, y: 0, width: 56, height: 22),
            buttonBounds: NSRect(x: 0, y: 0, width: 56, height: 22),
            placement: MenuBarBitmapImagePlacement(
                canonicalBounds: NSRect(x: 0, y: 0, width: 56, height: 22),
                imageDestinationRect: NSRect(x: 0, y: 0, width: 56, height: 22)
            ),
            backingScale: 2,
            iconVisible: true,
            textVisible: true,
            primaryVisible: true,
            secondaryVisible: true,
            sourceImageIdentity: sourceFrames.first.map(ObjectIdentifier.init),
            sourceImageSize: NSSize(width: 16, height: 16),
            sourceImageIsTemplate: true,
            sourceFrameIdentities: sourceFrames.map(ObjectIdentifier.init),
            sourceProviderIdentity: sourceProviderIdentity,
            activeClient: .codex,
            effectiveSnapshot: MenuBarBitmapAnimationSnapshotSignature(
                kind: "official",
                provider: sourceProviderIdentity,
                amount: 80,
                unit: "%",
                message: "reset",
                primaryText: primaryText,
                secondaryText: "reset"
            ),
            appearance: appearance,
            iconOffsetX: 0,
            iconOffsetY: 0,
            amountOffsetX: 0,
            amountOffsetY: 0,
            horizontalPadding: 6,
            widthAdjustment: 0,
            showReset: true,
            buttonImagePosition: 1,
            buttonImageScaling: 2,
            usesBitmapContent: usesBitmapContent
        )
    }
}
