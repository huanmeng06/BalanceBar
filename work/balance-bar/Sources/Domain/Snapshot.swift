import Foundation

struct LunaReserveQuota: Equatable {
    enum Status: Equatable {
        case loading
        case available
        case unavailable

        var localizedText: String {
            switch self {
            case .loading:
                return tr(.keyLunaReserveStatusLoading)
            case .available:
                return tr(.keyLunaReserveStatusAvailable)
            case .unavailable:
                return tr(.keyLunaReserveStatusUnavailable)
            }
        }
    }

    /// `remaining` is the percentage derived from the official
    /// `used_percent` field. It remains optional so missing or malformed
    /// fields never become a fabricated zero.
    let status: Status
    let remaining: Double?
    let reset: String?
    let resetAt: Date?

    init(
        status: Status,
        remaining: Double?,
        reset: String?,
        resetAt: Date? = nil
    ) {
        self.status = status
        self.remaining = remaining
        self.reset = reset
        self.resetAt = resetAt
    }

    var remainingText: String {
        guard let remaining else {
            return tr(.keyLunaReserveRemainingUnavailable)
        }
        return tr(
            .keyLunaReserveRemainingValue,
            arguments: [String(describing: Int(remaining))]
        )
    }

    var resetText: String {
        guard let reset = resetDisplayText() else {
            return tr(.keyLunaReserveResetUnavailable)
        }
        return tr(.keyLunaReserveResetValue, arguments: [reset])
    }

    var menuTitleText: String {
        "🌙 \(tr(.keyLunaReserveTitle))"
    }

    var menuSubtitleText: String {
        switch status {
        case .loading:
            return tr(.keyLunaReserveStatusLoading)
        case .available:
            guard let reset = resetDisplayText() else {
                return tr(.keyLunaReserveResetUnavailable)
            }
            return tr(.keyLunaReserveMenuResetValue, arguments: [reset])
        case .unavailable:
            return tr(.keyLunaReserveMenuUnavailable)
        }
    }

    func resetDisplayText(
        displayMode: OfficialQuotaResetDisplayMode = .both,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard let reset else { return nil }
        let exactDate = OfficialQuotaResetFormatter.string(
            for: resetAt,
            relativeTo: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        switch displayMode {
        case .remaining:
            return reset
        case .resetAt:
            return exactDate ?? reset
        case .both:
            guard let exactDate else { return reset }
            return tr(.keySnapshotValueValue, arguments: [reset, exactDate])
        }
    }

    var summaryText: String {
        tr(
            .keyLunaReserveSummaryValue,
            arguments: [
                tr(.keyLunaReserveTitle),
                status.localizedText,
                remainingText,
                resetText
            ]
        )
    }
}

struct OfficialQuotaWindow: Equatable {
    enum Kind: Int, Equatable, Hashable {
        case fiveHour
        case sevenDay
        case other

        var sortOrder: Int { rawValue }
    }

    let kind: Kind
    let remaining: Double
    let label: String
    let daysText: String
    let reset: String?
    let durationSeconds: Double?
    /// The original absolute reset timestamp, when the API supplied a valid
    /// future value. Relative reset text remains separate so it can continue
    /// to use the API's existing countdown semantics.
    let resetAt: Date?

    init(
        kind: Kind,
        remaining: Double,
        label: String,
        daysText: String,
        reset: String?,
        durationSeconds: Double?,
        resetAt: Date? = nil
    ) {
        self.kind = kind
        self.remaining = remaining
        self.label = label
        self.daysText = daysText
        self.reset = reset
        self.durationSeconds = durationSeconds
        self.resetAt = resetAt
    }

