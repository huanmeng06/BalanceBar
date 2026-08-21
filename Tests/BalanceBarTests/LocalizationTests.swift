import XCTest
@testable import BalanceBar

final class LocalizationTests: XCTestCase {
    private let allLanguages: [AppLanguage] = [
        .simplifiedChinese, .traditionalChinese, .japanese, .english
    ]

    func testExplicitLanguageSelectionIsConcrete() {
        for preferred in ["zh-CN", "zh-TW", "ja-JP", "en-US", "fr-FR"] {
            XCTAssertEqual(AppLanguage.resolved(for: .simplifiedChinese, preferredLanguages: [preferred]), .simplifiedChinese)
            XCTAssertEqual(AppLanguage.resolved(for: .traditionalChinese, preferredLanguages: [preferred]), .traditionalChinese)
            XCTAssertEqual(AppLanguage.resolved(for: .japanese, preferredLanguages: [preferred]), .japanese)
            XCTAssertEqual(AppLanguage.resolved(for: .english, preferredLanguages: [preferred]), .english)
        }
    }

    func testSystemSelectionMatchesSimplifiedChineseIdentifiers() {
        for preferred in ["zh-Hans", "zh-CN", "zh-SG", "zh", "zh-Hans-CN", "zh_CN"] {
            XCTAssertEqual(
                AppLanguage.resolved(for: .system, preferredLanguages: [preferred]),
                .simplifiedChinese,
                "expected \(preferred) to resolve to Simplified Chinese"
            )
        }
    }

    func testSystemSelectionMatchesTraditionalChineseIdentifiers() {
        for preferred in ["zh-Hant", "zh-TW", "zh-HK", "zh-MO", "zh-Hant-TW", "zh-HK_Hant"] {
            XCTAssertEqual(
                AppLanguage.resolved(for: .system, preferredLanguages: [preferred]),
                .traditionalChinese,
                "expected \(preferred) to resolve to Traditional Chinese"
            )
        }
    }

    func testSystemSelectionMatchesJapaneseIdentifiers() {
        for preferred in ["ja", "ja-JP", "ja_JP"] {
            XCTAssertEqual(
                AppLanguage.resolved(for: .system, preferredLanguages: [preferred]),
                .japanese,
                "expected \(preferred) to resolve to Japanese"
            )
        }
    }

    func testSystemSelectionFallsBackToEnglishForUnknownLanguages() {
        XCTAssertEqual(AppLanguage.resolved(for: .system, preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.resolved(for: .system, preferredLanguages: ["de", "ko-KR"]), .english)
        XCTAssertEqual(AppLanguage.resolved(for: .system, preferredLanguages: []), .english)
    }

    func testSystemSelectionUsesFirstSupportedPreferredLanguage() {
        XCTAssertEqual(
            AppLanguage.resolved(for: .system, preferredLanguages: ["en-US", "zh-TW"]),
            .english
        )
        XCTAssertEqual(
            AppLanguage.resolved(for: .system, preferredLanguages: ["zh-Hant", "en-US"]),
            .traditionalChinese
        )
        XCTAssertEqual(
            AppLanguage.resolved(for: .system, preferredLanguages: ["fr-FR", "ja-JP", "zh-CN"]),
            .japanese
        )
    }

    func testPersistenceRoundTripAndOldValueFallback() {
        let previous = AppLanguage.selected
        defer { AppLanguage.selected = previous }

        for language in allLanguages {
            AppLanguage.selected = language
            XCTAssertEqual(AppLanguage.selected, language)
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: "appLanguage"),
                language.rawValue
            )
        }

