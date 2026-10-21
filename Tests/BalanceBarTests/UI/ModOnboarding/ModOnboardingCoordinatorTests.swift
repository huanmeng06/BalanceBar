import AppKit
import XCTest
@testable import BalanceBar

private final class MemoryPromptPreference: ModPromptPreferenceStoring { var isPromptDismissed = false }

private final class MemoryTimestamp: ModDataTimestampStoring { var lastModDataAt: Date? }

private final class MemoryHeadless: ModHeadlessStoring { var accumulation = ModHeadlessAccumulation() }

private final class MutableClock {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

/// Scriptable stand-in for `claude --version`, the plugin registry and the HUD source.
private final class FakeEnvironment {
    private let lock = NSLock()
    private var state = (
        version: ClaudeCodeVersionStatus.detected(ClaudeCodeVersion(major: 2, minor: 1, patch: 291)),
        record: ModInstallRecord?.none, hud: false, headless: TimeInterval(0), reads: 0)

    var version: ClaudeCodeVersionStatus {
        get { lock.withLock { state.version } } set { lock.withLock { state.version = newValue } }
    }
    var record: ModInstallRecord? {
        get { lock.withLock { state.record } } set { lock.withLock { state.record = newValue } }
    }
    var hud: Bool {
        get { lock.withLock { state.hud } } set { lock.withLock { state.hud = newValue } }
    }
    var headless: TimeInterval {
        get { lock.withLock { state.headless } } set { lock.withLock { state.headless = newValue } }
    }
    var reads: Int { lock.withLock { state.reads } }

    var environment: ModOnboardingCoordinator.Environment {
        .init(
            detectClaudeCode: { self.lock.withLock { self.state.reads += 1; return self.state.version } },
            readInstallRecord: { self.lock.withLock { self.state.record } },
            hasHUDSnapshot: { self.hud },
            headlessDuration: { self.headless })
    }
}

final class ModOnboardingCoordinatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var clock: MutableClock!
    private var fake: FakeEnvironment!
    private var preference: MemoryPromptPreference!
    private var timestamps: MemoryTimestamp!
    private var headlessStore: MemoryHeadless!

    override func setUp() {
        super.setUp()
        clock = MutableClock(start)
        fake = FakeEnvironment()
        preference = MemoryPromptPreference()
        timestamps = MemoryTimestamp()
        headlessStore = MemoryHeadless()
    }

    private func makeCoordinator(installer: ModInstaller? = nil) -> ModOnboardingCoordinator {
        ModOnboardingCoordinator(
            plan: .standard, environment: fake.environment, promptPreference: preference, timestamps: timestamps, headlessStore: headlessStore,
            installer: installer, copyToPasteboard: { _ in }, now: { [clock] in clock!.now })
    }

    /// Runs a background environment refresh to completion.
    private func refresh(_ coordinator: ModOnboardingCoordinator, force: Bool = true) {
        let done = expectation(description: "environment refreshed")
        coordinator.refreshEnvironment(force: force) { done.fulfill() }
        wait(for: [done], timeout: 2)
        // The change notification hops to the main queue after the completion; drain it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    private func observation(source: String, observedAt: Date?, receivedAt: Date? = nil) -> QuotaObservation {
        QuotaObservation(window: .fiveHour, usedPercentage: 10, observedAt: observedAt,
                         receivedAt: receivedAt ?? clock.now, source: source, trust: .b,
                         accountID: "a", epoch: .initial)!
    }

    // MARK: Menu row

