import Foundation

/// The two `claude plugin` commands that install the Mod. BalanceBar never edits Claude's config files itself.
struct ModInstallPlan: Equatable {
    var marketplaceSource: String
    var pluginID: String
    var scope: String

    /// The published BalanceBar Mod (BB-14 / #525): plugin `balancebar-mod` from marketplace `balancebar-mods`.
    /// `marketplaceSource` is the public repository that hosts the marketplace; it only resolves once the
    /// marketplace is published there. Until then one-click install reports a failure and the panel falls back
    /// to the copyable commands. Development builds can point it at a checkout (see `resolved`).
    static let standard = ModInstallPlan(
        marketplaceSource: "huanmeng06/BalanceBar",
        pluginID: "balancebar-mod@balancebar-mods",
        scope: "user"
    )

    static let developmentSourceKey = "modOnboarding.marketplaceSource"
    static let developmentScopeKey = "modOnboarding.scope"

    /// The standard plan, or, for the development bundle only, one with the marketplace source (and optionally
    /// the scope) taken from user defaults, e.g.
    /// `defaults write com.huanmeng06.BalanceBar.dev modOnboarding.marketplaceSource "$PWD/mod"`.
    static func resolved(
        defaults: UserDefaults = .standard,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> ModInstallPlan {
        var plan = standard
        guard let bundleIdentifier, bundleIdentifier.hasPrefix("com.huanmeng06.BalanceBar.dev") else { return plan }
        if let source = defaults.string(forKey: developmentSourceKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !source.isEmpty {
            plan.marketplaceSource = source
        }
        if let scope = defaults.string(forKey: developmentScopeKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           ["user", "project", "local"].contains(scope) {
            plan.scope = scope
        }
        return plan
    }

    var marketplaceArguments: [String] { ["plugin", "marketplace", "add", marketplaceSource, "--scope", scope, "--json"] }
    var installArguments: [String] { ["plugin", "install", pluginID, "--scope", scope, "--json"] }

    /// Copy-paste fallback shown when the app cannot run the commands itself.
    var copyableCommands: String {
        "claude " + marketplaceArguments.joined(separator: " ") + "\n"
            + "claude " + installArguments.joined(separator: " ")
    }

    static let reloadCommand = "/reload-plugins"
}

enum ModInstallStep: Int, CaseIterable, Equatable {
    case addMarketplace
    case installPlugin
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
    case commandFailed(step: ModInstallStep, exitCode: Int32?, detail: String)

    var summary: String {
        switch self {
        case .claudeNotFound: return "claude not found"
        case let .commandFailed(step, code, detail):
            return "step \(step.rawValue + 1) failed (exit \(code.map(String.init) ?? "launch")): \(detail)"
        }
    }
}

enum ModInstallResult: Equatable {
    case success
    case failure(ModInstallFailure)
}

/// Runs the install commands on its own serial queue and reports progress and the result on `callbackQueue`.
final class ModInstaller {
    private let plan: ModInstallPlan
    private let locator: ClaudeExecutableLocating
    private let runner: ModCommandRunning
    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue

    init(
        plan: ModInstallPlan = .standard,
        locator: ClaudeExecutableLocating = DefaultClaudeExecutableLocator(),
        runner: ModCommandRunning = ProcessModCommandRunner(),
        workQueue: DispatchQueue = DispatchQueue(label: "balancebar.mod-installer", qos: .userInitiated),
        callbackQueue: DispatchQueue = .main
    ) {
        self.plan = plan
        self.locator = locator
        self.runner = runner
        self.workQueue = workQueue
        self.callbackQueue = callbackQueue
    }

    func install(progress: @escaping (ModInstallStep) -> Void, completion: @escaping (ModInstallResult) -> Void) {
        workQueue.async { [plan, locator, runner, callbackQueue] in
            func report(_ step: ModInstallStep) { callbackQueue.async { progress(step) } }
            func finish(_ result: ModInstallResult) { callbackQueue.async { completion(result) } }

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
