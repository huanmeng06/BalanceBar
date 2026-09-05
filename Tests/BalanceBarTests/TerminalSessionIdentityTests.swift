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

    func testAppleScriptTTYIsPreferredOverNewerGrokIO() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        let tty = TerminalFrontmostTTY.resolve(
            bundleIdentifier: "com.apple.Terminal",
            terminalPID: 100,
            snapshot: snapshot,
            appleScriptTTY: "/dev/ttys002",
            ttyIODate: { tty in
                tty == "ttys001"
                    ? Date(timeIntervalSince1970: 50)
                    : Date(timeIntervalSince1970: 10)
            }
        )
        XCTAssertEqual(tty, "ttys002")
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: tty,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs,
                grokTrueTurnEvidence: true
            ),
            .claude
        )
    }

    func testSingleCLIUnderFrontmostTerminalIsUsedWithoutAppleScript() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        let tty = TerminalFrontmostTTY.resolve(
            bundleIdentifier: "com.mitchellh.ghostty",
            terminalPID: 600,
            snapshot: snapshot,
            appleScriptTTY: nil,
            ttyIODate: { _ in Date(timeIntervalSince1970: 1) }
        )
        XCTAssertEqual(tty, "ttys003")
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: tty,
                grokTTYs: snapshot.grokTTYs,
                claudeTTYs: snapshot.claudeTTYs,
                grokTrueTurnEvidence: true
            ),
            .claude
        )
    }

    func testLatestTTYIOBreaksTiesAmongCLIsInTheSameTerminal() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: psOutput)
        let tty = TerminalFrontmostTTY.resolve(
            bundleIdentifier: "com.mitchellh.ghostty",
            terminalPID: 100,
            snapshot: snapshot,
            appleScriptTTY: nil,
            ttyIODate: { tty in
                tty == "ttys002"
                    ? Date(timeIntervalSince1970: 80)
                    : Date(timeIntervalSince1970: 20)
            }
        )
        XCTAssertEqual(tty, "ttys002")
    }

    func testAppleScriptSourceExistsOnlyForTerminalAndITerm() {
        XCTAssertNotNil(TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.apple.Terminal"))
        XCTAssertNotNil(TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.googlecode.iterm2"))
        XCTAssertNil(TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "com.mitchellh.ghostty"))
        XCTAssertNil(TerminalFrontmostTTY.appleScriptSource(bundleIdentifier: "dev.warp.warp-stable"))
    }
}
