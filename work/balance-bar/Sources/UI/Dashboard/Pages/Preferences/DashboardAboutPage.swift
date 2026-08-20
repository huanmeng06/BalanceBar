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
        let githubIcon = bundle.url(forResource: "GitHub", withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:))
        let githubButton = DashboardAboutGitHubButton(
            destinationURL: githubRepositoryURL,
            icon: githubIcon,
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
    static let controlSize: CGFloat = 28
    static let iconSize: CGFloat = 18
    let destinationURL: URL
    private let openURL: (URL) -> Bool
    private var trackingAreaReference: NSTrackingArea?
    private var isHovering = false
    private var isPressing = false

    var circularBackgroundFrameForTesting: NSRect {
        Self.circularBackgroundFrame(in: bounds)
    }

    init(destinationURL: URL, icon: NSImage?, openURL: @escaping (URL) -> Bool) {
        self.destinationURL = destinationURL
        self.openURL = openURL
        super.init(frame: .zero)

        image = icon
        image?.size = NSSize(width: Self.iconSize, height: Self.iconSize)
        image?.isTemplate = true
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image?.accessibilityDescription = DashboardAboutPage.githubAccessibilityLabel
        contentTintColor = .labelColor
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        isContinuous = false
        toolTip = DashboardAboutPage.githubAccessibilityLabel
        setAccessibilityRole(.button)
        setAccessibilityLabel(DashboardAboutPage.githubAccessibilityLabel)
        setAccessibilityHelp(tr("打开 BalanceBar GitHub 项目", "Open the BalanceBar GitHub repository"))
        target = self
        action = #selector(DashboardAboutGitHubButton.activate(_:))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.controlSize).isActive = true
        heightAnchor.constraint(equalToConstant: Self.controlSize).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        super.updateTrackingAreas()
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
        needsDisplay = true
        super.mouseDown(with: event)
        isPressing = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let circleFrame = Self.circularBackgroundFrame(in: bounds)
        let hasFocus = window?.firstResponder === self
        if isHovering || isPressing || hasFocus {
            let path = NSBezierPath(ovalIn: circleFrame)
            NSGraphicsContext.saveGraphicsState()
            if isHovering || isPressing {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
                shadow.shadowBlurRadius = 4
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
            }
            let fillColor = isPressing
                ? NSColor.controlAccentColor.withAlphaComponent(0.20)
                : NSColor.controlAccentColor.withAlphaComponent(0.12)
            fillColor.setFill()
            path.fill()
            if hasFocus {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        super.draw(dirtyRect)
    }

    static func circularBackgroundFrame(in bounds: NSRect) -> NSRect {
        let diameter = min(bounds.width, bounds.height)
        return NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        ).insetBy(dx: 1, dy: 1)
    }

    @objc func activate(_ sender: Any?) {
        _ = openURL(destinationURL)
    }
}
