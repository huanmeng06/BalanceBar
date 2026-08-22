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
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
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
        private var completion: ((Result<GitHubRelease, GitHubReleaseClientError>) -> Void)?

        func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, GitHubReleaseClientError>) -> Void) {
            requestCount += 1
            self.completion = completion
        }

        func resolve(_ result: Result<GitHubRelease, GitHubReleaseClientError>) {
            completion?(result)
            completion = nil
        }
    }

    private final class StubDownloader: UpdateAssetDownloading {
        private(set) var requestCount = 0
        private(set) var cleanedURLs: [URL] = []
        private var completion: ((Result<URL, UpdateAssetDownloadError>) -> Void)?

        func download(
            asset: GitHubReleaseAsset,
            completion: @escaping (Result<URL, UpdateAssetDownloadError>) -> Void
        ) {
            requestCount += 1
            self.completion = completion
        }

        func resolve(_ result: Result<URL, UpdateAssetDownloadError>) {
            completion?(result)
            completion = nil
        }

        func cleanupDownloadedFile(at url: URL) {
            cleanedURLs.append(url)
        }
    }

    private final class StubInstaller: UpdateApplicationInstalling {
        var shouldFail = false
        private(set) var installCount = 0
        private(set) var lastVersion: AppSemanticVersion?

        func install(
            diskImageURL: URL,
            expectedVersion: AppSemanticVersion,
            currentApplicationURL: URL,
            expectedBundleIdentifier: String
        ) throws {
            installCount += 1
            lastVersion = expectedVersion
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
            assets: [
                ["name": "BalanceBar-1.0.0.zip", "browser_download_url": "https://example.test/wrong.zip", "size": 1],
                ["name": "BalanceBar-1.0.0.dmg", "browser_download_url": "https://example.test/BalanceBar-1.0.0.dmg", "size": 4, "digest": "sha256:fixture"]
            ]
        )
        let release = try JSONDecoder().decode(GitHubRelease.self, from: body)
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

    func testGitHubReleaseClientUsesLatestEndpointAndPublicHeaders() throws {
        let endpoint = URL(string: "https://api.github.test/repos/huanmeng06/BalanceBar/releases/latest")!
        StubURLProtocol.setHandler { _ in
            StubURLResult(data: self.releaseBody(tag: "v1.0.1", assets: []))
        }
        let client = GitHubReleaseClient(session: session, endpoint: endpoint)
        let expectation = expectation(description: "release fetched")
        var result: Result<GitHubRelease, GitHubReleaseClientError>?
        client.fetchLatestRelease { value in
            result = value
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        guard case .success(let release) = result else {
            return XCTFail("expected decoded release, got \(String(describing: result))")
        }
        XCTAssertEqual(release.tagName, "v1.0.1")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "BalanceBar")
    }

    func testGitHubReleaseClientSurfacesHTTPAndInvalidJSONFailures() {
        StubURLProtocol.setHandler { _ in
            StubURLResult(statusCode: 503, data: Data(#"{"message":"unavailable"}"#.utf8))
        }
        let httpExpectation = expectation(description: "http failure")
        var httpResult: Result<GitHubRelease, GitHubReleaseClientError>?
        GitHubReleaseClient(session: session).fetchLatestRelease {
            httpResult = $0
            httpExpectation.fulfill()
        }
        wait(for: [httpExpectation], timeout: 2)
        guard case .failure(.httpStatus(503)) = httpResult else {
            return XCTFail("expected HTTP failure, got \(String(describing: httpResult))")
        }

        StubURLProtocol.setHandler { _ in StubURLResult(data: Data("not-json".utf8)) }
        let jsonExpectation = expectation(description: "json failure")
        var jsonResult: Result<GitHubRelease, GitHubReleaseClientError>?
        GitHubReleaseClient(session: session).fetchLatestRelease {
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
        downloader.download(asset: asset) {
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
        fetcher.resolve(.success(makeRelease(tag: "v1.0.0")))
        wait(for: [firstLatest], timeout: 2)
        XCTAssertEqual(fetcher.requestCount, 1)

        let draftLatest = waitForState(service, queue: queue) { state in
            if case .latest = state { return true }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success(makeRelease(tag: "v9.0.0", draft: true)))
        wait(for: [draftLatest], timeout: 2)

        let prereleaseLatest = waitForState(service, queue: queue) { state in
            if case .latest = state { return true }
            return false
        }
        service.checkForUpdates()
        fetcher.resolve(.success(makeRelease(tag: "v9.0.0", prerelease: true)))
        wait(for: [prereleaseLatest], timeout: 2)
        XCTAssertEqual(downloader.requestCount, 0)
        XCTAssertEqual(installer.installCount, 0)
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
        fetcher.resolve(.success(release))
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
            workQueue: DispatchQueue.main
        )
        service.checkForUpdates()
        fetcher.resolve(.success(makeRelease(tag: "v1.0.0")))
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
        fetcher.resolve(.success(makeRelease(tag: "v1.0.1", assets: [])))
        wait(for: [failure], timeout: 2)
    }

    func testUpdateServiceDownloadsInstallsCleansUpAndExposesRestartingState() {
        let fetcher = StubReleaseFetcher()
        let downloader = StubDownloader()
        let installer = StubInstaller()
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
        fetcher.resolve(.success(makeRelease(tag: "v1.0.1")))
        let available = waitForState(service, queue: queue) {
            if case .available = $0 { return true }
            return false
        }
        wait(for: [available], timeout: 2)

        let restarting = waitForState(service, queue: queue) {
            if case .restarting(_, let latest) = $0 { return latest == AppSemanticVersion("1.0.1") }
            return false
        }
        service.installAvailableUpdate()
        XCTAssertEqual(downloader.requestCount, 1)
        downloader.resolve(.success(URL(fileURLWithPath: "/tmp/verified-BalanceBar-1.0.1.dmg")))
        wait(for: [restarting], timeout: 2)
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
        fetcher.resolve(.success(makeRelease(tag: "v1.0.1")))
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
        let installer = UpdateApplicationInstaller(
            fileSystem: LiveUpdateFileSystem(),
            mounter: mounter,
            relauncher: relauncher
        )
        try installer.install(
            diskImageURL: image,
            expectedVersion: try XCTUnwrap(AppSemanticVersion("1.0.1")),
            currentApplicationURL: currentApp,
            expectedBundleIdentifier: "com.huanmeng06.BalanceBar.app"
        )
        XCTAssertEqual(LiveUpdateFileSystem().bundleMetadata(at: currentApp)?.shortVersion, "1.0.1")
        XCTAssertEqual(mounter.mountCount, 1)
        XCTAssertEqual(mounter.unmountCount, 1)
        XCTAssertEqual(relauncher.relaunchCount, 1)
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

    // MARK: - Dashboard state/action wiring and localization

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
        relay.onCheckForUpdates = { checkCount += 1 }
        relay.onInstallUpdate = { installCount += 1 }
        let pageController = DashboardGeneralPage()
        let page = pageController.make(.init(
            preferences: preferences,
            currentProviderName: "OpenAI",
            relay: relay,
            updateState: .latest(current: try XCTUnwrap(AppSemanticVersion("1.0.6")))
        ))
        let buttons = updateTestDescendants(of: page).compactMap { $0 as? NSButton }
        let updateButton = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "checkForUpdatesButton" })
        XCTAssertEqual(updateButton.title, "最新版本")
        XCTAssertFalse(updateButton.isEnabled)
        let row = try XCTUnwrap(updateButton.superview)
        XCTAssertEqual(equalHeightConstraint(in: row), 62)

        pageController.refresh(updateState: .idle(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))))
        XCTAssertEqual(updateButton.title, "检查更新")
        XCTAssertTrue(updateButton.isEnabled)
        relay.update(updateButton)
        XCTAssertEqual(checkCount, 1)

        pageController.refresh(updateState: .available(
            current: try XCTUnwrap(AppSemanticVersion("1.0.6")),
            latest: try XCTUnwrap(AppSemanticVersion("1.0.7"))
        ))
        XCTAssertEqual(updateButton.title, "下载并安装")
        XCTAssertTrue(updateButton.isEnabled)
        relay.update(updateButton)
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(
            updateTestDescendants(of: page).compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == "checkForUpdatesSubtitle" }?.stringValue,
            "新版本可用：1.0.6 -> 1.0.7"
        )
    }

    func testDashboardUpdateCopyIsLocalizedAcrossAllSupportedLanguages() throws {
        let states: [AppLanguage] = [.simplifiedChinese, .traditionalChinese, .japanese, .english]
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
            case .traditionalChinese:
                XCTAssertEqual(presentation.subtitle, "新版本可用：1.0.6 -> 1.0.7")
                XCTAssertEqual(presentation.buttonTitle, "下載並安裝")
            case .japanese:
                XCTAssertEqual(presentation.subtitle, "新しいバージョンがあります：1.0.6 -> 1.0.7")
                XCTAssertEqual(presentation.buttonTitle, "ダウンロードしてインストール")
            case .english:
                XCTAssertEqual(presentation.subtitle, "New version available: 1.0.6 -> 1.0.7")
                XCTAssertEqual(presentation.buttonTitle, "Download and Install")
            case .system:
                XCTFail("system is not part of this explicit localization matrix")
            }
            let latest = DashboardUpdatePresentation.make(
                for: .latest(current: try XCTUnwrap(AppSemanticVersion("1.0.6"))),
                language: language
            )
            XCTAssertFalse(latest.buttonEnabled)
        }
    }

    // MARK: - Fixtures

    private func releaseBody(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]]
    ) -> Data {
        let object: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "assets": assets
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [])
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

private func equalHeightConstraint(in view: NSView?) -> CGFloat? {
    view?.constraints.first {
        ($0.firstItem as? NSView) === view &&
            $0.firstAttribute == .height &&
            $0.relation == .equal
    }?.constant
}
