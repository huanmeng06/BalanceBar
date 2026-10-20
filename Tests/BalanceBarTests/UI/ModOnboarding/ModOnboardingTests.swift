import AppKit
import XCTest
@testable import BalanceBar

private struct FakeHeadless: ModHeadlessSignalProviding { var isSatisfied: Bool }

private final class MemoryPreference: ModPromptPreferenceStoring { var isPromptDismissed = false }

private struct FakeLocator: ClaudeExecutableLocating { var path: String?; func locate() -> String? { path } }

private final class ScriptedRunner: ModCommandRunning {
    var results: [ModCommandResult?]
    private(set) var calls: [[String]] = []
    init(_ results: [ModCommandResult?]) { self.results = results }
    func run(executablePath: String, arguments: [String]) -> ModCommandResult? {
        calls.append(arguments)
        return results.isEmpty ? nil : results.removeFirst()
    }
}

private let ok = ModCommandResult(exitCode: 0, stdout: "{\"outcome\":\"ok\"}", stderr: "")

final class ModPromptVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func inputs(_ edit: (inout ModPromptInputs) -> Void = { _ in }) -> ModPromptInputs {
        var i = ModPromptInputs(isOfficialDirect: true, claudeCode: .detected(.init(major: 2, minor: 1, patch: 291)))
        edit(&i)
        return i
    }

    func testVisibleOnlyWhenVersionConfirmed() {
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs(), now: now), .visible)
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.claudeCode = .unknown }, now: now), .hidden(.claudeCodeVersionUnknown))
    }

    func testEachConditionHidesPrompt() {
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.isOfficialDirect = false }, now: now), .hidden(.notOfficialDirect))
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.lastModDataAt = now.addingTimeInterval(-6 * 86_400) }, now: now), .hidden(.recentModData))
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.claudeCode = .detected(.init(major: 2, minor: 1, patch: 286)) }, now: now), .hidden(.claudeCodeTooOld))
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.promptDismissed = true }, now: now), .hidden(.dismissed))
    }

    func testBoundaries() {
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.lastModDataAt = now.addingTimeInterval(-7 * 86_400) }, now: now), .visible)
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.claudeCode = .detected(.init(major: 2, minor: 1, patch: 287)) }, now: now), .visible)
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.claudeCode = .detected(.init(major: 3, minor: 0, patch: 0)) }, now: now), .visible)
    }

    func testHeadlessSignalOnlyMattersWithHUDSnapshot() {
        let unmet = FakeHeadless(isSatisfied: false), met = FakeHeadless(isSatisfied: true)
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.headlessSignalSatisfied = unmet.isSatisfied }, now: now), .visible)
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.hasHUDSnapshot = true; $0.headlessSignalSatisfied = unmet.isSatisfied }, now: now), .hidden(.headlessSignalNotSatisfied))
        XCTAssertEqual(ModPromptVisibility.evaluate(inputs { $0.hasHUDSnapshot = true; $0.headlessSignalSatisfied = met.isSatisfied }, now: now), .visible)
    }

    func testVersionParsing() {
        XCTAssertEqual(ClaudeCodeVersion.parse("2.1.291 (Claude Code)"), .init(major: 2, minor: 1, patch: 291))
        XCTAssertNil(ClaudeCodeVersion.parse("garbage"))
        XCTAssertLessThan(ClaudeCodeVersion.parse("2.1.99")!, ModOnboardingConfig.minimumClaudeCodeVersion)
    }

    func testEnhancementStatus() {
        let v = ClaudeCodeVersionStatus.detected(.init(major: 2, minor: 1, patch: 291))
        func status(installed: Bool, last: TimeInterval?, active: Bool, since: TimeInterval? = nil,
                    claude: ClaudeCodeVersionStatus = v) -> ModEnhancementStatus {
            .resolve(installed: installed, lastModDataAt: last.map { now.addingTimeInterval(-$0) }, claudeActivityDetected: active,
                     claudeCode: claude, silenceSince: since.map { now.addingTimeInterval(-$0) }, now: now)
        }
        XCTAssertEqual(status(installed: false, last: nil, active: true), .notInstalled)
        XCTAssertEqual(status(installed: true, last: nil, active: false), .waitingForData)
        // Just installed with activity but no clock yet, or under 10 minutes: still waiting.
        XCTAssertEqual(status(installed: true, last: nil, active: true), .waitingForData)
        XCTAssertEqual(status(installed: true, last: nil, active: true, since: 9 * 60), .waitingForData)
        XCTAssertEqual(status(installed: true, last: nil, active: true, since: 10 * 60), .enabledButSilent)
        // Old data, activity started recently: grace applies from the activity start.
        XCTAssertEqual(status(installed: true, last: 3600, active: true, since: 60), .active(lastDataAt: now.addingTimeInterval(-3600)))
        XCTAssertEqual(status(installed: true, last: 3600, active: true, since: 11 * 60), .enabledButSilent)
        XCTAssertEqual(status(installed: true, last: 9 * 60, active: true, since: 30 * 60), .active(lastDataAt: now.addingTimeInterval(-9 * 60)))
        XCTAssertEqual(status(installed: true, last: 3600, active: false), .active(lastDataAt: now.addingTimeInterval(-3600)))
        // Uninstalled with a leftover snapshot (fresh or stale) is not "enabled".
        XCTAssertEqual(status(installed: false, last: 3600, active: false), .notInstalled)
        XCTAssertEqual(status(installed: false, last: 60, active: true), .notInstalled)
        XCTAssertEqual(status(installed: false, last: nil, active: false, claude: .detected(.init(major: 2, minor: 0, patch: 1))),
                       .unsupportedClaudeCode(.init(major: 2, minor: 0, patch: 1)))
    }
}

