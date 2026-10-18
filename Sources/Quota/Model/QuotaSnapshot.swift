import Foundation

/// Validation failures raised while reading or writing Schema v1 snapshots.
public enum QuotaSnapshotError: Error, Equatable, LocalizedError {
    /// The serialized snapshot exceeded the contract size limit.
    case snapshotTooLarge(actualBytes: Int, maximumBytes: Int)

    /// A percentage was outside the inclusive 0...100 range.
    case invalidPercentage(field: String, value: Double)

    /// A date string could not be parsed as an ISO-8601 timestamp.
    case invalidDate(field: String, value: String)

    /// A required string field was empty after trimming whitespace.
    case emptyField(String)

    public var errorDescription: String? {
        switch self {
        case let .snapshotTooLarge(actualBytes, maximumBytes):
            return "Snapshot is \(actualBytes) bytes; maximum is \(maximumBytes) bytes"
        case let .invalidPercentage(field, value):
            return "Invalid percentage \(value) in \(field)"
        case let .invalidDate(field, value):
            return "Invalid ISO-8601 date in \(field): \(value)"
        case let .emptyField(field):
            return "Required field is empty: \(field)"
        }
    }
}

/// A required rolling-window value in the Schema v1 payload.
public struct QuotaSnapshotWindow: Codable, Equatable {
    /// Percentage already used, constrained to 0...100.
    public let usedPercentage: Double

    /// Absolute reset time supplied by the source, when available.
    public let resetsAt: Date?

    /// Creates a validated snapshot window.
    public init?(usedPercentage: Double, resetsAt: Date? = nil) {
        guard usedPercentage.isFinite, (0...100).contains(usedPercentage),
              resetsAt?.timeIntervalSince1970.isFinite ?? true else {
            return nil
        }
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let percentage = try container.decode(Double.self, forKey: .usedPercentage)
        guard percentage.isFinite, (0...100).contains(percentage) else {
            throw QuotaSnapshotError.invalidPercentage(field: "used_percentage", value: percentage)
        }

        let resetString = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        let resetDate: Date?
        if let resetString {
            guard let parsed = QuotaSnapshotDateCoding.date(from: resetString) else {
                throw QuotaSnapshotError.invalidDate(field: "resets_at", value: resetString)
            }
            resetDate = parsed
        } else {
            resetDate = nil
        }

        self.usedPercentage = percentage
        self.resetsAt = resetDate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usedPercentage, forKey: .usedPercentage)
        try container.encodeIfPresent(resetsAt.map(QuotaSnapshotDateCoding.string(from:)), forKey: .resetsAt)
    }
}

/// Optional account metadata carried by the Mod and other extended sources.
public struct QuotaSnapshotAccount: Codable, Equatable {
    /// A one-way account email hash, never a plaintext email.
    public let emailHash: String?

    /// Creates optional account metadata.
    public init(emailHash: String? = nil) {
        self.emailHash = emailHash
    }

    private enum CodingKeys: String, CodingKey {
        case emailHash = "email_hash"
    }
}

/// One optional extension window in the Schema v1 `windows` array.
public struct QuotaSnapshotWindowEntry: Codable, Equatable {
    /// Window category supplied by the source.
    public let kind: QuotaWindowKind

    /// Percentage already used, constrained to 0...100.
    public let usedPercentage: Double

    /// Absolute reset time supplied by the source, when available.
    public let resetsAt: Date?

    /// Creates a validated extension window.
    public init?(
        kind: QuotaWindowKind,
        usedPercentage: Double,
        resetsAt: Date? = nil
    ) {
        guard usedPercentage.isFinite, (0...100).contains(usedPercentage),
              resetsAt?.timeIntervalSince1970.isFinite ?? true else {
            return nil
        }
        self.kind = kind
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = QuotaWindowKind(rawValue: try container.decode(String.self, forKey: .kind))
        let percentage = try container.decode(Double.self, forKey: .usedPercentage)
        guard percentage.isFinite, (0...100).contains(percentage) else {
            throw QuotaSnapshotError.invalidPercentage(field: "windows[].used_percentage", value: percentage)
        }

        let resetString = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        let resetDate: Date?
        if let resetString {
            guard let parsed = QuotaSnapshotDateCoding.date(from: resetString) else {
                throw QuotaSnapshotError.invalidDate(field: "windows[].resets_at", value: resetString)
            }
            resetDate = parsed
        } else {
            resetDate = nil
        }

        self.kind = kind
        self.usedPercentage = percentage
        self.resetsAt = resetDate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(usedPercentage, forKey: .usedPercentage)
        try container.encodeIfPresent(resetsAt.map(QuotaSnapshotDateCoding.string(from:)), forKey: .resetsAt)
    }
}

