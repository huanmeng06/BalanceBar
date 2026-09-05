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
                claudeProcessRunning: false,
                grokLastActivityAt: nil,
                claudeLastActivityAt: nil
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
                claudeProcessRunning: true,
                grokLastActivityAt: nil,
                claudeLastActivityAt: nil
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
                grokLastActivityAt: Date(timeIntervalSince1970: 20),
                claudeLastActivityAt: Date(timeIntervalSince1970: 10)
            ),
            .codex
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .other,
                current: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: false,
                grokLastActivityAt: Date(timeIntervalSince1970: 20),
                claudeLastActivityAt: nil
            ),
            .codex
        )
    }

    func testBothTerminalProcessesPreferLatestActivity() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                grokLastActivityAt: Date(timeIntervalSince1970: 30),
                claudeLastActivityAt: Date(timeIntervalSince1970: 10)
            ),
            .grok
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                grokLastActivityAt: Date(timeIntervalSince1970: 10),
                claudeLastActivityAt: Date(timeIntervalSince1970: 30)
            ),
            .claude
        )
    }

    func testBothProcessesPreferCurrentlyActiveClaudeEvenIfGrokFilesAreNewer() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                grokLastActivityAt: Date(timeIntervalSince1970: 50),
                claudeLastActivityAt: Date(timeIntervalSince1970: 10),
                grokObservation: .hardTerminal,
                claudeObservation: .active
            ),
            .claude
        )
        XCTAssertEqual(
            ActivityClientSelection.preferredTerminalClient(
                current: .grok,
                grokLastActivityAt: Date(timeIntervalSince1970: 50),
                claudeLastActivityAt: Date(timeIntervalSince1970: 10),
                grokObservation: .ambiguousIdle,
                claudeObservation: .active
            ),
            .claude
        )
    }

    func testWasGrokThenClaudeBecomesActiveSwitchesIdentity() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                grokLastActivityAt: Date(timeIntervalSince1970: 40),
                claudeLastActivityAt: Date(timeIntervalSince1970: 41),
                grokObservation: .hardTerminal,
                claudeObservation: .active
            ),
            .claude
        )
    }

    func testActiveGrokIsNotBlindlyReplacedByIdleClaude() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                grokLastActivityAt: Date(timeIntervalSince1970: 10),
                claudeLastActivityAt: Date(timeIntervalSince1970: 50),
                grokObservation: .active,
                claudeObservation: .hardTerminal
            ),
            .grok
        )
    }

    func testCodexFrontmostIsNotStolenByBackgroundGrokOrClaude() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .codex,
                current: .codex,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                grokLastActivityAt: Date(timeIntervalSince1970: 80),
                claudeLastActivityAt: Date(timeIntervalSince1970: 90),
                grokObservation: .active,
                claudeObservation: .active
            ),
            .codex
        )
    }

    func testIndistinguishableBothProcessesKeepCurrentTerminalClient() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                grokLastActivityAt: nil,
                claudeLastActivityAt: nil
            ),
            .grok
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .claude,
                grokProcessRunning: true,
                claudeProcessRunning: true,
                grokLastActivityAt: Date(timeIntervalSince1970: 10),
                claudeLastActivityAt: Date(timeIntervalSince1970: 10)
            ),
            .claude
        )
    }

    func testGrokExitWhileTerminalFrontmostFallsBackToClaudeOrCodex() {
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: false,
                claudeProcessRunning: true,
                grokLastActivityAt: nil,
                claudeLastActivityAt: Date(timeIntervalSince1970: 10)
            ),
            .claude
        )
        XCTAssertEqual(
            ActivityClientSelection.client(
                frontmost: .terminal,
                current: .grok,
                grokProcessRunning: false,
                claudeProcessRunning: false,
                grokLastActivityAt: nil,
                claudeLastActivityAt: nil
            ),
            .codex
        )
    }
}
