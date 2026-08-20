import AppKit
import XCTest
@testable import BalanceBar

final class DashboardScrollClampingTests: XCTestCase {
    func testSettingsPagesUseNativeScrollViewPath() throws {
        let page = DashboardSettingsComponents.makeSettingsPage([NSView()])
        let scrollView = try XCTUnwrap(firstDescendant(of: page, as: NSScrollView.self))

        XCTAssertTrue(scrollView.contentView is NSClipView)
        XCTAssertFalse(scrollView.contentView is DashboardClipView)
        XCTAssertTrue(page is DashboardSettingsPageView)
        XCTAssertTrue(scrollView.documentView is DashboardSettingsDocumentView)
        XCTAssertTrue(scrollView.documentView?.isFlipped == true)
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

    func testSettingsDocumentStartsAtNativeTopForShortAndTallPages() throws {
        let shortFixture = try makeSettingsPage(sectionHeight: 80, viewportHeight: 280)
        let short = shortFixture.scrollView
        XCTAssertEqual(short.documentView!.bounds.height, short.contentView.bounds.height, accuracy: 1)
        XCTAssertEqual(documentOffset(short), 0, accuracy: 1)

        let tallFixture = try makeSettingsPage(sectionHeight: 760, viewportHeight: 280)
        let tall = tallFixture.scrollView
        XCTAssertGreaterThan(tall.documentView!.bounds.height, tall.contentView.bounds.height)
        XCTAssertEqual(documentOffset(tall), 0, accuracy: 1)

        let document = try XCTUnwrap(tall.documentView)
        let topVisible = tall.contentView.convert(tall.contentView.bounds, to: document)
        XCTAssertEqual(topVisible.minY, document.bounds.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(topVisible.maxY, document.bounds.minY)

        let geometry = DashboardScrollGeometry(
            documentBounds: document.bounds,
            viewportHeight: tall.contentView.bounds.height,
            isDocumentFlipped: document.isFlipped
        )
        let bottomVisibleDocumentRect = geometry.visibleDocumentRect(
            forVisualOffset: geometry.maximumOffset
        )
        let bottomDocumentY = geometry.contentOriginDocumentY(
            for: bottomVisibleDocumentRect,
            contentViewIsFlipped: tall.contentView.isFlipped
        )
        let bottomContentY = document.convert(
            NSPoint(x: document.bounds.minX, y: bottomDocumentY),
            to: tall.contentView
        ).y
        tall.contentView.scroll(to: NSPoint(x: tall.contentView.bounds.minX, y: bottomContentY))
        tall.reflectScrolledClipView(tall.contentView)
        let bottomVisible = tall.contentView.convert(tall.contentView.bounds, to: document)
        XCTAssertLessThanOrEqual(bottomVisible.maxY, document.bounds.maxY + 1)
        XCTAssertGreaterThanOrEqual(bottomVisible.minY, document.bounds.minY - 1)

        let topVisibleDocumentRect = geometry.visibleDocumentRect(forVisualOffset: 0)
        let topDocumentY = geometry.contentOriginDocumentY(
            for: topVisibleDocumentRect,
            contentViewIsFlipped: tall.contentView.isFlipped
        )
        let topContentY = document.convert(
            NSPoint(x: document.bounds.minX, y: topDocumentY),
            to: tall.contentView
        ).y
        tall.contentView.scroll(to: NSPoint(x: tall.contentView.bounds.minX, y: topContentY))
        tall.reflectScrolledClipView(tall.contentView)
        let returnedTop = tall.contentView.convert(tall.contentView.bounds, to: document)
        let stack = try XCTUnwrap(firstDescendant(of: document, as: NSStackView.self))
        XCTAssertEqual(returnedTop.minY, document.bounds.minY, accuracy: 1)
        XCTAssertEqual(stack.frame.minY, document.bounds.minY, accuracy: 1)
    }

    func testReplacingAScrolledPageResetsTheFreshPageToNativeTop() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = host

        let firstSection = NSView()
        firstSection.translatesAutoresizingMaskIntoConstraints = false
        firstSection.heightAnchor.constraint(equalToConstant: 760).isActive = true
        let firstPage = DashboardSettingsComponents.makeSettingsPage([firstSection])
        firstPage.frame = host.bounds
        firstPage.autoresizingMask = [.width, .height]
        host.addSubview(firstPage)
        window.layoutIfNeeded()

        let firstScrollView = try XCTUnwrap(firstDescendant(of: firstPage, as: NSScrollView.self))
        let firstDocument = try XCTUnwrap(firstScrollView.documentView)
        let firstGeometry = DashboardScrollGeometry(
            documentBounds: firstDocument.bounds,
            viewportHeight: firstScrollView.contentView.bounds.height,
            isDocumentFlipped: firstDocument.isFlipped
        )
        let bottomRect = firstGeometry.visibleDocumentRect(forVisualOffset: firstGeometry.maximumOffset)
        let bottomDocumentY = firstGeometry.contentOriginDocumentY(
            for: bottomRect,
            contentViewIsFlipped: firstScrollView.contentView.isFlipped
        )
        let bottomContentY = firstDocument.convert(
            NSPoint(x: firstDocument.bounds.minX, y: bottomDocumentY),
            to: firstScrollView.contentView
        ).y
        firstScrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomContentY))
        firstScrollView.reflectScrolledClipView(firstScrollView.contentView)

        firstPage.removeFromSuperview()
        let secondSection = NSView()
        secondSection.translatesAutoresizingMaskIntoConstraints = false
        secondSection.heightAnchor.constraint(equalToConstant: 760).isActive = true
        let secondPage = DashboardSettingsComponents.makeSettingsPage([secondSection])
        secondPage.frame = host.bounds
        secondPage.autoresizingMask = [.width, .height]
        host.addSubview(secondPage)
        window.layoutIfNeeded()

        let secondScrollView = try XCTUnwrap(firstDescendant(of: secondPage, as: NSScrollView.self))
        XCTAssertEqual(documentOffset(secondScrollView), 0, accuracy: 1)
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

    private func makeSettingsPage(
        sectionHeight: CGFloat,
        viewportHeight: CGFloat
    ) throws -> (window: NSWindow, scrollView: NSScrollView) {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.heightAnchor.constraint(equalToConstant: sectionHeight).isActive = true
        let page = DashboardSettingsComponents.makeSettingsPage([section])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: viewportHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = page
        window.layoutIfNeeded()
        let scrollView = try XCTUnwrap(firstDescendant(of: page, as: NSScrollView.self))
        scrollView.layoutSubtreeIfNeeded()
        return (window, scrollView)
    }

    private func documentOffset(_ scrollView: NSScrollView) -> CGFloat {
        let document = scrollView.documentView!
        let visible = scrollView.contentView.convert(scrollView.contentView.bounds, to: document)
        return visible.minY - document.bounds.minY
    }
}

private final class FlippedDashboardDocumentView: NSView {
    override var isFlipped: Bool { true }
}
