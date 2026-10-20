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
            "# 实时增强",
            "• 只读取额度数据（5 小时 / 7 天用量），不读取对话内容。",
            "• 插件以你的用户权限在 Claude Code 内运行，可随时用 /plugin 卸载。",
            "• 数据只写入本机，不联网上传。",
            "• 新会话自动生效；已有会话可运行 /reload-plugins。",
            "( ) 不再在菜单中提示", "<一键安装>", "<关闭>",
        ])
        XCTAssertTrue(lines(.intro(dismissChecked: true)).contains("(x) 不再在菜单中提示"))
    }

    func testSnapshotInstallingSucceededFailedDismissed() {
        XCTAssertEqual(lines(.installing(current: .installPlugin)), ["# 实时增强", "[x] 添加来源", "[~] 安装 Mod", "[ ] 完成"])
        XCTAssertEqual(lines(.succeeded), ["# 已开启 ✓", "[x] 添加来源", "[x] 安装 Mod", "[x] 完成",
                                           "新开的 Claude Code 会话会自动生效。", "已有会话可选运行 /reload-plugins。", "</reload-plugins>", "<关闭>"])
        let commands = ModInstallPlan.standard.copyableCommands.replacingOccurrences(of: "\n", with: "\n$ ")
        XCTAssertEqual(lines(.failed(.claudeNotFound)), ["# 无法自动安装", "没有找到 claude 命令。请在终端中运行下面的命令：", "$ " + commands, "<复制命令>", "<关闭>"])
        XCTAssertEqual(lines(.failed(.commandFailed(step: .installPlugin, exitCode: 1, detail: "x")))[1], "命令未成功完成。请在终端中运行下面的命令：")
        XCTAssertEqual(lines(.dismissConfirmed), ["# 已关闭提示", "菜单底部改为显示“数据来源”。可在 设置 › 高级 › 实时增强 中重新开启。", "<撤销>", "<关闭>"])
    }

    func testPanelViewRendersEveryStateInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let c = controller(locator: nil, results: [])
            let view = ModOnboardingPanelView(controller: c)
            view.appearance = try XCTUnwrap(NSAppearance(named: name))
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(view.fittingSize.height, 100, "intro \(name.rawValue)")
        }
    }

    func testInstallFlowToSuccessAndClaudeMissingFallback() {
        let success = controller(locator: "/bin/claude", results: [ok, ok])
        let done = expectation(description: "success")
        success.onChange = { if success.state == .succeeded { done.fulfill() } }
        success.startInstall()
        XCTAssertEqual(success.state, .installing(current: .addMarketplace))
        wait(for: [done], timeout: 5)

        var copied: String?
        let missing = controller(locator: nil, results: [], copied: { copied = $0 })
        let failed = expectation(description: "failed")
        let view = ModOnboardingPanelView(controller: missing)
        let reload = missing.onChange
        missing.onChange = { reload?(); if missing.state == .failed(.claudeNotFound) { failed.fulfill() } }
        view.perform(.install)
        wait(for: [failed], timeout: 5)
        XCTAssertTrue(view.snapshotLines.contains("<复制命令>"))
        view.perform(.copyCommands)
        XCTAssertEqual(copied, ModInstallPlan.standard.copyableCommands)
    }

    func testDismissFlowShowsConfirmationAndPersists() {
        let pref = MemoryPreference()
        let c = controller(locator: nil, results: [], pref: pref)
        let view = ModOnboardingPanelView(controller: c)
        var closed = 0
        view.onRequestClose = { closed += 1 }
        view.perform(.close)  // unchecked: closes directly
        XCTAssertEqual(closed, 1); XCTAssertFalse(pref.isPromptDismissed)

        c.setDismissChecked(true)
        view.perform(.close)  // checked: confirmation state, not yet closed
        XCTAssertEqual(c.state, .dismissConfirmed); XCTAssertTrue(pref.isPromptDismissed); XCTAssertEqual(closed, 1)
        view.perform(.undoDismiss)
        XCTAssertEqual(c.state, .intro(dismissChecked: false)); XCTAssertFalse(pref.isPromptDismissed)
        c.setDismissChecked(true); view.perform(.close); view.perform(.close)
        XCTAssertEqual(closed, 2)
    }

    func testPanelViewRendersNonBlankWithButtonsWired() throws {
        let c = controller(locator: nil, results: [])
        let view = ModOnboardingPanelView(controller: c)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.height, 100)
        XCTAssertEqual(view.snapshotLines.count, 8)
    }

    func testSettingsPresentationAndToggle() {
        let silent = RealtimeBoostPresentation.make(status: .enabledButSilent)
        XCTAssertTrue(silent.statusText.contains("10 分钟")); XCTAssertTrue(silent.showsCopyAction); XCTAssertFalse(silent.showsInstallAction)
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .notInstalled).showsInstallAction)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RealtimeBoostPresentation.make(status: .active(lastDataAt: Date(timeIntervalSince1970: 1_767_274_800)), timeZone: utc).statusText, "已开启，最近数据 13:40:00")
        XCTAssertTrue(RealtimeBoostPresentation.make(status: .unsupportedClaudeCode(.init(major: 2, minor: 1, patch: 100))).statusText.contains("2.1.100"))

        let pref = MemoryPreference()
        let view = RealtimeBoostSettingsView(controller: controller(locator: nil, results: [], pref: pref), status: .notInstalled)
        XCTAssertEqual(view.promptToggle.state, .on)
        view.promptToggle.performClick(nil)
        XCTAssertTrue(pref.isPromptDismissed)
        view.promptToggle.performClick(nil)
        XCTAssertFalse(pref.isPromptDismissed)
    }

    func testPromptRowClick() {
        let row = ModPromptRowView()
        var clicks = 0
        row.onClick = { clicks += 1 }
        row.button.performClick(nil)
        XCTAssertEqual(clicks, 1); XCTAssertEqual(row.button.title, "启用实时增强 ›")
    }
}