final class ModInstallerTests: XCTestCase {
    private func run(locator: String?, results: [ModCommandResult?]) -> (ModInstallResult, [ModInstallStep], [[String]]) {
        let runner = ScriptedRunner(results)
        let q = DispatchQueue(label: "test.installer")
        let installer = ModInstaller(locator: FakeLocator(path: locator), runner: runner, workQueue: q, callbackQueue: q)
        let done = expectation(description: "install")
        var steps: [ModInstallStep] = [], result: ModInstallResult?
        installer.install(progress: { steps.append($0) }, completion: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        return (result!, q.sync { steps }, runner.calls)
    }

    func testSuccessRunsBothCommandsAndAllSteps() {
        let (result, steps, calls) = run(locator: "/bin/claude", results: [ok, ok])
        XCTAssertEqual(result, .success)
        XCTAssertEqual(steps, [.addMarketplace, .installPlugin, .finish])
        XCTAssertEqual(calls, [ModInstallPlan.standard.marketplaceArguments, ModInstallPlan.standard.installArguments])
    }

    func testClaudeNotFoundRunsNothing() {
        let (result, steps, calls) = run(locator: nil, results: [ok, ok])
        XCTAssertEqual(result, .failure(.claudeNotFound))
        XCTAssertTrue(steps.isEmpty); XCTAssertTrue(calls.isEmpty)
    }

    func testCommandFailureStopsAtThatStep() {
        let bad = ModCommandResult(exitCode: 1, stdout: "", stderr: "boom")
        let (result, steps, calls) = run(locator: "/bin/claude", results: [ok, bad])
        XCTAssertEqual(result, .failure(.commandFailed(step: .installPlugin, exitCode: 1, detail: "boom")))
        XCTAssertEqual(steps, [.addMarketplace, .installPlugin]); XCTAssertEqual(calls.count, 2)
    }

    func testLaunchFailureAndNonOkOutcome() {
        let (launch, _, _) = run(locator: "/bin/claude", results: [nil])
        XCTAssertEqual(launch, .failure(.commandFailed(step: .addMarketplace, exitCode: nil, detail: "launch failed")))
        let notOk = ModCommandResult(exitCode: 0, stdout: "{\"outcome\":\"error\"}", stderr: "")
        let (outcome, _, _) = run(locator: "/bin/claude", results: [notOk])
        XCTAssertEqual(outcome, .failure(.commandFailed(step: .addMarketplace, exitCode: 0, detail: "outcome=error")))
    }

    func testLocatorSearchesPathThenKnownDirectories() {
        var seen: [String] = []
        let locator = DefaultClaudeExecutableLocator(environment: ["PATH": "/a:/b"], homeDirectory: "/h",
                                                     isExecutable: { seen.append($0); return $0 == "/h/.local/bin/claude" })
        XCTAssertEqual(locator.locate(), "/h/.local/bin/claude")
        XCTAssertEqual(Array(seen.prefix(2)), ["/a/claude", "/b/claude"])
        XCTAssertNil(DefaultClaudeExecutableLocator(environment: [:], homeDirectory: "/h", isExecutable: { _ in false }).locate())
    }
}

final class ModOnboardingPanelTests: XCTestCase {
    private func controller(locator: String?, results: [ModCommandResult?], pref: MemoryPreference = MemoryPreference(),
                            copied: @escaping (String) -> Void = { _ in }) -> ModOnboardingController {
        let q = DispatchQueue(label: "test.panel")
        let installer = ModInstaller(locator: FakeLocator(path: locator), runner: ScriptedRunner(results), workQueue: q, callbackQueue: .main)
        return ModOnboardingController(installer: installer, preference: pref, copyToPasteboard: copied)
    }