    /// Keep unrecognized/legacy windows on the existing relative-only path.
    /// Only the two Codex windows identified by Issue #202 may expose a
    /// precise timestamp in the quota card.
    func resetDisplayText(
        displayMode: OfficialQuotaResetDisplayMode = .both,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard let reset else { return nil }
        let exactDate: String? = {
            guard kind != .other else { return nil }
            return OfficialQuotaResetFormatter.string(
                for: resetAt,
                relativeTo: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        }()

        switch displayMode {
        case .remaining:
            return reset
        case .resetAt:
            return exactDate ?? reset
        case .both:
            guard let exactDate else {
                return reset
            }
            return tr(.keySnapshotValueValue, arguments: [reset, exactDate])
        }
    }
}

struct OfficialQuotaMenuPresentation: Equatable {
    let windows: [OfficialQuotaWindow]
    let lunaReserve: LunaReserveQuota?
}

enum OfficialQuotaResetFormatter {
    /// Format a valid future reset timestamp in the user's local calendar and
    /// time zone. The `j` template field delegates 12/24-hour preference to
    /// Foundation's locale data, while the date template is only used after a
    /// local-calendar day boundary.
    static func string(
        for resetAt: Date?,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard let resetAt, resetAt > now else { return nil }

        var localizedCalendar = calendar
        localizedCalendar.locale = locale
        localizedCalendar.timeZone = timeZone
        let template = localizedCalendar.isDate(resetAt, inSameDayAs: now)
            ? "jm"
            : "Mdjm"

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = localizedCalendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        let text = formatter.string(from: resetAt)
        return text.isEmpty ? nil : text
    }
}

struct Snapshot {
    enum Kind { case placeholder, official, balance, openCodex, error }
    let kind: Kind
    let provider: String
    let amount: Double?
    let unit: String?
    let date: Date?
    let message: String?
    let websiteURL: URL?
    let balanceProgressPercentage: Double?
    let officialQuotaWindows: [OfficialQuotaWindow]
    let lunaReserve: LunaReserveQuota?
    /// The window selected for the compact/menu-bar presentation. The full
    /// quota card keeps all source windows, so this marker prevents the
    /// selected row's exact reset timestamp from being replaced by the
    /// representative (weekly) window when shared snapshot properties render.
    let selectedOfficialQuotaWindowKind: OfficialQuotaWindow.Kind?
    /// True only for the derived compact presentation used while the official
    /// service reports a usable Luna Reserve quota. The source snapshot and
    /// the expanded Dashboard card remain unchanged.
    let menuBarUsesLunaReserve: Bool

    init(
        kind: Kind,
        provider: String,
        amount: Double?,
        unit: String?,
        date: Date?,
        message: String?,
        websiteURL: URL?,
        balanceProgressPercentage: Double?,
        officialQuotaWindows: [OfficialQuotaWindow],
        selectedOfficialQuotaWindowKind: OfficialQuotaWindow.Kind? = nil,
        lunaReserve: LunaReserveQuota? = nil,
        menuBarUsesLunaReserve: Bool = false
    ) {
        self.kind = kind
        self.provider = provider
        self.amount = amount
        self.unit = unit
        self.date = date
        self.message = message
        self.websiteURL = websiteURL
        self.balanceProgressPercentage = balanceProgressPercentage
        self.officialQuotaWindows = officialQuotaWindows
        self.selectedOfficialQuotaWindowKind = selectedOfficialQuotaWindowKind
        self.lunaReserve = lunaReserve
        self.menuBarUsesLunaReserve = menuBarUsesLunaReserve
    }

    static let placeholder = Snapshot(
        kind: .placeholder,
        provider: "",
        amount: nil,
        unit: nil,
        date: nil,
        message: nil,
        websiteURL: nil,
        balanceProgressPercentage: nil,
        officialQuotaWindows: []
    )

