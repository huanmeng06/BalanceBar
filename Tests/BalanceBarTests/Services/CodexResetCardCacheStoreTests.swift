import Foundation
import XCTest
@testable import BalanceBar

final class CodexResetCardCacheStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let owner = "owner@example.com"
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var fileURL: URL { directory.appendingPathComponent("codex-reset-cards.json") }
    private var store: CodexResetCardCacheStore { CodexResetCardCacheStore(fileURL: fileURL) }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func parsedCredits() throws -> CodexBankedReset {
        let data = Data(#"{"credits":[{"id":"custom","reset_type":"custom","title":"A custom reset","expires_at":1700007200},{"id":"full","reset_type":"codex_rate_limits","expires_at":1700003600}]}"#.utf8)
        var reset = try XCTUnwrap(OfficialQuotaResponseParser.parseBankedResetCredits(data: data, now: now))
        reset.ownerEmail = owner
        return reset
    }

    func testRoundTripMatchesOnlineParsingAndFiltersExpiredCards() throws {
        let reset = try parsedCredits()
        store.save(reset, accountKey: owner, fetchedAt: now)
        let restored = try XCTUnwrap(store.load(now: now))
        XCTAssertEqual(restored.reset, reset)
        XCTAssertEqual(restored.fetchedAt, now)
        XCTAssertEqual(restored.reset.cards.map(\.id), ["full", "custom"])

        let later = try XCTUnwrap(store.load(now: now.addingTimeInterval(3_600)))
        XCTAssertEqual(later.reset.cards.map(\.id), ["custom"])
        XCTAssertNotEqual(later.reset.cards.first?.remainingText, reset.cards.last?.remainingText)
        let expired = try XCTUnwrap(store.load(now: now.addingTimeInterval(7_200)))
        XCTAssertEqual(expired.reset, CodexBankedReset(cards: [], ownerEmail: owner))
        XCTAssertEqual(expired.fetchedAt, now)
    }

    func testReadRebuildsLocalizedTitleButKeepsAPITitle() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english
        let reset = try parsedCredits()
        store.save(reset, accountKey: owner, fetchedAt: now)

        AppLanguage.selected = .simplifiedChinese
        let restored = try XCTUnwrap(store.load(now: now)).reset
        XCTAssertEqual(restored.cards.first?.localizedTitleText, tr(.keyCodexBankedResetFullResetTitle))
        XCTAssertNotEqual(restored.cards.first?.titleText, reset.cards.first?.titleText)
        XCTAssertEqual(restored.cards.last?.localizedTitleText, "A custom reset")
    }

    func testMissingCorruptAndUnknownVersionFilesAreIgnored() throws {
        XCTAssertNil(store.load(now: now))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not JSON".utf8).write(to: fileURL)
        XCTAssertNil(store.load(now: now))
        try Data(#"{"version":2,"fetchedAt":"2026-01-01T00:00:00Z","credits":[]}"#.utf8).write(to: fileURL)
        XCTAssertNil(store.load(now: now))
    }
}
