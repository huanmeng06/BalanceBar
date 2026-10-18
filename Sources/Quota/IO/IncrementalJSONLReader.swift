import Darwin
import Foundation

/// Outcome of one incremental read of a JSONL file.
public struct JSONLReadResult: Equatable {
    /// Complete, non-empty, not previously seen lines (without the trailing newline).
    public var lines: [Data]

    /// `true` when truncation or rotation made the reader restart from offset 0.
    public var didReset: Bool

    /// `true` when unread complete data remains because a per-read limit was hit.
    public var hasMore: Bool
}

/// Reads only newly appended complete lines from JSONL files.
///
/// Per file it remembers the byte offset after the last complete line and the
/// file identity (device + inode). A trailing partial line is left unread until
/// its newline arrives. A shrinking file is treated as truncation and a changed
/// identity as rotation; both restart at offset 0. Lines longer than
/// `maximumBytesPerRead` are skipped. Format parsing is the caller's job.
///
/// Methods perform blocking IO and are serialized on an internal background
/// queue; `read(_:)` must not be called from the main thread.
public final class IncrementalJSONLReader {
    public typealias DeduplicationKey = (Data) -> String?

    private struct FileState {
        var device: dev_t
        var inode: ino_t
        var offset: UInt64
        var skippingOversizedLine = false
        var seenKeys: Set<String> = []
        var keyOrder: [String] = []
    }

    private let configuration: QuotaIOConfiguration
    private let validator: SafeFileValidator?
    private let deduplicationKey: DeduplicationKey?
    private let queue = DispatchQueue(label: "BalanceBar.IncrementalJSONLReader", qos: .utility)
    private var states: [String: FileState] = [:]

    public init(
        configuration: QuotaIOConfiguration = .default,
        validator: SafeFileValidator? = nil,
        deduplicationKey: DeduplicationKey? = nil
    ) {
        self.configuration = configuration
        self.validator = validator
        self.deduplicationKey = deduplicationKey
    }

    /// Reads the next batch synchronously on the internal queue.
    public func read(_ url: URL) throws -> JSONLReadResult {
        return try queue.sync { try readLocked(url) }
    }

    /// Reads the next batch on the internal background queue.
    public func read(_ url: URL, completion: @escaping (Result<JSONLReadResult, Error>) -> Void) {
        queue.async { [self] in
            completion(Result { try readLocked(url) })
        }
    }

    /// Forgets the stored offset for one file.
    public func reset(_ url: URL) {
        queue.sync { _ = states.removeValue(forKey: key(for: url)) }
    }

    private func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func readLocked(_ url: URL) throws -> JSONLReadResult {
        let path = try validator?.validateFile(at: url) ?? url
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw SafeFileValidationError.unreadable(errno: errno)
        }
        let size = UInt64(info.st_size)
        let stateKey = key(for: url)

        var didReset = false
        var state: FileState
        if let previous = states[stateKey], previous.device == info.st_dev, previous.inode == info.st_ino,
           previous.offset <= size {
            state = previous
        } else {
            didReset = states[stateKey] != nil
            state = FileState(device: info.st_dev, inode: info.st_ino, offset: 0)
        }

        var lines: [Data] = []
        while state.offset < size, lines.count < configuration.maximumLinesPerRead {
            let length = Int(min(UInt64(configuration.maximumBytesPerRead), size - state.offset))
            try handle.seek(toOffset: state.offset)
            guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else { break }

            guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
                if chunk.count >= configuration.maximumBytesPerRead {
                    // A single line exceeds the batch limit: drop it until its newline.
                    state.offset += UInt64(chunk.count)
                    state.skippingOversizedLine = true
                    continue
                }
                break // Partial trailing line; wait for the rest.
            }

            var consumed = chunk.startIndex
            var lineStart = chunk.startIndex
            for index in chunk[...lastNewline].indices where chunk[index] == 0x0A {
                defer { lineStart = index + 1; consumed = index + 1 }
                if state.skippingOversizedLine {
                    state.skippingOversizedLine = false
                    continue
                }
                var line = chunk[lineStart..<index]
                if line.last == 0x0D { line = line.dropLast() }
                if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
                let data = Data(line)
                if let dedupeKey = deduplicationKey?(data) {
                    if state.seenKeys.contains(dedupeKey) { continue }
                    remember(dedupeKey, in: &state)
                }
                lines.append(data)
                if lines.count >= configuration.maximumLinesPerRead { break }
            }
            state.offset += UInt64(consumed - chunk.startIndex)
        }

        states[stateKey] = state
        return JSONLReadResult(lines: lines, didReset: didReset, hasMore: hasCompleteData(after: state, size: size, handle: handle))
    }

    private func remember(_ key: String, in state: inout FileState) {
        state.seenKeys.insert(key)
        state.keyOrder.append(key)
        let overflow = state.keyOrder.count - configuration.maximumDeduplicationKeys
        if overflow > 0 {
            for evicted in state.keyOrder.prefix(overflow) { state.seenKeys.remove(evicted) }
            state.keyOrder.removeFirst(overflow)
        }
    }

    private func hasCompleteData(after state: FileState, size: UInt64, handle: FileHandle) -> Bool {
        guard state.offset < size else { return false }
        let probeLength = Int(min(UInt64(configuration.maximumBytesPerRead), size - state.offset))
        guard (try? handle.seek(toOffset: state.offset)) != nil,
              let probe = try? handle.read(upToCount: probeLength) else { return false }
        return probe.contains(0x0A) || probe.count >= configuration.maximumBytesPerRead
    }
}
