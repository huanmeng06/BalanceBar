import AppKit
import Darwin

final class DashboardAboutPage {
    static let fallbackShortVersion = "0.11.14"
    static let githubRepositoryURL = URL(string: "https://github.com/huanmeng06/BalanceBar")!
    static let ccSwitchRepositoryURL = URL(string: "https://github.com/farion1231/cc-switch")!

    struct BuildVersion {
        enum Channel: String {
            case formal
            case beta
            case dev
        }

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
            let base = number
            guard isDevBuild else { return base }
            if let pullRequestNumber { return "\(base) (Dev #\(pullRequestNumber))" }
            if let sha { return "\(base) (Dev \(sha.prefix(7)))" }
            return "\(base) (Dev)"
        }

        var title: String { tr(.keyDashboardAboutPageVersionValue, arguments: [value]) }

        var number: String { shortVersion ?? DashboardAboutPage.fallbackShortVersion }

        var channel: Channel? {
            guard let shortVersion, let version = AppSemanticVersion(shortVersion) else { return nil }
            if isDevBuild { return .dev }
            if version.isFormalRelease { return .formal }
            if version.isDevelopmentRelease { return .beta }
            return nil
        }

        var channelTitle: String? {
            switch channel {
            case .formal: return tr(.keyDashboardAboutPageFormal)
            case .beta: return "Beta"
            case .dev: return pullRequestNumber.map { "Dev #\($0)" } ?? "Dev"
            case nil: return nil
            }
        }

        var displayValue: String {
            guard let channelTitle else { return number }
            return tr(.keyDashboardAboutPageVersionChannel, arguments: [number, channelTitle])
        }

        var devPullRequest: URL? {
            pullRequestNumber.map { DashboardAboutPage.githubRepositoryURL.appendingPathComponent("pull/\($0)") }
        }

        var releaseTag: String? {
            guard channel == .formal || channel == .beta, let shortVersion,
                  let semanticVersion = AppSemanticVersion(shortVersion) else { return nil }
            return "v\(semanticVersion)"
        }

        var releaseNotesURL: URL {
            let releases = DashboardAboutPage.githubRepositoryURL.appendingPathComponent("releases")
            return releaseTag.map { releases.appendingPathComponent("tag/\($0)") } ?? releases
        }

        var buildDestination: URL? {
            let repository = DashboardAboutPage.githubRepositoryURL
            if let releaseRunID { return repository.appendingPathComponent("actions/runs/\(releaseRunID)") }
            if let devPullRequest { return devPullRequest }
            return sha.map { repository.appendingPathComponent("commit/\($0)") }
        }

        var buildDescription: String {
            if let releaseRunID { return "GitHub Actions #\(releaseRunID)" }
            let values = [pullRequestNumber.map { "PR #\($0)" }, sha.map { String($0.prefix(7)) }]
            return values.compactMap { $0 }.joined(separator: " · ")
        }

