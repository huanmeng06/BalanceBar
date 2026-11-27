import AppKit
import CoreGraphics

final class AutomaticUpdateCoordinator {
    static let idleThreshold: TimeInterval = 10 * 60
    private let preferences: AppPreferences
    private let updateService: UpdateService
    private let verifier: UpdateSignatureVerifier
    private var preparingVersion: AppSemanticVersion?
    private var preparingChannel: UpdateChannel?
    private let idleThreshold: TimeInterval
    private let secondsSinceInput: () -> TimeInterval
    private var idleTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sleeping = false
    private var sessionInactive = false
    private var shuttingDown = false

    init(
        preferences: AppPreferences,
        updateService: UpdateService,
        verifier: UpdateSignatureVerifier = UpdateSignatureVerifier(),
        idleThreshold: TimeInterval = AutomaticUpdateCoordinator.configuredIdleThreshold(),
        secondsSinceInput: @escaping () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: UInt32.max)!)
        }
    ) {
        self.preferences = preferences
        self.updateService = updateService
        self.verifier = verifier
        self.idleThreshold = idleThreshold
        self.secondsSinceInput = secondsSinceInput
    }

    static func configuredIdleThreshold(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        if let bundleIdentifier, UpdateSignatureVerifier.isDevelopmentBundleIdentifier(bundleIdentifier),
           let value = environment["BALANCEBAR_UPDATE_IDLE_SECONDS"].flatMap(Double.init),
           value.isFinite, value >= 30 {
            return value
        }
        return idleThreshold
    }

    func start(onIdle: @escaping () -> Void) {
        updateService.removeInstalledUpdateCaches()
        updateCheckChanged(updateService.state)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.sleeping = true },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.sleeping = false },
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.sessionInactive = true },
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.sessionInactive = false },
            center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in self?.shuttingDown = true }
        ]
        let timer = Timer(timeInterval: 5, repeats: true) { _ in onIdle() }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
    }

    func idleRequest(interfaceInUse: Bool) -> AutomaticUpdateInstallationRequest? {
        guard !interfaceInUse, !sleeping, !sessionInactive, !shuttingDown,
              let request = quitRequest(),
              !AutomaticUpdateCommand.idleAttemptFailed(for: request),
              secondsSinceInput() >= idleThreshold else { return nil }
        return request
    }

    func quitRequest() -> AutomaticUpdateInstallationRequest? {
        guard preferences.permitsAutomaticInstallation(for: preferences.updateChannel), verifier.hasTrustedKeys else { return nil }
        return updateService.automaticUpdateInstallationRequest
    }

    func setDownloadEnabled(_ enabled: Bool) {
        let channel = preferences.updateChannel
        preferences.setAutomaticDownloadEnabled(enabled, for: channel)
        guard enabled else {
            preparingVersion = nil
            updateService.automaticUpdatesWereDisabled()
            return
        }
        updateCheckChanged(updateService.state)
    }

    func updateCheckChanged(_ state: UpdateCheckState) {
        let channel = preferences.updateChannel
        guard preferences.automaticDownloadEnabled(for: channel),
              verifier.hasTrustedKeys else { return }
        let version: AppSemanticVersion
        switch state {
        case .available(_, let latest), .recheckFailed(_, let latest, _):
            version = latest
        case .idle, .latest:
            preparingVersion = nil
            return
        default:
            return
        }
        guard preparingVersion != version || preparingChannel != channel else { return }
        preparingVersion = version
        preparingChannel = channel
        updateService.prepareAutomaticUpdate(verifier: verifier) { [weak self] _ in
            guard let self, self.preparingVersion == version, self.preparingChannel == channel else { return }
            self.preparingVersion = nil
        }
    }
}

struct AutomaticUpdateInstallationRequest {
    let diskImageURL: URL
    let applicationURL: URL
    let expectedVersion: String
    let channel: UpdateChannel
    let processIdentifier: Int32
}

enum AutomaticUpdateCommand {
    static var isBackgroundRelaunch: Bool {
        CommandLine.arguments.contains("--automatic-update-relaunch")
    }
    private struct CacheContext: Codable {
        let applicationPath: String
        let channel: String
    }

    private struct Transaction: Codable {
        var stage: String
        var applicationPath: String
        var backupPath: String
        var version: String
        var launchAttempted: Bool
        var idle: Bool? = nil
        var launchedAt: Date? = nil
        var noticeRead: Bool? = nil
    }

