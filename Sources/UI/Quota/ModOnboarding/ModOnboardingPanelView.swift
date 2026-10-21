import AppKit

struct ModPanelButton: Equatable {
    let title: String
    let action: ModPanelItem.ButtonAction
    var isDefault = false
}

/// One visible element of the window; the view renders exactly this list, and tests snapshot it.
enum ModPanelItem: Equatable {
    /// Centered header. A `nil` symbol shows the application icon.
    case hero(symbol: String?, title: String, subtitle: String?)
    case point(symbol: String, title: String, detail: String)
    case text(String)
    case bullet(String)
    case step(label: String, status: StepStatus)
    case codeBlock(String, copyAction: ButtonAction)
    /// Short, monospaced error summary returned by Claude Code.
    case detail(String)
    case checkbox(title: String, checked: Bool)
    case footer(leading: [ModPanelButton], trailing: [ModPanelButton])

    enum StepStatus: String, Equatable { case pending, running, done }
    enum ButtonAction: Equatable { case install, close, copyCommands, copyReload, openSettings }

    /// Text form used by tests; the view draws icons instead of the `[x]` marks.
    var snapshotLine: String {
        switch self {
        case let .hero(_, title, subtitle): return "# \(title)" + (subtitle.map { "\n\($0)" } ?? "")
        case let .point(_, title, detail): return "◆ \(title) — \(detail)"
        case let .text(t): return t
        case let .bullet(t): return "• \(t)"
        case let .step(label, status):
            let mark = status == .done ? "[x]" : status == .running ? "[~]" : "[ ]"
            return "\(mark) \(label)"
        case let .codeBlock(c, _): return "$ " + c.replacingOccurrences(of: "\n", with: "\n$ ")
        case let .detail(d): return "> \(d)"
        case let .checkbox(title, checked): return "(\(checked ? "x" : " ")) \(title)"
        case let .footer(leading, trailing):
            func render(_ buttons: [ModPanelButton]) -> String {
                buttons.map { "<\($0.title)>" + ($0.isDefault ? "*" : "") }.joined(separator: " ")
            }
            return [render(leading), render(trailing)].filter { !$0.isEmpty }.joined(separator: " | ")
        }
    }
}

enum ModPanelContent {
    static let pointSymbols = ["bolt.fill", "terminal", "gauge.with.dots.needle.33percent", "lock.shield"]

    static func items(
        for state: ModPanelState,
        plan: ModInstallPlan,
        localize: (ModOnboardingText) -> String
    ) -> [ModPanelItem] {
        let t = localize
        switch state {
        case let .intro(checked):
            let points: [(ModOnboardingText, ModOnboardingText)] = [
                (.point1Title, .point1Detail), (.point2Title, .point2Detail),
                (.point3Title, .point3Detail), (.point4Title, .point4Detail),
            ]
            return [.hero(symbol: nil, title: t(.panelTitle), subtitle: t(.panelSubtitle))]
                + zip(pointSymbols, points).map { .point(symbol: $0, title: t($1.0), detail: t($1.1)) }
                + [
                    .checkbox(title: t(.dismissCheckbox), checked: checked),
                    .footer(
                        leading: [ModPanelButton(title: t(.copyCommands), action: .copyCommands)],
                        trailing: [ModPanelButton(title: t(.laterButton), action: .close),
                                   ModPanelButton(title: t(.installButton), action: .install, isDefault: true)]),
                ]
        case let .installing(current):
            return [.hero(symbol: nil, title: t(.panelTitle), subtitle: nil)] + steps(current: current, t: t)
                + [.footer(leading: [], trailing: [ModPanelButton(title: t(.closeButton), action: .close)])]
        case .awaitingFirstData:
            // Nothing is asked of the user right now: new sessions pick the Mod up by themselves.
            return [.hero(symbol: nil, title: t(.panelTitle), subtitle: nil)] + steps(current: .finish, t: t)
                + [.text(t(.enabledNote)), .text(t(.reloadHint)),
                   .codeBlock(ModInstallPlan.reloadCommand, copyAction: .copyReload),
                   .footer(leading: [], trailing: [ModPanelButton(title: t(.closeButton), action: .close, isDefault: true)])]
        case .enabled:
            return [.hero(symbol: "checkmark.circle.fill", title: t(.enabled), subtitle: t(.enabledNote)),
                    .footer(leading: [], trailing: [ModPanelButton(title: t(.closeButton), action: .close, isDefault: true)])]
        case .silent:
            return [.hero(symbol: "exclamationmark.triangle.fill", title: t(.silentTitle), subtitle: nil),
                    .text(t(.silentIntro)),
                    .bullet(t(.silentItem1)), .bullet(t(.silentItem2)), .bullet(t(.silentItem3)),
                    .footer(leading: [], trailing: [
                        ModPanelButton(title: t(.closeButton), action: .close),
                        ModPanelButton(title: t(.dismissedOpenSettings), action: .openSettings, isDefault: true)])]
        case let .failed(failure):
            let reason: ModOnboardingText = failure == .claudeNotFound ? .failureClaudeMissing : .failureCommandFailed
            var items: [ModPanelItem] = [
                .hero(symbol: "exclamationmark.triangle.fill", title: t(.failureTitle), subtitle: nil),
                .text(t(reason)),
            ]
            if let summary = summary(of: failure) { items.append(.detail(summary)) }
            items.append(.codeBlock(plan.copyableCommands, copyAction: .copyCommands))
            items.append(.footer(leading: [], trailing: [ModPanelButton(title: t(.closeButton), action: .close, isDefault: true)]))
            return items
        case .dismissConfirmed:
            return [.hero(symbol: nil, title: t(.dismissedTitle), subtitle: t(.dismissedNote)),
                    .footer(leading: [], trailing: [
                        ModPanelButton(title: t(.dismissedOpenSettings), action: .openSettings),
                        ModPanelButton(title: t(.dismissedOk), action: .close, isDefault: true)])]
        }
    }

