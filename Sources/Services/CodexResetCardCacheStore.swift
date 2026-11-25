import Foundation
import OSLog

struct CodexResetCardCacheStore {
    private struct StoredCache: Codable {
        struct Credit: Codable {
            let id: String?
            let resetType: String
            let apiTitle: String?
            let expiresAt: Date?
        }

        let version: Int
        let accountKey: String?
        let fetchedAt: Date
        let credits: [Credit]
    }

    private let fileURL: URL

    private static func fractionalDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter
    }

    init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "BalanceBar", isDirectory: true)
            .appendingPathComponent("Quota", isDirectory: true)
            .appendingPathComponent("codex-reset-cards.json")
    }

    func save(_ reset: CodexBankedReset, accountKey: String?, fetchedAt: Date) {
        let stored = StoredCache(version: 1, accountKey: accountKey, fetchedAt: fetchedAt, credits: reset.cards.map {
            StoredCache.Credit(id: $0.id, resetType: $0.resetType,
                apiTitle: $0.titleLocalizationKey == nil ? $0.titleText : nil, expiresAt: $0.expiresAt)
        })
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            let formatter = Self.fractionalDateFormatter()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(formatter.string(from: date))
            }
            try encoder.encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "BalanceBar", category: "Quota")
                .debug("Codex reset-card cache write failed")
        }
    }

    func load(now: Date) -> (reset: CodexBankedReset, fetchedAt: Date)? {
        let decoder = JSONDecoder()
        let fractional = Self.fractionalDateFormatter()
        let wholeSeconds = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = fractional.date(from: value) ?? wholeSeconds.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid reset-card cache date")
            }
            return date
        }
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? decoder.decode(StoredCache.self, from: data),
              stored.version == 1 else { return nil }
        let cards = stored.credits.compactMap {
            OfficialQuotaResponseParser.codexBankedResetCard(
                id: $0.id, resetType: $0.resetType, apiTitle: $0.apiTitle, expiresAt: $0.expiresAt, now: now)
        }.sorted(by: OfficialQuotaResponseParser.bankedResetCardSort)
        return (CodexBankedReset(cards: cards, ownerEmail: stored.accountKey), stored.fetchedAt)
    }
}