    private func lines(_ state: ModPanelState) -> [String] {
        ModPanelContent.items(for: state, plan: .standard, localize: ModOnboardingText.defaultLocalize).map(\.snapshotLine)
    }

    func testSnapshotIntro() {
        XCTAssertEqual(lines(.intro(dismissChecked: false)), [
            "# 让 Claude 额度实时更新\nBalanceBar Mod 是运行在 Claude Code 里的小插件，每轮回复后把官方额度告诉 BalanceBar。",
            "◆ 实时、官方数据 — 每轮回复后立即更新，不是估算",
            "◆ 覆盖 Agent 场景 — claude -p、Agent SDK、多会话并行同样有效",
            "◆ 不再占用查询额度 — 不请求 Usage API，告别 429",
            "◆ 只读，可随时移除 — 不读对话内容；在 /plugin 中即可卸载",
            "( ) 不再在菜单中提示",
            "<复制命令> | <稍后> <一键安装>*",
        ])
        XCTAssertTrue(lines(.intro(dismissChecked: true)).contains("(x) 不再在菜单中提示"))
        XCTAssertEqual(ModPanelContent.pointSymbols, ["bolt.fill", "terminal", "gauge.with.dots.needle.33percent", "lock.shield"])
    }

    func testSnapshotInstallingAwaitingEnabledSilentFailedDismissed() {
        XCTAssertEqual(lines(.installing(current: .installPlugin)), [
            "# 让 Claude 额度实时更新", "[x] 添加插件源", "[~] 安装 Mod", "[ ] 等待首次数据", "<关闭>"])
        XCTAssertEqual(lines(.awaitingFirstData), [
            "# 让 Claude 额度实时更新", "[x] 添加插件源", "[x] 安装 Mod", "[~] 等待首次数据",
            "新开的 Claude Code 会话会自动启用，正在运行的会话可以不管。", "想让当前会话也马上生效，可在其中输入 /reload-plugins。",
            "$ /reload-plugins", "<关闭>*"])
        XCTAssertEqual(lines(.enabled), ["# 已开启 ✓\n新开的 Claude Code 会话会自动启用，正在运行的会话可以不管。", "<关闭>*"])
        XCTAssertEqual(lines(.silent), [
            "# 已安装，但还没收到数据", "Claude Code 在运行，但 10 分钟内没有收到 Mod 的数据。请检查：",
            "• Claude Code 版本是否为 v2.1.287 或更高", "• 是否是新会话，或已在会话中运行 /reload-plugins", "• 组织策略是否只允许托管插件",
            "<关闭> <打开高级设置>*"])
        let commands = ModInstallPlan.standard.copyableCommands.replacingOccurrences(of: "\n", with: "\n$ ")
        XCTAssertEqual(lines(.failed(.claudeNotFound)), [
            "# 无法自动安装", "没有找到 claude 命令。请在终端中运行下面的命令：", "$ " + commands, "<关闭>*"])
        let failed = lines(.failed(.commandFailed(step: .installPlugin, exitCode: 1, detail: "boom\nsecond\nthird")))
        XCTAssertEqual(failed[1], "命令未成功完成。请在终端中运行下面的命令：")
        XCTAssertEqual(failed[2], "> boom\nsecond", "the first two lines of Claude Code's answer are shown")
        XCTAssertEqual(lines(.dismissConfirmed), [
            "# 已隐藏提示\n之后可以在 设置 › 高级 › 实时增强 中安装 Mod，或重新显示提示。", "<打开高级设置> <好>*"])
    }

