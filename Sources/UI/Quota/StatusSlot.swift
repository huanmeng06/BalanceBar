import AppKit

/// Where the most recent non-estimated value came from.
enum StatusSlotSource: Equatable {
    /// A real-time local source (e.g. HUD / Mod snapshot) is fresh.
    case realtime
    /// The value was read from the official usage endpoint.
    case official
}

/// Context the display model does not carry; supplied by the integration layer (INT-1).
struct StatusSlotContext: Equatable {
    var isRefreshing: Bool
    var source: StatusSlotSource
    /// Time the displayed number was produced (official read, estimate, or failure).
    var updatedAt: Date?
    /// Another client is actively using the account; refresh frequency was raised.
    var externalActivityDetected: Bool

    init(
        isRefreshing: Bool = false,
        source: StatusSlotSource = .official,
        updatedAt: Date? = nil,
        externalActivityDetected: Bool = false
    ) {
        self.isRefreshing = isRefreshing
        self.source = source
        self.updatedAt = updatedAt
        self.externalActivityDetected = externalActivityDetected
    }
}

/// The five status-slot states, ordered by display priority.
enum StatusSlotState: Equatable {
    case refreshing
    case error(at: Date?)
    case estimated(at: Date?)
    case realtime
    case official(at: Date?)

    /// Picks the first matching state: refreshing, error, estimated, realtime, official.
    static func resolve(model: QuotaDisplayModel, context: StatusSlotContext) -> StatusSlotState {
        if context.isRefreshing { return .refreshing }
        if model.state == .error || model.state == .expired { return .error(at: context.updatedAt) }
        if model.isEstimated { return .estimated(at: context.updatedAt) }
        if context.source == .realtime { return .realtime }
        return .official(at: context.updatedAt)
    }
}

/// User-visible copy for the status slot and failure state.
///
/// Defaults are Simplified Chinese (the architecture spec's wording). The integration
/// layer can inject `localize` to route keys through the app's `tr` tables.
enum StatusSlotText: String, CaseIterable {
    case refreshing = "quota.status.refreshing"
    case realtime = "quota.status.realtime"
    case hoverRefreshing = "quota.status.hover.refreshing"
    case hoverError = "quota.status.hover.error"
    case hoverEstimated = "quota.status.hover.estimated"
    case hoverRealtime = "quota.status.hover.realtime"
    case hoverOfficial = "quota.status.hover.official"
    case hoverExternalActivity = "quota.status.hover.external_activity"
    case resetPending = "quota.status.reset_pending"
    case openUsagePage = "quota.failure.open_usage_page"
    case accessibilityStatus = "quota.status.accessibility"

    var defaultText: String {
        switch self {
        case .refreshing: return "刷新中…"
        case .realtime: return "实时"
        case .hoverRefreshing: return "正在读取最新额度"
        case .hoverError: return "更新失败，显示的是 %@ 的数据"
        case .hoverEstimated: return "根据 %@ 的数据估算，等待官方确认"
        case .hoverRealtime: return "来自本机实时数据"
        case .hoverOfficial: return "官方数据，更新于 %@"
        case .hoverExternalActivity: return "检测到其他端在使用，已提高更新频率"
        case .resetPending: return "预计已重置，等待确认"
        case .openUsagePage: return "打开官方用量页"
        case .accessibilityStatus: return "额度状态：%@"
        }
    }

    static let defaultLocalize: (StatusSlotText) -> String = { $0.defaultText }
}

/// Visual rules shared by the slot, the large number, and the progress bar.
enum StatusSlotAppearance {
    /// Alpha applied to the number and progress bar for estimated / reset-pending values.
    static let dimmedAlpha: CGFloat = 0.55
    static let estimatePrefix = "≈ "

    static func isDimmed(_ window: QuotaWindowDisplay) -> Bool {
        window.isEstimated || window.state == .resetPendingConfirmation
    }

    static func valueAlpha(for window: QuotaWindowDisplay) -> CGFloat {
        isDimmed(window) ? dimmedAlpha : 1
    }

    /// Prefixes the large-number text with ≈ when the value is estimated.
    static func valueText(_ text: String, for window: QuotaWindowDisplay) -> String {
        window.isEstimated ? estimatePrefix + text : text
    }

    static func timeText(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "--:--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// The card's top-right status indicator. Fixed width so the card title never shifts.
final class StatusSlotView: NSView {
    /// Fixed slot width; sized for the widest state ("⚠︎ 88:88" / "刷新中…").
    static let fixedWidth: CGFloat = 64
    static let fixedHeight: CGFloat = 16
    static let dotDiameter: CGFloat = 6

    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let localize: (StatusSlotText) -> String
    private let timeZone: TimeZone
    private(set) var state: StatusSlotState = .official(at: nil)
    private(set) var externalActivityDetected = false

    var textForTesting: String { label.stringValue }
    var textColorForTesting: NSColor? { label.textColor }
    var isDotVisibleForTesting: Bool { !dot.isHidden }

    init(
        localize: @escaping (StatusSlotText) -> String = StatusSlotText.defaultLocalize,
        timeZone: TimeZone = .current
    ) {
        self.localize = localize
        self.timeZone = timeZone
        super.init(frame: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: Self.fixedHeight))
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotDiameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.fixedWidth),
            heightAnchor.constraint(equalToConstant: Self.fixedHeight),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -3),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        apply()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.fixedWidth, height: Self.fixedHeight) }

    func update(state: StatusSlotState, externalActivityDetected: Bool = false) {
        self.state = state
        self.externalActivityDetected = externalActivityDetected
        apply()
    }

    func update(model: QuotaDisplayModel, context: StatusSlotContext) {
        update(
            state: StatusSlotState.resolve(model: model, context: context),
            externalActivityDetected: context.externalActivityDetected
        )
    }

    /// Hover text for the current state, including the external-activity sentence.
    var hoverText: String {
        let base: String
        switch state {
        case .refreshing: base = localize(.hoverRefreshing)
        case let .error(at): base = String(format: localize(.hoverError), time(at))
        case let .estimated(at): base = String(format: localize(.hoverEstimated), time(at))
        case .realtime: base = localize(.hoverRealtime)
        case let .official(at): base = String(format: localize(.hoverOfficial), time(at))
        }
        guard externalActivityDetected else { return base }
        return base + "\n" + localize(.hoverExternalActivity)
    }

    private func time(_ date: Date?) -> String { StatusSlotAppearance.timeText(date, timeZone: timeZone) }

    private func apply() {
        dot.isHidden = true
        switch state {
        case .refreshing:
            label.stringValue = localize(.refreshing)
            label.textColor = .secondaryLabelColor
        case let .error(at):
            label.stringValue = "⚠︎ " + time(at)
            label.textColor = .systemOrange
        case let .estimated(at):
            label.stringValue = StatusSlotAppearance.estimatePrefix + time(at)
            label.textColor = .secondaryLabelColor
        case .realtime:
            label.stringValue = localize(.realtime)
            label.textColor = .secondaryLabelColor
            dot.isHidden = false
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case let .official(at):
            label.stringValue = time(at)
            label.textColor = .secondaryLabelColor
        }
        toolTip = hoverText
        setAccessibilityLabel(String(format: localize(.accessibilityStatus), label.stringValue))
        setAccessibilityHelp(hoverText)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if case .realtime = state {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            }
        }
    }
}
