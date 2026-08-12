import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardComponentsTests: XCTestCase {
    func testDashboardSectionsPreserveNavigationOrderAndMetadata() {
        let sections = DashboardSection.allCases

        XCTAssertEqual(sections.map(\.rawValue), Array(0..<5))
        XCTAssertEqual(sections.map(\.symbolName), [
            "gearshape.fill",
            "menubar.rectangle",
            "filemenu.and.selection",
            "slider.horizontal.3",
            "info.circle.fill"
        ])
        XCTAssertTrue(sections.allSatisfy { !$0.title.isEmpty })
        XCTAssertEqual(DashboardSection(rawValue: 2), .menu)
        XCTAssertNil(DashboardSection(rawValue: 5))
    }

    func testNavigationRowAppliesSelectedAndInactiveStates() {
        let row = DashboardNavigationRowView()
        row.wantsLayer = true
        let icon = NSImageView()
        let title = NSTextField(labelWithString: "Menu")
        row.addSubview(icon)
        row.addSubview(title)
        row.iconView = icon
        row.titleLabel = title

        row.isSelected = true
        row.updateAppearance(animated: false)
        XCTAssertTrue(row.isSelected)
        XCTAssertTrue(icon.contentTintColor?.isEqual(NSColor.controlAccentColor) == true)
        XCTAssertTrue(title.textColor?.isEqual(NSColor.controlAccentColor) == true)

        row.isSelected = false
        row.updateAppearance(animated: false)
        XCTAssertFalse(row.isSelected)
        XCTAssertTrue(icon.contentTintColor?.isEqual(NSColor.secondaryLabelColor) == true)
        XCTAssertTrue(title.textColor?.isEqual(NSColor.secondaryLabelColor) == true)
    }

    func testQuotaProgressClampsValuesAndPreservesColorBoundaries() {
        XCTAssertEqual(QuotaProgressView(percentage: -1).percentage, 0)
        XCTAssertEqual(QuotaProgressView(percentage: 101).percentage, 100)

        XCTAssertTrue(QuotaProgressView.progressColor(for: 0).isEqual(NSColor.systemRed))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 9.99).isEqual(NSColor.systemRed))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 10).isEqual(NSColor.systemOrange))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 24.99).isEqual(NSColor.systemOrange))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 25).isEqual(NSColor.systemYellow))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 50).isEqual(NSColor.systemYellow))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 50.01).isEqual(NSColor.systemGreen))
    }

    func testHoverLinkInvokesActivationCallbackOnMouseDown() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.layout()
        var activationCount = 0
        link.onActivate = { activationCount += 1 }

        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: link.visibleTextHitRect.center))

        XCTAssertEqual(activationCount, 1)
    }

    func testHoverLinkActivatesOnlyInsideVisibleTextHitRect() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 220, height: 20)
        link.layout()

        XCTAssertLessThan(link.visibleTextHitRect.maxX, link.bounds.maxX)

        var activationCount = 0
        link.onActivate = { activationCount += 1 }
        for x in [
            link.visibleTextHitRect.minX + 1,
            link.visibleTextHitRect.midX,
            link.visibleTextHitRect.maxX - 1
        ] {
            link.mouseDown(with: makeMouseEvent(
                type: .leftMouseDown,
                location: NSPoint(x: x, y: link.visibleTextHitRect.midY)
            ))
        }
        link.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: link.visibleTextHitRect.maxX + 20, y: link.visibleTextHitRect.midY)
        ))

        XCTAssertEqual(activationCount, 3)
    }

    func testHoverLinkTruncationUsesOnlyVisibleRenderedText() {
        let link = HoverLinkTextField(text: "A very long provider name that must truncate")
        link.frame = NSRect(x: 0, y: 0, width: 90, height: 20)
        link.layout()

        XCTAssertGreaterThan(link.visibleTextHitRect.width, 0)
        XCTAssertLessThan(link.visibleTextHitRect.maxX, link.bounds.maxX)

        var activationCount = 0
        link.onActivate = { activationCount += 1 }
        link.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: link.visibleTextHitRect.maxX + 6, y: link.visibleTextHitRect.midY)
        ))

        XCTAssertEqual(activationCount, 0)
    }

    func testHoverLinkBlankAreaUsesArrowCursorAndDoesNotUnderline() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 220, height: 20)
        link.layout()

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        NSCursor.arrow.set()

        let blankEvent = makeMouseEvent(
            type: .mouseMoved,
            location: NSPoint(x: link.visibleTextHitRect.maxX + 20, y: link.visibleTextHitRect.midY)
        )
        link.cursorUpdate(with: blankEvent)
        link.mouseEntered(with: blankEvent)

        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.arrow))
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testHoverLinkRebuildsOneCursorTrackingArea() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)

        link.updateTrackingAreas()
        XCTAssertEqual(link.trackingAreas.count, 1)
        XCTAssertEqual(link.trackingAreas[0].rect, link.visibleTextHitRect)
        XCTAssertTrue(link.trackingAreas[0].options.contains(.cursorUpdate))
        XCTAssertTrue(link.trackingAreas[0].options.contains(.activeAlways))
        XCTAssertFalse(link.trackingAreas[0].options.contains(.inVisibleRect))

        link.updateTrackingAreas()
        XCTAssertEqual(link.trackingAreas.count, 1)
    }

    func testHoverLinkRemovalClearsHoverStyleAndTrackingArea() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.updateTrackingAreas()

        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) else {
            return XCTFail("Expected to create a mouse event")
        }

        link.mouseEntered(with: event)
        XCTAssertNotNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))

        link.removeFromSuperview()

        XCTAssertEqual(link.trackingAreas.count, 0)
        XCTAssertNil(link.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testHoverLinkCursorUpdateUsesPointingHandWithoutClick() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        link.layout()

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        NSCursor.arrow.set()

        link.cursorUpdate(with: makeMouseEvent(type: .mouseMoved, location: link.visibleTextHitRect.center))

        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: type == .leftMouseDown ? 1 : 0,
            pressure: type == .leftMouseDown ? 1 : 0
        ) else {
            fatalError("Expected to create a mouse event")
        }
        return event
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
