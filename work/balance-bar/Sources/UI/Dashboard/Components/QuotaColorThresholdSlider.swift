import AppKit
import OSLog

enum QuotaThresholdSliderMath {
    static let logicalTicks = Array(stride(from: 0, through: 100, by: 5))
    /// The scale mirrors the same 5% grid used by snapping and haptics so the
    /// dots are dense enough to be useful across a wide settings window.
    static let displayTicks = logicalTicks
    /// AppKit supplies the small set of native scale ticks underneath the
    /// denser contrast overlay. Keeping these independent avoids a continuous
    /// stock slider bar under the coloured quota track.
    static let nativeScaleTicks = [0, 25, 50, 75, 100]

    static func snapped(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return min(100, max(0, Int((value / 5).rounded()) * 5))
    }
    static func shouldEmitAlignmentHaptic(lastSnappedValue: Int?, newValue: Int) -> Bool {
        lastSnappedValue != newValue
    }
    static func crossedTicks(from oldValue: Int, to newValue: Int) -> [Int] {
        guard oldValue != newValue else { return [] }
        let low = min(oldValue, newValue), high = max(oldValue, newValue)
        return logicalTicks.filter { $0 > low && $0 <= high }
    }

}

/// Each boundary owns one native slider, preserving normal Force Click and
/// trackpad gesture handling with its untouched AppKit-provided cell.
private final class ThresholdInteractionSlider: NSSlider {
    let boundaryColor: QuotaProgressColor
    var prepareForNativeTracking: ((NSEvent) -> Void)?
    var onTrackingBegan: (() -> Void)?
    var onTrackingChanged: ((Double) -> Void)?
    var onTrackingEnded: (() -> Void)?
    var onKeyboardStep: ((Int) -> Void)?

    init(boundaryColor: QuotaProgressColor) {
        self.boundaryColor = boundaryColor
        super.init(frame: .zero)
        minValue = 0
        maxValue = 100
        doubleValue = 0
        sliderType = .linear
        controlSize = .regular
        isContinuous = true
        numberOfTickMarks = 0
        trackFillColor = .clear
        target = self
        action = #selector(valueChanged(_:))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func valueChanged(_ sender: NSSlider) {
        Self.logger.debug("quota native slider valueChanged color=\(self.boundaryColor.rawValue, privacy: .public) raw=\(sender.doubleValue, privacy: .public)")
        onTrackingChanged?(sender.doubleValue)
    }

    override func mouseDown(with event: NSEvent) {
        prepareForNativeTracking?(event)
        onTrackingBegan?()
        Self.logger.debug("quota native slider mouseDown type=\(event.type.rawValue, privacy: .public) pressure=\(event.pressure, privacy: .public)")
        super.mouseDown(with: event)
        Self.logger.debug("quota native slider mouseDown completed value=\(self.doubleValue, privacy: .public)")
        onTrackingEnded?()
    }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }
        switch characters {
        case "\u{F702}", "\u{F700}": onKeyboardStep?(-5)
        case "\u{F703}", "\u{F701}": onKeyboardStep?(5)
        default: super.keyDown(with: event)
        }
    }

    private static let logger = Logger(subsystem: "com.huanmeng06.BalanceBar", category: "QuotaThresholdSlider")
}

