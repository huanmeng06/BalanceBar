import AppKit

/// Geometry of the Advanced page's Claude source timeline, kept free of drawing so tests can
/// check it directly. Coordinates are flipped (y grows downwards), like the view.
struct ClaudeSourceTimelineLayout {
    static let span: TimeInterval = 60 * 60
    static let tickStep: TimeInterval = 15 * 60
    static let headerHeight: CGFloat = 26
    static let laneHeight: CGFloat = 30
    static let barHeight: CGFloat = 18
    static let cornerRadius: CGFloat = 6
    static let axisGap: CGFloat = 5
    static let axisLabelHeight: CGFloat = 15
    static let labelGap: CGFloat = 12
    static let minimumDividerSpacing: CGFloat = 5
    static let minimumMarkWidth: CGFloat = 4
    /// Top to bottom, as in the design sketch (Issue #619).
    static let lanes: [StatusSlotLiveSource] = [.mod, .statusLine, .oauthAPI]
    static let height: CGFloat = headerHeight + laneHeight * CGFloat(lanes.count) + axisGap + axisLabelHeight

    /// One continuous bar: overlapping or touching validity periods of the same source.
    struct Bar: Equatable {
        var source: StatusSlotLiveSource
        var rect: CGRect
        var readings: [ClaudeSourceTimeline.Reading]
        /// x positions where a later reading starts inside the bar, far enough apart to show.
        var dividers: [CGFloat]
        /// The blocks between dividers, each the readings that start inside it.
        var pieces: [Piece] = []
    }

    /// One block of a bar (what hovering lifts): from its first reading until the next block
    /// starts, or until the bar ends.
    struct Piece: Equatable {
        var source: StatusSlotLiveSource
        var rect: CGRect
        var readings: [ClaudeSourceTimeline.Reading]
        var start: Date
        var end: Date
    }

    struct Band: Equatable {
        var run: ClaudeSourceTimeline.FailureRun
        var rect: CGRect
    }

    struct Tick: Equatable {
        var date: Date
        var x: CGFloat
    }

    /// One mark ending where a mark in another lane starts: a dashed line ties them together as
    /// the same moment (e.g. local data expiring and the official read taking over).
    struct Junction: Equatable {
        var x: CGFloat
        var minY: CGFloat
        var maxY: CGFloat
    }

    /// Edges this close (about 18 s on a 600 pt chart) count as the same moment.
    static let junctionTolerance: CGFloat = 3

    let now: Date
    let plot: CGRect
    private(set) var bars: [Bar] = []
    private(set) var bands: [Band] = []
    private(set) var ticks: [Tick] = []
    private(set) var junctions: [Junction] = []

    var start: Date { now.addingTimeInterval(-Self.span) }
    var nowX: CGFloat { plot.maxX }
    var baselineY: CGFloat { plot.maxY + 1 }

    init(
        snapshot: ClaudeSourceTimeline.Snapshot, now: Date, bounds: CGRect,
        labelColumnWidth: CGFloat, timeZone: TimeZone
    ) {
        self.now = now
        let left = bounds.minX + labelColumnWidth
        plot = CGRect(
            x: left, y: bounds.minY + Self.headerHeight,
            width: max(1, bounds.maxX - left), height: Self.laneHeight * CGFloat(Self.lanes.count))
        bars = Self.lanes.flatMap { makeBars(for: $0, readings: snapshot.readings) }
        bands = snapshot.failures.compactMap(makeBand)
        ticks = makeTicks(timeZone: timeZone)
        junctions = makeJunctions()
    }

    func x(for date: Date) -> CGFloat {
        let fraction = date.timeIntervalSince(start) / Self.span
        return plot.minX + plot.width * CGFloat(min(1, max(0, fraction)))
    }

    func date(at x: CGFloat) -> Date {
        let fraction = (x - plot.minX) / plot.width
        return start.addingTimeInterval(Self.span * Double(min(1, max(0, fraction))))
    }

    func laneRect(_ source: StatusSlotLiveSource) -> CGRect {
        let index = CGFloat(Self.lanes.firstIndex(of: source) ?? 0)
        return CGRect(x: plot.minX, y: plot.minY + index * Self.laneHeight, width: plot.width, height: Self.laneHeight)
    }

    /// A mark shorter than the minimum width grows leftwards, so a reading that just arrived never
    /// pokes past the "now" line.
    private func barRect(_ source: StatusSlotLiveSource, from minX: CGFloat, to maxX: CGFloat) -> CGRect {
        let lane = laneRect(source)
        let width = max(Self.minimumMarkWidth, maxX - minX)
        let left = max(plot.minX, min(minX, plot.maxX - width))
        return CGRect(
            x: left, y: lane.midY - Self.barHeight / 2,
            width: min(width, plot.maxX - left), height: Self.barHeight)
    }

