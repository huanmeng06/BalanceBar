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

    func testAppleScriptSourceExistsOnlyForTerminalAndITerm() {
        XCTAssertNotNil(TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.apple.Terminal"))
        XCTAssertNotNil(TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.googlecode.iterm2"))
        XCTAssertNil(TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.mitchellh.ghostty"))
        XCTAssertNil(TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "dev.warp.warp-stable"))
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
