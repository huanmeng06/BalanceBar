import Foundation
import AppKit

enum AppLanguage: String, CaseIterable {
    case system
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case english

    static var selected: AppLanguage {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: "appLanguage"),
                  let language = AppLanguage(rawValue: rawValue) else {
                return .system
            }
            return language
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appLanguage")
        }
    }

    /// The concrete language BalanceBar should present right now: the explicit
    /// selection when one exists, otherwise the first macOS preferred language
    /// that BalanceBar supports (with English as the final fallback).
    static var resolved: AppLanguage {
        resolved(for: selected, preferredLanguages: Locale.preferredLanguages)
    }

    /// Maps a selection plus the system preferred-language list to one of the
    /// concrete display languages. `system` scans the preferred list in order;
    /// the first supported entry wins and an unsupported list falls back to
    /// English (the existing fallback strategy).
    static func resolved(for language: AppLanguage, preferredLanguages: [String]) -> AppLanguage {
        switch language {
        case .simplifiedChinese:
            return .simplifiedChinese
        case .traditionalChinese:
            return .traditionalChinese
        case .japanese:
            return .japanese
        case .english:
            return .english
        case .system:
            for preferred in preferredLanguages {
                let normalized = Self.normalizedPreferredLanguage(preferred)
                if Self.isTraditionalChinese(normalized) {
                    return .traditionalChinese
                }
                if normalized.hasPrefix("zh") {
                    return .simplifiedChinese
                }
                if normalized.hasPrefix("ja") {
                    return .japanese
                }
                if normalized.hasPrefix("en") {
                    return .english
                }
            }
            return .english
        }
    }

    /// Fixed label width used by the menu-bar overview "官方链接：/Official
    /// Link:/公式リンク：" prefix so the Provider link starts at a consistent
    /// column and is never truncated in any supported language.
    var overviewLinkPrefixWidth: CGFloat {
        switch self {
        case .simplifiedChinese, .traditionalChinese:
            return 62
        case .english, .japanese:
            return 72
        case .system:
            return 72
        }
    }

    var localizedTitle: String {
        localizedTitle(using: AppLanguage.resolved)
    }

    func localizedTitle(using language: AppLanguage) -> String {
        switch self {
        case .system:
            return tr("跟随系统", "Follow System", "跟隨系統", "システムに従う", language: language)
        case .simplifiedChinese:
            return "简体中文"
        case .traditionalChinese:
            return "繁體中文"
        case .japanese:
            return "日本語"
        case .english:
            return "English"
        }
    }

    private static func normalizedPreferredLanguage(_ identifier: String) -> String {
        identifier.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private static func isTraditionalChinese(_ normalized: String) -> Bool {
        normalized.hasPrefix("zh-hant")
            || normalized.hasPrefix("zh-tw")
            || normalized.hasPrefix("zh-hk")
            || normalized.hasPrefix("zh-mo")
    }
}

/// Translates a user-visible string into all four supported display
/// languages. Argument order is: Simplified Chinese, English, Traditional
/// Chinese, Japanese. Keeping the first two arguments in the historical order
/// makes every call site read `tr("简体", "English", "繁體", "日本語")`.
func tr(
    _ simplifiedChinese: String,
    _ english: String,
    _ traditionalChinese: String,
    _ japanese: String,
    language: AppLanguage = .selected
) -> String {
    switch AppLanguage.resolved(for: language, preferredLanguages: Locale.preferredLanguages) {
    case .simplifiedChinese:
        return simplifiedChinese
    case .english:
        return english
    case .traditionalChinese:
        return traditionalChinese
    case .japanese:
        return japanese
    case .system:
        return english
    }
}
