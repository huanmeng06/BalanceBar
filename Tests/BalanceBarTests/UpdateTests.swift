import Foundation
import AppKit
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import BalanceBar

final class UpdateTests: XCTestCase {
    private struct StubURLResult {
        let statusCode: Int
        let data: Data?
        let error: Error?

        init(statusCode: Int = 200, data: Data? = nil, error: Error? = nil) {
            self.statusCode = statusCode
            self.data = data
            self.error = error
        }
    }

    private final class StubURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var handler: ((URLRequest) -> StubURLResult)?
        private static var requests: [URLRequest] = []

        static func reset() {
            lock.lock()
            handler = nil
            requests = []
            lock.unlock()
        }

        static func setHandler(_ handler: @escaping (URLRequest) -> StubURLResult) {
            lock.lock()
            Self.handler = handler
            lock.unlock()
        }

        static var lastRequest: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return requests.last
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.requests.append(request)
            let result = Self.handler?(request) ?? StubURLResult(data: Data())
            Self.lock.unlock()
            if let error = result.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            var headers = ["Content-Type": "application/json"]
            if let data = result.data {
                headers["Content-Length"] = String(data.count)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = result.data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class StubReleaseFetcher: GitHubReleaseFetching {
        private(set) var requestCount = 0
        private var completions: [((Result<[GitHubRelease], GitHubReleaseClientError>) -> Void)] = []

        func fetchReleases(completion: @escaping (Result<[GitHubRelease], GitHubReleaseClientError>) -> Void) {
            requestCount += 1
            completions.append(completion)
        }

        func resolve(_ result: Result<[GitHubRelease], GitHubReleaseClientError>) {
            guard !completions.isEmpty else { return }
            let completion = completions.removeFirst()
            completion(result)
        }
    }

    private final class StubUpdateScheduler: UpdateScheduling {
        private struct ScheduledAction {
            let date: TimeInterval
            let action: () -> Void
        }

        private(set) var scheduledDelays: [TimeInterval] = []
        var onSchedule: ((TimeInterval) -> Void)?
        var now: TimeInterval
        private var scheduledActions: [ScheduledAction] = []

        init(now: TimeInterval = 1_000) {
            self.now = now
        }

        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
            scheduledDelays.append(delay)
            scheduledActions.append(ScheduledAction(date: now + delay, action: action))
            onSchedule?(delay)
        }

        func advance(by interval: TimeInterval) {
            now += interval
            let ready = scheduledActions.filter { $0.date <= now }
            scheduledActions.removeAll { $0.date <= now }
            ready.forEach { $0.action() }
        }
    }

    private final class StubDownloader: UpdateAssetDownloading {
        private(set) var requestCount = 0
        private(set) var cleanedURLs: [URL] = []
        private var progress: ((Int) -> Void)?
        private var completion: ((Result<URL, UpdateAssetDownloadError>) -> Void)?

        func download(
            asset: GitHubReleaseAsset,
            progress: @escaping (Int) -> Void,
            completion: @escaping (Result<URL, UpdateAssetDownloadError>) -> Void
        ) {
            requestCount += 1
            self.progress = progress
            self.completion = completion
        }

        func reportProgress(_ value: Int) {
            progress?(value)
        }

        func resolve(_ result: Result<URL, UpdateAssetDownloadError>) {
            completion?(result)
            progress = nil
            completion = nil
        }

        func cleanupDownloadedFile(at url: URL) {
            cleanedURLs.append(url)
        }
    }

    private final class StubInstaller: UpdateApplicationInstalling {
        var shouldFail = false
        var progressValues: [Int] = []
        private(set) var installCount = 0
        private(set) var lastVersion: AppSemanticVersion?

        func install(
            diskImageURL: URL,
            expectedVersion: AppSemanticVersion,
            currentApplicationURL: URL,
            expectedBundleIdentifier: String,
            progress: @escaping (Int) -> Void
        ) throws {
            installCount += 1
            lastVersion = expectedVersion
            progressValues.forEach(progress)
            if shouldFail { throw UpdateInstallationError.replacementFailed }
        }
    }

    private final class StubMounter: UpdateDiskImageMounting {
        let mountPoint: URL
        private(set) var mountCount = 0
        private(set) var unmountCount = 0

        init(mountPoint: URL) {
            self.mountPoint = mountPoint
        }

        func mount(diskImageURL: URL) throws -> MountedUpdateDiskImage {
            mountCount += 1
            return MountedUpdateDiskImage(mountPoint: mountPoint)
        }

        func unmount(_ image: MountedUpdateDiskImage) throws {
            unmountCount += 1
        }
    }

    private final class StubRelauncher: UpdateApplicationRelaunching {
        var shouldFail = false
        private(set) var relaunchCount = 0

        func relaunchApplication(at applicationURL: URL) throws {
            relaunchCount += 1
            if shouldFail { throw UpdateInstallationError.relaunchFailed }
        }
    }

    private final class StubProcessRunner: UpdateProcessRunning {
        var results: [UpdateProcessResult]
        private(set) var executableURLs: [URL] = []
        private(set) var arguments: [[String]] = []

        init(results: [UpdateProcessResult]) {
            self.results = results
        }

        func run(executableURL: URL, arguments: [String]) throws -> UpdateProcessResult {
            executableURLs.append(executableURL)
            self.arguments.append(arguments)
            return results.removeFirst()
        }
    }

    private final class StubDetachedProcessLauncher: UpdateDetachedProcessLaunching {
        private(set) var executableURL: URL?
        private(set) var arguments: [String]?
        var onLaunch: (() -> Void)?

        func launch(executableURL: URL, arguments: [String]) throws {
            self.executableURL = executableURL
            self.arguments = arguments
            onLaunch?()
        }
    }

    private final class StubApplicationTerminator: UpdateApplicationTerminating {
        var onTerminate: (() -> Void)?

        func terminateApplication() {
            onTerminate?()
        }
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.finishTasksAndInvalidate()
        session = nil
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - SemVer, release decoding, and HTTP boundaries

    func testSemanticVersionOrderingSupportsOptionalVAndSemVerPrecedence() throws {
        let release = try XCTUnwrap(AppSemanticVersion("v1.2.3"))
        XCTAssertEqual(release.description, "1.2.3")
        XCTAssertTrue(try XCTUnwrap(AppSemanticVersion("1.2.4")) > release)
        XCTAssertTrue(try XCTUnwrap(AppSemanticVersion("1.3.0")) > release)
        XCTAssertTrue(try XCTUnwrap(AppSemanticVersion("2.0.0")) > release)
        XCTAssertTrue(try XCTUnwrap(AppSemanticVersion("1.2.3")) == release)
        XCTAssertTrue(try XCTUnwrap(AppSemanticVersion("1.2.3-beta")) < release)
        let beta2 = try XCTUnwrap(AppSemanticVersion("1.2.3-beta.2"))
        let beta11 = try XCTUnwrap(AppSemanticVersion("1.2.3-beta.11"))
        XCTAssertTrue(beta2 < beta11)
        XCTAssertNil(AppSemanticVersion("1.02.3"))
        XCTAssertNil(AppSemanticVersion("1.2"))
        XCTAssertNil(AppSemanticVersion("1.2.3-01"))
    }

    func testReleaseDecodingFiltersStableReleaseAssetByExactVersionName() throws {
        let body = releaseBody(
            tag: "v1.0.0",
            draft: false,
            prerelease: false,
            body: "Release body",
            htmlURL: "https://github.com/huanmeng06/BalanceBar/releases/tag/v1.0.0",
            assets: [
                ["name": "BalanceBar-1.0.0.zip", "browser_download_url": "https://example.test/wrong.zip", "size": 1],
                ["name": "BalanceBar-1.0.0.dmg", "browser_download_url": "https://example.test/BalanceBar-1.0.0.dmg", "size": 4, "digest": "sha256:fixture"]
            ]
        )
        let release = try JSONDecoder().decode(GitHubRelease.self, from: body)
        XCTAssertEqual(release.body, "Release body")
        XCTAssertEqual(release.releaseURL?.absoluteString, "https://github.com/huanmeng06/BalanceBar/releases/tag/v1.0.0")
        XCTAssertEqual(
            GitHubRelease(
                tagName: "v1.0.0",
                draft: false,
                prerelease: false,
                assets: [],
                htmlURL: URL(string: "file:///tmp/untrusted")
            ).releaseURL?.absoluteString,
            "https://github.com/huanmeng06/BalanceBar/releases/tag/v1.0.0"
        )
        let version = try XCTUnwrap(release.stableVersion)
        XCTAssertEqual(version, AppSemanticVersion("1.0.0"))
        XCTAssertEqual(release.matchingAsset(for: version)?.name, "BalanceBar-1.0.0.dmg")
        XCTAssertNil(GitHubRelease(
            tagName: "v1.0.0",
            draft: false,
            prerelease: true,
            assets: []
        ).stableVersion)
    }