        var clipboardText: String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            var build = [CChar](repeating: 0, count: 64)
            var size = build.count
            let result = sysctlbyname("kern.osversion", &build, &size, nil, 0)
            let osBuild = result == 0 ? String(cString: build) : nil
            // hw.optional.arm64 reports the hardware even when translated by Rosetta.
            var arm64: Int32 = 0
            var architectureSize = MemoryLayout.size(ofValue: arm64)
            sysctlbyname("hw.optional.arm64", &arm64, &architectureSize, nil, 0)
            let version = "\(os.majorVersion).\(os.minorVersion)"
            return clipboardText(
                osVersion: os.patchVersion == 0 ? version : "\(version).\(os.patchVersion)",
                osBuild: osBuild, architecture: arm64 == 1 ? "Apple Silicon" : "Intel",
                language: AppLanguage.resolved.resourceLocalization
            )
        }

        func clipboardText(osVersion: String, osBuild: String?, architecture: String, language: String) -> String {
            let channelName = (isDevBuild ? Channel.dev : channel).map { " (\($0.rawValue))" } ?? ""
            let osBuildLabel = osBuild.map { " (\($0))" } ?? ""
            let build = buildDescription.isEmpty ? "local" : (isDevBuild ? "Dev " : "") + buildDescription
            return """
            BalanceBar \(number)\(channelName)
            Build: \(build)
            macOS \(osVersion)\(osBuildLabel) · \(architecture)
            Language: \(language)
            """
        }
    }

    private weak var updateRow: SettingsRowView?
    private weak var updateButton: NSButton?
    private weak var notesButton: NSButton?
    private weak var updateBadge: DashboardUpdateBadgeView?

    func make(
        bundle: Bundle = .main,
        devBundleIdentifier: String,
        relay: DashboardPreferencePageRelay,
        updateState: UpdateCheckState,
        forSearch: Bool = false,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        writeClipboard: @escaping (String) -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        }
    ) -> NSView {
        let version = BuildVersion(bundle: bundle, devBundleIdentifier: devBundleIdentifier)
        let header = makeHeader(version: version, openURL: openURL)
        let copy = DashboardAboutActionButton(
            title: tr(.keyDashboardAboutPageCopyVersion),
            action: { writeClipboard(version.clipboardText) }
        )
        copy.identifier = .init("about.copyVersion")
        copy.bezelStyle = .rounded
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.imagePosition = .imageLeading
        copy.copyConfirmation = true
        // Reserve space for either label so confirmation cannot reflow the row.
        let confirmation = NSButton(title: tr(.keyDashboardAboutPageCopied) + " ✓", target: nil, action: nil)
        confirmation.bezelStyle = copy.bezelStyle
        copy.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(copy.intrinsicContentSize.width, confirmation.intrinsicContentSize.width)
        ).isActive = true
        let versionLabel = NSTextField(labelWithString: version.displayValue)
        versionLabel.identifier = .init("about.version")
        versionLabel.isSelectable = true
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        let versionRow = SettingsRowView(
            title: tr(.keyDashboardAboutPageVersion),
            accessoryView: adaptiveControls([versionLabel, copy], stacksBesideLabel: true)
        )

        var versionRows = [makeUpdateRow(relay: relay), versionRow]
        if version.isDevBuild || version.releaseRunID != nil {
            let buildLink = version.buildDestination.map { destination in
                let title = version.isDevBuild ? version.buildDescription
                    : tr(.keyDashboardAboutPageGithubActionsBuild, arguments: [version.releaseRunID ?? ""])
                let help = tr(.keyDashboardAboutPageGithubActionsBuildHelp)
                let button = DashboardAboutActionButton.link(title, help: help, arrow: true) { _ = openURL(destination) }
                button.identifier = .init("about.githubActionsRun")
                return button
            }
            let row = SettingsRowView(
                title: tr(.keyDashboardAboutPageBuild),
                detail: tr(version.isDevBuild ? .keyDashboardAboutPageDevBuild : .keyDashboardAboutPageReleaseBuild),
                accessoryView: buildLink
            )
            row.identifier = .init("about.build")
            versionRows.append(row)
        }
        let versions = SettingsSectionView(title: tr(.keyDashboardAboutPageVersionAndUpdate), contentViews: versionRows)
        let links = SettingsSectionView(
            title: tr(.keyDashboardAboutPageLinks),
            contentViews: makeLinkRows(bundle: bundle, version: version, openURL: openURL)
        )
        let footer = makeFooter(bundle: bundle, forSearch: forSearch, openURL: openURL)
        let sections = forSearch ? [versions, links, footer] : [header, versions, links, footer]
        let stack = DashboardSettingsComponents.makeSettingsPageContent(sections)
        stack.spacing = 22
        stack.identifier = DashboardPageSearch.aboutContentIdentifier
        let root = DashboardAboutContentView(cards: [versions.cardView, links.cardView])
        root.addSubview(stack)
        let fillWidth = stack.widthAnchor.constraint(equalTo: root.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.safeAreaLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            fillWidth,
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        refresh(updateState: updateState)
        return root
    }

    func refresh(updateState: UpdateCheckState) {
        guard let updateRow, let updateButton, let notesButton else { return }
        let presentation = DashboardUpdatePresentation.make(for: updateState)
        updateRow.updateDetail(presentation.subtitle)
        updateButton.title = presentation.buttonTitle
        updateButton.isEnabled = presentation.buttonEnabled
        updateButton.tag = presentation.performsInstall ? 1 : 0
        updateButton.bezelColor = presentation.performsInstall ? .controlAccentColor : nil
        notesButton.isHidden = !presentation.showsReleaseNotesButton
        notesButton.isEnabled = presentation.showsReleaseNotesButton
        updateBadge?.isHidden = !presentation.showsUpdateBadge
        (updateButton.superview as? DashboardAdaptiveControlsStackView)?.invalidateLayoutAfterContentChange()
    }

    private func makeUpdateRow(relay: DashboardPreferencePageRelay) -> SettingsRowView {
        let update = NSButton(title: "", target: relay, action: #selector(DashboardPreferencePageRelay.update(_:)))
        update.identifier = .init("about.update")
        update.bezelStyle = .rounded
        let notes = NSButton(
            title: tr(.keyDashboardGeneralAndRefreshPagesViewReleaseNotes),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.openUpdateNotes(_:))
        )
        notes.identifier = .init("about.updateNotes")
        notes.bezelStyle = .rounded
        let badge = DashboardUpdateBadgeView()
        badge.identifier = .init("about.updateBadge")
        let row = SettingsRowView(
            title: tr(.keyDashboardAboutPageSoftwareUpdate),
            detail: " ",
            titleAccessory: badge,
            accessoryView: adaptiveControls([notes, update])
        )
        row.detailLabel.identifier = .init("about.updateSubtitle")
        updateRow = row
        updateButton = update
        notesButton = notes
        updateBadge = badge
        return row
    }

    private func adaptiveControls(_ views: [NSView], stacksBesideLabel: Bool = false) -> DashboardAdaptiveControlsStackView {
        let stack = DashboardAdaptiveControlsStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.minimumInlineLabelWidth = SettingsRowView.minimumInlineLabelWidth
        stack.stacksWhenLabelCannotFitBeside = stacksBesideLabel
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func makeHeader(version: BuildVersion, openURL: @escaping (URL) -> Bool) -> NSView {
        let icon = DashboardAboutIconView()
        let name = NSTextField(labelWithString: "BalanceBar")
        name.font = .systemFont(ofSize: 30, weight: .bold)
        name.setAccessibilityHelp(tr(.keyDashboardAboutPageACcSwitchBasedMenuBarBalanceViewer))
        let capsules = NSStackView(views: [DashboardAboutCapsule(title: version.number)])
        capsules.spacing = 6
        if let title = version.channelTitle {
            let color: NSColor? = version.isDevBuild ? .systemOrange : version.channel == .beta ? .controlAccentColor : nil
            let capsule = DashboardAboutCapsule(title: title, color: color, destination: version.devPullRequest, openURL: openURL)
            capsule.identifier = .init("about.channel")
            if let number = version.pullRequestNumber {
                capsule.button.setAccessibilityLabel(
                    tr(.keyDashboardAboutPageDevPullRequest, arguments: [String(number)])
                )
            }
            capsules.addArrangedSubview(capsule)
        }
        let header = NSStackView(views: [icon, name, capsules])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 8
        return header
    }

    private func makeLinkRows(bundle: Bundle, version: BuildVersion, openURL: @escaping (URL) -> Bool) -> [NSView] {
        let github = bundle.url(forResource: "GitHub", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
        let releasesDetail = version.releaseTag == nil ? tr(.keyDashboardAboutPageAllReleaseNotes)
            : tr(.keyDashboardAboutPageVersionReleaseNotes, arguments: [version.number])
        let repository = Self.githubRepositoryURL
        return [
            makeLinkRow("github", title: tr(.keyDashboardAboutPageGithubRepository),
                        detail: tr(.keyDashboardAboutPageGithubDetail), icon: github, tint: .darkGray,
                        destination: repository, openURL: openURL),
            makeLinkRow("releases", title: tr(.keyDashboardAboutPageReleaseNotes),
                        detail: releasesDetail, icon: symbol("doc.text"), tint: .systemBlue,
                        destination: version.releaseNotesURL, openURL: openURL),
            makeLinkRow("feedback", title: tr(.keyDashboardAboutPageFeedback),
                        detail: tr(.keyDashboardAboutPageFeedbackDetail), icon: symbol("exclamationmark.bubble"), tint: .systemOrange,
                        destination: repository.appendingPathComponent("issues/new/choose"), openURL: openURL),
            makeLinkRow("ccSwitch", title: "CC Switch",
                        detail: tr(.keyDashboardAboutPageCCSwitchDetail), icon: symbol("arrow.left.arrow.right"), tint: .systemTeal,
                        destination: Self.ccSwitchRepositoryURL, openURL: openURL)
        ]
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    private func makeLinkRow(
        _ identifier: String, title: String, detail: String, icon: NSImage?,
        tint: NSColor, destination: URL, openURL: @escaping (URL) -> Bool
    ) -> NSView {
        let mark = NSImageView()
        mark.image = icon?.copy() as? NSImage
        mark.image?.isTemplate = true
        mark.image?.size = NSSize(width: 14, height: 14)
        mark.imageScaling = .scaleNone
        mark.contentTintColor = .alternateSelectedControlTextColor
        mark.wantsLayer = true
        mark.layer?.cornerRadius = 6
        mark.layer?.backgroundColor = tint.cgColor
        mark.setAccessibilityElement(false)
        mark.widthAnchor.constraint(equalToConstant: 26).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let chevron = NSImageView(image: symbol("arrow.up.right") ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        let row = SettingsRowView(title: title, detail: detail, accessoryView: chevron, leadingAccessory: mark)
        row.identifier = .init("about.\(identifier)Row")
        // Keep the card's row layout and dividers. Place the icon before the labels
        // and a single accessible link over the entire content of the row.
        row.detailLabel.setAccessibilityElement(false)
        row.titleLabel.setAccessibilityElement(false)
        chevron.setAccessibilityElement(false)
        let button = DashboardAboutActionButton.link("", accessibilityTitle: title, help: detail) {
            _ = openURL(destination)
        }
        button.identifier = .init("about.\(identifier)Link")
        button.highlightsRow = true
        button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
            button.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -1)
        ])
        return row
    }

    private func makeFooter(bundle: Bundle, forSearch: Bool, openURL: @escaping (URL) -> Bool) -> NSView {
        let license = DashboardAboutActionButton.link(
            "MIT License", accessibilityTitle: tr(.keyDashboardAboutPageLicense) + ", MIT License"
        ) {}
        license.identifier = .init("about.license")
        license.onActivate = { [weak license] in
            guard let parent = license?.window else { return }
            let license = Self.licenseContent(in: bundle)
            Self.presentSheet(
                parent: parent, title: tr(.keyDashboardAboutPageLicense),
                text: license.text, monospaced: true, referenceURL: license.referenceURL, openURL: openURL
            )
        }
        let credits = DashboardAboutActionButton.link(tr(.keyDashboardAboutPageAcknowledgments)) {}
        credits.identifier = .init("about.acknowledgments")
        credits.onActivate = { [weak credits] in
            guard let parent = credits?.window else { return }
            let text = [
                LocalizationKey.keyDashboardAboutPageCreditsDependencies,
                .keyDashboardAboutPageCreditsCCSwitch,
                .keyDashboardAboutPageCreditsGitHub,
                .keyDashboardAboutPageCreditsThanks
            ].map { tr($0) }.joined(separator: "\n\n")
            Self.presentSheet(parent: parent, title: tr(.keyDashboardAboutPageAcknowledgments), text: text,
                              monospaced: false, referenceURL: nil, openURL: openURL)
        }
        if forSearch {
            return SettingsSectionView(title: "", contentViews: [
                SettingsRowView(title: tr(.keyDashboardAboutPageLicense), accessoryView: license),
                SettingsRowView(title: tr(.keyDashboardAboutPageAcknowledgments), accessoryView: credits)
            ])
        }
        let copyright = NSTextField(labelWithString: "· \(Self.copyright) ·")
        copyright.font = .systemFont(ofSize: 11.5)
        copyright.textColor = .tertiaryLabelColor
        for button in [license, credits] {
            button.linkColor = .tertiaryLabelColor
            button.font = .systemFont(ofSize: 11.5)
        }
        let inner = NSStackView(views: [license, copyright, credits])
        inner.alignment = .centerY
        inner.spacing = 4
        let footer = NSStackView(views: [inner])
        footer.orientation = .vertical
        footer.alignment = .centerX
        return footer
    }

    static func licenseContent(in bundle: Bundle) -> (text: String, referenceURL: URL?) {
        if let url = bundle.url(forResource: "LICENSE", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return (text, nil)
        }
        return ("MIT License · \(copyright)", githubRepositoryURL.appendingPathComponent("blob/main/LICENSE"))
    }

    static var copyright: String {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let years = year > 2026 ? "2026–\(year)" : "2026"
        return "© \(years) huanmeng06"
    }

    private static func presentSheet(
        parent: NSWindow, title: String, text: String, monospaced: Bool,
        referenceURL: URL?, openURL: @escaping (URL) -> Bool
    ) {
        guard parent.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 330),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = title
        sheet.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.font = monospaced ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 13)
            textView.textColor = .labelColor
            textView.string = text
            textView.setAccessibilityLabel(title)
        }
        let done = DashboardAboutActionButton(title: tr(.keyDashboardAboutPageDone)) { [weak parent, weak sheet] in
            if let sheet { parent?.endSheet(sheet) }
        }
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        if let referenceURL {
            controls.addArrangedSubview(DashboardAboutActionButton.link("MIT License", arrow: true) {
                _ = openURL(referenceURL)
            })
        }
        controls.addView(done, in: .trailing)
        let stack = NSStackView(views: [heading, scroll, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = sheet.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            controls.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])
        parent.beginSheet(sheet)
    }
}

