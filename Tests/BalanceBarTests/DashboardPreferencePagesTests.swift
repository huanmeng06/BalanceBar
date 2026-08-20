import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardPreferencePagesTests: XCTestCase {
    func testRelayRoutesEachPreferenceActionOnce() {
        let relay = DashboardPreferencePageRelay()
        var calls: [(String, Bool)] = []
        relay.onToggle = { calls.append(($0, $1)) }

        let control = NSSwitch()
        control.identifier = NSUserInterfaceItemIdentifier("showMenuBarAmount")
        control.state = .off
        relay.toggle(control)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "showMenuBarAmount")
        XCTAssertEqual(calls.first?.1, false)
    }

    func testRelayActionCanPersistThroughAppPreferences() {
        let suiteName = "DashboardPreferencePagesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let relay = DashboardPreferencePageRelay()
        relay.onToggle = { identifier, enabled in
            if identifier == "showQuickSwitchMenu" {
                preferences.showQuickSwitchMenu = enabled
            }
        }
        relay.onInterval = { identifier, value in
            if identifier == "codexUsageRefreshInterval" {
                preferences.codexUsageRefreshInterval = value
            }
        }

        let toggle = NSSwitch()
        toggle.identifier = NSUserInterfaceItemIdentifier("showQuickSwitchMenu")
        toggle.state = .off
        relay.toggle(toggle)
        let interval = NSPopUpButton()
        interval.identifier = NSUserInterfaceItemIdentifier("codexUsageRefreshInterval")
        interval.addItem(withTitle: "5")
        interval.item(at: 0)?.representedObject = NSNumber(value: 5)
        interval.selectItem(at: 0)
        relay.interval(interval)

        XCTAssertFalse(preferences.showQuickSwitchMenu)
        XCTAssertEqual(preferences.codexUsageRefreshInterval, 5)
    }

    func testMenuBarPreviewPresentationUsesSharedSnapshotValues() {
        let snapshot = Snapshot.official("OpenAI", 72, "7-day", "2h", Date(timeIntervalSince1970: 1))
        let presentation = DashboardMenuBarPage.presentation(
            for: snapshot,
            showAmount: true,
            showReset: true,
            resolving: { $0 }
        )

        XCTAssertEqual(presentation.primary, snapshot.menuBarPrimary)
        XCTAssertEqual(presentation.secondary, snapshot.menuBarSecondary)
        XCTAssertTrue(presentation.hasSecondary)
        XCTAssertFalse(presentation.isBalance)
    }

    func testLogsKeepViewerTextAndSeverityStyling() {
        let text = "[12:00:00] [ERROR] [configuration] value=42%"
        let styled = DashboardLogsPage.styledLog(text)
        let nsText = text as NSString

        XCTAssertEqual(styled.string, text)
        XCTAssertNotNil(styled.attribute(.foregroundColor, at: nsText.range(of: "[ERROR]").location, effectiveRange: nil))
        XCTAssertNotNil(styled.attribute(.font, at: nsText.range(of: "42").location, effectiveRange: nil))
    }

    func testAboutVersionPreservesBundleFallbackAndDevelopmentSuffix() {
        XCTAssertEqual(
            DashboardAboutPage.displayedVersion(shortVersion: nil, isDevBuild: false),
            "0.11.14"
        )
        XCTAssertEqual(
            DashboardAboutPage.displayedVersion(shortVersion: "0.11.20", isDevBuild: true),
            "0.11.20 · Dev"
        )
    }

    func testAboutPageGitHubEntryIsCenteredAccessibleAndOpensOnce() throws {
        var openedURLs: [URL] = []
        let resourceBundle = Bundle(for: DashboardAboutGitHubButton.self)
        let page = DashboardAboutPage.make(
            bundle: resourceBundle,
            devBundleIdentifier: "com.huanmeng06.BalanceBar.dev",
            openURL: { url in
                openedURLs.append(url)
                return true
            }
        )
        page.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
        page.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(descendant(withIdentifier: "about.githubRow", in: page) as? NSStackView)
        let button = try XCTUnwrap(descendant(withIdentifier: "about.githubButton", in: page) as? DashboardAboutGitHubButton)
        let rowCenter = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: page).x

        XCTAssertEqual(rowCenter, page.bounds.midX, accuracy: 0.5)
        XCTAssertNotNil(button.image)
        XCTAssertNotNil(resourceBundle.url(forResource: "GitHub", withExtension: "svg"))
        XCTAssertFalse(button.isBordered)
        XCTAssertEqual(button.bezelStyle, .regularSquare)
        XCTAssertEqual(button.bounds.width, button.bounds.height, accuracy: 0.5)
        XCTAssertEqual(button.circularBackgroundFrameForTesting.width, button.circularBackgroundFrameForTesting.height, accuracy: 0.5)
        XCTAssertEqual(button.circularBackgroundFrameForTesting.midX, button.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(button.circularBackgroundFrameForTesting.midY, button.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(button.destinationURL, DashboardAboutPage.githubRepositoryURL)
        let accessibilityLabel = button.accessibilityLabel()
        XCTAssertTrue(accessibilityLabel == "GitHub 项目" || accessibilityLabel == "GitHub repository")

        XCTAssertTrue(button.target === button)
        XCTAssertEqual(button.action, #selector(DashboardAboutGitHubButton.activate(_:)))
        button.activate(nil)

        XCTAssertEqual(openedURLs, [DashboardAboutPage.githubRepositoryURL])
    }

    private func descendant(withIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let match = descendant(withIdentifier: identifier, in: child) { return match }
        }
        return nil
    }
}
