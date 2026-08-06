import Foundation

enum AppLanguage: String, CaseIterable {
    case system
    case simplifiedChinese
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

    static var usesSimplifiedChinese: Bool {
        usesSimplifiedChinese(for: selected, preferredLanguage: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    static func usesSimplifiedChinese(for language: AppLanguage, preferredLanguage: String) -> Bool {
        switch language {
        case .simplifiedChinese:
            return true
        case .english:
            return false
        case .system:
            return preferredLanguage.lowercased().hasPrefix("zh")
        }
    }

    var localizedTitle: String {
        localizedTitle(using: AppLanguage.selected)
    }

    func localizedTitle(using language: AppLanguage) -> String {
        switch self {
        case .system:
            return tr("跟随系统", "Follow System", language: language)
        case .simplifiedChinese:
            return tr("简体中文", "Simplified Chinese", language: language)
        case .english:
            return "English"
        }
    }
}

func tr(_ simplifiedChinese: String, _ english: String) -> String {
    tr(simplifiedChinese, english, language: AppLanguage.selected)
}

func tr(_ simplifiedChinese: String, _ english: String, language: AppLanguage) -> String {
    AppLanguage.usesSimplifiedChinese(for: language, preferredLanguage: Locale.preferredLanguages.first ?? Locale.current.identifier)
        ? simplifiedChinese
        : english
}
