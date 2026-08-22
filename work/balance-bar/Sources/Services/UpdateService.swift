import Foundation
import AppKit
#if canImport(CryptoKit)
import CryptoKit
#endif

enum GitHubReleaseClientError: Error {
    case transport
    case httpStatus(Int)
    case invalidResponse
}

protocol GitHubReleaseFetching {
    func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, GitHubReleaseClientError>) -> Void)
}

/// Reads only the public latest-release endpoint. Authentication is not
/// needed, and no user credentials are ever attached to this request.
final class GitHubReleaseClient: GitHubReleaseFetching {
    static let endpoint = URL(string: "https://api.github.com/repos/huanmeng06/BalanceBar/releases/latest")!

    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession = .shared, endpoint: URL = GitHubReleaseClient.endpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, GitHubReleaseClientError>) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BalanceBar", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(.transport))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.invalidResponse))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                completion(.failure(.httpStatus(httpResponse.statusCode)))
                return
            }
            guard let data,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
            else {
                completion(.failure(.invalidResponse))
                return
            }
            completion(.success(release))
        }.resume()
    }
}

enum UpdateAssetDownloadError: Error {
    case invalidAsset
    case transport
    case httpStatus(Int)
    case emptyData
    case sizeMismatch
    case digestMismatch
    case writeFailed
}

protocol UpdateAssetDownloading {
    func download(
        asset: GitHubReleaseAsset,
        completion: @escaping (Result<URL, UpdateAssetDownloadError>) -> Void
    )

    func cleanupDownloadedFile(at url: URL)
}

enum UpdateAssetVerifier {
    static func verify(data: Data, asset: GitHubReleaseAsset) throws {
        guard !data.isEmpty else { throw UpdateAssetDownloadError.emptyData }
        if let expectedSize = asset.size, expectedSize != data.count {
            throw UpdateAssetDownloadError.sizeMismatch
        }
        if let digest = asset.digest {
            guard let expectedDigest = normalizedSHA256Digest(digest) else {
                throw UpdateAssetDownloadError.digestMismatch
            }
            let actualDigest = SHA256Hex.digest(data)
            guard actualDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame else {
                throw UpdateAssetDownloadError.digestMismatch
            }
        }
    }

    private static func normalizedSHA256Digest(_ value: String) -> String? {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let digest = parts.count == 2 && parts[0].lowercased() == "sha256"
            ? String(parts[1])
            : value
        let hexadecimalCharacters = "0123456789abcdefABCDEF"
        guard digest.count == 64,
              digest.allSatisfy({ hexadecimalCharacters.contains($0) })
        else { return nil }
        return digest
    }
}

private enum SHA256Hex {
    static func digest(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        // macOS 14 always provides CryptoKit. The fallback keeps this source
        // parseable for lightweight non-macOS source tooling.
        return ""
        #endif
    }
}

/// Downloads the exact release asset into a unique temporary directory and
/// validates HTTP status, content size, and the optional GitHub SHA-256 digest
/// before exposing the path to the installer.
final class URLSessionUpdateAssetDownloader: UpdateAssetDownloading {
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func download(
        asset: GitHubReleaseAsset,
        completion: @escaping (Result<URL, UpdateAssetDownloadError>) -> Void
    ) {
        guard let url = asset.browserDownloadURL,
              url.scheme?.lowercased() == "https"
        else {
            completion(.failure(.invalidAsset))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("BalanceBar", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [fileManager] data, response, error in
            if error != nil {
                completion(.failure(.transport))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.invalidAsset))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                completion(.failure(.httpStatus(httpResponse.statusCode)))
                return
            }
            guard let data else {
                completion(.failure(.emptyData))
                return
            }
            do {
                try UpdateAssetVerifier.verify(data: data, asset: asset)
                let directory = fileManager.temporaryDirectory
                    .appendingPathComponent("BalanceBar-update-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(asset.name)
                try data.write(to: destination, options: .atomic)
                completion(.success(destination))
            } catch let error as UpdateAssetDownloadError {
                completion(.failure(error))
            } catch {
                completion(.failure(.writeFailed))
            }
        }.resume()
    }

    func cleanupDownloadedFile(at url: URL) {
        try? fileManager.removeItem(at: url.deletingLastPathComponent())
    }
}

struct UpdateApplicationBundleMetadata: Equatable {
    let bundleIdentifier: String?
    let shortVersion: String?
}

protocol UpdateFileSystem {
    func makeTemporaryDirectory() throws -> URL
    func fileExists(at url: URL) -> Bool
    func isRegularFile(at url: URL) -> Bool
    func copyItem(at source: URL, to destination: URL) throws
    func replaceItem(at target: URL, withItemAt replacement: URL, backupItemName: String?) throws
    func removeItem(at url: URL) throws
    func bundleMetadata(at appURL: URL) -> UpdateApplicationBundleMetadata?
}

