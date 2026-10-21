import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class RefreshRateHelpTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private enum Sample { case waiting, live, staleMod, loginExpired }

    private func status(_ sample: Sample) -> ClaudeRefreshStatus {
        ClaudeRefreshStatus(
            scheduler: FetchSchedulerStatus(
                tokens: 1, tokenCapacity: 3, tokenRefillInterval: 180, nextTokenAt: base.addingTimeInterval(100), automaticTokenCost: 2,
                lastDispatchAt: base.addingTimeInterval(-60), automaticMinimumInterval: 180, lastSuccessAt: base.addingTimeInterval(-60),
                cooldownRemaining: 0, isUnauthorizedPaused: sample == .loginExpired, isBusy: false, at: base),
            realtimeAt: {
                switch sample {
                case .live: return base.addingTimeInterval(-30)
                case .staleMod: return base.addingTimeInterval(-600)
                default: return nil
                }
            }(),
            realtimeFreshnessWindow: 120)
    }

    private func content(_ sample: Sample?, language: AppLanguage = .english, onInstall: (() -> Void)? = nil) -> RefreshRateHelpContentView {
        RefreshRateHelpContentView(
            selectedInterval: 60, language: language, now: { self.base },
            status: sample.map { sample in { self.status(sample) } }, onInstall: onInstall)
    }

    func testTheExplanationAndTheModPitchAreWordedInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            let view = content(nil, language: language)
            let texts = allText(in: view)
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpTitle, language: language)), "\(language) title")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpLine1, language: language)), "\(language) explanation")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpModFooter, language: language)), "\(language) pitch")
            XCTAssertEqual(view.frame.width, RefreshRateHelpContentView.width)
            XCTAssertLessThan(view.frame.height, 600, "\(language) stays compact")
        }
    }

    func testTheStatusCardHasNoPlaceholdersLeftInAnyLanguage() {
        for language in AppLanguage.allCases where language != .system {
            for sample in [Sample.waiting, .live, .staleMod, .loginExpired] {
                let card = RefreshRateLiveStatusView(width: 308, language: language, now: { self.base }, provider: { self.status(sample) })
                let texts = allText(in: card).joined(separator: "\n")
                XCTAssertFalse(texts.contains("%1$@") || texts.contains("%2$@"), "\(language) \(sample): \(texts)")
            }
        }
    }

    func testWithoutModDataTheCardIsFollowedByTheExplanationAndThePitch() {
        let view = content(.waiting)
        XCTAssertTrue(view.isMetaVisible)
        XCTAssertTrue(view.isExplanationVisible)
        XCTAssertFalse(view.isModTimelineVisible, "no Mod line before the Mod delivers")
        XCTAssertTrue(view.isFooterVisible, "the install pitch is shown")
        XCTAssertFalse(allText(in: view).contains("Right now"), "no extra heading above the card")
    }

    func testWithFreshModDataThePitchGivesWayToTheModLine() {
        let view = content(.live)
        XCTAssertTrue(view.isModTimelineVisible)
        XCTAssertFalse(view.isFooterVisible, "already installed")
        XCTAssertTrue(view.isExplanationVisible)
    }

    func testAnInstalledModWhoseDataWentStaleGetsNoInstallPitchEither() {
        let view = content(.staleMod)
        XCTAssertFalse(view.isFooterVisible)
        XCTAssertFalse(view.isModTimelineVisible)
    }

    func testAProblemShowsOnlyThePointAndFoldsTheExplanationAway() {
        let view = content(.loginExpired)
        XCTAssertFalse(view.isMetaVisible, "only the one line that matters, no last-read or reads row")
        XCTAssertFalse(view.isExplanationVisible, "folded")
        XCTAssertFalse(view.isFooterVisible)
        let folded = view.frame.height
        view.toggleExplanationForTesting()
        XCTAssertTrue(view.isExplanationVisible)
        XCTAssertGreaterThan(view.frame.height, folded, "the popover grows when unfolded")
        view.toggleExplanationForTesting()
        XCTAssertFalse(view.isExplanationVisible)
    }

    func testTheInstallButtonRunsItsAction() {
        var installs = 0
        let view = content(.waiting, onInstall: { installs += 1 })
        view.tapInstallForTesting()
        XCTAssertEqual(installs, 1)
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

    /// Renders the popover in a few languages and states for a visual self-check (set BB_HELP_RENDER_DIR).
    func testRenderTheHelpWhenAskedTo() throws {
        guard let directory = ProcessInfo.processInfo.environment["BB_HELP_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for language in [AppLanguage.simplifiedChinese, .english, .russian] {
            for (sampleName, sample) in [("waiting", Sample.waiting), ("live", .live), ("login", .loginExpired)] {
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let view = content(sample, language: language)
                    view.appearance = NSAppearance(named: appearance)
                    view.wantsLayer = true
                    view.effectiveAppearance.performAsCurrentDrawingAppearance {
                        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    }
                    view.layoutSubtreeIfNeeded()
                    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("help-\(language.rawValue)-\(sampleName)-\(name).png"))
                }
            }
        }
    }

    private func allText(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? (view as? NSButton).map { [$0.title] } ?? []
        return own + view.subviews.flatMap(allText)
    }
}
