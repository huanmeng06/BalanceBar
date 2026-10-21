import Foundation

/// Health reported by a source adapter for diagnostics and status indicators.
public enum QuotaAdapterHealth: Equatable {
    /// The adapter's latest input was read and converted successfully.
    case healthy

    /// Input exists but could not be read, converted, or fully validated.
    case degraded(reason: String)

    /// No input location exists yet or the adapter cannot run.
    case unavailable(reason: String)
}

/// Converts one concrete producer's files into Schema v1 snapshots for the inbox.
///
/// Adapters never touch the file system for reading; `SnapshotInbox` validates and
/// reads every file through `SafeFileValidator` and hands the bytes to `convert`.
public protocol QuotaSourceAdapter: AnyObject {
    /// Stable diagnostic identifier, used as the observation source for sources that omit one.
    var sourceID: String { get }

    /// Trust grade this adapter declares for every observation it produces.
    var trust: QuotaTrust { get }

    /// Files or directories the adapter wants watched. Directories are scanned for regular files.
    func discoverPaths() -> [URL]

    /// Converts raw file bytes to Schema v1 JSON bytes; throws when the bytes are unusable.
    func convert(_ data: Data) throws -> Data

    /// Latest health, updated by the adapter or by the inbox after each processed file.
    var health: QuotaAdapterHealth { get set }
}

/// The default adapter for files that already use Schema v1 (the BalanceBar Mod).
public final class SchemaV1InboxAdapter: QuotaSourceAdapter {
    public let sourceID: String
    public let trust: QuotaTrust
    public var health: QuotaAdapterHealth = .unavailable(reason: "not started")
    private let directory: URL

    public init(directory: URL, sourceID: String = "inbox", trust: QuotaTrust = .b) {
        self.directory = directory
        self.sourceID = sourceID
        self.trust = trust
    }

    public func discoverPaths() -> [URL] { [directory] }

    public func convert(_ data: Data) throws -> Data { data }
}
