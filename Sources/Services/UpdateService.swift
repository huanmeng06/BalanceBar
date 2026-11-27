import Foundation
import AppKit
#if canImport(CryptoKit)
import CryptoKit
#endif

enum GitHubReleaseClientError: Error {
    case transport
    case httpStatus(Int)
    case rateLimited(GitHubRateLimitInfo)
    case invalidResponse
}

/// Rate-limit signal extracted from a GitHub API response. `retryAfter` is
/// already resolved into seconds measured from the response moment: a
/// `Retry-After` delay (or HTTP date), or `X-RateLimit-Reset` minus the
/// response time for the primary unauthenticated limit. It is nil when the
/// response indicates rate limiting but carries no usable recovery time.
struct GitHubRateLimitInfo: Equatable {
    let statusCode: Int
    let rateLimitRemaining: Int?
    let retryAfter: TimeInterval?
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
        // Release checks must always validate the current network state. A
        // cached 2xx response would make an offline manual check look like a
        // successful latest/available result.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
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
                if let rateLimit = Self.rateLimitInfo(
                    from: httpResponse,
                    body: data,
                    responseEpoch: Date().timeIntervalSince1970
                ) {
                    completion(.failure(.rateLimited(rateLimit)))
                } else {
                    completion(.failure(.httpStatus(httpResponse.statusCode)))
                }
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

    /// Classifies GitHub rate limiting from the status code, response
    /// headers, and error body. HTTP 429 is always rate limiting. HTTP 403 is
    /// rate limiting with any of the documented signals: an exhausted
    /// unauthenticated quota (`X-RateLimit-Remaining: 0`, governed by
    /// `X-RateLimit-Reset`), a secondary limit signalled by `Retry-After`, or
    /// an error body whose `message` names the secondary limit — some
    /// secondary limits send neither header. Any other 403 stays a plain
    /// forbidden error so the UI does not blame request frequency.
    static func rateLimitInfo(
        from response: HTTPURLResponse,
        body: Data?,
        responseEpoch: TimeInterval
    ) -> GitHubRateLimitInfo? {
        let statusCode = response.statusCode
        guard statusCode == 429 || statusCode == 403 else { return nil }
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            .flatMap { Int($0) }
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap { TimeInterval($0) }
        let retryAfter = parseRetryAfterInterval(
            response.value(forHTTPHeaderField: "Retry-After"),
            now: responseEpoch
        )
        let bodySignalsSecondaryLimit = statusCode == 403
            && Self.errorBodySignalsSecondaryRateLimit(body)
        guard statusCode == 429 || remaining == 0 || retryAfter != nil || bodySignalsSecondaryLimit
        else { return nil }
        let resolvedRetryAfter: TimeInterval?
        if let retryAfter {
            resolvedRetryAfter = retryAfter
        } else if let reset, remaining == 0 {
            resolvedRetryAfter = max(0, reset - responseEpoch)
        } else {
            resolvedRetryAfter = nil
        }
        return GitHubRateLimitInfo(
            statusCode: statusCode,
            rateLimitRemaining: remaining,
            retryAfter: resolvedRetryAfter
        )
    }

    /// GitHub's secondary limit rejections name themselves in the error
    /// body's `message` field, with no rate-limit headers on some variants.
    static func errorBodySignalsSecondaryRateLimit(_ body: Data?) -> Bool {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = object["message"] as? String
        else { return false }
        let lowered = message.lowercased()
        return lowered.contains("secondary rate limit")
            || lowered.contains("abuse detection mechanism")
    }

    private static func parseRetryAfterInterval(_ value: String?, now: TimeInterval) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed) {
            return max(0, seconds)
        }
        guard let date = Self.retryAfterDateFormatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSince1970 - now)
    }

    private static let retryAfterDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}

/// Reads a local release JSON fixture for development-only manual UI testing.
/// App composition gates this fetcher to the development bundle, so the
/// production app always uses GitHub's public releases endpoint.
final class LocalGitHubReleaseFixture: GitHubReleaseFetching {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Re-read on every fetch so a manual test can edit the file between retries.
    /// `{"rateLimited": <seconds>}` simulates a GitHub rate limit with that wait.
    func fetchReleases(completion: @escaping (Result<[GitHubRelease], GitHubReleaseClientError>) -> Void) {
        guard let data = try? Data(contentsOf: fileURL) else {
            completion(.failure(.invalidResponse))
            return
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let wait = (object["rateLimited"] as? NSNumber)?.doubleValue {
            completion(.failure(.rateLimited(GitHubRateLimitInfo(
                statusCode: 403, rateLimitRemaining: 0, retryAfter: wait))))
        } else if let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) {
            completion(.success(releases))
        } else if let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
            completion(.success([release]))
        } else {
            completion(.failure(.invalidResponse))
        }
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
    func cancelDownloads()
}

extension UpdateAssetDownloading {
    func cancelDownloads() {}

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

protocol UpdateVersionIgnoring {
    func ignoredVersion(for channel: UpdateChannel) -> AppSemanticVersion?
    func ignore(version: AppSemanticVersion, for channel: UpdateChannel)
}

final class UserDefaultsUpdateVersionIgnoreStore: UpdateVersionIgnoring {
    static let key = "ignoredUpdateVersions"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func ignoredVersion(for channel: UpdateChannel) -> AppSemanticVersion? {
        guard let versions = defaults.dictionary(forKey: Self.key) as? [String: String] else {
            return nil
        }
        return versions[channel.rawValue].flatMap(AppSemanticVersion.init)
    }

