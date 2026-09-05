import Foundation
import XCTest
@testable import BalanceBar

final class ActivityCoordinatorTests: XCTestCase {
    func testTerminalWithOnlyGrokSelectsGrok() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: false
            ),
            .grok
        )
    }

    func testTerminalWithOnlyClaudeKeepsClaude() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .codex,
                grokProcessRunning: false,
                claudeProcessRunning: true
            ),
            .claude
        )
    }

    func testBackgroundProcessesDoNotStealCodex() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .codex,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true
            ),
            .codex
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .other,
                current: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: false
            ),
            .codex
        )
    }

    func testFrontmostClaudeTTYWinsEvenIfGrokIsActiveAndCurrentIsGrok() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: "ttys002",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .claude
        )
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: "/dev/ttys002",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .claude
        )
    }

    func testFrontmostGrokTTYWinsWithoutTrueTurnEvidence() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .grok
        )
    }

    func testNoTTYKeepsCurrentWhenBothCLIsAreAlive() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true
            ),
            .grok
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true
            ),
            .claude
        )
    }

    func testCodexFrontmostIsNotStolenByBackgroundGrokOrClaude() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .codex,
                current: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .codex
        )
    }

    func testGrokSubagentDoesNotStealFocusedClaudeTTY() {
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .claude,
                frontmostTTY: "ttys002",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .claude
        )
    }

    func testGrokIdentityStillFollowsGrokTTYWhileSubagentIsActive() {
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .grok
        )
    }

    func testProcessCacheTTYSetsClassifyIdentityWithoutSessionScan() {
        XCTAssertEqual(
            TerminalFrontmostTTY.uniquelyClassifiedTTY(
                "/dev/ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            "ttys001"
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .grok
        )
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .claude,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"]
            ),
            .grok
        )
        XCTAssertNil(
            TerminalFrontmostTTY.uniquelyClassifiedTTY(
                "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys001"]
            )
        )
    }

    func testImmediateTerminalClientWaitsWhenBothExist() {
        XCTAssertEqual(
            ActivityClientSelection.immediateTerminalClient(
                grokProcessRunning: true,
                claudeProcessRunning: false
            ),
            .grok
        )
        XCTAssertEqual(
            ActivityClientSelection.immediateTerminalClient(
                grokProcessRunning: false,
                claudeProcessRunning: true
            ),
            .claude
        )
        XCTAssertNil(
            ActivityClientSelection.immediateTerminalClient(
                grokProcessRunning: true,
                claudeProcessRunning: true
            )
        )
        XCTAssertNil(
            ActivityClientSelection.immediateTerminalClient(
                grokProcessRunning: false,
                claudeProcessRunning: false
            )
        )
    }

    func testGrokExitWhileTerminalFrontmostFallsBackToClaudeOrCodex() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: false,
                claudeProcessRunning: true
            ),
            .claude
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: false,
                claudeProcessRunning: false
            ),
            .codex
        )
    }
}
