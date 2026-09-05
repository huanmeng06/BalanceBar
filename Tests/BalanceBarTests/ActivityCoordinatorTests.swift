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
                claudeProcessRunning: true,
                grokTrueTurnEvidence: true,
                claudeTrueTurnEvidence: true
            ),
            .codex
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .other,
                current: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: false,
                grokTrueTurnEvidence: true
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
                claudeTTYs: ["ttys002"],
                grokTrueTurnEvidence: true,
                claudeTrueTurnEvidence: false
            ),
            .claude
        )
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                frontmostTTY: "/dev/ttys002",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"],
                grokTrueTurnEvidence: true
            ),
            .claude
        )
    }

    func testFrontmostGrokTTYWinsEvenIfClaudeHasTrueTurnEvidence() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                frontmostTTY: "ttys001",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"],
                grokTrueTurnEvidence: false,
                claudeTrueTurnEvidence: true
            ),
            .grok
        )
    }

    func testNoTTYClaudeTrueTurnBeatsGrokFileActivity() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                grokTrueTurnEvidence: false,
                claudeTrueTurnEvidence: true
            ),
            .claude
        )
    }

    func testNoTTYWithoutUniqueTrueTurnKeepsCurrent() {
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
                claudeProcessRunning: true,
                grokTrueTurnEvidence: false,
                claudeTrueTurnEvidence: false
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
                claudeTTYs: ["ttys002"],
                grokTrueTurnEvidence: true,
                claudeTrueTurnEvidence: true
            ),
            .codex
        )
    }

    func testGrokSubagentTrueTurnDoesNotStealFocusedClaudeTTY() {
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .claude,
                frontmostTTY: "ttys002",
                grokTTYs: ["ttys001"],
                claudeTTYs: ["ttys002"],
                grokTrueTurnEvidence: true,
                claudeTrueTurnEvidence: false
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
                claudeTTYs: ["ttys002"],
                grokTrueTurnEvidence: true,
                claudeTrueTurnEvidence: false
            ),
            .grok
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
