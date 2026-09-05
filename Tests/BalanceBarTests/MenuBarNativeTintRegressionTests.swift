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
}
