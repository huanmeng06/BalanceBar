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

    /// Extract only an absolute API timestamp. Relative seconds are
    /// deliberately rejected here so a rounded countdown cannot be turned
    /// into a fabricated wall-clock reset time.
    static func resetDate(_ value: Any?, now: Date = Date()) -> Date? {
        let date: Date?
        if let number = numberValue(value) {
            guard number.isFinite else { return nil }
            let timestamp = number > 10_000_000_000 ? number / 1_000 : number
            guard timestamp > 1_000_000_000, timestamp < 10_000_000_000 else { return nil }
            date = Date(timeIntervalSince1970: timestamp)
        } else if let text = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty {
            if let number = Double(text) {
                return resetDate(number, now: now)
            }
            let formatter = ISO8601DateFormatter()
            date = formatter.date(from: text) ?? {
                formatter.formatOptions.insert(.withFractionalSeconds)
                return formatter.date(from: text)
            }()
        } else {
            return nil
        }

        guard let date, date > now else { return nil }
        return date
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
        let windows: [OfficialQuotaWindow]
        let lunaReserve: LunaReserveQuota?

        init(windows: [OfficialQuotaWindow], lunaReserve: LunaReserveQuota? = nil) {
            self.windows = windows
            self.lunaReserve = lunaReserve
        }

        private var representative: OfficialQuotaWindow? {
            windows.first(where: { $0.kind == .sevenDay })
                ?? windows.first(where: { $0.kind == .fiveHour })
                ?? windows.first
        }

        var representativeWindow: OfficialQuotaWindow? { representative }

        // Keep the existing single-window accessors for quick-switch summaries
        // and callers that still need one representative quota. The weekly
        // window remains preferred, preserving the compact status text and
        // Dashboard behavior while the menu card consumes `windows`.
        var remaining: Double { representative?.remaining ?? 0 }
        var label: String { representative?.label ?? tr(.keyResponseParsersQuota) }
        var daysText: String { representative?.daysText ?? tr(.keyResponseParsersQuota2) }
        var reset: String? { representative?.reset }
        var resetAt: Date? { representative?.resetAt }
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
                    windows: [OfficialQuotaWindow(
                        kind: .other,
                        remaining: max(0, min(100, 100 - utilization)),
                        label: label,
                        daysText: daysText,
                        reset: ResponseParsingSupport.resetDescription(window["resets_at"], now: now),
                        durationSeconds: nil
                    )]
                )
            }
            throw ResponseParserError.unsupportedFormat
        }

        let limits = (object["rate_limit"] as? [String: Any]) ?? object
        let windows = limits.values.compactMap { $0 as? [String: Any] }.compactMap { window in
            Self.parseCodexWindow(window, now: now)
        }
        guard !windows.isEmpty else {
            throw ResponseParserError.unsupportedFormat
        }
        return Output(
            windows: windows.sorted(by: Self.windowSort),
            lunaReserve: Self.parseCodexLunaReserve(from: object, now: now)
        )
    }

    private static func parseCodexWindow(
        _ window: [String: Any],
        now: Date
    ) -> OfficialQuotaWindow? {
        guard let used = ResponseParsingSupport.numberValue(window["used_percent"]) else {
            return nil
        }
        let duration = ResponseParsingSupport.numberValue(window["limit_window_seconds"])

        let kind: OfficialQuotaWindow.Kind
        if let duration, abs(duration - 5 * 3_600) < 1 {
            kind = .fiveHour
        } else if let duration, abs(duration - 7 * 86_400) < 1 {
            kind = .sevenDay
        } else {
            kind = .other
        }

        let label: String
        let daysText: String
        switch kind {
        case .fiveHour:
            label = tr(.keyResponseParsers5HourQuota)
            daysText = tr(.keyResponseParsers5Hours)
        case .sevenDay:
            label = tr(.keyResponseParsers7DayQuota2)
            daysText = tr(.keyResponseParsers7Days4)
        case .other:
            let isWeekly = duration.map { $0 >= 6 * 86_400 } ?? false
            label = isWeekly ? tr(.keyResponseParsers7DayQuota2) : tr(.keyResponseParsersQuota)
            daysText = isWeekly ? tr(.keyResponseParsers7Days4) : tr(.keyResponseParsersQuota2)
        }

        let rawResetAt = window["reset_at"] ?? window["resets_at"]
        let reset = ResponseParsingSupport.resetDescription(window["reset_after_seconds"], now: now)
            ?? ResponseParsingSupport.resetDescription(rawResetAt, now: now)
            ?? ResponseParsingSupport.stringValue(window["reset_description"])
        return OfficialQuotaWindow(
            kind: kind,
            remaining: max(0, min(100, 100 - used)),
            label: label,
            daysText: daysText,
            reset: reset,
            durationSeconds: duration,
            resetAt: ResponseParsingSupport.resetDate(rawResetAt, now: now)
        )
    }

    /// The official Codex response exposes Luna Reserve as a named
    /// additional rate limit. Match both stable identity fields before
    /// presenting it so an unrelated future rate limit cannot be mistaken for
    /// Reserve.
    private static func parseCodexLunaReserve(
        from object: [String: Any],
        now: Date
    ) -> LunaReserveQuota? {
        guard let additionalLimits = object["additional_rate_limits"] as? [[String: Any]],
              let entry = additionalLimits.first(where: { entry in
                  ResponseParsingSupport.stringValue(entry["limit_name"]) == "gpt-reserve"
                      && ResponseParsingSupport.stringValue(entry["metered_feature"]) == "base_model_inference"
              }),
              let rateLimit = entry["rate_limit"] as? [String: Any],
              let allowed = rateLimit["allowed"] as? Bool else {
            return nil
        }

        guard allowed else {
            return LunaReserveQuota(
                status: .unavailable,
                remaining: nil,
                reset: nil
            )
        }

        // The observed official payload uses the primary window. Accept the
        // named secondary window only when the primary one is absent, without
        // merging or averaging the two source windows.
        guard let window = (rateLimit["primary_window"] as? [String: Any])
                ?? (rateLimit["secondary_window"] as? [String: Any]) else {
            return LunaReserveQuota(
                status: .unavailable,
                remaining: nil,
                reset: nil
            )
        }

        let used = ResponseParsingSupport.numberValue(window["used_percent"])
            .flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        let remaining = used.map { max(0, min(100, 100 - $0)) }
        let limitReached = rateLimit["limit_reached"] as? Bool
        guard used != nil || limitReached != nil else {
            return nil
        }
        let status: LunaReserveQuota.Status
        if limitReached == true || remaining == 0 {
            status = .exhausted
        } else if used != nil || limitReached == false {
            status = .available
        } else {
            status = .unavailable
        }

        let rawResetAt = window["reset_at"] ?? window["resets_at"]
        let reset = Self.lunaReserveResetDescription(window, rawResetAt: rawResetAt, now: now)
        return LunaReserveQuota(
            status: status,
            remaining: remaining,
            reset: reset,
            resetAt: ResponseParsingSupport.resetDate(rawResetAt, now: now)
        )
    }

    private static func lunaReserveResetDescription(
        _ window: [String: Any],
        rawResetAt: Any?,
        now: Date
    ) -> String? {
        if let relative = ResponseParsingSupport.numberValue(window["reset_after_seconds"]),
           relative.isFinite,
           relative >= 0 {
            return ResponseParsingSupport.resetDescription(relative, now: now)
        }
        return ResponseParsingSupport.resetDescription(rawResetAt, now: now)
            ?? ResponseParsingSupport.stringValue(window["reset_description"])
    }

    private static func windowSort(
        _ lhs: OfficialQuotaWindow,
        _ rhs: OfficialQuotaWindow
    ) -> Bool {
        if lhs.kind.sortOrder != rhs.kind.sortOrder {
            return lhs.kind.sortOrder < rhs.kind.sortOrder
        }
        return (lhs.durationSeconds ?? 0) > (rhs.durationSeconds ?? 0)
    }
}
