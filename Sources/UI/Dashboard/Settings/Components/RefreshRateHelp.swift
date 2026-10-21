import AppKit

private extension NSBox {
    static func separator(width: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }
}

/// A thin bar in the state's color that fills up towards the next official read.
final class RefreshProgressBarView: NSView {
    var progress: Double = 0 { didSet { if progress != oldValue { needsDisplay = true } } }
    var tint: NSColor = .systemGreen { didSet { if tint != oldValue { needsDisplay = true } } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 4).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
            let filled = bounds.width * CGFloat(min(1, max(0, progress)))
            guard filled > 0 else { return }
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(filled, bounds.height), height: bounds.height),
                         xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// Words shared by the Settings status card and the menu's "Refresh Now".
enum ClaudeRefreshText {
    /// "2 min 5 s", "40 s": short, in the language's own units.
    static func duration(_ seconds: TimeInterval, language: AppLanguage = .selected) -> String {
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

    /// Why the menu's "Refresh Now" is greyed out, in a sentence, or nil when it is not. An expired sign-in keeps
    /// the item enabled: after running `claude`, a click is what re-reads the credentials.
    static func menuBlockReason(_ manual: ClaudeRefreshStatus.ManualRefresh, language: AppLanguage = .selected) -> String? {
        let key: LocalizationKey
        switch manual {
        case .now, .loginExpired: return nil
        case .rateLimited: key = .keyRefreshMenuBlockedRate
        case .reading: key = .keyRefreshMenuBlockedReading
        case .justRead: key = .keyRefreshMenuBlockedJustRead
        case .alreadyFresh: key = .keyRefreshMenuBlockedFresh
        case .noPoints: key = .keyRefreshMenuBlockedWait
        }
        return tr(key, language: language)
    }

    /// The greyed "Refresh Now"'s subtitle: why, then when it can refresh again (when that is known), each wrapped
    /// to the menu's width so a long translation does not widen the menu.
    static func menuBlockSubtitle(_ manual: ClaudeRefreshStatus.ManualRefresh, language: AppLanguage = .selected,
                                  width: CGFloat = menuSubtitleWidth) -> String? {
        guard let reason = menuBlockReason(manual, language: language) else { return nil }
        let remaining: TimeInterval?
        switch manual {
        case let .justRead(seconds), let .noPoints(seconds), let .rateLimited(seconds): remaining = seconds
        case .now, .loginExpired, .reading, .alreadyFresh: remaining = nil
        }
        var lines = [reason]
        if let remaining {
            lines.append(tr(.keyRefreshMenuAvailableIn, arguments: [duration(remaining, language: language)], language: language))
        }
        return lines.map { wrapped($0, width: width) }.joined(separator: "\n")
    }

    /// Room for a subtitle line in the 304 pt menu, after the title inset and the trailing margin.
    static let menuSubtitleWidth: CGFloat = 240
    /// A little larger than AppKit's subtitle font, so the measured lines never come out wider than the menu.
    private static let subtitleFont = NSFont.systemFont(ofSize: 12)

    /// Greedy line breaking: between any two Chinese or Japanese characters, at spaces elsewhere (Latin, Cyrillic,
    /// Korean), so mixed text such as "公式 API が…" still wraps.
    static func wrapped(_ text: String, width: CGFloat) -> String {
        func fits(_ line: String) -> Bool { (line as NSString).size(withAttributes: [.font: subtitleFont]).width <= width }
        func breaksAnywhere(_ character: Character) -> Bool {
            character.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF00...0xFFEF: return true
                default: return false
                }
            }
        }
        guard !fits(text) else { return text }
        var lines: [String] = []
        var current = ""
        for character in text {
            let candidate = current + String(character)
            if fits(candidate) || current.isEmpty {
                current = candidate
                continue
            }
            // Keep a word together: move it to the next line when it started after the last space.
            if !breaksAnywhere(character), let space = current.lastIndex(of: " "),
               !current[current.index(after: space)...].contains(where: breaksAnywhere) {
                lines.append(String(current[..<space]))
                current = String(current[current.index(after: space)...]) + String(character)
            } else if let mark = current.lastIndex(where: { "，、。；：）」』,.;:)".contains($0) }),
                      current.distance(from: current.startIndex, to: mark) >= current.count / 4 {
                // Rather after the last comma or full stop (unless it leaves a very short line) than mid-phrase.
                let next = current.index(after: mark)
                lines.append(String(current[..<next]).trimmingCharacters(in: .whitespaces))
                current = String(current[next...]).trimmingCharacters(in: .whitespaces) + String(character)
            } else {
                lines.append(current.trimmingCharacters(in: .whitespaces))
                current = character == " " ? "" : String(character)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
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
/// read and whether "Refresh Now" would read right now (one line), a read that failed, and how old the Mod's data is
/// once it went stale. The request budget behind it stays internal. Refreshes itself every second on screen.
final class RefreshRateLiveStatusView: NSView {
    /// What to run in a terminal to sign in again.
    static let loginCommand = "claude"

    private let provider: () -> ClaudeRefreshStatus?
    private let language: AppLanguage
    private let now: () -> Date
    private let dot = NSView()
    private let sentence = NSTextField(wrappingLabelWithString: "")
    private let bar = RefreshProgressBarView()
    private let lastReadValue = NSTextField(labelWithString: "")
    private let manualValue = NSTextField(labelWithString: "")
    private var manualRow = NSView()
    private var manualSeparator = NSView()
    private let modValue = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let copyRow = NSStackView()
    private var meta = NSStackView()
    private var modRow = NSView()
    private let failureValue = NSTextField(wrappingLabelWithString: "")
    private var failureRow = NSView()
    private var timer: Timer?
    private var copiedResetTimer: Timer?
    private var tint = NSColor.systemGreen
    private(set) var phase: ClaudeRefreshStatus.Phase = .ready
    /// Whether the last-read / Refresh Now line is shown (hidden while something is wrong).
    var showsDetails: Bool { !meta.isHidden }
    var showsCopyCommand: Bool { !copyRow.isHidden }
    var showsModAge: Bool { !modRow.isHidden }
    var showsLastFailure: Bool { !failureRow.isHidden }
    var manualRefreshText: String? { manualRow.isHidden ? nil : manualValue.stringValue }
    /// Called after every update, so the popover can re-arrange itself and follow the card's height.
    var onUpdate: (() -> Void)?
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

        bar.widthAnchor.constraint(equalToConstant: inner).isActive = true

        copyButton.title = localize(.keyModFailureCopy)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        copyButton.imagePosition = .imageLeading
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyLoginCommand)

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
            // Keep its natural width, so the "·" stays next to its neighbours instead of spreading the line.
            row.setHuggingPriority(.required, for: .horizontal)
            return row
        }
        for field in [lastReadValue, manualValue, modValue] {
            field.font = .systemFont(ofSize: 11)
            field.lineBreakMode = .byClipping
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            field.setContentHuggingPriority(.required, for: .horizontal)
        }
        let lastReadCaption = caption(localize(.keyRefreshStatusLastRead))
        let manualCaption = caption(localize(.keyRefreshStatusManualLabel))
        let lastRead = row([lastReadCaption, lastReadValue])
        manualRow = row([manualCaption, manualValue])
        // One line when it fits ("Last read 15:02 (1 min ago) · Refresh Now available now"), otherwise two.
        let separator = caption("·")
        manualSeparator = separator
        func textWidth(_ string: String) -> CGFloat {
            let field = NSTextField(labelWithString: string)
            field.font = lastReadValue.font
            return field.fittingSize.width
        }
        let widestManual = [localize(.keyRefreshStatusManualNow), localize(.keyRefreshStatusManualFresh),
                            tr(.keyRefreshStatusManualWait, arguments: [duration(59)], language: language)].map(textWidth).max() ?? 0
        let oneLine = lastReadCaption.fittingSize.width + textWidth(tr(.keyRefreshStatusLastReadValue, arguments: ["88:88:88 PM", "59 min"], language: language))
            + separator.fittingSize.width + manualCaption.fittingSize.width + widestManual + 5 * 8
        if oneLine <= inner {
            meta = row([lastRead, separator, manualRow])
        } else {
            meta = NSStackView(views: [lastRead, manualRow])
            meta.orientation = .vertical
            meta.alignment = .leading
            meta.spacing = 6
        }
        modRow = row([caption(localize(.keyRefreshStatusModLabel)), modValue])
        // A read that failed quietly: otherwise "last read" just stays old and nothing says why. One wrapping label
        // (the sign is part of the text), so long translations wrap instead of being cut off.
        failureValue.font = .systemFont(ofSize: 11)
        failureValue.textColor = .systemOrange
        failureValue.isSelectable = false
        failureValue.preferredMaxLayoutWidth = inner
        failureRow = failureValue
        failureRow.isHidden = true

        // Under the sentence, not under the dot.
        copyRow.setViews([copyButton], in: .leading)
        copyRow.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        copyRow.isHidden = true

        let stack = NSStackView(views: [header, copyRow, bar, meta, failureRow, modRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(10, after: header)
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

    deinit {
        timer?.invalidate()
        copiedResetTimer?.invalidate()
    }

    private func duration(_ seconds: TimeInterval) -> String { ClaudeRefreshText.duration(seconds, language: language) }

    /// "15:02:07" in the language's own time style, to the second, so two reads a few seconds apart can be told apart.
    private func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.formattingLocale
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    @objc private func copyLoginCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.loginCommand, forType: .string)
        copyButton.title = tr(.keyModFailureCopied, language: language)
        copiedResetTimer?.invalidate()
        copiedResetTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.copyButton.title = tr(.keyModFailureCopy, language: self.language)
        }
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
            // Fills up towards the moment the official endpoint is asked again.
            progress = age / max(1, status.realtimeFreshnessWindow)
        // Why it has to wait (just read, or the request budget) is the scheduler's business; when is what matters.
        case let .waiting(remaining, total):
            text = localize(.keyRefreshStatusPhaseWaiting, [duration(remaining)]); tint = .systemOrange
            progress = 1 - remaining / max(1, total)
        case .ready:
            text = localize(.keyRefreshStatusPhaseReady); tint = .systemGreen
        }
        let newMood = RefreshHelpMood(phase)
        sentence.stringValue = text
        sentence.font = .systemFont(ofSize: newMood == .alert ? 13 : 12, weight: .medium)
        applyTint()
        bar.isHidden = progress == nil
        bar.tint = tint
        bar.progress = progress ?? 0
        copyRow.isHidden = phase != .loginExpired
        // The one thing to read when something is wrong; the rest only distracts.
        meta.isHidden = newMood == .alert
        if let last = status.scheduler.lastSuccessAt ?? status.scheduler.lastDispatchAt {
            lastReadValue.stringValue = localize(.keyRefreshStatusLastReadValue, [
                clockTime(last), duration(date.timeIntervalSince(last))])
        } else {
            lastReadValue.stringValue = localize(.keyRefreshStatusLastReadNone)
        }
        let manual = status.manualRefresh(now: date)
        var manualHidden = false
        switch manual {
        case .now: manualValue.stringValue = localize(.keyRefreshStatusManualNow)
        case let .justRead(remaining), let .noPoints(remaining):
            manualValue.stringValue = localize(.keyRefreshStatusManualWait, [duration(remaining)])
        case .alreadyFresh: manualValue.stringValue = localize(.keyRefreshStatusManualFresh)
        // The status sentence already says what is going on.
        case .reading, .rateLimited, .loginExpired: manualHidden = true
        }
        manualRow.isHidden = manualHidden
        manualSeparator.isHidden = manualRow.isHidden
        if let failedAt = status.scheduler.lastFailureAt, newMood == .normal {
            failureValue.stringValue = "⚠︎ " + localize(.keyRefreshStatusLastFailed, [clockTime(failedAt)])
            failureRow.isHidden = false
        } else {
            failureRow.isHidden = true
        }
        // Only once the Mod's data went stale: while it is fresh, the sentence already says how old it is.
        if let realtimeAt = status.realtimeAt, newMood == .normal {
            modValue.stringValue = localize(.keyRefreshStatusModValue, [duration(max(0, date.timeIntervalSince(realtimeAt)))])
            modRow.isHidden = false
        } else {
            modRow.isHidden = true
        }
        lastReadValue.invalidateIntrinsicContentSize()
        manualValue.invalidateIntrinsicContentSize()
        failureValue.invalidateIntrinsicContentSize()
        modValue.invalidateIntrinsicContentSize()
        mood = newMood
        hasModData = status.realtimeAt != nil
        onUpdate?()
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
    private let footer = NSStackView()
    private let stack = NSStackView()
    private var mood: RefreshHelpMood = .normal
    private var expanded = false
    private let onInstall: (() -> Void)?
    /// Called when the arrangement changes the content's height, so the popover can follow.
    var onSizeChange: ((NSSize) -> Void)?

