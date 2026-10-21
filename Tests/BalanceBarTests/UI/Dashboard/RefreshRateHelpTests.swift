import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class RefreshRateHelpTests: XCTestCase {
    func testTheHelpExplainsTheFloorInPlainWordsInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            let content = RefreshRateHelpContentView(selectedInterval: 60, language: language)
            let texts = allText(in: content)
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpTitle, language: language)), "\(language) title")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpLine1, language: language)), "\(language) explanation")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpLine3, language: language)), "\(language) Mod hint")
            XCTAssertEqual(content.frame.width, RefreshRateHelpContentView.width)
            XCTAssertGreaterThan(content.frame.height, 150, "\(language) content is laid out")
            XCTAssertLessThan(content.frame.height, 600, "\(language) content stays compact")
        }
    }

    func testTheButtonOpensAndClosesThePopover() throws {
        let button = RefreshRateHelpButton(selectedInterval: { 90 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        window.contentView?.addSubview(button)
        button.frame.origin = NSPoint(x: 20, y: 60)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertEqual(button.toolTip, tr(.keyRefreshHelpTitle))
        button.performClick(nil)
        let popoverShown = try XCTUnwrap(Mirror(reflecting: button).children.first { $0.label == "popover" }?.value as? NSPopover?)
        XCTAssertTrue(popoverShown?.isShown == true)
        button.performClick(nil)
    }

    /// Renders the explanation in a few languages for a visual self-check (set BB_HELP_RENDER_DIR).
    func testRenderTheHelpWhenAskedTo() throws {
        guard let directory = ProcessInfo.processInfo.environment["BB_HELP_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for language in [AppLanguage.simplifiedChinese, .english, .russian] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let content = RefreshRateHelpContentView(selectedInterval: 60, language: language, now: { self.base }, status: { self.sampleStatus(live: language == .english) })
                content.appearance = NSAppearance(named: appearance)
                content.wantsLayer = true
                content.effectiveAppearance.performAsCurrentDrawingAppearance {
                    content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                content.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("help-\(language.rawValue)-\(name).png"))
            }
        }
    }

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func sampleStatus(live: Bool = false) -> ClaudeRefreshStatus {
        ClaudeRefreshStatus(
            scheduler: FetchSchedulerStatus(
                tokens: 1, tokenCapacity: 3, tokenRefillInterval: 180, nextTokenAt: base.addingTimeInterval(100), automaticTokenCost: 2,
                lastDispatchAt: base.addingTimeInterval(-60), automaticMinimumInterval: 180, lastSuccessAt: base.addingTimeInterval(-60),
                cooldownRemaining: 0, isUnauthorizedPaused: false, isBusy: false, at: base),
            realtimeAt: live ? base.addingTimeInterval(-30) : nil, realtimeFreshnessWindow: 120)
    }

    func testTheLiveSectionNamesWhatIsHoldingTheNextReadBackInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            let waiting = RefreshRateLiveStatusView(width: 308, language: language, now: { self.base }, provider: { self.sampleStatus() })
            let texts = allText(in: waiting).joined(separator: "\n")
            XCTAssertFalse(texts.contains("%1$@") || texts.contains("%2$@"), "\(language) left a placeholder unfilled: \(texts)")
            XCTAssertTrue(texts.contains(tr(.keyRefreshStatusLastRead, language: language)), "\(language) last read")
            XCTAssertTrue(texts.contains(tr(.keyRefreshStatusModNone, language: language)), "\(language) no Mod data")
            let live = RefreshRateLiveStatusView(width: 308, language: language, now: { self.base }, provider: { self.sampleStatus(live: true) })
            XCTAssertFalse(allText(in: live).joined().contains("%1$@"), "\(language) live sentence")
        }
    }

    func testTheContentShowsTheLiveSectionOnlyWhenAStatusSourceIsGiven() {
        let without = RefreshRateHelpContentView(selectedInterval: 60, language: .english)
        XCTAssertFalse(allText(in: without).contains(tr(.keyRefreshStatusNowTitle, language: .english)))
        let with = RefreshRateHelpContentView(selectedInterval: 60, language: .english, status: { self.sampleStatus() })
        XCTAssertTrue(allText(in: with).contains(tr(.keyRefreshStatusNowTitle, language: .english)))
    }

    private func allText(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(allText)
    }
}
