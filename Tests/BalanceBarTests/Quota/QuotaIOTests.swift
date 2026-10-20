import XCTest
@testable import BalanceBar

final class QuotaIOTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaIOTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func strings(_ result: JSONLReadResult) -> [String] {
        result.lines.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: IncrementalJSONLReader

    func testPartialLineIsReturnedOnceAfterCompletion() throws {
        let url = try write("{\"a\":1}\n{\"b\":", to: "log.jsonl")
        let reader = IncrementalJSONLReader()
        XCTAssertEqual(strings(try reader.read(url)), ["{\"a\":1}"])
        XCTAssertEqual(strings(try reader.read(url)), [])
        try append("2}\n", to: url)
        XCTAssertEqual(strings(try reader.read(url)), ["{\"b\":2}"])
        XCTAssertEqual(strings(try reader.read(url)), [])
    }

    func testFirstReadTailSkipsToTheEndOfALargeFileAndFollowsAppendsAfterwards() throws {
        let lines = (0..<100).map { "line-\(String(format: "%03d", $0))" }
        let url = try write(lines.joined(separator: "\n") + "\n", to: "big.jsonl")   // 100 lines x 9 bytes = 900 bytes
        let reader = IncrementalJSONLReader()
        // 25 bytes before the end lands inside line-097, which is dropped as a partial line.
        let tail = strings(try reader.read(url, firstReadTailBytes: 25))
        XCTAssertEqual(tail, ["line-098", "line-099"])
        XCTAssertEqual(reader.lastReadByteCount, 25)
        XCTAssertEqual(strings(try reader.read(url, firstReadTailBytes: 25)), [], "an already followed file ignores the tail option")
        try append("line-100\n", to: url)
        XCTAssertEqual(strings(try reader.read(url, firstReadTailBytes: 25)), ["line-100"])
    }

    func testFirstReadTailIsIgnoredForSmallFilesAndAfterRotation() throws {
        let url = try write("a\nb\nc\n", to: "small.jsonl")
        let reader = IncrementalJSONLReader()
        XCTAssertEqual(strings(try reader.read(url, firstReadTailBytes: 1_000)), ["a", "b", "c"], "a file smaller than the tail is read whole")

        let big = try write((0..<50).map { "row-\(String(format: "%02d", $0))" }.joined(separator: "\n") + "\n", to: "rot.jsonl")
        XCTAssertEqual(strings(try reader.read(big, firstReadTailBytes: 12)).count, 1)
        try FileManager.default.moveItem(at: big, to: root.appendingPathComponent("rot.jsonl.1"))
        _ = try write((0..<60).map { "new-\(String(format: "%02d", $0))" }.joined(separator: "\n") + "\n", to: "rot.jsonl")
        let rotated = try reader.read(big, firstReadTailBytes: 12)
        XCTAssertTrue(rotated.didReset)
        XCTAssertEqual(rotated.lines.count, 60, "after rotation the new file is read from its start")
    }

