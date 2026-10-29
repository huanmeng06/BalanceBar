import XCTest
@testable import BalanceBar

private final class FakeIdentity: AccountIdentityProviding {
    var accountIdentity: AccountIdentity? = AccountIdentity(
        stableID: "acct-1", email: "user@example.com", idSource: .accountUUID)
    var credentialVersion: CredentialVersion? = nil
    var accountEpoch = AccountEpoch(3)
}

private final class Collector {
    private let lock = NSLock()
    private var items: [QuotaObservation] = []
    func add(_ item: QuotaObservation) { lock.lock(); items.append(item); lock.unlock() }
    var all: [QuotaObservation] { lock.lock(); defer { lock.unlock() }; return items }
}

final class SnapshotInboxTests: XCTestCase {
    private var root: URL!
    private var inbox: URL!
    private var inboxes: [SnapshotInbox] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotInboxTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        inboxes.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let repo = try TestRepositoryRoot.locate(from: #filePath)
        return try Data(contentsOf: repo.appendingPathComponent("Tests/Fixtures/Quota").appendingPathComponent(name))
    }

    private func place(fixture name: String, as target: String? = nil) throws {
        try fixtureData(name).write(to: inbox.appendingPathComponent(target ?? name))
    }

    private func collect(
        identity: FakeIdentity = FakeIdentity(),
        retry: TimeInterval = 0.05,
        now: @escaping () -> Date = Date.init,
        settle: TimeInterval = 0.1
    ) -> [QuotaObservation] {
        let collector = Collector()
        let source = SnapshotInbox(
            inboxDirectory: inbox,
            identity: identity,
            configuration: SnapshotInboxConfiguration(halfWriteRetryDelay: retry),
            now: now
        )
        inboxes.append(source)
        source.start { collector.add($0) }
        // Start-up (directory creation, watcher, initial scan) runs on the source queue, so draining it
        // makes the initial scan deterministic; `settle` only covers the scheduled half-write retry.
        source.queue.sync {}
        Thread.sleep(forTimeInterval: settle)
        source.stop()
        return collector.all
    }

    func testHUDFixtureProducesBothWindows() throws {
        try place(fixture: "hud-0.11.3.json")
        let observations = collect().sorted { $0.window.rawValue < $1.window.rawValue }
        XCTAssertEqual(observations.map(\.window), [.fiveHour, .sevenDay])
        XCTAssertEqual(observations.map(\.usedPercentage), [34, 61.5])
        XCTAssertEqual(observations.first?.source, "inbox")
        XCTAssertEqual(observations.first?.trust, .b)
        XCTAssertEqual(observations.first?.accountID, "acct-1")
        XCTAssertEqual(observations.first?.epoch, AccountEpoch(3))
        XCTAssertNotNil(observations.first?.observedAt)
    }

    func testModSupersetProducesAllWindowsWithDeclaredSource() throws {
        // The fixture's account.email_hash is sha256 of "user@example.com", the FakeIdentity email,
        // so the fail-closed attribution check accepts it.
        try place(fixture: "mod-super-set.json")
        let observations = collect()
        XCTAssertEqual(Set(observations.map(\.window.rawValue)),
                       ["five_hour", "seven_day", "sonnet_context", "extra_usage"])
        XCTAssertEqual(Set(observations.map(\.source)), ["balancebar-mod"])
    }

    // MARK: Account attribution (fail closed)

    /// Writes a Schema v1 snapshot with the given source and account email hash.
    private func placeSnapshot(
        source: String?, emailHash: String?, as name: String = "snapshot.json",
        percentage: Double = 10, updatedAt: String = "2026-10-17T06:12:03Z"
    ) throws {
        var object: [String: Any] = [
            "updated_at": updatedAt,
            "five_hour": ["used_percentage": percentage, "resets_at": "2026-10-17T09:00:00Z"],
        ]
        if let source { object["source"] = source }
        if let emailHash { object["account"] = ["email_hash": emailHash] }
        try JSONSerialization.data(withJSONObject: object).write(to: inbox.appendingPathComponent(name))
    }

    private func latestInboxHealth() -> QuotaAdapterHealth? {
        inboxes.last?.adapters.first { $0.sourceID == "inbox" }?.health
    }

    func testModSnapshotWithMatchingEmailHashIsEmitted() throws {
        try placeSnapshot(
            source: "balancebar-mod",
            emailHash: SnapshotInbox.emailHash("user@example.com"))
        let observations = collect()
        XCTAssertEqual(observations.map(\.window), [.fiveHour])
        XCTAssertEqual(observations.map(\.source), ["balancebar-mod"])
    }

