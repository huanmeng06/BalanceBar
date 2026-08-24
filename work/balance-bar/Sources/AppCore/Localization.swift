import Foundation
import AppKit

enum AppLanguage: String, CaseIterable {
    case system
    case simplifiedChinese
    case traditionalChinese
    case english
    case japanese

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

    /// Fixed label width used by the menu-bar overview's localized link prefix
    /// so the Provider link starts at a consistent column in every language.
    var overviewLinkPrefixWidth: CGFloat {
        switch self {
        case .simplifiedChinese, .traditionalChinese:
            return 62
        case .english, .japanese, .system:
            return 72
        }
    }

    var localizedTitle: String {
        localizedTitle(using: AppLanguage.resolved)
    }

    func localizedTitle(using language: AppLanguage) -> String {
        switch self {
        case .system:
            return tr(.keyLocalizationFollowSystem, language: language)
        case .simplifiedChinese:
            return tr(.keyLocalizationSimplifiedChineseName, language: language)
        case .traditionalChinese:
            return tr(.keyLocalizationTraditionalChineseName, language: language)
        case .japanese:
            return tr(.keyLocalizationJapaneseName, language: language)
        case .english:
            return tr(.keyLocalizationEnglishName, language: language)
        }
    }

    fileprivate var resourceLocalization: String {
        switch self {
        case .system:
            return AppLanguage.resolved.resourceLocalization
        case .simplifiedChinese:
            return "zh-Hans"
        case .traditionalChinese:
            return "zh-Hant"
        case .english:
            return "en"
        case .japanese:
            return "ja"
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

/// Loads the explicit language sub-bundle instead of relying on the process
/// bundle's localization fallback. The latter follows macOS preferences and
/// cannot represent AppLanguage's runtime selection on macOS 14.
final class LocalizationResourceStore {
    private static let missingValuePrefix = "__balancebar_missing_localization__"

    private let bundle: Bundle
    private let resourceRoot: URL?
    private var bundleCache: [String: Bundle?] = [:]
    private let lock = NSLock()

    init(bundle: Bundle = .main, resourceRoot: URL? = nil) {
        self.bundle = bundle
        self.resourceRoot = resourceRoot
    }

    func localized(
        key: LocalizationKey,
        language: AppLanguage,
        arguments: [String] = [],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let resolvedLanguage = AppLanguage.resolved(
            for: language,
            preferredLanguages: preferredLanguages
        )
        let selected = value(for: key, localization: resolvedLanguage.resourceLocalization)
        if let selected {
            if let rendered = render(selected, key: key, arguments: arguments) {
                return rendered
            }
            NSLog(
                "BalanceBar localization warning: invalid format for key %@ in %@",
                key.rawKey,
                resolvedLanguage.resourceLocalization
            )
        } else if resolvedLanguage != .english {
            NSLog(
                "BalanceBar localization warning: missing key %@ in %@; trying English",
                key.rawKey,
                resolvedLanguage.resourceLocalization
            )
        }

        if resolvedLanguage != .english,
           let english = value(for: key, localization: AppLanguage.english.resourceLocalization),
           let rendered = render(english, key: key, arguments: arguments) {
            return rendered
        }

        NSLog("BalanceBar localization error: missing or invalid English key %@", key.rawKey)
        return "⟦\(key.rawKey)⟧"
    }

    private func value(for key: LocalizationKey, localization: String) -> String? {
        guard let localizedBundle = localizedBundle(for: localization) else {
            return nil
        }
        let missingValue = "\(Self.missingValuePrefix)\(localization)__\(key.rawKey)"
        let value = localizedBundle.localizedString(
            forKey: key.rawKey,
            value: missingValue,
            table: "Localizable"
        )
        return value == missingValue ? nil : value
    }

    private func localizedBundle(for localization: String) -> Bundle? {
        lock.lock()
        if let cached = bundleCache[localization] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let bundle: Bundle? = if let resourceRoot {
            Bundle(path: resourceRoot
                .appendingPathComponent("\(localization).lproj", isDirectory: true)
                .path)
        } else if let path = bundle.path(forResource: localization, ofType: "lproj") {
            Bundle(path: path)
        } else {
            ([Bundle(for: LocalizationResourceStore.self)] + Bundle.allBundles + Bundle.allFrameworks)
                .lazy
                .compactMap { candidate in
                    candidate.path(forResource: localization, ofType: "lproj")
                        .flatMap(Bundle.init(path:))
                }
                .first
        }

        lock.lock()
        bundleCache[localization] = bundle
        lock.unlock()
        return bundle
    }

    private func render(
        _ format: String,
        key: LocalizationKey,
        arguments: [String]
    ) -> String? {
        guard let indices = placeholderIndices(in: format) else {
            return nil
        }
        let expectedIndices = arguments.isEmpty ? Set<Int>() : Set(1...arguments.count)
        guard indices == expectedIndices else {
            NSLog(
                "BalanceBar localization warning: placeholder mismatch for key %@ (indices=%@, arguments=%ld)",
                key.rawKey,
                String(describing: indices),
                arguments.count
            )
            return nil
        }
        guard !arguments.isEmpty || format.contains("%") else {
            return format
        }
        let cVarArguments: [CVarArg] = arguments.map { $0 as CVarArg }
        return String(format: format, arguments: cVarArguments)
    }

    private func placeholderIndices(in format: String) -> Set<Int>? {
        var indices = Set<Int>()
        var index = format.startIndex
        while index < format.endIndex {
            guard format[index] == "%" else {
                index = format.index(after: index)
                continue
            }
            let next = format.index(after: index)
            guard next < format.endIndex else { return nil }
            if format[next] == "%" {
                index = format.index(after: next)
                continue
            }

            var cursor = next
            var digits = ""
            while cursor < format.endIndex, format[cursor].isNumber {
                digits.append(format[cursor])
                cursor = format.index(after: cursor)
            }
            guard !digits.isEmpty,
                  cursor < format.endIndex,
                  format[cursor] == "$" else {
                return nil
            }
            cursor = format.index(after: cursor)
            guard cursor < format.endIndex, format[cursor] == "@" else {
                return nil
            }
            guard let parsed = Int(digits), parsed > 0 else { return nil }
            indices.insert(parsed)
            index = format.index(after: cursor)
        }
        return indices
    }
}

enum LocalizationRuntime {
    private static var currentStore = LocalizationResourceStore()

    static func configure(bundle: Bundle = .main, resourceRoot: URL? = nil) {
        currentStore = LocalizationResourceStore(bundle: bundle, resourceRoot: resourceRoot)
    }

    static func localized(
        key: LocalizationKey,
        language: AppLanguage = .selected,
        arguments: [String] = [],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        currentStore.localized(
            key: key,
            language: language,
            arguments: arguments,
            preferredLanguages: preferredLanguages
        )
    }
}

func tr(
    _ key: LocalizationKey,
    arguments: [String] = [],
    language: AppLanguage = .selected
) -> String {
    LocalizationRuntime.localized(key: key, language: language, arguments: arguments)
}
