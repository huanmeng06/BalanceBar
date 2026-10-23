import Darwin
import XCTest
@testable import BalanceBar

final class ClaudeStatusLineSourceTests: XCTestCase {
    private final class Identity: AccountIdentityProviding {
        var accountIdentity: AccountIdentity? = AccountIdentity(stableID: "acct-a", idSource: .accountUUID)
        var credentialVersion: CredentialVersion? = CredentialVersion("v1")
        var accountEpoch = AccountEpoch.initial
    }

    private final class Registry: ClaudeSessionStartLookup {
        var starts: [String: Date] = [:]
        func startedAt(sessionID: String) -> Date? { starts[sessionID] }
    }

    private final class Collector {
        private let lock = NSLock()
        private var items: [QuotaObservation] = []
        func append(_ item: QuotaObservation) { lock.withLock { items.append(item) } }
        var all: [QuotaObservation] { lock.withLock { items } }
    }

    private var directory: URL!
    private var socketURL: URL { directory.appendingPathComponent("s.sock") }
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var identity: Identity!
    private var registry: Registry!
    private var collector: Collector!
    private var source: ClaudeStatusLineSource!

    override func setUpWithError() throws {
        // sun_path is limited to 104 bytes, so keep the socket path short.
        directory = URL(fileURLWithPath: "/tmp/bbsl-\(UUID().uuidString.prefix(8))")
        identity = Identity()
        registry = Registry()
        collector = Collector()
        source = ClaudeStatusLineSource(
            accountProvider: identity, tracker: ClaudeRealtimeTracker(now: { [unowned self] in clock }),
            socketURL: socketURL, sessionStarts: registry, now: { [unowned self] in clock })
        source.start { [collector] in collector!.append($0) }
        source.waitUntilIdle()
    }

    override func tearDownWithError() throws {
        source.stop()
        source.waitUntilIdle()
        try? FileManager.default.removeItem(at: directory)
    }

    // Fixed per test: the clock moves, the account's reset times do not.
    private let fiveReset: Double = 1_800_000_000 + 3_600
    private let sevenReset: Double = 1_800_000_000 + 86_400

