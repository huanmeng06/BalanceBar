import AppKit

enum DashboardAboutPage {
    static let fallbackShortVersion = "0.11.14"
    static let githubRepositoryURL = URL(string: "https://github.com/huanmeng06/BalanceBar")!
    static let githubAccessibilityLabel = tr(.keyDashboardAboutPageGithubRepository)

    struct BuildVersion {
        let shortVersion: String?
        let isDevBuild: Bool
        let pullRequestNumber: Int?
        let sha: String?
        let releaseRunID: String?

        init(shortVersion: String?, isDevBuild: Bool, buildPR: String? = nil, buildSHA: String? = nil, releaseRunID: String? = nil) {
            self.shortVersion = shortVersion
            self.isDevBuild = isDevBuild
            if isDevBuild, let buildPR, buildPR.range(of: #"\A[0-9]+\z"#, options: .regularExpression) != nil,
               let number = Int(buildPR), number > 0 {
                pullRequestNumber = number
            } else {
                pullRequestNumber = nil
            }
            sha = isDevBuild ? buildSHA.flatMap {
                $0.range(of: #"\A[0-9a-fA-F]{7,}\z"#, options: .regularExpression) == nil ? nil : $0
            } : nil
            self.releaseRunID = isDevBuild ? nil : releaseRunID.flatMap {
                $0.range(of: #"\A[0-9]+\z"#, options: .regularExpression) == nil ? nil : $0
            }
        }

        init(bundle: Bundle, devBundleIdentifier: String) {
            let isDevBuild = bundle.bundleIdentifier == devBundleIdentifier
            self.init(
                shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                isDevBuild: isDevBuild,
                buildPR: isDevBuild ? bundle.object(forInfoDictionaryKey: "BalanceBarBuildPR") as? String : nil,
                buildSHA: isDevBuild ? bundle.object(forInfoDictionaryKey: "BalanceBarBuildSHA") as? String : nil,
                releaseRunID: bundle.object(forInfoDictionaryKey: "BalanceBarReleaseRunID") as? String
            )
        }

        var value: String {
            let base = shortVersion ?? DashboardAboutPage.fallbackShortVersion
            guard isDevBuild else { return base }
            if let pullRequestNumber { return "\(base) (Dev #\(pullRequestNumber))" }
            if let sha { return "\(base) (Dev \(sha.prefix(7)))" }
            return "\(base) (Dev)"
        }

        var title: String { tr(.keyDashboardAboutPageVersionValue, arguments: [value]) }
    }

    static func make(
        bundle: Bundle = .main,
        devBundleIdentifier: String,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> NSView {
        let root = NSView()
        let icon = NSImageView(image: BalanceBarAppIcon.image())
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let name = NSTextField(labelWithString: "BalanceBar")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        let buildVersion = BuildVersion(bundle: bundle, devBundleIdentifier: devBundleIdentifier)
        let version = NSTextField(labelWithString: buildVersion.title)
        version.identifier = NSUserInterfaceItemIdentifier("about.version")
        version.textColor = .secondaryLabelColor
        let detail = NSTextField(labelWithString: tr(.keyDashboardAboutPageACcSwitchBasedMenuBarBalanceViewer))
        detail.textColor = .secondaryLabelColor
        var aboutViews: [NSView] = [icon, name, version]
        if let runID = buildVersion.releaseRunID,
           let runURL = URL(string: "https://github.com/huanmeng06/BalanceBar/actions/runs/\(runID)") {
            aboutViews.append(DashboardAboutRunButton(runID: runID, destinationURL: runURL, openURL: openURL))
        }
        aboutViews.append(detail)
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

        let stack = NSStackView(views: aboutViews + [githubRow])
        stack.identifier = DashboardPageSearch.aboutContentIdentifier
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.safeAreaLayoutGuide.centerXAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 92)
        ])
        return root
    }
}

final class DashboardAboutRunButton: NSButton {
    let destinationURL: URL
    private let openURL: (URL) -> Bool

    init(runID: String, destinationURL: URL, openURL: @escaping (URL) -> Bool) {
        self.destinationURL = destinationURL
        self.openURL = openURL
        super.init(frame: .zero)
        title = tr(.keyDashboardAboutPageGithubActionsBuild, arguments: [runID])
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.controlAccentColor])
        isBordered = false
        bezelStyle = .regularSquare
        toolTip = tr(.keyDashboardAboutPageGithubActionsBuildHelp)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(tr(.keyDashboardAboutPageGithubActionsBuildHelp))
        identifier = NSUserInterfaceItemIdentifier("about.githubActionsRun")
        target = self
        action = #selector(activate(_:))
    }

    required init?(coder: NSCoder) { nil }

    @objc func activate(_ sender: Any?) {
        _ = openURL(destinationURL)
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
        setAccessibilityHelp(tr(.keyDashboardAboutPageOpenTheBalancebarGithubRepository))
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