    static func official(
        _ provider: String,
        _ remaining: Double,
        _ lane: String,
        _ reset: String?,
        _ date: Date,
        windows: [OfficialQuotaWindow] = [],
        lunaReserve: LunaReserveQuota? = nil
    ) -> Snapshot {
        let fallbackWindows = windows.isEmpty
            ? [OfficialQuotaWindow(
                kind: .other,
                remaining: remaining,
                label: lane,
                daysText: lane,
                reset: reset,
                durationSeconds: nil
            )]
            : windows
        let resolvedWindows = fallbackWindows.sorted {
            if $0.kind.sortOrder != $1.kind.sortOrder {
                return $0.kind.sortOrder < $1.kind.sortOrder
            }
            return ($0.durationSeconds ?? 0) > ($1.durationSeconds ?? 0)
        }
        let representative = resolvedWindows.first(where: { $0.kind == .sevenDay })
            ?? resolvedWindows.first(where: { $0.kind == .fiveHour })
            ?? resolvedWindows[0]
        return Snapshot(
            kind: .official,
            provider: provider,
            amount: representative.remaining,
            unit: representative.label,
            date: date,
            message: representative.reset,
            websiteURL: nil,
            balanceProgressPercentage: nil,
            officialQuotaWindows: resolvedWindows,
            lunaReserve: lunaReserve
        )
    }

    static func balance(
        _ provider: String,
        _ amount: Double,
        _ unit: String,
        _ websiteURL: URL?,
        _ date: Date,
        progressPercentage: Double? = nil
    ) -> Snapshot {
        Snapshot(
            kind: .balance,
            provider: provider,
            amount: amount,
            unit: unit,
            date: date,
            message: nil,
            websiteURL: websiteURL,
            balanceProgressPercentage: progressPercentage,
            officialQuotaWindows: []
        )
    }

    static func openCodex(_ provider: String, selector: String?, status: String, _ date: Date) -> Snapshot {
        Snapshot(
            kind: .openCodex,
            provider: provider,
            amount: nil,
            unit: selector,
            date: date,
            message: status,
            websiteURL: nil,
            balanceProgressPercentage: nil,
            officialQuotaWindows: []
        )
    }

    static func error(_ message: String) -> Snapshot {
        Snapshot(
            kind: .error,
            provider: "",
            amount: nil,
            unit: nil,
            date: nil,
            message: message,
            websiteURL: nil,
            balanceProgressPercentage: nil,
            officialQuotaWindows: []
        )
    }

    static func providerError(_ provider: String, reason: String, cachedBalance: Snapshot?) -> Snapshot {
        let cached = cachedBalance?.kind == .balance ? cachedBalance : nil
        return Snapshot(
            kind: .error,
            provider: provider,
            amount: cached?.amount,
            unit: cached?.unit,
            date: cached?.date,
            message: reason,
            websiteURL: nil,
            balanceProgressPercentage: cached?.balanceProgressPercentage,
            officialQuotaWindows: []
        )
    }

    /// Only recognized Codex windows participate in the expanded menu card.
    /// Unknown/legacy windows remain available through the normal single-row
    /// snapshot presentation instead of being mistaken for a 5-hour or 7-day
    /// quota.
    var officialQuotaWindowsForMenu: [OfficialQuotaWindow] {
        let recognized = officialQuotaWindows.filter { $0.kind != .other }
        return recognized.isEmpty ? Array(officialQuotaWindows.prefix(1)) : recognized
    }

    /// Resolve the official quota rows shown in the status menu. This keeps
    /// menu-only visibility preferences out of the snapshot and never changes
    /// the source windows used by the Dashboard provider page.
    func officialQuotaMenuPresentation(
        lunaReserveDisplayMode: LunaReserveDisplayMode,
        hideExhaustedQuota: Bool
    ) -> OfficialQuotaMenuPresentation {
        guard kind == .official else {
            return OfficialQuotaMenuPresentation(windows: [], lunaReserve: nil)
        }

        let windows = officialQuotaWindowsForMenu
        let hasExhaustedQuota = windows.contains {
            $0.kind != .other && $0.remaining <= 0
        }
        let shouldShowLunaReserve: Bool
        switch lunaReserveDisplayMode {
        case .disabled:
            shouldShowLunaReserve = false
        case .whenQuotaExhausted:
            shouldShowLunaReserve = hasExhaustedQuota && lunaReserve != nil
        case .always:
            shouldShowLunaReserve = lunaReserve != nil
        }

        let presentedWindows = shouldShowLunaReserve
            && lunaReserveDisplayMode == .whenQuotaExhausted
            && hideExhaustedQuota
            ? windows.filter { $0.remaining > 0 }
            : windows
        return OfficialQuotaMenuPresentation(
            windows: presentedWindows,
            lunaReserve: shouldShowLunaReserve ? lunaReserve : nil
        )
    }

