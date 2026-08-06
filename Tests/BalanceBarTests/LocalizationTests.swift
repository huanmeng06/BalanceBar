import XCTest
@testable import BalanceBar

final class LocalizationTests: XCTestCase {
    func testExplicitLanguageSelection() {
        XCTAssertTrue(AppLanguage.usesSimplifiedChinese(for: .simplifiedChinese, preferredLanguage: "en-US"))
        XCTAssertFalse(AppLanguage.usesSimplifiedChinese(for: .english, preferredLanguage: "zh-CN"))
    }

    func testSystemSelectionUsesControlledPreferredLanguage() {
        XCTAssertTrue(AppLanguage.usesSimplifiedChinese(for: .system, preferredLanguage: "zh-CN"))
        XCTAssertFalse(AppLanguage.usesSimplifiedChinese(for: .system, preferredLanguage: "en-US"))
    }

    func testLocalizedTitlesAndTranslation() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "appLanguage")
        defer {
            if let previous { defaults.set(previous, forKey: "appLanguage") }
            else { defaults.removeObject(forKey: "appLanguage") }
        }

        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.system.localizedTitle, "跟随系统")
        XCTAssertEqual(AppLanguage.english.localizedTitle, "English")

        defaults.set(AppLanguage.english.rawValue, forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.system.localizedTitle, "Follow System")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localizedTitle, "Simplified Chinese")
        XCTAssertEqual(tr("中文", "English", language: .english), "English")
    }
}
