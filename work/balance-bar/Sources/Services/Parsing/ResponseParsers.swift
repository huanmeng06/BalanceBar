import Foundation

enum ResponseParserError: Error, Equatable {
    case invalidJSON
    case unsupportedFormat
}

enum ResponseParsingSupport {
    static func object(from data: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ResponseParserError.invalidJSON
        }
        guard let object = value as? [String: Any] else {
            throw ResponseParserError.unsupportedFormat
        }
        return object
    }

    static func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    static func resetDescription(_ value: Any?, now: Date = Date()) -> String? {
        if let number = numberValue(value) {
            let timestamp = number > 10_000_000_000 ? number / 1_000 : number
            let date = timestamp > 1_000_000_000
                ? Date(timeIntervalSince1970: timestamp)
                : now.addingTimeInterval(timestamp)
            return remainingTime(until: date, now: now)
        }
        guard let text = stringValue(value), !text.isEmpty else { return nil }
        if let number = Double(text) { return resetDescription(number, now: now) }
        if let date = ISO8601DateFormatter().date(from: text) {
            return remainingTime(until: date, now: now)
        }
        return text
    }

    private static func remainingTime(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.down)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}

enum BalanceResponseParser {
    struct Context {
        let isNewAPI: Bool
        let nativeBalanceProvider: NativeBalanceProvider?
        let isRightCode: Bool
        let subscriptionPrefix: String

        init(query: BalanceQuery) {
            isNewAPI = query.isNewAPI
            nativeBalanceProvider = query.nativeBalanceProvider
            isRightCode = query.isRightCode
            subscriptionPrefix = query.subscriptionPrefix
        }

        init(
            isNewAPI: Bool = false,
            nativeBalanceProvider: NativeBalanceProvider? = nil,
            isRightCode: Bool = false,
            subscriptionPrefix: String = "/codex"
        ) {
            self.isNewAPI = isNewAPI
            self.nativeBalanceProvider = nativeBalanceProvider
            self.isRightCode = isRightCode
            self.subscriptionPrefix = subscriptionPrefix
        }
    }

    struct Output: Equatable {
        let amount: Double
        let unit: String
    }

    static func parse(data: Data, query: BalanceQuery) throws -> Output {
        try parse(data: data, context: Context(query: query))
    }

    static func parse(object: [String: Any], query: BalanceQuery) throws -> Output {
        try parse(object: object, context: Context(query: query))
    }

    static func parse(data: Data, context: Context) throws -> Output {
        try parse(object: ResponseParsingSupport.object(from: data), context: context)
    }

    static func parse(object: [String: Any], context: Context) throws -> Output {
        if context.isNewAPI {
            guard
                (object["success"] as? Bool) != false,
                let data = object["data"] as? [String: Any],
                let quota = ResponseParsingSupport.numberValue(data["quota"])
            else { throw ResponseParserError.unsupportedFormat }
            return Output(amount: quota / 500_000, unit: "USD")
        }

        if let native = context.nativeBalanceProvider {
            switch native {
            case .deepSeek:
                let balances = object["balance_infos"] as? [[String: Any]] ?? []
                for balance in balances {
                    if let amount = ResponseParsingSupport.numberValue(balance["total_balance"]) {
                        return Output(
                            amount: amount,
                            unit: ResponseParsingSupport.stringValue(balance["currency"]) ?? "CNY"
                        )
                    }
                }
                throw ResponseParserError.unsupportedFormat
            case .stepFun:
                guard let amount = ResponseParsingSupport.numberValue(object["balance"]) else {
                    throw ResponseParserError.unsupportedFormat
                }
                return Output(amount: amount, unit: "CNY")
            case .siliconFlowCN, .siliconFlowEN:
                guard
                    let data = object["data"] as? [String: Any],
                    let amount = ResponseParsingSupport.numberValue(data["totalBalance"])
                else { throw ResponseParserError.unsupportedFormat }
                return Output(
                    amount: amount,
                    unit: native == .siliconFlowCN ? "CNY" : "USD"
                )
            case .openRouter:
                let data = (object["data"] as? [String: Any]) ?? object
                guard let total = ResponseParsingSupport.numberValue(data["total_credits"]) else {
                    throw ResponseParserError.unsupportedFormat
                }
                let used = ResponseParsingSupport.numberValue(data["total_usage"]) ?? 0
                return Output(amount: total - used, unit: "USD")
            case .novitaAI:
                guard let raw = ResponseParsingSupport.numberValue(object["availableBalance"]) else {
                    throw ResponseParserError.unsupportedFormat
                }
                return Output(amount: raw / 10_000, unit: "USD")
            }
        }

        guard let amount = extractBalance(
            from: object,
            rightCode: context.isRightCode,
            subscriptionPrefix: context.subscriptionPrefix
        ) else { throw ResponseParserError.unsupportedFormat }
        let unit = ResponseParsingSupport.stringValue(object["unit"])
            ?? ResponseParsingSupport.stringValue((object["quota"] as? [String: Any])?["unit"])
            ?? "USD"
        return Output(amount: amount, unit: unit)
    }