    /// Resolve only the compact/menu-bar presentation from the real quota
    /// windows carried by this snapshot. The expanded card continues to use
    /// `officialQuotaWindows` directly, so choosing a window never duplicates,
    /// rewrites, or hides the source data.
    func menuBarSnapshot(
        preferredQuotaWindow: OfficialQuotaWindowPreference,
        automaticallyUseLunaReserve: Bool = false
    ) -> Snapshot {
        guard kind == .official else { return self }

        let recognized = officialQuotaWindows.filter { $0.kind != .other }
        // Older responses do not identify their window duration. Preserve the
        // established single-row presentation instead of guessing which named
        // preference they represent.
        let selected: OfficialQuotaWindow?
        if recognized.isEmpty {
            selected = nil
        } else {
            switch preferredQuotaWindow {
            case .fiveHour:
                // Five-hour is the requested primary window, with the only safe
                // fallback required by the Issue being the real seven-day window.
                selected = recognized.first(where: { $0.kind == .fiveHour })
                    ?? recognized.first(where: { $0.kind == .sevenDay })
            case .sevenDay:
                // Never silently show five-hour data when seven-day is selected.
                selected = recognized.first(where: { $0.kind == .sevenDay })
            }
        }

        let selectedSnapshot: Snapshot
        if let selected {
            selectedSnapshot = replacingOfficialWindow(selected)
        } else if recognized.isEmpty {
            selectedSnapshot = self
        } else {
            return .providerError(
                provider,
                reason: tr(.keyProviderModelsQuotaUnavailable),
                cachedBalance: nil
            )
        }
        // The setting only permits the automatic takeover. Codex enters
        // Reserve after an identified original quota is exhausted; it must
        // not be inferred merely from the setting or Reserve data being
        // present. Keep this check generic across 5-hour and 7-day windows so
        // plans that expose only one official window work without binding the
        // takeover to the currently selected primary window.
        let originalQuotaIsExhausted = recognized.contains { $0.remaining <= 0 }
        guard automaticallyUseLunaReserve,
              originalQuotaIsExhausted,
              let lunaReserve,
              lunaReserve.status == .available,
              lunaReserve.remaining != nil else {
            return selectedSnapshot
        }
        return selectedSnapshot.replacingMenuBarWithLunaReserve()
    }

    private func replacingOfficialWindow(_ window: OfficialQuotaWindow) -> Snapshot {
        Snapshot(
            kind: kind,
            provider: provider,
            amount: window.remaining,
            unit: window.label,
            date: date,
            message: window.reset,
            websiteURL: websiteURL,
            balanceProgressPercentage: balanceProgressPercentage,
            officialQuotaWindows: officialQuotaWindows,
            selectedOfficialQuotaWindowKind: window.kind,
            lunaReserve: lunaReserve,
            menuBarUsesLunaReserve: false
        )
    }

    private func replacingMenuBarWithLunaReserve() -> Snapshot {
        guard kind == .official,
              let lunaReserve,
              lunaReserve.status == .available,
              let remaining = lunaReserve.remaining else {
            return self
        }
        return Snapshot(
            kind: kind,
            provider: provider,
            amount: remaining,
            unit: tr(.keyLunaReserveTitle),
            date: date,
            message: lunaReserve.reset,
            websiteURL: websiteURL,
            balanceProgressPercentage: balanceProgressPercentage,
            officialQuotaWindows: officialQuotaWindows,
            selectedOfficialQuotaWindowKind: selectedOfficialQuotaWindowKind,
            lunaReserve: lunaReserve,
            menuBarUsesLunaReserve: true
        )
    }

