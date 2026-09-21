import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardAccessibilityTests: XCTestCase {
    func testStandardSwitchBindsTitleUIElementAndUsesDetailAsHelp() {
        let control = NSSwitch()
        let row = SettingsRowView(
            title: "Silent Launch",
            detail: "Start in the background without opening the dashboard.",
            accessoryView: control
        )

        XCTAssertIdentical(control.accessibilityTitleUIElement() as AnyObject?, row.titleLabel)
        XCTAssertFalse(row.titleLabel.isAccessibilityElement())
        XCTAssertEqual(
            control.accessibilityHelp(),
            "Start in the background without opening the dashboard."
        )
        XCTAssertFalse(row.detailLabel.isAccessibilityElement())
        XCTAssertFalse(row.isAccessibilityElement())
    }

    func testSemanticSubtitleHelpUsesSourceTextWithoutLayoutBreaks() throws {
        let text = "Fine-tune the icon's vertical position Y axis + 0.0 pt"
        let suffix = "Y axis + 0.0 pt"
        let range = (text as NSString).range(of: suffix)
        XCTAssertNotEqual(range.location, NSNotFound)
        let subtitle = DashboardSettingsComponents.makeSubtitleLabel(
            LocalizedSubtitle(
                text: text,
                semanticGroups: [range],
                lineBreakBeforeSemanticGroups: [range]
            )
        )
        let control = NSSwitch()
        let row = SettingsRowView(
            title: "Icon Offset",
            detail: text,
            detailLabel: subtitle,
            accessoryView: control
        )

        XCTAssertIdentical(row.detailLabel, subtitle)
        XCTAssertEqual(control.accessibilityHelp(), text)
        XCTAssertEqual(
            (subtitle as? SettingsSemanticSubtitleLabel)?.sourceAccessibilityText,
            text
        )
    }

    func testCompactNumericFieldBindsOnInnerFieldNotStack() {
        let accessory = DashboardSettingsComponents.makeNumericTextField(
            value: "10.00",
            placeholder: "0.01",
            capacityTemplate: DashboardSettingsComponents.amountCapacityTemplate
        )
        let row = SettingsRowView(
            title: "Low Balance Display Threshold",
            detail: "Keep the progress bar red below this amount.",
            accessoryView: accessory
        )

        XCTAssertIdentical(
            DashboardSettingsAccessibility.primaryStandardControl(in: accessory),
            accessory.field
        )
        XCTAssertIdentical(
            accessory.field.accessibilityTitleUIElement() as AnyObject?,
            row.titleLabel
        )
        XCTAssertNil(accessory.accessibilityTitleUIElement())
        XCTAssertFalse(row.titleLabel.isAccessibilityElement())
        XCTAssertEqual(
            accessory.field.accessibilityHelp(),
            "Keep the progress bar red below this amount."
        )
    }

    func testExplicitCheckboxLabelIsNotReplacedByRowTitle() {
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.setAccessibilityLabel("Green")
        let row = SettingsRowView(
            title: "Displayed Colors",
            accessoryView: checkbox
        )

        XCTAssertNil(DashboardSettingsAccessibility.primaryStandardControl(in: checkbox))
        XCTAssertEqual(checkbox.accessibilityLabel(), "Green")
        XCTAssertNil(checkbox.accessibilityTitleUIElement())
        XCTAssertEqual(row.titleLabel.stringValue, "Displayed Colors")
    }

    func testMultiButtonColorStackDoesNotBindRowTitleToAnyCheckbox() {
        let green = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        green.setAccessibilityLabel("Green")
        let red = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        red.setAccessibilityLabel("Red")
        let greenSwatch = NSImageView()
        greenSwatch.setAccessibilityElement(false)
        let redSwatch = NSImageView()
        redSwatch.setAccessibilityElement(false)
        let stack = NSStackView(views: [
            NSStackView(views: [green, greenSwatch]),
            NSStackView(views: [red, redSwatch])
        ])
        let row = SettingsRowView(
            title: "Displayed Colors",
            accessoryView: stack
        )

        XCTAssertNil(DashboardSettingsAccessibility.primaryStandardControl(in: stack))
        XCTAssertEqual(green.accessibilityLabel(), "Green")
        XCTAssertEqual(red.accessibilityLabel(), "Red")
        XCTAssertNil(green.accessibilityTitleUIElement())
        XCTAssertNil(red.accessibilityTitleUIElement())
        XCTAssertEqual(row.titleLabel.stringValue, "Displayed Colors")
        XCTAssertEqual(greenSwatch.isAccessibilityElement(), false)
        XCTAssertEqual(redSwatch.isAccessibilityElement(), false)
    }

    func testPopUpButtonBindsTitleEvenWhenSelectedItemIsDefaultLabel() {
        let popup = DashboardSettingsComponents.makePopUpButton(
            items: [
                DashboardSettingsComponents.PopUpItem(title: "English"),
                DashboardSettingsComponents.PopUpItem(title: "Deutsch")
            ],
            selectedIndex: 0,
            target: nil,
            action: nil
        )
        let row = SettingsRowView(
            title: "Language",
            accessoryView: popup
        )

        XCTAssertEqual(popup.titleOfSelectedItem, "English")
        XCTAssertIdentical(popup.accessibilityTitleUIElement() as AnyObject?, row.titleLabel)
        XCTAssertFalse(row.titleLabel.isAccessibilityElement())
    }

    func testRowWithoutAccessoryKeepsTitleAndDetailReadable() {
        let row = SettingsRowView(
            title: "No Results",
            detail: "Try a different search."
        )

        XCTAssertNil(DashboardSettingsAccessibility.primaryStandardControl(in: nil))
        XCTAssertEqual(row.titleLabel.stringValue, "No Results")
        XCTAssertEqual(row.detailLabel.stringValue, "Try a different search.")
        XCTAssertNil(row.titleLabel.accessibilityTitleUIElement())
    }

    func testQuotaSliderDecorationsStayNonElementsAndInteractiveSlidersKeepRole() {
        let slider = QuotaColorThresholdSlider(configuration: .default)
        defer { slider.teardown() }
        slider.frame = NSRect(x: 0, y: 0, width: 420, height: 50)
        slider.layoutSubtreeIfNeeded()

        XCTAssertNil(DashboardSettingsAccessibility.primaryStandardControl(in: slider))
        let sliders = descendants(of: slider, as: NSSlider.self)
        XCTAssertFalse(sliders.isEmpty)
        let interactive = sliders.filter { $0.isAccessibilityElement() }
        XCTAssertFalse(interactive.isEmpty)
        for item in interactive {
            XCTAssertEqual(item.accessibilityRole(), .slider)
        }
        let decorative = sliders.filter { !$0.isAccessibilityElement() }
        XCTAssertFalse(decorative.isEmpty)
    }

    func testMenuColorSwatchesAreNotAccessibilityElements() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-445-dashboard-accessibility.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let composition = appDelegate.dashboardCompositionForTesting
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .menu))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let page = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)

        let green = try XCTUnwrap(
            descendant(in: page, as: NSButton.self) {
                $0.identifier?.rawValue == "quotaProgressColor.green"
            }
        )
        XCTAssertEqual(green.accessibilityLabel(), tr(.keyDashboardMenuPageColorGreen))
        XCTAssertNil(green.accessibilityTitleUIElement())
        let itemStack = try XCTUnwrap(green.superview as? NSStackView)
        let swatch = try XCTUnwrap(itemStack.arrangedSubviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertEqual(swatch.isAccessibilityElement(), false)
    }

    func testRebuildRebindsTitleUIElementToNewTitleLabelInstance() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-445-rebuild-ax.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let composition = appDelegate.dashboardCompositionForTesting
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let originalPage = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        let originalSwitch = try XCTUnwrap(
            descendant(in: originalPage, as: NSSwitch.self) {
                $0.identifier?.rawValue == AppPreferences.silentLaunchKey
            }
        )
        let originalTitle = originalSwitch.accessibilityTitleUIElement() as AnyObject?
        XCTAssertNotNil(originalTitle)
        XCTAssertIdentical(
            originalTitle,
            SettingsRowView.enclosing(originalSwitch)?.titleLabel
        )

        composition.rebuild()
        window.layoutIfNeeded()
        window.displayIfNeeded()

        XCTAssertNil(originalPage.superview)
        XCTAssertNil(originalSwitch.window)
        let restoredPage = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        let restoredSwitch = try XCTUnwrap(
            descendant(in: restoredPage, as: NSSwitch.self) {
                $0.identifier?.rawValue == AppPreferences.silentLaunchKey
            }
        )
        XCTAssertFalse(restoredSwitch === originalSwitch)
        let restoredTitle = restoredSwitch.accessibilityTitleUIElement() as AnyObject?
        XCTAssertIdentical(
            restoredTitle,
            SettingsRowView.enclosing(restoredSwitch)?.titleLabel
        )
        XCTAssertFalse(restoredTitle === originalTitle)
    }

    private func descendant<T: NSView>(
        in view: NSView,
        as type: T.Type,
        where predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = view as? T, predicate(match) {
            return match
        }
        for child in view.subviews {
            if let match = descendant(in: child, as: type, where: predicate) {
                return match
            }
        }
        return nil
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var matches: [T] = []
        if let match = view as? T {
            matches.append(match)
        }
        for child in view.subviews {
            matches.append(contentsOf: descendants(of: child, as: type))
        }
        return matches
    }
}