    private static func steps(current: ModInstallStep, t: (ModOnboardingText) -> String) -> [ModPanelItem] {
        let labels = [t(.step1), t(.step2), t(.step3)]
        return ModInstallStep.allCases.map { step -> ModPanelItem in
            let status: ModPanelItem.StepStatus = step.rawValue < current.rawValue ? .done
                : step == current ? .running : .pending
            return .step(label: labels[step.rawValue], status: status)
        }
    }

    /// The first two lines of what Claude Code said when a command failed.
    private static func summary(of failure: ModInstallFailure) -> String? {
        guard case let .commandFailed(_, _, detail) = failure else { return nil }
        let lines = detail.split(whereSeparator: \.isNewline).prefix(2).map(String.init)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - Menu prompt row

/// The menu prompt: a rounded block with a soft accent tint, the main copy, the "why" link and a chevron.
/// Lives in a menu item's custom view; clicking anywhere on it closes the menu and runs `onClick`.
final class ModPromptRowView: NSView {
    static let rowHeight: CGFloat = 52
    /// The tint block extends past the content by `contentPadding`; the icon and the chevron sit on the card's
    /// 16 pt grid (the progress bars' edges and a submenu arrow's right edge).
    static let contentPadding: CGFloat = 8
    static let blockInset: CGFloat = OpenCodexCardLayout.horizontalInset - contentPadding

    private let block = NSView()
    let iconView = NSImageView()
    private let mainLabel: NSTextField
    /// Whether the main text is cut short at the card width (test seam).
    var mainTextIsTruncated: Bool { mainLabel.intrinsicContentSize.width > mainLabel.frame.width + 0.5 }
    private let whyLabel: NSTextField
    let chevron = NSImageView()
    private var isHovering = false { didSet { updateBackground() } }
    var onClick: () -> Void = {}

    var mainText: String { mainLabel.stringValue }
    var whyText: String { whyLabel.stringValue }

    /// - Parameter headless: shows the headless wording (a HUD user whose headless runs go untracked).
    init(headless: Bool = false, localize: (ModOnboardingText) -> String = ModOnboardingText.defaultLocalize) {
        mainLabel = NSTextField(labelWithString: localize(headless ? .promptHeadless : .promptRow))
        whyLabel = NSTextField(labelWithString: localize(.promptWhy))
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: Self.rowHeight))
        autoresizingMask = [.width]
        setAccessibilityRole(.button)
        setAccessibilityLabel(mainLabel.stringValue + ", " + whyLabel.stringValue)

        block.wantsLayer = true
        block.layer?.cornerRadius = 8
        block.translatesAutoresizingMaskIntoConstraints = false
        addSubview(block)

        iconView.image = Self.symbol("bolt.fill", size: 15)
        iconView.contentTintColor = .controlAccentColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        mainLabel.font = .systemFont(ofSize: 13, weight: .medium)
        mainLabel.textColor = .controlAccentColor
        mainLabel.lineBreakMode = .byTruncatingTail
        whyLabel.font = .systemFont(ofSize: 11)
        whyLabel.textColor = .controlAccentColor
        chevron.image = Self.symbol("chevron.right", size: 11)
        chevron.contentTintColor = .labelColor
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let texts = NSStackView(views: [mainLabel, whyLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        // The text column takes the slack so the chevron sits at the trailing edge.
        texts.setContentHuggingPriority(.init(1), for: .horizontal)
        mainLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        whyLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [iconView, texts, chevron])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        block.addSubview(row)
        NSLayoutConstraint.activate([
            block.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.blockInset),
            block.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.blockInset),
            block.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            block.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            row.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: Self.contentPadding),
            row.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -Self.contentPadding),
            row.centerYAnchor.constraint(equalTo: block.centerYAnchor),
        ])
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        let handler = onClick
        DispatchQueue.main.async { handler() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            block.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isHovering ? 0.20 : 0.12).cgColor
        }
    }
}

