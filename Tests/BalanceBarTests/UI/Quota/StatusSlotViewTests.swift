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
        XCTAssertEqual(StatusSlotState.resolve(model: model(state: .resetPendingConfirmation, estimated: true), context: c), .resetPending(at: time))
        XCTAssertEqual(StatusSlotState.resolve(model: model(estimated: true), context: c), .estimated(at: time))
        XCTAssertEqual(StatusSlotState.resolve(model: model(), context: c), .realtime)
        c.source = .official
        XCTAssertEqual(StatusSlotState.resolve(model: model(), context: c), .official(at: time))
    }

    // MARK: Snapshots (light + dark)

    private static let snapshotDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__", isDirectory: true)

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

    /// Compares the real rendering of every state in light and dark mode against
    /// checked-in reference PNGs. Set BB_RECORD_SNAPSHOTS=1 to (re)record.
    func testRenderedSnapshotsMatchReferenceImages() throws {
        let record = ProcessInfo.processInfo.environment["BB_RECORD_SNAPSHOTS"] == "1"
        var missing: [String] = []
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearanceName == .aqua ? "light" : "dark"
            for (name, state) in allStates {
                let (_, rep) = try render(state, appearanceName)
                let url = Self.snapshotDirectory.appendingPathComponent("\(name)-\(suffix).png")
                if record || !FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.createDirectory(at: Self.snapshotDirectory, withIntermediateDirectories: true)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
                    missing.append(url.lastPathComponent)
                    continue
                }
                let reference = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
                XCTAssertEqual(reference.pixelsWide, rep.pixelsWide, url.lastPathComponent)
                XCTAssertEqual(reference.pixelsHigh, rep.pixelsHigh, url.lastPathComponent)
                guard reference.pixelsWide == rep.pixelsWide, reference.pixelsHigh == rep.pixelsHigh else { continue }
                // Compare ink structure (bounding box ±2px, coverage ±35%), not exact pixels:
                // glyph antialiasing differs between macOS runners. Colors and the green dot
                // are checked strictly in testRenderedColorsClippingAndAppearance.
                let actual = InkStructure(rep), expected = InkStructure(reference)
                XCTAssertTrue(actual.matches(expected), "\(url.lastPathComponent) ink structure \(actual) differs from reference \(expected)")
            }
        }
        if !missing.isEmpty {
            XCTFail("Recorded snapshots (re-run to verify): \(missing)")
        }
    }

    /// Rendering-level checks that do not depend on font rasterisation details.
    func testRenderedColorsClippingAndAppearance() throws {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        for (name, state) in allStates {
            let (lightView, light) = try render(state, .aqua)
            let (_, dark) = try render(state, .darkAqua)
            // The error state uses fixed systemOrange, which may resolve identically in both appearances.
            if case .error = state {} else {
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

    /// Ink bounding box and coverage of a rendering (ink = alpha > 0.5).
    private struct InkStructure: CustomStringConvertible {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, ink = 0

        init(_ rep: NSBitmapImageRep) {
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    ink += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }

        func matches(_ other: InkStructure) -> Bool {
            abs(minX - other.minX) <= 2 && abs(maxX - other.maxX) <= 2
                && abs(minY - other.minY) <= 2 && abs(maxY - other.maxY) <= 2
                && Double(abs(ink - other.ink)) <= 0.35 * Double(max(ink, other.ink, 1))
        }

        var description: String { "x \(minX)...\(maxX) y \(minY)...\(maxY) ink \(ink)" }
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
        for source in [StatusSlotSource.official, .realtime] {
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