struct LiveUpdateFileSystem: UpdateFileSystem {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("BalanceBar-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func isRegularFile(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeRegular
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try fileManager.copyItem(at: source, to: destination)
    }

    func replaceItem(at target: URL, withItemAt replacement: URL, backupItemName: String?) throws {
        _ = try fileManager.replaceItemAt(
            target,
            withItemAt: replacement,
            backupItemName: backupItemName,
            options: .usingNewMetadataOnly
        )
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func bundleMetadata(at appURL: URL) -> UpdateApplicationBundleMetadata? {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else { return nil }
        return UpdateApplicationBundleMetadata(
            bundleIdentifier: object["CFBundleIdentifier"] as? String,
            shortVersion: object["CFBundleShortVersionString"] as? String
        )
    }
}

struct MountedUpdateDiskImage {
    let mountPoint: URL
}

protocol UpdateDiskImageMounting {
    func mount(diskImageURL: URL) throws -> MountedUpdateDiskImage
    func unmount(_ image: MountedUpdateDiskImage) throws
}

struct UpdateProcessResult {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol UpdateProcessRunning {
    func run(executableURL: URL, arguments: [String]) throws -> UpdateProcessResult
}

struct LiveUpdateProcessRunner: UpdateProcessRunning {
    func run(executableURL: URL, arguments: [String]) throws -> UpdateProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return UpdateProcessResult(
            status: process.terminationStatus,
            standardOutput: output.fileHandleForReading.readDataToEndOfFile(),
            standardError: error.fileHandleForReading.readDataToEndOfFile()
        )
    }
}

enum UpdateInstallationError: Error, Equatable {
    case invalidDiskImage
    case mountFailed
    case applicationNotFound
    case bundleMetadataMismatch
    case stagingFailed
    case replacementFailed
    case relaunchFailed
}

struct HdiutilUpdateDiskImageMounter: UpdateDiskImageMounting {
    private let processRunner: UpdateProcessRunning
    private let hdiutilURL = URL(fileURLWithPath: "/usr/bin/hdiutil")

    init(processRunner: UpdateProcessRunning = LiveUpdateProcessRunner()) {
        self.processRunner = processRunner
    }

    func mount(diskImageURL: URL) throws -> MountedUpdateDiskImage {
        let result: UpdateProcessResult
        do {
            result = try processRunner.run(
                executableURL: hdiutilURL,
                arguments: ["attach", "-plist", "-nobrowse", "-readonly", diskImageURL.path]
            )
        } catch {
            throw UpdateInstallationError.mountFailed
        }
        guard result.status == 0,
              let object = try? PropertyListSerialization.propertyList(
                  from: result.standardOutput,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let entities = object["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw UpdateInstallationError.mountFailed
        }
        return MountedUpdateDiskImage(mountPoint: URL(fileURLWithPath: mountPoint, isDirectory: true))
    }

    func unmount(_ image: MountedUpdateDiskImage) throws {
        let result = try processRunner.run(
            executableURL: hdiutilURL,
            arguments: ["detach", image.mountPoint.path]
        )
        guard result.status == 0 else { throw UpdateInstallationError.mountFailed }
    }
}

protocol UpdateApplicationRelaunching {
    func relaunchApplication(at applicationURL: URL) throws
}

struct LiveUpdateApplicationRelauncher: UpdateApplicationRelaunching {
    private let processRunner: UpdateProcessRunning
    private let openURL = URL(fileURLWithPath: "/usr/bin/open")

    init(processRunner: UpdateProcessRunning = LiveUpdateProcessRunner()) {
        self.processRunner = processRunner
    }

    func relaunchApplication(at applicationURL: URL) throws {
        let result: UpdateProcessResult
        do {
            result = try processRunner.run(
                executableURL: openURL,
                arguments: ["-n", applicationURL.path]
            )
        } catch {
            throw UpdateInstallationError.relaunchFailed
        }
        guard result.status == 0 else { throw UpdateInstallationError.relaunchFailed }
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }
}

protocol UpdateApplicationInstalling {
    func install(
        diskImageURL: URL,
        expectedVersion: AppSemanticVersion,
        currentApplicationURL: URL,
        expectedBundleIdentifier: String
    ) throws
}

/// Stages and validates a new app before atomically replacing the currently
/// running bundle. The current app is never selected by the user: the caller
/// supplies `Bundle.main.bundleURL`, so an update cannot silently overwrite a
/// different application path.
final class UpdateApplicationInstaller: UpdateApplicationInstalling {
    private let fileSystem: UpdateFileSystem
    private let mounter: UpdateDiskImageMounting
    private let relauncher: UpdateApplicationRelaunching