    func testPanelViewRendersEveryStateInBothAppearances() throws {
        let states: [ModPanelState] = [
            .intro(dismissChecked: false), .installing(current: .addMarketplace), .awaitingFirstData, .enabled, .silent,
            .failed(.claudeNotFound), .failed(.commandFailed(step: .installPlugin, exitCode: 1, detail: "boom")), .dismissConfirmed,
        ]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for state in states {
                let items = ModPanelContent.items(for: state, plan: .standard, localize: ModOnboardingText.defaultLocalize)
                let c = controller(locator: nil, results: [])
                let view = ModOnboardingPanelView(controller: c)
                view.appearance = try XCTUnwrap(NSAppearance(named: name))
                view.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(view.fittingSize.height, 100, "\(state) \(name.rawValue)")
                XCTAssertEqual(view.fittingSize.width, ModOnboardingPanelView.fixedWidth)
                XCTAssertFalse(items.isEmpty)
            }
        }
    }

    func testInstallFlowWaitsForTheFirstSnapshotAndClaudeMissingFallsBackToCopy() {
        let success = controller(locator: "/bin/claude", results: [ok, ok])
        let done = expectation(description: "awaiting first data")
        success.onChange = { if success.state == .awaitingFirstData { done.fulfill() } }
        success.startInstall()
        XCTAssertEqual(success.state, .installing(current: .addMarketplace))
        wait(for: [done], timeout: 5)
        XCTAssertTrue(success.isInstallInProgress)
        success.resetToIntro()
        XCTAssertEqual(success.state, .awaitingFirstData, "reopening keeps showing the wait")
        success.markFirstDataReceived()
        XCTAssertEqual(success.state, .enabled)
        success.resetToIntro()
        XCTAssertEqual(success.state, .intro(dismissChecked: false))

        var copied: String?
        let missing = controller(locator: nil, results: [], copied: { copied = $0 })
        let failed = expectation(description: "failed")
        let view = ModOnboardingPanelView(controller: missing)
        let reload = missing.onChange
        missing.onChange = { reload?(); if missing.state == .failed(.claudeNotFound) { failed.fulfill() } }
        view.perform(.install)
        wait(for: [failed], timeout: 5)
        XCTAssertTrue(view.snapshotLines.contains { $0.hasPrefix("$ claude plugin marketplace add") })
        view.perform(.copyCommands)
        XCTAssertEqual(copied, ModInstallPlan.standard.copyableCommands)
    }