    func ignore(version: AppSemanticVersion, for channel: UpdateChannel) {
        var versions = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        versions[channel.rawValue] = version.description
        defaults.set(versions, forKey: Self.key)
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

enum SHA256Hex {
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
    private let sessionLock = NSLock()
    private var activeSessions: [UUID: URLSession] = [:]

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
        let sessionID = UUID()
        let delegate = UpdateAssetDownloadDelegate(
            sessionID: sessionID,
            asset: asset,
            fileManager: fileManager,
            progress: progress,
            completion: completion,
            restrictRedirectsToGitHub: url.host?.lowercased() == "github.com",
            didFinish: { [weak self] id in self?.removeSession(id) }
        )
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        sessionLock.lock()
        activeSessions[sessionID] = session
        sessionLock.unlock()
        progress(0)
        session.dataTask(with: request).resume()
    }

    func cleanupDownloadedFile(at url: URL) {
        try? fileManager.removeItem(at: url.deletingLastPathComponent())
    }

    func cancelDownloads() {
        sessionLock.lock()
        let sessions = Array(activeSessions.values)
        activeSessions.removeAll()
        sessionLock.unlock()
        sessions.forEach { $0.invalidateAndCancel() }
    }

    private func removeSession(_ id: UUID) {
        sessionLock.lock()
        activeSessions[id] = nil
        sessionLock.unlock()
    }
}

final class DevelopmentUpdateAssetFixture: UpdateAssetDownloading {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

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
        guard URL(fileURLWithPath: asset.name).lastPathComponent == asset.name,
              let data = try? Data(contentsOf: directoryURL.appendingPathComponent(asset.name)) else {
            completion(.failure(.invalidAsset))
            return
        }
        do {
            try UpdateAssetVerifier.verify(data: data, asset: asset)
            let destination = fileManager.temporaryDirectory
                .appendingPathComponent("BalanceBar-update-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            progress(0)
            let fileURL = destination.appendingPathComponent(asset.name)
            try data.write(to: fileURL, options: .atomic)
            progress(100)
            completion(.success(fileURL))
        } catch let error as UpdateAssetDownloadError {
            completion(.failure(error))
        } catch {
            completion(.failure(.writeFailed))
        }
    }

    func cleanupDownloadedFile(at url: URL) {
        try? fileManager.removeItem(at: url.deletingLastPathComponent())
    }
}

private final class UpdateAssetDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sessionID: UUID
    private let asset: GitHubReleaseAsset
    private let fileManager: FileManager
    private let progress: (Int) -> Void
    private let completion: (Result<URL, UpdateAssetDownloadError>) -> Void
    private let restrictRedirectsToGitHub: Bool
    private let didFinish: (UUID) -> Void
    private var response: HTTPURLResponse?
    private var expectedByteCount: Int64 = NSURLSessionTransferSizeUnknown
    private var receivedData = Data()
    private var didComplete = false
    private var didExceedAssetSize = false

    init(
        sessionID: UUID,
        asset: GitHubReleaseAsset,
        fileManager: FileManager,
        progress: @escaping (Int) -> Void,
        completion: @escaping (Result<URL, UpdateAssetDownloadError>) -> Void,
        restrictRedirectsToGitHub: Bool,
        didFinish: @escaping (UUID) -> Void
    ) {
        self.sessionID = sessionID
        self.asset = asset
        self.fileManager = fileManager
        self.progress = progress
        self.completion = completion
        self.restrictRedirectsToGitHub = restrictRedirectsToGitHub
        self.didFinish = didFinish
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if restrictRedirectsToGitHub {
            let host = response.url?.host?.lowercased()
            guard host == "github.com" || host == "release-assets.githubusercontent.com" else {
                completionHandler(.cancel)
                return
            }
        }
        self.response = response as? HTTPURLResponse
        expectedByteCount = response.expectedContentLength
        if let assetSize = asset.size, expectedByteCount > Int64(assetSize) {
            didExceedAssetSize = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let assetSize = asset.size,
           Int64(receivedData.count) + Int64(data.count) > Int64(assetSize) {
            didExceedAssetSize = true
            dataTask.cancel()
            return
        }
        receivedData.append(data)
        guard expectedByteCount > 0 else { return }
        let fraction = Double(receivedData.count) / Double(expectedByteCount)
        progress(Self.percent(for: fraction))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !didComplete else { return }
        didComplete = true
        defer {
            didFinish(sessionID)
            session.finishTasksAndInvalidate()
        }

        if didExceedAssetSize {
            completion(.failure(.sizeMismatch))
            return
        }
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
    case manualInstallationRequired
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
        var backupComplete = false
        var replaced = false
        do {
            // Keep an explicit backup until the relaunched process is known to
            // start. Relying on FileManager's optional backup name makes the
            // backup location/availability platform-dependent and can leave
            // the new bundle in place after a failed relaunch.
            try fileSystem.copyItem(at: currentApplicationURL, to: backupURL)
            backupComplete = true
            try fileSystem.replaceItem(
                at: currentApplicationURL,
                withItemAt: stagedApp,
                backupItemName: nil
            )
            replaced = true
            if currentApplicationURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
                try AutomaticUpdateCommand.recordSuccessfulReplacement(
                    applicationURL: currentApplicationURL,
                    backupURL: backupURL,
                    version: expectedVersion.description
                )
            }
        } catch {
            if replaced {
                try? fileSystem.replaceItem(at: currentApplicationURL, withItemAt: backupURL, backupItemName: nil)
            } else if !backupComplete {
                try? fileSystem.removeItem(at: backupURL)
            }
            throw UpdateInstallationError.replacementFailed
        }
        progress(80)

        do {
            try relauncher.relaunchApplication(at: currentApplicationURL)
        } catch {
            // Restore the old app if the new process could not be started.
            if (try? fileSystem.replaceItem(at: currentApplicationURL, withItemAt: backupURL, backupItemName: nil)) != nil,
               currentApplicationURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
                AutomaticUpdateCommand.clearTransaction()
            }
            throw UpdateInstallationError.relaunchFailed
        }
        progress(95)
        progress(100)
    }
}

protocol UpdateScheduling {
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
}

