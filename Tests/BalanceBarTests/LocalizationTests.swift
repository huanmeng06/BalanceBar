import XCTest
@testable import BalanceBar

final class LocalizationTests: XCTestCase {
    private let allLanguages: [AppLanguage] = [
        .simplifiedChinese, .traditionalChinese, .japanese, .english
    ]

    private let resourceDirectories: [String: AppLanguage] = [
        "en": .english,
        "zh-Hans": .simplifiedChinese,
        "zh-Hant": .traditionalChinese,
        "ja": .japanese
    ]

    private var testBundle: Bundle {
        Bundle(for: LocalizationTests.self)
    }

    override func setUp() {
        super.setUp()
        LocalizationRuntime.configure(bundle: testBundle)
    }

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

    func testLanguagePickerOrder() {
        XCTAssertEqual(
            AppLanguage.allCases,
            [.system, .simplifiedChinese, .traditionalChinese, .english, .japanese]
        )
    }

    func testLocalizedTitlesCoverAllLanguages() {
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .simplifiedChinese), "跟随系统")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .traditionalChinese), "跟隨系統")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .japanese), "システムに従う")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .english), "Follow System")

        // Language options always keep their own original names; only
        // "Follow System" is localized into the current UI language.
        for language in allLanguages + [.system] {
            XCTAssertEqual(AppLanguage.simplifiedChinese.localizedTitle(using: language), "简体中文")
            XCTAssertEqual(AppLanguage.traditionalChinese.localizedTitle(using: language), "繁體中文")
            XCTAssertEqual(AppLanguage.japanese.localizedTitle(using: language), "日本語")
            XCTAssertEqual(AppLanguage.english.localizedTitle(using: language), "English")
        }
    }

    func testTranslationReturnsLanguageSpecificStrings() {
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .simplifiedChinese), "跟随系统")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .traditionalChinese), "跟隨系統")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .japanese), "システムに従う")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .english), "Follow System")
    }

    func testAllTypedKeysExistInEveryBundledLanguage() throws {
        let expectedKeys = Set(LocalizationKey.allCases.map(\.rawKey))
        XCTAssertEqual(expectedKeys.count, LocalizationKey.allCases.count)
        XCTAssertEqual(expectedKeys.count, 349)

        for (directory, language) in resourceDirectories {
            let resourceURL = try XCTUnwrap(
                testBundle.url(forResource: directory, withExtension: "lproj")
            ).appendingPathComponent("Localizable.strings")
            let data = try Data(contentsOf: resourceURL)
            let text = try XCTUnwrap(
                String(data: data, encoding: .utf16) ?? String(data: data, encoding: .utf8)
            )
            let actualKeys = Set(
                text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("\""),
                          let equals = trimmed.range(of: "\" = ") else {
                        return nil
                    }
                    return String(trimmed.dropFirst().prefix(through: trimmed.index(before: equals.lowerBound)))
                }
            )
            XCTAssertEqual(actualKeys, expectedKeys, "resource keys for \(language)")
        }
    }

    func testParameterizedResourcesRenderAndValidatePlaceholderContracts() {
        let store = LocalizationResourceStore(bundle: testBundle)
        XCTAssertEqual(
            store.localized(
                key: .keySnapshotValueRemainingValueValue,
                language: .english,
                arguments: ["OpenAI", "87", "7-Day Quota"]
            ),
            "OpenAI remaining: 87% (7-Day Quota)"
        )
        XCTAssertEqual(
            store.localized(
                key: .keyDashboardGeneralAndRefreshPagesDownloadingValue,
                language: .english,
                arguments: ["12.5"]
            ),
            "Downloading 12.5% …"
        )
        XCTAssertEqual(
            store.localized(
                key: .keySnapshotValueRemainingValueValue,
                language: .english,
                arguments: ["OpenAI"]
            ),
            "⟦snapshot.value_remaining_value_value⟧"
        )
    }

    func testSemanticSubtitleResourcesExposeLocalizedAndAtomicInterpolationRanges() throws {
        let store = LocalizationResourceStore(bundle: testBundle)
        let values = [
            "\u{00A0}-\u{00A0}10.0\u{00A0}pt",
            "\u{00A0}+\u{00A0}10.0\u{00A0}pt",
            "\u{00A0}+\u{00A0}0.0\u{00A0}pt"
        ]

        for value in values {
            for language in allLanguages {
                let subtitle = store.localizedSubtitle(
                    key: .keyDashboardMenuBarPageAdjustsTheGapBetweenBalancebarAndOtherItemsWidthvalue,
                    language: language,
                    arguments: [value]
                )
                XCTAssertFalse(subtitle.text.contains(LocalizationSemanticMarker.semanticStart))
                XCTAssertEqual(subtitle.semanticGroups.count, 1, "semantic group for \(language), value \(value)")
                XCTAssertEqual(subtitle.atomicGroups.count, 1, "atomic interpolation for \(language), value \(value)")
                XCTAssertEqual(
                    subtitle.lineBreakBeforeSemanticGroups,
                    subtitle.semanticGroups,
                    "the complete dynamic suffix starts on its own line for \(language), value \(value)"
                )

                let text = subtitle.text as NSString
                let semanticText = text.substring(with: try XCTUnwrap(subtitle.semanticGroups.first))
                let atomicText = text.substring(with: try XCTUnwrap(subtitle.atomicGroups.first))
                XCTAssertTrue(
                    semanticText.contains(value),
                    "localized suffix should contain its dynamic value for \(language)"
                )
                XCTAssertEqual(atomicText, value, "dynamic value range for \(language)")
                XCTAssertTrue(
                    semanticText.contains("\u{00A0}"),
                    "localized resource should preserve the visual descriptor/value spacing for \(language)"
                )
            }
        }
    }

    func testFutureSubtitleFixtureUsesTheSameResourceContractWithoutLanguageBranch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-I178-Subtitle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = LocalizationKey.keyDashboardMenuBarPageAdjustsTheGapBetweenBalancebarAndOtherItemsWidthvalue.rawKey
        let fixture = "\"\(key)\" = \"Future summary: [[balancebar.break-before-semantic]][[balancebar.semantic]]Zukunft value[[balancebar.atomic]]%1$@[[/balancebar.atomic]][[/balancebar.semantic]]\";\n"
        try fixture.write(
            to: directory.appendingPathComponent("Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )

        let subtitle = LocalizationResourceStore(resourceRoot: root).localizedSubtitle(
            key: .keyDashboardMenuBarPageAdjustsTheGapBetweenBalancebarAndOtherItemsWidthvalue,
            language: .english,
            arguments: [" - 10.0 pt"]
        )
        XCTAssertEqual(subtitle.text, "Future summary: Zukunft value - 10.0 pt")
        XCTAssertEqual(subtitle.semanticGroups.count, 1)
        XCTAssertEqual(subtitle.atomicGroups.count, 1)
        XCTAssertEqual(subtitle.lineBreakBeforeSemanticGroups, subtitle.semanticGroups)
        XCTAssertEqual(
            (subtitle.text as NSString).substring(with: try XCTUnwrap(subtitle.semanticGroups.first)),
            "Zukunft value - 10.0 pt"
        )
        XCTAssertEqual(
            (subtitle.text as NSString).substring(with: try XCTUnwrap(subtitle.atomicGroups.first)),
            " - 10.0 pt"
        )
    }

    func testMissingSelectedKeyFallsBackToEnglishAndMissingEnglishIsDiagnosable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-I177-Localization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("en.lproj"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("zh-Hans.lproj"),
            withIntermediateDirectories: true
        )
        try "\"app.about_balancebar\" = \"English fallback\";\n".write(
            to: root.appendingPathComponent("en.lproj/Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: root.appendingPathComponent("zh-Hans.lproj/Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )

        let store = LocalizationResourceStore(resourceRoot: root)
        XCTAssertEqual(
            store.localized(key: .keyAppAboutBalancebar, language: .simplifiedChinese),
            "English fallback"
        )
        XCTAssertEqual(
            store.localized(key: .keyAppHideBalancebar, language: .simplifiedChinese),
            "⟦app.hide_balancebar⟧"
        )
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
                    return ["關於 BalanceBar", "跟隨系統", "简体中文", "繁體中文", "日本語"]
                case .japanese:
                    return ["BalanceBar について", "システムに従う", "简体中文", "繁體中文", "日本語"]
                case .english:
                    return ["About BalanceBar", "Follow System", "简体中文", "繁體中文", "日本語"]
                case .system:
                    return []
                }
            }()
            XCTAssertEqual(
                tr(.keyAppAboutBalancebar),
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
