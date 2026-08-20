import AppKit

enum DashboardAboutPage {
    static let fallbackShortVersion = "0.11.14"
    static let githubRepositoryURL = URL(string: "https://github.com/huanmeng06/BalanceBar")!
    static let githubAccessibilityLabel = tr("GitHub 项目", "GitHub repository")

    static func displayedVersion(shortVersion: String?, isDevBuild: Bool) -> String {
        let value = shortVersion ?? fallbackShortVersion
        return value + (isDevBuild ? " · Dev" : "")
    }

    static func make(
        bundle: Bundle = .main,
        devBundleIdentifier: String,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> NSView {
        let root = NSView()
        let icon = NSImageView()
        if let iconURL = bundle.url(forResource: "BalanceBar", withExtension: "icns") {
            icon.image = NSImage(contentsOf: iconURL)
        }
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let name = NSTextField(labelWithString: "BalanceBar")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = NSTextField(labelWithString: tr(
            "版本 \(displayedVersion(shortVersion: appVersion, isDevBuild: bundle.bundleIdentifier == devBundleIdentifier))",
            "Version \(displayedVersion(shortVersion: appVersion, isDevBuild: bundle.bundleIdentifier == devBundleIdentifier))"
        ))
        version.textColor = .secondaryLabelColor
        let detail = NSTextField(labelWithString: tr(
            "基于 CC Switch 的菜单栏余量查看工具",
            "A CC Switch-based menu bar balance viewer"
        ))
        detail.textColor = .secondaryLabelColor
        let githubButton = DashboardAboutGitHubButton(
            destinationURL: githubRepositoryURL,
            openURL: openURL
        )
        githubButton.identifier = NSUserInterfaceItemIdentifier("about.githubButton")
        let githubRow = NSStackView(views: [githubButton])
        githubRow.identifier = NSUserInterfaceItemIdentifier("about.githubRow")
        githubRow.orientation = .horizontal
        githubRow.alignment = .centerY
        githubRow.spacing = 0

        let stack = NSStackView(views: [icon, name, version, detail, githubRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 92)
        ])
        return root
    }
}

final class DashboardAboutGitHubButton: NSButton {
    let destinationURL: URL
    private let openURL: (URL) -> Bool

    init(destinationURL: URL, openURL: @escaping (URL) -> Bool) {
        self.destinationURL = destinationURL
        self.openURL = openURL
        super.init(frame: .zero)

        image = DashboardAboutGitHubButton.makeGitHubIcon()
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image?.accessibilityDescription = DashboardAboutPage.githubAccessibilityLabel
        isBordered = true
        bezelStyle = .texturedRounded
        showsBorderOnlyWhileMouseInside = true
        focusRingType = .exterior
        setButtonType(.momentaryPushIn)
        isContinuous = false
        toolTip = DashboardAboutPage.githubAccessibilityLabel
        setAccessibilityRole(.button)
        setAccessibilityLabel(DashboardAboutPage.githubAccessibilityLabel)
        setAccessibilityHelp(tr("打开 BalanceBar GitHub 项目", "Open the BalanceBar GitHub repository"))
        target = self
        action = #selector(activate(_:))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    @objc private func activate(_ sender: Any?) {
        _ = openURL(destinationURL)
    }

    private static func makeGitHubIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        image.accessibilityDescription = DashboardAboutPage.githubAccessibilityLabel
        image.lockFocus()

        let bounds = NSRect(x: 2, y: 2, width: 14, height: 14)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let leftEar = NSBezierPath()
        leftEar.move(to: NSPoint(x: 3.2, y: 13.4))
        leftEar.line(to: NSPoint(x: 4.1, y: 17.5))
        leftEar.line(to: NSPoint(x: 7.1, y: 14.9))
        leftEar.close()
        leftEar.fill()

        let rightEar = NSBezierPath()
        rightEar.move(to: NSPoint(x: 14.8, y: 13.4))
        rightEar.line(to: NSPoint(x: 13.9, y: 17.5))
        rightEar.line(to: NSPoint(x: 10.9, y: 14.9))
        rightEar.close()
        rightEar.fill()

        NSGraphicsContext.current?.compositingOperation = .clear
        NSColor.clear.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5.4, y: 7.1, width: 2.1, height: 2.1)).fill()
        NSBezierPath(ovalIn: NSRect(x: 10.5, y: 7.1, width: 2.1, height: 2.1)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        image.unlockFocus()
        return image
    }
}
