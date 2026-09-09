import AppKit
import Foundation

enum CurrentAgentOpenAction: Equatable {
    case openChatGPT
    case activateApplication(pid: Int32)
    case noOp(reason: String)
}

/// Pure routing for the status-menu “open current agent” item. Codex keeps
/// the ChatGPT.app launch. Grok/Claude activate the terminal that owns the
/// live CLI process and never fall back to ChatGPT.
enum CurrentAgentOpenPlanner {
    static func action(
        client: AssistantClient,
        snapshot: TerminalCLIProcessSnapshot?,
        runningApplicationPIDs: Set<Int32>,
        excludedApplicationPIDs: Set<Int32> = []
    ) -> CurrentAgentOpenAction {
        switch client {
        case .codex:
            return .openChatGPT
        case .grok, .claude:
            guard let snapshot else {
                return .noOp(reason: "process-snapshot-unavailable")
            }
            let records = client == .grok ? snapshot.grok : snapshot.claude
            guard !records.isEmpty else {
                return .noOp(reason: "cli-process-missing")
            }
            var seen = Set<Int32>()
            var candidates: [Int32] = []
            for record in records {
                guard let pid = owningApplicationPID(
                    startingAt: record.pid,
                    parentByPID: snapshot.parentByPID,
                    runningApplicationPIDs: runningApplicationPIDs,
                    excludedApplicationPIDs: excludedApplicationPIDs
                ), seen.insert(pid).inserted else {
                    continue
                }
                candidates.append(pid)
            }
            guard let pid = candidates.first else {
                return .noOp(reason: "terminal-application-missing")
            }
            return .activateApplication(pid: pid)
        }
    }

    static func owningApplicationPID(
        startingAt startPID: Int32,
        parentByPID: [Int32: Int32],
        runningApplicationPIDs: Set<Int32>,
        excludedApplicationPIDs: Set<Int32>
    ) -> Int32? {
        var current = startPID
        var seen = Set<Int32>()
        while current > 0, seen.insert(current).inserted {
            if current != startPID,
               runningApplicationPIDs.contains(current),
               !excludedApplicationPIDs.contains(current) {
                return current
            }
            guard let parent = parentByPID[current], parent != current else {
                return nil
            }
            current = parent
        }
        return nil
    }
}

struct CurrentAgentOpener {
    var loadSnapshot: () -> TerminalCLIProcessSnapshot?
    var runningApplicationPIDs: () -> Set<Int32>
    var excludedApplicationPIDs: () -> Set<Int32>
    var openChatGPT: () -> Void
    var activateApplication: (Int32) -> Bool

    static func live(openChatGPT: @escaping () -> Void) -> CurrentAgentOpener {
        CurrentAgentOpener(
            loadSnapshot: { TerminalCLIProcessSnapshot.load() },
            runningApplicationPIDs: {
                Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            },
            excludedApplicationPIDs: {
                var pids: Set<Int32> = [ProcessInfo.processInfo.processIdentifier]
                for app in NSWorkspace.shared.runningApplications
                where ChatGPTApplicationIdentity.matches(bundleIdentifier: app.bundleIdentifier) {
                    pids.insert(app.processIdentifier)
                }
                return pids
            },
            openChatGPT: openChatGPT,
            activateApplication: { pid in
                NSRunningApplication(processIdentifier: pid)?.activate() ?? false
            }
        )
    }

    func open(client: AssistantClient) {
        let action = CurrentAgentOpenPlanner.action(
            client: client,
            snapshot: client == .codex ? nil : loadSnapshot(),
            runningApplicationPIDs: client == .codex ? [] : runningApplicationPIDs(),
            excludedApplicationPIDs: client == .codex ? [] : excludedApplicationPIDs()
        )
        switch action {
        case .openChatGPT:
            openChatGPT()
        case .activateApplication(let pid):
            if activateApplication(pid) {
                SwitchLog.write(
                    "opened current agent terminal; client=\(client.rawValue); pid=\(pid)",
                    category: "ui.menu"
                )
            } else {
                SwitchLog.write(
                    "open current agent terminal failed; client=\(client.rawValue); pid=\(pid)",
                    level: .warning,
                    category: "ui.menu"
                )
            }
        case .noOp(let reason):
            SwitchLog.write(
                "open current agent skipped; client=\(client.rawValue); reason=\(reason)",
                level: .warning,
                category: "ui.menu"
            )
        }
    }
}
