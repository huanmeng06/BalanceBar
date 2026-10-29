import Foundation

/// File-level failures that prevent any window from being produced.
public enum QuotaSnapshotParseError: Error, Equatable {
    case tooLarge(size: Int, limit: Int)
    /// The bytes are not valid JSON, typically a half-written file.
    case malformedJSON
    case notAnObject
    case invalidUpdatedAt
}

/// A window that passed per-window validation.
public struct ParsedQuotaWindow: Equatable {
    public let kind: QuotaWindowKind
    public let usedPercentage: Double
    public let resetsAt: Date?
}

/// Parse output: valid windows plus the reasons other windows were dropped.
public struct ParsedQuotaSnapshot: Equatable {
    public let updatedAt: Date
    public let source: String?
    public let accountEmailHash: String?
    public let accountOrganizationHash: String?
    public let windows: [ParsedQuotaWindow]
    public let discarded: [String]
}

/// Lenient Schema v1 parser shared by the HUD subset and the Mod superset.
///
/// Unlike `QuotaSnapshot.decode`, which rejects a whole snapshot, this parser validates
/// window by window: an invalid or absent window is dropped (never filled with 0)
/// and the remaining windows are still returned.
public enum QuotaSnapshotParser {
    /// Window lengths used for the `resets_at >= updated_at - window length` check.
    /// Unknown kinds use the longest known window.
    public static func windowLength(for kind: QuotaWindowKind) -> TimeInterval {
        switch kind {
        case .fiveHour: return 5 * 3_600
        case .sevenDay, .other: return 7 * 24 * 3_600
        }
    }

    public static func parse(
        _ data: Data,
        maximumSize: Int = QuotaConstants.snapshotMaximumSizeBytes
    ) throws -> ParsedQuotaSnapshot {
        guard data.count <= maximumSize else {
            throw QuotaSnapshotParseError.tooLarge(size: data.count, limit: maximumSize)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw QuotaSnapshotParseError.malformedJSON
        }
        guard let root = object as? [String: Any] else { throw QuotaSnapshotParseError.notAnObject }
        guard let updatedString = root["updated_at"] as? String, let updatedAt = date(from: updatedString) else {
            throw QuotaSnapshotParseError.invalidUpdatedAt
        }

        var windows: [ParsedQuotaWindow] = []
        var discarded: [String] = []
        func accept(_ kind: QuotaWindowKind, _ raw: Any?, label: String) {
            guard !windows.contains(where: { $0.kind == kind }) else { return }
            switch validateWindow(kind: kind, raw: raw, updatedAt: updatedAt) {
            case let .success(window): if let window { windows.append(window) }
            case let .failure(reason): discarded.append("\(label): \(reason)")
            }
        }
        accept(.fiveHour, root["five_hour"], label: "five_hour")
        accept(.sevenDay, root["seven_day"], label: "seven_day")
        for (index, entry) in (root["windows"] as? [Any] ?? []).enumerated() {
            let label = "windows[\(index)]"
            guard let dict = entry as? [String: Any],
                  let kindString = dict["kind"] as? String,
                  !kindString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                discarded.append("\(label): missing kind")
                continue
            }
            accept(QuotaWindowKind(rawValue: kindString), dict, label: label)
        }

        let source = (root["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = root["account"] as? [String: Any]
        let emailHash = account?["email_hash"] as? String
        let organizationHash = account?["organization_hash"] as? String
        return ParsedQuotaSnapshot(
            updatedAt: updatedAt,
            source: source?.isEmpty == false ? source : nil,
            accountEmailHash: emailHash,
            accountOrganizationHash: organizationHash,
            windows: windows,
            discarded: discarded
        )
    }

    private enum WindowFailure: Error { case reason(String) }

    /// `.success(nil)` means the window is legitimately absent or has no percentage yet.
    private static func validateWindow(
        kind: QuotaWindowKind,
        raw: Any?,
        updatedAt: Date
    ) -> Result<ParsedQuotaWindow?, WindowFailure> {
        guard let raw, !(raw is NSNull) else { return .success(nil) }
        guard let dict = raw as? [String: Any] else { return .failure(.reason("not an object")) }
        guard let percentValue = dict["used_percentage"], !(percentValue is NSNull) else { return .success(nil) }
        guard let number = percentValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              (0...100).contains(number.doubleValue) else {
            return .failure(.reason("used_percentage out of range or not a number"))
        }
        var resetsAt: Date?
        if let resetValue = dict["resets_at"], !(resetValue is NSNull) {
            guard let string = resetValue as? String, let parsed = date(from: string) else {
                return .failure(.reason("resets_at unparsable"))
            }
            guard parsed >= updatedAt.addingTimeInterval(-windowLength(for: kind)) else {
                return .failure(.reason("resets_at earlier than updated_at minus window length"))
            }
            resetsAt = parsed
        }
        return .success(ParsedQuotaWindow(kind: kind, usedPercentage: number.doubleValue, resetsAt: resetsAt))
    }

    static func date(from value: String) -> Date? {
        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
            ISO8601DateFormatter.Options([.withInternetDateTime])
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value), date.timeIntervalSince1970.isFinite { return date }
        }
        return nil
    }
}
