import XCTest
@testable import BalanceBar

final class CurrentAgentOpenPlannerTests: XCTestCase {
    private let ghosttyPS = """
    100 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty ghostty
    200 100 ttys001 /bin/zsh zsh
    300 200 ttys001 /Users/dev/.grok/bin/grok grok
    400 100 ttys002 /bin/zsh zsh
    500 400 ttys002 /usr/local/bin/claude claude
    """

    func testCodexAlwaysOpensChatGPTWithoutReadingProcesses() {
        XCTAssertEqual(
            CurrentAgentOpenPlanner.action(
                client: .codex,
                snapshot: nil,
                runningApplicationPIDs: [100]
            ),
            .openChatGPT
        )
        XCTAssertEqual(
            CurrentAgentOpenPlanner.action(
                client: .codex,
                snapshot: TerminalCLIProcessSnapshot(psOutput: ghosttyPS),
                runningApplicationPIDs: [100]
            ),
            .openChatGPT
        )
    }

    func testGrokAndClaudeActivateOwningTerminalAndNeverOpenChatGPT() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: ghosttyPS)
        XCTAssertEqual(
            CurrentAgentOpenPlanner.action(
                client: .grok,
                snapshot: snapshot,
                runningApplicationPIDs: [100, 999],
                excludedApplicationPIDs: [999]
            ),
            .activateApplication(pid: 100)
        )
        XCTAssertEqual(
            CurrentAgentOpenPlanner.action(
                client: .claude,
                snapshot: snapshot,
                runningApplicationPIDs: [100, 999],
                excludedApplicationPIDs: [999]
            ),
            .activateApplication(pid: 100)
        )
    }

    func testMissingCLIDoesNotFallBackToChatGPT() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: ghosttyPS)
        XCTAssertEqual(
            CurrentAgentOpenPlanner.action(
                client: .grok,
                snapshot: nil,
                runningApplicationPIDs: [100]
            ),
            .noOp(reason: "process-snapshot-unavailable")
        )
        XCTAssertEqual(
            CurrentAgentOpenPlanner.action(
                client: .claude,
                snapshot: TerminalCLIProcessSnapshot(
                    psOutput: """
                    100 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty ghostty
                    200 100 ttys001 /bin/zsh zsh
                    300 200 ttys001 /Users/dev/.grok/bin/grok grok
                    """
                ),
                runningApplicationPIDs: [100]
            ),
            .noOp(reason: "cli-process-missing")
        )
        XCTAssertEqual(
            CurrentAgentOpenPlanner.action(
                client: .grok,
                snapshot: snapshot,
                runningApplicationPIDs: [],
                excludedApplicationPIDs: [100]
            ),
            .noOp(reason: "terminal-application-missing")
        )
    }

    func testChatGPTAndBalanceBarPIDsAreNotTreatedAsTheTerminal() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: ghosttyPS)
        XCTAssertEqual(
            CurrentAgentOpenPlanner.action(
                client: .grok,
                snapshot: snapshot,
                runningApplicationPIDs: [100, 42],
                excludedApplicationPIDs: [100, 42]
            ),
            .noOp(reason: "terminal-application-missing")
        )
    }

    func testOpenerRoutesCodexToChatGPTAndTerminalClientsToActivation() {
        let snapshot = TerminalCLIProcessSnapshot(psOutput: ghosttyPS)
        var chatGPTOpens = 0
        var activated: [Int32] = []
        let opener = CurrentAgentOpener(
            loadSnapshot: { snapshot },
            runningApplicationPIDs: { [100] },
            excludedApplicationPIDs: { [42] },
            openChatGPT: { chatGPTOpens += 1 },
            activateApplication: { pid in
                activated.append(pid)
                return true
            }
        )

        opener.open(client: .codex)
        XCTAssertEqual(chatGPTOpens, 1)
        XCTAssertEqual(activated, [])

        opener.open(client: .grok)
        opener.open(client: .claude)
        XCTAssertEqual(chatGPTOpens, 1, "Grok/Claude must not open ChatGPT.app")
        XCTAssertEqual(activated, [100, 100])
    }

    func testOpenerDoesNotOpenChatGPTWhenTheCLIHasExited() {
        var chatGPTOpens = 0
        var activated: [Int32] = []
        let opener = CurrentAgentOpener(
            loadSnapshot: {
                TerminalCLIProcessSnapshot(
                    psOutput: """
                    100 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty ghostty
                    """
                )
            },
            runningApplicationPIDs: { [100] },
            excludedApplicationPIDs: { [] },
            openChatGPT: { chatGPTOpens += 1 },
            activateApplication: { pid in
                activated.append(pid)
                return true
            }
        )

        opener.open(client: .grok)
        opener.open(client: .claude)
        XCTAssertEqual(chatGPTOpens, 0)
        XCTAssertEqual(activated, [])
    }
}