    private func payload(session: String = "s1", five: Double = 10, seven: Double = 40,
                         fiveReset: Double? = nil, sevenReset: Double? = nil) -> Data {
        let object: [String: Any] = [
            "schemaVersion": 1, "sessionID": session,
            "fiveHour": ["usedPercentage": five, "resetsAt": fiveReset ?? self.fiveReset],
            "sevenDay": ["usedPercentage": seven, "resetsAt": sevenReset ?? self.sevenReset]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @discardableResult
    private func send(_ data: Data) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        return true
    }

    /// Sends and waits until the source has merged the message.
    private func deliver(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        let before = source.handledConnectionCount
        XCTAssertTrue(send(data), file: file, line: line)
        let deadline = Date().addingTimeInterval(2)
        while source.handledConnectionCount == before, Date() < deadline { usleep(2_000) }
        XCTAssertGreaterThan(source.handledConnectionCount, before, "connection was accepted", file: file, line: line)
        source.waitUntilIdle()
    }

    private func startNewSession(_ id: String) {
        registry.starts[id] = clock.addingTimeInterval(1)
        clock = clock.addingTimeInterval(2)
    }

    // MARK: - Socket

    func testListenerKeepsAcceptingManyConsecutiveConnections() {
        startNewSession("s1")
        for step in 0..<25 { deliver(payload(five: Double(step), seven: 40 + Double(step) / 10)) }
        // Every message changed both windows, so each produced two observations.
        XCTAssertEqual(collector.all.count, 50)
        let lastSeven = collector.all.last { $0.window == .sevenDay }?.usedPercentage ?? 0
        XCTAssertEqual(lastSeven, 42.4, accuracy: 0.0001)
    }

    func testOversizedAndMalformedMessagesDoNotStopTheListener() {
        startNewSession("s1")
        deliver(Data(repeating: 0x41, count: ClaudeStatusLineSource.maximumPayloadBytes + 10))
        deliver(Data("not json".utf8))
        deliver(Data(#"{"schemaVersion":2,"sessionID":"s1"}"#.utf8))
        XCTAssertTrue(collector.all.isEmpty)
        deliver(payload())
        XCTAssertEqual(collector.all.count, 2)
    }

    func testStopRemovesSocketAndRestartListensAgain() {
        source.stop()
        source.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertFalse(send(payload()), "a stopped source refuses connections at once")
        source.start { [collector] in collector!.append($0) }
        source.waitUntilIdle()
        startNewSession("s1")
        deliver(payload())
        XCTAssertEqual(collector.all.count, 2)
    }

    // MARK: - Evidence

    func testFirstPayloadOfSessionStartedBeforeListenerIsOnlyABaseline() {
        registry.starts["old"] = clock.addingTimeInterval(-600)
        deliver(payload(session: "old"))
        XCTAssertTrue(collector.all.isEmpty)
    }

    func testIdenticalRepeatsAreReplaysAndNeverEmitted() {
        startNewSession("s1")
        deliver(payload())
        deliver(payload())
        deliver(payload())
        XCTAssertEqual(collector.all.count, 2)
    }

    func testLowerUsageInSameCycleIsAnOlderSnapshot() {
        startNewSession("s1")
        deliver(payload(five: 20))
        deliver(payload(five: 15))
        XCTAssertEqual(collector.all.count, 2)
    }

    func testNullWindowAndOutOfRangeValuesAreDroppedPerWindow() throws {
        startNewSession("s1")
        let object: [String: Any] = [
            "schemaVersion": 1, "sessionID": "s1",
            "fiveHour": ["usedPercentage": 101, "resetsAt": fiveReset],
            "sevenDay": ["usedPercentage": 40, "resetsAt": sevenReset]
        ]
        deliver(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(collector.all.map(\.window), [.sevenDay])
        let pastReset: [String: Any] = [
            "schemaVersion": 1, "sessionID": "s1",
            "sevenDay": ["usedPercentage": 41, "resetsAt": clock.timeIntervalSince1970 - 3_600]
        ]
        deliver(try JSONSerialization.data(withJSONObject: pastReset))
        XCTAssertEqual(collector.all.count, 1, "a reset in the past is malformed")
    }

    // MARK: - Attribution

    func testSessionOfUnknownOwnerNeedsBothResetsToMatchOfficialReading() {
        registry.starts["old"] = clock.addingTimeInterval(-600)
        deliver(payload(session: "old", five: 10))
        deliver(payload(session: "old", five: 11))
        XCTAssertTrue(collector.all.isEmpty, "no official reading to match yet")
        source.setGradeAResets([
            .fiveHour: Date(timeIntervalSince1970: fiveReset),
            .sevenDay: Date(timeIntervalSince1970: sevenReset + 60)
        ])
        deliver(payload(session: "old", five: 12))
        XCTAssertTrue(collector.all.isEmpty, "one mismatching reset is not enough")
        source.setGradeAResets([
            .fiveHour: Date(timeIntervalSince1970: fiveReset),
            .sevenDay: Date(timeIntervalSince1970: sevenReset)
        ])
        deliver(payload(session: "old", five: 13))
        XCTAssertEqual(collector.all.count, 2)
    }

    func testSessionWithUnknownStartIsTreatedAsUnknownOwner() {
        deliver(payload(session: "unregistered", five: 10))
        deliver(payload(session: "unregistered", five: 11))
        XCTAssertTrue(collector.all.isEmpty)
    }

    func testSessionsStartedBeforeAnAccountSwitchAreRejected() {
        startNewSession("a-session")
        deliver(payload(session: "a-session", five: 10))
        XCTAssertEqual(collector.all.count, 2)

        identity.accountIdentity = AccountIdentity(stableID: "acct-b", idSource: .accountUUID)
        identity.accountEpoch = identity.accountEpoch.next
        clock = clock.addingTimeInterval(5)
        source.accountDidChange(epoch: identity.accountEpoch)
        source.waitUntilIdle()

        // Account A's still-running session keeps reporting after the switch.
        deliver(payload(session: "a-session", five: 50))
        deliver(payload(session: "a-session", five: 51))
        XCTAssertEqual(collector.all.count, 2, "the old session's data never reaches account B")

        startNewSession("b-session")
        deliver(payload(session: "b-session", five: 5))
        XCTAssertEqual(collector.all.count, 4)
        XCTAssertEqual(collector.all.last?.accountID, "acct-b")
    }

    func testSwitchDetectedFromEpochEvenWithoutPipelineNotice() {
        startNewSession("a-session")
        deliver(payload(session: "a-session", five: 10))
        identity.accountIdentity = AccountIdentity(stableID: "acct-b", idSource: .accountUUID)
        identity.accountEpoch = identity.accountEpoch.next
        deliver(payload(session: "a-session", five: 50))
        deliver(payload(session: "a-session", five: 51))
        XCTAssertEqual(collector.all.count, 2)
    }

    func testDisagreeingResetsAcrossSessionsStopNativeData() {
        source.setGradeAResets([
            .fiveHour: Date(timeIntervalSince1970: fiveReset),
            .sevenDay: Date(timeIntervalSince1970: sevenReset)
        ])
        startNewSession("one")
        deliver(payload(session: "one", five: 10))
        XCTAssertEqual(collector.all.count, 2)
        startNewSession("two")
        deliver(payload(session: "two", five: 30, fiveReset: fiveReset + 900))
        deliver(payload(session: "one", five: 11))
        XCTAssertEqual(collector.all.count, 2, "two identities reporting at once: nothing is trusted")
    }

    func testMissingIdentityRejectsEverything() {
        identity.accountIdentity = nil
        startNewSession("s1")
        deliver(payload())
        XCTAssertTrue(collector.all.isEmpty)
    }
}