    func testGitHubReleaseClientUsesReleaseListEndpointAndPublicHeaders() throws {
        let endpoint = URL(string: "https://api.github.test/repos/huanmeng06/BalanceBar/releases")!
        StubURLProtocol.setHandler { _ in
            StubURLResult(data: self.releaseListBody(tag: "v1.0.1", assets: []))
        }
        let client = GitHubReleaseClient(session: session, endpoint: endpoint)
        let expectation = expectation(description: "release fetched")
        var result: Result<[GitHubRelease], GitHubReleaseClientError>?
        client.fetchReleases { value in
            result = value
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        guard case .success(let releases) = result,
              let release = releases.first else {
            return XCTFail("expected decoded release, got \(String(describing: result))")
        }
        XCTAssertEqual(release.tagName, "v1.0.1")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, endpoint.path)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "per_page" })?.value, "100")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "BalanceBar")
    }

    func testGitHubReleaseClientSurfacesHTTPAndInvalidJSONFailures() {
        StubURLProtocol.setHandler { _ in
            StubURLResult(statusCode: 503, data: Data(#"{"message":"unavailable"}"#.utf8))
        }
        let httpExpectation = expectation(description: "http failure")
        var httpResult: Result<[GitHubRelease], GitHubReleaseClientError>?
        GitHubReleaseClient(session: session).fetchReleases {
            httpResult = $0
            httpExpectation.fulfill()
        }
        wait(for: [httpExpectation], timeout: 2)
        guard case .failure(.httpStatus(503)) = httpResult else {
            return XCTFail("expected HTTP failure, got \(String(describing: httpResult))")
        }

        StubURLProtocol.setHandler { _ in StubURLResult(data: Data("not-json".utf8)) }
        let jsonExpectation = expectation(description: "json failure")
        var jsonResult: Result<[GitHubRelease], GitHubReleaseClientError>?
        GitHubReleaseClient(session: session).fetchReleases {
            jsonResult = $0
            jsonExpectation.fulfill()
        }
        wait(for: [jsonExpectation], timeout: 2)
        guard case .failure(.invalidResponse) = jsonResult else {
            return XCTFail("expected JSON failure, got \(String(describing: jsonResult))")
        }
    }

    func testAssetDownloaderValidatesSizeDigestAndCleansTemporaryFile() throws {
        let data = Data("fixture-installer".utf8)
        let digest = sha256(data)
        StubURLProtocol.setHandler { _ in StubURLResult(data: data) }
        let asset = GitHubReleaseAsset(
            name: "BalanceBar-1.0.1.dmg",
            browserDownloadURL: URL(string: "https://example.test/BalanceBar-1.0.1.dmg"),
            size: data.count,
            digest: "sha256:\(digest)"
        )
        let downloader = URLSessionUpdateAssetDownloader(session: session)
        let expectation = expectation(description: "asset downloaded")
        var result: Result<URL, UpdateAssetDownloadError>?
        var progressValues: [Int] = []
        downloader.download(asset: asset, progress: { progressValues.append($0) }) {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        let downloadedURL: URL
        guard case .success(let url) = result else {
            return XCTFail("expected verified download, got \(String(describing: result))")
        }
        downloadedURL = url
        XCTAssertEqual(try Data(contentsOf: downloadedURL), data)
        XCTAssertEqual(progressValues.first, 0)
        XCTAssertEqual(progressValues.last, 100)
        downloader.cleanupDownloadedFile(at: downloadedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedURL.path))
    }

    func testAssetDownloaderRejectsDigestMismatchBeforeExposingPath() {
        StubURLProtocol.setHandler { _ in StubURLResult(data: Data("wrong".utf8)) }
        let asset = GitHubReleaseAsset(
            name: "BalanceBar-1.0.1.dmg",
            browserDownloadURL: URL(string: "https://example.test/BalanceBar-1.0.1.dmg"),
            size: 5,
            digest: "sha256:\(String(repeating: "0", count: 64))"
        )
        let expectation = expectation(description: "digest rejected")
        var result: Result<URL, UpdateAssetDownloadError>?
        URLSessionUpdateAssetDownloader(session: session).download(asset: asset) {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        guard case .failure(.digestMismatch) = result else {
            return XCTFail("expected digest mismatch, got \(String(describing: result))")
        }
    }

    func testAssetDownloaderRejectsInsecureURLAndSizeMismatch() {
        let insecureAsset = GitHubReleaseAsset(
            name: "BalanceBar-1.0.1.dmg",
            browserDownloadURL: URL(string: "http://example.test/BalanceBar-1.0.1.dmg"),
            size: nil,
            digest: nil
        )
        let insecureExpectation = expectation(description: "insecure asset rejected")
        var insecureResult: Result<URL, UpdateAssetDownloadError>?
        URLSessionUpdateAssetDownloader(session: session).download(asset: insecureAsset) {
            insecureResult = $0
            insecureExpectation.fulfill()
        }
        wait(for: [insecureExpectation], timeout: 2)
        guard case .failure(.invalidAsset) = insecureResult else {
            return XCTFail("expected insecure URL rejection, got \(String(describing: insecureResult))")
        }

        let data = Data("size-mismatch".utf8)
        StubURLProtocol.setHandler { _ in StubURLResult(data: data) }
        let sizeMismatchAsset = GitHubReleaseAsset(
            name: "BalanceBar-1.0.1.dmg",
            browserDownloadURL: URL(string: "https://example.test/BalanceBar-1.0.1.dmg"),
            size: data.count + 1,
            digest: nil
        )
        let sizeExpectation = expectation(description: "size mismatch rejected")
        var sizeResult: Result<URL, UpdateAssetDownloadError>?
        URLSessionUpdateAssetDownloader(session: session).download(asset: sizeMismatchAsset) {
            sizeResult = $0
            sizeExpectation.fulfill()
        }
        wait(for: [sizeExpectation], timeout: 2)
        guard case .failure(.sizeMismatch) = sizeResult else {
            return XCTFail("expected size mismatch, got \(String(describing: sizeResult))")
        }
    }

    // MARK: - State machine and retry isolation

    func testUpdateServiceReportsLatestForOlderReleaseAndIgnoresDraftOrPrerelease() throws {
        let fetcher = StubReleaseFetcher()
        let downloader = StubDownloader()
        let installer = StubInstaller()
        let queue = DispatchQueue(label: "UpdateTests.latest")
        let service = UpdateService(
            releaseFetcher: fetcher,
            downloader: downloader,
            installer: installer,
            currentVersionString: "1.0.6",
            currentApplicationURL: URL(fileURLWithPath: "/tmp/BalanceBar-test.app"),
            currentBundleIdentifier: "com.huanmeng06.BalanceBar.app",
            callbackQueue: queue,
            workQueue: queue
        )

        let firstLatest = waitForState(service, queue: queue) {
            if case .latest(let current) = $0 { return current == AppSemanticVersion("1.0.6") }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success([makeRelease(tag: "v1.0.0")]))
        wait(for: [firstLatest], timeout: 2)
        XCTAssertEqual(fetcher.requestCount, 1)

        let draftLatest = waitForState(service, queue: queue) { state in
            if case .latest = state { return true }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success([makeRelease(tag: "v9.0.0", draft: true)]))
        wait(for: [draftLatest], timeout: 2)

        let prereleaseLatest = waitForState(service, queue: queue) { state in
            if case .latest = state { return true }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success([makeRelease(tag: "v9.0.0", prerelease: true)]))
        wait(for: [prereleaseLatest], timeout: 2)
        XCTAssertEqual(downloader.requestCount, 0)
        XCTAssertEqual(installer.installCount, 0)
    }

    func testUpdateServiceStableChannelChoosesNewestInstallableStableRelease() throws {
        let fetcher = StubReleaseFetcher()
        let queue = DispatchQueue(label: "UpdateTests.stable-channel")
        let service = UpdateService(
            releaseFetcher: fetcher,
            downloader: StubDownloader(),
            installer: StubInstaller(),
            currentVersionString: "1.0.0",
            updateChannel: .stable,
            callbackQueue: queue,
            workQueue: queue
        )
        let available = waitForState(service, queue: queue) { state in
            if case .available(_, let latest) = state {
                return latest == AppSemanticVersion("1.0.5")
            }
            return false
        }

        let invalid = GitHubRelease(
            tagName: "not-semver",
            draft: false,
            prerelease: false,
            assets: []
        )
        service.checkForUpdates()
        fetcher.resolve(.success([
            makeRelease(tag: "v3.0.0", prerelease: true),
            makeRelease(tag: "v2.0.0", draft: true),
            makeRelease(tag: "v1.0.4", assets: []),
            makeRelease(tag: "v1.0.5"),
            invalid
        ]))

        wait(for: [available], timeout: 2)
        guard case .available(_, let latest) = service.state else {
            return XCTFail("expected stable update to be available")
        }
        XCTAssertEqual(latest, AppSemanticVersion("1.0.5"))
    }

    func testUpdateServiceBetaChannelCanSelectAValidPrereleaseAboveStable() throws {
        let fetcher = StubReleaseFetcher()
        let queue = DispatchQueue(label: "UpdateTests.beta-channel")
        let service = UpdateService(
            releaseFetcher: fetcher,
            downloader: StubDownloader(),
            installer: StubInstaller(),
            currentVersionString: "1.0.0",
            updateChannel: .beta,
            callbackQueue: queue,
            workQueue: queue
        )
        let available = waitForState(service, queue: queue) { state in
            if case .available(_, let latest) = state {
                return latest == AppSemanticVersion("2.0.0-beta.1")
            }
            return false
        }

        service.checkForUpdates()
        fetcher.resolve(.success([
            makeRelease(tag: "v1.1.0"),
            makeRelease(tag: "v2.0.0-beta.1", prerelease: true),
            makeRelease(tag: "v9.0.0", prerelease: true, assets: []),
            makeRelease(tag: "v8.0.0", draft: true)
        ]))

        wait(for: [available], timeout: 2)
        guard case .available(_, let latest) = service.state else {
            return XCTFail("expected beta update to be available")
        }
        XCTAssertEqual(latest, AppSemanticVersion("2.0.0-beta.1"))
    }

    func testUpdateServiceChannelSwitchResetsCandidatesInBothDirectionsAndAllowsRecheck() throws {
        let fetcher = StubReleaseFetcher()
        let downloader = StubDownloader()
        let queue = DispatchQueue(label: "UpdateTests.channel-switch")
        let service = UpdateService(
            releaseFetcher: fetcher,
            downloader: downloader,
            currentVersionString: "1.0.0",
            updateChannel: .beta,
            callbackQueue: queue,
            workQueue: queue,
            minimumCheckingDuration: 0
        )
        let stableRelease = makeRelease(tag: "v1.1.0")
        let betaRelease = makeRelease(tag: "v2.0.0-beta.1", prerelease: true)

        let betaAvailable = waitForState(service, queue: queue) { state in
            if case .available(_, let latest) = state {
                return latest == AppSemanticVersion("2.0.0-beta.1")
            }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success([stableRelease, betaRelease]))
        wait(for: [betaAvailable], timeout: 2)

        let resetToStable = waitForState(service, queue: queue) { state in
            if case .idle(let current) = state {
                return current == AppSemanticVersion("1.0.0")
            }
            return false
        }
        service.updateChannel = .stable
        wait(for: [resetToStable], timeout: 2)
        XCTAssertEqual(service.updateChannel, .stable)
        service.installAvailableUpdate()
        XCTAssertEqual(downloader.requestCount, 0, "switching channel must invalidate the old Beta candidate")

        let stableAvailable = waitForState(service, queue: queue) { state in
            if case .available(_, let latest) = state {
                return latest == AppSemanticVersion("1.1.0")
            }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success([stableRelease, betaRelease]))
        wait(for: [stableAvailable], timeout: 2)

        let resetToBeta = waitForState(service, queue: queue) { state in
            if case .idle(let current) = state {
                return current == AppSemanticVersion("1.0.0")
            }
            return false
        }
        service.updateChannel = .beta
        wait(for: [resetToBeta], timeout: 2)
        XCTAssertEqual(service.updateChannel, .beta)
        service.installAvailableUpdate()
        XCTAssertEqual(downloader.requestCount, 0, "switching channel must invalidate the old Stable candidate")

        let betaAvailableAgain = waitForState(service, queue: queue) { state in
            if case .available(_, let latest) = state {
                return latest == AppSemanticVersion("2.0.0-beta.1")
            }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success([stableRelease, betaRelease]))
        wait(for: [betaAvailableAgain], timeout: 2)
    }

    func testUpdateServiceIgnoresInFlightResponseFromPreviousChannel() {
        let fetcher = StubReleaseFetcher()
        let queue = DispatchQueue(label: "UpdateTests.channel-switch.in-flight")
        let service = UpdateService(
            releaseFetcher: fetcher,
            currentVersionString: "1.0.0",
            updateChannel: .beta,
            callbackQueue: queue,
            workQueue: queue,
            minimumCheckingDuration: 0
        )

        service.checkForUpdates()
        XCTAssertEqual(fetcher.requestCount, 1)

        let reset = waitForState(service, queue: queue) { state in
            if case .idle = state { return true }
            return false
        }
        service.updateChannel = .stable
        wait(for: [reset], timeout: 2)

        service.checkForUpdates()
        XCTAssertEqual(fetcher.requestCount, 2)
        if case .checking = service.state {
            // The new Stable request owns the visible checking state.
        } else {
            XCTFail("the new channel check should be visible as checking")
        }

        fetcher.resolve(.success([makeRelease(tag: "v2.0.0-beta.1", prerelease: true)]))
        queue.sync {}
        if case .checking = service.state {
            // The stale Beta response must not settle the new Stable check.
        } else {
            XCTFail("a stale Beta response changed the new Stable state")
        }

        let latest = waitForState(service, queue: queue) { state in
            if case .latest(let current) = state {
                return current == AppSemanticVersion("1.0.0")
            }
            return false
        }
        fetcher.resolve(.success([makeRelease(tag: "v1.0.0")]))
        wait(for: [latest], timeout: 2)
    }

    func testUpdateServiceKeepsInstallTransactionWhenChannelChanges() {
        let fetcher = StubReleaseFetcher()
        let downloader = StubDownloader()
        let installer = StubInstaller()
        let queue = DispatchQueue(label: "UpdateTests.channel-switch.transaction")
        let service = UpdateService(
            releaseFetcher: fetcher,
            downloader: downloader,
            installer: installer,
            currentVersionString: "1.0.0",
            currentApplicationURL: URL(fileURLWithPath: "/tmp/BalanceBar-test.app"),
            currentBundleIdentifier: "com.huanmeng06.BalanceBar.app",
            updateChannel: .beta,
            callbackQueue: queue,
            workQueue: queue,
            minimumCheckingDuration: 0
        )

        let available = waitForState(service, queue: queue) { state in
            if case .available(_, let latest) = state {
                return latest == AppSemanticVersion("1.0.1")
            }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success([makeRelease(tag: "v1.0.1", prerelease: true)]))
        wait(for: [available], timeout: 2)

        service.installAvailableUpdate()
        if case .downloading = service.state {
            // The existing download remains active across a channel change.
        } else {
            XCTFail("expected the update download to be active")
        }
        service.updateChannel = .stable
        if case .downloading = service.state {
            // Channel selection must not cancel an already started transaction.
        } else {
            XCTFail("channel switching cancelled an active update transaction")
        }

        let restarting = waitForState(service, queue: queue) { state in
            if case .restarting(_, let latest) = state {
                return latest == AppSemanticVersion("1.0.1")
            }
            return false
        }
        downloader.resolve(.success(URL(fileURLWithPath: "/tmp/verified-BalanceBar-1.0.1.dmg")))
        wait(for: [restarting], timeout: 2)
        XCTAssertEqual(installer.installCount, 1)
    }

    func testUpdateServiceLatestStateAllowsRetry() {
        let fetcher = StubReleaseFetcher()
        let queue = DispatchQueue(label: "UpdateTests.latest-retry")
        let service = UpdateService(
            releaseFetcher: fetcher,
            currentVersionString: "1.0.0",
            callbackQueue: queue,
            workQueue: queue
        )
        let firstLatest = waitForState(service, queue: queue) { state in
            if case .latest = state { return true }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success([makeRelease(tag: "v1.0.0")]))
        wait(for: [firstLatest], timeout: 2)
        XCTAssertEqual(fetcher.requestCount, 1)

        let secondChecking = waitForState(service, queue: queue) { state in
            if case .checking = state { return true }
            return false
        }
        service.checkForUpdates()
        wait(for: [secondChecking], timeout: 2)
        XCTAssertEqual(fetcher.requestCount, 2)

        let secondLatest = waitForState(service, queue: queue) { state in
            if case .latest = state { return true }
            return false
        }
        fetcher.resolve(.success([makeRelease(tag: "v1.0.0")]))
        wait(for: [secondLatest], timeout: 2)
    }

    func testUpdateServiceFailureStateAllowsRetry() {
        let fetcher = StubReleaseFetcher()
        let queue = DispatchQueue(label: "UpdateTests.failure-retry")
        let service = UpdateService(
            releaseFetcher: fetcher,
            currentVersionString: "1.0.0",
            callbackQueue: queue,
            workQueue: queue
        )
        let firstFailure = waitForState(service, queue: queue) { state in
            if case .failed(.network) = state { return true }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.failure(.transport))
        wait(for: [firstFailure], timeout: 2)

        let secondChecking = waitForState(service, queue: queue) { state in
            if case .checking = state { return true }
            return false
        }
        service.checkForUpdates()
        wait(for: [secondChecking], timeout: 2)
        XCTAssertEqual(fetcher.requestCount, 2)

        let secondLatest = waitForState(service, queue: queue) { state in
            if case .latest = state { return true }
            return false
        }
        fetcher.resolve(.success([makeRelease(tag: "v1.0.0")]))
        wait(for: [secondLatest], timeout: 2)
    }

    func testUpdateServiceRejectsInvalidStableReleaseVersion() throws {
        let current = try XCTUnwrap(AppSemanticVersion("1.0.6"))
        let release = GitHubRelease(
            tagName: "not-semver",
            draft: false,
            prerelease: false,
            assets: []
        )
        let fetcher = StubReleaseFetcher()
        let queue = DispatchQueue(label: "UpdateTests.invalid-version")
        let service = UpdateService(
            releaseFetcher: fetcher,
            currentVersionString: current.description,
            callbackQueue: queue,
            workQueue: queue
        )
        let failure = waitForState(service, queue: queue) {
            if case .failed(.invalidReleaseVersion) = $0 { return true }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success([release]))
        wait(for: [failure], timeout: 2)
    }

    func testUpdateServiceDoesNotTreatMainAheadOfReleaseAsAvailable() {
        let fetcher = StubReleaseFetcher()
        let service = UpdateService(
            releaseFetcher: fetcher,
            downloader: StubDownloader(),
            installer: StubInstaller(),
            currentVersionString: "1.0.6",
            callbackQueue: DispatchQueue.main,
            workQueue: DispatchQueue.main,
            minimumCheckingDuration: 0
        )
        service.checkForUpdates()
        fetcher.resolve(.success([makeRelease(tag: "v1.0.0")]))
        let settled = expectation(description: "latest state")
        DispatchQueue.main.async {
            if case .latest = service.state { settled.fulfill() }
        }
        wait(for: [settled], timeout: 2)
        if case .available = service.state {
            XCTFail("an older Release must not be reported as available")
        }
    }

    func testUpdateServiceRequiresMatchingAssetAndPreventsDuplicateChecks() {
        let fetcher = StubReleaseFetcher()
        let queue = DispatchQueue(label: "UpdateTests.boundaries")
        let service = UpdateService(
            releaseFetcher: fetcher,
            downloader: StubDownloader(),
            installer: StubInstaller(),
            currentVersionString: "1.0.0",
            callbackQueue: queue,
            workQueue: queue
        )
        service.checkForUpdates()
        service.checkForUpdates()
        XCTAssertEqual(fetcher.requestCount, 1)

        let failure = waitForState(service, queue: queue) {
            if case .failed(.assetUnavailable) = $0 { return true }
            return false
        }
        fetcher.resolve(.success([makeRelease(tag: "v1.0.1", assets: [])]))
        wait(for: [failure], timeout: 2)
    }

    func testUpdateServiceDownloadsInstallsCleansUpAndExposesRestartingState() {
        let fetcher = StubReleaseFetcher()
        let downloader = StubDownloader()
        let installer = StubInstaller()
        installer.progressValues = [25, 100]
        let queue = DispatchQueue(label: "UpdateTests.install")
        let service = UpdateService(
            releaseFetcher: fetcher,
            downloader: downloader,
            installer: installer,
            currentVersionString: "1.0.0",
            currentApplicationURL: URL(fileURLWithPath: "/tmp/BalanceBar-test.app"),
            currentBundleIdentifier: "com.huanmeng06.BalanceBar.app",
            callbackQueue: queue,
            workQueue: queue
        )
        service.checkForUpdates()
        fetcher.resolve(.success([makeRelease(tag: "v1.0.1")]))
        let available = waitForState(service, queue: queue) {
            if case .available = $0 { return true }
            return false
        }
        wait(for: [available], timeout: 2)

        let downloadingProgress = expectation(description: "download progress")
        let installingProgress = expectation(description: "install progress")
        let restarting = expectation(description: "restarting state")
        service.onStateChange = { state in
            switch state {
            case .downloading(_, _, let progress) where progress == 25:
                downloadingProgress.fulfill()
            case .installing(_, _, let progress) where progress == 25:
                installingProgress.fulfill()
            case .restarting(_, let latest) where latest == AppSemanticVersion("1.0.1"):
                restarting.fulfill()
            default:
                break
            }
        }
        service.installAvailableUpdate()
        XCTAssertEqual(downloader.requestCount, 1)
        downloader.reportProgress(25)
        downloader.resolve(.success(URL(fileURLWithPath: "/tmp/verified-BalanceBar-1.0.1.dmg")))
        wait(for: [downloadingProgress, installingProgress, restarting], timeout: 2)
        XCTAssertEqual(installer.installCount, 1)
        XCTAssertEqual(installer.lastVersion, AppSemanticVersion("1.0.1"))
        XCTAssertEqual(downloader.cleanedURLs, [URL(fileURLWithPath: "/tmp/verified-BalanceBar-1.0.1.dmg")])
    }

    func testUpdateServiceInstallationFailureReturnsRetryableFailure() {
        let fetcher = StubReleaseFetcher()
        let downloader = StubDownloader()
        let installer = StubInstaller()
        installer.shouldFail = true
        let queue = DispatchQueue(label: "UpdateTests.install-failure")
        let service = UpdateService(
            releaseFetcher: fetcher,
            downloader: downloader,
            installer: installer,
            currentVersionString: "1.0.0",
            currentApplicationURL: URL(fileURLWithPath: "/tmp/BalanceBar-test.app"),
            currentBundleIdentifier: "com.huanmeng06.BalanceBar.app",
            callbackQueue: queue,
            workQueue: queue
        )
        service.checkForUpdates()
        fetcher.resolve(.success([makeRelease(tag: "v1.0.1")]))
        let available = waitForState(service, queue: queue) {
            if case .available = $0 { return true }
            return false
        }
        wait(for: [available], timeout: 2)
        let failed = waitForState(service, queue: queue) {
            if case .failed(.installationFailed) = $0 { return true }
            return false
        }
        service.installAvailableUpdate()
        downloader.resolve(.success(URL(fileURLWithPath: "/tmp/verified-BalanceBar-1.0.1.dmg")))
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(installer.installCount, 1)
    }

    // MARK: - Installer, rollback, and process/mount seams

    func testInstallerStagesValidBundleAtomicallyUnmountsAndRelaunches() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentApp = try makeAppBundle(
            at: root.appendingPathComponent("Current/BalanceBar.app"),
            version: "1.0.0"
        )
        let mountPoint = root.appendingPathComponent("Mounted", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        _ = try makeAppBundle(
            at: mountPoint.appendingPathComponent("BalanceBar.app"),
            version: "1.0.1"
        )
        let image = root.appendingPathComponent("BalanceBar-1.0.1.dmg")
        try Data("fixture-dmg".utf8).write(to: image)
        let mounter = StubMounter(mountPoint: mountPoint)
        let relauncher = StubRelauncher()
        var progressValues: [Int] = []
        let installer = UpdateApplicationInstaller(
            fileSystem: LiveUpdateFileSystem(),
            mounter: mounter,
            relauncher: relauncher
        )
        try installer.install(
            diskImageURL: image,
            expectedVersion: try XCTUnwrap(AppSemanticVersion("1.0.1")),
            currentApplicationURL: currentApp,
            expectedBundleIdentifier: "com.huanmeng06.BalanceBar.app",
            progress: { progressValues.append($0) }
        )
        XCTAssertEqual(LiveUpdateFileSystem().bundleMetadata(at: currentApp)?.shortVersion, "1.0.1")
        XCTAssertEqual(mounter.mountCount, 1)
        XCTAssertEqual(mounter.unmountCount, 1)
        XCTAssertEqual(relauncher.relaunchCount, 1)
        XCTAssertEqual(progressValues, [0, 15, 25, 50, 60, 80, 95, 100])
    }

    func testInstallerRollsBackOldBundleWhenRelaunchFails() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let currentApp = try makeAppBundle(
            at: root.appendingPathComponent("Current/BalanceBar.app"),
            version: "1.0.0"
        )
        let mountPoint = root.appendingPathComponent("Mounted", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        _ = try makeAppBundle(
            at: mountPoint.appendingPathComponent("BalanceBar.app"),
            version: "1.0.1"
        )
        let image = root.appendingPathComponent("BalanceBar-1.0.1.dmg")
        try Data("fixture-dmg".utf8).write(to: image)
        let relauncher = StubRelauncher()
        relauncher.shouldFail = true
        let installer = UpdateApplicationInstaller(
            fileSystem: LiveUpdateFileSystem(),
            mounter: StubMounter(mountPoint: mountPoint),
            relauncher: relauncher
        )
        XCTAssertThrowsError(try installer.install(
            diskImageURL: image,
            expectedVersion: try XCTUnwrap(AppSemanticVersion("1.0.1")),
            currentApplicationURL: currentApp,
            expectedBundleIdentifier: "com.huanmeng06.BalanceBar.app"
        )) { error in
            XCTAssertEqual(error as? UpdateInstallationError, .relaunchFailed)
        }
        XCTAssertEqual(LiveUpdateFileSystem().bundleMetadata(at: currentApp)?.shortVersion, "1.0.0")
    }

    func testHdiutilMounterParsesMountPointAndDetachesThroughProcessBoundary() throws {
        let plist: [String: Any] = [
            "system-entities": [["mount-point": "/Volumes/BalanceBar Test"]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let runner = StubProcessRunner(results: [
            UpdateProcessResult(status: 0, standardOutput: data, standardError: Data()),
            UpdateProcessResult(status: 0, standardOutput: Data(), standardError: Data())
        ])
        let mounter = HdiutilUpdateDiskImageMounter(processRunner: runner)
        let mounted = try mounter.mount(diskImageURL: URL(fileURLWithPath: "/tmp/update.dmg"))
        XCTAssertEqual(mounted.mountPoint.path, "/Volumes/BalanceBar Test")
        try mounter.unmount(mounted)
        XCTAssertEqual(runner.arguments[0].prefix(4), ["attach", "-plist", "-nobrowse", "-readonly"])
        XCTAssertEqual(runner.arguments[1], ["detach", "/Volumes/BalanceBar Test"])
    }

    func testRelauncherWaitsForCurrentProcessBeforeOpeningReplacedBundle() throws {
        let launcher = StubDetachedProcessLauncher()
        let terminator = StubApplicationTerminator()
        var events: [String] = []
        launcher.onLaunch = { events.append("launch-waiter") }
        let termination = expectation(description: "old process termination requested")
        terminator.onTerminate = {
            events.append("terminate-old-process")
            termination.fulfill()
        }
        let relauncher = LiveUpdateApplicationRelauncher(
            processLauncher: launcher,
            terminator: terminator
        )
        let applicationURL = URL(fileURLWithPath: "/tmp/BalanceBar-test.app")

        try relauncher.relaunchApplication(at: applicationURL)
        wait(for: [termination], timeout: 1)

        XCTAssertEqual(events, ["launch-waiter", "terminate-old-process"])
        XCTAssertEqual(launcher.executableURL?.path, "/bin/sh")
        let arguments = try XCTUnwrap(launcher.arguments)
        XCTAssertEqual(arguments.first, "-c")
        XCTAssertTrue(arguments[1].contains("kill -0"))
        XCTAssertTrue(arguments[1].contains("/usr/bin/open -n"))
        XCTAssertEqual(arguments.last, applicationURL.path)
    }

    func testReleaseNotesManifestUsesLocaleFallbacksThenReleaseBodyAndEmptyState() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseDirectory = root.appendingPathComponent("1.1.22", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)
        try "Taiwan notes".write(
            to: releaseDirectory.appendingPathComponent("zh-Hant-TW.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Traditional Chinese base notes".write(
            to: releaseDirectory.appendingPathComponent("zh-Hant.md"),
            atomically: true,
            encoding: .utf8
        )
        try "English notes".write(
            to: releaseDirectory.appendingPathComponent("en.md"),
            atomically: true,
            encoding: .utf8
        )
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "releases": [
                "1.1.22": [
                    "files": [
                        "zh-Hant-TW": "1.1.22/zh-Hant-TW.md",
                        "zh-Hant": "1.1.22/zh-Hant.md",
                        "en": "1.1.22/en.md"
                    ]
                ]
            ]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: root.appendingPathComponent("manifest.json"))

        let release = GitHubRelease(
            tagName: "v1.1.22",
            draft: false,
            prerelease: false,
            assets: [],
            body: "GitHub original body",
            htmlURL: URL(string: "https://github.com/huanmeng06/BalanceBar/releases/tag/v1.1.22")
        )
        let store = ReleaseNotesStore(releaseNotesRoot: root)
        let version = try XCTUnwrap(AppSemanticVersion("1.1.22"))

        XCTAssertEqual(
            store.resolve(version: version, language: .traditionalChineseTaiwan, release: release),
            ReleaseNotesResolution(markdown: "Taiwan notes", source: .bundled(locale: "zh-Hant-TW"))
        )
        XCTAssertEqual(
            store.resolve(version: version, language: .traditionalChineseHongKong, release: release),
            ReleaseNotesResolution(markdown: "Traditional Chinese base notes", source: .bundled(locale: "zh-Hant"))
        )
        XCTAssertEqual(
            store.resolve(version: version, language: .german, release: release),
            ReleaseNotesResolution(markdown: "English notes", source: .bundled(locale: "en"))
        )

        let missingVersion = try XCTUnwrap(AppSemanticVersion("9.9.9"))
        XCTAssertEqual(
            store.resolve(version: missingVersion, language: .english, release: release),
            ReleaseNotesResolution(markdown: "GitHub original body", source: .githubRelease)
        )
        XCTAssertEqual(
            store.resolve(version: missingVersion, language: .english, release: GitHubRelease(
                tagName: "v9.9.9",
                draft: false,
                prerelease: false,
                assets: []
            )),
            ReleaseNotesResolution(markdown: nil, source: .unavailable)
        )
    }

    func testReleaseNotesMarkdownRendererKeepsUnsupportedMarkupAsTextAndOnlyAllowsWebLinks() throws {
        let rendered = ReleaseNotesMarkdownRenderer.render(markdown: """
        # Heading

        - **Bold** and `code`
        [Safe](https://example.com/release)
        [Unsafe](javascript:alert(1))
        <script>alert(1)</script>
        <a href="https://example.com">HTML link</a>
        """)

        XCTAssertTrue(rendered.string.contains("Heading"))
        XCTAssertTrue(rendered.string.contains("• Bold and code"))
        XCTAssertTrue(rendered.string.contains("javascript:alert(1)"))
        XCTAssertTrue(rendered.string.contains("<script>alert(1)</script>"))
        XCTAssertTrue(rendered.string.contains("<a href=\"https://example.com\">HTML link</a>"))

        let table = ReleaseNotesMarkdownRenderer.render(markdown: """
        项目 | 说明
        --- | ---
        **修复** | [查看](https://example.com/fix)
        """)
        XCTAssertTrue(table.string.contains("项目"))
        XCTAssertTrue(table.string.contains("说明"))
        XCTAssertTrue(table.string.contains("修复"))
        XCTAssertFalse(table.string.contains("--- | ---"))
        XCTAssertFalse(table.string.contains("|"))
        let tableParagraph = try XCTUnwrap(
            table.attributes(at: 0, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle
        )
        XCTAssertFalse(tableParagraph.textBlocks.isEmpty)
        let tableLinkRange = (table.string as NSString).range(of: "查看")
        XCTAssertEqual(
            (table.attributes(at: tableLinkRange.location, effectiveRange: nil)[.link] as? URL)?.scheme,
            "https"
        )

        let blockLayout = ReleaseNotesMarkdownRenderer.render(markdown: """
        ## 修复与体验优化

        ---

        项目 | 说明
        --- | ---
        修复 | 说明

        ## 安装

        1. 下载文件
        """)
        XCTAssertFalse(blockLayout.string.contains("\n\n"))
        let headingRange = (blockLayout.string as NSString).range(of: "修复与体验优化")
        let headingParagraph = try XCTUnwrap(
            blockLayout.attributes(at: headingRange.location, effectiveRange: nil)[.paragraphStyle]
                as? NSParagraphStyle
        )
        XCTAssertTrue(headingParagraph.textBlocks.isEmpty)
        XCTAssertFalse(blockLayout.string.contains("---"))

        let tableRange = (blockLayout.string as NSString).range(of: "项目")
        let firstTableParagraph = try XCTUnwrap(
            blockLayout.attributes(at: tableRange.location, effectiveRange: nil)[.paragraphStyle]
                as? NSParagraphStyle
        )
        let firstCell = try XCTUnwrap(
            firstTableParagraph.textBlocks.first as? ReleaseNotesTableCellBlock
        )
        XCTAssertEqual(firstCell.rowCount, 2)
        XCTAssertEqual(firstCell.columnCount, 2)
        XCTAssertTrue(firstCell.isHeader)
        XCTAssertTrue(firstCell.drawsOuterLeftEdge)
        XCTAssertFalse(firstCell.drawsOuterRightEdge)
        XCTAssertTrue(firstCell.drawsOuterTopEdge)
        XCTAssertFalse(firstCell.drawsOuterBottomEdge)
        XCTAssertTrue(firstCell.drawsInternalRightEdge)
        XCTAssertTrue(firstCell.drawsInternalBottomEdge)

        let bodyMarkerRange = (blockLayout.string as NSString).range(of: "修复", options: .backwards)
        let bodyRange = (blockLayout.string as NSString).range(of: "说明", options: [], range: NSRange(
            location: bodyMarkerRange.location + bodyMarkerRange.length,
            length: blockLayout.length - bodyMarkerRange.location - bodyMarkerRange.length
        ))
        let bodyParagraph = try XCTUnwrap(
            blockLayout.attributes(at: bodyRange.location, effectiveRange: nil)[.paragraphStyle]
                as? NSParagraphStyle
        )
        let lastCell = try XCTUnwrap(
            bodyParagraph.textBlocks.first as? ReleaseNotesTableCellBlock
        )
        XCTAssertFalse(lastCell.isHeader)
        XCTAssertEqual(bodyParagraph.paragraphSpacing, releaseNotesTableBottomSpacing, accuracy: 0.001)
        XCTAssertTrue(lastCell.drawsOuterRightEdge)
        XCTAssertTrue(lastCell.drawsOuterBottomEdge)
        XCTAssertFalse(lastCell.drawsInternalRightEdge)
        XCTAssertFalse(lastCell.drawsInternalBottomEdge)

        let secondHeadingRange = (blockLayout.string as NSString).range(of: "安装")
        let secondHeadingParagraph = try XCTUnwrap(
            blockLayout.attributes(at: secondHeadingRange.location, effectiveRange: nil)[.paragraphStyle]
                as? NSParagraphStyle
        )
        XCTAssertEqual(secondHeadingParagraph.paragraphSpacing, 10, accuracy: 0.001)

        let safeRange = (rendered.string as NSString).range(of: "Safe")
        let safeAttributes = rendered.attributes(at: safeRange.location, effectiveRange: nil)
        XCTAssertEqual((safeAttributes[.link] as? URL)?.scheme, "https")

        let unsafeRange = (rendered.string as NSString).range(of: "Unsafe")
        XCTAssertNil(rendered.attributes(at: unsafeRange.location, effectiveRange: nil)[.link])
        let htmlRange = (rendered.string as NSString).range(of: "HTML link")
        XCTAssertNil(rendered.attributes(at: htmlRange.location, effectiveRange: nil)[.link])
    }

    func testReleaseNotesTableSpacingCreatesFollowingBlockGapInTextKitGeometry() throws {
        let rendered = ReleaseNotesMarkdownRenderer.render(markdown: """
        ## 修复与体验优化

        项目 | 说明
        --- | ---
        修复 | 说明

        ## 安装

        1. 下载文件
        """)
        let storage = NSTextStorage(attributedString: rendered)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let bodyRange = (rendered.string as NSString).range(of: "说明", options: .backwards)
        let headingRange = (rendered.string as NSString).range(of: "安装")
        let listRange = (rendered.string as NSString).range(of: "1. 下载文件")
        XCTAssertNotEqual(bodyRange.location, NSNotFound)
        XCTAssertNotEqual(headingRange.location, NSNotFound)
        XCTAssertNotEqual(listRange.location, NSNotFound)

        let bodyParagraph = try XCTUnwrap(
            rendered.attributes(at: bodyRange.location, effectiveRange: nil)[.paragraphStyle]
                as? NSParagraphStyle
        )
        XCTAssertEqual(bodyParagraph.paragraphSpacing, releaseNotesTableBottomSpacing, accuracy: 0.001)

        let bodyGlyphRange = layoutManager.glyphRange(
            forCharacterRange: bodyRange,
            actualCharacterRange: nil
        )
        let headingGlyphRange = layoutManager.glyphRange(
            forCharacterRange: headingRange,
            actualCharacterRange: nil
        )
        let listGlyphRange = layoutManager.glyphRange(
            forCharacterRange: listRange,
            actualCharacterRange: nil
        )
        let bodyRect = layoutManager.boundingRect(forGlyphRange: bodyGlyphRange, in: textContainer)
        let headingRect = layoutManager.boundingRect(forGlyphRange: headingGlyphRange, in: textContainer)
        let listRect = layoutManager.boundingRect(forGlyphRange: listGlyphRange, in: textContainer)
        let gap = max(bodyRect.minY, headingRect.minY) - min(bodyRect.maxY, headingRect.maxY)
        let headingToListGap = max(headingRect.minY, listRect.minY)
            - min(headingRect.maxY, listRect.maxY)
        XCTAssertGreaterThanOrEqual(
            gap,
            headingToListGap + 8 - 1,
            "expected table-to-heading gap \(gap) >= heading-to-list gap \(headingToListGap) + 8, body=\(bodyRect), heading=\(headingRect), list=\(listRect)"
        )

        let trailingTable = ReleaseNotesMarkdownRenderer.render(markdown: """
        项目 | 说明
        --- | ---
        修复 | 说明
        """)
        let trailingRange = (trailingTable.string as NSString).range(of: "说明", options: .backwards)
        let trailingParagraph = try XCTUnwrap(
            trailingTable.attributes(at: trailingRange.location, effectiveRange: nil)[.paragraphStyle]
                as? NSParagraphStyle
        )
        XCTAssertEqual(trailingParagraph.paragraphSpacing, 0, accuracy: 0.001)
    }

    func testReleaseNotesTableGridUsesVisibleLightAndDarkColors() throws {
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightColors = ReleaseNotesAppearanceColors.resolved(for: lightAppearance)
        let darkColors = ReleaseNotesAppearanceColors.resolved(for: darkAppearance)

        XCTAssertEqual(lightColors.tableGrid.alphaComponent, 0.30, accuracy: 0.001)
        XCTAssertEqual(darkColors.tableGrid.alphaComponent, 0.32, accuracy: 0.001)
        XCTAssertLessThan(lightColors.tableGrid.whiteComponent, 0.10)
        XCTAssertGreaterThan(darkColors.tableGrid.whiteComponent, 0.90)

        let markdown = """
        项目 | 说明
        --- | ---
        修复 | 长文本用于验证表格在深色模式下仍有清晰网格。
        """
        for appearance in [lightAppearance, darkAppearance] {
            let rendered = ReleaseNotesMarkdownRenderer.render(markdown: markdown)
            let markerRange = (rendered.string as NSString).range(of: "项目")
            let paragraph = try XCTUnwrap(
                rendered.attributes(at: markerRange.location, effectiveRange: nil)[.paragraphStyle]
                    as? NSParagraphStyle
            )
            let cell = try XCTUnwrap(paragraph.textBlocks.first as? ReleaseNotesTableCellBlock)
            XCTAssertTrue(cell.drawsOuterLeftEdge)
            XCTAssertTrue(cell.drawsOuterTopEdge)

            let expected = ReleaseNotesAppearanceColors.resolved(for: appearance)
            XCTAssertGreaterThanOrEqual(expected.tableGrid.alphaComponent, 0.30)
        }
    }

    func testReleaseNotesTableGridDrawsBottomAndRightOuterEdgesInOffscreenBitmap() throws {
        let rendered = ReleaseNotesMarkdownRenderer.render(markdown: """
        项目 | 说明
        --- | ---
        修复 | 说明
        """)
        let bodyRange = (rendered.string as NSString).range(of: "说明", options: .backwards)
        let bodyParagraph = try XCTUnwrap(
            rendered.attributes(at: bodyRange.location, effectiveRange: nil)[.paragraphStyle]
                as? NSParagraphStyle
        )
        let cell = try XCTUnwrap(bodyParagraph.textBlocks.first as? ReleaseNotesTableCellBlock)
        XCTAssertTrue(cell.drawsOuterRightEdge)
        XCTAssertTrue(cell.drawsOuterBottomEdge)

        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
        view.appearance = darkAppearance
        let scale = max(1, NSScreen.main?.backingScaleFactor ?? 2)
        let bitmapSize = NSSize(width: 180, height: 100)
        let pixelsWide = max(1, Int(ceil(bitmapSize.width * scale)))
        let pixelsHigh = max(1, Int(ceil(bitmapSize.height * scale)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let frame = NSRect(x: 12.25, y: 11.25, width: 120.5, height: 42.25)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.cgContext.saveGState()
        context.cgContext.scaleBy(x: scale, y: scale)
        cell.drawBackground(
            withFrame: frame,
            in: view,
            characterRange: bodyRange,
            layoutManager: NSLayoutManager()
        )
        context.cgContext.restoreGState()
        context.flushGraphics()

        let lineWidth = 1 / scale
        let interiorXRange = bitmapPixelRange(
            from: frame.minX + lineWidth * 2,
            to: frame.maxX - lineWidth * 2,
            scale: scale,
            limit: pixelsWide
        )
        let interiorYRange = bitmapYPixelRange(
            from: frame.minY + lineWidth * 2,
            to: frame.maxY - lineWidth * 2,
            scale: scale,
            pixelsHigh: pixelsHigh
        )
        let bottomYRange = bitmapYPixelRange(
            from: frame.maxY - lineWidth * 1.5,
            to: frame.maxY + lineWidth * 0.5,
            scale: scale,
            pixelsHigh: pixelsHigh
        )
        let rightXRange = bitmapPixelRange(
            from: frame.maxX - lineWidth * 1.5,
            to: frame.maxX + lineWidth * 0.5,
            scale: scale,
            limit: pixelsWide
        )

        XCTAssertTrue(
            bitmapContainsInk(bitmap, xRange: interiorXRange, yRange: bottomYRange),
            "expected the last table row to contain a visible bottom outer edge"
        )
        XCTAssertTrue(
            bitmapContainsInk(bitmap, xRange: rightXRange, yRange: interiorYRange),
            "expected the last table column to contain a visible right outer edge"
        )
    }

    func testUpdateNotesWindowLaysOutContentOnFirstPresentation() throws {
        let controller = UpdateNotesWindowController(onInstall: {})
        defer { controller.close() }
        let release = GitHubRelease(
            tagName: "v9.9.8",
            draft: false,
            prerelease: false,
            assets: [],
            body: "# First presentation\n\nThe release notes are visible immediately."
        )

        controller.show(currentVersion: try XCTUnwrap(AppSemanticVersion("1.1.21")), release: release)

        let window = try XCTUnwrap(controller.window)
        let contentView = try XCTUnwrap(window.contentView)
        let scrollView = try XCTUnwrap(
            updateTestDescendants(of: contentView)
                .compactMap { $0 as? NSScrollView }
                .first
        )
        let notesTextView = try XCTUnwrap(scrollView.documentView as? ReleaseNotesTextView)
        XCTAssertTrue(notesTextView.string.contains("First presentation"))
        XCTAssertGreaterThan(notesTextView.frame.width, 1)
        XCTAssertEqual(scrollView.layer?.cornerRadius ?? 0, 12, accuracy: 0.001)
        XCTAssertEqual(scrollView.layer?.cornerCurve, .continuous)
        XCTAssertTrue(scrollView.layer?.masksToBounds ?? false)
        XCTAssertEqual(scrollView.borderType, .noBorder)
        XCTAssertTrue(scrollView.contentView is NSClipView)
        XCTAssertEqual(scrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
        XCTAssertFalse(scrollView.automaticallyAdjustsContentInsets)
        XCTAssertEqual(scrollView.contentInsets.top, 0, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentInsets.bottom, 0, accuracy: 0.001)
        let materialSurface = try XCTUnwrap(window.contentView as? NSVisualEffectView)
        XCTAssertEqual(materialSurface.material, .underWindowBackground)
        XCTAssertEqual(materialSurface.blendingMode, .behindWindow)
        XCTAssertEqual(materialSurface.state, .active)
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.standardWindowButton(.miniaturizeButton)?.isEnabled ?? false)
        XCTAssertFalse(window.standardWindowButton(.zoomButton)?.isEnabled ?? true)
        XCTAssertEqual(materialSurface.layer?.cornerRadius ?? 0, 16, accuracy: 0.001)
        XCTAssertEqual(materialSurface.layer?.cornerCurve, .continuous)
        let contentSurface = try XCTUnwrap(
            updateTestDescendants(of: materialSurface)
                .first { $0.identifier?.rawValue == "updateNotesContentSurface" }
        )
        let expectedContentAlpha = dashboardUsesDarkAppearance ? 0.20 : 0.82
        XCTAssertEqual(
            contentSurface.layer?.backgroundColor?.alpha ?? 0,
            expectedContentAlpha,
            accuracy: 0.01
        )
        if let glassViewClass = NSClassFromString("NSGlassEffectView") {
            XCTAssertFalse(materialSurface.isKind(of: glassViewClass))
            XCTAssertFalse(
                updateTestDescendants(of: materialSurface).contains {
                    $0.isKind(of: glassViewClass)
                }
            )
        }
        let titleLabel = try XCTUnwrap(
            updateTestDescendants(of: contentView)
                .compactMap { $0 as? NSTextField }
                .first
        )
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        let titleLabelFrame = titleLabel.convert(titleLabel.bounds, to: contentView)
        let topInset = contentView.bounds.maxY - titleLabelFrame.maxY
        XCTAssertGreaterThanOrEqual(topInset, titlebarHeight + 20)
    }

    func testUpdateNotesWindowUsesDashboardMaterialContractInLightAndDarkModes() throws {
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }

        for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
            NSApp.appearance = appearance
            let controller = UpdateNotesWindowController(onInstall: {})
            controller.show(
                currentVersion: try XCTUnwrap(AppSemanticVersion("1.1.20")),
                release: GitHubRelease(
                    tagName: "v1.1.21",
                    draft: false,
                    prerelease: true,
                    assets: [],
                    body: "# Material test\n\nOpaque content surface."
                )
            )
            let window = try XCTUnwrap(controller.window)
            let materialSurface = try XCTUnwrap(window.contentView as? NSVisualEffectView)
            let contentSurface = try XCTUnwrap(
                updateTestDescendants(of: materialSurface)
                    .first { $0.identifier?.rawValue == "updateNotesContentSurface" }
            )
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            XCTAssertEqual(materialSurface.material, .underWindowBackground)
            XCTAssertEqual(materialSurface.blendingMode, .behindWindow)
            XCTAssertEqual(materialSurface.state, .active)
            XCTAssertEqual(
                window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
                isDark ? .darkAqua : .aqua
            )
            XCTAssertEqual(
                materialSurface.layer?.backgroundColor?.alpha ?? 0,
                isDark ? 0.14 : 0.08,
                accuracy: 0.01
            )
            XCTAssertEqual(
                contentSurface.layer?.backgroundColor?.alpha ?? 0,
                isDark ? 0.20 : 0.82,
                accuracy: 0.01
            )
            let contentColor = try XCTUnwrap(
                try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(contentSurface.layer?.backgroundColor)))
                    .usingColorSpace(.deviceRGB)
            )
            if isDark {
                XCTAssertLessThan(contentColor.redComponent, 0.10)
            } else {
                XCTAssertGreaterThan(contentColor.redComponent, 0.80)
            }
            let notesTextView = try XCTUnwrap(
                updateTestDescendants(of: contentSurface)
                    .compactMap { $0 as? NSTextView }
                    .first
            )
            XCTAssertTrue(notesTextView.drawsBackground)
            let notesBackground = try XCTUnwrap(
                notesTextView.backgroundColor.usingColorSpace(.sRGB)
            )
            if isDark {
                XCTAssertEqual(notesBackground.redComponent, 29.0 / 255.0, accuracy: 0.001)
                XCTAssertEqual(notesBackground.greenComponent, 30.0 / 255.0, accuracy: 0.001)
                XCTAssertEqual(notesBackground.blueComponent, 30.0 / 255.0, accuracy: 0.001)
                XCTAssertEqual(notesBackground.alphaComponent, 1, accuracy: 0.001)
            } else {
                XCTAssertEqual(notesBackground.redComponent, 1, accuracy: 0.001)
                XCTAssertEqual(notesBackground.greenComponent, 1, accuracy: 0.001)
                XCTAssertEqual(notesBackground.blueComponent, 1, accuracy: 0.001)
                XCTAssertEqual(notesBackground.alphaComponent, 1, accuracy: 0.001)
            }
            controller.close()
        }
    }

    func testUpdateNotesTextViewDisablesSelectionAndKeepsLinks() throws {
        let controller = UpdateNotesWindowController(onInstall: {})
        defer { controller.close() }
        controller.show(
            currentVersion: try XCTUnwrap(AppSemanticVersion("1.1.20")),
            release: GitHubRelease(
                tagName: "v1.1.21",
                draft: false,
                prerelease: true,
                assets: [],
                body: "# Readable\n\nOpen [the release](https://github.com/huanmeng06/BalanceBar/releases)."
            )
        )

        let window = try XCTUnwrap(controller.window)
        let scrollView = try XCTUnwrap(
            updateTestDescendants(of: try XCTUnwrap(window.contentView))
                .compactMap { $0 as? NSScrollView }
                .first
        )
        let notesTextView = try XCTUnwrap(scrollView.documentView as? ReleaseNotesTextView)
        notesTextView.updateTrackingAreas()
        XCTAssertFalse(notesTextView.isSelectable)
        XCTAssertFalse(notesTextView.isEditable)
        XCTAssertFalse(notesTextView.acceptsFirstResponder)
        XCTAssertNotEqual(window.firstResponder, notesTextView)
        XCTAssertEqual(notesTextView.selectedRange().length, 0)
        XCTAssertTrue(
            notesTextView.trackingAreas.contains {
                $0.options.contains(.cursorUpdate) && $0.options.contains(.mouseMoved)
            }
        )

        let range = (notesTextView.string as NSString).range(of: "the release")
        XCTAssertNotEqual(range.location, NSNotFound)
        XCTAssertEqual(
            notesTextView.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL,
            URL(string: "https://github.com/huanmeng06/BalanceBar/releases")
        )

        let textStorage = try XCTUnwrap(notesTextView.textStorage)
        let layoutManager = try XCTUnwrap(notesTextView.layoutManager)
        let textContainer = try XCTUnwrap(notesTextView.textContainer)
        let linkGlyphRange = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        let linkRect = layoutManager
            .boundingRect(forGlyphRange: linkGlyphRange, in: textContainer)
            .offsetBy(dx: notesTextView.textContainerOrigin.x, dy: notesTextView.textContainerOrigin.y)
        XCTAssertTrue(
            notesTextView.cursor(at: NSPoint(x: linkRect.midX, y: linkRect.midY)) === NSCursor.pointingHand
        )
        let trailingLinkPoint = NSPoint(
            x: min(linkRect.maxX + 24, notesTextView.bounds.maxX - 2),
            y: linkRect.midY
        )
        XCTAssertGreaterThan(trailingLinkPoint.x, linkRect.maxX)
        XCTAssertTrue(notesTextView.cursor(at: trailingLinkPoint) === NSCursor.arrow)

        let headingRange = (textStorage.string as NSString).range(of: "Readable")
        let headingGlyphRange = layoutManager.glyphRange(
            forCharacterRange: headingRange,
            actualCharacterRange: nil
        )
        let headingRect = layoutManager
            .boundingRect(forGlyphRange: headingGlyphRange, in: textContainer)
            .offsetBy(dx: notesTextView.textContainerOrigin.x, dy: notesTextView.textContainerOrigin.y)
        XCTAssertTrue(
            notesTextView.cursor(at: NSPoint(x: headingRect.midX, y: headingRect.midY)) === NSCursor.arrow
        )
    }

    func testReleaseNotesReflowsLongContentAcrossLanguagesAndWindowWidths() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let controller = UpdateNotesWindowController(onInstall: {})
        defer { controller.close() }
        let longList = (1...14)
            .map { "\($0). 这是一段用于验证窄窗口滚动和重复打开的较长更新说明。" }
            .joined(separator: "\n")
        let release = GitHubRelease(
            tagName: "v9.9.9",
            draft: false,
            prerelease: true,
            assets: [],
            body: """
            ## 修复与体验优化

            项目 | 说明
            --- | ---
            长文本 | This is a deliberately long English and 中文 paragraph used to verify wrapping at narrow widths. 日本語 한국어 Español Deutsch.

            ## 安装

            1. 下载 BalanceBar-9.9.9.dmg。
            2. Open the DMG and move BalanceBar.app into Applications.
            3. 从应用程序文件夹启动 BalanceBar。

            \(longList)
            """
        )
        let languages: [AppLanguage] = [
            .simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .english,
            .japanese,
            .korean,
            .spanish,
            .german
        ]

        for language in languages {
            AppLanguage.selected = language
            controller.show(
                currentVersion: try XCTUnwrap(AppSemanticVersion("1.1.20")),
                release: release
            )
            let window = try XCTUnwrap(controller.window)
            for width in [520, 900] {
                var frame = window.frame
                frame.size = NSSize(width: width, height: 560)
                window.setFrame(frame, display: false)
                window.contentView?.layoutSubtreeIfNeeded()
                let contentView = try XCTUnwrap(window.contentView)
                let scrollView = try XCTUnwrap(
                    updateTestDescendants(of: contentView)
                        .compactMap { $0 as? NSScrollView }
                        .first
                )
                let notesTextView = try XCTUnwrap(scrollView.documentView as? NSTextView)
                XCTAssertGreaterThan(notesTextView.frame.width, 1)
                XCTAssertGreaterThanOrEqual(
                    notesTextView.frame.height,
                    scrollView.contentView.bounds.height
                )
                if width == 520 {
                    XCTAssertGreaterThan(
                        notesTextView.frame.height,
                        scrollView.contentView.bounds.height
                    )
                    let maxScrollY = max(
                        0,
                        notesTextView.frame.height - scrollView.contentView.bounds.height
                    )
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxScrollY))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            controller.show(
                currentVersion: try XCTUnwrap(AppSemanticVersion("1.1.20")),
                release: release
            )
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(controller.window?.isVisible == true)
            controller.close()
        }

        AppLanguage.selected = .english
        controller.show(
            currentVersion: try XCTUnwrap(AppSemanticVersion("1.1.20")),
            release: release
        )
        let englishTitle = try XCTUnwrap(
            updateTestDescendants(of: try XCTUnwrap(controller.window?.contentView))
                .compactMap { $0 as? NSTextField }
                .first
        ).stringValue
        AppLanguage.selected = .japanese
        controller.refreshForCurrentLanguage()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let japaneseTitle = try XCTUnwrap(
            updateTestDescendants(of: try XCTUnwrap(controller.window?.contentView))
                .compactMap { $0 as? NSTextField }
                .first
        ).stringValue
        XCTAssertNotEqual(englishTitle, japaneseTitle)
        controller.close()

        XCTAssertEqual(releaseNotesPixelAligned(10.24, scale: 2), 10, accuracy: 0.001)
        XCTAssertEqual(releaseNotesPixelAligned(10.26, scale: 2), 10.5, accuracy: 0.001)
        XCTAssertEqual(releaseNotesPixelAligned(10.17, scale: 3), 31.0 / 3.0, accuracy: 0.001)
        let snappedRect = releaseNotesPixelAlignedRect(
            NSRect(x: 0.24, y: 1.17, width: 10.26, height: 5.24),
            scale: 2
        )
        XCTAssertEqual(snappedRect.minX * 2, (snappedRect.minX * 2).rounded(), accuracy: 0.001)
        XCTAssertEqual(snappedRect.minY * 2, (snappedRect.minY * 2).rounded(), accuracy: 0.001)
        XCTAssertEqual(snappedRect.maxX * 2, (snappedRect.maxX * 2).rounded(), accuracy: 0.001)
        XCTAssertEqual(snappedRect.maxY * 2, (snappedRect.maxY * 2).rounded(), accuracy: 0.001)
    }

    // MARK: - Dashboard state/action wiring and localization

    func testDashboardRetryActionKeepsCheckingVisibleForOneSecondAndGuardsDuplicateRequests() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "UpdateTests.UI.retry-state.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fetcher = StubReleaseFetcher()
        let scheduler = StubUpdateScheduler()
        let service = UpdateService(
            releaseFetcher: fetcher,
            currentVersionString: "1.0.0",
            callbackQueue: .main,
            workQueue: .main,
            scheduler: scheduler
        )
        let relay = DashboardPreferencePageRelay()
        let pageController = DashboardGeneralPage()
        var latestCount = 0
        let firstLatest = expectation(description: "first check settles")
        let secondLatest = expectation(description: "second check settles")
        let firstMinimumDurationScheduled = expectation(description: "first minimum checking duration scheduled")
        let secondMinimumDurationScheduled = expectation(description: "second minimum checking duration scheduled")
        scheduler.onSchedule = { _ in
            switch scheduler.scheduledDelays.count {
            case 1:
                firstMinimumDurationScheduled.fulfill()
            case 2:
                secondMinimumDurationScheduled.fulfill()
            default:
                XCTFail("unexpected extra minimum checking duration")
            }
        }
        service.onStateChange = { state in
            pageController.refresh(updateState: state)
            guard case .latest = state else { return }
            latestCount += 1
            if latestCount == 1 {
                firstLatest.fulfill()
            } else if latestCount == 2 {
                secondLatest.fulfill()
            }
        }
        relay.onCheckForUpdates = { service.checkForUpdates() }

        let page = pageController.make(.init(
            preferences: AppPreferences(defaults: defaults),
            currentProviderName: "OpenAI",
            relay: relay,
            updateState: service.state
        ))
        let updateButton = try XCTUnwrap(
            updateTestDescendants(of: page)
                .compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "checkForUpdatesButton" }
        )

        relay.update(updateButton)
        XCTAssertEqual(fetcher.requestCount, 1)
        XCTAssertEqual(updateButton.title, "检查中…")
        XCTAssertFalse(updateButton.isEnabled)

        relay.update(updateButton)
        XCTAssertEqual(fetcher.requestCount, 1, "duplicate action during checking must stay guarded")

        fetcher.resolve(.success([makeRelease(tag: "v1.0.0")]))
        wait(for: [firstMinimumDurationScheduled], timeout: 2)
        XCTAssertEqual(updateButton.title, "检查中…")
        XCTAssertFalse(updateButton.isEnabled)
        scheduler.advance(by: 0.999)
        XCTAssertEqual(updateButton.title, "检查中…")
        XCTAssertFalse(updateButton.isEnabled)
        relay.update(updateButton)
        XCTAssertEqual(fetcher.requestCount, 1, "duplicate action during the minimum checking duration must stay guarded")
        scheduler.advance(by: 0.001)
        wait(for: [firstLatest], timeout: 2)
        XCTAssertEqual(updateButton.title, "检查更新")
        XCTAssertTrue(updateButton.isEnabled)

        relay.update(updateButton)
        XCTAssertEqual(fetcher.requestCount, 2)
        XCTAssertEqual(updateButton.title, "检查中…")
        XCTAssertFalse(updateButton.isEnabled)

        relay.update(updateButton)
        XCTAssertEqual(fetcher.requestCount, 2, "duplicate action during the retry must stay guarded")

        fetcher.resolve(.success([makeRelease(tag: "v1.0.0")]))
        wait(for: [secondMinimumDurationScheduled], timeout: 2)
        XCTAssertEqual(updateButton.title, "检查中…")
        XCTAssertFalse(updateButton.isEnabled)
        scheduler.advance(by: 1.0)
        wait(for: [secondLatest], timeout: 2)
        XCTAssertEqual(updateButton.title, "检查更新")
        XCTAssertTrue(updateButton.isEnabled)
    }

    func testDashboardChannelSwitchRefreshesButtonAndAllowsCurrentChannelCheck() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let suiteName = "UpdateTests.UI.channel-switch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.updateChannel = .beta

        let fetcher = StubReleaseFetcher()
        let scheduler = StubUpdateScheduler()
        let service = UpdateService(
            releaseFetcher: fetcher,
            currentVersionString: "1.0.0",
            updateChannel: .beta,
            callbackQueue: .main,
            workQueue: .main,
            scheduler: scheduler,
            minimumCheckingDuration: 0
        )
        let relay = DashboardPreferencePageRelay()
        let pageController = DashboardGeneralPage()
        relay.onCheckForUpdates = { service.checkForUpdates() }
        relay.onInstallUpdate = { service.installAvailableUpdate() }
        relay.onUpdateChannelChanged = { channel in
            preferences.updateChannel = channel
            service.updateChannel = channel
        }

        let page = pageController.make(.init(
            preferences: preferences,
            currentProviderName: "OpenAI",
            relay: relay,
            updateState: service.state
        ))
        let updateButton = try XCTUnwrap(
            updateTestDescendants(of: page)
                .compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "checkForUpdatesButton" }
        )
        let channelPopup = try XCTUnwrap(
            updateTestDescendants(of: page)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == AppPreferences.updateChannelKey }
        )

        let betaAvailable = expectation(description: "Beta update is available")
        service.onStateChange = { state in
            DispatchQueue.main.async {
                pageController.refresh(updateState: state)
                if case .available = state { betaAvailable.fulfill() }
            }
        }
        service.checkForUpdates()
        fetcher.resolve(.success([makeRelease(tag: "v2.0.0-beta.1", prerelease: true)]))
        wait(for: [betaAvailable], timeout: 2)
        XCTAssertEqual(updateButton.title, "下载并安装")
        XCTAssertTrue(updateButton.isEnabled)
        XCTAssertEqual(updateButton.tag, 1)

        let resetToStable = expectation(description: "Dashboard resets after channel switch")
        service.onStateChange = { state in
            DispatchQueue.main.async {
                pageController.refresh(updateState: state)
                if case .idle = state { resetToStable.fulfill() }
            }
        }
        channelPopup.selectItem(at: UpdateChannel.allCases.firstIndex(of: .stable)!)
        relay.updateChannel(channelPopup)
        wait(for: [resetToStable], timeout: 2)
        XCTAssertEqual(preferences.updateChannel, .stable)
        XCTAssertEqual(updateButton.title, "检查更新")
        XCTAssertTrue(updateButton.isEnabled)
        XCTAssertEqual(updateButton.tag, 0)

        relay.update(updateButton)
        XCTAssertEqual(fetcher.requestCount, 2)
        let stableLatest = expectation(description: "Stable recheck settles")
        service.onStateChange = { state in
            DispatchQueue.main.async {
                pageController.refresh(updateState: state)
                if case .latest = state { stableLatest.fulfill() }
            }
        }
        fetcher.resolve(.success([makeRelease(tag: "v1.0.0")]))
        wait(for: [stableLatest], timeout: 2)
        XCTAssertEqual(updateButton.title, "检查更新")
        XCTAssertTrue(updateButton.isEnabled)
    }

    func testUpdateServiceMinimumCheckingDurationDelaysFastFailureAndKeepsRetryGuarded() {
        let fetcher = StubReleaseFetcher()
        let scheduler = StubUpdateScheduler()
        let queue = DispatchQueue(label: "UpdateTests.minimum-duration.failure")
        let service = UpdateService(
            releaseFetcher: fetcher,
            currentVersionString: "1.0.0",
            callbackQueue: queue,
            workQueue: queue,
            scheduler: scheduler
        )
        let scheduled = expectation(description: "minimum checking duration scheduled")
        scheduler.onSchedule = { delay in
            XCTAssertEqual(delay, 1.0, accuracy: 0.001)
            scheduled.fulfill()
        }
        let failed = waitForState(service, queue: queue) {
            if case .failed(.network) = $0 { return true }
            return false
        }

        service.checkForUpdates()
        fetcher.resolve(.failure(.transport))
        wait(for: [scheduled], timeout: 2)
        if case .checking = service.state {
            // The fast failure must not replace the visible checking state yet.
        } else {
            XCTFail("fast failure must remain in checking state during the minimum presentation duration")
        }

        service.checkForUpdates()
        XCTAssertEqual(fetcher.requestCount, 1, "duplicate check during the minimum duration must stay guarded")
        scheduler.advance(by: 0.999)
        if case .failed = service.state {
            XCTFail("fast failure must remain pending until the minimum checking duration elapses")
        }
        scheduler.advance(by: 0.001)
        wait(for: [failed], timeout: 2)
        guard case .failed(.network) = service.state else {
            return XCTFail("expected the delayed network failure")
        }
    }

    func testDashboardGeneralUpdateRowUsesSharedSettingsRowAndRelayActions() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese
        let suiteName = "UpdateTests.UI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let relay = DashboardPreferencePageRelay()
        var checkCount = 0
        var installCount = 0
        var openNotesCount = 0
        relay.onCheckForUpdates = { checkCount += 1 }
        relay.onInstallUpdate = { installCount += 1 }
        relay.onOpenUpdateNotes = { openNotesCount += 1 }
        var selectedChannel: UpdateChannel?
        relay.onUpdateChannelChanged = { selectedChannel = $0 }
        let pageController = DashboardGeneralPage()
        let page = pageController.make(.init(
            preferences: preferences,
            currentProviderName: "OpenAI",
            relay: relay,
            updateState: .latest(current: try XCTUnwrap(AppSemanticVersion("1.0.6")))
        ))
        let buttons = updateTestDescendants(of: page).compactMap { $0 as? NSButton }
        let updateButton = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "checkForUpdatesButton" })
        XCTAssertEqual(updateButton.title, "检查更新")
        XCTAssertTrue(updateButton.isEnabled)
        let channelPopup = try XCTUnwrap(
            updateTestDescendants(of: page)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == AppPreferences.updateChannelKey }
        )
        XCTAssertTrue(
            updateTestDescendants(of: page)
                .compactMap { $0 as? NSTextField }
                .contains {
                    $0.stringValue == tr(
                        .keyDashboardGeneralAndRefreshPagesUpdateChannelDescription,
                        language: .simplifiedChinese
                    )
                }
        )
        XCTAssertEqual(channelPopup.itemTitles, ["正式版", "Beta 测试版"])
        XCTAssertEqual(channelPopup.selectedItem?.representedObject as? String, UpdateChannel.stable.rawValue)
        let updateNotesButton = try XCTUnwrap(
            buttons.first { $0.identifier?.rawValue == "viewUpdateNotesButton" }
        )
        XCTAssertTrue(updateNotesButton.isHidden)
        XCTAssertFalse(channelPopup.superview === updateButton.superview)
        channelPopup.selectItem(at: UpdateChannel.allCases.firstIndex(of: .beta)!)
        relay.updateChannel(channelPopup)
        XCTAssertEqual(selectedChannel, .beta)

        let row = try XCTUnwrap(updateButton.superview?.superview)
        XCTAssertEqual(equalHeightConstraint(in: row), 62)

        relay.update(updateButton)
        XCTAssertEqual(checkCount, 1)

        pageController.refresh(updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))))
        XCTAssertEqual(updateButton.title, "检查更新")
        XCTAssertTrue(updateButton.isEnabled)
        relay.update(updateButton)
        XCTAssertEqual(checkCount, 2)

        pageController.refresh(updateState: .available(
            current: try XCTUnwrap(AppSemanticVersion("1.0.6")),
            latest: try XCTUnwrap(AppSemanticVersion("1.0.7"))
        ))
        XCTAssertEqual(updateButton.title, "下载并安装")
        XCTAssertTrue(updateButton.isEnabled)
        XCTAssertEqual(updateNotesButton.title, "查看更新内容")
        XCTAssertFalse(updateNotesButton.isHidden)
        XCTAssertEqual((updateButton.superview as? NSStackView)?.arrangedSubviews.first, updateNotesButton)
        relay.openUpdateNotes(updateNotesButton)
        XCTAssertEqual(openNotesCount, 1)
        relay.update(updateButton)
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(
            updateTestDescendants(of: page).compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == "checkForUpdatesSubtitle" }?.stringValue,
            "新版本可用：1.0.6 -> 1.0.7"
        )
    }

    func testDashboardUpdateCopyIsLocalizedAcrossAllSupportedLanguages() throws {
        let states: [AppLanguage] = [
            .simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong, .japanese, .english,
            .korean, .spanish, .german
        ]
        for language in states {
            let presentation = DashboardUpdatePresentation.make(
                for: .available(
                    current: try XCTUnwrap(AppSemanticVersion("1.0.6")),
                    latest: try XCTUnwrap(AppSemanticVersion("1.0.7"))
                ),
                language: language
            )
            switch language {
            case .simplifiedChinese:
                XCTAssertEqual(presentation.subtitle, "新版本可用：1.0.6 -> 1.0.7")
                XCTAssertEqual(presentation.buttonTitle, "下载并安装")
            case .traditionalChineseTaiwan, .traditionalChineseHongKong:
                XCTAssertEqual(presentation.subtitle, "新版本可用：1.0.6 -> 1.0.7")
                XCTAssertEqual(presentation.buttonTitle, "下載並安裝")
            case .japanese:
                XCTAssertEqual(presentation.subtitle, "新しいバージョンがあります：1.0.6 -> 1.0.7")
                XCTAssertEqual(presentation.buttonTitle, "ダウンロードしてインストール")
            case .english:
                XCTAssertEqual(presentation.subtitle, "New version available: 1.0.6 -> 1.0.7")
                XCTAssertEqual(presentation.buttonTitle, "Download and Install")
            case .korean:
                XCTAssertEqual(presentation.subtitle, "새 버전 사용 가능: 1.0.6 -> 1.0.7")
                XCTAssertEqual(presentation.buttonTitle, "다운로드 및 설치")
            case .spanish:
                XCTAssertEqual(presentation.subtitle, "Nueva versión disponible: 1.0.6 -> 1.0.7")
                XCTAssertEqual(presentation.buttonTitle, "Descargar e instalar")
            case .german:
                XCTAssertEqual(presentation.subtitle, "Neue Version verfügbar: 1.0.6 -> 1.0.7")
                XCTAssertEqual(presentation.buttonTitle, "Laden und installieren")
            case .system:
                XCTFail("system is not part of this explicit localization matrix")
            }
            XCTAssertTrue(presentation.showsReleaseNotesButton)
            XCTAssertEqual(
                tr(.keyDashboardGeneralAndRefreshPagesViewReleaseNotes, language: language),
                language == .simplifiedChinese ? "查看更新内容" :
                    (language == .traditionalChineseTaiwan || language == .traditionalChineseHongKong) ? "查看更新內容" :
                    language == .japanese ? "更新内容を見る" :
                    language == .korean ? "업데이트 내용 보기" :
                    language == .spanish ? "Ver notas de la versión" :
                    language == .german ? "Versionshinweise anzeigen" : "View Release Notes"
            )
            XCTAssertEqual(
                tr(.keyDashboardGeneralAndRefreshPagesUpdateChannelDescription, language: language),
                language == .simplifiedChinese ? "选择要检查的正式版或 Beta 测试版更新" :
                    (language == .traditionalChineseTaiwan || language == .traditionalChineseHongKong) ? "選擇要檢查的正式版或 Beta 測試版更新" :
                    language == .japanese ? "正式版またはベータテストの更新を確認するか選択します" :
                    language == .korean ? "정식 버전 또는 베타 테스트 업데이트를 확인할지 선택합니다" :
                    language == .spanish ? "Elige si quieres buscar actualizaciones estables o beta" :
                    language == .german ? "Wähle, ob nach stabilen oder Beta-Updates gesucht werden soll" :
                    "Choose whether to check Stable or Beta releases"
            )
            let downloading = DashboardUpdatePresentation.make(
                for: .downloading(
                    current: try XCTUnwrap(AppSemanticVersion("1.0.6")),
                    latest: try XCTUnwrap(AppSemanticVersion("1.0.7")),
                    progress: 25
                ),
                language: language
            )
            let installing = DashboardUpdatePresentation.make(
                for: .installing(
                    current: try XCTUnwrap(AppSemanticVersion("1.0.6")),
                    latest: try XCTUnwrap(AppSemanticVersion("1.0.7")),
                    progress: 25
                ),
                language: language
            )
            switch language {
            case .simplifiedChinese:
                XCTAssertEqual(downloading.buttonTitle, "下载中 25% …")
                XCTAssertEqual(installing.buttonTitle, "安装中 25% …")
            case .traditionalChineseTaiwan, .traditionalChineseHongKong:
                XCTAssertEqual(downloading.buttonTitle, "下載中 25% …")
                XCTAssertEqual(installing.buttonTitle, "安裝中 25% …")
            case .japanese:
                XCTAssertEqual(downloading.buttonTitle, "ダウンロード中 25% …")
                XCTAssertEqual(installing.buttonTitle, "インストール中 25% …")
            case .english:
                XCTAssertEqual(downloading.buttonTitle, "Downloading 25% …")
                XCTAssertEqual(installing.buttonTitle, "Installing 25% …")
            case .korean:
                XCTAssertEqual(downloading.buttonTitle, "25% 다운로드 중 …")
                XCTAssertEqual(installing.buttonTitle, "25% 설치 중 …")
            case .spanish:
                XCTAssertEqual(downloading.buttonTitle, "Descargando 25% …")
                XCTAssertEqual(installing.buttonTitle, "Instalando 25% …")
            case .german:
                XCTAssertEqual(downloading.buttonTitle, "25% wird geladen …")
                XCTAssertEqual(installing.buttonTitle, "25% wird installiert …")
            case .system:
                XCTFail("system is not part of this explicit localization matrix")
            }
            let latest = DashboardUpdatePresentation.make(
                for: .latest(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))),
                language: language
            )
            XCTAssertEqual(
                latest.buttonTitle,
                language == .simplifiedChinese ? "检查更新" :
                (language == .traditionalChineseTaiwan || language == .traditionalChineseHongKong) ? "檢查更新" :
                    language == .japanese ? "アップデートを確認" :
                    language == .korean ? "업데이트 확인" :
                    language == .spanish ? "Buscar actualizaciones" :
                    language == .german ? "Nach Updates suchen" : "Check for Updates"
            )
            XCTAssertTrue(latest.buttonEnabled)
            XCTAssertEqual(
                UpdateChannel.stable.localizedTitle(using: language),
                language == .simplifiedChinese ? "正式版" :
                    (language == .traditionalChineseTaiwan || language == .traditionalChineseHongKong) ? "正式版" :
                    language == .japanese ? "正式版" :
                    language == .korean ? "정식 버전" :
                    language == .spanish ? "Estable" :
                    language == .german ? "Stabil" : "Stable"
            )
            XCTAssertEqual(
                UpdateChannel.beta.localizedTitle(using: language),
                language == .simplifiedChinese ? "Beta 测试版" :
                    (language == .traditionalChineseTaiwan || language == .traditionalChineseHongKong) ? "Beta 測試版" :
                    language == .japanese ? "ベータテスト" :
                    language == .korean ? "베타 테스트" :
                    language == .spanish ? "Prueba beta" :
                    language == .german ? "Betatest" : "Beta Test"
            )
            let failure = DashboardUpdatePresentation.make(
                for: .failed(.network),
                language: language
            )
            XCTAssertTrue(failure.buttonEnabled)
        }
    }

    // MARK: - Fixtures

    private func releaseBody(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = false,
        body: String? = nil,
        htmlURL: String? = nil,
        assets: [[String: Any]]
    ) -> Data {
        var object: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "assets": assets
        ]
        if let body { object["body"] = body }
        if let htmlURL { object["html_url"] = htmlURL }
        return try! JSONSerialization.data(withJSONObject: object, options: [])
    }

    private func releaseListBody(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]]
    ) -> Data {
        let release = try! JSONSerialization.jsonObject(
            with: releaseBody(tag: tag, draft: draft, prerelease: prerelease, assets: assets)
        )
        return try! JSONSerialization.data(withJSONObject: [release], options: [])
    }

    private func makeRelease(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]]? = nil
    ) -> GitHubRelease {
        let version = AppSemanticVersion(tag)!
        let releaseAssets = assets.map { values in
            values.compactMap { value in
                guard let name = value["name"] as? String else { return nil }
                return GitHubReleaseAsset(
                    name: name,
                    browserDownloadURL: (value["browser_download_url"] as? String).flatMap(URL.init(string:)),
                    size: value["size"] as? Int,
                    digest: value["digest"] as? String
                )
            }
        } ?? [GitHubReleaseAsset(
            name: "BalanceBar-\(version.normalizedAssetVersion).dmg",
            browserDownloadURL: URL(string: "https://example.test/BalanceBar-\(version).dmg"),
            size: nil,
            digest: nil
        )]
        return GitHubRelease(
            tagName: tag,
            draft: draft,
            prerelease: prerelease,
            assets: releaseAssets
        )
    }

    private func waitForState(
        _ service: UpdateService,
        queue: DispatchQueue,
        predicate: @escaping (UpdateCheckState) -> Bool
    ) -> XCTestExpectation {
        let expectation = expectation(description: "update state transition")
        service.onStateChange = { state in
            guard predicate(state) else { return }
            expectation.fulfill()
        }
        _ = queue
        return expectation
    }

    private func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return String(repeating: "0", count: 64)
        #endif
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-UpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeAppBundle(at appURL: URL, version: String) throws -> URL {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.huanmeng06.BalanceBar.app",
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return appURL
    }

}