    func testModSnapshotWithForeignEmailHashIsRejected() throws {
        try placeSnapshot(
            source: "balancebar-mod",
            emailHash: SnapshotInbox.emailHash("someone-else@example.com"))
        XCTAssertTrue(collect().isEmpty)
        XCTAssertEqual(
            latestInboxHealth(),
            .degraded(reason: "rejected snapshot: account email hash does not match the active account"))
    }

    func testModSnapshotWithoutEmailHashIsRejected() throws {
        // Closes the old patch's hole where a missing hash was silently tolerated.
        try placeSnapshot(source: "balancebar-mod", emailHash: nil)
        XCTAssertTrue(collect().isEmpty)
        XCTAssertEqual(
            latestInboxHealth(),
            .degraded(reason: "rejected snapshot: missing account email hash"))
    }

    func testForeignEmailHashIsRejectedForAnySource() throws {
        try placeSnapshot(source: "some-other-tool", emailHash: "sha256:deadbeef")
        XCTAssertTrue(collect().isEmpty)
    }

    func testAccountWithoutEmailCannotAttributeAnySnapshot() throws {
        let identity = FakeIdentity()
        identity.accountIdentity = AccountIdentity(stableID: "acct-1", idSource: .accountUUID)
        try placeSnapshot(source: "balancebar-mod", emailHash: SnapshotInbox.emailHash("user@example.com"))
        XCTAssertTrue(collect(identity: identity).isEmpty)
        try placeSnapshot(source: "balancebar-mod", emailHash: nil, as: "no-hash.json")
        XCTAssertTrue(collect(identity: identity).isEmpty)
    }

    func testNonModSnapshotWithoutAccountIsStillEmitted() throws {
        // Generic inbox files without an account block keep their existing behavior.
        try placeSnapshot(source: "some-other-tool", emailHash: nil)
        let observations = collect()
        XCTAssertEqual(observations.map(\.window), [.fiveHour])
        XCTAssertEqual(observations.map(\.source), ["some-other-tool"])
    }

    func testEmailHashMatchesTheModContract() {
        XCTAssertEqual(
            SnapshotInbox.emailHash("  User@Example.COM "),
            "sha256:b4c9a289323b21a01c3e940f150eb9b8c542587f1abfd8f0e1cc1ffc5e475514")
        XCTAssertEqual(SnapshotInbox.emailHash("   "), "")
    }

    func testMissingWindowOnlyEmitsExistingWindowWithoutZeroFill() throws {
        try place(fixture: "missing-window.json")
        let observations = collect()
        XCTAssertEqual(observations.map(\.window), [.fiveHour])
    }

    func testNullPercentageProducesNoObservationForThatWindow() throws {
        try place(fixture: "hud-null-percentage.json")
        let observations = collect()
        XCTAssertEqual(observations.map(\.window), [.fiveHour])
        XCTAssertNil(observations.first?.resetsAt)
    }

    func testOutOfRangeDropsOnlyThatWindow() throws {
        try place(fixture: "out-of-range.json")
        XCTAssertEqual(collect().map(\.window), [.sevenDay])
    }

    func testCorruptFileProducesNoObservations() throws {
        try place(fixture: "corrupt.json")
        XCTAssertTrue(collect().isEmpty)
    }

    func testNoActiveAccountProducesNoObservations() throws {
        try place(fixture: "hud-0.11.3.json")
        let identity = FakeIdentity()
        identity.accountIdentity = nil
        XCTAssertTrue(collect(identity: identity).isEmpty)
    }

    func testHalfWrittenFileIsRetriedOnceAndThenRead() throws {
        let target = inbox.appendingPathComponent("hud.json")
        let full = try fixtureData("hud-0.11.3.json")
        try full.prefix(40).write(to: target)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { try? full.write(to: target) }
        let observations = collect(retry: 0.3, settle: 0.9)
        XCTAssertEqual(Set(observations.map(\.window.rawValue)), ["five_hour", "seven_day"])
    }