// MARK: - Copy button

/// The small copy control of a code block: a 22 pt rounded button with hover and pressed fills, a pointing-hand
/// cursor, and a green check mark for a moment after the click.
final class ModCopyButton: NSButton {
    static let side: CGFloat = 22
    private var isHovering = false { didSet { updateFill() } }
    private var isPressed = false { didSet { updateFill() } }
    private var feedback: DispatchWorkItem?
    private let idleImage = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
    private let doneImage = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))

    /// `true` while the check mark is showing.
    private(set) var isShowingFeedback = false

    init(toolTip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        image = idleImage
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        isBordered = false
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 5
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.side).isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
        updateFill()
    }

    required init?(coder: NSCoder) { nil }

    /// A plain NSButton pads its frame beyond the aligned rect, which made the 22x22 constraints a taller frame.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)   // tracks until the button is released
        isPressed = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    /// Shows the check mark for 1.2 s.
    func flashCopied() {
        feedback?.cancel()
        isShowingFeedback = true
        image = doneImage
        contentTintColor = .systemGreen
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowingFeedback = false
            self.image = self.idleImage
            self.contentTintColor = .secondaryLabelColor
        }
        feedback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let alpha: CGFloat = isPressed ? 0.16 : isHovering ? 0.09 : 0
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }
}

