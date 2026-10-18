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
            ("estimated", .estimated(at: time)),
            ("realtime", .realtime),
            ("official", .official(at: time)),
        ]
    }

    // MARK: Priority

    func testResolvePriorityOrder() {
        let ctx = StatusSlotContext(isRefreshing: true, source: .realtime, updatedAt: time)
        XCTAssertEqual(StatusSlotState.resolve(model: model(state: .error, estimated: true), context: ctx), .refreshing)

        var c = ctx; c.isRefreshing = false
        XCTAssertEqual(StatusSlotState.resolve(model: model(state: .error, estimated: true), context: c), .error(at: time))
        XCTAssertEqual(StatusSlotState.resolve(model: model(state: .expired), context: c), .error(at: time))
        XCTAssertEqual(StatusSlotState.resolve(model: model(estimated: true), context: c), .estimated(at: time))
        XCTAssertEqual(StatusSlotState.resolve(model: model(), context: c), .realtime)
        c.source = .official
        XCTAssertEqual(StatusSlotState.resolve(model: model(), context: c), .official(at: time))
    }

    // MARK: Snapshots (light + dark)

    /// Textual snapshot of every state in both appearances, plus a rendered bitmap
    /// check that the slot draws visible pixels at its fixed size.
    func testSnapshotsAllStatesLightAndDark() throws {
        let expected: [String: String] = [
            "refreshing": "刷新中…|secondary|dot=false",
            "error": "⚠︎ 13:40|orange|dot=false",
            "estimated": "≈ 13:40|secondary|dot=false",
            "realtime": "实时|secondary|dot=true",
            "official": "13:40|secondary|dot=false",
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for (name, state) in allStates {
                let view = StatusSlotView(timeZone: utc)
                view.appearance = appearance
                view.update(state: state)
                view.layoutSubtreeIfNeeded()
                let color = view.textColorForTesting == .systemOrange ? "orange" : "secondary"
                XCTAssertEqual(
                    "\(view.textForTesting)|\(color)|dot=\(view.isDotVisibleForTesting)",
                    expected[name],
                    "\(appearanceName.rawValue) \(name)"
                )

                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                XCTAssertEqual(rep.size, NSSize(width: StatusSlotView.fixedWidth, height: StatusSlotView.fixedHeight))
                XCTAssertTrue(hasOpaquePixel(rep), "\(appearanceName.rawValue) \(name) rendered blank")
            }
        }
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

    // MARK: Hover + VoiceOver

    func testHoverTextsIncludingExternalActivity() {
        let view = StatusSlotView(timeZone: utc)
        view.update(state: .official(at: time))
        XCTAssertEqual(view.toolTip, "官方数据，更新于 13:40")
        view.update(state: .estimated(at: time), externalActivityDetected: true)
        XCTAssertEqual(view.toolTip, "根据 13:40 的数据估算，等待官方确认\n检测到其他端在使用，已提高更新频率")
        view.update(state: .error(at: time))
        XCTAssertEqual(view.toolTip, "更新失败，显示的是 13:40 的数据")
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