    /// - Parameters:
    ///   - status: the live look at the scheduler; without it only the explanation is shown.
    ///   - onInstall: opens the Mod's settings (the "install" button in the footer).
    init(language: AppLanguage = .selected, now: @escaping () -> Date = Date.init,
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
        // ② The explanation: why Claude is slower than the setting, and why other tools make it worse.
        explanation.setViews([
            text(localize(.keyRefreshHelpTitle), size: 12, weight: .semibold),
            text(localize(.keyRefreshHelpLine1), size: 12),
            text(localize(.keyRefreshHelpOtherTools), size: 12),
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

        // ③ The way to the Mod, only while there is none: one quiet line with a link, green like the Mod's dots.
        let bolt = NSImageView()
        bolt.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        bolt.contentTintColor = .systemGreen
        bolt.setContentHuggingPriority(.required, for: .horizontal)
        let install = NSButton(title: "", target: self, action: #selector(installTapped))
        install.attributedTitle = NSAttributedString(string: localize(.keyRefreshHelpModInstall), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.linkColor])
        install.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        install.imagePosition = .imageTrailing
        install.imageHugsTitle = true
        install.contentTintColor = .linkColor
        install.isBordered = false
        install.keyEquivalent = ""
        install.setContentHuggingPriority(.required, for: .horizontal)
        install.setContentCompressionResistancePriority(.required, for: .horizontal)
        let pitch = text(localize(.keyRefreshHelpModFooter), size: 12, color: .labelColor)
        pitch.preferredMaxLayoutWidth = contentWidth - bolt.fittingSize.width - install.fittingSize.width - 2 * 8
        let pitchRow = NSStackView(views: [bolt, pitch, install])
        pitchRow.orientation = .horizontal
        pitchRow.alignment = .firstBaseline
        pitchRow.spacing = 8
        pitchRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        footer.setViews([NSBox.separator(width: contentWidth), pitchRow], in: .top)
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 10

        // ⓪ Who the setting applies to: Codex follows it, Claude has a floor. Everything below is about Claude.
        func overviewRow(_ name: String, _ detail: String, color: NSColor) -> NSStackView {
            // A symbol, so the color follows light and dark mode like the timeline dots.
            let dot = NSImageView()
            dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 6, weight: .regular))
            dot.contentTintColor = color
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
            let detailLabel = text(detail, size: 12)
            detailLabel.preferredMaxLayoutWidth = contentWidth - 6 - 52 - 2 * 8
            let row = NSStackView(views: [dot, nameLabel, detailLabel])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            dot.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor).isActive = true
            return row
        }
        let overview = NSStackView(views: [
            overviewRow("Codex", localize(.keyRefreshHelpOverviewCodex), color: .systemGreen),
            overviewRow("Claude", localize(.keyRefreshHelpOverviewClaude), color: .systemOrange),
        ])
        overview.orientation = .vertical
        overview.alignment = .leading
        overview.spacing = 6
        let claudeHeader = NSTextField(labelWithString: "Claude")
        claudeHeader.font = .systemFont(ofSize: 13, weight: .semibold)

