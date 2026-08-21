import Foundation

struct Snapshot {
    enum Kind { case placeholder, official, balance, openCodex, error }
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
    static func openCodex(_ provider: String, selector: String?, status: String, _ date: Date) -> Snapshot { Snapshot(kind: .openCodex, provider: provider, amount: nil, unit: selector, date: date, message: status, websiteURL: nil) }
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
            return tr(
                "\(title) · \(message ?? "状态未知")",
                "\(title) · \(message ?? "Unknown status")",
                "\(title) · \(message ?? "狀態未知")",
                "\(title) · \(message ?? "ステータス不明")"
            )
        }
        return tr(
            "\(title) · 重置：\(message ?? "未知")",
            "\(title) · Reset: \(message ?? "Unknown")",
            "\(title) · 重設：\(message ?? "未知")",
            "\(title) · リセット：\(message ?? "不明")"
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
            return tr("重置：\(message ?? "未知")", "Reset: \(message ?? "Unknown")", "重設：\(message ?? "未知")", "リセット：\(message ?? "不明")")
        case .balance:
            return tr(
                "最后刷新：\(formatter.string(from: refreshDate ?? date ?? Date()))",
                "Last refreshed: \(formatter.string(from: refreshDate ?? date ?? Date()))",
                "最後重新整理：\(formatter.string(from: refreshDate ?? date ?? Date()))",
                "最終更新：\(formatter.string(from: refreshDate ?? date ?? Date()))"
            )
        case .openCodex:
            return message ?? tr("OpenCodex 状态未知", "OpenCodex status is unknown", "OpenCodex 狀態未知", "OpenCodex のステータスが不明です")
        case .placeholder:
            return tr("正在读取当前供应商…", "Loading the current Provider…", "正在讀取目前供應商…", "現在のプロバイダーを読み込み中…")
        case .error:
            return message ?? tr("余额读取失败", "Failed to load balance", "餘額讀取失敗", "残高の読み込みに失敗しました")
        }
    }

    var overviewQuotaTitle: String {
        switch kind {
        case .official: return tr("可用额度", "Available Quota", "可用額度", "利用可能なクォータ")
        case .balance: return tr("可用余额", "Available Balance", "可用餘額", "利用可能な残高")
        case .openCodex: return tr("OpenCodex", "OpenCodex", "OpenCodex", "OpenCodex")
        case .placeholder, .error: return tr("额度状态", "Balance Status", "額度狀態", "残高ステータス")
        }
    }

    var overviewQuotaDetail: String {
        switch kind {
        case .official: return unit ?? tr("7 日额度", "7-Day Quota", "7 日額度", "7日間クォータ")
        case .balance: return tr("剩余额度", "Remaining Balance", "剩餘額度", "残りのクォータ")
        case .openCodex: return tr("当前 provider/model", "Current provider/model", "目前 provider/model", "現在のプロバイダー/モデル")
        case .placeholder: return tr("等待刷新", "Waiting to Refresh", "等待重新整理", "更新待ち")
        case .error: return tr("读取失败", "Load Failed", "讀取失敗", "読み込み失敗")
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
        kind == .official ? amount : nil
    }

    var title: String {
        switch kind {
        case .placeholder:
            return tr("正在读取 CC Switch…", "Loading CC Switch…", "正在讀取 CC Switch…", "CC Switch を読み込み中…")
        case .official:
            return tr(
                "\(provider) 剩余：\(Int(amount ?? 0))%（\(unit ?? "额度")）",
                "\(provider) remaining: \(Int(amount ?? 0))% (\(unit ?? "Quota"))",
                "\(provider) 剩餘：\(Int(amount ?? 0))%（\(unit ?? "額度")）",
                "\(provider) の残り：\(Int(amount ?? 0))%（\(unit ?? "クォータ")）"
            )
        case .balance:
            return tr(
                "\(provider) 剩余：\(format(amount ?? 0, unit ?? "USD"))",
                "\(provider) remaining: \(format(amount ?? 0, unit ?? "USD"))",
                "\(provider) 剩餘：\(format(amount ?? 0, unit ?? "USD"))",
                "\(provider) の残り：\(format(amount ?? 0, unit ?? "USD"))"
            )
        case .openCodex:
            return tr(
                "\(provider) · \(unit ?? "OpenCodex")",
                "\(provider) · \(unit ?? "OpenCodex")",
                "\(provider) · \(unit ?? "OpenCodex")",
                "\(provider) · \(unit ?? "OpenCodex")"
            )
        case .error:
            return tr("余额读取失败", "Failed to Load Balance", "餘額讀取失敗", "残高の読み込みに失敗しました")
        }
    }

    var compactQuotaTitle: String {
        switch kind {
        case .official:
            return tr(
                "\(unit ?? "额度")剩余：\(Int(amount ?? 0))%",
                "\(unit ?? "Quota") remaining: \(Int(amount ?? 0))%",
                "\(unit ?? "額度")剩餘：\(Int(amount ?? 0))%",
                "\(unit ?? "クォータ") の残り：\(Int(amount ?? 0))%"
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
                "Reset: \(message ?? "Waiting for quota data")",
                "重設：\(message ?? "等待額度資訊")",
                "リセット：\(message ?? "クォータ情報を待機中")"
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
                "Updated: \(date?.formatted(date: .omitted, time: .shortened) ?? "Just now") · Follows CC Switch automatically",
                "更新：\(date?.formatted(date: .omitted, time: .shortened) ?? "剛剛") · 隨 CC Switch 自動切換",
                "更新：\(date?.formatted(date: .omitted, time: .shortened) ?? "たった今") · CC Switch に自動的に追従"
            )
        case .official:
            let resetText = message.map {
                tr(" · 重置：\($0)", " · Reset: \($0)", " · 重設：\($0)", " · リセット：\($0)")
            } ?? ""
            return tr("每分钟更新官方额度\(resetText)", "Official quota updates every minute\(resetText)", "每分鐘更新官方額度\(resetText)", "公式クォータは毎分更新\(resetText)")
        case .openCodex:
            return message ?? tr("等待 OpenCodex 状态", "Waiting for OpenCodex status", "等待 OpenCodex 狀態", "OpenCodex のステータスを待機中")
        case .error: return message ?? tr("未知错误", "Unknown Error", "未知錯誤", "不明なエラー")
        case .placeholder: return tr("等待 CC Switch 状态", "Waiting for CC Switch Status", "等待 CC Switch 狀態", "CC Switch のステータスを待機中")
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