    var menuBarTitle: String {
        switch kind {
        case .placeholder: return " …"
        case .official: return " \(Int(amount ?? 0))%\(menuBarUsesLunaReserve ? " 🌙" : "")"
        case .balance: return " \(format(amount ?? 0, unit ?? "USD"))"
        case .openCodex: return " \(unit ?? "OpenCodex")"
        case .error: return " !"
        }
    }

    var menuBarPrimary: String {
        switch kind {
        case .placeholder: return "…"
        case .official: return "\(Int(amount ?? 0))%\(menuBarUsesLunaReserve ? " 🌙" : "")"
        case .balance: return format(amount ?? 0, unit ?? "USD")
        case .openCodex: return unit ?? "OpenCodex"
        case .error: return "!"
        }
    }

    var menuBarSecondary: String {
        menuBarSecondary(displayMode: .defaultValue)
    }

    func menuBarSecondary(
        displayMode: OfficialQuotaResetDisplayMode,
        lunaReserveResetTimeMode: LunaReserveResetTimeMode = .defaultValue,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard kind == .official else { return "" }
        let reset: String?
        if menuBarUsesLunaReserve && lunaReserveResetTimeMode == .lunaReserve {
            reset = lunaReserve?.resetDisplayText(
                displayMode: displayMode,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        } else {
            reset = officialResetDisplayValue(
                displayMode: displayMode,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        }
        return reset ?? "—"
    }

    var menuBarToolTip: String {
        guard kind == .official || kind == .openCodex else { return title }
        if kind == .openCodex {
            return tr(.keySnapshotValueValue, arguments: [String(describing: title), String(describing: message ?? tr(.keyLocalizationStatusUnknown))])
        }
        let reset = String(describing: officialResetDisplayValue() ?? tr(.keyLocalizationUnknown))
        guard let lunaReserve else {
            return tr(.keySnapshotValueResetValue, arguments: [String(describing: title), reset])
        }
        return tr(
            .keySnapshotValueValue,
            arguments: [
                tr(.keySnapshotValueResetValue, arguments: [String(describing: title), reset]),
                lunaReserve.summaryText
            ]
        )
    }

    var overviewProvider: String {
        switch kind {
        case .placeholder: return "CC Switch"
        case .official, .balance, .openCodex: return provider
        case .error: return provider.isEmpty ? "CC Switch" : provider
        }
    }

    func overviewReset(refreshDate: Date?, formatter: DateFormatter) -> String {
        switch kind {
        case .official:
            return tr(.keySnapshotResetValue, arguments: [String(describing: officialResetDisplayValue() ?? tr(.keyLocalizationUnknown))])
        case .balance:
            return tr(.keySnapshotLastRefreshedValue, arguments: [String(describing: formatter.string(from: refreshDate ?? date ?? Date()))])
        case .openCodex:
            return message ?? tr(.keySnapshotOpencodexStatusIsUnknown)
        case .placeholder:
            return tr(.keySnapshotLoadingTheCurrentProvider)
        case .error:
            return message ?? tr(.keySnapshotFailedToLoadBalance)
        }
    }

    var overviewQuotaTitle: String {
        switch kind {
        case .official: return tr(.keySnapshotAvailableQuota)
        case .balance: return tr(.keySnapshotAvailableBalance)
        case .openCodex: return tr(.keySnapshotOpencodex)
        case .placeholder, .error: return tr(.keySnapshotBalanceStatus)
        }
    }

    var overviewQuotaDetail: String {
        switch kind {
        case .official: return unit ?? tr(.keySnapshot7DayQuota)
        case .balance: return tr(.keySnapshotRemainingBalance)
        case .openCodex: return tr(.keySnapshotCurrentProviderModel)
        case .placeholder: return tr(.keySnapshotWaitingToRefresh)
        case .error: return tr(.keySnapshotLoadFailed)
        }
    }

    var overviewLargeAmount: String {
        switch kind {
        case .official: return "\(Int(amount ?? 0))%"
        case .balance: return format(amount ?? 0, unit ?? "USD")
        case .openCodex: return unit ?? "—"
        case .placeholder: return "—"
        case .error:
            guard let amount, let unit else { return "—" }
            return format(amount, unit)
        }
    }

    var hasCachedBalance: Bool {
        kind == .error && amount != nil && unit != nil && date != nil
    }

    var progressPercentage: Double? {
        switch kind {
        case .official: return amount
        case .balance: return balanceProgressPercentage
        case .placeholder, .openCodex, .error: return nil
        }
    }

    var title: String {
        switch kind {
        case .placeholder:
            return tr(.keySnapshotLoadingCcSwitch)
        case .official:
            return tr(.keySnapshotValueRemainingValueValue, arguments: [String(describing: provider), String(describing: Int(amount ?? 0)), String(describing: unit ?? tr(.keyLocalizationQuota))])
        case .balance:
            return tr(.keySnapshotValueRemainingValue, arguments: [String(describing: provider), String(describing: format(amount ?? 0, unit ?? "USD"))])
        case .openCodex:
            return tr(.keySnapshotValueValue2, arguments: [String(describing: provider), String(describing: unit ?? "OpenCodex")])
        case .error:
            return tr(.keySnapshotFailedToLoadBalance2)
        }
    }

    var compactQuotaTitle: String {
        switch kind {
        case .official:
            return tr(.keySnapshotValueRemainingValue2, arguments: [String(describing: unit ?? tr(.keyLocalizationQuota)), String(describing: Int(amount ?? 0))])
        default:
            return title
        }
    }

    var compactResetTitle: String {
        switch kind {
        case .official:
            return tr(.keySnapshotResetValue2, arguments: [String(describing: officialResetDisplayValue() ?? tr(.keyLocalizationWaitingForQuotaData))])
        default:
            return ""
        }
    }

    var detail: String {
        switch kind {
        case .balance:
            return tr(.keySnapshotUpdatedValueFollowsCcSwitchAutomatically, arguments: [String(describing: date?.formatted(date: .omitted, time: .shortened) ?? tr(.keyLocalizationJustNow))])
        case .official:
            let resetText = officialResetDisplayValue().map {
                tr(.keySnapshotResetValue3, arguments: [String(describing: $0)])
            } ?? ""
            return tr(.keySnapshotOfficialQuotaUpdatesEveryMinutevalue, arguments: [String(describing: resetText)])
        case .openCodex:
            return message ?? tr(.keySnapshotWaitingForOpencodexStatus)
        case .error: return message ?? tr(.keySnapshotUnknownError)
        case .placeholder: return tr(.keySnapshotWaitingForCcSwitchStatus)
        }
    }

    func officialResetDisplayValue(
        displayMode: OfficialQuotaResetDisplayMode = .both,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard kind == .official else { return nil }
        let representative = selectedOfficialQuotaWindowKind.flatMap { selectedKind in
            officialQuotaWindows.first(where: { $0.kind == selectedKind })
        }
            ?? officialQuotaWindows.first(where: { $0.kind == .sevenDay })
            ?? officialQuotaWindows.first(where: { $0.kind == .fiveHour })
            ?? officialQuotaWindows.first
        return representative?.resetDisplayText(
            displayMode: displayMode,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        ) ?? message
    }

    private func format(_ amount: Double, _ unit: String) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        switch unit.uppercased() {
        case "USD":
            return "$\(number)"
        case "CNY", "CNH", "RMB":
            return "¥\(number)"
        default:
            return "\(number) \(unit)"
        }
    }
}
