import AppKit
import XCTest
@testable import BalanceBar

final class DashboardScrollClampingTests: XCTestCase {
    func testSettingsPagesUseNativeScrollViewPath() throws {
        let page = DashboardSettingsComponents.makeSettingsPage([NSView()])
        let scrollView = try XCTUnwrap(firstDescendant(of: page, as: NSScrollView.self))

        XCTAssertTrue(scrollView.contentView is NSClipView)
        XCTAssertFalse(scrollView.contentView is DashboardClipView)
        XCTAssertEqual(scrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("work/balance-bar/Sources/AppCore/DashboardScrollClamping.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let clipStart = try XCTUnwrap(source.range(of: "final class DashboardClipView"))
        let clipSource = String(source[clipStart.lowerBound...])
        XCTAssertFalse(clipSource.contains("override func scroll(to"))
        XCTAssertFalse(clipSource.contains("override func setBoundsOrigin"))
        XCTAssertFalse(clipSource.contains("override func constrainBoundsRect"))
        XCTAssertFalse(clipSource.contains("reflectScrolledClipView"))
    }

    func testThreeRapidNativeSwipesPreserveLegalOriginsWithoutCustomOscillation() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let clipView = NSClipView(frame: scrollView.bounds)
        let documentView = FlippedDashboardDocumentView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        scrollView.contentView = clipView
        scrollView.documentView = documentView
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        window.contentView = scrollView
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }

        let geometry = DashboardScrollGeometry(
            documentBounds: documentView.bounds,
            viewportHeight: clipView.bounds.height,
            isDocumentFlipped: documentView.isFlipped
        )
        XCTAssertEqual(geometry.maximumOffset, 200, accuracy: 0.0001)

        let swipes: [[CGFloat]] = [
            [200, 199, 198, 200, 197, 196, 200, 195],
            [0, 1, 2, 0, 3, 4, 0, 5],
            [200, 198, 199, 200, 197, 196, 200, 195]
        ]
        for swipe in swipes {
            for proposedVisualOffset in swipe {
                clipView.scroll(
                    to: NSPoint(x: clipView.bounds.minX, y: proposedVisualOffset)
                )
                let visibleRect = clipView.convert(clipView.bounds, to: documentView)
                let actualVisualOffset = geometry.visualOffset(for: visibleRect)
                XCTAssertGreaterThanOrEqual(actualVisualOffset, -0.0001)
                XCTAssertLessThanOrEqual(
                    actualVisualOffset,
                    geometry.maximumOffset + 0.0001
                )
            }
        }

        XCTAssertFalse(
            DashboardScrollTrace.snapshot().contains {
                $0.kind == "edge-writer" || $0.kind == "constrain-result"
            },
            "Native user scrolling must not emit custom correction events"
        )
    }

    func testScrollGeometryKeepsStrictNoBlankRangeForBothCoordinateSystems() {
        for isFlipped in [false, true] {
            let geometry = DashboardScrollGeometry(
                documentBounds: NSRect(x: 4, y: 30, width: 400, height: 260),
                viewportHeight: 80,
                isDocumentFlipped: isFlipped
            )
            XCTAssertEqual(geometry.maximumOffset, 180)
            XCTAssertEqual(geometry.clampedVisualOffset(-80), 0)
            XCTAssertEqual(geometry.clampedVisualOffset(250), 180)
            XCTAssertEqual(geometry.clampedVisualOffset(73.25), 73.25, accuracy: 0.0001)
        }
    }

    func testShortDocumentHasNoVerticalOffset() {
        let geometry = DashboardScrollGeometry(
            documentBounds: NSRect(x: 12, y: 40, width: 400, height: 180),
            viewportHeight: 240,
            isDocumentFlipped: true
        )

        XCTAssertEqual(geometry.maximumOffset, 0)
        XCTAssertEqual(geometry.clampedVisualOffset(-80), 0)
        XCTAssertEqual(geometry.clampedVisualOffset(80), 0)
    }

    private func firstDescendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstDescendant(of: child, as: type) { return match }
        }
        return nil
    }
}

private final class FlippedDashboardDocumentView: NSView {
    override var isFlipped: Bool { true }
}