        var arranged: [NSView] = [overview, NSBox.separator(width: contentWidth), claudeHeader]
        if let statusView { arranged.append(statusView) }
        arranged += [expandButton, explanation, footer]
        stack.setViews(arranged, in: .top)
        stack.setCustomSpacing(8, after: claudeHeader)
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
        statusView?.onUpdate = { [weak self] in self?.arrange(for: self?.statusView?.mood ?? .normal, notify: true) }
        arrange(for: statusView?.mood ?? .normal, notify: false)
    }

    required init?(coder: NSCoder) { nil }

    /// Shows what the current state calls for: the explanation (folded away for a problem), the Mod line and the pitch.
    private func arrange(for mood: RefreshHelpMood, notify: Bool) {
        self.mood = mood
        if mood != .alert, expanded {
            expanded = false
            updateExpandChevron()
        }
        let folded = mood == .alert && !expanded
        expandButton.isHidden = mood != .alert
        explanation.isHidden = folded
        // The pitch only makes sense while the Mod has delivered nothing (and nothing is broken).
        footer.isHidden = mood != .normal || (statusView?.hasModData ?? false)
        resize(notify: notify)
    }

    private func resize(notify: Bool) {
        layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: fittingSize.height)
        guard size != frame.size else { return }
        setFrameSize(size)
        if notify { onSizeChange?(size) }
    }

    private func updateExpandChevron() {
        expandButton.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
    }

    @objc private func toggleExpanded() {
        expanded.toggle()
        explanation.isHidden = mood == .alert && !expanded
        updateExpandChevron()
        resize(notify: true)
    }

    @objc private func installTapped() { onInstall?() }

    // MARK: Test seams

    var isExplanationVisible: Bool { !explanation.isHidden }
    var isFooterVisible: Bool { !footer.isHidden }
    var isMetaVisible: Bool { statusView?.showsDetails ?? false }
    var isCopyCommandVisible: Bool { statusView?.showsCopyCommand ?? false }
    var isModAgeVisible: Bool { statusView?.showsModAge ?? false }
    var isLastFailureVisible: Bool { statusView?.showsLastFailure ?? false }
    func refreshStatusForTesting() { statusView?.update() }
    func toggleExplanationForTesting() { toggleExpanded() }
    func tapInstallForTesting() { installTapped() }
}

/// The small "?" next to a setting's title; a click opens the explanation and the live state in a popover.
final class RefreshRateHelpButton: NSButton {
    private var popover: NSPopover?
    private let status: (() -> ClaudeRefreshStatus?)?
    private let openRealtimeBoost: (() -> Void)?

    init(status: (() -> ClaudeRefreshStatus?)? = nil, openRealtimeBoost: (() -> Void)? = nil) {
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
        toolTip = tr(.keyRefreshHelpTooltip)
        setAccessibilityLabel(tr(.keyRefreshHelpTooltip))
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
            status: status,
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