    static func launch(_ request: AutomaticUpdateInstallationRequest, relaunch: Bool = false) throws {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.huanmeng06.BalanceBar.app"
        let root = support.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updater", isDirectory: true)
        let host = root.appendingPathComponent("UpdateHost.app", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: host.path) { try fileManager.removeItem(at: host) }
        try fileManager.copyItem(at: Bundle.main.bundleURL, to: host)
        guard let executable = Bundle(url: host)?.executableURL else { throw UpdateInstallationError.stagingFailed }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--apply-automatic-update",
            request.diskImageURL.path,
            request.applicationURL.path,
            request.expectedVersion,
            request.channel.rawValue,
            String(request.processIdentifier),
            relaunch ? "idle" : "quit"
        ]
        try process.run()
    }

    static func canInstallAutomatically(_ request: AutomaticUpdateInstallationRequest) -> Bool {
        let diskImageURL = request.diskImageURL
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return false }
        guard let expectedVersion = AppSemanticVersion(request.expectedVersion),
              let contextData = try? Data(contentsOf: diskImageURL.deletingLastPathComponent().appendingPathComponent("install-context.json")),
              let context = try? JSONDecoder().decode(CacheContext.self, from: contextData),
              context.applicationPath == request.applicationURL.path,
              context.channel == request.channel.rawValue else {
            return false
        }
        let version = expectedVersion.description
        let manifestURL = diskImageURL.deletingLastPathComponent().appendingPathComponent("BalanceBar-\(version).update.json")
        let signatureURL = diskImageURL.deletingLastPathComponent().appendingPathComponent("BalanceBar-\(version).update.json.sig")
        guard let current = LiveUpdateFileSystem().bundleMetadata(at: request.applicationURL),
              let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? UpdateSignatureVerifier().verify(
                manifestData: manifestData,
                signatureData: Data(contentsOf: signatureURL)
              ),
              manifest.version == version,
              manifest.channel == request.channel.rawValue,
              manifest.bundleIdentifier == current.bundleIdentifier,
              let dmgData = try? Data(contentsOf: diskImageURL),
              (try? diskImageURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true,
              (try? diskImageURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              Int64(dmgData.count) == manifest.asset.size,
              SHA256Hex.digest(dmgData) == manifest.asset.sha256,
              let currentVersion = current.shortVersion.flatMap(AppSemanticVersion.init),
              expectedVersion > currentVersion else { return false }
        let writeProbe = request.applicationURL.deletingLastPathComponent()
            .appendingPathComponent(".balancebar-update-preflight-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: writeProbe.path, contents: Data()) else { return false }
        try? FileManager.default.removeItem(atPath: writeProbe.path)
        let preflightDirectory = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.huanmeng06.BalanceBar.app", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent("preflight-\(UUID().uuidString)", isDirectory: true)
        let stagedApp = preflightDirectory.appendingPathComponent("BalanceBar.app", isDirectory: true)
        do {
            defer { try? FileManager.default.removeItem(at: preflightDirectory) }
            try FileManager.default.createDirectory(at: preflightDirectory, withIntermediateDirectories: true)
            try stageVerifiedApplication(from: diskImageURL, at: stagedApp, bundleIdentifier: manifest.bundleIdentifier, version: expectedVersion)
            return true
        } catch {
            return false
        }
    }

    static func stageVerifiedApplication(
        from diskImage: URL, at stagedApp: URL, bundleIdentifier: String, version: AppSemanticVersion
    ) throws {
        let mounter = HdiutilUpdateDiskImageMounter()
        let mount = try mounter.mount(diskImageURL: diskImage)
        var mounted = true
        defer { if mounted { try? mounter.unmount(mount) } }
        let source = mount.mountPoint.appendingPathComponent("BalanceBar.app", isDirectory: true)
        let properties = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink == false else {
            throw UpdateInstallationError.manualInstallationRequired
        }
        try FileManager.default.copyItem(at: source, to: stagedApp)
        guard UpdateApplicationPreflight.validate(appURL: stagedApp),
              let metadata = LiveUpdateFileSystem().bundleMetadata(at: stagedApp),
              metadata.bundleIdentifier == bundleIdentifier,
              AppSemanticVersion(metadata.shortVersion ?? "") == version else {
            throw UpdateInstallationError.manualInstallationRequired
        }
        try mounter.unmount(mount)
        mounted = false
    }

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 6,
              let expectedVersion = AppSemanticVersion(arguments[2]),
              let channel = UpdateChannel(rawValue: arguments[3]),
              let processIdentifier = Int32(arguments[4]), processIdentifier > 0,
              ["idle", "quit"].contains(arguments[5]) else { return 2 }
        let idle = arguments[5] == "idle"
        let application = URL(fileURLWithPath: arguments[1])
        let request = AutomaticUpdateInstallationRequest(
            diskImageURL: URL(fileURLWithPath: arguments[0]),
            applicationURL: application,
            expectedVersion: expectedVersion.description,
            channel: channel,
            processIdentifier: processIdentifier
        )
        do {
            try waitForProcessExit(processIdentifier)
            try install(
                diskImageURL: request.diskImageURL,
                applicationURL: application,
                expectedVersion: expectedVersion,
                channel: channel,
                idle: idle
            )
            if idle {
                try reopen(application)
                try waitForSuccessfulLaunch {
                    guard let record = readTransaction(), record.idle == true,
                          record.applicationPath == application.path, record.version == request.expectedVersion,
                          record.launchedAt != nil else { return false }
                    try? FileManager.default.removeItem(atPath: record.backupPath)
                    return true
                }
            }
            return 0
        } catch {
            if idle {
                recordIdleFailure(for: request)
                recoverAndReopen(request)
            } else {
                recordFailure(applicationURL: application, version: expectedVersion.description)
            }
            NSLog("BalanceBar updater: automatic installation failed (idle=%@)", idle ? "yes" : "no")
            return 1
        }
    }

    private static func reopen(_ application: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", application.path]
        if let identifier = Bundle.main.bundleIdentifier, UpdateSignatureVerifier.isDevelopmentBundleIdentifier(identifier) {
            let environment = ProcessInfo.processInfo.environment
            for name in ["BALANCEBAR_RELEASE_FIXTURE_PATH", "BALANCEBAR_UPDATE_ASSET_DIRECTORY",
                         "BALANCEBAR_UPDATE_TEST_PUBLIC_KEY", "BALANCEBAR_UPDATE_IDLE_SECONDS"] {
                if let value = environment[name] { process.arguments?.append(contentsOf: ["--env", "\(name)=\(value)"]) }
            }
        }
        process.arguments?.append(contentsOf: ["--args", "--automatic-update-relaunch"])
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateInstallationError.relaunchFailed }
    }

    static func waitForSuccessfulLaunch(timeout: TimeInterval = 60, confirmed: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if confirmed() { return }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
        throw UpdateInstallationError.relaunchFailed
    }

    private static func recoverAndReopen(_ request: AutomaticUpdateInstallationRequest) {
        let application = request.applicationURL
        var fallback: URL?
        if let record = readTransaction(), record.idle == true, record.stage == "replaced",
           record.applicationPath == application.path, record.version == request.expectedVersion {
            let backup = URL(fileURLWithPath: record.backupPath)
            fallback = backup
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .filter { $0.bundleURL?.resolvingSymlinksInPath() == application.resolvingSymlinksInPath() && !$0.isTerminated }
            for app in running {
                app.forceTerminate()
                try? waitForProcessExit(app.processIdentifier)
            }
            do {
                try restoreBackup(backup, to: application)
                try? FileManager.default.removeItem(at: backup)
                fallback = nil
            } catch {
                NSLog("BalanceBar updater: restoring the previous installation failed")
            }
        } else if let record = readTransaction(), record.stage == "rollback-failed",
                  record.applicationPath == application.path, record.version == request.expectedVersion {
            fallback = URL(fileURLWithPath: record.backupPath)
        }
        recordFailure(applicationURL: application, version: request.expectedVersion)
        let destination = fallback ?? application
        for _ in 0..<3 {
            if (try? reopen(destination)) != nil,
               waitForRunningApplication(at: destination) { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        NSLog("BalanceBar updater: reopening the previous version failed")
    }

    private static func waitForRunningApplication(at url: URL) -> Bool {
        let expectedPath = url.resolvingSymlinksInPath().path
        let identifier = Bundle.main.bundleIdentifier ?? ""
        for _ in 0..<40 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
                $0.bundleURL?.resolvingSymlinksInPath().path == expectedPath && $0.isFinishedLaunching && !$0.isTerminated
            }) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func restoreBackup(_ backup: URL, to application: URL) throws {
        let files = FileManager.default
        let staging = application.deletingLastPathComponent()
            .appendingPathComponent(".BalanceBar-recovery-\(UUID().uuidString).app")
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: backup, to: staging)
        if files.fileExists(atPath: application.path) {
            _ = try files.replaceItemAt(application, withItemAt: staging, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: staging, to: application)
        }
    }

    private static func readTransaction() -> Transaction? {
        guard let url = transactionURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transaction.self, from: data)
    }

    private static func idleFailureURL(for request: AutomaticUpdateInstallationRequest) -> URL? {
        transactionURL()?.deletingLastPathComponent().appendingPathComponent("idle-failed-\(request.expectedVersion)")
    }

    static func idleAttemptFailed(for request: AutomaticUpdateInstallationRequest) -> Bool {
        guard let url = idleFailureURL(for: request) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func recordIdleFailure(for request: AutomaticUpdateInstallationRequest) {
        guard let url = idleFailureURL(for: request) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url, options: .atomic)
    }

    static func idleUpdateNotice(markRead: Bool = false) -> String? {
        guard let url = transactionURL(), var record = readTransaction(),
              record.idle == true, record.noticeRead != true, let launchedAt = record.launchedAt,
              Date().timeIntervalSince(launchedAt) < 24 * 60 * 60,
              Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == record.version else { return nil }
        if markRead {
            record.noticeRead = true
            try? save(record, to: url)
        }
        return record.version
    }

    static func confirmSuccessfulLaunch() {
        guard let transactionURL = transactionURL(),
              var transaction = readTransaction(),
              transaction.stage == "replaced",
              Bundle.main.bundleURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: transaction.applicationPath).resolvingSymlinksInPath().path,
              AppSemanticVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")?.description == transaction.version else { return }
        if transaction.idle == true {
            guard transaction.launchedAt == nil else { return }
            transaction.launchedAt = Date()
            try? save(transaction, to: transactionURL)
            return
        }
        try? FileManager.default.removeItem(atPath: transaction.backupPath)
        try? FileManager.default.removeItem(at: transactionURL)
    }

    static func recordSuccessfulReplacement(applicationURL: URL, backupURL: URL, version: String) throws {
        guard let url = transactionURL() else { throw UpdateInstallationError.replacementFailed }
        try save(Transaction(
            stage: "replaced",
            applicationPath: applicationURL.path,
            backupPath: backupURL.path,
            version: version,
            launchAttempted: false
        ), to: url)
    }

    static func clearTransaction() {
        if let url = transactionURL() { try? FileManager.default.removeItem(at: url) }
    }

    static func hasPreviousInstallationFailure() -> Bool {
        guard let url = transactionURL(),
              let transaction = try? JSONDecoder().decode(Transaction.self, from: Data(contentsOf: url)) else { return false }
        return transaction.stage == "failed" || transaction.stage == "rollback-failed"
    }

    static func prepareForLaunch() -> Bool {
        guard let transactionURL = transactionURL(),
              var transaction = try? JSONDecoder().decode(Transaction.self, from: Data(contentsOf: transactionURL)),
              transaction.stage == "replaced", transaction.idle != true else { return true }
        guard transaction.launchAttempted else {
            transaction.launchAttempted = true
            try? save(transaction, to: transactionURL)
            return true
        }
        do {
            let applicationURL = URL(fileURLWithPath: transaction.applicationPath)
            let backupURL = URL(fileURLWithPath: transaction.backupPath)
            let recoveryURL = applicationURL.deletingLastPathComponent()
                .appendingPathComponent(".BalanceBar-recovery-\(UUID().uuidString).app", isDirectory: true)
            try FileManager.default.copyItem(at: backupURL, to: recoveryURL)
            try FileManager.default.replaceItemAt(
                applicationURL,
                withItemAt: recoveryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.removeItem(at: transactionURL)
        } catch {
            transaction.stage = "rollback-failed"
            try? save(transaction, to: transactionURL)
        }
        return false
    }

    private static func install(
        diskImageURL: URL,
        applicationURL: URL,
        expectedVersion: AppSemanticVersion,
        channel: UpdateChannel,
        idle: Bool
    ) throws {
        let fileManager = FileManager.default
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.huanmeng06.BalanceBar.app"
        let contextURL = diskImageURL.deletingLastPathComponent().appendingPathComponent("install-context.json")
        let context = try JSONDecoder().decode(CacheContext.self, from: Data(contentsOf: contextURL))
        guard context.applicationPath == applicationURL.path,
              context.channel == channel.rawValue,
              fileManager.fileExists(atPath: diskImageURL.path),
              (try? diskImageURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true,
              (try? diskImageURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let support = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            throw UpdateInstallationError.invalidDiskImage
        }
        let manifestURL = diskImageURL.deletingLastPathComponent()
            .appendingPathComponent("BalanceBar-\(expectedVersion.description).update.json")
        let signatureURL = diskImageURL.deletingLastPathComponent()
            .appendingPathComponent("BalanceBar-\(expectedVersion.description).update.json.sig")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try UpdateSignatureVerifier().verify(
            manifestData: manifestData,
            signatureData: Data(contentsOf: signatureURL)
        )
        let dmgData = try Data(contentsOf: diskImageURL)
        guard manifest.version == expectedVersion.description,
              manifest.channel == channel.rawValue,
              manifest.bundleIdentifier == bundleIdentifier,
              Int64(dmgData.count) == manifest.asset.size,
              SHA256Hex.digest(dmgData) == manifest.asset.sha256,
              let currentMetadata = LiveUpdateFileSystem().bundleMetadata(at: applicationURL),
              currentMetadata.bundleIdentifier == bundleIdentifier,
              let currentVersion = currentMetadata.shortVersion.flatMap(AppSemanticVersion.init),
              expectedVersion > currentVersion else {
            throw UpdateInstallationError.bundleMetadataMismatch
        }

        let parent = applicationURL.deletingLastPathComponent()
        let probe = parent.appendingPathComponent(".balancebar-update-write-check-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: probe.path, contents: Data()),
              (try? fileManager.removeItem(at: probe)) != nil else {
            throw UpdateInstallationError.manualInstallationRequired
        }
        let updaterRoot = support.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updater", isDirectory: true)
        let backupDirectory = updaterRoot.appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backup = backupDirectory.appendingPathComponent("BalanceBar.previous-\(expectedVersion.description).app", isDirectory: true)
        guard !fileManager.fileExists(atPath: backup.path) else { throw UpdateInstallationError.stagingFailed }
        let transaction = updaterRoot.appendingPathComponent("installation.json")
        var record = Transaction(
            stage: "prepared",
            applicationPath: applicationURL.path,
            backupPath: backup.path,
            version: expectedVersion.description,
            launchAttempted: false,
            idle: idle
        )
        try save(record, to: transaction)

        let stagedApp = parent.appendingPathComponent(".BalanceBar-staged-\(UUID().uuidString).app", isDirectory: true)
        do {
            try stageVerifiedApplication(from: diskImageURL, at: stagedApp, bundleIdentifier: bundleIdentifier, version: expectedVersion)
            try fileManager.copyItem(at: applicationURL, to: backup)
            record.stage = "backed-up"
            try save(record, to: transaction)
            try fileManager.replaceItemAt(applicationURL, withItemAt: stagedApp, backupItemName: nil, options: .usingNewMetadataOnly)
            record.stage = "replaced"
            try save(record, to: transaction)
        } catch {
            let backupExists = fileManager.fileExists(atPath: backup.path)
            let targetExists = fileManager.fileExists(atPath: applicationURL.path)
            let targetHasNewVersion = LiveUpdateFileSystem().bundleMetadata(at: applicationURL)?.shortVersion
                == expectedVersion.description
            if backupExists && (targetHasNewVersion || !targetExists) {
                let recovery = parent.appendingPathComponent(".BalanceBar-rollback-\(UUID().uuidString).app", isDirectory: true)
                do {
                    try fileManager.copyItem(at: backup, to: recovery)
                    if targetExists {
                        try fileManager.replaceItemAt(applicationURL, withItemAt: recovery, backupItemName: nil, options: .usingNewMetadataOnly)
                    } else {
                        try fileManager.moveItem(at: recovery, to: applicationURL)
                    }
                    try fileManager.removeItem(at: backup)
                    record.stage = "failed"
                } catch {
                    record.stage = "rollback-failed"
                }
            } else {
                if backupExists { try? fileManager.removeItem(at: backup) }
                record.stage = "failed"
            }
            try save(record, to: transaction)
            try? fileManager.removeItem(at: stagedApp)
            throw error
        }
    }

    private static func waitForProcessExit(_ processIdentifier: Int32) throws {
        for _ in 0..<600 {
            if kill(processIdentifier, 0) != 0 && errno == ESRCH { return }
            usleep(100_000)
        }
        throw UpdateInstallationError.replacementFailed
    }

    private static func transactionURL() -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.huanmeng06.BalanceBar.app"
        return support.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updater", isDirectory: true)
            .appendingPathComponent("installation.json")
    }

    private static func recordFailure(applicationURL: URL, version: String) {
        guard let url = transactionURL() else { return }
        if let existing = try? JSONDecoder().decode(Transaction.self, from: Data(contentsOf: url)),
           existing.stage == "rollback-failed" { return }
        try? save(Transaction(
            stage: "failed",
            applicationPath: applicationURL.path,
            backupPath: "",
            version: version,
            launchAttempted: false
        ), to: url)
    }

    private static func save(_ transaction: Transaction, to url: URL) throws {
        let data = try JSONEncoder().encode(transaction)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
