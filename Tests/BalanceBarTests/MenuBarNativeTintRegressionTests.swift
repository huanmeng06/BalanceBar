import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class MenuBarNativeTintRegressionTests: XCTestCase {
    func testCodexTextureUsesStableLabelColorForOrdinaryAndHighlightStates() throws {
        let host = makeHost()
        let sourceImage = makeTemplateProbeImage()
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: appearance,
                contentsScale: 2
            )
        )
        let ordinary = try texture(from: host)
        XCTAssertEqual(host.contentsRasterizationCount, 1)

        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: appearance,
                contentsScale: 2,
                highlighted: false
            )
        )
        let unhighlighted = try texture(from: host)

        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: appearance,
                contentsScale: 2,
                highlighted: true
            )
        )
        let highlighted = try texture(from: host)

        XCTAssertEqual(
            host.contentsRasterizationCount,
            1,
            "transient button highlighting must not invalidate the Codex texture"
        )
        XCTAssertEqual(pixelData(of: ordinary), pixelData(of: unhighlighted))
        XCTAssertEqual(pixelData(of: ordinary), pixelData(of: highlighted))
        try assertCenterPixel(
            in: highlighted,
            matches: .labelColor,
            appearance: appearance
        )
    }

    func testAppearanceChangesInvalidateButHighlightChangesRemainStable() throws {
        let host = makeHost()
        let sourceImage = makeTemplateProbeImage()
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: lightAppearance,
                contentsScale: 2,
                highlighted: false
            )
        )
        let lightTexture = try texture(from: host)
        XCTAssertEqual(host.contentsRasterizationCount, 1)

        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: lightAppearance,
                contentsScale: 2,
                highlighted: true
            )
        )
        XCTAssertEqual(host.contentsRasterizationCount, 1)

        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: darkAppearance,
                contentsScale: 2,
                highlighted: false
            )
        )
        let darkTexture = try texture(from: host)
        XCTAssertEqual(
            host.contentsRasterizationCount,
            2,
            "light/dark appearance changes must invalidate the texture"
        )
        try assertCenterPixel(
            in: lightTexture,
            matches: .labelColor,
            appearance: lightAppearance
        )
        try assertCenterPixel(
            in: darkTexture,
            matches: .labelColor,
            appearance: darkAppearance
        )

        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: darkAppearance,
                contentsScale: 2,
                highlighted: true
            )
        )
        XCTAssertEqual(host.contentsRasterizationCount, 2)

        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: lightAppearance,
                contentsScale: 2,
                highlighted: false
            )
        )
        XCTAssertEqual(host.contentsRasterizationCount, 3)
        let restoredLightTexture = try texture(from: host)
        XCTAssertEqual(pixelData(of: lightTexture), pixelData(of: restoredLightTexture))
    }

    func testSourceGeometryAndBackingScaleChangesInvalidateCodexTexture() throws {
        let host = makeHost()
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let sourceImage = makeTemplateProbeImage()
        let replacementImage = makeTemplateProbeImage()

        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: lightAppearance,
                contentsScale: 2
            )
        )
        XCTAssertEqual(host.contentsRasterizationCount, 1)

        XCTAssertTrue(
            host.updateContents(
                sourceImage: replacementImage,
                appearance: lightAppearance,
                contentsScale: 2
            )
        )
        XCTAssertEqual(
            host.contentsRasterizationCount,
            2,
            "a replacement source image must invalidate the texture"
        )

        host.updateGeometry(
            frame: NSRect(x: 0, y: 0, width: 18, height: 18),
            contentsScale: 2
        )
        XCTAssertTrue(
            host.updateContents(
                sourceImage: replacementImage,
                appearance: lightAppearance,
                contentsScale: 2
            )
        )
        XCTAssertEqual(
            host.contentsRasterizationCount,
            3,
            "a geometry change must invalidate the texture"
        )

        XCTAssertTrue(
            host.updateContents(
                sourceImage: replacementImage,
                appearance: lightAppearance,
                contentsScale: 3
            )
        )
        let scaledTexture = try texture(from: host)
        XCTAssertEqual(host.contentsRasterizationCount, 4)
        XCTAssertEqual(scaledTexture.width, 54)
        XCTAssertEqual(scaledTexture.height, 54)
    }

    func testStableTintSynchronizationKeepsOneCoreAnimationInstall() throws {
        let host = makeHost()
        let sourceImage = makeTemplateProbeImage()
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        XCTAssertTrue(
            host.updateContents(
                sourceImage: sourceImage,
                appearance: appearance,
                contentsScale: 2,
                highlighted: false
            )
        )
        host.installRotationAnimation()
        let rasterizationCount = host.contentsRasterizationCount

        for highlighted in [true, false, true, false] {
            XCTAssertTrue(
                host.updateContents(
                    sourceImage: sourceImage,
                    appearance: appearance,
                    contentsScale: 2,
                    highlighted: highlighted
                )
            )
            host.installRotationAnimation()
        }

        XCTAssertEqual(host.contentsRasterizationCount, rasterizationCount)
        XCTAssertEqual(host.rotationAnimationInstallCount, 1)
        XCTAssertNotNil(host.rotationAnimationForTesting)
        host.removeRotationAnimation()
    }

    @MainActor
    func testCodexHostRemainsAttachedAndPopulatedAcrossRefreshBoundaries() throws {
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
        let menuInput = makeMenuInput()
        let settings = makeSettings()
        controller.start(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: menuInput,
            settings: settings
        )

        let codexIcon = makeTemplateProbeImage()
        controller.setCodexIconForTesting(codexIcon)
        controller.updateActivity(
            activeClient: .codex,
            codexTaskRunning: true,
            claudeTaskRunning: false,
            animationEnabled: true
        )
        try assertCodexHostReady(controller)

        let host = try XCTUnwrap(controller.nativeCodexAnimationHostForTesting)
        let installCount = host.rotationAnimationInstallCount
        let rasterizationCount = host.contentsRasterizationCount

        controller.update(
            snapshot: snapshot,
            refreshDate: snapshot.date,
            menuInput: menuInput,
            settings: settings
        )
        try assertCodexHostReady(controller)

        controller.updateFontSize(settings.fontSize + 1)
        try assertCodexHostReady(controller)

        controller.updateWidthAdjustment(1)
        try assertCodexHostReady(controller)

        controller.menuWillOpen(controller.statusMenuForTesting)
        try assertCodexHostReady(controller)
        controller.menuDidClose(controller.statusMenuForTesting)
        try assertCodexHostReady(controller)

        XCTAssertEqual(
            host.rotationAnimationInstallCount,
            installCount,
            "refresh boundaries must retain one CA animation"
        )
        XCTAssertGreaterThanOrEqual(
            host.contentsRasterizationCount,
            rasterizationCount,
            "a true geometry boundary may rerasterize without detaching the host"
        )
    }

    func testNativeCodexProbeRetainsCanonicalStaticImage() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "work/balance-bar/Sources/UI/MenuBar/StatusItemController.swift"
            ),
            encoding: .utf8
        )
        let hostStart = try XCTUnwrap(
            source.range(of: "private func synchronizeNativeCodexAnimationHost()")
        )
        let hostEnd = try XCTUnwrap(
            source.range(
                of: "private func synchronizeClaudeThinkingAnimationHost()",
                range: hostStart.upperBound..<source.endIndex
            )
        )
        let hostSource = String(source[hostStart.lowerBound..<hostEnd.lowerBound])
        XCTAssertTrue(hostSource.contains("let staticImage = cachedStaticMenuBarContentBitmap"))
        XCTAssertTrue(hostSource.contains("button.image = staticImage"))
        XCTAssertTrue(hostSource.contains("applyNativeCodexSourceIconCutout("))
        XCTAssertFalse(hostSource.contains("cachedMenuBarTextBitmap"))
        XCTAssertFalse(hostSource.contains("button.image = textBitmap"))
        XCTAssertFalse(hostSource.contains("selectedMenuItemTextColor"))

        let maskStart = try XCTUnwrap(
            source.range(of: "private func applyNativeCodexSourceIconCutout(")
        )
        let maskEnd = try XCTUnwrap(
            source.range(
                of: "private static func nativeCodexIconRectInLayerCoordinates(",
                range: maskStart.upperBound..<source.endIndex
            )
        )
        let maskSource = String(source[maskStart.lowerBound..<maskEnd.lowerBound])
        XCTAssertTrue(maskSource.contains("button.wantsLayer = true"))
        XCTAssertTrue(maskSource.contains("buttonLayer.bounds"))
        XCTAssertTrue(maskSource.contains("let path = CGMutablePath()"))
        XCTAssertTrue(maskSource.contains("path.addRect(maskBounds)"))
        XCTAssertTrue(maskSource.contains("path.addRect(iconRect)"))
        XCTAssertTrue(maskSource.contains("mask.fillRule = .evenOdd"))
        XCTAssertFalse(maskSource.contains("NSScreen"))
        XCTAssertFalse(maskSource.contains("NSEvent"))

        let detachStart = try XCTUnwrap(
            source.range(of: "private func detachNativeCodexAnimationHostForStatusItemReplacement()")
        )
        let detachEnd = try XCTUnwrap(
            source.range(
                of: "private func deactivateClaudeThinkingAnimation()",
                range: detachStart.upperBound..<source.endIndex
            )
        )
        let detachSource = String(source[detachStart.lowerBound..<detachEnd.lowerBound])
        XCTAssertTrue(detachSource.contains("clearNativeCodexSourceIconCutout()"))
    }

    private func makeHost() -> MenuBarNativeAnimatedIconHostView {
        let host = MenuBarNativeAnimatedIconHostView(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16)
        )
        host.updateGeometry(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16),
            contentsScale: 2
        )
        return host
    }

    private func makeTemplateProbeImage(
        size: NSSize = NSSize(width: 16, height: 16)
    ) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.insetBy(dx: 3, dy: 3).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func texture(
        from host: MenuBarNativeAnimatedIconHostView
    ) throws -> CGImage {
        let contents: Any = try XCTUnwrap(host.iconLayer.contents)
        return contents as! CGImage
    }

    private func pixelData(of image: CGImage) -> Data {
        guard
            let providerData = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(providerData)
        else {
            return Data()
        }
        return Data(bytes: bytes, count: CFDataGetLength(providerData))
    }

    private func assertCenterPixel(
        in image: CGImage,
        matches color: NSColor,
        appearance: NSAppearance
    ) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let center = try XCTUnwrap(
            bitmap.colorAt(x: image.width / 2, y: image.height / 2)
        )
        var expectedColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            expectedColor = color.usingColorSpace(.deviceRGB)
        }
        let expected = try XCTUnwrap(expectedColor)

        XCTAssertEqual(center.alphaComponent, expected.alphaComponent, accuracy: 0.03)
        XCTAssertEqual(center.redComponent, expected.redComponent, accuracy: 0.03)
        XCTAssertEqual(center.greenComponent, expected.greenComponent, accuracy: 0.03)
        XCTAssertEqual(center.blueComponent, expected.blueComponent, accuracy: 0.03)
    }

    private func assertCodexHostReady(
        _ controller: StatusItemController
    ) throws {
        let host = try XCTUnwrap(controller.nativeCodexAnimationHostForTesting)
        XCTAssertNotNil(host.superview, "the Codex host must remain attached to the status button")
        XCTAssertFalse(host.isHidden, "the attached Codex host must be visible")
        XCTAssertNotNil(host.iconLayer.contents, "the attached Codex host must have model contents")
        XCTAssertNotNil(
            host.rotationAnimationForTesting,
            "the attached Codex host must retain its CA animation"
        )
    }

    private func makeController(
        codexAnimationBackend: MenuBarCodexAnimationBackend
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
            codexAnimationBackend: codexAnimationBackend
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
}
