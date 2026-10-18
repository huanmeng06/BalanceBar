import Foundation
import XCTest
@testable import BalanceBar

final class ClaudeAccountIdentityProviderTests: XCTestCase {
    private final class FakeReader: AccountConfigurationReading {
        private let lock = NSLock()
        private var data: Data?
        private(set) var mainThreadReads = 0
        private(set) var reads = 0

        func set(_ json: String?) {
            lock.lock()
            data = json.map { Data($0.utf8) }
            lock.unlock()
        }

        func readData(from url: URL) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            if Thread.isMainThread { mainThreadReads += 1 }
            guard let data else { throw CocoaError(.fileNoSuchFile) }
            return data
        }
    }

    private let queue = DispatchQueue(label: "ClaudeAccountIdentityProviderTests")
    private let url = URL(fileURLWithPath: "/nonexistent/.claude.json")

    private func account(_ uuid: String?, org: String? = "org-1", email: String? = "A@Example.com") -> String {
        var fields: [String] = []
        if let uuid { fields.append("\"accountUuid\":\"\(uuid)\"") }
        if let org { fields.append("\"organizationUuid\":\"\(org)\"") }
        if let email { fields.append("\"emailAddress\":\"\(email)\"") }
        return "{\"oauthAccount\":{\(fields.joined(separator: ","))}}"
    }

    private func makeProvider(_ reader: FakeReader, date: Date = Date(timeIntervalSince1970: 100)) -> ClaudeAccountIdentityProvider {
        ClaudeAccountIdentityProvider(
            configurationURL: url,
            reader: reader,
            workQueue: queue,
            coalescingInterval: 0.05,
            now: { date }
        )
    }

    private func reloadAndWait(_ provider: ClaudeAccountIdentityProvider) {
        provider.scheduleReload()
        drain()
    }

    private func drain() {
        let done = expectation(description: "drain")
        queue.asyncAfter(deadline: .now() + 0.15) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testParsesAccountAndOrganizationUUIDs() throws {
        let identity = try ClaudeAccountConfigurationParser.identity(from: Data(account("ACC-1").utf8))
        XCTAssertEqual(identity.stableID, "claude:acc-1:org-1")
        XCTAssertEqual(identity.idSource, .accountUUID)
        XCTAssertEqual(identity.email, "a@example.com")
    }

    func testFallsBackToNormalizedEmailWhenUUIDMissing() throws {
        let identity = try ClaudeAccountConfigurationParser.identity(from: Data(account(nil, email: " A@Example.com ").utf8))
        XCTAssertEqual(identity.stableID, "claude-email:a@example.com")
        XCTAssertEqual(identity.idSource, .emailFallback)
    }

    func testReportsMissingAndCorruptedConfiguration() {
        XCTAssertThrowsError(try ClaudeAccountConfigurationParser.identity(from: Data("{".utf8))) {
            XCTAssertEqual($0 as? AccountIdentityError, .corrupted)
        }
        XCTAssertThrowsError(try ClaudeAccountConfigurationParser.identity(from: Data("{}".utf8))) {
            XCTAssertEqual($0 as? AccountIdentityError, .missingAccount)
        }
        XCTAssertThrowsError(try ClaudeAccountConfigurationParser.identity(from: Data(account(nil, email: nil).utf8))) {
            XCTAssertEqual($0 as? AccountIdentityError, .missingAccount)
        }
    }

    func testTokenRefreshKeepsEpochAndUpdatesCredentialVersion() {
        let reader = FakeReader()
        reader.set(account("acc-1"))
        let provider = makeProvider(reader)
        reloadAndWait(provider)
        provider.ingestCredential(accessToken: "token-a")
        drain()
        let first = provider.credentialVersion

        var changes: [AccountIdentityChange] = []
        let token = provider.addObserver { changes.append($0) }
        provider.ingestCredential(accessToken: "token-b")
        reloadAndWait(provider)

        XCTAssertEqual(provider.accountEpoch, .initial)
        XCTAssertNotNil(first)
        XCTAssertNotEqual(provider.credentialVersion, first)
        XCTAssertFalse(provider.credentialVersion?.value.contains("token") ?? true)
        XCTAssertEqual(changes.map(\.accountChanged), [false])
        withExtendedLifetime(token) {}
    }

    func testAccountSwitchAdvancesEpochNotifiesAndRecordsTimeline() {
        let reader = FakeReader()
        reader.set(account("acc-1"))
        var current = Date(timeIntervalSince1970: 100)
        let provider = ClaudeAccountIdentityProvider(
            configurationURL: url, reader: reader, workQueue: queue, coalescingInterval: 0.05, now: { current }
        )
        reloadAndWait(provider)

        var changes: [AccountIdentityChange] = []
        let token = provider.addObserver { changes.append($0) }
        current = Date(timeIntervalSince1970: 200)
        reader.set(account("acc-2"))
        reloadAndWait(provider)

        XCTAssertEqual(provider.accountEpoch, AccountEpoch(1))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.accountChanged, true)
        XCTAssertEqual(changes.first?.epoch, AccountEpoch(1))
        XCTAssertEqual(provider.timeline.map(\.epoch), [AccountEpoch(0), AccountEpoch(1)])
        XCTAssertEqual(provider.timelineEntry(at: Date(timeIntervalSince1970: 150))?.identity?.stableID, "claude:acc-1:org-1")
        XCTAssertEqual(provider.timelineEntry(at: Date(timeIntervalSince1970: 250))?.identity?.stableID, "claude:acc-2:org-1")
        withExtendedLifetime(token) {}
    }

    func testCorruptedFileKeepsLastAccountAndEpoch() {
        let reader = FakeReader()
        reader.set(account("acc-1"))
        let provider = makeProvider(reader)
        reloadAndWait(provider)

        reader.set("{not json")
        reloadAndWait(provider)
        XCTAssertEqual(provider.lastReadError, .corrupted)
        XCTAssertEqual(provider.accountIdentity?.stableID, "claude:acc-1:org-1")
        XCTAssertEqual(provider.accountEpoch, .initial)

        reader.set(nil)
        reloadAndWait(provider)
        XCTAssertEqual(provider.lastReadError, .unreadable)
        XCTAssertEqual(provider.accountEpoch, .initial)
    }

    func testBurstOfEventsIsCoalescedIntoOneRead() {
        let reader = FakeReader()
        reader.set(account("acc-1"))
        let provider = makeProvider(reader)
        for _ in 0..<10 { provider.scheduleReload() }
        drain()
        XCTAssertEqual(reader.reads, 1)
    }

    func testMainThreadNeverPerformsIOOrCredentialWork() {
        let reader = FakeReader()
        reader.set(account("acc-1"))
        let provider = makeProvider(reader)
        XCTAssertTrue(Thread.isMainThread)
        provider.scheduleReload()
        provider.ingestCredential(accessToken: "token")
        XCTAssertEqual(reader.reads, 0, "Calls from the main thread must only enqueue work")
        drain()
        XCTAssertEqual(reader.reads, 1)
        XCTAssertEqual(reader.mainThreadReads, 0)
        XCTAssertNotNil(provider.credentialVersion)
    }

    func testFileMonitoringReloadsAfterRealFileChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(".claude.json")
        try Data(account("acc-1").utf8).write(to: fileURL, options: .atomic)

        let provider = ClaudeAccountIdentityProvider(
            configurationURL: fileURL, workQueue: queue, coalescingInterval: 0.05
        )
        let switched = expectation(description: "switched")
        let token = provider.addObserver { if $0.epoch == AccountEpoch(1) { switched.fulfill() } }
        provider.startMonitoring()
        drain()
        XCTAssertEqual(provider.accountIdentity?.stableID, "claude:acc-1:org-1")

        try Data(account("acc-2").utf8).write(to: fileURL, options: .atomic)
        wait(for: [switched], timeout: 3)
        provider.stopMonitoring()
        withExtendedLifetime(token) {}
    }
}
