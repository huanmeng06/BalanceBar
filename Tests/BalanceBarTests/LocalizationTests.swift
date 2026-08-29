import XCTest
@testable import BalanceBar

final class LocalizationTests: XCTestCase {
    private let allLanguages: [AppLanguage] = [
        .simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong, .japanese, .english,
        .korean, .spanish, .german, .french
    ]

    private let resourceDirectories: [String: AppLanguage] = [
        "en": .english,
        "zh-Hans": .simplifiedChinese,
        "zh-Hant-TW": .traditionalChineseTaiwan,
        "zh-Hant-HK": .traditionalChineseHongKong,
        "ja": .japanese,
        "ko": .korean,
        "es": .spanish,
        "de": .german,
        "fr": .french,
        "pt": .portuguese,
        "ru": .russian,
        "it": .italian
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
            XCTAssertEqual(AppLanguage.resolved(for: .french, preferredLanguages: [preferred]), .french)
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
            ("de_AT", .german),
            ("fr", .french),
            ("fr-FR", .french),
            ("fr-CA", .french),
            ("fr_CA", .french)
        ]

        for (preferred, expected) in cases {
            XCTAssertEqual(
                AppLanguage.resolved(for: .system, preferredLanguages: [preferred]),
                expected,
                "expected \(preferred) to resolve to \(expected)"
            )
        }
    }

    func testSystemSelectionMatchesFrenchIdentifiers() {
        for preferred in ["fr", "fr-FR", "fr-CA", "fr_CA"] {
            XCTAssertEqual(
                AppLanguage.resolved(for: .system, preferredLanguages: [preferred]),
                .french,
                "expected \(preferred) to resolve to French"
            )
        }
    }

    func testSystemSelectionFallsBackToEnglishForUnknownLanguages() {
        XCTAssertEqual(AppLanguage.resolved(for: .system, preferredLanguages: ["xx-XX"]), .english)
        XCTAssertEqual(AppLanguage.resolved(for: .system, preferredLanguages: []), .english)
    }

    func testSystemSelectionMatchesPortugueseRussianAndItalianIdentifiers() {
        let cases: [(String, AppLanguage)] = [
            ("pt", .portuguese), ("pt-BR", .portuguese), ("pt-PT", .portuguese),
            ("ru", .russian), ("ru-RU", .russian),
            ("it", .italian), ("it-IT", .italian)
        ]
        for (preferred, expected) in cases {
            XCTAssertEqual(
                AppLanguage.resolved(for: .system, preferredLanguages: [preferred]),
                expected,
                "expected \(preferred) to resolve to \(expected)"
            )
        }
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
            .french
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
            [.system, .simplifiedChinese, .traditionalChineseHongKong, .traditionalChineseTaiwan, .english, .japanese, .korean, .spanish, .portuguese, .french, .german, .russian, .italian]
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
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .french), "Suivre le système")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .portuguese), "Seguir o sistema")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .russian), "Следовать системе")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .italian), "Segui il sistema")

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
            XCTAssertEqual(AppLanguage.french.localizedTitle(using: language), "Français")
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
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .french), "Suivre le système")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .portuguese), "Seguir o sistema")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .russian), "Следовать системе")
        XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: .italian), "Segui il sistema")
    }

    func testNewLanguageNamesRemainNativeAndCoreCopyIsLocalized() {
        let cases: [(AppLanguage, String, String)] = [
            (.portuguese, "Sobre o BalanceBar", "Seguir o sistema"),
            (.russian, "О BalanceBar", "Следовать системе"),
            (.italian, "Informazioni su BalanceBar", "Segui il sistema")
        ]
        for (language, about, followSystem) in cases {
            XCTAssertEqual(tr(.keyAppAboutBalancebar, language: language), about)
            XCTAssertEqual(tr(.keyLocalizationFollowSystem, language: language), followSystem)
            XCTAssertEqual(AppLanguage.portuguese.localizedTitle(using: language), "Português")
            XCTAssertEqual(AppLanguage.russian.localizedTitle(using: language), "Русский")
            XCTAssertEqual(AppLanguage.italian.localizedTitle(using: language), "Italiano")
            let rendered = tr(
                .keyDashboardGeneralAndRefreshPagesNewVersionAvailableValueValue,
                arguments: ["1.0", "1.1"],
                language: language
            )
            XCTAssertTrue(rendered.contains("1.0") && rendered.contains("1.1"))
            XCTAssertFalse(rendered.contains("%1$@") || rendered.contains("%2$@"))
        }
    }

    func testZeroSecondIconDisplayDelayCopyExistsInEverySupportedLanguage() {
        let key = LocalizationKey.keyDashboardMenuBarPageIconDisplayDelayZeroSeconds
        let expected: [AppLanguage: String] = [
            .simplifiedChinese: "0 秒",
            .traditionalChineseTaiwan: "0 秒",
            .traditionalChineseHongKong: "0 秒",
            .japanese: "0 秒",
            .english: "0 seconds",
            .korean: "0초",
            .spanish: "0 segundos",
            .german: "0 Sekunden",
            .french: "0 secondes"
        ]

        for language in allLanguages {
            XCTAssertEqual(tr(key, language: language), expected[language])
            XCTAssertFalse(tr(key, language: language).hasPrefix("⟦"))
        }
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

    func testLunaReserveCopyExistsWithRenderedValuesInEverySupportedLanguage() {
        for language in allLanguages {
            let title = tr(.keyLunaReserveTitle, language: language)
            let loading = tr(.keyLunaReserveStatusLoading, language: language)
            let status = tr(.keyLunaReserveStatusAvailable, language: language)
            let remaining = tr(
                .keyLunaReserveRemainingValue,
                arguments: ["45"],
                language: language
            )
            let reset = tr(
                .keyLunaReserveResetValue,
                arguments: ["1h30m"],
                language: language
            )
            let menuReset = tr(
                .keyLunaReserveMenuResetValue,
                arguments: ["1h30m · 9/4 04:55"],
                language: language
            )
            let menuUnavailable = tr(.keyLunaReserveMenuUnavailable, language: language)
            XCTAssertEqual(title, "Luna Reserve", "title should stay product terminology in (language)")
            XCTAssertFalse(loading.hasPrefix("⟦"), "missing Reserve loading status in (language)")
            XCTAssertFalse(status.hasPrefix("⟦"), "missing Reserve status in (language)")
            XCTAssertTrue(remaining.contains("45"), "missing remaining value in (language)")
            XCTAssertTrue(reset.contains("1h30m"), "missing reset value in (language)")
            XCTAssertTrue(menuReset.contains("1h30m · 9/4 04:55"), "missing menu reset value in (language)")
            XCTAssertFalse(menuUnavailable.hasPrefix("⟦"), "missing menu unavailable copy in (language)")
            XCTAssertFalse(remaining.contains("%1$@"), "unrendered remaining placeholder in (language)")
            XCTAssertFalse(reset.contains("%1$@"), "unrendered reset placeholder in (language)")
            XCTAssertFalse(menuReset.contains("%1$@"), "unrendered menu reset placeholder in (language)")
        }
        XCTAssertEqual(
            tr(.keyLunaReserveMenuUnavailable, language: .simplifiedChinese),
            "Luna Reserve 暂不可用"
        )
    }

    func testLunaReserveMenuDisplaySettingsCopyExistsAcrossAllLanguages() {
        let expected: [AppLanguage: [String]] = [
            .simplifiedChinese: [
                "🌙 Luna Reserve显示方式", "选择 Luna Reserve 在菜单中的显示时机", "不显示", "额度用完后显示", "始终显示",
                "隐藏已用完额度", "打开后，🌙 Luna Reserve 显示时会隐藏菜单中已归零的额度。"
            ],
            .traditionalChineseTaiwan: [
                "🌙 Luna Reserve 顯示方式", "選擇 Luna Reserve 在選單中的顯示時機", "不顯示", "額度用完後顯示", "始終顯示",
                "隱藏已用完額度", "開啟後，顯示 🌙 Luna Reserve 時會隱藏選單中已歸零的額度。"
            ],
            .traditionalChineseHongKong: [
                "🌙 Luna Reserve 顯示方式", "選擇 Luna Reserve 在選單中的顯示時機", "不顯示", "配額用完後顯示", "始終顯示",
                "隱藏已用完配額", "開啟後，顯示 🌙 Luna Reserve 時會隱藏選單中已歸零的配額。"
            ],
            .japanese: [
                "🌙 Luna Reserve の表示方法", "メニューで Luna Reserve を表示するタイミングを選択", "表示しない", "クォータ消費後に表示", "常に表示",
                "使い切ったクォータを隠す", "オンにすると、🌙 Luna Reserve の表示時に残り 0% のクォータをメニューから隠します。"
            ],
            .english: [
                "🌙 Luna Reserve Display", "Choose when Luna Reserve is shown in the menu", "Do not show", "Show after quota is used up", "Always show",
                "Hide used-up quotas", "When enabled, zeroed quotas are hidden from the menu when 🌙 Luna Reserve is shown."
            ],
            .korean: [
                "🌙 Luna Reserve 표시 방식", "메뉴에서 Luna Reserve를 표시할 시점을 선택", "표시 안 함", "할당량 소진 후 표시", "항상 표시",
                "소진된 할당량 숨기기", "켜면 🌙 Luna Reserve가 표시될 때 잔여량이 0%인 할당량을 메뉴에서 숨깁니다."
            ],
            .spanish: [
                "🌙 Mostrar Luna Reserve", "Elige cuándo mostrar Luna Reserve en el menú", "No mostrar", "Mostrar al agotar la cuota", "Mostrar siempre",
                "Ocultar cuotas agotadas", "Al activarlo, las cuotas al 0 % se ocultan del menú cuando se muestra 🌙 Luna Reserve."
            ],
            .german: [
                "🌙 Luna Reserve-Anzeige", "Zeitpunkt für die Anzeige von Luna Reserve im Menü auswählen", "Nicht anzeigen", "Nach Verbrauch des Kontingents anzeigen", "Immer anzeigen",
                "Verbrauchte Kontingente ausblenden", "Wenn aktiviert, werden Kontingente mit 0 % im Menü ausgeblendet, sobald 🌙 Luna Reserve angezeigt wird."
            ],
            .french: [
                "🌙 Affichage de Luna Reserve", "Choisissez quand afficher Luna Reserve dans le menu", "Ne pas afficher", "Afficher après épuisement du quota", "Toujours afficher",
                "Masquer les quotas épuisés", "Lorsque cette option est activée, les quotas à 0 % sont masqués du menu quand 🌙 Luna Reserve est affiché."
            ]
        ]
        let keys: [LocalizationKey] = [
            .keyDashboardMenuPageLunaReserveDisplayMode,
            .keyDashboardMenuPageLunaReserveDisplayModeDescription,
            .keyDashboardMenuPageLunaReserveDisplayModeDisabled,
            .keyDashboardMenuPageLunaReserveDisplayModeWhenQuotaExhausted,
            .keyDashboardMenuPageLunaReserveDisplayModeAlways,
            .keyDashboardMenuPageHideExhaustedQuota,
            .keyDashboardMenuPageHideExhaustedQuotaDescription
        ]

        for language in allLanguages {
            let values = keys.map { tr($0, language: language) }
            XCTAssertEqual(values, expected[language], "Luna Reserve menu settings copy for \(language)")
            XCTAssertTrue(values.allSatisfy { !$0.hasPrefix("⟦") })
        }
    }

    func testQuotaAndLunaReserveSettingsCopyMatchesIssueAcrossAllLanguages() {
        let expected: [AppLanguage: [String]] = [
            .simplifiedChinese: [
                "优先显示额度", "选择菜单栏优先显示 5 小时额度还是 7 日额度", "5 小时额度", "7 日额度",
                "重置时间样式", "选择显示剩余时长、具体时间，或同时显示两者", "剩余时长", "重置时间", "同时显示",
                "🌙 Luna Reserve 自动切换", "进入 🌙 Luna Reserve 后，自动切换菜单栏显示的额度",
                "🌙 Luna Reserve 时间", "进入 🌙 Luna Reserve 后，选择继续显示原额度或 🌙 Luna Reserve 的重置时间",
                "🌙 Luna Reserve", "原额度"
            ],
            .traditionalChineseTaiwan: [
                "優先顯示額度", "選擇選單列優先顯示 5 小時額度還是 7 日額度", "5 小時額度", "7 日額度",
                "重設時間樣式", "選擇顯示剩餘時間、具體時間，或同時顯示兩者", "剩餘時間", "重設時間", "同時顯示",
                "🌙 Luna Reserve 自動切換", "進入 🌙 Luna Reserve 後，自動切換選單列顯示的額度",
                "🌙 Luna Reserve 時間", "進入 🌙 Luna Reserve 後，選擇繼續顯示原額度或 🌙 Luna Reserve 的重設時間",
                "🌙 Luna Reserve", "原額度"
            ],
            .traditionalChineseHongKong: [
                "優先顯示配額", "選擇選單列優先顯示 5 小時配額還是 7 日配額", "5 小時配額", "7 日配額",
                "重設時間樣式", "選擇顯示剩餘時間、具體時間，或同時顯示兩者", "剩餘時間", "重設時間", "同時顯示",
                "🌙 Luna Reserve 自動切換", "進入 🌙 Luna Reserve 後，自動切換選單列顯示的配額",
                "🌙 Luna Reserve 時間", "進入 🌙 Luna Reserve 後，選擇繼續顯示原配額或 🌙 Luna Reserve 的重設時間",
                "🌙 Luna Reserve", "原配額"
            ],
            .japanese: [
                "優先表示するクォータ", "メニューバーで 5 時間クォータと 7 日間クォータのどちらを優先表示するか選択", "5時間クォータ", "7日間クォータ",
                "リセット時刻の表示形式", "残り時間、具体的なリセット時刻、または両方を表示するか選択", "残り時間", "リセット時刻", "両方を表示",
                "🌙 Luna Reserve への自動切り替え", "🌙 Luna Reserve に入った後、メニューバーに表示するクォータを自動的に切り替えます",
                "🌙 Luna Reserve のリセット時刻", "🌙 Luna Reserve に入った後、元のクォータのリセット時刻と 🌙 Luna Reserve のリセット時刻のどちらを表示するか選択",
                "🌙 Luna Reserve", "元のクォータ"
            ],
            .english: [
                "Prioritize Quota", "Choose whether the menu bar prioritizes the 5-hour or 7-day quota", "5-Hour Quota", "7-Day Quota",
                "Reset Time Display", "Choose whether to show the time remaining, the specific reset time, or both", "Time Remaining", "Reset Time", "Show Both",
                "🌙 Luna Reserve Auto-Switch", "After entering 🌙 Luna Reserve, automatically switch the quota shown in the menu bar.",
                "🌙 Luna Reserve Reset Time", "After entering 🌙 Luna Reserve, choose whether to keep showing the original quota's reset time or 🌙 Luna Reserve's.",
                "🌙 Luna Reserve", "Original Quota"
            ],
            .korean: [
                "우선 표시할 할당량", "메뉴 막대에 5시간 할당량과 7일 할당량 중 어느 것을 우선 표시할지 선택하세요", "5시간 할당량", "7일 할당량",
                "재설정 시간 표시 방식", "남은 시간, 정확한 재설정 시간 또는 둘 다 표시할지 선택하세요", "남은 시간", "재설정 시간", "둘 다 표시",
                "🌙 Luna Reserve 자동 전환", "🌙 Luna Reserve에 진입한 후 메뉴 막대에 표시할 할당량을 자동으로 전환합니다",
                "🌙 Luna Reserve 재설정 시간", "🌙 Luna Reserve에 진입한 후 원래 할당량의 재설정 시간과 🌙 Luna Reserve의 재설정 시간 중 어느 것을 표시할지 선택합니다",
                "🌙 Luna Reserve", "원래 할당량"
            ],
            .spanish: [
                "Priorizar cuota", "Elige si la barra de menús debe priorizar la cuota de 5 horas o la de 7 días", "Cuota de 5 horas", "Cuota de 7 días",
                "Formato de la hora de reinicio", "Elige si mostrar el tiempo restante, la hora exacta de reinicio o ambos", "Tiempo restante", "Hora de reinicio", "Mostrar ambos",
                "Cambio automático a 🌙 Luna Reserve", "Después de entrar en 🌙 Luna Reserve, cambia automáticamente la cuota que se muestra en la barra de menús",
                "Hora de reinicio de 🌙 Luna Reserve", "Después de entrar en 🌙 Luna Reserve, elige si mantener la hora de reinicio de la cuota original o mostrar la de 🌙 Luna Reserve",
                "🌙 Luna Reserve", "Cuota original"
            ],
            .german: [
                "Bevorzugtes Kontingent", "Auswählen, ob in der Menüleiste das 5-Stunden- oder das 7-Tage-Kontingent bevorzugt angezeigt wird", "5-Stunden-Kontingent", "7-Tage-Kontingent",
                "Format der Rücksetzzeit", "Auswählen, ob die verbleibende Zeit, die genaue Rücksetzzeit oder beides angezeigt wird", "Verbleibende Zeit", "Rücksetzzeit", "Beides",
                "Automatisch zu 🌙 Luna Reserve wechseln", "Nach dem Wechsel zu 🌙 Luna Reserve wird das in der Menüleiste angezeigte Kontingent automatisch umgeschaltet",
                "Rücksetzzeit für 🌙 Luna Reserve", "Nach dem Wechsel zu 🌙 Luna Reserve auswählen, ob die Rücksetzzeit des ursprünglichen Kontingents oder von 🌙 Luna Reserve angezeigt wird",
                "🌙 Luna Reserve", "Ursprüngliches Kontingent"
            ],
            .french: [
                "Quota à privilégier", "Choisissez si la barre des menus doit privilégier le quota de 5 heures ou celui de 7 jours", "Quota sur 5 heures", "Quota sur 7 jours",
                "Format de l’heure de réinitialisation", "Choisissez d’afficher le temps restant, l’heure exacte de réinitialisation ou les deux", "Temps restant", "Heure de réinitialisation", "Afficher les deux",
                "Basculement automatique vers 🌙 Luna Reserve", "Après l’entrée dans 🌙 Luna Reserve, le quota affiché dans la barre des menus bascule automatiquement",
                "Heure de réinitialisation de 🌙 Luna Reserve", "Après l’entrée dans 🌙 Luna Reserve, choisissez d’afficher l’heure de réinitialisation du quota d’origine ou celle de 🌙 Luna Reserve",
                "🌙 Luna Reserve", "Quota d’origine"
            ]
        ]
        let keys: [LocalizationKey] = [
            .keyDashboardMenuBarPageQuotaDisplayPriority,
            .keyDashboardMenuBarPageQuotaDisplayPriorityDescription,
            .keyDashboardMenuBarPageFiveHourQuota,
            .keyDashboardMenuBarPageSevenDayQuota,
            .keyDashboardMenuBarPageQuotaResetDisplayMode,
            .keyDashboardMenuBarPageQuotaResetDisplayModeDescription,
            .keyDashboardMenuBarPageQuotaResetDisplayRemaining,
            .keyDashboardMenuBarPageQuotaResetDisplayTarget,
            .keyDashboardMenuBarPageQuotaResetDisplayBoth,
            .keyDashboardMenuBarPageAutoSwitchLunaReserve,
            .keyDashboardMenuBarPageAutoSwitchLunaReserveDescription,
            .keyDashboardMenuBarPageLunaReserveResetTime,
            .keyDashboardMenuBarPageLunaReserveResetTimeDescription,
            .keyDashboardMenuBarPageLunaReserveResetTimeLunaReserve,
            .keyDashboardMenuBarPageLunaReserveResetTimeOriginalQuota
        ]

        for language in allLanguages {
            let values = keys.map { tr($0, language: language) }
            XCTAssertEqual(values, expected[language], "Quota and Luna Reserve settings copy for \(language)")
            XCTAssertTrue(values.allSatisfy { !$0.hasPrefix("⟦") })
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
            .german: "Diese Version ignorieren",
            .french: "Ignorer cette version"
        ]

        for language in allLanguages {
            XCTAssertEqual(tr(key, language: language), expected[language])
            XCTAssertFalse(tr(key, language: language).hasPrefix("⟦"))
        }
    }

    func testAllTypedKeysExistInEveryBundledLanguage() throws {
        let expectedKeys = Set(LocalizationKey.allCases.map(\.rawKey))
        XCTAssertEqual(expectedKeys.count, LocalizationKey.allCases.count)
        XCTAssertEqual(expectedKeys.count, 433)

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
            (.german, "de", "Über BalanceBar"),
            (.french, "fr", "À propos de BalanceBar")
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
                "上次刷新：10:00",
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
                "立即刷新目前服務商資料",
                "立即刷新目前服務商資料",
                "立即刷新当前服务商数据",
                "Refresh the current provider's data now",
                "現在のプロバイダーのデータを今すぐ更新"
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
                "刷新後保持選單開啟",
                "刷新後保持選單開啟",
                "刷新后保持菜单打开",
                "Keep the menu open after refresh",
                "更新後もメニューを開いたままにする"
            ),
            (
                .keyDashboardMenuPageReopenTheMenuAfterRefreshNow,
                "Menu settings description",
                "按一下「立即刷新」後自動重新開啟選單",
                "按一下「立即刷新」後自動重新開啟選單",
                "点击“立即刷新”后自动重新打开菜单",
                "Reopen the menu after clicking “Refresh Now”",
                "「今すぐ更新」をクリックした後、メニューを自動的に再度開く"
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

    func testStatusLinkSettingsUseViewStatusTerminologyAcrossLanguages() {
        let expected: [AppLanguage: (title: String, subtitle: String)] = [
            .simplifiedChinese: ("查看状态", "自定义“查看状态”链接"),
            .traditionalChineseTaiwan: ("檢視狀態", "自訂「檢視狀態」連結"),
            .traditionalChineseHongKong: ("檢視狀態", "自訂「檢視狀態」連結"),
            .japanese: ("ステータスを表示", "「ステータスを表示」リンクをカスタマイズ"),
            .english: ("View Status", "Customize “View Status” links"),
            .korean: ("상태 보기", "‘상태 보기’ 링크 사용자 지정"),
            .spanish: ("Ver estado", "Personalizar los enlaces de «Ver estado»"),
            .german: ("Status anzeigen", "Links für „Status anzeigen“ anpassen"),
            .french: ("Voir l’état", "Personnaliser les liens « Voir l’état »")
        ]

        for language in allLanguages {
            XCTAssertEqual(
                tr(.keyDashboardMenuPageViewStatus, language: language),
                expected[language]?.title,
                "status-link title for \(language)"
            )
            XCTAssertEqual(
                tr(.keyDashboardMenuPageShowCustomizableServiceStatusLinks, language: language),
                expected[language]?.subtitle,
                "status-link subtitle for \(language)"
            )
            XCTAssertEqual(
                tr(.keyDashboardMenuPageShowCustomizableServiceStatusLinks2, language: language),
                expected[language]?.subtitle,
                "status-link auxiliary subtitle for \(language)"
            )
        }
    }

    func testDashboardTaskOrientedSectionTitlesAreLocalizedAcrossAllLanguages() {
        let expected: [AppLanguage: (quotaAndReset: String, iconAndTaskStatus: String, layout: String, menuBehavior: String, statusLinks: String, iconDisplayMode: String)] = [
            .simplifiedChinese: ("额度与重置", "图标与任务状态", "布局", "菜单行为", "状态链接", "菜单栏图标显示"),
            .traditionalChineseTaiwan: ("配額與重設", "圖示與任務狀態", "版面", "選單行為", "狀態連結", "選單列圖示顯示"),
            .traditionalChineseHongKong: ("配額與重設", "圖示與任務狀態", "版面", "選單行為", "狀態連結", "選單列圖示顯示"),
            .japanese: ("クォータとリセット", "アイコンとタスクの状態", "レイアウト", "メニューの動作", "ステータスリンク", "メニューバーアイコンの表示"),
            .english: ("Quota & Reset", "Icon & Task Status", "Layout", "Menu behavior", "Status Links", "Menu Bar Icon Display"),
            .korean: ("할당량 및 재설정", "아이콘 및 작업 상태", "레이아웃", "메뉴 동작", "상태 링크", "메뉴 막대 아이콘 표시"),
            .spanish: ("Cuota y reinicio", "Icono y estado de la tarea", "Diseño", "Comportamiento del menú", "Enlaces de estado", "Mostrar el icono de la barra de menús"),
            .german: ("Kontingent und Zurücksetzung", "Symbol und Aufgabenstatus", "Layout", "Menüverhalten", "Statuslinks", "Anzeige des Menüsymbols"),
            .french: ("Quota et réinitialisation", "Icône et état de la tâche", "Disposition", "Comportement du menu", "Liens d’état", "Affichage de l’icône de la barre des menus")
        ]

        for language in allLanguages {
            let values = expected[language]
            XCTAssertEqual(
                tr(.keyDashboardMenuBarPageQuotaAndReset, language: language),
                values?.quotaAndReset,
                "quota/reset section title for \(language)"
            )
            XCTAssertEqual(
                tr(.keyDashboardMenuBarPageIconAndTaskStatus, language: language),
                values?.iconAndTaskStatus,
                "icon/task section title for \(language)"
            )
            XCTAssertEqual(
                tr(.keyDashboardMenuBarPageLayout, language: language),
                values?.layout,
                "layout section title for \(language)"
            )
            XCTAssertEqual(
                tr(.keyDashboardMenuPageMenuBehavior, language: language),
                values?.menuBehavior,
                "menu behavior section title for \(language)"
            )
            XCTAssertEqual(
                tr(.keyDashboardMenuPageStatusLinks, language: language),
                values?.statusLinks,
                "status links section title for \(language)"
            )
            XCTAssertEqual(
                tr(.keyDashboardMenuBarPageIconDisplayMode, language: language),
                values?.iconDisplayMode,
                "icon display title for \(language)"
            )
        }
    }

    func testCodexQuotaWindowLabelsAreLocalizedAcrossAllSupportedLanguages() {
        let store = LocalizationResourceStore(bundle: testBundle)
        let languages: [AppLanguage] = [
            .simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .english,
            .japanese,
            .korean,
            .spanish,
            .german,
            .french
        ]

        for language in languages {
            let fiveHour = store.localized(
                key: .keyResponseParsers5HourQuota,
                language: language
            )
            let sevenDay = store.localized(
                key: .keyResponseParsers7DayQuota2,
                language: language
            )

            XCTAssertFalse(fiveHour.isEmpty, "missing 5-hour label for \(language)")
            XCTAssertFalse(sevenDay.isEmpty, "missing 7-day label for \(language)")
            XCTAssertFalse(fiveHour.hasPrefix("⟦"), "unresolved 5-hour label for \(language)")
            XCTAssertFalse(sevenDay.hasPrefix("⟦"), "unresolved 7-day label for \(language)")
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
        XCTAssertEqual(AppLanguage.french.overviewLinkPrefixWidth, 72)
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
                    return ["关于 BalanceBar", "跟随系统", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
                case .traditionalChineseTaiwan, .traditionalChineseHongKong:
                    return ["關於 BalanceBar", "跟隨系統", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
                case .japanese:
                    return ["BalanceBar について", "システムに従う", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
                case .english:
                    return ["About BalanceBar", "Follow System", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
                case .korean:
                    return ["BalanceBar 정보", "시스템 언어 사용", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
                case .spanish:
                    return ["Acerca de BalanceBar", "Seguir el sistema", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
                case .german:
                    return ["Über BalanceBar", "System folgen", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
                case .french:
                    return ["À propos de BalanceBar", "Suivre le système", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
                case .portuguese:
                    return ["Sobre o BalanceBar", "Seguir o sistema", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
                case .russian:
                    return ["О BalanceBar", "Следовать системе", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
                case .italian:
                    return ["Informazioni su BalanceBar", "Segui il sistema", "简体中文", "繁體中文（台灣）", "繁體中文（香港）", "日本語", "한국어", "Español", "Deutsch", "Français"]
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
            XCTAssertEqual(
                AppLanguage.french.localizedTitle,
                expected[9]
            )
        }
    }
}
