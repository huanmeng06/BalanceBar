import Foundation
import XCTest
@testable import BalanceBar

final class ResponseParsersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBalanceFixturesCoverGenericRightCodeAndNativeProviders() throws {
        let cases: [(String, Data, BalanceResponseParser.Context, Double, String)] = [
            (
                "generic",
                fixture(#"{"balance":"12.50","quota":{"unit":"CNY"}}"#),
                BalanceResponseParser.Context(),
                12.5,
                "CNY"
            ),
            (
                "right-code",
                fixture(#"{"balance":"2","subscriptions":[{"available_prefixes":["/codex"],"remaining_quota":"4","total_quota":5,"reset_today":true},{"available_prefixes":["/codex"],"remaining_quota":1,"total_quota":10,"reset_today":false},{"available_prefixes":["/claude"],"remaining_quota":100,"total_quota":100}]}"#),
                BalanceResponseParser.Context(isRightCode: true, subscriptionPrefix: "/codex"),
                17,
                "USD"
            ),
            (
                "new-api",
                fixture(#"{"success":true,"data":{"quota":"1000000"}}"#),
                BalanceResponseParser.Context(isNewAPI: true),
                2,
                "USD"
            ),
            (
                "deepseek",
                fixture(#"{"balance_infos":[{"total_balance":"8.25","currency":"CNY"}]}"#),
                BalanceResponseParser.Context(nativeBalanceProvider: .deepSeek),
                8.25,
                "CNY"
            ),
            (
                "stepfun",
                fixture(#"{"balance":4.5}"#),
                BalanceResponseParser.Context(nativeBalanceProvider: .stepFun),
                4.5,
                "CNY"
            ),
            (
                "siliconflow-cn",
                fixture(#"{"data":{"totalBalance":"7.25"}}"#),
                BalanceResponseParser.Context(nativeBalanceProvider: .siliconFlowCN),
                7.25,
                "CNY"
            ),
            (
                "openrouter",
                fixture(#"{"data":{"total_credits":10,"total_usage":"2.5"}}"#),
                BalanceResponseParser.Context(nativeBalanceProvider: .openRouter),
                7.5,
                "USD"
            ),
            (
                "novita",
                fixture(#"{"availableBalance":25000}"#),
                BalanceResponseParser.Context(nativeBalanceProvider: .novitaAI),
                2.5,
                "USD"
            )
        ]

        for (name, data, context, amount, unit) in cases {
            let result = try BalanceResponseParser.parse(data: data, context: context)
            XCTAssertEqual(result.amount, amount, accuracy: 0.000001, "fixture: \(name)")
            XCTAssertEqual(result.unit, unit, "fixture: \(name)")
        }
    }

    func testBalanceParserPreservesFieldPriorityAndRejectsInvalidFixtures() throws {
        let result = try BalanceResponseParser.parse(
            object: [
                "remaining": 3.25,
                "balance": 9.5,
                "unit": "EUR",
                "quota": ["remaining": 1.5, "unit": "CNY"]
            ],
            context: BalanceResponseParser.Context()
        )
        XCTAssertEqual(result, BalanceResponseParser.Output(amount: 3.25, unit: "EUR"))

        XCTAssertThrowsError(
            try BalanceResponseParser.parse(
                data: Data("not-json".utf8),
                context: BalanceResponseParser.Context()
            )
        ) { error in
            XCTAssertEqual(error as? ResponseParserError, .invalidJSON)
        }
        XCTAssertThrowsError(
            try BalanceResponseParser.parse(
                object: ["data": ["unexpected": true]],
                context: BalanceResponseParser.Context(nativeBalanceProvider: .stepFun)
            )
        ) { error in
            XCTAssertEqual(error as? ResponseParserError, .unsupportedFormat)
        }
    }

    func testOfficialQuotaFixturesCoverClaudeAndCodexWindows() throws {
        let claude = try OfficialQuotaResponseParser.parse(
            data: fixture(#"{"seven_day":{"utilization":"12.5","resets_at":"2023-11-15T00:13:20Z"}}"#),
            client: .claude,
            now: now
        )
        XCTAssertEqual(claude.remaining, 87.5, accuracy: 0.000001)
        XCTAssertEqual(claude.label, tr(.keyResponseParsers7DayQuota))
        XCTAssertEqual(claude.daysText, tr(.keyResponseParsers7Days))
        XCTAssertEqual(claude.reset, "2h0m")

        let codex = try OfficialQuotaResponseParser.parse(
            data: fixture(#"{"rate_limit":{"primary_window":{"used_percent":"20","limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1700007200},"secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_after_seconds":5400,"reset_at":1700010800}}}"#),
            client: .codex,
            now: now
        )
        XCTAssertEqual(codex.remaining, 45, accuracy: 0.000001)
        XCTAssertEqual(codex.label, tr(.keyResponseParsers7DayQuota))
        XCTAssertEqual(codex.daysText, tr(.keyResponseParsers7Days))
        XCTAssertEqual(codex.reset, "1h30m")
        XCTAssertEqual(codex.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(codex.windows.map(\.remaining), [80, 45])
        XCTAssertEqual(codex.windows.map(\.reset), ["1h0m", "1h30m"])
        XCTAssertEqual(codex.windows.map(\.resetAt), [
            Date(timeIntervalSince1970: 1_700_007_200),
            Date(timeIntervalSince1970: 1_700_010_800)
        ])
        XCTAssertEqual(codex.resetAt, Date(timeIntervalSince1970: 1_700_010_800))
    }

    func testCodexWindowOrderingUsesSemanticDurationsInsteadOfPayloadFieldOrder() throws {
        let output = try OfficialQuotaResponseParser.parse(
            data: fixture(#"{"rate_limit":{"secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_after_seconds":5400},"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":3600}}}"#),
            client: .codex,
            now: now
        )

        XCTAssertEqual(output.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(output.windows.map(\.label), [
            tr(.keyResponseParsers5HourQuota),
            tr(.keyResponseParsers7DayQuota2)
        ])
        XCTAssertEqual(output.windows.map(\.daysText), [
            tr(.keyResponseParsers5Hours),
            tr(.keyResponseParsers7Days4)
        ])
    }

    func testCodexMissingAndLegacyWindowsDoNotSynthesizeTheOtherWindow() throws {
        let weeklyOnly = try OfficialQuotaResponseParser.parse(
            object: [
                "rate_limit": [
                    "secondary_window": [
                        "used_percent": 55,
                        "limit_window_seconds": 604_800,
                        "reset_after_seconds": 5_400
                    ]
                ]
            ],
            client: .codex,
            now: now
        )
        XCTAssertEqual(weeklyOnly.windows.map(\.kind), [.sevenDay])
        XCTAssertEqual(weeklyOnly.remaining, 45, accuracy: 0.000001)

        let fiveHourOnly = try OfficialQuotaResponseParser.parse(
            object: [
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 20,
                        "limit_window_seconds": 18_000,
                        "reset_after_seconds": 3_600
                    ]
                ]
            ],
            client: .codex,
            now: now
        )
        XCTAssertEqual(fiveHourOnly.windows.map(\.kind), [.fiveHour])
        XCTAssertEqual(fiveHourOnly.remaining, 80, accuracy: 0.000001)

        let legacy = try OfficialQuotaResponseParser.parse(
            object: [
                "primary_window": [
                    "used_percent": 20,
                    "limit_window_seconds": 3_600,
                    "reset_after_seconds": 600
                ]
            ],
            client: .codex,
            now: now
        )
        XCTAssertEqual(legacy.windows.map(\.kind), [.other])
        XCTAssertEqual(legacy.label, tr(.keyResponseParsersQuota))
        XCTAssertFalse(legacy.windows.contains { $0.kind == .fiveHour || $0.kind == .sevenDay })

        let legacyWithoutDuration = try OfficialQuotaResponseParser.parse(
            object: [
                "primary_window": [
                    "used_percent": 20,
                    "reset_description": "later"
                ]
            ],
            client: .codex,
            now: now
        )
        XCTAssertEqual(legacyWithoutDuration.windows.map(\.kind), [.other])
        XCTAssertEqual(legacyWithoutDuration.remaining, 80, accuracy: 0.000001)
        XCTAssertEqual(legacyWithoutDuration.reset, "later")
    }

    func testResetDescriptionsSupportNumericAndTextValues() {
        XCTAssertEqual(ResponseParsingSupport.numberValue(NSNumber(value: 12.5)), 12.5)
        XCTAssertEqual(ResponseParsingSupport.numberValue("12.5"), 12.5)
        XCTAssertNil(ResponseParsingSupport.numberValue("unknown"))
        XCTAssertEqual(ResponseParsingSupport.stringValue("USD"), "USD")
        XCTAssertNil(ResponseParsingSupport.stringValue(NSNumber(value: 1)))

        XCTAssertEqual(
            ResponseParsingSupport.resetDescription(5_400, now: now),
            "1h30m"
        )
        XCTAssertEqual(
            ResponseParsingSupport.resetDescription("5400", now: now),
            "1h30m"
        )
        XCTAssertEqual(
            ResponseParsingSupport.resetDescription(1_700_000_000_000, now: now),
            "0m"
        )
        XCTAssertEqual(
            ResponseParsingSupport.resetDescription("2023-11-15T00:13:20Z", now: now),
            "2h0m"
        )
        XCTAssertEqual(ResponseParsingSupport.resetDescription("after deploy", now: now), "after deploy")
        XCTAssertNil(ResponseParsingSupport.resetDescription("", now: now))
    }

    func testResetDatesAcceptOnlyFutureAbsoluteEpochOrISOValues() {
        XCTAssertEqual(
            ResponseParsingSupport.resetDate(1_700_003_600, now: now),
            Date(timeIntervalSince1970: 1_700_003_600)
        )
        XCTAssertEqual(
            ResponseParsingSupport.resetDate("1700003600000", now: now),
            Date(timeIntervalSince1970: 1_700_003_600)
        )
        XCTAssertEqual(
            ResponseParsingSupport.resetDate("2023-11-14T23:13:20Z", now: now),
            Date(timeIntervalSince1970: 1_700_003_600)
        )
        XCTAssertEqual(
            ResponseParsingSupport.resetDate("2023-11-14T23:13:20.500Z", now: now),
            Date(timeIntervalSince1970: 1_700_003_600.5)
        )

        // A relative countdown must never become an absolute date.
        XCTAssertNil(ResponseParsingSupport.resetDate(5_400, now: now))
        XCTAssertNil(ResponseParsingSupport.resetDate("5400", now: now))
        XCTAssertNil(ResponseParsingSupport.resetDate("not-a-date", now: now))
        XCTAssertNil(ResponseParsingSupport.resetDate(1_699_999_999, now: now))
        XCTAssertNil(ResponseParsingSupport.resetDate(Double.greatestFiniteMagnitude, now: now))
        XCTAssertNil(ResponseParsingSupport.resetDate("", now: now))
    }

    func testCodexRelativeOnlyAndInvalidOrExpiredAbsoluteTimestampsRemainSafe() throws {
        let relativeOnly = try OfficialQuotaResponseParser.parse(
            object: [
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 20,
                        "limit_window_seconds": 18_000,
                        "reset_after_seconds": 2_700
                    ]
                ]
            ],
            client: .codex,
            now: now
        )
        XCTAssertEqual(relativeOnly.windows.first?.reset, "45m")
        XCTAssertNil(relativeOnly.windows.first?.resetAt)

        let invalid = try OfficialQuotaResponseParser.parse(
            object: [
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 20,
                        "limit_window_seconds": 18_000,
                        "reset_at": "later"
                    ]
                ]
            ],
            client: .codex,
            now: now
        )
        XCTAssertEqual(invalid.windows.first?.reset, "later")
        XCTAssertNil(invalid.windows.first?.resetAt)

        let expired = try OfficialQuotaResponseParser.parse(
            object: [
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 20,
                        "limit_window_seconds": 18_000,
                        "reset_at": 1_699_999_999
                    ]
                ]
            ],
            client: .codex,
            now: now
        )
        XCTAssertEqual(expired.windows.first?.reset, "0m")
        XCTAssertNil(expired.windows.first?.resetAt)
    }

    func testOfficialQuotaParserRejectsInvalidAndMissingFixtures() throws {
        XCTAssertThrowsError(
            try OfficialQuotaResponseParser.parse(
                data: Data("{invalid".utf8),
                client: .codex,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ResponseParserError, .invalidJSON)
        }

        XCTAssertThrowsError(
            try OfficialQuotaResponseParser.parse(
                object: ["rate_limit": ["primary_window": ["limit_window_seconds": 18_000]]],
                client: .codex,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ResponseParserError, .unsupportedFormat)
        }
    }

    private func fixture(_ json: String) -> Data {
        Data(json.utf8)
    }
}
