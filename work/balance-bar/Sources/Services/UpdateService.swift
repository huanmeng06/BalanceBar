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
    /// Kept as a compatibility seam for callers that only need the previous
    /// single-release behavior. UpdateService uses the list method below.
    func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, GitHubReleaseClientError>) -> Void)
    func fetchReleases(completion: @escaping (Result<[GitHubRelease], GitHubReleaseClientError>) -> Void)
}

extension GitHubReleaseFetching {
    func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, GitHubReleaseClientError>) -> Void) {
        fetchReleases { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let releases):
                guard let release = releases.first else {
                    completion(.failure(.invalidResponse))
                    return
                }
                completion(.success(release))
            }
        }
    }

    func fetchReleases(completion: @escaping (Result<[GitHubRelease], GitHubReleaseClientError>) -> Void) {
        fetchLatestRelease { result in
            completion(result.map { [$0] })
        }
    }
}

/// Reads the public release list endpoint. Authentication is not needed, and
/// no user credentials are ever attached to this request.
final class GitHubReleaseClient: GitHubReleaseFetching {
    static let endpoint = URL(string: "https://api.github.com/repos/huanmeng06/BalanceBar/releases")!

    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession = .shared, endpoint: URL = GitHubReleaseClient.endpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    func fetchReleases(completion: @escaping (Result<[GitHubRelease], GitHubReleaseClientError>) -> Void) {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        if !endpoint.path.hasSuffix("/latest"),
           !queryItems.contains(where: { $0.name == "per_page" }) {
            queryItems.append(URLQueryItem(name: "per_page", value: "100"))
        }
        components?.queryItems = queryItems
        let requestURL = components?.url ?? endpoint
        var request = URLRequest(url: requestURL)
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
            guard let data else {
                completion(.failure(.invalidResponse))
                return
            }
            if let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) {
                completion(.success(releases))
            } else if let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
                completion(.success([release]))
            } else {
                completion(.failure(.invalidResponse))
            }
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

    func download(
        asset: GitHubReleaseAsset,
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, UpdateAssetDownloadError>) -> Void
    )

    func cleanupDownloadedFile(at url: URL)
}

extension UpdateAssetDownloading {
    func download(
        asset: GitHubReleaseAsset,
        completion: @escaping (Result<URL, UpdateAssetDownloadError>) -> Void
    ) {
        download(asset: asset, progress: { _ in }, completion: completion)
    }

    func download(
        asset: GitHubReleaseAsset,
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, UpdateAssetDownloadError>) -> Void
    ) {
        download(asset: asset, completion: completion)
    }
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
    private let sessionConfiguration: URLSessionConfiguration
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.sessionConfiguration = session.configuration
        self.fileManager = fileManager
    }

    func download(
        asset: GitHubReleaseAsset,
        progress: @escaping (Int) -> Void,
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
        let delegate = UpdateAssetDownloadDelegate(
            asset: asset,
            fileManager: fileManager,
            progress: progress,
            completion: completion
        )
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        progress(0)
        session.dataTask(with: request).resume()
    }

    func cleanupDownloadedFile(at url: URL) {
        try? fileManager.removeItem(at: url.deletingLastPathComponent())
    }
}