        // Unknown or legacy values fall back to "system" instead of crashing.
        AppLanguage.selected = .system
        UserDefaults.standard.set("no-such-language", forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.selected, .system)
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.selected, .system)
    }

    func testLanguagePickerOrderMatchesIssueRequirement() {
        XCTAssertEqual(
            AppLanguage.allCases,
            [.system, .simplifiedChinese, .traditionalChinese, .japanese, .english]
        )
    }

    func testLocalizedTitlesCoverAllLanguages() {
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .simplifiedChinese), "跟随系统")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .traditionalChinese), "跟隨系統")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .japanese), "システムに従う")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .english), "Follow System")

        XCTAssertEqual(AppLanguage.simplifiedChinese.localizedTitle(using: .simplifiedChinese), "简体中文")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localizedTitle(using: .traditionalChinese), "簡體中文")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localizedTitle(using: .japanese), "簡体中国語")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localizedTitle(using: .english), "Simplified Chinese")

        XCTAssertEqual(AppLanguage.traditionalChinese.localizedTitle(using: .simplifiedChinese), "繁體中文")
        XCTAssertEqual(AppLanguage.traditionalChinese.localizedTitle(using: .traditionalChinese), "繁體中文")
        XCTAssertEqual(AppLanguage.traditionalChinese.localizedTitle(using: .japanese), "繁体中国語")
        XCTAssertEqual(AppLanguage.traditionalChinese.localizedTitle(using: .english), "Traditional Chinese")

        XCTAssertEqual(AppLanguage.japanese.localizedTitle(using: .simplifiedChinese), "日本語")
        XCTAssertEqual(AppLanguage.japanese.localizedTitle(using: .traditionalChinese), "日本語")
        XCTAssertEqual(AppLanguage.japanese.localizedTitle(using: .japanese), "日本語")
        XCTAssertEqual(AppLanguage.japanese.localizedTitle(using: .english), "Japanese")

        XCTAssertEqual(AppLanguage.english.localizedTitle(using: .simplifiedChinese), "English")
        XCTAssertEqual(AppLanguage.english.localizedTitle(using: .traditionalChinese), "English")
        XCTAssertEqual(AppLanguage.english.localizedTitle(using: .japanese), "English")
        XCTAssertEqual(AppLanguage.english.localizedTitle(using: .english), "English")
    }

    func testTranslationReturnsLanguageSpecificStrings() {
        XCTAssertEqual(tr("中文", "English", "中文（繁體）", "日本語のテキスト", language: .simplifiedChinese), "中文")
        XCTAssertEqual(tr("中文", "English", "中文（繁體）", "日本語のテキスト", language: .traditionalChinese), "中文（繁體）")
        XCTAssertEqual(tr("中文", "English", "中文（繁體）", "日本語のテキスト", language: .japanese), "日本語のテキスト")
        XCTAssertEqual(tr("中文", "English", "中文（繁體）", "日本語のテキスト", language: .english), "English")
    }

    func testMenuOverviewLinkPrefixWidthsAreStable() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.overviewLinkPrefixWidth, 62)
        XCTAssertEqual(AppLanguage.traditionalChinese.overviewLinkPrefixWidth, 62)
        XCTAssertEqual(AppLanguage.japanese.overviewLinkPrefixWidth, 72)
        XCTAssertEqual(AppLanguage.english.overviewLinkPrefixWidth, 72)
    }

    /// Production-path coverage: every concrete display language must produce
    /// its own copy (no English fallback) for the core menu and Dashboard
    /// labels that drive the language picker and application menus.
    func testCoreMenuAndDashboardStringsHaveNoWrongFallback() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        for language in allLanguages {
            AppLanguage.selected = language
            let expected: [String] = {
                switch language {
                case .simplifiedChinese:
                    return ["关于 BalanceBar", "跟随系统", "简体中文", "繁體中文", "日本語"]
                case .traditionalChinese:
                    return ["關於 BalanceBar", "跟隨系統", "簡體中文", "繁體中文", "日本語"]
                case .japanese:
                    return ["BalanceBar について", "システムに従う", "簡体中国語", "繁体中国語", "日本語"]
                case .english:
                    return ["About BalanceBar", "Follow System", "Simplified Chinese", "Traditional Chinese", "Japanese"]
                case .system:
                    return []
                }
            }()
            XCTAssertEqual(
                tr("关于 BalanceBar", "About BalanceBar", "關於 BalanceBar", "BalanceBar について"),
                expected[0]
            )
            XCTAssertEqual(
                AppLanguage.system.localizedTitle,
                expected[1]
            )
            XCTAssertEqual(
                AppLanguage.simplifiedChinese.localizedTitle,
                expected[2]
            )
            XCTAssertEqual(
                AppLanguage.traditionalChinese.localizedTitle,
                expected[3]
            )
            XCTAssertEqual(
                AppLanguage.japanese.localizedTitle,
                expected[4]
            )
        }
    }
}
