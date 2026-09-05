import Foundation
import XCTest
@testable import BalanceBar

final class TerminalSessionIdentityTests: XCTestCase {
    private let psOutput = """
    100 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty ghostty
    200 100 ttys001 /bin/zsh zsh
    300 200 ttys001 /Users/dev/.grok/bin/grok grok
    400 100 ttys002 /bin/zsh zsh
    500 400 ttys002 /usr/local/bin/claude claude
    600 1 ?? /Applications/Kitty.app/Contents/MacOS/kitty kitty
    700 600 ttys003 /bin/zsh zsh
    800 700 ttys003 /usr/local/bin/claude claude
    """

    private let grokTTY = "ttys001"
    private let claudeTTY = "ttys002"
    private let quietIO = Date(timeIntervalSince1970: 10)
    private let defaultWinsize = TerminalTTYWinsize(rows: 40, cols: 120)

    func testSnapshotParsesTTYAndClassifiesCLIProcesses() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        XCTAssertEqual(snapshot.grok.map(\.pid), [300])
        XCTAssertEqual(snapshot.claude.map(\.pid), [500, 800])
        XCTAssertEqual(snapshot.grokTTYs, ["ttys001"])
        XCTAssertEqual(snapshot.claudeTTYs, ["ttys002", "ttys003"])
        XCTAssertTrue(snapshot.belongsToTerminal(pid: 300, terminalPID: 100))
        XCTAssertTrue(snapshot.belongsToTerminal(pid: 500, terminalPID: 100))
        XCTAssertFalse(snapshot.belongsToTerminal(pid: 800, terminalPID: 100))
        XCTAssertEqual(snapshot.uniqueCLITTY(focusedPID: 200, terminalPID: 100), grokTTY)
        XCTAssertEqual(snapshot.uniqueCLITTY(focusedPID: 300, terminalPID: 100), grokTTY)
        XCTAssertEqual(snapshot.uniqueCLITTY(focusedPID: 400, terminalPID: 100), claudeTTY)
        XCTAssertEqual(snapshot.uniqueCLITTY(focusedPID: 500, terminalPID: 100), claudeTTY)
        XCTAssertNil(snapshot.uniqueCLITTY(focusedPID: 100, terminalPID: 100))
        XCTAssertNil(snapshot.uniqueCLITTY(focusedPID: 800, terminalPID: 100))
    }

    func testNormalizeTTYStripsDevPrefixAndIgnoresDetached() {
        XCTAssertEqual(TerminalCLIProcessRecord.normalizeTTY("/dev/ttys002"), "ttys002")
        XCTAssertEqual(TerminalCLIProcessRecord.normalizeTTY("ttys002"), "ttys002")
        XCTAssertNil(TerminalCLIProcessRecord.normalizeTTY("??"))
        XCTAssertNil(TerminalCLIProcessRecord.normalizeTTY("-"))
        XCTAssertNil(TerminalCLIProcessRecord.normalizeTTY("  "))
    }

    func testAppleScriptTTYIsPreferredOverStreamingGrok() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        let tty = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 9_000,
            claudeOffset: 50,
            grokIO: Date(timeIntervalSince1970: 90),
            appleScriptTTY: "/dev/ttys002"
        )
        XCTAssertEqual(tty, claudeTTY)
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: tty,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            ),
            .claude
        )
    }

    func testSingleCLIUnderFrontmostTerminalIsUsedWithoutAppleScript() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        let tty = TerminalFrontmostTTY.resolve(
            bundleIdentifier: "com.mitchellh.ghostty",
            terminalPID: 600,
            snapshot: snapshot,
            appleScriptTTY: nil,
            ttyIODate: { _ in quietIO },
            latch: &latch
        )
        XCTAssertEqual(tty, "ttys003")
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: tty,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            ),
            .claude
        )
    }

    func testLatchedClaudeHoldsWhileGrokFDGrowsEverySample() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        var grokOffset: Int64 = 100
        func sample(claudeOffset: Int64, claudeIO: Date = Date(timeIntervalSince1970: 10)) -> String? {
            grokOffset += 1
            return resolveGhostty(
                snapshot: snapshot,
                latch: &latch,
                grokOffset: grokOffset,
                claudeOffset: claudeOffset,
                grokIO: Date(timeIntervalSince1970: TimeInterval(90 + grokOffset)),
                claudeIO: claudeIO
            )
        }

        _ = sample(claudeOffset: 50)
        _ = sample(claudeOffset: 50)
        _ = sample(claudeOffset: 50)
        let claudePulse = sample(
            claudeOffset: 51,
            claudeIO: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(claudePulse, claudeTTY)
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: claudePulse,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            ),
            .claude
        )

        for sampleIndex in 1...6 {
            let tty = sample(
                claudeOffset: 51,
                claudeIO: Date(timeIntervalSince1970: 20)
            )
            XCTAssertEqual(tty, claudeTTY, "sample \(sampleIndex) must keep the Claude latch")
            XCTAssertEqual(
                ActivityClientSelection.client(
                    frontmost: .terminal,
                    current: .claude,
                    grokProcessRunning: true,
                    claudeProcessRunning: true,
                    frontmostTTY: tty,
                    grokTTYs: snapshot.grokTTYs,
                    claudeTTYs: snapshot.claudeTTYs
                ),
                .claude
            )
        }
    }

    func testQuietGrokTTYOneShotIOSelectsGrok() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        quietBoth(snapshot: snapshot, latch: &latch, current: .claude)

        let tty = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 101,
            claudeOffset: 50,
            grokIO: Date(timeIntervalSince1970: 40)
        )
        XCTAssertEqual(tty, grokTTY)
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .claude,
                frontmostTTY: tty,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            ),
            .grok
        )
    }

    func testClaudeQuietOneShotHoldsWhileGrokStreams() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        var grokOffset: Int64 = 100
        func sample(claudeOffset: Int64, claudeIO: Date) -> String? {
            grokOffset += 1
            return resolveGhostty(
                snapshot: snapshot,
                latch: &latch,
                grokOffset: grokOffset,
                claudeOffset: claudeOffset,
                grokIO: Date(timeIntervalSince1970: TimeInterval(90 + grokOffset)),
                claudeIO: claudeIO
            )
        }

        _ = sample(claudeOffset: 50, claudeIO: quietIO)
        _ = sample(claudeOffset: 50, claudeIO: quietIO)
        _ = sample(claudeOffset: 50, claudeIO: quietIO)
        let claudePulse = sample(
            claudeOffset: 51,
            claudeIO: Date(timeIntervalSince1970: 80)
        )
        XCTAssertEqual(claudePulse, claudeTTY)

        for _ in 0..<4 {
            let held = sample(claudeOffset: 51, claudeIO: Date(timeIntervalSince1970: 80))
            XCTAssertEqual(held, claudeTTY)
            XCTAssertEqual(
                ActivityClientSelection.preferredTerminalClient(
                    current: .claude,
                    frontmostTTY: held,
                    grokTTYs: snapshot.grokTTYs,
                    claudeTTYs: snapshot.claudeTTYs
                ),
                .claude
            )
        }
    }

    func testWinsizeOneShotOnQuietGrokSelectsGrok() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        quietBoth(snapshot: snapshot, latch: &latch)

        let tty = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 100,
            claudeOffset: 50,
            grokWinsize: TerminalTTYWinsize(rows: 41, cols: 120)
        )
        XCTAssertEqual(tty, grokTTY)
    }

    func testWindowTitleSelectsGrokWithoutIO() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        quietBoth(snapshot: snapshot, latch: &latch)
        _ = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 100,
            claudeOffset: 51,
            claudeIO: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(latch.tty, claudeTTY)

        let tty = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 100,
            claudeOffset: 51,
            windowTitle: "grok"
        )
        XCTAssertEqual(tty, grokTTY)
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .claude,
                frontmostTTY: tty,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            ),
            .grok
        )
    }

    func testAmbiguousWindowTitleDoesNotOverrideLatch() {
        XCTAssertEqual(TerminalFocusHint.client(fromWindowTitle: "grok"), .grok)
        XCTAssertEqual(TerminalFocusHint.client(fromWindowTitle: "Claude Code"), .claude)
        XCTAssertNil(TerminalFocusHint.client(fromWindowTitle: "Ghostty"))
        XCTAssertNil(TerminalFocusHint.client(fromWindowTitle: "grok — claude"))
        XCTAssertNil(TerminalFocusHint.client(fromWindowTitle: nil))

        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        quietBoth(snapshot: snapshot, latch: &latch)
        _ = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 100,
            claudeOffset: 51
        )
        let tty = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 100,
            claudeOffset: 51,
            windowTitle: "Ghostty"
        )
        XCTAssertEqual(tty, claudeTTY)
    }

    func testKittyIPCFocusedGrokTTYWinsWithoutIO() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        let json = Data("""
        [{"is_focused":true,"tabs":[{"is_focused":true,"windows":[{
            "is_focused":true,
            "pid":200,
            "tty":"/dev/ttys001",
            "foreground_processes":[{"pid":300,"cmdline":["/Users/dev/.grok/bin/grok"]}]
        }]}]}]
        """.utf8)
        XCTAssertEqual(
            TerminalFocusHint.focusedKittyTTY(
                lsJSON: json,
                snapshot: snapshot,
                terminalPID: 100
            ),
            grokTTY
        )

        var latch = TerminalTTYFocusLatch()
        quietBoth(snapshot: snapshot, latch: &latch)
        _ = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 100,
            claudeOffset: 51
        )
        let tty = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 100,
            claudeOffset: 51,
            ipcTTY: grokTTY
        )
        XCTAssertEqual(tty, grokTTY)
    }

    func testLeavingTerminalPIDClearsLatchAndDoesNotKeepStaleFocus() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        quietBoth(snapshot: snapshot, latch: &latch)
        _ = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 100,
            claudeOffset: 51
        )
        XCTAssertEqual(latch.tty, claudeTTY)

        let cleared = TerminalFrontmostTTY.resolve(
            bundleIdentifier: "com.openai.codex",
            terminalPID: nil,
            snapshot: snapshot,
            appleScriptTTY: nil,
            ttyIODate: { _ in quietIO },
            latch: &latch
        )
        XCTAssertNil(cleared)
        XCTAssertNil(latch.tty)

        let resampled = resolveGhostty(
            snapshot: snapshot,
            latch: &latch,
            grokOffset: 500,
            claudeOffset: 51,
            grokIO: Date(timeIntervalSince1970: 500)
        )
        XCTAssertNil(resampled)
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .codex,
                frontmostTTY: resampled,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            ),
            .claude
        )
    }

    func testStreamingGrokWithoutFocusSignalDoesNotBeatCurrentClaude() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        var grokOffset: Int64 = 100
        func sample(claudeOffset: Int64) -> String? {
            grokOffset += 1
            return resolveGhostty(
                snapshot: snapshot,
                latch: &latch,
                grokOffset: grokOffset,
                claudeOffset: claudeOffset,
                grokIO: Date(timeIntervalSince1970: TimeInterval(90 + grokOffset))
            )
        }
        _ = sample(claudeOffset: 50)
        _ = sample(claudeOffset: 50)
        _ = sample(claudeOffset: 50)
        let tty = sample(claudeOffset: 51)
        XCTAssertEqual(tty, claudeTTY)
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: sample(claudeOffset: 51),
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            ),
            .claude
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .codex,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: grokTTY,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            ),
            .codex
        )
    }

    func testPTYNameMapsPtmxMinorAndSlavePath() {
        XCTAssertEqual(
            TerminalPTYFDActivity.ttyName(path: "/dev/ptmx", rdev: 15 << 24),
            "ttys000"
        )
        XCTAssertEqual(
            TerminalPTYFDActivity.ttyName(path: "/dev/ptmx", rdev: (15 << 24) | 4),
            "ttys004"
        )
        XCTAssertEqual(
            TerminalPTYFDActivity.ttyName(path: "/dev/ttys001", rdev: 0),
            "ttys001"
        )
        XCTAssertNil(TerminalPTYFDActivity.ttyName(path: "/dev/null", rdev: 0))
    }

    func testAppleScriptSourceCoversTerminalITermAndGhosttyNotWarp() {
        let terminal = TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.apple.Terminal")
        let iterm = TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.googlecode.iterm2")
        let ghostty = TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.mitchellh.ghostty")
        XCTAssertNotNil(terminal)
        XCTAssertNotNil(iterm)
        XCTAssertEqual(
            terminal,
            TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.apple.Terminal")
        )
        XCTAssertEqual(
            iterm,
            TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.googlecode.iterm2")
        )
        XCTAssertTrue(
            ghostty?.contains("tty of focused terminal of selected tab of front window") == true
        )
        XCTAssertTrue(
            TerminalFrontmostTTY.appleScriptSource(
                bundleIdentifier: "com.mitchellh.ghostty",
                query: .pid
            )?.contains("pid of focused terminal of selected tab of front window") == true
        )
        XCTAssertNil(
            TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.apple.Terminal", query: .pid)
        )
        XCTAssertNil(
            TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.googlecode.iterm2", query: .pid)
        )
        XCTAssertNil(TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "dev.warp.warp-stable"))
        XCTAssertNil(TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "net.kovidgoyal.kitty"))
    }

    func testGhosttyAppleScriptTTYWinsOverGrowingGrokFDWithoutSurfaceProbes() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        var grokOffset: Int64 = 100
        var snapshotLoads = 0
        var fdCalls = 0
        var winsizeCalls = 0
        var ipcCalls = 0
        var titleCalls = 0

        for sampleIndex in 1...4 {
            grokOffset += 1
            let result = resolveFocusGhostty(
                snapshot: snapshot,
                latch: &latch,
                appleScriptTTY: grokTTY,
                grokOffset: grokOffset,
                claudeOffset: 50,
                grokIO: Date(timeIntervalSince1970: TimeInterval(90 + grokOffset)),
                loadSnapshot: {
                    snapshotLoads += 1
                    return snapshot
                },
                fdCalled: { fdCalls += 1 },
                winsizeCalled: { winsizeCalls += 1 },
                ipcCalled: { ipcCalls += 1 },
                titleCalled: { titleCalls += 1 }
            )
            XCTAssertEqual(result.tty, grokTTY, "sample \(sampleIndex)")
            XCTAssertFalse(result.loadedSnapshot)
            XCTAssertFalse(result.probedSurface)
            XCTAssertEqual(
                ActivityClientSelection.preferredTerminalClient(
                    current: .claude,
                    frontmostTTY: result.tty,
                    grokTTYs: snapshot.grokTTYs,
                    claudeTTYs: snapshot.claudeTTYs
                ),
                .grok
            )
        }

        XCTAssertEqual(snapshotLoads, 0)
        XCTAssertEqual(fdCalls, 0)
        XCTAssertEqual(winsizeCalls, 0)
        XCTAssertEqual(ipcCalls, 0)
        XCTAssertEqual(titleCalls, 0)
    }

    func testPidMapsToUniqueGrokTTYUnderWindowWithoutSurfaceProbes() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        var snapshotLoads = 0
        var fdCalls = 0
        var winsizeCalls = 0
        let result = resolveFocusGhostty(
            snapshot: snapshot,
            latch: &latch,
            appleScriptPID: 200,
            grokOffset: 9_000,
            claudeOffset: 50,
            grokIO: Date(timeIntervalSince1970: 90),
            loadSnapshot: {
                snapshotLoads += 1
                return snapshot
            },
            fdCalled: { fdCalls += 1 },
            winsizeCalled: { winsizeCalls += 1 }
        )
        XCTAssertEqual(result.tty, grokTTY)
        XCTAssertTrue(result.loadedSnapshot)
        XCTAssertFalse(result.probedSurface)
        XCTAssertEqual(snapshotLoads, 1)
        XCTAssertEqual(fdCalls, 0)
        XCTAssertEqual(winsizeCalls, 0)
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .claude,
                frontmostTTY: result.tty,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            ),
            .grok
        )
    }

    func testMissingAppleScriptStillLatchesClaudeWhileGrokStreams() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        var latch = TerminalTTYFocusLatch()
        var grokOffset: Int64 = 100
        var snapshotLoads = 0
        func sample(claudeOffset: Int64) -> String? {
            grokOffset += 1
            let result = resolveFocusGhostty(
                snapshot: snapshot,
                latch: &latch,
                grokOffset: grokOffset,
                claudeOffset: claudeOffset,
                grokIO: Date(timeIntervalSince1970: TimeInterval(90 + grokOffset)),
                loadSnapshot: {
                    snapshotLoads += 1
                    return snapshot
                }
            )
            XCTAssertTrue(result.loadedSnapshot)
            XCTAssertTrue(result.probedSurface)
            return result.tty
        }

        _ = sample(claudeOffset: 50)
        _ = sample(claudeOffset: 50)
        _ = sample(claudeOffset: 50)
        let tty = sample(claudeOffset: 51)
        XCTAssertEqual(tty, claudeTTY)
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: tty,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            ),
            .claude
        )
        XCTAssertGreaterThanOrEqual(snapshotLoads, 4)
    }

    private func quietBoth(
        snapshot: TerminalCLIProcessSnapshot,
        latch: inout TerminalTTYFocusLatch,
        current: AssistantClient = .claude
    ) {
        for _ in 0..<3 {
            let tty = resolveGhostty(
                snapshot: snapshot,
                latch: &latch,
                grokOffset: 100,
                claudeOffset: 50
            )
            _ = ActivityClientSelection.preferredTerminalClient(
                current: current,
                frontmostTTY: tty,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs
            )
        }
    }

    private func resolveFocusGhostty(
        snapshot: TerminalCLIProcessSnapshot,
        latch: inout TerminalTTYFocusLatch,
        appleScriptTTY: String? = nil,
        appleScriptPID: Int32? = nil,
        grokOffset: Int64,
        claudeOffset: Int64,
        grokIO: Date? = nil,
        claudeIO: Date? = nil,
        grokWinsize: TerminalTTYWinsize? = nil,
        claudeWinsize: TerminalTTYWinsize? = nil,
        loadSnapshot: @escaping () -> TerminalCLIProcessSnapshot? = { nil },
        fdCalled: @escaping () -> Void = {},
        winsizeCalled: @escaping () -> Void = {},
        ipcCalled: @escaping () -> Void = {},
        titleCalled: @escaping () -> Void = {}
    ) -> (tty: String?, loadedSnapshot: Bool, probedSurface: Bool) {
        TerminalFrontmostTTY.resolveFocus(
            bundleIdentifier: "com.mitchellh.ghostty",
            terminalPID: 100,
            grokTTYs: snapshot.grokTTYs,
            claudeTTYs: snapshot.claudeTTYs,
            appleScriptTTY: appleScriptTTY,
            appleScriptPID: appleScriptPID,
            loadSnapshot: loadSnapshot,
            ttyIODate: { tty in
                if tty == self.grokTTY { return grokIO ?? self.quietIO }
                if tty == self.claudeTTY { return claudeIO ?? self.quietIO }
                return self.quietIO
            },
            ttyFDOffsets: {
                fdCalled()
                return [self.grokTTY: grokOffset, self.claudeTTY: claudeOffset]
            },
            ttyWinsize: { tty in
                winsizeCalled()
                if tty == self.grokTTY { return grokWinsize ?? self.defaultWinsize }
                if tty == self.claudeTTY { return claudeWinsize ?? self.defaultWinsize }
                return self.defaultWinsize
            },
            ipcTTY: {
                ipcCalled()
                return nil
            },
            windowTitle: {
                titleCalled()
                return nil
            },
            latch: &latch
        )
    }

    private func resolveGhostty(
        snapshot: TerminalCLIProcessSnapshot,
        latch: inout TerminalTTYFocusLatch,
        grokOffset: Int64,
        claudeOffset: Int64,
        grokIO: Date? = nil,
        claudeIO: Date? = nil,
        grokWinsize: TerminalTTYWinsize? = nil,
        claudeWinsize: TerminalTTYWinsize? = nil,
        ipcTTY: String? = nil,
        windowTitle: String? = nil,
        appleScriptTTY: String? = nil
    ) -> String? {
        TerminalFrontmostTTY.resolve(
            bundleIdentifier: "com.mitchellh.ghostty",
            terminalPID: 100,
            snapshot: snapshot,
            appleScriptTTY: appleScriptTTY,
            ttyIODate: { tty in
                if tty == grokTTY { return grokIO ?? quietIO }
                if tty == claudeTTY { return claudeIO ?? quietIO }
                return quietIO
            },
            ttyFDOffset: { tty in
                if tty == grokTTY { return grokOffset }
                if tty == claudeTTY { return claudeOffset }
                return nil
            },
            ttyWinsize: { tty in
                if tty == grokTTY { return grokWinsize ?? defaultWinsize }
                if tty == claudeTTY { return claudeWinsize ?? defaultWinsize }
                return defaultWinsize
            },
            ipcTTY: ipcTTY,
            windowTitle: windowTitle,
            latch: &latch
        )
    }
}
