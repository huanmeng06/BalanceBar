import AppKit
import XCTest
@testable import BalanceBar

final class StatusSlotViewTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-01-01 13:40:00 UTC
    private let time = Date(timeIntervalSince1970: 1_767_274_800)

    private func model(state: WindowState = .inProgress, estimated: Bool = false) -> QuotaDisplayModel {
        QuotaDisplayModel(
            windows: [QuotaWindowDisplay(kind: .fiveHour, usedPercentage: 40, isEstimated: estimated, state: state, hoverTextKey: "k")],
            isEstimated: estimated,
            state: state,
            hoverTextKey: "k"
        )
    }

    private var allStates: [(String, StatusSlotState)] {
        [
            ("refreshing", .refreshing),
            ("error", .error(at: time)),
            ("resetPending", .resetPending(at: time)),
            ("estimated", .estimated(at: time)),
            ("realtime", .realtime(.statusLine, at: time)),
            ("realtime-oauth", .realtime(.oauthAPI, at: time)),
            ("realtime-mod", .realtime(.mod, at: time)),
            ("official", .official(at: time)),
        ]
    }

    // MARK: Priority

    func testResolvePriorityOrder() {
        let ctx = StatusSlotContext(isRefreshing: true, source: .realtime(.statusLine), updatedAt: time)
        XCTAssertEqual(StatusSlotState.resolve(model: model(state: .error, estimated: true), context: ctx), .refreshing)

        var c = ctx; c.isRefreshing = false
        XCTAssertEqual(StatusSlotState.resolve(model: model(state: .error, estimated: true), context: c), .error(at: time))
        XCTAssertEqual(StatusSlotState.resolve(model: model(state: .expired), context: c), .error(at: time))
        XCTAssertEqual(StatusSlotState.resolve(model: model(state: .resetPendingConfirmation, estimated: true), context: c), .resetPending(at: time))
        XCTAssertEqual(StatusSlotState.resolve(model: model(estimated: true), context: c), .estimated(at: time))
        XCTAssertEqual(StatusSlotState.resolve(model: model(), context: c), .realtime(.statusLine, at: time))
        c.source = .official
        XCTAssertEqual(StatusSlotState.resolve(model: model(), context: c), .official(at: time))
    }

    // MARK: Rendering (light + dark)

    private func render(_ state: StatusSlotState, _ appearanceName: NSAppearance.Name) throws -> (StatusSlotView, NSBitmapImageRep) {
        let view = StatusSlotView(timeZone: utc)
        view.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        view.frame = NSRect(x: 0, y: 0, width: StatusSlotView.fixedWidth, height: StatusSlotView.fixedHeight)
        view.update(state: state)
        view.layoutSubtreeIfNeeded()
        // Fixed 1x bitmap so pixel size does not depend on the runner's backing scale.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(StatusSlotView.fixedWidth),
            pixelsHigh: Int(StatusSlotView.fixedHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return (view, rep)
    }

    /// Rendering-level checks that do not depend on font rasterisation details.
    func testRenderedColorsClippingAndAppearance() throws {
        let font = NSFont.monospacedDigitSystemFont(ofSize: StatusSlotView.fontSize, weight: .regular)
        for (name, state) in allStates {
            let (lightView, light) = try render(state, .aqua)
            let (_, dark) = try render(state, .darkAqua)
            if case .error = state {
                // systemOrange adapts by only ~0.03 per channel, below differingPixelRatio's 0.1
                // threshold, so check each render carries its own appearance's exact orange.
                let lightOrange = resolved(.systemOrange, in: try XCTUnwrap(NSAppearance(named: .aqua)))
                let darkOrange = resolved(.systemOrange, in: try XCTUnwrap(NSAppearance(named: .darkAqua)))
                XCTAssertGreaterThan(distance(lightOrange, darkOrange), 0.02, "systemOrange is not appearance-adaptive")
                for (label, rep, own, other) in [("light", light, lightOrange, darkOrange), ("dark", dark, darkOrange, lightOrange)] {
                    let ownDistance = nearestDistance(to: own, in: rep)
                    let otherDistance = nearestDistance(to: other, in: rep)
                    XCTAssertLessThanOrEqual(ownDistance, 0.01, "error \(label): no pixel matches its orange (\(ownDistance))")
                    XCTAssertLessThan(ownDistance, otherDistance, "error \(label): rendered with the other appearance's orange")
                }
            } else {
                XCTAssertGreaterThan(differingPixelRatio(light, dark), 0, "\(name): light and dark render identically")
            }

            for (appearanceName, rep) in [(NSAppearance.Name.aqua, light), (.darkAqua, dark)] {
                let label = "\(appearanceName.rawValue) \(name)"
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                XCTAssertTrue(hasOpaquePixel(rep), "\(label) rendered blank")

                let green = resolved(.systemGreen, in: appearance)
                let orange = resolved(.systemOrange, in: appearance)
                if case .realtime = state {
                    XCTAssertTrue(containsPixel(near: green, in: rep), "\(label) missing green dot")
                } else {
                    XCTAssertFalse(containsPixel(near: green, in: rep), "\(label) unexpected green")
                }
                if case .error = state {
                    XCTAssertTrue(containsPixel(near: orange, in: rep, tolerance: 0.2), "\(label) error text not orange")
                }
                // Text is right-aligned: ink touching the leading column means it was clipped.
                XCTAssertFalse(columnHasInk(0, rep), "\(label) clipped at leading edge")
            }

            let textWidth = (lightView.textForTesting as NSString).size(withAttributes: [.font: font]).width
            var available = StatusSlotView.fixedWidth
            if case .realtime = state { available -= StatusSlotView.dotDiameter + 3 }
            XCTAssertLessThanOrEqual(textWidth, available, "\(name) text wider than slot")
        }
    }

    // MARK: Relative time and source

    func testRelativeTextUnits() {
        let now = Date(timeIntervalSince1970: 1_767_300_000)
        func text(_ seconds: TimeInterval?) -> String {
            StatusSlotAppearance.relativeText(
                from: seconds.map { now.addingTimeInterval(-$0) }, now: now, localize: StatusSlotText.defaultLocalize)
        }
        XCTAssertEqual(text(nil), "--")
        XCTAssertEqual(text(0), "1 分钟前")
        XCTAssertEqual(text(59), "1 分钟前")
        XCTAssertEqual(text(60), "1 分钟前")
        XCTAssertEqual(text(125), "2 分钟前")
        XCTAssertEqual(text(59 * 60 + 59), "59 分钟前")
        XCTAssertEqual(text(3_600), "1 小时前")
        XCTAssertEqual(text(23 * 3_600 + 3_599), "23 小时前")
        XCTAssertEqual(text(24 * 3_600), "1 天前")
        XCTAssertEqual(text(3 * 86_400), "3 天前")
        XCTAssertEqual(text(-500), "1 分钟前", "a clock that ran backwards never shows a negative age")
    }

    func testStaleAndFailedStatesShowAgeAndSourceInsteadOfClockTime() {
        var clock = time.addingTimeInterval(5 * 60)
        let view = StatusSlotView(timeZone: utc, now: { clock })

        view.update(state: .official(at: time, source: .mod))
        XCTAssertEqual(view.textForTesting, "5 分钟前 · Mod", "a stale local source keeps showing its age")
        XCTAssertTrue(view.isDotVisibleForTesting, "stale readings carry the orange dot")
        XCTAssertEqual(srgb(view.textColorForTesting), srgb(.secondaryLabelColor))
        XCTAssertEqual(view.toolTip, "来自本机数据，更新于 13:40:00", "a stale Mod reading is local data, never described as official")
        view.update(state: .official(at: time, source: .statusLine))
        XCTAssertEqual(view.toolTip, "来自本机数据，更新于 13:40:00")
        view.update(state: .official(at: time, source: .oauthAPI))
        XCTAssertEqual(view.toolTip, "官方数据，更新于 13:40:00", "the absolute time moved into the tooltip")
        view.update(state: .official(at: time, source: .mod))

        view.update(state: .error(at: time, source: .oauthAPI))
        XCTAssertEqual(view.textForTesting, "⚠︎ 5 分钟前 · OAuth API")
        XCTAssertFalse(view.isDotVisibleForTesting, "a failure uses the warning glyph, not the dot")
        XCTAssertEqual(srgb(view.textColorForTesting), srgb(.systemOrange))

        view.update(state: .official(at: time, source: nil))
        XCTAssertEqual(view.textForTesting, "5 分钟前", "no source, no separator")

        view.update(state: .official(at: time, source: .statusLine))
        XCTAssertEqual(view.textForTesting, "5 分钟前 · 原生同步")
        view.update(state: .official(at: time, source: .oauthAPI))
        XCTAssertEqual(view.textForTesting, "5 分钟前 · OAuth API", "an official reading still shows its age")
        clock = clock.addingTimeInterval(61)
        view.refreshAgeForTesting()
        XCTAssertEqual(view.textForTesting, "6 分钟前 · OAuth API", "the age keeps counting while the slot is shown")
    }

    func testResolveCarriesTheLastSourceIntoStaleAndFailedStates() {
        var context = StatusSlotContext(source: .official, updatedAt: time, lastSource: .mod)
        XCTAssertEqual(StatusSlotState.resolve(model: model(), context: context), .official(at: time, source: .mod))
        XCTAssertEqual(StatusSlotState.resolve(model: model(state: .error), context: context), .error(at: time, source: .mod))
        context.source = .realtime(.mod)
        XCTAssertEqual(StatusSlotState.resolve(model: model(), context: context), .realtime(.mod, at: time))
    }

    private static let widestAges: [TimeInterval] = [3_599, 86_399, 8_553_600]

    /// The live label ("实时 · 原生同步") fits the slot in every supported language and source.
    func testLiveSourceLabelFitsTheSlotInEveryLanguage() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: StatusSlotView.fontSize, weight: .regular)
        for language in AppLanguage.allCases {
            let localize: (StatusSlotText) -> String = { StatusSlotText.appLocalize(text: $0, language: language) }
            for source in [StatusSlotLiveSource.oauthAPI, .statusLine, .mod] {
                for age in Self.widestAges {
                    let shownAt = time
                    let view = StatusSlotView(localize: localize, timeZone: utc, now: { shownAt.addingTimeInterval(age) })
                    let states: [StatusSlotState] = [
                        .realtime(source, at: time), .official(at: time, source: source), .error(at: time, source: source)]
                    for state in states {
                        view.update(state: state)
                        let width = (view.textForTesting as NSString).size(withAttributes: [.font: font]).width
                        // Realtime and stale states show a dot; the failure state shows a glyph instead.
                        let reserved: CGFloat = view.isDotVisibleForTesting ? StatusSlotView.dotDiameter + 3 : 0
                        XCTAssertLessThanOrEqual(
                            width, StatusSlotView.fixedWidth - reserved,
                            "\(language) \(source) \(age)s: \(view.textForTesting)")
                        XCTAssertTrue(view.textForTesting.contains(" · "), "\(language) \(source)")
                    }
                }
            }
        }
    }

    private func srgb(_ color: NSColor?) -> NSColor? { color?.usingColorSpace(.sRGB) }

    private func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
    }

    /// Smallest color distance from `target` among fully opaque pixels.
    private func nearestDistance(to target: NSColor, in rep: NSBitmapImageRep) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = srgb(rep.colorAt(x: x, y: y)), c.alphaComponent > 0.99 else { continue }
                best = min(best, distance(c, target))
            }
        }
        return best
    }

    private func containsPixel(near target: NSColor, in rep: NSBitmapImageRep, tolerance: CGFloat = 0.12) -> Bool {
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = srgb(rep.colorAt(x: x, y: y)), c.alphaComponent > 0.9 else { continue }
                if distance(c, target) <= tolerance { return true }
            }
        }
        return false
    }

    private func columnHasInk(_ x: Int, _ rep: NSBitmapImageRep) -> Bool {
        (0..<rep.pixelsHigh).contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.1 }
    }

    private func differingPixelRatio(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        var differing = 0
        for x in 0..<a.pixelsWide {
            for y in 0..<a.pixelsHigh {
                guard let ca = srgb(a.colorAt(x: x, y: y)), let cb = srgb(b.colorAt(x: x, y: y)) else { continue }
                if distance(ca, cb) > 0.1 || abs(ca.alphaComponent - cb.alphaComponent) > 0.1 { differing += 1 }
            }
        }
        return Double(differing) / Double(max(1, a.pixelsWide * a.pixelsHigh))
    }

    // MARK: Title stability

    func testTitleDoesNotMoveWhenSlotStateChanges() {
        let card = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let title = NSTextField(labelWithString: "5 小时额度")
        let slot = StatusSlotView(timeZone: utc)
        let stack = NSStackView(views: [title, slot])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.frame = card.bounds
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        card.addSubview(stack)

        var titleFrames = Set<String>()
        var slotFrames = Set<String>()
        for (_, state) in allStates {
            slot.update(state: state, externalActivityDetected: true)
            stack.layoutSubtreeIfNeeded()
            titleFrames.insert(NSStringFromRect(title.frame))
            slotFrames.insert(NSStringFromRect(slot.frame))
        }
        XCTAssertEqual(titleFrames.count, 1, "title moved: \(titleFrames)")
        XCTAssertEqual(slotFrames.count, 1, "slot resized: \(slotFrames)")
    }

    func testResetPendingWithoutEstimateIsNotReportedAsOfficialOrRealtime() {
        for source in [StatusSlotSource.official, .realtime(.statusLine)] {
            let ctx = StatusSlotContext(source: source, updatedAt: time)
            XCTAssertEqual(StatusSlotState.resolve(model: model(state: .resetPendingConfirmation), context: ctx), .resetPending(at: time))
        }
        // Aggregate in progress but one window awaiting reset confirmation.
        let mixed = QuotaDisplayModel(
            windows: [
                QuotaWindowDisplay(kind: .fiveHour, usedPercentage: 0, isEstimated: false, state: .resetPendingConfirmation, hoverTextKey: "k"),
                QuotaWindowDisplay(kind: .sevenDay, usedPercentage: 30, isEstimated: false, state: .inProgress, hoverTextKey: "k"),
            ],
            isEstimated: false, state: .inProgress, hoverTextKey: "k"
        )
        XCTAssertEqual(StatusSlotState.resolve(model: mixed, context: StatusSlotContext(updatedAt: time)), .resetPending(at: time))

        let view = StatusSlotView(timeZone: utc)
        view.update(model: model(state: .resetPendingConfirmation), context: StatusSlotContext(updatedAt: time))
        XCTAssertEqual(view.textForTesting, "待确认")
        XCTAssertEqual(view.toolTip, "预计已重置，等待确认")
        XCTAssertEqual(view.accessibilityLabel(), "额度状态：待确认")
    }

    // MARK: Time style

    /// Stale / failed states read as "5 分钟前"; the exact HH:mm:ss moved into the tooltip.
    func testAgeStatesKeepTheExactTimeInTheTooltipAndThePlainRefreshTimeFont() {
        let withSeconds = time.addingTimeInterval(7)
        let view = StatusSlotView(timeZone: utc, now: { withSeconds.addingTimeInterval(5 * 60) })
        XCTAssertEqual(view.fontForTesting, .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        view.update(state: .official(at: withSeconds))
        XCTAssertEqual(view.textForTesting, "5 分钟前")
        XCTAssertEqual(view.toolTip, "官方数据，更新于 13:40:07")
        XCTAssertEqual(view.accessibilityLabel(), "额度状态：5 分钟前")
        view.update(state: .error(at: withSeconds))
        XCTAssertEqual(view.textForTesting, "⚠︎ 5 分钟前")
        XCTAssertEqual(view.toolTip, "更新失败，显示的是 13:40:07 的数据")
        XCTAssertEqual(view.accessibilityLabel(), "额度状态：⚠︎ 5 分钟前")
        view.update(state: .estimated(at: withSeconds))
        XCTAssertEqual(view.textForTesting, "≈ 13:40:07")
        XCTAssertEqual(view.toolTip, "根据 13:40:07 的数据估算，等待官方确认")
        view.update(state: .error(at: nil))
        XCTAssertEqual(view.textForTesting, "⚠︎ --")
    }

    // MARK: Hover + VoiceOver

    func testHoverDetailSurvivesTheAgeRefresh() {
        var clock = time.addingTimeInterval(60)
        let view = StatusSlotView(timeZone: utc, now: { clock })
        view.hoverDetail = "Too many requests (HTTP 429)"
        view.update(state: .error(at: time, source: .oauthAPI))
        XCTAssertEqual(view.toolTip, "更新失败，显示的是 13:40:00 的数据\nToo many requests (HTTP 429)")
        clock = clock.addingTimeInterval(30)
        view.refreshAgeForTesting()
        XCTAssertEqual(view.toolTip, "更新失败，显示的是 13:40:00 的数据\nToo many requests (HTTP 429)", "the timer rebuilds the tooltip without dropping the reason")
        XCTAssertEqual(view.accessibilityHelp(), view.toolTip)
        view.hoverDetail = nil
        XCTAssertEqual(view.toolTip, "更新失败，显示的是 13:40:00 的数据")
    }

    func testHoverTextsIncludingExternalActivity() {
        let view = StatusSlotView(timeZone: utc)
        view.update(state: .official(at: time))
        XCTAssertEqual(view.toolTip, "官方数据，更新于 13:40:00")
        view.update(state: .estimated(at: time), externalActivityDetected: true)
        XCTAssertEqual(view.toolTip, "根据 13:40:00 的数据估算，等待官方确认\n检测到其他端在使用，已提高更新频率")
        view.update(state: .error(at: time))
        XCTAssertEqual(view.toolTip, "更新失败，显示的是 13:40:00 的数据")
        for (_, state) in allStates {
            view.update(state: state)
            XCTAssertFalse(view.toolTip?.isEmpty ?? true)
        }
    }

    func testAccessibilityLabels() {
        let view = StatusSlotView(timeZone: utc)
        XCTAssertTrue(view.isAccessibilityElement())
        for (_, state) in allStates {
            view.update(state: state)
            XCTAssertEqual(view.accessibilityLabel(), "额度状态：\(view.textForTesting)")
            XCTAssertEqual(view.accessibilityHelp(), view.toolTip)
        }
    }

    // MARK: Dimming

    func testEstimatedAndResetPendingAreDimmed() {
        let estimated = QuotaWindowDisplay(kind: .fiveHour, usedPercentage: 40, isEstimated: true, state: .inProgress, hoverTextKey: "k")
        let pending = QuotaWindowDisplay(kind: .fiveHour, usedPercentage: 0, isEstimated: false, state: .resetPendingConfirmation, hoverTextKey: "k")
        let live = QuotaWindowDisplay(kind: .fiveHour, usedPercentage: 40, isEstimated: false, state: .inProgress, hoverTextKey: "k")
        XCTAssertEqual(StatusSlotAppearance.valueAlpha(for: estimated), StatusSlotAppearance.dimmedAlpha)
        XCTAssertEqual(StatusSlotAppearance.valueAlpha(for: pending), StatusSlotAppearance.dimmedAlpha)
        XCTAssertEqual(StatusSlotAppearance.valueAlpha(for: live), 1)
        XCTAssertEqual(StatusSlotAppearance.valueText("60%", for: estimated), "≈ 60%")
        XCTAssertEqual(StatusSlotAppearance.valueText("60%", for: live), "60%")
    }

    // MARK: Failure state

    func testFailureStateReasonButtonAndAccessibility() throws {
        var opened = 0
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let view = FailureStateView(reason: "登录已过期") { opened += 1 }
            view.appearance = NSAppearance(named: appearanceName)
            view.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.reasonForTesting, "登录已过期")
            XCTAssertEqual(view.openUsageButton.title, "打开官方用量页")
            XCTAssertEqual(view.openUsageButton.accessibilityLabel(), "打开官方用量页")
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            XCTAssertTrue(hasOpaquePixel(rep))
            view.openUsageButton.performClick(nil)
        }
        XCTAssertEqual(opened, 2)
    }

    private func hasOpaquePixel(_ rep: NSBitmapImageRep) -> Bool {
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                return true
            }
        }
        return false
    }
}
