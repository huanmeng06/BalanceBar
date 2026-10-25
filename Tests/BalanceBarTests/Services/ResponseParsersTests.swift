import Foundation
import XCTest
@testable import BalanceBar

final class ResponseParsersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let codexResetIssueJSON = Data(#"""
    {"mode":"model","updated_at":"2026-09-13T14:35:22.017Z","probabilities":{"raw_24h":0.23953072768015632,"raw_48h":0.4216864858573275,"rounded_24h":24,"rounded_48h":42,"model_24h":24,"model_48h":42},"confidence":"low","confidence_note":"Experimental: walk-forward backtest has not beaten both baselines yet.","hint_copy":"do not show"}
    """#.utf8)

    func testCodexRejectsNonFiniteUsedPercentBeforeRemainingClamp() throws {
        for invalid in ["NaN", "Infinity", "-Infinity"] {
            let primary: [String: Any] = ["used_percent": invalid, "limit_window_seconds": 18_000,
                                          "reset_at": 1_700_009_000]
            let data = try JSONSerialization.data(withJSONObject: ["rate_limit": ["primary_window": primary]])
            XCTAssertThrowsError(try OfficialQuotaResponseParser.parse(data: data, client: .codex, now: now))
            let secondary: [String: Any] = ["used_percent": 25, "limit_window_seconds": 604_800,
                                            "reset_at": 1_700_302_400]
            let mixed = try JSONSerialization.data(withJSONObject:
                ["rate_limit": ["primary_window": primary, "secondary_window": secondary]])
            let output = try OfficialQuotaResponseParser.parse(data: mixed, client: .codex, now: now)
            XCTAssertEqual(output.windows.map(\.kind), [.sevenDay])
            XCTAssertEqual(output.windows.map(\.remaining), [75])
        }
    }

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

    func testClaudeQuotaPreservesBothWindowsAndModelSpecificTiers() throws {
        let output = try OfficialQuotaResponseParser.parse(data: fixture(#"""
        {"five_hour":{"utilization":23,"resets_at":"2023-11-15T00:13:20Z"},
         "seven_day":{"utilization":"41","resets_at":"2023-11-21T00:13:20Z"},
         "seven_day_sonnet":{"utilization":110},"seven_day_opus":{"utilization":-5}}
        """#), client: .claude, now: now)
        XCTAssertEqual(output.windows.map(\.kind), [.fiveHour, .sevenDay, .other, .other])
        XCTAssertEqual(output.windows.map(\.remaining), [77, 59, 0, 100])
        XCTAssertEqual(output.windows.map(\.durationSeconds), [18_000, 604_800, 604_800, 604_800])
        XCTAssertEqual(output.windows[0].resetAt, Date(timeIntervalSince1970: 1_700_007_200))
        XCTAssertNotNil(output.windows[1].resetAt)
        XCTAssertNil(output.windows[2].resetAt)
        XCTAssertEqual(output.remaining, 59, "legacy scalar accessors still prefer weekly quota")
    }

    /// Issue #580: an explicit null window / null utilization means the window has not
    /// started and must still produce a 0% reading, or a pending reset can never be
    /// confirmed. A window that merely lacks the utilization key stays unknown, so a
    /// malformed payload cannot invent a fresh cycle and wrongly confirm a reset.
    func testClaudeQuotaTreatsExplicitNullWindowsAsNotStarted() throws {
        let output = try OfficialQuotaResponseParser.parse(data: fixture(#"{"five_hour":{"utilization":"25"},"seven_day":null,"seven_day_sonnet":{"utilization":"invalid"}}"#), client: .claude, now: now)
        XCTAssertEqual(output.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(output.windows.map(\.remaining), [75, 100], "a null window has not started")
        XCTAssertNil(output.windows.last?.resetAt)
        XCTAssertNil(output.windows.first?.resetAt)

        let missingKey = try OfficialQuotaResponseParser.claudeReadings(
            object: ["five_hour": [String: Any](), "seven_day": ["utilization": 41, "resets_at": "2023-11-21T00:13:20Z"]], now: now)
        XCTAssertEqual(missingKey.map(\.key), ["seven_day"], "a window without the utilization key stays unknown")

        let nullWindow = try OfficialQuotaResponseParser.parse(data: fixture(#"{"five_hour":null,"seven_day":{"utilization":41}}"#), client: .claude, now: now)
        XCTAssertEqual(nullWindow.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(nullWindow.windows.map(\.remaining), [100, 59], "only the explicit null window reads as not started")

        let nullUtilization = try OfficialQuotaResponseParser.claudeReadings(
            object: ["seven_day": ["utilization": NSNull()]], now: now)
        XCTAssertEqual(nullUtilization.map(\.usedPercentage), [0])
        XCTAssertNil(nullUtilization.first?.resetsAt, "a not-started window has no reset time")
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

    func testCodexLunaReserveMapsTheNamedAdditionalRateLimit() throws {
        let output = try OfficialQuotaResponseParser.parse(
            object: [
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 20,
                        "limit_window_seconds": 18_000,
                        "reset_after_seconds": 3_600
                    ],
                    "secondary_window": [
                        "used_percent": 55,
                        "limit_window_seconds": 604_800,
                        "reset_after_seconds": 5_400
                    ]
                ],
                "additional_rate_limits": [[
                    "limit_name": "gpt-reserve",
                    "metered_feature": "base_model_inference",
                    "rate_limit": [
                        "allowed": true,
                        "limit_reached": false,
                        "primary_window": [
                            "used_percent": 55,
                            "limit_window_seconds": 604_800,
                            "reset_after_seconds": 5_400,
                            "reset_at": 1_700_005_400
                        ],
                        "secondary_window": NSNull()
                    ]
                ]]
            ],
            client: .codex,
            now: now
        )

        let reserve = try XCTUnwrap(output.lunaReserve)
        XCTAssertEqual(reserve.status, .available)
        XCTAssertEqual(reserve.remaining ?? -1, 45, accuracy: 0.000001)
        XCTAssertEqual(reserve.reset, "1h30m")
        XCTAssertEqual(reserve.resetAt, Date(timeIntervalSince1970: 1_700_005_400))
        XCTAssertEqual(output.windows.map(\.kind), [.fiveHour, .sevenDay])
    }

    func testCodexLunaReserveKeepsUnavailableSeparateFromZeroRemaining() throws {
        let standardWindow: [String: Any] = [
            "used_percent": 20,
            "limit_window_seconds": 18_000,
            "reset_after_seconds": 3_600
        ]

        let unavailable = try OfficialQuotaResponseParser.parse(
            object: [
                "rate_limit": ["primary_window": standardWindow],
                "additional_rate_limits": [[
                    "limit_name": "gpt-reserve",
                    "metered_feature": "base_model_inference",
                    "rate_limit": ["allowed": false, "limit_reached": true]
                ]]
            ],
            client: .codex,
            now: now
        )
        let unavailableReserve = try XCTUnwrap(unavailable.lunaReserve)
        XCTAssertEqual(unavailableReserve.status, .unavailable)
        XCTAssertNil(unavailableReserve.remaining)
        XCTAssertNil(unavailableReserve.reset)

        let zeroRemaining = try OfficialQuotaResponseParser.parse(
            object: [
                "rate_limit": ["primary_window": standardWindow],
                "additional_rate_limits": [[
                    "limit_name": "gpt-reserve",
                    "metered_feature": "base_model_inference",
                    "rate_limit": [
                        "allowed": true,
                        "limit_reached": true,
                        "primary_window": [
                            "used_percent": 100,
                            "reset_after_seconds": 300
                        ]
                    ]
                ]]
            ],
            client: .codex,
            now: now
        )
        let zeroRemainingReserve = try XCTUnwrap(zeroRemaining.lunaReserve)
        XCTAssertEqual(zeroRemainingReserve.status, .available)
        XCTAssertEqual(zeroRemainingReserve.remaining ?? -1, 0, accuracy: 0.000001)
        XCTAssertEqual(zeroRemainingReserve.reset, "5m")

        let limitReachedWithoutUsage = try OfficialQuotaResponseParser.parse(
            object: [
                "rate_limit": ["primary_window": standardWindow],
                "additional_rate_limits": [[
                    "limit_name": "gpt-reserve",
                    "metered_feature": "base_model_inference",
                    "rate_limit": [
                        "allowed": true,
                        "limit_reached": true,
                        "primary_window": [
                            "reset_after_seconds": 300
                        ]
                    ]
                ]]
            ],
            client: .codex,
            now: now
        )
        let limitReachedReserve = try XCTUnwrap(limitReachedWithoutUsage.lunaReserve)
        XCTAssertEqual(limitReachedReserve.status, .available)
        XCTAssertEqual(limitReachedReserve.remaining ?? -1, 0, accuracy: 0.000001)
        XCTAssertEqual(limitReachedReserve.reset, "5m")
    }

    func testCodexLunaReserveRejectsUnrelatedOrMalformedAdditionalLimits() throws {
        let standardWindow: [String: Any] = [
            "used_percent": 20,
            "limit_window_seconds": 18_000
        ]
        let output = try OfficialQuotaResponseParser.parse(
            object: [
                "rate_limit": ["primary_window": standardWindow],
                "additional_rate_limits": [
                    [
                        "limit_name": "other-reserve",
                        "metered_feature": "base_model_inference",
                        "rate_limit": ["allowed": true]
                    ],
                    [
                        "limit_name": "gpt-reserve",
                        "metered_feature": "other_feature",
                        "rate_limit": ["allowed": true]
                    ],
                    [
                        "limit_name": "gpt-reserve",
                        "metered_feature": "base_model_inference",
                        "rate_limit": [
                            "allowed": true,
                            "primary_window": ["used_percent": "not-a-number"]
                        ]
                    ]
                ]
            ],
            client: .codex,
            now: now
        )

        XCTAssertNil(output.lunaReserve)
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

    func testClaudeUnusedWindowShowsFullDurationCountdownLikeCodex() throws {
        let output = try OfficialQuotaResponseParser.parse(
            data: fixture(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":0}}"#),
            client: .claude, now: now)
        XCTAssertEqual(output.windows.map(\.reset), ["5h0m", ResponseParsingSupport.resetDescription(604_800.0, now: now)])
        XCTAssertEqual(output.windows.map(\.resetAt), [nil, nil], "no wall-clock reset is invented before first use")
        let codex = try OfficialQuotaResponseParser.parse(
            data: fixture(#"{"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":18000}}}"#),
            client: .codex, now: now)
        XCTAssertEqual(output.windows[0].reset, codex.windows[0].reset)
    }

    func testClaudeUsedWindowWithoutResetTimeStaysUnknown() throws {
        for utilization in [16, 100] {
            let output = try OfficialQuotaResponseParser.parse(
                data: fixture(#"{"five_hour":{"utilization":\#(utilization)},"seven_day":{"utilization":\#(utilization),"resets_at":null}}"#),
                client: .claude, now: now)
            XCTAssertEqual(output.windows.map(\.reset), [nil, nil], "\(utilization)% used has an unknown window start")
            XCTAssertEqual(output.windows.map(\.resetAt), [nil, nil])
        }
        let valid = try OfficialQuotaResponseParser.parse(
            data: fixture(#"{"five_hour":{"utilization":16,"resets_at":"2023-11-15T00:13:20Z"}}"#),
            client: .claude, now: now)
        XCTAssertEqual(valid.windows.first?.reset, "2h0m")
        XCTAssertEqual(valid.windows.first?.resetAt, Date(timeIntervalSince1970: 1_700_007_200))
    }

    func testClaudeMicrosecondResetTimestampFormatsAsCountdown() throws {
        let reference = ISO8601DateFormatter().date(from: "2026-10-17T02:30:00Z")!
        let reset = "2026-10-17T06:59:59.997388+00:00"
        XCTAssertEqual(ResponseParsingSupport.resetDescription(reset, now: reference), "4h29m")
        let output = try OfficialQuotaResponseParser.parse(
            data: fixture(#"{"five_hour":{"utilization":10,"resets_at":"2026-10-17T06:59:59.997388+00:00"}}"#),
            client: .claude, now: reference)
        XCTAssertEqual(output.windows.first?.reset, "4h29m")
        XCTAssertNotNil(output.windows.first?.resetAt)
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

    func testCodexBankedResetParsesAvailableUnexpiredCardsInExpiryOrder() throws {
        let earlier = Date(timeIntervalSince1970: 1_700_086_400)
        let later = Date(timeIntervalSince1970: 1_700_172_800)
        let output = try OfficialQuotaResponseParser.parse(
            object: standardCodexUsage(extra: [
                "rate_limit_reset_credits": [
                    "available_count": 2,
                    "credits": [
                        [
                            "id": "RateLimitResetCredit_later",
                            "reset_type": "codex_rate_limits",
                            "status": "available",
                            "expires_at": "2023-11-16T22:13:20Z",
                            "title": "One free rate limit reset"
                        ],
                        [
                            "id": "RateLimitResetCredit_earlier",
                            "reset_type": "codex_rate_limits",
                            "status": "available",
                            "expires_at": 1_700_086_400,
                            "title": "One free rate limit reset"
                        ]
                    ]
                ]
            ]),
            client: .codex,
            now: now
        )

        XCTAssertEqual(output.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(output.windows.map(\.remaining), [80, 45])
        XCTAssertFalse(output.bankedResetNeedsCreditList)
        let bankedReset = try XCTUnwrap(output.bankedReset)
        XCTAssertEqual(bankedReset.availableCount, 2)
        XCTAssertEqual(bankedReset.cards.map(\.id), [
            "RateLimitResetCredit_earlier",
            "RateLimitResetCredit_later"
        ])
        XCTAssertEqual(bankedReset.cards.map(\.resetType), [
            "codex_rate_limits",
            "codex_rate_limits"
        ])
        XCTAssertEqual(bankedReset.cards.map(\.titleText), [
            tr(.keyCodexBankedResetFullResetTitle),
            tr(.keyCodexBankedResetFullResetTitle)
        ])
        XCTAssertEqual(bankedReset.cards.map(\.windowText), [
            tr(.keyCodexBankedResetFullResetWindow),
            tr(.keyCodexBankedResetFullResetWindow)
        ])
        XCTAssertEqual(bankedReset.cards.map(\.expiresAt), [earlier, later])
        XCTAssertEqual(bankedReset.cards.map(\.expiresText), [
            expectedBankedResetExpiresText(earlier),
            expectedBankedResetExpiresText(later)
        ])
        XCTAssertEqual(
            bankedReset.cards.map(\.remainingText),
            [
                CodexBankedResetFormatting.remaining(until: earlier, now: now)?.text,
                CodexBankedResetFormatting.remaining(until: later, now: now)?.text
            ]
        )
        XCTAssertEqual(bankedReset.cards.map(\.remainingIsWarning), [false, false])
    }

    func testCodexBankedResetKeepsZeroCountAndStillFetchesWhenCountIsPositiveWithoutCredits() throws {
        let missing = try OfficialQuotaResponseParser.parse(
            object: standardCodexUsage(),
            client: .codex,
            now: now
        )
        XCTAssertEqual(missing.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(missing.bankedReset?.availableCount, 0)
        XCTAssertEqual(missing.bankedReset?.cards, [])
        XCTAssertFalse(missing.bankedResetNeedsCreditList)

        let zeroCount = try OfficialQuotaResponseParser.parse(
            object: standardCodexUsage(extra: [
                "rate_limit_reset_credits": [
                    "available_count": 0,
                    "credits": []
                ]
            ]),
            client: .codex,
            now: now
        )
        XCTAssertEqual(zeroCount.windows.map(\.remaining), [80, 45])
        XCTAssertEqual(zeroCount.bankedReset?.availableCount, 0)
        XCTAssertEqual(zeroCount.bankedReset?.cards, [])
        XCTAssertFalse(zeroCount.bankedResetNeedsCreditList)

        let malformed = try OfficialQuotaResponseParser.parse(
            object: standardCodexUsage(extra: [
                "rate_limit_reset_credits": "not-an-object",
                "additional_rate_limits": [[
                    "limit_name": "gpt-reserve",
                    "metered_feature": "base_model_inference",
                    "rate_limit": [
                        "allowed": true,
                        "limit_reached": false,
                        "primary_window": [
                            "used_percent": 55,
                            "reset_after_seconds": 5_400
                        ]
                    ]
                ]]
            ]),
            client: .codex,
            now: now
        )
        XCTAssertEqual(malformed.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertNotNil(malformed.lunaReserve)
        XCTAssertNil(malformed.bankedReset)
        XCTAssertFalse(malformed.bankedResetNeedsCreditList)

        let countOnly = try OfficialQuotaResponseParser.parse(
            object: standardCodexUsage(extra: [
                "rate_limit_reset_credits": [
                    "available_count": 2
                ]
            ]),
            client: .codex,
            now: now
        )
        XCTAssertEqual(countOnly.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertNil(countOnly.bankedReset)
        XCTAssertTrue(countOnly.bankedResetNeedsCreditList)

        let emptyCredits = try OfficialQuotaResponseParser.parse(
            object: standardCodexUsage(extra: [
                "rate_limit_reset_credits": [
                    "available_count": 2,
                    "credits": []
                ]
            ]),
            client: .codex,
            now: now
        )
        XCTAssertEqual(emptyCredits.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertNil(emptyCredits.bankedReset)
        XCTAssertTrue(emptyCredits.bankedResetNeedsCreditList)
    }

    func testCodexBankedResetKeepsCardsWithoutExpiryLastAndDropsRedeemedOrExpired() throws {
        let dated = Date(timeIntervalSince1970: 1_700_086_400)
        let output = try OfficialQuotaResponseParser.parse(
            object: standardCodexUsage(extra: [
                "rate_limit_reset_credits": [
                    "available_count": 4,
                    "credits": [
                        [
                            "id": "undated",
                            "reset_type": "codex_rate_limits",
                            "status": "available"
                        ],
                        [
                            "id": "dated",
                            "reset_type": "codex_rate_limits",
                            "status": "available",
                            "expires_at": "2023-11-15T22:13:20Z"
                        ],
                        [
                            "id": "redeemed",
                            "reset_type": "codex_rate_limits",
                            "status": "redeemed",
                            "expires_at": "2023-11-16T22:13:20Z"
                        ],
                        [
                            "id": "expired",
                            "reset_type": "codex_rate_limits",
                            "status": "available",
                            "expires_at": 1_699_999_999
                        ]
                    ]
                ]
            ]),
            client: .codex,
            now: now
        )

        let bankedReset = try XCTUnwrap(output.bankedReset)
        XCTAssertEqual(bankedReset.availableCount, 2)
        XCTAssertEqual(bankedReset.cards.map(\.id), ["dated", "undated"])
        XCTAssertEqual(bankedReset.cards[0].expiresAt, dated)
        XCTAssertEqual(bankedReset.cards[0].expiresText, expectedBankedResetExpiresText(dated))
        XCTAssertEqual(
            bankedReset.cards[0].remainingText,
            CodexBankedResetFormatting.remaining(until: dated, now: now)?.text
        )
        XCTAssertFalse(bankedReset.cards[0].remainingIsWarning)
        XCTAssertNil(bankedReset.cards[1].expiresAt)
        XCTAssertNil(bankedReset.cards[1].expiresText)
        XCTAssertNil(bankedReset.cards[1].remainingText)
        XCTAssertFalse(bankedReset.cards[1].remainingIsWarning)
    }

    func testClaudeOfficialQuotaIgnoresBankedResetCredits() throws {
        let output = try OfficialQuotaResponseParser.parse(
            object: [
                "seven_day": [
                    "utilization": "12.5",
                    "resets_at": "2023-11-15T00:13:20Z"
                ],
                "rate_limit_reset_credits": [
                    "available_count": 2,
                    "credits": [[
                        "id": "RateLimitResetCredit_claude",
                        "reset_type": "codex_rate_limits",
                        "status": "available",
                        "expires_at": "2023-11-16T22:13:20Z"
                    ]]
                ]
            ],
            client: .claude,
            now: now
        )
        XCTAssertEqual(output.remaining, 87.5, accuracy: 0.000001)
        XCTAssertNil(output.bankedReset)
        XCTAssertFalse(output.bankedResetNeedsCreditList)
        XCTAssertNil(output.lunaReserve)
    }

    func testBankedResetCreditListParserAcceptsStandaloneCreditsPayload() throws {
        let expiresAt = Date(timeIntervalSince1970: 1_700_086_400)
        let bankedReset = try XCTUnwrap(
            OfficialQuotaResponseParser.parseBankedResetCredits(
                object: [
                    "available_count": 1,
                    "credits": [[
                        "id": "RateLimitResetCredit_list",
                        "reset_type": "codex_rate_limits",
                        "status": "available",
                        "expires_at": "2023-11-15T22:13:20Z",
                        "title": "One free rate limit reset"
                    ]]
                ],
                now: now
            )
        )
        XCTAssertEqual(bankedReset.availableCount, 1)
        XCTAssertEqual(bankedReset.cards[0].titleText, tr(.keyCodexBankedResetFullResetTitle))
        XCTAssertEqual(bankedReset.cards[0].windowText, tr(.keyCodexBankedResetFullResetWindow))
        XCTAssertEqual(bankedReset.cards[0].expiresAt, expiresAt)
        XCTAssertEqual(
            bankedReset.cards[0].remainingText,
            CodexBankedResetFormatting.remaining(until: expiresAt, now: now)?.text
        )
        XCTAssertNil(
            OfficialQuotaResponseParser.parseBankedResetCredits(
                data: Data("{invalid".utf8),
                now: now
            )
        )
        let emptyList = try XCTUnwrap(
            OfficialQuotaResponseParser.parseBankedResetCredits(
                object: [
                    "available_count": 0,
                    "credits": []
                ],
                now: now
            )
        )
        XCTAssertEqual(emptyList.availableCount, 0)
        XCTAssertTrue(emptyList.cards.isEmpty)
    }

    func testCodexResetForecastParserReadsRoundedPercentsIndependently() {
        let parsed = CodexResetForecastParser.parse(data: Self.codexResetIssueJSON)
        XCTAssertEqual(parsed.probability24h, .percent(24))
        XCTAssertEqual(parsed.probability48h, .percent(42))
        XCTAssertEqual(parsed.confidence, .low)
        XCTAssertEqual(
            parsed.updatedAt,
            ResponseParsingSupport.timestampDate("2026-09-13T14:35:22.017Z")
        )
        XCTAssertFalse(parsed.isCached)
        XCTAssertTrue(parsed.hasAnyValue)
        XCTAssertEqual(CodexResetForecastParser.websiteURL.host, "codex-reset.com")
        XCTAssertEqual(CodexResetForecastParser.forecastURL.path, "/api/forecast")
        XCTAssertEqual(CodexResetProbability.unavailable.displayText, "--%")
        XCTAssertEqual(CodexResetProbability.percent(75).displayText, "75%")
        XCTAssertEqual(CodexResetConfidence.unavailable.displayText(), "--")
        XCTAssertEqual(
            CodexResetConfidence.unknown("experimental").displayText(language: .simplifiedChinese),
            "未知"
        )
        XCTAssertEqual(
            CodexResetConfidence.low.displayText(language: .simplifiedChinese),
            "低"
        )

        let missing24 = CodexResetForecastParser.parse(
            data: Data(#"{"probabilities":{"rounded_48h":42},"confidence":"low"}"#.utf8)
        )
        XCTAssertEqual(missing24.probability24h, .unavailable)
        XCTAssertEqual(missing24.probability48h, .percent(42))
        XCTAssertEqual(missing24.confidence, .low)

        let unknownConfidence = CodexResetForecastParser.parse(
            data: Data(#"{"probabilities":{"rounded_24h":10,"rounded_48h":20},"confidence":"experimental"}"#.utf8)
        )
        XCTAssertEqual(unknownConfidence.confidence, .unknown("experimental"))
        XCTAssertNotEqual(unknownConfidence.confidence, .high)

        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data(#"{"forecast":{"score":75}}"#.utf8)),
            .unavailable
        )
        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data(#"{"probabilities":{"rounded_24h":101}}"#.utf8)).probability24h,
            .unavailable
        )
        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data(#"{"probabilities":{"rounded_24h":true}}"#.utf8)).probability24h,
            .unavailable
        )
        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data(#"{"probabilities":{"raw_24h":0.24}}"#.utf8)).probability24h,
            .unavailable
        )
        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data(#"{"signal_score":80}"#.utf8)),
            .unavailable
        )
        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data("{invalid".utf8)),
            .unavailable
        )
        let noteOnly = CodexResetForecastParser.parse(
            data: Data(#"{"confidence_note":"Experimental","hint_copy":"english"}"#.utf8)
        )
        XCTAssertEqual(noteOnly, .unavailable)
        XCTAssertFalse(noteOnly.hasAnyValue)
    }

    func testCodexResetForecastParserReadsOfficialSignalIndependentlyOfOrdinaryForecast() {
        let ordinary = CodexResetForecastParser.parse(
            data: Data(#"{"probabilities":{"rounded_24h":20,"rounded_48h":35,"signal_percent":71,"commitment":0.72},"signal_score":{"value":73}}"#.utf8)
        )
        XCTAssertNil(ordinary.officialSignal)
        XCTAssertEqual(ordinary.probability24h, .percent(20))
        XCTAssertEqual(ordinary.probability48h, .percent(35))
        XCTAssertEqual(ordinary.menuProbabilityPresentation, .ordinary(.percent(20)))
        XCTAssertTrue(ordinary.showsOrdinaryForecastMetrics)
        XCTAssertEqual(ordinary.menuPrimaryDisplayText(language: .english), "20%")

        let nullSignal = CodexResetForecastParser.parse(
            data: Data(#"{"official_signal":null,"probabilities":{"rounded_24h":20,"rounded_48h":35,"signal_percent":71}}"#.utf8)
        )
        XCTAssertNil(nullSignal.officialSignal)
        XCTAssertEqual(nullSignal.menuProbabilityPresentation, .ordinary(.percent(20)))

        let scored = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"score":{"value":71,"base":74}},"probabilities":{"rounded_24h":20,"rounded_48h":35,"signal_percent":72,"commitment":0.73,"commitment_floor_percent":75},"signal_score":{"value":76}}
            """#.utf8)
        )
        XCTAssertEqual(scored.officialSignal?.probability, .percent(71))
        XCTAssertEqual(scored.probability24h, .percent(20))
        XCTAssertEqual(scored.probability48h, .percent(35))
        XCTAssertEqual(scored.menuProbabilityPresentation, .strongSignal(.percent(71)))
        XCTAssertFalse(scored.showsOrdinaryForecastMetrics)
        XCTAssertEqual(scored.menuPrimaryDisplayText(language: .english), "71%")
        XCTAssertNotEqual(scored.officialSignal?.probability, .percent(20))
        XCTAssertNotEqual(scored.officialSignal?.probability, .percent(83))
        XCTAssertNotEqual(scored.officialSignal?.probability, .percent(93))

        let signalPercent = CodexResetForecastParser.parse(
            data: Data(#"{"official_signal":{},"probabilities":{"rounded_24h":20,"rounded_48h":35,"signal_percent":72,"commitment":0.73}}"#.utf8)
        )
        XCTAssertEqual(signalPercent.officialSignal?.probability, .percent(72))
        XCTAssertEqual(signalPercent.menuPrimaryDisplayText(language: .english), "72%")

        let commitment = CodexResetForecastParser.parse(
            data: Data(#"{"official_signal":{"tweet_id":"1"},"probabilities":{"rounded_24h":20,"rounded_48h":35,"commitment":0.73}}"#.utf8)
        )
        XCTAssertEqual(commitment.officialSignal?.probability, .percent(73))
        XCTAssertEqual(commitment.officialSignal?.episodeKey, "tweet_id:1")

        let missingProbability = CodexResetForecastParser.parse(
            data: Data(#"{"official_signal":{"tweet_id":"1","summary":"reset"},"probabilities":{"rounded_24h":20,"rounded_48h":35}}"#.utf8)
        )
        XCTAssertEqual(missingProbability.officialSignal?.probability, .unavailable)
        XCTAssertEqual(missingProbability.officialSignal?.episodeKey, "tweet_id:1")
        XCTAssertEqual(missingProbability.probability24h, .percent(20))
        XCTAssertEqual(
            missingProbability.menuProbabilityPresentation,
            .strongSignal(.unavailable)
        )
        XCTAssertEqual(
            missingProbability.menuPrimaryDisplayText(language: .simplifiedChinese),
            "高概率"
        )
        XCTAssertEqual(
            missingProbability.menuPrimaryDisplayText(language: .english),
            "High Prob."
        )
        XCTAssertNotEqual(missingProbability.menuPrimaryDisplayText(), "20%")
        XCTAssertNotEqual(missingProbability.menuPrimaryDisplayText(), "83%")
        XCTAssertNotEqual(missingProbability.menuPrimaryDisplayText(), "93%")

        let relocated = CodexResetForecastParser.parse(
            data: Data(#"{"official_signal":{"mystery":93},"probabilities":{"rounded_24h":20}}"#.utf8)
        )
        XCTAssertEqual(relocated.officialSignal?.probability, .unavailable)
        XCTAssertNotEqual(relocated.officialSignal?.probability, .percent(93))
        XCTAssertTrue(relocated.hasAnyValue)
        XCTAssertNil(relocated.officialSignal?.targetAt)
        XCTAssertEqual(
            relocated.officialHintText(language: .simplifiedChinese),
            "官方重置提示 · 暂无具体时间点"
        )
        XCTAssertEqual(
            relocated.officialHintText(language: .english),
            "Official reset hint · No specific time"
        )
    }

    func testCodexResetSummaryFallbackMatchesOctober25SiteCountdown() throws {
        // Oct 25 live public API: announced signal with window=null and a
        // "By midnight PST" summary. The site showed 03:00 EDT (07:00 UTC).
        let published = "2026-10-25T03:40:04.000Z"
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T05:00:00Z"))
        let deadline = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T07:00:00Z"))
        let forecast = CodexResetForecastParser.parse(
            data: Data(#"""
            {
              "mode":"announced",
              "probabilities":{"rounded_24h":39,"rounded_48h":63,"signal_percent":83},
              "official_signal":{
                "tweet_id":"2114200291319124163",
                "summary":"By midnight PST",
                "at":"2026-10-25T03:40:04.000Z",
                "window":null
              }
            }
            """#.utf8),
            now: now
        )
        XCTAssertEqual(forecast.officialSignal?.episodeKey, "tweet_id:2114200291319124163")
        XCTAssertEqual(forecast.officialSignal?.publishedAt, ResponseParsingSupport.timestampDate(published))
        XCTAssertEqual(forecast.officialSignal?.targetAt, deadline)
        XCTAssertEqual(forecast.officialSignal?.windowKind, .deadline)
        XCTAssertEqual(forecast.officialSignal?.probability, .percent(83))
        XCTAssertEqual(forecast.remainingCountdownSeconds(now: now), 7_200)
        XCTAssertTrue(forecast.showsOfficialWindowDeadlineProgress)
        XCTAssertEqual(forecast.menuPrimaryDisplayText(language: .english, now: now), "2h0m")
        XCTAssertFalse(forecast.isOfficialResetConfirmed)

        let afterDeadline = now.addingTimeInterval(4 * 60 * 60)
        let expired = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"summary":"By midnight PST",
              "at":"2026-10-25T03:40:04.000Z","window":null},
              "probabilities":{"signal_percent":83}}
            """#.utf8),
            now: afterDeadline
        )
        XCTAssertEqual(expired.officialSignal?.targetAt, deadline)
        XCTAssertEqual(expired.remainingCountdownSeconds(now: afterDeadline), 0)
        XCTAssertEqual(expired.menuPrimaryDisplayText(language: .english, now: afterDeadline), "0m")
        XCTAssertFalse(expired.isOfficialResetConfirmed)
    }

    func testCodexResetSummaryFallbackHandlesHistoricalTimingAndDST() throws {
        func parsed(_ summary: String, at: String) -> CodexResetForecast {
            CodexResetForecastParser.parse(
                data: Data(#"""
                {"official_signal":{"summary":"\#(summary)","at":"\#(at)","window":null},
                  "probabilities":{"signal_percent":83}}
                """#.utf8)
            )
        }
        func date(_ iso: String) -> Date {
            // Intentionally fail loudly if a test fixture has an invalid date.
            ResponseParsingSupport.timestampDate(iso)!
        }

        XCTAssertEqual(
            parsed("By midnight PST", at: "2026-01-13T03:40:04Z").officialSignal?.targetAt,
            date("2026-01-13T08:00:00Z"),
            "PST winter midnight is UTC-8, unlike October's daylight time"
        )
        XCTAssertEqual(
            parsed("Landing tomorrow before 10am PST", at: "2026-10-23T04:47:34Z").officialSignal?.targetAt,
            date("2026-10-23T17:00:00Z")
        )
        XCTAssertEqual(
            parsed("By 10:30 AM PT tomorrow", at: "2026-10-23T04:47:34Z").officialSignal?.targetAt,
            date("2026-10-23T17:30:00Z")
        )
        XCTAssertEqual(
            parsed("Landing within an hour", at: "2026-07-21T16:47:15Z").officialSignal?.targetAt,
            date("2026-07-21T17:47:15Z")
        )
        XCTAssertEqual(
            parsed("Should land over next 30 minutes", at: "2026-07-11T05:54:25Z").officialSignal?.targetAt,
            date("2026-07-11T06:24:25Z")
        )
        XCTAssertEqual(
            parsed("Full reset within a few hours", at: "2026-06-26T23:39:48Z").officialSignal?.targetAt,
            date("2026-06-27T02:39:48Z")
        )
        XCTAssertEqual(
            parsed("Another one will come later today", at: "2026-07-10T17:59:43Z").officialSignal?.targetAt,
            date("2026-07-11T07:00:00Z").addingTimeInterval(-0.001)
        )
        XCTAssertEqual(
            parsed("By EOD PST", at: "2026-10-23T04:47:34Z").officialSignal?.targetAt,
            date("2026-10-23T07:00:00Z").addingTimeInterval(-0.001)
        )
    }

    func testCodexResetSummaryFallbackNeverOverridesExplicitDeadlineOrGuesses() throws {
        let deadline = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T08:30:00Z"))
        let explicit = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"summary":"By midnight PST","at":"2026-10-25T03:40:04Z",
              "window":{"target_kind":"deadline","target_at":"2026-10-25T08:30:00Z"}},
              "probabilities":{"signal_percent":83}}
            """#.utf8)
        )
        XCTAssertEqual(explicit.officialSignal?.targetAt, deadline)
        XCTAssertEqual(explicit.officialSignal?.windowKind, .deadline)

        for summary in [
            "Soon", "Today maybe", "next week", "Perhaps by midnight PST",
            "By midnight UTC", "Before 13pm PST tomorrow", "By 10 AM tomorrow",
            "We already reset", "Within an indefinite period"
        ] {
            let payload = Data(#"""
            {"official_signal":{"summary":"\#(summary)","at":"2026-10-25T03:40:04Z","window":null},
              "probabilities":{"signal_percent":83}}
            """#.utf8)
            let result = CodexResetForecastParser.parse(data: payload)
            XCTAssertNil(result.officialSignal?.targetAt, "must not invent time for: \(summary)")
            XCTAssertEqual(result.menuPrimaryDisplayText(language: .english), "83%")
        }

        let missingPublishedAt = CodexResetForecastParser.parse(
            data: Data(#"{"official_signal":{"summary":"By midnight PST","window":null}}"#.utf8)
        )
        XCTAssertNil(missingPublishedAt.officialSignal?.targetAt)

        let noActiveSignal = CodexResetForecastParser.parse(
            data: Data(#"{"official_signal":null,"probabilities":{"signal_percent":83}}"#.utf8)
        )
        XCTAssertNil(noActiveSignal.officialSignal)
    }

    func testCodexResetForecastParserUsesLiveTargetAtAndKeepsExpiredDeadline() throws {
        // Regression for the Oct 23 public /api/forecast schema. The live API
        // uses window.target_at/end_at, not the historical at/deadline/target.
        let deadline = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T17:00:00Z"))
        let observedAt = deadline.addingTimeInterval(-25 * 60)
        let payload = Data(#"""
        {
          "mode":"announced",
          "updated_at":"2026-10-23T16:13:52.692Z",
          "probabilities":{"rounded_24h":32,"rounded_48h":53,"signal_percent":93},
          "official_signal":{
            "tweet_id":"2113492502355562875",
            "at":"2026-10-23T04:47:34.000Z",
            "window":{
              "label":"by 10 AM PT on Oct 23",
              "start_at":"2026-10-23T04:47:34.000Z",
              "end_at":"2026-10-23T17:00:00.000Z",
              "target_kind":"deadline",
              "target_at":"2026-10-23T17:00:00.000Z"
            }
          }
        }
        """#.utf8)
        let forecast = CodexResetForecastParser.parse(data: payload, now: observedAt)
        XCTAssertEqual(forecast.officialSignal?.episodeKey, "tweet_id:2113492502355562875")
        XCTAssertEqual(forecast.officialSignal?.targetAt, deadline)
        XCTAssertEqual(forecast.officialSignal?.windowKind, .deadline)
        XCTAssertEqual(forecast.remainingCountdownSeconds(now: observedAt), 25 * 60)
        XCTAssertEqual(forecast.menuPrimaryDisplayText(language: .english, now: observedAt), "25m")
        XCTAssertEqual(forecast.officialSignal?.probability, .percent(93))
        XCTAssertNotNil(forecast.officialCountdownProgressSpan())

        let afterDeadline = deadline.addingTimeInterval(120)
        let expired = CodexResetForecastParser.parse(data: payload, now: afterDeadline)
        XCTAssertEqual(expired.officialSignal?.targetAt, deadline)
        XCTAssertEqual(expired.remainingCountdownSeconds(now: afterDeadline), 0)
        XCTAssertEqual(expired.menuPrimaryDisplayText(language: .english, now: afterDeadline), "0m")
        XCTAssertFalse(expired.isOfficialResetConfirmed)
    }

    func testCodexResetForecastParserAcceptsRangeEndWhenTargetAtMissing() throws {
        let deadline = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T17:00:00Z"))
        let now = deadline.addingTimeInterval(-15 * 60)
        let forecast = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"tweet_id":"range","window":{
              "start_at":"2026-10-23T04:47:34.000Z",
              "end_at":"2026-10-23T17:00:00.000Z"
            }},"probabilities":{"rounded_24h":32}}
            """#.utf8),
            now: now
        )
        XCTAssertEqual(forecast.officialSignal?.targetAt, deadline)
        XCTAssertEqual(forecast.officialSignal?.windowKind, .range)
        XCTAssertEqual(forecast.menuPrimaryDisplayText(language: .english, now: now), "15m")

        let noDeadline = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"window":{"start_at":"2026-10-23T04:47:34.000Z",
              "label":"later today"}},"probabilities":{"rounded_24h":32}}
            """#.utf8),
            now: now
        )
        XCTAssertNil(noDeadline.officialSignal?.targetAt)
        XCTAssertNil(noDeadline.officialSignal?.windowKind)
    }

    func testCodexResetForecastParserReadsOfficialSignalWindowAsFutureInstant() throws {
        let future = now.addingTimeInterval(3_665)
        let past = now.addingTimeInterval(-120)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let futureISO = iso.string(from: future)
        let pastISO = iso.string(from: past)
        let futureUnix = Int(future.timeIntervalSince1970)

        let noWindow = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"score":{"value":71},"window":null,"at":"\#(futureISO)"},"probabilities":{"rounded_24h":20,"rounded_48h":35},"time_window":{"start_hour":23,"end_hour":2},"last_reset_at":"\#(futureISO)","context":{"reset_at":"\#(futureISO)"}}
            """#.utf8),
            now: now
        )
        XCTAssertEqual(noWindow.officialSignal?.probability, .percent(71))
        XCTAssertNil(noWindow.officialSignal?.targetAt)
        XCTAssertEqual(noWindow.officialSignal?.publishedAt, future)
        XCTAssertEqual(noWindow.remainingCountdownSeconds(now: now), nil)
        XCTAssertNil(noWindow.officialCountdownProgressSpan())
        XCTAssertNil(noWindow.officialCountdownRemainingFraction(now: now))
        XCTAssertEqual(
            noWindow.officialHintText(language: .simplifiedChinese),
            "官方重置提示 · 暂无具体时间点"
        )
        XCTAssertEqual(noWindow.menuPrimaryDisplayText(language: .english, now: now), "71%")
        XCTAssertFalse(noWindow.showsOrdinaryForecastMetrics)

        let missingWindow = CodexResetForecastParser.parse(
            data: Data(#"{"official_signal":{"score":{"value":71}},"probabilities":{"rounded_24h":20}}"#.utf8),
            now: now
        )
        XCTAssertNil(missingWindow.officialSignal?.targetAt)
        XCTAssertNil(missingWindow.officialSignal?.publishedAt)
        XCTAssertEqual(
            missingWindow.officialHintText(language: .simplifiedChinese),
            "官方重置提示 · 暂无具体时间点"
        )

        let isoWindow = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"score":{"value":71},"window":"\#(futureISO)","at":"\#(pastISO)"},"probabilities":{"rounded_24h":20,"rounded_48h":35}}
            """#.utf8),
            now: now
        )
        XCTAssertEqual(isoWindow.remainingCountdownSeconds(now: now), 3_665)
        XCTAssertEqual(isoWindow.officialSignal?.publishedAt, past)
        XCTAssertEqual(isoWindow.officialSignal?.targetAt, future)
        XCTAssertNil(isoWindow.officialHintText())
        XCTAssertEqual(
            try XCTUnwrap(isoWindow.officialCountdownElapsedFraction(now: past)),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(isoWindow.officialCountdownRemainingFraction(now: past)),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(isoWindow.officialCountdownElapsedFraction(now: future)),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(isoWindow.officialCountdownRemainingFraction(now: future)),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(isoWindow.remainingCountdownMinutes(now: now), 61)
        XCTAssertEqual(isoWindow.menuPrimaryDisplayText(now: now), "1h1m")
        XCTAssertNotEqual(isoWindow.menuPrimaryDisplayText(now: now), "71%")

        let unixWindow = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"score":{"value":72},"window":\#(futureUnix)},"probabilities":{"rounded_24h":20}}
            """#.utf8),
            now: now
        )
        XCTAssertEqual(unixWindow.remainingCountdownSeconds(now: now), 3_665)
        XCTAssertNil(unixWindow.officialSignal?.publishedAt)
        XCTAssertNil(unixWindow.officialCountdownProgressSpan())
        XCTAssertNil(unixWindow.officialCountdownRemainingFraction(now: now))
        XCTAssertEqual(
            unixWindow.officialHintText(language: .simplifiedChinese),
            "官方重置提示 · 具体时间点"
        )

        let nestedDeadline = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"score":{"value":73},"window":{"deadline":\#(futureUnix)}},"probabilities":{"rounded_24h":20}}
            """#.utf8),
            now: now
        )
        XCTAssertEqual(nestedDeadline.remainingCountdownSeconds(now: now), 3_665)

        let nestedTarget = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"window":{"target":"\#(futureISO)"},"at":"\#(pastISO)"},"probabilities":{"rounded_24h":20,"signal_percent":74}}
            """#.utf8),
            now: now
        )
        XCTAssertEqual(nestedTarget.remainingCountdownSeconds(now: now), 3_665)
        XCTAssertEqual(nestedTarget.officialSignal?.probability, .percent(74))
        XCTAssertEqual(nestedTarget.officialSignal?.publishedAt, past)
        XCTAssertNotNil(nestedTarget.officialCountdownProgressSpan())

        let hourRangeWindow = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"score":{"value":71},"window":{"start_hour":23,"end_hour":2,"label":"11 PM - 2 AM","timezone":"UTC"}},"probabilities":{"rounded_24h":20}}
            """#.utf8),
            now: now
        )
        XCTAssertNil(hourRangeWindow.officialSignal?.targetAt)
        XCTAssertEqual(
            hourRangeWindow.officialHintText(language: .simplifiedChinese),
            "官方重置提示 · 暂无具体时间点"
        )

        let pastWindow = CodexResetForecastParser.parse(
            data: Data(#"""
            {"official_signal":{"score":{"value":71},"window":"\#(pastISO)"},"probabilities":{"rounded_24h":20}}
            """#.utf8),
            now: now
        )
        XCTAssertNil(pastWindow.officialSignal?.targetAt)
        XCTAssertEqual(
            pastWindow.officialHintText(language: .simplifiedChinese),
            "官方重置提示 · 暂无具体时间点"
        )
        XCTAssertEqual(pastWindow.menuPrimaryDisplayText(language: .english, now: now), "71%")

        let ordinary = CodexResetForecastParser.parse(
            data: Data(#"""
            {"probabilities":{"rounded_24h":20,"rounded_48h":35},"time_window":{"start_hour":23,"end_hour":2},"last_reset_at":"\#(futureISO)","context":{"reset_at":"\#(futureISO)"}}
            """#.utf8),
            now: now
        )
        XCTAssertNil(ordinary.officialSignal)
        XCTAssertNil(ordinary.officialHintText())
        XCTAssertTrue(ordinary.showsOrdinaryForecastMetrics)
        XCTAssertEqual(ordinary.menuPrimaryDisplayText(now: now), "20%")
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

    private func standardCodexUsage(extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 20,
                    "limit_window_seconds": 18_000,
                    "reset_after_seconds": 3_600
                ],
                "secondary_window": [
                    "used_percent": 55,
                    "limit_window_seconds": 604_800,
                    "reset_after_seconds": 5_400
                ]
            ]
        ]
        extra.forEach { object[$0.key] = $0.value }
        return object
    }

    private func expectedBankedResetExpiresText(_ date: Date) -> String {
        CodexBankedResetFormatting.expiryText(for: date, relativeTo: now) ?? ""
    }
}