private final class DashboardAboutContentView: NSView {
    private let cards: [SettingsSectionCardView]
    private var optionsObserver: NSObjectProtocol?

    init(cards: [SettingsSectionCardView]) {
        self.cards = cards
        super.init(frame: .zero)
        optionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyContrast() }
        applyContrast()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let optionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(optionsObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // AppKit updates descendants' layer colors during the same pass.
        DispatchQueue.main.async { [weak self] in self?.applyContrast() }
    }

    private func applyContrast() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for card in cards {
                let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                card.layer?.borderWidth = contrast ? 1 : SettingsSectionView.borderWidth
                card.layer?.borderColor = contrast ? NSColor.separatorColor.cgColor : dashboardAdaptiveColor(
                    light: NSColor.white.withAlphaComponent(0.95), dark: NSColor.white.withAlphaComponent(0.075)
                ).cgColor
            }
        }
    }
}

final class DashboardAboutActionButton: NSButton {
    var onActivate: () -> Void
    var copyConfirmation = false
    var highlightsRow = false { didSet { wantsLayer = highlightsRow } }
    var onHover: ((Bool) -> Void)?
    var linkColor: NSColor = .secondaryLabelColor { didSet { updateLinkAppearance() } }
    private var linkTitle: String?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var confirmationWork: DispatchWorkItem?
    private var originalTitle: String?