struct DispatchUpdateScheduler: UpdateScheduling {
    let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    var now: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: action)
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
    private let automaticUpdatesDirectory: URL?
    private let stageAutomaticUpdateApplication: (URL, URL, String, AppSemanticVersion) throws -> Void
    private let callbackQueue: DispatchQueue
    private let workQueue: DispatchQueue
    private let scheduler: UpdateScheduling
    private let minimumCheckingDuration: TimeInterval
    private let automaticCheckMinimumInterval: TimeInterval
    private let ignoredVersionStore: UpdateVersionIgnoring
    private var availableRelease: GitHubRelease?
    private var availableReleases: [GitHubRelease] = []
    private var checkingStartedAt: TimeInterval?
    private var lastCheckStartedAtByChannel: [UpdateChannel: TimeInterval] = [:]
    private var updateCheckGeneration: UInt64 = 0
    private var automaticDownloadGeneration: UInt64 = 0
    private var automaticCachedUpdateURL: URL?
    private var cachedAutomaticRelease: GitHubRelease?
    private var automaticCacheVerifier: UpdateSignatureVerifier?

    private(set) var state: UpdateCheckState
    /// Last verified update per channel. It survives re-checks and check
    /// failures so the update entry cannot disappear while a refresh runs or
    /// GitHub rate limits the request; only a confirmed newer server truth
    /// (no update, ignore, or a channel's own new candidate) replaces it.
    private struct RetainedUpdate: Equatable {
        let release: GitHubRelease
        let releases: [GitHubRelease]
        let latest: AppSemanticVersion
    }

    private var retainedUpdatesByChannel: [UpdateChannel: RetainedUpdate] = [:]
    /// Scheduler-clock deadline for the global (cross-channel) GitHub release
    /// endpoint cooldown. Server-guided waits use the response's
    /// `Retry-After` / `X-RateLimit-Reset`; unguided waits use capped
    /// exponential backoff. Manual checks may bypass the automatic minimum
    /// interval but never this cooldown.
    private var rateLimitedUntil: TimeInterval?
    private var rateLimitBackoffIndex = 0
    var updateChannel: UpdateChannel {
        didSet {
            guard oldValue != updateChannel else { return }
            cancelAutomaticUpdateDownload(transitionToAvailable: false)
            switch state {
            case .installing, .restarting:
                break
            default:
                discardAutomaticCache()
            }
            updateCheckGeneration &+= 1
            checkingStartedAt = nil
            applyRetainedUpdatePresentation(for: updateChannel)

            guard let currentVersion else { return }
            switch state {
            case .downloading, .installing, .restarting:
                // An update transaction already in progress is independent of
                // the channel selected for the next check.
                break
            case .automaticDownloading:
                if let retained = retainedUpdatesByChannel[updateChannel] {
                    transition(to: .available(current: currentVersion, latest: retained.latest))
                } else {
                    transition(to: .idle(current: currentVersion))
                }
            default:
                if let retained = retainedUpdatesByChannel[updateChannel] {
                    transition(to: .available(current: currentVersion, latest: retained.latest))
                } else {
                    transition(to: .idle(current: currentVersion))
                }
            }
        }
    }
    var onStateChange: ((UpdateCheckState) -> Void)?

    /// The release that produced the current available state. The dashboard
    /// uses this read-only seam for release notes and the GitHub link while
    /// the service remains the sole owner of update selection/install logic.
    var availableReleaseForPresentation: GitHubRelease? { availableRelease }

    /// The installed version the retained update was discovered against.
    var installedVersion: AppSemanticVersion? { currentVersion }

    /// The newer releases crossed by the current update, ordered from the
    /// target version back toward the installed version. The target release
    /// remains available separately for installation and its GitHub link.
    var availableReleasesForPresentation: [GitHubRelease] { availableReleases }

    var automaticUpdateInstallationRequest: AutomaticUpdateInstallationRequest? {
        guard case .automaticReady(_, let version) = state,
              let automaticCachedUpdateURL else { return nil }
        return AutomaticUpdateInstallationRequest(
            diskImageURL: automaticCachedUpdateURL,
            applicationURL: currentApplicationURL,
            expectedVersion: version.description,
            channel: updateChannel,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
    }

    private func discardAutomaticCache() {
        if let automaticCachedUpdateURL {
            try? FileManager.default.removeItem(at: automaticCachedUpdateURL.deletingLastPathComponent())
        }
        automaticCachedUpdateURL = nil
        cachedAutomaticRelease = nil
        automaticCacheVerifier = nil
    }

    func removeInstalledUpdateCaches() {
        removeAutomaticUpdateCacheDirectories { name in
            if name.hasPrefix(".download-") || name.hasPrefix("preflight-") {
                return true
            }
            guard let currentVersion, let version = AppSemanticVersion(name) else { return false }
            return version <= currentVersion
        }
    }

    private func pruneAutomaticUpdateCaches(keeping version: AppSemanticVersion) {
        removeAutomaticUpdateCacheDirectories { name in
            AppSemanticVersion(name) != nil && name != version.description
        }
    }

    private func removeAutomaticUpdateCacheDirectories(where shouldRemove: (String) -> Bool) {
        switch state {
        case .installing, .restarting:
            return
        default:
            break
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let updates = automaticUpdatesDirectory,
              (try? updates.deletingLastPathComponent().resourceValues(forKeys: keys).isSymbolicLink) == false,
              let properties = try? updates.resourceValues(forKeys: keys),
              properties.isDirectory == true, properties.isSymbolicLink == false,
              let children = try? FileManager.default.contentsOfDirectory(at: updates, includingPropertiesForKeys: Array(keys))
        else { return }

        for child in children where shouldRemove(child.lastPathComponent) {
            guard let properties = try? child.resourceValues(forKeys: keys),
                  properties.isDirectory == true, properties.isSymbolicLink == false else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    func restoreAutomaticUpdateOnLaunch(verifier: UpdateSignatureVerifier) {
        guard case .idle(let current) = state, let updates = automaticUpdatesDirectory,
              let bundleID = currentBundleIdentifier,
              let directories = try? FileManager.default.contentsOfDirectory(at: updates, includingPropertiesForKeys: nil)
        else { return }
        let channel = updateChannel
        for version in directories.compactMap({ AppSemanticVersion($0.lastPathComponent) }).sorted(by: >) {
            guard version > current, ignoredVersionStore.ignoredVersion(for: channel) != version else { continue }
            let directory = updates.appendingPathComponent(version.description)
            let dmg = directory.appendingPathComponent("BalanceBar-\(version).dmg")
            guard let cache = try? VerifiedUpdateCache(
                at: dmg, application: currentApplicationURL, bundleIdentifier: bundleID, channel: channel,
                current: current, expected: version, verifier: verifier
            ) else { continue }
            let manifest = cache.manifest
            let asset = GitHubReleaseAsset(
                name: manifest.asset.name,
                browserDownloadURL: URL(string: "https://github.com/huanmeng06/BalanceBar/releases/download/\(manifest.tag)/\(manifest.asset.name)"),
                size: cache.diskImage.count, digest: "sha256:\(manifest.asset.sha256)"
            )
            let release = GitHubRelease(tagName: manifest.tag, draft: false, prerelease: channel == .beta, assets: [asset])
            retainedUpdatesByChannel[channel] = RetainedUpdate(release: release, releases: [], latest: version)
            availableRelease = release
            automaticCachedUpdateURL = dmg
            cachedAutomaticRelease = release
            automaticCacheVerifier = verifier
            pruneAutomaticUpdateCaches(keeping: version)
            transition(to: .automaticReady(current: current, latest: version))
            return
        }
    }

    init(
        releaseFetcher: GitHubReleaseFetching = GitHubReleaseClient(),
        downloader: UpdateAssetDownloading = URLSessionUpdateAssetDownloader(),
        installer: UpdateApplicationInstalling = UpdateApplicationInstaller(),
        currentVersionString: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        currentApplicationURL: URL = Bundle.main.bundleURL,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        updateChannel: UpdateChannel = .stable,
        callbackQueue: DispatchQueue = .main,
        workQueue: DispatchQueue = DispatchQueue(label: "local.balancebar.update-install", qos: .userInitiated),
        scheduler: UpdateScheduling = DispatchUpdateScheduler(),
        minimumCheckingDuration: TimeInterval = 1.0,
        automaticCheckMinimumInterval: TimeInterval = 15 * 60,
        ignoredVersionStore: UpdateVersionIgnoring = UserDefaultsUpdateVersionIgnoreStore(),
        applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        stageAutomaticUpdateApplication: @escaping (URL, URL, String, AppSemanticVersion) throws -> Void =
            AutomaticUpdateCommand.stageVerifiedApplication
    ) {
        self.releaseFetcher = releaseFetcher
        self.downloader = downloader
        self.installer = installer
        self.currentVersion = currentVersionString.flatMap(AppSemanticVersion.init)
        self.currentApplicationURL = currentApplicationURL
        self.currentBundleIdentifier = currentBundleIdentifier
        self.automaticUpdatesDirectory = applicationSupportDirectory?
            .appendingPathComponent(currentBundleIdentifier ?? "com.huanmeng06.BalanceBar.app", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        self.stageAutomaticUpdateApplication = stageAutomaticUpdateApplication
        self.updateChannel = updateChannel
        self.callbackQueue = callbackQueue
        self.workQueue = workQueue
        self.scheduler = scheduler
        self.minimumCheckingDuration = max(0, minimumCheckingDuration)
        self.automaticCheckMinimumInterval = max(0, automaticCheckMinimumInterval)
        self.ignoredVersionStore = ignoredVersionStore
        if let currentVersion = self.currentVersion {
            self.state = .idle(current: currentVersion)
        } else {
            self.state = .failed(.invalidCurrentVersion)
        }
    }

    /// Starts the inexpensive automatic check used when the settings page is
    /// shown. A recent manual or automatic request counts toward the cooldown
    /// so redraws, window resizes, and repeated page-entry callbacks cannot
    /// create a request storm. Channel changes can bypass the cooldown after
    /// the caller has invalidated the previous channel's presentation state.
    /// Neither automatic path bypasses a GitHub rate-limit cooldown, and only
    /// the user-initiated channel change surfaces the refusal as feedback.
    func checkForUpdatesIfNeeded(force: Bool = false) {
        guard currentVersion != nil, !isBusy else { return }
        let channel = updateChannel
        if !force,
           let lastCheckStartedAt = lastCheckStartedAtByChannel[channel],
           scheduler.now - lastCheckStartedAt < automaticCheckMinimumInterval {
            return
        }
        if !force, rateLimitRemainingWait() != nil { return }
        performCheck(respectingRateLimitCooldown: true)
    }

    /// User-initiated check. A rate-limit cooldown is only our own politeness window: the
    /// limit is per source IP, so after the user switches proxy a retry must really go out.
    func checkForUpdates() {
        performCheck(respectingRateLimitCooldown: false)
    }

    private func performCheck(respectingRateLimitCooldown: Bool) {
        guard let currentVersion,
              !isBusy, checkingStartedAt == nil
        else { return }
        if respectingRateLimitCooldown, let remainingWait = rateLimitRemainingWait() {
            // A rate-limited endpoint stays rate limited no matter how the
            // check was triggered. Re-show the failure with the remaining
            // wait instead of spending another request.
            applyCheckFailure(
                .rateLimited(retryAfter: remainingWait),
                currentVersion: currentVersion,
                updateChannel: updateChannel
            )
            return
        }
        let updateChannel = self.updateChannel
        let updateCheckGeneration = self.updateCheckGeneration
        let checkStartedAt = scheduler.now
        lastCheckStartedAtByChannel[updateChannel] = checkStartedAt
        checkingStartedAt = checkStartedAt
        if let retained = retainedUpdatesByChannel[updateChannel] {
            availableRelease = retained.release
            availableReleases = retained.releases
            if automaticUpdateInstallationRequest == nil {
                transition(to: .revalidating(current: currentVersion, latest: retained.latest))
            }
        } else {
            availableRelease = nil
            availableReleases = []
            transition(to: .checking(current: currentVersion))
        }
        releaseFetcher.fetchReleases { [weak self] result in
            guard let self else { return }
            self.callbackQueue.async {
                self.finishReleaseResultAfterMinimumCheckingDuration(
                    result,
                    currentVersion: currentVersion,
                    updateChannel: updateChannel,
                    updateCheckGeneration: updateCheckGeneration
                )
            }
        }
    }

    /// Retires the advertised version. Every state that shows a valid
    /// candidate — including the retained-update states reached from the
    /// release notes window — must honor the ignore action, otherwise the
    /// window closes while the badge survives and the action looks broken.
    func ignoreAvailableUpdate() {
        let latest: AppSemanticVersion
        switch state {
        case .available(_, let advertised):
            latest = advertised
        case .automaticDownloading(_, let advertised, _):
            latest = advertised
        case .automaticReady(_, let advertised), .automaticInstallationFailed(_, let advertised),
             .automaticDownloadFailed(_, let advertised, _), .automaticNeedsManual(_, let advertised):
            latest = advertised
        case .revalidating(_, let advertised):
            latest = advertised
        case .recheckFailed(_, let advertised, _):
            latest = advertised
        default:
            return
        }
        guard let currentVersion else { return }
        ignoredVersionStore.ignore(version: latest, for: updateChannel)
        cancelAutomaticUpdateDownload(transitionToAvailable: false)
        discardAutomaticCache()
        retainedUpdatesByChannel[updateChannel] = nil
        availableRelease = nil
        availableReleases = []
        transition(to: .latest(current: currentVersion))
    }

    func prepareAutomaticUpdate(
        verifier: UpdateSignatureVerifier = UpdateSignatureVerifier(),
        completion: @escaping (Result<URL?, UpdateFailure>) -> Void
    ) {
        let candidate: (release: GitHubRelease, version: AppSemanticVersion)
        switch state {
        case .available(_, let version), .revalidating(_, let version), .recheckFailed(_, let version, _):
            guard let release = availableRelease else { return }
            candidate = (release, version)
        default:
            return
        }
        guard let currentVersion else { return }
        let channel = updateChannel
        guard let dmgAsset = candidate.release.matchingAsset(for: candidate.version),
              let manifestAsset = candidate.release.assets.first(where: { $0.name == "BalanceBar-\(candidate.version).update.json" }),
              let signatureAsset = candidate.release.assets.first(where: { $0.name == "BalanceBar-\(candidate.version).update.json.sig" }) else {
            transition(to: .automaticNeedsManual(current: currentVersion, latest: candidate.version))
            callbackQueue.async { completion(.success(nil)) }
            return
        }
        guard verifier.hasTrustedKeys else {
            transition(to: .automaticNeedsManual(current: currentVersion, latest: candidate.version))
            callbackQueue.async { completion(.success(nil)) }
            return
        }
        guard Self.isOfficialReleaseAsset(manifestAsset),
              Self.isOfficialReleaseAsset(signatureAsset),
              Self.isOfficialReleaseAsset(dmgAsset),
              let manifestSize = manifestAsset.size, (1...16 * 1024).contains(manifestSize),
              let signatureSize = signatureAsset.size, (1...4 * 1024).contains(signatureSize) else {
            transition(to: .automaticNeedsManual(current: currentVersion, latest: candidate.version))
            callbackQueue.async { completion(.success(nil)) }
            return
        }

        if let cachedUpdate = restoreCachedAutomaticUpdate(
            for: candidate.version,
            release: candidate.release,
            dmgAsset: dmgAsset,
            verifier: verifier,
            currentVersion: currentVersion
        ) {
            automaticCachedUpdateURL = cachedUpdate
            cachedAutomaticRelease = candidate.release
            automaticCacheVerifier = verifier
            pruneAutomaticUpdateCaches(keeping: candidate.version)
            transition(to: .automaticReady(current: currentVersion, latest: candidate.version))
            callbackQueue.async { completion(.success(cachedUpdate)) }
            return
        }

        automaticDownloadGeneration &+= 1
        automaticCacheVerifier = verifier
        let generation = automaticDownloadGeneration
        transition(to: .automaticDownloading(current: currentVersion, latest: candidate.version, progress: 0))
        downloader.download(asset: manifestAsset, progress: { [weak self] percent in
            self?.reportAutomaticProgress(min(10, max(0, percent / 10)), generation: generation, version: candidate.version)
        }) { [weak self] manifestResult in
            guard let self else { return }
            guard self.automaticDownloadGeneration == generation else {
                if case .success(let url) = manifestResult { self.downloader.cleanupDownloadedFile(at: url) }
                return
            }
            guard case .success(let manifestURL) = manifestResult else {
                self.finishAutomaticUpdate(
                    .failure(Self.failure(for: manifestResult)),
                    generation: generation,
                    completion: completion
                )
                return
            }
            defer { self.downloader.cleanupDownloadedFile(at: manifestURL) }
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  manifestData.count <= 16 * 1024 else {
                self.finishAutomaticUpdate(.failure(.verificationFailed), generation: generation, completion: completion)
                return
            }
            self.downloader.download(asset: signatureAsset, progress: { [weak self] percent in
                self?.reportAutomaticProgress(10 + min(10, max(0, percent / 10)), generation: generation, version: candidate.version)
            }) { [weak self] signatureResult in
                guard let self else { return }
                guard self.automaticDownloadGeneration == generation else {
                    if case .success(let url) = signatureResult { self.downloader.cleanupDownloadedFile(at: url) }
                    return
                }
                guard case .success(let signatureURL) = signatureResult else {
                    self.finishAutomaticUpdate(
                        .failure(Self.failure(for: signatureResult)),
                        generation: generation,
                        completion: completion
                    )
                    return
                }
                defer { self.downloader.cleanupDownloadedFile(at: signatureURL) }
                guard let signatureData = try? Data(contentsOf: signatureURL),
                      let manifest = try? verifier.verify(manifestData: manifestData, signatureData: signatureData),
                      manifest.version == candidate.version.description,
                      manifest.tag == candidate.release.tagName,
                      manifest.channel == channel.rawValue,
                      candidate.release.prerelease == (channel == .beta),
                      manifest.bundleIdentifier == self.currentBundleIdentifier,
                      manifest.asset.size == Int64(dmgAsset.size ?? -1),
                      manifest.asset.name == dmgAsset.name,
                      candidate.version > currentVersion else {
                    self.finishAutomaticUpdate(.failure(.verificationFailed), generation: generation, completion: completion)
                    return
                }
                self.downloader.download(asset: dmgAsset, progress: { [weak self] percent in
                    self?.reportAutomaticProgress(20 + min(80, max(0, percent * 80 / 100)), generation: generation, version: candidate.version)
                }) { [weak self] dmgResult in
                    guard let self else { return }
                    guard self.automaticDownloadGeneration == generation else {
                        if case .success(let url) = dmgResult { self.downloader.cleanupDownloadedFile(at: url) }
                        return
                    }
                    guard case .success(let downloadedDMG) = dmgResult else {
                        self.finishAutomaticUpdate(
                            .failure(Self.failure(for: dmgResult)),
                            generation: generation,
                            completion: completion
                        )
                        return
                    }
                    self.workQueue.async {
                        defer { self.downloader.cleanupDownloadedFile(at: downloadedDMG) }
                        guard let dmgData = try? Data(contentsOf: downloadedDMG, options: .mappedIfSafe),
                              Int64(dmgData.count) == manifest.asset.size,
                              SHA256Hex.digest(dmgData) == manifest.asset.sha256 else {
                            self.finishAutomaticUpdate(.failure(.verificationFailed), generation: generation, completion: completion)
                            return
                        }
                        do {
                            guard let updates = self.automaticUpdatesDirectory else { throw UpdateFailure.downloadFailed }
                            let bundleIdentifier = self.currentBundleIdentifier ?? "com.huanmeng06.BalanceBar.app"
                            let directory = updates.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            let stagedApp = directory.appendingPathComponent("BalanceBar.app", isDirectory: true)
                            do {
                                try self.stageAutomaticUpdateApplication(downloadedDMG, stagedApp, bundleIdentifier, candidate.version)
                                try FileManager.default.removeItem(at: stagedApp)
                            } catch {
                                try? FileManager.default.removeItem(at: directory)
                                self.finishAutomaticUpdate(.failure(.verificationFailed), generation: generation, completion: completion)
                                return
                            }
                            let cachedDMG = directory.appendingPathComponent(dmgAsset.name)
                            let cachedManifest = directory.appendingPathComponent(manifestAsset.name)
                            let cachedSignature = directory.appendingPathComponent(signatureAsset.name)
                            try dmgData.write(to: cachedDMG, options: .atomic)
                            try manifestData.write(to: cachedManifest, options: .atomic)
                            try signatureData.write(to: cachedSignature, options: .atomic)
                            let context = [
                                "applicationPath": self.currentApplicationURL.path,
                                "channel": channel.rawValue,
                                "version": candidate.version.description,
                                "sha256": manifest.asset.sha256
                            ]
                            let contextData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
                            try contextData.write(
                                to: directory.appendingPathComponent("install-context.json"),
                                options: .atomic
                            )
                            self.callbackQueue.async {
                                defer { try? FileManager.default.removeItem(at: directory) }
                                guard self.automaticDownloadGeneration == generation else { return }
                                let destination = updates.appendingPathComponent(candidate.version.description, isDirectory: true)
                                do {
                                    if FileManager.default.fileExists(atPath: destination.path) {
                                        try FileManager.default.removeItem(at: destination)
                                    }
                                    try FileManager.default.moveItem(at: directory, to: destination)
                                    self.finishAutomaticUpdate(
                                        .success(destination.appendingPathComponent(dmgAsset.name)),
                                        generation: generation, completion: completion
                                    )
                                } catch {
                                    self.finishAutomaticUpdate(.failure(.downloadFailed), generation: generation, completion: completion)
                                }
                            }
                        } catch {
                            self.finishAutomaticUpdate(.failure(.downloadFailed), generation: generation, completion: completion)
                        }
                    }
                }
            }
        }
    }

    func cancelAutomaticUpdateDownload(transitionToAvailable: Bool = true) {
        automaticDownloadGeneration &+= 1
        if case .automaticDownloading(let current, let latest, _) = state {
            downloader.cancelDownloads()
            if transitionToAvailable {
                transition(to: .available(current: current, latest: latest))
            }
        }
    }

    func automaticUpdatesWereDisabled() {
        cancelAutomaticUpdateDownload()
        switch state {
        case .automaticReady(let current, let latest), .automaticInstallationFailed(let current, let latest):
            transition(to: .available(current: current, latest: latest))
        case .automaticDownloadFailed(let current, let latest, _), .automaticNeedsManual(let current, let latest):
            transition(to: .available(current: current, latest: latest))
        default:
            break
        }
    }

    private func finishAutomaticUpdate(
        _ result: Result<URL?, UpdateFailure>,
        generation: UInt64,
        completion: @escaping (Result<URL?, UpdateFailure>) -> Void
    ) {
        callbackQueue.async {
            guard self.automaticDownloadGeneration == generation else { return }
            switch result {
            case .success(let url):
                guard let currentVersion = self.currentVersion else { return }
                if let url {
                    self.automaticCachedUpdateURL = url
                    self.cachedAutomaticRelease = self.availableRelease
                    guard case .automaticDownloading(_, let latest, _) = self.state else { return }
                    self.pruneAutomaticUpdateCaches(keeping: latest)
                    self.transition(to: .automaticReady(current: currentVersion, latest: latest))
                }
            case .failure(let failure):
                guard case .automaticDownloading(let current, let latest, _) = self.state else { return }
                self.transition(to: .automaticDownloadFailed(current: current, latest: latest, failure: failure))
            }
            completion(result)
        }
    }

    private func reportAutomaticProgress(_ progress: Int, generation: UInt64, version: AppSemanticVersion) {
        callbackQueue.async {
            guard self.automaticDownloadGeneration == generation,
                  case .automaticDownloading(let current, let latest, _) = self.state,
                  latest == version else { return }
            self.transition(to: .automaticDownloading(
                current: current,
                latest: latest,
                progress: Self.clampProgress(progress)
            ))
        }
    }

    private static func isOfficialReleaseAsset(_ asset: GitHubReleaseAsset) -> Bool {
        guard let url = asset.browserDownloadURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else { return false }
        return url.path.hasPrefix("/huanmeng06/BalanceBar/releases/download/")
    }

    private static func failure(for result: Result<URL, UpdateAssetDownloadError>) -> UpdateFailure {
        guard case .failure(let error) = result else { return .downloadFailed }
        switch error {
        case .sizeMismatch, .digestMismatch, .emptyData:
            return .verificationFailed
        case .invalidAsset, .transport, .httpStatus, .writeFailed:
            return .downloadFailed
        }
    }

    private func restoreCachedAutomaticUpdate(
        for version: AppSemanticVersion,
        release: GitHubRelease,
        dmgAsset: GitHubReleaseAsset,
        verifier: UpdateSignatureVerifier,
        currentVersion: AppSemanticVersion
    ) -> URL? {
        guard let updates = automaticUpdatesDirectory else { return nil }
        let directory = updates.appendingPathComponent(version.description, isDirectory: true)
        let dmg = directory.appendingPathComponent(dmgAsset.name)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        guard let bundleID = currentBundleIdentifier,
              let cache = try? VerifiedUpdateCache(
                at: dmg, application: currentApplicationURL, bundleIdentifier: bundleID, channel: updateChannel,
                current: currentVersion, expected: version, verifier: verifier
              ),
              cache.manifest.tag == release.tagName, updateChannel.accepts(release),
              (try? UpdateAssetVerifier.verify(data: cache.diskImage, asset: dmgAsset)) != nil else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return dmg
    }

    private func finishReleaseResultAfterMinimumCheckingDuration(
        _ result: Result<[GitHubRelease], GitHubReleaseClientError>,
        currentVersion: AppSemanticVersion,
        updateChannel: UpdateChannel,
        updateCheckGeneration: UInt64
    ) {
        guard self.updateCheckGeneration == updateCheckGeneration,
              isReleaseCheckInFlight else { return }
        let elapsed = checkingStartedAt.map { scheduler.now - $0 } ?? minimumCheckingDuration
        let remaining = max(0, minimumCheckingDuration - elapsed)
        guard remaining > 0 else {
            handleReleaseResult(
                result,
                currentVersion: currentVersion,
                updateChannel: updateChannel,
                updateCheckGeneration: updateCheckGeneration
            )
            return
        }

        scheduler.schedule(after: remaining) { [weak self] in
            guard let self else { return }
            self.callbackQueue.async {
                guard self.updateCheckGeneration == updateCheckGeneration,
                      self.isReleaseCheckInFlight else { return }
                self.handleReleaseResult(
                    result,
                    currentVersion: currentVersion,
                    updateChannel: updateChannel,
                    updateCheckGeneration: updateCheckGeneration
                )
            }
        }
    }

    func installAvailableUpdate() {
        // A retained update stays installable after a failed re-check, and
        // stays installable while a re-check runs: the candidate release and
        // its asset were validated when discovered, and the download/install
        // pipeline re-verifies size, digest, and bundle metadata before
        // replacing anything. The in-flight re-check's result is discarded by
        // the state guards once the download transaction owns the state.
        let latestVersion: AppSemanticVersion
        switch state {
        case .automaticReady(_, let advertised):
            latestVersion = advertised
        case .automaticInstallationFailed(_, let advertised):
            latestVersion = advertised
        case .automaticNeedsManual(_, let advertised):
            latestVersion = advertised
        case .available(_, let latest):
            latestVersion = latest
        case .revalidating(_, let latest):
            latestVersion = latest
        case .recheckFailed(_, let latest, _):
            latestVersion = latest
        default:
            return
        }
        guard let currentVersion,
              let release = availableRelease,
              let asset = release.matchingAsset(for: latestVersion)
        else { return }
        if let automaticCachedUpdateURL, automaticCachedUpdateURL.lastPathComponent == asset.name {
            handleDownloadResult(.success(automaticCachedUpdateURL), currentVersion: currentVersion, latestVersion: latestVersion)
            return
        }
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
        case .checking, .revalidating, .downloading, .automaticDownloading, .installing, .restarting:
            return true
        case .idle, .latest, .available, .automaticReady, .automaticDownloadReady, .automaticIdleUpdated, .automaticInstallationFailed,
             .automaticDownloadFailed, .automaticNeedsManual, .recheckFailed, .failed:
            return false
        }
    }

    private var isReleaseCheckInFlight: Bool {
        switch state {
        case .checking, .revalidating, .automaticReady:
            return checkingStartedAt != nil
        default:
            return false
        }
    }

    private func rateLimitRemainingWait() -> TimeInterval? {
        guard let rateLimitedUntil else { return nil }
        let remaining = rateLimitedUntil - scheduler.now
        return remaining > 0 ? remaining : nil
    }

    private static func nextRateLimitBackoffDelay(index: inout Int) -> TimeInterval {
        let delay = min(60.0 * pow(2.0, Double(index)), 1800.0)
        index += 1
        return delay
    }

    /// Moves the machine out of an in-flight check after the request failed.
    /// A retained update keeps its badge, notes, and install entry, with the
    /// failure marked as this attempt's result; without a retained update the
    /// plain failure state applies.
    private func applyCheckFailure(
        _ failure: UpdateFailure,
        currentVersion: AppSemanticVersion,
        updateChannel: UpdateChannel
    ) {
        checkingStartedAt = nil
        if case .automaticReady = state { return }
        if let retained = retainedUpdatesByChannel[updateChannel] {
            transition(to: .recheckFailed(
                current: currentVersion,
                latest: retained.latest,
                failure: failure
            ))
        } else {
            availableRelease = nil
            availableReleases = []
            transition(to: .failed(failure))
        }
    }

    /// Swaps the visible release/notes to the selected channel's retained
    /// update, or clears them when that channel has none. A channel never
    /// inherits another channel's update entry.
    private func applyRetainedUpdatePresentation(for channel: UpdateChannel) {
        if let retained = retainedUpdatesByChannel[channel] {
            availableRelease = retained.release
            availableReleases = retained.releases
        } else {
            availableRelease = nil
            availableReleases = []
        }
    }

    private func handleReleaseResult(
        _ result: Result<[GitHubRelease], GitHubReleaseClientError>,
        currentVersion: AppSemanticVersion,
        updateChannel: UpdateChannel,
        updateCheckGeneration: UInt64
    ) {
        guard self.updateCheckGeneration == updateCheckGeneration,
              isReleaseCheckInFlight else { return }
        checkingStartedAt = nil
        switch result {
        case .failure(let error):
            switch error {
            case .rateLimited(let info):
                let wait = info.retryAfter ?? Self.nextRateLimitBackoffDelay(index: &rateLimitBackoffIndex)
                rateLimitedUntil = scheduler.now + max(0, wait)
                applyCheckFailure(
                    .rateLimited(retryAfter: wait),
                    currentVersion: currentVersion,
                    updateChannel: updateChannel
                )
            case .transport:
                rateLimitedUntil = nil
                applyCheckFailure(.network, currentVersion: currentVersion, updateChannel: updateChannel)
            case .httpStatus(let statusCode):
                rateLimitedUntil = nil
                applyCheckFailure(.httpStatus(statusCode), currentVersion: currentVersion, updateChannel: updateChannel)
            case .invalidResponse:
                rateLimitedUntil = nil
                applyCheckFailure(.invalidResponse, currentVersion: currentVersion, updateChannel: updateChannel)
            }
        case .success(let releases):
            rateLimitedUntil = nil
            rateLimitBackoffIndex = 0
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
                guard ignoredVersionStore.ignoredVersion(for: updateChannel) != version else {
                    continue
                }
                candidates.append(UpdateReleaseCandidate(release: release, version: version))
            }

            if let candidate = candidates.max(by: { $0.version < $1.version }) {
                let notesReleases = releaseNotesReleases(
                    from: releases,
                    currentVersion: currentVersion,
                    targetVersion: candidate.version,
                    targetRelease: candidate.release,
                    updateChannel: updateChannel
                )
                retainedUpdatesByChannel[updateChannel] = RetainedUpdate(
                    release: candidate.release,
                    releases: notesReleases,
                    latest: candidate.version
                )
                if let cachedAutomaticRelease, cachedAutomaticRelease.tagName != candidate.release.tagName {
                    discardAutomaticCache()
                }
                availableRelease = candidate.release
                availableReleases = notesReleases
                if case .automaticReady(_, let version) = state, version == candidate.version,
                   automaticCachedUpdateURL != nil { return }
                transition(to: .available(current: currentVersion, latest: candidate.version))
            } else {
                discardAutomaticCache()
                // A successful response is authoritative: a confirmed "no new
                // version" (or an ignored/unusable one) retires the retained
                // entry for this channel.
                retainedUpdatesByChannel[updateChannel] = nil
                availableRelease = nil
                availableReleases = []
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

    private func releaseNotesReleases(
        from releases: [GitHubRelease],
        currentVersion: AppSemanticVersion,
        targetVersion: AppSemanticVersion,
        targetRelease: GitHubRelease,
        updateChannel: UpdateChannel
    ) -> [GitHubRelease] {
        var versionedReleases = releases.compactMap { release -> (release: GitHubRelease, version: AppSemanticVersion)? in
            guard updateChannel.accepts(release),
                  let version = release.version,
                  version > currentVersion,
                  version <= targetVersion else {
                return nil
            }
            return (release: release, version: version)
        }
        // The selected target is always included, even if a future change to
        // the fetcher supplies a differently shaped list than the candidate
        // scan above. The installed version is intentionally excluded: the
        // notes window describes releases the user is moving through, not the
        // version already running.
        versionedReleases.append((release: targetRelease, version: targetVersion))
        versionedReleases.sort { left, right in
            if Self.sameVersion(left.version, right.version) {
                let leftIsTarget = left.release == targetRelease
                let rightIsTarget = right.release == targetRelease
                if leftIsTarget != rightIsTarget {
                    return leftIsTarget
                }
                let leftHasBody = Self.hasReleaseBody(left.release)
                let rightHasBody = Self.hasReleaseBody(right.release)
                if leftHasBody != rightHasBody {
                    return leftHasBody
                }
                return left.release.tagName < right.release.tagName
            }
            return left.version > right.version
        }

        var unique: [(release: GitHubRelease, version: AppSemanticVersion)] = []
        for entry in versionedReleases
        where !unique.contains(where: { Self.sameVersion($0.version, entry.version) }) {
            unique.append(entry)
        }
        return unique.map(\.release)
    }

    private static func sameVersion(_ lhs: AppSemanticVersion, _ rhs: AppSemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    private static func hasReleaseBody(_ release: GitHubRelease) -> Bool {
        guard let body = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !body.isEmpty
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
            let isAutomaticCache = automaticCachedUpdateURL == downloadedURL
            let channel = updateChannel
            let verifier = automaticCacheVerifier
            checkingStartedAt = nil
            transition(to: .installing(current: currentVersion, latest: latestVersion, progress: 0))
            guard let bundleIdentifier = currentBundleIdentifier else {
                if !isAutomaticCache { downloader.cleanupDownloadedFile(at: downloadedURL) }
                transition(to: .failed(.installationFailed))
                return
            }
            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    func install(_ image: URL) throws {
                        try self.installer.install(
                            diskImageURL: image,
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
                    }
                    if isAutomaticCache {
                        guard let verifier, let cache = try? VerifiedUpdateCache(
                            at: downloadedURL, application: self.currentApplicationURL, bundleIdentifier: bundleIdentifier,
                            channel: channel, current: currentVersion, expected: latestVersion, verifier: verifier
                        ) else {
                            self.callbackQueue.async {
                                self.discardAutomaticCache()
                                self.transition(to: .automaticDownloadFailed(current: currentVersion, latest: latestVersion, failure: .verificationFailed))
                            }
                            return
                        }
                        try cache.withDiskImage(install)
                    } else {
                        try install(downloadedURL)
                    }
                    if !isAutomaticCache {
                        self.downloader.cleanupDownloadedFile(at: downloadedURL)
                    }
                    self.callbackQueue.async {
                        if isAutomaticCache { self.automaticCachedUpdateURL = nil }
                        self.transition(to: .restarting(current: currentVersion, latest: latestVersion))
                    }
                } catch {
                    if !isAutomaticCache {
                        self.downloader.cleanupDownloadedFile(at: downloadedURL)
                    }
                    self.callbackQueue.async {
                        self.transition(to: isAutomaticCache
                            ? .automaticInstallationFailed(current: currentVersion, latest: latestVersion)
                            : .failed(.installationFailed))
                    }
                }
            }
        }
    }

    private func transition(to newState: UpdateCheckState) {
        switch newState {
        case .checking, .revalidating, .automaticReady:
            break
        default:
            checkingStartedAt = nil
        }
        state = newState
        onStateChange?(newState)
    }

    private static func clampProgress(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }
}
