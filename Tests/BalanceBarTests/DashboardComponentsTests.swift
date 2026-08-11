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
        var activationCount = 0
        link.onActivate = { activationCount += 1 }

        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return XCTFail("Expected to create a mouse event")
        }

        link.mouseDown(with: event)

        XCTAssertEqual(activationCount, 1)
    }

    func testHoverLinkRebuildsOneCursorTrackingArea() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 120, height: 20)

        link.updateTrackingAreas()
        XCTAssertEqual(link.trackingAreas.count, 1)
        XCTAssertTrue(link.trackingAreas[0].options.contains(.cursorUpdate))
        XCTAssertTrue(link.trackingAreas[0].options.contains(.activeAlways))

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

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        NSCursor.arrow.set()

        link.cursorUpdate(with: event)

        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))
    }
}
