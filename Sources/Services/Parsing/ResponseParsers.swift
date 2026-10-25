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
        if let date = timestampDate(text) {
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

    /// Parse an absolute API timestamp without requiring it to be in the
    /// future. Banked-reset expiry uses this so expired cards can be filtered
    /// instead of being treated as missing dates.
    static func timestampDate(_ value: Any?) -> Date? {
        if let number = numberValue(value) {
            guard number.isFinite else { return nil }
            let timestamp = number > 10_000_000_000 ? number / 1_000 : number
            guard timestamp > 1_000_000_000, timestamp < 10_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        }
        guard let text = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        if let number = Double(text) {
            return timestampDate(number)
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text) ?? {
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: text)
        }()
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
        let bankedReset: CodexBankedReset?
        /// True when Codex usage includes a reset-credits object with a
        /// positive available count but no usable `credits[]`. Callers may
        /// then issue one read-only list GET.
        let bankedResetNeedsCreditList: Bool

        init(
            windows: [OfficialQuotaWindow],
            lunaReserve: LunaReserveQuota? = nil,
            bankedReset: CodexBankedReset? = nil,
            bankedResetNeedsCreditList: Bool = false
        ) {
            self.windows = windows
            self.lunaReserve = lunaReserve
            self.bankedReset = bankedReset
            self.bankedResetNeedsCreditList = bankedResetNeedsCreditList
        }

        private var representative: OfficialQuotaWindow? {
            windows.first(where: { $0.kind == .sevenDay })
                ?? windows.first(where: { $0.kind == .fiveHour })
                ?? windows.first
        }

        var representativeWindow: OfficialQuotaWindow? { representative }

        // Keep the existing single-window accessors for callers that still need
        // one representative quota. The weekly window remains preferred,
        // preserving the legacy compact status text and Dashboard behavior
        // while presentation consumers that support window selection use
        // `windows`.
        var remaining: Double { representative?.remaining ?? 0 }
        var label: String { representative?.label ?? tr(.keyResponseParsersQuota) }
        var daysText: String { representative?.daysText ?? tr(.keyResponseParsersQuota2) }
        var reset: String? { representative?.reset }
        var resetAt: Date? { representative?.resetAt }
    }


    /// One Claude usage window as reported by the API, before any merging.
    struct ClaudeReading {
        let key: String
        let usedPercentage: Double
        /// Absolute reset time as reported, which may already be in the past.
        let resetsAt: Date?
        let window: OfficialQuotaWindow

        /// Stable quota-module window kind for this API key.
        var quotaKind: QuotaWindowKind {
            switch key {
            case "five_hour": return .fiveHour
            case "seven_day": return .sevenDay
            default: return .other(key)
            }
        }
    }

    private struct ClaudeTier {
        let key: String
        let kind: OfficialQuotaWindow.Kind
        let label: String
        let daysText: String
        let duration: Double
    }

    private static func claudeTiers() -> [ClaudeTier] {
        [
            ClaudeTier(key: "five_hour", kind: .fiveHour, label: tr(.keyResponseParsers5HourQuota), daysText: tr(.keyResponseParsers5Hours), duration: 5 * 3_600),
            ClaudeTier(key: "seven_day", kind: .sevenDay, label: tr(.keyResponseParsers7DayQuota), daysText: tr(.keyResponseParsers7Days), duration: 7 * 86_400),
            ClaudeTier(key: "seven_day_sonnet", kind: .other, label: tr(.keyResponseParsersSonnet7DayQuota), daysText: tr(.keyResponseParsers7Days2), duration: 7 * 86_400),
            ClaudeTier(key: "seven_day_opus", kind: .other, label: tr(.keyResponseParsersOpus7DayQuota), daysText: tr(.keyResponseParsers7Days3), duration: 7 * 86_400)
        ]
    }

    private static func claudeWindow(_ tier: ClaudeTier, usedPercentage: Double, resetRaw: Any?, resetAt: Date?, now: Date) -> OfficialQuotaWindow {
        // An unused window (0%) has no `resets_at` yet; like Codex's idle
        // `reset_after_seconds`, it shows the window length. A used window
        // without `resets_at` has an unknown start, so it stays unknown.
        let idleLength = usedPercentage <= 0 ? ResponseParsingSupport.resetDescription(tier.duration, now: now) : nil
        return OfficialQuotaWindow(
            kind: tier.kind,
            remaining: max(0, min(100, 100 - usedPercentage)),
            label: tier.label,
            daysText: tier.daysText,
            reset: ResponseParsingSupport.resetDescription(resetRaw, now: now) ?? idleLength,
            durationSeconds: tier.duration,
            resetAt: resetAt
        )
    }

    /// Parses the Claude usage payload into per-window readings.
    static func claudeReadings(object: [String: Any], now: Date = Date()) -> [ClaudeReading] {
        claudeTiers().compactMap { tier -> ClaudeReading? in
            guard let payload = object[tier.key] else { return nil }
            // An explicit null window / null utilization means the window has not started
            // and reads as 0% used without a reset time. A window that merely lacks the
            // key, or carries a value that is not a usable number, stays unknown instead
            // of inventing a fresh cycle that could wrongly confirm a pending reset.
            let used: Double
            let raw: Any?
            if payload is NSNull {
                used = 0
                raw = nil
            } else if let window = payload as? [String: Any] {
                guard let utilizationValue = window["utilization"] else { return nil }
                if utilizationValue is NSNull {
                    used = 0
                } else {
                    guard let number = ResponseParsingSupport.numberValue(utilizationValue),
                          number.isFinite else { return nil }
                    used = number
                }
                raw = window["resets_at"]
            } else {
                return nil
            }
            return ClaudeReading(
                key: tier.key,
                usedPercentage: max(0, min(100, used)),
                resetsAt: ResponseParsingSupport.timestampDate(raw),
                window: claudeWindow(tier, usedPercentage: used, resetRaw: raw,
                    resetAt: ResponseParsingSupport.resetDate(raw, now: now), now: now))
        }
    }

    static func claudeReadings(data: Data, now: Date = Date()) throws -> [ClaudeReading] {
        let readings = claudeReadings(object: try ResponseParsingSupport.object(from: data), now: now)
        guard !readings.isEmpty else { throw ResponseParserError.unsupportedFormat }
        return readings
    }

    /// Builds the display window for a merged reading of the Claude window `kind`.
    static func claudeWindow(for kind: QuotaWindowKind, usedPercentage: Double, resetsAt: Date?, now: Date = Date()) -> OfficialQuotaWindow? {
        guard let tier = claudeTiers().first(where: { $0.key == kind.rawValue }) else { return nil }
        let future = resetsAt.flatMap { $0 > now ? $0 : nil }
        return claudeWindow(tier, usedPercentage: usedPercentage,
            resetRaw: future.map { $0.timeIntervalSince1970 }, resetAt: future, now: now)
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
            let windows = claudeReadings(object: object, now: now).map(\.window)
            guard !windows.isEmpty else { throw ResponseParserError.unsupportedFormat }
            return Output(windows: windows)
        }

        let limits = (object["rate_limit"] as? [String: Any]) ?? object
        let windows = limits.values.compactMap { $0 as? [String: Any] }.compactMap { window in
            Self.parseCodexWindow(window, now: now)
        }
        guard !windows.isEmpty else {
            throw ResponseParserError.unsupportedFormat
        }
        let bankedResetParse = Self.parseCodexBankedReset(from: object, now: now)
        return Output(
            windows: windows.sorted(by: Self.windowSort),
            lunaReserve: Self.parseCodexLunaReserve(from: object, now: now),
            bankedReset: bankedResetParse.reset,
            bankedResetNeedsCreditList: bankedResetParse.needsCreditList
        )
    }

    static func parseBankedResetCredits(
        data: Data,
        now: Date = Date()
    ) -> CodexBankedReset? {
        guard let object = try? ResponseParsingSupport.object(from: data) else {
            return nil
        }
        return parseBankedResetCredits(object: object, now: now)
    }

    static func parseBankedResetCredits(
        object: [String: Any],
        now: Date = Date()
    ) -> CodexBankedReset? {
        let source = (object["rate_limit_reset_credits"] as? [String: Any]) ?? object
        guard let credits = Self.creditDictionaries(from: source["credits"]) else {
            return nil
        }
        return bankedReset(from: credits, now: now) ?? CodexBankedReset(cards: [])
    }

    private static func parseCodexWindow(
        _ window: [String: Any],
        now: Date
    ) -> OfficialQuotaWindow? {
        guard let used = ResponseParsingSupport.numberValue(window["used_percent"]), used.isFinite else {
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
        let limitReached = rateLimit["limit_reached"] as? Bool
        guard used != nil || limitReached != nil else {
            return nil
        }
        // Reaching the limit is still a valid, available Reserve record. It
        // means the remaining amount is zero, not that the data is unavailable.
        let remaining = used.map { max(0, min(100, 100 - $0)) }
            ?? (limitReached == true ? 0 : nil)

        let rawResetAt = window["reset_at"] ?? window["resets_at"]
        let reset = Self.lunaReserveResetDescription(window, rawResetAt: rawResetAt, now: now)
        return LunaReserveQuota(
            status: .available,
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

    private static func parseCodexBankedReset(
        from object: [String: Any],
        now: Date
    ) -> (reset: CodexBankedReset?, needsCreditList: Bool) {
        guard object["rate_limit_reset_credits"] != nil else {
            return (CodexBankedReset(cards: []), false)
        }
        guard let creditsObject = object["rate_limit_reset_credits"] as? [String: Any] else {
            return (nil, false)
        }
        if let credits = Self.creditDictionaries(from: creditsObject["credits"]),
           let reset = bankedReset(from: credits, now: now) {
            return (reset, false)
        }
        if let count = nonNegativeInt(creditsObject["available_count"]), count > 0 {
            return (nil, true)
        }
        return (CodexBankedReset(cards: []), false)
    }

    private static func creditDictionaries(from value: Any?) -> [[String: Any]]? {
        guard let items = value as? [Any] else { return nil }
        return items.compactMap { $0 as? [String: Any] }
    }

    private static func bankedReset(
        from credits: [[String: Any]],
        now: Date
    ) -> CodexBankedReset? {
        var seenIDs = Set<String>()
        var cards: [CodexBankedResetCard] = []
        for item in credits {
            guard let card = parseBankedResetCard(item, now: now) else { continue }
            if let id = card.id, !id.isEmpty {
                if seenIDs.contains(id) { continue }
                seenIDs.insert(id)
            }
            cards.append(card)
        }
        cards.sort(by: bankedResetCardSort)
        guard !cards.isEmpty else { return nil }
        return CodexBankedReset(cards: cards)
    }

    private static func parseBankedResetCard(
        _ object: [String: Any],
        now: Date
    ) -> CodexBankedResetCard? {
        if let status = ResponseParsingSupport.stringValue(object["status"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty {
            guard status.lowercased() == "available" else { return nil }
        }

        let expiresAt = ResponseParsingSupport.timestampDate(object["expires_at"])
        if let expiresAt, expiresAt <= now {
            return nil
        }

        let resetType = ResponseParsingSupport.stringValue(object["reset_type"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let apiTitle = ResponseParsingSupport.stringValue(object["title"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText: String
        let windowText: String?
        if resetType == "codex_rate_limits" {
            titleText = tr(.keyCodexBankedResetFullResetTitle)
            windowText = tr(.keyCodexBankedResetFullResetWindow)
        } else if let apiTitle, isUserReadableCreditTitle(apiTitle) {
            titleText = apiTitle
            windowText = nil
        } else {
            titleText = tr(.keyCodexBankedResetTitle)
            windowText = nil
        }

        let rawID = ResponseParsingSupport.stringValue(object["id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = CodexBankedResetFormatting.remaining(until: expiresAt, now: now)

        return CodexBankedResetCard(
            id: rawID?.isEmpty == true ? nil : rawID,
            resetType: resetType,
            titleText: titleText,
            windowText: windowText,
            expiresAt: expiresAt,
            expiresText: CodexBankedResetFormatting.expiryText(for: expiresAt, relativeTo: now),
            remainingText: remaining?.text,
            remainingIsWarning: remaining?.isWarning ?? false
        )
    }

    private static func bankedResetCardSort(
        _ lhs: CodexBankedResetCard,
        _ rhs: CodexBankedResetCard
    ) -> Bool {
        switch (lhs.expiresAt, rhs.expiresAt) {
        case let (left?, right?):
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return false
        }
    }

    private static func isUserReadableCreditTitle(_ title: String) -> Bool {
        title.contains(where: { $0.isWhitespace || !$0.isASCII })
            || title.contains(where: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite,
                  doubleValue >= 0,
                  doubleValue == doubleValue.rounded(.towardZero),
                  doubleValue <= Double(Int.max) else {
                return nil
            }
            return Int(doubleValue)
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(trimmed), parsed >= 0 else { return nil }
            return parsed
        }
        return nil
    }
}

enum CodexResetForecastParser {
    static let websiteURL = URL(string: "https://codex-reset.com/")!
    static let forecastURL = URL(string: "https://codex-reset.com/api/forecast")!

    static func parse(data: Data, now: Date = Date()) -> CodexResetForecast {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable
        }
        let probabilities = object["probabilities"] as? [String: Any]
        return CodexResetForecast(
            probability24h: percent(probabilities?["rounded_24h"]),
            probability48h: percent(probabilities?["rounded_48h"]),
            confidence: confidence(object["confidence"]),
            updatedAt: ResponseParsingSupport.timestampDate(object["updated_at"]),
            isCached: false,
            officialSignal: officialSignal(from: object, now: now)
        )
    }

    private static func officialSignal(
        from object: [String: Any],
        now: Date
    ) -> CodexResetOfficialSignal? {
        switch object["official_signal"] {
        case nil, is NSNull:
            return nil
        default:
            let target = officialSignalTarget(from: object, now: now)
            return CodexResetOfficialSignal(
                probability: signalProbability(from: object),
                targetAt: target.targetAt,
                windowKind: target.windowKind,
                publishedAt: officialSignalPublishedAt(from: object),
                episodeKey: officialSignalEpisodeKey(from: object, now: now)
            )
        }
    }

    /// Prefer an upstream event identity; timestamp fallbacks still keep a
    /// changed signal from inheriting the previous episode when the API omits
    /// a dedicated id.
    private static func officialSignalEpisodeKey(
        from object: [String: Any],
        now: Date
    ) -> String? {
        guard let official = object["official_signal"] as? [String: Any] else {
            return nil
        }
        for key in ["episode_id", "signal_id", "tweet_id", "id"] {
            if let value = ResponseParsingSupport.stringValue(official[key]), !value.isEmpty {
                return "\(key):\(value)"
            }
        }
        let publishedAt = officialSignalPublishedAt(from: object)
        let targetAt = officialSignalEpisodeTargetAt(from: object)
        if let publishedAt {
            return "published:\(publishedAt.timeIntervalSince1970)"
        }
        if let targetAt {
            return "target:\(targetAt.timeIntervalSince1970)"
        }
        return nil
    }

    /// Episode identity must remain stable after the countdown target passes;
    /// unlike the UI countdown parser, this fallback accepts past timestamps.
    private static func officialSignalEpisodeTargetAt(from object: [String: Any]) -> Date? {
        guard let official = object["official_signal"] as? [String: Any] else { return nil }
        return absoluteSignalInstant(official["window"])
            ?? ResponseParsingSupport.timestampDate(official["deadline"])
            ?? ResponseParsingSupport.timestampDate(official["target"])
    }

    private static func absoluteSignalInstant(_ value: Any?) -> Date? {
        switch value {
        case let dict as [String: Any]:
            return ResponseParsingSupport.timestampDate(dict["target_at"])
                ?? ResponseParsingSupport.timestampDate(dict["end_at"])
                ?? ResponseParsingSupport.timestampDate(dict["at"])
                ?? ResponseParsingSupport.timestampDate(dict["deadline"])
                ?? ResponseParsingSupport.timestampDate(dict["target"])
        default:
            return ResponseParsingSupport.timestampDate(value)
        }
    }

    /// Explicit absolute targets from the public `official_signal.window`
    /// take precedence over legacy aliases. Keep an expired target while the
    /// signal remains active, so the clock displays 0m instead of reverting to
    /// a probability. Never use the tweet or forecast update time as a target.
    /// A `target_kind=deadline` target or an `end_at`-only range endpoint is
    /// an observation-window boundary, not a guaranteed reset instant; the
    /// returned kind preserves that distinction for countdown labelling.
    private static func officialSignalTarget(
        from object: [String: Any],
        now: Date
    ) -> (targetAt: Date?, windowKind: CodexResetOfficialSignal.WindowKind?) {
        let official = object["official_signal"] as? [String: Any]
        guard let official else { return (nil, nil) }
        if let windowTarget = windowTarget(official["window"], now: now) {
            return windowTarget
        }
        if let deadline = ResponseParsingSupport.resetDate(official["deadline"], now: now) {
            return (deadline, .deadline)
        }
        if let target = ResponseParsingSupport.resetDate(official["target"], now: now) {
            return (target, nil)
        }
        // The public API sometimes identifies an active announcement but omits
        // its structured window. Parse only unambiguous, documented timing
        // phrases as a fallback; never mistake a publication time for a target.
        if let deadline = CodexResetSummaryTimeParser.deadline(
            summary: official["summary"] as? String,
            publishedAt: officialSignalPublishedAt(from: object)
        ) {
            return (deadline, .deadline)
        }
        return (nil, nil)
    }

    /// Publish instant from `official_signal.at`. Past timestamps are kept so
    /// the progress bar can measure elapsed time from the tweet.
    private static func officialSignalPublishedAt(from object: [String: Any]) -> Date? {
        let official = object["official_signal"] as? [String: Any]
        guard let official else { return nil }
        return ResponseParsingSupport.timestampDate(official["at"])
    }

    private static func windowTarget(
        _ value: Any?,
        now: Date
    ) -> (targetAt: Date?, windowKind: CodexResetOfficialSignal.WindowKind?)? {
        switch value {
        case nil, is NSNull:
            return nil
        case let dict as [String: Any]:
            let targetKind = (dict["target_kind"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let isDeadlineKind = targetKind == "deadline"
                || targetKind == "end"
                || targetKind == "window_end"
            // Live API: window.target_at is the observed announced deadline;
            // window.end_at is its explicit range endpoint. Both are absolute.
            if let targetAt = ResponseParsingSupport.timestampDate(dict["target_at"]) {
                return (targetAt, isDeadlineKind ? .deadline : nil)
            }
            if let endAt = ResponseParsingSupport.timestampDate(dict["end_at"]) {
                return (endAt, .range)
            }
            if let at = ResponseParsingSupport.resetDate(dict["at"], now: now) {
                return (at, nil)
            }
            if let deadline = ResponseParsingSupport.resetDate(dict["deadline"], now: now) {
                return (deadline, .deadline)
            }
            if let target = ResponseParsingSupport.resetDate(dict["target"], now: now) {
                return (target, nil)
            }
            return nil
        default:
            guard let date = ResponseParsingSupport.resetDate(value, now: now) else {
                return nil
            }
            return (date, nil)
        }
    }

    /// Compatibility reads for the current public schema. UI must not depend
    /// on these paths; missing or relocated fields become `.unavailable`.
    private static func signalProbability(from object: [String: Any]) -> CodexResetProbability {
        let probabilities = object["probabilities"] as? [String: Any]
        let official = object["official_signal"] as? [String: Any]
        let nestedScore = official?["score"] as? [String: Any]
        let topScore = object["signal_score"] as? [String: Any]
        let candidates: [CodexResetProbability] = [
            percent(nestedScore?["value"]),
            percent(nestedScore?["base"]),
            percent(official?["score"]),
            percent(probabilities?["signal_percent"]),
            percent(probabilities?["commitment_floor_percent"]),
            fractionPercent(probabilities?["commitment"]),
            percent(topScore?["value"]),
            percent(topScore?["base"])
        ]
        return candidates.first { candidate in
            if case .percent = candidate {
                return true
            }
            return false
        } ?? .unavailable
    }

    private static func percent(_ value: Any?) -> CodexResetProbability {
        guard let score = integerPercent(value), (0...100).contains(score) else {
            return .unavailable
        }
        return .percent(score)
    }

    /// `probabilities.commitment` is a 0...1 fraction in the current schema.
    /// Values already expressed as 0...100 percents are accepted as-is.
    private static func fractionPercent(_ value: Any?) -> CodexResetProbability {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .unavailable
            }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite else { return .unavailable }
            if (0...1).contains(doubleValue) {
                return percent(doubleValue * 100)
            }
            return percent(doubleValue)
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Double(trimmed), parsed.isFinite {
                if (0...1).contains(parsed) {
                    return percent(parsed * 100)
                }
                return percent(parsed)
            }
        }
        return .unavailable
    }

    private static func integerPercent(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite, (0...100).contains(doubleValue) else { return nil }
            return Int(doubleValue.rounded(.towardZero))
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Int(trimmed) {
                return parsed
            }
            if let parsed = Double(trimmed), parsed.isFinite, (0...100).contains(parsed) {
                return Int(parsed.rounded(.towardZero))
            }
        }
        return nil
    }

    private static func confidence(_ value: Any?) -> CodexResetConfidence {
        if value == nil || value is NSNull {
            return .unavailable
        }
        guard let text = value as? String else {
            return .unknown("")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .unavailable
        }
        switch trimmed.lowercased() {
        case "low":
            return .low
        case "medium":
            return .medium
        case "high":
            return .high
        default:
            return .unknown(trimmed)
        }
    }
}


/// Conservative fallback for English announcements when the public forecast
/// contains `official_signal` but omits `window`. This is an observation
/// deadline, NOT proof or a guaranteed instant of a user's quota reset.
///
/// Site convention: PST/PT in natural-language promises refers to Pacific
/// civil time (including daylight saving), as observed on Oct 25, 2026.
private enum CodexResetSummaryTimeParser {
    private static let pacificTimeZone = TimeZone(identifier: "America/Los_Angeles")!

    static func deadline(summary: String?, publishedAt: Date?) -> Date? {
        guard let publishedAt, let summary, !summary.isEmpty else { return nil }

        // "By midnight PST" is the *next* local midnight following the post,
        // not midnight UTC, nor a hard-coded UTC-8 offset.
        if matches(#"^\\s*(?:by|before)\\s+midnight\\s+(?:pst|pdt|pt)\\b"#, in: summary) {
            return nextPacificMidnight(after: publishedAt)
        }

        // "Landing tomorrow before 10am PST" / "by 10:30 AM PT tomorrow".
        // Require both an explicit "tomorrow" and a recognized Pacific zone.
        if matches(#"\\btomorrow\\b"#, in: summary),
           let time = firstMatch(
                #"\\b(?:before|by)\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)\\s*(?:pst|pdt|pt)\\b"#,
                in: summary
           ) {
            let string = summary as NSString
            guard let hour = capture(time, at: 1, from: string).flatMap(Int.init),
                  (1...12).contains(hour) else { return nil }
            let minute = capture(time, at: 2, from: string).flatMap(Int.init) ?? 0
            guard (0...59).contains(minute),
                  let marker = capture(time, at: 3, from: string)?.lowercased() else {
                return nil
            }
            let hour24 = hour % 12 + (marker == "pm" ? 12 : 0)
            var calendar = pacificCalendar
            guard let day = calendar.date(
                byAdding: .day, value: 1, to: calendar.startOfDay(for: publishedAt)
            ) else { return nil }
            return calendar.date(bySettingHour: hour24, minute: minute, second: 0, of: day)
        }

        // Short, explicit relative windows are anchored to the source post.
        if let time = firstMatch(
            #"\\b(?:within|over)\\s+(?:the\\s+)?(?:next\\s+)?(\\d{1,3})\\s+minutes?\\b"#,
            in: summary
        ), let minutes = capture(time, at: 1, from: summary as NSString).flatMap(Int.init),
           (1...360).contains(minutes) {
            return publishedAt.addingTimeInterval(TimeInterval(minutes * 60))
        }
        if matches(
            #"\\b(?:within\\s+(?:(?:the\\s+)?(?:next\\s+)?)?(?:an?|one)\\s+hour|within\\s+the\\s+hour|(?:in|over)\\s+the\\s+next\\s+hour)\\b"#,
            in: summary
        ) {
            return publishedAt.addingTimeInterval(60 * 60)
        }
        // The site's historical API used three hours for "within a few hours".
        if matches(
            #"\\bwithin\\s+(?:(?:the\\s+)?(?:next\\s+)?)?(?:a\\s+)?few\\s+hours?\\b"#,
            in: summary
        ) {
            return publishedAt.addingTimeInterval(3 * 60 * 60)
        }

        // "Later today" is a deadline at the end of the post's Pacific day.
        if matches(
            #"\\b(?:later\\s+today|by\\s+(?:the\\s+)?end\\s+of\\s+(?:the\\s+)?day|by\\s+eod)\\b"#,
            in: summary
        ) {
            guard let nextMidnight = nextPacificMidnight(after: publishedAt) else {
                return nil
            }
            return nextMidnight.addingTimeInterval(-0.001)
        }

        return nil
    }

    private static var pacificCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacificTimeZone
        return calendar
    }

    private static func nextPacificMidnight(after date: Date) -> Date? {
        let calendar = pacificCalendar
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        firstMatch(pattern, in: text) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        return regex.firstMatch(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        at index: Int,
        from text: NSString
    ) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return text.substring(with: range)
    }
}
