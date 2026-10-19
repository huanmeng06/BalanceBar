import Foundation

/// Token usage of one assistant message in a Claude Code transcript.
public struct TranscriptUsageRecord: Equatable {
    public let uuid: String
    public let requestID: String?
    public let timestamp: Date
    public let model: String
    public let sessionID: String?
    public let isSidechain: Bool
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int

    /// Key used to drop repeated records: the request when known, otherwise the message.
    public var deduplicationKey: String {
        requestID.map { "r:" + $0 } ?? "u:" + uuid
    }

    public var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
    public var cacheTokens: Int { cacheCreationTokens + cacheReadTokens }
}

/// Parses transcript JSONL lines. Pure and side-effect free.
public enum TranscriptUsageParser {
    /// Returns the usage record for an assistant line, or `nil` for any other line.
    public static func parse(_ line: Data) -> TranscriptUsageRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let uuid = object["uuid"] as? String,
              let timestampText = object["timestamp"] as? String,
              let timestamp = parseDate(timestampText),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }
        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>" else { return nil }
        func count(_ key: String) -> Int { max(0, (usage[key] as? NSNumber)?.intValue ?? 0) }
        return TranscriptUsageRecord(
            uuid: uuid,
            requestID: object["requestId"] as? String,
            timestamp: timestamp,
            model: model,
            sessionID: object["sessionId"] as? String,
            isSidechain: object["isSidechain"] as? Bool ?? false,
            inputTokens: count("input_tokens"),
            outputTokens: count("output_tokens"),
            cacheCreationTokens: count("cache_creation_input_tokens"),
            cacheReadTokens: count("cache_read_input_tokens")
        )
    }

    /// Message-level key for `IncrementalJSONLReader`; request-level dedupe is done by the estimator.
    public static func readerDeduplicationKey(_ line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let uuid = object["uuid"] as? String else { return nil }
        return uuid
    }

    private static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
