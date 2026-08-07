import Foundation

struct Snapshot {
    enum Kind { case placeholder, official, balance, error }
    let kind: Kind
    let provider: String
    let amount: Double?
    let unit: String?
    let date: Date?
    let message: String?
    let websiteURL: URL?

    static let placeholder = Snapshot(kind: .placeholder, provider: "", amount: nil, unit: nil, date: nil, message: nil, websiteURL: nil)
    static func official(_ provider: String, _ remaining: Double, _ lane: String, _ reset: String?, _ date: Date) -> Snapshot { Snapshot(kind: .official, provider: provider, amount: remaining, unit: lane, date: date, message: reset, websiteURL: nil) }
    static func balance(_ provider: String, _ amount: Double, _ unit: String, _ websiteURL: URL?, _ date: Date) -> Snapshot { Snapshot(kind: .balance, provider: provider, amount: amount, unit: unit, date: date, message: nil, websiteURL: websiteURL) }
    static func error(_ message: String) -> Snapshot { Snapshot(kind: .error, provider: "", amount: nil, unit: nil, date: nil, message: message, websiteURL: nil) }
    static func providerError(_ provider: String, reason: String, cachedBalance: Snapshot?) -> Snapshot {
        let cached = cachedBalance?.kind == .balance ? cachedBalance : nil
        return Snapshot(
            kind: .error,
            provider: provider,
            amount: cached?.amount,
            unit: cached?.unit,
            date: cached?.date,
            message: reason,
            websiteURL: nil
        )
    }

    var menuBarTitle: String {
        switch kind {
        case .placeholder: return " …"
        case .official: return " \(Int(amount ?? 0))%"
        case .balance: return " \(format(amount ?? 0, unit ?? "USD"))"
        case .error: return " !"
        }
    }

    var menuBarPrimary: String {
        switch kind {
        case .placeholder: return "…"
        case .official: return "\(Int(amount ?? 0))%"
        case .balance: return format(amount ?? 0, unit ?? "USD")
        case .error: return "!"
        }
    }

    var menuBarSecondary: String {
        kind == .official ? (message ?? "—") : ""
    }

    var menuBarToolTip: String {
        guard kind == .official else { return title }
        return tr(
            "\(title) · 重置：\(message ?? "未知")",
            "\(title) · Reset: \(message ?? "Unknown")"
        )
    }

    var overviewProvider: String {
        switch kind {
        case .placeholder: return "CC Switch"
        case .official, .balance: return provider
        case .error: return provider.isEmpty ? "CC Switch" : provider
        }
    }

    func overviewReset(refreshDate: Date?, formatter: DateFormatter) -> String {
        switch kind {
        case .official:
            return tr("重置：\(message ?? "未知")", "Reset: \(message ?? "Unknown")")
        case .balance:
            return tr(
                "最后刷新：\(formatter.string(from: refreshDate ?? date ?? Date()))",
                "Last refreshed: \(formatter.string(from: refreshDate ?? date ?? Date()))"
            )
        case .placeholder:
            return tr("正在读取当前供应商…", "Loading the current Provider…")
        case .error:
            return message ?? tr("余额读取失败", "Failed to load balance")
        }
    }

    var overviewQuotaTitle: String {
        switch kind {
        case .official: return tr("可用额度", "Available Quota")
        case .balance: return tr("可用余额", "Available Balance")
        case .placeholder, .error: return tr("额度状态", "Balance Status")
        }
    }

    var overviewQuotaDetail: String {
        switch kind {
        case .official: return unit ?? tr("7 日额度", "7-Day Quota")
        case .balance: return tr("剩余额度", "Remaining Balance")
        case .placeholder: return tr("等待刷新", "Waiting to Refresh")
        case .error: return tr("读取失败", "Load Failed")
        }
    }

    var overviewLargeAmount: String {
        switch kind {
        case .official: return "\(Int(amount ?? 0))%"
        case .balance: return format(amount ?? 0, unit ?? "USD")
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
        kind == .official ? amount : nil
    }

    var title: String {
        switch kind {
        case .placeholder:
            return tr("正在读取 CC Switch…", "Loading CC Switch…")
        case .official:
            return tr(
                "\(provider) 剩余：\(Int(amount ?? 0))%（\(unit ?? "额度")）",
                "\(provider) remaining: \(Int(amount ?? 0))% (\(unit ?? "Quota"))"
            )
        case .balance:
            return tr(
                "\(provider) 剩余：\(format(amount ?? 0, unit ?? "USD"))",
                "\(provider) remaining: \(format(amount ?? 0, unit ?? "USD"))"
            )
        case .error:
            return tr("余额读取失败", "Failed to Load Balance")
        }
    }

    var compactQuotaTitle: String {
        switch kind {
        case .official:
            return tr(
                "\(unit ?? "额度")剩余：\(Int(amount ?? 0))%",
                "\(unit ?? "Quota") remaining: \(Int(amount ?? 0))%"
            )
        default:
            return title
        }
    }

    var compactResetTitle: String {
        switch kind {
        case .official:
            return tr(
                "重置：\(message ?? "等待额度信息")",
                "Reset: \(message ?? "Waiting for quota data")"
            )
        default:
            return ""
        }
    }

    var detail: String {
        switch kind {
        case .balance:
            return tr(
                "更新：\(date?.formatted(date: .omitted, time: .shortened) ?? "刚刚") · 随 CC Switch 自动切换",
                "Updated: \(date?.formatted(date: .omitted, time: .shortened) ?? "Just now") · Follows CC Switch automatically"
            )
        case .official:
            let resetText = message.map {
                tr(" · 重置：\($0)", " · Reset: \($0)")
            } ?? ""
            return tr("每分钟更新官方额度\(resetText)", "Official quota updates every minute\(resetText)")
        case .error: return message ?? tr("未知错误", "Unknown Error")
        case .placeholder: return tr("等待 CC Switch 状态", "Waiting for CC Switch Status")
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
