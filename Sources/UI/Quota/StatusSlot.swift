import AppKit

/// Which source produced a value that is still live.
enum StatusSlotLiveSource: Equatable {
    /// The official OAuth usage API, read recently.
    case oauthAPI
    /// Claude Code's statusLine (native sync).
    case statusLine
    /// The BalanceBar Mod's snapshots.
    case mod
}

/// Where the most recent non-estimated value came from.
enum StatusSlotSource: Equatable {
    /// A fresh reading from the given live source.
    case realtime(StatusSlotLiveSource)
    /// The value was read from the official usage endpoint a while ago.
    case official
}

/// Context the display model does not carry; supplied by the integration layer (INT-1).
struct StatusSlotContext: Equatable {
    var isRefreshing: Bool
    var source: StatusSlotSource
    /// Time the displayed number was produced (official read, estimate, or failure).
    var updatedAt: Date?
    /// Source of the newest displayed reading, whether or not it is still live.
    var lastSource: StatusSlotLiveSource?
    /// Another client is actively using the account; refresh frequency was raised.
    var externalActivityDetected: Bool

    init(
        isRefreshing: Bool = false,
        source: StatusSlotSource = .official,
        updatedAt: Date? = nil,
        lastSource: StatusSlotLiveSource? = nil,
        externalActivityDetected: Bool = false
    ) {
        self.isRefreshing = isRefreshing
        self.source = source
        self.updatedAt = updatedAt
        self.lastSource = lastSource
        self.externalActivityDetected = externalActivityDetected
    }
}

/// Status-slot states, ordered by display priority.
enum StatusSlotState: Equatable {
    case refreshing
    case error(at: Date?, source: StatusSlotLiveSource? = nil)
    case resetPending(at: Date?)
    case estimated(at: Date?)
    case realtime(StatusSlotLiveSource, at: Date?)
    case official(at: Date?, source: StatusSlotLiveSource? = nil)

    /// Picks the first matching state: refreshing, error, reset pending, estimated, realtime, official.
    static func resolve(model: QuotaDisplayModel, context: StatusSlotContext) -> StatusSlotState {
        if context.isRefreshing { return .refreshing }
        if model.state == .error || model.state == .expired { return .error(at: context.updatedAt, source: context.lastSource) }
        if model.state == .resetPendingConfirmation
            || model.windows.contains(where: { $0.state == .resetPendingConfirmation }) {
            return .resetPending(at: context.updatedAt)
        }
        if model.isEstimated { return .estimated(at: context.updatedAt) }
        if case let .realtime(source) = context.source { return .realtime(source, at: context.updatedAt) }
        return .official(at: context.updatedAt, source: context.lastSource)
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
    case agoMinutes = "quota.status.ago.minutes"
    case agoHours = "quota.status.ago.hours"
    case agoDays = "quota.status.ago.days"
    case sourceOAuthAPI = "quota.status.source.oauth_api"
    case sourceStatusLine = "quota.status.source.native_sync"
    case sourceMod = "quota.status.source.mod"
    case resetPending = "quota.status.reset_pending"
    case resetPendingShort = "quota.status.reset_pending_short"
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
        case .agoMinutes: return "%@ 分钟前"
        case .agoHours: return "%@ 小时前"
        case .agoDays: return "%@ 天前"
        case .sourceOAuthAPI: return "OAuth API"
        case .sourceStatusLine: return "原生同步"
        case .sourceMod: return "Mod"
        case .resetPending: return "预计已重置，等待确认"
        case .resetPendingShort: return "待确认"
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

    /// "N 分钟前" / "N 小时前" / "N 天前"; under a minute (or a clock that ran backwards) reads as one
    /// minute, because anything fresher than the live thresholds never reaches this label.
    static func relativeText(from date: Date?, now: Date, localize: (StatusSlotText) -> String) -> String {
        guard let date else { return "--" }
        let minutes = max(1, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return String(format: localize(.agoMinutes), "\(minutes)") }
        let hours = minutes / 60
        if hours < 24 { return String(format: localize(.agoHours), "\(hours)") }
        return String(format: localize(.agoDays), "\(hours / 24)")
    }

    static func timeText(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "--:--:--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// The card's top-right status indicator. Fixed width so the card title never shifts.
final class StatusSlotView: NSView {
    /// Fixed slot width, sized for the widest state ("● 实时 · 原生同步" in the longest language /
    /// "⚠︎ 88:88:88") at the same 12 pt as the plain refresh time. It is anchored at the right edge
    /// of the card's refresh-time column and extends leftwards; the card title shrinks to make room.
    static let fixedWidth: CGFloat = 156
    static let fontSize: CGFloat = 12
    static let fixedHeight: CGFloat = 16
    static let dotDiameter: CGFloat = 6

    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let localize: (StatusSlotText) -> String
    private let timeZone: TimeZone
    private let now: () -> Date
    private var ageTimer: Timer?
    private(set) var state: StatusSlotState = .official(at: nil)
    private(set) var externalActivityDetected = false

    var textForTesting: String { label.stringValue }
    var textColorForTesting: NSColor? { label.textColor }
    var fontForTesting: NSFont? { label.font }
    var isDotVisibleForTesting: Bool { !dot.isHidden }

    init(
        localize: @escaping (StatusSlotText) -> String = StatusSlotText.defaultLocalize,
        timeZone: TimeZone = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.localize = localize
        self.timeZone = timeZone
        self.now = now
        super.init(frame: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: Self.fixedHeight))
        label.font = .monospacedDigitSystemFont(ofSize: Self.fontSize, weight: .regular)
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

    deinit { ageTimer?.invalidate() }

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
        case let .error(at, _): base = String(format: localize(.hoverError), time(at))
        case .resetPending: base = localize(.resetPending)
        case let .estimated(at): base = String(format: localize(.hoverEstimated), time(at))
        case let .realtime(source, at):
            base = source == .oauthAPI ? String(format: localize(.hoverOfficial), time(at)) : localize(.hoverRealtime)
        case let .official(at, _): base = String(format: localize(.hoverOfficial), time(at))
        }
        guard externalActivityDetected else { return base }
        return base + "\n" + localize(.hoverExternalActivity)
    }

    private func sourceName(_ source: StatusSlotLiveSource) -> String {
        switch source {
        case .oauthAPI: return localize(.sourceOAuthAPI)
        case .statusLine: return localize(.sourceStatusLine)
        case .mod: return localize(.sourceMod)
        }
    }

    /// "5 分钟前 · Mod": how old the displayed reading is and who produced it.
    private func ageText(_ date: Date?, _ source: StatusSlotLiveSource?) -> String {
        let age = StatusSlotAppearance.relativeText(from: date, now: now(), localize: localize)
        return source.map { age + " · " + sourceName($0) } ?? age
    }

    private var showsAge: Bool {
        switch state {
        case .official, .error: return true
        default: return false
        }
    }

    /// Re-renders the relative time while the slot is on screen, so "5 分钟前" keeps counting.
    func refreshAgeForTesting() { if showsAge { apply() } }

    private func syncAgeTimer() {
        guard showsAge, window != nil else {
            ageTimer?.invalidate()
            ageTimer = nil
            return
        }
        guard ageTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.apply() }
        timer.tolerance = 2
        ageTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncAgeTimer()
        if window != nil, showsAge { apply() }
    }

