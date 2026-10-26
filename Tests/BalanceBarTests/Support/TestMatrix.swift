import AppKit
@testable import BalanceBar

/// Representative samples for layout / copy tests, so they do not iterate the full
/// language × appearance × width matrix. Localization completeness is covered
/// separately by `LocalizationTests`, which still checks every bundled language.
enum TestMatrix {
    /// English baseline, Chinese primary, and the two languages with the longest
    /// text (German, Russian), which are the likeliest to truncate.
    static let representativeLanguages: [AppLanguage] = [.english, .simplifiedChinese, .german, .russian]

    /// Pure layout tests only need one appearance; colour assertions use `colorAppearances`.
    static let layoutAppearances: [NSAppearance.Name] = [.aqua]
    static let colorAppearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// Narrowest and widest supported widths.
    static let minAndMaxWidths: [CGFloat] = [420, 760]

    /// Starting pages for "state is independent of where the user came from" tests:
    /// one ordinary page and one with special search/layout logic.
    static let representativeStartingSections: [DashboardSection] = [.menuBar, .advanced]
}
