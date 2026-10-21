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

/// The content of the "?" popover next to the refresh frequency: a title, the timelines and three plain sentences.
final class RefreshRateHelpContentView: NSView {
    static let width: CGFloat = 340

    /// - Parameter selectedInterval: the frequency currently chosen in Settings, shown next to the first timeline.
    init(selectedInterval: TimeInterval, language: AppLanguage = .selected) {
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

        let stack = NSStackView(views: [
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

    init(selectedInterval: @escaping () -> TimeInterval) {
        self.selectedInterval = selectedInterval
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
        let content = RefreshRateHelpContentView(selectedInterval: selectedInterval())
        let controller = NSViewController()
        controller.view = content
        let popover = DashboardTextTooltip.makePopover()
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}
