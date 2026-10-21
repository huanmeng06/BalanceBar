import AppKit

/// A line with dots on it: the chosen frequency (many small dots), what Claude's official endpoint allows
/// (a few dots) and, once the Mod delivers, a dot after every reply.
final class RefreshRateTimelineView: NSView {
    enum Style { case wished, actual, mod }

    private let style: Style
    /// Dot positions as fractions of the line, 0...1.
    private let positions: [CGFloat]

    init(style: Style) {
        self.style = style
        switch style {
        case .wished: positions = (0...10).map { CGFloat($0) / 10 }
        case .actual: positions = [0.0, 0.3, 0.6, 0.95]
        case .mod: positions = [0.04, 0.12, 0.3, 0.38, 0.55, 0.7, 0.78, 0.93]
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 14).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = style == .wished ? 6 : 9
        let y = bounds.midY
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.separatorColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: y - 0.5, width: bounds.width, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
            let color: NSColor = {
                switch style {
                case .wished: return .tertiaryLabelColor
                case .actual: return .systemOrange
                case .mod: return .systemGreen
                }
            }()
            color.setFill()
            let usable = bounds.width - diameter
            for position in positions {
                let dot = NSRect(x: position * usable, y: y - diameter / 2, width: diameter, height: diameter)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }
}

private extension NSBox {
    static func separator(width: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }
}

/// The reads still available out of the bucket's capacity. Plain label color, so color only ever means a state.
final class RefreshTokenDotsView: NSView {
    var filled = 0 { didSet { if filled != oldValue { needsDisplay = true } } }
    private let total: Int

    init(total: Int) {
        self.total = total
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: CGFloat(total) * 14).isActive = true
        heightAnchor.constraint(equalToConstant: 12).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for index in 0..<total {
                let dot = NSRect(x: CGFloat(index) * 14 + 1, y: bounds.midY - 5, width: 10, height: 10)
                if index < filled {
                    NSColor.labelColor.setFill()
                    NSBezierPath(ovalIn: dot).fill()
                } else {
                    NSColor.tertiaryLabelColor.setStroke()
                    let path = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }
        }
    }
}

/// How the popover treats the current state of the official read.
enum RefreshHelpMood: Equatable {
    /// Waiting, ready or reading, no Mod data in play.
    case normal
    /// The Mod's data is fresh: no install pitch, and the Mod gets its own line in the explanation.
    case live
    /// Sign-in expired or rate limited: the one thing to read, the explanation folds away.
    case alert

    init(_ phase: ClaudeRefreshStatus.Phase) {
        switch phase {
        case .liveFresh: self = .live
        case .loginExpired, .rateLimited: self = .alert
        default: self = .normal
        }
    }
}

/// The status card: what is holding the next official read back, a bar that fills while it waits, when it was last
/// read, how many reads are available and how old the Mod's data is. Refreshes itself every second on screen.
final class RefreshRateLiveStatusView: NSView {
    private let provider: () -> ClaudeRefreshStatus?
    private let language: AppLanguage
    private let now: () -> Date
    private let dot = NSView()
    private let sentence = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let lastReadValue = NSTextField(labelWithString: "")
    private let tokenDots = RefreshTokenDotsView(total: QuotaConstants.requestTokenBucketCapacity)
    private let modValue = NSTextField(labelWithString: "")
    private var metaRows: [NSView] = []
    private var modRow = NSView()
    private var timer: Timer?
    private var tint = NSColor.systemGreen
    private(set) var phase: ClaudeRefreshStatus.Phase = .ready
    /// Whether the last-read and reads-available rows are shown (hidden while something is wrong).
    var showsDetails: Bool { !(metaRows.first?.isHidden ?? true) }
    /// Called when the kind of state changes (not on every tick), so the popover can re-arrange itself.
    var onMoodChange: ((RefreshHelpMood) -> Void)?
    private(set) var mood: RefreshHelpMood = .normal
    /// The Mod has delivered at least once (fresh or not): it is installed, so there is nothing to pitch.
    private(set) var hasModData = false

