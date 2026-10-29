import AppKit
import Foundation
import QuartzCore
import CoreText

enum MenuBarWidthPerformance {
    #if DEBUG
    private static let log = OSLog(
        subsystem: "com.huanmeng06.BalanceBar",
        category: "menu-bar-width"
    )

    @inline(__always)
    static func measure(_ name: StaticString, _ body: () -> Void) {
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: signpostID)
        body()
        os_signpost(.end, log: log, name: name, signpostID: signpostID)
    }
    #else
    @inline(__always)
    static func measure(_ name: StaticString, _ body: () -> Void) {
        body()
    }
    #endif
}

/// Coalesces continuous width changes to display refreshes without making the
/// slider's mouse-tracking action perform the expensive status-bar update.
/// The display link runs in the common main run-loop modes so it continues
/// during AppKit slider tracking.
final class MenuBarWidthDisplayCoalescer: NSObject {
    private let apply: (CGFloat) -> Void
    private var pendingValue: CGFloat?
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?

    init(apply: @escaping (CGFloat) -> Void) {
        self.apply = apply
        super.init()
    }

    func submit(_ value: CGFloat) {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingValue = value
        guard displayLink == nil, fallbackTimer == nil else { return }
        startRefreshSource()
    }

    func flush() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopRefreshSource()
        let value = pendingValue
        pendingValue = nil
        if let value {
            apply(value)
        }
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopRefreshSource()
        pendingValue = nil
    }

    private func startRefreshSource() {
        if #available(macOS 14.0, *), let screen = NSScreen.main {
            let link = screen.displayLink(
                target: self,
                selector: #selector(displayLinkDidRefresh(_:))
            )
            displayLink = link
            link.add(to: .main, forMode: .common)
        } else {
            startFallbackTimer()
        }
    }

    private func startFallbackTimer() {
        let framesPerSecond = max(1, NSScreen.main?.maximumFramesPerSecond ?? 60)
        let timer = Timer(
            timeInterval: 1.0 / Double(framesPerSecond),
            repeats: true
        ) { [weak self] _ in
            self?.flushOneFrame()
        }
        fallbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRefreshSource() {
        if let displayLink {
            displayLink.invalidate()
            self.displayLink = nil
        }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func displayLinkDidRefresh(_ displayLink: CADisplayLink) {
        flushOneFrame()
    }

    private func flushOneFrame() {
        dispatchPrecondition(condition: .onQueue(.main))
        let value = pendingValue
        pendingValue = nil
        guard let value else {
            stopRefreshSource()
            return
        }
        apply(value)

        if pendingValue == nil {
            stopRefreshSource()
        }
    }
}

/// Pure geometry for one single-line marquee viewport. The viewport belongs
/// to the caller's content inset; the fade is only a mask at that viewport's
/// edges and is never added to the scrolling text's measured width. The
/// trailing fade buffer extends the animation endpoint past the raw text
/// overflow so the final glyphs stop before the trailing fade begins.
struct AccountMarqueeLayout: Equatable {
    static let defaultFadeWidth: CGFloat = 8

    let clipBounds: NSRect
    let measuredTextWidth: CGFloat
    let isScrollable: Bool
    let edgeFadeWidth: CGFloat
    let contentWidth: CGFloat
    let contentLeadingInset: CGFloat
    let textOverflow: CGFloat
    let trailingFadeBuffer: CGFloat
    let scrollDistance: CGFloat
    let maskLocations: [CGFloat]

    init(
        measuredTextWidth: CGFloat,
        clipBounds: NSRect,
        fadeWidth: CGFloat = Self.defaultFadeWidth,
        contentLeadingInset: CGFloat = 0
    ) {
        let viewportWidth = max(0, clipBounds.width)
        let textWidth = max(0, measuredTextWidth)
        let leadingInset = max(0, contentLeadingInset)
        let overflow = max(0, textWidth - leadingInset - viewportWidth)
        let scrollable = viewportWidth > 0 && overflow > 0
        let effectiveFadeWidth = scrollable
            ? min(max(0, fadeWidth), min(viewportWidth / 4, overflow))
            : 0

        self.clipBounds = clipBounds
        self.measuredTextWidth = textWidth
        self.isScrollable = scrollable
        self.edgeFadeWidth = effectiveFadeWidth
        self.contentLeadingInset = leadingInset
        self.contentWidth = scrollable ? textWidth : max(viewportWidth + leadingInset, textWidth)
        self.textOverflow = overflow
        self.trailingFadeBuffer = scrollable ? effectiveFadeWidth : 0
        self.scrollDistance = scrollable
            ? overflow + effectiveFadeWidth
            : 0

        if effectiveFadeWidth > 0, viewportWidth > 0 {
            let fadeFraction = effectiveFadeWidth / viewportWidth
            self.maskLocations = [
                0,
                fadeFraction,
                1 - fadeFraction,
                1
            ]
        } else {
            self.maskLocations = []
        }
    }

    /// Optical alignment trims the label's leading drawing space without
    /// reducing its full cell width. Fade width never adds another text inset.
    var contentFrame: NSRect {
        NSRect(
            x: clipBounds.minX - contentLeadingInset,
            y: clipBounds.minY,
            width: contentWidth,
            height: clipBounds.height
        )
    }

    /// The label frame at the far end of its animation. This is kept as a
    /// geometry seam so callers/tests can verify that text ends before the
    /// viewport's trailing fade rather than underneath the subscription row.
    var endpointContentFrame: NSRect {
        contentFrame.offsetBy(dx: -scrollDistance, dy: 0)
    }

    var trailingOpaqueMaxX: CGFloat {
        clipBounds.maxX - edgeFadeWidth
    }
}

/// Describes the visual state of a marquee from the offset actually applied to
/// its scrolling label. Each edge fades only while that side has hidden text,
/// including the stationary pause before the first movement.
struct AccountMarqueeScrollState: Equatable {
    static let activationThreshold: CGFloat = 0.5

    let offset: CGFloat
    let isActive: Bool
    private let overflow: CGFloat

    init(offset: CGFloat, overflow: CGFloat) {
        self.offset = offset
        self.overflow = overflow
        self.isActive = overflow > 0 && offset < -Self.activationThreshold
    }

    /// Ease the mask in as the leading glyph enters the fade region, and out
    /// along the same curve on the return trip. Activity's noise threshold must
    /// not act as a binary switch for the visible mask.
    func fadeStrength(fadeWidth: CGFloat) -> CGFloat {
        strength(hiddenDistance: -offset, fadeWidth: fadeWidth)
    }

    func trailingFadeStrength(fadeWidth: CGFloat) -> CGFloat {
        strength(hiddenDistance: overflow + offset, fadeWidth: fadeWidth)
    }

    private func strength(hiddenDistance: CGFloat, fadeWidth: CGFloat) -> CGFloat {
        guard overflow > 0, fadeWidth > 0 else { return 0 }
        let progress = min(1, max(0, hiddenDistance / fadeWidth))
        return progress * progress * (3 - 2 * progress)
    }
}

/// A fixed header badge whose text uses the existing visibility-aware marquee.
final class AggregationNoteTagView: NSView {
    let textView: AccountMarqueeView
    var originalTitleFrame: NSRect = .zero

    init(text: String, frame: NSRect) {
        textView = AccountMarqueeView(text: text, font: .systemFont(ofSize: 11),
            textColor: .secondaryLabelColor, frame: NSRect(x: 6, y: 0, width: max(0, frame.width - 12), height: 15))
        super.init(frame: frame)
        textView.respectsReduceMotion = true
        textView.centersTextWhenFits = true
        wantsLayer = true
        layer?.cornerRadius = 4
        addSubview(textView)
        updateText(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateText(_ text: String) {
        // The outer tag frame is assigned before this method during reuse.
        // Sync the inner viewport first so centering is measured against the
        // current width, and reset the marquee when the label identity changes.
        textView.frame = NSRect(x: 6, y: 0, width: max(0, bounds.width - 12), height: 15)
        textView.updateText(text, preserveScrollPosition: false)
        toolTip = text
        setAccessibilityLabel(text)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.quaternaryLabelColor.usingColorSpace(.deviceRGB) ?? .quaternaryLabelColor
            layer?.backgroundColor = color.withAlphaComponent(color.alphaComponent * 0.65).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        textView.frame = NSRect(x: 6, y: 0, width: max(0, bounds.width - 12), height: 15)
    }
}

final class AccountMarqueeView: NSView {
    static let animationKey = "BalanceBar.accountMarquee"
    static let defaultEdgeFadeWidth = AccountMarqueeLayout.defaultFadeWidth
    private static let minimumScrollDuration: TimeInterval = 5
    private static let minimumScrollSpeed: CGFloat = 36
    private static let maximumScrollSpeed: CGFloat = 180
    private static let scrollSpeedResponseLength: CGFloat = 320
    private static let minimumTravelDuration: TimeInterval = 1
    private static let scrollPauseDuration: TimeInterval = 0.8
    private static let scrollActivityInterval: TimeInterval = 1.0 / 30.0

    let accountLabel: NSTextField
    private(set) var measuredTextWidth: CGFloat = 0
    private(set) var isScrollable = false
    private(set) var isScrolling = false
    private(set) var showsEdgeFade = false
    private(set) var leadingEdgeFadeStrength: CGFloat = 0
    private(set) var trailingEdgeFadeStrength: CGFloat = 0
    private(set) var edgeFadeInset: CGFloat = 0
    private(set) var scrollOverflow: CGFloat = 0
    private(set) var scrollDistance: CGFloat = 0
    private(set) var scrollOffset: CGFloat = 0

    private var opticalClipHost: NSView?
    private let leadingInkAnchor: CGFloat?
    private var clippingView: NSView { opticalClipHost ?? self }
    var textClipFrame: NSRect { opticalClipHost?.frame ?? bounds }

    private var edgeFadeMask: CAGradientLayer?
    private var contentLayout: AccountMarqueeLayout?
    private var configuredText: String?
    private var configuredFontSignature: String?
    private var scrollActivityTimer: Timer?
    private var scrollIsSuspended = false
    var hasActiveScrollTimer: Bool { scrollActivityTimer != nil }
    var respectsReduceMotion = false
    var centersTextWhenFits = false {
        didSet { configureContentIfNeeded(force: true) }
    }

    private var isActuallyVisible: Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return false }
        var ancestor = superview
        while let current = ancestor {
            if let host = current as? MenuHoverLinkHostView { return host.isMenuContentVisible }
            ancestor = current.superview
        }
        return window?.isVisible == true
    }

    /// Offscreen rows retain their animation phase, but do no periodic work.
    func refreshScrollVisibility() {
        if respectsReduceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopScrolling()
            return
        }
        guard isActuallyVisible else {
            scrollActivityTimer?.invalidate()
            scrollActivityTimer = nil
            if !scrollIsSuspended, let layer = accountLabel.layer,
               layer.animation(forKey: Self.animationKey) != nil {
                layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
                scrollIsSuspended = true
            }
            return
        }
        startScrollingIfNeeded()
    }

    init(text: String, font: NSFont, textColor: NSColor, frame: NSRect, leadingInkAnchor: CGFloat? = nil,
         label: NSTextField? = nil) {
        accountLabel = label ?? NSTextField(labelWithString: text)
        self.leadingInkAnchor = leadingInkAnchor
        super.init(frame: frame)

        wantsLayer = true
        layer?.masksToBounds = true

        accountLabel.font = font
        accountLabel.textColor = textColor
        accountLabel.alignment = .left
        accountLabel.lineBreakMode = .byClipping
        accountLabel.usesSingleLineMode = true
        accountLabel.maximumNumberOfLines = 1
        accountLabel.wantsLayer = true
        if leadingInkAnchor != nil {
            let clip = NSView(frame: bounds)
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            addSubview(clip)
            clip.addSubview(accountLabel)
            opticalClipHost = clip
        } else {
            addSubview(accountLabel)
        }

        configureContentIfNeeded(force: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        configureContentIfNeeded()
        updateEdgeFadeMaskFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopScrolling()
        } else {
            configureContentIfNeeded()
            startScrollingIfNeeded()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            stopScrolling()
        } else {
            configureContentIfNeeded()
            startScrollingIfNeeded()
        }
    }

    deinit {
        stopScrolling()
    }

    /// Updates the semantic text without replacing the accessible text field.
    /// Re-measurement is immediate so dynamic menu copy cannot use the old
    /// overflow distance for one or more frames.
    func updateText(_ text: String, preserveScrollPosition: Bool = false) {
        guard accountLabel.stringValue != text else { return }
        accountLabel.stringValue = text
        configureContentIfNeeded(force: true, preserveScrollPosition: preserveScrollPosition)
    }

    private func configureContentIfNeeded(force: Bool = false, preserveScrollPosition: Bool = false) {
        let font = accountLabel.font ?? .systemFont(ofSize: 13)
        let text = accountLabel.stringValue
        let fontSignature = Self.fontSignature(for: font)
        // NSString reports glyph advances, whereas the NSTextField cell also
        // reserves drawing insets. A narrow label clips its own trailing glyphs
        // even after the outer viewport has scrolled all the way to the end.
        let labelWidth = centersTextWhenFits
            ? ceil(Self.textWidth(of: text, font: font))
            : max(Self.textWidth(of: text, font: font), ceil(accountLabel.cell?.cellSize.width ?? 0))
        if let clip = opticalClipHost, let anchor = leadingInkAnchor {
            let inset = min(max(0, anchor), bounds.width)
            clip.frame = NSRect(x: bounds.minX + inset, y: bounds.minY,
                                width: max(0, bounds.width - inset), height: bounds.height)
        }
        let nextLayout = AccountMarqueeLayout(
            measuredTextWidth: labelWidth,
            clipBounds: clippingView.bounds,
            fadeWidth: Self.defaultEdgeFadeWidth,
            contentLeadingInset: leadingInkAnchor == nil ? 0 : Self.leadingInkInset(of: accountLabel)
        )
        accountLabel.alignment = centersTextWhenFits && !nextLayout.isScrollable ? .center : .left
        guard force
            || contentLayout != nextLayout
            || configuredText != text
            || configuredFontSignature != fontSignature else {
            return
        }

        if preserveScrollPosition, contentLayout == nextLayout,
           configuredFontSignature == fontSignature {
            configuredText = text
            return
        }

        stopScrolling()
        contentLayout = nextLayout
        configuredText = text
        configuredFontSignature = fontSignature
        measuredTextWidth = nextLayout.measuredTextWidth
        isScrollable = nextLayout.isScrollable
        edgeFadeInset = nextLayout.edgeFadeWidth
        scrollOverflow = nextLayout.textOverflow
        scrollDistance = nextLayout.scrollDistance
        accountLabel.frame = nextLayout.contentFrame

        if nextLayout.isScrollable {
            let mask = edgeFadeMask ?? CAGradientLayer()
            // CAGradientLayer defaults to a vertical axis. The marquee is a
            // single-line viewport, so the fade must run across its actual
            // horizontal clip bounds instead of fading the glyphs by height.
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [
                NSColor.black.cgColor,
                NSColor.black.cgColor,
                NSColor.black.cgColor,
                NSColor.black.cgColor
            ]
            mask.locations = nextLayout.maskLocations.map {
                NSNumber(value: Double($0))
            }
            edgeFadeMask = mask
            clippingView.layer?.mask = nil
            updateEdgeFadeMaskFrame()
        } else {
            clippingView.layer?.mask = nil
            edgeFadeMask = nil
            showsEdgeFade = false
        }

        // Reapply even if the strengths match the previous geometry: resizing
        // may have replaced the mask or changed its stop locations.
        applyScrollState(AccountMarqueeScrollState(offset: 0, overflow: scrollOverflow), force: true)
        startScrollingIfNeeded()
    }

    private func updateEdgeFadeMaskFrame() {
        guard let mask = edgeFadeMask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = clippingView.layer?.bounds ?? clippingView.bounds
        CATransaction.commit()
    }

    private func startScrollingIfNeeded() {
        guard isScrollable,
              !(respectsReduceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
              isActuallyVisible,
              let labelLayer = accountLabel.layer else {
            return
        }

        let overflow = contentLayout?.textOverflow ?? scrollOverflow
        guard overflow > 0 else { return }
        if scrollIsSuspended {
            let pausedTime = labelLayer.timeOffset
            labelLayer.speed = 1
            labelLayer.timeOffset = 0
            labelLayer.beginTime = 0
            labelLayer.beginTime = labelLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            scrollIsSuspended = false
        }

        if labelLayer.animation(forKey: Self.animationKey) == nil {
            let trailingFadeBuffer = contentLayout?.trailingFadeBuffer ?? edgeFadeInset
            let animation = Self.scrollAnimation(
                forOverflow: overflow,
                trailingFadeBuffer: trailingFadeBuffer
            )
            labelLayer.add(animation, forKey: Self.animationKey)
        }
        startScrollActivityMonitoring()
    }

    private func stopScrolling() {
        scrollIsSuspended = false
        accountLabel.layer?.speed = 1
        accountLabel.layer?.timeOffset = 0
        accountLabel.layer?.beginTime = 0
        accountLabel.layer?.removeAnimation(forKey: Self.animationKey)
        scrollActivityTimer?.invalidate()
        scrollActivityTimer = nil
        applyScrollState(AccountMarqueeScrollState(offset: 0, overflow: scrollOverflow))
    }

    private func startScrollActivityMonitoring() {
        guard scrollActivityTimer == nil else {
            updateScrollActivity()
            return
        }

        let timer = Timer(
            timeInterval: Self.scrollActivityInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            if self.isActuallyVisible { self.updateScrollActivity() }
            else { self.refreshScrollVisibility() }
        }
        scrollActivityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateScrollActivity()
    }

    private func updateScrollActivity() {
        guard let labelLayer = accountLabel.layer,
              labelLayer.animation(forKey: Self.animationKey) != nil else {
            applyScrollState(AccountMarqueeScrollState(offset: 0, overflow: scrollOverflow))
            return
        }

        let offset = (labelLayer.presentation()?
            .value(forKeyPath: "transform.translation.x") as? NSNumber)
            .map { CGFloat($0.doubleValue) } ?? 0
        applyScrollState(
            AccountMarqueeScrollState(offset: offset, overflow: scrollOverflow)
        )
    }

    private func applyScrollState(_ state: AccountMarqueeScrollState, force: Bool = false) {
        scrollOffset = state.offset
        isScrolling = state.isActive

        let leading = state.fadeStrength(fadeWidth: edgeFadeInset)
        let trailing = state.trailingFadeStrength(fadeWidth: edgeFadeInset)
        guard force || leading != leadingEdgeFadeStrength || trailing != trailingEdgeFadeStrength else { return }
        leadingEdgeFadeStrength = leading
        trailingEdgeFadeStrength = trailing

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if leading > 0 || trailing > 0, let mask = edgeFadeMask {
            let attaching = clippingView.layer?.mask !== mask
            if attaching {
                clippingView.layer?.mask = mask
                updateEdgeFadeMaskFrame()
            }
            // Interpolate between samples independently at each edge. The
            // stationary start has only a trailing fade; the end only leading.
            CATransaction.setDisableActions(attaching)
            CATransaction.setAnimationDuration(Self.scrollActivityInterval)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            let leadingEdge = NSColor.black.withAlphaComponent(1 - leading).cgColor
            let trailingEdge = NSColor.black.withAlphaComponent(1 - trailing).cgColor
            mask.colors = [leadingEdge, NSColor.black.cgColor, NSColor.black.cgColor, trailingEdge]
        } else {
            clippingView.layer?.mask = nil
            // Reset a retained mask for the next cycle's first attachment.
            edgeFadeMask?.colors = Array(repeating: NSColor.black.cgColor, count: 4)
        }
        showsEdgeFade = leading > 0 || trailing > 0
        CATransaction.commit()
    }

    /// Test seam for checking the mask contract without depending on a live
    /// WindowServer presentation frame. Production activity is sampled from
    /// the label layer's presentation transform in `updateScrollActivity()`.
    func applyScrollOffsetForTesting(_ offset: CGFloat) {
        applyScrollState(
            AccountMarqueeScrollState(offset: offset, overflow: scrollOverflow)
        )
    }

    /// Include the NSTextField drawing inset and the shaped run's ink bearing,
    /// rather than aligning the viewport to a guessed padding or one language.
    static func leadingInkInset(of label: NSTextField) -> CGFloat {
        let font = label.font ?? .systemFont(ofSize: 13)
        let text = label.stringValue
        let advance = (text as NSString).size(withAttributes: [.font: font]).width
        let cellInset = max(0, ((label.cell?.cellSize.width ?? advance) - advance) / 2)
        let run = NSAttributedString(string: text, attributes: [.font: font])
        let ink = CTLineGetImageBounds(CTLineCreateWithAttributedString(run as CFAttributedString), nil)
        return max(0, cellInset + (ink.isNull ? 0 : ink.minX))
    }

    static func textWidth(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Makes long strings cross the viewport in a reasonable amount of time.
    /// The saturating exponential curve increases speed quickly for the first
    /// few hundred points of overflow, then approaches a readable upper bound
    /// instead of growing linearly without limit.
    static func scrollSpeed(forOverflow overflow: CGFloat) -> CGFloat {
        let normalizedOverflow = max(0, overflow) / scrollSpeedResponseLength
        let curveProgress = CGFloat(1 - exp(-Double(normalizedOverflow)))
        return min(
            maximumScrollSpeed,
            minimumScrollSpeed
                + (maximumScrollSpeed - minimumScrollSpeed) * curveProgress
        )
    }

    private static func fontSignature(for font: NSFont) -> String {
        "\(font.fontName)|\(font.pointSize)|\(font.fontDescriptor.symbolicTraits.rawValue)"
    }

    static func scrollAnimation(
        forOverflow overflow: CGFloat,
        trailingFadeBuffer: CGFloat = 0
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        let safeOverflow = max(0, overflow)
        let safeTrailingFadeBuffer = max(0, trailingFadeBuffer)
        let scrollDistance = safeOverflow + safeTrailingFadeBuffer
        let offset = NSNumber(value: -Double(scrollDistance))
        let scrollSpeed = Self.scrollSpeed(forOverflow: safeOverflow)
        let travelDuration = max(
            minimumTravelDuration,
            Double(scrollDistance / scrollSpeed)
        )
        let phaseDuration = 2 * scrollPauseDuration + 2 * travelDuration
        let pauseFraction = scrollPauseDuration / phaseDuration
        let travelFraction = travelDuration / phaseDuration

        animation.values = [0, 0, offset, offset, 0]
        animation.keyTimes = [
            NSNumber(value: 0),
            NSNumber(value: pauseFraction),
            NSNumber(value: pauseFraction + travelFraction),
            NSNumber(value: pauseFraction + travelFraction + pauseFraction),
            NSNumber(value: 1)
        ]
        animation.duration = max(minimumScrollDuration, phaseDuration)
        animation.repeatCount = .infinity
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        return animation
    }
}

/// The account row is deliberately different from quota/reset copy. Account
/// emails stay still and use a measured middle truncation so the visible
/// value never needs to move underneath the subscription column. The full
/// value remains on the native label for accessibility and AppKit's hover
/// tooltip.
struct AccountEmailTextLayout: Equatable {
    static let ellipsis = "…"

    let displayText: String
    let prefix: String
    let suffix: String
    let measuredTextWidth: CGFloat
    let availableWidth: CGFloat
    let isTruncated: Bool

    private struct Candidate {
        let displayText: String
        let prefix: String
        let suffix: String
        let usesFullDomain: Bool
        let hasPrefix: Bool
        let prefixCharacterCount: Int
        let suffixCharacterCount: Int
    }

    static func make(
        for text: String,
        font: NSFont,
        availableWidth: CGFloat
    ) -> Self {
        let width = max(0, availableWidth)
        let measuredTextWidth = AccountMarqueeView.textWidth(of: text, font: font)
        if measuredTextWidth <= width {
            return Self(
                displayText: text,
                prefix: text,
                suffix: "",
                measuredTextWidth: measuredTextWidth,
                availableWidth: width,
                isTruncated: false
            )
        }

        let ellipsis = Self.ellipsis
        let measure: (String) -> CGFloat = {
            AccountMarqueeView.textWidth(of: $0, font: font)
        }

        func makeLayout(from candidate: Candidate) -> Self {
            Self(
                displayText: candidate.displayText,
                prefix: candidate.prefix,
                suffix: candidate.suffix,
                measuredTextWidth: measure(candidate.displayText),
                availableWidth: width,
                isTruncated: true
            )
        }

        func isBetter(_ candidate: Candidate, than current: Candidate?) -> Bool {
            guard let current else { return true }
            if candidate.usesFullDomain != current.usesFullDomain {
                return candidate.usesFullDomain
            }
            if candidate.hasPrefix != current.hasPrefix {
                return candidate.hasPrefix
            }
            if candidate.suffixCharacterCount != current.suffixCharacterCount {
                return candidate.suffixCharacterCount > current.suffixCharacterCount
            }
            if candidate.prefixCharacterCount != current.prefixCharacterCount {
                return candidate.prefixCharacterCount > current.prefixCharacterCount
            }
            return candidate.displayText.count > current.displayText.count
        }

        func candidate(
            prefix: String,
            suffix: String,
            usesFullDomain: Bool,
            prefixCharacterCount: Int,
            suffixCharacterCount: Int
        ) -> Candidate? {
            let displayText = prefix + ellipsis + suffix
            guard measure(displayText) <= width + 0.001 else { return nil }
            return Candidate(
                displayText: displayText,
                prefix: prefix,
                suffix: suffix,
                usesFullDomain: usesFullDomain,
                hasPrefix: prefixCharacterCount > 0,
                prefixCharacterCount: prefixCharacterCount,
                suffixCharacterCount: suffixCharacterCount
            )
        }

        func bestDomainCandidate(
            localCharacters: [Character],
            domainCharacters: [Character],
            includeAtSign: Bool,
            requirePrefix: Bool
        ) -> Candidate? {
            var best: Candidate?
            for prefixCount in 0...localCharacters.count {
                if requirePrefix && prefixCount == 0 { continue }
                let prefix = String(localCharacters.prefix(prefixCount))
                for domainStart in 0...domainCharacters.count {
                    let domainTail = String(domainCharacters.dropFirst(domainStart))
                    let suffix = includeAtSign ? "@" + domainTail : domainTail
                    guard let next = candidate(
                        prefix: prefix,
                        suffix: suffix,
                        usesFullDomain: domainStart == 0,
                        prefixCharacterCount: prefixCount,
                        suffixCharacterCount: domainTail.count
                    ) else { continue }
                    if isBetter(next, than: best) {
                        best = next
                    }
                }
            }
            return best
        }

        if let atIndex = text.lastIndex(of: "@") {
            let localPart = String(text[..<atIndex])
            let domainPart = String(text[text.index(after: atIndex)...])
            let localCharacters = Array(localPart)
            let domainCharacters = Array(domainPart)

            // A complete @-domain wins whenever the actual font measurement
            // allows it. If the domain itself is too long, the same search
            // keeps its right-hand graphemes and then spends the remaining
            // width on the local-part prefix.
            if let best = bestDomainCandidate(
                localCharacters: localCharacters,
                domainCharacters: domainCharacters,
                includeAtSign: true,
                requirePrefix: true
            ) {
                return makeLayout(from: best)
            }
            if let best = bestDomainCandidate(
                localCharacters: localCharacters,
                domainCharacters: domainCharacters,
                includeAtSign: true,
                requirePrefix: false
            ) {
                return makeLayout(from: best)
            }

            // Extremely narrow viewports may not fit the @ together with any
            // domain grapheme. Keep the domain's right tail rather than
            // silently falling back to a leading hard clip.
            if let best = bestDomainCandidate(
                localCharacters: localCharacters,
                domainCharacters: domainCharacters,
                includeAtSign: false,
                requirePrefix: true
            ) {
                return makeLayout(from: best)
            }
            if let best = bestDomainCandidate(
                localCharacters: localCharacters,
                domainCharacters: domainCharacters,
                includeAtSign: false,
                requirePrefix: false
            ) {
                return makeLayout(from: best)
            }
        }

        // Addresses without a usable @, and very narrow addresses for which
        // even the @-domain candidates do not fit, still get a true middle
        // truncation. Character iteration keeps composed Unicode graphemes
        // intact instead of splitting UTF-8 or UTF-16 storage.
        let characters = Array(text)
        if characters.count > 1 {
            var best: Candidate?
            for prefixCount in 0..<(characters.count) {
                let maxSuffixCount = characters.count - prefixCount - 1
                let prefix = String(characters.prefix(prefixCount))
                for suffixCount in 0...maxSuffixCount {
                    let suffix = String(characters.suffix(suffixCount))
                    guard let next = candidate(
                        prefix: prefix,
                        suffix: suffix,
                        usesFullDomain: false,
                        prefixCharacterCount: prefixCount,
                        suffixCharacterCount: suffixCount
                    ) else { continue }
                    if let current = best {
                        let nextVisibleCount = prefixCount + suffixCount
                        let currentVisibleCount = current.prefixCharacterCount
                            + current.suffixCharacterCount
                        if nextVisibleCount > currentVisibleCount
                            || (nextVisibleCount == currentVisibleCount
                                && min(prefixCount, suffixCount)
                                    > min(
                                        current.prefixCharacterCount,
                                        current.suffixCharacterCount
                                    ))
                            || (nextVisibleCount == currentVisibleCount
                                && min(prefixCount, suffixCount)
                                    == min(
                                        current.prefixCharacterCount,
                                        current.suffixCharacterCount
                                    )
                                && isBetter(next, than: current)) {
                            best = next
                        }
                    } else {
                        best = next
                    }
                }
            }
            if let best {
                return makeLayout(from: best)
            }
        }

        if measure(ellipsis) <= width {
            return Self(
                displayText: ellipsis,
                prefix: "",
                suffix: "",
                measuredTextWidth: measure(ellipsis),
                availableWidth: width,
                isTruncated: true
            )
        }

        return Self(
            displayText: "",
            prefix: "",
            suffix: "",
            measuredTextWidth: 0,
            availableWidth: width,
            isTruncated: true
        )
    }
}

struct AccountEmailTooltipLayout: Equatable {
    static let maximumTextWidth: CGFloat = 280
    static let minimumTextWidth: CGFloat = 160
    static let textMeasurementSlack: CGFloat = 8
    static let textHeightMeasurementSlack: CGFloat = 2
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 8

    let textWidth: CGFloat
    let textHeight: CGFloat
    let contentSize: NSSize

    static func make(for email: String, font: NSFont) -> Self {
        let textWidth = min(
            maximumTextWidth,
            max(
                minimumTextWidth,
                ceil(AccountMarqueeView.textWidth(of: email, font: font))
                    + textMeasurementSlack
            )
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        let measuredText = NSAttributedString(
            string: email,
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
        ).boundingRect(
            with: NSSize(
                width: textWidth,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let measurementLabel = NSTextField(wrappingLabelWithString: email)
        measurementLabel.font = font
        measurementLabel.lineBreakMode = .byCharWrapping
        measurementLabel.usesSingleLineMode = false
        measurementLabel.maximumNumberOfLines = 0
        measurementLabel.preferredMaxLayoutWidth = textWidth
        measurementLabel.cell?.wraps = true
        measurementLabel.cell?.truncatesLastVisibleLine = false
        measurementLabel.cell?.lineBreakMode = .byCharWrapping
        let textHeight = max(
            ceil(font.ascender - font.descender + 2),
            ceil(measuredText.height) + textHeightMeasurementSlack,
            ceil(measurementLabel.fittingSize.height)
        )
        return Self(
            textWidth: textWidth,
            textHeight: textHeight,
            contentSize: NSSize(
                width: textWidth + horizontalInset * 2,
                height: textHeight + verticalInset * 2
            )
        )
    }
}

private final class AccountEmailTooltipViewController: NSViewController {

    private let email: String

    init(email: String) {
        self.email = email
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let font = DashboardTextTooltip.font
        let layout = AccountEmailTooltipLayout.make(for: email, font: font)
        let view = NSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: layout.contentSize.width,
                height: layout.contentSize.height
            )
        )
        let label = NSTextField(wrappingLabelWithString: email)
        DashboardTextTooltip.configure(label)
        label.font = font
        label.lineBreakMode = .byCharWrapping
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = layout.textWidth
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = false
        label.cell?.lineBreakMode = .byCharWrapping
        label.frame = NSRect(
            x: AccountEmailTooltipLayout.horizontalInset,
            y: AccountEmailTooltipLayout.verticalInset,
            width: layout.textWidth,
            height: layout.textHeight
        )
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel(email)
        label.setAccessibilityValue(email)
        view.addSubview(label)
        self.view = view
    }
}

final class AccountEmailTextField: NSTextField {
    static let tooltipDelay: TimeInterval = 0.15

    var accountAccessibilityValue = ""
    private var hoverTrackingArea: NSTrackingArea?
    private var tooltipTimer: Timer?
    private var tooltipPopover: NSPopover?
    private var tooltipText = ""
    private var displayedText = ""
    private var displayedFont = NSFont.systemFont(ofSize: 13)
    private var displayedTextColor = NSColor.secondaryLabelColor

    private(set) var isEmailHovered = false
    private(set) var isTooltipScheduled = false
    private(set) var isTooltipVisible = false

    var isUnderlined: Bool {
        guard !displayedText.isEmpty else { return false }
        return (attributedStringValue.attribute(
            .underlineStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue
    }

    override func accessibilityValue() -> String? {
        accountAccessibilityValue
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        super.updateTrackingAreas()
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setEmailHovered(true)
        scheduleTooltipPresentation()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        cancelTooltipPresentation()
        setEmailHovered(false)
    }

    /// Updates the rendered text while retaining the hover underline state.
    /// The parent view calls this after every dynamic text or resize update.
    func setDisplayedText(_ text: String, font: NSFont, textColor: NSColor) {
        displayedText = text
        displayedFont = font
        displayedTextColor = textColor
        applyDisplayedTextAttributes()
    }

    /// Test seam for the same state transition driven by AppKit mouse-enter
    /// and mouse-exit events. Production hover handling uses the tracking area
    /// above; this keeps the lifecycle testable without synthesizing a window
    /// event or relying on a click.
    func setHoveringForTesting(_ isHovering: Bool) {
        if !isHovering {
            cancelTooltipPresentation()
        }
        setEmailHovered(isHovering)
    }

    /// Keeps the full value on AppKit's native tooltip property as a fallback,
    /// while the short-delay popover is used when the label is in a visible
    /// menu window.
    func setTooltipText(_ text: String) {
        guard tooltipText != text else { return }
        tooltipText = text
        toolTip = text
        guard tooltipPopover != nil else { return }
        closeTooltipPresentation()
        if isEmailHovered {
            scheduleTooltipPresentation()
        }
    }

    private func setEmailHovered(_ isHovering: Bool) {
        guard isEmailHovered != isHovering else { return }
        isEmailHovered = isHovering
        applyDisplayedTextAttributes()
    }

    private func scheduleTooltipPresentation() {
        guard !isTooltipVisible,
              tooltipTimer == nil,
              !tooltipText.isEmpty else {
            return
        }
        let timer = Timer(
            timeInterval: Self.tooltipDelay,
            repeats: false
        ) { [weak self] _ in
            self?.presentTooltip()
        }
        tooltipTimer = timer
        isTooltipScheduled = true
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelTooltipPresentation() {
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        isTooltipScheduled = false
        closeTooltipPresentation()
    }

    private func presentTooltip() {
        tooltipTimer = nil
        isTooltipScheduled = false
        guard isEmailHovered,
              let window,
              window.isVisible,
              !tooltipText.isEmpty else {
            return
        }

        let popover = DashboardTextTooltip.makePopover()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let tooltipViewController = AccountEmailTooltipViewController(email: tooltipText)
        tooltipViewController.loadViewIfNeeded()
        popover.contentViewController = tooltipViewController
        popover.contentSize = tooltipViewController.view.frame.size
        tooltipPopover = popover

        // Cancel AppKit's slower default tooltip once the accelerated native
        // popover is ready. Restore it when the pointer leaves as a fallback.
        toolTip = nil
        popover.show(
            relativeTo: bounds,
            of: self,
            preferredEdge: .maxY
        )
        guard popover.isShown else {
            tooltipPopover = nil
            toolTip = tooltipText
            return
        }
        isTooltipVisible = true
    }

    private func closeTooltipPresentation() {
        tooltipPopover?.animates = false
        tooltipPopover?.close()
        tooltipPopover = nil
        isTooltipVisible = false
        if toolTip != tooltipText {
            toolTip = tooltipText
        }
    }

    deinit {
        tooltipTimer?.invalidate()
        tooltipPopover?.close()
    }

    private func applyDisplayedTextAttributes() {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: displayedFont,
            .foregroundColor: displayedTextColor
        ]
        if isEmailHovered {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        attributedStringValue = NSAttributedString(
            string: displayedText,
            attributes: attributes
        )
    }
}

final class AccountEmailView: NSView {
    static let accessibilityIdentifier = NSUserInterfaceItemIdentifier("accountEmail")

    let emailLabel: AccountEmailTextField
    private(set) var fullEmail: String
    private(set) var textLayout: AccountEmailTextLayout

    var displayedEmail: String { textLayout.displayText }
    var isMarqueeEnabled: Bool { false }

    init(email: String, font: NSFont, textColor: NSColor, frame: NSRect) {
        fullEmail = email
        emailLabel = AccountEmailTextField(frame: .zero)
        textLayout = AccountEmailTextLayout(
            displayText: "",
            prefix: "",
            suffix: "",
            measuredTextWidth: 0,
            availableWidth: max(0, frame.width),
            isTruncated: !email.isEmpty
        )
        super.init(frame: frame)

        emailLabel.font = font
        emailLabel.textColor = textColor
        emailLabel.alignment = .left
        emailLabel.lineBreakMode = .byClipping
        emailLabel.usesSingleLineMode = true
        emailLabel.maximumNumberOfLines = 1
        emailLabel.isEditable = false
        emailLabel.isSelectable = false
        emailLabel.drawsBackground = false
        emailLabel.isBordered = false
        emailLabel.identifier = Self.accessibilityIdentifier
        emailLabel.toolTip = email
        emailLabel.setAccessibilityRole(.staticText)
        addSubview(emailLabel)

        refreshLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        emailLabel.frame = bounds
        refreshLayout()
    }

    /// Test seam for AppKit's native tooltip hit region. Production uses the
    /// NSTextField `toolTip` property, whose own hover tracking shows and
    /// hides the system tooltip without changing this view's frame.
    func tooltipText(at point: NSPoint) -> String? {
        bounds.contains(point) ? fullEmail : nil
    }

    func updateText(_ email: String) {
        guard fullEmail != email else {
            refreshLayout()
            return
        }
        fullEmail = email
        refreshLayout()
    }

    private func updateAccessibilityAndTooltip() {
        emailLabel.setTooltipText(fullEmail)
        emailLabel.accountAccessibilityValue = fullEmail
        emailLabel.setAccessibilityLabel(fullEmail)
        emailLabel.setAccessibilityValue(fullEmail)
    }

    private func refreshLayout() {
        emailLabel.frame = bounds
        let font = emailLabel.font ?? .systemFont(ofSize: 13)
        let nextLayout = AccountEmailTextLayout.make(
            for: fullEmail,
            font: font,
            availableWidth: bounds.width
        )
        guard nextLayout != textLayout || emailLabel.stringValue != nextLayout.displayText else {
            updateAccessibilityAndTooltip()
            return
        }
        textLayout = nextLayout
        emailLabel.setDisplayedText(
            nextLayout.displayText,
            font: font,
            textColor: emailLabel.textColor ?? .secondaryLabelColor
        )
        updateAccessibilityAndTooltip()
    }
}

enum StatusItemVisibility: Equatable {
    case unknown
    case visible
    case hiddenByMenuBarSpace
    case hiddenByRuntimePolicy
    case hiddenByMenuBarSpaceAndRuntimePolicy

    var isHiddenByMenuBarSpace: Bool {
        self == .hiddenByMenuBarSpace
            || self == .hiddenByMenuBarSpaceAndRuntimePolicy
    }

    var isHiddenByRuntimePolicy: Bool {
        self == .hiddenByRuntimePolicy
            || self == .hiddenByMenuBarSpaceAndRuntimePolicy
    }
}

struct StatusItemVisibilityEvidence {
    let statusItemIsVisible: Bool
    let windowIsVisible: Bool
    let windowIsOcclusionVisible: Bool
    let statusItemIdentity: ObjectIdentifier?
    let windowIdentity: ObjectIdentifier?
    let buttonIdentity: ObjectIdentifier?
    let statusItemFrame: NSRect?
    let statusItemWindowFrame: NSRect?
    let screenFrame: NSRect?
    let buttonIsHidden: Bool
}

/// Fuses AppKit identity, occlusion, geometry, and button state into the one
/// visibility state consumed by the real menu-bar status and Dashboard warning.
///
/// AppKit can briefly leave an item, its button, and a complete screen-space
/// frame in place while the WindowServer is reflowing the menu bar. A single
/// non-occluded sample is therefore only a hidden candidate. A visible
/// occlusion sample is stronger evidence and clears any previous warning
/// immediately; hidden space warnings require two stable samples for the same
/// item/window/button and geometry signature.
struct StatusItemVisibilityStateMachine {
    static let hiddenConfirmationSampleCount = 2
    static let hiddenConfirmationInterval: TimeInterval = 0.15

    private struct HiddenCandidateKey: Equatable {
        let statusItemIdentity: ObjectIdentifier
        let windowIdentity: ObjectIdentifier
        let buttonIdentity: ObjectIdentifier
        let statusItemFrame: NSRect
        let statusItemWindowFrame: NSRect
        let screenFrame: NSRect
        let buttonIsHidden: Bool
        let exceedsScreenHorizontally: Bool
    }

    private struct HiddenCandidate {
        let key: HiddenCandidateKey
        var sampleCount: Int
        let firstSampleAt: Date
        var lastSampleAt: Date
    }

    // This is the state already published to the menu bar and Dashboard.
    // `hiddenCandidate` is deliberately kept separate: a new geometry sample
    // can be pending while the last committed state remains authoritative.
    private(set) var visibility: StatusItemVisibility = .unknown
    private var hiddenCandidate: HiddenCandidate?

    var needsAdditionalHiddenSample: Bool {
        guard let hiddenCandidate else { return false }
        return hiddenCandidate.sampleCount < Self.hiddenConfirmationSampleCount
    }

    var hiddenCandidateSampleCount: Int {
        hiddenCandidate?.sampleCount ?? 0
    }

    mutating func reset() {
        visibility = .unknown
        hiddenCandidate = nil
    }

    mutating func ingest(
        _ evidence: StatusItemVisibilityEvidence,
        at date: Date
    ) -> StatusItemVisibility {
        guard evidence.statusItemIsVisible,
              evidence.windowIsVisible,
              let statusItemIdentity = evidence.statusItemIdentity,
              let windowIdentity = evidence.windowIdentity,
              let buttonIdentity = evidence.buttonIdentity,
              let statusItemFrame = evidence.statusItemFrame,
              let statusItemWindowFrame = evidence.statusItemWindowFrame,
              let screenFrame = evidence.screenFrame,
              statusItemFrame.width > 0,
              statusItemFrame.height > 0,
              statusItemWindowFrame.width > 0,
              statusItemWindowFrame.height > 0,
              screenFrame.width > 0,
              screenFrame.height > 0 else {
            return setUnknown()
        }

        let isInMenuBarBand = statusItemWindowFrame.maxY >= screenFrame.maxY - 4
            && statusItemWindowFrame.minY >= screenFrame.maxY - 48
        guard isInMenuBarBand else { return setUnknown() }

        let exceedsScreenHorizontally = statusItemFrame.minX < screenFrame.minX
            || statusItemFrame.maxX > screenFrame.maxX
        let key = HiddenCandidateKey(
            statusItemIdentity: statusItemIdentity,
            windowIdentity: windowIdentity,
            buttonIdentity: buttonIdentity,
            statusItemFrame: statusItemFrame,
            statusItemWindowFrame: statusItemWindowFrame,
            screenFrame: screenFrame,
            buttonIsHidden: evidence.buttonIsHidden,
            exceedsScreenHorizontally: exceedsScreenHorizontally
        )

        if evidence.windowIsOcclusionVisible,
           !evidence.buttonIsHidden,
           !exceedsScreenHorizontally {
            hiddenCandidate = nil
            visibility = .visible
            return .visible
        }

        if var candidate = hiddenCandidate, candidate.key == key {
            guard date.timeIntervalSince(candidate.lastSampleAt)
                >= Self.hiddenConfirmationInterval else {
                return visibility
            }
            candidate.sampleCount += 1
            candidate.lastSampleAt = date
            hiddenCandidate = candidate
        } else {
            hiddenCandidate = HiddenCandidate(
                key: key,
                sampleCount: 1,
                firstSampleAt: date,
                lastSampleAt: date
            )
        }

        guard let candidate = hiddenCandidate,
              candidate.sampleCount >= Self.hiddenConfirmationSampleCount,
              candidate.lastSampleAt.timeIntervalSince(candidate.firstSampleAt)
                >= Self.hiddenConfirmationInterval else {
            return visibility
        }

        visibility = .hiddenByMenuBarSpace
        return .hiddenByMenuBarSpace
    }

    private mutating func setUnknown() -> StatusItemVisibility {
        hiddenCandidate = nil
        visibility = .unknown
        return .unknown
    }
}

/// Applies the user-selected menu-bar display policy to Codex activity
/// samples. A false sample is only allowed to hide the status item after two
/// stable samples separated by the normal activity polling cadence and the
/// selected post-task grace period. This keeps startup, monitor recovery, and
/// quick task transitions visible while reusing the activity value emitted by
/// ActivityCoordinator.
struct MenuBarIconDisplayStateMachine {
    static let idleConfirmationSampleCount = 2
    static let idleConfirmationInterval: TimeInterval = 0.25

    private struct IdleCandidate {
        var sampleCount: Int
        let firstSampleAt: Date
        var lastSampleAt: Date
    }

    private(set) var shouldDisplay = true
    private var mode: MenuBarIconDisplayMode = .alwaysVisible
    private var displayDelay: MenuBarIconDisplayDelay = .defaultValue
    private var idleCandidate: IdleCandidate?

    var needsAdditionalIdleSample: Bool {
        guard let idleCandidate else { return false }
        return idleCandidate.sampleCount < Self.idleConfirmationSampleCount
    }

    var idleCandidateSampleCount: Int {
        idleCandidate?.sampleCount ?? 0
    }

    mutating func reset() {
        shouldDisplay = true
        mode = .alwaysVisible
        displayDelay = .defaultValue
        idleCandidate = nil
    }

    @discardableResult
    mutating func setMode(
        _ mode: MenuBarIconDisplayMode,
        codexTaskRunning: Bool,
        at date: Date
    ) -> Bool {
        guard self.mode != mode else { return shouldDisplay }
        self.mode = mode
        guard mode == .onlyWhileRunning, !codexTaskRunning else {
            shouldDisplay = true
            idleCandidate = nil
            return shouldDisplay
        }
        idleCandidate = IdleCandidate(
            sampleCount: 1,
            firstSampleAt: date,
            lastSampleAt: date
        )
        return shouldDisplay
    }

    @discardableResult
    mutating func setDisplayDelay(
        _ delay: MenuBarIconDisplayDelay,
        at date: Date
    ) -> Bool {
        displayDelay = delay
        return commitIdleIfReady(at: date)
    }

    @discardableResult
    mutating func ingest(
        mode: MenuBarIconDisplayMode,
        displayDelay: MenuBarIconDisplayDelay = .defaultValue,
        codexTaskRunning: Bool,
        at date: Date
    ) -> Bool {
        setMode(mode, codexTaskRunning: codexTaskRunning, at: date)
        setDisplayDelay(displayDelay, at: date)
        guard mode == .onlyWhileRunning else {
            shouldDisplay = true
            idleCandidate = nil
            return shouldDisplay
        }

        guard !codexTaskRunning else {
            shouldDisplay = true
            idleCandidate = nil
            return shouldDisplay
        }

        if var candidate = idleCandidate {
            guard date.timeIntervalSince(candidate.lastSampleAt)
                >= Self.idleConfirmationInterval else {
                return shouldDisplay
            }
            candidate.sampleCount += 1
            candidate.lastSampleAt = date
            idleCandidate = candidate
        } else {
            idleCandidate = IdleCandidate(
                sampleCount: 1,
                firstSampleAt: date,
                lastSampleAt: date
            )
        }

        return commitIdleIfReady(at: date)
    }

    private mutating func commitIdleIfReady(at date: Date) -> Bool {
        guard mode == .onlyWhileRunning,
              let candidate = idleCandidate,
              candidate.sampleCount >= Self.idleConfirmationSampleCount,
              candidate.lastSampleAt.timeIntervalSince(candidate.firstSampleAt)
                >= Self.idleConfirmationInterval,
              date.timeIntervalSince(candidate.firstSampleAt)
                >= displayDelay.duration else {
            return shouldDisplay
        }

        shouldDisplay = false
        return shouldDisplay
    }
}

/// Stable value representation for a view transform. The final bitmap cache
/// is keyed by the transforms that were actually applied to the offscreen
/// content, not just by the user preferences that usually produce them.
struct MenuBarBitmapAnimationTransformSignature: Equatable {
    let a: CGFloat
    let b: CGFloat
    let c: CGFloat
    let d: CGFloat
    let tx: CGFloat
    let ty: CGFloat

    init(_ transform: CGAffineTransform = .identity) {
        a = transform.a
        b = transform.b
        c = transform.c
        d = transform.d
        tx = transform.tx
        ty = transform.ty
    }
}

/// The portion of the effective menu-bar snapshot that can affect the
/// displayed bitmap. Fetch timestamps and other non-rendered metadata are
/// deliberately excluded so a periodic update with identical visible text
/// can reuse the existing frame set.
struct MenuBarBitmapAnimationSnapshotSignature: Equatable {
    let kind: String
    let provider: String
    let amount: Double?
    let unit: String?
    let message: String?
    let primaryText: String
    let secondaryText: String
    let selectedQuotaWindowKind: Int?
    let usesLunaReserve: Bool

    init(
        kind: String = "",
        provider: String = "",
        amount: Double? = nil,
        unit: String? = nil,
        message: String? = nil,
        primaryText: String = "",
        secondaryText: String = "",
        selectedQuotaWindowKind: Int? = nil,
        usesLunaReserve: Bool = false
    ) {
        self.kind = kind
        self.provider = provider
        self.amount = amount
        self.unit = unit
        self.message = message
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.selectedQuotaWindowKind = selectedQuotaWindowKind
        self.usesLunaReserve = usesLunaReserve
    }
}

/// Every input that can change a button-ready Codex animation frame belongs in
/// this signature. Keeping it as a value type makes the cache lifecycle
/// explicit and lets unchanged `update(...)` calls short-circuit before any
/// bitmap rendering work is performed.
struct MenuBarBitmapAnimationVisualSignature: Equatable {
    let primaryText: String
    let secondaryText: String
    let primaryFont: String
    let secondaryFont: String
    let contentFrame: NSRect
    let iconSlotFrame: NSRect
    let iconFrame: NSRect
    let textFrame: NSRect
    let contentBounds: NSRect
    let iconSlotBounds: NSRect
    let iconBounds: NSRect
    let textBounds: NSRect
    let contentTransform: MenuBarBitmapAnimationTransformSignature
    let iconSlotTransform: MenuBarBitmapAnimationTransformSignature
    let iconTransform: MenuBarBitmapAnimationTransformSignature
    let textTransform: MenuBarBitmapAnimationTransformSignature
    let bitmapBounds: NSRect
    let bitmapFrame: NSRect
    let buttonBounds: NSRect
    let placement: MenuBarBitmapImagePlacement
    let backingScale: CGFloat
    let iconVisible: Bool
    let textVisible: Bool
    let primaryVisible: Bool
    let secondaryVisible: Bool
    let sourceImageIdentity: ObjectIdentifier?
    let sourceImageSize: NSSize
    let sourceImageIsTemplate: Bool
    var sourceFrameIdentities: [ObjectIdentifier]
    let sourceProviderIdentity: String
    let activeClient: AssistantClient
    let effectiveSnapshot: MenuBarBitmapAnimationSnapshotSignature
    let appearance: String
    let iconOffsetX: CGFloat
    let iconOffsetY: CGFloat
    let amountOffsetX: CGFloat
    let amountOffsetY: CGFloat
    let horizontalPadding: CGFloat
    let widthAdjustment: CGFloat
    let showReset: Bool
    let buttonImagePosition: Int
    let buttonImageScaling: Int
    let iconViewImageScaling: Int
    let iconViewImageAlignment: Int

    init(
        primaryText: String = "",
        secondaryText: String = "",
        primaryFont: String = "",
        secondaryFont: String = "",
        contentFrame: NSRect = .zero,
        iconSlotFrame: NSRect = .zero,
        iconFrame: NSRect = .zero,
        textFrame: NSRect = .zero,
        contentBounds: NSRect = .zero,
        iconSlotBounds: NSRect = .zero,
        iconBounds: NSRect = .zero,
        textBounds: NSRect = .zero,
        contentTransform: MenuBarBitmapAnimationTransformSignature = .init(),
        iconSlotTransform: MenuBarBitmapAnimationTransformSignature = .init(),
        iconTransform: MenuBarBitmapAnimationTransformSignature = .init(),
        textTransform: MenuBarBitmapAnimationTransformSignature = .init(),
        bitmapBounds: NSRect = .zero,
        bitmapFrame: NSRect = .zero,
        buttonBounds: NSRect = .zero,
        placement: MenuBarBitmapImagePlacement = MenuBarBitmapImagePlacement(
            canonicalBounds: .zero,
            imageDestinationRect: .zero
        ),
        backingScale: CGFloat = 0,
        iconVisible: Bool = false,
        textVisible: Bool = false,
        primaryVisible: Bool = false,
        secondaryVisible: Bool = false,
        sourceImageIdentity: ObjectIdentifier? = nil,
        sourceImageSize: NSSize = .zero,
        sourceImageIsTemplate: Bool = false,
        sourceFrameIdentities: [ObjectIdentifier] = [],
        sourceProviderIdentity: String = "",
        activeClient: AssistantClient = .codex,
        effectiveSnapshot: MenuBarBitmapAnimationSnapshotSignature = .init(),
        appearance: String = "",
        iconOffsetX: CGFloat = 0,
        iconOffsetY: CGFloat = 0,
        amountOffsetX: CGFloat = 0,
        amountOffsetY: CGFloat = 0,
        horizontalPadding: CGFloat = 0,
        widthAdjustment: CGFloat = 0,
        showReset: Bool = false,
        buttonImagePosition: Int = 0,
        buttonImageScaling: Int = 0,
        iconViewImageScaling: Int = 0,
        iconViewImageAlignment: Int = 0
    ) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.primaryFont = primaryFont
        self.secondaryFont = secondaryFont
        self.contentFrame = contentFrame
        self.iconSlotFrame = iconSlotFrame
        self.iconFrame = iconFrame
        self.textFrame = textFrame
        self.contentBounds = contentBounds
        self.iconSlotBounds = iconSlotBounds
        self.iconBounds = iconBounds
        self.textBounds = textBounds
        self.contentTransform = contentTransform
        self.iconSlotTransform = iconSlotTransform
        self.iconTransform = iconTransform
        self.textTransform = textTransform
        self.bitmapBounds = bitmapBounds
        self.bitmapFrame = bitmapFrame
        self.buttonBounds = buttonBounds
        self.placement = placement
        self.backingScale = backingScale
        self.iconVisible = iconVisible
        self.textVisible = textVisible
        self.primaryVisible = primaryVisible
        self.secondaryVisible = secondaryVisible
        self.sourceImageIdentity = sourceImageIdentity
        self.sourceImageSize = sourceImageSize
        self.sourceImageIsTemplate = sourceImageIsTemplate
        self.sourceFrameIdentities = sourceFrameIdentities
        self.sourceProviderIdentity = sourceProviderIdentity
        self.activeClient = activeClient
        self.effectiveSnapshot = effectiveSnapshot
        self.appearance = appearance
        self.iconOffsetX = iconOffsetX
        self.iconOffsetY = iconOffsetY
        self.amountOffsetX = amountOffsetX
        self.amountOffsetY = amountOffsetY
        self.horizontalPadding = horizontalPadding
        self.widthAdjustment = widthAdjustment
        self.showReset = showReset
        self.buttonImagePosition = buttonImagePosition
        self.buttonImageScaling = buttonImageScaling
        self.iconViewImageScaling = iconViewImageScaling
        self.iconViewImageAlignment = iconViewImageAlignment
    }

    /// Source frame identities are animation-state inputs, not inputs to the
    /// one-time text/layout render. Keeping this comparison separate prevents
    /// a backend transition from causing a second full offscreen composition
    /// on the next ordinary update.
    func matchesStaticContent(of other: Self) -> Bool {
        var lhs = self
        var rhs = other
        lhs.sourceFrameIdentities = []
        rhs.sourceFrameIdentities = []
        return lhs == rhs
    }
}

/// Owns the finite set of complete button images for one visual state. The
/// cache has no timer and no semantic state; it only maps an animation source
/// frame identity to the already-composed final image.
struct MenuBarBitmapAnimationFrameCache {
    private(set) var images: [NSImage] = []
    private(set) var sourceFrameIdentities: [ObjectIdentifier] = []
    private(set) var signature: MenuBarBitmapAnimationVisualSignature?
    private(set) var rebuildCount = 0
    private(set) var compositionCount = 0

    var count: Int { images.count }

    func isValid(
        for signature: MenuBarBitmapAnimationVisualSignature,
        sourceFrames: [NSImage]
    ) -> Bool {
        self.signature == signature
            && images.count == sourceFrames.count
            && sourceFrameIdentities == sourceFrames.map(ObjectIdentifier.init)
    }

    func image(forSourceFrame sourceFrame: NSImage?) -> NSImage? {
        guard let sourceFrame,
              let index = sourceFrameIdentities.firstIndex(of: ObjectIdentifier(sourceFrame)) else {
            return nil
        }
        return images[index]
    }

    @discardableResult
    mutating func rebuildIfNeeded(
        signature: MenuBarBitmapAnimationVisualSignature,
        sourceFrames: [NSImage],
        compose: (NSImage) -> NSImage?
    ) -> Bool {
        guard !sourceFrames.isEmpty else {
            invalidate()
            return false
        }
        guard !isValid(for: signature, sourceFrames: sourceFrames) else {
            return true
        }

        var nextImages: [NSImage] = []
        nextImages.reserveCapacity(sourceFrames.count)
        for sourceFrame in sourceFrames {
            compositionCount += 1
            guard let image = compose(sourceFrame) else {
                invalidate()
                return false
            }
            nextImages.append(image)
        }
        images = nextImages
        sourceFrameIdentities = sourceFrames.map(ObjectIdentifier.init)
        self.signature = signature
        rebuildCount += 1
        return true
    }

    mutating func invalidate() {
        images.removeAll(keepingCapacity: false)
        sourceFrameIdentities.removeAll(keepingCapacity: false)
        signature = nil
    }
}

/// Holds one stable NSImage and a mutable bitmap representation for Codex
/// bitmap animation. Complete frames are materialized into raw pixel buffers
/// once per visual rebuild; animation ticks only copy one buffer into the
/// already-installed representation and request a redraw on the button. The
/// controller-facing rebuild path composes one frame at a time, so complete
/// `NSImage` frames are not retained alongside the raw buffers.
struct MenuBarStableBitmapAnimationFrameBuffer {
    private(set) var image: NSImage?
    private(set) var backing: NSBitmapImageRep?
    private(set) var signature: MenuBarBitmapAnimationVisualSignature?
    private(set) var sourceFrameIdentities: [ObjectIdentifier] = []
    private(set) var completeFrameIdentities: [ObjectIdentifier] = []
    private var framePixelBuffers: [Data] = []
    private(set) var rebuildCount = 0
    private(set) var compositionCount = 0
    private(set) var pixelCopyCount = 0

    var count: Int { framePixelBuffers.count }

    var backingPixelDataForTesting: Data? {
        guard let backing,
              let bitmapData = backing.bitmapData else {
            return nil
        }
        return Data(bytes: bitmapData, count: backing.bytesPerRow * backing.pixelsHigh)
    }

    func isValid(
        for signature: MenuBarBitmapAnimationVisualSignature,
        sourceFrames: [NSImage],
        completeFrames: [NSImage]
    ) -> Bool {
        self.signature == signature
            && image != nil
            && backing != nil
            && framePixelBuffers.count == sourceFrames.count
            && sourceFrameIdentities == sourceFrames.map(ObjectIdentifier.init)
            && completeFrameIdentities == completeFrames.map(ObjectIdentifier.init)
    }

    func isValid(
        for signature: MenuBarBitmapAnimationVisualSignature,
        sourceFrames: [NSImage]
    ) -> Bool {
        self.signature == signature
            && image != nil
            && backing != nil
            && framePixelBuffers.count == sourceFrames.count
            && sourceFrameIdentities == sourceFrames.map(ObjectIdentifier.init)
    }

    @discardableResult
    mutating func rebuildIfNeeded(
        signature: MenuBarBitmapAnimationVisualSignature,
        sourceFrames: [NSImage],
        completeFrames: [NSImage]
    ) -> Bool {
        guard !sourceFrames.isEmpty,
              sourceFrames.count == completeFrames.count,
              let firstFrame = completeFrames.first,
              firstFrame.size.width > 0,
              firstFrame.size.height > 0 else {
            invalidate()
            return false
        }
        guard !isValid(
            for: signature,
            sourceFrames: sourceFrames,
            completeFrames: completeFrames
        ) else {
            return true
        }

        let pixelDimensions = MenuBarBitmapImageLayout.pixelDimensions(
            for: firstFrame.size,
            scale: signature.backingScale
        )
        guard let nextBacking = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelDimensions.width,
            pixelsHigh: pixelDimensions.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            invalidate()
            return false
        }
        nextBacking.size = firstFrame.size

        var nextPixelBuffers: [Data] = []
        nextPixelBuffers.reserveCapacity(completeFrames.count)
        for frame in completeFrames {
            guard frame.size == firstFrame.size,
                  let bytes = Self.rasterize(frame, into: nextBacking) else {
                invalidate()
                return false
            }
            nextPixelBuffers.append(bytes)
        }

        let nextImage = NSImage(size: firstFrame.size)
        nextImage.addRepresentation(nextBacking)
        nextImage.isTemplate = true
        // The backing is intentionally mutated in place. Avoid an NSImage
        // offscreen cache that could continue presenting an old pixel copy.
        nextImage.cacheMode = .never

        image = nextImage
        backing = nextBacking
        self.signature = signature
        sourceFrameIdentities = sourceFrames.map(ObjectIdentifier.init)
        completeFrameIdentities = completeFrames.map(ObjectIdentifier.init)
        framePixelBuffers = nextPixelBuffers
        rebuildCount += 1
        return true
    }

    /// Rebuilds directly from the source frames without retaining the
    /// complete button images. The closure is invoked only during a visual
    /// invalidation and its result is rasterized before the next result is
    /// requested, keeping the long-lived representation to raw pixel buffers
    /// plus one stable image.
    @discardableResult
    mutating func rebuildIfNeeded(
        signature: MenuBarBitmapAnimationVisualSignature,
        sourceFrames: [NSImage],
        compose: (NSImage) -> NSImage?
    ) -> Bool {
        guard !sourceFrames.isEmpty else {
            invalidate()
            return false
        }
        guard !isValid(for: signature, sourceFrames: sourceFrames) else {
            return true
        }

        var nextBacking: NSBitmapImageRep?
        var nextPixelBuffers: [Data] = []
        nextPixelBuffers.reserveCapacity(sourceFrames.count)

        for sourceFrame in sourceFrames {
            compositionCount += 1
            guard let completeFrame = compose(sourceFrame),
                  completeFrame.size.width > 0,
                  completeFrame.size.height > 0 else {
                invalidate()
                return false
            }

            if nextBacking == nil {
                let pixelDimensions = MenuBarBitmapImageLayout.pixelDimensions(
                    for: completeFrame.size,
                    scale: signature.backingScale
                )
                guard let backing = Self.makeBacking(
                    pixelDimensions: pixelDimensions,
                    size: completeFrame.size
                ) else {
                    invalidate()
                    return false
                }
                nextBacking = backing
            }

            guard let backing = nextBacking,
                  completeFrame.size == backing.size,
                  let bytes = Self.rasterize(completeFrame, into: backing) else {
                invalidate()
                return false
            }
            nextPixelBuffers.append(bytes)
        }

        guard let nextBacking else {
            invalidate()
            return false
        }
        let firstFrameSize = nextBacking.size
        let nextImage = NSImage(size: firstFrameSize)
        nextImage.addRepresentation(nextBacking)
        nextImage.isTemplate = true
        // The backing is intentionally mutated in place. Avoid an NSImage
        // offscreen cache that could continue presenting an old pixel copy.
        nextImage.cacheMode = .never

        image = nextImage
        backing = nextBacking
        self.signature = signature
        sourceFrameIdentities = sourceFrames.map(ObjectIdentifier.init)
        completeFrameIdentities.removeAll(keepingCapacity: false)
        framePixelBuffers = nextPixelBuffers
        rebuildCount += 1
        return true
    }

    @discardableResult
    mutating func apply(frameIndex: Int) -> Bool {
        guard framePixelBuffers.indices.contains(frameIndex),
              let backing,
              let destination = backing.bitmapData else {
            return false
        }
        let source = framePixelBuffers[frameIndex]
        let byteCount = backing.bytesPerRow * backing.pixelsHigh
        guard byteCount > 0, source.count == byteCount else {
            return false
        }
        var didCopy = false
        source.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(destination, baseAddress, byteCount)
            didCopy = true
        }
        guard didCopy else { return false }
        pixelCopyCount += 1
        return true
    }

    mutating func invalidate() {
        image = nil
        backing = nil
        signature = nil
        sourceFrameIdentities.removeAll(keepingCapacity: false)
        completeFrameIdentities.removeAll(keepingCapacity: false)
        framePixelBuffers.removeAll(keepingCapacity: false)
    }

    private static func rasterize(
        _ image: NSImage,
        into backing: NSBitmapImageRep
    ) -> Data? {
        guard let bitmapData = backing.bitmapData,
              let context = NSGraphicsContext(bitmapImageRep: backing) else {
            return nil
        }
        let byteCount = backing.bytesPerRow * backing.pixelsHigh
        memset(bitmapData, 0, byteCount)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: backing.size),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: bitmapData, count: byteCount)
    }

    private static func makeBacking(
        pixelDimensions: (width: Int, height: Int),
        size: NSSize
    ) -> NSBitmapImageRep? {
        guard let backing = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelDimensions.width,
            pixelsHigh: pixelDimensions.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        backing.size = size
        return backing
    }
}

final class StatusItemController: NSObject, NSMenuDelegate {
    /// macOS renders status items whose button carries no image with a
    /// greyed-out, translucent appearance on displays that do not own
    /// keyboard focus. Assigning an empty image keeps the item on the
    /// standard image-backed rendering path so its inactive-display dimming
    /// matches the rest of the menu bar.
    static let placeholderButtonImage = NSImage()
    private static let statusItemVisibilityStabilityDelay: TimeInterval = 0.2
    private static let subscriptionFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    struct Actions {
        let manualRefresh: () -> Void
        let openDashboard: () -> Void
        let openChatGPT: () -> Void
        let openCCSwitch: () -> Void
        let quit: () -> Void
        let switchProvider: (String) -> Void
        let openProviderWebsite: () -> Void
        let openStatusLink: (URL) -> Void
        /// Opens the Mod explanation/manage panel from the menu prompt.
        let showModOnboarding: () -> Void
        let iconChanged: (NSImage?) -> Void
        let frameImageChanged: (NSImage?) -> Void
        let animationStateChanged: (Bool) -> Void
        let claudeAnimationStateChanged: (Bool, NSImage?, NSImage?) -> Void
        let grokAnimationStateChanged: (Bool, NSImage?, NSImage?) -> Void
        let animationFallbackChanged: (Bool) -> Void
        let visibilityChanged: (StatusItemVisibility) -> Void
        /// Date until which the visible official quota is rate-limited, read
        /// when the menu validates its items; nil when refresh is available.
        let manualRefreshBlockedUntil: () -> Date?
        /// Whether the visible official quota is paused on a rejected login (401);
        /// read when the menu validates its items.
        let isClaudeLoginExpired: () -> Bool

        init(
            manualRefresh: @escaping () -> Void,
            openDashboard: @escaping () -> Void,
            openChatGPT: @escaping () -> Void,
            openCCSwitch: @escaping () -> Void,
            quit: @escaping () -> Void,
            switchProvider: @escaping (String) -> Void,
            openProviderWebsite: @escaping () -> Void,
            openStatusLink: @escaping (URL) -> Void,
            iconChanged: @escaping (NSImage?) -> Void,
            frameImageChanged: @escaping (NSImage?) -> Void = { _ in },
            animationStateChanged: @escaping (Bool) -> Void = { _ in },
            claudeAnimationStateChanged: @escaping (Bool, NSImage?, NSImage?) -> Void = { _, _, _ in },
            grokAnimationStateChanged: @escaping (Bool, NSImage?, NSImage?) -> Void = { _, _, _ in },
            animationFallbackChanged: @escaping (Bool) -> Void = { _ in },
            visibilityChanged: @escaping (StatusItemVisibility) -> Void = { _ in },
            manualRefreshBlockedUntil: @escaping () -> Date? = { nil },
            isClaudeLoginExpired: @escaping () -> Bool = { false },
            showModOnboarding: @escaping () -> Void = {}
        ) {
            self.manualRefreshBlockedUntil = manualRefreshBlockedUntil
            self.isClaudeLoginExpired = isClaudeLoginExpired
            self.manualRefresh = manualRefresh
            self.openDashboard = openDashboard
            self.openChatGPT = openChatGPT
            self.openCCSwitch = openCCSwitch
            self.quit = quit
            self.switchProvider = switchProvider
            self.openProviderWebsite = openProviderWebsite
            self.openStatusLink = openStatusLink
            self.showModOnboarding = showModOnboarding
            self.iconChanged = iconChanged
            self.frameImageChanged = frameImageChanged
            self.animationStateChanged = animationStateChanged
            self.claudeAnimationStateChanged = claudeAnimationStateChanged
            self.grokAnimationStateChanged = grokAnimationStateChanged
            self.animationFallbackChanged = animationFallbackChanged
            self.visibilityChanged = visibilityChanged
        }
    }

    struct MenuBarSettings: Equatable {
        let showIcon: Bool
        let showAmount: Bool
        let showReset: Bool
        let iconDisplayMode: MenuBarIconDisplayMode
        let iconDisplayDelay: MenuBarIconDisplayDelay
        let rightClickAction: MenuBarRightClickAction
        let reverseMouseButtons: Bool
        let horizontalPadding: CGFloat
        let keepMenuOpenAfterRefresh: Bool
        let iconOffsetX: CGFloat
        let iconOffsetY: CGFloat
        let amountOffsetX: CGFloat
        let amountOffsetY: CGFloat
        var widthAdjustment: CGFloat
        let quotaWindowPreference: OfficialQuotaWindowPreference
        /// Shared logical AppKit point size for both official rows and the
        /// single-line third-party amount. The secondary row is derived from
        /// the default 13:10 ratio in the bitmap layout.
        var fontSize: CGFloat
        /// Logical point size for the client icon slot and redrawn mark.
        var iconSize: CGFloat
        let quotaResetDisplayMode: OfficialQuotaResetDisplayMode
        let autoSwitchLunaReserve: Bool
        let lunaReserveResetTimeMode: LunaReserveResetTimeMode
        let quotaProgressColorConfiguration: QuotaProgressColorConfiguration
        let showQuotaProgressBar: Bool
        let showQuotaPaceIndicator: Bool
        let showBankedReset: Bool
        let displayTimeZone: TimeZone

        init(
            showIcon: Bool,
            showAmount: Bool,
            showReset: Bool,
            horizontalPadding: CGFloat,
            keepMenuOpenAfterRefresh: Bool,
            iconDisplayMode: MenuBarIconDisplayMode = .defaultValue,
            iconDisplayDelay: MenuBarIconDisplayDelay = .defaultValue,
            rightClickAction: MenuBarRightClickAction = .defaultValue,
            reverseMouseButtons: Bool = false,
            iconOffsetX: CGFloat = 0,
            iconOffsetY: CGFloat = 0,
            amountOffsetX: CGFloat = 0,
            amountOffsetY: CGFloat = 0,
            widthAdjustment: CGFloat = 0,
            fontSize: CGFloat = MenuBarLayout.primaryFontPointSize,
            iconSize: CGFloat = MenuBarLayout.iconSlotWidth,
            quotaWindowPreference: OfficialQuotaWindowPreference = .defaultValue,
            quotaResetDisplayMode: OfficialQuotaResetDisplayMode = .defaultValue,
            autoSwitchLunaReserve: Bool = false,
            lunaReserveResetTimeMode: LunaReserveResetTimeMode = .defaultValue,
            quotaProgressColorConfiguration: QuotaProgressColorConfiguration = .default,
            showQuotaProgressBar: Bool = true,
            showQuotaPaceIndicator: Bool = true,
            showBankedReset: Bool = true,
            displayTimeZone: TimeZone = .autoupdatingCurrent
        ) {
            self.showIcon = showIcon
            self.showAmount = showAmount
            self.showReset = showReset
            self.iconDisplayMode = iconDisplayMode
            self.iconDisplayDelay = iconDisplayDelay
            self.rightClickAction = rightClickAction
            self.reverseMouseButtons = reverseMouseButtons
            self.horizontalPadding = horizontalPadding
            self.keepMenuOpenAfterRefresh = keepMenuOpenAfterRefresh
            self.iconOffsetX = iconOffsetX
            self.iconOffsetY = iconOffsetY
            self.amountOffsetX = amountOffsetX
            self.amountOffsetY = amountOffsetY
            self.widthAdjustment = widthAdjustment
            self.quotaWindowPreference = quotaWindowPreference
            self.quotaResetDisplayMode = quotaResetDisplayMode
            self.autoSwitchLunaReserve = autoSwitchLunaReserve
            self.lunaReserveResetTimeMode = lunaReserveResetTimeMode
            self.quotaProgressColorConfiguration = quotaProgressColorConfiguration.normalized()
            self.showQuotaProgressBar = showQuotaProgressBar
            self.showQuotaPaceIndicator = showQuotaPaceIndicator
            self.showBankedReset = showBankedReset
            self.displayTimeZone = displayTimeZone
            self.fontSize = CGFloat(
                AppPreferences.normalizedMenuBarFontSize(
                    Double(fontSize),
                    range: AppPreferences.menuBarFontSizeRange
                )
            )
            self.iconSize = MenuBarIconSizePreset.nearest(to: iconSize).pointSize
        }
    }

    struct MenuInput: Equatable {
        private let language: AppLanguage
        let aggregatedProviders: [AggregatedProviderDisplay]
        let aggregationQuickSwitchBlocked: Bool
        let quickSwitchSafety: CCSwitchQuickSwitchSafety
        let choices: [ProviderChoice]
        let quickSwitchSummaries: [String: String]
        let activeClient: AssistantClient
        let openAIAccount: OpenAIAccountPresentation?
        let statusLinks: [StatusLink]
        let showQuickSwitchMenu: Bool
        let showOpenChatGPTMenu: Bool
        let showOpenCCSwitchMenu: Bool
        let showStatusMenu: Bool
        let directProviderNotes: [String]
        let directProviderID: String?
        let directProviderIsOfficial: Bool
        let lunaReserveDisplayMode: LunaReserveDisplayMode
        let lunaReserveHideExhaustedQuota: Bool
        let bankedResetDisplayMode: CodexBankedResetDisplayMode
        let showsAvailableUpdateBadge: Bool
        /// The realtime-boost prompt row under the quota card.
        let modRow: ModMenuRow

        init(
            choices: [ProviderChoice],
            quickSwitchSummaries: [String: String],
            activeClient: AssistantClient,
            openAIAccount: OpenAIAccountPresentation?,
            statusLinks: [StatusLink],
            showQuickSwitchMenu: Bool,
            showOpenChatGPTMenu: Bool,
            showOpenCCSwitchMenu: Bool,
            showStatusMenu: Bool,
            directProviderNotes: [String] = [],
            directProviderID: String? = nil,
            directProviderIsOfficial: Bool = false,
            lunaReserveDisplayMode: LunaReserveDisplayMode = .defaultValue,
            lunaReserveHideExhaustedQuota: Bool = false,
            bankedResetDisplayMode: CodexBankedResetDisplayMode = .defaultValue,
            showsAvailableUpdateBadge: Bool = false,
            modRow: ModMenuRow = .none,
            aggregatedProviders: [AggregatedProviderDisplay] = [],
            aggregationQuickSwitchBlocked: Bool = false,
            quickSwitchSafety: CCSwitchQuickSwitchSafety? = nil
        ) {
            self.language = AppLanguage.resolved
            self.aggregatedProviders = aggregatedProviders
            self.quickSwitchSafety = quickSwitchSafety ?? (aggregationQuickSwitchBlocked ? .blockedAggregation : .allowedDirect)
            self.aggregationQuickSwitchBlocked = self.quickSwitchSafety.isBlocked
            self.choices = choices
            self.quickSwitchSummaries = quickSwitchSummaries
            self.activeClient = activeClient
            self.openAIAccount = openAIAccount
            self.statusLinks = statusLinks
            self.showQuickSwitchMenu = showQuickSwitchMenu
            self.showOpenChatGPTMenu = showOpenChatGPTMenu
            self.showOpenCCSwitchMenu = showOpenCCSwitchMenu
            self.showStatusMenu = showStatusMenu
            self.directProviderNotes = directProviderNotes
            self.directProviderID = directProviderID
            self.directProviderIsOfficial = directProviderIsOfficial
            self.lunaReserveDisplayMode = lunaReserveDisplayMode
            self.lunaReserveHideExhaustedQuota = lunaReserveHideExhaustedQuota
            self.bankedResetDisplayMode = bankedResetDisplayMode
            self.showsAvailableUpdateBadge = showsAvailableUpdateBadge
            self.modRow = modRow
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.aggregatedProviders == rhs.aggregatedProviders && lhs.language == rhs.language
                && lhs.quickSwitchSafety == rhs.quickSwitchSafety
                && lhs.choices.elementsEqual(rhs.choices) { left, right in
                    left.id == right.id
                        && left.name == right.name
                        && left.isCurrent == right.isCurrent
                }
                && lhs.quickSwitchSummaries == rhs.quickSwitchSummaries
                && lhs.activeClient.rawValue == rhs.activeClient.rawValue
                && lhs.openAIAccount == rhs.openAIAccount
                && lhs.statusLinks == rhs.statusLinks
                && lhs.showQuickSwitchMenu == rhs.showQuickSwitchMenu
                && lhs.showOpenChatGPTMenu == rhs.showOpenChatGPTMenu
                && lhs.showOpenCCSwitchMenu == rhs.showOpenCCSwitchMenu
                && lhs.showStatusMenu == rhs.showStatusMenu
                && lhs.directProviderNotes == rhs.directProviderNotes
                && lhs.directProviderID == rhs.directProviderID
                && lhs.directProviderIsOfficial == rhs.directProviderIsOfficial
                && lhs.lunaReserveDisplayMode == rhs.lunaReserveDisplayMode
                && lhs.lunaReserveHideExhaustedQuota == rhs.lunaReserveHideExhaustedQuota
                && lhs.bankedResetDisplayMode == rhs.bankedResetDisplayMode
                && lhs.showsAvailableUpdateBadge == rhs.showsAvailableUpdateBadge
                && lhs.modRow == rhs.modRow
        }
        func hasSameNativeItems(as other: Self) -> Bool {
            activeClient == other.activeClient
                && statusLinks == other.statusLinks && showQuickSwitchMenu == other.showQuickSwitchMenu
                && showOpenChatGPTMenu == other.showOpenChatGPTMenu && showOpenCCSwitchMenu == other.showOpenCCSwitchMenu
                && showStatusMenu == other.showStatusMenu && showsAvailableUpdateBadge == other.showsAvailableUpdateBadge
                && language == other.language && modRow == other.modRow
        }
    }

    private struct OverviewCardContext {
        let snapshot: Snapshot
        let identity: String
        let account: OpenAIAccountPresentation?
        let date: Date?
        var notes: String? = nil
        var noteTags: [String]? = nil
        /// Client that owns this card's quota prediction evidence.
        var paceClient: AssistantClient = .codex
    }
    private struct AggregationCard {
        let wrapper: NSView
        var card: NSView
        var snapshot: Snapshot
    }
    private var aggregationViewportShowsSingleCard = false
    private var closedMenuRebuildScheduled = false
    private var menuRebuildReason = "initial"
    private var aggregationViewport: NSScrollView?
    private var aggregationGrouping = AggregationWalletGrouping()
    private var aggregationOrder: [AggregationDisplayIdentity] = []
    private var aggregationOverviewDisplays: [AggregatedProviderDisplay] = []
    private(set) var aggregationPlacementCountForTesting = 0
    private var aggregationCards: [AggregationDisplayIdentity: AggregationCard] = [:]
    private var aggregationBoundsObserver: NSObjectProtocol?

    private var statusItem: NSStatusItem?
    private var statusMenu = NSMenu()
    private var retiringStatusMenus: [NSMenu] = []
    private var retiringStatusMenuObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var statusItemAttachmentCheckScheduled = false
    private var statusItemReanchorAttempts = 0
    private var isStatusMenuTracking = false
    private var statusMenuNeedsRebuild = false
    private var statusMenuNeedsNativeStructureRebuild = false
    private var menuDismissalTrace: MenuDismissalTrace?
    private var lastSeenOverviewNumerics: [OverviewNumericIdentity: OverviewNumericSample] = [:]
    private var presentedOverviewNumerics: [OverviewNumericSample] = []
    private var overviewMenuWasSeen = false
    private var overviewNumericOpenWorkItem: DispatchWorkItem?
    private var quotaPaceTimer: Timer?
    /// The account and client the current snapshot was fetched for. A menu-only
    /// update may reconcile cards with a stale snapshot; pace must not follow it.
    private var quotaPaceSnapshotAccount: OpenAIAccountPresentation?
    private var quotaPaceSnapshotClient: AssistantClient?
    var quotaPaceNowForTesting: Date?
    var quotaPaceTimerForTesting: Timer? { quotaPaceTimer }
    var overviewNumericReduceMotionForTesting: Bool?
    var bankedResetCountdownNowForTesting: Date?
    var bankedResetCountdownTimerForTesting: Timer? { bankedResetCountdownTimer }
    private var bankedResetCountdownTimer: Timer?
    var lastSeenOverviewNumericsForTesting: [OverviewNumericIdentity: OverviewNumericSample] {
        lastSeenOverviewNumerics
    }
    private var suppressLayoutFromSourceImageChange = false
    private var codexAnimationNeedsPostLayoutReconciliation = false
    private(set) var layoutStatusItemCallCountForTesting = 0
    private(set) var statusMenuRebuildCountForTesting = 0
    var statusMenuNeedsRebuildForTesting: Bool { statusMenuNeedsRebuild }
    var retiringStatusMenuCountForTesting: Int { retiringStatusMenus.count }
    var isStatusMenuDetachedForCustomClickForTesting: Bool { isStatusMenuDetachedForCustomClick }
    var statusItemMenuIsBoundForTesting: Bool { statusItem?.menu === statusMenu }
    func detachStatusMenuForCustomClickForTesting() { detachStatusMenuForCustomClick() }
    func restoreStatusMenuAfterCustomClickForTesting() { restoreStatusMenuAfterCustomClick() }
    private let menuBarIconView: RotatingTemplateImageView
    private let menuBarIconSlot = PassthroughView()
    private let menuBarTextStack = MenuBarTextView()
    private let menuBarContentStack = MenuBarContentView()
    /// The content view tree is kept offscreen as a layout/render engine while
    /// the button displays one template bitmap, so macOS 26's replicant
    /// machinery has no custom view hierarchy to re-snapshot.
    private let bitmapRenderContainer = MenuBarBitmapRenderView(
        frame: NSRect(x: 0, y: 0, width: 56, height: 22)
    )
    private var cachedMenuBarTextBitmap: NSImage?
    private var cachedStaticMenuBarContentBitmap: NSImage?
    private var cachedMenuBarContentVisualSignature: MenuBarBitmapAnimationVisualSignature?
    private var menuBarBitmapImagePlacement: MenuBarBitmapImagePlacement?
    private var cachedMenuBarIconDrawRect: NSRect?
    private var stableCodexAnimationFrameBuffer = MenuBarStableBitmapAnimationFrameBuffer()
    /// The backend currently running. `preferredCodexAnimationBackend` stays
    /// independent so a temporary efficient-mode fallback never overwrites
    /// the user's saved preference.
    private var codexAnimationBackend: MenuBarCodexAnimationBackend
    private var preferredCodexAnimationBackend: MenuBarCodexAnimationBackend
    private var animationFrameRate: Int
    private var codexAnimationFallbackActive = false
    private var nativeCodexAnimatedIconHost: MenuBarNativeAnimatedIconHostView?
    private var nativeCodexAnimationIsActive = false
    private var nativeCodexSourceIconMask: CAShapeLayer?
    private weak var nativeCodexSourceIconMaskOwnerButton: NSStatusBarButton?
    private var nativeCodexSourceIconPreviousMask: CALayer?
    private var claudeThinkingAnimatedIconHost: MenuBarClaudeAnimatedIconHostView?
    private var claudeThinkingAnimationIsActive = false
    private var grokThinkingAnimatedIconHost: MenuBarClaudeAnimatedIconHostView?
    private var grokThinkingAnimationIsActive = false
    private var grokThinkingStableFrameBuffer = MenuBarStableBitmapAnimationFrameBuffer()
    private var grokThinkingFrameTimer: Timer?
    private var grokThinkingFrameIndex = 0
    private var grokThinkingSourceFrames: [NSImage] = []
    /// Test-only seam for exercising the documented efficient-mode fallback;
    /// no product path enables it.
    private var forceNativeCodexAnimationFailureForTesting = false
    private(set) var stableCodexAnimationImageAssignmentCountForTesting = 0
    private(set) var stableCodexAnimationRedrawRequestCountForTesting = 0
    private let menuBarPrimaryLabel = PassthroughTextField(labelWithString: "…")
    private let menuBarSecondaryLabel = PassthroughTextField(labelWithString: "")
    private var isMenuBarContentStackConfigured = false
    private var codexIconImage: NSImage?
    private var claudeIconImage: NSImage?
    private var grokIconImage: NSImage?
    private var grokThinkingSpriteImage: NSImage?
    private var claudeThinkingSpriteImage: NSImage?
    private var snapshot = Snapshot.placeholder
    private var refreshDate: Date?
    private var menuInput = MenuInput(
        choices: [],
        quickSwitchSummaries: [:],
        activeClient: .codex,
        openAIAccount: nil,
        statusLinks: [],
        showQuickSwitchMenu: true,
        showOpenChatGPTMenu: true,
        showOpenCCSwitchMenu: true,
        showStatusMenu: true,
        showsAvailableUpdateBadge: false
    )
    private var settings = MenuBarSettings(
        showIcon: true,
        showAmount: true,
        showReset: true,
        horizontalPadding: 6,
        keepMenuOpenAfterRefresh: true
    )
    private var rightClickMonitor: Any?
    private var isRightClickPressActive = false
    private var isLeftClickPressActive = false
    private var clickStateGeneration = 0
    /// True while a reversed right-click is being delivered as a native
    /// left-click so AppKit can track the status menu. The local monitor
    /// must not treat that rewritten click as the configured left-click action.
    private var isPassingThroughRewrittenMenuClick = false
    /// Detach `statusItem.menu` for a custom click so a leftover press or
    /// `highlight(_:)` cannot start modal menu tracking and swallow the action.
    private var isStatusMenuDetachedForCustomClick = false
    /// Test hook: synthetic NSEvents have no status-item window.
    private var ignoreStatusItemHitTestForTesting = false
    private var activeClient: AssistantClient = .codex
    private var isCodexTaskRunning = false
    private var isClaudeTaskRunning = false
    private var isGrokTaskRunning = false
    private var animationEnabled = true
    private var lastMenuBarGeometry: MenuBarGeometry?
    private var lastMenuBarIconYOffset: CGFloat = 0
    private var lastMenuBarOfficialTextYOffset: CGFloat = 0
    private var lastMenuBarEffectiveSnapshot = Snapshot.placeholder
    private let actions: Actions
    private var lifecycleGeneration = 0
    private(set) var statusItemInstallCount = 0
    private(set) var statusItemVisibility: StatusItemVisibility = .unknown
    private var statusItemVisibilityStateMachine = StatusItemVisibilityStateMachine()
    private var menuBarIconDisplayStateMachine = MenuBarIconDisplayStateMachine()
    private weak var observedStatusItemWindow: NSWindow?
    private var statusItemWindowObservers: [NSObjectProtocol] = []
    private var screenParametersObserver: NSObjectProtocol?
    private var accessibilityDisplayOptionsObserver: NSObjectProtocol?

    var isVisible: Bool { statusItem?.isVisible ?? false }
    var iconImage: NSImage? { menuBarIconView.image }

    // Exposes the controller's current outer footprint for headless layout
    // tests without exposing the underlying NSStatusItem.
    var statusItemLengthForTesting: CGFloat? { statusItem?.length }

    // Live AppKit geometry used by the single-line regression tests. These
    // are the rendered primary ink and icon bounds, not the anti-clipping
    // label/frame allocation.
    var menuBarPrimaryInkBoundsForTesting: NSRect? {
        menuBarPrimaryInkBounds(in: menuBarContentCoordinateSpace)
    }

    var menuBarIconFrameForTesting: NSRect? {
        guard let space = menuBarContentCoordinateSpace else { return nil }
        return menuBarIconView.convert(menuBarIconView.bounds, to: space)
    }

    var menuBarButtonBoundsForTesting: NSRect? {
        statusItem?.button?.bounds
    }

    var menuBarPrimaryTextForTesting: String { menuBarPrimaryLabel.stringValue }

    var menuBarSecondaryTextForTesting: String { menuBarSecondaryLabel.stringValue }

    // Rendering-cache diagnostics keep the production seam read-only while
    // allowing focused tests to prove finite precomposition and stable-buffer
    // reuse. The legacy "cache" names remain as test compatibility aliases;
    // production state is owned by stableCodexAnimationFrameBuffer.
    var codexAnimationCacheFrameCountForTesting: Int {
        stableCodexAnimationFrameBuffer.count
    }

    var codexAnimationCacheBuildCountForTesting: Int {
        stableCodexAnimationFrameBuffer.rebuildCount
    }

    var codexAnimationFrameCompositionCountForTesting: Int {
        stableCodexAnimationFrameBuffer.compositionCount
    }

    var stableCodexAnimationImageForTesting: NSImage? {
        stableCodexAnimationFrameBuffer.image
    }

    var stableCodexAnimationFrameCountForTesting: Int {
        stableCodexAnimationFrameBuffer.count
    }

    var stableCodexAnimationRebuildCountForTesting: Int {
        stableCodexAnimationFrameBuffer.rebuildCount
    }

    var stableCodexAnimationPixelCopyCountForTesting: Int {
        stableCodexAnimationFrameBuffer.pixelCopyCount
    }

    var stableCodexAnimationBackingPixelDataForTesting: Data? {
        stableCodexAnimationFrameBuffer.backingPixelDataForTesting
    }

    var nativeCodexAnimationIsRotatingForTesting: Bool {
        menuBarIconView.isRotating
    }

    var stableCodexAnimationTimerForTesting: Timer? {
        menuBarIconView.rotationTimerForTesting
    }

    var menuBarSourceImageForTesting: NSImage? {
        menuBarIconView.sourceImageForRendering
    }

    var codexAnimationBackendForTesting: MenuBarCodexAnimationBackend {
        codexAnimationBackend
    }

    var nativeCodexAnimationHostForTesting: MenuBarNativeAnimatedIconHostView? {
        nativeCodexAnimatedIconHost
    }

    var nativeCodexSourceIconMaskForTesting: CAShapeLayer? {
        nativeCodexSourceIconMask
    }

    var claudeThinkingAnimationHostForTesting: MenuBarClaudeAnimatedIconHostView? {
        claudeThinkingAnimatedIconHost
    }

    var nativeCodexAnimationIsActiveForTesting: Bool {
        nativeCodexAnimationIsActive
    }

    var claudeThinkingAnimationIsActiveForTesting: Bool {
        claudeThinkingAnimationIsActive
    }

    var grokThinkingAnimationHostForTesting: MenuBarClaudeAnimatedIconHostView? {
        grokThinkingAnimatedIconHost
    }

    var grokThinkingAnimationIsActiveForTesting: Bool {
        grokThinkingAnimationIsActive
    }

    var grokThinkingStableImageForTesting: NSImage? {
        grokThinkingStableFrameBuffer.image
    }

    var grokThinkingStableFrameCountForTesting: Int {
        grokThinkingStableFrameBuffer.count
    }

    var preferredCodexAnimationBackendForTesting: MenuBarCodexAnimationBackend {
        preferredCodexAnimationBackend
    }

    var effectiveCodexAnimationBackendForTesting: MenuBarCodexAnimationBackend {
        codexAnimationBackend
    }

    var codexAnimationFallbackActiveForTesting: Bool {
        codexAnimationFallbackActive
    }

    var nativeCodexAnimationInstallCountForTesting: Int {
        nativeCodexAnimatedIconHost?.rotationAnimationInstallCount ?? 0
    }

    var nativeCodexAnimationContentsRasterizationCountForTesting: Int {
        nativeCodexAnimatedIconHost?.contentsRasterizationCount ?? 0
    }

    var menuBarButtonImageForTesting: NSImage? { statusItem?.button?.image }

    var cachedStaticMenuBarContentBitmapForTesting: NSImage? {
        cachedStaticMenuBarContentBitmap
    }

    var cachedMenuBarTextBitmapForTesting: NSImage? {
        cachedMenuBarTextBitmap
    }

    var menuBarContentIsOffscreenForTesting: Bool {
        guard let button = statusItem?.button else { return false }
        return menuBarContentStack.superview === bitmapRenderContainer
            && !button.subviews.contains { $0 === menuBarContentStack }
    }

    /// Supplies a deterministic source for controller-level bitmap cache tests;
    /// production always supplies the bundled Codex asset during setup.
    func setCodexIconForTesting(_ image: NSImage) {
        codexIconImage = image
        menuBarIconView.setSourceImage(
            image,
            prepareAnimationFrames: codexAnimationBackend != .nativeCoreAnimation
        )
    }

    func setGrokIconForTesting(_ image: NSImage) {
        setGrokIconsForTesting(idle: image, thinking: grokThinkingSpriteImage ?? image)
    }

    func setGrokIconsForTesting(idle: NSImage, thinking: NSImage) {
        grokIconImage = idle
        grokThinkingSpriteImage = thinking
        guard activeClient == .grok else { return }
        menuBarIconView.setSourceImage(idle, prepareAnimationFrames: false)
    }

    func advanceGrokThinkingFrameForTesting(_ frameIndex: Int) {
        guard codexAnimationBackend == .stableBitmap else { return }
        applyStableGrokThinkingFrame(frameIndex)
    }

    /// Supplies deterministic Claude assets for controller-level compositor
    /// tests without depending on the application bundle.
    func setClaudeAnimationAssetsForTesting(
        staticImage: NSImage,
        spriteImage: NSImage
    ) {
        claudeIconImage = staticImage
        claudeThinkingSpriteImage = spriteImage
        menuBarIconView.setSourceImage(staticImage, prepareAnimationFrames: false)
    }

    func advanceCodexAnimationFrameForTesting(_ frameIndex: Int) {
        guard codexAnimationBackend == .stableBitmap else { return }
        applyStableCodexAnimationFrame(frameIndex)
    }

    // Exposes the controller's actual menu for headless production-path tests.
    // The application still owns and renders this same NSMenu instance.
    var menuItemsForTesting: [NSMenuItem] { statusMenu.items }

    var menuBarIconSlotWidthForTesting: CGFloat? { lastMenuBarGeometry?.iconWidth }

    var menuBarIconImageSizeForTesting: NSSize? { menuBarIconView.image?.size }

    var menuBarIconSizeForTesting: CGFloat { settings.iconSize }

    var grokIdleIconSizeForTesting: NSSize? { grokIconImage?.size }

    var grokIdleIconImageForTesting: NSImage? { grokIconImage }

    var grokIdleIsVectorSVGForTesting: Bool {
        guard let image = grokIconImage else { return false }
        return GrokIdleIcon.isVectorSVGRepresentation(image)
    }

    var grokThinkingSpriteImageForTesting: NSImage? { grokThinkingSpriteImage }

    var grokThinkingSpriteSizeForTesting: NSSize? { grokThinkingSpriteImage?.size }

    var grokThinkingSpriteIsVectorSVGForTesting: Bool {
        guard let image = grokThinkingSpriteImage else { return false }
        return GrokThinkingSprite.isVectorSVGRepresentation(image)
    }

    var grokThinkingSpritePixelWidthForTesting: Int? {
        grokThinkingSpriteImage?
            .representations
            .compactMap { $0 as? NSBitmapImageRep }
            .map(\.pixelsWide)
            .max()
    }

    // Exposes the actual AppKit point sizes applied to the live menu-bar
    // labels without exposing the labels themselves.
    var menuBarFontPointSizesForTesting: (primary: CGFloat, secondary: CGFloat)? {
        guard let primary = menuBarPrimaryLabel.font?.pointSize,
              let secondary = menuBarSecondaryLabel.font?.pointSize else {
            return nil
        }
        return (primary, secondary)
    }

    // Exposes the live menu to tests that verify AppKit's deferred rebuild
    // behavior while the status menu is tracking.
    var statusMenuForTesting: NSMenu { statusMenu }

    var rightClickActionForTesting: MenuBarRightClickAction { settings.rightClickAction }

    var reverseMouseButtonsForTesting: Bool { settings.reverseMouseButtons }

    var areMouseButtonsReversedForTesting: Bool { areMouseButtonsReversed }

    private(set) var rightClickMenuPresentationCountForTesting = 0

    var statusItemButtonIsHighlightedForTesting: Bool {
        statusItem?.button?.isHighlighted ?? false
    }

    var isStatusMenuBoundForTesting: Bool {
        statusItem?.menu === statusMenu
    }

    func handleConfiguredRightClickForTesting() {
        performConfiguredRightClickAction()
    }

    func handleStatusItemRightMouseDownForTesting() {
        handleRightClickMouseDown()
    }

    func handleStatusItemRightMouseUpForTesting() {
        handleRightClickMouseUp()
    }

    func handleStatusItemLeftMouseDownForTesting() {
        handleLeftClickMouseDown()
    }

    func handleStatusItemLeftMouseUpForTesting() {
        handleLeftClickMouseUp()
    }

    func rewriteReversedRightClickEventForTesting(_ event: NSEvent) -> NSEvent? {
        guard areMouseButtonsReversed,
              event.type == .rightMouseDown || event.type == .rightMouseUp else {
            return nil
        }
        return rewrittenLeftMouseEvent(
            from: event,
            type: event.type == .rightMouseUp ? .leftMouseUp : .leftMouseDown
        )
    }

    func handleStatusItemEventForTesting(_ event: NSEvent) -> NSEvent? {
        ignoreStatusItemHitTestForTesting = true
        defer { ignoreStatusItemHitTestForTesting = false }
        return handlePotentialStatusItemClick(event)
    }

    func handleStatusItemControlClickMouseDownForTesting() {
        guard isCustomRightClickAction else { return }
        detachStatusMenuForCustomClick()
        cancelMenuBarTracking()
        handleRightClickMouseDown()
    }

    func handleStatusItemControlClickMouseUpForTesting() {
        handleRightClickMouseUp()
    }

    var startupDiagnostic: String {
        let statusWindow = statusItem?.button?.window
        return "status_visible=\(isVisible); menu_bound=\(statusItem?.menu === statusMenu); menu_items=\(statusMenu.items.count); button_window=\(statusWindow != nil)"
    }

    init(
        actions: Actions,
        codexAnimationBackend: MenuBarCodexAnimationBackend = .stableBitmap,
        animationFrameRate: Int = MenuBarAnimationTiming.defaultFrameRate,
        forceNativeCodexAnimationFailureForTesting: Bool = false
    ) {
        self.actions = actions
        self.preferredCodexAnimationBackend = codexAnimationBackend
        self.codexAnimationBackend = codexAnimationBackend
        self.animationFrameRate = MenuBarAnimationTiming.clampedFrameRate(animationFrameRate)
        self.forceNativeCodexAnimationFailureForTesting = forceNativeCodexAnimationFailureForTesting
        self.menuBarIconView = RotatingTemplateImageView(
            frame: .zero
        )
        super.init()
        menuBarIconView.setFrameRate(self.animationFrameRate)
        bitmapRenderContainer.onEffectiveAppearanceChanged = { [weak self] in
            self?.handleBitmapEffectiveAppearanceChanged()
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.statusItem != nil else { return }
            self.refreshBitmapContentAfterExternalVisualChange()
            self.scheduleStatusItemAttachmentCheck(
                reason: "screen-parameters",
                reanchor: false
            )
        }
        accessibilityDisplayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.statusItem != nil else { return }
            // Reduce Motion is a runtime animation policy. Reconcile it at
            // the notification boundary so an already-running timer cannot
            // outlive the user's accessibility preference.
            self.updateActivityIcon()
            let hosts = self.overviewCardHosts()
            hosts.forEach { $0.paceViews.forEach { $0.refreshMarkerAccessibility() } }
            MainActor.assumeIsolated {
                hosts.forEach {
                    $0.sectionFocus.refreshAccessibility()
                    $0.reconcilePeerBlur()
                }
            }
        }
    }

    deinit {
        quotaPaceTimer?.invalidate()
        if let aggregationBoundsObserver { NotificationCenter.default.removeObserver(aggregationBoundsObserver) }
        removeRightClickMonitor()
        removeStatusItemWindowObservation()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        if let accessibilityDisplayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                accessibilityDisplayOptionsObserver
            )
        }
    }

    private func handleBitmapEffectiveAppearanceChanged() {
        refreshBitmapContentAfterExternalVisualChange()
    }

    private func refreshBitmapContentAfterExternalVisualChange() {
        guard statusItem != nil else { return }
        invalidateBitmapContentCache()
        layoutStatusItem(for: snapshot)
    }

    func start(
        snapshot: Snapshot,
        refreshDate: Date?,
        menuInput: MenuInput,
        settings: MenuBarSettings
    ) {
        lifecycleGeneration += 1
        self.settings = settings
        if statusItem == nil {
            menuBarIconDisplayStateMachine.reset()
            menuBarIconDisplayStateMachine.setMode(
                settings.iconDisplayMode,
                codexTaskRunning: isCodexTaskRunning,
                at: Date()
            )
            menuBarIconDisplayStateMachine.setDisplayDelay(
                settings.iconDisplayDelay,
                at: Date()
            )
        }
        statusItemVisibilityStateMachine.reset()
        publishStatusItemVisibility()
        statusMenu.delegate = self
        if statusItem == nil {
            installStatusItem()
        }
        update(
            snapshot: snapshot,
            refreshDate: refreshDate,
            menuInput: menuInput,
            settings: settings
        )
    }

    func teardown() {
        clearAggregationOverview()
        lifecycleGeneration += 1
        removeStatusItemWindowObservation()
        deactivateNativeCodexAnimation()
        setCodexAnimationFallbackActive(false)
        codexAnimationBackend = preferredCodexAnimationBackend
        deactivateClaudeThinkingAnimation()
        deactivateGrokThinkingAnimation()
        statusItemVisibilityStateMachine.reset()
        menuBarIconDisplayStateMachine.reset()
        publishStatusItemVisibility()
        statusItemAttachmentCheckScheduled = false
        statusItemReanchorAttempts = 0
        statusMenuNeedsRebuild = false
        statusMenuNeedsNativeStructureRebuild = false
        retiringStatusMenuObservers.values.flatMap { $0 }.forEach(NotificationCenter.default.removeObserver)
        retiringStatusMenuObservers.removeAll()
        retiringStatusMenus.removeAll()
        isStatusMenuTracking = false
        overviewMenuWasSeen = false
        stopBankedResetCountdownTimer()
        stopQuotaPaceTracking()
        cancelPendingOverviewNumericTransitions()
        lastSeenOverviewNumerics = [:]
        presentedOverviewNumerics = []
        isRightClickPressActive = false
        rightClickMenuPresentationCountForTesting = 0
        codexAnimationNeedsPostLayoutReconciliation = false
        lastMenuBarGeometry = nil
        menuBarIconView.onSourceImageChanged = nil
        menuBarIconView.onFrameImageChanged = nil
        menuBarIconView.onAnimationFrameIndexChanged = nil
        menuBarIconView.stopRotating()
        invalidateBitmapContentCache()
        menuBarContentStack.removeFromSuperview()
        statusMenu.delegate = nil
        menuDismissalTrace?.record("menu.teardown.removeAllItems", view: statusMenu.items.first?.view)
        statusMenu.removeAllItems()
        removeRightClickMonitor()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func update(
        snapshot: Snapshot,
        refreshDate: Date?,
        menuInput: MenuInput,
        settings: MenuBarSettings,
        deferMenuRebuild: Bool = false
    ) {
        let clickBehaviorChanged = self.settings.rightClickAction != settings.rightClickAction
            || self.settings.reverseMouseButtons != settings.reverseMouseButtons
        let iconDisplayModeChanged = self.settings.iconDisplayMode != settings.iconDisplayMode
        let iconDisplayDelayChanged = self.settings.iconDisplayDelay != settings.iconDisplayDelay
        let taskIconVisibilityChanged = self.settings.showIcon != settings.showIcon
        let menuBarChanged = statusMenu.items.isEmpty || self.snapshot != snapshot || self.settings != settings
            || self.menuInput.activeClient != menuInput.activeClient
        let overviewChanged = statusMenu.items.isEmpty || self.snapshot != snapshot
            || self.menuInput != menuInput || self.settings != settings
        let nativeItemsChanged = !self.menuInput.hasSameNativeItems(as: menuInput)
        let iconSizeChanged = self.settings.iconSize != settings.iconSize
        self.snapshot = snapshot
        self.refreshDate = refreshDate
        self.menuInput = menuInput
        quotaPaceSnapshotAccount = menuInput.openAIAccount
        quotaPaceSnapshotClient = menuInput.activeClient
        aggregationOverviewDisplays = aggregationGrouping.cards(menuInput.aggregatedProviders)
        if clickBehaviorChanged {
            resetStatusItemClickState()
        }
        self.settings = settings
        if iconSizeChanged {
            loadMenuBarIconAssets(size: settings.iconSize)
        }
        if iconDisplayModeChanged {
            menuBarIconDisplayStateMachine.setMode(
                settings.iconDisplayMode,
                codexTaskRunning: isCodexTaskRunning,
                at: Date()
            )
        }
        if iconDisplayDelayChanged {
            menuBarIconDisplayStateMachine.setDisplayDelay(
                settings.iconDisplayDelay,
                at: Date()
            )
        }
        applyMenuBarIconDisplayPolicy()
        if menuBarChanged { layoutStatusItem(for: snapshot) }
        if taskIconVisibilityChanged || iconSizeChanged {
            // Reconcile the animation after the new content geometry is
            // established so turning off the parent task-icon switch stops
            // the active backend immediately, and so a size change redraws
            // idle marks and task sprites at the selected point size.
            updateActivityIcon()
        }
        if overviewChanged {
            rebuildOrDeferMenu(forceDefer: deferMenuRebuild, nativeItemsChanged: nativeItemsChanged)
            reconcileOverviewSectionsIfTracking()
            applyInPlaceOverviewNumericUpdatesIfTracking()
            syncBankedResetCountdownTimer()
        }
        refreshQuotaPaceViews()
        scheduleStatusItemAttachmentCheck(reason: "update", reanchor: false)
    }

    /// Applies one already-coalesced width value to the status item. The
    /// application owns the display-frame coalescer so the Dashboard preview
    /// and the real menu-bar card consume the same value on the same frame.
    func updateWidthAdjustment(_ widthAdjustment: CGFloat) {
        settings.widthAdjustment = widthAdjustment
        applyPendingWidthAdjustment(widthAdjustment)
    }

    /// Applies a discrete font-size change without rebuilding the status menu.
    /// The menu contents are independent of typography, so keeping this on the
    /// cached layout path avoids an unnecessary status-item redraw while the
    /// native Dashboard popup is closing.
    func updateFontSize(_ fontSize: CGFloat) {
        settings.fontSize = CGFloat(
            AppPreferences.normalizedMenuBarFontSize(
                Double(fontSize),
                range: AppPreferences.menuBarFontSizeRange
            )
        )
        layoutStatusItem(for: snapshot)
    }

    /// Applies a discrete icon-size change without rebuilding the status menu.
    /// Slot geometry and SVG/sprite output are both rebuilt at the selected
    /// point size so the mark is not a stretched 16 pt bitmap.
    func updateIconSize(_ iconSize: CGFloat) {
        let snapped = MenuBarIconSizePreset.nearest(to: iconSize).pointSize
        guard settings.iconSize != snapped else { return }
        settings.iconSize = snapped
        loadMenuBarIconAssets(size: snapped)
        invalidateBitmapContentCache()
        layoutStatusItem(for: snapshot)
        updateActivityIcon()
    }

    private func applyPendingWidthAdjustment(_ widthAdjustment: CGFloat) {
        guard let statusItem,
              let button = statusItem.button,
              let geometry = lastMenuBarGeometry else {
            return
        }

        let requestedLength: CGFloat
        if isSingleLineAmountMode(
            effectiveSnapshot: lastMenuBarEffectiveSnapshot,
            geometry: geometry
        ) {
            requestedLength = MenuBarLayout.singleLineStatusItemLength(
                primaryText: lastMenuBarEffectiveSnapshot.menuBarPrimary,
                showIcon: settings.showIcon,
                isBalance: lastMenuBarEffectiveSnapshot.kind == .balance,
                horizontalPadding: settings.horizontalPadding,
                widthAdjustment: widthAdjustment,
                iconSlotWidth: settings.iconSize
            )
        } else {
            requestedLength = MenuBarLayout.statusItemLength(
                contentWidth: geometry.contentWidth,
                horizontalPadding: settings.horizontalPadding,
                widthAdjustment: widthAdjustment
            )
        }
        guard requestedLength != statusItem.length else { return }
        MenuBarWidthPerformance.measure("statusItem.length") {
            statusItem.length = requestedLength
        }
        MenuBarWidthPerformance.measure("content-frames") {
            applyMenuBarContentFrames(
                button: button,
                buttonSize: NSSize(width: requestedLength, height: button.bounds.height),
                geometry: geometry,
                iconViewYOffset: lastMenuBarIconYOffset,
                effectiveSnapshot: lastMenuBarEffectiveSnapshot,
                officialTextYOffset: lastMenuBarOfficialTextYOffset
            )
        }
        refreshMenuBarContentBitmap()
    }

    func updateMenu(input: MenuInput, deferRebuild: Bool = false) {
        // The caller may still perform its periodic local-state read so the
        // database-watcher fallback remains intact. Reuse the current menu
        // hierarchy when that read produces the same semantic input.
        guard menuInput != input else { return }
        let nativeItemsChanged = !menuInput.hasSameNativeItems(as: input)
        let overviewUnchanged = menuInput.aggregatedProviders == input.aggregatedProviders
            && menuInput.directProviderNotes == input.directProviderNotes
            && menuInput.directProviderID == input.directProviderID
            && menuInput.directProviderIsOfficial == input.directProviderIsOfficial
            && menuInput.openAIAccount == input.openAIAccount
            && menuInput.lunaReserveDisplayMode == input.lunaReserveDisplayMode
            && menuInput.lunaReserveHideExhaustedQuota == input.lunaReserveHideExhaustedQuota
            && menuInput.bankedResetDisplayMode == input.bankedResetDisplayMode
        menuInput = input
        aggregationOverviewDisplays = aggregationGrouping.cards(input.aggregatedProviders)
        if !nativeItemsChanged && overviewUnchanged {
            guard menuQuickSwitchCanMutate else {
                rebuildOrDeferMenu(forceDefer: deferRebuild, nativeItemsChanged: false)
                refreshQuotaPaceViews()
                return
            }
            updateQuickSwitchContent()
            updateQuickSwitchProtection()
            refreshQuotaPaceViews()
            return
        }
        rebuildOrDeferMenu(forceDefer: deferRebuild, nativeItemsChanged: nativeItemsChanged)
        reconcileOverviewSectionsIfTracking()
        applyInPlaceOverviewNumericUpdatesIfTracking()
        syncBankedResetCountdownTimer()
        refreshQuotaPaceViews()
    }

    private func updateStatusItemVisibility(_ visibility: StatusItemVisibility) {
        guard statusItemVisibility != visibility else { return }
        statusItemVisibility = visibility
        actions.visibilityChanged(visibility)
    }

    /// Publishes the product of the independent AppKit space evidence and the
    /// user-selected runtime display policy. The space state machine itself
    /// remains unaware of the policy state; this is only a presentation-layer
    /// combination for the menu bar and Dashboard.
    private func publishStatusItemVisibility() {
        let isHiddenByMenuBarSpace =
            statusItemVisibilityStateMachine.visibility.isHiddenByMenuBarSpace
        let isHiddenByRuntimePolicy = !menuBarIconDisplayStateMachine.shouldDisplay
        let visibility: StatusItemVisibility
        switch (isHiddenByMenuBarSpace, isHiddenByRuntimePolicy) {
        case (true, true):
            visibility = .hiddenByMenuBarSpaceAndRuntimePolicy
        case (true, false):
            visibility = .hiddenByMenuBarSpace
        case (false, true):
            visibility = .hiddenByRuntimePolicy
        case (false, false):
            visibility = statusItemVisibilityStateMachine.visibility
        }
        updateStatusItemVisibility(visibility)
    }

    func updateActivity(
        activeClient: AssistantClient,
        codexTaskRunning: Bool,
        claudeTaskRunning: Bool,
        grokTaskRunning: Bool = false,
        animationEnabled: Bool,
        layout: Bool = true
    ) {
        let activeClientChanged = self.activeClient != activeClient
        let deferCodexAnimationActivation = activeClientChanged
            && activeClient == .codex
            && !layout
        self.activeClient = activeClient
        self.isCodexTaskRunning = codexTaskRunning
        self.isClaudeTaskRunning = claudeTaskRunning
        self.isGrokTaskRunning = grokTaskRunning
        self.animationEnabled = animationEnabled
        if activeClientChanged {
            stableCodexAnimationFrameBuffer.invalidate()
            if activeClient != .codex {
                codexAnimationNeedsPostLayoutReconciliation = false
            }
        }
        let previousSuppressLayout = suppressLayoutFromSourceImageChange
        if !layout {
            suppressLayoutFromSourceImageChange = true
        }
        if deferCodexAnimationActivation {
            // A cached client switch deliberately lays out after this activity
            // update. Replacing the semantic source invalidates the old
            // client's bitmap first, so neither Codex backend can safely
            // activate until that promised layout has rebuilt the cache.
            codexAnimationNeedsPostLayoutReconciliation = true
        }
        updateActivityIcon(deferCodexAnimationActivation: deferCodexAnimationActivation)
        if !layout {
            suppressLayoutFromSourceImageChange = previousSuppressLayout
        } else if activeClientChanged {
            // The source-image callback normally performs this layout. Keep a
            // direct refresh for missing optional assets so changing clients
            // can never leave a cache keyed to the previous client.
            layoutStatusItem(for: snapshot)
        }
        menuBarIconDisplayStateMachine.ingest(
            mode: settings.iconDisplayMode,
            displayDelay: settings.iconDisplayDelay,
            codexTaskRunning: codexTaskRunning,
            at: Date()
        )
        applyMenuBarIconDisplayPolicy()
    }

    /// Accepts a repeated Codex monitor sample without re-running the activity
    /// icon animation path. ActivityCoordinator remains the only producer of
    /// task state; this method only advances the display debounce.
    func observeCodexTaskSample(_ running: Bool, at date: Date = Date()) {
        isCodexTaskRunning = running
        menuBarIconDisplayStateMachine.ingest(
            mode: settings.iconDisplayMode,
            displayDelay: settings.iconDisplayDelay,
            codexTaskRunning: running,
            at: date
        )
        applyMenuBarIconDisplayPolicy()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        // A row clicked in the previous presentation can still think it is hovered.
        statusMenu.items.compactMap { $0.view as? ModPromptRowView }.forEach { $0.resetHoverState() }
        let previousView = statusMenu.items.first?.view
        let previousWindowVisible = previousView?.window?.isVisible == true
        let previousViewDismissing = previousView.map {
            descendantViews(of: $0, as: MenuHoverLinkHostView.self).contains { $0.isMenuDismissing }
        } ?? false
        menuDismissalTrace = MenuDismissalTrace.beginRound(menu: statusMenu)
        menuDismissalTrace?.host = statusMenu.items.first?.view as? MenuHoverLinkHostView
        menuDismissalTrace?.record("menu.willOpen", view: statusMenu.items.first?.view)
        if let view = statusMenu.items.first?.view {
            descendantViews(of: view, as: MenuHoverLinkHostView.self).forEach { $0.finishMenuDismissal(beforeOpening: true) }
        }
        let currentViewDismissing = statusMenu.items.first?.view.map {
            descendantViews(of: $0, as: MenuHoverLinkHostView.self).contains { $0.isMenuDismissing }
        } ?? false
        let canReplaceBeforeOpen = !previousWindowVisible && !currentViewDismissing
        // A direct card applies a pending rebuild before it is shown again. For
        // an aggregated menu, distinguish a card-only sync from a native menu
        // structure change: the former is complete once the mounted viewport
        // has been reconciled, while the latter still requires a real rebuild.
        if statusMenuNeedsRebuild, menuInput.aggregatedProviders.isEmpty {
            if !canReplaceBeforeOpen {
                menuDismissalTrace?.record("menu.rebuild.deferred", view: previousView,
                    details: "reason=nextOpen; direct_target_waiting_for_old_window; stale_dismissing=\(previousViewDismissing)")
            } else {
                rebuildStatusMenu(reason: "nextOpen")
            }
        } else if statusMenuNeedsRebuild {
            // menuWillOpen is the boundary for the next presentation. Apply a
            // top-level mode or native-structure change before tracking starts;
            // card-only changes can reuse the mounted viewport.
            let needsNativeStructure = statusMenuNeedsNativeStructureRebuild
            let topLevelView = statusMenu.items.first?.view
            let topLevelViewChanged = menuInput.aggregatedProviders.isEmpty
                ? !(topLevelView is MenuHoverLinkHostView)
                : !(topLevelView is AggregationOverviewScrollView)
            if (topLevelViewChanged || needsNativeStructure)
                && canReplaceBeforeOpen {
                rebuildStatusMenu(reason: "nextOpen")
                menuDismissalTrace?.record("menu.aggregation.rebuilt", view: statusMenu.items.first?.view,
                    details: "reason=nextOpen; top_level_changed=\(topLevelViewChanged); native_structure=\(needsNativeStructure)")
            } else if topLevelViewChanged || needsNativeStructure {
                statusMenuNeedsRebuild = true
                menuDismissalTrace?.record("menu.aggregation.sync-deferred", view: previousView,
                    details: "reason=nextOpen; old_window_visible=\(previousWindowVisible); old_view_dismissing=\(currentViewDismissing)")
            } else if !needsNativeStructure {
                if canReplaceBeforeOpen {
                    let view = makeAggregationOverview()
                    statusMenuNeedsRebuild = false
                    menuDismissalTrace?.record("menu.aggregation.synced", view: view,
                        details: "reason=nextOpen; pending_cleared=true")
                } else {
                    statusMenuNeedsRebuild = true
                    menuDismissalTrace?.record("menu.aggregation.sync-deferred", view: previousView,
                        details: "reason=nextOpen; content_sync_waiting_for_old_window=true")
                }
            } else {
                statusMenuNeedsRebuild = true
                menuDismissalTrace?.record("menu.aggregation.sync-deferred", view: previousView,
                    details: "reason=nextOpen; native_structure_pending=true")
            }
        }
        (statusMenu.items.first?.view as? MenuHoverLinkHostView)?.setDismissalTrace(menuDismissalTrace)
        isStatusMenuTracking = true
        statusMenu.items.first { $0.action == #selector(openChatGPT) }?.title = openCurrentAgentMenuTitle()
        logAggregationLifecycle(reason: "will-open")
        if let view = statusMenu.items.first?.view {
            descendantViews(of: view, as: MenuHoverLinkHostView.self).forEach { $0.setMenuContentVisible(true) }
            (view as? AggregationOverviewScrollView)?.setMenuContentVisible(true)
            view.layoutSubtreeIfNeeded()
            (view as? AggregationOverviewScrollView)?.logGeometry(reason: "will-open")
        }
        updateQuickSwitchContent()
        refreshQuotaPaceViews()
        overviewMenuWasSeen = true
        playPendingOverviewNumericTransitions()
        syncBankedResetCountdownTimer()
        refreshNativeCodexIconAppearance()
        refreshClaudeThinkingIconAppearance()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        resetStatusItemClickState()
        menuDismissalTrace?.record("menu.didClose", view: statusMenu.items.first?.view,
            details: "controller_tracking=\(isStatusMenuTracking); rebuild_pending=\(statusMenuNeedsRebuild)")
        if overviewMenuWasSeen {
            lastSeenOverviewNumerics = OverviewNumericTransition.commitSeenValues(
                presentedOverviewNumerics
            )
            overviewMenuWasSeen = false
        }
        releaseHiddenRetiringStatusMenus()
        isStatusMenuTracking = false
        if let view = statusMenu.items.first?.view {
            descendantViews(of: view, as: MenuHoverLinkHostView.self).forEach { $0.setMenuContentVisible(false) }
            (view as? AggregationOverviewScrollView)?.setMenuContentVisible(false)
        }
        stopBankedResetCountdownTimer()
        stopQuotaPaceTracking()
        cancelPendingOverviewNumericTransitions()
        refreshNativeCodexIconAppearance()
        refreshClaudeThinkingIconAppearance()
        logAggregationLifecycle(reason: "did-close")
        if statusMenuNeedsRebuild, statusMenu.items.first?.view?.window?.isVisible == true {
            rebuildStatusMenu(reason: "closed-next-session", replacingMenu: true)
        } else {
            scheduleClosedMenuRebuild()
        }
    }

    /// Keep the outgoing menu intact for AppKit's dismissal. A main-queue hop
    /// is not a window-hidden boundary, so the closed rebuild waits until the
    /// outgoing window has actually hidden; a reopen first takes over instead.
    private func scheduleClosedMenuRebuild(attempt: Int = 0) {
        guard statusMenuNeedsRebuild, !isStatusMenuTracking, !closedMenuRebuildScheduled else { return }
        closedMenuRebuildScheduled = true
        // Poll quickly at first, then back off; never give up while a rebuild
        // is pending, or an aggregated menu could keep stale content.
        let delay: TimeInterval = attempt == 0 ? 0 : (attempt <= 20 ? 0.1 : 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.closedMenuRebuildScheduled = false
            guard self.statusItem != nil, !self.isStatusMenuTracking, self.statusMenuNeedsRebuild else { return }
            guard self.statusMenu.items.first?.view?.window?.isVisible != true else {
                self.menuDismissalTrace?.record("menu.rebuild.closed.waiting", view: self.statusMenu.items.first?.view,
                    details: "attempt=\(attempt)")
                self.scheduleClosedMenuRebuild(attempt: attempt + 1)
                return
            }
            self.rebuildStatusMenu(reason: "closed")
        }
    }

    /// Applies the user's Codex animation-mode choice immediately. The
    /// selected backend is an effective runtime value; a failed efficient
    /// setup may temporarily replace it with the stable bitmap backend while
    /// `preferredCodexAnimationBackend` remains unchanged.
    func setCodexAnimationBackend(_ backend: MenuBarCodexAnimationBackend) {
        precondition(Thread.isMainThread, "Codex animation mode must be changed on the main thread")
        guard preferredCodexAnimationBackend != backend
            || codexAnimationBackend != backend
            || codexAnimationFallbackActive else {
            return
        }

        // Codex reads this setting as rotation G/D0. Grok reads the same
        // setting but plays its thinking sprite on those backends. Claude
        // keeps an independent animator.
        if activeClient.usesRotationAnimation {
            stopCodexAnimationImplementation()
        }
        if activeClient == .grok {
            deactivateGrokThinkingAnimation()
        }
        preferredCodexAnimationBackend = backend
        codexAnimationBackend = backend
        setCodexAnimationFallbackActive(false)
        if activeClient.usesRotationAnimation || activeClient == .grok {
            updateActivityIcon()
        }
    }

    /// Applies the shared runtime FPS immediately. 36 discrete states stay
    /// fixed; only the D0 timer interval, G CA duration, and Grok thinking
    /// cadence change. Claude is intentionally not retimed.
    func setAnimationFrameRate(_ fps: Int) {
        precondition(Thread.isMainThread, "Animation frame rate must be changed on the main thread")
        let clamped = MenuBarAnimationTiming.clampedFrameRate(fps)
        guard animationFrameRate != clamped else { return }
        animationFrameRate = clamped
        menuBarIconView.setFrameRate(clamped)
        nativeCodexAnimatedIconHost?.rotationDuration = MenuBarAnimationTiming.rotationDuration(
            fps: clamped
        )
        if let grokHost = grokThinkingAnimatedIconHost {
            grokHost.timing = .grok(frameRate: clamped)
        }
        restartGrokThinkingFrameTimerIfNeeded()
    }

    var animationFrameRateForTesting: Int { animationFrameRate }

    private func rebuildOrDeferMenu(forceDefer: Bool = false, nativeItemsChanged: Bool = true) {
        guard statusItem != nil else { return }
        if nativeItemsChanged { statusMenuNeedsNativeStructureRebuild = true }
        menuRebuildReason = nativeItemsChanged ? "native-structure" : "overview-content"
        let firstView = statusMenu.items.first?.view
        let host = firstView as? MenuHoverLinkHostView
        guard menuQuickSwitchCanMutate else {
            statusMenuNeedsRebuild = true
            menuDismissalTrace?.record("quick-switch.update.deferred", view: firstView,
                details: "tracking=\(isStatusMenuTracking); window_visible=\(firstView?.window?.isVisible ?? false); dismissing=\(outgoingMenuIsDismissing)")
            if firstView?.window?.isVisible == true, !isStatusMenuTracking {
                rebuildStatusMenu(reason: "quick-switch-next-session", replacingMenu: true)
            } else if firstView?.window?.isVisible != true {
                scheduleClosedMenuRebuild()
            }
            return
        }
        if !isStatusMenuTracking, outgoingMenuIsDismissing || firstView?.window?.isVisible == true {
            // Keep the outgoing menu immutable and prepare a separate next
            // presentation as soon as new data arrives during its dismissal.
            statusMenuNeedsRebuild = true
            menuDismissalTrace?.record("menu.rebuild.deferred", view: host,
                details: "controller_tracking=false; force=\(forceDefer)")
            if firstView?.window?.isVisible == true {
                rebuildStatusMenu(reason: "late-update-next-session", replacingMenu: true)
            } else {
                scheduleClosedMenuRebuild()
            }
            return
        }
        updateQuickSwitchContent()
        if !menuInput.aggregatedProviders.isEmpty, !statusMenu.items.isEmpty,
           isStatusMenuTracking || (!nativeItemsChanged && aggregationViewport != nil) {
            // Between app deactivation and menuDidClose the cards may already
            // be dismissing; leave them intact for the closed rebuild.
            if outgoingMenuIsDismissing {
                statusMenuNeedsRebuild = true
                menuDismissalTrace?.record("menu.rebuild.deferred", view: firstView,
                    details: "controller_tracking=\(isStatusMenuTracking); aggregated_dismissing=true")
                return
            }
            let view = makeAggregationOverview()
            if statusMenu.items.first?.view !== view {
                if isStatusMenuTracking { statusMenuNeedsRebuild = true; return }
                statusMenu.items.first?.view = view
            }
            updateQuickSwitchProtection()
            if nativeItemsChanged { statusMenuNeedsRebuild = true }
            return
        }
        if isStatusMenuTracking, aggregationViewport != nil {
            // Retain the mounted top-level viewport until tracking ends.
            if outgoingMenuIsDismissing {
                // The old aggregation cards are still owned by the outgoing
                // native menu. Do not detach them while their dismissal is in
                // flight; the closed rebuild will apply the mode transition.
                statusMenuNeedsRebuild = true
                menuDismissalTrace?.record("menu.rebuild.deferred", view: firstView,
                    details: "controller_tracking=true; aggregation_to_direct=true; aggregated_dismissing=true")
                scheduleClosedMenuRebuild()
                return
            }
            let viewport = aggregationViewport!
            aggregationCards.values.forEach { ($0.card as? MenuHoverLinkHostView)?.setMenuContentVisible(false) }
            aggregationCards.removeAll()
            aggregationOrder = []
            let card = makeOverviewMenuItem(for: snapshot).view!
            viewport.documentView = card
            aggregationViewportShowsSingleCard = true
            viewport.frame.size = card.frame.size
            (viewport as? AggregationOverviewScrollView)?.restoreViewport(distanceFromTop: 0)
            (card as? MenuHoverLinkHostView)?.setMenuContentVisible(true)
            updateQuickSwitchProtection()
            statusMenuNeedsRebuild = true
            return
        }
        if isStatusMenuTracking || forceDefer {
            statusMenuNeedsRebuild = true
            menuDismissalTrace?.record("menu.rebuild.deferred", view: host,
                details: "controller_tracking=\(isStatusMenuTracking); force=\(forceDefer)")
            scheduleClosedMenuRebuild()
        } else if nativeItemsChanged || statusMenu.items.isEmpty || aggregationViewport != nil || statusMenuNeedsRebuild {
            // A rebuild still pending from a tracked update must land here;
            // swapping only the card would leave the flag set and make the
            // next open discard the fresh card.
            rebuildStatusMenu(reason: "idleUpdate")
        } else if let first = statusMenu.items.first {
            first.view = makeOverviewMenuItem(for: snapshot).view
        }
    }

    private var menuContentCanMutate: Bool {
        guard let view = statusMenu.items.first?.view else { return !isStatusMenuTracking }
        if let host = view as? MenuHoverLinkHostView {
            return isStatusMenuTracking && host.isMenuContentVisible && !host.isMenuDismissing
        }
        if view is AggregationOverviewScrollView {
            let hosts = descendantViews(of: view, as: MenuHoverLinkHostView.self)
            return isStatusMenuTracking && hosts.allSatisfy { $0.isMenuContentVisible && !$0.isMenuDismissing }
        }
        return !isStatusMenuTracking && view.window?.isVisible != true
    }

    /// Native Quick Switch writes have a narrower gate than card content. A
    /// fully hidden idle menu is safe to update; a dismissing menu must remain
    /// unchanged until the next presentation, even before menuDidClose arrives.
    private var menuQuickSwitchCanMutate: Bool {
        if !isStatusMenuTracking, statusMenu.items.first?.view?.window?.isVisible != true,
           !overviewCardHosts().contains(where: { $0.outgoingMenuWindow?.isVisible == true }) {
            return true
        }
        return menuContentCanMutate
    }

    /// All tracking-time mutations share the same gate, including the gap
    /// between application deactivation and the native menu delegate callback.
    private func menuContentHostForUpdate(_ source: String) -> MenuHoverLinkHostView? {
        guard let host = statusMenu.items.first?.view as? MenuHoverLinkHostView else { return nil }
        guard isStatusMenuTracking, host.isMenuContentVisible, !host.isMenuDismissing else {
            if isStatusMenuTracking || host.isMenuDismissing || host.window?.isVisible == true {
                statusMenuNeedsRebuild = true
                menuDismissalTrace?.record("content.update.deferred", view: host, details: "source=\(source)")
            }
            return nil
        }
        menuDismissalTrace?.record("content.update", view: host, details: "source=\(source)")
        return host
    }

    /// Every overview card actually mounted in the menu. The provider list may
    /// already have changed, so a card that is leaving is found by the view
    /// hierarchy rather than by the latest displays.
    private func overviewCardHosts() -> [MenuHoverLinkHostView] {
        guard let view = statusMenu.items.first?.view else { return [] }
        return descendantViews(of: view, as: MenuHoverLinkHostView.self)
    }

    /// Any card of the outgoing menu is still dismissing; never mutate it.
    private var outgoingMenuIsDismissing: Bool {
        overviewCardHosts().contains { $0.isMenuDismissing }
    }

    /// Cards that may take a tracking-time mutation now, each with its own
    /// data context. Direct mode uses the shared host gate above; aggregated
    /// cards pass the same tracking/visibility/dismissal checks one by one.
    private func menuContentCardsForUpdate(_ source: String) -> [(host: MenuHoverLinkHostView, context: OverviewCardContext)] {
        if menuInput.aggregatedProviders.isEmpty {
            return menuContentHostForUpdate(source).map { [($0, directCardContext(for: snapshot))] } ?? []
        }
        var cards: [(host: MenuHoverLinkHostView, context: OverviewCardContext)] = []
        for display in aggregationOverviewDisplays {
            guard let host = aggregationCards[display.identity]?.card as? MenuHoverLinkHostView else { continue }
            guard isStatusMenuTracking, host.isMenuContentVisible, !host.isMenuDismissing else {
                if isStatusMenuTracking || host.isMenuDismissing || host.window?.isVisible == true {
                    statusMenuNeedsRebuild = true
                    menuDismissalTrace?.record("content.update.deferred", view: host,
                        details: "source=\(source); card=aggregated")
                }
                continue
            }
            cards.append((host, cardContext(display)))
        }
        return cards
    }

    private func refreshNativeCodexIconAppearance() {
        guard codexAnimationBackend == .nativeCoreAnimation,
              nativeCodexAnimationIsActive else { return }
        guard synchronizeNativeCodexAnimationHost() else {
            activateTemporaryStableBitmapFallback()
            return
        }
    }

    private func refreshClaudeThinkingIconAppearance() {
        guard claudeThinkingAnimationIsActive else { return }
        guard synchronizeClaudeThinkingAnimationHost() else {
            deactivateClaudeThinkingAnimation()
            restoreStaticMenuBarBitmap()
            return
        }
    }

    /// Reloads idle marks and thinking sprites at the selected point size.
    /// Grok idle is `GrokIdle.svg`; running Grok uses the 30-frame thinking pack.
    private func loadMenuBarIconAssets(size: CGFloat) {
        let iconSize = MenuBarIconSizePreset.nearest(to: size).pointSize
        let outputSize = NSSize(width: iconSize, height: iconSize)
        if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = outputSize
            icon.isTemplate = true
            codexIconImage = icon
        }
        if let iconURL = Bundle.main.url(forResource: "Claude", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = outputSize
            icon.isTemplate = true
            claudeIconImage = icon
            if let thinkingURL = Bundle.main.url(
                forResource: "ClaudeThinking",
                withExtension: "svg"
            ) {
                claudeThinkingSpriteImage = ClaudeThinkingSprite.make(
                    from: thinkingURL,
                    outputSize: outputSize
                )
            }
        }
        // Idle Grok is relocated Frame 16 (`GrokIdle.svg`), vector-loaded like
        // Codex/Claude. Do not redraw it into an `NSImage(size: slot)` bitmap.
        grokIconImage = nil
        if let idleURL = GrokIdleIcon.bundledSVGURL() {
            grokIconImage = GrokIdleIcon.make(
                fromSVG: idleURL,
                outputSize: outputSize
            )
        }
        if grokIconImage == nil {
            if let iconURL = Bundle.main.url(forResource: "Grok", withExtension: "svg"),
               let icon = NSImage(contentsOf: iconURL) {
                icon.size = outputSize
                icon.isTemplate = true
                grokIconImage = icon
            } else if let iconURL = Bundle.main.url(forResource: "Grok", withExtension: "png") {
                grokIconImage = GrokIdleIcon.make(
                    fromPNG: iconURL,
                    outputSize: outputSize
                )
            }
        }
        grokThinkingSpriteImage = nil
        if let thinkingDirectory = GrokThinkingSprite.bundledDirectoryURL() {
            grokThinkingSpriteImage = GrokThinkingSprite.make(
                fromDirectory: thinkingDirectory,
                outputSize: outputSize
            )
        }
        switch activeClient {
        case .codex:
            if let codexIconImage {
                menuBarIconView.setSourceImage(
                    codexIconImage,
                    prepareAnimationFrames: codexAnimationBackend != .nativeCoreAnimation
                )
            }
        case .claude:
            if let claudeIconImage {
                menuBarIconView.setSourceImage(
                    claudeIconImage,
                    prepareAnimationFrames: false
                )
            }
        case .grok:
            if let grokIconImage {
                menuBarIconView.setSourceImage(
                    grokIconImage,
                    prepareAnimationFrames: false
                )
            }
        }
    }

    private func configureStatusItem() {
        guard let statusItem, let button = statusItem.button else { return }
        statusItemVisibilityStateMachine.reset()
        publishStatusItemVisibility()
        statusItem.isVisible = menuBarIconDisplayStateMachine.shouldDisplay
        statusItem.length = 56
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = Self.placeholderButtonImage
        button.toolTip = "BalanceBar"

        loadMenuBarIconAssets(size: settings.iconSize)
        menuBarIconView.onSourceImageChanged = { [weak self] image in
            guard let self else { return }
            self.invalidateBitmapContentCache()
            if !self.suppressLayoutFromSourceImageChange {
                self.layoutStatusItem(for: self.snapshot)
            }
            self.actions.iconChanged(image)
        }
        menuBarIconView.onAnimationFrameIndexChanged = { [weak self] frameIndex in
            guard let self,
                  let frame = self.menuBarIconView.animationFrame(at: frameIndex) else {
                return
            }
            guard self.activeClient.usesRotationAnimation,
                  self.codexAnimationBackend == .stableBitmap else {
                return
            }
            self.applyStableCodexAnimationFrame(frameIndex)
            // Dashboard preview animation is a separate consumer. It
            // receives the icon-only frame without mutating the detached
            // real status-item image view.
            self.actions.frameImageChanged(frame)
        }
        menuBarIconView.onFrameImageChanged = { [weak self] image in
            guard let self else { return }
            self.actions.frameImageChanged(image)
        }
        actions.iconChanged(menuBarIconView.image)
        menuBarIconView.imageScaling = .scaleProportionallyDown
        menuBarIconView.contentTintColor = .labelColor
        applyMenuBarFonts()
        menuBarPrimaryLabel.textColor = .labelColor
        menuBarPrimaryLabel.lineBreakMode = .byClipping
        menuBarSecondaryLabel.textColor = .labelColor
        menuBarSecondaryLabel.lineBreakMode = .byClipping
        configureMenuBarContentStackIfNeeded()
        configureBitmapMenuBarContent()
        layoutStatusItem(for: snapshot)
        SwitchLog.write(
            "status item configured; visible=\(statusItem.isVisible); length=\(statusItem.length)",
            category: "ui.status-item"
        )
        let generation = lifecycleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.lifecycleGeneration == generation,
                  let statusItem = self.statusItem,
                  let button = statusItem.button else { return }
            let statusWindow = button.window
            let windowFrame = statusWindow.map { DashboardLogging.rect($0.frame) } ?? "none"
            let screenFrame = statusWindow?.screen.map { DashboardLogging.rect($0.frame) } ?? "none"
            SwitchLog.write(
                "status item presentation; visible=\(statusItem.isVisible); window_visible=\(statusWindow?.isVisible ?? false); window_occlusion_visible=\(statusWindow?.occlusionState.contains(.visible) ?? false); window_occlusion_raw=\(statusWindow?.occlusionState.rawValue ?? 0); button_window=\(statusWindow != nil); button_hidden=\(button.isHidden); image=\(button.image != nil); frame=\(DashboardLogging.rect(button.frame)); window_frame=\(windowFrame); screen_frame=\(screenFrame)",
                category: "ui.status-item"
            )
        }
        scheduleStatusItemAttachmentCheck(reason: "initial registration")
    }

    private func installStatusItem() {
        statusItemInstallCount += 1
        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        self.statusItem = statusItem
        statusItem.menu = statusMenu
        installRightClickMonitorIfNeeded()
        configureStatusItem()
    }

    private var areMouseButtonsReversed: Bool {
        settings.reverseMouseButtons && settings.rightClickAction != .matchLeftClick
    }

    private func installRightClickMonitorIfNeeded() {
        guard rightClickMonitor == nil else { return }
        // Right-click is always intercepted. Left-click is consumed when
        // reverse is on, or when Control is held and a custom right-click
        // action is set (Control-click is the keyboard equivalent of
        // right-click). Otherwise it keeps the normal NSStatusItem path,
        // including opening the menu on mouse-down.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handlePotentialStatusItemClick(event)
        }
    }

    private func removeRightClickMonitor() {
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
            self.rightClickMonitor = nil
        }
        resetStatusItemClickState()
    }

    private func resetStatusItemClickState() {
        clickStateGeneration += 1
        isRightClickPressActive = false
        isLeftClickPressActive = false
        isPassingThroughRewrittenMenuClick = false
        setStatusItemHighlighted(false)
        restoreStatusMenuAfterCustomClick()
    }

    private func handlePotentialStatusItemClick(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            if isPassingThroughRewrittenMenuClick { return event }
            if event.modifierFlags.contains(.control) {
                guard isEventInStatusItem(event) else { return event }
                if isCustomRightClickAction {
                    detachStatusMenuForCustomClick()
                    cancelMenuBarTracking()
                    isRightClickPressActive = true
                    let generation = lifecycleGeneration
                    let clickGeneration = clickStateGeneration
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              self.lifecycleGeneration == generation,
                              self.clickStateGeneration == clickGeneration else { return }
                        self.handleRightClickMouseDown()
                    }
                    return nil
                }
                return event
            }
            guard areMouseButtonsReversed, isEventInStatusItem(event) else { return event }
            detachStatusMenuForCustomClick()
            cancelMenuBarTracking()
            isLeftClickPressActive = true
            let generation = lifecycleGeneration
            let clickGeneration = clickStateGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.lifecycleGeneration == generation,
                      self.clickStateGeneration == clickGeneration else { return }
                self.handleLeftClickMouseDown()
            }
            return nil
        case .leftMouseUp:
            if isPassingThroughRewrittenMenuClick { return event }
            if isRightClickPressActive {
                isRightClickPressActive = false
                let generation = lifecycleGeneration
                let clickGeneration = clickStateGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.lifecycleGeneration == generation,
                          self.clickStateGeneration == clickGeneration else { return }
                    self.handleRightClickMouseUp()
                }
                return nil
            }
            guard isLeftClickPressActive else {
                if isCustomRightClickAction,
                   event.modifierFlags.contains(.control),
                   isEventInStatusItem(event) {
                    return nil
                }
                return event
            }
            isLeftClickPressActive = false
            let generation = lifecycleGeneration
            let clickGeneration = clickStateGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.lifecycleGeneration == generation,
                      self.clickStateGeneration == clickGeneration else { return }
                self.handleLeftClickMouseUp()
            }
            return nil
        case .rightMouseDown:
            guard isEventInStatusItem(event) else { return event }
            if areMouseButtonsReversed,
               let rewritten = rewrittenLeftMouseEvent(from: event, type: .leftMouseDown) {
                // Deliver a real left-click while the mouse is still down so
                // AppKit tracks the status menu. performClick after mouse-up
                // flashes and can highlight Window when the dashboard is key.
                isPassingThroughRewrittenMenuClick = true
                return rewritten
            }
            if settings.rightClickAction != .matchLeftClick {
                detachStatusMenuForCustomClick()
                cancelMenuBarTracking()
            }
            isRightClickPressActive = true
            let generation = lifecycleGeneration
            let clickGeneration = clickStateGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.lifecycleGeneration == generation,
                      self.clickStateGeneration == clickGeneration else { return }
                self.handleRightClickMouseDown()
            }
            return nil
        case .rightMouseUp:
            if isPassingThroughRewrittenMenuClick {
                isPassingThroughRewrittenMenuClick = false
                return rewrittenLeftMouseEvent(from: event, type: .leftMouseUp) ?? event
            }
            if isRightClickPressActive {
                isRightClickPressActive = false
                let generation = lifecycleGeneration
                let clickGeneration = clickStateGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.lifecycleGeneration == generation,
                          self.clickStateGeneration == clickGeneration else { return }
                    self.handleRightClickMouseUp()
                }
                return nil
            }
            // An unpaired up must not reach AppKit: with `statusItem.menu`
            // assigned, a leaked right-click can open the status menu instead
            // of the configured action, especially on rapid clicks.
            if isCustomRightClickAction, isEventInStatusItem(event) {
                return nil
            }
            return event
        default:
            return event
        }
    }

    private func rewrittenLeftMouseEvent(
        from event: NSEvent,
        type: NSEvent.EventType
    ) -> NSEvent? {
        if let copy = event.cgEvent?.copy() {
            copy.type = type == .leftMouseDown ? .leftMouseDown : .leftMouseUp
            copy.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            return NSEvent(cgEvent: copy)
        }
        return NSEvent.mouseEvent(
            with: type,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        )
    }

    private func isEventInStatusItem(_ event: NSEvent) -> Bool {
        if ignoreStatusItemHitTestForTesting { return true }
        guard let button = statusItem?.button else { return false }
        // Each status item has its own window. Use the window, not button
        // bounds: highlight and layout can shrink the hit box for a frame
        // and leak a rapid click through to AppKit's status menu.
        return event.window === button.window
    }

    private var isCustomRightClickAction: Bool {
        !areMouseButtonsReversed && settings.rightClickAction != .matchLeftClick
    }

    private func detachStatusMenuForCustomClick() {
        guard !isStatusMenuDetachedForCustomClick else { return }
        statusItem?.menu = nil
        isStatusMenuDetachedForCustomClick = true
        cancelMenuBarTracking()
    }

    private func restoreStatusMenuAfterCustomClick() {
        guard isStatusMenuDetachedForCustomClick else { return }
        statusItem?.menu = statusMenu
        isStatusMenuDetachedForCustomClick = false
    }

    private func handleLeftClickMouseDown() {
        guard areMouseButtonsReversed else { return }
        detachStatusMenuForCustomClick()
        setStatusItemHighlighted(true)
    }

    private func handleLeftClickMouseUp() {
        setStatusItemHighlighted(false)
        if areMouseButtonsReversed {
            performConfiguredAction(settings.rightClickAction)
            return
        }
        restoreStatusMenuAfterCustomClick()
    }

    private func handleRightClickMouseDown() {
        if areMouseButtonsReversed || settings.rightClickAction == .matchLeftClick {
            restoreStatusMenuAfterCustomClick()
            presentStatusItemMenuFromRightClick()
            return
        }
        detachStatusMenuForCustomClick()
        setStatusItemHighlighted(true)
    }

    private func handleRightClickMouseUp() {
        guard !areMouseButtonsReversed, settings.rightClickAction != .matchLeftClick else {
            restoreStatusMenuAfterCustomClick()
            return
        }
        setStatusItemHighlighted(false)
        performConfiguredAction(settings.rightClickAction)
    }

    private func presentStatusItemMenuFromRightClick() {
        rightClickMenuPresentationCountForTesting += 1
        // performClick is the supported left-click path: it draws the status
        // item highlight and opens `statusItem.menu`. popUpMenu(_:) is
        // deprecated and skips that highlight. Skip the AppKit click during
        // XCTest; menu tracking is modal and would stall the suite.
        guard !AutomatedTestHost.isRunning else { return }
        statusItem?.button?.performClick(nil)
    }

    private func setStatusItemHighlighted(_ highlighted: Bool) {
        statusItem?.button?.highlight(highlighted)
    }

    private func performConfiguredRightClickAction() {
        performConfiguredAction(settings.rightClickAction)
    }

    private func performConfiguredAction(_ action: MenuBarRightClickAction) {
        switch action {
        case .matchLeftClick:
            break
        case .openMainWindow:
            openMainWindowFromRightClick()
        case .openAgent:
            openExternalAppFromStatusItemClick(actions.openChatGPT)
        case .openCCSwitch:
            openExternalAppFromStatusItemClick(actions.openCCSwitch)
        }
    }

    private func openMainWindowFromRightClick() {
        cancelMenuBarTracking()
        if AutomatedTestHost.isRunning {
            actions.openDashboard()
            restoreStatusMenuAfterCustomClick()
            return
        }
        // The right-click was swallowed so AppKit would not track the status
        // menu. Wait one more turn after mouse-up so becoming a regular app
        // cannot treat that leftover menu-bar click as selecting Window.
        // Keep the status menu detached until that leftover is gone, otherwise
        // a rapid second click opens the menu and modal tracking blocks this.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cancelMenuBarTracking()
            self.actions.openDashboard()
            DispatchQueue.main.async { [weak self] in
                self?.cancelMenuBarTracking()
                self?.restoreStatusMenuAfterCustomClick()
            }
        }
    }

    /// Activating another app in the same turn as a swallowed status-item
    /// click lets that leftover menu-bar press select the new app's Window
    /// menu. Wait until the mouse is up, then one extra teardown delay.
    private func openExternalAppFromStatusItemClick(_ open: @escaping () -> Void) {
        cancelMenuBarTracking()
        if AutomatedTestHost.isRunning {
            open()
            restoreStatusMenuAfterCustomClick()
            return
        }
        let generation = lifecycleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.cancelMenuBarTracking()
            self.scheduleExternalAppOpenAfterClickSettles(
                generation: generation,
                open: open
            )
        }
    }

    private func scheduleExternalAppOpenAfterClickSettles(
        generation: Int,
        open: @escaping () -> Void
    ) {
        if NSEvent.pressedMouseButtons != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.scheduleExternalAppOpenAfterClickSettles(
                    generation: generation,
                    open: open
                )
            }
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CurrentAgentApplicationActivator.menuTeardownDelay
        ) { [weak self] in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.cancelMenuBarTracking()
            open()
            self.restoreStatusMenuAfterCustomClick()
        }
    }

    private func cancelMenuBarTracking() {
        statusMenu.cancelTracking()
        NSApp.mainMenu?.cancelTracking()
        NSApp.windowsMenu?.cancelTracking()
    }

    private func scheduleStatusItemAttachmentCheck(
        reason: String,
        reanchor: Bool = true,
        delay: TimeInterval = 0.2
    ) {
        guard !statusItemAttachmentCheckScheduled else { return }
        statusItemAttachmentCheckScheduled = true
        let generation = lifecycleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.statusItemAttachmentCheckScheduled = false
            self.verifyStatusItemAttachment(reason: reason, reanchor: reanchor)
        }
    }

    private func observeStatusItemWindow(_ window: NSWindow?) {
        guard observedStatusItemWindow !== window else { return }
        removeStatusItemWindowObservation()
        guard let window else { return }

        observedStatusItemWindow = window
        let notifications: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification
        ]
        statusItemWindowObservers = notifications.map { notificationName in
            NotificationCenter.default.addObserver(
                forName: notificationName,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.statusItem != nil else { return }
                if notificationName == NSWindow.didChangeBackingPropertiesNotification {
                    // The raw bitmap dimensions and color-space-sensitive
                    // backing must be rebuilt once at this public lifecycle
                    // boundary. This is not a timer/polling path.
                    self.refreshBitmapContentAfterExternalVisualChange()
                }
                self.scheduleStatusItemAttachmentCheck(
                    reason: "window-\(notificationName.rawValue)",
                    reanchor: false
                )
            }
        }
    }

    private func removeStatusItemWindowObservation() {
        for observer in statusItemWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        statusItemWindowObservers.removeAll()
        observedStatusItemWindow = nil
    }

    private func updateStatusItemVisibility(
        with evidence: StatusItemVisibilityEvidence,
        reason: String
    ) {
        _ = statusItemVisibilityStateMachine.ingest(
            evidence,
            at: Date()
        )
        publishStatusItemVisibility()
        guard statusItemVisibilityStateMachine.needsAdditionalHiddenSample else {
            return
        }
        scheduleStatusItemAttachmentCheck(
            reason: "visibility-stability-(reason)",
            reanchor: false,
            delay: Self.statusItemVisibilityStabilityDelay
        )
    }

    private func verifyStatusItemAttachment(reason: String, reanchor: Bool) {
        guard let item = statusItem else {
            statusItemVisibilityStateMachine.reset()
            publishStatusItemVisibility()
            SwitchLog.write(
                "status item attachment failed; reason=missing item",
                level: .error,
                category: "ui.status-item"
            )
            return
        }

        guard menuBarIconDisplayStateMachine.shouldDisplay else {
            // An intentionally hidden status item must not be fed into the
            // AppKit space detector as false visibility evidence. Retain the
            // last confirmed space state so it can coexist with this policy
            // state and be re-evaluated when the item is shown again.
            statusItemReanchorAttempts = 0
            publishStatusItemVisibility()
            return
        }

        guard let button = item.button else {
            statusItemVisibilityStateMachine.reset()
            publishStatusItemVisibility()
            SwitchLog.write(
                "status item attachment failed; reason=missing button",
                level: .error,
                category: "ui.status-item"
            )
            return
        }

        let window = button.window
        observeStatusItemWindow(window)
        let windowFrame = window.map { DashboardLogging.rect($0.frame) } ?? "none"
        let screen = window?.screen
        let screenFrame = screen.map { DashboardLogging.rect($0.frame) } ?? "none"
        let statusItemFrame = window.map {
            $0.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let windowIsOcclusionVisible = window?.occlusionState.contains(.visible) ?? false
        updateStatusItemVisibility(
            with: StatusItemVisibilityEvidence(
                statusItemIsVisible: item.isVisible,
                windowIsVisible: window?.isVisible ?? false,
                windowIsOcclusionVisible: windowIsOcclusionVisible,
                statusItemIdentity: ObjectIdentifier(item),
                windowIdentity: window.map(ObjectIdentifier.init),
                buttonIdentity: ObjectIdentifier(button),
                statusItemFrame: statusItemFrame,
                statusItemWindowFrame: window?.frame,
                screenFrame: screen?.frame,
                buttonIsHidden: button.isHidden
            ),
            reason: reason
        )
        let attached = window.map { window in
            guard let screen else { return false }
            let frame = window.frame
            let screenFrame = screen.frame
            return window.isVisible
                && frame.minX >= screenFrame.minX
                && frame.maxX <= screenFrame.maxX
                && frame.maxY >= screenFrame.maxY - 4
                && frame.minY >= screenFrame.maxY - 48
        } ?? false

        SwitchLog.write(
            "status item attachment checked; reason=\(reason); attached=\(attached); visible=\(item.isVisible); window_visible=\(window?.isVisible ?? false); window_occlusion_visible=\(windowIsOcclusionVisible); window_occlusion_raw=\(window?.occlusionState.rawValue ?? 0); button_hidden=\(button.isHidden); visibility=\(statusItemVisibility); hidden_candidate_samples=\(statusItemVisibilityStateMachine.hiddenCandidateSampleCount); status_item_frame=\(statusItemFrame.map { DashboardLogging.rect($0) } ?? "none"); window_frame=\(windowFrame); screen_frame=\(screenFrame); length=\(item.length)",
            level: attached ? .debug : .warning,
            category: "ui.status-item",
            throttleKey: "status-item-attachment-\(reason)",
            minimumInterval: 0.5
        )

        guard !attached else {
            statusItemReanchorAttempts = 0
            return
        }
        guard reanchor else { return }
        guard statusItemReanchorAttempts < 3 else {
            SwitchLog.write(
                "status item attachment unresolved after retries; reason=\(reason); window_frame=\(windowFrame); screen_frame=\(screenFrame)",
                level: .error,
                category: "ui.status-item"
            )
            return
        }

        statusItemReanchorAttempts += 1
        let desiredLength = max(CGFloat(30), item.length)
        // Keep an active native-CA host's layer animation alive while AppKit
        // replaces the source status item.  The retained host is reattached
        // by the next layout boundary, preserving its layer-local phase.
        detachNativeCodexAnimationHostForStatusItemReplacement()
        detachClaudeThinkingAnimationHostForStatusItemReplacement()
        detachGrokThinkingAnimationHostForStatusItemReplacement()
        removeStatusItemWindowObservation()
        NSStatusBar.system.removeStatusItem(item)
        let replacement = NSStatusBar.system.statusItem(withLength: desiredLength)
        statusItem = replacement
        replacement.menu = statusMenu
        configureStatusItem()
        scheduleStatusItemAttachmentCheck(reason: "re-registered-\(statusItemReanchorAttempts)-\(reason)")
    }

    private func updateActivityIcon(deferCodexAnimationActivation: Bool = false) {
        switch activeClient {
        case .codex:
            deactivateClaudeThinkingAnimation()
            deactivateGrokThinkingAnimation()
            ensureRotationSourceImage()
            let shouldAnimate = MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: isRotationTaskRunning,
                preferenceEnabled: animationEnabled,
                reduceMotionEnabled: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )

            guard shouldAnimate, settings.showIcon else {
                stopCodexAnimationImplementation()
                codexAnimationBackend = preferredCodexAnimationBackend
                setCodexAnimationFallbackActive(false)
                return
            }

            if deferCodexAnimationActivation {
                // Keep the previous backend fully stopped while the cached
                // client render establishes Codex-owned bitmap geometry. The
                // layout boundary below will activate exactly one selected
                // backend from a valid cache instead of treating the expected
                // cache miss as a G failure or a D0 start failure.
                stopCodexAnimationImplementation()
                codexAnimationBackend = preferredCodexAnimationBackend
                setCodexAnimationFallbackActive(false)
                return
            }

            switch codexAnimationBackend {
            case .nativeCoreAnimation:
                menuBarIconView.stopRotating()
                guard synchronizeNativeCodexAnimationHost() else {
                    activateTemporaryStableBitmapFallback()
                    return
                }
            case .stableBitmap:
                deactivateNativeCodexAnimation()
                if let rotationSourceImage {
                    menuBarIconView.setSourceImage(
                        rotationSourceImage,
                        prepareAnimationFrames: true
                    )
                }
                if !menuBarIconView.isRotating {
                    guard installStableCodexAnimationImage(at: 0) else {
                        menuBarIconView.stopRotating()
                        restoreStaticMenuBarBitmap()
                        return
                    }
                } else if !ensureStableCodexAnimationFrameBuffer() {
                    menuBarIconView.stopRotating()
                    restoreStaticMenuBarBitmap()
                    return
                }
                menuBarIconView.startRotating()
            }
        case .grok:
            stopCodexAnimationImplementation()
            deactivateClaudeThinkingAnimation()
            codexAnimationBackend = preferredCodexAnimationBackend
            setCodexAnimationFallbackActive(false)
            if let grokIconImage,
               menuBarIconView.sourceImageForRendering !== grokIconImage {
                menuBarIconView.setSourceImage(
                    grokIconImage,
                    prepareAnimationFrames: false
                )
            }
            if MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: isGrokTaskRunning,
                preferenceEnabled: animationEnabled,
                reduceMotionEnabled: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ) {
                switch codexAnimationBackend {
                case .nativeCoreAnimation:
                    stopGrokThinkingStableBitmap()
                    guard synchronizeGrokThinkingAnimationHost() else {
                        deactivateGrokThinkingAnimation()
                        restoreStaticMenuBarBitmap()
                        return
                    }
                case .stableBitmap:
                    deactivateGrokThinkingAnimationHost()
                    guard installStableGrokThinkingImage(at: grokThinkingFrameIndex) else {
                        deactivateGrokThinkingAnimation()
                        restoreStaticMenuBarBitmap()
                        return
                    }
                }
            } else {
                deactivateGrokThinkingAnimation()
                restoreStaticMenuBarBitmap()
            }
        case .claude:
            stopCodexAnimationImplementation()
            deactivateGrokThinkingAnimation()
            codexAnimationBackend = preferredCodexAnimationBackend
            setCodexAnimationFallbackActive(false)
            if let claudeIconImage,
               menuBarIconView.sourceImageForRendering !== claudeIconImage {
                menuBarIconView.setSourceImage(
                    claudeIconImage,
                    prepareAnimationFrames: false
                )
            }
            if MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: isClaudeTaskRunning,
                preferenceEnabled: animationEnabled,
                reduceMotionEnabled: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ) {
                guard synchronizeClaudeThinkingAnimationHost() else {
                    deactivateClaudeThinkingAnimation()
                    restoreStaticMenuBarBitmap()
                    return
                }
            } else {
                deactivateClaudeThinkingAnimation()
                restoreStaticMenuBarBitmap()
            }
        }
    }

    /// Establishes the active rotation client's semantic source before the
    /// task animation policy can take an idle early-return path. Idle must
    /// not keep the previous client's icon.
    private func ensureRotationSourceImage() {
        guard let rotationSourceImage,
              menuBarIconView.sourceImageForRendering !== rotationSourceImage else {
            return
        }
        menuBarIconView.setSourceImage(
            rotationSourceImage,
            prepareAnimationFrames: false
        )
    }

    private var isRotationTaskRunning: Bool {
        switch activeClient {
        case .codex:
            return isCodexTaskRunning
        case .grok, .claude:
            return false
        }
    }

    private var rotationSourceImage: NSImage? {
        switch activeClient {
        case .codex:
            return codexIconImage
        case .grok, .claude:
            return nil
        }
    }

    private func stopCodexAnimationImplementation() {
        menuBarIconView.stopRotating()
        deactivateNativeCodexAnimation()
        restoreStaticMenuBarBitmap()
    }

    private func setCodexAnimationFallbackActive(_ active: Bool) {
        guard codexAnimationFallbackActive != active else { return }
        codexAnimationFallbackActive = active
        actions.animationFallbackChanged(active)
    }

    private func activateTemporaryStableBitmapFallback() {
        // This is intentionally a one-way transition for the current task.
        // It prevents a failed G setup from bouncing between backends on every
        // ordinary snapshot update; a new task or explicit mode selection
        // starts a fresh G attempt.
        deactivateNativeCodexAnimation()
        codexAnimationBackend = .stableBitmap
        setCodexAnimationFallbackActive(true)
        guard let rotationSourceImage else { return }
        menuBarIconView.setSourceImage(rotationSourceImage, prepareAnimationFrames: true)
        guard installStableCodexAnimationImage(at: 0) else {
            menuBarIconView.stopRotating()
            restoreStaticMenuBarBitmap()
            return
        }
        menuBarIconView.startRotating()
    }

    private func applyMenuBarIconDisplayPolicy() {
        guard let statusItem else { return }
        let shouldDisplay = menuBarIconDisplayStateMachine.shouldDisplay
        let changed = statusItem.isVisible != shouldDisplay
        if changed {
            statusItem.isVisible = shouldDisplay
            SwitchLog.write(
                "menu bar display mode applied; mode=\(settings.iconDisplayMode.rawValue); delay_seconds=\(settings.iconDisplayDelay.duration); codex_running=\(isCodexTaskRunning); visible=\(shouldDisplay)",
                category: "ui.status-item"
            )
        }
        publishStatusItemVisibility()
        if changed, shouldDisplay {
            scheduleStatusItemAttachmentCheck(
                reason: "activity-running",
                reanchor: true
            )
        }
    }

    private func configureMenuBarContentStackIfNeeded() {
        guard !isMenuBarContentStackConfigured else { return }
        isMenuBarContentStackConfigured = true
        menuBarIconView.translatesAutoresizingMaskIntoConstraints = true
        menuBarIconSlot.translatesAutoresizingMaskIntoConstraints = true
        menuBarIconSlot.addSubview(menuBarIconView)
        menuBarTextStack.addSubview(menuBarPrimaryLabel)
        menuBarTextStack.addSubview(menuBarSecondaryLabel)
        menuBarTextStack.wantsLayer = true
        menuBarTextStack.layer?.setAffineTransform(.identity)
        menuBarContentStack.addSubview(menuBarIconSlot)
        menuBarContentStack.addSubview(menuBarTextStack)
        menuBarContentStack.translatesAutoresizingMaskIntoConstraints = true
    }

    /// Installs the offscreen content tree used to produce the button bitmap.
    private func configureBitmapMenuBarContent() {
        guard let button = statusItem?.button else { return }
        menuBarContentStack.removeFromSuperview()
        invalidateBitmapContentCache()
        button.image = Self.placeholderButtonImage

        bitmapRenderContainer.frame = NSRect(origin: .zero, size: button.bounds.size)
        bitmapRenderContainer.addSubview(menuBarContentStack)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
    }

    private func layoutStatusItem(for snapshot: Snapshot) {
        layoutStatusItemCallCountForTesting += 1
        guard let statusItem, let button = statusItem.button else { return }
        applyMenuBarFonts()
        let effectiveSnapshot = menuBarSnapshot(for: snapshot)
        let reservedSecondary = settings.showAmount && effectiveSnapshot.kind == .official
            ? effectiveSnapshot.menuBarSecondary(
                displayMode: settings.quotaResetDisplayMode,
                lunaReserveResetTimeMode: settings.lunaReserveResetTimeMode,
                timeZone: settings.displayTimeZone
            )
            : ""
        let hasSecondary = settings.showAmount
            && settings.showReset
            && !reservedSecondary.isEmpty

        MenuBarLayout.applyPrimaryText(
            settings.showAmount ? effectiveSnapshot.menuBarPrimary : "",
            to: menuBarPrimaryLabel
        )
        if menuBarSecondaryLabel.stringValue != reservedSecondary {
            menuBarSecondaryLabel.stringValue = reservedSecondary
        }
        menuBarIconSlot.isHidden = !settings.showIcon
        menuBarTextStack.isHidden = !settings.showAmount
        let geometry = MenuBarLayout.geometry(
            primarySize: menuBarPrimaryLabel.intrinsicContentSize,
            secondarySize: menuBarSecondaryLabel.intrinsicContentSize,
            showIcon: settings.showIcon,
            showAmount: settings.showAmount,
            hasSecondary: hasSecondary,
            isBalance: effectiveSnapshot.kind == .balance,
            iconSlotWidth: settings.iconSize
        )
        MenuBarLayout.applyTextLayout(
            container: menuBarTextStack,
            primary: menuBarPrimaryLabel,
            secondary: menuBarSecondaryLabel,
            geometry: geometry,
            showAmount: settings.showAmount,
            hasSecondary: hasSecondary
        )

        // macOS 26's status-item replicant machinery re-snapshots the whole
        // button content whenever the item looks mutated; assigning the same
        // length again re-enters that loop for no visual change.
        let requestedLength: CGFloat
        if isSingleLineAmountMode(
            effectiveSnapshot: effectiveSnapshot,
            geometry: geometry
        ) {
            requestedLength = MenuBarLayout.singleLineStatusItemLength(
                primaryText: effectiveSnapshot.menuBarPrimary,
                showIcon: settings.showIcon,
                isBalance: effectiveSnapshot.kind == .balance,
                horizontalPadding: settings.horizontalPadding,
                widthAdjustment: settings.widthAdjustment,
                iconSlotWidth: settings.iconSize
            )
        } else {
            requestedLength = MenuBarLayout.statusItemLength(
                contentWidth: geometry.contentWidth,
                horizontalPadding: settings.horizontalPadding,
                widthAdjustment: settings.widthAdjustment
            )
        }
        if statusItem.length != requestedLength {
            SwitchLog.write(
                "status item length changed; old=\(statusItem.length); new=\(requestedLength)",
                level: .debug,
                category: "ui.status-item"
            )
            statusItem.length = requestedLength
        }
        button.layoutSubtreeIfNeeded()

        let buttonHeight = button.bounds.height
        let apiIconYOffset = settings.showIcon && settings.showAmount
            ? MenuBarLayout.singleLineIconYOffset
            : 0
        let iconYOffset: CGFloat
        if effectiveSnapshot.kind == .official, settings.showIcon {
            let apiGeometry = MenuBarLayout.geometry(
                primarySize: menuBarPrimaryLabel.intrinsicContentSize,
                secondarySize: menuBarSecondaryLabel.intrinsicContentSize,
                showIcon: settings.showIcon,
                showAmount: settings.showAmount,
                hasSecondary: false,
                isBalance: true,
                iconSlotWidth: settings.iconSize
            )
            iconYOffset = geometry.iconViewYOffset(
                alignedTo: apiGeometry,
                buttonHeight: buttonHeight,
                referenceIconViewYOffset: apiIconYOffset
            )
        } else if effectiveSnapshot.kind == .balance {
            iconYOffset = apiIconYOffset
        } else {
            iconYOffset = 0
        }
        let officialTextYOffset: CGFloat
        if effectiveSnapshot.kind == .official, settings.showAmount {
            officialTextYOffset = MenuBarLayout.officialTextYOffset(
                hasSecondary: hasSecondary
            )
        } else {
            officialTextYOffset = 0
        }
        lastMenuBarGeometry = geometry
        lastMenuBarIconYOffset = iconYOffset
        lastMenuBarOfficialTextYOffset = officialTextYOffset
        lastMenuBarEffectiveSnapshot = effectiveSnapshot
        applyMenuBarContentFrames(
            button: button,
            // AppKit can update the status button's bounds one run-loop turn
            // after `statusItem.length` changes. Pass the requested footprint
            // immediately so toggling the icon cannot leave the amount
            // centered against the previous icon-inclusive width.
            buttonSize: NSSize(width: max(0, statusItem.length), height: buttonHeight),
            geometry: geometry,
            iconViewYOffset: iconYOffset,
            effectiveSnapshot: effectiveSnapshot,
            officialTextYOffset: officialTextYOffset
        )
        // Frames are final here; snapshot the offscreen tree into the button
        // image so the real button carries no live view hierarchy.
        refreshMenuBarContentBitmap()
        if codexAnimationNeedsPostLayoutReconciliation {
            codexAnimationNeedsPostLayoutReconciliation = false
            updateActivityIcon()
        }
        if button.toolTip != effectiveSnapshot.menuBarToolTip(timeZone: settings.displayTimeZone) {
            button.toolTip = effectiveSnapshot.menuBarToolTip(timeZone: settings.displayTimeZone)
        }
        button.isHidden = false
        button.isEnabled = true
        applyMenuBarIconDisplayPolicy()
    }

    private func applyMenuBarFonts() {
        // Reassigning fonts (even equal ones) dirties the text fields and feeds
        // macOS 26's status-item replicant re-snapshot loop, so guard first.
        let primaryFont = MenuBarLayout.primaryFont(size: settings.fontSize)
        if menuBarPrimaryLabel.font != primaryFont {
            menuBarPrimaryLabel.font = primaryFont
        }
        let secondaryFont = MenuBarLayout.secondaryFont(
            size: CGFloat(
                AppPreferences.secondaryMenuBarFontSize(for: Double(settings.fontSize))
            )
        )
        if menuBarSecondaryLabel.font != secondaryFont {
            menuBarSecondaryLabel.font = secondaryFont
        }
    }

    private func applyMenuBarContentFrames(
        button: NSStatusBarButton,
        buttonSize: NSSize? = nil,
        geometry: MenuBarGeometry,
        iconViewYOffset: CGFloat,
        effectiveSnapshot: Snapshot,
        officialTextYOffset: CGFloat
    ) {
        // Use the requested status-item footprint as the horizontal background
        // geometry immediately; the actual button height remains authoritative.
        let effectiveButtonSize = buttonSize ?? NSSize(
            width: max(0, statusItem?.length ?? button.bounds.width),
            height: button.bounds.height
        )
        let backgroundBounds = NSRect(
            x: button.bounds.minX,
            y: button.bounds.minY,
            width: max(0, effectiveButtonSize.width),
            height: max(0, effectiveButtonSize.height)
        )
        let frames = MenuBarLayout.frames(
            buttonSize: backgroundBounds.size,
            geometry: geometry,
            iconViewYOffset: iconViewYOffset,
            iconOffset: NSSize(
                width: settings.iconOffsetX,
                height: settings.iconOffsetY
            ),
            textOffset: NSSize(
                width: settings.amountOffsetX,
                height: settings.amountOffsetY + officialTextYOffset
            )
        )
        let isSingleLine = isSingleLineAmountMode(
            effectiveSnapshot: effectiveSnapshot,
            geometry: geometry
        )
        // Install the unadjusted hierarchy first. The narrow single-line path
        // measures the actual primary ink after AppKit has applied its cell
        // drawing and the existing balance text transform; the icon remains
        // in this same outer stack for horizontal translation only.
        menuBarContentStack.frame = frames.content
        menuBarIconSlot.frame = frames.iconSlot
        menuBarIconView.frame = frames.icon
        menuBarTextStack.frame = frames.text
        menuBarTextStack.layer?.setAffineTransform(.identity)
        if effectiveSnapshot.kind == .balance,
           settings.showIcon,
           settings.showAmount {
            menuBarTextStack.layer?.setAffineTransform(CGAffineTransform(
                translationX: 0,
                y: -MenuBarLayout.singleLineTextYOffset
            ))
        }

        if isSingleLine {
            // Establish the zero-user-offset baseline first. The final
            // correction below then targets the same primary ink plus the
            // requested amountOffsetY, so the user adjustment cannot be
            // consumed by the baseline measurement.
            let zeroUserTextFrame = MenuBarLayout.frames(
                buttonSize: backgroundBounds.size,
                geometry: geometry,
                iconViewYOffset: iconViewYOffset,
                iconOffset: NSSize(
                    width: settings.iconOffsetX,
                    height: settings.iconOffsetY
                ),
                textOffset: NSSize(
                    width: settings.amountOffsetX,
                    height: officialTextYOffset
                )
            ).text
            menuBarTextStack.frame = zeroUserTextFrame
            let horizontalCorrection: CGFloat
            if let primaryInk = menuBarPrimaryInkBounds(in: menuBarContentCoordinateSpace) {
                let targetX = MenuBarLayout.singleLinePrimaryAnchorX(
                    backgroundBounds: backgroundBounds,
                    primaryText: effectiveSnapshot.menuBarPrimary,
                    showIcon: settings.showIcon,
                    isBalance: effectiveSnapshot.kind == .balance,
                    iconSlotWidth: settings.iconSize
                )
                horizontalCorrection = targetX - primaryInk.midX
            } else {
                horizontalCorrection = 0
            }
            menuBarContentStack.frame = frames.content.offsetBy(
                dx: horizontalCorrection,
                dy: 0
            )

            // The icon must not follow this Y correction. It is the primary
            // glyph's measured ink—not the icon/text union—that is aligned to
            // the button center. The user amount offset is the target visual
            // displacement, while official/balance baseline constants are
            // absorbed by this measured correction.
            if let primaryInk = menuBarPrimaryInkBounds(in: menuBarContentCoordinateSpace) {
                let automaticTextYOffset = MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                    fontSize: settings.fontSize
                )
                let coordinateBounds = menuBarContentCoordinateSpace?.bounds ?? button.bounds
                let verticalCorrection = MenuBarLayout.primaryInkVerticalCorrection(
                    primaryInk: primaryInk,
                    coordinateBounds: coordinateBounds,
                    amountOffsetY: settings.amountOffsetY,
                    automaticYOffset: automaticTextYOffset
                )
                menuBarTextStack.frame = zeroUserTextFrame.offsetBy(
                    dx: 0,
                    dy: verticalCorrection
                )
            }
        } else {
            // Keep the established official two-line and icon-only layout
            // path byte-for-byte in behavior, including its background
            // compensation and frame relationships.
            let horizontalCenteringCompensation = MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: backgroundBounds,
                geometry: geometry,
                iconOffsetX: settings.iconOffsetX,
                textOffsetX: settings.amountOffsetX,
                centerVisibleUnionOnBackground: geometry.secondaryHeight > 0
            )
            menuBarContentStack.frame = frames.content.offsetBy(
                dx: horizontalCenteringCompensation,
                dy: 0
            )
        }
    }

    private func isSingleLineAmountMode(
        effectiveSnapshot: Snapshot,
        geometry: MenuBarGeometry
    ) -> Bool {
        guard settings.showAmount, geometry.secondaryHeight == 0 else {
            return false
        }
        switch effectiveSnapshot.kind {
        case .official, .balance:
            return true
        case .placeholder, .error:
            return false
        }
    }

    /// The offscreen render container is the sole coordinate space for the
    /// content tree. Its bounds share the button's (0,0)-origin footprint.
    private var menuBarContentCoordinateSpace: NSView? {
        bitmapRenderContainer.bounds.width > 0 ? bitmapRenderContainer : nil
    }

    private func menuBarPrimaryInkBounds(in coordinateSpace: NSView?) -> NSRect? {
        guard let coordinateSpace,
              settings.showAmount,
              let geometry = lastMenuBarGeometry,
              menuBarPrimaryLabel.frame.width > 0,
              geometry.primaryHeight > 0,
              let localBounds = MenuBarLayout.appKitRenderedTextBounds(
                  for: menuBarPrimaryLabel,
                  frameSize: NSSize(
                      width: menuBarPrimaryLabel.bounds.width,
                      height: geometry.primaryHeight
                  )
              ) else {
            return nil
        }
        return menuBarPrimaryLabel.convert(localBounds, to: coordinateSpace)
    }

    private func invalidateBitmapContentCache(setPlaceholder: Bool = false) {
        clearNativeCodexSourceIconCutout()
        cachedMenuBarTextBitmap = nil
        cachedStaticMenuBarContentBitmap = nil
        cachedMenuBarContentVisualSignature = nil
        menuBarBitmapImagePlacement = nil
        cachedMenuBarIconDrawRect = nil
        stableCodexAnimationFrameBuffer.invalidate()
        grokThinkingStableFrameBuffer.invalidate()
        if setPlaceholder {
            statusItem?.button?.image = Self.placeholderButtonImage
        }
    }

    private var shouldPrepareCodexAnimationFrames: Bool {
        activeClient.usesRotationAnimation
            && isRotationTaskRunning
            && animationEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !menuBarIconSlot.isHidden
            && !menuBarIconView.isHidden
    }

    private var shouldUseStableCodexAnimation: Bool {
        shouldPrepareCodexAnimationFrames && menuBarIconView.isRotating
    }

    private var shouldUseNativeCodexAnimation: Bool {
        codexAnimationBackend == .nativeCoreAnimation
            && shouldPrepareCodexAnimationFrames
    }

    private var shouldPrepareClaudeThinkingAnimation: Bool {
        activeClient == .claude
            && isClaudeTaskRunning
            && animationEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !menuBarIconSlot.isHidden
            && !menuBarIconView.isHidden
            && claudeThinkingSpriteImage != nil
    }

    private var shouldPrepareGrokThinkingAnimation: Bool {
        activeClient == .grok
            && isGrokTaskRunning
            && animationEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !menuBarIconSlot.isHidden
            && !menuBarIconView.isHidden
            && grokThinkingSpriteImage != nil
    }

    /// Materializes one mutable image representation from the finite source
    /// frame set. This may compose and rasterize each frame, but only during a
    /// bounded visual-cache rebuild; no timer callback reaches this method.
    @discardableResult
    private func ensureStableCodexAnimationFrameBuffer() -> Bool {
        precondition(Thread.isMainThread, "Codex bitmap cache must be rebuilt on the main thread")
        guard shouldPrepareCodexAnimationFrames,
              let cachedSignature = cachedMenuBarContentVisualSignature,
              let textBitmap = cachedMenuBarTextBitmap,
              let iconDrawRect = cachedMenuBarIconDrawRect,
              let placement = menuBarBitmapImagePlacement,
              let button = statusItem?.button,
              let rotationSourceImage,
              let sourceImage = menuBarIconView.sourceImageForRendering,
              sourceImage === rotationSourceImage else {
            return false
        }
        let currentSignature = makeMenuBarBitmapAnimationVisualSignature(
            button: button,
            placement: placement,
            scale: button.window?.backingScaleFactor ?? 2
        )
        guard currentSignature.matchesStaticContent(of: cachedSignature) else {
            return false
        }
        let sourceFrames = menuBarIconView.animationFrames
        guard !sourceFrames.isEmpty else { return false }
        return stableCodexAnimationFrameBuffer.rebuildIfNeeded(
            signature: currentSignature,
            sourceFrames: sourceFrames
        ) { frame in
            Self.makeCompleteMenuBarBitmap(
                textBitmap: textBitmap,
                iconImage: frame,
                iconDrawRect: iconDrawRect,
                canvasSize: placement.canvasSize
            )
        }
    }

    /// Installs the stable image at an animation boundary (start or a real
    /// visual invalidation). Once installed, frame callbacks must use
    /// applyStableCodexAnimationFrame(_:) so they never assign button.image.
    @discardableResult
    private func installStableCodexAnimationImage(at frameIndex: Int) -> Bool {
        precondition(Thread.isMainThread, "Codex bitmap image must be installed on the main thread")
        guard ensureStableCodexAnimationFrameBuffer(),
              let button = statusItem?.button,
              let image = stableCodexAnimationFrameBuffer.image,
              stableCodexAnimationFrameBuffer.apply(frameIndex: frameIndex) else {
            return false
        }
        if button.image !== image {
            button.image = image
            stableCodexAnimationImageAssignmentCountForTesting += 1
        }
        button.needsDisplay = true
        stableCodexAnimationRedrawRequestCountForTesting += 1
        return true
    }

    /// Copies prebuilt pixels into the already-installed image. This is the
    /// only Codex bitmap work performed by the animation timer path.
    private func applyStableCodexAnimationFrame(_ frameIndex: Int) {
        precondition(Thread.isMainThread, "Codex bitmap pixels must be copied on the main thread")
        guard shouldUseStableCodexAnimation,
              let button = statusItem?.button,
              let image = stableCodexAnimationFrameBuffer.image,
              button.image === image,
              stableCodexAnimationFrameBuffer.apply(frameIndex: frameIndex) else {
            return
        }
        button.needsDisplay = true
        stableCodexAnimationRedrawRequestCountForTesting += 1
    }

    private func restoreStaticMenuBarBitmap() {
        guard let button = statusItem?.button,
              let staticImage = cachedStaticMenuBarContentBitmap else {
            return
        }
        if button.image !== staticImage {
            button.image = staticImage
        }
    }

    /// Synchronizes the BalanceBar-owned icon host at a bounded visual
    /// boundary. The canonical static GPT+text bitmap stays on the native
    /// button so inactive-display replicants keep a visible icon. The host
    /// then overlays compositor rotation on the current source presentation.
    @discardableResult
    private func synchronizeNativeCodexAnimationHost() -> Bool {
        precondition(Thread.isMainThread, "Native Codex animation must be synchronized on the main thread")
        if forceNativeCodexAnimationFailureForTesting {
            return false
        }
        guard codexAnimationBackend == .nativeCoreAnimation,
              shouldPrepareCodexAnimationFrames,
              let button = statusItem?.button,
              let staticImage = cachedStaticMenuBarContentBitmap,
              let iconDrawRect = cachedMenuBarIconDrawRect,
              let placement = menuBarBitmapImagePlacement,
              let rotationSourceImage else {
            return false
        }

        let localIconRect = placement.buttonLocalRect(
            forImageCanvasRect: iconDrawRect
        )
        guard localIconRect.width > 0, localIconRect.height > 0 else {
            return false
        }

        if button.image !== staticImage {
            // Replicants snapshot this native image. Keep the complete static
            // GPT+text bitmap; the CA host is source-local and is not copied
            // to inactive displays.
            button.image = staticImage
        }

        let host = nativeCodexAnimatedIconHost ?? {
            let newHost = MenuBarNativeAnimatedIconHostView(frame: localIconRect)
            nativeCodexAnimatedIconHost = newHost
            return newHost
        }()
        let hostFrame = attachNativeCodexAnimationHost(
            host,
            button: button,
            localIconRect: localIconRect
        )
        if host.superview !== nil, host.superview !== button {
            guard applyNativeCodexSourceIconCutout(
                button: button,
                localIconRect: localIconRect
            ) else {
                deactivateNativeCodexAnimation()
                return false
            }
        } else {
            clearNativeCodexSourceIconCutout()
        }

        let scale = button.window?.backingScaleFactor ?? 2
        host.updateGeometry(frame: hostFrame, contentsScale: scale)
        guard host.updateContents(
            sourceImage: rotationSourceImage,
            appearance: button.effectiveAppearance,
            contentsScale: scale,
            highlighted: button.isHighlighted || button.cell?.isHighlighted == true
        ) else {
            host.removeRotationAnimation()
            host.isHidden = true
            host.removeFromSuperview()
            clearNativeCodexSourceIconCutout()
            return false
        }
        host.isHidden = false
        host.rotationDuration = MenuBarAnimationTiming.rotationDuration(fps: animationFrameRate)
        // Existing animation is deliberately retained across geometry,
        // appearance, backing-scale, and status-item reattachment changes.
        // FPS changes replace the duration through `rotationDuration`.
        host.installRotationAnimation()
        publishNativeCodexAnimationStateIfNeeded(true)
        return true
    }

    /// Places the transparent rotating host beside the status button so a
    /// source-local icon cutout can hide the static GPT without clipping the
    /// overlay. Falls back to a button child if AppKit has not installed a
    /// container yet.
    @discardableResult
    private func attachNativeCodexAnimationHost(
        _ host: MenuBarNativeAnimatedIconHostView,
        button: NSStatusBarButton,
        localIconRect: NSRect
    ) -> NSRect {
        if let container = button.superview {
            if host.superview !== container {
                host.removeFromSuperview()
                container.addSubview(host, positioned: .above, relativeTo: button)
            }
            return button.convert(localIconRect, to: container)
        }
        if host.superview !== button {
            host.removeFromSuperview()
            button.addSubview(host, positioned: .above, relativeTo: nil)
        }
        return localIconRect
    }

    /// Hides only the source button's static GPT by masking the icon rect.
    /// The canonical `button.image` is left unchanged for inactive replicants.
    @discardableResult
    private func applyNativeCodexSourceIconCutout(
        button: NSStatusBarButton,
        localIconRect: NSRect
    ) -> Bool {
        guard localIconRect.width > 0, localIconRect.height > 0 else {
            return false
        }
        button.wantsLayer = true
        guard let buttonLayer = button.layer,
              let iconRect = Self.nativeCodexIconRectInLayerCoordinates(
                  button: button,
                  buttonLayer: buttonLayer,
                  localIconRect: localIconRect
              ) else {
            return false
        }

        let mask: CAShapeLayer
        if let existingMask = nativeCodexSourceIconMask,
           nativeCodexSourceIconMaskOwnerButton === button {
            mask = existingMask
        } else {
            clearNativeCodexSourceIconCutout()
            let newMask = CAShapeLayer()
            nativeCodexSourceIconMask = newMask
            nativeCodexSourceIconMaskOwnerButton = button
            nativeCodexSourceIconPreviousMask = buttonLayer.mask
            mask = newMask
        }

        if let currentMask = buttonLayer.mask,
           currentMask !== mask,
           currentMask !== nativeCodexSourceIconPreviousMask {
            return false
        }

        let maskBounds = CGRect(origin: .zero, size: buttonLayer.bounds.size)
        let path = CGMutablePath()
        path.addRect(maskBounds)
        path.addRect(iconRect)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = buttonLayer.bounds
        mask.path = path
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        mask.isGeometryFlipped = buttonLayer.isGeometryFlipped
        if buttonLayer.mask !== mask {
            buttonLayer.mask = mask
        }
        CATransaction.commit()
        return buttonLayer.mask === mask
    }

    private static func nativeCodexIconRectInLayerCoordinates(
        button: NSStatusBarButton,
        buttonLayer: CALayer,
        localIconRect: NSRect
    ) -> CGRect? {
        let viewBounds = button.bounds
        let layerBounds = buttonLayer.bounds
        guard viewBounds.width > 0,
              viewBounds.height > 0,
              layerBounds.width > 0,
              layerBounds.height > 0 else {
            return nil
        }
        let clippedIconRect = localIconRect.intersection(viewBounds)
        guard !clippedIconRect.isNull,
              clippedIconRect.width > 0,
              clippedIconRect.height > 0 else {
            return nil
        }

        let xScale = layerBounds.width / viewBounds.width
        let yScale = layerBounds.height / viewBounds.height
        let x = (clippedIconRect.minX - viewBounds.minX) * xScale
        let yInViewCoordinates: CGFloat
        if button.isFlipped == buttonLayer.isGeometryFlipped {
            yInViewCoordinates = clippedIconRect.minY - viewBounds.minY
        } else {
            yInViewCoordinates = viewBounds.maxY - clippedIconRect.maxY
        }
        let rect = CGRect(
            x: x,
            y: yInViewCoordinates * yScale,
            width: clippedIconRect.width * xScale,
            height: clippedIconRect.height * yScale
        )
        let maskBounds = CGRect(origin: .zero, size: layerBounds.size)
        guard maskBounds.contains(rect) else { return nil }
        return rect
    }

    private func clearNativeCodexSourceIconCutout() {
        if let mask = nativeCodexSourceIconMask,
           let ownerButton = nativeCodexSourceIconMaskOwnerButton,
           let buttonLayer = ownerButton.layer,
           buttonLayer.mask === mask {
            buttonLayer.mask = nativeCodexSourceIconPreviousMask
        }
        nativeCodexSourceIconMask = nil
        nativeCodexSourceIconMaskOwnerButton = nil
        nativeCodexSourceIconPreviousMask = nil
    }

    /// Synchronizes the retained Claude sprite host at a bounded visual
    /// boundary. The real status button keeps only the text bitmap; the host
    /// owns the single sprite texture and its compositor-local animation.
    @discardableResult
    private func synchronizeClaudeThinkingAnimationHost() -> Bool {
        precondition(
            Thread.isMainThread,
            "Claude animation must be synchronized on the main thread"
        )
        guard shouldPrepareClaudeThinkingAnimation,
              let button = statusItem?.button,
              let textBitmap = cachedMenuBarTextBitmap,
              let iconDrawRect = cachedMenuBarIconDrawRect,
              let placement = menuBarBitmapImagePlacement,
              let claudeThinkingSpriteImage,
              let claudeIconImage else {
            return false
        }

        let localIconRect = placement.buttonLocalRect(
            forImageCanvasRect: iconDrawRect
        )
        guard localIconRect.width > 0, localIconRect.height > 0 else {
            return false
        }

        if button.image !== textBitmap {
            // One boundary assignment replaces the complete static bitmap
            // with its text-only variant; the host supplies the icon pixels.
            button.image = textBitmap
        }

        let host = claudeThinkingAnimatedIconHost ?? {
            let newHost = MenuBarClaudeAnimatedIconHostView(frame: localIconRect)
            claudeThinkingAnimatedIconHost = newHost
            return newHost
        }()
        if host.superview !== button {
            host.removeFromSuperview()
            button.addSubview(host, positioned: .above, relativeTo: nil)
        }

        let scale = button.window?.backingScaleFactor ?? 2
        host.updateGeometry(frame: localIconRect, contentsScale: scale)
        let frameSize = NSSize(
            width: claudeThinkingSpriteImage.size.width,
            height: claudeThinkingSpriteImage.size.height
                / CGFloat(MenuBarClaudeAnimatedIconHostView.thinkingFrameCount)
        )
        guard host.updateContents(
            spriteImage: claudeThinkingSpriteImage,
            frameSize: frameSize,
            appearance: button.effectiveAppearance,
            contentsScale: scale,
            highlighted: button.isHighlighted || button.cell?.isHighlighted == true
        ) else {
            host.removeThinkingAnimation()
            host.isHidden = true
            host.removeFromSuperview()
            return false
        }
        host.isHidden = false
        // Existing animation is deliberately retained across geometry,
        // appearance, backing-scale, and status-item reattachment changes.
        host.installThinkingAnimation()
        publishClaudeThinkingAnimationStateIfNeeded(
            true,
            iconImage: claudeIconImage,
            spriteImage: claudeThinkingSpriteImage
        )
        return true
    }

    private func deactivateNativeCodexAnimation() {
        clearNativeCodexSourceIconCutout()
        nativeCodexAnimatedIconHost?.removeRotationAnimation()
        nativeCodexAnimatedIconHost?.isHidden = true
        nativeCodexAnimatedIconHost?.removeFromSuperview()
        publishNativeCodexAnimationStateIfNeeded(false)
    }

    /// Detaches only the view during an AppKit status-item replacement.  The
    /// layer animation stays installed on the retained host, so reattachment
    /// continues at the layer-local compositor phase without a restart.
    private func detachNativeCodexAnimationHostForStatusItemReplacement() {
        clearNativeCodexSourceIconCutout()
        nativeCodexAnimatedIconHost?.removeFromSuperview()
    }

    private func deactivateClaudeThinkingAnimation() {
        claudeThinkingAnimatedIconHost?.removeThinkingAnimation()
        claudeThinkingAnimatedIconHost?.isHidden = true
        claudeThinkingAnimatedIconHost?.removeFromSuperview()
        publishClaudeThinkingAnimationStateIfNeeded(
            false,
            iconImage: claudeIconImage,
            spriteImage: claudeThinkingSpriteImage
        )
    }

    /// Detaches only the Claude host during AppKit status-item replacement.
    /// Its layer animation remains installed so reattachment preserves phase.
    private func detachClaudeThinkingAnimationHostForStatusItemReplacement() {
        claudeThinkingAnimatedIconHost?.removeFromSuperview()
    }

    /// Performance/G: thinking sprite host on the current screen; native
    /// `button.image` keeps the complete static Grok+text bitmap so inactive
    /// replicants still show the spark. Mirrors #312, not Claude's text-only
    /// bitmap.
    @discardableResult
    private func synchronizeGrokThinkingAnimationHost() -> Bool {
        precondition(
            Thread.isMainThread,
            "Grok animation must be synchronized on the main thread"
        )
        guard shouldPrepareGrokThinkingAnimation,
              codexAnimationBackend == .nativeCoreAnimation,
              let button = statusItem?.button,
              let staticImage = cachedStaticMenuBarContentBitmap,
              let iconDrawRect = cachedMenuBarIconDrawRect,
              let placement = menuBarBitmapImagePlacement,
              let grokThinkingSpriteImage,
              let grokIconImage else {
            return false
        }

        let localIconRect = placement.buttonLocalRect(
            forImageCanvasRect: iconDrawRect
        )
        guard localIconRect.width > 0, localIconRect.height > 0 else {
            return false
        }

        if button.image !== staticImage {
            button.image = staticImage
        }

        let host = grokThinkingAnimatedIconHost ?? {
            let newHost = MenuBarClaudeAnimatedIconHostView(frame: localIconRect)
            grokThinkingAnimatedIconHost = newHost
            return newHost
        }()
        host.timing = .grok(frameRate: animationFrameRate)
        let hostFrame = attachGrokThinkingAnimationHost(
            host,
            button: button,
            localIconRect: localIconRect
        )
        if host.superview !== nil, host.superview !== button {
            guard applyNativeCodexSourceIconCutout(
                button: button,
                localIconRect: localIconRect
            ) else {
                deactivateGrokThinkingAnimationHost()
                return false
            }
        } else {
            clearNativeCodexSourceIconCutout()
        }

        let scale = button.window?.backingScaleFactor ?? 2
        host.updateGeometry(frame: hostFrame, contentsScale: scale)
        let frameSize = NSSize(
            width: grokThinkingSpriteImage.size.width,
            height: grokThinkingSpriteImage.size.height
                / CGFloat(host.timing.frameCount)
        )
        guard host.updateContents(
            spriteImage: grokThinkingSpriteImage,
            frameSize: frameSize,
            appearance: button.effectiveAppearance,
            contentsScale: scale,
            highlighted: button.isHighlighted || button.cell?.isHighlighted == true
        ) else {
            host.removeThinkingAnimation()
            host.isHidden = true
            host.removeFromSuperview()
            clearNativeCodexSourceIconCutout()
            return false
        }
        host.isHidden = false
        host.installThinkingAnimation()
        publishGrokThinkingAnimationStateIfNeeded(
            true,
            iconImage: grokIconImage,
            spriteImage: grokThinkingSpriteImage
        )
        return true
    }

    @discardableResult
    private func attachGrokThinkingAnimationHost(
        _ host: MenuBarClaudeAnimatedIconHostView,
        button: NSStatusBarButton,
        localIconRect: NSRect
    ) -> NSRect {
        if let container = button.superview {
            if host.superview !== container {
                host.removeFromSuperview()
                container.addSubview(host, positioned: .above, relativeTo: button)
            }
            return button.convert(localIconRect, to: container)
        }
        if host.superview !== button {
            host.removeFromSuperview()
            button.addSubview(host, positioned: .above, relativeTo: nil)
        }
        return localIconRect
    }

    private func deactivateGrokThinkingAnimationHost() {
        grokThinkingAnimatedIconHost?.removeThinkingAnimation()
        grokThinkingAnimatedIconHost?.isHidden = true
        grokThinkingAnimatedIconHost?.removeFromSuperview()
        clearNativeCodexSourceIconCutout()
    }

    private func deactivateGrokThinkingAnimation() {
        stopGrokThinkingStableBitmap()
        deactivateGrokThinkingAnimationHost()
        publishGrokThinkingAnimationStateIfNeeded(
            false,
            iconImage: grokIconImage,
            spriteImage: grokThinkingSpriteImage
        )
    }

    private func detachGrokThinkingAnimationHostForStatusItemReplacement() {
        grokThinkingAnimatedIconHost?.removeFromSuperview()
        clearNativeCodexSourceIconCutout()
    }

    private func stopGrokThinkingStableBitmap() {
        grokThinkingFrameTimer?.invalidate()
        grokThinkingFrameTimer = nil
        grokThinkingStableFrameBuffer.invalidate()
        grokThinkingSourceFrames = []
    }

    private func makeGrokThinkingSourceFrames(from sprite: NSImage) -> [NSImage]? {
        let frameCount = GrokThinkingAnimationTiming.frameCount
        guard sprite.size.width > 0,
              sprite.size.height > 0,
              frameCount > 0 else {
            return nil
        }
        let frameSize = NSSize(
            width: sprite.size.width,
            height: sprite.size.height / CGFloat(frameCount)
        )
        guard frameSize.height > 0 else { return nil }
        var frames: [NSImage] = []
        frames.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            let frame = NSImage(size: frameSize)
            frame.isTemplate = sprite.isTemplate
            frame.lockFocusFlipped(true)
            let stripIndex = GrokThinkingSprite.synchronizedStripIndex(for: index)
            sprite.draw(
                in: NSRect(origin: .zero, size: frameSize),
                from: NSRect(
                    x: 0,
                    y: CGFloat(stripIndex) * frameSize.height,
                    width: frameSize.width,
                    height: frameSize.height
                ),
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            frame.unlockFocus()
            frames.append(frame)
        }
        return frames
    }

    @discardableResult
    private func ensureStableGrokThinkingFrameBuffer() -> Bool {
        precondition(Thread.isMainThread, "Grok bitmap cache must be rebuilt on the main thread")
        guard shouldPrepareGrokThinkingAnimation,
              codexAnimationBackend == .stableBitmap,
              let cachedSignature = cachedMenuBarContentVisualSignature,
              let textBitmap = cachedMenuBarTextBitmap,
              let iconDrawRect = cachedMenuBarIconDrawRect,
              let placement = menuBarBitmapImagePlacement,
              let button = statusItem?.button,
              let grokThinkingSpriteImage else {
            return false
        }
        let currentSignature = makeMenuBarBitmapAnimationVisualSignature(
            button: button,
            placement: placement,
            scale: button.window?.backingScaleFactor ?? 2
        )
        guard currentSignature.matchesStaticContent(of: cachedSignature) else {
            return false
        }
        if grokThinkingSourceFrames.count != GrokThinkingAnimationTiming.frameCount {
            grokThinkingSourceFrames = makeGrokThinkingSourceFrames(
                from: grokThinkingSpriteImage
            ) ?? []
        }
        guard grokThinkingSourceFrames.count == GrokThinkingAnimationTiming.frameCount else {
            return false
        }
        return grokThinkingStableFrameBuffer.rebuildIfNeeded(
            signature: currentSignature,
            sourceFrames: grokThinkingSourceFrames
        ) { frame in
            Self.makeCompleteMenuBarBitmap(
                textBitmap: textBitmap,
                iconImage: frame,
                iconDrawRect: iconDrawRect,
                canvasSize: placement.canvasSize
            )
        }
    }

    @discardableResult
    private func installStableGrokThinkingImage(at frameIndex: Int) -> Bool {
        precondition(Thread.isMainThread, "Grok bitmap image must be installed on the main thread")
        guard ensureStableGrokThinkingFrameBuffer(),
              let button = statusItem?.button,
              let image = grokThinkingStableFrameBuffer.image,
              grokThinkingStableFrameBuffer.apply(frameIndex: frameIndex) else {
            return false
        }
        grokThinkingFrameIndex = frameIndex
        if button.image !== image {
            button.image = image
        }
        button.needsDisplay = true
        startGrokThinkingFrameTimerIfNeeded()
        publishGrokThinkingAnimationStateIfNeeded(
            true,
            iconImage: grokIconImage,
            spriteImage: grokThinkingSpriteImage
        )
        return true
    }

    private func applyStableGrokThinkingFrame(_ frameIndex: Int) {
        precondition(Thread.isMainThread, "Grok bitmap pixels must be copied on the main thread")
        guard shouldPrepareGrokThinkingAnimation,
              codexAnimationBackend == .stableBitmap,
              let button = statusItem?.button,
              let image = grokThinkingStableFrameBuffer.image,
              button.image === image,
              grokThinkingStableFrameBuffer.apply(frameIndex: frameIndex) else {
            return
        }
        grokThinkingFrameIndex = frameIndex
        button.needsDisplay = true
    }

    private func startGrokThinkingFrameTimerIfNeeded() {
        let interval = GrokThinkingAnimationTiming.frameDuration(fps: animationFrameRate)
        if let grokThinkingFrameTimer {
            if abs(grokThinkingFrameTimer.timeInterval - interval) < 0.000_001 {
                return
            }
            grokThinkingFrameTimer.invalidate()
            self.grokThinkingFrameTimer = nil
        }
        let timer = Timer(
            timeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            let next = (self.grokThinkingFrameIndex + 1)
                % GrokThinkingAnimationTiming.frameCount
            self.applyStableGrokThinkingFrame(next)
        }
        RunLoop.main.add(timer, forMode: .common)
        grokThinkingFrameTimer = timer
    }

    private func restartGrokThinkingFrameTimerIfNeeded() {
        guard grokThinkingFrameTimer != nil else { return }
        grokThinkingFrameTimer?.invalidate()
        grokThinkingFrameTimer = nil
        startGrokThinkingFrameTimerIfNeeded()
    }

    private func publishGrokThinkingAnimationStateIfNeeded(
        _ active: Bool,
        iconImage: NSImage?,
        spriteImage: NSImage?
    ) {
        guard grokThinkingAnimationIsActive != active else { return }
        grokThinkingAnimationIsActive = active
        actions.grokAnimationStateChanged(active, iconImage, spriteImage)
    }

    private func publishNativeCodexAnimationStateIfNeeded(_ active: Bool) {
        guard nativeCodexAnimationIsActive != active else { return }
        nativeCodexAnimationIsActive = active
        actions.animationStateChanged(active)
    }

    private func publishClaudeThinkingAnimationStateIfNeeded(
        _ active: Bool,
        iconImage: NSImage?,
        spriteImage: NSImage?
    ) {
        guard claudeThinkingAnimationIsActive != active else { return }
        claudeThinkingAnimationIsActive = active
        actions.claudeAnimationStateChanged(active, iconImage, spriteImage)
    }

    private func makeMenuBarBitmapAnimationVisualSignature(
        button: NSStatusBarButton,
        placement: MenuBarBitmapImagePlacement,
        scale: CGFloat
    ) -> MenuBarBitmapAnimationVisualSignature {
        let canonicalFrame: (NSView) -> NSRect = { view in
            view.convert(view.bounds, to: self.bitmapRenderContainer)
        }
        let sourceImage = menuBarIconView.sourceImageForRendering
        let effectiveSnapshot = lastMenuBarEffectiveSnapshot
        let snapshotKind: String
        switch effectiveSnapshot.kind {
        case .placeholder: snapshotKind = "placeholder"
        case .official: snapshotKind = "official"
        case .balance: snapshotKind = "balance"
        case .error: snapshotKind = "error"
        }
        let effectiveSnapshotSignature = MenuBarBitmapAnimationSnapshotSignature(
            kind: snapshotKind,
            provider: effectiveSnapshot.provider,
            amount: effectiveSnapshot.amount,
            unit: effectiveSnapshot.unit,
            message: effectiveSnapshot.message,
            primaryText: menuBarPrimaryLabel.stringValue,
            secondaryText: menuBarSecondaryLabel.stringValue,
            selectedQuotaWindowKind: effectiveSnapshot.selectedOfficialQuotaWindowKind?.rawValue,
            usesLunaReserve: effectiveSnapshot.menuBarUsesLunaReserve
        )
        let iconVisible = !menuBarIconSlot.isHidden && !menuBarIconView.isHidden
        let textVisible = !menuBarTextStack.isHidden && !menuBarContentStack.isHidden
        let providerIdentity = menuInput.choices.first(where: \.isCurrent)?.id
            ?? effectiveSnapshot.provider
        return MenuBarBitmapAnimationVisualSignature(
            primaryText: menuBarPrimaryLabel.stringValue,
            secondaryText: menuBarSecondaryLabel.stringValue,
            primaryFont: Self.bitmapFontSignature(menuBarPrimaryLabel.font),
            secondaryFont: Self.bitmapFontSignature(menuBarSecondaryLabel.font),
            contentFrame: canonicalFrame(menuBarContentStack),
            iconSlotFrame: canonicalFrame(menuBarIconSlot),
            iconFrame: canonicalFrame(menuBarIconView),
            textFrame: canonicalFrame(menuBarTextStack),
            contentBounds: menuBarContentStack.bounds,
            iconSlotBounds: menuBarIconSlot.bounds,
            iconBounds: menuBarIconView.bounds,
            textBounds: menuBarTextStack.bounds,
            contentTransform: MenuBarBitmapAnimationTransformSignature(
                menuBarContentStack.layer?.affineTransform() ?? .identity
            ),
            iconSlotTransform: MenuBarBitmapAnimationTransformSignature(
                menuBarIconSlot.layer?.affineTransform() ?? .identity
            ),
            iconTransform: MenuBarBitmapAnimationTransformSignature(
                menuBarIconView.layer?.affineTransform() ?? .identity
            ),
            textTransform: MenuBarBitmapAnimationTransformSignature(
                menuBarTextStack.layer?.affineTransform() ?? .identity
            ),
            bitmapBounds: bitmapRenderContainer.bounds,
            bitmapFrame: bitmapRenderContainer.frame,
            buttonBounds: button.bounds,
            placement: placement,
            backingScale: scale,
            iconVisible: iconVisible,
            textVisible: textVisible,
            primaryVisible: textVisible && !menuBarPrimaryLabel.isHidden,
            secondaryVisible: textVisible && !menuBarSecondaryLabel.isHidden,
            sourceImageIdentity: sourceImage.map(ObjectIdentifier.init),
            sourceImageSize: sourceImage?.size ?? .zero,
            sourceImageIsTemplate: sourceImage?.isTemplate ?? false,
            sourceFrameIdentities: menuBarIconView.animationFrames.map(ObjectIdentifier.init),
            sourceProviderIdentity: providerIdentity,
            activeClient: activeClient,
            effectiveSnapshot: effectiveSnapshotSignature,
            appearance: Self.bitmapAppearanceSignature(button.effectiveAppearance),
            iconOffsetX: settings.iconOffsetX,
            iconOffsetY: settings.iconOffsetY,
            amountOffsetX: settings.amountOffsetX,
            amountOffsetY: settings.amountOffsetY,
            horizontalPadding: settings.horizontalPadding,
            widthAdjustment: settings.widthAdjustment,
            showReset: settings.showReset,
            buttonImagePosition: Int(button.imagePosition.rawValue),
            buttonImageScaling: Int(button.imageScaling.rawValue),
            iconViewImageScaling: Int(menuBarIconView.imageScaling.rawValue),
            iconViewImageAlignment: Int(menuBarIconView.imageAlignment.rawValue)
        )
    }

    private static func bitmapFontSignature(_ font: NSFont?) -> String {
        guard let font else { return "none" }
        return "\(font.fontName)|\(font.pointSize)|\(font.fontDescriptor.symbolicTraits.rawValue)"
    }

    private static func bitmapAppearanceSignature(_ appearance: NSAppearance) -> String {
        let bestMatch = appearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "none"
        return "\(appearance.name.rawValue)|\(bestMatch)"
    }

    /// Renders the offscreen text/visual base once, then creates the static
    /// image and (when Codex animation is active) every complete button-ready
    /// animation frame from that base. The visual signature is evaluated
    /// before any rasterization so a repeated `update(...)` is a no-op.
    private func refreshMenuBarContentBitmap() {
        guard let button = statusItem?.button,
              bitmapRenderContainer.bounds.width > 0,
              bitmapRenderContainer.bounds.height > 0 else {
            return
        }

        bitmapRenderContainer.frame = NSRect(origin: .zero, size: button.bounds.size)
        let scale = button.window?.backingScaleFactor ?? 2
        let placement = MenuBarBitmapImageLayout.placement(
            for: button,
            canonicalBounds: bitmapRenderContainer.bounds
        )
        let signature = makeMenuBarBitmapAnimationVisualSignature(
            button: button,
            placement: placement,
            scale: scale
        )

        if let cachedSignature = cachedMenuBarContentVisualSignature,
           signature.matchesStaticContent(of: cachedSignature),
           cachedMenuBarTextBitmap != nil,
           cachedStaticMenuBarContentBitmap != nil {
            if activeClient.usesRotationAnimation, codexAnimationBackend == .nativeCoreAnimation {
                if shouldUseNativeCodexAnimation {
                    _ = synchronizeNativeCodexAnimationHost()
                } else {
                    deactivateNativeCodexAnimation()
                    restoreStaticMenuBarBitmap()
                }
            } else if activeClient.usesRotationAnimation,
                      shouldUseStableCodexAnimation,
                      stableCodexAnimationFrameBuffer.image == nil {
                _ = installStableCodexAnimationImage(
                    at: menuBarIconView.currentAnimationFrameIndex
                )
            } else if activeClient == .claude {
                if shouldPrepareClaudeThinkingAnimation {
                    _ = synchronizeClaudeThinkingAnimationHost()
                } else {
                    deactivateClaudeThinkingAnimation()
                    restoreStaticMenuBarBitmap()
                }
            } else if activeClient == .grok {
                if shouldPrepareGrokThinkingAnimation {
                    switch codexAnimationBackend {
                    case .nativeCoreAnimation:
                        _ = synchronizeGrokThinkingAnimationHost()
                    case .stableBitmap:
                        if grokThinkingStableFrameBuffer.image == nil {
                            _ = installStableGrokThinkingImage(at: grokThinkingFrameIndex)
                        }
                    }
                } else {
                    deactivateGrokThinkingAnimation()
                    restoreStaticMenuBarBitmap()
                }
            }
            return
        }

        let sourceImage = menuBarIconView.sourceImageForRendering
        let iconWasHidden = menuBarIconSlot.isHidden
        menuBarIconSlot.isHidden = true
        let renderedTextBitmap = Self.renderViewToTemplateImage(
            bitmapRenderContainer,
            scale: scale
        )
        menuBarIconSlot.isHidden = iconWasHidden

        guard let renderedTextBitmap else {
            invalidateBitmapContentCache(setPlaceholder: true)
            return
        }
        let textBitmap = Self.placeTemplateImage(renderedTextBitmap, using: placement)
            ?? renderedTextBitmap
        let iconViewBounds = menuBarIconView.convert(
            menuBarIconView.bounds,
            to: bitmapRenderContainer
        )
        let imageViewBounds = placement.imageRect(forCanonicalRect: iconViewBounds)
        let iconDrawRect: NSRect?
        if !iconWasHidden {
            iconDrawRect = Self.fittedIconDrawRect(
                for: sourceImage,
                in: imageViewBounds
            )
        } else {
            iconDrawRect = nil
        }

        let staticImage: NSImage?
        if let sourceImage, let iconDrawRect {
            staticImage = Self.makeCompleteMenuBarBitmap(
                textBitmap: textBitmap,
                iconImage: sourceImage,
                iconDrawRect: iconDrawRect,
                canvasSize: placement.canvasSize
            )
        } else {
            staticImage = textBitmap
        }
        guard let staticImage else {
            invalidateBitmapContentCache(setPlaceholder: true)
            return
        }

        cachedMenuBarTextBitmap = textBitmap
        cachedStaticMenuBarContentBitmap = staticImage
        cachedMenuBarContentVisualSignature = signature
        menuBarBitmapImagePlacement = placement
        cachedMenuBarIconDrawRect = iconDrawRect

        if activeClient.usesRotationAnimation, shouldUseNativeCodexAnimation {
            if !synchronizeNativeCodexAnimationHost() {
                activateTemporaryStableBitmapFallback()
            }
        } else if activeClient.usesRotationAnimation, codexAnimationBackend == .nativeCoreAnimation {
            deactivateNativeCodexAnimation()
            button.image = staticImage
        } else if activeClient.usesRotationAnimation, shouldUseStableCodexAnimation {
            if !installStableCodexAnimationImage(
                at: menuBarIconView.currentAnimationFrameIndex
            ) {
                menuBarIconView.stopRotating()
                button.image = staticImage
            }
        } else if activeClient == .claude, shouldPrepareClaudeThinkingAnimation {
            if !synchronizeClaudeThinkingAnimationHost() {
                deactivateClaudeThinkingAnimation()
                button.image = staticImage
            }
        } else if activeClient == .grok, shouldPrepareGrokThinkingAnimation {
            switch codexAnimationBackend {
            case .nativeCoreAnimation:
                if !synchronizeGrokThinkingAnimationHost() {
                    deactivateGrokThinkingAnimation()
                    button.image = staticImage
                }
            case .stableBitmap:
                if !installStableGrokThinkingImage(at: grokThinkingFrameIndex) {
                    deactivateGrokThinkingAnimation()
                    button.image = staticImage
                }
            }
        } else {
            deactivateClaudeThinkingAnimation()
            deactivateGrokThinkingAnimation()
            button.image = staticImage
        }
    }

    /// Builds one complete button-ready bitmap. `iconDrawRect` is resolved at
    /// cache-build time, so callers on the animation tick only select an image
    /// and assign it to the status button.
    private static func makeCompleteMenuBarBitmap(
        textBitmap: NSImage,
        iconImage: NSImage?,
        iconDrawRect: NSRect?,
        canvasSize: NSSize
    ) -> NSImage? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let composed = NSImage(size: canvasSize)
        composed.isTemplate = true
        composed.lockFocusFlipped(true)
        defer { composed.unlockFocus() }
        textBitmap.draw(
            in: NSRect(origin: .zero, size: canvasSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        if let iconImage, let iconDrawRect {
            MenuBarTemplateIconEmphasis.draw(iconImage, in: iconDrawRect)
        }
        return composed
    }

    private static func fittedIconDrawRect(
        for iconImage: NSImage?,
        in imageViewBounds: NSRect
    ) -> NSRect? {
        guard let iconImage,
              iconImage.size.width > 0,
              iconImage.size.height > 0,
              imageViewBounds.width > 0,
              imageViewBounds.height > 0 else {
            return nil
        }
        let scaleFactor = min(
            imageViewBounds.width / iconImage.size.width,
            imageViewBounds.height / iconImage.size.height,
            1
        )
        let fittedSize = NSSize(
            width: iconImage.size.width * scaleFactor,
            height: iconImage.size.height * scaleFactor
        )
        return NSRect(
            x: imageViewBounds.midX - fittedSize.width / 2,
            y: imageViewBounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private static func placeTemplateImage(
        _ image: NSImage,
        using placement: MenuBarBitmapImagePlacement
    ) -> NSImage? {
        guard !placement.isIdentity else { return image }
        let canvas = NSImage(size: placement.canvasSize)
        canvas.isTemplate = true
        canvas.lockFocusFlipped(true)
        let offset = placement.canonicalToImageOffset
        image.draw(
            in: NSRect(
                x: offset.width,
                y: offset.height,
                width: image.size.width,
                height: image.size.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        canvas.unlockFocus()
        return canvas
    }

    private static func renderViewToTemplateImage(_ view: NSView, scale: CGFloat) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let pixelDimensions = MenuBarBitmapImageLayout.pixelDimensions(
            for: bounds.size,
            scale: scale
        )
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelDimensions.width,
            pixelsHigh: pixelDimensions.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    private func menuBarSnapshot(for snapshot: Snapshot) -> Snapshot {
        snapshot.menuBarSnapshot(
            preferredQuotaWindow: settings.quotaWindowPreference,
            automaticallyUseLunaReserve: settings.autoSwitchLunaReserve
        )
    }

    /// Re-evaluated whenever the menu opens or ⌘R is pressed, so the item
    /// becomes available again as soon as the rate-limit wait ends.
    var isManualRefreshAvailable: Bool {
        actions.manualRefreshBlockedUntil().map { Date() >= $0 } ?? true
    }

    /// The refresh item only says something when the login has expired: that is the one state the user
    /// must act on (the menu closes on click). The action title stays fixed; the hint is the subtitle.
    func manualRefreshMenuSubtitle() -> String? {
        actions.isClaudeLoginExpired() ? tr(.keyStatusItemControllerRefreshNowLoginExpired) : nil
    }

    private func applyManualRefreshContent(to item: NSMenuItem) {
        item.title = tr(.keyStatusItemControllerRefreshNow)
        let subtitle = manualRefreshMenuSubtitle()
        if #available(macOS 14.4, *) {
            item.attributedTitle = nil
            item.subtitle = subtitle
        } else if let subtitle {
            let text = NSMutableAttributedString(
                string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            item.attributedTitle = text
        } else {
            item.attributedTitle = nil
        }
    }

    @objc private func manualRefresh() {
        guard isManualRefreshAvailable else { return }
        actions.manualRefresh()
        if settings.keepMenuOpenAfterRefresh {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.statusItem?.button?.performClick(nil)
            }
        }
    }

    @objc private func openDashboard() { actions.openDashboard() }
    @objc private func openChatGPT() { actions.openChatGPT() }

    private func openCurrentAgentMenuTitle() -> String {
        switch menuInput.activeClient {
        case .codex:
            return tr(.keyStatusItemControllerOpenChatgpt)
        case .claude:
            return tr(.keyStatusItemControllerOpenClaude)
        case .grok:
            return tr(.keyStatusItemControllerOpenGrok)
        }
    }
    @objc private func openCCSwitch() { actions.openCCSwitch() }
    @objc private func quit() { actions.quit() }

    @objc private func switchProvider(_ sender: NSMenuItem) {
        guard let providerID = sender.representedObject as? String else { return }
        guard !menuInput.aggregationQuickSwitchBlocked, sender.isEnabled, sender.action != nil else { return }
        actions.switchProvider(providerID)
    }

    @objc private func openStatusLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        actions.openStatusLink(url)
    }

    /// The accent-tinted realtime-boost prompt row under the quota card.
    private func makeModPromptItem() -> NSMenuItem? {
        guard menuInput.modRow == .prompt else { return nil }
        let view = ModPromptRowView(localize: modOnboardingLocalize)
        view.onClick = { [weak self] in self?.openModOnboarding() }
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func openModOnboarding() {
        // The menu is closing; open the window once it is gone.
        DispatchQueue.main.async { [weak self] in self?.actions.showModOnboarding() }
    }

    private func makeOpenDashboardMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: tr(.keyStatusItemControllerOpenMainWindow),
            action: #selector(openDashboard),
            keyEquivalent: ""
        )
        item.target = self
        if menuInput.showsAvailableUpdateBadge {
            item.badge = NSMenuItemBadge(
                string: tr(.keyStatusItemControllerUpdateAvailableBadge)
            )
        }
        return item
    }

    private func rebuildStatusMenu(reason: String? = nil, replacingMenu: Bool = false) {
        guard !isStatusMenuTracking else { statusMenuNeedsRebuild = true; return }
        let oldMenu = statusMenu
        let menu = replacingMenu ? NSMenu() : oldMenu
        let previousDistanceFromTop = aggregationViewport.flatMap { scroll in
            scroll.documentView.map { max(0, $0.frame.height - scroll.contentView.bounds.maxY) }
        }
        if replacingMenu {
            if let outgoingWindow = oldMenu.items.first?.view?.window, outgoingWindow.isVisible {
                retainRetiringStatusMenu(oldMenu, until: outgoingWindow)
            }
            releaseHiddenRetiringStatusMenus()
            statusMenu = menu
            menu.delegate = self
            if !isStatusMenuDetachedForCustomClick {
                statusItem?.menu = menu
            }
            // The retiring menu owns its old card tree until its window hides.
            // Start new aggregation state without detaching or reusing that tree.
            aggregationViewport = nil
            aggregationViewportShowsSingleCard = false
            aggregationCards = [:]
            aggregationOrder = []
            if let aggregationBoundsObserver { NotificationCenter.default.removeObserver(aggregationBoundsObserver) }
            aggregationBoundsObserver = nil
        }
        statusMenuNeedsRebuild = false
        statusMenuNeedsNativeStructureRebuild = false
        releaseHiddenRetiringStatusMenus()
        menuDismissalTrace?.record("menu.rebuild.removeAllItems", view: oldMenu.items.first?.view,
            details: "reason=\(reason ?? menuRebuildReason)")
        logAggregationLifecycle(reason: "rebuild-" + menuRebuildReason)
        statusMenuRebuildCountForTesting += 1
        // A custom view must not move from a retired menu item to a new one.
        // Keep card subtrees, but give each rebuilt item a fresh AppKit host.
        if !replacingMenu, aggregationViewport != nil {
            oldMenu.items.first?.view = nil
            (aggregationViewport as? AggregationOverviewScrollView)?.setMenuContentVisible(false)
            aggregationViewport = nil
            aggregationViewportShowsSingleCard = false
            if let aggregationBoundsObserver { NotificationCenter.default.removeObserver(aggregationBoundsObserver) }
            aggregationBoundsObserver = nil
        }
        if !replacingMenu { menu.removeAllItems() }
        if menuInput.aggregatedProviders.isEmpty {
            clearAggregationOverview()
            menu.addItem(makeOverviewMenuItem(for: snapshot))
        } else {
            let item = NSMenuItem()
            let viewport = makeAggregationOverview()
            if let previousDistanceFromTop {
                (viewport as? AggregationOverviewScrollView)?.restoreViewportAfterMount(distanceFromTop: previousDistanceFromTop)
            }
            item.view = viewport
            menu.addItem(item)
        }
        // The realtime-boost prompt sits right under the quota card, above Quick Switch.
        if let prompt = makeModPromptItem() { menu.addItem(prompt) }
        menu.addItem(.separator())
        if menuInput.showQuickSwitchMenu {
            menu.addItem(makeQuickSwitchMenuItem())
        }
        let refreshItem = menu.addItem(
            withTitle: tr(.keyStatusItemControllerRefreshNow),
            action: #selector(manualRefresh),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        applyManualRefreshContent(to: refreshItem)
        menu.addItem(.separator())
        menu.addItem(makeOpenDashboardMenuItem())
        if menuInput.showOpenChatGPTMenu {
            menu.addItem(
                withTitle: openCurrentAgentMenuTitle(),
                action: #selector(openChatGPT),
                keyEquivalent: ""
            ).target = self
        }
        if menuInput.showOpenCCSwitchMenu {
            menu.addItem(
                withTitle: tr(.keyStatusItemControllerOpenCcSwitch),
                action: #selector(openCCSwitch),
                keyEquivalent: ""
            ).target = self
        }
        if menuInput.showStatusMenu {
            menu.addItem(makeStatusLinksMenuItem())
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: tr(.keyStatusItemControllerQuitBalancebar),
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self
        (menu.items.first?.view as? MenuHoverLinkHostView)?.setDismissalTrace(menuDismissalTrace)
        menuDismissalTrace?.record("menu.rebuild.complete", view: menu.items.first?.view,
            details: "reason=\(reason)")
        let statusWindow = statusItem?.button?.window
        SwitchLog.write(
            "status menu rendered; item_count=\(statusMenu.items.count); status_visible=\(isVisible); button_window=\(statusWindow != nil); window_visible=\(statusWindow?.isVisible ?? false); window_occlusion_visible=\(statusWindow?.occlusionState.contains(.visible) ?? false); window_occlusion_raw=\(statusWindow?.occlusionState.rawValue ?? 0); image=\(statusItem?.button?.image != nil)",
            level: .debug,
            category: "ui.status-menu",
            throttleKey: "status-menu-render",
            minimumInterval: 1
        )
    }

    private func retainRetiringStatusMenu(_ menu: NSMenu, until window: NSWindow) {
        let identity = ObjectIdentifier(menu)
        guard retiringStatusMenuObservers[identity] == nil else { return }
        retiringStatusMenus.append(menu)
        scheduleRetiringStatusMenuRelease(identity, attempt: 0)
        let notifications: [Notification.Name] = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification]
        retiringStatusMenuObservers[identity] = notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                guard let self, let window else { return }
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, !window.isVisible else { return }
                    self.releaseRetiringStatusMenu(identity)
                }
            }
        }
    }

    private func releaseRetiringStatusMenu(_ identity: ObjectIdentifier) {
        retiringStatusMenus.removeAll { ObjectIdentifier($0) == identity }
        retiringStatusMenuObservers.removeValue(forKey: identity)?.forEach(NotificationCenter.default.removeObserver)
    }

    private func releaseHiddenRetiringStatusMenus() {
        let hiddenIdentities = retiringStatusMenus
            .filter { $0.items.first?.view?.window?.isVisible != true }
            .map(ObjectIdentifier.init)
        hiddenIdentities.forEach(releaseRetiringStatusMenu)
    }

    private func scheduleRetiringStatusMenuRelease(_ identity: ObjectIdentifier, attempt: Int) {
        let delay = attempt < 40 ? 0.05 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.retiringStatusMenuObservers[identity] != nil else { return }
            guard let menu = self.retiringStatusMenus.first(where: { ObjectIdentifier($0) == identity }) else {
                self.releaseRetiringStatusMenu(identity)
                return
            }
            if menu.items.first?.view?.window?.isVisible != true {
                self.releaseRetiringStatusMenu(identity)
            } else {
                self.scheduleRetiringStatusMenuRelease(identity, attempt: min(attempt + 1, 41))
            }
        }
    }

    private func makeStatusLinksMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: tr(.keyStatusItemControllerViewStatus), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: tr(.keyStatusItemControllerViewStatus2))
        for link in menuInput.statusLinks {
            let title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let url = URL(string: address),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else { continue }
            let item = NSMenuItem(
                title: title,
                action: #selector(openStatusLink(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            let empty = NSMenuItem(
                title: tr(.keyStatusItemControllerNoStatusLinksConfigured),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        parent.submenu = submenu
        return parent
    }

    private func makeQuickSwitchMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: tr(.keyStatusItemControllerQuickSwitch), action: nil, keyEquivalent: "")
        parent.identifier = NSUserInterfaceItemIdentifier("quickSwitch.parent")
        let submenu = NSMenu(title: tr(.keyStatusItemControllerQuickSwitch2))
        submenu.autoenablesItems = false
        let menuChoices = QuickSwitchMenuModel.entries(from: menuInput.choices)
        if menuChoices.isEmpty {
            submenu.minimumWidth = QuickSwitchTitleLayout.minimumTabLocation
                + QuickSwitchTitleLayout.menuChromeWidth
            let empty = NSMenuItem(title: tr(.keyStatusItemControllerNoCodexProviderFound), action: nil, keyEquivalent: "")
            empty.identifier = NSUserInterfaceItemIdentifier("quickSwitch.empty")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            let font = NSFont.menuFont(ofSize: 0)
            let summaries = menuChoices.map { menuInput.quickSwitchSummaries[$0.id] ?? "…" }
            let layout = QuickSwitchTitleLayout.make(
                names: menuChoices.map(\.name),
                summaries: summaries,
                font: font
            )
            submenu.minimumWidth = layout.minimumMenuWidth
            for (index, choice) in menuChoices.enumerated() {
                let item = NSMenuItem(
                    title: "",
                    action: #selector(switchProvider(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = choice.id
                item.state = choice.isCurrent ? .on : .off
                applyQuickSwitchTitle(
                    to: item,
                    displayedName: QuickSwitchTitleLayout.truncatedName(
                        choice.name,
                        fitting: layout.nameColumnWidth,
                        font: font
                    ),
                    summary: summaries[index],
                    tabLocation: layout.tabLocation
                )
                submenu.addItem(item)
            }
        }
        SwitchLog.write(
            "quick-switch menu built; app_type=\(menuInput.activeClient.appType); choice_count=\(menuInput.choices.count); submenu_item_count=\(submenu.items.count); choices_omitted=true; empty_state=\(menuInput.choices.isEmpty)",
            level: .debug,
            category: "provider.menu",
            throttleKey: "quick-switch-menu-\(menuInput.activeClient.appType)",
            minimumInterval: 1
        )
        applyQuickSwitchProtection(to: submenu)
        parent.submenu = submenu
        return parent
    }

    private func applyQuickSwitchTitle(
        to item: NSMenuItem,
        displayedName: String,
        summary: String,
        tabLocation: CGFloat
    ) {
        let title = "\(displayedName)\t\(summary)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tabLocation)]
        paragraph.defaultTabInterval = tabLocation
        paragraph.lineBreakMode = .byClipping
        item.title = title
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .paragraphStyle: paragraph
            ]
        )
    }

    private func clearAggregationOverview() {
        aggregationViewportShowsSingleCard = false
        aggregationOrder = []
        aggregationCards.values.forEach { ($0.card as? MenuHoverLinkHostView)?.setMenuContentVisible(false) }
        aggregationCards.removeAll()
        (aggregationViewport as? AggregationOverviewScrollView)?.setMenuContentVisible(false)
        aggregationViewport = nil
        if let aggregationBoundsObserver { NotificationCenter.default.removeObserver(aggregationBoundsObserver) }
        aggregationBoundsObserver = nil
    }

    private func directCardContext(for snapshot: Snapshot) -> OverviewCardContext {
        OverviewCardContext(snapshot: snapshot,
            identity: menuInput.directProviderID.map { menuInput.activeClient.rawValue + "|" + $0 } ?? snapshot.provider,
            account: menuInput.openAIAccount, date: refreshDate, noteTags: menuInput.directProviderNotes,
            paceClient: menuInput.activeClient)
    }

    private func cardContext(_ display: AggregatedProviderDisplay) -> OverviewCardContext {
        OverviewCardContext(snapshot: display.snapshot, identity: display.identity.numericScope,
            account: display.account, date: display.fetchedAt, notes: display.entry.source.notes, noteTags: display.groupedNotes)
    }

    private func logAggregationLifecycle(reason: String) {
        guard AggregationOverviewScrollView.diagnosticsEnabled else { return }
        SwitchLog.write("aggregation lifecycle; reason=\(reason); tracking=\(isStatusMenuTracking); providers=\(menuInput.aggregatedProviders.count); rebuilds=\(statusMenuRebuildCountForTesting); placements=\(aggregationPlacementCountForTesting); pending=\(statusMenuNeedsRebuild)",
            level: .debug, category: "ui.aggregation", throttleKey: "aggregation-lifecycle-\(reason)", minimumInterval: 0.25)
    }

    private func updateQuickSwitchContent() {
        guard menuQuickSwitchCanMutate else {
            menuDismissalTrace?.record("quick-switch.update.ignored", view: statusMenu.items.first?.view,
                details: "tracking=\(isStatusMenuTracking); window_visible=\(statusMenu.items.first?.view?.window?.isVisible ?? false)")
            return
        }
        guard let submenu = statusMenu.items.first(where: { $0.identifier?.rawValue == "quickSwitch.parent" })?.submenu else { return }
        let choices = QuickSwitchMenuModel.entries(from: menuInput.choices)
        let font = NSFont.menuFont(ofSize: 0)
        let summaries = choices.map { menuInput.quickSwitchSummaries[$0.id] ?? "…" }
        let layout = QuickSwitchTitleLayout.make(names: choices.map(\.name), summaries: summaries, font: font)
        submenu.minimumWidth = layout.minimumMenuWidth
        var desired: [NSMenuItem] = []
        for (index, choice) in choices.enumerated() {
            let item = submenu.items.first { $0.representedObject as? String == choice.id }
                ?? NSMenuItem(title: "", action: #selector(switchProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            applyQuickSwitchTitle(to: item, displayedName: QuickSwitchTitleLayout.truncatedName(choice.name,
                fitting: layout.nameColumnWidth, font: font), summary: summaries[index], tabLocation: layout.tabLocation)
            item.state = !menuInput.aggregationQuickSwitchBlocked && choice.isCurrent ? .on : .off
            item.isEnabled = !menuInput.aggregationQuickSwitchBlocked
            desired.append(item)
        }
        if choices.isEmpty {
            let id = NSUserInterfaceItemIdentifier("quickSwitch.empty")
            let empty = submenu.items.first { $0.identifier == id }
                ?? NSMenuItem(title: tr(.keyStatusItemControllerNoCodexProviderFound), action: nil, keyEquivalent: "")
            empty.identifier = id
            empty.isEnabled = false
            desired.append(empty)
        }
        // Reconcile only this submenu. Sorting or editing Providers must never
        // retire the menu item that owns the mounted aggregation viewport.
        for item in submenu.items where !desired.contains(where: { $0 === item }) { submenu.removeItem(item) }
        for (index, item) in desired.enumerated() where index >= submenu.numberOfItems || submenu.item(at: index) !== item {
            if item.menu === submenu { submenu.removeItem(item) }
            submenu.insertItem(item, at: index)
        }
        applyQuickSwitchProtection(to: submenu)
    }

    private func updateQuickSwitchProtection() {
        guard menuQuickSwitchCanMutate else { return }
        guard let submenu = statusMenu.items.first(where: { $0.identifier?.rawValue == "quickSwitch.parent" })?.submenu else { return }
        applyQuickSwitchProtection(to: submenu)
    }

    private func applyQuickSwitchProtection(to submenu: NSMenu) {
        submenu.autoenablesItems = false
        let blocked = menuInput.quickSwitchSafety.isBlocked
        for item in submenu.items where item.representedObject is String {
            item.isEnabled = !blocked
            item.action = blocked ? nil : #selector(switchProvider(_:))
            item.target = blocked ? nil : self
            item.state = !blocked && menuInput.choices.contains(where: { $0.id == item.representedObject as? String && $0.isCurrent }) ? .on : .off
        }
        let owned = ["aggregation.quickSwitch.hint", "quickSwitch.manage", "quickSwitch.separator"]
        for item in submenu.items where owned.contains(item.identifier?.rawValue ?? "") { submenu.removeItem(item) }
        if blocked {
            let hint = NSMenuItem(title: menuInput.quickSwitchSafety.hint, action: nil, keyEquivalent: "")
            hint.identifier = NSUserInterfaceItemIdentifier("aggregation.quickSwitch.hint")
            hint.isEnabled = false
            submenu.insertItem(hint, at: 0)
            let separator = NSMenuItem.separator()
            separator.identifier = NSUserInterfaceItemIdentifier("quickSwitch.separator")
            submenu.addItem(separator)
            let manage = NSMenuItem(title: tr(.keyQuickSwitchManageInCCSwitch), action: #selector(openCCSwitch), keyEquivalent: "")
            manage.identifier = NSUserInterfaceItemIdentifier("quickSwitch.manage")
            manage.target = self
            manage.isEnabled = true
            submenu.addItem(manage)
        }
    }

    /// Places existing cards only; all metric/ticket geometry stays with #492.
    /// One native menu view contains the document and its bounded viewport.
    private func makeAggregationOverview() -> NSScrollView {
        let scroll: NSScrollView
        let document: NSView
        if let existing = aggregationViewport, let existingDocument = existing.documentView {
            scroll = existing
            if aggregationViewportShowsSingleCard {
                document = NSView(frame: .zero)
                scroll.documentView = document
                aggregationViewportShowsSingleCard = false
            } else { document = existingDocument }
        } else {
            scroll = AggregationOverviewScrollView(frame: .zero)
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.borderType = .noBorder
            scroll.identifier = NSUserInterfaceItemIdentifier("aggregation.overview")
            document = NSView(frame: .zero)
            scroll.documentView = document
            aggregationViewport = scroll
            (scroll as? AggregationOverviewScrollView)?.diagnosticContext = { [weak self] in
                guard let self else { return "" }
                return "tracking=\(self.isStatusMenuTracking); rebuilds=\(self.statusMenuRebuildCountForTesting); placements=\(self.aggregationPlacementCountForTesting)"
            }
            scroll.contentView.postsBoundsChangedNotifications = true
            aggregationBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                self?.aggregationCards.values.forEach { ($0.card as? MenuHoverLinkHostView)?.refreshMarqueeVisibility() }
                (self?.aggregationViewport as? AggregationOverviewScrollView)?.logGeometry(reason: "clip-bounds")
            }
        }
        let oldHeight = document.frame.height
        let distanceFromTop = max(0, oldHeight - scroll.contentView.bounds.maxY)
        let order = aggregationOverviewDisplays.map(\.identity)
        var needsPlacement = aggregationOrder != order
        let identities = Set(order)
        for identity in aggregationCards.keys.filter({ !identities.contains($0) }) {
            let old = aggregationCards.removeValue(forKey: identity)
            (old?.card as? MenuHoverLinkHostView)?.setMenuContentVisible(false)
            old?.wrapper.removeFromSuperview()
        }
        var total: CGFloat = 0
        let gap: CGFloat = 8
        for display in aggregationOverviewDisplays {
            let context = cardContext(display)
            var record: AggregationCard
            if var existing = aggregationCards[display.identity], existing.snapshot.kind == display.snapshot.kind {
                if let host = existing.card as? MenuHoverLinkHostView {
                    reconcileOverviewSections(in: host, context: context)
                    // Third-party cards have no section topology. Their source
                    // link is unchanged because configuration is part of identity.
                    if display.snapshot.kind == .balance {
                        let presentation = display.snapshot.officialQuotaMenuPresentation(
                            lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
                            hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota)
                        let layout = makeOverviewCardLayout(for: display.snapshot, presentation: presentation, account: context.account, aggregation: true)
                        reconcileBalanceLayout(in: host, next: layout)
                        if layout.progress == nil {
                            host.subviews.compactMap { $0 as? QuotaProgressView }.forEach { $0.removeFromSuperview() }
                        } else if !host.subviews.contains(where: { $0 is QuotaProgressView }),
                                  let frame = layout.progress,
                                  let sample = OverviewNumericPresentation.samples(snapshot: display.snapshot, providerIdentity: context.identity,
                                      lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
                                      hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota,
                                      showBankedReset: settings.showBankedReset).first {
                            host.addSubview(makeOverviewNumericProgress(plan: overviewNumericPlan(for: sample), frame: frame))
                        }
                        let labels = existing.card.subviews.compactMap { $0 as? NSTextField }
                        labels.first { $0.font?.pointSize == 15 }?.stringValue = display.snapshot.overviewProvider
                        labels.first { $0.identifier?.rawValue == "overview.refreshTime" }?.stringValue = display.fetchedAt.map {
                            AppDisplayTime.formatter(timeZone: settings.displayTimeZone).string(from: $0)
                        } ?? "--:--:--"
                    }
                } else if existing.snapshot != display.snapshot {
                    existing.card.removeFromSuperview()
                    existing.card = makeOverviewMenuItem(for: display.snapshot, context: context).view!
                    existing.wrapper.addSubview(existing.card)
                }
                existing.snapshot = display.snapshot
                record = existing
            } else {
                if let old = aggregationCards[display.identity] {
                    (old.card as? MenuHoverLinkHostView)?.setMenuContentVisible(false)
                    old.wrapper.removeFromSuperview()
                }
                let wrapper = NSView(frame: .zero)
                let card = makeOverviewMenuItem(for: display.snapshot, context: context).view!
                wrapper.addSubview(card)
                document.addSubview(wrapper)
                record = AggregationCard(wrapper: wrapper, card: card, snapshot: display.snapshot)
                needsPlacement = true
            }
            if record.wrapper.superview !== document {
                document.addSubview(record.wrapper)
                needsPlacement = true
            }
            updateOverviewHeaderNotes(in: record.card, context: context)
            updateOverviewQuotaDetail(in: record.card, context: context)
            updateBalanceSubtitle(in: record.card, context: context)
            alignSingleLineBalance(in: record.card, snapshot: context.snapshot)
            record.card.frame.origin = .zero
            let size = record.card.frame.size
            if record.wrapper.frame.size != size { needsPlacement = true; record.wrapper.frame.size = size }
            updateAggregationTimestamp(in: record.card, display: display)
            if !isStatusMenuTracking { prepareClosedAggregationNumerics(in: record.card, context: context) }
            record.wrapper.identifier = NSUserInterfaceItemIdentifier("aggregation.provider.\(display.entry.providerID)")
            record.wrapper.setAccessibilityElement(true)
            record.wrapper.setAccessibilityRole(.group)
            record.wrapper.setAccessibilityLabel(display.entry.source.name + (display.entry.role == .default ? " · " + tr(.keyAggregationDefault) : ""))
            aggregationCards[display.identity] = record
            total += record.wrapper.frame.height + gap
        }
        total = max(0, total - gap)
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let footer = CGFloat(max(10, statusMenu.numberOfItems)) * 24 + 60
        let maximum = max(80, (screen?.visibleFrame.height ?? 800) - footer)
        let viewportSize = NSSize(width: OpenCodexCardLayout.cardWidth, height: min(total, maximum))
        if scroll.frame.size != viewportSize { needsPlacement = true }
        if needsPlacement {
            aggregationPlacementCountForTesting += 1
            document.frame.size = NSSize(width: OpenCodexCardLayout.cardWidth, height: total)
            var y = total
            for display in aggregationOverviewDisplays {
                guard let record = aggregationCards[display.identity] else { continue }
                y -= record.wrapper.frame.height
                record.wrapper.frame.origin = NSPoint(x: 0, y: y)
                y -= gap
            }
            scroll.frame.size = viewportSize
            (scroll as? AggregationOverviewScrollView)?.restoreViewport(distanceFromTop: distanceFromTop)
            logAggregationLifecycle(reason: "place-cards")
        }
        aggregationOrder = order
        for record in aggregationCards.values {
            let host = record.card as? MenuHoverLinkHostView
            if host?.isMenuContentVisible != isStatusMenuTracking { host?.setMenuContentVisible(isStatusMenuTracking) }
        }
        (scroll as? AggregationOverviewScrollView)?.setMenuContentVisible(isStatusMenuTracking)
        // Cards came or went: drop a removed focus owner, recede newcomers.
        (scroll as? AggregationOverviewScrollView)?.reconcileFocusOwnership()
        presentedOverviewNumerics = currentOverviewNumericSamples()
        (scroll as? AggregationOverviewScrollView)?.logGeometry(reason: "overview-updated")
        return scroll
    }

    private func prepareClosedAggregationNumerics(in card: NSView, context: OverviewCardContext) {
        let amounts = overviewNumericTextViews(in: card)
        let links = overviewNumericLinkFields(in: card)
        let progressViews = overviewNumericProgressViews(in: card)
        progressViews.forEach { $0.setColorConfiguration(settings.quotaProgressColorConfiguration) }
        for sample in numericSamples(for: context) {
            let matchingAmounts = amounts.filter { $0.sample?.identity == sample.identity }
            let matchingLinks = links.filter { $0.sample?.identity == sample.identity }
            guard matchingAmounts.contains(where: { $0.sample != sample })
                || matchingLinks.contains(where: { $0.sample != sample }) else { continue }
            let plan = overviewNumericPlan(for: sample)
            matchingAmounts.forEach { $0.configure(plan: plan, sample: sample) }
            matchingLinks.forEach { $0.configure(plan: plan, sample: sample) }
            if let target = sample.progressPercentage, let progress = progressViews.first(where: {
                $0.identifier == OverviewNumericPresentation.progressIdentifier(for: sample.identity)
            }) {
                progress.preparePercentage(from: plan.startProgress ?? target, to: target,
                    duration: OverviewNumericTransition.duration(for: sample.format))
            }
        }
    }

    private func updateOverviewHeaderNotes(in card: NSView, context: OverviewCardContext) {
        guard let title = descendantViews(of: card, as: NSTextField.self).first(where: {
            $0.identifier?.rawValue == "overview.providerTitle"
        }), let header = title.superview,
        let time = descendantViews(of: card, as: NSTextField.self).first(where: {
            $0.identifier?.rawValue == "overview.refreshTime"
        }) else { return }
        let prefix = "aggregation.notes." + context.identity
        let existing = header.subviews.compactMap { $0 as? AggregationNoteTagView }
        let titleFrame: NSRect
        if let layout = (card as? MenuHoverLinkHostView)?.overviewLayout {
            titleFrame = layout.title.offsetBy(dx: header === card ? 0 : -header.frame.minX,
                                              dy: header === card ? 0 : -header.frame.minY)
        } else { titleFrame = existing.first?.originalTitleFrame ?? title.frame }
        let raw = context.noteTags ?? context.notes.map { [$0] } ?? []
        let notes = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var labels = Array(notes.prefix(2))
        if notes.count > 2 { labels.append("+\(notes.count - 2)") }
        title.toolTip = context.snapshot.overviewProvider
        title.setAccessibilityLabel(context.snapshot.overviewProvider)
        title.lineBreakMode = .byTruncatingTail
        if let link = title as? HoverLinkTextField {
            let url = context.snapshot.websiteURL.flatMap { url -> URL? in
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
                return url
            }
            link.onActivate = url.map { url in { [weak self] in self?.actions.openStatusLink(url) } }
        }
        for tag in existing where !labels.indices.contains(where: { tag.identifier?.rawValue == prefix + ".\($0)" }) {
            tag.removeFromSuperview()
        }
        guard !labels.isEmpty else { title.frame = titleFrame; return }
        let available = max(0, header.convert(time.frame, from: time.superview).minX - 6 - titleFrame.minX)
        let font = NSFont.systemFont(ofSize: 11)
        let desired = labels.enumerated().map { index, text -> CGFloat in
            let measure = NSTextField(labelWithString: text)
            measure.font = font
            measure.usesSingleLineMode = true
            return min(available / 2, max(index == 2 ? 24 : 36,
                ceil(max(AccountMarqueeView.textWidth(of: text, font: font), measure.cell?.cellSize.width ?? 0)) + 14))
        }
        let gaps = CGFloat(labels.count - 1) * 4
        let budget = max(0, available - min(labels.count > 2 ? 48 : 64, titleFrame.width) - 8 - gaps)
        let minimum = labels.indices.map { index in
            labels[index].count <= 6 ? desired[index] : CGFloat(index == 2 ? 24 : 36)
        }
        let extra = max(0, min(desired.reduce(0, +) - minimum.reduce(0, +), budget - minimum.reduce(0, +)))
        let wantedExtra = max(1, desired.reduce(0, +) - minimum.reduce(0, +))
        let minimumScale = min(1, budget / max(1, minimum.reduce(0, +)))
        let widths = labels.indices.map { minimum[$0] * minimumScale + extra * max(0, desired[$0] - minimum[$0]) / wantedExtra }
        let titleWidth = min(ceil(title.cell?.cellSize.width ?? titleFrame.width), max(0, available - widths.reduce(0, +) - gaps - 8))
        title.frame = NSRect(x: titleFrame.minX, y: titleFrame.minY, width: titleWidth, height: titleFrame.height)
        var x = title.frame.maxX + 8
        let capCenter = title.frame.maxY - title.firstBaselineOffsetFromTop + (title.font?.capHeight ?? 0) / 2
        for index in labels.indices {
            let id = NSUserInterfaceItemIdentifier(prefix + ".\(index)")
            let frame = NSRect(x: x, y: capCenter - 7.5, width: widths[index], height: 15)
            let tag = existing.first { $0.identifier == id } ?? AggregationNoteTagView(text: labels[index], frame: frame)
            tag.identifier = id
            tag.originalTitleFrame = titleFrame
            tag.frame = frame
            tag.updateText(labels[index])
            if index == 2 { tag.toolTip = notes.joined(separator: "\n"); tag.setAccessibilityLabel(notes.joined(separator: ", ")) }
            if tag.superview == nil { header.addSubview(tag) }
            tag.layoutSubtreeIfNeeded()
            x += widths[index] + 4
        }
    }

    private func updateOverviewQuotaDetail(in card: NSView, context: OverviewCardContext) {
        guard let host = card as? MenuHoverLinkHostView,
              let layout = host.overviewLayout,
              let detail = descendantViews(of: card, as: AccountMarqueeView.self).first(where: {
                  $0.identifier?.rawValue == "overview.quotaDetail"
              }) else { return }
        let amountText = numericSamples(for: context).first.map { overviewNumericPlan(for: $0).layoutReservationText }
            ?? context.snapshot.overviewLargeAmount
        let amountFont = NSFont.monospacedDigitSystemFont(
            ofSize: OpenCodexCardLayout.quotaAmountPointSize,
            weight: .semibold
        )
        detail.frame = overviewMarqueeFrame(
            layout.quotaDetail,
            avoidingAmountFrame: layout.amount,
            amountText: amountText,
            amountFont: amountFont,
            minimumAmountGap: context.snapshot.kind == .balance ? 12 : 0
        )
        detail.updateText(context.snapshot.overviewQuotaDetail, preserveScrollPosition: false)
    }

    private func reconcileBalanceLayout(in host: MenuHoverLinkHostView, next: OpenCodexCardFrames) {
        guard let previous = host.overviewLayout, previous != next else { return }
        let shift = next.cardSize.height - previous.cardSize.height
        for child in host.subviews where !(child is QuotaProgressView) {
            if child is OverviewNumericTextView || (child as? NSTextField)?.font?.pointSize == OpenCodexCardLayout.quotaAmountPointSize {
                child.frame = next.amount
            } else if child.identifier?.rawValue == "overview.quotaDetail" {
                child.frame.origin.y = next.quotaDetail.minY
            } else { child.frame.origin.y += shift }
        }
        host.frame.size = next.cardSize
        host.overviewLayout = next
    }

    private func alignSingleLineBalance(in card: NSView, snapshot: Snapshot) {
        guard snapshot.kind == .balance, snapshot.balanceRecharge == nil,
              (card as? MenuHoverLinkHostView)?.overviewLayout?.balanceRecharge == nil,
              let host = card as? MenuHoverLinkHostView, host.overviewLayout?.link == nil,
              let amount = descendantViews(of: card, as: OverviewNumericTextView.self).first,
              let detail = descendantViews(of: card, as: AccountMarqueeView.self).first(where: {
                  $0.identifier?.rawValue == "overview.quotaDetail"
              }) else { return }
        guard let parent = detail.superview else { return }
        detail.frame.origin.y += Self.overviewBaselineY(for: amount.textField, in: parent)
            - Self.overviewBaselineY(for: detail.accountLabel, in: parent)
    }

    static func overviewBaselineY(for label: NSTextField, in parent: NSView) -> CGFloat {
        let y = label.isFlipped ? label.bounds.minY + label.firstBaselineOffsetFromTop
            : label.bounds.maxY - label.firstBaselineOffsetFromTop
        return label.convert(NSPoint(x: label.bounds.minX, y: y), to: parent).y
    }

    private func updateBalanceSubtitle(in card: NSView, context: OverviewCardContext) {
        let id = NSUserInterfaceItemIdentifier("balance.subtitle")
        let aggregation = !menuInput.aggregatedProviders.isEmpty
            || (context.snapshot.kind == .balance && !menuInput.directProviderIsOfficial)
        if aggregation && context.snapshot.kind == .balance {
            let tooltip = context.snapshot.balanceProgressTooltip(timeZone: settings.displayTimeZone)
            descendantViews(of: card, as: QuotaProgressView.self).forEach {
                $0.toolTip = tooltip
                $0.setAccessibilityHelp(tooltip)
            }
        }
        guard (aggregation || context.snapshot.balanceRecharge != nil),
              let row = (card as? MenuHoverLinkHostView)?.overviewLayout?.balanceRecharge,
              context.snapshot.unit != nil else {
            card.subviews.first { $0.identifier == id }?.removeFromSuperview()
            return
        }
        let text = context.snapshot.balanceSubtitle(timeZone: settings.displayTimeZone)
        let hasRechargeHint = context.snapshot.balanceDisplayConsumedCents != nil
        let subtitleFont = NSFont.systemFont(ofSize: OpenCodexCardLayout.quotaResetPointSize)
        let frame: NSRect
        if let layout = (card as? MenuHoverLinkHostView)?.overviewLayout, row.intersects(layout.amount) {
            frame = overviewMarqueeFrame(row, avoidingAmountFrame: layout.amount,
                amountText: numericSamples(for: context).first.map { overviewNumericPlan(for: $0).layoutReservationText }
                    ?? context.snapshot.overviewLargeAmount, amountFont: .monospacedDigitSystemFont(ofSize: OpenCodexCardLayout.quotaAmountPointSize, weight: .semibold), minimumAmountGap: 12)
        } else { frame = row }
        let needsMarquee = textWidth(text, font: subtitleFont) > frame.width + 0.5
        let existing = card.subviews.first { $0.identifier == id }
        let label: NSView
        if needsMarquee {
            let marquee: AccountMarqueeView
            if let existing = existing as? AccountMarqueeView,
               (existing.accountLabel is HoverLinkTextField) == hasRechargeHint {
                marquee = existing
            } else {
                existing?.removeFromSuperview()
                marquee = AccountMarqueeView(text: text, font: subtitleFont,
                    textColor: .secondaryLabelColor, frame: frame,
                    label: hasRechargeHint ? HoverLinkTextField(text: text) : nil)
                card.addSubview(marquee)
            }
            marquee.identifier = id
            marquee.frame = frame
            marquee.updateText(text, preserveScrollPosition: false)
            label = marquee
        } else {
            let textField: NSTextField
            if let existing = existing as? NSTextField,
               (existing is HoverLinkTextField) == hasRechargeHint {
                textField = existing
            } else {
                existing?.removeFromSuperview()
                textField = hasRechargeHint ? HoverLinkTextField(text: text) : makeOverviewLabel("", font: subtitleFont)
                card.addSubview(textField)
            }
            textField.font = subtitleFont
            textField.identifier = id
            textField.frame = frame
            textField.lineBreakMode = .byTruncatingTail
            textField.usesSingleLineMode = true
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            textField.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: subtitleFont,
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            label = textField
        }
        let tooltip: String
        if let recharge = context.snapshot.balanceRecharge {
            tooltip = context.snapshot.balanceSubtitle(timeZone: settings.displayTimeZone)
                + " · " + recharge.dateText(timeZone: settings.displayTimeZone, includesTime: true)
                + "\n" + tr(.keyBalanceRechargeObserved)
        } else {
            tooltip = text + "\n" + context.snapshot.balanceProgressTooltip(timeZone: settings.displayTimeZone)
        }
        if hasRechargeHint, let startDate = context.snapshot.balanceConsumptionStartDate,
           let link = (label as? HoverLinkTextField) ?? (label as? AccountMarqueeView)?.accountLabel as? HoverLinkTextField {
            link.decoratesOnHover = false
            link.underlinesHoverPhrase = true
            link.restingTextColor = .secondaryLabelColor
            link.hoverPhrase = tr(.keyBalanceLastRecharge)
            link.hoverHintDelay = 0.3
            link.updateTextTooltip(title: tr(.keyBalanceLastRecharge),
                text: BalanceRecharge.dateText(for: startDate, timeZone: settings.displayTimeZone) + " "
                    + BalanceRecharge.clockText(for: startDate, timeZone: settings.displayTimeZone))
            let timeZone = settings.displayTimeZone
            link.textTooltipTextProvider = {
                Self.balanceRechargeTooltipText(startDate: startDate, timeZone: timeZone)
            }
            (card as? MenuHoverLinkHostView)?.track(link)
            label.toolTip = nil
            link.setAccessibilityHelp(tooltip)
        } else { label.toolTip = tooltip }
        label.setAccessibilityLabel(tooltip)
    }

    static func balanceRechargeTooltipText(startDate: Date, now: Date = Date(), timeZone: TimeZone, locale: Locale = TimeZoneCityCatalog.locale) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        let minutes = max(0, floor(now.timeIntervalSince(startDate) / 60))
        formatter.allowedUnits = minutes >= 24 * 60 ? [.day] : [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropLeading
        let duration = formatter.string(from: minutes * 60) ?? "0"
        return BalanceRecharge.dateText(for: startDate, now: now, timeZone: timeZone) + " "
            + BalanceRecharge.clockText(for: startDate, timeZone: timeZone) + " · "
            + tr(.keyBalanceElapsedAgo, arguments: [duration])
    }

    private func updateAggregationTimestamp(in card: NSView, display: AggregatedProviderDisplay) {
        guard let time = descendantViews(of: card, as: NSTextField.self).first(where: {
            $0.identifier?.rawValue == "overview.refreshTime"
        }) else { return }
        let text = display.fetchedAt.map { AppDisplayTime.formatter(timeZone: settings.displayTimeZone).string(from: $0) } ?? "--:--:--"
        let isStale = display.status == .stale || (display.status == .loading && display.reason != nil && display.fetchedAt != nil)
        time.stringValue = isStale ? "⚠︎ " + text : text
        time.textColor = isStale ? .systemOrange : .secondaryLabelColor
        time.toolTip = isStale ? display.reason ?? tr(.keyAggregationStale) : nil
        time.setAccessibilityLabel(isStale ? tr(.keyAggregationStale) + " · " + text + " · " + (display.reason ?? "") : text)
    }

    private func makeOverviewCardLayout(for snapshot: Snapshot,
                                        presentation: OfficialQuotaMenuPresentation,
                                        account: OpenAIAccountPresentation? = nil,
                                        aggregation: Bool = false) -> OpenCodexCardFrames {
        let isBalance = snapshot.kind == .balance
        let unifiedBalance = isBalance && (!menuInput.directProviderIsOfficial || aggregation)
        let officialQuotaWindows = presentation.windows
        let lunaReserve = presentation.lunaReserve
        let bankedReset = presentation.bankedReset
        let bankedResetTicketMetrics = bankedReset?.cards.map {
            OpenCodexTicketTextMetrics(
                titleWidth: textWidth($0.titleText, font: .systemFont(ofSize: OpenCodexCardLayout.quotaDetailPointSize, weight: .medium)) + 4,
                windowWidth: textWidth($0.windowText ?? "", font: .systemFont(ofSize: OpenCodexCardLayout.quotaResetPointSize, weight: .regular)) + 4,
                resetWidth: textWidth(CodexBankedResetFormatting.expiryText(for: $0.expiresAt, relativeTo: Date(), timeZone: settings.displayTimeZone) ?? $0.expiresText ?? "", font: .systemFont(ofSize: OpenCodexCardLayout.quotaResetPointSize, weight: .regular)) + 4,
                amountWidth: textWidth($0.remainingText ?? "", font: .monospacedDigitSystemFont(ofSize: OpenCodexCardLayout.quotaDetailPointSize, weight: .medium)) + 4
            )
        } ?? []
        let nearestExpiryText = bankedReset.flatMap {
            CodexBankedResetFormatting.nearestExpiryText(cards: $0.cards, timeZone: settings.displayTimeZone)
        }
        let subscription = account?.subscription
        let subscriptionTextWidth = subscription.map {
            AccountMarqueeView.textWidth(of: $0.text, font: Self.subscriptionFont)
        }
        return OpenCodexCardLayout.frames(
            for: isBalance ? .balance : .quota,
            linkPrefixWidth: AppLanguage.resolved.overviewLinkPrefixWidth,
            includesBalanceSubtitle: !unifiedBalance,
            includesBalanceRecharge: isBalance && (unifiedBalance || snapshot.balanceRecharge != nil),
            includesAccount: snapshot.kind == .official && account != nil,
            includesSubscription: snapshot.kind == .official && subscription != nil,
            subscriptionTextWidth: snapshot.kind == .official ? subscriptionTextWidth : nil,
            officialQuotaWindows: officialQuotaWindows,
            includesLunaReserve: snapshot.kind == .official && lunaReserve != nil,
            includesLunaReserveProgress: settings.showQuotaProgressBar
                && snapshot.kind == .official
                && lunaReserve?.remaining != nil,
            lunaReserveInsertionIndex: presentation.lunaReserveInsertionIndex,
            includesQuotaProgress: settings.showQuotaProgressBar
                && (!isBalance || snapshot.progressPercentage != nil),
            includesBankedReset: settings.showBankedReset
                && snapshot.kind == .official
                && bankedReset != nil,
            bankedResetCardCount: bankedReset?.cards.count ?? 0,
            bankedResetDisplayMode: menuInput.bankedResetDisplayMode,
            includesBankedResetNearestExpiry: nearestExpiryText != nil,
            includesResetProbability: settings.showBankedReset && snapshot.kind == .official
                && (bankedReset != nil || presentation.resetForecast.hasAnyValue),
            includesBankedResetCountdownProgress: settings.showBankedReset
                && snapshot.kind == .official
                && presentation.resetForecast.showsOfficialWindowDeadlineProgress,
            bankedResetTicketMetrics: bankedResetTicketMetrics
        )
    }

    private func makeOverviewMenuItem(for snapshot: Snapshot, context supplied: OverviewCardContext? = nil) -> NSMenuItem {
        let context = supplied ?? directCardContext(for: snapshot)
        if snapshot.kind == .error {
            presentedOverviewNumerics = currentOverviewNumericSamples()
            return makeOverviewErrorMenuItem(for: snapshot, context: context)
        }
        let quotaPaceNow = quotaPaceNowForTesting ?? Date()
        let item = NSMenuItem()
        item.isEnabled = snapshot.kind == .balance && snapshot.websiteURL != nil
        let isBalance = snapshot.kind == .balance
        let quotaPresentation = snapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
            hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota
        )
        let officialQuotaWindows = quotaPresentation.windows
        let lunaReserve = quotaPresentation.lunaReserve
        let bankedReset = quotaPresentation.bankedReset
        let nearestExpiryText = bankedReset.flatMap {
            CodexBankedResetFormatting.nearestExpiryText(cards: $0.cards, timeZone: settings.displayTimeZone)
        }
        let subscription = context.account?.subscription
        let layout = makeOverviewCardLayout(for: snapshot, presentation: quotaPresentation, account: context.account,
            aggregation: supplied != nil || (snapshot.kind == .balance && !menuInput.directProviderIsOfficial))
        let view = MenuHoverLinkHostView(frame: NSRect(origin: .zero, size: layout.cardSize))
        view.quotaPaceAccount = context.account
        view.quotaPaceClient = context.paceClient
        view.overviewLayout = layout
        view.providerIdentity = context.identity
        view.forecastContentKey = forecastContentKey(quotaPresentation.resetForecast)
        view.bankedResetCardIDs = bankedReset?.cards.map(\.id) ?? []
        view.wantsLayer = true
        view.clipsToBounds = true
        view.layer?.masksToBounds = true
        if OpenCodexCardLayout.showsSectionOutlines {
            for section in layout.sectionLayouts {
                guard !section.frame.isEmpty else { continue }
                let outlineFrame = NSRect(
                    x: OpenCodexCardLayout.horizontalInset,
                    y: section.frame.minY - 3,
                    width: OpenCodexCardLayout.contentWidth,
                    height: section.frame.height + 6
                )
                let outline = OverviewSectionOutlineView(frame: outlineFrame)
                view.addSubview(outline)
            }
        }
        let sectionViews: [OpenCodexOverviewSectionID: OpenCodexOverviewSectionView] =
            snapshot.kind == .official ? Dictionary(uniqueKeysWithValues: layout.sectionLayouts.map { section in
                let child: OpenCodexOverviewSectionView
                switch section.id {
                case .account: child = OpenCodexAccountSectionView(layout: section)
                case .bankedReset: child = OpenCodexBankedResetSectionView(layout: section)
                default: child = OpenCodexMetricSectionView(layout: section)
                }
                view.addSubview(child)
                return (section.id, child)
            }) : [:]
        let headerHost: NSView = sectionViews[.account] ?? view
        func headerFrame(_ frame: NSRect) -> NSRect {
            frame.offsetBy(dx: -headerHost.frame.minX, dy: headerHost === view ? 0 : -headerHost.frame.minY)
        }
        let websiteURL = snapshot.websiteURL.flatMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
        let provider: NSTextField
        if isBalance, let websiteURL {
            let link = HoverLinkTextField(text: snapshot.overviewProvider)
            link.font = .systemFont(ofSize: 15, weight: .semibold)
            link.restingTextColor = .labelColor
            link.onActivate = { [weak self] in self?.actions.openStatusLink(websiteURL) }
            view.track(link)
            provider = link
        } else {
            provider = makeOverviewLabel(snapshot.overviewProvider, font: .systemFont(ofSize: 15, weight: .semibold))
        }
        provider.identifier = NSUserInterfaceItemIdentifier("overview.providerTitle")
        provider.frame = headerFrame(layout.title)

        if snapshot.kind == .official, let quotaStatus = snapshot.quotaStatus {
            // Claude official quota: BB-07's status slot replaces the plain refresh time.
            let slot = StatusSlotView(localize: StatusSlotText.appLocalize, timeZone: settings.displayTimeZone)
            applyQuotaStatus(quotaStatus, reason: snapshot.staleReason, to: slot)
            slot.identifier = NSUserInterfaceItemIdentifier("overview.refreshTime")
            slot.frame = Self.statusSlotFrame(in: headerFrame(layout.refreshTime))
            // The slot extends left of the refresh-time column; the title yields the space.
            provider.frame.size.width = max(0, min(provider.frame.width, slot.frame.minX - provider.frame.minX - 6))
            headerHost.addSubview(slot)
        } else if snapshot.kind == .official || snapshot.kind == .balance {
            let refreshTime = makeOverviewLabel("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
            refreshTime.alignment = .right
            applyRefreshTime(to: refreshTime, date: context.date, staleReason: snapshot.staleReason)
            refreshTime.identifier = NSUserInterfaceItemIdentifier("overview.refreshTime")
            refreshTime.frame = headerFrame(layout.refreshTime)
            headerHost.addSubview(refreshTime)
        }
        if let account = context.account, let accountFrame = layout.account {
            let accountLabel = makeAccountLabel(
                account,
                frame: headerFrame(accountFrame)
            )
            accountLabel.identifier = NSUserInterfaceItemIdentifier("overview.accountSubtitle")
            headerHost.addSubview(accountLabel)
        }
        if let subscription,
           let subscriptionFrame = layout.subscription {
            headerHost.addSubview(makeSubscriptionLabel(subscription.text, frame: headerFrame(subscriptionFrame)))
        }

        let cardNumerics = numericSamples(for: context)
        presentedOverviewNumerics = currentOverviewNumericSamples()
        if (!officialQuotaWindows.isEmpty && !layout.quotaRows.isEmpty)
            || layout.lunaReserveRow != nil
            || layout.bankedResetSummaryRow != nil || layout.bankedResetProbabilityRow != nil {
            for (index, rawWindow) in officialQuotaWindows.enumerated() {
                let id = OpenCodexOverviewSectionID.quota(rawWindow, index: index)
                let window = context.paceClient == .claude ? rawWindow.projectingIdleReset(now: quotaPaceNow) : rawWindow
                guard let section = layout.sectionLayouts.first(where: { $0.id == id }),
                      let row = section.row, let sectionView = sectionViews[id] as? OpenCodexMetricSectionView else { continue }
                let sample = OverviewNumericSample(
                    identity: OverviewNumericPresentation.identity(
                        for: window,
                        provider: context.identity
                    ),
                    format: .integerPercent,
                    value: window.remaining,
                    progressPercentage: window.remaining
                )
                let plan = overviewNumericPlan(for: sample)
                let progress = settings.showQuotaProgressBar
                    ? makeOverviewQuotaProgress(plan: plan, frame: row.progress, window: window,
                        cycleStart: quotaPaceCycleStart(for: window, context: context), now: quotaPaceNow) : nil

                let amount = makeOverviewNumericAmount(plan: plan, sample: sample, frame: row.amount)

                let quotaDetail = makeMarqueeOverviewLabel(
                    window.label,
                    font: .systemFont(
                        ofSize: OpenCodexCardLayout.quotaDetailPointSize,
                        weight: .medium
                    ),
                    textColor: .labelColor,
                    frame: overviewMarqueeFrame(
                        row.quotaDetail,
                        avoidingAmountFrame: amount.frame,
                        amountText: plan.layoutReservationText
                    )
                )

                let resetText = window.resetDisplayText(timeZone: settings.displayTimeZone).map {
                    tr(.keySnapshotResetValue, arguments: [String(describing: $0)])
                } ?? tr(.keySnapshotResetValue, arguments: [tr(.keyLocalizationUnknown)])
                let reset = makeMarqueeOverviewLabel(
                    resetText,
                    font: .systemFont(
                        ofSize: OpenCodexCardLayout.quotaResetPointSize,
                        weight: .regular
                    ),
                    textColor: .secondaryLabelColor,
                    frame: overviewMarqueeFrame(
                        row.reset,
                        avoidingAmountFrame: amount.frame,
                        amountText: plan.layoutReservationText
                    )
                )
                sectionView.installMetric(title: quotaDetail, subtitle: reset, amount: amount, progress: progress)
            }
            if let lunaReserve,
               let row = layout.sectionLayouts.first(where: { $0.id == .lunaReserve })?.row,
               let sectionView = sectionViews[.lunaReserve] as? OpenCodexMetricSectionView {
                let amountFont = NSFont.monospacedDigitSystemFont(
                    ofSize: OpenCodexCardLayout.quotaAmountPointSize,
                    weight: .semibold
                )
                let amount: NSView
                var progress: NSView?
                let marqueeAmountText: String
                if let remaining = lunaReserve.remaining {
                    let sample = OverviewNumericSample(
                        identity: .lunaReserve(provider: context.identity),
                        format: .integerPercent,
                        value: remaining,
                        progressPercentage: remaining
                    )
                    let plan = overviewNumericPlan(for: sample)
                    if settings.showQuotaProgressBar {
                        progress = makeOverviewNumericProgress(plan: plan, frame: row.progress)
                    }
                    let numeric = makeOverviewNumericAmount(
                        plan: plan,
                        sample: sample,
                        frame: row.amount
                    )
                    amount = numeric
                    marqueeAmountText = plan.layoutReservationText
                } else {
                    let label = makeOverviewLabel("—", font: amountFont)
                    label.alignment = .right
                    label.frame = row.amount
                    amount = label
                    marqueeAmountText = "—"
                }

                let quotaDetail = makeMarqueeOverviewLabel(
                    lunaReserve.menuTitleText,
                    font: .systemFont(
                        ofSize: OpenCodexCardLayout.quotaDetailPointSize,
                        weight: .medium
                    ),
                    textColor: .labelColor,
                    frame: overviewMarqueeFrame(
                        row.quotaDetail,
                        avoidingAmountFrame: amount.frame,
                        amountText: marqueeAmountText,
                        amountFont: amountFont
                    )
                )

                let reset = makeMarqueeOverviewLabel(
                    lunaReserve.menuSubtitle(timeZone: settings.displayTimeZone),
                    font: .systemFont(
                        ofSize: OpenCodexCardLayout.quotaResetPointSize,
                        weight: .regular
                    ),
                    textColor: .secondaryLabelColor,
                    frame: overviewMarqueeFrame(
                        row.reset,
                        avoidingAmountFrame: amount.frame,
                        amountText: marqueeAmountText,
                        amountFont: amountFont
                    )
                )
                sectionView.installMetric(title: quotaDetail, subtitle: reset, amount: amount, progress: progress)
            }
            if let sectionView = sectionViews[.resetProbability],
               let row = layout.sectionLayouts.first(where: { $0.id == .resetProbability })?.row {
                addBankedResetProbabilityBlock(
                    to: sectionView, eventHost: view, row: row,
                    forecast: quotaPresentation.resetForecast, provider: context.identity
                )
            }
            if let bankedReset,
               let section = layout.sectionLayouts.first(where: { $0.id == .bankedReset }),
               let summaryRow = section.row, let sectionView = sectionViews[.bankedReset] as? OpenCodexBankedResetSectionView {
                let isCompactBankedReset = menuInput.bankedResetDisplayMode == .compact
                if summaryRow.amount.width > 0 {
                    let sample = OverviewNumericSample(
                        identity: .bankedResetCount(provider: context.identity),
                        format: .integerCount,
                        value: Double(bankedReset.availableCount),
                        progressPercentage: nil
                    )
                    let plan = overviewNumericPlan(for: sample)
                    let amount = makeOverviewNumericAmount(
                        plan: plan,
                        sample: sample,
                        frame: summaryRow.amount
                    )
                    let summaryTitle = makeMarqueeOverviewLabel(
                            tr(.keyCodexBankedResetTitle),
                            font: .systemFont(
                                ofSize: OpenCodexCardLayout.quotaDetailPointSize,
                                weight: .medium
                            ),
                            textColor: .labelColor,
                            frame: overviewMarqueeFrame(
                                summaryRow.quotaDetail,
                                avoidingAmountFrame: amount.frame,
                                amountText: plan.layoutReservationText
                            )
                        )
                    var subtitle: NSView?
                    if let nearestExpiryText, summaryRow.reset.width > 0 {
                        let nearest = makeMarqueeOverviewLabel(
                            nearestExpiryText,
                            font: .systemFont(
                                ofSize: OpenCodexCardLayout.quotaResetPointSize,
                                weight: .regular
                            ),
                            textColor: .secondaryLabelColor,
                            frame: overviewMarqueeFrame(
                                summaryRow.reset,
                                avoidingAmountFrame: amount.frame,
                                amountText: plan.layoutReservationText
                            )
                        )
                        nearest.identifier = NSUserInterfaceItemIdentifier(
                            "codex.bankedReset.nearestExpiry"
                        )
                        subtitle = nearest
                    }
                    sectionView.installMetric(title: summaryTitle, subtitle: subtitle, amount: amount)
                }

                if !isCompactBankedReset {
                    let ticketImage = Self.bankedResetTicketImage()
                    let ticketHost: NSView
                    let ticketScrollView: BankedResetTicketScrollView?
                    if let viewport = layout.bankedResetTicketViewport,
                       layout.bankedResetDetailRows.map(\.chrome.height).reduce(0, +)
                        + CGFloat(max(0, layout.bankedResetDetailRows.count - 1)) * OpenCodexCardLayout.metrics.ticketSpacing > viewport.height + 0.5 {
                        let document = BankedResetTicketDocumentView(
                            frame: NSRect(
                                x: 0,
                                y: 0,
                                width: viewport.width,
                                height: layout.bankedResetDetailRows.map(\.chrome.maxY).max() ?? 0
                            )
                        )
                        let scrollView = BankedResetTicketScrollView(frame: viewport.offsetBy(dx: 0, dy: -section.frame.minY))
                        scrollView.identifier = NSUserInterfaceItemIdentifier(
                            "codex.bankedReset.ticketScroll"
                        )
                        scrollView.documentView = document
                        sectionView.addSubview(scrollView)
                        view.trackTicketScroll(scrollView)
                        ticketHost = document
                        ticketScrollView = scrollView
                    } else {
                        if let viewport = layout.bankedResetTicketViewport {
                            let document = BankedResetTicketDocumentView(frame: viewport.offsetBy(dx: 0, dy: -section.frame.minY))
                            sectionView.addSubview(document)
                            ticketHost = document
                        } else {
                            ticketHost = sectionView
                        }
                        ticketScrollView = nil
                    }
                    for (card, row) in zip(bankedReset.cards, layout.bankedResetDetailRows) {
                        if row.chrome.width > 0 {
                            let chrome = BankedResetChromeView(frame: row.chrome)
                            chrome.identifier = NSUserInterfaceItemIdentifier("codex.bankedReset.chrome")
                            ticketHost.addSubview(chrome)
                        }

                        if row.icon.width > 0, let ticketImage {
                            let icon = NSImageView(frame: row.icon)
                            icon.image = ticketImage
                            icon.imageScaling = .scaleProportionallyUpOrDown
                            icon.identifier = NSUserInterfaceItemIdentifier("codex.bankedReset.ticket")
                            ticketHost.addSubview(icon)
                        }

                        let title = makeTicketOverviewLabel(
                            card.titleText,
                            font: .systemFont(ofSize: OpenCodexCardLayout.quotaDetailPointSize, weight: .medium),
                            textColor: .labelColor,
                            frame: row.quotaDetail,
                            identifier: "codex.bankedReset.ticketTitle"
                        )
                        ticketHost.addSubview(title)

                        var windowLine: NSTextField?
                        if let windowText = card.windowText, !windowText.isEmpty {
                            let label = makeTicketOverviewLabel(
                                windowText,
                                font: .systemFont(ofSize: OpenCodexCardLayout.quotaResetPointSize, weight: .regular),
                                textColor: .secondaryLabelColor,
                                frame: row.window,
                                identifier: "codex.bankedReset.ticketWindow"
                            )
                            ticketHost.addSubview(label)
                            windowLine = label as? NSTextField
                        }

                        var remaining: NSTextField?
                        if let remainingText = card.remainingText, !remainingText.isEmpty {
                            let label = makeOverviewLabel(
                                remainingText,
                                font: .monospacedDigitSystemFont(
                                    ofSize: OpenCodexCardLayout.quotaDetailPointSize,
                                    weight: .medium
                                )
                            )
                            label.alignment = .right
                            label.textColor = card.remainingIsWarning ? .systemOrange : .labelColor
                            label.frame = row.amount
                            label.identifier = NSUserInterfaceItemIdentifier("codex.bankedReset.remaining")
                            ticketHost.addSubview(label)
                            remaining = label
                        }

                        if let windowLine, let remaining,
                           row.chrome.height == OpenCodexCardLayout.bankedResetDetailRowHeight {
                            alignOverviewLabelBaseline(remaining, to: windowLine)
                        }

                        if let expiresText = CodexBankedResetFormatting.expiryText(for: card.expiresAt, relativeTo: Date(), timeZone: settings.displayTimeZone) ?? (card.expiresAt == nil ? card.expiresText : nil), !expiresText.isEmpty {
                            let subtitle = makeTicketOverviewLabel(
                                expiresText,
                                font: .systemFont(ofSize: OpenCodexCardLayout.quotaResetPointSize, weight: .regular),
                                textColor: .secondaryLabelColor,
                                frame: row.reset,
                                identifier: "codex.bankedReset.ticketExpiry"
                            )
                            ticketHost.addSubview(subtitle)
                        }
                    }
                    ticketScrollView?.scrollToTopOfDocument()
                }
            }
            headerHost.addSubview(provider)
        } else {
            let bodyHost: NSView = sectionViews[.legacyQuota] ?? view
            func attachBody(_ child: NSView) {
                if bodyHost !== view { child.frame.origin.y -= bodyHost.frame.minY }
                bodyHost.addSubview(child)
            }
            let amountFont = NSFont.monospacedDigitSystemFont(
                ofSize: OpenCodexCardLayout.quotaAmountPointSize,
                weight: .semibold
            )
            let amount: NSView
            let marqueeAmountText: String
            if snapshot.kind == .balance, let sample = cardNumerics.first {
                let plan = overviewNumericPlan(for: sample)
                if settings.showQuotaProgressBar,
                   sample.progressPercentage != nil,
                   let progressFrame = layout.progress {
                    attachBody(makeOverviewNumericProgress(plan: plan, frame: progressFrame))
                }
                // With or without the progress bar, the balance amount frame's
                // top sits 1pt above the shorter detail row. Pin the glyphs
                // to that edge instead of centering them in the tall box.
                amount = makeOverviewNumericAmount(
                    plan: plan,
                    sample: sample,
                    frame: layout.amount,
                    verticalAlignment: .top
                )
                marqueeAmountText = plan.layoutReservationText
            } else {
                if settings.showQuotaProgressBar,
                   let percentage = snapshot.progressPercentage,
                   let progressFrame = layout.progress {
                    let progress = QuotaProgressView(
                        percentage: percentage,
                        colorConfiguration: settings.quotaProgressColorConfiguration
                    )
                    progress.frame = progressFrame
                    attachBody(progress)
                }
                let label = makeOverviewLabel(snapshot.overviewLargeAmount, font: amountFont)
                label.alignment = .right
                label.frame = layout.amount
                amount = label
                marqueeAmountText = snapshot.overviewLargeAmount
            }
            let quotaDetail = makeMarqueeOverviewLabel(
                snapshot.overviewQuotaDetail,
                font: .systemFont(
                    ofSize: OpenCodexCardLayout.quotaDetailPointSize,
                    weight: .medium
                ),
                textColor: .labelColor,
                frame: overviewMarqueeFrame(
                    layout.quotaDetail,
                    avoidingAmountFrame: amount.frame,
                    amountText: marqueeAmountText,
                    amountFont: amountFont,
                    minimumAmountGap: isBalance ? 12 : 0
                )
            )
            quotaDetail.identifier = NSUserInterfaceItemIdentifier("overview.quotaDetail")
            if isBalance {
                if menuInput.directProviderIsOfficial && supplied == nil {
                    let linkPrefix = makeOverviewLabel(tr(.keyStatusItemControllerOfficialLink), font: .systemFont(ofSize: 12))
                    linkPrefix.textColor = .secondaryLabelColor
                    linkPrefix.frame = layout.linkPrefix ?? .zero
                    view.addSubview(linkPrefix)
                    if let websiteURL, let linkFrame = layout.link {
                        let link = HoverLinkTextField(text: snapshot.provider)
                        link.frame = linkFrame
                        link.onActivate = { [weak self] in self?.actions.openProviderWebsite() }
                        view.addSubview(link)
                        view.track(link)
                    }
                }
            } else {
                let reset = makeMarqueeOverviewLabel(
                    snapshot.overviewReset(refreshDate: context.date, formatter: AppDisplayTime.formatter(timeZone: settings.displayTimeZone)),
                    font: .systemFont(
                        ofSize: OpenCodexCardLayout.quotaResetPointSize,
                        weight: .regular
                    ),
                    textColor: .secondaryLabelColor,
                    frame: overviewMarqueeFrame(
                        layout.reset ?? .zero,
                        avoidingAmountFrame: amount.frame,
                        amountText: marqueeAmountText,
                        amountFont: amountFont
                    )
                )
                attachBody(reset)
            }
            headerHost.addSubview(provider)
            [quotaDetail, amount].forEach(attachBody)
        }
        item.view = view
        updateOverviewHeaderNotes(in: view, context: context)
        updateBalanceSubtitle(in: view, context: context)
        alignSingleLineBalance(in: view, snapshot: context.snapshot)
        return item
    }

    private func makeOverviewErrorMenuItem(for snapshot: Snapshot, context: OverviewCardContext) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let message = snapshot.overviewReset(refreshDate: nil, formatter: AppDisplayTime.formatter(timeZone: settings.displayTimeZone))
        // Claude official failures add the BB-07 failure view: reason plus a button
        // that opens the official usage page, in extra height below the detail.
        let showsUsagePageButton = snapshot.quotaStatus != nil
        let buttonShift = showsUsagePageButton ? ErrorCardLayout.usagePageButtonHeight : 0
        let baseFrames = ErrorCardLayout.errorFrames(
            for: message,
            includesAccount: context.account != nil,
            includesSubscription: context.account?.subscription != nil,
            subscriptionTextWidth: context.account?.subscription.map {
                AccountMarqueeView.textWidth(of: $0.text, font: Self.subscriptionFont)
            }
        )
        let frames = baseFrames.shiftedUp(by: buttonShift)
        let view = NSView(frame: NSRect(origin: .zero, size: frames.cardSize))
        let provider = makeOverviewLabel(snapshot.overviewProvider, font: ErrorCardLayout.titleFont)
        provider.frame = frames.title
        provider.identifier = NSUserInterfaceItemIdentifier("overview.providerTitle")
        view.addSubview(provider)
        if let account = context.account, let accountFrame = frames.account {
            let accountLabel = makeAccountLabel(
                account,
                frame: accountFrame
            )
            view.addSubview(accountLabel)
        }
        if let subscription = context.account?.subscription,
           let subscriptionFrame = frames.subscription {
            view.addSubview(makeSubscriptionLabel(subscription.text, frame: subscriptionFrame))
        }
        let timeText = context.date.map { AppDisplayTime.formatter(timeZone: settings.displayTimeZone).string(from: $0) } ?? "--:--:--"
        let refreshTime = ErrorCardLayout.makeRefreshTimeLabel(
            timeText,
            showsCachedBalance: snapshot.hasCachedBalance
        )
        refreshTime.identifier = NSUserInterfaceItemIdentifier("overview.refreshTime")
        refreshTime.frame = frames.refreshTime
        view.addSubview(refreshTime)
        let quotaDetail = makeOverviewLabel(snapshot.overviewQuotaDetail, font: ErrorCardLayout.quotaFont)
        quotaDetail.frame = frames.quotaDetail
        view.addSubview(quotaDetail)
        let amount = makeOverviewLabel(snapshot.overviewLargeAmount, font: ErrorCardLayout.amountFont)
        amount.alignment = .right
        amount.frame = frames.amount
        view.addSubview(amount)
        if showsUsagePageButton {
            let failure = FailureStateView(
                reason: frames.detailText,
                localize: StatusSlotText.appLocalize,
                onOpenUsagePage: { [weak self] in self?.actions.openStatusLink(FailureStateView.officialUsageURL) })
            failure.identifier = NSUserInterfaceItemIdentifier("overview.failureState")
            failure.frame = NSRect(x: frames.detail.minX, y: frames.detail.minY - buttonShift,
                                   width: frames.detail.width, height: frames.detail.height + buttonShift)
            view.addSubview(failure)
        } else {
            let detail = ErrorCardLayout.makeDetailLabel(
                frames.detailText,
                textColor: snapshot.provider.isEmpty ? .secondaryLabelColor : .systemRed
            )
            detail.frame = frames.detail
            view.addSubview(detail)
        }
        updateOverviewHeaderNotes(in: view, context: context)
        item.view = view
        return item
    }

    private static func bankedResetTicketImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "BankedResetTicket", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.size = OpenCodexCardLayout.bankedResetTicketIconSize
        return image
    }

    private func makeOverviewLabel(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func alignOverviewLabelBaseline(_ label: NSTextField, to reference: NSTextField) {
        let labelBaseline = label.frame.maxY - label.firstBaselineOffsetFromTop
        let referenceBaseline = reference.frame.maxY - reference.firstBaselineOffsetFromTop
        label.frame.origin.y += referenceBaseline - labelBaseline
    }

    private func makeMarqueeOverviewLabel(
        _ text: String,
        font: NSFont,
        textColor: NSColor,
        frame: NSRect,
        leadingInkAnchor: CGFloat? = nil
    ) -> AccountMarqueeView {
        AccountMarqueeView(
            text: text,
            font: font,
            textColor: textColor,
            frame: frame,
            leadingInkAnchor: leadingInkAnchor
        )
    }

    private func makeTicketOverviewLabel(
        _ text: String,
        font: NSFont,
        textColor: NSColor,
        frame: NSRect,
        identifier: String
    ) -> NSView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if textWidth(text, font: font) + 4 > frame.width {
            let marquee = makeMarqueeOverviewLabel(text, font: font, textColor: textColor, frame: frame)
            marquee.identifier = id
            marquee.accountLabel.identifier = id
            return marquee
        }
        let label = makeOverviewLabel(text, font: font)
        label.textColor = textColor
        label.frame = frame
        label.identifier = id
        return label
    }

    private func overviewMarqueeFrame(
        _ baseFrame: NSRect,
        avoidingAmountFrame amountFrame: NSRect,
        amountText: String,
        amountFont: NSFont = .monospacedDigitSystemFont(
            ofSize: OpenCodexCardLayout.quotaAmountPointSize,
            weight: .semibold
        ),
        minimumAmountGap: CGFloat = 0
    ) -> NSRect {
        guard baseFrame.width > 0 else { return baseFrame }

        // The amount label is right-aligned. Its frame reserves the full
        // primary column, but the rendered value often occupies only its
        // rightmost portion (for example `77%`). Let localized detail text
        // use that empty space. If the value itself reaches the column's
        // leading edge, keep the viewport bounded by the actual safe gap and
        // let the marquee scroll. This keeps scrolling as the overflow
        // fallback, rather than the first response to a barely-overlong
        // translation. Reservation text is the wider of the animation start
        // and end so intermediate digit widths do not shove the marquee.
        let amountTextWidth = AccountMarqueeView.textWidth(
            of: amountText,
            font: amountFont
        )
        let renderedAmountMinX = amountFrame.maxX - amountTextWidth
        let safeAmountMinX = max(amountFrame.minX, renderedAmountMinX)
        let availableWidth = max(0, safeAmountMinX - baseFrame.minX - minimumAmountGap)
        // Keep any requested breathing room outside the marquee's fade mask,
        // so even scrolling glyphs cannot reach the adjacent value.
        let expandedWidth = availableWidth
        return NSRect(
            x: baseFrame.minX,
            y: baseFrame.minY,
            width: expandedWidth,
            height: baseFrame.height
        )
    }

    private func currentOverviewNumericSamples() -> [OverviewNumericSample] {
        if !menuInput.aggregatedProviders.isEmpty {
            return aggregationOverviewDisplays.flatMap { numericSamples(for: cardContext($0)) }
        }
        return numericSamples(for: directCardContext(for: snapshot))
    }

    private func numericSamples(for context: OverviewCardContext) -> [OverviewNumericSample] {
        OverviewNumericPresentation.samples(
            snapshot: context.snapshot,
            providerIdentity: context.identity,
            lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
            hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota,
            showBankedReset: settings.showBankedReset,
            now: bankedResetCountdownNow()
        )
    }

    private func bankedResetCountdownNow() -> Date {
        bankedResetCountdownNowForTesting ?? Date()
    }

    /// Each card is validated against its own account: aggregated Codex
    /// cards may belong to accounts other than the active one. Claude cards
    /// use the same rule; their contexts are recorded by the refresh
    /// coordinator from the account-wide Claude quota pipeline.
    private func quotaPaceCycleStart(for window: OfficialQuotaWindow, context: OverviewCardContext) -> Date? {
        let snapshot = context.snapshot
        guard context.paceClient == .codex || context.paceClient == .claude, snapshot.kind == .official,
              case .available(let email) = context.account?.state,
              snapshot.quotaPredictionAccountKey == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let cycle = QuotaPredictionCycle(window: window) else { return nil }
        return snapshot.quotaPredictionContexts.first { $0.cycle == cycle }?.inferredCycleStart
    }

    private func refreshQuotaPaceViews() {
        let cards = menuContentCardsForUpdate("pace")
        guard !cards.isEmpty else { return }
        let now = quotaPaceNowForTesting ?? Date()
        let aggregated = !menuInput.aggregatedProviders.isEmpty
        for (host, context) in cards {
            host.reconcilePaceMenuTracking()
            let snapshot = context.snapshot
            let windows = snapshot.officialQuotaMenuPresentation(
                lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
                hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota
            ).windows
            // Aggregated cards carry their own account; the direct card must
            // also match the account its snapshot was fetched for.
            let ownerMatches = aggregated
                ? host.quotaPaceAccount == context.account && host.quotaPaceClient == context.paceClient
                : host.quotaPaceAccount == menuInput.openAIAccount && host.quotaPaceClient == menuInput.activeClient
                    && quotaPaceSnapshotAccount == menuInput.openAIAccount && quotaPaceSnapshotClient == menuInput.activeClient
            let identityMatches = snapshot.kind == .official && ownerMatches
                && settings.showQuotaProgressBar && settings.showQuotaPaceIndicator
            for view in host.paceViews {
                if identityMatches, let window = windows.first(where: {
                    OverviewNumericPresentation.identity(for: $0, provider: context.identity) == view.numericIdentity
                }).map({ context.paceClient == .claude ? $0.projectingIdleReset(now: now) : $0 }) {
                    view.update(window: window, now: now, cycleStart: quotaPaceCycleStart(for: window, context: context),
                        timeZone: settings.displayTimeZone)
                } else {
                    view.invalidatePresentation()
                }
            }
        }
        // One menu-level timer serves every card.
        if cards.contains(where: { $0.host.paceViews.contains { $0.pace != nil } }) {
            guard quotaPaceTimer == nil else { return }
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshQuotaPaceViews() }
            timer.tolerance = 1
            quotaPaceTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        } else {
            quotaPaceTimer?.invalidate()
            quotaPaceTimer = nil
        }
    }

    private func stopQuotaPaceTracking() {
        quotaPaceTimer?.invalidate()
        quotaPaceTimer = nil
        (statusMenu.items.first?.view as? MenuHoverLinkHostView)?.setPaceMenuTracking(false)
    }

    private func syncBankedResetCountdownTimer() {
        let shouldRun = settings.showBankedReset
            && menuContentCardsForUpdate("countdown.timer").contains { card in
                card.context.snapshot.kind == .official
                    && card.context.snapshot.officialQuotaMenuPresentation(
                        lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
                        hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota
                    ).resetForecast.remainingCountdownSeconds(now: bankedResetCountdownNow()) != nil
            }
        if shouldRun {
            startBankedResetCountdownTimerIfNeeded()
        } else {
            stopBankedResetCountdownTimer()
        }
    }

    private func startBankedResetCountdownTimerIfNeeded() {
        guard bankedResetCountdownTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.applyInPlaceOverviewNumericUpdatesIfTracking()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        bankedResetCountdownTimer = timer
    }

    private func stopBankedResetCountdownTimer() {
        bankedResetCountdownTimer?.invalidate()
        bankedResetCountdownTimer = nil
    }

    private func shouldReduceOverviewNumericMotion() -> Bool {
        overviewNumericReduceMotionForTesting
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func overviewNumericPlan(
        for sample: OverviewNumericSample
    ) -> OverviewNumericTransitionPlan {
        OverviewNumericTransition.plan(
            previous: lastSeenOverviewNumerics[sample.identity],
            current: sample,
            reduceMotion: shouldReduceOverviewNumericMotion()
        )
    }

    static func codexResetForecastHint(for forecast: CodexResetForecast) -> String {
        codexResetForecastTooltip(for: forecast).plainText
    }

    static func codexResetForecastTooltip(
        for forecast: CodexResetForecast,
        language: AppLanguage = .resolved,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> DashboardForecastTooltipContent {
        let updatedText: String
        if let updatedAt = forecast.updatedAt {
            let localeID: String
            switch language {
            case .simplifiedChinese: localeID = "zh_CN"
            case .traditionalChineseTaiwan: localeID = "zh_TW"
            case .traditionalChineseHongKong: localeID = "zh_HK"
            case .japanese: localeID = "ja_JP"
            case .korean: localeID = "ko_KR"
            case .spanish: localeID = "es_ES"
            case .portuguese: localeID = "pt_PT"
            case .french: localeID = "fr_FR"
            case .german: localeID = "de_DE"
            case .russian: localeID = "ru_RU"
            case .italian: localeID = "it_IT"
            case .english, .system: localeID = "en_US"
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: localeID)
            formatter.timeZone = timeZone
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            formatter.calendar = calendar
            let sameYear = calendar.component(.year, from: updatedAt) == calendar.component(.year, from: now)
            if localeID.hasPrefix("zh") {
                formatter.dateFormat = sameYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
            } else {
                formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMdHHmm" : "yMMMdHHmm")
            }
            updatedText = formatter.string(from: updatedAt)
        } else {
            updatedText = "--"
        }
        let isSignal = forecast.officialSignal != nil
        // The countdown variant describes the reset window itself; a
        // probability-only official signal keeps the generic signal copy.
        let isWindowDeadline = forecast.isOfficialWindowDeadlineCountdown
        let titleKey: LocalizationKey = isWindowDeadline
            ? .keyCodexBankedResetWindowDeadlineCountdown
            : (isSignal ? .keyCodexResetSignalTooltipTitle : .keyCodexBankedResetTooltipTitle)
        let bodyKey: LocalizationKey = isWindowDeadline
            ? .keyCodexResetSignalWindowTooltipBody
            : (isSignal ? .keyCodexResetSignalTooltipBody : .keyCodexBankedResetTooltipBody)
        let disclaimerKey: LocalizationKey = isWindowDeadline
            ? .keyCodexResetSignalWindowTooltipDisclaimer
            : (isSignal ? .keyCodexResetSignalTooltipDisclaimer : .keyCodexBankedResetTooltipDisclaimer)
        return DashboardForecastTooltipContent(
            title: tr(titleKey, language: language),
            body: tr(bodyKey, language: language),
            source: tr(.keyCodexBankedResetTooltipSource, arguments: [updatedText], language: language),
            disclaimer: tr(disclaimerKey, language: language)
        )
    }

    private func addBankedResetProbabilityBlock(
        to view: NSView,
        eventHost: MenuHoverLinkHostView,
        row: OpenCodexQuotaRowFrames,
        forecast: CodexResetForecast,
        provider: String
    ) {
        let contentKey = forecastContentKey(forecast)
        let amountFont = NSFont.monospacedDigitSystemFont(
            ofSize: OpenCodexCardLayout.quotaAmountPointSize,
            weight: .semibold
        )
        let amount: NSView
        let marqueeAmountText: String
        var reservationFont = amountFont
        if contentKey.primary == .confirmed {
            let text = forecast.menuPrimaryDisplayText()
            let labelFont = OpenCodexCardLayout.bankedResetPrimaryLabelFont(for: text)
            let label = makeOverviewLabel(text, font: labelFont)
            label.alignment = .right
            label.frame = row.amount
            label.identifier = NSUserInterfaceItemIdentifier(
                "codex.bankedReset.probabilityConfirmedLabel"
            )
            amount = label
            marqueeAmountText = text
            reservationFont = labelFont
        } else if contentKey.primary == .countdown, let minutes = forecast.remainingCountdownMinutes(now: bankedResetCountdownNow()) {
            let sample = OverviewNumericSample(
                identity: .bankedResetProbabilityCountdown(provider: provider),
                format: .remainingMinutes,
                value: Double(minutes),
                progressPercentage: nil
            )
            let plan = overviewNumericPlan(for: sample)
            let numeric = makeOverviewNumericAmount(
                plan: plan,
                sample: sample,
                frame: row.amount
            )
            numeric.identifier = NSUserInterfaceItemIdentifier(
                "codex.bankedReset.probabilityCountdownAmount"
            )
            amount = numeric
            marqueeAmountText = plan.layoutReservationText
        } else {
        switch forecast.menuProbabilityPresentation {
        case .ordinary(.percent(let percent)):
            let sample = OverviewNumericSample(
                identity: .bankedResetProbability24h(provider: provider),
                format: .integerPercent,
                value: Double(percent),
                progressPercentage: nil
            )
            let plan = overviewNumericPlan(for: sample)
            let numeric = makeOverviewNumericHoverLinkAmount(
                plan: plan,
                sample: sample,
                frame: row.amount,
                forecast: forecast
            )
            numeric.identifier = NSUserInterfaceItemIdentifier(
                "codex.bankedReset.probability24hAmount"
            )
            amount = numeric
            marqueeAmountText = plan.layoutReservationText
        case .strongSignal(.percent(let percent)):
            let sample = OverviewNumericSample(
                identity: .bankedResetProbabilitySignal(provider: provider),
                format: .integerPercent,
                value: Double(percent),
                progressPercentage: nil
            )
            let plan = overviewNumericPlan(for: sample)
            let numeric = makeOverviewNumericHoverLinkAmount(
                plan: plan,
                sample: sample,
                frame: row.amount,
                forecast: forecast
            )
            numeric.identifier = NSUserInterfaceItemIdentifier(
                "codex.bankedReset.probabilitySignalAmount"
            )
            amount = numeric
            marqueeAmountText = plan.layoutReservationText
        case .ordinary:
            let label = HoverLinkTextField(text: forecast.probability24h.displayText)
            label.font = amountFont
            label.restingTextColor = .labelColor
            label.textColor = .labelColor
            label.percentSignFont = OverviewNumericTextView.currencySymbolFont(for: amountFont)
            makeInertBankedResetAmount(label)
            label.alignment = .right
            label.frame = row.amount
            label.identifier = NSUserInterfaceItemIdentifier(
                "codex.bankedReset.probability24hAmount"
            )
            amount = label
            marqueeAmountText = forecast.probability24h.displayText
        case .strongSignal:
            let text = forecast.menuPrimaryDisplayText()
            let labelFont = OpenCodexCardLayout.bankedResetPrimaryLabelFont(for: text)
            let label = HoverLinkTextField(text: text)
            label.font = labelFont
            label.restingTextColor = .labelColor
            label.textColor = .labelColor
            label.percentSignFont = OverviewNumericTextView.currencySymbolFont(for: labelFont)
            makeInertBankedResetAmount(label)
            label.alignment = .right
            label.frame = row.amount
            label.identifier = NSUserInterfaceItemIdentifier(
                "codex.bankedReset.probabilityHighLabel"
            )
            amount = label
            marqueeAmountText = text
            reservationFont = labelFont
        }
        }
        // The title, not the amount, hosts the source bubble and website link.
        let titleText = contentKey.primary == .countdown
            ? tr(.keyCodexBankedResetWindowDeadlineCountdown)
            : tr(.keyCodexBankedResetProbabilityPrefix)
        let titleLink = contentKey.primary == .confirmed ? nil : HoverLinkTextField(text: titleText)
        let probabilityTitle = AccountMarqueeView(
            text: titleText,
            font: .systemFont(
                ofSize: OpenCodexCardLayout.quotaDetailPointSize,
                weight: .medium
            ),
            textColor: .labelColor,
            frame: overviewMarqueeFrame(
                row.quotaDetail,
                avoidingAmountFrame: amount.frame,
                amountText: marqueeAmountText,
                amountFont: reservationFont,
                minimumAmountGap: 12
            ),
            label: titleLink
        )
        (view as? OpenCodexMetricSectionView)?.installMetric(title: probabilityTitle, subtitle: nil, amount: amount)
        let leadingInkAnchor = AccountMarqueeView.leadingInkInset(of: probabilityTitle.accountLabel)
        if let titleLink {
            titleLink.identifier = NSUserInterfaceItemIdentifier("codex.bankedReset.probabilityTitleLink")
            titleLink.restingTextColor = .labelColor
            titleLink.opensHoverHintAbove = true
            configureBankedResetSourceLink(titleLink, forecast: forecast)
            eventHost.track(titleLink)
        }
        // The countdown variant reserves a dedicated subtitle line for the
        // absolute deadline and a separate bottom row for the progress bar.
        // Other presentations keep the shared forecast/hint subtitle slot.
        if contentKey.primary == .countdown {
            let deadlineFrame = overviewMarqueeFrame(
                row.reset, avoidingAmountFrame: amount.frame,
                amountText: marqueeAmountText, amountFont: reservationFont,
                minimumAmountGap: 12
            )
            if let deadline = forecast.officialWindowDeadlineText(timeZone: settings.displayTimeZone) {
                addBankedResetOfficialCountdownDeadline(
                    to: view,
                    frame: deadlineFrame,
                    text: deadline,
                    leadingInkAnchor: leadingInkAnchor
                )
            }
            if let remaining = forecast.officialCountdownRemainingFraction(now: bankedResetCountdownNow()) {
                addBankedResetOfficialCountdownProgress(
                    to: view,
                    frame: row.progress,
                    remainingFraction: remaining
                )
            }
        } else if !row.reset.isEmpty {
            let subtitleFrame = row.reset
            let metricsFrame = overviewMarqueeFrame(
                subtitleFrame, avoidingAmountFrame: amount.frame,
                amountText: marqueeAmountText, amountFont: reservationFont,
                minimumAmountGap: 12
            )
            switch contentKey.subtitle {
            case .forecast:
                addBankedResetForecastMetrics(to: view, frame: metricsFrame, forecast: forecast, leadingInkAnchor: leadingInkAnchor)
            case .officialHint:
                if let hint = forecast.officialHintText() {
                    addBankedResetOfficialHint(to: view, frame: metricsFrame, text: hint, leadingInkAnchor: leadingInkAnchor)
                }
            case .countdownProgress:
                if let remaining = forecast.officialCountdownRemainingFraction(now: bankedResetCountdownNow()) {
                    addBankedResetOfficialCountdownProgress(to: view, frame: metricsFrame, remainingFraction: remaining)
                }
            case .none: break
            }
        }
    }

    private func addBankedResetOfficialCountdownDeadline(
        to view: NSView,
        frame: NSRect,
        text: String,
        leadingInkAnchor: CGFloat
    ) {
        let label = makeMarqueeOverviewLabel(
            text,
            font: OpenCodexCardLayout.bankedResetForecastSubtitleFont,
            textColor: .secondaryLabelColor,
            frame: frame,
            leadingInkAnchor: leadingInkAnchor
        )
        label.identifier = NSUserInterfaceItemIdentifier(
            "codex.bankedReset.officialCountdownDeadline"
        )
        label.accountLabel.identifier = label.identifier
        view.addSubview(label)
    }

    private func addBankedResetOfficialCountdownProgress(
        to view: NSView,
        frame: NSRect,
        remainingFraction: Double
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        let progress = QuotaProgressView(
            percentage: remainingFraction * 100,
            colorConfiguration: settings.quotaProgressColorConfiguration,
            fillOrigin: .leading
        )
        progress.frame = frame
        progress.identifier = NSUserInterfaceItemIdentifier(
            "codex.bankedReset.officialCountdownProgress"
        )
        view.addSubview(progress)
    }

    private func addBankedResetOfficialHint(
        to view: NSView,
        frame: NSRect,
        text: String,
        leadingInkAnchor: CGFloat
    ) {
        let label = makeMarqueeOverviewLabel(
            text, font: OpenCodexCardLayout.bankedResetForecastSubtitleFont,
            textColor: .secondaryLabelColor, frame: frame, leadingInkAnchor: leadingInkAnchor
        )
        label.identifier = NSUserInterfaceItemIdentifier("codex.bankedReset.officialHint")
        label.accountLabel.identifier = label.identifier
        view.addSubview(label)
    }

    private func addBankedResetForecastMetrics(
        to view: NSView,
        frame: NSRect,
        forecast: CodexResetForecast,
        leadingInkAnchor: CGFloat
    ) {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: OpenCodexCardLayout.bankedResetForecastSubtitleFont.pointSize,
            weight: .regular
        )
        let subtitle = makeMarqueeOverviewLabel(
            bankedResetForecastSubtitleText(forecast), font: font,
            textColor: .secondaryLabelColor, frame: frame, leadingInkAnchor: leadingInkAnchor
        )
        subtitle.identifier = NSUserInterfaceItemIdentifier("codex.bankedReset.forecastSubtitle")
        subtitle.accountLabel.identifier = subtitle.identifier
        view.addSubview(subtitle)
    }

    private func bankedResetForecastSubtitleText(_ forecast: CodexResetForecast) -> String {
        tr(.keyCodexBankedResetProbability48hFormat, arguments: [forecast.probability48h.displayText])
    }

    private func updateBankedResetForecastSubtitleIfNeeded(in overview: NSView, snapshot: Snapshot) {
        guard let subtitle = descendantViews(of: overview, as: AccountMarqueeView.self).first(where: {
            $0.identifier?.rawValue == "codex.bankedReset.forecastSubtitle"
        }) else { return }
        let forecast = snapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
            hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota
        ).resetForecast
        guard forecast.showsOrdinaryForecastMetrics else { return }
        subtitle.updateText(bankedResetForecastSubtitleText(forecast), preserveScrollPosition: true)
    }

    private func makeOverviewNumericAmount(
        plan: OverviewNumericTransitionPlan,
        sample: OverviewNumericSample,
        frame: NSRect,
        verticalAlignment: OverviewNumericVerticalAlignment = .center
    ) -> OverviewNumericTextView {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: OpenCodexCardLayout.quotaAmountPointSize,
            weight: .semibold
        )
        let view = OverviewNumericTextView(
            text: plan.startText,
            font: font,
            value: plan.startValue,
            verticalAlignment: verticalAlignment
        )
        view.frame = frame
        view.identifier = OverviewNumericPresentation.amountIdentifier(for: sample.identity)
        view.textField.identifier = view.identifier
        view.configure(plan: plan, sample: sample)
        return view
    }

    private func configureBankedResetSourceLink(_ link: HoverLinkTextField, forecast: CodexResetForecast) {
        link.hoverHintDelay = OpenCodexCardLayout.bankedResetProbabilityHoverHintDelay
        let content = Self.codexResetForecastTooltip(for: forecast, timeZone: settings.displayTimeZone)
        link.updateForecastTooltipContent(content)
        link.onActivate = {
            NSWorkspace.shared.open(CodexResetForecastParser.websiteURL)
        }
    }

    private func makeOverviewNumericHoverLinkAmount(
        plan: OverviewNumericTransitionPlan,
        sample: OverviewNumericSample,
        frame: NSRect,
        forecast: CodexResetForecast
    ) -> OverviewNumericHoverLinkTextField {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: OpenCodexCardLayout.quotaAmountPointSize,
            weight: .semibold
        )
        let link = OverviewNumericHoverLinkTextField(text: plan.startText)
        link.font = font
        link.alignment = .right
        link.cell?.alignment = .right
        link.lineBreakMode = .byClipping
        link.usesSingleLineMode = true
        link.restingTextColor = .labelColor
        link.frame = frame
        link.identifier = OverviewNumericPresentation.amountIdentifier(for: sample.identity)
        link.textColor = .labelColor
        link.percentSignFont = OverviewNumericTextView.currencySymbolFont(for: font)
        makeInertBankedResetAmount(link)
        link.configure(plan: plan, sample: sample)
        return link
    }

    private func makeOverviewQuotaProgress(
        plan: OverviewNumericTransitionPlan,
        frame: NSRect,
        window: OfficialQuotaWindow,
        cycleStart: Date?,
        now: Date
    ) -> NSView {
        guard settings.showQuotaPaceIndicator,
              window.kind == .fiveHour || window.kind == .sevenDay else {
            return makeOverviewNumericProgress(plan: plan, frame: frame)
        }
        let host = QuotaProgressPaceView(
            percentage: plan.startProgress ?? plan.toProgress ?? window.remaining,
            window: window,
            identity: plan.identity,
            now: now,
            colorConfiguration: settings.quotaProgressColorConfiguration,
            cycleStart: cycleStart,
            timeZone: settings.displayTimeZone
        )
        host.frame = frame.insetBy(dx: 0, dy: -6.5)
        if plan.animates, let target = plan.toProgress {
            host.setPercentage(target, animated: true, duration: OverviewNumericTransition.duration(for: plan.format))
        }
        return host
    }

    /// The probability title owns the bubble and link; the amount must not
    /// react to hover even if a card reconcile registers it with the host.
    private func makeInertBankedResetAmount(_ amount: HoverLinkTextField) {
        amount.decoratesOnHover = false
        amount.setInteractionMode(.menuHosted)
    }

    private func makeOverviewNumericProgress(
        plan: OverviewNumericTransitionPlan,
        frame: NSRect
    ) -> QuotaProgressView {
        let start = plan.startProgress ?? plan.toProgress ?? 0
        let progress = QuotaProgressView(
            percentage: start,
            colorConfiguration: settings.quotaProgressColorConfiguration
        )
        progress.frame = frame
        progress.identifier = OverviewNumericPresentation.progressIdentifier(for: plan.identity)
        if plan.animates, let target = plan.toProgress {
            progress.setPercentage(
                target,
                animated: true,
                duration: OverviewNumericTransition.duration(for: plan.format)
            )
        }
        return progress
    }

    private func cancelPendingOverviewNumericTransitions() {
        overviewNumericOpenWorkItem?.cancel()
        overviewNumericOpenWorkItem = nil
    }

    private func playPendingOverviewNumericTransitions() {
        guard statusMenu.items.first?.view != nil else { return }
        cancelPendingOverviewNumericTransitions()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.overviewNumericOpenWorkItem = nil
            for card in self.menuContentCardsForUpdate("numerics.open") {
                self.playOverviewNumericTransitions(in: card.host)
            }
        }
        overviewNumericOpenWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OverviewNumericTransition.openDelay,
            execute: work
        )
    }

    private func playOverviewNumericTransitions(in overview: NSView) {
        for view in overviewNumericTextViews(in: overview) {
            view.playPendingIfNeeded()
        }
        for link in overviewNumericLinkFields(in: overview) {
            link.playPendingIfNeeded()
        }
        for progress in overviewNumericProgressViews(in: overview) {
            progress.playPendingAnimationIfNeeded()
        }
    }

    struct ForecastContentKey: Equatable {
        enum Primary: Equatable { case confirmed, countdown, ordinaryNumeric, ordinaryPlaceholder, signalNumeric, signalPlaceholder }
        enum Subtitle: Equatable { case forecast, officialHint, countdownProgress, none }
        let primary: Primary
        let subtitle: Subtitle
    }

    private func forecastContentKey(_ forecast: CodexResetForecast) -> ForecastContentKey {
        let primary: ForecastContentKey.Primary
        if forecast.isOfficialResetConfirmed { primary = .confirmed }
        else if forecast.remainingCountdownMinutes(now: bankedResetCountdownNow()) != nil { primary = .countdown }
        else {
            switch forecast.menuProbabilityPresentation {
            case .ordinary(.percent): primary = .ordinaryNumeric
            case .ordinary: primary = .ordinaryPlaceholder
            case .strongSignal(.percent): primary = .signalNumeric
            case .strongSignal: primary = .signalPlaceholder
            }
        }
        let subtitle: ForecastContentKey.Subtitle
        if forecast.showsOrdinaryForecastMetrics { subtitle = .forecast }
        else if forecast.isOfficialResetConfirmed, forecast.officialHintText() != nil { subtitle = .officialHint }
        else if forecast.officialCountdownRemainingFraction(now: bankedResetCountdownNow()) != nil { subtitle = .countdownProgress }
        else if forecast.officialHintText() != nil { subtitle = .officialHint }
        else { subtitle = .none }
        return ForecastContentKey(primary: primary, subtitle: subtitle)
    }

    /// Single source for the direct card's refresh time: a rebuilt card and an
    /// in-place update while the menu stays open must show the same state.
    private func applyRefreshTime(to label: NSTextField, date: Date?, staleReason: String?) {
        let timeText = date.map { AppDisplayTime.formatter(timeZone: settings.displayTimeZone).string(from: $0) } ?? "--:--:--"
        label.stringValue = staleReason == nil ? timeText : "⚠︎ " + timeText
        label.textColor = staleReason == nil ? .secondaryLabelColor : .systemOrange
        label.toolTip = staleReason
        label.setAccessibilityLabel(staleReason.map { tr(.keyAggregationStale) + " · " + timeText + " · " + $0 } ?? timeText)
    }

    /// Right-aligns the fixed-size status slot inside the refresh-time frame.
    static func statusSlotFrame(in frame: NSRect) -> NSRect {
        NSRect(x: frame.maxX - StatusSlotView.fixedWidth,
               y: frame.midY - StatusSlotView.fixedHeight / 2,
               width: StatusSlotView.fixedWidth, height: StatusSlotView.fixedHeight)
    }

    /// Shared by a rebuilt card and an in-place update, like `applyRefreshTime`.
    /// The failure reason, when any, is appended to the slot's hover text.
    private func applyQuotaStatus(_ state: StatusSlotState, reason: String?, to slot: StatusSlotView) {
        slot.hoverDetail = reason
        slot.update(state: state)
    }

    private func reconcileOverviewSectionsIfTracking() {
        guard menuInput.aggregatedProviders.isEmpty, let host = menuContentHostForUpdate("sections") else { return }
        reconcileOverviewSections(in: host, context: directCardContext(for: snapshot))
    }

    private func reconcileOverviewSections(in host: MenuHoverLinkHostView, context: OverviewCardContext) {
        // A lifted ticket floats as a snapshot; resync it with whatever changed.
        defer { host.refreshLiftedTickets() }
        let snapshot = context.snapshot
        guard snapshot.kind == .official, let previous = host.overviewLayout else { return }
        let presentation = snapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
            hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota)
        let next = makeOverviewCardLayout(for: snapshot, presentation: presentation, account: context.account,
            aggregation: !menuInput.aggregatedProviders.isEmpty)
        let nextForecastKey = forecastContentKey(presentation.resetForecast)
        let nextCardIDs = presentation.bankedReset?.cards.map(\.id) ?? []
        let providerChanged = host.providerIdentity != context.identity
        // Each card owns its account: aggregated Codex cards are not the active one.
        let quotaIdentityChanged = host.quotaPaceAccount != context.account
            || host.quotaPaceClient != context.paceClient
        if providerChanged || quotaIdentityChanged {
            host.clearPaceHover()
            host.paceViews.forEach { $0.invalidatePresentation() }
        }
        if previous != next || providerChanged || quotaIdentityChanged || host.forecastContentKey != nextForecastKey || host.bankedResetCardIDs != nextCardIDs {
            // Topology or local geometry changes may replace affected sections;
            // unchanged sections keep their controls and animation state.
            guard let proposed = makeOverviewMenuItem(for: snapshot, context: context).view as? MenuHoverLinkHostView else { return }
            host.beginFocusSectionReplacement()
            defer { host.finishFocusSectionReplacement() }
            let oldSections = Dictionary(uniqueKeysWithValues: host.subviews.compactMap {
                ($0 as? OpenCodexOverviewSectionView).map { ($0.sectionID, $0) }
            })
            let proposedSections = proposed.subviews.compactMap { $0 as? OpenCodexOverviewSectionView }
            let oldScroll = descendantViews(of: host, as: BankedResetTicketScrollView.self).first
            let scrollOrigin = oldScroll?.contentView.bounds.origin
            for newSection in proposedSections {
                let oldLayout = previous.sectionLayouts.first { $0.id == newSection.sectionID }
                let newLayout = next.sectionLayouts.first { $0.id == newSection.sectionID }
                let sameLocalGeometry = !providerChanged && !quotaIdentityChanged && oldLayout?.row == newLayout?.row
                    && oldLayout?.header == newLayout?.header
                    && oldLayout?.frame.size == newLayout?.frame.size
                    && (newSection.sectionID != .resetProbability || host.forecastContentKey == nextForecastKey)
                    && (newSection.sectionID != .bankedReset || (previous.bankedResetDetailRows == next.bankedResetDetailRows && host.bankedResetCardIDs == nextCardIDs))
                if sameLocalGeometry, let old = oldSections[newSection.sectionID] {
                    if let newLayout { old.updatePlacement(newLayout) }
                } else {
                    oldSections[newSection.sectionID]?.removeFromSuperview()
                    newSection.removeFromSuperview()
                    host.addSubview(newSection)
                }
            }
            for (id, old) in oldSections where !next.sectionLayouts.contains(where: { $0.id == id }) {
                old.removeFromSuperview()
            }
            host.frame.size = next.cardSize
            host.overviewLayout = next
            host.providerIdentity = context.identity
            host.quotaPaceAccount = context.account
            host.quotaPaceClient = context.paceClient
            host.forecastContentKey = nextForecastKey
            host.bankedResetCardIDs = nextCardIDs
            // Moved sections were tracked by the proposal host; re-register every link here.
            descendantViews(of: host, as: HoverLinkTextField.self).forEach { host.track($0) }
            if let scroll = descendantViews(of: host, as: BankedResetTicketScrollView.self).first {
                host.trackTicketScroll(scroll)
                if let scrollOrigin {
                    scroll.contentView.scroll(to: scrollOrigin)
                }
            }
            host.refreshMarqueeVisibility()
        }
        if let header = host.subviews.compactMap({ $0 as? OpenCodexAccountSectionView }).first {
            let labels = header.subviews.compactMap { $0 as? NSTextField }
            labels.first { $0.font?.pointSize == 15 }?.stringValue = snapshot.overviewProvider
            if let refreshTime = labels.first(where: { $0.identifier?.rawValue == "overview.refreshTime" }) {
                applyRefreshTime(to: refreshTime, date: context.date, staleReason: snapshot.staleReason)
            }
            if let slot = header.subviews.compactMap({ $0 as? StatusSlotView }).first,
               let quotaStatus = snapshot.quotaStatus {
                applyQuotaStatus(quotaStatus, reason: snapshot.staleReason, to: slot)
            }
            if let account = context.account, case .available(let email) = account.state {
                descendantViews(of: header, as: AccountEmailView.self).first?.updateText(email)
            }
            if let subscription = context.account?.subscription {
                labels.first { $0.font == Self.subscriptionFont }?.stringValue = subscription.text
            }
        }
        updateOverviewHeaderNotes(in: host, context: context)
        let sections = host.subviews.compactMap { $0 as? OpenCodexMetricSectionView }
        for (index, window) in presentation.windows.enumerated() {
            let id = OpenCodexOverviewSectionID.quota(window, index: index)
            guard let section = sections.first(where: { $0.sectionID == id }) else { continue }
            let resetText = window.resetDisplayText(timeZone: settings.displayTimeZone).map {
                tr(.keySnapshotResetValue, arguments: [$0])
            } ?? tr(.keySnapshotResetValue, arguments: [tr(.keyLocalizationUnknown)])
            section.updateText(title: window.label, subtitle: resetText)
        }
        if let reserve = presentation.lunaReserve,
           let section = sections.first(where: { $0.sectionID == .lunaReserve }) {
            section.updateText(title: reserve.menuTitleText, subtitle: reserve.menuSubtitle(timeZone: settings.displayTimeZone))
        }
        if let section = sections.first(where: { $0.sectionID == .resetProbability }) {
            let titleText = presentation.resetForecast.isOfficialWindowDeadlineCountdown
                ? tr(.keyCodexBankedResetWindowDeadlineCountdown)
                : tr(.keyCodexBankedResetProbabilityPrefix)
            (section.titleView as? AccountMarqueeView)?.updateText(titleText, preserveScrollPosition: true)
            if let deadline = presentation.resetForecast.officialWindowDeadlineText(
                timeZone: settings.displayTimeZone
            ) {
                descendantViews(of: section, as: AccountMarqueeView.self).first {
                    $0.identifier?.rawValue == "codex.bankedReset.officialCountdownDeadline"
                }?.updateText(deadline, preserveScrollPosition: true)
            }
        }
        if let banked = presentation.bankedReset,
           let section = sections.first(where: { $0.sectionID == .bankedReset }) {
            (section.titleView as? AccountMarqueeView)?.updateText(tr(.keyCodexBankedResetTitle), preserveScrollPosition: true)
            if let document = descendantViews(of: section, as: BankedResetTicketDocumentView.self).first {
                for (card, row) in zip(banked.cards, next.bankedResetDetailRows) {
                    let expiry = CodexBankedResetFormatting.expiryText(for: card.expiresAt, relativeTo: Date(), timeZone: settings.displayTimeZone)
                        ?? (card.expiresAt == nil ? card.expiresText : nil) ?? ""
                    let lines: [(String, String, NSRect, NSFont, NSColor)] = [
                        ("codex.bankedReset.ticketTitle", card.titleText, row.quotaDetail,
                         .systemFont(ofSize: OpenCodexCardLayout.quotaDetailPointSize, weight: .medium), .labelColor),
                        ("codex.bankedReset.ticketWindow", card.windowText ?? "", row.window,
                         .systemFont(ofSize: OpenCodexCardLayout.quotaResetPointSize), .secondaryLabelColor),
                        ("codex.bankedReset.ticketExpiry", expiry, row.reset,
                         .systemFont(ofSize: OpenCodexCardLayout.quotaResetPointSize), .secondaryLabelColor)
                    ]
                    for (id, text, frame, font, color) in lines {
                        let old = document.subviews.first { $0.identifier?.rawValue == id && $0.frame.origin == frame.origin }
                        if let marquee = old as? AccountMarqueeView {
                            marquee.updateText(text, preserveScrollPosition: true)
                        } else if let label = old as? NSTextField, textWidth(text, font: font) + 4 <= frame.width {
                            label.stringValue = text
                        } else if !text.isEmpty {
                            old?.removeFromSuperview()
                            document.addSubview(makeTicketOverviewLabel(text, font: font, textColor: color, frame: frame, identifier: id))
                        }
                    }
                }
            }
            let fields = descendantViews(of: section, as: NSTextField.self).filter {
                $0.identifier?.rawValue == "codex.bankedReset.remaining"
            }
            for (field, card) in zip(fields, banked.cards) {
                field.stringValue = card.remainingText ?? ""
                field.textColor = card.remainingIsWarning ? .systemOrange : .labelColor
            }
            if let nearest = CodexBankedResetFormatting.nearestExpiryText(cards: banked.cards, timeZone: settings.displayTimeZone) {
                (section.subtitleView as? AccountMarqueeView)?.updateText(nearest, preserveScrollPosition: true)
            }
        }
    }

    private func applyInPlaceOverviewNumericUpdatesIfTracking() {
        guard statusMenu.items.first?.view != nil else { return }
        let cards = menuContentCardsForUpdate("numerics")
        let aggregated = !menuInput.aggregatedProviders.isEmpty
        // Error cards are plain views without their own dismissal state; they
        // follow the menu-wide gate.
        let plainCards = aggregated && isStatusMenuTracking && !outgoingMenuIsDismissing
            ? aggregationOverviewDisplays.filter { !(aggregationCards[$0.identity]?.card is MenuHoverLinkHostView) }
            : []
        guard !cards.isEmpty || !plainCards.isEmpty else { return }
        presentedOverviewNumerics = currentOverviewNumericSamples()
        for (host, context) in cards {
            applyInPlaceOverviewNumericUpdates(in: host, context: context)
            if aggregated, let display = aggregationOverviewDisplays.first(where: {
                aggregationCards[$0.identity]?.card === host
            }) {
                updateAggregationTimestamp(in: host, display: display)
            }
        }
        for display in plainCards {
            guard let card = aggregationCards[display.identity]?.card else { continue }
            applyInPlaceOverviewNumericUpdates(in: card, context: cardContext(display))
            updateAggregationTimestamp(in: card, display: display)
        }
    }

    private func applyInPlaceOverviewNumericUpdates(in overview: NSView, context: OverviewCardContext) {
        defer { (overview as? MenuHoverLinkHostView)?.refreshLiftedTickets() }
        let snapshot = context.snapshot
        if snapshot.kind == .balance, let host = overview as? MenuHoverLinkHostView {
            let presentation = snapshot.officialQuotaMenuPresentation(lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
                hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota)
            reconcileBalanceLayout(in: host, next: makeOverviewCardLayout(for: snapshot, presentation: presentation,
                account: context.account, aggregation: !menuInput.aggregatedProviders.isEmpty))
            updateBalanceSubtitle(in: host, context: context)
            alignSingleLineBalance(in: host, snapshot: context.snapshot)
        }
        let samples = numericSamples(for: context)
        let reduceMotion = shouldReduceOverviewNumericMotion()
        let amountViews = overviewNumericTextViews(in: overview)
        let linkViews = overviewNumericLinkFields(in: overview)
        let progressViews = overviewNumericProgressViews(in: overview)
        progressViews.forEach { $0.setColorConfiguration(settings.quotaProgressColorConfiguration) }
        for sample in samples {
            let displayed: OverviewNumericSample?
            let matchingAmounts = amountViews.filter { $0.sample?.identity == sample.identity }
            if let view = matchingAmounts.first,
               let current = view.sample {
                displayed = OverviewNumericSample(
                    identity: current.identity,
                    format: current.format,
                    value: view.currentValue,
                    progressPercentage: current.progressPercentage
                )
                let plan = OverviewNumericTransition.plan(
                    previous: displayed,
                    current: sample,
                    reduceMotion: reduceMotion
                )
                // The large 24h figure and the subtitle 24h share one sample.
                for amountView in matchingAmounts {
                    amountView.apply(plan: plan, sample: sample)
                }
            } else if let link = linkViews.first(where: { $0.sample?.identity == sample.identity }),
                      let current = link.sample {
                displayed = OverviewNumericSample(
                    identity: current.identity,
                    format: current.format,
                    value: link.currentValue,
                    progressPercentage: nil
                )
                let plan = OverviewNumericTransition.plan(
                    previous: displayed,
                    current: sample,
                    reduceMotion: reduceMotion
                )
                link.apply(plan: plan, sample: sample)
            }
            if let progress = progressViews.first(where: {
                $0.identifier == OverviewNumericPresentation.progressIdentifier(for: sample.identity)
            }), let target = sample.progressPercentage {
                progress.setPercentage(
                    target,
                    animated: !reduceMotion,
                    duration: OverviewNumericTransition.duration(for: sample.format)
                )
            }
        }
        updateBankedResetForecastSubtitleIfNeeded(in: overview, snapshot: snapshot)
        let forecast = snapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
            hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota).resetForecast
        let tooltipContent = Self.codexResetForecastTooltip(for: forecast, timeZone: settings.displayTimeZone)
        for link in descendantViews(of: overview, as: HoverLinkTextField.self)
            where link.forecastTooltipContent != nil {
            link.updateForecastTooltipContent(tooltipContent)
        }
        if let hint = forecast.officialHintText(), let label = descendantViews(of: overview, as: AccountMarqueeView.self).first(where: {
            $0.identifier?.rawValue == "codex.bankedReset.officialHint"
        }) { label.updateText(hint, preserveScrollPosition: true) }
        applyOfficialCountdownProgressIfNeeded(in: overview, snapshot: snapshot)
    }

    private func applyOfficialCountdownProgressIfNeeded(in overview: NSView, snapshot: Snapshot) {
        guard let progress = overviewNumericProgressViews(in: overview).first(where: {
            $0.identifier?.rawValue == "codex.bankedReset.officialCountdownProgress"
        }) else { return }
        let forecast = snapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
            hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota
        ).resetForecast
        guard let remaining = forecast.officialCountdownRemainingFraction(
            now: bankedResetCountdownNow()
        ) else { return }
        progress.setPercentage(remaining * 100, animated: false)
    }

    private func overviewNumericTextViews(in view: NSView) -> [OverviewNumericTextView] {
        descendantViews(of: view, as: OverviewNumericTextView.self)
    }

    private func overviewNumericLinkFields(in view: NSView) -> [OverviewNumericHoverLinkTextField] {
        descendantViews(of: view, as: OverviewNumericHoverLinkTextField.self)
    }

    private func overviewNumericProgressViews(in view: NSView) -> [QuotaProgressView] {
        descendantViews(of: view, as: QuotaProgressView.self)
    }

    private func descendantViews<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var matches: [T] = []
        if let match = view as? T {
            matches.append(match)
        }
        for child in view.subviews {
            matches.append(contentsOf: descendantViews(of: child, as: type))
        }
        return matches
    }

    private func makeSubscriptionLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = makeOverviewLabel(text, font: Self.subscriptionFont)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.frame = frame
        return label
    }

    private func makeAccountLabel(
        _ account: OpenAIAccountPresentation,
        frame: NSRect
    ) -> NSView {
        switch account.state {
        case .available(let email):
            return AccountEmailView(
                email: email,
                font: .systemFont(ofSize: 13, weight: .regular),
                textColor: .secondaryLabelColor,
                frame: frame
            )
        case .unavailable:
            // Keep the existing marquee path for the localized unavailable
            // state; only an actual account email gets the new static layout.
            return makeMarqueeOverviewLabel(
                account.text(),
                font: .systemFont(ofSize: 13, weight: .regular),
                textColor: .secondaryLabelColor,
                frame: frame
            )
        }
    }

    static func formatBalanceSummary(_ amount: Double, unit: String) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        switch unit.uppercased() {
        case "USD":
            return "$\(number)"
        case "CNY", "CNH", "RMB":
            return "¥\(number)"
        default:
            return "\(number) \(unit)"
        }
    }

}

extension StatusItemController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(manualRefresh) else { return true }
        applyManualRefreshContent(to: menuItem)
        return isManualRefreshAvailable
    }
}
