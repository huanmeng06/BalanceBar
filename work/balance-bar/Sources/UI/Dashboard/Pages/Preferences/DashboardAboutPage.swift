import AppKit

enum DashboardAboutPage {
    static let fallbackShortVersion = "0.11.14"

    static func displayedVersion(shortVersion: String?, isDevBuild: Bool) -> String {
        let value = shortVersion ?? fallbackShortVersion
        return value + (isDevBuild ? " · Dev" : "")
    }

    static func make(bundle: Bundle = .main, devBundleIdentifier: String) -> NSView {
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
        let stack = NSStackView(views: [icon, name, version, detail])
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