    init(width: CGFloat, language: AppLanguage, now: @escaping () -> Date = Date.init, provider: @escaping () -> ClaudeRefreshStatus?) {
        self.provider = provider
        self.language = language
        self.now = now
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        func localize(_ key: LocalizationKey) -> String { tr(key, language: language) }
        let padding: CGFloat = 10
        let inner = width - 2 * padding
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        sentence.font = .systemFont(ofSize: 12, weight: .medium)
        sentence.isSelectable = false
        sentence.preferredMaxLayoutWidth = inner - 16
        let header = NSStackView(views: [dot, sentence])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 8
        dot.topAnchor.constraint(equalTo: sentence.topAnchor, constant: 4).isActive = true

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: inner).isActive = true

        func caption(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            return field
        }
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            return row
        }
        for field in [lastReadValue, modValue] {
            field.font = .systemFont(ofSize: 11)
            field.lineBreakMode = .byClipping
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let lastRead = row([caption(localize(.keyRefreshStatusLastRead)), lastReadValue])
        let reads = row([caption(localize(.keyRefreshStatusTokensLabel)), tokenDots])
        modRow = row([caption(localize(.keyRefreshStatusModLabel)), modValue])
        metaRows = [lastRead, reads, modRow]

        let stack = NSStackView(views: [header, bar, lastRead, reads, modRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
        ])
        update()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    deinit { timer?.invalidate() }

    private func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.formattingLocale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 60 ? [.minute, .second] : [.second]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(1, seconds.rounded(.up))) ?? "\(Int(seconds))s"
    }

    private func applyTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(0.10).cgColor
            dot.layer?.backgroundColor = tint.cgColor
        }
    }

    /// Reads the scheduler's state and shows it.
    func update() {
        func localize(_ key: LocalizationKey, _ arguments: [String] = []) -> String { tr(key, arguments: arguments, language: language) }
        guard let status = provider() else { return }
        let date = now()
        phase = status.phase(now: date)
        var progress: Double?
        let text: String
        switch phase {
        case .reading:
            text = localize(.keyRefreshStatusPhaseReading); tint = .systemGreen
        case .loginExpired:
            text = localize(.keyRefreshStatusPhaseLogin); tint = .systemRed
        case let .rateLimited(remaining):
            text = localize(.keyRefreshStatusPhaseRate, [duration(remaining)]); tint = .systemRed
        case let .liveFresh(age):
            text = localize(.keyRefreshStatusPhaseLive, [duration(age)]); tint = .systemGreen
            progress = 1 - age / max(1, status.realtimeFreshnessWindow)
        case let .waitingInterval(remaining, total):
            text = localize(.keyRefreshStatusPhaseInterval, [duration(remaining)]); tint = .systemOrange
            progress = 1 - remaining / max(1, total)
        case let .waitingTokens(remaining, total):
            text = localize(.keyRefreshStatusPhaseTokens, [duration(remaining)]); tint = .systemOrange
            progress = 1 - remaining / max(1, total)
        case .ready:
            text = localize(.keyRefreshStatusPhaseReady); tint = .systemGreen
        }
        let newMood = RefreshHelpMood(phase)
        sentence.stringValue = text
        sentence.font = .systemFont(ofSize: newMood == .alert ? 13 : 12, weight: .medium)
        applyTint()
        bar.isHidden = progress == nil
        bar.doubleValue = min(1, max(0, progress ?? 0))
        // The one thing to read when something is wrong; the rest only distracts.
        metaRows.forEach { $0.isHidden = newMood == .alert }
        if let last = status.scheduler.lastSuccessAt ?? status.scheduler.lastDispatchAt {
            lastReadValue.stringValue = localize(.keyRefreshStatusLastReadValue, [
                StatusSlotAppearance.timeText(last, timeZone: .current), duration(date.timeIntervalSince(last))])
        } else {
            lastReadValue.stringValue = localize(.keyRefreshStatusLastReadNone)
        }
        tokenDots.filled = status.tokensAvailable(at: date)
        if let realtimeAt = status.realtimeAt, newMood != .alert {
            modValue.stringValue = localize(.keyRefreshStatusModValue, [duration(max(0, date.timeIntervalSince(realtimeAt)))])
            modRow.isHidden = false
        } else {
            modRow.isHidden = true
        }
        lastReadValue.invalidateIntrinsicContentSize()
        modValue.invalidateIntrinsicContentSize()
        let newHasModData = status.realtimeAt != nil
        if newMood != mood || newHasModData != hasModData {
            mood = newMood
            hasModData = newHasModData
            onMoodChange?(newMood)
        }
    }
}