    func testSilenceTurnsTheWaitIntoAdviceUntilDataArrives() {
        var silent = false
        let c = controller(locator: nil, results: [])
        c.silenceCheck = { silent }
        c.checkSilence()
        XCTAssertEqual(c.state, .intro(dismissChecked: false), "only a waiting window can turn silent")
        let waiting = controller(locator: "/bin/claude", results: [ok, ok])
        waiting.silenceCheck = { silent }
        let done = expectation(description: "awaiting")
        waiting.onChange = { if waiting.state == .awaitingFirstData { done.fulfill() } }
        waiting.startInstall()
        wait(for: [done], timeout: 5)
        waiting.checkSilence()
        XCTAssertEqual(waiting.state, .awaitingFirstData)
        silent = true
        waiting.checkSilence()
        XCTAssertEqual(waiting.state, .silent)
        waiting.markFirstDataReceived()
        XCTAssertEqual(waiting.state, .enabled, "late data still completes the install")
    }

    func testEnabledClosesTheWindowAfterTwoSecondsOnlyWhenItWasWaiting() {
        let c = controller(locator: "/bin/claude", results: [ok, ok])
        let view = ModOnboardingPanelView(controller: c)
        var closed = 0
        view.onRequestClose = { closed += 1 }
        let done = expectation(description: "awaiting")
        let reload = c.onChange
        c.onChange = { reload?(); if c.state == .awaitingFirstData { done.fulfill() } }
        c.startInstall()
        wait(for: [done], timeout: 5)
        c.markFirstDataReceived()
        XCTAssertEqual(closed, 0)
        let closing = expectation(description: "auto close")
        DispatchQueue.main.asyncAfter(deadline: .now() + ModOnboardingPanelView.successDisplayDuration + 0.5) { closing.fulfill() }
        wait(for: [closing], timeout: 5)
        XCTAssertEqual(closed, 1)
    }

    func testDismissFlowShowsConfirmationAndPersists() {
        let pref = MemoryPreference()
        let c = controller(locator: nil, results: [], pref: pref)
        let view = ModOnboardingPanelView(controller: c)
        var closed = 0
        view.onRequestClose = { closed += 1 }
        view.perform(.close)  // "later", unchecked: closes directly
        XCTAssertEqual(closed, 1); XCTAssertFalse(pref.isPromptDismissed)

        c.setDismissChecked(true)
        view.perform(.close)  // checked: confirmation state, not yet closed
        XCTAssertEqual(c.state, .dismissConfirmed); XCTAssertTrue(pref.isPromptDismissed); XCTAssertEqual(closed, 1)
        view.perform(.close)  // "OK"
        XCTAssertEqual(closed, 2)

        // Any non-install button counts: "copy commands" with the box ticked also confirms the dismissal.
        pref.isPromptDismissed = false
        c.resetToIntro()
        c.setDismissChecked(true)
        view.perform(.copyCommands)
        XCTAssertEqual(c.state, .dismissConfirmed); XCTAssertTrue(pref.isPromptDismissed)
    }

    func testCopyButtonOfTheCodeBlockCopiesAndShowsACheckMark() throws {
        var copied: String?
        let c = controller(locator: nil, results: [], copied: { copied = $0 })
        c.setStateForTesting(.failed(.claudeNotFound))
        let view = ModOnboardingPanelView(controller: c)
        view.layoutSubtreeIfNeeded()
        func find(_ v: NSView) -> ModCopyButton? { (v as? ModCopyButton) ?? v.subviews.lazy.compactMap(find).first }
        let button = try XCTUnwrap(find(view))
        XCTAssertEqual(button.frame.width, ModCopyButton.side)
        XCTAssertEqual(button.frame.height, ModCopyButton.side, "the copy button is square")
        XCTAssertEqual(button.layer?.bounds.size, CGSize(width: ModCopyButton.side, height: ModCopyButton.side))
        XCTAssertEqual(button.toolTip, ModOnboardingText.copyCommands.defaultText)
        XCTAssertFalse(button.isShowingFeedback)
        button.performClick(nil)
        XCTAssertEqual(copied, ModInstallPlan.standard.copyableCommands)
        XCTAssertTrue(button.isShowingFeedback)
        let reset = expectation(description: "feedback ends")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { reset.fulfill() }
        wait(for: [reset], timeout: 3)
        XCTAssertFalse(button.isShowingFeedback)
    }

