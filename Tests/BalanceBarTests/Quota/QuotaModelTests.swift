import Foundation
import XCTest
@testable import BalanceBar

final class QuotaModelTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let root = try TestRepositoryRoot.locate(from: #filePath)
        let url = root.appendingPathComponent("Tests/Fixtures/Quota").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    func testHUDFixtureDecodesAndDefaultsOptionalExtensions() throws {
        let snapshot = try QuotaSnapshot.decode(fixture("hud-0.11.3.json"))

        XCTAssertEqual(QuotaSnapshot.schemaVersion, 1)
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(
            snapshot.updatedAt,
            formatter.date(from: "2026-10-17T06:12:03Z")
        )
        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour.usedPercentage), 34)
        XCTAssertEqual(try XCTUnwrap(snapshot.sevenDay.usedPercentage), 61.5)
        XCTAssertEqual(snapshot.source, "unknown")
        XCTAssertNil(snapshot.account)
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testModFixtureDecodesSchemaExtensionsAndUnknownWindowKind() throws {
        let snapshot = try QuotaSnapshot.decode(fixture("mod-super-set.json"))

        XCTAssertEqual(snapshot.source, "balancebar-mod")
        // sha256 of "user@example.com", the identity the SnapshotInbox attribution tests use.
        XCTAssertEqual(snapshot.account?.emailHash, "sha256:b4c9a289323b21a01c3e940f150eb9b8c542587f1abfd8f0e1cc1ffc5e475514")
        XCTAssertEqual(snapshot.windows.count, 4)
        XCTAssertEqual(snapshot.windows[0].kind, .fiveHour)
        XCTAssertEqual(snapshot.windows[1].kind, .sevenDay)
        XCTAssertEqual(snapshot.windows[2].kind, .other("sonnet_context"))
        XCTAssertEqual(snapshot.windows[2].usedPercentage, 12)
        XCTAssertEqual(snapshot.windows[3].kind, .other("extra_usage"))
        XCTAssertEqual(snapshot.windows[3].usedPercentage, 35)
    }

    func testCorruptOutOfRangeAndMissingWindowFixturesAreRejected() throws {
        for fixtureName in ["corrupt.json", "out-of-range.json", "missing-window.json"] {
            XCTAssertThrowsError(try QuotaSnapshot.decode(fixture(fixtureName)), fixtureName)
        }
    }

    func testSchemaAcceptsInclusivePercentageBoundariesAndRejectsOversizePayloads() throws {
        let payload = """
        {
          "updated_at": "2026-10-17T06:12:03Z",
          "five_hour": { "used_percentage": 0 },
          "seven_day": { "used_percentage": 100 }
        }
        """
        let snapshot = try QuotaSnapshot.decode(Data(payload.utf8))
        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour.usedPercentage), 0)
        XCTAssertEqual(try XCTUnwrap(snapshot.sevenDay.usedPercentage), 100)

        let oversized = Data(repeating: 0x20, count: QuotaConstants.snapshotMaximumSizeBytes + 1)
        XCTAssertThrowsError(try QuotaSnapshot.decode(oversized)) { error in
            XCTAssertEqual(
                error as? QuotaSnapshotError,
                .snapshotTooLarge(
                    actualBytes: oversized.count,
                    maximumBytes: QuotaConstants.snapshotMaximumSizeBytes
                )
            )
        }
    }

    func testSchemaRoundTripKeepsContractFields() throws {
        let original = try QuotaSnapshot.decode(fixture("mod-super-set.json"))
        let encoded = try original.encodedData()
        let decoded = try QuotaSnapshot.decode(encoded)

        XCTAssertEqual(decoded, original)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(encodedText.contains("updated_at"))
        XCTAssertTrue(encodedText.contains("used_percentage"))
        XCTAssertTrue(encodedText.contains("sonnet_context"))
        XCTAssertTrue(encodedText.contains("extra_usage"))
    }

    func testHUDFixtureAllowsNullPercentageAndRoundTripsNull() throws {
        let original = try QuotaSnapshot.decode(fixture("hud-null-percentage.json"))

        XCTAssertEqual(try XCTUnwrap(original.fiveHour.usedPercentage), 34)
        XCTAssertNil(original.sevenDay.usedPercentage)

        let encoded = try original.encodedData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let sevenDay = try XCTUnwrap(object["seven_day"] as? [String: Any])
        XCTAssertTrue(sevenDay["used_percentage"] is NSNull)
        XCTAssertEqual(try QuotaSnapshot.decode(encoded), original)
    }

    func testModelTypesValidateObservationAndExposeDisplayContract() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = AccountIdentity(
            stableID: "account-uuid",
            email: "person@example.com",
            plan: "pro",
            idSource: .accountUUID
        )
        let observation = QuotaObservation(
            window: .fiveHour,
            usedPercentage: 34,
            resetsAt: now.addingTimeInterval(3_600),
            observedAt: now,
            receivedAt: now,
            source: "claude-hud",
            trust: .a,
            accountID: identity.stableID,
            epoch: .initial
        )
        XCTAssertNotNil(observation)
        XCTAssertNil(QuotaObservation(
            window: .fiveHour,
            usedPercentage: 101,
            receivedAt: now,
            source: "claude-hud",
            trust: .a,
            accountID: identity.stableID,
            epoch: .initial
        ))

        let window = QuotaWindowDisplay(
            kind: .fiveHour,
            usedPercentage: 34,
            resetsAt: now.addingTimeInterval(3_600),
            isEstimated: false,
            state: .inProgress,
            hoverTextKey: "quota.fiveHour"
        )
        let display = QuotaDisplayModel(
            windows: [window],
            isEstimated: false,
            state: .inProgress,
            hoverTextKey: "quota.summary"
        )
        XCTAssertEqual(display.window(for: .fiveHour)?.displayValue, 34)
        XCTAssertEqual(display.status, .inProgress)
        XCTAssertEqual(AccountEpoch.initial.next.rawValue, 1)
    }

    func testContractConstantsMatchIssueValues() {
        XCTAssertEqual(QuotaConstants.automaticRequestMinimumInterval, 180)
        XCTAssertEqual(QuotaConstants.minimumCooldown, 900)
        XCTAssertEqual(QuotaConstants.realtimeSourceFreshness, 120)
        XCTAssertEqual(QuotaConstants.gradeBTolerancePercentagePoints, 2)
        XCTAssertEqual(QuotaConstants.snapshotMaximumSizeBytes, 64 * 1_024)
    }
}