    init(
        fileSystem: UpdateFileSystem = LiveUpdateFileSystem(),
        mounter: UpdateDiskImageMounting = HdiutilUpdateDiskImageMounter(),
        relauncher: UpdateApplicationRelaunching = LiveUpdateApplicationRelauncher()
    ) {
        self.fileSystem = fileSystem
        self.mounter = mounter
        self.relauncher = relauncher
    }

    func install(
        diskImageURL: URL,
        expectedVersion: AppSemanticVersion,
        currentApplicationURL: URL,
        expectedBundleIdentifier: String
    ) throws {
        guard fileSystem.fileExists(at: diskImageURL),
              fileSystem.isRegularFile(at: diskImageURL)
        else { throw UpdateInstallationError.invalidDiskImage }

        let mounted: MountedUpdateDiskImage
        do {
            mounted = try mounter.mount(diskImageURL: diskImageURL)
        } catch let error as UpdateInstallationError {
            throw error
        } catch {
            throw UpdateInstallationError.mountFailed
        }

        var mountIsActive = true
        var stagingDirectory: URL?
        defer {
            if mountIsActive { try? mounter.unmount(mounted) }
            if let stagingDirectory { try? fileSystem.removeItem(at: stagingDirectory) }
        }

        let sourceApp = mounted.mountPoint.appendingPathComponent("BalanceBar.app", isDirectory: true)
        guard fileSystem.fileExists(at: sourceApp) else {
            throw UpdateInstallationError.applicationNotFound
        }
        guard let sourceMetadata = fileSystem.bundleMetadata(at: sourceApp),
              sourceMetadata.bundleIdentifier == expectedBundleIdentifier,
              let sourceVersion = sourceMetadata.shortVersion,
              let parsedSourceVersion = AppSemanticVersion(sourceVersion),
              parsedSourceVersion == expectedVersion
        else {
            throw UpdateInstallationError.bundleMetadataMismatch
        }

        let temporaryDirectory: URL
        do {
            temporaryDirectory = try fileSystem.makeTemporaryDirectory()
        } catch {
            throw UpdateInstallationError.stagingFailed
        }
        stagingDirectory = temporaryDirectory
        let stagedApp = temporaryDirectory.appendingPathComponent("BalanceBar.app", isDirectory: true)
        do {
            try fileSystem.copyItem(at: sourceApp, to: stagedApp)
        } catch {
            throw UpdateInstallationError.stagingFailed
        }
        guard let stagedMetadata = fileSystem.bundleMetadata(at: stagedApp),
              stagedMetadata.bundleIdentifier == expectedBundleIdentifier,
              let stagedVersion = stagedMetadata.shortVersion,
              AppSemanticVersion(stagedVersion) == expectedVersion
        else {
            throw UpdateInstallationError.bundleMetadataMismatch
        }

        do {
            try mounter.unmount(mounted)
            mountIsActive = false
        } catch {
            throw UpdateInstallationError.mountFailed
        }

        let backupName = ".BalanceBar.previous-\(UUID().uuidString).app"
        let backupURL = currentApplicationURL
            .deletingLastPathComponent()
            .appendingPathComponent(backupName)
        do {
            // Keep an explicit backup until the relaunched process is known to
            // start. Relying on FileManager's optional backup name makes the
            // backup location/availability platform-dependent and can leave
            // the new bundle in place after a failed relaunch.
            try fileSystem.copyItem(at: currentApplicationURL, to: backupURL)
            try fileSystem.replaceItem(
                at: currentApplicationURL,
                withItemAt: stagedApp,
                backupItemName: nil
            )
        } catch {
            throw UpdateInstallationError.replacementFailed
        }

        do {
            try relauncher.relaunchApplication(at: currentApplicationURL)
        } catch {
            // Restore the old app if the new process could not be started.
            try? fileSystem.replaceItem(
                at: currentApplicationURL,
                withItemAt: backupURL,
                backupItemName: nil
            )
            throw UpdateInstallationError.relaunchFailed
        }
        try? fileSystem.removeItem(at: backupURL)
    }
}

/// Coordinates release lookup, asset download, installation and UI-visible
/// state transitions. All side effects are injected so tests never require
/// GitHub access, a real DMG, or the production app path.
final class UpdateService {
    private let releaseFetcher: GitHubReleaseFetching
    private let downloader: UpdateAssetDownloading
    private let installer: UpdateApplicationInstalling
    private let currentVersion: AppSemanticVersion?
    private let currentApplicationURL: URL
    private let currentBundleIdentifier: String?
    private let callbackQueue: DispatchQueue
    private let workQueue: DispatchQueue
    private var availableRelease: GitHubRelease?

    private(set) var state: UpdateCheckState
    var onStateChange: ((UpdateCheckState) -> Void)?

