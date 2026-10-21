import AppKit

/// Three short timelines that show, without numbers to read, why the refresh is slower than the setting:
/// the chosen frequency (many small dots), what Claude's official endpoint allows (a few dots) and the Mod
/// (a dot after every reply).
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

/// Dots for the request tokens left (filled) out of the bucket's capacity.
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
                    NSColor.controlAccentColor.setFill()
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

/// "Right now": what is holding the next official read back, with a bar that fills while it waits, the request
/// tokens as dots and the age of the Mod's data. Refreshes itself every second while it is on screen.
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
    private var timer: Timer?

    init(width: CGFloat, language: AppLanguage, now: @escaping () -> Date = Date.init, provider: @escaping () -> ClaudeRefreshStatus?) {
        self.provider = provider
        self.language = language
        self.now = now
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        func localize(_ key: LocalizationKey) -> String { tr(key, language: language) }
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        sentence.font = .systemFont(ofSize: 12, weight: .medium)
        sentence.isSelectable = false
        sentence.preferredMaxLayoutWidth = width - 8 - 8
        let header = NSStackView(views: [dot, sentence])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        header.alignment = .top

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: width).isActive = true

        func infoRow(_ label: String, _ value: NSView) -> NSView {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            caption.setContentHuggingPriority(.required, for: .horizontal)
            caption.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = NSStackView(views: [caption, value])
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
        let tokenHint = NSTextField(wrappingLabelWithString: localize(.keyRefreshStatusTokensHint))
        tokenHint.font = .systemFont(ofSize: 10)
        tokenHint.textColor = .tertiaryLabelColor
        tokenHint.isSelectable = false
        tokenHint.preferredMaxLayoutWidth = width

        let stack = NSStackView(views: [
            header, bar,
            infoRow(localize(.keyRefreshStatusLastRead), lastReadValue),
            infoRow(localize(.keyRefreshStatusTokensLabel), tokenDots),
            tokenHint,
            infoRow(localize(.keyRefreshStatusModLabel), modValue),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
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

    /// Reads the scheduler's state and shows it.
    func update() {
        func localize(_ key: LocalizationKey, _ arguments: [String] = []) -> String { tr(key, arguments: arguments, language: language) }
        guard let status = provider() else { return }
        let date = now()
        let phase = status.phase(now: date)
        var color = NSColor.systemGreen
        var progress: Double?
        let text: String
        switch phase {
        case .reading:
            text = localize(.keyRefreshStatusPhaseReading)
        case .loginExpired:
            text = localize(.keyRefreshStatusPhaseLogin); color = .systemRed
        case let .rateLimited(remaining):
            text = localize(.keyRefreshStatusPhaseRate, [duration(remaining)]); color = .systemRed
        case let .liveFresh(age):
            text = localize(.keyRefreshStatusPhaseLive, [duration(age)])
            progress = 1 - age / max(1, status.realtimeFreshnessWindow)
        case let .waitingInterval(remaining, total):
            text = localize(.keyRefreshStatusPhaseInterval, [duration(remaining)]); color = .systemOrange
            progress = 1 - remaining / max(1, total)
        case let .waitingTokens(remaining, total):
            text = localize(.keyRefreshStatusPhaseTokens, [duration(remaining)]); color = .systemOrange
            progress = 1 - remaining / max(1, total)
        case .ready:
            text = localize(.keyRefreshStatusPhaseReady)
        }
        sentence.stringValue = text
        dot.effectiveAppearance.performAsCurrentDrawingAppearance { dot.layer?.backgroundColor = color.cgColor }
        bar.isHidden = progress == nil
        bar.doubleValue = min(1, max(0, progress ?? 0))
        if let last = status.scheduler.lastSuccessAt ?? status.scheduler.lastDispatchAt {
            lastReadValue.stringValue = localize(.keyRefreshStatusLastReadValue, [
                StatusSlotAppearance.timeText(last, timeZone: .current), duration(date.timeIntervalSince(last))])
        } else {
            lastReadValue.stringValue = localize(.keyRefreshStatusLastReadNone)
        }
        tokenDots.filled = status.tokensAvailable(at: date)
        if let realtimeAt = status.realtimeAt {
            modValue.stringValue = localize(.keyRefreshStatusModValue, [duration(max(0, date.timeIntervalSince(realtimeAt)))])
        } else {
            modValue.stringValue = localize(.keyRefreshStatusModNone)
        }
        lastReadValue.invalidateIntrinsicContentSize()
        modValue.invalidateIntrinsicContentSize()
    }
}

/// The content of the "?" popover next to the refresh frequency: a title, the timelines and three plain sentences.
final class RefreshRateHelpContentView: NSView {
    static let width: CGFloat = 340

    /// - Parameter selectedInterval: the frequency currently chosen in Settings, shown next to the first timeline.
    init(selectedInterval: TimeInterval, language: AppLanguage = .selected, now: @escaping () -> Date = Date.init,
         status: (() -> ClaudeRefreshStatus?)? = nil) {
        func localize(_ key: LocalizationKey) -> String { tr(key, language: language) }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        let inset: CGFloat = 16
        let contentWidth = Self.width - 2 * inset

        func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: string)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.isSelectable = false
            field.preferredMaxLayoutWidth = contentWidth
            return field
        }
        func timeline(_ label: String, hint: String, style: RefreshRateTimelineView.Style) -> NSView {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 11, weight: .medium)
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

        let seconds = tr(.keyDashboardOfficialEverySeconds, arguments: [String(Int(selectedInterval))], language: language)
        let rows = NSStackView(views: [
            timeline(localize(.keyRefreshHelpRowSetting), hint: seconds, style: .wished),
            timeline(localize(.keyRefreshHelpRowActual), hint: localize(.keyRefreshHelpRowActualHint), style: .actual),
            timeline(localize(.keyRefreshHelpRowMod), hint: localize(.keyRefreshHelpRowModHint), style: .mod),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10

        var live: [NSView] = []
        if let status {
            live = [
                text(localize(.keyRefreshStatusNowTitle), size: 13, weight: .semibold),
                RefreshRateLiveStatusView(width: contentWidth, language: language, now: now, provider: status),
                NSBox.separator(width: contentWidth),
            ]
        }
        let stack = NSStackView(views: live + [
            text(localize(.keyRefreshHelpTitle), size: 13, weight: .semibold),
            rows,
            text(localize(.keyRefreshHelpLine1), size: 12, color: .secondaryLabelColor),
            text(localize(.keyRefreshHelpLine2), size: 12, color: .secondaryLabelColor),
            text(localize(.keyRefreshHelpLine3), size: 12),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
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
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Self.width, height: fittingSize.height))
    }

    required init?(coder: NSCoder) { nil }
}

/// The small "?" next to a setting's title; a click opens the plain-language explanation in a popover.
final class RefreshRateHelpButton: NSButton {
    private var popover: NSPopover?
    private let selectedInterval: () -> TimeInterval
    private let status: (() -> ClaudeRefreshStatus?)?

    init(selectedInterval: @escaping () -> TimeInterval, status: (() -> ClaudeRefreshStatus?)? = nil) {
        self.selectedInterval = selectedInterval
        self.status = status
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
        let content = RefreshRateHelpContentView(selectedInterval: selectedInterval(), status: status)
        let controller = NSViewController()
        controller.view = content
        let popover = DashboardTextTooltip.makePopover()
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}