    private func makeBars(for source: StatusSlotLiveSource, readings: [ClaudeSourceTimeline.Reading]) -> [Bar] {
        var bars: [Bar] = []
        // Readings grouped by block, parallel to `bars`: a divider starts a new block.
        var groups: [[[ClaudeSourceTimeline.Reading]]] = []
        var ends: [Date] = []
        var lastMarkX: CGFloat = 0
        for reading in readings where reading.source == source {
            let from = max(reading.observedAt, start)
            let to = min(reading.expiresAt, now)
            guard to > from else { continue }
            let minX = x(for: from), maxX = x(for: to)
            if var current = bars.last, minX <= current.rect.maxX + 0.5 {
                if minX - lastMarkX >= Self.minimumDividerSpacing {
                    current.dividers.append(minX)
                    groups[groups.count - 1].append([reading])
                    lastMarkX = minX
                } else {
                    groups[groups.count - 1][groups[groups.count - 1].count - 1].append(reading)
                }
                current.rect = barRect(source, from: current.rect.minX, to: max(current.rect.maxX, maxX))
                current.readings.append(reading)
                bars[bars.count - 1] = current
                ends[ends.count - 1] = max(ends[ends.count - 1], reading.expiresAt)
            } else {
                bars.append(Bar(source: source, rect: barRect(source, from: minX, to: maxX), readings: [reading], dividers: []))
                groups.append([[reading]])
                ends.append(reading.expiresAt)
                lastMarkX = minX
            }
        }
        for index in bars.indices {
            let bar = bars[index]
            let edges = [bar.rect.minX] + bar.dividers + [bar.rect.maxX]
            let blocks = groups[index]
            bars[index].pieces = blocks.indices.map { block in
                // Real times, not the ones clipped to the chart, so the tooltip stays put while
                // the left edge slides; an end after now means the block is still running.
                let pieceStart = blocks[block][0].observedAt
                let pieceEnd = block + 1 < blocks.count ? blocks[block + 1][0].observedAt : ends[index]
                return Piece(
                    source: source,
                    rect: CGRect(x: edges[block], y: bar.rect.minY, width: edges[block + 1] - edges[block], height: bar.rect.height),
                    readings: blocks[block], start: pieceStart, end: max(pieceEnd, pieceStart))
            }
        }
        return bars
    }

    /// The block (or failure box) under a point, for hovering.
    enum HoverTarget: Equatable {
        case piece(Piece)
        case band(Band)

        var rect: CGRect {
            switch self {
            case let .piece(piece): return piece.rect
            case let .band(band): return band.rect
            }
        }
    }

    func hoverTarget(at point: CGPoint) -> HoverTarget? {
        let slop: CGFloat = 3
        if let band = bands.last(where: { $0.rect.insetBy(dx: -1, dy: -slop).contains(point) }) {
            return .band(band)
        }
        for bar in bars where bar.rect.insetBy(dx: -1, dy: -slop).contains(point) {
            if let piece = bar.pieces.first(where: { point.x >= $0.rect.minX - 1 && point.x <= $0.rect.maxX + 1 }) {
                return .piece(piece)
            }
        }
        return nil
    }

    private func makeBand(_ run: ClaudeSourceTimeline.FailureRun) -> Band? {
        let from = max(run.start, start)
        let to = min(run.end ?? now, now)
        guard to >= from, from < now else { return nil }
        // Same size as a bar so the failure reads as one more box in the OAuth row.
        let minX = x(for: from)
        return Band(run: run, rect: barRect(.oauthAPI, from: minX, to: x(for: to)))
    }

    /// Pairs a real end (not cut off by "now") with a real start (not cut off by the left edge) in
    /// another lane. Failure boxes take part as marks of the OAuth lane.
    private func makeJunctions() -> [Junction] {
        let marks: [(lane: StatusSlotLiveSource, rect: CGRect)] =
            bars.map { ($0.source, $0.rect) } + bands.map { (.oauthAPI, $0.rect) }
        var junctions: [Junction] = []
        for end in marks where end.rect.maxX < nowX - 0.5 {
            for start in marks where start.lane != end.lane && start.rect.minX > plot.minX + 0.5
                && abs(start.rect.minX - end.rect.maxX) <= Self.junctionTolerance {
                // Only across the gap between the two marks, on the edge of the one that starts, so
                // the line leaves one outline and lands on the other instead of piercing both.
                let upper = end.rect.minY < start.rect.minY ? end.rect : start.rect
                let lower = end.rect.minY < start.rect.minY ? start.rect : end.rect
                let junction = Junction(x: start.rect.minX + 0.75, minY: upper.maxY, maxY: lower.minY)
                if !junctions.contains(junction) { junctions.append(junction) }
            }
        }
        return junctions
    }

    /// Quarter-hour marks in the display time zone, so they read as 10:15, 10:30, …
    private func makeTicks(timeZone: TimeZone) -> [Tick] {
        let offset = TimeInterval(timeZone.secondsFromGMT(for: start))
        let local = start.timeIntervalSince1970 + offset
        var value = (local / Self.tickStep).rounded(.up) * Self.tickStep - offset
        var ticks: [Tick] = []
        while value < now.timeIntervalSince1970 {
            let date = Date(timeIntervalSince1970: value)
            ticks.append(Tick(date: date, x: x(for: date)))
            value += Self.tickStep
        }
        return ticks
    }
}

