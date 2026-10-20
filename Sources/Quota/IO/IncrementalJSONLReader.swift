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
/// `maximumBytesPerRead` are skipped. Each call reads at most
/// `maximumBytesPerRead` bytes, regardless of duplicates or skipped lines.
/// A caller that only needs a file's newest content can pass `firstReadTailBytes`: a file seen for the first
/// time then starts that many bytes before its end (at the next line boundary) instead of at offset 0.
/// Format parsing is the caller's job.
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
        var keyHead = 0
    }

    private let configuration: QuotaIOConfiguration
    private let validator: SafeFileValidator?
    private let deduplicationKey: DeduplicationKey?
    private let queue = DispatchQueue(label: "BalanceBar.IncrementalJSONLReader", qos: .utility)
    private var states: [String: FileState] = [:]

    /// Bytes read from disk by the most recent call; exposed for tests.
    private(set) var lastReadByteCount = 0

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
    /// - Parameter firstReadTailBytes: For a file not read before, skip everything but roughly this many
    ///   trailing bytes (the partial line at the cut is dropped). Ignored for files already being followed.
    public func read(_ url: URL, firstReadTailBytes: Int? = nil) throws -> JSONLReadResult {
        return try queue.sync { try readLocked(url, firstReadTailBytes: firstReadTailBytes) }
    }

    /// Reads the next batch on the internal background queue.
    public func read(_ url: URL, completion: @escaping (Result<JSONLReadResult, Error>) -> Void) {
        queue.async { [self] in
            completion(Result { try readLocked(url, firstReadTailBytes: nil) })
        }
    }

    /// Forgets the stored offset for one file.
    public func reset(_ url: URL) {
        queue.sync { _ = states.removeValue(forKey: key(for: url)) }
    }

    private func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func readLocked(_ url: URL, firstReadTailBytes: Int?) throws -> JSONLReadResult {
        let handle: FileHandle
        var info = stat()
        if let validator {
            (handle, info) = try validator.openValidatedFile(at: url)
        } else {
            handle = try FileHandle(forReadingFrom: url)
            guard fstat(handle.fileDescriptor, &info) == 0 else {
                try? handle.close()
                throw SafeFileValidationError.unreadable(errno: errno)
            }
        }
        defer { try? handle.close() }

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
            if !didReset, let tail = firstReadTailBytes, tail > 0, size > UInt64(tail) {
                // The cut usually lands inside a line: drop it up to the next newline.
                state.offset = size - UInt64(tail)
                state.skippingOversizedLine = true
            }
        }

        var lines: [Data] = []
        var stoppedAtPartialTail = false
        lastReadByteCount = 0
        if state.offset < size {
            // Exactly one bounded read per call enforces the per-call byte budget.
            let length = Int(min(UInt64(configuration.maximumBytesPerRead), size - state.offset))
            try handle.seek(toOffset: state.offset)
            let chunk = try handle.read(upToCount: length) ?? Data()
            lastReadByteCount = chunk.count
            let readToEOF = state.offset + UInt64(chunk.count) == size

            if let lastNewline = chunk.lastIndex(of: 0x0A) {
                var consumed = chunk.startIndex
                var lineStart = chunk.startIndex
                for index in chunk[...lastNewline].indices where chunk[index] == 0x0A {
                    if lines.count >= configuration.maximumLinesPerRead { break }
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
                }
                state.offset += UInt64(consumed - chunk.startIndex)
                // Reached EOF with only an unterminated tail left after the last newline.
                stoppedAtPartialTail = readToEOF && consumed == lastNewline + 1 && state.offset < size
            } else if !chunk.isEmpty, chunk.count >= configuration.maximumBytesPerRead {
                // A single line exceeds the batch limit: drop it until its newline.
                state.offset += UInt64(chunk.count)
                state.skippingOversizedLine = true
            } else {
                stoppedAtPartialTail = true // Partial trailing line; wait for the rest.
            }
        }

        states[stateKey] = state
        return JSONLReadResult(
            lines: lines,
            didReset: didReset,
            hasMore: state.offset < size && !stoppedAtPartialTail
        )
    }

    private func remember(_ key: String, in state: inout FileState) {
        state.seenKeys.insert(key)
        state.keyOrder.append(key)
        // Evict by advancing a head index; compact occasionally so eviction is O(1) amortized.
        while state.keyOrder.count - state.keyHead > configuration.maximumDeduplicationKeys {
            state.seenKeys.remove(state.keyOrder[state.keyHead])
            state.keyHead += 1
        }
        if state.keyHead > state.keyOrder.count / 2 {
            state.keyOrder.removeFirst(state.keyHead)
            state.keyHead = 0
        }
    }
}
