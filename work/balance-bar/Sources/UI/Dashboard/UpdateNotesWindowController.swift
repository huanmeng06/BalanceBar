import AppKit

private final class ReleaseNotesTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    override func writeSelection(
        to pasteboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        let range = selectedRange()
        guard range.length > 0,
              types.contains(.string),
              range.location >= 0,
              NSMaxRange(range) <= (string as NSString).length else {
            return false
        }
        let selectedText = (string as NSString).substring(with: range)
        pasteboard.declareTypes([.string], owner: nil)
        return pasteboard.setString(selectedText, forType: .string)
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = writeSelection(to: pasteboard, types: [.string])
    }
}

final class UpdateNotesWindowController: NSWindowController, NSWindowDelegate {
    private let releaseNotesStore: ReleaseNotesStore
    private let onInstall: () -> Void
    private let titleLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let notesTextView = ReleaseNotesTextView(frame: .zero)
    private let materialSurface = NSVisualEffectView()
    private let contentSurface = NSView()
    private let laterButton = NSButton(title: "", target: nil, action: nil)
    private let githubButton = NSButton(title: "", target: nil, action: nil)
    private let installButton = NSButton(title: "", target: nil, action: nil)
    private var currentVersion: AppSemanticVersion?
    private var release: GitHubRelease?
    private var appearanceObserver: NSObjectProtocol?

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
        installAppearanceObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
    }

    func show(currentVersion: AppSemanticVersion, release: GitHubRelease) {
        self.currentVersion = currentVersion
        self.release = release
        guard let window else { return }
        adoptDashboardAppearance()
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(notesTextView)
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
        materialSurface.identifier = NSUserInterfaceItemIdentifier("updateNotesMaterialSurface")
        materialSurface.material = .underWindowBackground
        materialSurface.blendingMode = .behindWindow
        materialSurface.state = .active
        materialSurface.autoresizingMask = [.width, .height]
        materialSurface.wantsLayer = true
        materialSurface.layer?.cornerRadius = 16
        materialSurface.layer?.masksToBounds = true
        contentSurface.identifier = NSUserInterfaceItemIdentifier("updateNotesContentSurface")
        contentSurface.translatesAutoresizingMaskIntoConstraints = false
        contentSurface.wantsLayer = true
        updateSurfaceAppearance()

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

        contentSurface.addSubview(header)
        contentSurface.addSubview(scrollView)
        contentSurface.addSubview(buttons)
        materialSurface.addSubview(contentSurface)
        window.contentView = materialSurface
        window.initialFirstResponder = notesTextView
        // Resolve the concrete backing colors only after the view hierarchy is
        // attached to the window. This makes the update window use the same
        // effective appearance as the Dashboard instead of briefly baking a
        // light surface while its text resolves in dark mode.
        updateSurfaceAppearance()
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)

        NSLayoutConstraint.activate([
            contentSurface.topAnchor.constraint(equalTo: materialSurface.topAnchor),
            contentSurface.leadingAnchor.constraint(equalTo: materialSurface.leadingAnchor),
            contentSurface.trailingAnchor.constraint(equalTo: materialSurface.trailingAnchor),
            contentSurface.bottomAnchor.constraint(equalTo: materialSurface.bottomAnchor),
            header.topAnchor.constraint(equalTo: contentSurface.topAnchor, constant: titlebarHeight + 24),
            header.leadingAnchor.constraint(equalTo: contentSurface.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: contentSurface.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: contentSurface.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: contentSurface.trailingAnchor, constant: -24),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: contentSurface.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: contentSurface.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: contentSurface.bottomAnchor, constant: -20),
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
    }

    private func installAppearanceObserver() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.adoptDashboardAppearance()
                self.render()
                self.relayoutAfterPresentation()
            }
        }
    }

    private func adoptDashboardAppearance() {
        guard let window else { return }
        if let applicationAppearance = NSApp.appearance {
            window.appearance = applicationAppearance
        } else {
            let sourceWindow = NSApp.windows.first {
                $0 !== window && $0.isVisible && ($0.isKeyWindow || $0 === NSApp.mainWindow)
            } ?? NSApp.windows.first {
                $0 !== window && $0.isVisible
            }
            window.appearance = sourceWindow?.effectiveAppearance
        }
        updateSurfaceAppearance()
    }

    private func updateSurfaceAppearance() {
        guard let window else { return }
        let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        materialSurface.layer?.backgroundColor = (isDark
            ? NSColor.black.withAlphaComponent(0.14)
            : NSColor.white.withAlphaComponent(0.08)
        ).cgColor
        contentSurface.layer?.backgroundColor = (isDark
            ? NSColor.black.withAlphaComponent(0.20)
            : NSColor(calibratedWhite: 0.94, alpha: 0.82)
        ).cgColor
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
        notesTextView.needsDisplay = true
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

    func windowDidChangeBackingProperties(_ notification: Notification) {
        updateTextViewFrame()
        notesTextView.needsDisplay = true
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
