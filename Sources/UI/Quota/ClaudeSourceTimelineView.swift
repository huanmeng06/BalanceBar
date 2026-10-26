import AppKit

/// Geometry of the Advanced page's Claude source timeline, kept free of drawing so tests can
/// check it directly. Coordinates are flipped (y grows downwards), like the view.
struct ClaudeSourceTimelineLayout {
    static let span: TimeInterval = 60 * 60
    static let tickStep: TimeInterval = 15 * 60
    static let headerHeight: CGFloat = 20
    static let laneHeight: CGFloat = 18
    static let barHeight: CGFloat = 10
    static let axisGap: CGFloat = 3
    static let axisLabelHeight: CGFloat = 14
    static let labelGap: CGFloat = 8
    static let minimumDividerSpacing: CGFloat = 4
    static let minimumMarkWidth: CGFloat = 2
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
        let lane = laneRect(.oauthAPI).insetBy(dx: 0, dy: 2)
        let minX = x(for: from)
        return Band(run: run, rect: CGRect(
            x: minX, y: lane.minY, width: max(Self.minimumMarkWidth, x(for: to) - minX), height: lane.height))
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
    static let labelFont = NSFont.systemFont(ofSize: 11)
    static let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    static let bandFont = NSFont.systemFont(ofSize: 10, weight: .medium)

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
        return widest + ClaudeSourceTimelineLayout.labelGap
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

    /// Whether a band is wide enough to carry its category text.
    static func bandShowsText(_ band: ClaudeSourceTimelineLayout.Band) -> Bool {
        let width = (failureText(band.run.kind) as NSString).size(withAttributes: [.font: bandFont]).width
        return band.rect.width >= ceil(width) + 8
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = makeLayout()
        let secondary: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        for source in ClaudeSourceTimelineLayout.lanes {
            let lane = layout.laneRect(source)
            let name = laneName(source) as NSString
            let size = name.size(withAttributes: secondary)
            name.draw(at: NSPoint(x: bounds.minX, y: lane.midY - size.height / 2), withAttributes: secondary)
        }

        // Baseline under the lanes, quarter-hour ticks and the "now" mark.
        NSColor.separatorColor.setFill()
        NSRect(x: layout.plot.minX, y: layout.baselineY, width: layout.plot.width, height: 1).fill()
        let axis: [NSAttributedString.Key: Any] = [.font: Self.axisFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let nowText = tr(.keyClaudeTimelineNow) as NSString
        let nowSize = nowText.size(withAttributes: axis)
        let nowLabelX = layout.nowX - nowSize.width
        let axisY = layout.baselineY + ClaudeSourceTimelineLayout.axisGap
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        for tick in layout.ticks {
            NSColor.separatorColor.setFill()
            NSRect(x: tick.x, y: layout.plot.minY, width: 0.5, height: layout.plot.height + 1).fill()
            let text = formatter.string(from: tick.date) as NSString
            let width = text.size(withAttributes: axis).width
            let minX = tick.x - width / 2
            guard minX >= layout.plot.minX, minX + width + 6 <= nowLabelX else { continue }
            text.draw(at: NSPoint(x: minX, y: axisY), withAttributes: axis)
        }
        nowText.draw(at: NSPoint(x: nowLabelX, y: axisY), withAttributes: axis)

        for band in layout.bands { drawBand(band) }
        for bar in layout.bars { drawBar(bar) }

        NSColor.labelColor.setFill()
        NSRect(x: layout.nowX - 1, y: layout.plot.minY - 2, width: 1, height: layout.plot.height + 3).fill()

        if content.timeline.readings.isEmpty, content.timeline.failures.isEmpty {
            let empty = tr(.keyClaudeTimelineEmpty) as NSString
            let size = empty.size(withAttributes: secondary)
            empty.draw(
                at: NSPoint(x: layout.plot.midX - size.width / 2, y: layout.plot.midY - size.height / 2),
                withAttributes: secondary)
        }
    }

    /// A light tint inside a solid outline of the same hue, so each refresh mark inside the
    /// validity period stays visible instead of disappearing into a solid fill.
    private func drawBar(_ bar: ClaudeSourceTimelineLayout.Bar) {
        let color = Self.color(for: bar.source)
        let outline = NSBezierPath(roundedRect: bar.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        color.withAlphaComponent(0.18).setFill()
        outline.fill()
        color.withAlphaComponent(0.75).setFill()
        for x in bar.dividers {
            NSRect(x: x - 0.5, y: bar.rect.minY + 2, width: 1, height: bar.rect.height - 4).fill()
        }
        outline.lineWidth = 1
        color.setStroke()
        outline.stroke()
    }

    /// A rounded red box in the bars' style (tint, outline, faint stripes) rather than edge lines.
    private func drawBand(_ band: ClaudeSourceTimelineLayout.Band) {
        let rect = band.rect
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.systemRed.withAlphaComponent(0.12).setFill()
        box.fill()
        NSGraphicsContext.saveGraphicsState()
        box.addClip()
        let stripes = NSBezierPath()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            stripes.move(to: NSPoint(x: x, y: rect.maxY))
            stripes.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += 6
        }
        stripes.lineWidth = 1
        NSColor.systemRed.withAlphaComponent(0.25).setStroke()
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()
        box.lineWidth = 1
        NSColor.systemRed.setStroke()
        box.stroke()
        guard Self.bandShowsText(band) else { return }
        let text = Self.failureText(band.run.kind) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.bandFont, .foregroundColor: NSColor.systemRed]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
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