    func testMenuRowFollowsThePromptRules() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .none,
                       "an undetected Claude Code version keeps the prompt hidden")
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: false), .none)

        refresh(coordinator)
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .prompt(headless: false))

        fake.record = ModInstallRecord(installedAt: start)
        refresh(coordinator)
        coordinator.recordObservation(observation(source: ModOnboardingConfig.modSourceID, observedAt: clock.now))
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .none, "Mod data within seven days hides the prompt")
        fake.record = nil
        refresh(coordinator)
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .prompt(headless: false),
                       "uninstalled: leftover data from a session that still has the Mod loaded no longer hides it")
        fake.record = ModInstallRecord(installedAt: start)
        refresh(coordinator)
        clock.advance(by: 8 * 86_400)
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .prompt(headless: false), "…and an old one no longer does")
    }

    func testAnUnreadableClaudeVersionIsRetriedAfterAMinuteInsteadOfADay() {
        fake.version = .unknown
        let coordinator = makeCoordinator()
        refresh(coordinator)
        XCTAssertEqual(fake.reads, 1)
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .none)

        fake.version = .detected(ClaudeCodeVersion(major: 2, minor: 1, patch: 291))
        refresh(coordinator, force: false)
        XCTAssertEqual(fake.reads, 1, "too early to look again")
        clock.advance(by: ModOnboardingConfig.unknownVersionRetryInterval + 1)
        refresh(coordinator, force: false)
        XCTAssertEqual(fake.reads, 2)
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .prompt(headless: false), "installing Claude Code shows the prompt")

        clock.advance(by: 3_600)
        refresh(coordinator, force: false)
        XCTAssertEqual(fake.reads, 2, "a readable version is only re-read daily")
    }

    func testDismissingThePromptRemovesTheMenuRow() {
        let coordinator = makeCoordinator()
        refresh(coordinator)
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .prompt(headless: false))
        let changed = expectation(description: "menu input refresh requested")
        coordinator.onChange = { changed.fulfill() }
        coordinator.controller.setDismissChecked(true)
        XCTAssertFalse(coordinator.controller.close(), "closing with the checkbox ticked shows the confirmed state")
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(coordinator.controller.state, .dismissConfirmed)
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .none)

        coordinator.controller.setPromptEnabled(true)
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .prompt(headless: false))
    }

    func testHUDSnapshotNeedsTheHeadlessSignalBeforeThePromptShows() {
        let coordinator = makeCoordinator()
        refresh(coordinator)
        fake.hud = true
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .none)
        fake.headless = ModOnboardingConfig.headlessDurationThreshold
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .none, "exactly 30 minutes is not more than 30 minutes")
        fake.headless = ModOnboardingConfig.headlessDurationThreshold + 60
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .prompt(headless: true),
                       "a HUD user with enough headless time gets the headless wording")
    }

    func testHeadlessTimeAccumulatesPerDayAndSurvivesARestart() {
        let coordinator = makeCoordinator()
        refresh(coordinator)
        fake.hud = true
        fake.headless = 20 * 60
        XCTAssertEqual(coordinator.menuRow(isOfficialDirect: true), .none)
        XCTAssertEqual(headlessStore.accumulation.seconds, 20 * 60)

        // A restart: the HUD source counts from zero again, but the day's total is kept.
        let restarted = makeCoordinator()
        refresh(restarted)
        fake.headless = 11 * 60
        XCTAssertEqual(restarted.menuRow(isOfficialDirect: true), .prompt(headless: true), "20 + 11 minutes within one day")

        // Once the day is over the sum starts again.
        clock.advance(by: ModOnboardingConfig.headlessAccumulationWindow + 60)
        fake.headless = 12 * 60
        XCTAssertEqual(restarted.menuRow(isOfficialDirect: true), .none)
        XCTAssertEqual(headlessStore.accumulation.seconds, 60)
    }

    func testClaudeCodeVersionIsReadOncePerDayAndAfterAnInstall() {
        let coordinator = makeCoordinator()
        refresh(coordinator)
        let reads = fake.reads
        clock.advance(by: 23 * 3_600)
        coordinator.refreshEnvironment()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(fake.reads, reads, "not before a day has passed")
        clock.advance(by: 2 * 3_600)
        refresh(coordinator, force: false)
        XCTAssertEqual(fake.reads, reads + 1)
    }

    // MARK: Status and the silence clock

    func testTheWindowOffersStatusAndRemovalOnceTheModIsInstalled() {
        let coordinator = makeCoordinator()
        refresh(coordinator)
        _ = coordinator.makePanelView()
        XCTAssertEqual(coordinator.controller.state, .intro(dismissChecked: false), "not installed: the install pitch")

        fake.record = ModInstallRecord(installedAt: start)
        refresh(coordinator)
        _ = coordinator.makePanelView()
        guard case let .installed(text) = coordinator.controller.state else { return XCTFail("expected the management view") }
        XCTAssertEqual(text, RealtimeBoostPresentation.make(status: .waitingForData, localize: RealtimeBoostText.appLocalize).stateAndDetail)

        let seen = start.addingTimeInterval(30)
        clock.advance(by: 30)
        coordinator.recordObservation(observation(source: ModOnboardingConfig.modSourceID, observedAt: seen))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard case let .installed(updated) = coordinator.controller.state else { return XCTFail("expected the management view") }
        XCTAssertNotEqual(updated, text, "an open management window follows the live status")

        fake.record = nil
        refresh(coordinator)
        _ = coordinator.makePanelView()
        XCTAssertEqual(coordinator.controller.state, .intro(dismissChecked: false), "uninstalled elsewhere: back to the pitch")
    }

    func testStatusFollowsInstallRegistryVersionAndData() {
        let coordinator = makeCoordinator()
        refresh(coordinator)
        XCTAssertEqual(coordinator.enhancementStatus(), .notInstalled)

        fake.record = ModInstallRecord(installedAt: start)
        refresh(coordinator)
        XCTAssertEqual(coordinator.enhancementStatus(), .waitingForData)

        let seen = start.addingTimeInterval(30)
        clock.advance(by: 30)
        coordinator.recordObservation(observation(source: ModOnboardingConfig.modSourceID, observedAt: seen))
        XCTAssertEqual(coordinator.enhancementStatus(), .active(lastDataAt: seen))

        fake.version = .detected(ClaudeCodeVersion(major: 2, minor: 1, patch: 200))
        refresh(coordinator)
        XCTAssertEqual(coordinator.enhancementStatus(), .unsupportedClaudeCode(ClaudeCodeVersion(major: 2, minor: 1, patch: 200)))
    }

    func testSilenceClockStartsAtTheLaterOfInstallTimeAndTheStartOfCurrentActivity() {
        fake.record = ModInstallRecord(installedAt: start)
        let coordinator = makeCoordinator()
        refresh(coordinator)

        // Claude Code has been idle for a long time; the install was just now.
        clock.advance(by: 3_600)
        XCTAssertEqual(coordinator.enhancementStatus(), .waitingForData, "no activity yet: nothing to be silent about")

        // Work starts; an hour-old install must not make the Mod "silent" immediately.
        coordinator.setClaudeActivity(running: true)
        XCTAssertEqual(coordinator.enhancementStatus(), .waitingForData)
        clock.advance(by: ModOnboardingConfig.noDataWithActivityGrace - 1)
        XCTAssertEqual(coordinator.enhancementStatus(), .waitingForData)
        clock.advance(by: 1)
        XCTAssertEqual(coordinator.enhancementStatus(), .enabledButSilent)

        // Activity that ended and began again restarts the clock.
        coordinator.setClaudeActivity(running: false)
        clock.advance(by: 60)
        coordinator.setClaudeActivity(running: true)
        XCTAssertEqual(coordinator.enhancementStatus(), .waitingForData)
    }

    func testReinstallingStartsTheSilenceClockAtTheNewInstallTime() {
        fake.record = ModInstallRecord(installedAt: start)
        let coordinator = makeCoordinator()
        coordinator.setClaudeActivity(running: true)
        refresh(coordinator)
        clock.advance(by: 3_600)
        XCTAssertEqual(coordinator.enhancementStatus(), .enabledButSilent)

        fake.record = ModInstallRecord(installedAt: clock.now)
        refresh(coordinator)
        XCTAssertEqual(coordinator.enhancementStatus(), .waitingForData)
    }

    // MARK: Mod data

    func testOnlyModObservationsCountAndTheTimestampIsPersistedAndCappedAtNow() {
        let coordinator = makeCoordinator()
        coordinator.recordObservation(observation(source: "claude-hud", observedAt: clock.now))
        XCTAssertNil(timestamps.lastModDataAt, "HUD data is not Mod data")

        coordinator.recordObservation(observation(source: ModOnboardingConfig.modSourceID, observedAt: clock.now.addingTimeInterval(3_600)))
        XCTAssertEqual(timestamps.lastModDataAt, clock.now, "a clock-skewed snapshot cannot lie in the future")

        let older = clock.now.addingTimeInterval(-500)
        coordinator.recordObservation(observation(source: ModOnboardingConfig.modSourceID, observedAt: older))
        XCTAssertEqual(timestamps.lastModDataAt, clock.now, "an older snapshot never moves the timestamp back")

        // The persisted value survives a restart.
        fake.record = ModInstallRecord(installedAt: start)
        let restarted = makeCoordinator()
        refresh(restarted)
        XCTAssertEqual(restarted.menuRow(isOfficialDirect: true), .none)
    }

    // MARK: Install

    func testASuccessfulInstallRefreshesTheRegistryAndStartsTheSilenceClock() {
        final class Locator: ClaudeExecutableLocating { func locate() -> String? { "/usr/local/bin/claude" } }
        final class Runner: ModCommandRunning {
            func run(executablePath: String, arguments: [String]) -> ModCommandResult? {
                ModCommandResult(exitCode: 0, stdout: "{\"outcome\":\"ok\"}", stderr: "")
            }
        }
        let installer = ModInstaller(plan: .standard, locator: Locator(), runner: Runner(),
                                     workQueue: DispatchQueue(label: "test.mod-install"), callbackQueue: .main)
        let coordinator = makeCoordinator(installer: installer)
        refresh(coordinator)
        XCTAssertEqual(coordinator.enhancementStatus(), .notInstalled)

        fake.record = ModInstallRecord(installedAt: clock.now)
        let reads = fake.reads
        let finished = expectation(description: "install finished")
        coordinator.controller.onStateChange = {
            if coordinator.controller.state == .awaitingFirstData { finished.fulfill() }
        }
        coordinator.controller.startInstall()
        wait(for: [finished], timeout: 2)
        let deadline = Date().addingTimeInterval(2)
        while coordinator.enhancementStatus() == .notInstalled, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(fake.reads, reads, "the install triggers a fresh environment read")
        XCTAssertEqual(coordinator.enhancementStatus(), .waitingForData)

        // The Mod's first snapshot completes the install.
        coordinator.recordObservation(observation(source: ModOnboardingConfig.modSourceID, observedAt: clock.now))
        let enabled = Date().addingTimeInterval(2)
        while coordinator.controller.state != .enabled, Date() < enabled {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(coordinator.controller.state, .enabled)
    }

    func testWindowWaitingForDataTurnsSilentOnlyAfterTenMinutesOfActivity() {
        fake.record = ModInstallRecord(installedAt: start)
        let coordinator = makeCoordinator()
        refresh(coordinator)
        coordinator.setClaudeActivity(running: true)
        XCTAssertEqual(coordinator.controller.silenceCheck?(), false)
        clock.advance(by: ModOnboardingConfig.noDataWithActivityGrace)
        XCTAssertEqual(coordinator.controller.silenceCheck?(), true)
        XCTAssertEqual(coordinator.enhancementStatus(), .enabledButSilent)
    }

    // MARK: Registry and plan

    func testPluginRegistryParsing() {
        let json = """
        {"version": 2, "plugins": {
          "balancebar-mod@balancebar-mods": [{"scope": "user", "installedAt": "2026-10-20T10:00:00.000Z"}],
          "other@market": [{"scope": "user"}],
          "empty@market": []
        }}
        """
        let installed = ClaudePluginRegistry.record(from: Data(json.utf8), pluginID: "balancebar-mod@balancebar-mods")
        XCTAssertEqual(installed?.installedAt, ISO8601DateFormatter().date(from: "2026-10-20T10:00:00Z"))
        XCTAssertEqual(ClaudePluginRegistry.record(from: Data(json.utf8), pluginID: "other@market"), ModInstallRecord(installedAt: nil))
        XCTAssertNil(ClaudePluginRegistry.record(from: Data(json.utf8), pluginID: "empty@market"))
        XCTAssertNil(ClaudePluginRegistry.record(from: Data(json.utf8), pluginID: "missing@market"))
        XCTAssertNil(ClaudePluginRegistry.record(from: Data("not json".utf8), pluginID: "balancebar-mod@balancebar-mods"))
    }

    func testStandardPlanNamesThePublishedModAndOnlyDevelopmentBuildsAcceptAnOverride() throws {
        XCTAssertEqual(ModInstallPlan.standard.pluginID, "balancebar-mod@balancebar-mods")
        XCTAssertEqual(ModInstallPlan.standard.marketplaceArguments,
                       ["plugin", "marketplace", "add", "huanmeng06/BalanceBar", "--scope", "user", "--json"])
        let suite = "ModPlan.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/tmp/checkout/mod", forKey: ModInstallPlan.developmentSourceKey)
        defaults.set("local", forKey: ModInstallPlan.developmentScopeKey)

        XCTAssertEqual(ModInstallPlan.resolved(defaults: defaults, bundleIdentifier: "com.huanmeng06.BalanceBar"), .standard,
                       "a production build ignores the override")
        let dev = ModInstallPlan.resolved(defaults: defaults, bundleIdentifier: "com.huanmeng06.BalanceBar.dev")
        XCTAssertEqual(dev.marketplaceSource, "/tmp/checkout/mod")
        XCTAssertEqual(dev.scope, "local")
        XCTAssertEqual(dev.pluginID, ModInstallPlan.standard.pluginID)

        defaults.set("elsewhere", forKey: ModInstallPlan.developmentScopeKey)
        XCTAssertEqual(ModInstallPlan.resolved(defaults: defaults, bundleIdentifier: "com.huanmeng06.BalanceBar.dev").scope, "user",
                       "an unknown scope falls back to the standard one")
    }

    // MARK: Localization

    func testEveryOnboardingTextHasAResourceKeyAndTheSimplifiedChineseCopyMatchesItsDefault() {
        func normalized(_ text: String) -> String { text.replacingOccurrences(of: "%1$@", with: "%@") }
        for text in ModOnboardingText.allCases {
            let key = LocalizationKey(rawValue: text.rawValue)
            XCTAssertNotNil(key, "\(text.rawValue) has no LocalizationKey")
            if let key { XCTAssertEqual(tr(key, language: .simplifiedChinese), text.defaultText, text.rawValue) }
            // (no placeholders in the onboarding copy, so no arguments are passed)
        }
        for text in RealtimeBoostText.allCases {
            let key = LocalizationKey(rawValue: text.rawValue)
            XCTAssertNotNil(key, "\(text.rawValue) has no LocalizationKey")
            if let key {
                let takesArgument = text == .statusTitleFormat || text == .lastData || text == .unsupportedDetail
                XCTAssertEqual(normalized(tr(key, arguments: takesArgument ? ["%1$@"] : [], language: .simplifiedChinese)),
                               normalized(text.defaultText), text.rawValue)
            }
        }
        // Status lines that embed a state, a time or a version keep a placeholder in every language.
        for language in AppLanguage.allCases where language != .system {
            for key in [LocalizationKey.keyModSettingsStatusTitleFormat, .keyModSettingsStatusLastData, .keyModSettingsStatusUnsupportedDetail] {
                XCTAssertTrue(tr(key, arguments: ["%1$@"], language: language).contains("%1$@"), "\(language) \(key.rawKey)")
            }
        }
    }

    // MARK: Views

    func testSettingsRowsShowStatusAndFollowTheInstall() throws {
        let coordinator = makeCoordinator()
        refresh(coordinator)
        let rows = coordinator.realtimeBoostSettingsRows()
        XCTAssertEqual(rows.count, 2)
        let status = try XCTUnwrap(rows.first as? SettingsRowView)
        XCTAssertEqual(status.titleLabel.stringValue, tr(.keyModSettingsStatusTitleFormat, arguments: [tr(.keyModSettingsStatusNotInstalled)]))

        fake.record = ModInstallRecord(installedAt: start)
        refresh(coordinator)
        let deadline = Date().addingTimeInterval(1)
        let notInstalledTitle = tr(.keyModSettingsStatusTitleFormat, arguments: [tr(.keyModSettingsStatusNotInstalled)])
        while status.titleLabel.stringValue == notInstalledTitle, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(status.titleLabel.stringValue, tr(.keyModSettingsStatusTitleFormat, arguments: [tr(.keyModSettingsStatusWaiting)]))
        XCTAssertEqual(status.detailLabel.stringValue, "", "no uninstall note any more")
        XCTAssertTrue(coordinator.realtimeBoostSettingsRows().first === status, "one set is kept up to date")
        XCTAssertFalse(coordinator.realtimeBoostSettingsRows(detached: true).first === status, "search gets its own copy")
    }

    func testPanelFromTheCoordinatorUsesTheAppLanguageAndStartsAtTheIntro() {
        let coordinator = makeCoordinator()
        let panel = coordinator.makePanelView()
        XCTAssertEqual(coordinator.controller.state, .intro(dismissChecked: false))
        XCTAssertTrue(try XCTUnwrap(panel.snapshotLines.first).hasPrefix("# " + tr(.keyModPanelTitle)))
        XCTAssertTrue(panel.snapshotLines.last?.contains("<" + tr(.keyModPanelInstall) + ">") == true)
    }

    func testWindowControllerBuildsAStandaloneWindowWithEscapeAndDefaultButton() throws {
        let coordinator = makeCoordinator()
        let window = coordinator.windowController.prepare()
        XCTAssertTrue(window.styleMask.contains(.titled)); XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.titlebarAppearsTransparent); XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.contentView?.frame.width, coordinator.windowController.panelView?.width)
        XCTAssertEqual(window.defaultButtonCell?.title, tr(.keyModPanelInstall))

        // Esc is "later": it closes the window.
        window.orderOut(nil)
        window.cancelOperation(nil)
        XCTAssertFalse(window.isVisible)
        // The window is reused.
        XCTAssertTrue(coordinator.windowController.prepare() === window)
        XCTAssertGreaterThan(window.frame.height, 300)
    }

    /// Renders every state in both appearances to PNG files for a visual self-check (set BB_MOD_RENDER_DIR).
    func testRenderEveryStateToImagesWhenAskedTo() throws {
        guard let directory = ProcessInfo.processInfo.environment["BB_MOD_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let states: [(String, ModPanelState)] = [
            ("intro", .intro(dismissChecked: false)), ("intro-checked", .intro(dismissChecked: true)),
            ("installing", .installing(current: .installPlugin)), ("awaiting", .awaitingFirstData),
            ("enabled", .enabled), ("silent", .silent), ("failed-missing", .failed(.claudeNotFound)),
            ("failed-command", .failed(.commandFailed(step: .installPlugin, exitCode: 1, detail: "Plugin not found in marketplace\nSee claude plugin marketplace list"))),
            ("dismissed", .dismissConfirmed),
            ("installed", .installed(statusText: "已启用\n最新数据：03:39:00")), ("uninstalling", .uninstalling),
            ("uninstalled", .uninstalled), ("uninstall-failed", .uninstallFailed(.claudeNotFound)),
        ]
        for (appearanceName, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (label, state) in states {
                let c = ModOnboardingController(preference: MemoryPromptPreference(), copyToPasteboard: { _ in })
                c.setStateForTesting(state)
                let view = ModOnboardingPanelView(controller: c, localize: ModOnboardingText.appLocalize)
                view.appearance = try XCTUnwrap(NSAppearance(named: name))
                view.wantsLayer = true
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                view.layoutSubtreeIfNeeded()
                let size = view.fittingSize
                view.frame = NSRect(origin: .zero, size: size)
                view.layoutSubtreeIfNeeded()
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = view.appearance
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(label)-\(appearanceName).png"))
            }
            // The intro window in every language (long wording wraps the footer buttons onto two rows).
            for language in AppLanguage.allCases where language != .system {
                let c = ModOnboardingController(preference: MemoryPromptPreference(), copyToPasteboard: { _ in })
                let view = ModOnboardingPanelView(controller: c, localize: { text in
                    LocalizationKey(rawValue: text.rawValue).map { tr($0, language: language) } ?? text.defaultText
                })
                view.appearance = NSAppearance(named: name)
                view.layoutSubtreeIfNeeded()
                let size = view.fittingSize
                view.frame = NSRect(origin: .zero, size: size)
                view.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("intro-\(language.rawValue)-\(appearanceName).png"))
            }
            // The settings rows in every language.
            for language in AppLanguage.allCases where language != .system {
                for status in [ModEnhancementStatus.notInstalled, .active(lastDataAt: Date())] {
                    let c = ModOnboardingController(preference: MemoryPromptPreference(), copyToPasteboard: { _ in })
                    let rows = RealtimeBoostSettingsRows(
                        controller: c, status: status,
                        localize: { text in
                            LocalizationKey(rawValue: text.rawValue).map { key in
                                switch text {
                                case .statusTitleFormat, .lastData, .unsupportedDetail: return tr(key, arguments: ["%1$@"], language: language)
                                default: return tr(key, language: language)
                                }
                            } ?? text.defaultText
                        })
                    let section = SettingsSectionView(title: "Claude", contentViews: rows.rows)
                    section.appearance = NSAppearance(named: name)
                    section.frame = NSRect(x: 0, y: 0, width: 560, height: 10)
                    section.layoutSubtreeIfNeeded()
                    section.frame.size.height = section.fittingSize.height
                    section.layoutSubtreeIfNeeded()
                    let rep = try XCTUnwrap(section.bitmapImageRepForCachingDisplay(in: section.bounds))
                    section.cacheDisplay(in: section.bounds, to: rep)
                    var tag = "notinstalled"; if case .active = status { tag = "active" }
                    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-\(language.rawValue)-\(tag)-\(appearanceName).png"))
                }
            }
            // The menu prompt row on a menu-like background, in every language (the row sizes itself to the wording).
            for language in AppLanguage.allCases where language != .system {
                for headless in [false, true] {
                    let row = ModPromptRowView(headless: headless, localize: { text in
                        LocalizationKey(rawValue: text.rawValue).map { tr($0, language: language) } ?? text.defaultText
                    })
                    row.appearance = NSAppearance(named: name)
                    row.wantsLayer = true
                    row.effectiveAppearance.performAsCurrentDrawingAppearance {
                        row.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    }
                    row.layoutSubtreeIfNeeded()
                    let rep = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                    row.cacheDisplay(in: row.bounds, to: rep)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "prompt-row-\(language.rawValue)\(headless ? "-headless" : "")-\(appearanceName).png"))
                }
            }
        }
    }
}
