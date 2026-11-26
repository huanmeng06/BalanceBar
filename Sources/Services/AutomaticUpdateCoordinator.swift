import Foundation

final class AutomaticUpdateCoordinator {
    private let preferences: AppPreferences
    private let updateService: UpdateService
    private let verifier: UpdateSignatureVerifier
    private var preparingVersion: AppSemanticVersion?

    init(
        preferences: AppPreferences,
        updateService: UpdateService,
        verifier: UpdateSignatureVerifier = UpdateSignatureVerifier()
    ) {
        self.preferences = preferences
        self.updateService = updateService
        self.verifier = verifier
    }

    func start() {
        updateCheckChanged(updateService.state)
    }

    func setEnabled(_ enabled: Bool) {
        let channel = preferences.updateChannel
        preferences.setAutomaticUpdateEnabled(enabled, for: channel)
        guard enabled else {
            preparingVersion = nil
            updateService.automaticUpdatesWereDisabled()
            return
        }
        updateCheckChanged(updateService.state)
    }

    func updateCheckChanged(_ state: UpdateCheckState) {
        guard preferences.automaticUpdateEnabled(for: preferences.updateChannel),
              verifier.hasTrustedKeys else { return }
        let version: AppSemanticVersion
        switch state {
        case .available(_, let latest), .revalidating(_, let latest), .recheckFailed(_, let latest, _):
            version = latest
        default:
            return
        }
        guard preparingVersion != version else { return }
        preparingVersion = version
        updateService.prepareAutomaticUpdate(verifier: verifier) { [weak self] result in
            guard let self, self.preparingVersion == version else { return }
            if case .failure = result { self.preparingVersion = nil }
            if case .success(nil) = result { self.preparingVersion = nil }
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
    }

    static func launch(_ request: AutomaticUpdateInstallationRequest) throws {
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
            String(request.processIdentifier)
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
        guard let image = try? HdiutilUpdateDiskImageMounter().mount(diskImageURL: diskImageURL) else { return false }
        defer { try? HdiutilUpdateDiskImageMounter().unmount(image) }
        let application = image.mountPoint.appendingPathComponent("BalanceBar.app", isDirectory: true)
        guard let metadata = LiveUpdateFileSystem().bundleMetadata(at: application),
              metadata.bundleIdentifier == manifest.bundleIdentifier,
              AppSemanticVersion(metadata.shortVersion ?? "") == expectedVersion else { return false }
        let preflightDirectory = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.huanmeng06.BalanceBar.app", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent("preflight-\(UUID().uuidString)", isDirectory: true)
        let stagedApp = preflightDirectory.appendingPathComponent("BalanceBar.app", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: preflightDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: application, to: stagedApp)
            let valid = UpdateApplicationPreflight.validate(appURL: stagedApp)
            try? FileManager.default.removeItem(at: preflightDirectory)
            return valid
        } catch {
            try? FileManager.default.removeItem(at: preflightDirectory)
            return false
        }
    }

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 5,
              let expectedVersion = AppSemanticVersion(arguments[2]),
              let channel = UpdateChannel(rawValue: arguments[3]),
              let processIdentifier = Int32(arguments[4]) else { return 2 }
        do {
            try install(
                diskImageURL: URL(fileURLWithPath: arguments[0]),
                applicationURL: URL(fileURLWithPath: arguments[1]),
                expectedVersion: expectedVersion,
                channel: channel,
                processIdentifier: processIdentifier
            )
            return 0
        } catch {
            if arguments.count >= 3,
               let version = AppSemanticVersion(arguments[2]),
               let applicationURL = arguments.dropFirst(1).first.map({ URL(fileURLWithPath: $0) }) {
                recordFailure(applicationURL: applicationURL, version: version.description)
            }
            return 1
        }
    }

    static func confirmSuccessfulLaunch() {
        guard let transactionURL = transactionURL(),
              let transaction = try? JSONDecoder().decode(Transaction.self, from: Data(contentsOf: transactionURL)),
              transaction.stage == "replaced",
              AppSemanticVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")?.description == transaction.version else { return }
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
              transaction.stage == "replaced" else { return true }
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
        processIdentifier: Int32
    ) throws {
        try waitForProcessExit(processIdentifier)
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

        let mount = try HdiutilUpdateDiskImageMounter().mount(diskImageURL: diskImageURL)
        var mountIsActive = true
        defer {
            if mountIsActive { try? HdiutilUpdateDiskImageMounter().unmount(mount) }
        }
        let sourceApp = mount.mountPoint.appendingPathComponent("BalanceBar.app", isDirectory: true)
        guard let sourceMetadata = LiveUpdateFileSystem().bundleMetadata(at: sourceApp),
              sourceMetadata.bundleIdentifier == bundleIdentifier,
              AppSemanticVersion(sourceMetadata.shortVersion ?? "") == expectedVersion else {
            throw UpdateInstallationError.manualInstallationRequired
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
            launchAttempted: false
        )
        try save(record, to: transaction)

        let stagedApp = parent.appendingPathComponent(".BalanceBar-staged-\(UUID().uuidString).app", isDirectory: true)
        do {
            try fileManager.copyItem(at: sourceApp, to: stagedApp)
            guard UpdateApplicationPreflight.validate(appURL: stagedApp) else {
                throw UpdateInstallationError.manualInstallationRequired
            }
            try HdiutilUpdateDiskImageMounter().unmount(mount)
            mountIsActive = false
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
