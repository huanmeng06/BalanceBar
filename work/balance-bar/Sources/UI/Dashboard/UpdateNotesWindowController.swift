import AppKit

final class UpdateNotesWindowController: NSWindowController, NSWindowDelegate {
    private let releaseNotesStore: ReleaseNotesStore
    private let onInstall: () -> Void
    private let titleLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let notesTextView = NSTextView(frame: .zero)
    private let laterButton = NSButton(title: "", target: nil, action: nil)
    private let githubButton = NSButton(title: "", target: nil, action: nil)
    private let installButton = NSButton(title: "", target: nil, action: nil)
    private var currentVersion: AppSemanticVersion?
    private var release: GitHubRelease?

    init(
        releaseNotesStore: ReleaseNotesStore = ReleaseNotesStore(),
        onInstall: @escaping () -> Void
    ) {
        self.releaseNotesStore = releaseNotesStore
        self.onInstall = onInstall

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 400)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.appearance = nil
        super.init(window: window)
        window.delegate = self
        configureView()
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(currentVersion: AppSemanticVersion, release: GitHubRelease) {
        self.currentVersion = currentVersion
        self.release = release
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        render()
        DispatchQueue.main.async { [weak self] in
            self?.relayoutAfterPresentation()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshForCurrentLanguage() {
        guard currentVersion != nil, release != nil else { return }
        render()
        DispatchQueue.main.async { [weak self] in
            self?.relayoutAfterPresentation()
        }
    }

    private func configureView() {
        guard let window else { return }
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, versionLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        notesTextView.isEditable = false
        notesTextView.isSelectable = true
        notesTextView.isRichText = true
        notesTextView.importsGraphics = false
        notesTextView.allowsUndo = false
        notesTextView.drawsBackground = false
        notesTextView.isAutomaticLinkDetectionEnabled = false
        notesTextView.textContainerInset = NSSize(width: 16, height: 14)
        notesTextView.textContainer?.lineFragmentPadding = 0
        notesTextView.isVerticallyResizable = true
        notesTextView.isHorizontallyResizable = false
        notesTextView.autoresizingMask = [.width]
        notesTextView.minSize = NSSize(width: 0, height: 0)
        notesTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        notesTextView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = notesTextView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        for button in [laterButton, githubButton, installButton] {
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        laterButton.target = self
        laterButton.action = #selector(later(_:))
        githubButton.target = self
        githubButton.action = #selector(openGitHub(_:))
        installButton.target = self
        installButton.action = #selector(install(_:))
        installButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [laterButton, githubButton, installButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scrollView)
        root.addSubview(buttons)

        let surface: NSView
        if let glassSurface = makeDashboardGlassEffectView(contentView: root, cornerRadius: 18) {
            surface = glassSurface
        } else {
            let visualEffectSurface = NSVisualEffectView()
            visualEffectSurface.material = .windowBackground
            visualEffectSurface.blendingMode = .behindWindow
            visualEffectSurface.state = .active
            root.translatesAutoresizingMaskIntoConstraints = false
            visualEffectSurface.addSubview(root)
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: visualEffectSurface.topAnchor),
                root.leadingAnchor.constraint(equalTo: visualEffectSurface.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: visualEffectSurface.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: visualEffectSurface.bottomAnchor)
            ])
            surface = visualEffectSurface
        }
        surface.autoresizingMask = [.width, .height]
        window.contentView = surface

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
    }

    private func render() {
        guard let currentVersion, let release else { return }
        let language = AppLanguage.resolved
        titleLabel.stringValue = tr(.keyDashboardGeneralAndRefreshPagesReleaseNotes, language: language)
        versionLabel.stringValue = tr(
            .keyDashboardGeneralAndRefreshPagesNewVersionAvailableValueValue,
            arguments: [String(describing: currentVersion), String(describing: release.version ?? currentVersion)],
            language: language
        )
        laterButton.title = tr(.keyDashboardGeneralAndRefreshPagesReleaseNotesLater, language: language)
        githubButton.title = tr(.keyDashboardGeneralAndRefreshPagesReleaseNotesViewGithub, language: language)
        installButton.title = tr(.keyDashboardGeneralAndRefreshPagesDownloadAndInstall, language: language)
        githubButton.isEnabled = release.releaseURL != nil

        let resolution = releaseNotesStore.resolve(
            version: release.version ?? currentVersion,
            language: language,
            release: release
        )
        let markdown = resolution.markdown
            ?? tr(.keyDashboardGeneralAndRefreshPagesReleaseNotesUnavailable, language: language)
        notesTextView.textStorage?.setAttributedString(
            ReleaseNotesMarkdownRenderer.render(markdown: markdown)
        )
        updateTextViewFrame()
    }

    private func updateTextViewFrame() {
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let width = clipView.bounds.width
        guard width > 1,
              let textContainer = notesTextView.textContainer,
              let layoutManager = notesTextView.layoutManager else {
            return
        }
        let inset = notesTextView.textContainerInset
        let textContainerWidth = max(1, width - inset.width * 2)
        textContainer.widthTracksTextView = false
        textContainer.containerSize = NSSize(
            width: textContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        notesTextView.frame.size.width = width
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let minimumHeight = max(1, clipView.bounds.height)
        notesTextView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(minimumHeight, ceil(usedHeight + inset.height * 2))
        )
    }

    private func relayoutAfterPresentation() {
        guard let window, window.isVisible else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        updateTextViewFrame()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        updateTextViewFrame()
    }

    func windowDidResize(_ notification: Notification) {
        updateTextViewFrame()
    }

    @objc private func later(_ sender: NSButton) {
        close()
    }

    @objc private func openGitHub(_ sender: NSButton) {
        guard let url = release?.releaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func install(_ sender: NSButton) {
        onInstall()
        close()
    }
}