/// The content of the "?" popover next to the refresh frequency: the status card first, then, quieter, why it is not
/// as fast as the setting, and finally (without Mod data) a way to the Mod.
final class RefreshRateHelpContentView: NSView {
    static let width: CGFloat = 340

    private let language: AppLanguage
    private let statusView: RefreshRateLiveStatusView?
    private let hasStatusSource: Bool
    private let explanation = NSStackView()
    private let expandButton = NSButton()
    private let modTimeline = NSStackView()
    private let footer = NSStackView()
    private let stack = NSStackView()
    private var mood: RefreshHelpMood = .normal
    private var expanded = false
    private let onInstall: (() -> Void)?
    /// Called when the arrangement changes the content's height, so the popover can follow.
    var onSizeChange: ((NSSize) -> Void)?

    /// - Parameters:
    ///   - selectedInterval: the frequency currently chosen in Settings, shown next to the first timeline.
    ///   - status: the live look at the scheduler; without it only the explanation is shown.
    ///   - onInstall: opens the Mod's settings (the "install" button in the footer).
    init(selectedInterval: TimeInterval, language: AppLanguage = .selected, now: @escaping () -> Date = Date.init,
         status: (() -> ClaudeRefreshStatus?)? = nil, onInstall: (() -> Void)? = nil) {
        self.language = language
        self.onInstall = onInstall
        hasStatusSource = status != nil
        let inset: CGFloat = 16
        let contentWidth = Self.width - 2 * inset
        statusView = status.map { RefreshRateLiveStatusView(width: contentWidth, language: language, now: now, provider: $0) }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        func localize(_ key: LocalizationKey) -> String { tr(key, language: language) }

        func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: string)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.isSelectable = false
            field.preferredMaxLayoutWidth = contentWidth
            return field
        }
        func timeline(_ label: String, hint: String, style: RefreshRateTimelineView.Style) -> NSStackView {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 11, weight: .medium)
            caption.textColor = .secondaryLabelColor
            let hintLabel = NSTextField(labelWithString: hint)
            hintLabel.font = .systemFont(ofSize: 11)
            hintLabel.textColor = .secondaryLabelColor
            hintLabel.alignment = .right
            hintLabel.setContentHuggingPriority(.init(1), for: .horizontal)
            let header = NSStackView(views: [caption, hintLabel])
            header.orientation = .horizontal
            let stack = NSStackView(views: [header, RefreshRateTimelineView(style: style)])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            stack.arrangedSubviews[1].widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            return stack
        }

        // ② The explanation: two timelines (a third once the Mod delivers) and one paragraph.
        let seconds = tr(.keyDashboardOfficialEverySeconds, arguments: [String(Int(selectedInterval))], language: language)
        let timelines = NSStackView(views: [
            timeline(localize(.keyRefreshHelpRowSetting), hint: seconds, style: .wished),
            timeline(localize(.keyRefreshHelpRowActual), hint: localize(.keyRefreshHelpRowActualHint), style: .actual),
        ])
        modTimeline.setViews([timeline(localize(.keyRefreshHelpRowModNow), hint: localize(.keyRefreshHelpRowModHint), style: .mod)], in: .top)
        modTimeline.orientation = .vertical
        modTimeline.alignment = .leading
        modTimeline.isHidden = true
        timelines.addArrangedSubview(modTimeline)
        timelines.orientation = .vertical
        timelines.alignment = .leading
        timelines.spacing = 10
        explanation.setViews([
            text(localize(.keyRefreshHelpTitle), size: 12, weight: .semibold),
            timelines,
            text(localize(.keyRefreshHelpLine1), size: 12),
        ], in: .top)
        explanation.orientation = .vertical
        explanation.alignment = .leading
        explanation.spacing = 10

        expandButton.title = localize(.keyRefreshHelpExpand)
        expandButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        expandButton.imagePosition = .imageLeading
        expandButton.isBordered = false
        expandButton.font = .systemFont(ofSize: 12)
        expandButton.contentTintColor = .secondaryLabelColor
        expandButton.alignment = .left
        expandButton.target = self
        expandButton.action = #selector(toggleExpanded)
        expandButton.isHidden = true

        // ③ The way to the Mod, only while there is none.
        let bolt = NSImageView()
        bolt.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        bolt.contentTintColor = .controlAccentColor
        bolt.setContentHuggingPriority(.required, for: .horizontal)
        let pitch = text(localize(.keyRefreshHelpModFooter), size: 12, color: .labelColor)
        pitch.preferredMaxLayoutWidth = contentWidth - 24 - 70
        let install = NSButton(title: localize(.keyRefreshHelpModInstall), target: self, action: #selector(installTapped))
        install.bezelStyle = .rounded
        install.controlSize = .small
        install.keyEquivalent = ""
        install.setContentHuggingPriority(.required, for: .horizontal)
        let pitchRow = NSStackView(views: [bolt, pitch, install])
        pitchRow.orientation = .horizontal
        pitchRow.alignment = .centerY
        pitchRow.spacing = 8
        footer.setViews([NSBox.separator(width: contentWidth), pitchRow], in: .top)
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 10

        var arranged: [NSView] = []
        if let statusView { arranged.append(statusView) }
        arranged += [expandButton, explanation, footer]
        stack.setViews(arranged, in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        statusView?.onMoodChange = { [weak self] mood in self?.arrange(for: mood, notify: true) }
        arrange(for: statusView?.mood ?? .normal, notify: false)
    }

    required init?(coder: NSCoder) { nil }

    /// Shows what the current state calls for: the explanation (folded away for a problem), the Mod line and the pitch.
    private func arrange(for mood: RefreshHelpMood, notify: Bool) {
        self.mood = mood
        if mood != .alert { expanded = false }
        let folded = mood == .alert && !expanded
        expandButton.isHidden = mood != .alert
        explanation.isHidden = folded
        modTimeline.isHidden = mood != .live
        // The pitch only makes sense while the Mod has delivered nothing (and nothing is broken).
        footer.isHidden = mood != .normal || (statusView?.hasModData ?? false)
        resize(notify: notify)
    }

    private func resize(notify: Bool) {
        layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: fittingSize.height)
        setFrameSize(size)
        if notify { onSizeChange?(size) }
    }

    @objc private func toggleExpanded() {
        expanded.toggle()
        explanation.isHidden = mood == .alert && !expanded
        let name = expanded ? "chevron.down" : "chevron.right"
        expandButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        resize(notify: true)
    }

    @objc private func installTapped() { onInstall?() }

    // MARK: Test seams

    var isExplanationVisible: Bool { !explanation.isHidden }
    var isFooterVisible: Bool { !footer.isHidden }
    var isModTimelineVisible: Bool { !modTimeline.isHidden }
    var isMetaVisible: Bool { statusView?.showsDetails ?? false }
    func toggleExplanationForTesting() { toggleExpanded() }
    func tapInstallForTesting() { installTapped() }
}