    private func time(_ date: Date?) -> String { StatusSlotAppearance.timeText(date, timeZone: timeZone) }

    private func apply() {
        dot.isHidden = true
        switch state {
        case .refreshing:
            label.stringValue = localize(.refreshing)
            label.textColor = .secondaryLabelColor
        case let .error(at, source):
            label.stringValue = "⚠︎ " + ageText(at, source)
            label.textColor = .systemOrange
        case .resetPending:
            label.stringValue = localize(.resetPendingShort)
            label.textColor = .secondaryLabelColor
        case let .estimated(at):
            label.stringValue = StatusSlotAppearance.estimatePrefix + time(at)
            label.textColor = .secondaryLabelColor
        case let .realtime(source, _):
            label.stringValue = localize(.realtime) + " · " + sourceName(source)
            label.textColor = .secondaryLabelColor
            dot.isHidden = false
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case let .official(at, source):
            label.stringValue = ageText(at, source)
            label.textColor = .secondaryLabelColor
            dot.isHidden = false
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        }
        syncAgeTimer()
        toolTip = hoverText
        setAccessibilityLabel(String(format: localize(.accessibilityStatus), label.stringValue))
        setAccessibilityHelp(hoverText)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let color: NSColor
        switch state {
        case .realtime: color = .systemGreen
        case .official: color = .systemOrange
        default: return
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = color.cgColor
        }
    }
}

extension StatusSlotText {
    /// Routes copy through the app's localization tables. Format strings keep a
    /// literal `%@` so the slot can substitute the time later.
    static let appLocalize: (StatusSlotText) -> String = { appLocalize(text: $0, language: .selected) }

    static func appLocalize(text: StatusSlotText, language: AppLanguage) -> String {
        guard let key = LocalizationKey(rawValue: text.rawValue) else { return text.defaultText }
        switch text {
        case .hoverError, .hoverEstimated, .hoverOfficial, .accessibilityStatus, .agoMinutes, .agoHours, .agoDays:
            return tr(key, arguments: ["%@"], language: language)
        default:
            return tr(key, language: language)
        }
    }
}
