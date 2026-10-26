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
    }

    struct Band: Equatable {
        var run: ClaudeSourceTimeline.FailureRun
        var rect: CGRect
    }

    struct Tick: Equatable {
        var date: Date
        var x: CGFloat
    }

    let now: Date
    let plot: CGRect
    private(set) var bars: [Bar] = []
    private(set) var bands: [Band] = []
    private(set) var ticks: [Tick] = []

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

    private func barRect(_ source: StatusSlotLiveSource, from minX: CGFloat, to maxX: CGFloat) -> CGRect {
        let lane = laneRect(source)
        return CGRect(
            x: minX, y: lane.midY - Self.barHeight / 2,
            width: max(Self.minimumMarkWidth, maxX - minX), height: Self.barHeight)
    }

    private func makeBars(for source: StatusSlotLiveSource, readings: [ClaudeSourceTimeline.Reading]) -> [Bar] {
        var bars: [Bar] = []
        var lastMarkX: CGFloat = 0
        for reading in readings where reading.source == source {
            let from = max(reading.observedAt, start)
            let to = min(reading.expiresAt, now)
            guard to > from else { continue }
            let minX = x(for: from), maxX = x(for: to)
            if var current = bars.last, minX <= current.rect.maxX + 0.5 {
                if minX - lastMarkX >= Self.minimumDividerSpacing {
                    current.dividers.append(minX)
                    lastMarkX = minX
                }
                current.rect = barRect(source, from: current.rect.minX, to: max(current.rect.maxX, maxX))
                current.readings.append(reading)
                bars[bars.count - 1] = current
            } else {
                bars.append(Bar(source: source, rect: barRect(source, from: minX, to: maxX), readings: [reading], dividers: []))
                lastMarkX = minX
            }
        }
        return bars
    }

    private func makeBand(_ run: ClaudeSourceTimeline.FailureRun) -> Band? {
        let from = max(run.start, start)
        let to = min(run.end ?? now, now)
        guard to >= from, from < now else { return nil }
        // Same size as a bar so the failure reads as one more box in the OAuth row.
        let minX = x(for: from)
        return Band(run: run, rect: barRect(.oauthAPI, from: minX, to: x(for: to)))
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
final class ClaudeSourceTimelineView: NSView {
    struct Content: Equatable {
        var timeline: ClaudeSourceTimeline.Snapshot
        /// The same status the menu card's slot shows; nil before the pipeline published one.
        var status: StatusSlotState?

        static let empty = Content(timeline: .empty, status: nil)
    }

    static let refreshInterval: TimeInterval = 5
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Source-colored dot in front of each lane name.
    static let legendDotSize: CGFloat = 8
    static let legendDotGap: CGFloat = 6

    private let provider: () -> Content
    private let localize: (StatusSlotText) -> String
    private let timeZone: TimeZone
    private let now: () -> Date
    let statusSlot: StatusSlotView
    private(set) var content: Content = .empty
    private var refreshTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?

    var isRefreshTimerRunningForTesting: Bool { refreshTimer != nil }

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
        statusSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusSlot)
        NSLayoutConstraint.activate([
            statusSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusSlot.topAnchor.constraint(equalTo: topAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        reload()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        refreshTimer?.invalidate()
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
        needsDisplay = true
        rebuildToolTips()
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

    override func layout() {
        super.layout()
        rebuildToolTips()
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
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
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
            guard minX >= layout.plot.minX, minX + width + 8 <= nowLabelX else { continue }
            text.draw(at: NSPoint(x: minX, y: axisY), withAttributes: axis)
        }
        nowText.draw(at: NSPoint(x: nowLabelX, y: axisY), withAttributes: nowAttributes)

        for band in layout.bands { drawBand(band) }
        for bar in layout.bars { drawBar(bar, live: bar.rect.maxX >= layout.nowX - 0.5) }

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

    /// A light tint inside a solid outline of the same hue, so each refresh mark inside the
    /// validity period stays visible instead of disappearing into a solid fill. The bar that is
    /// still valid now is filled a little stronger.
    private func drawBar(_ bar: ClaudeSourceTimelineLayout.Bar, live: Bool) {
        let color = Self.color(for: bar.source)
        let radius = min(ClaudeSourceTimelineLayout.cornerRadius, bar.rect.width / 2)
        let outline = NSBezierPath(roundedRect: bar.rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        color.withAlphaComponent(live ? 0.30 : 0.18).setFill()
        outline.fill()
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

    // MARK: Tooltips

    private func time(_ date: Date) -> String { StatusSlotAppearance.timeText(date, timeZone: timeZone) }

    private func rebuildToolTips() {
        removeAllToolTips()
        guard bounds.width > 0 else { return }
        let layout = makeLayout()
        for item in layout.bars {
            let lane = layout.laneRect(item.source)
            addToolTip(NSRect(x: item.rect.minX, y: lane.minY, width: item.rect.width, height: lane.height), owner: self, userData: nil)
        }
        for band in layout.bands { addToolTip(band.rect, owner: self, userData: nil) }
        let oauthLabel = NSRect(x: bounds.minX, y: layout.laneRect(.oauthAPI).minY, width: labelColumnWidth, height: ClaudeSourceTimelineLayout.laneHeight)
        addToolTip(oauthLabel, owner: self, userData: nil)
    }

    /// Text for the hover point: the failure band, the reading under the pointer, or the OAuth rule.
    func toolTipText(at point: NSPoint) -> String? {
        let layout = makeLayout()
        if point.x < layout.plot.minX {
            let lane = layout.laneRect(.oauthAPI)
            return point.y >= lane.minY && point.y < lane.maxY ? tr(.keyClaudeTimelineTooltipOauthRule) : nil
        }
        if let band = layout.bands.last(where: { $0.rect.contains(point) }) {
            return tr(.keyClaudeTimelineTooltipFailure, arguments: [
                laneName(.oauthAPI), Self.failureText(band.run.kind),
                time(band.run.start), band.run.end.map(time) ?? tr(.keyClaudeTimelineNow)])
        }
        guard let bar = layout.bars.first(where: {
            layout.laneRect($0.source).contains(point) && point.x >= $0.rect.minX && point.x <= $0.rect.maxX
        }) else { return nil }
        let date = layout.date(at: point.x)
        let reading = bar.readings.last(where: { $0.observedAt <= date }) ?? bar.readings[0]
        return tr(.keyClaudeTimelineTooltipReading, arguments: [
            laneName(reading.source), time(reading.observedAt), time(reading.expiresAt)])
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

extension ClaudeSourceTimelineView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTipText(at: point) ?? ""
    }
}
