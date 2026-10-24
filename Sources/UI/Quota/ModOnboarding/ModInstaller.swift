import Foundation

/// The two `claude plugin` commands that install the Mod. BalanceBar never edits Claude's config files itself.
struct ModInstallPlan: Equatable {
    var marketplaceSource: String
    var pluginID: String
    var scope: String

    /// The marketplace manifest lives at the repository root (`.claude-plugin/marketplace.json`,
    /// plugin source `./mod`) so `claude plugin marketplace add huanmeng06/BalanceBar` can
    /// discover it; the plugin id matches the marketplace name declared there.
    static let standard = ModInstallPlan(
        marketplaceSource: "huanmeng06/BalanceBar",
        pluginID: "balancebar-mod@balancebar-mods",
        scope: "user"
    )

    var marketplaceArguments: [String] { ["plugin", "marketplace", "add", marketplaceSource, "--scope", scope, "--json"] }
    var installArguments: [String] { ["plugin", "install", pluginID, "--scope", scope, "--json"] }

    /// Uninstalling only touches this plugin's own user-scope registration and the
    /// marketplace entry the install flow created — both explicitly scoped, never
    /// another plugin or an unscoped marketplace removal.
    var uninstallArguments: [String] { ["plugin", "uninstall", pluginID, "--scope", scope, "--json"] }
    var removeMarketplaceArguments: [String] { ["plugin", "marketplace", "remove", marketplaceName, "--scope", scope, "--json"] }
    /// Re-enabling is offered as a copy-paste fallback for the "installed but disabled" state.
    var enableArguments: [String] { ["plugin", "enable", pluginID, "--scope", scope, "--json"] }
    static let versionArguments: [String] = ["--version"]
    static let listArguments: [String] = ["plugin", "list", "--json"]

    /// The marketplace name is the id's suffix: `plugin@marketplace`.
    var marketplaceName: String {
        pluginID.split(separator: "@").last.map(String.init) ?? pluginID
    }

    /// Copy-paste fallback shown when the app cannot run the commands itself.
    var copyableCommands: String {
        "claude " + marketplaceArguments.joined(separator: " ") + "\n"
            + "claude " + installArguments.joined(separator: " ")
    }

    var copyableUninstallCommands: String {
        "claude " + uninstallArguments.joined(separator: " ") + "\n"
            + "claude " + removeMarketplaceArguments.joined(separator: " ")
    }

    var copyableEnableCommand: String {
        "claude " + enableArguments.joined(separator: " ")
    }

    static let reloadCommand = "/reload-plugins"
}

enum ModInstallStep: Int, CaseIterable, Equatable {
    case addMarketplace
    case installPlugin
    case finish
}

/// The uninstall flow's steps: remove the plugin, then the marketplace entry the
/// install flow created. The marketplace removal is best-effort; a failure there is
/// reported but the plugin itself is already gone.
enum ModUninstallStep: Int, CaseIterable, Equatable {
    case uninstallPlugin
    case removeMarketplace
    case finish
}

struct ModCommandResult: Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

protocol ModCommandRunning {
    /// Blocking; called off the main thread. Returns nil when the process could not be launched.
    func run(executablePath: String, arguments: [String]) -> ModCommandResult?
}

protocol ClaudeExecutableLocating {
    /// Blocking file-system probe; called off the main thread.
    func locate() -> String?
}

enum ModInstallFailure: Equatable {
    case claudeNotFound
    /// The default snapshot inbox could not be prepared before the install; the Mod
    /// never creates it itself, so installing without it would stay silent.
    case inboxNotReady
    case commandFailed(step: ModInstallStep, exitCode: Int32?, detail: String)

    var summary: String {
        switch self {
        case .claudeNotFound: return "claude not found"
        case .inboxNotReady: return "inbox not ready"
        case let .commandFailed(step, code, detail):
            return "step \(step.rawValue + 1) failed (exit \(code.map(String.init) ?? "launch")): \(detail)"
        }
    }
}

enum ModInstallResult: Equatable {
    case success
    case failure(ModInstallFailure)
}

enum ModUninstallFailure: Equatable {
    case claudeNotFound
    case commandFailed(step: ModUninstallStep, exitCode: Int32?, detail: String)
}

enum ModUninstallResult: Equatable {
    case success
    case failure(ModUninstallFailure)
}

/// Runs the install commands on its own serial queue and reports progress and the result on `callbackQueue`.
final class ModInstaller {
    private let plan: ModInstallPlan
    private let locator: ClaudeExecutableLocating
    private let runner: ModCommandRunning
    /// Prepares the default snapshot inbox before the install (the Mod never creates
    /// directories itself). Runs on `workQueue`, off the main thread.
    private let prepareInbox: () -> Bool
    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue

