import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardSettingsSwitchTests: XCTestCase {
    private final class ToggleRecorder: NSObject {
        var callCount = 0
        @objc func toggle(_ sender: NSSwitch) {
            callCount += 1
        }
    }

    private func renderToBitmap(_ control: NSControl, scale: CGFloat = 2) -> NSBitmapImageRep {
        let size = control.bounds.size
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
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
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        control.draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private struct RegionStats {
        var accentPixels = 0
        var whitePixels = 0
        var neutralTrackPixels = 0
    }

    private func stats(
        in rect: CGRect,
        of rep: NSBitmapImageRep
    ) -> RegionStats {
        var result = RegionStats()
        let x0 = max(0, Int(rect.minX)), x1 = min(rep.pixelsWide - 1, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(rep.pixelsHigh - 1, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return result }
        for y in y0...y1 {
            for x in x0...x1 {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent * 255
                let g = color.greenComponent * 255
                let b = color.blueComponent * 255
                if r > 235, g > 235, b > 235 {
                    result.whitePixels += 1
                } else if r < 140, g > 60, g < 220, b > 200, abs(r - b) > 60 {
                    result.accentPixels += 1
                } else if abs(r - g) < 12, abs(g - b) < 12, r > 60, r < 240 {
                    result.neutralTrackPixels += 1
                }
            }
        }
        return result
    }

    func testMakeSwitchReturnsSelfPaintedSwitchWiredToTarget() {
        let recorder = ToggleRecorder()
        let control = DashboardSettingsComponents.makeSwitch(
            identifier: "unitTestSwitch",
            isOn: true,
            target: recorder,
            action: #selector(ToggleRecorder.toggle(_:))
        )
        XCTAssertTrue(control is DashboardSettingsSwitch)
        XCTAssertEqual(control.identifier?.rawValue, "unitTestSwitch")
        XCTAssertEqual(control.state, .on)
        XCTAssertIdentical(control.target as? ToggleRecorder, recorder)

        control.performClick(nil)
        XCTAssertEqual(control.state, .off)
        XCTAssertEqual(recorder.callCount, 1)
        control.performClick(nil)
        XCTAssertEqual(control.state, .on)
        XCTAssertEqual(recorder.callCount, 2)
    }

    func testSelfPaintedSwitchKeepsStockIntrinsicSize() {
        let stock = NSSwitch()
        let painted = DashboardSettingsSwitch()
        painted.sizeToFit()
        stock.sizeToFit()
        XCTAssertEqual(painted.intrinsicContentSize.width, stock.intrinsicContentSize.width, accuracy: 0.5)
        XCTAssertEqual(painted.intrinsicContentSize.height, stock.intrinsicContentSize.height, accuracy: 0.5)
    }

    func testStockHostedContentStaysHiddenInsideWindowHierarchy() throws {
        let painted = DashboardSettingsSwitch()
        painted.state = .on
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        painted.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(painted)
        NSLayoutConstraint.activate([
            painted.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            painted.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        for subview in painted.subviews {
            XCTAssertTrue(subview.isHidden, "stock hosted switch content must stay hidden")
        }
        window.orderOut(nil)
    }

    func testOnStatePaintsAccentTrackOnLeftAndKnobOnRight() {
        let control = DashboardSettingsSwitch()
        control.state = .on
        control.setFrameSize(control.intrinsicContentSize)
        let rep = renderToBitmap(control)
        // 108×48 bitmap at 2x: left quarter exposes the accent track beside
        // the knob; the right quarter must be dominated by the white knob.
        let left = stats(in: CGRect(x: 0, y: 0, width: 28, height: rep.pixelsHigh), of: rep)
        let right = stats(in: CGRect(x: 72, y: 0, width: rep.pixelsWide - 72, height: rep.pixelsHigh), of: rep)
        XCTAssertGreaterThan(
            left.accentPixels, 120,
            "ON state must paint the accent track beside the knob (accent=\(left.accentPixels))"
        )
        XCTAssertGreaterThan(
            right.whitePixels, 300,
            "ON state must paint a visible white knob on the right (white=\(right.whitePixels))"
        )
        // The knob spans ~px 40-104 of the 108px bitmap; the accent track
        // legitimately peeks 2pt past each knob edge, so the interior of the
        // knob must be accent-free while the right edge strip is not.
        let knobInterior = stats(in: CGRect(x: 48, y: 8, width: 48, height: rep.pixelsHigh - 16), of: rep)
        XCTAssertLessThan(knobInterior.accentPixels, 20)
    }

    func testOffStatePaintsKnobOnLeftAndNeutralTrackOnRight() {
        let control = DashboardSettingsSwitch()
        control.state = .off
        control.setFrameSize(control.intrinsicContentSize)
        let rep = renderToBitmap(control)
        let left = stats(in: CGRect(x: 0, y: 0, width: 36, height: rep.pixelsHigh), of: rep)
        let right = stats(in: CGRect(x: 72, y: 0, width: rep.pixelsWide - 72, height: rep.pixelsHigh), of: rep)
        XCTAssertGreaterThan(
            left.whitePixels, 300,
            "OFF state must paint a visible white knob on the left (white=\(left.whitePixels))"
        )
        XCTAssertGreaterThan(
            right.neutralTrackPixels, 120,
            "OFF state must paint a neutral track on the right (neutral=\(right.neutralTrackPixels))"
        )
        XCTAssertLessThan(right.whitePixels, 80)
        XCTAssertLessThan(right.accentPixels, 50, "OFF state must not paint the accent track")
    }

    func testStateFlipMovesPaintedKnob() {
        let control = DashboardSettingsSwitch()
        control.setFrameSize(control.intrinsicContentSize)
        control.state = .on
        let onRep = renderToBitmap(control)
        control.state = .off
        let offRep = renderToBitmap(control)
        let onRight = stats(in: CGRect(x: 72, y: 0, width: onRep.pixelsWide - 72, height: onRep.pixelsHigh), of: onRep)
        let offRight = stats(in: CGRect(x: 72, y: 0, width: offRep.pixelsWide - 72, height: offRep.pixelsHigh), of: offRep)
        XCTAssertGreaterThan(onRight.whitePixels, 300)
        XCTAssertLessThan(offRight.whitePixels, 80, "flipping to off must move the knob off the right side")
    }
}
