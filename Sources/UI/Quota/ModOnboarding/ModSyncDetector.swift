import Darwin
import Foundation

/// Gathers the read-only environment facts for the Mod sync status. Every probe
/// (executables, files, `claude` commands) runs on `workQueue`; the completion is
/// delivered once on `callbackQueue`. Nothing here installs, removes or writes
/// configuration — detection only reads.
final class ModSyncDetector {
    private let plan: ModInstallPlan
    private let locator: ClaudeExecutableLocating
    private let runner: ModCommandRunning
    private let inboxDirectory: URL
    private let fileManager: FileManager
    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue

    init(
        plan: ModInstallPlan = .standard,
        locator: ClaudeExecutableLocating = DefaultClaudeExecutableLocator(),
        runner: ModCommandRunning = ProcessModCommandRunner(),
        inboxDirectory: URL = SnapshotInbox.defaultInboxDirectory(),
        fileManager: FileManager = .default,
        workQueue: DispatchQueue = DispatchQueue(label: "balancebar.mod-sync-detector", qos: .utility),
        callbackQueue: DispatchQueue = .main
    ) {
        self.plan = plan
        self.locator = locator
        self.runner = runner
        self.inboxDirectory = inboxDirectory
        self.fileManager = fileManager
        self.workQueue = workQueue
        self.callbackQueue = callbackQueue
    }

    /// - Parameter claudeProcessRunning: sampled by the caller on the main thread so the
    ///   activity coordinator's state is read where it is written.
    func detect(claudeProcessRunning: Bool, completion: @escaping (ModEnvironment) -> Void) {
        workQueue.async { [plan, locator, runner, inboxDirectory, fileManager, callbackQueue] in
            var environment = ModEnvironment(
                claudeFound: false, claudeVersion: nil, installation: nil,
                hasNonUserScopeInstall: false, inboxReady: false, claudeProcessRunning: claudeProcessRunning)
            environment.inboxReady = Self.isInboxReady(directory: inboxDirectory, fileManager: fileManager)
            guard let claudePath = locator.locate() else {
                return callbackQueue.async { completion(environment) }
            }
            environment.claudeFound = true
            if let versionResult = runner.run(executablePath: claudePath, arguments: ModInstallPlan.versionArguments) {
                environment.claudeVersion = versionResult.exitCode == 0
                    ? ClaudeCodeVersion.parse(versionResult.stdout)
                    : nil
            }
            if let listResult = runner.run(executablePath: claudePath, arguments: ModInstallPlan.listArguments),
               listResult.exitCode == 0, let data = listResult.stdout.data(using: .utf8) {
                let parsed = Self.parsePluginList(data, plan: plan)
                environment.installation = parsed.installation
                environment.hasNonUserScopeInstall = parsed.hasNonUserScopeInstall
            }
            callbackQueue.async { completion(environment) }
        }
    }

    // MARK: Pure helpers (unit tested)

    /// The inbox directory exists, is writable and belongs to the current user — the same
    /// ownership rule `SnapshotInbox` applies before it touches the directory.
    static func isInboxReady(directory: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        guard fileManager.isWritableFile(atPath: directory.path) else { return false }
        guard let owner = (try? fileManager.attributesOfItem(atPath: directory.path)[.ownerAccountID]) as? NSNumber
        else { return false }
        return owner.uint32Value == getuid()
    }

    /// Creates the default inbox with current-user-only permissions when missing; never
    /// modifies a directory it does not own. Returns whether the directory is usable after.
    static func prepareInbox(directory: URL, fileManager: FileManager = .default) -> Bool {
        if isInboxReady(directory: directory, fileManager: fileManager) { return true }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            // Exists but is not a usable directory (wrong owner, a file, unwritable):
            // report it instead of touching something BalanceBar does not own.
            return false
        }
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch { return false }
        return isInboxReady(directory: directory, fileManager: fileManager)
    }

    /// Parses `claude plugin list --json`. Only an entry whose id and scope both match the
    /// plan counts as the managed installation; entries in other scopes are reported
    /// separately so a project/local install is never shown as the global one.
    static func parsePluginList(
        _ data: Data, plan: ModInstallPlan
    ) -> (installation: ModPluginInstallation?, hasNonUserScopeInstall: Bool) {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return (nil, false)
        }
        var installation: ModPluginInstallation?
        var hasNonUserScopeInstall = false
        for entry in entries where (entry["id"] as? String) == plan.pluginID {
            let scope = (entry["scope"] as? String) ?? ""
            guard scope == plan.scope else {
                hasNonUserScopeInstall = true
                continue
            }
            installation = ModPluginInstallation(
                scope: scope,
                isEnabled: (entry["enabled"] as? Bool) ?? false,
                version: entry["version"] as? String,
                installedAt: (entry["installedAt"] as? String).flatMap(Self.parseTimestamp))
        }
        return (installation, hasNonUserScopeInstall)
    }

    static func parseTimestamp(_ text: String) -> Date? {
        if let date = Self.fractionalSecondsFormatter.date(from: text) { return date }
        return Self.secondsFormatter.date(from: text)
    }

    private static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let secondsFormatter = ISO8601DateFormatter()
}