/// BalanceBar's unified quota snapshot contract, version 1.
public struct QuotaSnapshot: Codable, Equatable {
    /// The schema version represented by this type.
    public static let schemaVersion = 1

    /// Timestamp at which the source produced the snapshot.
    public let updatedAt: Date

    /// Required five-hour window matching the Claude HUD field name.
    public let fiveHour: QuotaSnapshotWindow

    /// Required seven-day window matching the Claude HUD field name.
    public let sevenDay: QuotaSnapshotWindow

    /// Source identifier; `unknown` is used when the extension is absent.
    public let source: String

    /// Optional extension account metadata.
    public let account: QuotaSnapshotAccount?

    /// Optional extension windows; an absent field decodes as an empty array.
    public let windows: [QuotaSnapshotWindowEntry]

    /// Creates a validated Schema v1 snapshot.
    public init(
        updatedAt: Date,
        fiveHour: QuotaSnapshotWindow,
        sevenDay: QuotaSnapshotWindow,
        source: String = "unknown",
        account: QuotaSnapshotAccount? = nil,
        windows: [QuotaSnapshotWindowEntry] = []
    ) throws {
        guard updatedAt.timeIntervalSince1970.isFinite else {
            throw QuotaSnapshotError.invalidDate(field: "updated_at", value: String(describing: updatedAt))
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuotaSnapshotError.emptyField("source")
        }
        self.updatedAt = updatedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.source = source
        self.account = account
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case source
        case account
        case windows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let updatedString = try container.decode(String.self, forKey: .updatedAt)
        guard let updatedAt = QuotaSnapshotDateCoding.date(from: updatedString) else {
            throw QuotaSnapshotError.invalidDate(field: "updated_at", value: updatedString)
        }
        let source = try container.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuotaSnapshotError.emptyField("source")
        }

        self.updatedAt = updatedAt
        self.fiveHour = try container.decode(QuotaSnapshotWindow.self, forKey: .fiveHour)
        self.sevenDay = try container.decode(QuotaSnapshotWindow.self, forKey: .sevenDay)
        self.source = source
        self.account = try container.decodeIfPresent(QuotaSnapshotAccount.self, forKey: .account)
        self.windows = try container.decodeIfPresent([QuotaSnapshotWindowEntry].self, forKey: .windows) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(QuotaSnapshotDateCoding.string(from: updatedAt), forKey: .updatedAt)
        try container.encode(fiveHour, forKey: .fiveHour)
        try container.encode(sevenDay, forKey: .sevenDay)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(account, forKey: .account)
        try container.encode(windows, forKey: .windows)
    }

    /// Decodes one Schema v1 snapshot and enforces the 64 KiB size limit.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= QuotaConstants.snapshotMaximumSizeBytes else {
            throw QuotaSnapshotError.snapshotTooLarge(
                actualBytes: data.count,
                maximumBytes: QuotaConstants.snapshotMaximumSizeBytes
            )
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// Encodes the snapshot with stable, human-readable Schema v1 field names.
    public func encodedData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Entry point for callers that want to name the schema explicitly.
public enum QuotaSnapshotSchema {
    /// The supported unified snapshot schema version.
    public static let version = QuotaSnapshot.schemaVersion

    /// Decodes a Schema v1 payload.
    public static func decode(_ data: Data) throws -> QuotaSnapshot {
        try QuotaSnapshot.decode(data)
    }

    /// Encodes a Schema v1 payload.
    public static func encode(_ snapshot: QuotaSnapshot, prettyPrinted: Bool = false) throws -> Data {
        try snapshot.encodedData(prettyPrinted: prettyPrinted)
    }
}

/// Explicit type name for consumers that include the schema version in APIs.
public typealias QuotaSnapshotV1 = QuotaSnapshot

private enum QuotaSnapshotDateCoding {
    static func date(from value: String) -> Date? {
        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
            ISO8601DateFormatter.Options([.withInternetDateTime])
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value), date.timeIntervalSince1970.isFinite {
                return date
            }
        }
        return nil
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
