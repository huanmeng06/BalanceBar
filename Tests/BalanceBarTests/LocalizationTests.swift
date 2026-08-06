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
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .simplifiedChinese), "跟随系统")
        XCTAssertEqual(AppLanguage.system.localizedTitle(using: .english), "Follow System")
        XCTAssertEqual(AppLanguage.english.localizedTitle(using: .simplifiedChinese), "English")
        XCTAssertEqual(tr("中文", "English", language: .english), "English")
    }
}
