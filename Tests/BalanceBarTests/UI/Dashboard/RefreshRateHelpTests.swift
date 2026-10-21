import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class RefreshRateHelpTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private enum Sample { case waiting, reading, failed, live, staleMod, loginExpired }

    private func status(_ sample: Sample) -> ClaudeRefreshStatus {
        ClaudeRefreshStatus(
            scheduler: FetchSchedulerStatus(
                tokens: 1, tokenCapacity: 3, tokenRefillInterval: 180, nextTokenAt: base.addingTimeInterval(100), automaticTokenCost: 2,
                lastDispatchAt: base.addingTimeInterval(-60), automaticMinimumInterval: 180, lastSuccessAt: base.addingTimeInterval(-60),
                lastFailureAt: sample == .failed ? base.addingTimeInterval(-20) : nil,
                cooldownRemaining: 0, isUnauthorizedPaused: sample == .loginExpired, isBusy: sample == .reading, at: base),
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

    /// A popover whose state can be changed between ticks.
    private func content(following sample: @escaping () -> Sample) -> RefreshRateHelpContentView {
        RefreshRateHelpContentView(selectedInterval: 60, language: .english, now: { self.base }, status: { self.status(sample()) })
    }

    func testTheExplanationAndTheModPitchAreWordedInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            let view = content(nil, language: language)
            let texts = allText(in: view)
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpTitle, language: language)), "\(language) title")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpLine1, language: language)), "\(language) explanation")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpModFooter, language: language)), "\(language) pitch")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpOtherTools, language: language)), "\(language) other tools share the endpoint")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpRowActual, language: language)), "\(language) BalanceBar's own pace")
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
        XCTAssertTrue(view.isModAgeVisible, "how old the Mod's data is, since the sentence no longer says it")
    }

    func testEveryTimelineHeadingFitsOnOneLineInEveryLanguage() {
        let contentWidth = RefreshRateHelpContentView.width - 32
        func width(_ text: String, _ weight: NSFont.Weight) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: weight)]).width
        }
        for language in AppLanguage.allCases where language != .system {
            let rows: [(LocalizationKey, String)] = [
                (.keyRefreshHelpRowSetting, tr(.keyDashboardOfficialEverySeconds, arguments: ["600"], language: language)),
                (.keyRefreshHelpRowActual, tr(.keyRefreshHelpRowActualHint, language: language)),
                (.keyRefreshHelpRowModNow, tr(.keyRefreshHelpRowModHint, language: language)),
            ]
            for (label, hint) in rows {
                let needed = width(tr(label, language: language), .medium) + width(hint, .regular) + 8
                XCTAssertLessThanOrEqual(needed, contentWidth, "\(language) \(label.rawValue) is cut off")
            }
        }
    }

        /// The dots are points, not reads: every sentence about them says what an automatic read costs, and that cost
    /// is the scheduler's.
    func testThePointSentencesStateTheRealCostInEveryLanguage() {
        let automatic = String(QuotaConstants.automaticRequestTokenCost)
        let manual = String(QuotaConstants.manualRequestTokenCost)
        let capacity = String(QuotaConstants.requestTokenBucketCapacity)
        for language in AppLanguage.allCases where language != .system {
            XCTAssertTrue(tr(.keyRefreshStatusPhaseTokens, arguments: ["1 min"], language: language).contains(automatic), "\(language) tokens")
            XCTAssertTrue(tr(.keyRefreshStatusPhaseReady, language: language).contains(automatic), "\(language) ready")
            let hint = tr(.keyRefreshStatusTokensHint, language: language)
            for number in [automatic, manual, capacity] {
                XCTAssertTrue(hint.contains(number), "\(language) hint lacks \(number)")
            }
        }
    }

    func testTheReadsRowExplainsItsRulesOnHover() {
        let card = RefreshRateLiveStatusView(width: 308, language: .english, now: { self.base }, provider: { self.status(.waiting) })
        func tips(_ view: NSView) -> [String] { [view.toolTip].compactMap { $0 } + view.subviews.flatMap(tips) }
        XCTAssertTrue(tips(card).contains(tr(.keyRefreshStatusTokensHint, language: .english)))
    }

    func testTheOverviewSaysCodexFollowsTheSettingAndTheRestIsAboutClaudeInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            let texts = allText(in: content(.waiting, language: language))
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpOverviewCodex, language: language)), "\(language) Codex")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpOverviewClaude, language: language)), "\(language) Claude")
            XCTAssertTrue(texts.contains("Codex") && texts.contains("Claude"), "\(language) names and the Claude section")
        }
    }

    func testAFailedReadIsShownUntilTheNextSuccessButNotOverAProblem() {
        let failed = content(.failed)
        XCTAssertTrue(failed.isLastFailureVisible)
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.english.formattingLocale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let expected = tr(.keyRefreshStatusLastFailed, arguments: [formatter.string(from: base.addingTimeInterval(-20))], language: .english)
        XCTAssertTrue(allText(in: failed).contains(expected), "names when the failed read was")
        XCTAssertFalse(content(.waiting).isLastFailureVisible)
        XCTAssertFalse(content(.loginExpired).isLastFailureVisible)
        for language in AppLanguage.allCases where language != .system {
            let card = RefreshRateLiveStatusView(width: 308, language: language, now: { self.base }, provider: { self.status(.failed) })
            XCTAssertFalse(allText(in: card).joined().contains("%1$@"), "\(language) failure line")
        }
    }

    func testFreshModDataIsNotRepeatedBelowTheSentence() {
        let view = content(.live)
        XCTAssertFalse(view.isModAgeVisible, "the sentence already says how old it is")
    }

    func testOnlyAnExpiredSignInOffersToCopyTheCommand() {
        XCTAssertTrue(content(.loginExpired).isCopyCommandVisible)
        for sample in [Sample.waiting, .reading, .live, .staleMod] {
            XCTAssertFalse(content(sample).isCopyCommandVisible, "\(sample)")
        }
        XCTAssertEqual(RefreshRateLiveStatusView.loginCommand, "claude")
    }

    func testThePopoverFollowsTheStateAsItChanges() {
        var sample = Sample.loginExpired
        let view = content(following: { sample })
        var sizes: [NSSize] = []
        view.onSizeChange = { sizes.append($0) }
        view.toggleExplanationForTesting()
        XCTAssertTrue(view.isExplanationVisible)

        sample = .waiting
        view.refreshStatusForTesting()
        XCTAssertTrue(view.isExplanationVisible)
        XCTAssertTrue(view.isMetaVisible)
        XCTAssertFalse(view.isCopyCommandVisible)
        let waiting = view.frame.height

        sample = .reading
        view.refreshStatusForTesting()
        XCTAssertLessThan(view.frame.height, waiting, "no bar while reading, and the popover shrinks with it")
        XCTAssertEqual(sizes.last, view.frame.size)

        sample = .loginExpired
        view.refreshStatusForTesting()
        XCTAssertFalse(view.isExplanationVisible, "folded again the next time something goes wrong")
        let count = sizes.count
        view.refreshStatusForTesting()
        XCTAssertEqual(sizes.count, count, "an unchanged tick does not resize the popover")
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
        XCTAssertEqual(button.toolTip, tr(.keyRefreshHelpTooltip))
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
            for (sampleName, sample) in [("waiting", Sample.waiting), ("failed", .failed), ("live", .live), ("stale", .staleMod), ("login", .loginExpired)] {
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