/// The semantic colour track. It is deliberately a single continuous source
/// beneath all persistent native sliders. Cover slices may mask stock bar
/// material around the knobs, but they must not remove these colour pixels.
private final class QuotaThresholdTrackView: NSView {
    weak var owner: QuotaColorThresholdSlider?

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawTrack(in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A physical slice of the visual cover. During native tracking, the sibling
/// slices leave a real view gap around the active stock knob instead of
/// relying on a transparent hole that must be erased from a full-size backing
/// store.
private final class QuotaThresholdTrackCoverSliceView: NSView {
    weak var owner: QuotaColorThresholdSlider?

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawTrackCoverSlice(in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class QuotaNativeScaleSlider: NSSlider {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        minValue = 0
        maxValue = 100
        doubleValue = 0
        sliderType = .linear
        controlSize = .regular
        isContinuous = true
        autoresizingMask = []
        numberOfTickMarks = QuotaThresholdSliderMath.nativeScaleTicks.count
        tickMarkPosition = .below
        allowsTickMarkValuesOnly = false
        target = nil
        action = nil
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Clips one stock scale slider down to the exact rect returned by AppKit for
/// its single native tick. Each clip is independent so the other stock
/// slider content cannot form one continuous scale bar.
private final class QuotaNativeTickClipView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        autoresizesSubviews = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Adds the higher-contrast point presentation requested for the scale while
/// the stock AppKit sliders continue to provide the underlying tick positions.
private final class QuotaScaleTickOverlay: NSView {
    static let dotDiameter: CGFloat = 2
    private(set) var tickCenters: [CGFloat] = [] {
        didSet { needsDisplay = true }
    }

    var usesSecondaryLabelColor: Bool { tickColor.isEqual(NSColor.secondaryLabelColor) }

    private let tickColor = NSColor.secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func setTickCenters(_ centers: [CGFloat]) {
        tickCenters = centers
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = Self.dotDiameter
        let y = bounds.midY - diameter / 2
        tickColor.setFill()
        for center in tickCenters {
            let dot = NSRect(x: center - diameter / 2, y: y, width: diameter, height: diameter)
            guard dot.intersects(dirtyRect) else { continue }
            NSBezierPath(roundedRect: dot, xRadius: 0.5, yRadius: 0.5).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Owns only the scale underneath the quota slider. Keeping this separate from
/// the semantic track prevents native tick rendering from changing the
/// colour-track drawing or native slider event path.
final class DashboardSliderScaleView: NSView {
    private let nativeSliders = QuotaThresholdSliderMath.nativeScaleTicks.map { _ in
        QuotaNativeScaleSlider(frame: .zero)
    }
    private let nativeTickClipViews = QuotaThresholdSliderMath.nativeScaleTicks.map { _ in
        QuotaNativeTickClipView(frame: .zero)
    }
    private let tickOverlay = QuotaScaleTickOverlay(frame: .zero)
    var positionForValue: ((Int) -> CGFloat?)?

    var displayTicks: [Int] { QuotaThresholdSliderMath.displayTicks }
    var resolvedTickCenters: [Int: CGFloat] {
        Dictionary(uniqueKeysWithValues: displayTicks.compactMap { value in
            positionForValue?(value).map { (value, $0) }
        })
    }
    var nativeTickMarkCount: Int { nativeSliders.first?.numberOfTickMarks ?? 0 }
    var nativeTickRendererCount: Int { nativeSliders.count }
    var nativeTickMarkPosition: NSSlider.TickMarkPosition {
        nativeSliders.first?.tickMarkPosition ?? .below
    }
    var allowsNativeTickMarkValuesOnly: Bool {
        nativeSliders.first?.allowsTickMarkValuesOnly ?? false
    }
    var usesNativeTickMarks: Bool {
        nativeSliders.count == QuotaThresholdSliderMath.nativeScaleTicks.count && nativeSliders.allSatisfy { slider in
            slider.numberOfTickMarks == QuotaThresholdSliderMath.nativeScaleTicks.count &&
                slider.cell.map { type(of: $0) == NSSliderCell.self } ?? false
        }
    }
    var allRenderersUseStockCells: Bool { usesNativeTickMarks }
    var textLabelCount: Int { subviews.compactMap { $0 as? NSTextField }.count }
    var nativeTickCenters: [Int: CGFloat] {
        Dictionary(uniqueKeysWithValues: nativeSliders.enumerated().map { index, slider in
            let tickRect = slider.rectOfTickMark(at: index)
            let center = slider.convert(NSPoint(x: tickRect.midX, y: tickRect.midY), to: self)
            let value = QuotaThresholdSliderMath.nativeScaleTicks[index]
            return (value, center.x)
        })
    }
    var nativeTickBandsInScaleView: [NSRect] {
        nativeSliders.enumerated().map { index, slider in
            let tickRect = slider.rectOfTickMark(at: index)
            return slider.convert(tickRect, to: self)
        }
    }
    var nativeTickClipFrames: [NSRect] { nativeTickClipViews.map(\.frame) }
    var highContrastTickCount: Int { tickOverlay.tickCenters.count }
    var highContrastTickCenters: [CGFloat] { tickOverlay.tickCenters }
    var usesSecondaryLabelColorForHighContrastTicks: Bool { tickOverlay.usesSecondaryLabelColor }
    var highContrastTickDiameter: CGFloat { QuotaScaleTickOverlay.dotDiameter }
    var nativeTickMarksAreFullyVisible: Bool {
        guard nativeSliders.count == QuotaThresholdSliderMath.nativeScaleTicks.count else { return false }
        return zip(nativeSliders, nativeTickClipViews).enumerated().allSatisfy { index, pair in
            let (slider, clipView) = pair
            let tickRect = slider.rectOfTickMark(at: index)
            let rectInClip = slider.convert(tickRect, to: clipView)
            let intersection = rectInClip.intersection(clipView.bounds)
            return intersection.width > 0 && intersection.height > 0
        }
    }
    var nativeTickClipsAreDiscrete: Bool {
        let frames = nativeTickClipFrames
        return frames.count == QuotaThresholdSliderMath.nativeScaleTicks.count && zip(frames, frames.dropFirst()).allSatisfy {
            !$0.intersects($1)
        }
    }
    var requiredHeight: CGFloat {
        max(nativeSliders.first?.rectOfTickMark(at: 0).height ?? 0, QuotaScaleTickOverlay.dotDiameter)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        autoresizesSubviews = false
        for (slider, clipView) in zip(nativeSliders, nativeTickClipViews) {
            clipView.addSubview(slider)
            addSubview(clipView)
        }
        addSubview(tickOverlay)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard !bounds.isEmpty else { return }

        let lowerEndpoint = positionForValue?(0) ?? bounds.minX
        let upperEndpoint = positionForValue?(100) ?? bounds.maxX
        let sliderWidth = max(1, abs(upperEndpoint - lowerEndpoint))
        let sliderOriginX = min(lowerEndpoint, upperEndpoint)
        let sliderHeight = max(28, nativeSliders.first?.intrinsicContentSize.height ?? 28)
        tickOverlay.frame = bounds

        for (index, pair) in zip(nativeSliders, nativeTickClipViews).enumerated() {
            let (slider, clipView) = pair
            clipView.frame = bounds
            slider.frame = NSRect(x: 0, y: 0, width: sliderWidth, height: sliderHeight)
            clipView.layoutSubtreeIfNeeded()
            let tickRect = slider.rectOfTickMark(at: index)
            let tickCenterX = sliderOriginX + tickRect.midX
            clipView.frame = NSRect(
                x: tickCenterX - tickRect.width / 2,
                y: bounds.minY,
                width: tickRect.width,
                height: min(tickRect.height, bounds.height)
            )
            slider.frame = NSRect(
                x: sliderOriginX - clipView.frame.minX,
                y: -tickRect.minY,
                width: sliderWidth,
                height: sliderHeight
            )
        }
        tickOverlay.setTickCenters(displayTicks.compactMap { positionForValue?($0) })
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A full-width display-only native slider used while the corresponding
/// interaction slider is idle. AppKit owns the complete knob presentation;
/// its dedicated cell suppresses the bar while the semantic cover stays
/// continuous underneath it.
private final class QuotaPassiveKnobCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        // The parent draws the semantic colour track. The passive slider only
        // contributes AppKit's native idle knob.
    }
}

private final class QuotaPassiveKnobSlider: NSSlider {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = QuotaPassiveKnobCell()
        minValue = 0
        maxValue = 100
        doubleValue = 0
        sliderType = .linear
        controlSize = .regular
        isContinuous = true
        numberOfTickMarks = 0
        target = nil
        action = nil
        focusRingType = .none
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct QuotaTrackCoverGeometry: Equatable {
    let leftFrame: NSRect
    let rightFrame: NSRect
    let hole: NSRect?
    let hidesRightSlice: Bool

    static func make(bounds: NSRect, hole: NSRect?) -> Self {
        guard let hole else {
            return Self(
                leftFrame: bounds,
                rightFrame: .zero,
                hole: nil,
                hidesRightSlice: true
            )
        }

        let clippedHole = hole.intersection(bounds)
        guard !clippedHole.isNull else { return make(bounds: bounds, hole: nil) }
        let leftFrame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(0, clippedHole.minX - bounds.minX),
            height: bounds.height
        )
        let rightFrame = NSRect(
            x: clippedHole.maxX,
            y: bounds.minY,
            width: max(0, bounds.maxX - clippedHole.maxX),
            height: bounds.height
        )
        return Self(
            leftFrame: leftFrame,
            rightFrame: rightFrame,
            hole: clippedHole,
            hidesRightSlice: false
        )
    }
}

enum QuotaThresholdTrackGeometry {
    static func customColorTrackRect(from nativeBarRect: NSRect) -> NSRect {
        nativeBarRect
    }
}

final class QuotaColorThresholdSlider: NSControl {
    struct DebugThumbState: Equatable {
        let color: QuotaProgressColor
        let minimumValue: Double
        let maximumValue: Double
        let value: Double
        let knobMidX: CGFloat
        let knobMidY: CGFloat
    }

    struct DebugPassiveKnobState: Equatable {
        let color: QuotaProgressColor
        let frame: NSRect
        let isHidden: Bool
        let knobMidX: CGFloat
    }

    /// A render-observable portion of the coloured track.  Keeping this
    /// geometry available to tests lets them verify the first snapped frame,
    /// rather than only checking the final persisted configuration.
    struct DebugColorTrackSegment: Equatable {
        let color: QuotaProgressColor
        let frame: NSRect
    }

    private var configurationStorage: QuotaProgressColorConfiguration
    private var boundarySliders: [QuotaProgressColor: ThresholdInteractionSlider] = [:]
    private var passiveKnobViews: [QuotaProgressColor: QuotaPassiveKnobSlider] = [:]
    private let trackView = QuotaThresholdTrackView()
    private let leftTrackCover = QuotaThresholdTrackCoverSliceView()
    private let rightTrackCover = QuotaThresholdTrackCoverSliceView()
    private let scaleView = DashboardSliderScaleView()
    private var activeBoundaryColor: QuotaProgressColor?
    private var activePopoverColor: QuotaProgressColor?
    private var trackingColor: QuotaProgressColor?
    private var focusedColor: QuotaProgressColor?
    private var lastSnappedValues: [QuotaProgressColor: Int] = [:]
    private var trackingChangeIndex = 0
    private let geometryProbe: NSSlider = {
        let slider = NSSlider()
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = 0
        slider.sliderType = .linear
        slider.controlSize = .regular
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.trackFillColor = .clear
        return slider
    }()
    private let popover = DashboardTextTooltip.makePopover()
    private let popoverLabel = NSTextField(labelWithString: "")
    private var hoverWorkItem: DispatchWorkItem?
    private var trackingAreaReference: NSTrackingArea?
    private var trackCoverGeometry = QuotaTrackCoverGeometry.make(bounds: .zero, hole: nil)
    // Percentage hover/drag labels are part of the Issue contract.  They use
    // the existing Dashboard tooltip presentation and do not alter native
    // slider tracking.
    private let popoverEnabled = false

    var onChange: ((QuotaProgressColorConfiguration) -> Void)?
    var configuration: QuotaProgressColorConfiguration {
        get { configurationStorage }
        set { applyExternalConfiguration(newValue.normalized()) }
    }
    /// Logical thumb count: one boundary between each adjacent enabled colour.
    var thumbCount: Int { activeBoundaries.count }
    var thumbIdentitySet: Set<ObjectIdentifier> { Set(boundarySliders.values.map(ObjectIdentifier.init)) }
    var nativeThumbSliders: [NSSlider] { activeBoundaries.compactMap { slider(for: $0.0) } }
    var nativeSliderBoundaryColors: [QuotaProgressColor] { activeBoundaries.compactMap { slider(for: $0.0)?.boundaryColor } }
    var nativeSliderIdentityByColor: [QuotaProgressColor: ObjectIdentifier] {
        Dictionary(uniqueKeysWithValues: boundarySliders.map { ($0.key, ObjectIdentifier($0.value)) })
    }
    var nativeSliderCellIdentityByColor: [QuotaProgressColor: ObjectIdentifier] {
        Dictionary(uniqueKeysWithValues: boundarySliders.compactMap { color, slider in
            slider.cell.map { (color, ObjectIdentifier($0)) }
        })
    }
    var passiveKnobCount: Int { passiveKnobViews.count }
    var passiveKnobIdentityByColor: [QuotaProgressColor: ObjectIdentifier] {
        Dictionary(uniqueKeysWithValues: passiveKnobViews.map { ($0.key, ObjectIdentifier($0.value)) })
    }
    var usesBarSuppressedPassiveKnobCells: Bool {
        passiveKnobViews.values.allSatisfy { $0.cell is QuotaPassiveKnobCell }
    }
    var debugScaleTicks: [Int] { scaleView.displayTicks }
    var debugScaleTickCenters: [Int: CGFloat] { scaleView.resolvedTickCenters }
    var debugScaleGeometryTickCenters: [Int: CGFloat] {
        Dictionary(uniqueKeysWithValues: scaleView.displayTicks.compactMap { value in
            stableKnobCenter(for: value).map { (value, $0) }
        })
    }
    var debugScaleNativeTickMarkCount: Int { scaleView.nativeTickMarkCount }
    var debugScaleNativeTickRendererCount: Int { scaleView.nativeTickRendererCount }
    var debugScaleNativeTickMarkPosition: NSSlider.TickMarkPosition { scaleView.nativeTickMarkPosition }
    var debugScaleAllowsNativeTickMarkValuesOnly: Bool { scaleView.allowsNativeTickMarkValuesOnly }
    var debugScaleUsesNativeTickMarks: Bool { scaleView.usesNativeTickMarks }
    var debugScaleAllRenderersUseStockCells: Bool { scaleView.allRenderersUseStockCells }
    var debugScaleTextLabelCount: Int { scaleView.textLabelCount }
    var debugScaleNativeTickCenters: [Int: CGFloat] { scaleView.nativeTickCenters }
    var debugScaleNativeTickBands: [NSRect] { scaleView.nativeTickBandsInScaleView }
    var debugScaleNativeTickClipFrames: [NSRect] { scaleView.nativeTickClipFrames }
    var debugScaleNativeTickMarksAreFullyVisible: Bool { scaleView.nativeTickMarksAreFullyVisible }
    var debugScaleNativeTickClipsAreDiscrete: Bool { scaleView.nativeTickClipsAreDiscrete }
    var debugScaleHighContrastTickCount: Int { scaleView.highContrastTickCount }
    var debugScaleHighContrastTickCenters: [CGFloat] { scaleView.highContrastTickCenters }
    var debugScaleUsesSecondaryLabelColorForHighContrastTicks: Bool {
        scaleView.usesSecondaryLabelColorForHighContrastTicks
    }
    var debugScaleHighContrastTickDiameter: CGFloat { scaleView.highContrastTickDiameter }
    var debugScaleRequiredHeight: CGFloat { scaleView.requiredHeight }
    var debugScaleFrame: NSRect { scaleView.frame }
    var debugSliderFrame: NSRect { sliderFrame }
    var debugScaleDoesNotHitTest: Bool {
        scaleView.hitTest(NSPoint(x: scaleView.bounds.midX, y: scaleView.bounds.midY)) == nil
    }
    var debugNativeSliderAlphaByColor: [QuotaProgressColor: CGFloat] {
        Dictionary(uniqueKeysWithValues: boundarySliders.map { ($0.key, $0.value.alphaValue) })
    }
    var usesNSSliderThumbs: Bool { nativeThumbSliders.allSatisfy { $0.superview === self } }
    var usesCustomSliderCell: Bool { nativeThumbSliders.contains { !($0.cell is NSSliderCell) } }
    /// All custom colour sources, including the continuous semantic track and
    /// the cover slices used to mask native bar material.
    var debugColorTrackSourceFrames: [NSRect] {
        [trackView.frame, leftTrackCover.frame] + (rightTrackCover.isHidden ? [] : [rightTrackCover.frame])
    }
    var debugNativeBarsAreCovered: Bool { leftTrackCover.frame == bounds && rightTrackCover.isHidden }
    var debugCurrentNativeKnobGap: NSRect? { trackCoverGeometry.hole }
    var debugNativeTrackRect: NSRect { nativeTrackRect }
    var debugCustomColorTrackRect: NSRect {
        QuotaThresholdTrackGeometry.customColorTrackRect(from: nativeTrackRect)
    }
    var debugRenderedColorBoundaryCenters: [QuotaProgressColor: CGFloat] {
        Dictionary(uniqueKeysWithValues: activeBoundaries.compactMap { color, _ in
            stableKnobCenter(for: color).map { (color, $0) }
        })
    }
    var debugRenderedColorTrackSegments: [DebugColorTrackSegment] {
        renderedColorTrackSegments(in: self)
    }
    var debugHasContinuousColorTrackUnderNativeKnob: Bool {
        guard let gap = debugCurrentNativeKnobGap else { return false }
        return renderedColorTrackSegments(in: self).contains { $0.frame.intersects(gap) }
    }
    var debugThumbStates: [DebugThumbState] {
        layoutSubtreeIfNeeded()
        return activeBoundaries.compactMap { color, value in
            guard let knob = knobRect(for: color), let cell = cell(for: color) else { return nil }
            return DebugThumbState(
                color: color,
                minimumValue: cell.minValue,
                maximumValue: cell.maxValue,
                value: Double(value),
                knobMidX: knob.midX,
                knobMidY: knob.midY
            )
        }
    }
    var debugPassiveKnobStates: [DebugPassiveKnobState] {
        layoutSubtreeIfNeeded()
        return activeBoundaries.compactMap { color, _ in
            guard let passiveKnob = passiveKnobViews[color],
                  let cell = passiveKnob.cell as? NSSliderCell else { return nil }
            let knob = passiveKnob.convert(cell.knobRect(flipped: passiveKnob.isFlipped), to: self)
            return DebugPassiveKnobState(
                color: color,
                frame: passiveKnob.frame,
                isHidden: passiveKnob.isHidden,
                knobMidX: knob.midX
            )
        }
    }

    init(configuration: QuotaProgressColorConfiguration) {
        configurationStorage = configuration.normalized()
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("quotaProgressThresholdSlider")
        setAccessibilityRole(.group)

        trackView.owner = self
        trackView.wantsLayer = false
        addSubview(trackView)
        configureTrackCoverSlice(leftTrackCover)
        configureTrackCoverSlice(rightTrackCover)
        reconcileBoundarySliders()
        addSubview(leftTrackCover)
        addSubview(rightTrackCover)
        reconcilePassiveKnobViews()
        scaleView.positionForValue = { [weak self] value in
            guard let self else { return nil }
            guard let center = self.stableKnobCenter(for: value) else { return nil }
            return center - self.scaleView.frame.minX + self.scaleView.bounds.minX
        }
        scaleView.setAccessibilityElement(false)
        addSubview(scaleView)

        let contentView = NSView(frame: .zero)
        DashboardTextTooltip.configure(popoverLabel, alignment: .center)
        popoverLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(popoverLabel)
        NSLayoutConstraint.activate([
            popoverLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 7),
            popoverLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
            popoverLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            popoverLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5)
        ])
        let controller = NSViewController()
        controller.view = contentView
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        updateTrackCoverGeometry()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        hoverWorkItem?.cancel()
        popover.close()
    }

    func teardown() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        trackingColor = nil
        synchronizePassiveKnobVisibility()
        dismissPopover()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
            self.trackingAreaReference = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { teardown() }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 300, height: Self.sliderRegionHeight + scaleView.requiredHeight)
    }

    private static let sliderRegionHeight: CGFloat = 34

    private var sliderRegionFrame: NSRect {
        let height = min(Self.sliderRegionHeight, max(0, bounds.height))
        return NSRect(
            x: bounds.minX,
            y: bounds.maxY - height,
            width: bounds.width,
            height: height
        )
    }
    private var sliderFrame: NSRect {
        let region = sliderRegionFrame
        return NSRect(x: region.minX, y: region.midY - 14, width: region.width, height: 28)
    }
    private var scaleFrame: NSRect {
        let scaleHeight = scaleView.requiredHeight
        return NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: min(scaleHeight, max(0, bounds.height))
        )
    }
    private var nativeTrackRect: NSRect {
        guard let slider = boundarySliders.values.first,
              let cell = slider.cell as? NSSliderCell else {
            return sliderFrame
        }
        return slider.convert(cell.barRect(flipped: slider.isFlipped), to: self)
    }
    private var activeBoundaries: [(QuotaProgressColor, Int)] {
        configurationStorage.enabledColorsInOrder.dropLast().compactMap { color in
            configurationStorage.boundary(after: color).map { (color, $0) }
        }
    }

    private func slider(for color: QuotaProgressColor) -> ThresholdInteractionSlider? {
        boundarySliders[color]
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        guard popoverEnabled else {
            trackingAreaReference = nil
            return
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func layout() {
        super.layout()
        trackView.frame = bounds
        scaleView.frame = scaleFrame
        for slider in boundarySliders.values { slider.frame = sliderFrame }
        synchronizeBoundarySliders()
        layoutPassiveKnobViews()
        updateTrackCoverGeometry()
        if let activePopoverColor { updatePopoverAnchor(for: activePopoverColor) }
        invalidateVisuals()
    }

    private func makeBoundarySlider(for color: QuotaProgressColor) -> ThresholdInteractionSlider {
        let slider = ThresholdInteractionSlider(boundaryColor: color)
        slider.prepareForNativeTracking = { [weak self] event in
            self?.prepareBoundaryForNativeTracking(color: color, event: event)
        }
        slider.onTrackingBegan = { [weak self] in self?.beginTracking(color: color) }
        slider.onTrackingChanged = { [weak self] value in self?.applyTrackedBoundaryChange(color: color, value: value) }
        slider.onTrackingEnded = { [weak self] in self?.finishTracking(color: color) }
        slider.onKeyboardStep = { [weak self] delta in self?.stepBoundary(color: color, by: delta) }
        if leftTrackCover.superview != nil {
            addSubview(slider, positioned: .below, relativeTo: leftTrackCover)
        } else {
            addSubview(slider)
        }
        return slider
    }

    private func reconcileBoundarySliders() {
        let orderedColors = activeBoundaries.map(\.0)
        let wanted = Set(orderedColors)
        for color in Array(boundarySliders.keys) where !wanted.contains(color) {
            boundarySliders[color]?.removeFromSuperview()
            boundarySliders.removeValue(forKey: color)
            lastSnappedValues.removeValue(forKey: color)
        }
        for color in orderedColors where boundarySliders[color] == nil {
            boundarySliders[color] = makeBoundarySlider(for: color)
        }
        if activeBoundaryColor == nil || !wanted.contains(activeBoundaryColor!) {
            activeBoundaryColor = activeBoundaries.first?.0
        }
        synchronizeBoundarySliders()
        needsLayout = true
        needsDisplay = true
    }

    private func reconcilePassiveKnobViews() {
        let orderedColors = activeBoundaries.map(\.0)
        let wanted = Set(orderedColors)
        for color in Array(passiveKnobViews.keys) where !wanted.contains(color) {
            passiveKnobViews[color]?.removeFromSuperview()
            passiveKnobViews.removeValue(forKey: color)
        }
        for color in orderedColors where passiveKnobViews[color] == nil {
            let passiveKnob = QuotaPassiveKnobSlider(frame: .zero)
            passiveKnobViews[color] = passiveKnob
            addSubview(passiveKnob, positioned: .above, relativeTo: rightTrackCover)
        }
        synchronizePassiveKnobVisibility()
        synchronizeInteractionSliderVisibility()
        needsLayout = true
        needsDisplay = true
    }

    private func configureTrackCoverSlice(_ slice: QuotaThresholdTrackCoverSliceView) {
        slice.owner = self
        slice.wantsLayer = true
        slice.layer?.backgroundColor = NSColor.clear.cgColor
        slice.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    private func synchronizeBoundarySliders() {
        for (color, value) in activeBoundaries {
            guard let slider = slider(for: color) else { continue }
            slider.minValue = 0
            slider.maxValue = 100
            slider.doubleValue = Double(value)
            lastSnappedValues[color] = value
            updateInteractionAccessibility(for: color, value: value)
        }
        synchronizeInteractionSliderVisibility()
        guard let activeBoundaryColor,
              let value = configurationStorage.boundary(after: activeBoundaryColor) else { return }
        if let slider = slider(for: activeBoundaryColor), abs(slider.doubleValue - Double(value)) > 0.01 {
            slider.doubleValue = Double(value)
        }
        updateInteractionAccessibility(for: activeBoundaryColor, value: value)
    }

    private func applyExternalConfiguration(_ value: QuotaProgressColorConfiguration) {
        guard value != configurationStorage else { return }
        let oldColors = configurationStorage.enabledColors
        configurationStorage = value
        if oldColors != value.enabledColors {
            trackingColor = nil
            if let focusedColor, !value.enabledColors.contains(focusedColor) { self.focusedColor = nil }
            dismissPopover()
            reconcileBoundarySliders()
            reconcilePassiveKnobViews()
        } else {
            synchronizeBoundarySliders()
        }
        layoutPassiveKnobViews()
        updateTrackCoverGeometry()
        needsDisplay = true
        needsLayout = true
        invalidateVisuals()
    }

    private func prepareBoundaryForNativeTracking(color: QuotaProgressColor, event: NSEvent) {
        guard let value = configurationStorage.boundary(after: color),
              let slider = slider(for: color) else { return }
        activeBoundaryColor = color
        focusedColor = color
        if abs(slider.doubleValue - Double(value)) > 0.01 { slider.doubleValue = Double(value) }
        updateInteractionAccessibility(for: color, value: value)
    }

    private func beginTracking(color: QuotaProgressColor) {
        activeBoundaryColor = color
        focusedColor = color
        trackingColor = color
        trackingChangeIndex = 0
        hoverWorkItem?.cancel()
        synchronizeInteractionSliderVisibility()
        passiveKnobViews[color]?.isHidden = true
        updateTrackCoverGeometry()
        invalidateVisuals()
        guard popoverEnabled else { return }
        activePopoverColor = color
        presentPopover(for: color)
    }

    private func applyTrackedBoundaryChange(color: QuotaProgressColor, value: Double) {
        let old = configurationStorage.boundary(after: color) ?? 0
        let snappedValue = QuotaThresholdSliderMath.snapped(value)
        let updated = configurationStorage.settingBoundary(after: color, to: snappedValue)
        guard let actual = updated.boundary(after: color) else { return }
        if trackingColor == color { trackingChangeIndex += 1 }
        slider(for: color)?.doubleValue = Double(actual)
        configurationStorage = updated
        updateInteractionAccessibility(for: color, value: actual)
        layoutPassiveKnobViews()
        let nativeKnobMidX = knobRect(for: color)?.midX ?? -1
        let semanticBoundaryMidX = stableKnobCenter(for: actual) ?? -1
        Self.logger.debug(
            "quota tracking change #\(self.trackingChangeIndex, privacy: .public) color=\(color.rawValue, privacy: .public) old=\(old, privacy: .public) raw=\(value, privacy: .public) snapped=\(snappedValue, privacy: .public) actual=\(actual, privacy: .public) nativeX=\(nativeKnobMidX, privacy: .public) semanticX=\(semanticBoundaryMidX, privacy: .public)"
        )
        if trackingColor == color { updatePopoverAnchor(for: color, value: actual) }
        guard actual != old else { return }
        updateTrackCoverGeometry()
        invalidateVisuals()
        commitTrackingVisuals()
        if QuotaThresholdSliderMath.shouldEmitAlignmentHaptic(lastSnappedValue: lastSnappedValues[color], newValue: actual) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastSnappedValues[color] = actual
        onChange?(updated)
        sendAction(action, to: target)
        needsDisplay = true
    }

    private func stepBoundary(color: QuotaProgressColor, by delta: Int) {
        guard let value = configurationStorage.boundary(after: color) else { return }
        activeBoundaryColor = color
        applyTrackedBoundaryChange(color: color, value: Double(value + delta))
    }

    private func finishTracking(color: QuotaProgressColor) {
        guard trackingColor == color else { return }
        defer {
            trackingColor = nil
            synchronizeInteractionSliderVisibility()
            layoutPassiveKnobViews()
            updateTrackCoverGeometry()
            passiveKnobViews[color]?.isHidden = false
            invalidateVisuals()
            commitTrackingVisuals()
        }
        guard activePopoverColor == color else { dismissPopover(); return }
        if let point = currentMousePoint(), let knob = knobRect(for: color), knob.insetBy(dx: -5, dy: -5).contains(point) {
            updatePopoverAnchor(for: color)
        } else {
            dismissPopover()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard popoverEnabled else { return }
        if let trackingColor {
            updatePopoverAnchor(for: trackingColor)
            return
        }
        hoverWorkItem?.cancel()
        let point = convert(event.locationInWindow, from: nil)
        let color = hitThumb(at: point)
        activePopoverColor = color
        if let color {
            let item = DispatchWorkItem { [weak self] in self?.presentPopover(for: color) }
            hoverWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        } else {
            dismissPopover()
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard popoverEnabled else { return }
        guard trackingColor == nil else { return }
        hoverWorkItem?.cancel()
        dismissPopover()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point),
              let color = hitThumb(at: point) ?? nearestBoundary(to: point.x),
              let slider = slider(for: color) else { return nil }
        // Return the exact persistent child so AppKit dispatches the original
        // NSEvent through that stock NSSlider's native tracking path. The
        // parent intentionally does not forward mouseDown itself.
        return slider
    }

    func applyRawThumbValueForTesting(_ value: Double, after color: QuotaProgressColor) {
        activeBoundaryColor = color
        applyTrackedBoundaryChange(color: color, value: value)
    }

    func setNativeSliderPresentationValueForTesting(_ value: Double, after color: QuotaProgressColor) {
        slider(for: color)?.doubleValue = value
    }

    func setTrackingColorForTesting(_ color: QuotaProgressColor?) {
        if let color, let value = configurationStorage.boundary(after: color) {
            activeBoundaryColor = color
            slider(for: color)?.doubleValue = Double(value)
            trackingColor = color
        } else {
            trackingColor = nil
        }
        synchronizePassiveKnobVisibility()
        synchronizeInteractionSliderVisibility()
        layoutPassiveKnobViews()
        updateTrackCoverGeometry()
    }

    private func cell(for color: QuotaProgressColor) -> NSSliderCell? {
        slider(for: color)?.cell as? NSSliderCell
    }

    private func knobRect(for color: QuotaProgressColor) -> NSRect? {
        guard let cell = cell(for: color) else { return nil }
        guard let slider = slider(for: color) else { return nil }
        let knob = cell.knobRect(flipped: slider.isFlipped)
        return slider.convert(knob, to: self)
    }

    private func stableKnobCenter(for color: QuotaProgressColor) -> CGFloat? {
        guard let value = configurationStorage.boundary(after: color) else { return nil }
        return stableKnobCenter(for: value)
    }

    private func stableKnobCenter(for value: Int) -> CGFloat? {
        geometryProbe.frame = sliderFrame
        // The probe is intentionally not attached to a window. Force the
        // cell to refresh even when the requested value equals its initial
        // value, otherwise AppKit can report a zero-sized 0% knob on the
        // first geometry query.
        geometryProbe.doubleValue = value == 0 ? 100 : 0
        geometryProbe.doubleValue = Double(value)
        geometryProbe.layoutSubtreeIfNeeded()
        guard let cell = geometryProbe.cell as? NSSliderCell else { return nil }
        return geometryProbe.frame.minX + cell.knobRect(flipped: geometryProbe.isFlipped).midX
    }

    private func stableKnobCenter(for value: Int, in view: NSView) -> CGFloat? {
        guard let center = stableKnobCenter(for: value) else { return nil }
        return view.convert(NSPoint(x: center, y: bounds.midY), from: self).x
    }

    private func synchronizePassiveKnobVisibility() {
        for (color, passiveKnob) in passiveKnobViews {
            passiveKnob.isHidden = trackingColor == color
        }
    }

    private func synchronizeInteractionSliderVisibility() {
        for (color, slider) in boundarySliders {
            slider.alphaValue = trackingColor == color ? 1 : 0
        }
    }

    private func layoutPassiveKnobViews() {
        for (color, value) in activeBoundaries {
            guard let passiveKnob = passiveKnobViews[color] else { continue }
            passiveKnob.frame = sliderFrame
            passiveKnob.minValue = 0
            passiveKnob.maxValue = 100
            passiveKnob.doubleValue = Double(value)
            passiveKnob.needsDisplay = true
        }
        synchronizePassiveKnobVisibility()
        synchronizeInteractionSliderVisibility()
    }

    private func hitThumb(at point: NSPoint) -> QuotaProgressColor? {
        activeBoundaries.compactMap { color, _ -> (QuotaProgressColor, CGFloat)? in
            guard let rect = knobRect(for: color), rect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
            return (color, abs(rect.midX - point.x))
        }.min(by: { $0.1 < $1.1 })?.0
    }

    private func nearestBoundary(to x: CGFloat) -> QuotaProgressColor? {
        activeBoundaries.min { lhs, rhs in
            abs((knobRect(for: lhs.0)?.midX ?? 0) - x) < abs((knobRect(for: rhs.0)?.midX ?? 0) - x)
        }?.0
    }

    private func updateInteractionAccessibility(for color: QuotaProgressColor, value: Int) {
        let label: String
        switch color {
        case .red: label = tr(.keyDashboardMenuPageColorRed)
        case .orange: label = tr(.keyDashboardMenuPageColorOrange)
        case .yellow: label = tr(.keyDashboardMenuPageColorYellow)
        case .green: label = tr(.keyDashboardMenuPageColorGreen)
        }
        slider(for: color)?.setAccessibilityLabel(label)
        slider(for: color)?.setAccessibilityValue(value)
        slider(for: color)?.setAccessibilityValueDescription("\(value)%")
    }

    private func presentPopover(for color: QuotaProgressColor) {
        activePopoverColor = color
        updatePopoverAnchor(for: color)
        if !popover.isShown, let rect = knobRect(for: color) {
            popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        }
    }

    private func updatePopoverAnchor(for color: QuotaProgressColor, value: Int? = nil) {
        guard let rect = knobRect(for: color) else { dismissPopover(); return }
        popoverLabel.stringValue = "\(value ?? configurationStorage.boundary(after: color) ?? 0)%"
        let labelSize = popoverLabel.fittingSize
        popover.contentSize = NSSize(width: ceil(labelSize.width) + 14, height: ceil(labelSize.height) + 10)
        if popover.isShown { popover.positioningRect = rect }
    }

    private func dismissPopover() {
        activePopoverColor = nil
        popover.close()
    }

    private func currentMousePoint() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    private func invalidateVisuals() {
        // The semantic track is the single source of truth for colour
        // boundaries.  Mark it dirty whenever a snapped value, layout, or
        // configuration changes so the next commit reflects the new native
        // knob centres immediately.
        trackView.needsDisplay = true
        leftTrackCover.needsDisplay = true
        rightTrackCover.needsDisplay = true
        for slider in boundarySliders.values { slider.needsDisplay = true }
    }

    /// Commit the custom cover slices after a snapped value changes.  Native
    /// slider tracking remains entirely under AppKit's stock control path.
    private func commitTrackingVisuals() {
        trackView.displayIfNeeded()
        leftTrackCover.displayIfNeeded()
        rightTrackCover.displayIfNeeded()
    }

    fileprivate func drawTrack(in trackView: QuotaThresholdTrackView) {
        drawColorTrack(in: trackView)
    }

    fileprivate func drawTrackCoverSlice(in trackCover: QuotaThresholdTrackCoverSliceView) {
        drawColorTrack(in: trackCover)
    }

    private func drawColorTrack(in drawingView: NSView) {
        let track = drawingView.convert(nativeTrackRect, from: self)
        let colorTrack = QuotaThresholdTrackGeometry.customColorTrackRect(from: track)
        let trackPath = NSBezierPath(
            roundedRect: colorTrack,
            xRadius: colorTrack.height / 2,
            yRadius: colorTrack.height / 2
        )
        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()
        for segment in renderedColorTrackSegments(in: drawingView) {
            segment.color.nsColor.setFill()
            NSBezierPath(rect: segment.frame).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func renderedColorTrackSegments(in drawingView: NSView) -> [DebugColorTrackSegment] {
        let track = drawingView.convert(nativeTrackRect, from: self)
        let colorTrack = QuotaThresholdTrackGeometry.customColorTrackRect(from: track)
        let boundaryXs = activeBoundaries.map { _, value in
            stableKnobCenter(for: value, in: drawingView) ?? track.minX
        }
        let segmentXs = [colorTrack.minX] + boundaryXs + [colorTrack.maxX]
        return configurationStorage.enabledColorsInOrder.enumerated().map { index, color in
            DebugColorTrackSegment(
                color: color,
                frame: NSRect(
                    x: segmentXs[index],
                    y: colorTrack.minY,
                    width: segmentXs[index + 1] - segmentXs[index],
                    height: colorTrack.height
                )
            )
        }
    }

    private func updateTrackCoverGeometry() {
        let nativeKnobHole: NSRect?
        if let trackingColor, let knob = knobRect(for: trackingColor) {
            // The physical gap includes the stock knob's Liquid Glass halo;
            // it is a sibling-view gap, never transparent drawn content.
            nativeKnobHole = knob.insetBy(dx: -8, dy: -8)
        } else {
            nativeKnobHole = nil
        }
        let geometry = QuotaTrackCoverGeometry.make(bounds: bounds, hole: nativeKnobHole)
        trackCoverGeometry = geometry
        leftTrackCover.frame = geometry.leftFrame
        rightTrackCover.frame = geometry.rightFrame
        rightTrackCover.isHidden = geometry.hidesRightSlice
        leftTrackCover.needsDisplay = true
        rightTrackCover.needsDisplay = true
    }

    private static let logger = Logger(subsystem: "com.huanmeng06.BalanceBar", category: "QuotaThresholdSlider")

}
