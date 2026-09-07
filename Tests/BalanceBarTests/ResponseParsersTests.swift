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

    func testCodexBankedResetHidesMissingZeroOrUnusableCreditsWithoutFailingQuota() throws {
        let missing = try OfficialQuotaResponseParser.parse(
            object: standardCodexUsage(),
            client: .codex,
            now: now
        )
        XCTAssertEqual(missing.windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertNil(missing.bankedReset)
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
        XCTAssertNil(zeroCount.bankedReset)
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
    }

    func testCodexResetForecastParserReadsScoreAndFallsBack() {
        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data(#"{"forecast":{"score":75}}"#.utf8)),
            .percent(75)
        )
        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data(#"{"forecast":{"score":24.9}}"#.utf8)),
            .percent(24)
        )
        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data(#"{"forecast":{"score":101}}"#.utf8)),
            .unavailable
        )
        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data(#"{"forecast":{}}"#.utf8)),
            .unavailable
        )
        XCTAssertEqual(
            CodexResetForecastParser.parse(data: Data("{invalid".utf8)),
            .unavailable
        )
        XCTAssertEqual(CodexResetProbability.unavailable.displayText, "--%")
        XCTAssertEqual(CodexResetProbability.percent(75).displayText, "75%")
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
