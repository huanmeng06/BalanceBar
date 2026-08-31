import AppKit
import OSLog

enum QuotaThresholdSliderMath {
    static let logicalTicks = Array(stride(from: 0, through: 100, by: 5))
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
    static func visibleTicks(width: CGFloat, thumbValues: [Int]) -> [Int] {
        let interval = width >= 420 ? 5 : (width >= 260 ? 10 : 20)
        return Array(Set(stride(from: 0, through: 100, by: interval)).union([0, 50, 100]).union(thumbValues)).sorted()
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

/// A full-width display-only native slider used while the corresponding
/// interaction slider is idle. AppKit owns the complete knob presentation;
/// the clear fill suppresses this slider's bar while the semantic cover stays
/// continuous underneath it.
private final class QuotaPassiveKnobSlider: NSSlider {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        minValue = 0
        maxValue = 100
        doubleValue = 0
        sliderType = .linear
        controlSize = .regular
        isContinuous = true
        numberOfTickMarks = 0
        trackFillColor = .clear
        target = nil
        action = nil
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

    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 34) }

    private var sliderFrame: NSRect {
        NSRect(x: bounds.minX, y: bounds.midY - 14, width: bounds.width, height: 28)
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
        geometryProbe.doubleValue = Double(value)
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

        NSColor.tertiaryLabelColor.setStroke()
        for tick in QuotaThresholdSliderMath.visibleTicks(width: bounds.width, thumbValues: activeBoundaries.map(\.1)) {
            let x = activeBoundaries.first(where: { $0.1 == tick })
                .flatMap { stableKnobCenter(for: $0.1, in: drawingView) }
                ?? track.minX + track.width * CGFloat(tick) / 100
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: track.minY - 3))
            path.line(to: NSPoint(x: x, y: track.minY))
            path.stroke()
        }
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