    init(title: String, action: @escaping () -> Void) {
        onActivate = action
        super.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(activate)
        focusRingType = .default
    }

    required init?(coder: NSCoder) { nil }

    static func link(
        _ title: String, accessibilityTitle: String? = nil, help: String? = nil, arrow: Bool = false,
        action: @escaping () -> Void
    ) -> DashboardAboutActionButton {
        let button = DashboardAboutActionButton(title: title, action: action)
        button.linkTitle = title + (arrow ? " ↗" : "")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setAccessibilityRole(.link)
        button.setAccessibilityLabel(accessibilityTitle ?? title)
        button.setAccessibilityHelp(help)
        button.toolTip = help
        button.updateLinkAppearance()
        return button
    }

    @objc func activate() {
        onActivate()
        guard copyConfirmation else { return }
        if originalTitle == nil { originalTitle = title }
        title = tr(.keyDashboardAboutPageCopied) + " ✓"
        confirmationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let originalTitle else { return }
            title = originalTitle
            self.originalTitle = nil
            confirmationWork = nil
        }
        confirmationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
                                     owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if linkTitle != nil || onHover != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setHovered(false)
    }

    private func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        updateLinkAppearance()
        onHover?(value)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLinkAppearance()
    }

    private func updateLinkAppearance() {
        guard let linkTitle else { return }
        if highlightsRow {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = hovered ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor : nil
            }
        } else {
            attributedTitle = NSAttributedString(string: linkTitle, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: hovered ? NSColor.controlAccentColor : linkColor,
                .underlineStyle: hovered ? NSUnderlineStyle.single.rawValue : 0
            ])
        }
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override var focusRingMaskBounds: NSRect { highlightsRow ? bounds.insetBy(dx: 2, dy: 2) : bounds }

    override func drawFocusRingMask() {
        if highlightsRow {
            NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 5, yRadius: 5).fill()
        } else {
            super.drawFocusRingMask()
        }
    }

    override func keyDown(with event: NSEvent) {
        if accessibilityRole() == .link, event.charactersIgnoringModifiers == "\r" {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class DashboardAboutCapsule: NSView {
    let button: DashboardAboutActionButton
    private let tint: NSColor?
    private var optionsObserver: NSObjectProtocol?

    init(title: String, color: NSColor? = nil, destination: URL? = nil,
         openURL: ((URL) -> Bool)? = nil) {
        tint = color
        button = DashboardAboutActionButton(title: title + (destination == nil ? "" : " ↗")) {
            if let destination { _ = openURL?(destination) }
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        let value: NSView
        if destination != nil {
            button.isBordered = false
            button.setAccessibilityRole(.link)
            button.setAccessibilityLabel(title)
            button.onHover = { [weak self] hovering in self?.applyColors(hovering: hovering) }
            value = button
        } else {
            let label = NSTextField(labelWithString: title)
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            label.textColor = tint == nil ? .secondaryLabelColor : .alternateSelectedControlTextColor
            value = label
        }
        value.translatesAutoresizingMaskIntoConstraints = false
        addSubview(value)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            value.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            value.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        optionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyColors() }
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let optionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(optionsObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors(hovering: Bool = false) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let background = tint ?? NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
            layer?.backgroundColor = (hovering ? background.highlight(withLevel: 0.12) ?? background : background).cgColor
            layer?.borderWidth = contrast ? 1 : 0
            layer?.borderColor = NSColor.separatorColor.cgColor
            if button.superview != nil {
                button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.alternateSelectedControlTextColor
                ])
            }
        }
    }
}