    init(
        releaseFetcher: GitHubReleaseFetching = GitHubReleaseClient(),
        downloader: UpdateAssetDownloading = URLSessionUpdateAssetDownloader(),
        installer: UpdateApplicationInstalling = UpdateApplicationInstaller(),
        currentVersionString: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        currentApplicationURL: URL = Bundle.main.bundleURL,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        callbackQueue: DispatchQueue = .main,
        workQueue: DispatchQueue = DispatchQueue(label: "local.balancebar.update-install", qos: .userInitiated)
    ) {
        self.releaseFetcher = releaseFetcher
        self.downloader = downloader
        self.installer = installer
        self.currentVersion = currentVersionString.flatMap(AppSemanticVersion.init)
        self.currentApplicationURL = currentApplicationURL
        self.currentBundleIdentifier = currentBundleIdentifier
        self.callbackQueue = callbackQueue
        self.workQueue = workQueue
        if let currentVersion = self.currentVersion {
            self.state = .idle(current: currentVersion)
        } else {
            self.state = .failed(.invalidCurrentVersion)
        }
    }

    func checkForUpdates() {
        guard let currentVersion,
              !isBusy
        else { return }
        availableRelease = nil
        transition(to: .checking(current: currentVersion))
        releaseFetcher.fetchLatestRelease { [weak self] result in
            guard let self else { return }
            self.callbackQueue.async {
                self.handleReleaseResult(result, currentVersion: currentVersion)
            }
        }
    }

    func installAvailableUpdate() {
        guard case .available(let currentVersion, let latestVersion) = state,
              let release = availableRelease,
              let asset = release.matchingAsset(for: latestVersion)
        else { return }
        transition(to: .downloading(current: currentVersion, latest: latestVersion))
        downloader.download(asset: asset) { [weak self] result in
            guard let self else { return }
            self.callbackQueue.async {
                self.handleDownloadResult(
                    result,
                    currentVersion: currentVersion,
                    latestVersion: latestVersion
                )
            }
        }
    }

    private var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        case .idle, .latest, .available, .restarting, .failed:
            return false
        }
    }

    private func handleReleaseResult(
        _ result: Result<GitHubRelease, GitHubReleaseClientError>,
        currentVersion: AppSemanticVersion
    ) {
        switch result {
        case .failure(let error):
            switch error {
            case .transport:
                transition(to: .failed(.network))
            case .httpStatus(let statusCode):
                transition(to: .failed(.httpStatus(statusCode)))
            case .invalidResponse:
                transition(to: .failed(.invalidResponse))
            }
        case .success(let release):
            guard !release.draft, !release.prerelease else {
                availableRelease = nil
                transition(to: .latest(current: currentVersion))
                return
            }
            guard let latestVersion = AppSemanticVersion(release.tagName) else {
                availableRelease = nil
                transition(to: .failed(.invalidReleaseVersion))
                return
            }
            guard latestVersion > currentVersion else {
                availableRelease = nil
                transition(to: .latest(current: currentVersion))
                return
            }
            guard release.matchingAsset(for: latestVersion) != nil else {
                availableRelease = nil
                transition(to: .failed(.assetUnavailable))
                return
            }
            availableRelease = release
            transition(to: .available(current: currentVersion, latest: latestVersion))
        }
    }

    private func handleDownloadResult(
        _ result: Result<URL, UpdateAssetDownloadError>,
        currentVersion: AppSemanticVersion,
        latestVersion: AppSemanticVersion
    ) {
        switch result {
        case .failure(let error):
            switch error {
            case .digestMismatch, .sizeMismatch, .emptyData:
                transition(to: .failed(.verificationFailed))
            case .invalidAsset, .transport, .httpStatus, .writeFailed:
                transition(to: .failed(.downloadFailed))
            }
        case .success(let downloadedURL):
            transition(to: .installing(current: currentVersion, latest: latestVersion))
            guard let bundleIdentifier = currentBundleIdentifier else {
                downloader.cleanupDownloadedFile(at: downloadedURL)
                transition(to: .failed(.installationFailed))
                return
            }
            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.installer.install(
                        diskImageURL: downloadedURL,
                        expectedVersion: latestVersion,
                        currentApplicationURL: self.currentApplicationURL,
                        expectedBundleIdentifier: bundleIdentifier
                    )
                    self.downloader.cleanupDownloadedFile(at: downloadedURL)
                    self.callbackQueue.async {
                        self.transition(to: .restarting(current: currentVersion, latest: latestVersion))
                    }
                } catch {
                    self.downloader.cleanupDownloadedFile(at: downloadedURL)
                    self.callbackQueue.async {
                        self.transition(to: .failed(.installationFailed))
                    }
                }
            }
        }
    }

    private func transition(to newState: UpdateCheckState) {
        state = newState
        onStateChange?(newState)
    }
}
