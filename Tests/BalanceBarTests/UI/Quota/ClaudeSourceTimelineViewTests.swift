import AppKit
import XCTest
@testable import BalanceBar

final class ClaudeSourceTimelineViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z
    private let utc = TimeZone(identifier: "UTC")!
    private typealias Reading = ClaudeSourceTimeline.Reading
    private typealias Run = ClaudeSourceTimeline.FailureRun

    private func layout(
        readings: [Reading] = [], failures: [Run] = [], width: CGFloat = 660, labelColumn: CGFloat = 60
    ) -> ClaudeSourceTimelineLayout {
        ClaudeSourceTimelineLayout(
            snapshot: .init(readings: readings, failures: failures), now: now,
            bounds: CGRect(x: 0, y: 0, width: width, height: ClaudeSourceTimelineLayout.height),
            labelColumnWidth: labelColumn, timeZone: utc)
    }

    private func reading(_ source: StatusSlotLiveSource, _ from: TimeInterval, _ to: TimeInterval) -> Reading {
        Reading(source: source, observedAt: now.addingTimeInterval(from), expiresAt: now.addingTimeInterval(to))
    }

    func testLanesFollowTheSketchOrderAndTheNowLineIsTheRightEdge() {
        let layout = layout()
        XCTAssertEqual(ClaudeSourceTimelineLayout.lanes, [.mod, .statusLine, .oauthAPI])
        XCTAssertLessThan(layout.laneRect(.mod).minY, layout.laneRect(.statusLine).minY)
        XCTAssertLessThan(layout.laneRect(.statusLine).minY, layout.laneRect(.oauthAPI).minY)
        XCTAssertEqual(layout.nowX, 660)
        XCTAssertEqual(layout.x(for: now.addingTimeInterval(-3_600)), 60)
        XCTAssertEqual(layout.x(for: now.addingTimeInterval(-1_800)), 360)
    }

    func testTouchingReadingsMergeIntoOneBarAndAreClippedAtNow() {
        let layout = layout(readings: [
            reading(.oauthAPI, -1_800, -1_200),
            reading(.oauthAPI, -1_200, -600),   // touches: same bar, divider at its start
            reading(.oauthAPI, -300, 300),      // gap before it; runs past now
            reading(.mod, -4_000, -3_700),      // entirely before the window
        ])
        let oauth = layout.bars.filter { $0.source == .oauthAPI }
        XCTAssertEqual(oauth.count, 2)
        XCTAssertEqual(oauth[0].rect.minX, 360, accuracy: 0.01)
        XCTAssertEqual(oauth[0].rect.maxX, 560, accuracy: 0.01)
        XCTAssertEqual(oauth[0].dividers, [460])
        XCTAssertEqual(oauth[1].rect.maxX, layout.nowX, accuracy: 0.01, "validity beyond now is not drawn")
        XCTAssertTrue(layout.bars.filter { $0.source == .mod }.isEmpty)
        XCTAssertEqual(oauth[0].rect.midY, layout.laneRect(.oauthAPI).midY, accuracy: 0.01)
    }

    func testAReadingThatJustArrivedStaysLeftOfTheNowLine() {
        let layout = layout(
            readings: [reading(.statusLine, -1, 120)],
            failures: [Run(start: now.addingTimeInterval(-1), end: nil, kind: .network)])
        let bar = try! XCTUnwrap(layout.bars.first)
        XCTAssertEqual(bar.rect.maxX, layout.nowX, accuracy: 0.01)
        XCTAssertEqual(bar.rect.width, ClaudeSourceTimelineLayout.minimumMarkWidth, accuracy: 0.01)
        let band = try! XCTUnwrap(layout.bands.first)
        XCTAssertLessThanOrEqual(band.rect.maxX, layout.nowX + 0.01)
        let early = self.layout(readings: [reading(.mod, -3_600, -3_600 + 0.1)]).bars
        XCTAssertGreaterThanOrEqual(early.first?.rect.minX ?? 0, 60, "a mark at the left edge stays inside the chart too")
    }

    func testAHandOverBetweenLanesGetsASameMomentJunction() {
        let layout = layout(readings: [
            reading(.mod, -1_300, -1_200),       // Mod expires at -1200 …
            reading(.oauthAPI, -1_200, -600),    // … exactly when the official read takes over
            reading(.statusLine, -900, -700),    // 100 s from anything: no junction
            reading(.statusLine, -60, 60),       // live: its "end" is only cut off by now
            reading(.oauthAPI, -60, 300),
        ])
        XCTAssertEqual(layout.junctions.count, 1)
        let junction = try! XCTUnwrap(layout.junctions.first)
        XCTAssertEqual(junction.x, 460.75, accuracy: 0.01, "on the outline of the block that starts")
        XCTAssertEqual(junction.minY, layout.laneRect(.mod).midY + ClaudeSourceTimelineLayout.barHeight / 2, accuracy: 0.01,
                       "leaves the upper block's bottom edge")
        XCTAssertEqual(junction.maxY, layout.laneRect(.oauthAPI).midY - ClaudeSourceTimelineLayout.barHeight / 2, accuracy: 0.01,
                       "lands on the lower block's top edge")
    }

    func testFrequentReadingsMergeWithoutCrowdedDividers() {
        let readings = stride(from: -600.0, to: -300, by: 5).map { reading(.mod, $0, $0 + 120) }
        let bars = layout(readings: readings).bars
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].readings.count, readings.count)
        let gaps = zip(bars[0].dividers.dropFirst(), bars[0].dividers).map { $0 - $1 }
        XCTAssertTrue(gaps.allSatisfy { $0 >= ClaudeSourceTimelineLayout.minimumDividerSpacing - 0.001 })
        XCTAssertLessThan(bars[0].dividers.count, readings.count - 1)
    }

    func testFailureBoxesStayInTheOAuthLaneMatchTheBarsAndAnOpenRunReachesNow() {
        let layout = layout(failures: [
            Run(start: now.addingTimeInterval(-1_500), end: now.addingTimeInterval(-900), kind: .network),
            Run(start: now.addingTimeInterval(-120), end: nil, kind: .unauthorized),
        ])
        let lane = layout.laneRect(.oauthAPI)
        XCTAssertEqual(layout.bands.count, 2)
        for band in layout.bands {
            XCTAssertGreaterThanOrEqual(band.rect.minY, lane.minY)
            XCTAssertLessThanOrEqual(band.rect.maxY, lane.maxY)
        }
        XCTAssertEqual(layout.bands[1].rect.maxX, layout.nowX, accuracy: 0.01)
        let bar = self.layout(readings: [reading(.oauthAPI, -600, 0)]).bars[0]
        XCTAssertEqual(layout.bands[0].rect.height, bar.rect.height, "a failure box is the size of a bar")
        XCTAssertEqual(layout.bands[0].rect.midY, bar.rect.midY, accuracy: 0.01)
    }

    func testTicksSitOnQuarterHoursOfTheDisplayTimeZone() {
        let layout = layout()
        XCTAssertEqual(layout.ticks.count, 4)
        let formatter = DateFormatter()
        formatter.timeZone = utc
        formatter.dateFormat = "HH:mm"
        XCTAssertEqual(layout.ticks.map { formatter.string(from: $0.date) }, ["07:00", "07:15", "07:30", "07:45"])
        let shifted = ClaudeSourceTimelineLayout(
            snapshot: .empty, now: now.addingTimeInterval(400), bounds: CGRect(x: 0, y: 0, width: 660, height: 90),
            labelColumnWidth: 60, timeZone: utc)
        XCTAssertEqual(shifted.ticks.map { formatter.string(from: $0.date) }, ["07:15", "07:30", "07:45", "08:00"])
    }

    func testViewShowsTheCardStatusTooltipsAndAnAccessibleSummary() {
        let content = ClaudeSourceTimelineView.Content(
            timeline: .init(
                readings: [reading(.oauthAPI, -900, -300), reading(.mod, -60, 60)],
                failures: [Run(start: now.addingTimeInterval(-1_500), end: now.addingTimeInterval(-1_000), kind: .network)]),
            status: .realtime(.mod, at: now.addingTimeInterval(-60)))
        let view = ClaudeSourceTimelineView(provider: { content }, localize: StatusSlotText.defaultLocalize, timeZone: utc, now: { self.now })
        view.frame = NSRect(x: 0, y: 0, width: 600, height: ClaudeSourceTimelineLayout.height)
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.statusSlot.isHidden)
        XCTAssertEqual(view.statusSlot.textForTesting, "实时 · Mod")
        let summary = view.accessibilitySummary
        XCTAssertEqual(view.accessibilityLabel(), summary)
        XCTAssertTrue(summary.contains(tr(.keyClaudeTimelineAccessibilityCount, arguments: ["Mod", "1"])), summary)
        XCTAssertTrue(summary.contains(tr(.keyClaudeTimelineAccessibilityFailures, arguments: ["1"])), summary)

        let layout = view.makeLayout()
        let modBar = try! XCTUnwrap(layout.bars.first { $0.source == .mod })
        let reading = view.hoverContent(for: try! XCTUnwrap(layout.hoverTarget(at: CGPoint(x: modBar.rect.midX, y: modBar.rect.midY))))
        XCTAssertEqual(reading.title, "Mod")
        XCTAssertEqual(reading.rows, [
            .init(label: tr(.keyClaudeTimelineHoverTime), value: "07:59:00 – 08:00:00"),
            .init(label: tr(.keyClaudeTimelineHoverDuration), value: ClaudeSourceTimelineView.durationText(60)),
            .init(label: tr(.keyClaudeTimelineHoverRefreshes), value: tr(.keyClaudeTimelineHoverRefreshCount, arguments: ["1"])),
            .init(label: tr(.keyClaudeTimelineHoverValidity), value: ClaudeSourceTimelineView.durationText(120)),
        ], "type heading, then range so far, duration, refreshes and each refresh's validity")
        let band = try! XCTUnwrap(layout.bands.first)
        let failure = view.hoverContent(for: .band(band))
        XCTAssertEqual(failure.title, "OAuth API · " + tr(.keyClaudeTimelineFailureNetwork))
        XCTAssertEqual(failure.rows, [
            .init(label: tr(.keyClaudeTimelineHoverTime), value: "07:35:00 – 07:43:20"),
            .init(label: tr(.keyClaudeTimelineHoverDuration), value: ClaudeSourceTimelineView.durationText(500)),
        ])
        XCTAssertEqual(view.hoverText(at: NSPoint(x: band.rect.midX, y: band.rect.midY)), failure.plainText)
        XCTAssertEqual(
            view.hoverText(at: NSPoint(x: 2, y: layout.laneRect(.oauthAPI).midY)),
            tr(.keyClaudeTimelineTooltipOauthRule))
        XCTAssertNil(view.hoverText(at: NSPoint(x: 2, y: layout.laneRect(.mod).midY)))
    }

    func testEachRefreshBlockIsItsOwnHoverTarget() {
        // Three Mod refreshes 40 s apart (≈ 6.7 pt) inside one continuous bar.
        let layout = layout(readings: [reading(.mod, -200, -80), reading(.mod, -160, -40), reading(.mod, -120, 0)])
        let bar = try! XCTUnwrap(layout.bars.first)
        XCTAssertEqual(bar.pieces.count, 3)
        XCTAssertEqual(bar.pieces.map(\.start), [-200, -160, -120].map { now.addingTimeInterval($0) })
        XCTAssertEqual(bar.pieces.map(\.end), [-160, -120, 0].map { now.addingTimeInterval($0) })
        XCTAssertEqual(bar.pieces.first?.rect.minX, bar.rect.minX)
        XCTAssertEqual(bar.pieces.last?.rect.maxX, bar.rect.maxX)
        let middle = bar.pieces[1]
        guard case let .piece(hit)? = layout.hoverTarget(at: CGPoint(x: middle.rect.midX, y: middle.rect.midY)) else {
            return XCTFail("the middle block should be hoverable")
        }
        XCTAssertEqual(hit, middle)
        XCTAssertNil(layout.hoverTarget(at: CGPoint(x: bar.rect.minX - 20, y: bar.rect.midY)))
    }

    func testDurationsReadAsSecondsMinutesOrHours() {
        XCTAssertEqual(ClaudeSourceTimelineView.durationText(45), tr(.keyClaudeTimelineDurationSeconds, arguments: ["45"]))
        XCTAssertEqual(ClaudeSourceTimelineView.durationText(150), tr(.keyClaudeTimelineDurationMinutes, arguments: ["3"]))
        XCTAssertEqual(ClaudeSourceTimelineView.durationText(3_900), tr(.keyClaudeTimelineDurationHours, arguments: ["1", "5"]))
    }

    func testHoveringLiftsTheBlockBlursTheChartAndQueuesTheTooltip() throws {
        let content = ClaudeSourceTimelineView.Content(
            timeline: .init(readings: [reading(.oauthAPI, -900, -300)], failures: []), status: nil)
        let view = ClaudeSourceTimelineView(provider: { content }, localize: StatusSlotText.defaultLocalize, timeZone: utc, now: { self.now })
        view.frame = NSRect(x: 0, y: 0, width: 600, height: ClaudeSourceTimelineLayout.height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        defer { window.close() }
        let bar = try XCTUnwrap(view.makeLayout().bars.first)

        view.updateHover(at: NSPoint(x: bar.rect.midX, y: bar.rect.midY))
        XCTAssertTrue(view.isLiftedForTesting)
        XCTAssertTrue(view.isChartRecededForTesting, "everything but the lifted block is blurred")
        XCTAssertTrue(view.isTooltipPendingOrShownForTesting)

        view.updateHover(at: NSPoint(x: bar.rect.midX, y: view.makeLayout().laneRect(.mod).midY))
        XCTAssertNil(view.hovered, "an empty spot lowers the block")
        XCTAssertFalse(view.isTooltipPendingOrShownForTesting)
    }

    /// Offscreen renders for review (XCTest attachments); `BB_TIMELINE_RENDER_DIR` also writes PNGs.
    func testOffscreenRendersInLightAndDark() throws {
        let busy = ClaudeSourceTimelineView.Content(
            timeline: .init(
                readings: [-3_300, -2_700, -2_100].map { reading(.oauthAPI, $0, $0 + 600) }
                    + [reading(.oauthAPI, -1_100, -500), reading(.oauthAPI, -300, 300)]
                    + stride(from: -1_900.0, to: -1_500, by: 20).map { reading(.statusLine, $0, $0 + 120) }
                    + stride(from: -1_800.0, to: -1_400, by: 15).map { reading(.mod, $0, $0 + 120) }
                    + stride(from: -420.0, to: -60, by: 20).map { reading(.statusLine, $0, $0 + 120) }
                    + stride(from: -400.0, to: -5, by: 10).map { reading(.mod, $0, $0 + 120) },
                failures: [Run(start: now.addingTimeInterval(-1_400), end: now.addingTimeInterval(-1_100), kind: .network)]),
            status: .realtime(.mod, at: now.addingTimeInterval(-5)))
        let cases: [(String, ClaudeSourceTimelineView.Content, CGFloat)] = [
            ("busy", busy, 600), ("narrow", busy, 380), ("empty", .empty, 600),
        ]
        let directory = ProcessInfo.processInfo.environment["BB_TIMELINE_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        for (name, content, width) in cases {
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let view = ClaudeSourceTimelineView(provider: { content }, localize: StatusSlotText.defaultLocalize, timeZone: utc, now: { self.now })
                let host = NSView(frame: NSRect(x: 0, y: 0, width: width + 32, height: ClaudeSourceTimelineLayout.height + 24))
                host.appearance = NSAppearance(named: appearanceName)
                host.wantsLayer = true
                host.effectiveAppearance.performAsCurrentDrawingAppearance {
                    host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                host.addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
                    view.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
                    view.widthAnchor.constraint(equalToConstant: width),
                ])
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(view.bounds.width, width)
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.effectiveAppearance.performAsCurrentDrawingAppearance {
                    host.cacheDisplay(in: host.bounds, to: image)
                }
                let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                let label = "timeline-\(name)-\(appearanceName == .aqua ? "light" : "dark")"
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = label
                attachment.lifetime = .keepAlways
                add(attachment)
                if let directory { try png.write(to: directory.appendingPathComponent(label + ".png")) }
            }
        }
    }

    func testBlockTooltipFitsItsContentInEveryLanguage() throws {
        for language in AppLanguage.allCases {
            let rows: [ClaudeSourceTimelineTooltipContent.Row] = [
                .init(label: tr(.keyClaudeTimelineHoverTime, language: language), value: "15:04:53 – 15:09:53"),
                .init(label: tr(.keyClaudeTimelineHoverDuration, language: language), value: "5"),
                .init(label: tr(.keyClaudeTimelineHoverRefreshes, language: language),
                      value: tr(.keyClaudeTimelineHoverRefreshCount, arguments: ["12"], language: language)),
                .init(label: tr(.keyClaudeTimelineHoverValidity, language: language), value: "5"),
            ]
            let controller = ClaudeSourceTimelineTooltipViewController(
                content: .init(title: "OAuth API · " + tr(.keyClaudeTimelineFailureNetwork, language: language), color: .systemBlue, rows: rows))
            controller.loadViewIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            for label in descendants(of: controller.view).compactMap({ $0 as? NSTextField }) {
                XCTAssertGreaterThanOrEqual(
                    ceil(label.frame.width) + 0.5, ceil(label.intrinsicContentSize.width),
                    "\(language): \(label.stringValue) is clipped")
                let frame = label.convert(label.bounds, to: controller.view)
                XCTAssertTrue(controller.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(language): \(label.stringValue) overflows")
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    func testOffscreenRendersTheBlockTooltip() throws {
        let content = ClaudeSourceTimelineTooltipContent(title: "Mod", color: .systemOrange, rows: [
            .init(label: tr(.keyClaudeTimelineHoverTime), value: "15:04:53 – 15:09:53"),
            .init(label: tr(.keyClaudeTimelineHoverDuration), value: ClaudeSourceTimelineView.durationText(300)),
            .init(label: tr(.keyClaudeTimelineHoverRefreshes), value: tr(.keyClaudeTimelineHoverRefreshCount, arguments: ["1"])),
            .init(label: tr(.keyClaudeTimelineHoverValidity), value: ClaudeSourceTimelineView.durationText(300)),
        ])
        let directory = ProcessInfo.processInfo.environment["BB_TIMELINE_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let controller = ClaudeSourceTimelineTooltipViewController(content: content)
            controller.loadViewIfNeeded()
            let view = controller.view
            view.appearance = NSAppearance(named: appearanceName)
            view.wantsLayer = true
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: image) }
            let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            let label = "timeline-tooltip-\(appearanceName == .aqua ? "light" : "dark")"
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = label
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory { try png.write(to: directory.appendingPathComponent(label + ".png")) }
        }
    }

    func testStatusSlotIsHiddenUntilThePipelinePublishes() {
        let view = ClaudeSourceTimelineView(provider: { .empty }, timeZone: utc, now: { self.now })
        XCTAssertTrue(view.statusSlot.isHidden)
    }

    func testRefreshTimerRunsOnlyInAVisibleWindow() {
        let view = ClaudeSourceTimelineView(provider: { .empty }, timeZone: utc, now: { self.now })
        view.syncRefreshTimer()
        XCTAssertFalse(view.isRefreshTimerRunningForTesting, "no window, no timer")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        XCTAssertFalse(view.isRefreshTimerRunningForTesting, "an ordered-out window is not visible")
        view.removeFromSuperview()
        XCTAssertFalse(view.isRefreshTimerRunningForTesting)
        window.close()
    }

    func testLaneNamesFitTheLabelColumnInEveryLanguage() {
        for language in AppLanguage.allCases {
            let localize: (StatusSlotText) -> String = { StatusSlotText.appLocalize(text: $0, language: language) }
            let view = ClaudeSourceTimelineView(provider: { .empty }, localize: localize, timeZone: utc, now: { self.now })
            for width: CGFloat in [420, 480, 760] {
                view.frame = NSRect(x: 0, y: 0, width: width - 2 * SettingsLayout.rowHorizontalInset, height: ClaudeSourceTimelineLayout.height)
                let layout = view.makeLayout()
                XCTAssertGreaterThan(layout.plot.width, layout.plot.minX, "\(language) at \(width)pt leaves most of the width to the chart")
                for source in ClaudeSourceTimelineLayout.lanes {
                    let name = localize(source == .mod ? .sourceMod : source == .statusLine ? .sourceStatusLine : .sourceOAuthAPI)
                    let textWidth = (name as NSString).size(withAttributes: [.font: ClaudeSourceTimelineView.labelFont]).width
                    XCTAssertLessThanOrEqual(textWidth, layout.plot.minX, "\(language) lane name \(name) overlaps the bars")
                }
            }
        }
    }
}
