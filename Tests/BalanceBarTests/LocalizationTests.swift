import XCTest
@testable import BalanceBar

final class LocalizationTests: XCTestCase {
    private let allLanguages: [AppLanguage] = [
        .simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong, .japanese, .english,
        .korean, .spanish, .german
    ]

    private let resourceDirectories: [String: AppLanguage] = [
        "en": .english,
        "zh-Hans": .simplifiedChinese,
        "zh-Hant-TW": .traditionalChineseTaiwan,
        "zh-Hant-HK": .traditionalChineseHongKong,
        "ja": .japanese,
        "ko": .korean,
        "es": .spanish,
        "de": .german
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
            XCTAssertEqual(AppLanguage.resolved(for: .traditionalChineseTaiwan, preferredLanguages: [preferred]), .traditionalChineseTaiwan)
            XCTAssertEqual(AppLanguage.resolved(for: .traditionalChineseHongKong, preferredLanguages: [preferred]), .traditionalChineseHongKong)
            XCTAssertEqual(AppLanguage.resolved(for: .japanese, preferredLanguages: [preferred]), .japanese)
            XCTAssertEqual(AppLanguage.resolved(for: .english, preferredLanguages: [preferred]), .english)
            XCTAssertEqual(AppLanguage.resolved(for: .korean, preferredLanguages: [preferred]), .korean)
            XCTAssertEqual(AppLanguage.resolved(for: .spanish, preferredLanguages: [preferred]), .spanish)
            XCTAssertEqual(AppLanguage.resolved(for: .german, preferredLanguages: [preferred]), .german)
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

    func testSystemSelectionMatchesTaiwanTraditionalChineseIdentifiers() {
        for preferred in ["zh-Hant", "zh-TW", "zh-Hant-TW", "zh_TW"] {
            XCTAssertEqual(
                AppLanguage.resolved(for: .system, preferredLanguages: [preferred]),
                .traditionalChineseTaiwan,
                "expected \(preferred) to resolve to Taiwan Traditional Chinese"
            )
        }
    }

    func testSystemSelectionMatchesHongKongTraditionalChineseIdentifiers() {
        for preferred in ["zh-HK", "zh-Hant-HK", "zh-MO", "zh-Hant-MO", "zh-HK_Hant"] {
            XCTAssertEqual(
                AppLanguage.resolved(for: .system, preferredLanguages: [preferred]),
                .traditionalChineseHongKong,
                "expected \(preferred) to resolve to Hong Kong Traditional Chinese"
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

    func testSystemSelectionMatchesNewLanguageIdentifiers() {
        let cases: [(String, AppLanguage)] = [
            ("ko", .korean),
            ("ko-KR", .korean),
            ("ko_KR", .korean),
            ("es", .spanish),
            ("es-ES", .spanish),
            ("es_MX", .spanish),
            ("de", .german),
            ("de-DE", .german),
            ("de_AT", .german)
        ]

        for (preferred, expected) in cases {
            XCTAssertEqual(
                AppLanguage.resolved(for: .system, preferredLanguages: [preferred]),
                expected,
                "expected \(preferred) to resolve to \(expected)"
            )
        }
    }

    func testSystemSelectionFallsBackToEnglishForUnknownLanguages() {
        XCTAssertEqual(AppLanguage.resolved(for: .system, preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.resolved(for: .system, preferredLanguages: ["fr-FR", "it-IT"]), .english)
        XCTAssertEqual(AppLanguage.resolved(for: .system, preferredLanguages: []), .english)
    }

    func testSystemSelectionUsesFirstSupportedPreferredLanguage() {
        XCTAssertEqual(
            AppLanguage.resolved(for: .system, preferredLanguages: ["en-US", "zh-TW"]),
            .english
        )
        XCTAssertEqual(
            AppLanguage.resolved(for: .system, preferredLanguages: ["zh-Hant", "en-US"]),
            .traditionalChineseTaiwan
        )
        XCTAssertEqual(
            AppLanguage.resolved(for: .system, preferredLanguages: ["fr-FR", "ja-JP", "zh-CN"]),
            .japanese
        )
    }

    func testPersistenceRoundTripAndOldValueFallback() {
        let previousRawValue = UserDefaults.standard.string(forKey: "appLanguage")
        defer {
            if let previousRawValue {
                UserDefaults.standard.set(previousRawValue, forKey: "appLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "appLanguage")
            }
        }

        for language in allLanguages {
            AppLanguage.selected = language
            XCTAssertEqual(AppLanguage.selected, language)
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: "appLanguage"),
                language.rawValue
            )
        }

        // Unknown values fall back to "system" instead of crashing.
        UserDefaults.standard.set("no-such-language", forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.selected, .system)

        // The pre-Issue-184 value is migrated in place to Taiwan, preserving
        // the user's choice while giving future launches a regional value.
        UserDefaults.standard.set("traditionalChinese", forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.selected, .traditionalChineseTaiwan)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "appLanguage"),
            AppLanguage.traditionalChineseTaiwan.rawValue
        )
    }

    func testLanguagePickerOrder() {
        XCTAssertEqual(
            AppLanguage.allCases,
            [.system, .simplifiedChinese, .traditionalChineseHongKong, .traditionalChineseTaiwan, .english, .japanese, .korean, .spanish, .german]
        )
    }

    func testLanguagePickerRegionalSelectionsKeepTheirOwnRouting() {
        let pickerLanguages = AppLanguage.allCases
        let regionalLanguages: [AppLanguage] = [
            .traditionalChineseHongKong,
            .traditionalChineseTaiwan
        ]

        XCTAssertEqual(
            Array(pickerLanguages.dropFirst(2).prefix(2)),
            regionalLanguages
        )

        for language in regionalLanguages {
            guard let pickerIndex = pickerLanguages.firstIndex(of: language) else {
                XCTFail("missing picker item")
                continue
            }
            let representedValue = pickerLanguages[pickerIndex].rawValue
            guard let selectedLanguage = AppLanguage(rawValue: representedValue) else {
                XCTFail("picker item has an invalid raw value")
                continue
            }

            XCTAssertEqual(selectedLanguage, language)
            XCTAssertEqual(
                AppLanguage.resolved(for: selectedLanguage, preferredLanguages: ["en-US"]),
                language
            )
        }
    }

    func testLocalizedTitlesCoverAllLanguages() {
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .simplifiedChinese), "跟随系统")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .traditionalChineseTaiwan), "跟隨系統")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .traditionalChineseHongKong), "跟隨系統")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .japanese), "システムに従う")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .english), "Follow System")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .korean), "시스템 언어 사용")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .spanish), "Seguir el sistema")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .german), "System folgen")

        // Language options always keep their own original names; only
        // "Follow System" is localized into the current UI language.
        for language in allLanguages + [.system] {
            XCTAssertEqual(AppLanguage.simplifiedChinese.localizedTitle(using: language), "简体中文")
            XCTAssertEqual(AppLanguage.traditionalChineseTaiwan.localizedTitle(using: language), "繁體中文（台灣）")
            XCTAssertEqual(AppLanguage.traditionalChineseHongKong.localizedTitle(using: language), "繁體中文（香港）")
            XCTAssertEqual(AppLanguage.japanese.localizedTitle(using: language), "日本語")
            XCTAssertEqual(AppLanguage.english.localizedTitle(using: language), "English")
            XCTAssertEqual(AppLanguage.korean.localizedTitle(using: language), "한국어")
            XCTAssertEqual(AppLanguage.spanish.localizedTitle(using: language), "Español")
            XCTAssertEqual(AppLanguage.german.localizedTitle(using: language), "Deutsch")
        }
    }

    func testTranslationReturnsLanguageSpecificStrings() {
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .simplifiedChinese), "跟随系统")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .traditionalChineseTaiwan), "跟隨系統")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .traditionalChineseHongKong), "跟隨系統")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .japanese), "システムに従う")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .english), "Follow System")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .korean), "시스템 언어 사용")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .spanish), "Seguir el sistema")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .german), "System folgen")
    }

    func testUpdateVersionSubtitleKeepsExistingTwoPlaceholderContract() {
        let key = LocalizationKey.keyDashboardGeneralAndRefreshPagesNewVersionAvailableValueValue
        for language in allLanguages {
            let rendered = tr(
                key,
                arguments: ["1.0.6", "1.0.7"],
                language: language
            )
            XCTAssertTrue(rendered.contains("1.0.6"), "missing current version in \(language)")
            XCTAssertTrue(rendered.contains("1.0.7"), "missing target version in \(language)")
            XCTAssertFalse(rendered.contains("%1$@"), "unrendered first placeholder in \(language)")
            XCTAssertFalse(rendered.contains("%2$@"), "unrendered second placeholder in \(language)")
            XCTAssertFalse(rendered.hasPrefix("⟦"), "missing existing update subtitle key in \(language)")
        }
    }

    func testIgnoreUpdateCopyExistsInEverySupportedLanguage() {
        let key = LocalizationKey.keyDashboardGeneralAndRefreshPagesIgnoreThisVersion
        let expected: [AppLanguage: String] = [
            .simplifiedChinese: "忽略此版本",
            .traditionalChineseTaiwan: "忽略此版本",
            .traditionalChineseHongKong: "忽略此版本",
            .japanese: "このバージョンを無視",
            .english: "Ignore This Version",
            .korean: "이 버전 무시",
            .spanish: "Ignorar esta versión",
            .german: "Diese Version ignorieren"
        ]

        for language in allLanguages {
            XCTAssertEqual(tr(key, language: language), expected[language])
            XCTAssertFalse(tr(key, language: language).hasPrefix("⟦"))
        }
    }

    func testAllTypedKeysExistInEveryBundledLanguage() throws {
        let expectedKeys = Set(LocalizationKey.allCases.map(\.rawKey))
        XCTAssertEqual(expectedKeys.count, LocalizationKey.allCases.count)
        XCTAssertEqual(expectedKeys.count, 361)

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

    func testNewLanguageBundlesLoadExplicitlyWithoutEnglishFallback() throws {
        let store = LocalizationResourceStore(bundle: testBundle)
        let expectations: [(AppLanguage, String, String)] = [
            (.traditionalChineseTaiwan, "zh-Hant-TW", "關於 BalanceBar"),
            (.traditionalChineseHongKong, "zh-Hant-HK", "關於 BalanceBar"),
            (.korean, "ko", "BalanceBar 정보"),
            (.spanish, "es", "Acerca de BalanceBar"),
            (.german, "de", "Über BalanceBar")
        ]

        for (language, directory, aboutTitle) in expectations {
            XCTAssertNotNil(
                testBundle.url(forResource: directory, withExtension: "lproj"),
                "test bundle must package \(directory).lproj"
            )
            XCTAssertEqual(
                store.localized(key: .keyAppAboutBalancebar, language: language),
                aboutTitle,
                "explicit resource bundle lookup for \(language)"
            )
            XCTAssertFalse(
                store.localized(key: .keyAppAboutBalancebar, language: language).contains("⟦"),
                "new-language lookup must not expose an internal key"
            )
        }
    }

    func testNewLanguageMissingKeyFallsBackToEnglishAndMissingEnglishIsDiagnosable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-I181-Localization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("en.lproj"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ko.lproj"),
            withIntermediateDirectories: true
        )
        try "\"app.about_balancebar\" = \"English fallback\";\n".write(
            to: root.appendingPathComponent("en.lproj/Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )
        try "\"localization.follow_system\" = \"시스템 언어 사용\";\n".write(
            to: root.appendingPathComponent("ko.lproj/Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )

        let store = LocalizationResourceStore(resourceRoot: root)
        XCTAssertEqual(
            store.localized(key: .keyAppAboutBalancebar, language: .korean),
            "English fallback"
        )
        XCTAssertEqual(
            store.localized(key: .keyLocalizationFollowSystem, language: .korean),
            "시스템 언어 사용"
        )
        XCTAssertEqual(
            store.localized(key: .keyAppHideBalancebar, language: .korean),
            "⟦app.hide_balancebar⟧"
        )
        XCTAssertTrue(
            store.localized(key: .keyAppHideBalancebar, language: .korean).contains("app.hide_balancebar"),
            "missing English resources remain diagnosable"
        )
    }

    func testRegionalTraditionalChineseResourcesStayDistinctAndDoNotCrossFallback() throws {
        let store = LocalizationResourceStore(bundle: testBundle)
        XCTAssertEqual(
            store.localized(key: .keyLocalizationQuota, language: .traditionalChineseTaiwan),
            "額度"
        )
        XCTAssertEqual(
            store.localized(key: .keyLocalizationQuota, language: .traditionalChineseHongKong),
            "配額"
        )
        XCTAssertNotEqual(
            store.localized(key: .keyLocalizationQuota, language: .traditionalChineseTaiwan),
            store.localized(key: .keyLocalizationQuota, language: .traditionalChineseHongKong)
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalanceBar-I184-Regional-Fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["en.lproj", "zh-Hant.lproj"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        try "\"app.about_balancebar\" = \"Legacy Taiwan resource\";\n".write(
            to: root.appendingPathComponent("zh-Hant.lproj/Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )
        try "\"app.about_balancebar\" = \"English fallback\";\n".write(
            to: root.appendingPathComponent("en.lproj/Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )

        let legacyStore = LocalizationResourceStore(resourceRoot: root)
        XCTAssertEqual(
            legacyStore.localized(key: .keyAppAboutBalancebar, language: .traditionalChineseTaiwan),
            "Legacy Taiwan resource"
        )
        XCTAssertEqual(
            legacyStore.localized(key: .keyAppAboutBalancebar, language: .traditionalChineseHongKong),
            "English fallback",
            "Hong Kong must not silently reuse a generic Taiwan resource"
        )
    }

    func testRefreshTerminologyUsesUnifiedTraditionalChineseValues() throws {
        let store = LocalizationResourceStore(bundle: testBundle)
        let expectations: [
            (key: LocalizationKey, surface: String, traditionalChineseTaiwan: String, traditionalChineseHongKong: String, simplifiedChinese: String, english: String, japanese: String)
        ] = [
            (
                .keySnapshotLastRefreshedValue,
                "Snapshot status summary",
                "最後刷新：10:00",
                "最後刷新：10:00",
                "最后刷新：10:00",
                "Last refreshed: 10:00",
                "最終更新：10:00"
            ),
            (
                .keySnapshotWaitingToRefresh,
                "Snapshot status summary",
                "等待刷新",
                "等待刷新",
                "等待刷新",
                "Waiting to Refresh",
                "更新待ち"
            ),
            (
                .keyDashboardGeneralAndRefreshPagesRefreshNow,
                "Refresh settings button",
                "立即刷新",
                "立即刷新",
                "立即刷新",
                "Refresh Now",
                "今すぐ更新"
            ),
            (
                .keyDashboardGeneralAndRefreshPagesRefresh,
                "Refresh settings title",
                "刷新",
                "刷新",
                "刷新",
                "Refresh",
                "更新"
            ),
            (
                .keyDashboardGeneralAndRefreshPagesReloadTheCurrentProviderNow,
                "Refresh settings description",
                "立即刷新目前供應商",
                "立即刷新目前供應商",
                "立即重新读取当前供应商",
                "Reload the current Provider now",
                "現在のプロバイダーをすぐに再読み込み"
            ),
            (
                .keyDashboardGeneralAndRefreshPagesRefreshSettings,
                "Refresh settings title",
                "刷新設定",
                "刷新設定",
                "刷新设置",
                "Refresh Settings",
                "更新設定"
            ),
            (
                .keyDashboardLogsPageRefresh,
                "Logs button",
                "刷新",
                "刷新",
                "刷新",
                "Refresh",
                "更新"
            ),
            (
                .keyDashboardLogsPageRefresh2,
                "Logs button accessibility label",
                "刷新",
                "刷新",
                "刷新",
                "Refresh",
                "更新"
            ),
            (
                .keyDashboardMenuPageKeepOpenAfterRefresh,
                "Menu settings title",
                "刷新後保持展開",
                "刷新後保持展開",
                "刷新后保持展开",
                "Keep Open After Refresh",
                "更新後も開いたままにする"
            ),
            (
                .keyDashboardMenuPageReopenTheMenuAfterRefreshNow,
                "Menu settings description",
                "按一下立即刷新後重新開啟選單",
                "按一下立即刷新後重新開啟選單",
                "点击立即刷新后重新打开菜单",
                "Reopen the menu after Refresh Now",
                "「今すぐ更新」後にメニューを再度開く"
            ),
            (
                .keyDashboardProviderPagesRefreshNow,
                "Provider detail and quick-switch button",
                "立即刷新",
                "立即刷新",
                "立即刷新",
                "Refresh Now",
                "今すぐ更新"
            ),
            (
                .keyStatusItemControllerRefreshNow,
                "Menu bar refresh button",
                "立即刷新",
                "立即刷新",
                "立即刷新",
                "Refresh Now",
                "今すぐ更新"
            )
        ]

        for expectation in expectations {
            let arguments = expectation.key == .keySnapshotLastRefreshedValue ? ["10:00"] : []
            let values = [
                (AppLanguage.traditionalChineseTaiwan, expectation.traditionalChineseTaiwan),
                (AppLanguage.traditionalChineseHongKong, expectation.traditionalChineseHongKong),
                (AppLanguage.simplifiedChinese, expectation.simplifiedChinese),
                (AppLanguage.english, expectation.english),
                (AppLanguage.japanese, expectation.japanese)
            ]
            for (language, expected) in values {
                XCTAssertEqual(
                    store.localized(key: expectation.key, language: language, arguments: arguments),
                    expected,
                    "unexpected \(expectation.surface) value for \(expectation.key.rawKey) in \(language)"
                )
            }
            XCTAssertFalse(
                expectation.traditionalChineseTaiwan.contains("重新整理") || expectation.traditionalChineseHongKong.contains("重新整理"),
                "confirmed Traditional Chinese values still contain the unconfirmed term for \(expectation.key.rawKey)"
            )
        }

        for directory in ["zh-Hant-TW", "zh-Hant-HK"] {
            let resourceURL = try XCTUnwrap(
                testBundle.url(forResource: directory, withExtension: "lproj")
            ).appendingPathComponent("Localizable.strings")
            let data = try Data(contentsOf: resourceURL)
            let resource = try XCTUnwrap(
                String(data: data, encoding: .utf16) ?? String(data: data, encoding: .utf8)
            )
            XCTAssertFalse(
                resource.contains("重新整理"),
                "the \(directory) resource must not retain the unconfirmed refresh term"
            )
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
        XCTAssertEqual(AppLanguage.traditionalChineseTaiwan.overviewLinkPrefixWidth, 62)
        XCTAssertEqual(AppLanguage.traditionalChineseHongKong.overviewLinkPrefixWidth, 62)
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
                    return ["关于 BalanceBar", "跟随系统", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch"]
                case .traditionalChineseTaiwan, .traditionalChineseHongKong:
                    return ["關於 BalanceBar", "跟隨系統", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch"]
                case .japanese:
                    return ["BalanceBar について", "システムに従う", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch"]
                case .english:
                    return ["About BalanceBar", "Follow System", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch"]
                case .korean:
                    return ["BalanceBar 정보", "시스템 언어 사용", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch"]
                case .spanish:
                    return ["Acerca de BalanceBar", "Seguir el sistema", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch"]
                case .german:
                    return ["Über BalanceBar", "System folgen", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch"]
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
                AppLanguage.traditionalChineseTaiwan.localizedTitle,
                expected[3]
            )
            XCTAssertEqual(
                AppLanguage.traditionalChineseHongKong.localizedTitle,
                expected[4]
            )
            XCTAssertEqual(
                AppLanguage.japanese.localizedTitle,
                expected[5]
            )
            XCTAssertEqual(
                AppLanguage.korean.localizedTitle,
                expected[6]
            )
            XCTAssertEqual(
                AppLanguage.spanish.localizedTitle,
                expected[7]
            )
            XCTAssertEqual(
                AppLanguage.german.localizedTitle,
                expected[8]
            )
        }
    }
}
