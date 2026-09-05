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

    @MainActor
    func testStatusItemContentIsAlwaysRenderedFromTheOffscreenBitmapTree() {
        let controller = makeController()
        defer { controller.teardown() }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )

        XCTAssertTrue(controller.menuBarContentIsOffscreenForTesting)
        XCTAssertNotNil(controller.menuBarButtonImageForTesting)
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
        XCTAssertNotEqual(base, changedText)
        XCTAssertNotEqual(base, changedGeometry)
        XCTAssertNotEqual(base, changedAppearance)
        XCTAssertNotEqual(base, changedProvider)
        let replacementFrames = (0..<RotatingTemplateImageView.frameCount).map { _ in
            NSImage(size: NSSize(width: 16, height: 16))
        }
        var changedSourceFrames = base
        changedSourceFrames.sourceFrameIdentities = replacementFrames.map(ObjectIdentifier.init)
        XCTAssertTrue(
            base.matchesStaticContent(of: changedSourceFrames),
            "animation frame identities must not invalidate static menu-bar content"
        )
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
        let settings = makeSettings()

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
    func testRuntimeDisplayPolicyPublishesAndClearsItsWarningImmediately() {
        var visibilityTransitions: [StatusItemVisibility] = []
        let controller = StatusItemController(
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
                iconChanged: { _ in },
                visibilityChanged: { visibilityTransitions.append($0) }
            )
        )
        defer { controller.teardown() }

        let input = StatusItemController.MenuInput(
            openCodexCards: [],
            openCodexState: nil,
            openCodexSwitchInFlight: false,
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: nil,
            statusLinks: [],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
            showOpenCodexMenu: true,
            showStatusMenu: true
        )
        func settings(for mode: MenuBarIconDisplayMode) -> StatusItemController.MenuBarSettings {
            StatusItemController.MenuBarSettings(
                showIcon: true,
                showAmount: true,
                showReset: true,
                horizontalPadding: 6,
                keepMenuOpenAfterRefresh: true,
                iconDisplayMode: mode,
                iconDisplayDelay: .zeroSeconds
            )
        }

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: settings(for: .onlyWhileRunning)
        )

        let sampleStart = Date()
        controller.observeCodexTaskSample(false, at: sampleStart)
        controller.observeCodexTaskSample(
            false,
            at: sampleStart.addingTimeInterval(
                MenuBarIconDisplayStateMachine.idleConfirmationInterval
            )
        )

        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(controller.statusItemVisibility.isHiddenByRuntimePolicy)
        XCTAssertFalse(controller.statusItemVisibility.isHiddenByMenuBarSpace)
        XCTAssertEqual(visibilityTransitions.last, .hiddenByRuntimePolicy)

        // Changing the preference is itself a policy transition; it must not
        // wait for another activity sample before restoring the item or
        // clearing the Dashboard-facing warning.
        controller.update(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: settings(for: .alwaysVisible)
        )

        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.statusItemVisibility.isHiddenByRuntimePolicy)
        XCTAssertEqual(visibilityTransitions.last, .unknown)
    }

    @MainActor
    func testNativeCoreAnimationCodexLifecycleUsesOneOwnedHostWithoutBitmapTicks() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController(
            codexAnimationBackend: .nativeCoreAnimation
        )
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = makeMenuInput()
        let settings = makeSettings()

        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        let icon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.2,
            green: 0.4,
            blue: 0.8
        )
        icon.isTemplate = true
        controller.setCodexIconForTesting(icon)
        let staticImage = try XCTUnwrap(controller.menuBarButtonImageForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )

        let host = try XCTUnwrap(controller.nativeCodexAnimationHostForTesting)
        XCTAssertEqual(
            controller.codexAnimationBackendForTesting,
            .nativeCoreAnimation
        )
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertTrue(host.superview != nil)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertEqual(host.iconLayer.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(host.iconLayer.bounds.size, host.bounds.size)
        XCTAssertEqual(
            host.iconLayer.position,
            CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        )
        XCTAssertNotNil(host.rotationAnimationForTesting)
        XCTAssertTrue(
            controller.menuBarButtonImageForTesting === staticImage,
            "running CA presentation must keep the canonical static GPT+text bitmap"
        )
        XCTAssertTrue(
            controller.menuBarButtonImageForTesting
                === controller.cachedStaticMenuBarContentBitmapForTesting
        )
        XCTAssertTrue(
            controller.menuBarButtonImageForTesting
                !== controller.cachedMenuBarTextBitmapForTesting,
            "Performance/G must not replace the native image with the text-only bitmap"
        )

        let installCount = host.rotationAnimationInstallCount
        let rasterizationCount = host.contentsRasterizationCount
        controller.update(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        XCTAssertEqual(host.rotationAnimationInstallCount, installCount)
        XCTAssertEqual(host.contentsRasterizationCount, rasterizationCount)

        // This seam represents a legacy timer callback.  Native CA must leave
        // it unable to copy pixels or request a native redraw.
        let pixelCopies = controller.stableCodexAnimationPixelCopyCountForTesting
        let redraws = controller.stableCodexAnimationRedrawRequestCountForTesting
        controller.advanceCodexAnimationFrameForTesting(7)
        XCTAssertEqual(controller.stableCodexAnimationPixelCopyCountForTesting, pixelCopies)
        XCTAssertEqual(controller.stableCodexAnimationRedrawRequestCountForTesting, redraws)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertNil(host.superview)
        XCTAssertTrue(host.isHidden)
        XCTAssertNil(host.rotationAnimationForTesting)
        XCTAssertTrue(controller.menuBarButtonImageForTesting === staticImage)
    }

    @MainActor
    func testNativeCoreAnimationKeepsCanonicalStaticImageAcrossHostLifecycle() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController(
            codexAnimationBackend: .nativeCoreAnimation
        )
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = makeMenuInput()
        let settings = makeSettings()

        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        let icon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.2,
            green: 0.4,
            blue: 0.8
        )
        icon.isTemplate = true
        controller.setCodexIconForTesting(icon)

        func assertCanonicalStaticNativeImage(
            _ message: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let buttonImage = try XCTUnwrap(
                controller.menuBarButtonImageForTesting,
                file: file,
                line: line
            )
            let staticImage = try XCTUnwrap(
                controller.cachedStaticMenuBarContentBitmapForTesting,
                file: file,
                line: line
            )
            let textBitmap = try XCTUnwrap(
                controller.cachedMenuBarTextBitmapForTesting,
                file: file,
                line: line
            )
            XCTAssertTrue(
                buttonImage === staticImage,
                message,
                file: file,
                line: line
            )
            XCTAssertTrue(
                buttonImage !== textBitmap,
                "native image must not be the text-only bitmap: \(message)",
                file: file,
                line: line
            )
        }

        try assertCanonicalStaticNativeImage("idle native image is the complete static bitmap")
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        try assertCanonicalStaticNativeImage(
            "running Performance/G must keep the complete static GPT+text bitmap"
        )
        let host = try XCTUnwrap(controller.nativeCodexAnimationHostForTesting)
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertTrue(host.superview != nil)
        XCTAssertFalse(host.isHidden)
        XCTAssertNotNil(host.rotationAnimationForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)

        let installCount = host.rotationAnimationInstallCount
        let rasterizationCount = host.contentsRasterizationCount
        let runningStaticImage = controller.cachedStaticMenuBarContentBitmapForTesting
        controller.update(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: input,
            settings: settings
        )
        try assertCanonicalStaticNativeImage(
            "snapshot updates must not replace the canonical static native image"
        )
        XCTAssertTrue(controller.menuBarButtonImageForTesting === runningStaticImage)
        XCTAssertEqual(host.rotationAnimationInstallCount, installCount)
        XCTAssertEqual(host.contentsRasterizationCount, rasterizationCount)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        try assertCanonicalStaticNativeImage("stopped Performance/G restores the static native image")
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertNil(host.superview)
        XCTAssertTrue(host.isHidden)
        XCTAssertNil(host.rotationAnimationForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        try assertCanonicalStaticNativeImage(
            "restarting Performance/G must still keep the complete static native image"
        )
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertTrue(controller.nativeCodexAnimationHostForTesting?.superview != nil)
        XCTAssertNotNil(
            controller.nativeCodexAnimationHostForTesting?.rotationAnimationForTesting
        )

        controller.setCodexAnimationBackend(.stableBitmap)
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertNil(controller.nativeCodexAnimationHostForTesting?.superview)
        XCTAssertTrue(controller.nativeCodexAnimationIsRotatingForTesting)

        controller.setCodexAnimationBackend(.nativeCoreAnimation)
        try assertCanonicalStaticNativeImage(
            "returning to Performance/G must restore the complete static native image"
        )
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertTrue(controller.nativeCodexAnimationHostForTesting?.superview != nil)
        XCTAssertNotNil(
            controller.nativeCodexAnimationHostForTesting?.rotationAnimationForTesting
        )
    }

    @MainActor
    func testClaudeThinkingLifecycleUsesOneOwnedSpriteHostWithoutBitmapTicks() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Claude animation is disabled by the system reduce-motion setting"
        )
        var animationTransitions: [(Bool, NSImage?, NSImage?)] = []
        let controller = StatusItemController(
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
                iconChanged: { _ in },
                claudeAnimationStateChanged: { active, iconImage, spriteImage in
                    animationTransitions.append((active, iconImage, spriteImage))
                }
            )
        )
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
            settings: makeSettings()
        )
        let staticIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.9,
            green: 0.5,
            blue: 0.2
        )
        staticIcon.isTemplate = true
        let sprite = makeSolidImage(
            size: NSSize(width: 16, height: 144),
            red: 0.9,
            green: 0.5,
            blue: 0.2
        )
        sprite.isTemplate = true
        controller.setClaudeAnimationAssetsForTesting(
            staticImage: staticIcon,
            spriteImage: sprite
        )
        let staticBitmap = try XCTUnwrap(controller.menuBarButtonImageForTesting)

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: true,
            animationEnabled: true
        )

        let host = try XCTUnwrap(controller.claudeThinkingAnimationHostForTesting)
        XCTAssertTrue(controller.claudeThinkingAnimationIsActiveForTesting)
        XCTAssertTrue(host.superview != nil)
        XCTAssertFalse(host.isHidden)
        XCTAssertNotNil(host.thinkingAnimationForTesting)
        XCTAssertTrue(controller.menuBarButtonImageForTesting !== staticBitmap)
        XCTAssertEqual(animationTransitions.count, 1)
        XCTAssertTrue(animationTransitions[0].0)
        XCTAssertTrue(animationTransitions[0].1 === staticIcon)
        XCTAssertTrue(animationTransitions[0].2 === sprite)

        let installCount = host.thinkingAnimationInstallCount
        let rasterizationCount = host.spriteRasterizationCount
        controller.update(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: makeMenuInput(),
            settings: makeSettings()
        )
        XCTAssertEqual(host.thinkingAnimationInstallCount, installCount)
        XCTAssertEqual(host.spriteRasterizationCount, rasterizationCount)

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)
        XCTAssertTrue(host.isHidden)
        XCTAssertNil(host.thinkingAnimationForTesting)
        XCTAssertEqual(animationTransitions.count, 2)
        XCTAssertFalse(animationTransitions[1].0)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(host.isHidden)
        XCTAssertNil(host.superview)
    }

    @MainActor
    func testCodexIdleReclaimsSourceAfterClaudeIdleAndRunningRoundTrips() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Claude animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController(codexAnimationBackend: .stableBitmap)
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
            settings: makeSettings()
        )

        let codexIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.2,
            green: 0.4,
            blue: 0.8
        )
        codexIcon.isTemplate = true
        let claudeIcon = makeSolidImage(
            size: NSSize(width: 16, height: 16),
            red: 0.9,
            green: 0.5,
            blue: 0.2
        )
        claudeIcon.isTemplate = true
        let claudeSprite = makeSolidImage(
            size: NSSize(width: 16, height: 144),
            red: 0.9,
            green: 0.5,
            blue: 0.2
        )
        claudeSprite.isTemplate = true
        controller.setCodexIconForTesting(codexIcon)
        controller.setClaudeAnimationAssetsForTesting(
            staticImage: claudeIcon,
            spriteImage: claudeSprite
        )

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(controller.menuBarSourceImageForTesting === codexIcon)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(controller.menuBarSourceImageForTesting === claudeIcon)
        XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertTrue(
            controller.menuBarSourceImageForTesting === codexIcon,
            "idle Codex must reclaim source ownership after idle Claude"
        )
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)

        controller.updateActivity(
            activeClient: .claude,
            codexTaskRunning: false,
            claudeTaskRunning: true,
            animationEnabled: true
        )
        XCTAssertTrue(controller.menuBarSourceImageForTesting === claudeIcon)
        XCTAssertTrue(controller.claudeThinkingAnimationIsActiveForTesting)

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: true,
            animationEnabled: true
        )
        XCTAssertTrue(
            controller.menuBarSourceImageForTesting === codexIcon,
            "idle Codex must reclaim source ownership after animated Claude"
        )
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)
        XCTAssertNil(controller.claudeThinkingAnimationHostForTesting?.superview)
    }

    @MainActor
    func testCodexRunningThroughClaudeToCodexIdleRestoresSourceForBothBackends() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )

        for backend in [MenuBarCodexAnimationBackend.stableBitmap, .nativeCoreAnimation] {
            let controller = makeController(codexAnimationBackend: backend)

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
                settings: makeSettings()
            )

            let codexIcon = makeSolidImage(
                size: NSSize(width: 16, height: 16),
                red: 0.2,
                green: 0.4,
                blue: 0.8
            )
            codexIcon.isTemplate = true
            let claudeIcon = makeSolidImage(
                size: NSSize(width: 16, height: 16),
                red: 0.9,
                green: 0.5,
                blue: 0.2
            )
            claudeIcon.isTemplate = true
            let claudeSprite = makeSolidImage(
                size: NSSize(width: 16, height: 144),
                red: 0.9,
                green: 0.5,
                blue: 0.2
            )
            claudeSprite.isTemplate = true
            controller.setCodexIconForTesting(codexIcon)
            controller.setClaudeAnimationAssetsForTesting(
                staticImage: claudeIcon,
                spriteImage: claudeSprite
            )

            controller.updateActivity(
                activeClient: .codex,
                codexTaskRunning: true,
                claudeTaskRunning: false,
                animationEnabled: true
            )
            XCTAssertTrue(controller.menuBarSourceImageForTesting === codexIcon)
            switch backend {
            case .stableBitmap:
                XCTAssertTrue(controller.nativeCodexAnimationIsRotatingForTesting)
            case .nativeCoreAnimation:
                XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
                XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
            }

            controller.updateActivity(
                activeClient: .claude,
                codexTaskRunning: true,
                claudeTaskRunning: false,
                animationEnabled: true
            )
            XCTAssertTrue(
                controller.menuBarSourceImageForTesting === claudeIcon,
                "Codex to Claude must immediately install Claude source"
            )
            XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
            XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)

            controller.updateActivity(
                activeClient: .codex,
                codexTaskRunning: false,
                claudeTaskRunning: false,
                animationEnabled: true
            )
            XCTAssertTrue(
                controller.menuBarSourceImageForTesting === codexIcon,
                "idle Codex must reclaim source ownership after running Codex"
            )
            XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
            XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
            XCTAssertFalse(controller.claudeThinkingAnimationIsActiveForTesting)

            controller.teardown()
        }
    }

    @MainActor
    func testCodexAnimationModeSwitchIsImmediateAndKeepsExactlyOneBackendActive() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )
        let controller = makeController(codexAnimationBackend: .nativeCoreAnimation)
        defer { controller.teardown() }
        let snapshot = Snapshot.balance(
            "Provider",
            80,
            "USD",
            nil,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let settings = makeSettings()
        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: makeMenuInput(),
            settings: settings
        )
        let icon = makeSolidImage(size: NSSize(width: 16, height: 16), red: 0.2, green: 0.4, blue: 0.8)
        icon.isTemplate = true
        controller.setCodexIconForTesting(icon)
        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        let host = try XCTUnwrap(controller.nativeCodexAnimationHostForTesting)
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)

        controller.setCodexAnimationBackend(.stableBitmap)
        XCTAssertEqual(controller.preferredCodexAnimationBackendForTesting, .stableBitmap)
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .stableBitmap)
        XCTAssertFalse(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertNil(host.superview)
        XCTAssertNil(host.rotationAnimationForTesting)
        XCTAssertTrue(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertEqual(controller.stableCodexAnimationFrameCountForTesting, 36)

        controller.setCodexAnimationBackend(.nativeCoreAnimation)
        XCTAssertEqual(controller.preferredCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertTrue(controller.nativeCodexAnimationIsActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertTrue(
            controller.nativeCodexAnimationHostForTesting?.rotationAnimationForTesting != nil
        )
        XCTAssertFalse(controller.codexAnimationFallbackActiveForTesting)
    }

    @MainActor
    func testEfficientModeFailureFallsBackTemporarilyWithoutChangingPreference() throws {
        try XCTSkipUnless(
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "Codex animation is disabled by the system reduce-motion setting"
        )
        var fallbackTransitions: [Bool] = []
        let controller = StatusItemController(
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
                iconChanged: { _ in },
                animationFallbackChanged: { fallbackTransitions.append($0) }
            ),
            codexAnimationBackend: .nativeCoreAnimation,
            forceNativeCodexAnimationFailureForTesting: true
        )
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
            settings: makeSettings()
        )
        let icon = makeSolidImage(size: NSSize(width: 16, height: 16), red: 0.2, green: 0.4, blue: 0.8)
        icon.isTemplate = true
        controller.setCodexIconForTesting(icon)
        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )

        XCTAssertEqual(controller.preferredCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .stableBitmap)
        XCTAssertTrue(controller.codexAnimationFallbackActiveForTesting)
        XCTAssertTrue(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertEqual(fallbackTransitions, [true])

        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: false,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        XCTAssertEqual(controller.effectiveCodexAnimationBackendForTesting, .nativeCoreAnimation)
        XCTAssertFalse(controller.codexAnimationFallbackActiveForTesting)
        XCTAssertFalse(controller.nativeCodexAnimationIsRotatingForTesting)
        XCTAssertEqual(fallbackTransitions, [true, false])
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

    private func makeController(
        codexAnimationBackend: MenuBarCodexAnimationBackend = .stableBitmap,
        forceNativeCodexAnimationFailureForTesting: Bool = false
    ) -> StatusItemController {
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
            ),
            codexAnimationBackend: codexAnimationBackend,
            forceNativeCodexAnimationFailureForTesting: forceNativeCodexAnimationFailureForTesting
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

    private func makeSettings() -> StatusItemController.MenuBarSettings {
        StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
    }

    private func makeVisualSignature(
        primaryText: String = "…",
        sourceFrames: [NSImage],
        contentFrame: NSRect = NSRect(x: 0, y: 0, width: 56, height: 22),
        appearance: String = "aqua",
        sourceProviderIdentity: String = "provider"
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
            buttonImageScaling: 2
        )
    }
}
