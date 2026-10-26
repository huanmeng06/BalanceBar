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
        XCTAssertEqual(
            view.toolTipText(at: NSPoint(x: modBar.rect.midX, y: modBar.rect.midY)),
            tr(.keyClaudeTimelineTooltipReading, arguments: ["Mod", "07:59:00", "08:01:00"]))
        let band = try! XCTUnwrap(layout.bands.first)
        XCTAssertEqual(
            view.toolTipText(at: NSPoint(x: band.rect.midX, y: band.rect.midY)),
            tr(.keyClaudeTimelineTooltipFailure, arguments: [
                "OAuth API", tr(.keyClaudeTimelineFailureNetwork), "07:35:00", "07:43:20"]))
        XCTAssertEqual(
            view.toolTipText(at: NSPoint(x: 2, y: layout.laneRect(.oauthAPI).midY)),
            tr(.keyClaudeTimelineTooltipOauthRule))
        XCTAssertNil(view.toolTipText(at: NSPoint(x: 2, y: layout.laneRect(.mod).midY)))
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