    func testFilesOlderThanRetentionAreRemovedAndFreshOnesKept() throws {
        try place(fixture: "hud-0.11.3.json", as: "old.json")
        try place(fixture: "hud-0.11.3.json", as: "fresh.json")
        let old = inbox.appendingPathComponent("old.json")
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-25 * 3_600)], ofItemAtPath: old.path
        )
        _ = collect(now: { now })
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("fresh.json").path))
    }

    func testFileAddedAfterStartIsPickedUpByWatcher() throws {
        let collector = Collector()
        let source = SnapshotInbox(
            inboxDirectory: inbox,
            identity: FakeIdentity(),
            configuration: SnapshotInboxConfiguration(io: QuotaIOConfiguration(watchCoalescingInterval: 0.05))
        )
        inboxes.append(source)
        source.start { collector.add($0) }
        source.queue.sync {} // watcher is running once the start-up block has finished
        try place(fixture: "hud-0.11.3.json")
        let deadline = Date().addingTimeInterval(5)
        while collector.all.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(collector.all.count, 2)
    }

    // MARK: Review fixes

    func testFileInNotYetExistingDirectoryIsObservedAfterCreation() throws {
        let target = root.appendingPathComponent("producer/state.json")
        let collector = Collector()
        let source = SnapshotInbox(
            inboxDirectory: inbox,
            adapters: [SchemaV1InboxAdapter(directory: target, sourceID: "late")],
            identity: FakeIdentity(),
            configuration: SnapshotInboxConfiguration(io: QuotaIOConfiguration(watchCoalescingInterval: 0.05))
        )
        inboxes.append(source)
        source.start { collector.add($0) }
        source.queue.sync {}
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixtureData("hud-0.11.3.json").write(to: target)
        let deadline = Date().addingTimeInterval(5)
        while collector.all.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(Set(collector.all.map(\.window.rawValue)), ["five_hour", "seven_day"])
    }

    func testDirectoryCatchUpEventExpandsToFiles() throws {
        try place(fixture: "hud-0.11.3.json", as: "a.json")
        let source = SnapshotInbox(inboxDirectory: inbox, identity: FakeIdentity())
        let expanded = source.queue.sync { source.expand(paths: [inbox.path]) }
        XCTAssertEqual(expanded, [inbox.appendingPathComponent("a.json").path])
    }

    func testAncestorCatchUpEventFindsNestedDiscoveredFile() throws {
        let target = root.appendingPathComponent("producer/state.json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixtureData("hud-0.11.3.json").write(to: target)
        let source = SnapshotInbox(
            inboxDirectory: inbox,
            adapters: [SchemaV1InboxAdapter(directory: target, sourceID: "nested")],
            identity: FakeIdentity()
        )
        let expanded = source.queue.sync { source.expand(paths: [root.path]) }
        XCTAssertTrue(expanded.contains(target.path))
    }

    func testSymlinkedInboxIsNotCleaned() throws {
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let foreign = shared.appendingPathComponent("foreign.txt")
        try Data("keep".utf8).write(to: foreign)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-48 * 3_600)], ofItemAtPath: foreign.path
        )
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        inbox = link
        _ = collect(now: { now })
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testStopFromObservationHandlerDoesNotDeadlock() throws {
        try place(fixture: "hud-0.11.3.json")
        let stopped = expectation(description: "stopped in handler")
        stopped.assertForOverFulfill = false
        let source = SnapshotInbox(inboxDirectory: inbox, identity: FakeIdentity())
        inboxes.append(source)
        source.start { [unowned source] _ in
            source.stop()
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 5)
        source.queue.sync {}
    }

    // MARK: Parser

    func testParserDropsWindowsWithBadResetTimesIndividually() throws {
        let json = """
        {"updated_at":"2026-10-17T06:12:03Z",
         "five_hour":{"used_percentage":10,"resets_at":"2026-10-17T00:00:00Z"},
         "seven_day":{"used_percentage":20,"resets_at":"not-a-date"},
         "windows":[{"kind":"extra","used_percentage":30,"resets_at":"2026-10-17T06:00:00Z"}]}
        """
        let parsed = try QuotaSnapshotParser.parse(Data(json.utf8))
        // five_hour resets_at is 6h before updated_at: earlier than updated_at minus 5h.
        XCTAssertEqual(parsed.windows.map(\.kind.rawValue), ["extra"])
        XCTAssertEqual(parsed.discarded.count, 2)
    }

    func testParserBoundaryResetExactlyOneWindowBeforeUpdatedAtIsKept() throws {
        let json = """
        {"updated_at":"2026-10-17T06:00:00Z",
         "five_hour":{"used_percentage":0,"resets_at":"2026-10-17T01:00:00Z"},
         "seven_day":{"used_percentage":100}}
        """
        let parsed = try QuotaSnapshotParser.parse(Data(json.utf8))
        XCTAssertEqual(parsed.windows.map(\.usedPercentage), [0, 100])
    }

    func testParserRejectsInvalidUpdatedAtAndHalfWrittenBytes() {
        XCTAssertThrowsError(try QuotaSnapshotParser.parse(Data(#"{"five_hour":{"used_percentage":1}}"#.utf8))) {
            XCTAssertEqual($0 as? QuotaSnapshotParseError, .invalidUpdatedAt)
        }
        XCTAssertThrowsError(try QuotaSnapshotParser.parse(Data(#"{"updated_at":"#.utf8))) {
            XCTAssertEqual($0 as? QuotaSnapshotParseError, .malformedJSON)
        }
    }

    // MARK: Rejection observer (Issue #597)

    private final class LockedReasons {
        private let lock = NSLock()
        private var values: [SnapshotRejectionReason] = []
        func append(_ value: SnapshotRejectionReason) { lock.lock(); values.append(value); lock.unlock() }
        var all: [SnapshotRejectionReason] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// FSEvents latency plus the watcher's coalescing interval is not a fixed constant,
    /// so assertions on asynchronously observed files poll up to a generous deadline.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    func testRejectionObserverReportsAccountAttributionRejectionsOnly() throws {
        let reasons = LockedReasons()
        let source = SnapshotInbox(
            inboxDirectory: inbox, identity: FakeIdentity(),
            configuration: SnapshotInboxConfiguration(halfWriteRetryDelay: 0.05))
        source.rejectionObserver = { reasons.append($0) }
        inboxes.append(source)
        source.start { _ in }
        // Foreign hash → attribution mismatch.
        try placeSnapshot(
            source: "balancebar-mod", emailHash: SnapshotInbox.emailHash("someone-else@example.com"), as: "wrong.json")
        // Missing hash on a Mod snapshot → attribution impossible.
        try placeSnapshot(source: "balancebar-mod", emailHash: nil, as: "missing.json")
        // An unrelated source without a hash is not a Mod snapshot and not a rejection.
        try placeSnapshot(source: "unrelated-producer", emailHash: nil, as: "other.json")
        XCTAssertTrue(waitUntil(timeout: 5) { reasons.all.count >= 2 })
        source.stop()
        // Paths are processed in sorted order, so only the set of reasons is deterministic.
        XCTAssertEqual(reasons.all.count, 2)
        XCTAssertEqual(Set(reasons.all), [.accountEmailHashMismatch, .missingAccountEmailHash])
    }

    func testUnverifiedCycleIsReportedByTheRejectionObserver() throws {
        let reasons = LockedReasons()
        let source = SnapshotInbox(
            inboxDirectory: inbox, identity: FakeIdentity(),
            configuration: SnapshotInboxConfiguration(halfWriteRetryDelay: 0.05))
        source.rejectionObserver = { reasons.append($0) }
        source.cycleVerification = { _, _, _, _ in false }
        inboxes.append(source)
        source.start { _ in }
        try placeSnapshot(source: "balancebar-mod", emailHash: SnapshotInbox.emailHash("user@example.com"), as: "cycle.json")
        XCTAssertTrue(waitUntil { !reasons.all.isEmpty })
        source.stop()
        XCTAssertEqual(reasons.all, [.cycleUnverified])
    }

    func testReplaySuppressionDoesNotFireTheRejectionObserver() throws {
        let reasons = LockedReasons()
        let collector = Collector()
        let source = SnapshotInbox(
            inboxDirectory: inbox, identity: FakeIdentity(),
            configuration: SnapshotInboxConfiguration(halfWriteRetryDelay: 0.05))
        source.rejectionObserver = { reasons.append($0) }
        inboxes.append(source)
        source.start { collector.add($0) }
        try placeSnapshot(
            source: "balancebar-mod", emailHash: SnapshotInbox.emailHash("user@example.com"),
            as: "ok.json", percentage: 20)
        XCTAssertTrue(waitUntil { !collector.all.isEmpty }, "the snapshot is emitted")
        // Let FSEvents catch-up rescans of the directory settle before promoting the
        // baseline, so the replay below is measured against adopted evidence only.
        Thread.sleep(forTimeInterval: 1.5)
        source.queue.sync {}
        let adopted = collector.all.map(\.receivedAt)
        for receivedAt in adopted {
            source.noteProcessed(source: "balancebar-mod", accountID: "acct-1", receivedAt: receivedAt, accepted: true)
        }
        source.queue.sync {}
        try placeSnapshot(
            source: "balancebar-mod", emailHash: SnapshotInbox.emailHash("user@example.com"),
            as: "replay.json", percentage: 20)
        XCTAssertTrue(waitUntil { source.queue.sync { source.suppressedReplayCount } >= 1 })
        Thread.sleep(forTimeInterval: 0.5)
        source.stop()
        XCTAssertEqual(reasons.all, [], "a whole-snapshot replay is healthy, not a rejection")
    }

    /// Issue #634 F1/F2: an unchanged percentage must not hide a newer Mod snapshot. Same values
    /// and a strictly later production time are emitted again (the merge engine renews the
    /// reading's time); the same production time (a file re-read) and an older one stay replays.
    func testSameValueNewerModSnapshotIsEmittedWhileReplaysStayDropped() throws {
        let hash = SnapshotInbox.emailHash("user@example.com")
        let collector = Collector()
        let source = SnapshotInbox(
            inboxDirectory: inbox, identity: FakeIdentity(),
            configuration: SnapshotInboxConfiguration(halfWriteRetryDelay: 0.05))
        inboxes.append(source)
        source.start { collector.add($0) }
        func place(_ updatedAt: String) throws {
            try placeSnapshot(source: "balancebar-mod", emailHash: hash, as: "mod.json", percentage: 20,
                              updatedAt: updatedAt)
        }
        func adoptAll() {
            for receivedAt in collector.all.map(\.receivedAt) {
                source.noteProcessed(source: "balancebar-mod", accountID: "acct-1", receivedAt: receivedAt, accepted: true)
            }
            source.queue.sync {}
        }
        func reread() { source.queue.sync { source.process(paths: [inbox.appendingPathComponent("mod.json").path]) } }
        try place("2026-10-17T06:12:03Z")
        XCTAssertTrue(waitUntil { !collector.all.isEmpty })
        Thread.sleep(forTimeInterval: 1.5) // let directory catch-up rescans settle
        source.queue.sync {}
        adoptAll()
        let base = collector.all.count // the initial scan and the watcher may both have delivered

        reread() // same file, same production time
        try place("2026-10-17T06:11:00Z")
        reread() // older production time, same values
        XCTAssertEqual(collector.all.count, base, "replays are not emitted")

        try place("2026-10-17T06:13:00Z")
        reread()
        XCTAssertEqual(collector.all.count, base + 1, "same values, later production time")
        XCTAssertEqual(collector.all.last?.observedAt, ISO8601DateFormatter().date(from: "2026-10-17T06:13:00Z"))
        adoptAll()
        reread() // the renewed production time is now the replay baseline
        XCTAssertEqual(collector.all.count, base + 1)
        source.stop()
    }

    func testNonModSameValueNewerSnapshotIsStillADroppedReplay() throws {
        let collector = Collector()
        let source = SnapshotInbox(
            inboxDirectory: inbox, identity: FakeIdentity(),
            configuration: SnapshotInboxConfiguration(halfWriteRetryDelay: 0.05))
        inboxes.append(source)
        source.start { collector.add($0) }
        try placeSnapshot(source: "some-other-tool", emailHash: nil, as: "o.json", percentage: 20)
        XCTAssertTrue(waitUntil { !collector.all.isEmpty })
        Thread.sleep(forTimeInterval: 1.5)
        source.queue.sync {}
        for receivedAt in collector.all.map(\.receivedAt) {
            source.noteProcessed(source: "some-other-tool", accountID: "acct-1", receivedAt: receivedAt, accepted: true)
        }
        source.queue.sync {}
        let base = collector.all.count // the initial scan and the watcher may both have delivered
        try placeSnapshot(source: "some-other-tool", emailHash: nil, as: "o.json", percentage: 20,
                          updatedAt: "2026-10-17T06:13:00Z")
        source.queue.sync { source.process(paths: [inbox.appendingPathComponent("o.json").path]) }
        XCTAssertEqual(collector.all.count, base)
        source.stop()
    }

    func testNonModRejectionsAreNotReportedAsModFailures() throws {
        let reasons = LockedReasons()
        let source = SnapshotInbox(
            inboxDirectory: inbox, identity: FakeIdentity(),
            configuration: SnapshotInboxConfiguration(halfWriteRetryDelay: 0.05))
        source.rejectionObserver = { reasons.append($0) }
        source.cycleVerification = { _, _, _, _ in false }
        inboxes.append(source)
        source.start { _ in }
        // Wrong hash on a non-Mod producer: rejected, but not a Mod failure.
        try placeSnapshot(source: "some-other-tool", emailHash: "sha256:deadbeef", as: "wrong.json")
        // Cycle mismatch on a non-Mod producer: rejected, but not a Mod failure.
        try placeSnapshot(source: "some-other-tool", emailHash: SnapshotInbox.emailHash("user@example.com"), as: "cycle.json")
        Thread.sleep(forTimeInterval: 0.5)
        source.stop()
        XCTAssertEqual(reasons.all, [], "non-Mod rejections must not change the Mod status entry")
    }
}