extension NSButton {
    /// Shows `text` as the title for a moment ("copied" feedback), then restores the original title.
    func flashTitle(_ text: String, duration: TimeInterval = 1.2) {
        let original = (objc_getAssociatedObject(self, &NSButton.flashOriginalKey) as? String) ?? title
        objc_setAssociatedObject(self, &NSButton.flashOriginalKey, original, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        title = text
        let token = UUID()
        objc_setAssociatedObject(self, &NSButton.flashTokenKey, token, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, objc_getAssociatedObject(self, &NSButton.flashTokenKey) as? UUID == token else { return }
            self.title = original
            objc_setAssociatedObject(self, &NSButton.flashOriginalKey, nil, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        }
    }

    private static var flashOriginalKey: UInt8 = 0
    private static var flashTokenKey: UInt8 = 0
}

// MARK: - Window content

/// Explanation window content: renders `ModPanelContent` for the controller's current state.
final class ModOnboardingPanelView: NSView {
    static let fixedWidth: CGFloat = 380
    static let inset: CGFloat = 24
    /// How long "enabled ✓" stays before the window closes itself.
    static let successDisplayDuration: TimeInterval = 2
    static let silenceCheckInterval: TimeInterval = 30

    private let controller: ModOnboardingController
    private let localize: (ModOnboardingText) -> String
    private let stack = NSStackView()
    private var previousState: ModPanelState?
    private var silenceTimer: Timer?
    private(set) var defaultButton: NSButton?
    var onRequestClose: () -> Void = {}
    /// Called after each reload with the view's new fitting size.
    var onContentSizeChange: ((NSSize) -> Void)?
    /// Called with the default button after each reload, so a window can bind the Return key to it.
    var onDefaultButtonChange: ((NSButton?) -> Void)?

    private(set) var items: [ModPanelItem] = []
    var snapshotLines: [String] { items.map(\.snapshotLine) }
    private var contentWidth: CGFloat { Self.fixedWidth - 2 * Self.inset }

    init(controller: ModOnboardingController, localize: @escaping (ModOnboardingText) -> String = ModOnboardingText.defaultLocalize) {
        self.controller = controller
        self.localize = localize
        super.init(frame: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.fixedWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        controller.onChange = { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { nil }

    deinit { silenceTimer?.invalidate() }

    func reload() {
        let wasWaiting = previousState == .awaitingFirstData || previousState == .silent
        previousState = controller.state
        items = ModPanelContent.items(for: controller.state, plan: controller.plan, localize: localize)
        defaultButton = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let view = makeView(item)
            stack.addArrangedSubview(view)
            // Fill the content width; the hero centers its own content.
            view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.first ?? NSView())
        layoutSubtreeIfNeeded()
        onDefaultButtonChange?(defaultButton)
        onContentSizeChange?(fittingSize)
        updateSilenceTimer()
        // The first snapshot arrived while the window was open: show "enabled ✓" briefly, then close.
        if wasWaiting, controller.state == .enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.successDisplayDuration) { [weak self] in
                guard let self, self.controller.state == .enabled else { return }
                self.onRequestClose()
            }
        }
    }

    /// While waiting for the first snapshot, ten minutes without one (with Claude Code active) turns into advice.
    private func updateSilenceTimer() {
        guard controller.state == .awaitingFirstData else {
            silenceTimer?.invalidate()
            silenceTimer = nil
            return
        }
        guard silenceTimer == nil else { return }
        let timer = Timer(timeInterval: Self.silenceCheckInterval, repeats: true) { [weak self] _ in
            self?.controller.checkSilence()
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    /// Triggers a button as if clicked (used by tests and the window's Esc / Return handling).
    func perform(_ action: ModPanelItem.ButtonAction) {
        switch action {
        case .install: controller.startInstall()
        case .copyCommands: controller.copyInstallCommands()
        case .copyReload: controller.copyReloadCommand()
        case .openSettings:
            controller.openSettings()
            onRequestClose()
        case .close: if controller.close() { onRequestClose() }
        }
    }

    // MARK: Drawing

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                       alignment: NSTextAlignment = .left, width: CGFloat? = nil) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = alignment
        field.preferredMaxLayoutWidth = width ?? contentWidth
        field.isSelectable = false
        return field
    }

    private func makeView(_ item: ModPanelItem) -> NSView {
        switch item {
        case let .hero(symbol, title, subtitle):
            let icon = NSImageView()
            let size: CGFloat = 56
            if let symbol {
                icon.image = Self.symbol(symbol, size: 44, weight: .medium)
                icon.contentTintColor = symbol.hasPrefix("exclamation") ? .systemOrange : .systemGreen
            } else {
                icon.image = NSApp?.applicationIconImage
            }
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: size).isActive = true
            icon.heightAnchor.constraint(equalToConstant: size).isActive = true
            var views: [NSView] = [icon, label(title, size: 17, weight: .semibold, alignment: .center)]
            if let subtitle { views.append(label(subtitle, size: 13, color: .secondaryLabelColor, alignment: .center)) }
            let column = NSStackView(views: views)
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 8
            column.setCustomSpacing(10, after: icon)
            return column
        case let .point(symbol, title, detail):
            // Every icon sits in the same square box, solid accent color, so differently shaped symbols line up.
            let box: CGFloat = 30
            let icon = NSImageView(image: Self.symbol(symbol, size: 20, weight: .medium) ?? NSImage())
            icon.contentTintColor = .controlAccentColor
            icon.imageScaling = .scaleProportionallyDown
            icon.imageAlignment = .alignCenter
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: box).isActive = true
            icon.heightAnchor.constraint(equalToConstant: box).isActive = true
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            let textWidth = contentWidth - box - 12
            let column = NSStackView(views: [
                label(title, size: 13, weight: .semibold, width: textWidth),
                label(detail, size: 12, color: .secondaryLabelColor, width: textWidth),
            ])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            let row = NSStackView(views: [icon, column])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            return row
        case let .text(text):
            return label(text, size: 13, color: .secondaryLabelColor)
        case let .bullet(text):
            return label("•  " + text, size: 13, color: .secondaryLabelColor)
        case let .step(text, status):
            let indicator: NSView
            switch status {
            case .done:
                let image = NSImageView(image: Self.symbol("checkmark.circle.fill", size: 16) ?? NSImage())
                image.contentTintColor = .systemGreen
                indicator = image
            case .running:
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.isIndeterminate = true
                spinner.startAnimation(nil)
                indicator = spinner
            case .pending:
                let image = NSImageView(image: Self.symbol("circle", size: 16) ?? NSImage())
                image.contentTintColor = .tertiaryLabelColor
                indicator = image
            }
            indicator.widthAnchor.constraint(equalToConstant: 18).isActive = true
            indicator.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let title = label(text, size: 13, weight: status == .running ? .semibold : .regular,
                              color: status == .pending ? .tertiaryLabelColor : .labelColor, width: contentWidth - 30)
            title.setAccessibilityLabel("\(text), \(status.rawValue)")
            let row = NSStackView(views: [indicator, title])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            return row
        case let .codeBlock(text, copyAction):
            return makeCodeBlock(text, copyAction: copyAction)
        case let .detail(text):
            let field = label(text, size: 11, color: .secondaryLabelColor)
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isSelectable = true
            return field
        case let .checkbox(title, checked):
            let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxToggled(_:)))
            box.state = checked ? .on : .off
            box.controlSize = .regular
            return box
        case let .footer(leading, trailing):
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            leading.forEach { row.addArrangedSubview(makeButton($0)) }
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            trailing.forEach { row.addArrangedSubview(makeButton($0)) }
            return row
        }
    }

    private func makeButton(_ model: ModPanelButton) -> NSButton {
        let button = NSButton(title: model.title, target: self, action: #selector(buttonPressed(_:)))
        button.bezelStyle = .push
        button.controlSize = .large
        button.identifier = NSUserInterfaceItemIdentifier(Self.identifier(for: model.action))
        if model.isDefault {
            button.keyEquivalent = "\r"
            defaultButton = button
        }
        return button
    }

    private func makeCodeBlock(_ text: String, copyAction: ModPanelItem.ButtonAction) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.translatesAutoresizingMaskIntoConstraints = false
        container.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        }
        let code = NSTextField(wrappingLabelWithString: text)
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        code.isSelectable = true
        code.preferredMaxLayoutWidth = contentWidth - 10 - 6 - ModCopyButton.side - 6
        code.translatesAutoresizingMaskIntoConstraints = false
        let copy = ModCopyButton(toolTip: localize(.copyCommands))
        copy.target = self
        copy.action = #selector(copyPressed(_:))
        copy.identifier = NSUserInterfaceItemIdentifier(Self.identifier(for: copyAction))
        container.addSubview(code)
        container.addSubview(copy)
        NSLayoutConstraint.activate([
            code.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            code.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            code.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            code.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -6),
            copy.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            copy.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
        ])
        return container
    }

    @objc private func checkboxToggled(_ sender: NSButton) { controller.setDismissChecked(sender.state == .on) }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let action = Self.action(for: id) else { return }
        perform(action)
        if action == .copyCommands || action == .copyReload { sender.flashTitle("✓ " + localize(.copied)) }
    }

    /// Copy icon: copies, then shows a check mark for a moment.
    @objc private func copyPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let action = Self.action(for: id) else { return }
        perform(action)
        (sender as? ModCopyButton)?.flashCopied()
    }

    private static func identifier(for action: ModPanelItem.ButtonAction) -> String { String(describing: action) }
    private static func action(for id: String) -> ModPanelItem.ButtonAction? {
        [.install, .close, .copyCommands, .copyReload, .openSettings].first { identifier(for: $0) == id }
    }
}