private final class DashboardAboutIconView: NSView {
    private let halo = CAGradientLayer()
    private let haloMask = CAShapeLayer()
    private let artwork = NSImageView(image: BalanceBarAppIcon.image())
    private var windowObservers: [NSObjectProtocol] = []
    private var optionsObserver: NSObjectProtocol?
    private var isHovering = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        halo.startPoint = CGPoint(x: 0, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 0.5)
        halo.mask = haloMask
        layer?.addSublayer(halo)

        artwork.wantsLayer = true
        artwork.imageScaling = .scaleProportionallyDown
        artwork.setAccessibilityElement(false)
        artwork.layer?.shadowColor = NSColor.shadowColor.cgColor
        artwork.layer?.shadowOffset = CGSize(width: 0, height: -10)
        artwork.layer?.shadowRadius = 18
        artwork.layer?.shadowOpacity = 0.18
        let button = DashboardAboutActionButton(title: "") { [weak self] in self?.spin() }
        button.identifier = .init("about.appIcon")
        button.isBordered = false
        button.setAccessibilityLabel("BalanceBar")
        button.onHover = { [weak self] hovering in
            self?.isHovering = hovering
            self?.updateHover()
        }
        artwork.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artwork)
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 112),
            heightAnchor.constraint(equalToConstant: 112),
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: trailingAnchor),
            artwork.topAnchor.constraint(equalTo: topAnchor),
            artwork.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        optionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncAnimation()
            self?.updateHover()
        }
        applyPalette()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let optionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(optionsObserver) }
    }

    override func layout() {
        super.layout()
        // The gradient and soft mask share one continuous rounded outline.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let padding: CGFloat = 54
        halo.frame = bounds.insetBy(dx: -padding, dy: -padding)
        haloMask.frame = halo.bounds
        let outline = CGPath(roundedRect: halo.bounds.insetBy(dx: padding + 8, dy: padding + 8),
                             cornerWidth: 22, cornerHeight: 22, transform: nil)
        haloMask.path = outline
        haloMask.fillColor = NSColor.white.cgColor
        haloMask.shadowPath = outline
        haloMask.shadowColor = NSColor.white.cgColor
        haloMask.shadowRadius = 24
        haloMask.shadowOpacity = 1
        haloMask.shadowOffset = .zero
        CATransaction.commit()
        syncAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    private func applyPalette() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        halo.colors = [
            NSColor(srgbRed: 0.12, green: 0.71, blue: 0.69, alpha: 1).cgColor,
            NSColor(srgbRed: 0.96, green: 0.54, blue: 0.12, alpha: 1).cgColor
        ]
        halo.opacity = dark ? 0.24 : 0.35
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.syncAnimation()
                })
            }
            if let clipView = enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                windowObservers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main) { [weak self] _ in
                    self?.syncAnimation()
                })
            }
        }
        syncAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        syncAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncAnimation()
    }

    private func syncAnimation() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced { artwork.layer?.removeAnimation(forKey: "spin") }
        guard !reduced, let window, window.isKeyWindow, window.occlusionState.contains(.visible),
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else {
            halo.removeAnimation(forKey: "drift")
            return
        }
        guard halo.animation(forKey: "drift") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "transform")
        sweep.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        sweep.toValue = NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation(9, 0, 0), 1.08, 1.08, 1))
        sweep.duration = 10
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(sweep, forKey: "drift")
    }

    private func updateHover() {
        guard let layer = artwork.layer else { return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale = isHovering && !reduced ? 1.04 : 1
        let previous = layer.presentation()?.value(forKeyPath: "transform.scale") ?? layer.value(forKeyPath: "transform.scale")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(scale, forKeyPath: "transform.scale")
        CATransaction.commit()
        layer.removeAnimation(forKey: "hover")
        if !reduced {
            let animation = CASpringAnimation(keyPath: "transform.scale")
            animation.fromValue = previous
            animation.toValue = scale
            animation.damping = 14
            animation.duration = 0.35
            layer.add(animation, forKey: "hover")
        }
    }

    private func spin() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = [0, -Double.pi * 2.025, -Double.pi * 2]
        animation.keyTimes = [0, 0.84, 1]
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeOut)]
        animation.duration = 0.9
        artwork.layer?.add(animation, forKey: "spin")
    }
}