    init(
        plan: ModInstallPlan = .standard,
        locator: ClaudeExecutableLocating = DefaultClaudeExecutableLocator(),
        runner: ModCommandRunning = ProcessModCommandRunner(),
        prepareInbox: @escaping () -> Bool = { ModSyncDetector.prepareInbox(directory: SnapshotInbox.defaultInboxDirectory()) },
        workQueue: DispatchQueue = DispatchQueue(label: "balancebar.mod-installer", qos: .userInitiated),
        callbackQueue: DispatchQueue = .main
    ) {
        self.plan = plan
        self.locator = locator
        self.runner = runner
        self.prepareInbox = prepareInbox
        self.workQueue = workQueue
        self.callbackQueue = callbackQueue
    }

    func install(progress: @escaping (ModInstallStep) -> Void, completion: @escaping (ModInstallResult) -> Void) {
        workQueue.async { [plan, locator, runner, prepareInbox, callbackQueue] in
            func report(_ step: ModInstallStep) { callbackQueue.async { progress(step) } }
            func finish(_ result: ModInstallResult) { callbackQueue.async { completion(result) } }

            // The Mod writes only into an existing directory, so the inbox must exist
            // before the plugin can ever deliver a snapshot.
            guard prepareInbox() else { return finish(.failure(.inboxNotReady)) }
            guard let path = locator.locate() else { return finish(.failure(.claudeNotFound)) }
            let steps: [(ModInstallStep, [String])] = [
                (.addMarketplace, plan.marketplaceArguments),
                (.installPlugin, plan.installArguments),
            ]
            for (step, arguments) in steps {
                report(step)
                guard let result = runner.run(executablePath: path, arguments: arguments) else {
                    return finish(.failure(.commandFailed(step: step, exitCode: nil, detail: "launch failed")))
                }
                if let failure = Self.failure(for: result, step: step) { return finish(.failure(failure)) }
            }
            report(.finish)
            finish(.success)
        }
    }

    /// Uninstalls this plugin's user-scope registration, then removes the marketplace
    /// entry the install flow created. The marketplace removal is best-effort: the
    /// plugin being gone is the outcome that counts, and a leftover empty marketplace
    /// declaration is BalanceBar's own entry, not another plugin's.
    func uninstall(progress: @escaping (ModUninstallStep) -> Void, completion: @escaping (ModUninstallResult) -> Void) {
        workQueue.async { [plan, locator, runner, callbackQueue] in
            func report(_ step: ModUninstallStep) { callbackQueue.async { progress(step) } }
            func finish(_ result: ModUninstallResult) { callbackQueue.async { completion(result) } }

            guard let path = locator.locate() else { return finish(.failure(.claudeNotFound)) }
            let steps: [(ModUninstallStep, [String])] = [
                (.uninstallPlugin, plan.uninstallArguments),
                (.removeMarketplace, plan.removeMarketplaceArguments),
            ]
            for (step, arguments) in steps {
                report(step)
                guard let result = runner.run(executablePath: path, arguments: arguments) else {
                    if step == .uninstallPlugin {
                        return finish(.failure(.commandFailed(step: step, exitCode: nil, detail: "launch failed")))
                    }
                    continue
                }
                if let failure = Self.failure(for: result, step: step) {
                    if step == .uninstallPlugin { return finish(.failure(failure)) }
                    continue
                }
            }
            report(.finish)
            finish(.success)
        }
    }

    /// Exit code must be 0, and a JSON `outcome` (when present) must be "ok".
    static func failure(for result: ModCommandResult, step: ModInstallStep) -> ModInstallFailure? {
        if result.exitCode != 0 {
            return .commandFailed(step: step, exitCode: result.exitCode, detail: summarize(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        if let data = result.stdout.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let outcome = object["outcome"] as? String, outcome != "ok" {
            return .commandFailed(step: step, exitCode: result.exitCode, detail: "outcome=\(outcome)")
        }
        return nil
    }

    /// Same contract as the install mapper, for the uninstall steps.
    static func failure(for result: ModCommandResult, step: ModUninstallStep) -> ModUninstallFailure? {
        if result.exitCode != 0 {
            return .commandFailed(step: step, exitCode: result.exitCode, detail: summarize(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        if let data = result.stdout.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let outcome = object["outcome"] as? String, outcome != "ok" {
            return .commandFailed(step: step, exitCode: result.exitCode, detail: "outcome=\(outcome)")
        }
        return nil
    }

    private static func summarize(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}

/// Looks for `claude` on PATH, then in the usual install locations. Injectable for tests.
struct DefaultClaudeExecutableLocator: ClaudeExecutableLocating {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: String = NSHomeDirectory()
    var isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    func locate() -> String? {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [
            homeDirectory + "/.claude/local", homeDirectory + "/.local/bin",
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
        for directory in directories where !directory.isEmpty {
            let candidate = directory + "/claude"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}

private final class DataBox { var data = Data() }

/// Runs a command with `Process`, bounded by a timeout.
struct ProcessModCommandRunner: ModCommandRunning {
    var timeout: TimeInterval = 120

    func run(executablePath: String, arguments: [String]) -> ModCommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return ModCommandResult(exitCode: -1, stdout: "", stderr: "timed out")
        }
        group.wait()
        return ModCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }
}