    private static func extractBalance(
        from object: [String: Any],
        rightCode: Bool,
        subscriptionPrefix: String
    ) -> Double? {
        if rightCode {
            let cash = ResponseParsingSupport.numberValue(object["balance"]) ?? 0
            let subscriptions = object["subscriptions"] as? [[String: Any]] ?? []
            let subscriptionBalance = subscriptions.reduce(0.0) { total, subscription in
                let prefixes = subscription["available_prefixes"] as? [String] ?? []
                guard prefixes.contains(subscriptionPrefix) else { return total }
                let remaining = ResponseParsingSupport.numberValue(subscription["remaining_quota"]) ?? 0
                let limit = ResponseParsingSupport.numberValue(subscription["total_quota"]) ?? 0
                let resetsToday = (subscription["reset_today"] as? Bool) ?? false
                return total + (resetsToday ? remaining : remaining + limit)
            }
            return cash + subscriptionBalance
        }
        if let direct = ResponseParsingSupport.numberValue(object["remaining"])
            ?? ResponseParsingSupport.numberValue(object["balance"]) {
            return direct
        }
        if let quota = object["quota"] as? [String: Any] {
            return ResponseParsingSupport.numberValue(quota["remaining"])
        }
        return nil
    }
}

enum OfficialQuotaResponseParser {
    struct Output: Equatable {
        let remaining: Double
        let label: String
        let daysText: String
        let reset: String?
    }

    static func parse(
        data: Data,
        client: AssistantClient,
        now: Date = Date()
    ) throws -> Output {
        try parse(
            object: ResponseParsingSupport.object(from: data),
            client: client,
            now: now
        )
    }

    static func parse(
        object: [String: Any],
        client: AssistantClient,
        now: Date = Date()
    ) throws -> Output {
        if client == .claude {
            let tierNames = [
                ("seven_day", tr(.keyResponseParsers7DayQuota), tr(.keyResponseParsers7Days)),
                ("five_hour", tr(.keyResponseParsers5HourQuota), tr(.keyResponseParsers5Hours)),
                ("seven_day_sonnet", tr(.keyResponseParsersSonnet7DayQuota), tr(.keyResponseParsers7Days2)),
                ("seven_day_opus", tr(.keyResponseParsersOpus7DayQuota), tr(.keyResponseParsers7Days3))
            ]
            for (name, label, daysText) in tierNames {
                guard let window = object[name] as? [String: Any],
                      let utilization = ResponseParsingSupport.numberValue(window["utilization"])
                else { continue }
                return Output(
                    remaining: max(0, min(100, 100 - utilization)),
                    label: label,
                    daysText: daysText,
                    reset: ResponseParsingSupport.resetDescription(window["resets_at"], now: now)
                )
            }
            throw ResponseParserError.unsupportedFormat
        }

        let limits = (object["rate_limit"] as? [String: Any]) ?? object
        let primary = limits["primary_window"] as? [String: Any]
        let secondary = limits["secondary_window"] as? [String: Any]
        // Select the longest actual window; CC Switch may expose weekly quota
        // in either primary_window or secondary_window.
        let windows = [primary, secondary].compactMap { $0 }
        guard let chosen = windows.max(by: {
            (ResponseParsingSupport.numberValue($0["limit_window_seconds"]) ?? 0) <
            (ResponseParsingSupport.numberValue($1["limit_window_seconds"]) ?? 0)
        }), let used = ResponseParsingSupport.numberValue(chosen["used_percent"]) else {
            throw ResponseParserError.unsupportedFormat
        }
        let remaining = max(0, min(100, 100 - used))
        let duration = ResponseParsingSupport.numberValue(chosen["limit_window_seconds"]) ?? 0
        let isWeekly = duration >= 6 * 86_400
        let reset = ResponseParsingSupport.resetDescription(chosen["reset_after_seconds"], now: now)
            ?? ResponseParsingSupport.resetDescription(chosen["reset_at"], now: now)
            ?? ResponseParsingSupport.stringValue(chosen["reset_description"])
        return Output(
            remaining: remaining,
            label: isWeekly ? tr(.keyResponseParsers7DayQuota2) : tr(.keyResponseParsersQuota),
            daysText: isWeekly ? tr(.keyResponseParsers7Days4) : tr(.keyResponseParsersQuota2),
            reset: reset
        )
    }
}