/// The small "?" next to a setting's title; a click opens the explanation and the live state in a popover.
final class RefreshRateHelpButton: NSButton {
    private var popover: NSPopover?
    private let selectedInterval: () -> TimeInterval
    private let status: (() -> ClaudeRefreshStatus?)?
    private let openRealtimeBoost: (() -> Void)?

    init(selectedInterval: @escaping () -> TimeInterval, status: (() -> ClaudeRefreshStatus?)? = nil,
         openRealtimeBoost: (() -> Void)? = nil) {
        self.selectedInterval = selectedInterval
        self.status = status
        self.openRealtimeBoost = openRealtimeBoost
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = tr(.keyRefreshHelpTitle)
        setAccessibilityLabel(tr(.keyRefreshHelpTitle))
        identifier = NSUserInterfaceItemIdentifier("refreshRateHelp")
        target = self
        action = #selector(toggle)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func toggle() {
        if let popover, popover.isShown { popover.performClose(nil); return }
        let popover = DashboardTextTooltip.makePopover()
        let content = RefreshRateHelpContentView(
            selectedInterval: selectedInterval(), status: status,
            onInstall: { [weak self, weak popover] in
                popover?.performClose(nil)
                self?.openRealtimeBoost?()
            })
        content.onSizeChange = { [weak popover] size in popover?.contentSize = size }
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}
