import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class RefreshRateHelpTests: XCTestCase {
    func testTheHelpExplainsTheFloorInPlainWordsInEveryLanguage() {
        for language in AppLanguage.allCases where language != .system {
            let content = RefreshRateHelpContentView(selectedInterval: 60, language: language)
            let texts = allText(in: content)
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpTitle, language: language)), "\(language) title")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpLine1, language: language)), "\(language) explanation")
            XCTAssertTrue(texts.contains(tr(.keyRefreshHelpLine3, language: language)), "\(language) Mod hint")
            XCTAssertEqual(content.frame.width, RefreshRateHelpContentView.width)
            XCTAssertGreaterThan(content.frame.height, 150, "\(language) content is laid out")
            XCTAssertLessThan(content.frame.height, 600, "\(language) content stays compact")
        }
    }

    func testTheButtonOpensAndClosesThePopover() throws {
        let button = RefreshRateHelpButton(selectedInterval: { 90 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        window.contentView?.addSubview(button)
        button.frame.origin = NSPoint(x: 20, y: 60)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertEqual(button.toolTip, tr(.keyRefreshHelpTitle))
        button.performClick(nil)
        let popoverShown = try XCTUnwrap(Mirror(reflecting: button).children.first { $0.label == "popover" }?.value as? NSPopover?)
        XCTAssertTrue(popoverShown?.isShown == true)
        button.performClick(nil)
    }

    /// Renders the explanation in a few languages for a visual self-check (set BB_HELP_RENDER_DIR).
    func testRenderTheHelpWhenAskedTo() throws {
        guard let directory = ProcessInfo.processInfo.environment["BB_HELP_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for language in [AppLanguage.simplifiedChinese, .english, .russian] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let content = RefreshRateHelpContentView(selectedInterval: 60, language: language)
                content.appearance = NSAppearance(named: appearance)
                content.wantsLayer = true
                content.effectiveAppearance.performAsCurrentDrawingAppearance {
                    content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                content.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("help-\(language.rawValue)-\(name).png"))
            }
        }
    }

    private func allText(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(allText)
    }
}