/// Live timeline of Claude quota sources for Settings › Advanced (Issue #619): when each source's
/// readings arrived and how long they counted as valid, official failures, and the current status.
///
/// Hovering a block lifts it (scale and shadow, like the Codex reset card but without the pointer
/// tilt), blurs the rest of the chart (the menu's focus blur) and shows the app's popover tooltip
/// above it with the block's type and duration.
final class ClaudeSourceTimelineView: NSView {
    struct Content: Equatable {
        var timeline: ClaudeSourceTimeline.Snapshot
        /// The same status the menu card's slot shows; nil before the pipeline published one.
        var status: StatusSlotState?

        static let empty = Content(timeline: .empty, status: nil)
    }

    /// Hover look and timings, matching the menu's focus blur and the reset card's lift.
    enum Hover {
        static let liftScale: CGFloat = 1.12
        static let liftShadowOpacity: Float = 0.3
        static let blurRadius: CGFloat = 3
        static let recededAlpha: CGFloat = 0.5
        static let blurDuration: TimeInterval = 0.18
        static let restoreDuration: TimeInterval = 0.2
        static let tooltipDelay: TimeInterval = 0.3
        static let exitDebounce: TimeInterval = 0.08
        static let springStiffness: CGFloat = 320
        static let springDamping: CGFloat = 19
    }

    static let refreshInterval: TimeInterval = 5
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Source-colored dot in front of each lane name.
    static let legendDotSize: CGFloat = 8
    static let legendDotGap: CGFloat = 6
    private static let blurFilterName = "balancebarTimelineFocusBlur"

    private let provider: () -> Content
    private let localize: (StatusSlotText) -> String
    private let timeZone: TimeZone
    private let now: () -> Date
    let statusSlot: StatusSlotView
    /// The board's heading, 「数据来源监视器」.
    let titleLabel = NSTextField(labelWithString: tr(.keyClaudeTimelineTitle))
    private let titleIcon = DashboardRefreshPage.agentIconStrip(["Claude"])
    private let canvas = TimelineCanvas()
    private let liftHost = TimelineFlippedView()
    private let liftLayer = CALayer()
    private let liftFill = CAShapeLayer()
    private let liftTint = CAShapeLayer()
    private(set) var content: Content = .empty
    private var refreshTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?
    /// The lifted block, if any.
    private(set) var hovered: ClaudeSourceTimelineLayout.HoverTarget?
    private var lastMouse: NSPoint?
    private var popover: NSPopover?
    private var tooltipPayload: TooltipPayload?
    private var tooltipWork: DispatchWorkItem?
    private var exitWork: DispatchWorkItem?
    private var hoverGeneration = 0
    private var blurGeneration = 0

    var isRefreshTimerRunningForTesting: Bool { refreshTimer != nil }
    var isLiftedForTesting: Bool { hovered != nil && !liftLayer.isHidden }
    var isChartRecededForTesting: Bool {
        canvas.layer?.filters?.contains { ($0 as? CIFilter)?.name == Self.blurFilterName } == true
    }
    var isTooltipPendingOrShownForTesting: Bool { tooltipWork != nil || popover?.isShown == true }