private final class UpdateAssetDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let asset: GitHubReleaseAsset
    private let fileManager: FileManager
    private let progress: (Int) -> Void
    private let completion: (Result<URL, UpdateAssetDownloadError>) -> Void
    private var response: HTTPURLResponse?
    private var expectedByteCount: Int64 = NSURLSessionTransferSizeUnknown
    private var receivedData = Data()
    private var didComplete = false

    init(
        asset: GitHubReleaseAsset,
        fileManager: FileManager,
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, UpdateAssetDownloadError>) -> Void
    ) {
        self.asset = asset
        self.fileManager = fileManager
        self.progress = progress
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response as? HTTPURLResponse
        expectedByteCount = response.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        guard expectedByteCount > 0 else { return }
        let fraction = Double(receivedData.count) / Double(expectedByteCount)
        progress(Self.percent(for: fraction))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !didComplete else { return }
        didComplete = true
        defer { session.finishTasksAndInvalidate() }

        if error != nil {
            completion(.failure(.transport))
            return
        }
        guard let response,
              (200..<300).contains(response.statusCode)
        else {
            if let response {
                completion(.failure(.httpStatus(response.statusCode)))
            } else {
                completion(.failure(.invalidAsset))
            }
            return
        }
        guard !receivedData.isEmpty else {
            completion(.failure(.emptyData))
            return
        }
        do {
            try UpdateAssetVerifier.verify(data: receivedData, asset: asset)
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("BalanceBar-update-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(asset.name)
            try receivedData.write(to: destination, options: .atomic)
            progress(100)
            completion(.success(destination))
        } catch let error as UpdateAssetDownloadError {
            completion(.failure(error))
        } catch {
            completion(.failure(.writeFailed))
        }
    }

    private static func percent(for fraction: Double) -> Int {
        min(max(Int((fraction * 100).rounded(.down)), 0), 100)
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

protocol UpdateDetachedProcessLaunching {
    func launch(executableURL: URL, arguments: [String]) throws
}

struct LiveUpdateDetachedProcessLauncher: UpdateDetachedProcessLaunching {
    func launch(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
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

protocol UpdateApplicationTerminating {
    func terminateApplication()
}

struct LiveUpdateApplicationTerminator: UpdateApplicationTerminating {
    func terminateApplication() {
        NSApplication.shared.terminate(nil)
    }
}

struct LiveUpdateApplicationRelauncher: UpdateApplicationRelaunching {
    private let processLauncher: UpdateDetachedProcessLaunching
    private let terminator: UpdateApplicationTerminating
    private let shellURL = URL(fileURLWithPath: "/bin/sh")

    init(
        processLauncher: UpdateDetachedProcessLaunching = LiveUpdateDetachedProcessLauncher(),
        terminator: UpdateApplicationTerminating = LiveUpdateApplicationTerminator()
    ) {
        self.processLauncher = processLauncher
        self.terminator = terminator
    }

    func relaunchApplication(at applicationURL: URL) throws {
        // Launch a detached waiter before terminating this process. Calling
        // `open -n` while the current app is still alive is not reliable for a
        // bundle that disallows multiple instances: LaunchServices can accept
        // the request without starting the replaced bundle. Passing the path
        // as a positional shell argument avoids interpolating it into code.
        let waitAndOpenScript = """
        pid="$1"
        app="$2"
        attempts=0
        while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 150 ]; do
            sleep 0.1
            attempts=$((attempts + 1))
        done
        exec /usr/bin/open -n "$app"
        """
        do {
            try processLauncher.launch(
                executableURL: shellURL,
                arguments: [
                    "-c",
                    waitAndOpenScript,
                    "BalanceBar-relaunch",
                    String(ProcessInfo.processInfo.processIdentifier),
                    applicationURL.path
                ]
            )
        } catch {
            throw UpdateInstallationError.relaunchFailed
        }
        DispatchQueue.main.async {
            self.terminator.terminateApplication()
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

    func install(
        diskImageURL: URL,
        expectedVersion: AppSemanticVersion,
        currentApplicationURL: URL,
        expectedBundleIdentifier: String,
        progress: @escaping (Int) -> Void
    ) throws
}

extension UpdateApplicationInstalling {
    func install(
        diskImageURL: URL,
        expectedVersion: AppSemanticVersion,
        currentApplicationURL: URL,
        expectedBundleIdentifier: String
    ) throws {
        try install(
            diskImageURL: diskImageURL,
            expectedVersion: expectedVersion,
            currentApplicationURL: currentApplicationURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            progress: { _ in }
        )
    }

    func install(
        diskImageURL: URL,
        expectedVersion: AppSemanticVersion,
        currentApplicationURL: URL,
        expectedBundleIdentifier: String,
        progress: @escaping (Int) -> Void
    ) throws {
        try install(
            diskImageURL: diskImageURL,
            expectedVersion: expectedVersion,
            currentApplicationURL: currentApplicationURL,
            expectedBundleIdentifier: expectedBundleIdentifier
        )
    }
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
        expectedBundleIdentifier: String,
        progress: @escaping (Int) -> Void
    ) throws {
        progress(0)
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
        progress(15)

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
        progress(25)

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
        progress(50)

        do {
            try mounter.unmount(mounted)
            mountIsActive = false
        } catch {
            throw UpdateInstallationError.mountFailed
        }
        progress(60)

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
        progress(80)

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
        progress(95)
        try? fileSystem.removeItem(at: backupURL)
        progress(100)
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
    var updateChannel: UpdateChannel
    var onStateChange: ((UpdateCheckState) -> Void)?

    init(
        releaseFetcher: GitHubReleaseFetching = GitHubReleaseClient(),
        downloader: UpdateAssetDownloading = URLSessionUpdateAssetDownloader(),
        installer: UpdateApplicationInstalling = UpdateApplicationInstaller(),
        currentVersionString: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        currentApplicationURL: URL = Bundle.main.bundleURL,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        updateChannel: UpdateChannel = .stable,
        callbackQueue: DispatchQueue = .main,
        workQueue: DispatchQueue = DispatchQueue(label: "local.balancebar.update-install", qos: .userInitiated)
    ) {
        self.releaseFetcher = releaseFetcher
        self.downloader = downloader
        self.installer = installer
        self.currentVersion = currentVersionString.flatMap(AppSemanticVersion.init)
        self.currentApplicationURL = currentApplicationURL
        self.currentBundleIdentifier = currentBundleIdentifier
        self.updateChannel = updateChannel
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
        let updateChannel = self.updateChannel
        availableRelease = nil
        transition(to: .checking(current: currentVersion))
        releaseFetcher.fetchReleases { [weak self] result in
            guard let self else { return }
            self.callbackQueue.async {
                self.handleReleaseResult(
                    result,
                    currentVersion: currentVersion,
                    updateChannel: updateChannel
                )
            }
        }
    }

    func installAvailableUpdate() {
        guard case .available(let currentVersion, let latestVersion) = state,
              let release = availableRelease,
              let asset = release.matchingAsset(for: latestVersion)
        else { return }
        transition(to: .downloading(current: currentVersion, latest: latestVersion, progress: 0))
        downloader.download(
            asset: asset,
            progress: { [weak self] progress in
                guard let self else { return }
                self.callbackQueue.async {
                    guard case .downloading(let current, let latest, _) = self.state,
                          current == currentVersion,
                          latest == latestVersion
                    else { return }
                    self.transition(
                        to: .downloading(
                            current: currentVersion,
                            latest: latestVersion,
                            progress: Self.clampProgress(progress)
                        )
                    )
                }
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.callbackQueue.async {
                    self.handleDownloadResult(
                        result,
                        currentVersion: currentVersion,
                        latestVersion: latestVersion
                    )
                }
            }
        )
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
        _ result: Result<[GitHubRelease], GitHubReleaseClientError>,
        currentVersion: AppSemanticVersion,
        updateChannel: UpdateChannel
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
        case .success(let releases):
            var candidates: [UpdateReleaseCandidate] = []
            var hasInvalidNewerRelease = false
            var hasUnavailableNewerRelease = false

            for release in releases where updateChannel.accepts(release) {
                guard let version = release.version else {
                    hasInvalidNewerRelease = true
                    continue
                }
                guard version > currentVersion else { continue }
                guard release.matchingAsset(for: version) != nil else {
                    hasUnavailableNewerRelease = true
                    continue
                }
                candidates.append(UpdateReleaseCandidate(release: release, version: version))
            }

            if let candidate = candidates.max(by: { $0.version < $1.version }) {
                availableRelease = candidate.release
                transition(to: .available(current: currentVersion, latest: candidate.version))
            } else {
                availableRelease = nil
                if hasUnavailableNewerRelease {
                    transition(to: .failed(.assetUnavailable))
                } else if hasInvalidNewerRelease {
                    transition(to: .failed(.invalidReleaseVersion))
                } else {
                    transition(to: .latest(current: currentVersion))
                }
            }
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
            transition(to: .installing(current: currentVersion, latest: latestVersion, progress: 0))
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
                        expectedBundleIdentifier: bundleIdentifier,
                        progress: { [weak self] progress in
                            guard let self else { return }
                            self.callbackQueue.async {
                                guard case .installing(let current, let latest, _) = self.state,
                                      current == currentVersion,
                                      latest == latestVersion
                                else { return }
                                self.transition(
                                    to: .installing(
                                        current: currentVersion,
                                        latest: latestVersion,
                                        progress: Self.clampProgress(progress)
                                    )
                                )
                            }
                        }
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

    private static func clampProgress(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }
}