    func testTruncationRestartsFromBeginning() throws {
        let url = try write("one\ntwo\nthree\n", to: "log.jsonl")
        let reader = IncrementalJSONLReader()
        XCTAssertEqual(try reader.read(url).lines.count, 3)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("x\n".utf8))
        try handle.close()
        let result = try reader.read(url)
        XCTAssertTrue(result.didReset)
        XCTAssertEqual(strings(result), ["x"])
    }

    func testRotationRestartsFromBeginning() throws {
        let url = try write("old1\nold2\nold3\nold4\n", to: "log.jsonl")
        let reader = IncrementalJSONLReader()
        XCTAssertEqual(try reader.read(url).lines.count, 4)
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("log.jsonl.1"))
        // New file is longer than the old offset, so only the inode reveals rotation.
        _ = try write("new1\nnew2\nnew3\nnew4\nnew5\nnew6\n", to: "log.jsonl")
        let result = try reader.read(url)
        XCTAssertTrue(result.didReset)
        XCTAssertEqual(strings(result).first, "new1")
        XCTAssertEqual(result.lines.count, 6)
    }

    func testDeduplicationAndBlankLines() throws {
        let url = try write("k1\n\n  \nk2\r\nk1\n", to: "log.jsonl")
        let reader = IncrementalJSONLReader(deduplicationKey: { String(decoding: $0, as: UTF8.self) })
        XCTAssertEqual(strings(try reader.read(url)), ["k1", "k2"])
        try append("k2\nk3\n", to: url)
        XCTAssertEqual(strings(try reader.read(url)), ["k3"])
    }

    func testBatchLimitsReportHasMore() throws {
        let url = try write((1...25).map { "line\($0)\n" }.joined(), to: "log.jsonl")
        let reader = IncrementalJSONLReader(configuration: QuotaIOConfiguration(maximumLinesPerRead: 10))
        var all: [String] = []
        var result = try reader.read(url)
        all += strings(result)
        XCTAssertTrue(result.hasMore)
        while result.hasMore {
            result = try reader.read(url)
            all += strings(result)
        }
        XCTAssertEqual(all, (1...25).map { "line\($0)" })
    }

    func testOversizedLineIsSkipped() throws {
        let long = String(repeating: "x", count: 100)
        let url = try write("a\n\(long)\nb\n", to: "log.jsonl")
        let reader = IncrementalJSONLReader(configuration: QuotaIOConfiguration(maximumBytesPerRead: 16))
        var all: [String] = []
        var result: JSONLReadResult
        repeat {
            result = try reader.read(url)
            all += strings(result)
        } while result.hasMore
        XCTAssertEqual(all, ["a", "b"])
    }

    func testReaderRejectsSymlinkEscapingAllowedDirectory() throws {
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let outside = try write("secret\n", to: "outside.jsonl")
        let link = allowed.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let reader = IncrementalJSONLReader(
            validator: SafeFileValidator(allowedDirectories: [allowed], maximumFileSize: nil)
        )
        XCTAssertThrowsError(try reader.read(link)) {
            XCTAssertEqual($0 as? SafeFileValidationError, .outsideAllowedDirectories)
        }
    }

    func testSingleReadNeverExceedsByteBudget() throws {
        let duplicates = String(repeating: "dup\n", count: 1_000)
        let oversized = String(repeating: "z", count: 10_000)
        let url = try write(duplicates + oversized + "\nend\n", to: "log.jsonl")
        let budget = 64
        let reader = IncrementalJSONLReader(
            configuration: QuotaIOConfiguration(maximumBytesPerRead: budget),
            deduplicationKey: { String(decoding: $0, as: UTF8.self) }
        )
        var all: [String] = []
        var calls = 0
        var result: JSONLReadResult
        repeat {
            result = try reader.read(url)
            calls += 1
            XCTAssertLessThanOrEqual(reader.lastReadByteCount, budget)
            all += strings(result)
        } while result.hasMore && calls < 10_000
        XCTAssertEqual(all, ["dup", "end"])
        XCTAssertFalse(result.hasMore)
    }

    func testPartialTailAtEndReportsNoMore() throws {
        let url = try write("a\nb\npartial", to: "log.jsonl")
        let result = try IncrementalJSONLReader().read(url)
        XCTAssertEqual(strings(result), ["a", "b"])
        XCTAssertFalse(result.hasMore)
    }

    func testEvictedDeduplicationKeyIsAcceptedAgain() throws {
        let url = try write("a\nb\nc\na\nc\n", to: "log.jsonl")
        let reader = IncrementalJSONLReader(
            configuration: QuotaIOConfiguration(maximumDeduplicationKeys: 2),
            deduplicationKey: { String(decoding: $0, as: UTF8.self) }
        )
        XCTAssertEqual(strings(try reader.read(url)), ["a", "b", "c", "a"])
    }

    func testDeduplicationBeyondCapacityStaysLinear() throws {
        let url = root.appendingPathComponent("unique.jsonl")
        var text = ""
        for index in 0..<150_000 { text += "{\"id\":\"\(UUID().uuidString)-\(index)\"}\n" }
        try Data(text.utf8).write(to: url)
        let reader = IncrementalJSONLReader(
            configuration: QuotaIOConfiguration(maximumDeduplicationKeys: 50_000),
            deduplicationKey: { String(decoding: $0, as: UTF8.self) }
        )
        let start = Date()
        var count = 0
        var result: JSONLReadResult
        repeat {
            result = try reader.read(url)
            count += result.lines.count
        } while result.hasMore
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(count, 150_000)
        XCTAssertLessThan(elapsed, 10, "dedup eviction should be amortized O(1)")
        print("QuotaIOBenchmark dedup: 150000 unique keys (cap 50000) in \(String(format: "%.3f", elapsed)) s")
    }

    func testReaderRejectsGroupWritableFileThroughValidator() throws {
        let url = try write("x\n", to: "shared.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        let reader = IncrementalJSONLReader(
            validator: SafeFileValidator(allowedDirectories: [root], maximumFileSize: nil)
        )
        XCTAssertThrowsError(try reader.read(url)) {
            XCTAssertEqual($0 as? SafeFileValidationError, .writableByOthers)
        }
    }

    func testDefaultConfigurationComesFromQuotaConstants() {
        let configuration = QuotaIOConfiguration.default
        XCTAssertEqual(configuration.watchCoalescingInterval, QuotaConstants.directoryWatchCoalescingInterval)
        XCTAssertEqual(configuration.maximumBytesPerRead, QuotaConstants.incrementalReadMaximumBytes)
        XCTAssertEqual(configuration.maximumLinesPerRead, QuotaConstants.incrementalReadMaximumLines)
        XCTAssertEqual(
            configuration.maximumDeduplicationKeys,
            QuotaConstants.incrementalReadMaximumDeduplicationKeys
        )
        XCTAssertEqual(QuotaConstants.directoryWatchCoalescingInterval, 1)
        XCTAssertEqual(QuotaConstants.incrementalReadMaximumBytes, 4 * 1_024 * 1_024)
        XCTAssertEqual(QuotaConstants.incrementalReadMaximumLines, 10_000)
        XCTAssertEqual(QuotaConstants.incrementalReadMaximumDeduplicationKeys, 50_000)
    }

    // MARK: SafeFileValidator

    func testValidatorAcceptsSymlinkInsideAllowedDirectory() throws {
        let target = try write("{}", to: "snapshot.json")
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let validator = SafeFileValidator(allowedDirectories: [root])
        XCTAssertEqual(try validator.readValidatedFile(at: link), Data("{}".utf8))
    }

    func testValidatorRejectsPrefixSiblingDirectory() throws {
        let allowed = root.appendingPathComponent("dir", isDirectory: true)
        let sibling = root.appendingPathComponent("dir-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let file = sibling.appendingPathComponent("a.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try SafeFileValidator(allowedDirectories: [allowed]).validateFile(at: file)) {
            XCTAssertEqual($0 as? SafeFileValidationError, .outsideAllowedDirectories)
        }
    }

    func testValidatorRejectsLargeFile() throws {
        let url = try write(String(repeating: "a", count: 33), to: "big.json")
        let validator = SafeFileValidator(allowedDirectories: [root], maximumFileSize: 32)
        XCTAssertThrowsError(try validator.validateFile(at: url)) {
            XCTAssertEqual($0 as? SafeFileValidationError, .tooLarge(size: 33, limit: 32))
        }
        XCTAssertThrowsError(try validator.validate(Data(count: 33)))
        XCTAssertNoThrow(try validator.validate(Data(count: 32)))
    }

    func testValidatorRejectsGroupOrOtherWritableFile() throws {
        let url = try write("{}", to: "shared.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        XCTAssertThrowsError(try SafeFileValidator(allowedDirectories: [root]).validateFile(at: url)) {
            XCTAssertEqual($0 as? SafeFileValidationError, .writableByOthers)
        }
    }

    func testValidatorRejectsForeignOwnerAndDirectory() throws {
        let url = try write("{}", to: "a.json")
        XCTAssertThrowsError(
            try SafeFileValidator(allowedDirectories: [root], ownerUID: getuid() + 1).validateFile(at: url)
        ) {
            XCTAssertEqual($0 as? SafeFileValidationError, .wrongOwner(uid: getuid()))
        }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SafeFileValidator(allowedDirectories: [root]).validateFile(at: sub))
    }

    // MARK: DirectoryWatcher

    func testWatcherKeepsReportingAfterAtomicRename() throws {
        let target = try write("v0", to: "snapshot.json")
        let lock = NSLock()
        var batches: [Set<String>] = []
        let watcher = DirectoryWatcher(
            directory: root,
            configuration: QuotaIOConfiguration(watchCoalescingInterval: 0.2),
            notificationCenter: NotificationCenter()
        ) { paths in
            lock.lock(); batches.append(paths); lock.unlock()
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)

        for version in 1...3 {
            let before = lock.withLock { batches.count }
            let temp = root.appendingPathComponent(".tmp-\(version)")
            try Data("v\(version)".utf8).write(to: temp)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            let deadline = Date().addingTimeInterval(5)
            while lock.withLock({ batches.count }) == before, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let latest = lock.withLock { batches.last ?? [] }
            XCTAssertGreaterThan(lock.withLock { batches.count }, before, "no event for replacement \(version)")
            XCTAssertTrue(latest.contains { $0.hasSuffix("snapshot.json") }, "\(latest)")
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    func testWatcherCoalescesBurstsAndCatchesUpAfterWake() throws {
        let center = NotificationCenter()
        let lock = NSLock()
        var batches: [Set<String>] = []
        let watcher = DirectoryWatcher(
            directory: root,
            configuration: QuotaIOConfiguration(watchCoalescingInterval: 0.5),
            notificationCenter: center
        ) { paths in
            lock.lock(); batches.append(paths); lock.unlock()
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)

        for index in 0..<10 { _ = try write("x", to: "f\(index).json") }
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(lock.withLock { batches.count }, 1)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        Thread.sleep(forTimeInterval: 0.9)
        XCTAssertEqual(lock.withLock { batches.count }, 2)
        XCTAssertEqual(lock.withLock { batches.last }, [root.path])

        watcher.stop()
        _ = try write("y", to: "after-stop.json")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(lock.withLock { batches.count }, 2)
    }

    // MARK: Benchmark

    func testIncrementalParseOf100kLinesBenchmark() throws {
        let line = "{\"type\":\"usage\",\"input_tokens\":12345,\"output_tokens\":678,\"id\":\"%d\"}\n"
        let url = root.appendingPathComponent("bench.jsonl")
        var text = ""
        text.reserveCapacity(100_000 * 80)
        for index in 0..<50_000 { text += line.replacingOccurrences(of: "%d", with: "\(index)") }
        try Data(text.utf8).write(to: url)
        let reader = IncrementalJSONLReader(deduplicationKey: { String(decoding: $0, as: UTF8.self) })
        var initial = 0
        var first: JSONLReadResult
        repeat {
            first = try reader.read(url)
            initial += first.lines.count
        } while first.hasMore
        XCTAssertEqual(initial, 50_000)

        var appended = ""
        for index in 50_000..<150_000 { appended += line.replacingOccurrences(of: "%d", with: "\(index)") }
        try append(appended, to: url)

        let footprintBefore = Self.physicalFootprint()
        var peakFootprint = footprintBefore
        let start = Date()
        var count = 0
        var result: JSONLReadResult
        repeat {
            result = try reader.read(url)
            count += result.lines.count
            peakFootprint = max(peakFootprint, Self.physicalFootprint())
        } while result.hasMore
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(count, 100_000)
        print("QuotaIOBenchmark: 100000 incremental lines in \(String(format: "%.3f", elapsed)) s, "
            + "peak footprint delta \((peakFootprint - footprintBefore) / 1_048_576) MiB")
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
