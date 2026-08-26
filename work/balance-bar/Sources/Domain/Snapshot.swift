import Foundation

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
        windows: [OfficialQuotaWindow] = []
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
            officialQuotaWindows: resolvedWindows
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

    /// Resolve only the compact/menu-bar presentation from the real quota
    /// windows carried by this snapshot. The expanded card continues to use
    /// `officialQuotaWindows` directly, so choosing a window never duplicates,
    /// rewrites, or hides the source data.
    func menuBarSnapshot(
        preferredQuotaWindow: OfficialQuotaWindowPreference
    ) -> Snapshot {
        guard kind == .official else { return self }

        let recognized = officialQuotaWindows.filter { $0.kind != .other }
        // Older responses do not identify their window duration. Preserve the
        // established single-row presentation instead of guessing which named
        // preference they represent.
        guard !recognized.isEmpty else { return self }

        let selected: OfficialQuotaWindow?
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

        guard let selected else {
            return .providerError(
                provider,
                reason: tr(.keyProviderModelsQuotaUnavailable),
                cachedBalance: nil
            )
        }
        return replacingOfficialWindow(selected)
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
            officialQuotaWindows: officialQuotaWindows
        )
    }

    var menuBarTitle: String {
        switch kind {
        case .placeholder: return " …"
        case .official: return " \(Int(amount ?? 0))%"
        case .balance: return " \(format(amount ?? 0, unit ?? "USD"))"
        case .openCodex: return " \(unit ?? "OpenCodex")"
        case .error: return " !"
        }
    }

    var menuBarPrimary: String {
        switch kind {
        case .placeholder: return "…"
        case .official: return "\(Int(amount ?? 0))%"
        case .balance: return format(amount ?? 0, unit ?? "USD")
        case .openCodex: return unit ?? "OpenCodex"
        case .error: return "!"
        }
    }

    var menuBarSecondary: String {
        kind == .official ? (message ?? "—") : ""
    }

    var menuBarToolTip: String {
        guard kind == .official || kind == .openCodex else { return title }
        if kind == .openCodex {
            return tr(.keySnapshotValueValue, arguments: [String(describing: title), String(describing: message ?? tr(.keyLocalizationStatusUnknown))])
        }
        return tr(.keySnapshotValueResetValue, arguments: [String(describing: title), String(describing: message ?? tr(.keyLocalizationUnknown))])
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
            return tr(.keySnapshotResetValue, arguments: [String(describing: message ?? tr(.keyLocalizationUnknown))])
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
            return tr(.keySnapshotResetValue2, arguments: [String(describing: message ?? tr(.keyLocalizationWaitingForQuotaData))])
        default:
            return ""
        }
    }

    var detail: String {
        switch kind {
        case .balance:
            return tr(.keySnapshotUpdatedValueFollowsCcSwitchAutomatically, arguments: [String(describing: date?.formatted(date: .omitted, time: .shortened) ?? tr(.keyLocalizationJustNow))])
        case .official:
            let resetText = message.map {
                tr(.keySnapshotResetValue3, arguments: [String(describing: $0)])
            } ?? ""
            return tr(.keySnapshotOfficialQuotaUpdatesEveryMinutevalue, arguments: [String(describing: resetText)])
        case .openCodex:
            return message ?? tr(.keySnapshotWaitingForOpencodexStatus)
        case .error: return message ?? tr(.keySnapshotUnknownError)
        case .placeholder: return tr(.keySnapshotWaitingForCcSwitchStatus)
        }
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
