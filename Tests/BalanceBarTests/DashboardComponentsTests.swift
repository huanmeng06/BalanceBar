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
        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        var activationCount = 0
        link.onActivate = { activationCount += 1 }

        link.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: link.visibleTextHitRect.center))

        XCTAssertEqual(activationCount, 1)
    }

    func testHoverLinkActivatesOnlyInsideVisibleTextHitRect() {
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 0, y: 0, width: 220, height: 20)
        link.layout()

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
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

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
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

    func testMenuHostedLinkUsesHostMouseMovementWithoutExpandingActivation() {
        let item = NSMenuItem()
        let host = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 220, height: 20))
        item.view = host

        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 30, y: 0, width: 160, height: 20)
        host.addSubview(link)
        link.layout()
        link.installMenuTrackingArea(in: host)
        link.updateTrackingAreas()

        XCTAssertEqual(host.trackingAreas.count, 3)
        guard let mouseArea = host.trackingAreas.first(where: { $0.options.contains(.mouseMoved) }),
              let mouseEntryArea = host.trackingAreas.first(where: { $0.options.contains(.mouseEnteredAndExited) }),
              let cursorArea = host.trackingAreas.first(where: { $0.options.contains(.cursorUpdate) })
        else {
            return XCTFail("Expected separate mouse, entry, and cursor tracking areas")
        }
        XCTAssertEqual(
            mouseArea.rect,
            host.convert(link.visibleTextHitRect, from: link)
        )
        XCTAssertTrue(mouseArea.options.contains(.activeAlways))
        XCTAssertFalse(mouseArea.options.contains(.mouseEnteredAndExited))
        XCTAssertFalse(mouseArea.options.contains(.cursorUpdate))
        XCTAssertTrue(mouseEntryArea.options.contains(.activeAlways))
        XCTAssertFalse(mouseEntryArea.options.contains(.mouseMoved))
        XCTAssertFalse(mouseEntryArea.options.contains(.cursorUpdate))
        XCTAssertTrue(cursorArea.options.contains(.activeAlways))
        XCTAssertFalse(cursorArea.options.contains(.activeInKeyWindow))
        XCTAssertEqual(link.trackingAreas.count, 0)

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        NSCursor.arrow.set()

        var activationCount = 0
        link.onActivate = { activationCount += 1 }
        let visiblePoint = host.convert(link.visibleTextHitRect.center, from: link)
        let blankPoint = NSPoint(
            x: host.convert(
                NSPoint(
                    x: link.visibleTextHitRect.maxX
                        + (link.bounds.maxX - link.visibleTextHitRect.maxX) / 2,
                    y: link.visibleTextHitRect.midY
                ),
                from: link
            ).x,
            y: visiblePoint.y
        )

        host.mouseMoved(with: makeMouseEvent(
            type: .mouseMoved,
            location: visiblePoint
        ))
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))

        host.cursorUpdate(with: makeMouseEvent(
            type: .mouseMoved,
            location: visiblePoint
        ))
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))

        host.mouseMoved(with: makeMouseEvent(
            type: .mouseMoved,
            location: blankPoint
        ))
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.arrow))

        link.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: blankPoint
        ))
        XCTAssertEqual(activationCount, 0)

        link.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: link.visibleTextHitRect.center
        ))
        XCTAssertEqual(activationCount, 1)
    }

    func testMenuHostedLinkTeardownRemovesHostTrackingAndRestoresArrow() {
        let item = NSMenuItem()
        let host = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 160, height: 20))
        item.view = host

        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 20, y: 0, width: 120, height: 20)
        host.addSubview(link)
        link.layout()
        link.installMenuTrackingArea(in: host)

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        NSCursor.arrow.set()
        host.mouseMoved(with: makeMouseEvent(
            type: .mouseMoved,
            location: host.convert(link.visibleTextHitRect.center, from: link)
        ))
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))

        link.removeFromSuperview()
        link.removeFromSuperview()

        XCTAssertEqual(host.trackingAreas.count, 0)
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.arrow))
        item.view = nil
    }

    func testMenuHostedLinkEnablesMouseMovedEventsForItsMenuWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 20),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.acceptsMouseMovedEvents = false

        let host = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 220, height: 20))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 30, y: 0, width: 160, height: 20)
        host.addSubview(link)
        link.layout()
        link.installMenuTrackingArea(in: host)

        XCTAssertEqual(host.trackingAreas.count, 3)
        window.contentView = host

        XCTAssertTrue(window.acceptsMouseMovedEvents)
        XCTAssertEqual(host.trackingAreas.count, 3)
        guard let mouseArea = host.trackingAreas.first(where: { $0.options.contains(.mouseMoved) }) else {
            return XCTFail("Expected a mouse tracking area after attaching the menu view")
        }
        XCTAssertEqual(
            mouseArea.rect,
            host.convert(link.visibleTextHitRect, from: link)
        )

        host.prepareForMenuTracking()
        XCTAssertEqual(host.trackingAreas.count, 3)
        XCTAssertTrue(window.acceptsMouseMovedEvents)

        link.removeFromSuperview()
        XCTAssertFalse(window.acceptsMouseMovedEvents)
        window.contentView = nil
    }

    func testMenuHostedLinkReactivatesAfterPopupDetachAndReattach() {
        let menu = NSMenu(title: "Issue 104 reopen")
        let item = NSMenuItem()
        let host = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 32, y: 4, width: 170, height: 20)
        host.addSubview(link)
        link.layout()
        link.installMenuTrackingArea(in: host)
        item.view = host
        menu.addItem(item)

        let bridge = MenuWindowCursorTrackingBridge()
        var callbackInstallationCount = 0
        var secondOpenTrackingAreaCount = 0
        var secondOpenCursorIsHand = false
        var secondOpenIsUnderlined = false
        host.onMenuWindowChanged = { window in
            guard let window else { return }
            bridge.install(on: window)
            bridge.register(host)
            bridge.beginMenuTracking()
            callbackInstallationCount += 1
        }

        let previousCursor = NSCursor.current
        defer {
            bridge.tearDown()
            previousCursor.set()
            menu.removeAllItems()
        }

        for openNumber in 1...2 {
            var hostAttached = false
            let probeTimer = Timer(
                timeInterval: 0.02,
                repeats: false
            ) { _ in
                guard let window = host.window else {
                    menu.cancelTracking()
                    return
                }
                hostAttached = true
                if openNumber == 2 {
                    secondOpenTrackingAreaCount = host.trackingAreas.count
                    let hostPoint = host.convert(link.visibleTextHitRect.center, from: link)
                    let windowPoint = host.window?.contentView.map {
                        host.convert(hostPoint, to: $0)
                    } ?? hostPoint
                    NSCursor.arrow.set()
                    bridge.mouseMoved(with: self.makeMouseEvent(
                        type: .mouseMoved,
                        location: windowPoint
                    ))
                    secondOpenCursorIsHand = NSCursor.current.isEqual(NSCursor.pointingHand)
                    secondOpenIsUnderlined = link.attributedStringValue.attribute(
                        .underlineStyle,
                        at: 0,
                        effectiveRange: nil
                    ) != nil
                }
                menu.cancelTracking()
            }
            RunLoop.main.add(probeTimer, forMode: .eventTracking)

            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: 0),
                in: nil
            )

            XCTAssertTrue(hostAttached, "menu open \(openNumber) did not attach the item view")
        }

        XCTAssertGreaterThanOrEqual(callbackInstallationCount, 2)
        XCTAssertEqual(secondOpenTrackingAreaCount, 3)
        XCTAssertTrue(secondOpenCursorIsHand)
        XCTAssertTrue(secondOpenIsUnderlined)
    }

    func testMenuCloseResynchronizesIndependentDashboardLink() {
        let dashboardWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let dashboardContent = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 40))
        dashboardWindow.contentView = dashboardContent
        let dashboardLink = HoverLinkTextField(text: "Provider")
        dashboardLink.frame = NSRect(x: 28, y: 10, width: 170, height: 20)
        dashboardContent.addSubview(dashboardLink)
        dashboardLink.layout()

        let mouseScreenPoint = NSEvent.mouseLocation
        let visiblePointInWindow = dashboardContent.convert(
            dashboardLink.visibleTextHitRect.center,
            from: dashboardLink
        )
        dashboardWindow.setFrameOrigin(NSPoint(
            x: mouseScreenPoint.x - visiblePointInWindow.x,
            y: mouseScreenPoint.y - visiblePointInWindow.y
        ))
        dashboardWindow.orderFrontRegardless()
        dashboardWindow.displayIfNeeded()
        dashboardLink.updateTrackingAreas()

        let menu = NSMenu(title: "Issue 104 Dashboard teardown")
        let item = NSMenuItem()
        let menuHost = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let menuLink = HoverLinkTextField(text: "Provider")
        menuLink.frame = NSRect(x: 32, y: 4, width: 170, height: 20)
        menuHost.addSubview(menuLink)
        menuLink.layout()
        menuLink.installMenuTrackingArea(in: menuHost)
        item.view = menuHost
        menu.addItem(item)

        let bridge = MenuWindowCursorTrackingBridge()
        menuHost.onMenuWindowChanged = { window in
            guard let window else { return }
            bridge.install(on: window)
            bridge.register(menuHost)
            bridge.beginMenuTracking()
        }

        let previousCursor = NSCursor.current
        defer {
            bridge.tearDown()
            dashboardWindow.orderOut(nil)
            dashboardWindow.contentView = nil
            previousCursor.set()
            menu.removeAllItems()
        }

        let visibleDashboardPoint = visiblePointInWindow
        NSCursor.arrow.set()
        dashboardLink.mouseMoved(with: makeMouseEvent(
            type: .mouseMoved,
            location: visibleDashboardPoint
        ))
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))
        XCTAssertNotNil(dashboardLink.attributedStringValue.attribute(
            .underlineStyle,
            at: 0,
            effectiveRange: nil
        ))

        var menuHostAttached = false
        let probeTimer = Timer(timeInterval: 0.02, repeats: false) { _ in
            guard menuHost.window != nil else {
                menu.cancelTracking()
                return
            }
            menuHostAttached = true
            menu.cancelTracking()
        }
        RunLoop.main.add(probeTimer, forMode: .eventTracking)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: 0),
            in: nil
        )
        XCTAssertTrue(menuHostAttached)

        // This is the production menuDidClose-equivalent cleanup. The pointer
        // never leaves the still-visible Dashboard glyph while the menu's
        // nested tracking loop is active.
        dashboardLink.mouseExited(with: makeMouseEvent(
            type: .mouseMoved,
            location: visibleDashboardPoint
        ))
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.arrow))
        XCTAssertNil(dashboardLink.attributedStringValue.attribute(
            .underlineStyle,
            at: 0,
            effectiveRange: nil
        ))
        bridge.tearDown()

        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))
        XCTAssertNotNil(dashboardLink.attributedStringValue.attribute(
            .underlineStyle,
            at: 0,
            effectiveRange: nil
        ))

        let blankPoint = dashboardContent.convert(
            NSPoint(
                x: dashboardLink.visibleTextHitRect.maxX
                    + (dashboardLink.bounds.maxX - dashboardLink.visibleTextHitRect.maxX) / 2,
                y: dashboardLink.visibleTextHitRect.midY
            ),
            from: dashboardLink
        )
        var activationCount = 0
        dashboardLink.onActivate = { activationCount += 1 }
        NSCursor.pointingHand.set()
        dashboardLink.mouseMoved(with: makeMouseEvent(
            type: .mouseMoved,
            location: blankPoint
        ))
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.arrow))
        XCTAssertNil(dashboardLink.attributedStringValue.attribute(
            .underlineStyle,
            at: 0,
            effectiveRange: nil
        ))
        dashboardLink.mouseDown(with: makeMouseEvent(
            type: .leftMouseDown,
            location: blankPoint
        ))
        XCTAssertEqual(activationCount, 0)
    }

    func testMenuHostedLinkUsesTheActualNSMenuPopupWindowTrackingLoop() {
        let menu = NSMenu(title: "Issue 104")
        let item = NSMenuItem()
        let host = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 32, y: 4, width: 170, height: 20)
        host.addSubview(link)
        link.layout()
        link.installMenuTrackingArea(in: host)
        item.view = host
        menu.addItem(item)

        let bridge = MenuWindowCursorTrackingBridge()
        var callbackInstalledBridge = false
        host.onMenuWindowChanged = { window in
            guard let window else { return }
            bridge.install(on: window)
            bridge.register(host)
            bridge.beginMenuTracking()
            callbackInstalledBridge = true
        }

        let previousCursor = NSCursor.current
        defer {
            bridge.tearDown()
            previousCursor.set()
            menu.removeAllItems()
        }

        var hostAttached = false
        var bridgeInstalled = false
        var trackingAreaCount = 0
        let probeTimer = Timer(
            timeInterval: 0.02,
            repeats: false
        ) { _ in
            guard let window = host.window else {
                menu.cancelTracking()
                return
            }
            hostAttached = true
            bridgeInstalled = window.acceptsMouseMovedEvents
            trackingAreaCount = host.trackingAreas.count
            menu.cancelTracking()
        }
        RunLoop.main.add(probeTimer, forMode: .eventTracking)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: 0),
            in: nil
        )

        XCTAssertTrue(hostAttached)
        XCTAssertTrue(bridgeInstalled)
        XCTAssertTrue(callbackInstalledBridge)
        XCTAssertEqual(trackingAreaCount, 3)
    }

    func testMenuWindowCursorBridgeRoutesVisibleGlyphAndBlankArea() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 28),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.acceptsMouseMovedEvents = false

        let host = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 32, y: 4, width: 170, height: 20)
        host.addSubview(link)
        link.layout()
        link.installMenuTrackingArea(in: host)
        window.contentView = host

        let bridge = MenuWindowCursorTrackingBridge()
        bridge.install(on: window)
        bridge.beginMenuTracking()

        XCTAssertTrue(window.acceptsMouseMovedEvents)
        guard let bridgeMouseArea = host.trackingAreas.first(where: {
            $0.owner as AnyObject === bridge
                && $0.options.contains(.mouseMoved)
        }), let bridgeCursorArea = host.trackingAreas.first(where: {
            $0.owner as AnyObject === bridge
                && $0.options.contains(.cursorUpdate)
        }) else {
            return XCTFail("Expected separate content-view mouse and cursor bridge tracking areas")
        }
        XCTAssertTrue(bridgeMouseArea.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(bridgeMouseArea.options.contains(.activeAlways))
        XCTAssertFalse(bridgeMouseArea.options.contains(.cursorUpdate))
        XCTAssertTrue(bridgeCursorArea.options.contains(.activeAlways))
        XCTAssertFalse(bridgeCursorArea.options.contains(.activeInKeyWindow))
        XCTAssertFalse(bridgeCursorArea.options.contains(.mouseMoved))
        XCTAssertEqual(bridgeMouseArea.rect, host.bounds)
        XCTAssertEqual(bridgeCursorArea.rect, host.bounds)

        let previousCursor = NSCursor.current
        defer {
            bridge.tearDown()
            previousCursor.set()
            window.contentView = nil
        }
        NSCursor.arrow.set()

        let visiblePoint = host.convert(link.visibleTextHitRect.center, from: link)
        let blankPoint = host.convert(
            NSPoint(
                x: link.visibleTextHitRect.maxX
                    + (link.bounds.maxX - link.visibleTextHitRect.maxX) / 2,
                y: link.visibleTextHitRect.midY
            ),
            from: link
        )

        bridge.mouseMoved(with: makeMouseEvent(type: .mouseMoved, location: visiblePoint))
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))

        bridge.cursorUpdate(with: makeMouseEvent(type: .mouseMoved, location: blankPoint))
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.arrow))

        bridge.tearDown()
        XCTAssertFalse(window.acceptsMouseMovedEvents)
    }

    func testMenuWindowCursorBridgeReassertsCursorAfterMenuDispatch() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 28),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.acceptsMouseMovedEvents = false

        let host = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 32, y: 4, width: 170, height: 20)
        host.addSubview(link)
        link.layout()
        window.contentView = host
        link.installMenuTrackingArea(in: host)

        let bridge = MenuWindowCursorTrackingBridge()
        bridge.install(on: window)

        let previousCursor = NSCursor.current
        defer {
            bridge.tearDown()
            previousCursor.set()
            window.contentView = nil
        }

        NSCursor.arrow.set()

        let visiblePoint = host.convert(link.visibleTextHitRect.center, from: link)
        bridge.handleMenuMouseMoved(
            with: makeMouseEvent(type: .mouseMoved, location: visiblePoint)
        )
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))

        // Simulate NSMenu restoring its default cursor after dispatching the
        // movement event. The bridge must win on the event-tracking turn.
        NSCursor.arrow.set()
        bridge.reassertMenuCursorState()

        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))
    }

    func testMenuWindowCursorBridgeReassertsCursorInMenuTrackingRunLoopMode() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 28),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.acceptsMouseMovedEvents = false

        let host = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 32, y: 4, width: 170, height: 20)
        host.addSubview(link)
        link.layout()
        window.contentView = host
        link.installMenuTrackingArea(in: host)

        let bridge = MenuWindowCursorTrackingBridge()
        bridge.install(on: window)

        let previousCursor = NSCursor.current
        defer {
            bridge.tearDown()
            previousCursor.set()
            window.contentView = nil
        }

        NSCursor.arrow.set()
        let visiblePoint = host.convert(link.visibleTextHitRect.center, from: link)
        let screenPoint = NSEvent.mouseLocation
        window.setFrameOrigin(
            NSPoint(
                x: screenPoint.x - visiblePoint.x,
                y: screenPoint.y - visiblePoint.y
            )
        )
        bridge.handleMenuMouseMoved(
            with: makeMouseEvent(type: .mouseMoved, location: visiblePoint)
        )

        // Simulate NSMenu restoring its default cursor before the tracking
        // run-loop gets to the bridge's deferred reassertion.
        NSCursor.arrow.set()
        bridge.reassertMenuCursorState()
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))
        NSCursor.arrow.set()
        let runLoopWakeup = Timer(
            timeInterval: 0.001,
            repeats: false
        ) { _ in }
        RunLoop.main.add(runLoopWakeup, forMode: .eventTracking)
        _ = RunLoop.main.run(
            mode: .eventTracking,
            before: Date(timeIntervalSinceNow: 0.05)
        )

        // The real menu window is under the pointer, so its cursor-rect
        // rebuild must preserve the visible-glyph hand cursor as well.
        window.resetCursorRects()
        host.resetCursorRects()
        XCTAssertTrue(NSCursor.current.isEqual(NSCursor.pointingHand))
    }

    func testMenuWindowCursorBridgeSamplesActualScreenMouseLocation() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 28),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 32, y: 4, width: 170, height: 20)
        host.addSubview(link)
        link.layout()
        link.installMenuTrackingArea(in: host)
        window.contentView = host

        let bridge = MenuWindowCursorTrackingBridge()
        bridge.install(on: window)
        bridge.register(host)

        let previousCursor = NSCursor.current
        defer {
            bridge.tearDown()
            previousCursor.set()
            window.contentView = nil
        }

        let visiblePoint = host.convert(link.visibleTextHitRect.center, from: link)
        let mouseScreenPoint = NSEvent.mouseLocation
        window.setFrameOrigin(
            NSPoint(
                x: mouseScreenPoint.x - visiblePoint.x,
                y: mouseScreenPoint.y - visiblePoint.y
            )
        )
        NSCursor.arrow.set()
        bridge.refreshMenuCursorState()

        XCTAssertTrue(
            NSCursor.current.isEqual(NSCursor.pointingHand),
            "cursor=\(NSCursor.current); window=\(window.frame); screen=\(mouseScreenPoint); "
                + "windowPoint=\(window.convertPoint(fromScreen: mouseScreenPoint)); "
                + "visible=\(visiblePoint); host=\(host.convert(visiblePoint, to: nil)); "
                + "hostBounds=\(host.bounds)"
        )
    }

    func testMenuWindowCursorBridgeTeardownRestoresWindowState() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 24),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.acceptsMouseMovedEvents = false
        let contentView = NSView(frame: window.frame)
        window.contentView = contentView

        let bridge = MenuWindowCursorTrackingBridge()
        bridge.install(on: window)
        XCTAssertEqual(contentView.trackingAreas.count, 2)
        XCTAssertTrue(window.acceptsMouseMovedEvents)

        bridge.tearDown()

        XCTAssertEqual(contentView.trackingAreas.count, 0)
        XCTAssertFalse(window.acceptsMouseMovedEvents)
        window.contentView = nil
    }

    func testMenuHostedLinkRebuildsPreciseHostTrackingWhenTextGeometryChanges() {
        let host = MenuItemContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 20))
        let link = HoverLinkTextField(text: "Provider")
        link.frame = NSRect(x: 40, y: 0, width: 180, height: 20)
        host.addSubview(link)
        link.layout()
        link.installMenuTrackingArea(in: host)

        guard let initialMouseArea = host.trackingAreas.first(where: { $0.options.contains(.mouseMoved) }) else {
            return XCTFail("Expected a mouse tracking area")
        }
        let initialRect = initialMouseArea.rect
        link.frame = NSRect(x: 12, y: 0, width: 90, height: 20)
        link.layout()

        XCTAssertEqual(host.trackingAreas.count, 3)
        guard let mouseArea = host.trackingAreas.first(where: { $0.options.contains(.mouseMoved) }) else {
            return XCTFail("Expected a mouse tracking area")
        }
        XCTAssertEqual(
            mouseArea.rect,
            host.convert(link.visibleTextHitRect, from: link)
        )
        XCTAssertNotEqual(mouseArea.rect, initialRect)
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        windowNumber: Int = 0
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
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