    func testOpenAdvancedSettingsButtonAsksTheAppAndClosesTheWindow() {
        let c = controller(locator: nil, results: [])
        var opened = 0
        c.onOpenSettings = { opened += 1 }
        let view = ModOnboardingPanelView(controller: c)
        var closed = 0
        view.onRequestClose = { closed += 1 }
        view.perform(.openSettings)
        XCTAssertEqual(opened, 1); XCTAssertEqual(closed, 1)
    }

    func testPanelViewHasTheDefaultInstallButtonAndFixedWidth() throws {
        let c = controller(locator: nil, results: [])
        let view = ModOnboardingPanelView(controller: c)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.defaultButton?.title, "一键安装")
        XCTAssertEqual(view.defaultButton?.keyEquivalent, "\r")
        XCTAssertEqual(view.snapshotLines.count, 7)
    }

    func testSettingsPresentationRowsAndSwitch() {
        let silent = RealtimeBoostPresentation.make(status: .enabledButSilent)
        XCTAssertTrue(silent.statusText.contains("10 分钟")); XCTAssertTrue(silent.showsCopyAction); XCTAssertFalse(silent.showsInstallAction)
        XCTAssertEqual(silent.statusTone, .orange)
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .notInstalled).showsInstallAction)
        XCTAssertEqual(RealtimeBoostPresentation.make(status: .notInstalled).statusTone, .gray)
        XCTAssertEqual(RealtimeBoostPresentation.make(status: .waitingForData).statusTone, .orange)
        let utc = TimeZone(identifier: "UTC")!
        let active = RealtimeBoostPresentation.make(status: .active(lastDataAt: Date(timeIntervalSince1970: 1_767_274_800)), timeZone: utc)
        XCTAssertEqual(active.statusText, "已启用 · 最近数据 13:40:00"); XCTAssertEqual(active.statusTone, .green)
        let old = RealtimeBoostPresentation.make(status: .unsupportedClaudeCode(.init(major: 2, minor: 1, patch: 100)))
        XCTAssertTrue(old.statusText.contains("2.1.100")); XCTAssertEqual(old.statusTone, .red)

        let pref = MemoryPreference()
        let rows = RealtimeBoostSettingsRows(controller: controller(locator: nil, results: [], pref: pref), status: .notInstalled)
        XCTAssertEqual(rows.rows.count, 2)
        XCTAssertEqual(rows.promptSwitch.state, .on)
        rows.promptSwitch.performClick(nil)
        XCTAssertTrue(pref.isPromptDismissed)
        rows.promptSwitch.performClick(nil)
        XCTAssertFalse(pref.isPromptDismissed)
        XCTAssertFalse(rows.installButton.isHidden)
        rows.update(status: .active(lastDataAt: Date()))
        XCTAssertTrue(rows.installButton.isHidden)
        XCTAssertEqual(rows.detailText, "卸载：在 Claude Code 中输入 /plugin 即可移除。")
    }

    func testPromptRowShowsTheDocumentCopyAndRunsItsAction() {
        let row = ModPromptRowView()
        XCTAssertEqual(row.mainText, "安装 BalanceBar Mod，额度实时更新")
        XCTAssertEqual(row.whyText, "为什么这么做？")
        XCTAssertEqual(ModPromptRowView(headless: true).mainText, "检测到 headless 运行，安装 Mod 可让这部分也实时更新")
        var clicks = 0
        row.onClick = { clicks += 1 }
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(row.accessibilityRole(), .button)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.frame.height, ModPromptRowView.rowHeight)
    }
}