    init(
        provider: @escaping () -> Content,
        localize: @escaping (StatusSlotText) -> String = StatusSlotText.appLocalize,
        timeZone: TimeZone = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.localize = localize
        self.timeZone = timeZone
        self.now = now
        statusSlot = StatusSlotView(localize: localize, timeZone: timeZone, now: now)
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: ClaudeSourceTimelineLayout.height))
        identifier = NSUserInterfaceItemIdentifier("dashboard.advanced.sourceTimeline")
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wantsLayer = true

        canvas.owner = self
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.wantsLayer = true
        canvas.layerUsesCoreImageFilters = true
        addSubview(canvas)

        liftHost.frame = bounds
        liftHost.autoresizingMask = [.width, .height]
        liftHost.wantsLayer = true
        liftHost.layer?.masksToBounds = false
        liftLayer.isHidden = true
        liftLayer.opacity = 0
        liftLayer.shadowColor = NSColor.black.cgColor
        liftLayer.shadowRadius = 8
        liftLayer.shadowOffset = CGSize(width: 0, height: 3)
        liftLayer.shadowOpacity = 0
        liftLayer.addSublayer(liftFill)
        liftLayer.addSublayer(liftTint)
        liftHost.layer?.addSublayer(liftLayer)
        addSubview(liftHost)

        // Same as a settings row title, followed by the Claude mark like those rows.
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)
        titleIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleIcon)
        statusSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusSlot)
        NSLayoutConstraint.activate([
            statusSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusSlot.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            titleIcon.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: SettingsRowView.titleAccessorySpacing),
            titleIcon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleIcon.trailingAnchor.constraint(lessThanOrEqualTo: statusSlot.leadingAnchor, constant: -8)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        reload()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        refreshTimer?.invalidate()
        tooltipWork?.cancel()
        exitWork?.cancel()
        popover?.close()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ClaudeSourceTimelineLayout.height)
    }

    /// Pulls the latest history and status; called on new events, setting changes and the timer.
    func reload() {
        content = provider()
        if let status = content.status {
            statusSlot.isHidden = false
            statusSlot.update(state: status)
        } else {
            statusSlot.isHidden = true
        }
        setAccessibilityLabel(accessibilitySummary)
        canvas.needsDisplay = true
        // The chart moves under a still pointer as time passes; keep the lifted block in step.
        if hovered != nil, let lastMouse { updateHover(at: lastMouse) }
    }

    // MARK: Layout

    private func laneName(_ source: StatusSlotLiveSource) -> String {
        switch source {
        case .oauthAPI: return localize(.sourceOAuthAPI)
        case .statusLine: return localize(.sourceStatusLine)
        case .mod: return localize(.sourceMod)
        }
    }

    var labelColumnWidth: CGFloat {
        let widest = ClaudeSourceTimelineLayout.lanes.map {
            ceil((laneName($0) as NSString).size(withAttributes: [.font: Self.labelFont]).width)
        }.max() ?? 0
        return Self.legendDotSize + Self.legendDotGap + widest + ClaudeSourceTimelineLayout.labelGap
    }

    func makeLayout() -> ClaudeSourceTimelineLayout {
        ClaudeSourceTimelineLayout(
            snapshot: content.timeline, now: now(), bounds: bounds,
            labelColumnWidth: labelColumnWidth, timeZone: timeZone)
    }

    // MARK: Drawing

    private static func color(for source: StatusSlotLiveSource) -> NSColor {
        switch source {
        case .oauthAPI: return .systemBlue
        case .statusLine: return .systemPurple
        case .mod: return .systemOrange
        }
    }

    static func failureText(_ kind: ClaudeSourceTimeline.FailureKind) -> String {
        switch kind {
        case .network: return tr(.keyClaudeTimelineFailureNetwork)
        case .rateLimited: return tr(.keyClaudeTimelineFailureRateLimited)
        case .unauthorized: return tr(.keyClaudeTimelineFailureUnauthorized)
        case .serverError: return tr(.keyClaudeTimelineFailureServerError)
        case .missingCredentials: return tr(.keyClaudeTimelineFailureMissingCredentials)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        canvas.needsDisplay = true
        if let hovered { styleLift(for: hovered) }
    }

    fileprivate func drawChart() {
        let layout = makeLayout()
        let radius = ClaudeSourceTimelineLayout.cornerRadius
        let name: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor]

        // Lane names with a source-colored dot, and a faint rounded track behind each lane.
        for source in ClaudeSourceTimelineLayout.lanes {
            let lane = layout.laneRect(source)
            let dot = NSRect(
                x: bounds.minX, y: lane.midY - Self.legendDotSize / 2,
                width: Self.legendDotSize, height: Self.legendDotSize)
            Self.color(for: source).setFill()
            NSBezierPath(ovalIn: dot).fill()
            let text = laneName(source) as NSString
            let size = text.size(withAttributes: name)
            text.draw(
                at: NSPoint(x: dot.maxX + Self.legendDotGap, y: lane.midY - size.height / 2), withAttributes: name)
            let track = NSRect(
                x: layout.plot.minX, y: lane.midY - ClaudeSourceTimelineLayout.barHeight / 2,
                width: layout.plot.width, height: ClaudeSourceTimelineLayout.barHeight)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        }

        // Quarter-hour guides (dashed, very faint) and their times under the lanes.
        let axis: [NSAttributedString.Key: Any] = [.font: Self.axisFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let nowAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.controlAccentColor,
        ]
        let nowText = tr(.keyClaudeTimelineNow) as NSString
        let nowSize = nowText.size(withAttributes: nowAttributes)
        let nowLabelX = layout.nowX - nowSize.width
        let axisY = layout.baselineY + ClaudeSourceTimelineLayout.axisGap
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        // The left edge is where history is cut off; label it so the clipped marks have a time.
        let startText = formatter.string(from: layout.start) as NSString
        let startEndX = layout.plot.minX + startText.size(withAttributes: axis).width
        startText.draw(at: NSPoint(x: layout.plot.minX, y: axisY), withAttributes: axis)
        for tick in layout.ticks {
            let guide = NSBezierPath()
            guide.move(to: NSPoint(x: tick.x, y: layout.plot.minY))
            guide.line(to: NSPoint(x: tick.x, y: layout.baselineY))
            guide.lineWidth = 1
            guide.setLineDash([2, 3], count: 2, phase: 0)
            NSColor.separatorColor.setStroke()
            guide.stroke()
            let text = formatter.string(from: tick.date) as NSString
            let width = text.size(withAttributes: axis).width
            let minX = tick.x - width / 2
            guard minX >= startEndX + 8, minX + width + 8 <= nowLabelX else { continue }
            text.draw(at: NSPoint(x: minX, y: axisY), withAttributes: axis)
        }
        nowText.draw(at: NSPoint(x: nowLabelX, y: axisY), withAttributes: nowAttributes)

        // Same-moment junctions sit under the marks, so they show only in the gap between lanes.
        for junction in layout.junctions {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: junction.x, y: junction.minY))
            line.line(to: NSPoint(x: junction.x, y: junction.maxY))
            line.lineWidth = 1.5
            line.lineCapStyle = .round
            line.setLineDash([0.1, 4], count: 2, phase: 0)
            NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
            line.stroke()
        }
        for band in layout.bands { drawBand(band) }
        // Only the bar of the source the card is using right now gets the stronger fill; other
        // sources that are still valid stay light. Before a status is known, every valid bar counts.
        let active = Self.activeSource(content.status)
        for bar in layout.bars {
            let valid = bar.rect.maxX >= layout.nowX - 0.5
            drawBar(bar, live: valid && (content.status == nil || bar.source == active))
        }

        // The "now" line in the accent color, capped with a dot.
        NSColor.controlAccentColor.setFill()
        NSRect(x: layout.nowX - 0.75, y: layout.plot.minY - 2, width: 1.5, height: layout.baselineY - layout.plot.minY + 2).fill()
        NSBezierPath(ovalIn: NSRect(x: layout.nowX - 3, y: layout.plot.minY - 6, width: 6, height: 6)).fill()

        if content.timeline.readings.isEmpty, content.timeline.failures.isEmpty {
            let empty = tr(.keyClaudeTimelineEmpty) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = empty.size(withAttributes: attributes)
            empty.draw(
                at: NSPoint(x: layout.plot.midX - size.width / 2, y: layout.plot.midY - size.height / 2),
                withAttributes: attributes)
        }
    }

    /// The source the status slot says is in use, if any.
    static func activeSource(_ status: StatusSlotState?) -> StatusSlotLiveSource? {
        switch status {
        case let .realtime(source, _): return source
        case let .official(_, source): return source ?? .oauthAPI
        default: return nil
        }
    }

    /// A light tint inside a solid outline of the same hue, so each refresh mark inside the
    /// validity period stays visible instead of disappearing into a solid fill. The block of the
    /// source in use right now is filled clearly stronger.
    private func drawBar(_ bar: ClaudeSourceTimelineLayout.Bar, live: Bool) {
        let color = Self.color(for: bar.source)
        let radius = min(ClaudeSourceTimelineLayout.cornerRadius, bar.rect.width / 2)
        let outline = NSBezierPath(roundedRect: bar.rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        color.withAlphaComponent(0.16).setFill()
        outline.fill()
        // Only the block running right now is darker, not the whole bar.
        if live, let current = bar.pieces.last {
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            color.withAlphaComponent(0.42).setFill()
            current.rect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        color.withAlphaComponent(0.7).setFill()
        for x in bar.dividers {
            NSBezierPath(
                roundedRect: NSRect(x: x - 0.75, y: bar.rect.minY + 5, width: 1.5, height: bar.rect.height - 10),
                xRadius: 0.75, yRadius: 0.75).fill()
        }
        outline.lineWidth = 1.5
        color.setStroke()
        outline.stroke()
    }

    /// A rounded red box the size of a bar (tint, outline, faint stripes); its category is in the tooltip.
    private func drawBand(_ band: ClaudeSourceTimelineLayout.Band) {
        let rect = band.rect
        let radius = min(ClaudeSourceTimelineLayout.cornerRadius, rect.width / 2)
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        NSColor.systemRed.withAlphaComponent(0.14).setFill()
        box.fill()
        NSGraphicsContext.saveGraphicsState()
        box.addClip()
        let stripes = NSBezierPath()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            stripes.move(to: NSPoint(x: x, y: rect.maxY))
            stripes.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += 7
        }
        stripes.lineWidth = 1.5
        NSColor.systemRed.withAlphaComponent(0.28).setStroke()
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()
        box.lineWidth = 1.5
        NSColor.systemRed.setStroke()
        box.stroke()
    }

    // MARK: Hover text

    private func time(_ date: Date) -> String { StatusSlotAppearance.timeText(date, timeZone: timeZone) }

    /// "45 秒" / "3 分钟" / "1 小时 5 分钟".
    static func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return tr(.keyClaudeTimelineDurationSeconds, arguments: [String(seconds)]) }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return tr(.keyClaudeTimelineDurationMinutes, arguments: [String(minutes)]) }
        return tr(.keyClaudeTimelineDurationHours, arguments: [String(minutes / 60), String(minutes % 60)])
    }

    /// Type (heading), then time range, duration and refreshes as labelled rows.
    func hoverContent(for target: ClaudeSourceTimelineLayout.HoverTarget) -> ClaudeSourceTimelineTooltipContent {
        switch target {
        case let .piece(piece):
            let first = piece.readings[0]
            let ongoing = piece.end >= now()
            return ClaudeSourceTimelineTooltipContent(title: laneName(piece.source), color: Self.color(for: piece.source), rows: [
                .init(label: tr(.keyClaudeTimelineHoverTime),
                      value: time(piece.start) + " – " + (ongoing ? tr(.keyClaudeTimelineNow) : time(piece.end))),
                .init(label: tr(.keyClaudeTimelineHoverDuration),
                      value: Self.durationText(min(piece.end, now()).timeIntervalSince(piece.start))),
                .init(label: tr(.keyClaudeTimelineHoverRefreshes),
                      value: tr(.keyClaudeTimelineHoverRefreshCount, arguments: [String(piece.readings.count)])),
                .init(label: tr(.keyClaudeTimelineHoverValidity),
                      value: Self.durationText(first.expiresAt.timeIntervalSince(first.observedAt))),
            ])
        case let .band(band):
            let end = band.run.end ?? now()
            return ClaudeSourceTimelineTooltipContent(
                title: laneName(.oauthAPI) + " · " + Self.failureText(band.run.kind), color: .systemRed, rows: [
                    .init(label: tr(.keyClaudeTimelineHoverTime),
                          value: time(band.run.start) + " – " + (band.run.end.map(time) ?? tr(.keyClaudeTimelineNow))),
                    .init(label: tr(.keyClaudeTimelineHoverDuration),
                          value: Self.durationText(end.timeIntervalSince(band.run.start))),
                ])
        }
    }

    func hoverText(for target: ClaudeSourceTimelineLayout.HoverTarget) -> String {
        hoverContent(for: target).plainText
    }

    /// What hovering at a point shows: a block or failure box, or the calibration rule on the
    /// OAuth lane name.
    func hoverText(at point: NSPoint) -> String? {
        let layout = makeLayout()
        if let target = layout.hoverTarget(at: point) { return hoverText(for: target) }
        return oauthLabelRect(in: layout).contains(point) ? tr(.keyClaudeTimelineTooltipOauthRule) : nil
    }

    private func oauthLabelRect(in layout: ClaudeSourceTimelineLayout) -> NSRect {
        let lane = layout.laneRect(.oauthAPI)
        return NSRect(x: bounds.minX, y: lane.minY, width: labelColumnWidth, height: lane.height)
    }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        exitWork?.cancel()
        exitWork = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouse = point
        updateHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        lastMouse = nil
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.exitWork = nil
            self?.setHover(nil, labelText: nil)
        }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Hover.exitDebounce, execute: work)
    }

    /// Lifts the block under `point` (or shows the OAuth rule over the lane name); test seam too.
    func updateHover(at point: NSPoint) {
        exitWork?.cancel()
        exitWork = nil
        let layout = makeLayout()
        if let target = layout.hoverTarget(at: point) {
            setHover(target, labelText: nil)
        } else if oauthLabelRect(in: layout).contains(point) {
            setHover(nil, labelText: (tr(.keyClaudeTimelineTooltipOauthRule), oauthLabelRect(in: layout)))
        } else {
            setHover(nil, labelText: nil)
        }
    }

    private static func sameTarget(_ lhs: ClaudeSourceTimelineLayout.HoverTarget?, _ rhs: ClaudeSourceTimelineLayout.HoverTarget?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (.piece(a)?, .piece(b)?): return a.source == b.source && a.readings.first == b.readings.first
        case let (.band(a)?, .band(b)?): return a.run.start == b.run.start
        default: return false
        }
    }

    private func setHover(_ target: ClaudeSourceTimelineLayout.HoverTarget?, labelText: (String, NSRect)?) {
        if Self.sameTarget(target, hovered) {
            // Same block: follow its geometry (time moves it) without restarting any animation.
            if let target {
                hovered = target
                placeLift(on: target.rect)
                updateTooltipInPlace(.rich(hoverContent(for: target)), rect: liftedRect(target.rect))
            } else if let labelText {
                if tooltipPayload != .plain(labelText.0) || popover?.isShown != true, tooltipWork == nil {
                    scheduleTooltip(.plain(labelText.0), rect: labelText.1)
                }
            } else {
                closeTooltip()
            }
            return
        }
        let wasHovering = hovered != nil
        hovered = target
        hoverGeneration += 1
        if let target {
            styleLift(for: target)
            placeLift(on: target.rect)
            animateLift(up: true)
            if !wasHovering { setChartReceded(true) }
            scheduleTooltip(.rich(hoverContent(for: target)), rect: liftedRect(target.rect))
        } else {
            animateLift(up: false)
            setChartReceded(false)
            if let labelText { scheduleTooltip(.plain(labelText.0), rect: labelText.1) } else { closeTooltip() }
        }
    }

    // MARK: Lift

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func liftedRect(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -rect.width * (Hover.liftScale - 1) / 2, dy: -rect.height * (Hover.liftScale - 1) / 2)
    }

    private func styleLift(for target: ClaudeSourceTimelineLayout.HoverTarget) {
        let color: NSColor
        let tintAlpha: CGFloat
        switch target {
        case let .piece(piece):
            color = Self.color(for: piece.source)
            tintAlpha = 0.32
        case .band:
            color = .systemRed
            tintAlpha = 0.18
        }
        // The lifted block is opaque: it floats over the blurred chart rather than showing it through.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liftFill.fillColor = NSColor.windowBackgroundColor.cgColor
            liftTint.fillColor = color.withAlphaComponent(tintAlpha).cgColor
            liftTint.strokeColor = color.cgColor
            liftTint.lineWidth = 1.5
            CATransaction.commit()
        }
    }

    private func placeLift(on rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = min(ClaudeSourceTimelineLayout.cornerRadius, rect.width / 2)
        liftLayer.bounds = CGRect(origin: .zero, size: rect.size)
        liftLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        let local = CGRect(origin: .zero, size: rect.size)
        let path = CGPath(roundedRect: local.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius, cornerHeight: radius, transform: nil)
        liftFill.frame = local
        liftTint.frame = local
        liftFill.path = path
        liftTint.path = path
        liftLayer.shadowPath = CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)
        liftLayer.isHidden = false
        CATransaction.commit()
    }

    /// Scale and shadow only (no pointer tilt), on the reset card's spring. The lifted block also
    /// fades: it is a standalone rounded card, so on the way down it dissolves into the continuous
    /// bar underneath instead of landing as a box with its own corners.
    private func animateLift(up: Bool) {
        let scale = up ? Hover.liftScale : 1
        let opacity: Float = up ? Hover.liftShadowOpacity : 0
        let generation = hoverGeneration
        let currentScale = (liftLayer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? (up ? 1 : Hover.liftScale)
        let currentOpacity = liftLayer.presentation()?.shadowOpacity ?? liftLayer.shadowOpacity
        let currentAlpha = liftLayer.presentation()?.opacity ?? (up ? 0 : 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !up, self.hoverGeneration == generation else { return }
            self.liftLayer.isHidden = true
        }
        liftLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        liftLayer.shadowOpacity = opacity
        liftLayer.opacity = up ? 1 : 0
        if !reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = currentAlpha
            fade.toValue = up ? 1 : 0
            fade.duration = up ? 0.12 : Hover.restoreDuration
            fade.timingFunction = CAMediaTimingFunction(name: up ? .easeOut : .easeIn)
            liftLayer.add(fade, forKey: "liftFade")
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = currentScale
            spring.toValue = scale
            spring.stiffness = Hover.springStiffness
            spring.damping = Hover.springDamping
            spring.duration = spring.settlingDuration
            liftLayer.add(spring, forKey: "lift")
            let shadow = CABasicAnimation(keyPath: "shadowOpacity")
            shadow.fromValue = currentOpacity
            shadow.toValue = opacity
            shadow.duration = up ? Hover.blurDuration : Hover.restoreDuration
            shadow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            liftLayer.add(shadow, forKey: "liftShadow")
        }
        CATransaction.commit()
    }

    // MARK: Blur

    /// The menu's focus blur: Gaussian radius 3 and half opacity on everything but the lifted block.
    private func setChartReceded(_ receded: Bool) {
        guard let layer = canvas.layer else { return }
        blurGeneration += 1
        let generation = blurGeneration
        let radius: CGFloat = receded && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? Hover.blurRadius : 0
        let duration = receded ? Hover.blurDuration : Hover.restoreDuration
        let keyPath = "filters.\(Self.blurFilterName).inputRadius"
        if receded, layer.filters?.contains(where: { ($0 as? CIFilter)?.name == Self.blurFilterName }) != true,
           let filter = CIFilter(name: "CIGaussianBlur") {
            filter.name = Self.blurFilterName
            filter.setValue(0, forKey: kCIInputRadiusKey)
            layer.filters = (layer.filters ?? []) + [filter]
        }
        let current = (layer.presentation()?.value(forKeyPath: keyPath) as? CGFloat) ?? (receded ? 0 : Hover.blurRadius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !receded, self.blurGeneration == generation else { return }
            self.canvas.layer?.filters = self.canvas.layer?.filters?.filter { ($0 as? CIFilter)?.name != Self.blurFilterName }
        }
        layer.setValue(radius, forKeyPath: keyPath)
        if !reduceMotion {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = current
            animation.toValue = radius
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "focusBlur")
        }
        CATransaction.commit()
        let alpha = receded ? Hover.recededAlpha : 1
        if reduceMotion {
            canvas.alphaValue = alpha
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                canvas.animator().alphaValue = alpha
            }
        }
    }

    // MARK: Tooltip

    /// A block's structured tooltip, or a plain sentence (the OAuth rule).
    enum TooltipPayload: Equatable {
        case rich(ClaudeSourceTimelineTooltipContent)
        case plain(String)
    }

    private func makeTooltipController(_ payload: TooltipPayload) -> NSViewController {
        let controller: NSViewController
        switch payload {
        case let .rich(content): controller = ClaudeSourceTimelineTooltipViewController(content: content)
        case let .plain(text): controller = DashboardTextTooltipViewController(text: text)
        }
        controller.loadViewIfNeeded()
        return controller
    }

    /// Shows the app's popover tooltip above `rect` after the menu's hover delay; an open tooltip
    /// moves to the new block at once instead.
    private func scheduleTooltip(_ payload: TooltipPayload, rect: CGRect) {
        tooltipWork?.cancel()
        tooltipWork = nil
        if popover?.isShown == true {
            updateTooltipInPlace(payload, rect: rect)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tooltipWork = nil
            self.showTooltip(payload, rect: rect)
        }
        tooltipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Hover.tooltipDelay, execute: work)
    }

    private func showTooltip(_ payload: TooltipPayload, rect: CGRect) {
        guard window != nil else { return }
        let controller = makeTooltipController(payload)
        let popover = DashboardTextTooltip.makePopover()
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        popover.animates = !reduceMotion
        // The view is flipped, so .minY is the top edge: the tooltip opens above the block.
        popover.show(relativeTo: rect, of: self, preferredEdge: .minY)
        self.popover = popover
        tooltipPayload = payload
    }

    private func updateTooltipInPlace(_ payload: TooltipPayload, rect: CGRect) {
        guard let popover, popover.isShown else { return }
        popover.animates = false
        if tooltipPayload != payload {
            let controller = makeTooltipController(payload)
            popover.contentViewController = controller
            popover.contentSize = controller.view.frame.size
            tooltipPayload = payload
        }
        popover.positioningRect = rect
    }

    private func closeTooltip() {
        tooltipWork?.cancel()
        tooltipWork = nil
        guard let popover else { return }
        popover.animates = !reduceMotion
        popover.close()
        self.popover = nil
        tooltipPayload = nil
    }

    // MARK: Accessibility

    var accessibilitySummary: String {
        let counts = ClaudeSourceTimelineLayout.lanes.map { source in
            tr(.keyClaudeTimelineAccessibilityCount, arguments: [
                laneName(source), String(content.timeline.readings.filter { $0.source == source }.count)])
        }
        let failures = tr(.keyClaudeTimelineAccessibilityFailures, arguments: [String(content.timeline.failures.count)])
        return tr(.keyClaudeTimelineAccessibility, arguments: [(counts + [failures]).joined(separator: ", ")])
    }

    // MARK: Refresh timer

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.syncRefreshTimer() }
            reload()
        } else {
            lastMouse = nil
            setHover(nil, labelText: nil)
            closeTooltip()
        }
        syncRefreshTimer()
    }

    override func viewDidHide() {
        super.viewDidHide()
        syncRefreshTimer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncRefreshTimer()
    }

    /// The "now" line only advances while someone can see it.
    func syncRefreshTimer() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        guard visible, !isHiddenOrHasHiddenAncestor else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.reload() }
        timer.tolerance = 1
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        reload()
    }
}