private func updateTestDescendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(updateTestDescendants)
}

private func bitmapPixelRange(
    from lower: CGFloat,
    to upper: CGFloat,
    scale: CGFloat,
    limit: Int
) -> ClosedRange<Int> {
    guard limit > 0 else { return 0...0 }
    let lowerPixel = max(0, Int(floor(lower * scale)))
    let upperPixel = min(limit - 1, Int(ceil(upper * scale)))
    return lowerPixel...max(lowerPixel, upperPixel)
}

private func bitmapYPixelRange(
    from lower: CGFloat,
    to upper: CGFloat,
    scale: CGFloat,
    pixelsHigh: Int
) -> ClosedRange<Int> {
    let bitmapHeight = CGFloat(pixelsHigh) / scale
    return bitmapPixelRange(
        from: bitmapHeight - upper,
        to: bitmapHeight - lower,
        scale: scale,
        limit: pixelsHigh
    )
}

private func bitmapContainsInk(
    _ bitmap: NSBitmapImageRep,
    xRange: ClosedRange<Int>,
    yRange: ClosedRange<Int>
) -> Bool {
    for y in yRange {
        for x in xRange {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            if color.alphaComponent > 0.05 {
                return true
            }
        }
    }
    return false
}

private func equalHeightConstraint(in view: NSView?) -> CGFloat? {
    view?.constraints.first {
        ($0.firstItem as? NSView) === view &&
            $0.firstAttribute == .height &&
            $0.relation == .equal
    }?.constant
}