/// What a block's tooltip says: a heading with the source color, then label/value rows.
struct ClaudeSourceTimelineTooltipContent: Equatable {
    struct Row: Equatable {
        var label: String
        var value: String
    }

    var title: String
    var color: NSColor
    var rows: [Row]

    /// One line per row, for tests and logs.
    var plainText: String {
        ([title] + rows.map { $0.label + " " + $0.value }).joined(separator: "\n")
    }
}

/// The block tooltip: a colored dot and a semibold heading over a two-column grid (secondary
/// labels, monospaced-digit values). Sized from its content, so nothing is clipped.
final class ClaudeSourceTimelineTooltipViewController: NSViewController {
    static let horizontalInset: CGFloat = 14
    static let verticalInset: CGFloat = 11

    let content: ClaudeSourceTimelineTooltipContent

    init(content: ClaudeSourceTimelineTooltipContent) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    static let dotSize: CGFloat = 8
    static let dotGap: CGFloat = 6
    static let headingGap: CGFloat = 8
    static let rowGap: CGFloat = 4
    static let columnGap: CGFloat = 14

    /// Frame layout measured from each label's own size: the popover always fits its text.
    override func loadView() {
        func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = font
            field.textColor = color
            field.lineBreakMode = .byClipping
            field.sizeToFit()
            return field
        }
        let title = label(content.title, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        let rows = content.rows.map { row in
            (label(row.label, font: .systemFont(ofSize: 12), color: .secondaryLabelColor),
             label(row.value, font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: .labelColor))
        }
        let labelWidth = ceil(rows.map { $0.0.frame.width }.max() ?? 0)
        let valueWidth = ceil(rows.map { $0.1.frame.width }.max() ?? 0)
        let rowHeight = ceil(rows.map { max($0.0.frame.height, $0.1.frame.height) }.max() ?? 0)
        let titleWidth = Self.dotSize + Self.dotGap + ceil(title.frame.width)
        let gridWidth = rows.isEmpty ? 0 : labelWidth + Self.columnGap + valueWidth
        let contentWidth = max(titleWidth, gridWidth)
        let gridHeight = rows.isEmpty ? 0 : CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * Self.rowGap
        let titleHeight = ceil(title.frame.height)
        let size = NSSize(
            width: contentWidth + 2 * Self.horizontalInset,
            height: titleHeight + (rows.isEmpty ? 0 : Self.headingGap + gridHeight) + 2 * Self.verticalInset)

        let root = TimelineFlippedContainer(frame: NSRect(origin: .zero, size: size))
        let dot = NSView(frame: NSRect(
            x: Self.horizontalInset, y: Self.verticalInset + (titleHeight - Self.dotSize) / 2,
            width: Self.dotSize, height: Self.dotSize))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = content.color.cgColor
        dot.layer?.cornerRadius = Self.dotSize / 2
        root.addSubview(dot)
        title.frame = NSRect(
            x: dot.frame.maxX + Self.dotGap, y: Self.verticalInset, width: ceil(title.frame.width), height: titleHeight)
        root.addSubview(title)
        var y = Self.verticalInset + titleHeight + Self.headingGap
        for (name, value) in rows {
            name.frame = NSRect(x: Self.horizontalInset, y: y, width: labelWidth, height: rowHeight)
            value.frame = NSRect(
                x: Self.horizontalInset + labelWidth + Self.columnGap, y: y, width: valueWidth, height: rowHeight)
            root.addSubview(name)
            root.addSubview(value)
            y += rowHeight + Self.rowGap
        }
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.staticText)
        root.setAccessibilityLabel(content.plainText)
        view = root
        preferredContentSize = root.frame.size
    }
}

/// Draws the chart; a separate view so the focus blur never touches the lifted block or the status.
private final class TimelineCanvas: NSView {
    weak var owner: ClaudeSourceTimelineView?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawChart()
    }
}

/// Top-down coordinates for the tooltip's frame layout.
private final class TimelineFlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Hosts the lifted block's layer in the chart's flipped coordinates.
private final class TimelineFlippedView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
