import AppKit
import Foundation
import QuartzCore

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
    let textOverflow: CGFloat
    let trailingFadeBuffer: CGFloat
    let scrollDistance: CGFloat
    let maskLocations: [CGFloat]

    init(
        measuredTextWidth: CGFloat,
        clipBounds: NSRect,
        fadeWidth: CGFloat = Self.defaultFadeWidth
    ) {
        let viewportWidth = max(0, clipBounds.width)
        let textWidth = max(0, measuredTextWidth)
        let overflow = max(0, textWidth - viewportWidth)
        let scrollable = viewportWidth > 0 && overflow > 0
        let effectiveFadeWidth = scrollable
            ? min(max(0, fadeWidth), min(viewportWidth / 4, overflow))
            : 0

        self.clipBounds = clipBounds
        self.measuredTextWidth = textWidth
        self.isScrollable = scrollable
        self.edgeFadeWidth = effectiveFadeWidth
        self.contentWidth = scrollable ? textWidth : max(viewportWidth, textWidth)
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

    /// The text starts in the same coordinate space as the viewport's leading
    /// edge. This is intentionally not shifted by the fade width.
    var contentFrame: NSRect {
        NSRect(
            x: clipBounds.minX,
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
/// its scrolling label. A marquee may be configured and waiting at offset zero
/// before its first movement; that state must remain unmasked.
struct AccountMarqueeScrollState: Equatable {
    static let activationThreshold: CGFloat = 0.5

    let offset: CGFloat
    let isActive: Bool

    init(offset: CGFloat, overflow: CGFloat) {
        self.offset = offset
        self.isActive = overflow > 0 && offset < -Self.activationThreshold
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
    private(set) var edgeFadeInset: CGFloat = 0
    private(set) var scrollOverflow: CGFloat = 0
    private(set) var scrollDistance: CGFloat = 0
    private(set) var scrollOffset: CGFloat = 0

    private var edgeFadeMask: CAGradientLayer?
    private var contentLayout: AccountMarqueeLayout?
    private var configuredText: String?
    private var configuredFontSignature: String?
    private var scrollActivityTimer: Timer?

    init(text: String, font: NSFont, textColor: NSColor, frame: NSRect) {
        accountLabel = NSTextField(labelWithString: text)
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
        addSubview(accountLabel)

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
    func updateText(_ text: String) {
        guard accountLabel.stringValue != text else { return }
        accountLabel.stringValue = text
        configuredText = nil
        configureContentIfNeeded(force: true)
    }

    private func configureContentIfNeeded(force: Bool = false) {
        let font = accountLabel.font ?? .systemFont(ofSize: 13)
        let text = accountLabel.stringValue
        let fontSignature = Self.fontSignature(for: font)
        let nextLayout = AccountMarqueeLayout(
            measuredTextWidth: Self.textWidth(of: text, font: font),
            clipBounds: bounds,
            fadeWidth: Self.defaultEdgeFadeWidth
        )
        guard force
            || contentLayout != nextLayout
            || configuredText != text
            || configuredFontSignature != fontSignature else {
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
                NSColor.clear.cgColor,
                NSColor.black.cgColor,
                NSColor.black.cgColor,
                NSColor.clear.cgColor
            ]
            mask.locations = nextLayout.maskLocations.map {
                NSNumber(value: Double($0))
            }
            edgeFadeMask = mask
            // Keep the initial, zero-offset frame fully readable. The mask is
            // attached only after the presentation layer reports real motion.
            layer?.mask = nil
            showsEdgeFade = false
            updateEdgeFadeMaskFrame()
        } else {
            layer?.mask = nil
            edgeFadeMask = nil
            showsEdgeFade = false
        }

        startScrollingIfNeeded()
    }

    private func updateEdgeFadeMaskFrame() {
        guard let mask = edgeFadeMask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = layer?.bounds ?? bounds
        CATransaction.commit()
    }

    private func startScrollingIfNeeded() {
        guard isScrollable,
              window != nil || superview != nil,
              let labelLayer = accountLabel.layer else {
            return
        }

        let overflow = contentLayout?.textOverflow ?? scrollOverflow
        guard overflow > 0 else { return }

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
        accountLabel.layer?.removeAnimation(forKey: Self.animationKey)
        scrollActivityTimer?.invalidate()
        scrollActivityTimer = nil
        applyScrollState(AccountMarqueeScrollState(offset: 0, overflow: 0))
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
            self?.updateScrollActivity()
        }
        scrollActivityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateScrollActivity()
    }

    private func updateScrollActivity() {
        guard let labelLayer = accountLabel.layer,
              labelLayer.animation(forKey: Self.animationKey) != nil else {
            applyScrollState(AccountMarqueeScrollState(offset: 0, overflow: 0))
            return
        }

        let offset = (labelLayer.presentation()?
            .value(forKeyPath: "transform.translation.x") as? NSNumber)
            .map { CGFloat($0.doubleValue) } ?? 0
        applyScrollState(
            AccountMarqueeScrollState(offset: offset, overflow: scrollOverflow)
        )
    }

    private func applyScrollState(_ state: AccountMarqueeScrollState) {
        scrollOffset = state.offset
        isScrolling = state.isActive

        guard state.isActive != showsEdgeFade else { return }
        if state.isActive, let mask = edgeFadeMask {
            layer?.mask = mask
            updateEdgeFadeMaskFrame()
        } else {
            layer?.mask = nil
        }
        showsEdgeFade = state.isActive
    }

    /// Test seam for checking the mask contract without depending on a live
    /// WindowServer presentation frame. Production activity is sampled from
    /// the label layer's presentation transform in `updateScrollActivity()`.
    func applyScrollOffsetForTesting(_ offset: CGFloat) {
        applyScrollState(
            AccountMarqueeScrollState(offset: offset, overflow: scrollOverflow)
        )
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
    let sourceFrameIdentities: [ObjectIdentifier]
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
    let usesBitmapContent: Bool

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
        iconViewImageAlignment: Int = 0,
        usesBitmapContent: Bool = true
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
        self.usesBitmapContent = usesBitmapContent
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
/// already-installed representation and request a redraw on the button.
struct MenuBarStableBitmapAnimationFrameBuffer {
    private(set) var image: NSImage?
    private(set) var backing: NSBitmapImageRep?
    private(set) var signature: MenuBarBitmapAnimationVisualSignature?
    private(set) var sourceFrameIdentities: [ObjectIdentifier] = []
    private(set) var completeFrameIdentities: [ObjectIdentifier] = []
    private var framePixelBuffers: [Data] = []
    private(set) var rebuildCount = 0
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
}

final class StatusItemController: NSObject, NSMenuDelegate {
    /// macOS renders status items whose button carries no image with a
    /// greyed-out, translucent appearance on displays that do not own
    /// keyboard focus. Assigning an empty image keeps the item on the
    /// standard image-backed rendering path so its inactive-display dimming
    /// matches the rest of the menu bar.
    static let placeholderButtonImage = NSImage()
    private static let statusItemVisibilityStabilityDelay: TimeInterval = 0.2
    private static let menuBarTransitionWatchCadence =
        MenuBarAnimationOverlayTransitionWatch.cadence
    private static let subscriptionFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    struct Actions {
        let manualRefresh: () -> Void
        let openDashboard: () -> Void
        let openChatGPT: () -> Void
        let openCCSwitch: () -> Void
        let openOpenCodex: () -> Void
        let quit: () -> Void
        let switchProvider: (String) -> Void
        let switchOpenCodexPreference: (OpenCodexPreference) -> Void
        let openProviderWebsite: () -> Void
        let openStatusLink: (URL) -> Void
        let iconChanged: (NSImage?) -> Void
        let frameImageChanged: (NSImage?) -> Void
        let overlayAnimationStateChanged: (Bool) -> Void
        let visibilityChanged: (StatusItemVisibility) -> Void

        init(
            manualRefresh: @escaping () -> Void,
            openDashboard: @escaping () -> Void,
            openChatGPT: @escaping () -> Void,
            openCCSwitch: @escaping () -> Void,
            openOpenCodex: @escaping () -> Void,
            quit: @escaping () -> Void,
            switchProvider: @escaping (String) -> Void,
            switchOpenCodexPreference: @escaping (OpenCodexPreference) -> Void,
            openProviderWebsite: @escaping () -> Void,
            openStatusLink: @escaping (URL) -> Void,
            iconChanged: @escaping (NSImage?) -> Void,
            frameImageChanged: @escaping (NSImage?) -> Void = { _ in },
            overlayAnimationStateChanged: @escaping (Bool) -> Void = { _ in },
            visibilityChanged: @escaping (StatusItemVisibility) -> Void = { _ in }
        ) {
            self.manualRefresh = manualRefresh
            self.openDashboard = openDashboard
            self.openChatGPT = openChatGPT
            self.openCCSwitch = openCCSwitch
            self.openOpenCodex = openOpenCodex
            self.quit = quit
            self.switchProvider = switchProvider
            self.switchOpenCodexPreference = switchOpenCodexPreference
            self.openProviderWebsite = openProviderWebsite
            self.openStatusLink = openStatusLink
            self.iconChanged = iconChanged
            self.frameImageChanged = frameImageChanged
            self.overlayAnimationStateChanged = overlayAnimationStateChanged
            self.visibilityChanged = visibilityChanged
        }
    }

    struct MenuBarSettings {
        let showIcon: Bool
        let showAmount: Bool
        let showReset: Bool
        let iconDisplayMode: MenuBarIconDisplayMode
        let iconDisplayDelay: MenuBarIconDisplayDelay
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
        /// the default 13:10 ratio in the renderer.
        var fontSize: CGFloat
        let quotaResetDisplayMode: OfficialQuotaResetDisplayMode
        let autoSwitchLunaReserve: Bool
        let lunaReserveResetTimeMode: LunaReserveResetTimeMode
        let quotaProgressColorConfiguration: QuotaProgressColorConfiguration
        let usesBitmapContent: Bool

        init(
            showIcon: Bool,
            showAmount: Bool,
            showReset: Bool,
            horizontalPadding: CGFloat,
            keepMenuOpenAfterRefresh: Bool,
            iconDisplayMode: MenuBarIconDisplayMode = .defaultValue,
            iconDisplayDelay: MenuBarIconDisplayDelay = .defaultValue,
            iconOffsetX: CGFloat = 0,
            iconOffsetY: CGFloat = 0,
            amountOffsetX: CGFloat = 0,
            amountOffsetY: CGFloat = 0,
            widthAdjustment: CGFloat = 0,
            fontSize: CGFloat = MenuBarLayout.primaryFontPointSize,
            quotaWindowPreference: OfficialQuotaWindowPreference = .defaultValue,
            quotaResetDisplayMode: OfficialQuotaResetDisplayMode = .defaultValue,
            autoSwitchLunaReserve: Bool = false,
            lunaReserveResetTimeMode: LunaReserveResetTimeMode = .defaultValue,
            quotaProgressColorConfiguration: QuotaProgressColorConfiguration = .default,
            usesBitmapContent: Bool = AppPreferences.menuBarBitmapContentDefault
        ) {
            self.showIcon = showIcon
            self.showAmount = showAmount
            self.showReset = showReset
            self.iconDisplayMode = iconDisplayMode
            self.iconDisplayDelay = iconDisplayDelay
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
            self.usesBitmapContent = usesBitmapContent
            self.fontSize = CGFloat(
                AppPreferences.normalizedMenuBarFontSize(
                    Double(fontSize),
                    range: AppPreferences.menuBarFontSizeRange
                )
            )
        }
    }

    struct MenuInput: Equatable {
        let openCodexCards: [OpenCodexModelCard]
        let openCodexState: OpenCodexRuntimeState?
        let openCodexSwitchInFlight: Bool
        let choices: [ProviderChoice]
        let quickSwitchSummaries: [String: String]
        let activeClient: AssistantClient
        let openAIAccount: OpenAIAccountPresentation?
        let statusLinks: [StatusLink]
        let showQuickSwitchMenu: Bool
        let showOpenChatGPTMenu: Bool
        let showOpenCCSwitchMenu: Bool
        let showOpenCodexMenu: Bool
        let showStatusMenu: Bool
        let lunaReserveDisplayMode: LunaReserveDisplayMode
        let lunaReserveHideExhaustedQuota: Bool
        let showsAvailableUpdateBadge: Bool

        init(
            openCodexCards: [OpenCodexModelCard],
            openCodexState: OpenCodexRuntimeState?,
            openCodexSwitchInFlight: Bool,
            choices: [ProviderChoice],
            quickSwitchSummaries: [String: String],
            activeClient: AssistantClient,
            openAIAccount: OpenAIAccountPresentation?,
            statusLinks: [StatusLink],
            showQuickSwitchMenu: Bool,
            showOpenChatGPTMenu: Bool,
            showOpenCCSwitchMenu: Bool,
            showOpenCodexMenu: Bool,
            showStatusMenu: Bool,
            lunaReserveDisplayMode: LunaReserveDisplayMode = .defaultValue,
            lunaReserveHideExhaustedQuota: Bool = false,
            showsAvailableUpdateBadge: Bool = false
        ) {
            self.openCodexCards = openCodexCards
            self.openCodexState = openCodexState
            self.openCodexSwitchInFlight = openCodexSwitchInFlight
            self.choices = choices
            self.quickSwitchSummaries = quickSwitchSummaries
            self.activeClient = activeClient
            self.openAIAccount = openAIAccount
            self.statusLinks = statusLinks
            self.showQuickSwitchMenu = showQuickSwitchMenu
            self.showOpenChatGPTMenu = showOpenChatGPTMenu
            self.showOpenCCSwitchMenu = showOpenCCSwitchMenu
            self.showOpenCodexMenu = showOpenCodexMenu
            self.showStatusMenu = showStatusMenu
            self.lunaReserveDisplayMode = lunaReserveDisplayMode
            self.lunaReserveHideExhaustedQuota = lunaReserveHideExhaustedQuota
            self.showsAvailableUpdateBadge = showsAvailableUpdateBadge
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.openCodexCards == rhs.openCodexCards
                && lhs.openCodexState == rhs.openCodexState
                && lhs.openCodexSwitchInFlight == rhs.openCodexSwitchInFlight
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
                && lhs.showOpenCodexMenu == rhs.showOpenCodexMenu
                && lhs.showStatusMenu == rhs.showStatusMenu
                && lhs.lunaReserveDisplayMode == rhs.lunaReserveDisplayMode
                && lhs.lunaReserveHideExhaustedQuota == rhs.lunaReserveHideExhaustedQuota
                && lhs.showsAvailableUpdateBadge == rhs.showsAvailableUpdateBadge
        }
    }

    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var statusItemAttachmentCheckScheduled = false
    private var statusItemReanchorAttempts = 0
    private var isStatusMenuTracking = false
    private var statusMenuNeedsRebuild = false
    private let menuBarIconView = RotatingTemplateImageView()
    private let menuBarIconSlot = PassthroughView()
    private let menuBarTextStack = MenuBarTextView()
    private let menuBarContentStack = MenuBarContentView()
    /// The bitmap-backed content mode keeps the content view tree offscreen as
    /// a layout/render engine while the button displays one template bitmap,
    /// so macOS 26's replicant machinery has no custom view hierarchy to
    /// re-snapshot. It is the default; the Advanced > Rendering switch can
    /// opt into the traditional live-view path.
    private var usesBitmapContent = false
    private let bitmapRenderContainer = MenuBarBitmapRenderView(
        frame: NSRect(x: 0, y: 0, width: 56, height: 22)
    )
    private var cachedMenuBarTextBitmap: NSImage?
    private var cachedStaticMenuBarContentBitmap: NSImage?
    private var cachedMenuBarContentVisualSignature: MenuBarBitmapAnimationVisualSignature?
    private var menuBarBitmapImagePlacement: MenuBarBitmapImagePlacement?
    private var cachedMenuBarIconDrawRect: NSRect?
    private var codexAnimationFrameCache = MenuBarBitmapAnimationFrameCache()
    private var stableCodexAnimationFrameBuffer = MenuBarStableBitmapAnimationFrameBuffer()
    private(set) var stableCodexAnimationImageAssignmentCountForTesting = 0
    private(set) var stableCodexAnimationRedrawRequestCountForTesting = 0
    private let menuBarPrimaryLabel = PassthroughTextField(labelWithString: "…")
    private let menuBarSecondaryLabel = PassthroughTextField(labelWithString: "")
    private var isMenuBarContentStackConfigured = false
    private var lastMenuBarIconFrameDiagnostic: String?
    private var codexIconImage: NSImage?
    private var claudeIconImage: NSImage?
    private var claudeThinkingAnimator: ClaudeThinkingAnimator?
    private let animationRenderingMode: MenuBarAnimationRenderingMode
    private var isOverlayCodexAnimationActive = false
    private var menuBarAnimationOverlay: MenuBarAnimationOverlayController?
    private var isDeferringOverlaySynchronization = false
    private var fontSizeLayoutSettlementScheduled = false
    private var snapshot = Snapshot.placeholder
    private var refreshDate: Date?
    private var menuInput = MenuInput(
        openCodexCards: [],
        openCodexState: nil,
        openCodexSwitchInFlight: false,
        choices: [],
        quickSwitchSummaries: [:],
        activeClient: .codex,
        openAIAccount: nil,
        statusLinks: [],
        showQuickSwitchMenu: true,
        showOpenChatGPTMenu: true,
        showOpenCCSwitchMenu: true,
        showOpenCodexMenu: true,
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
    private var activeClient: AssistantClient = .codex
    private var isCodexTaskRunning = false
    private var isClaudeTaskRunning = false
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
    private var workspaceObservers: [NSObjectProtocol] = []
    private var overlaySynchronizationScheduled = false
    private var bitmapVisualRefreshScheduled = false
    private var overlayLifecycleSuspended = false
    private var menuBarTransitionWatcher: Timer?
    private var menuBarTransitionWatch = MenuBarAnimationOverlayTransitionWatch()

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

    var animationRenderingModeForTesting: MenuBarAnimationRenderingMode {
        animationRenderingMode
    }

    var overlayCodexAnimationIsActiveForTesting: Bool {
        isOverlayCodexAnimationActive
    }

    var isOverlayCodexAnimationActiveForDashboard: Bool {
        isOverlayCodexAnimationActive
    }

    var overlayAnimationIsAnimatingForTesting: Bool {
        menuBarAnimationOverlay?.isAnimating ?? false
    }

    var overlayAnimationIsVisibleForTesting: Bool {
        menuBarAnimationOverlay?.isVisible ?? false
    }

    var overlayAnimationHasInstalledRotationForTesting: Bool {
        menuBarAnimationOverlay?.hasInstalledRotationAnimationForTesting ?? false
    }

    var menuBarTransitionWatcherIsActiveForTesting: Bool {
        menuBarTransitionWatcher != nil
    }

    var overlayAnimationStartCountForTesting: Int {
        menuBarAnimationOverlay?.animationStartCount ?? 0
    }

    var overlayAnimationStopCountForTesting: Int {
        menuBarAnimationOverlay?.animationStopCount ?? 0
    }

    var nativeCodexAnimationIsRotatingForTesting: Bool {
        menuBarIconView.isRotating
    }

    // Rendering-cache diagnostics keep the production seam read-only while
    // allowing focused tests to prove finite precomposition and cache reuse.
    var codexAnimationCacheFrameCountForTesting: Int {
        codexAnimationFrameCache.count
    }

    var codexAnimationCacheBuildCountForTesting: Int {
        codexAnimationFrameCache.rebuildCount
    }

    var codexAnimationFrameCompositionCountForTesting: Int {
        codexAnimationFrameCache.compositionCount
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

    var menuBarButtonImageForTesting: NSImage? { statusItem?.button?.image }

    /// Supplies a deterministic source for controller-level bitmap cache tests;
    /// production always supplies the bundled Codex asset during setup.
    func setCodexIconForTesting(_ image: NSImage) {
        codexIconImage = image
        menuBarIconView.setSourceImage(image)
    }

    func advanceCodexAnimationFrameForTesting(_ frameIndex: Int) {
        applyStableCodexAnimationFrame(frameIndex)
    }

    // Exposes the controller's actual menu for headless production-path tests.
    // The application still owns and renders this same NSMenu instance.
    var menuItemsForTesting: [NSMenuItem] { statusMenu.items }

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

    var startupDiagnostic: String {
        let statusWindow = statusItem?.button?.window
        return "status_visible=\(isVisible); menu_bound=\(statusItem?.menu === statusMenu); menu_items=\(statusMenu.items.count); button_window=\(statusWindow != nil)"
    }

    init(
        actions: Actions,
        animationRenderingMode: MenuBarAnimationRenderingMode = .configured
    ) {
        self.actions = actions
        self.animationRenderingMode = animationRenderingMode
        super.init()
        bitmapRenderContainer.onEffectiveAppearanceChanged = { [weak self] in
            self?.handleBitmapEffectiveAppearanceChanged()
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.statusItem != nil else { return }
            self.scheduleBitmapContentRefreshAfterExternalVisualChange()
            self.beginMenuBarVisibilityTransitionWatcher()
            self.scheduleOverlaySynchronization()
            self.scheduleStatusItemAttachmentCheck(
                reason: "screen-parameters",
                reanchor: false
            )
        }
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.statusItem != nil else { return }
                self.beginMenuBarVisibilityTransitionWatcher()
                self.scheduleOverlaySynchronization()
                self.scheduleStatusItemAttachmentCheck(
                    reason: "active-space",
                    reanchor: false,
                    delay: 0
                )
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.statusItem != nil else { return }
                // Reduce Motion is a live accessibility setting. Re-evaluate
                // the product animation request at this boundary so turning
                // it on removes the compositor animation immediately and
                // turning it off can restore the currently-running task.
                self.updateActivityIcon()
                self.scheduleOverlaySynchronization()
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.stopMenuBarVisibilityTransitionWatcher()
                self.overlayLifecycleSuspended = true
                self.synchronizeMenuBarAnimationOverlay()
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.overlayLifecycleSuspended = false
                self.beginMenuBarVisibilityTransitionWatcher()
                self.scheduleOverlaySynchronization()
                self.scheduleStatusItemAttachmentCheck(
                    reason: "wake",
                    reanchor: false,
                    delay: 0
                )
            }
        ]
    }

    deinit {
        removeStatusItemWindowObservation()
        menuBarAnimationOverlay?.teardown()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func handleBitmapEffectiveAppearanceChanged() {
        scheduleBitmapContentRefreshAfterExternalVisualChange()
        scheduleOverlaySynchronization()
    }

    private func scheduleOverlaySynchronization() {
        guard !overlaySynchronizationScheduled else { return }
        overlaySynchronizationScheduled = true
        let generation = lifecycleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.lifecycleGeneration == generation else { return }
            self.overlaySynchronizationScheduled = false
            self.synchronizeMenuBarAnimationOverlay()
        }
    }

    /// Auto-hide changes are not guaranteed to line up with the status
    /// window's visibility notifications. When one of the existing AppKit
    /// transition events fires, briefly re-read the public menu-bar signal and
    /// the status-item evidence until the state settles. This timer is never
    /// created by the animation tick and is invalidated after one transition.
    private func beginMenuBarVisibilityTransitionWatcher() {
        guard menuBarAnimationOverlay != nil,
              shouldUseOverlayCodexAnimation else {
            stopMenuBarVisibilityTransitionWatcher()
            return
        }
        guard menuBarTransitionWatcher == nil else { return }
        let date = Date()
        let initialObservation = makeMenuBarVisibilityTransitionObservation()
        guard menuBarTransitionWatch.begin(
            at: date,
            initialObservation: initialObservation
        ) else {
            return
        }

        let generation = lifecycleGeneration
        handleMenuBarVisibilityTransitionWatcherTick()
        guard menuBarTransitionWatch.isActive else { return }

        let timer = Timer(
            timeInterval: Self.menuBarTransitionWatchCadence,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            guard self.lifecycleGeneration == generation else {
                self.stopMenuBarVisibilityTransitionWatcher()
                return
            }
            self.handleMenuBarVisibilityTransitionWatcherTick()
        }
        timer.tolerance = Self.menuBarTransitionWatchCadence / 2
        RunLoop.main.add(timer, forMode: .common)
        menuBarTransitionWatcher = timer
    }

    private func stopMenuBarVisibilityTransitionWatcher() {
        menuBarTransitionWatcher?.invalidate()
        menuBarTransitionWatcher = nil
        menuBarTransitionWatch.stop()
    }

    private func handleMenuBarVisibilityTransitionWatcherTick() {
        guard menuBarTransitionWatch.isActive else {
            stopMenuBarVisibilityTransitionWatcher()
            return
        }
        guard statusItem != nil,
              shouldUseOverlayCodexAnimation else {
            stopMenuBarVisibilityTransitionWatcher()
            synchronizeMenuBarAnimationOverlay()
            return
        }

        // Refresh the same evidence used by the main synchronizer. This also
        // clears a stale hidden-by-space state as soon as the native item is
        // visibly attached again, without waiting for the 0.2 s retry.
        verifyStatusItemAttachment(
            reason: "menu-bar-visibility-transition",
            reanchor: false
        )
        synchronizeMenuBarAnimationOverlay()
        let shouldContinue = menuBarTransitionWatch.observe(
            makeMenuBarVisibilityTransitionObservation(),
            at: Date()
        )
        if !shouldContinue {
            stopMenuBarVisibilityTransitionWatcher()
        }
    }

    private func makeMenuBarVisibilityTransitionObservation()
        -> MenuBarAnimationOverlayTransitionObservation {
        let item = statusItem
        let button = item?.button
        let window = button?.window
        let screenFrame = shouldUseOverlayCodexAnimation
            ? menuBarAnimationOverlayScreenFrame()
            : nil
        let validGeometry = screenFrame.map {
            $0.width > 0
                && $0.height > 0
                && $0.minX.isFinite
                && $0.minY.isFinite
                && $0.maxX.isFinite
                && $0.maxY.isFinite
        } ?? false
        return MenuBarAnimationOverlayTransitionObservation(
            menuBarVisible: NSMenu.menuBarVisible(),
            statusItemVisible: item?.isVisible ?? false,
            statusWindowVisible: window?.isVisible ?? false,
            statusWindowOcclusionVisible: window?.occlusionState.contains(.visible)
                ?? false,
            validGeometry: validGeometry,
            overlayVisible: menuBarAnimationOverlay?.isVisible ?? false,
            statusVisibilityStableHidden: statusItemVisibility.isHiddenByMenuBarSpace
                || statusItemVisibility.isHiddenByRuntimePolicy
        )
    }

    private func scheduleBitmapContentRefreshAfterExternalVisualChange() {
        guard usesBitmapContent, statusItem != nil else { return }
        guard !bitmapVisualRefreshScheduled else { return }
        bitmapVisualRefreshScheduled = true
        let generation = lifecycleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.lifecycleGeneration == generation,
                  self.statusItem != nil else { return }
            self.bitmapVisualRefreshScheduled = false
            self.refreshBitmapContentAfterExternalVisualChange()
            self.scheduleOverlaySynchronization()
        }
    }

    private func refreshBitmapContentAfterExternalVisualChange() {
        guard usesBitmapContent, statusItem != nil else { return }
        invalidateBitmapContentCache()
        let wasDeferringOverlaySynchronization = isDeferringOverlaySynchronization
        isDeferringOverlaySynchronization = true
        defer {
            isDeferringOverlaySynchronization = wasDeferringOverlaySynchronization
        }
        layoutStatusItem(for: snapshot)
    }

    func start(
        snapshot: Snapshot,
        refreshDate: Date?,
        menuInput: MenuInput,
        settings: MenuBarSettings
    ) {
        lifecycleGeneration += 1
        stopMenuBarVisibilityTransitionWatcher()
        overlaySynchronizationScheduled = false
        bitmapVisualRefreshScheduled = false
        overlayLifecycleSuspended = false
        let isNewStatusItem = statusItem == nil
        if isNewStatusItem {
            usesBitmapContent = settings.usesBitmapContent
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
        lifecycleGeneration += 1
        stopMenuBarVisibilityTransitionWatcher()
        overlaySynchronizationScheduled = false
        bitmapVisualRefreshScheduled = false
        overlayLifecycleSuspended = false
        removeStatusItemWindowObservation()
        statusItemVisibilityStateMachine.reset()
        menuBarIconDisplayStateMachine.reset()
        publishStatusItemVisibility()
        statusItemAttachmentCheckScheduled = false
        statusItemReanchorAttempts = 0
        statusMenuNeedsRebuild = false
        isStatusMenuTracking = false
        lastMenuBarIconFrameDiagnostic = nil
        lastMenuBarGeometry = nil
        menuBarIconView.onSourceImageChanged = nil
        menuBarIconView.onFrameImageChanged = nil
        menuBarIconView.onAnimationFrameIndexChanged = nil
        setOverlayCodexAnimationActive(false, rebuild: false)
        menuBarAnimationOverlay?.teardown()
        menuBarIconView.stopRotating()
        claudeThinkingAnimator?.stop()
        invalidateBitmapContentCache()
        menuBarContentStack.removeFromSuperview()
        statusMenu.delegate = nil
        statusMenu.removeAllItems()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func update(
        snapshot: Snapshot,
        refreshDate: Date?,
        menuInput: MenuInput,
        settings: MenuBarSettings
    ) {
        let bitmapContentModeChanged = usesBitmapContent != settings.usesBitmapContent
        let showIconChanged = self.settings.showIcon != settings.showIcon
        let iconDisplayModeChanged = self.settings.iconDisplayMode != settings.iconDisplayMode
        let iconDisplayDelayChanged = self.settings.iconDisplayDelay != settings.iconDisplayDelay
        self.snapshot = snapshot
        self.refreshDate = refreshDate
        self.menuInput = menuInput
        self.settings = settings
        if bitmapContentModeChanged {
            if !settings.usesBitmapContent {
                setOverlayCodexAnimationActive(false, rebuild: false)
            }
            usesBitmapContent = settings.usesBitmapContent
            configureMenuBarContentPresentation()
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
        layoutStatusItem(for: snapshot)
        if (bitmapContentModeChanged || showIconChanged),
           animationRenderingMode == .overlayCoreAnimation {
            updateActivityIcon()
        }
        rebuildOrDeferMenu()
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
        // AppKit may publish the new status-button bounds one run-loop turn
        // after `statusItem.length` changes. Keep the visible text/cache
        // update synchronous, but defer the overlay's screen conversion until
        // that new button footprint is observable so the icon never takes one
        // frame through the old geometry.
        isDeferringOverlaySynchronization = true
        layoutStatusItem(for: snapshot)
        isDeferringOverlaySynchronization = false
        scheduleFontSizeLayoutSettlement()
    }

    private func scheduleFontSizeLayoutSettlement() {
        guard !fontSizeLayoutSettlementScheduled else { return }
        fontSizeLayoutSettlementScheduled = true
        let generation = lifecycleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fontSizeLayoutSettlementScheduled = false
            guard self.lifecycleGeneration == generation,
                  self.statusItem != nil else { return }
            self.isDeferringOverlaySynchronization = true
            self.layoutStatusItem(for: self.snapshot)
            self.isDeferringOverlaySynchronization = false
            self.synchronizeMenuBarAnimationOverlay()
        }
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
                widthAdjustment: widthAdjustment
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
        if usesBitmapContent {
            refreshMenuBarContentBitmap(
                buttonSize: NSSize(
                    width: requestedLength,
                    height: button.bounds.height
                )
            )
        }
        synchronizeMenuBarAnimationOverlay()
    }

    func updateMenu(input: MenuInput) {
        // The caller may still perform its periodic local-state read so the
        // database-watcher fallback remains intact. Reuse the current menu
        // hierarchy when that read produces the same semantic input.
        guard menuInput != input else { return }
        menuInput = input
        rebuildOrDeferMenu()
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
        animationEnabled: Bool
    ) {
        let activeClientChanged = self.activeClient != activeClient
        self.activeClient = activeClient
        self.isCodexTaskRunning = codexTaskRunning
        self.isClaudeTaskRunning = claudeTaskRunning
        self.animationEnabled = animationEnabled
        if activeClientChanged {
            codexAnimationFrameCache.invalidate()
            stableCodexAnimationFrameBuffer.invalidate()
        }
        updateActivityIcon()
        if activeClientChanged {
            // The source-image callback normally performs this layout. Keep a
            // direct refresh for missing optional assets so changing clients
            // can never leave a cache keyed to the previous client.
            if usesBitmapContent {
                layoutStatusItem(for: snapshot)
            }
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
        isStatusMenuTracking = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        isStatusMenuTracking = false
        guard statusMenuNeedsRebuild else { return }
        statusMenuNeedsRebuild = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStatusMenuTracking else { return }
            self.rebuildStatusMenu()
        }
    }

    private func rebuildOrDeferMenu() {
        guard statusItem != nil else { return }
        if isStatusMenuTracking {
            statusMenuNeedsRebuild = true
        } else {
            rebuildStatusMenu()
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

        if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = true
            codexIconImage = icon
            menuBarIconView.setSourceImage(icon)
        }
        if let iconURL = Bundle.main.url(forResource: "Claude", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = true
            claudeIconImage = icon
            if let thinkingURL = Bundle.main.url(
                forResource: "ClaudeThinking",
                withExtension: "svg"
            ) {
                claudeThinkingAnimator = ClaudeThinkingAnimator(
                    imageView: menuBarIconView,
                    staticImage: icon,
                    animatedSVGURL: thinkingURL
                )
            }
        }
        menuBarIconView.onSourceImageChanged = { [weak self] image in
            guard let self else { return }
            self.invalidateBitmapContentCache()
            self.layoutStatusItem(for: self.snapshot)
            self.actions.iconChanged(image)
        }
        menuBarIconView.onAnimationFrameIndexChanged = { [weak self] frameIndex in
            guard let self,
                  let frame = self.menuBarIconView.animationFrame(at: frameIndex) else {
                return
            }
            if self.usesBitmapContent, self.activeClient == .codex {
                self.applyStableCodexAnimationFrame(frameIndex)
                // Dashboard preview animation is a separate consumer. It
                // receives the icon-only frame without mutating the detached
                // real status-item image view.
                self.actions.frameImageChanged(frame)
            } else {
                // Traditional rendering keeps the original image-view path;
                // Claude's animator also enters this path directly.
                self.menuBarIconView.displayImage(frame)
            }
        }
        menuBarIconView.onFrameImageChanged = { [weak self] image in
            guard let self else { return }
            if self.usesBitmapContent {
                if self.activeClient != .codex {
                    // Claude keeps its independent nine-frame animator and
                    // existing bitmap composition behavior for now.
                    self.composeMenuBarContentBitmap(iconImage: image)
                }
            }
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
        configureMenuBarContentPresentation()
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
                "status item presentation; visible=\(statusItem.isVisible); window_visible=\(statusWindow?.isVisible ?? false); window_occlusion_visible=\(statusWindow?.occlusionState.contains(.visible) ?? false); window_occlusion_raw=\(statusWindow?.occlusionState.rawValue ?? 0); button_window=\(statusWindow != nil); button_hidden=\(button.isHidden); image=\(button.image != nil); title=\(button.title); attributed_title=\(button.attributedTitle.string); frame=\(DashboardLogging.rect(button.frame)); window_frame=\(windowFrame); screen_frame=\(screenFrame)",
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
        configureStatusItem()
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
            NSWindow.didChangeBackingPropertiesNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ]
        statusItemWindowObservers = notifications.map { notificationName in
            NotificationCenter.default.addObserver(
                forName: notificationName,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.statusItem != nil else { return }
                self.beginMenuBarVisibilityTransitionWatcher()
                self.scheduleOverlaySynchronization()
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

    /// Returns the current geometry evidence that the native item is attached
    /// to a visible menu-bar band. This is deliberately derived from the live
    /// button/window rather than from the delayed visibility state machine, so
    /// a menu-bar auto-hide transition can recover without waiting for its
    /// confirmation retry.
    private func isStatusItemGeometryAttached(
        button: NSStatusBarButton,
        window: NSWindow
    ) -> Bool {
        guard !button.isHidden,
              window.isVisible,
              let screen = window.screen else {
            return false
        }
        let itemFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let windowFrame = window.frame
        let screenFrame = screen.frame
        guard itemFrame.width > 0,
              itemFrame.height > 0,
              windowFrame.width > 0,
              windowFrame.height > 0,
              screenFrame.width > 0,
              screenFrame.height > 0,
              itemFrame.minX.isFinite,
              itemFrame.maxX.isFinite,
              itemFrame.minY.isFinite,
              itemFrame.maxY.isFinite,
              windowFrame.minX.isFinite,
              windowFrame.maxX.isFinite,
              windowFrame.minY.isFinite,
              windowFrame.maxY.isFinite,
              screenFrame.minX.isFinite,
              screenFrame.maxX.isFinite,
              screenFrame.minY.isFinite,
              screenFrame.maxY.isFinite else {
            return false
        }
        return itemFrame.minX >= screenFrame.minX
            && itemFrame.maxX <= screenFrame.maxX
            && windowFrame.maxY >= screenFrame.maxY - 4
            && windowFrame.minY >= screenFrame.maxY - 48
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
            synchronizeMenuBarAnimationOverlay()
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
            synchronizeMenuBarAnimationOverlay()
            publishStatusItemVisibility()
            return
        }

        guard let button = item.button else {
            statusItemVisibilityStateMachine.reset()
            synchronizeMenuBarAnimationOverlay()
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
        synchronizeMenuBarAnimationOverlay()
        let attached = window.map {
            isStatusItemGeometryAttached(button: button, window: $0)
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
        removeStatusItemWindowObservation()
        NSStatusBar.system.removeStatusItem(item)
        let replacement = NSStatusBar.system.statusItem(withLength: desiredLength)
        statusItem = replacement
        replacement.menu = statusMenu
        configureStatusItem()
        scheduleStatusItemAttachmentCheck(reason: "re-registered-\(statusItemReanchorAttempts)-\(reason)")
    }

    private func updateActivityIcon() {
        switch activeClient {
        case .codex:
            claudeThinkingAnimator?.stop()
            let shouldAnimate = MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: isCodexTaskRunning,
                preferenceEnabled: animationEnabled,
                reduceMotionEnabled: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            let shouldUseOverlay = shouldAnimate
                && animationRenderingMode == .overlayCoreAnimation
                && usesBitmapContent
                && settings.showIcon
                && codexIconImage != nil

            if shouldUseOverlay {
                if !isOverlayCodexAnimationActive {
                    setOverlayCodexAnimationActive(true, rebuild: false)
                    menuBarIconView.stopRotating()
                    invalidateBitmapContentCache()
                    layoutStatusItem(for: snapshot)
                }
                menuBarIconView.stopRotating()
                // The centralized synchronizer owns overlay start, geometry,
                // appearance and visibility application. Keeping this branch
                // request-only prevents duplicate CA installation on rapid
                // activity samples.
                _ = overlayAnimationController()
                synchronizeMenuBarAnimationOverlay()
                return
            }

            setOverlayCodexAnimationActive(false)
            // While the rotation is feeding frames, re-assigning the static
            // source would clobber the current frame for one tick and dirty
            // the view; the rotation frames already derive from this source.
            if !menuBarIconView.isRotating, let codexIconImage {
                menuBarIconView.setSourceImage(codexIconImage)
            }
            if shouldAnimate {
                if usesBitmapContent {
                    ensureCodexAnimationFrameCache()
                    if !menuBarIconView.isRotating {
                        guard installStableCodexAnimationImage(at: 0) else {
                            menuBarIconView.stopRotating()
                            restoreCodexStaticBitmap()
                            return
                        }
                    } else if !ensureStableCodexAnimationFrameBuffer() {
                        menuBarIconView.stopRotating()
                        restoreCodexStaticBitmap()
                        return
                    }
                }
                menuBarIconView.startRotating()
            } else {
                menuBarIconView.stopRotating()
                if usesBitmapContent {
                    restoreCodexStaticBitmap()
                }
            }
        case .claude:
            setOverlayCodexAnimationActive(false)
            menuBarIconView.stopRotating()
            if claudeThinkingAnimator?.isAnimating != true, let claudeIconImage {
                menuBarIconView.setSourceImage(claudeIconImage)
            }
            if MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: isClaudeTaskRunning,
                preferenceEnabled: animationEnabled,
                reduceMotionEnabled: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ) {
                claudeThinkingAnimator?.start()
            } else {
                claudeThinkingAnimator?.stop()
            }
        }
    }

    private func setOverlayCodexAnimationActive(
        _ active: Bool,
        rebuild: Bool = true
    ) {
        guard isOverlayCodexAnimationActive != active else { return }
        isOverlayCodexAnimationActive = active
        actions.overlayAnimationStateChanged(active)
        if !active {
            stopMenuBarVisibilityTransitionWatcher()
        }
        if rebuild, usesBitmapContent {
            invalidateBitmapContentCache()
            layoutStatusItem(for: snapshot)
        }
        // The synchronizer is the only overlay lifecycle authority. In the
        // no-rebuild path there is no layout boundary that will reach it, so
        // apply the new desired state here without directly stopping or
        // showing the window.
        synchronizeMenuBarAnimationOverlay()
    }

    private func overlayAnimationController() -> MenuBarAnimationOverlayController {
        if let menuBarAnimationOverlay {
            return menuBarAnimationOverlay
        }
        let overlay = MenuBarAnimationOverlayController()
        menuBarAnimationOverlay = overlay
        return overlay
    }

    private var shouldUseOverlayCodexAnimation: Bool {
        animationRenderingMode == .overlayCoreAnimation
            && usesBitmapContent
            && activeClient == .codex
            && settings.showIcon
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && codexIconImage != nil
            && isOverlayCodexAnimationActive
    }

    /// Uses the already measured bitmap placement and the real status-button
    /// window to convert the visible icon pixels into screen coordinates.
    /// There is no independent overlay layout constant to drift from the
    /// native menu-bar content.
    private func menuBarAnimationOverlayScreenFrame() -> NSRect? {
        guard shouldUseOverlayCodexAnimation,
              let button = statusItem?.button,
              let window = button.window,
              let placement = menuBarBitmapImagePlacement,
              let iconDrawRect = cachedMenuBarIconDrawRect else {
            return nil
        }
        let iconRectInButton = placement.canonicalRect(forImageRect: iconDrawRect)
        return window.convertToScreen(button.convert(iconRectInButton, to: nil))
    }

    private func synchronizeMenuBarAnimationOverlay() {
        guard !isDeferringOverlaySynchronization else { return }
        guard let overlay = menuBarAnimationOverlay else {
            return
        }

        let animationRequested = shouldUseOverlayCodexAnimation
        if !animationRequested {
            stopMenuBarVisibilityTransitionWatcher()
        }
        guard let statusItem,
              let button = statusItem.button,
              let window = button.window else {
            overlay.synchronize(
                image: codexIconImage,
                // A status-item replacement temporarily has no button/window.
                // Keep the requested compositor animation installed, but hide
                // the overlay until fresh geometry is available.
                animationRequested: animationRequested,
                screenFrame: nil,
                appearance: nil,
                backingScale: nil,
                shouldShow: false
            )
            return
        }

        let menuBarActuallyVisible = NSMenu.menuBarVisible()
        let statusItemGeometryAttached = isStatusItemGeometryAttached(
            button: button,
            window: window
        )
        let restoringFromMenuBarSpace = menuBarActuallyVisible
            && statusItemVisibility.isHiddenByMenuBarSpace
            && statusItemGeometryAttached
        let statusItemVisibilityConfirmed = statusItemVisibility == .visible
            || restoringFromMenuBarSpace
        let screenFrame = animationRequested
            ? menuBarAnimationOverlayScreenFrame()
            : nil
        let validGeometry = screenFrame.map {
            $0.width > 0
                && $0.height > 0
                && $0.minX.isFinite
                && $0.minY.isFinite
                && $0.maxX.isFinite
                && $0.maxY.isFinite
        } ?? false
        let shouldShow = MenuBarAnimationOverlayVisibilityPolicy.shouldShow(
            animationRequested: animationRequested,
            // `.unknown` is deliberately not treated as visible. During
            // status-item creation/replacement AppKit can expose a button
            // before its window and space attachment are confirmed; the
            // overlay must remain hidden until that evidence is authoritative.
            // A known hidden-by-space state may be cleared only when the
            // current public menu-bar signal and live geometry both confirm
            // that the item has returned.
            statusItemVisible: statusItem.isVisible
                && !button.isHidden
                && statusItemVisibilityConfirmed,
            hiddenByMenuBarSpace: statusItemVisibility.isHiddenByMenuBarSpace
                && !restoringFromMenuBarSpace,
            hiddenByRuntimePolicy: statusItemVisibility.isHiddenByRuntimePolicy,
            statusWindowVisible: window.isVisible,
            statusWindowOcclusionVisible: window.occlusionState.contains(.visible),
            validGeometry: validGeometry,
            reduceMotionEnabled: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            menuBarActuallyVisible: menuBarActuallyVisible,
            lifecycleSuspended: overlayLifecycleSuspended
        )
        overlay.synchronize(
            image: codexIconImage,
            animationRequested: animationRequested,
            screenFrame: shouldShow ? screenFrame : nil,
            appearance: button.effectiveAppearance,
            backingScale: window.backingScaleFactor,
            shouldShow: shouldShow
        )
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
        synchronizeMenuBarAnimationOverlay()
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

    /// Switches the live content tree between the classic button hierarchy and
    /// the offscreen bitmap root. The same method is used at initial setup and
    /// when the Advanced settings switch changes, so both paths clean up the
    /// previous attachment before laying out the new coordinate space.
    private func configureMenuBarContentPresentation() {
        guard let button = statusItem?.button else { return }
        menuBarContentStack.removeFromSuperview()
        invalidateBitmapContentCache()
        button.image = Self.placeholderButtonImage

        if usesBitmapContent {
            bitmapRenderContainer.frame = NSRect(origin: .zero, size: button.bounds.size)
            bitmapRenderContainer.addSubview(menuBarContentStack)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        } else {
            button.addSubview(menuBarContentStack)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }
    }

    private func logMenuBarIconFrames(
        snapshot: Snapshot,
        button: NSStatusBarButton,
        hasSecondary: Bool,
        iconYOffset: CGFloat
    ) {
        guard !usesBitmapContent else { return }
        guard settings.showIcon else { return }
        let kind: String
        switch snapshot.kind {
        case .placeholder: kind = "placeholder"
        case .official: kind = "official"
        case .balance: kind = "balance"
        case .openCodex: kind = "open-codex"
        case .error: kind = "error"
        }
        let stackInButton = menuBarContentStack.convert(menuBarContentStack.bounds, to: button)
        let slotInButton = menuBarIconSlot.convert(menuBarIconSlot.bounds, to: button)
        let iconInButton = menuBarIconView.convert(menuBarIconView.bounds, to: button)
        let iconInWindow = menuBarIconView.convert(menuBarIconView.bounds, to: nil)
        let iconInScreen = button.window?.convertToScreen(iconInWindow)
        let diagnostic = "menu bar icon frames; kind=\(kind); show_amount=\(settings.showAmount); has_secondary=\(hasSecondary); offset=\(DashboardLogging.number(iconYOffset)); flipped=button:\(button.isFlipped),stack:\(menuBarContentStack.isFlipped),slot:\(menuBarIconSlot.isFlipped),icon:\(menuBarIconView.isFlipped); button=\(DashboardLogging.rect(button.bounds)); stack_local=\(DashboardLogging.rect(menuBarContentStack.frame)); stack_button=\(DashboardLogging.rect(stackInButton)); slot_local=\(DashboardLogging.rect(menuBarIconSlot.frame)); slot_button=\(DashboardLogging.rect(slotInButton)); icon_local=\(DashboardLogging.rect(menuBarIconView.frame)); icon_button=\(DashboardLogging.rect(iconInButton)); icon_window=\(DashboardLogging.rect(iconInWindow)); icon_screen=\(iconInScreen.map { DashboardLogging.rect($0) } ?? "none"); center_button=\(DashboardLogging.number(iconInButton.midY)); center_window=\(DashboardLogging.number(iconInWindow.midY))"
        guard diagnostic != lastMenuBarIconFrameDiagnostic else { return }
        lastMenuBarIconFrameDiagnostic = diagnostic
        SwitchLog.write(diagnostic, level: .debug, category: "ui.geometry")
    }

    private func layoutStatusItem(for snapshot: Snapshot) {
        guard let statusItem, let button = statusItem.button else { return }
        applyMenuBarFonts()
        let effectiveSnapshot = menuBarSnapshot(for: snapshot)
        let reservedSecondary = settings.showAmount && effectiveSnapshot.kind == .official
            ? effectiveSnapshot.menuBarSecondary(
                displayMode: settings.quotaResetDisplayMode,
                lunaReserveResetTimeMode: settings.lunaReserveResetTimeMode
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
            isBalance: effectiveSnapshot.kind == .balance
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
                widthAdjustment: settings.widthAdjustment
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
                isBalance: true
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
        let requestedButtonSize = NSSize(
            width: max(0, statusItem.length),
            height: buttonHeight
        )
        applyMenuBarContentFrames(
            button: button,
            // AppKit can update the status button's bounds one run-loop turn
            // after `statusItem.length` changes. Pass the requested footprint
            // immediately so toggling the icon cannot leave the amount
            // centered against the previous icon-inclusive width.
            buttonSize: requestedButtonSize,
            geometry: geometry,
            iconViewYOffset: iconYOffset,
            effectiveSnapshot: effectiveSnapshot,
            officialTextYOffset: officialTextYOffset
        )
        if usesBitmapContent {
            // Frames are final here; snapshot the offscreen tree into the
            // button image so the real button carries no live view hierarchy.
            refreshMenuBarContentBitmap(buttonSize: requestedButtonSize)
        }
        logMenuBarIconFrames(
            snapshot: effectiveSnapshot,
            button: button,
            hasSecondary: hasSecondary,
            iconYOffset: iconYOffset
        )
        if button.toolTip != effectiveSnapshot.menuBarToolTip {
            button.toolTip = effectiveSnapshot.menuBarToolTip
        }
        button.isHidden = false
        button.isEnabled = true
        applyMenuBarIconDisplayPolicy()
        synchronizeMenuBarAnimationOverlay()
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
                    isBalance: effectiveSnapshot.kind == .balance
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
        case .placeholder, .openCodex, .error:
            return false
        }
    }

    /// The view whose coordinate space the content frames live in: the status
    /// button in the classic path, the offscreen render container in bitmap
    /// mode. Both share a (0,0)-origin bounds of the same size.
    private var menuBarContentCoordinateSpace: NSView? {
        if usesBitmapContent {
            return bitmapRenderContainer.bounds.width > 0 ? bitmapRenderContainer : nil
        }
        return statusItem?.button
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
        cachedMenuBarTextBitmap = nil
        cachedStaticMenuBarContentBitmap = nil
        cachedMenuBarContentVisualSignature = nil
        menuBarBitmapImagePlacement = nil
        cachedMenuBarIconDrawRect = nil
        codexAnimationFrameCache.invalidate()
        stableCodexAnimationFrameBuffer.invalidate()
        if setPlaceholder {
            statusItem?.button?.image = Self.placeholderButtonImage
        }
    }

    private var shouldPrepareCodexAnimationFrames: Bool {
        usesBitmapContent
            && animationRenderingMode == .nativeCachedFrames
            && activeClient == .codex
            && isCodexTaskRunning
            && animationEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !menuBarIconSlot.isHidden
            && !menuBarIconView.isHidden
    }

    /// Rebuilds the finite Codex cache only after a real content/layout
    /// invalidation or when an animation is started without a prepared cache.
    /// A timer callback never calls this method.
    private func ensureCodexAnimationFrameCache() {
        guard shouldPrepareCodexAnimationFrames,
              let signature = cachedMenuBarContentVisualSignature,
              let textBitmap = cachedMenuBarTextBitmap,
              let iconDrawRect = cachedMenuBarIconDrawRect,
              let placement = menuBarBitmapImagePlacement,
              let codexIconImage,
              let sourceImage = menuBarIconView.sourceImageForRendering,
              sourceImage === codexIconImage else {
            return
        }

        let sourceFrames = menuBarIconView.animationFrames
        guard !sourceFrames.isEmpty else { return }
        let didPrepare = codexAnimationFrameCache.rebuildIfNeeded(
            signature: signature,
            sourceFrames: sourceFrames
        ) { frame in
            Self.makeCompleteMenuBarBitmap(
                textBitmap: textBitmap,
                iconImage: frame,
                iconDrawRect: iconDrawRect,
                canvasSize: placement.canvasSize
            )
        }
        guard didPrepare else {
            invalidateBitmapContentCache(setPlaceholder: true)
            return
        }
    }

    private var shouldUseStableCodexAnimation: Bool {
        shouldPrepareCodexAnimationFrames && menuBarIconView.isRotating
    }

    /// Materializes the existing complete-frame cache into one mutable image
    /// representation. This may draw each frame, but only during a bounded
    /// visual-cache rebuild; no timer callback reaches this method.
    @discardableResult
    private func ensureStableCodexAnimationFrameBuffer() -> Bool {
        guard shouldPrepareCodexAnimationFrames,
              let signature = cachedMenuBarContentVisualSignature else {
            return false
        }
        let sourceFrames = menuBarIconView.animationFrames
        guard !sourceFrames.isEmpty,
              codexAnimationFrameCache.images.count == sourceFrames.count else {
            return false
        }
        return stableCodexAnimationFrameBuffer.rebuildIfNeeded(
            signature: signature,
            sourceFrames: sourceFrames,
            completeFrames: codexAnimationFrameCache.images
        )
    }

    /// Installs the stable image at an animation boundary (start or a real
    /// visual invalidation). Once installed, frame callbacks must use
    /// applyStableCodexAnimationFrame(_:) so they never assign button.image.
    @discardableResult
    private func installStableCodexAnimationImage(at frameIndex: Int) -> Bool {
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
    /// only Codex bitmap work performed by the 30 fps timer path.
    private func applyStableCodexAnimationFrame(_ frameIndex: Int) {
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

    private func restoreCodexStaticBitmap() {
        guard let button = statusItem?.button,
              let staticImage = cachedStaticMenuBarContentBitmap else {
            return
        }
        if button.image !== staticImage {
            button.image = staticImage
        }
    }

    private func makeMenuBarBitmapAnimationVisualSignature(
        button: NSStatusBarButton,
        placement: MenuBarBitmapImagePlacement,
        scale: CGFloat,
        buttonBounds: NSRect? = nil
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
        case .openCodex: snapshotKind = "openCodex"
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
            buttonBounds: buttonBounds ?? button.bounds,
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
            iconViewImageAlignment: Int(menuBarIconView.imageAlignment.rawValue),
            usesBitmapContent: usesBitmapContent
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
    private func refreshMenuBarContentBitmap(buttonSize: NSSize? = nil) {
        guard usesBitmapContent,
              let button = statusItem?.button,
              button.bounds.height > 0 else {
            return
        }

        let effectiveButtonSize = buttonSize ?? button.bounds.size
        guard effectiveButtonSize.width > 0, effectiveButtonSize.height > 0 else {
            return
        }
        bitmapRenderContainer.frame = NSRect(origin: .zero, size: effectiveButtonSize)
        let effectiveButtonBounds = NSRect(
            origin: button.bounds.origin,
            size: effectiveButtonSize
        )
        let scale = button.window?.backingScaleFactor ?? 2
        let placement = MenuBarBitmapImageLayout.placement(
            for: button,
            canonicalBounds: bitmapRenderContainer.bounds,
            buttonBounds: effectiveButtonBounds
        )
        let signature = makeMenuBarBitmapAnimationVisualSignature(
            button: button,
            placement: placement,
            scale: scale,
            buttonBounds: effectiveButtonBounds
        )

        if signature == cachedMenuBarContentVisualSignature,
           cachedMenuBarTextBitmap != nil,
           cachedStaticMenuBarContentBitmap != nil {
            if shouldPrepareCodexAnimationFrames {
                ensureCodexAnimationFrameCache()
                if shouldUseStableCodexAnimation,
                   stableCodexAnimationFrameBuffer.image == nil {
                    _ = installStableCodexAnimationImage(
                        at: menuBarIconView.currentAnimationFrameIndex
                    )
                }
            }
            return
        }

        let displayedImage = menuBarIconView.image
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
        if !shouldUseOverlayCodexAnimation,
           let sourceImage,
           let iconDrawRect {
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

        if shouldPrepareCodexAnimationFrames {
            ensureCodexAnimationFrameCache()
        } else {
            codexAnimationFrameCache.invalidate()
        }

        if shouldUseStableCodexAnimation {
            if !installStableCodexAnimationImage(
                at: menuBarIconView.currentAnimationFrameIndex
            ) {
                menuBarIconView.stopRotating()
                button.image = staticImage
            }
        } else if activeClient == .claude,
                  claudeThinkingAnimator?.isAnimating == true,
                  let displayedImage,
                  let iconDrawRect {
            // Preserve Claude's independent animation while sharing the
            // already-rendered text base. This is a refresh-time composition,
            // never the Codex steady-state timer path.
            button.image = Self.makeCompleteMenuBarBitmap(
                textBitmap: textBitmap,
                iconImage: displayedImage,
                iconDrawRect: iconDrawRect,
                canvasSize: placement.canvasSize
            ) ?? staticImage
        } else {
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
            iconImage.draw(
                in: iconDrawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
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

    /// Composites a Claude animation frame over the cached text bitmap. The
    /// Codex callback never reaches this method; its complete frame pixels are
    /// copied into the stable bitmap backing instead.
    private func composeMenuBarContentBitmap(iconImage: NSImage?) {
        guard usesBitmapContent,
              let button = statusItem?.button,
              let textBitmap = cachedMenuBarTextBitmap else {
            return
        }
        let bounds = bitmapRenderContainer.bounds
        let composed = NSImage(size: bounds.size)
        composed.isTemplate = true
        composed.lockFocusFlipped(true)
        textBitmap.draw(
            in: NSRect(origin: .zero, size: bounds.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        if let iconImage, !menuBarIconSlot.isHidden {
            // menuBarIconView.frame is in its superview's (iconSlot) space;
            // resolve the view's actual position inside the render container
            // before drawing, and center-fit like NSImageView's
            // scaleProportionallyDown so the rotating frame lands exactly
            // where the static render placed the icon.
            let viewBoundsInContainer = menuBarIconView.convert(
                menuBarIconView.bounds,
                to: bitmapRenderContainer
            )
            let placement = menuBarBitmapImagePlacement
                ?? MenuBarBitmapImagePlacement(
                    canonicalBounds: bounds,
                    imageDestinationRect: bounds
                )
            let imageViewBounds = placement.imageRect(forCanonicalRect: viewBoundsInContainer)
            let iconSize = iconImage.size
            if iconSize.width > 0, iconSize.height > 0,
               imageViewBounds.width > 0, imageViewBounds.height > 0 {
                let scaleFactor = min(
                    imageViewBounds.width / iconSize.width,
                    imageViewBounds.height / iconSize.height,
                    1
                )
                let fittedSize = NSSize(
                    width: iconSize.width * scaleFactor,
                    height: iconSize.height * scaleFactor
                )
                iconImage.draw(in: NSRect(
                    x: imageViewBounds.midX - fittedSize.width / 2,
                    y: imageViewBounds.midY - fittedSize.height / 2,
                    width: fittedSize.width,
                    height: fittedSize.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
                )
            }
        }
        composed.unlockFocus()
        button.image = composed
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
        let effective = OpenCodexCardPresentation.menuBarSnapshot(
            for: snapshot,
            cards: menuInput.openCodexCards
        )
        let resolved = effective.menuBarSnapshot(
            preferredQuotaWindow: settings.quotaWindowPreference,
            automaticallyUseLunaReserve: settings.autoSwitchLunaReserve
        )
        guard snapshot.kind == .openCodex else { return resolved }
        let match = OpenCodexCardPresentation.menuBarCardMatch(from: menuInput.openCodexCards)
        let cardSummary = menuInput.openCodexCards.enumerated()
            .map { index, card in
                "\(index){selector=\(card.selector),isCurrent=\(card.isCurrent),data=\(card.data.diagnosticName)}"
            }
            .joined(separator: ";")
        let selection = match.card?.selector ?? "none"
        let signature = [
            snapshot.unit ?? "none",
            cardSummary,
            match.diagnosticReason,
            snapshotKindDiagnosticName(resolved.kind),
            resolved.menuBarPrimary,
            resolved.menuBarSecondary
        ].joined(separator: "|")
        SwitchLog.write(
            "OpenCodex menu bar resolution; runtime_selector=\(snapshot.unit ?? "none"); cards=[\(cardSummary)]; match=\(match.diagnosticReason); selected_selector=\(selection); effective_kind=\(snapshotKindDiagnosticName(resolved.kind)); primary=\(resolved.menuBarPrimary); secondary=\(resolved.menuBarSecondary)",
            level: .debug,
            category: "open-codex.menu-bar",
            throttleKey: "open-codex-menu-resolution-\(signature)",
            minimumInterval: 1
        )
        return resolved
    }

    private func snapshotKindDiagnosticName(_ kind: Snapshot.Kind) -> String {
        switch kind {
        case .placeholder: return "placeholder"
        case .official: return "official"
        case .balance: return "balance"
        case .openCodex: return "openCodex"
        case .error: return "error"
        }
    }

    @objc private func manualRefresh() {
        actions.manualRefresh()
        if settings.keepMenuOpenAfterRefresh {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.statusItem?.button?.performClick(nil)
            }
        }
    }

    @objc private func openDashboard() { actions.openDashboard() }
    @objc private func openChatGPT() { actions.openChatGPT() }
    @objc private func openCCSwitch() { actions.openCCSwitch() }
    @objc private func openOpenCodex() { actions.openOpenCodex() }
    @objc private func quit() { actions.quit() }

    @objc private func switchProvider(_ sender: NSMenuItem) {
        guard let providerID = sender.representedObject as? String else { return }
        actions.switchProvider(providerID)
    }

    @objc private func switchOpenCodexPreference(_ sender: NSMenuItem) {
        guard let preference = sender.representedObject as? OpenCodexPreference else { return }
        actions.switchOpenCodexPreference(preference)
    }

    @objc private func openStatusLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        actions.openStatusLink(url)
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

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()
        if snapshot.kind == .openCodex {
            if menuInput.openCodexCards.isEmpty {
                statusMenu.addItem(makeOpenCodexEmptyMenuItem())
            } else {
                for (index, card) in menuInput.openCodexCards.enumerated() {
                    statusMenu.addItem(makeOpenCodexCardMenuItem(card))
                    if index < menuInput.openCodexCards.count - 1 {
                        statusMenu.addItem(.separator())
                    }
                }
            }
        } else {
            statusMenu.addItem(makeOverviewMenuItem(for: snapshot))
        }
        statusMenu.addItem(.separator())
        if menuInput.showQuickSwitchMenu {
            statusMenu.addItem(makeQuickSwitchMenuItem())
        }
        statusMenu.addItem(
            withTitle: tr(.keyStatusItemControllerRefreshNow),
            action: #selector(manualRefresh),
            keyEquivalent: "r"
        ).target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(makeOpenDashboardMenuItem())
        if menuInput.showOpenChatGPTMenu {
            statusMenu.addItem(
                withTitle: tr(.keyStatusItemControllerOpenChatgpt),
                action: #selector(openChatGPT),
                keyEquivalent: ""
            ).target = self
        }
        if menuInput.showOpenCCSwitchMenu {
            statusMenu.addItem(
                withTitle: tr(.keyStatusItemControllerOpenCcSwitch),
                action: #selector(openCCSwitch),
                keyEquivalent: ""
            ).target = self
        }
        if menuInput.showOpenCodexMenu {
            statusMenu.addItem(
                withTitle: tr(.keyStatusItemControllerOpenOpencodex),
                action: #selector(openOpenCodex),
                keyEquivalent: ""
            ).target = self
        }
        if menuInput.showStatusMenu {
            statusMenu.addItem(makeStatusLinksMenuItem())
        }
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: tr(.keyStatusItemControllerQuitBalancebar),
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self
        let menuTitles = statusMenu.items.map { item in
            item.title.isEmpty ? "<custom>" : item.title
        }.joined(separator: "|")
        let statusWindow = statusItem?.button?.window
        let windowFrame = statusWindow.map { DashboardLogging.rect($0.frame) } ?? "none"
        let screenFrame = statusWindow?.screen.map { DashboardLogging.rect($0.frame) } ?? "none"
        let buttonTitle = statusItem?.button?.title ?? ""
        SwitchLog.write(
            "status menu rendered; item_count=\(statusMenu.items.count); items=\(menuTitles); status_visible=\(isVisible); button_window=\(statusWindow != nil); window_visible=\(statusWindow?.isVisible ?? false); window_occlusion_visible=\(statusWindow?.occlusionState.contains(.visible) ?? false); window_occlusion_raw=\(statusWindow?.occlusionState.rawValue ?? 0); image=\(statusItem?.button?.image != nil); title=\(buttonTitle); window_frame=\(windowFrame); screen_frame=\(screenFrame)",
            level: .debug,
            category: "ui.status-menu",
            throttleKey: "status-menu-render",
            minimumInterval: 1
        )
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
        let submenu = NSMenu(title: tr(.keyStatusItemControllerQuickSwitch2))
        submenu.minimumWidth = 210
        let choiceSummary = menuInput.choices.map {
            "id=\($0.id),name=\($0.name),current=\($0.isCurrent)"
        }.joined(separator: "|")
        let menuChoices = QuickSwitchMenuModel.entries(from: menuInput.choices)
        if menuChoices.isEmpty {
            let empty = NSMenuItem(title: tr(.keyStatusItemControllerNoCodexProviderFound), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for choice in menuChoices {
                let item = NSMenuItem(
                    title: "",
                    action: #selector(switchProvider(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = choice.id
                item.state = choice.isCurrent ? .on : .off
                applyQuickSwitchTitle(to: item, providerID: choice.id, providerName: choice.name)
                submenu.addItem(item)
            }
        }
        SwitchLog.write(
            "quick-switch menu built; app_type=\(menuInput.activeClient.appType); choice_count=\(menuInput.choices.count); submenu_item_count=\(submenu.items.count); choices=\(choiceSummary.isEmpty ? "<empty>" : choiceSummary); empty_state=\(menuInput.choices.isEmpty)",
            level: .debug,
            category: "provider.menu",
            throttleKey: "quick-switch-menu-\(menuInput.activeClient.appType)",
            minimumInterval: 1
        )
        parent.submenu = submenu
        return parent
    }

    private func applyQuickSwitchTitle(to item: NSMenuItem, providerID: String, providerName: String) {
        let title = "\(providerName)\t\(menuInput.quickSwitchSummaries[providerID] ?? "…")"
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 170)]
        paragraph.defaultTabInterval = 170
        item.title = title
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .paragraphStyle: paragraph
            ]
        )
    }

    private func makeOverviewMenuItem(for snapshot: Snapshot) -> NSMenuItem {
        if snapshot.kind == .error {
            return makeOverviewErrorMenuItem(for: snapshot)
        }
        let item = NSMenuItem()
        item.isEnabled = snapshot.kind == .balance && snapshot.websiteURL != nil
        let isBalance = snapshot.kind == .balance
        let quotaPresentation = snapshot.officialQuotaMenuPresentation(
            lunaReserveDisplayMode: menuInput.lunaReserveDisplayMode,
            hideExhaustedQuota: menuInput.lunaReserveHideExhaustedQuota
        )
        let officialQuotaWindows = quotaPresentation.windows
        let lunaReserve = quotaPresentation.lunaReserve
        let subscription = menuInput.openAIAccount?.subscription
        let subscriptionTextWidth = subscription.map {
            AccountMarqueeView.textWidth(of: $0.text, font: Self.subscriptionFont)
        }
        let layout = OpenCodexCardLayout.frames(
            for: isBalance ? .balance : .quota,
            linkPrefixWidth: AppLanguage.resolved.overviewLinkPrefixWidth,
            includesAccount: snapshot.kind == .official && menuInput.openAIAccount != nil,
            includesSubscription: snapshot.kind == .official && subscription != nil,
            subscriptionTextWidth: snapshot.kind == .official ? subscriptionTextWidth : nil,
            officialQuotaWindows: officialQuotaWindows,
            includesLunaReserve: snapshot.kind == .official && lunaReserve != nil,
            includesLunaReserveProgress: snapshot.kind == .official && lunaReserve?.remaining != nil,
            lunaReserveInsertionIndex: quotaPresentation.lunaReserveInsertionIndex
        )
        let view = MenuHoverLinkHostView(frame: NSRect(origin: .zero, size: layout.cardSize))
        let provider = makeOverviewLabel(snapshot.overviewProvider, font: .systemFont(ofSize: 15, weight: .semibold))
        provider.frame = layout.title

        if snapshot.kind == .official || snapshot.kind == .balance {
            let timeText = refreshDate.map { Self.timeFormatter.string(from: $0) } ?? "--:--:--"
            let refreshTime = makeOverviewLabel(timeText, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
            refreshTime.textColor = .secondaryLabelColor
            refreshTime.alignment = .right
            refreshTime.frame = layout.refreshTime
            view.addSubview(refreshTime)
        }
        if let account = menuInput.openAIAccount, let accountFrame = layout.account {
            let accountLabel = makeAccountLabel(
                account,
                frame: accountFrame
            )
            view.addSubview(accountLabel)
        }
        if let subscription,
           let subscriptionFrame = layout.subscription {
            view.addSubview(makeSubscriptionLabel(subscription.text, frame: subscriptionFrame))
        }

        if !layout.quotaRows.isEmpty || layout.lunaReserveRow != nil {
            for (window, row) in zip(officialQuotaWindows, layout.quotaRows) {
                let progress = QuotaProgressView(percentage: window.remaining, colorConfiguration: settings.quotaProgressColorConfiguration)
                progress.frame = row.progress
                view.addSubview(progress)

                let amount = makeOverviewLabel(
                    "\(Int(window.remaining))%",
                    font: .monospacedDigitSystemFont(
                        ofSize: OpenCodexCardLayout.quotaAmountPointSize,
                        weight: .semibold
                    )
                )
                amount.alignment = .right
                amount.frame = row.amount
                view.addSubview(amount)

                let quotaDetail = makeMarqueeOverviewLabel(
                    window.label,
                    font: .systemFont(
                        ofSize: OpenCodexCardLayout.quotaDetailPointSize,
                        weight: .medium
                    ),
                    textColor: .labelColor,
                    frame: overviewMarqueeFrame(row.quotaDetail, avoiding: amount)
                )
                view.addSubview(quotaDetail)

                let resetText = window.resetDisplayText().map {
                    tr(.keySnapshotResetValue, arguments: [String(describing: $0)])
                } ?? tr(.keySnapshotResetValue, arguments: [tr(.keyLocalizationUnknown)])
                let reset = makeMarqueeOverviewLabel(
                    resetText,
                    font: .systemFont(
                        ofSize: OpenCodexCardLayout.quotaResetPointSize,
                        weight: .regular
                    ),
                    textColor: .secondaryLabelColor,
                    frame: overviewMarqueeFrame(row.reset, avoiding: amount)
                )
                view.addSubview(reset)
            }
            if let lunaReserve,
               let row = layout.lunaReserveRow {
                if let remaining = lunaReserve.remaining {
                    let progress = QuotaProgressView(percentage: remaining, colorConfiguration: settings.quotaProgressColorConfiguration)
                    progress.frame = row.progress
                    view.addSubview(progress)
                }

                let amount = makeOverviewLabel(
                    lunaReserve.remaining.map { "\(Int($0))%" } ?? "—",
                    font: .monospacedDigitSystemFont(
                        ofSize: OpenCodexCardLayout.quotaAmountPointSize,
                        weight: .semibold
                    )
                )
                amount.alignment = .right
                amount.frame = row.amount
                view.addSubview(amount)

                let quotaDetail = makeMarqueeOverviewLabel(
                    lunaReserve.menuTitleText,
                    font: .systemFont(
                        ofSize: OpenCodexCardLayout.quotaDetailPointSize,
                        weight: .medium
                    ),
                    textColor: .labelColor,
                    frame: overviewMarqueeFrame(row.quotaDetail, avoiding: amount)
                )
                view.addSubview(quotaDetail)

                let reset = makeMarqueeOverviewLabel(
                    lunaReserve.menuSubtitleText,
                    font: .systemFont(
                        ofSize: OpenCodexCardLayout.quotaResetPointSize,
                        weight: .regular
                    ),
                    textColor: .secondaryLabelColor,
                    frame: overviewMarqueeFrame(row.reset, avoiding: amount)
                )
                view.addSubview(reset)
            }
            view.addSubview(provider)
        } else {
            if let percentage = snapshot.progressPercentage, let progressFrame = layout.progress {
                let progress = QuotaProgressView(percentage: percentage, colorConfiguration: settings.quotaProgressColorConfiguration)
                progress.frame = progressFrame
                view.addSubview(progress)
            }

            let amount = makeOverviewLabel(
                snapshot.overviewLargeAmount,
                font: .monospacedDigitSystemFont(
                    ofSize: OpenCodexCardLayout.quotaAmountPointSize,
                    weight: .semibold
                )
            )
            amount.alignment = .right
            amount.frame = layout.amount
            let quotaDetail = makeMarqueeOverviewLabel(
                snapshot.overviewQuotaDetail,
                font: .systemFont(
                    ofSize: OpenCodexCardLayout.quotaDetailPointSize,
                    weight: .medium
                ),
                textColor: .labelColor,
                frame: overviewMarqueeFrame(layout.quotaDetail, avoiding: amount)
            )
            if isBalance {
                let linkPrefix = makeOverviewLabel(
                    tr(.keyStatusItemControllerOfficialLink),
                    font: .systemFont(ofSize: 12, weight: .regular)
                )
                linkPrefix.textColor = .secondaryLabelColor
                linkPrefix.frame = layout.linkPrefix ?? .zero
                view.addSubview(linkPrefix)
                if snapshot.websiteURL != nil, let linkFrame = layout.link {
                    let link = HoverLinkTextField(text: snapshot.provider)
                    link.frame = linkFrame
                    link.onActivate = { [weak self] in self?.actions.openProviderWebsite() }
                    view.addSubview(link)
                    view.track(link)
                }
            } else {
                let reset = makeMarqueeOverviewLabel(
                    snapshot.overviewReset(refreshDate: refreshDate, formatter: Self.timeFormatter),
                    font: .systemFont(
                        ofSize: OpenCodexCardLayout.quotaResetPointSize,
                        weight: .regular
                    ),
                    textColor: .secondaryLabelColor,
                    frame: overviewMarqueeFrame(layout.reset ?? .zero, avoiding: amount)
                )
                view.addSubview(reset)
            }
            [provider, quotaDetail, amount].forEach(view.addSubview)
        }
        item.view = view
        return item
    }

    private func makeOpenCodexEmptyMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 68))
        let title = makeOverviewLabel(
            tr(.keyStatusItemControllerOpencodex),
            font: .systemFont(ofSize: 15, weight: .semibold)
        )
        title.frame = NSRect(x: 14, y: 38, width: 220, height: 20)
        let status: String
        if let state = menuInput.openCodexState?.managementAvailable, !state {
            status = tr(.keyStatusItemControllerOpencodexManagementApiIsUnavailable)
        } else if menuInput.openCodexState?.preferenceDataAvailable == false {
            status = tr(.keyStatusItemControllerOpencodexFeaturedModelsAreNotAvailableYet)
        } else {
            status = tr(.keyStatusItemControllerNoOpencodexFeaturedModelsAreConfigured)
        }
        let detail = makeOverviewLabel(status, font: .systemFont(ofSize: 12))
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 14, y: 14, width: 312, height: 18)
        [title, detail].forEach(view.addSubview)
        item.view = view
        return item
    }

    private func makeOpenCodexCardMenuItem(_ card: OpenCodexModelCard) -> NSMenuItem {
        let item = NSMenuItem()
        let category = card.data.category
        let layout = OpenCodexCardLayout.frames(
            for: category,
            linkPrefixWidth: AppLanguage.resolved.overviewLinkPrefixWidth
        )
        let view = MenuHoverLinkHostView(frame: NSRect(origin: .zero, size: layout.cardSize))
        let titleText = OpenCodexCardPresentation.identity(for: card)
            + (card.isCurrent ? tr(.keyStatusItemControllerCurrent) : "")
        let provider = makeOverviewLabel(titleText, font: .systemFont(ofSize: 15, weight: .semibold))
        provider.frame = layout.title
        let updatedAt: Date?
        switch card.data {
        case .official(_, _, _, let date), .officialWithWindow(_, let date), .balance(_, _, _, _, let date):
            updatedAt = date
        case .loading, .unavailable:
            updatedAt = nil
        }
        let refreshTime = makeOverviewLabel(
            updatedAt.map { Self.timeFormatter.string(from: $0) } ?? "--:--:--",
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        )
        refreshTime.textColor = .secondaryLabelColor
        refreshTime.alignment = .right
        refreshTime.frame = layout.refreshTime

        let primary: NSTextField
        let detail: NSView
        let secondary: NSView
        var progress: QuotaProgressView?
        var websiteLink: HoverLinkTextField?
        switch card.data {
        case .official, .officialWithWindow:
            let window = card.data.officialWindow!
            let remaining = window.remaining
            let label = window.label
            progress = QuotaProgressView(percentage: remaining, colorConfiguration: settings.quotaProgressColorConfiguration)
            progress?.frame = layout.progress ?? .zero
            primary = makeOverviewLabel(
                "\(Int(remaining))%",
                font: .monospacedDigitSystemFont(
                    ofSize: OpenCodexCardLayout.quotaAmountPointSize,
                    weight: .semibold
                )
            )
            primary.alignment = .right
            primary.frame = layout.amount
            detail = makeMarqueeOverviewLabel(
                label,
                font: .systemFont(
                    ofSize: OpenCodexCardLayout.quotaDetailPointSize,
                    weight: .medium
                ),
                textColor: .labelColor,
                frame: overviewMarqueeFrame(layout.quotaDetail, avoiding: primary)
            )
            secondary = makeMarqueeOverviewLabel(
                window.resetDisplayText().map {
                    tr(.keyStatusItemControllerResetValue, arguments: [String(describing: $0)])
                } ?? tr(.keyStatusItemControllerResetTimeUnavailable),
                font: .systemFont(
                    ofSize: OpenCodexCardLayout.quotaResetPointSize,
                    weight: .regular
                ),
                textColor: .secondaryLabelColor,
                frame: overviewMarqueeFrame(layout.reset ?? .zero, avoiding: primary)
            )
        case .balance(let amount, let unit, let progressPercentage, let websiteURL, _):
            progress = QuotaProgressView(percentage: progressPercentage, colorConfiguration: settings.quotaProgressColorConfiguration)
            progress?.frame = layout.progress ?? .zero
            primary = makeOverviewLabel(Self.formatBalanceSummary(amount, unit: unit), font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold))
            primary.alignment = .right
            primary.frame = layout.amount
            detail = makeMarqueeOverviewLabel(
                tr(.keyStatusItemControllerRemainingBalance),
                font: .systemFont(ofSize: 13, weight: .medium),
                textColor: .labelColor,
                frame: overviewMarqueeFrame(layout.quotaDetail, avoiding: primary)
            )
            let linkPrefix = makeOverviewLabel(
                tr(.keyStatusItemControllerOfficialLink2),
                font: .systemFont(ofSize: 12, weight: .regular)
            )
            linkPrefix.textColor = .secondaryLabelColor
            linkPrefix.frame = layout.linkPrefix ?? .zero
            secondary = linkPrefix
            if let websiteURL, let linkFrame = layout.link {
                let link = HoverLinkTextField(text: card.provider)
                link.frame = linkFrame
                link.onActivate = { NSWorkspace.shared.open(websiteURL) }
                websiteLink = link
            }
        case .loading:
            primary = makeOverviewLabel("—", font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold))
            primary.alignment = .right
            primary.frame = layout.amount
            detail = makeMarqueeOverviewLabel(
                category == .quota ? tr(.keyStatusItemControllerReadingQuota) : tr(.keyStatusItemControllerReadingBalance),
                font: .systemFont(ofSize: 13, weight: .medium),
                textColor: .labelColor,
                frame: overviewMarqueeFrame(layout.quotaDetail, avoiding: primary)
            )
            secondary = makeMarqueeOverviewLabel(
                tr(.keyStatusItemControllerNoLiveDataReceivedYet),
                font: .systemFont(ofSize: 13, weight: .regular),
                textColor: .secondaryLabelColor,
                frame: overviewMarqueeFrame(layout.reset ?? layout.linkPrefix ?? .zero, avoiding: primary)
            )
        case .unavailable(_, let reason):
            primary = makeOverviewLabel("—", font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold))
            primary.alignment = .right
            primary.frame = layout.amount
            detail = makeMarqueeOverviewLabel(
                category.unavailableTitle,
                font: .systemFont(ofSize: 13, weight: .medium),
                textColor: .labelColor,
                frame: overviewMarqueeFrame(layout.quotaDetail, avoiding: primary)
            )
            secondary = makeMarqueeOverviewLabel(
                reason,
                font: .systemFont(ofSize: 12, weight: .regular),
                textColor: .secondaryLabelColor,
                frame: overviewMarqueeFrame(layout.reset ?? layout.linkPrefix ?? .zero, avoiding: primary)
            )
        }
        [provider, refreshTime, primary, detail, secondary].forEach(view.addSubview)
        if let progress { view.addSubview(progress) }
        if let websiteLink {
            view.addSubview(websiteLink)
            view.track(websiteLink)
        }
        let preference = menuInput.openCodexState?.preferences.first { $0.selector == card.selector }
        item.target = self
        item.action = #selector(switchOpenCodexPreference(_:))
        item.representedObject = preference
        item.state = card.isCurrent ? .on : .off
        item.isEnabled = preference != nil
            && menuInput.openCodexState?.managementAvailable == true
            && !menuInput.openCodexSwitchInFlight
        item.view = view
        return item
    }

    private func makeOverviewErrorMenuItem(for snapshot: Snapshot) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let message = snapshot.overviewReset(refreshDate: nil, formatter: Self.timeFormatter)
        let frames = ErrorCardLayout.errorFrames(
            for: message,
            includesAccount: menuInput.openAIAccount != nil,
            includesSubscription: menuInput.openAIAccount?.subscription != nil,
            subscriptionTextWidth: menuInput.openAIAccount?.subscription.map {
                AccountMarqueeView.textWidth(of: $0.text, font: Self.subscriptionFont)
            }
        )
        let view = NSView(frame: NSRect(origin: .zero, size: frames.cardSize))
        let provider = makeOverviewLabel(snapshot.overviewProvider, font: ErrorCardLayout.titleFont)
        provider.frame = frames.title
        view.addSubview(provider)
        if let account = menuInput.openAIAccount, let accountFrame = frames.account {
            let accountLabel = makeAccountLabel(
                account,
                frame: accountFrame
            )
            view.addSubview(accountLabel)
        }
        if let subscription = menuInput.openAIAccount?.subscription,
           let subscriptionFrame = frames.subscription {
            view.addSubview(makeSubscriptionLabel(subscription.text, frame: subscriptionFrame))
        }
        let timeText = refreshDate.map { Self.timeFormatter.string(from: $0) } ?? "--:--:--"
        let refreshTime = ErrorCardLayout.makeRefreshTimeLabel(
            timeText,
            showsCachedBalance: snapshot.hasCachedBalance
        )
        refreshTime.frame = frames.refreshTime
        view.addSubview(refreshTime)
        let quotaDetail = makeOverviewLabel(snapshot.overviewQuotaDetail, font: ErrorCardLayout.quotaFont)
        quotaDetail.frame = frames.quotaDetail
        view.addSubview(quotaDetail)
        let amount = makeOverviewLabel(snapshot.overviewLargeAmount, font: ErrorCardLayout.amountFont)
        amount.alignment = .right
        amount.frame = frames.amount
        view.addSubview(amount)
        let detail = ErrorCardLayout.makeDetailLabel(
            frames.detailText,
            textColor: snapshot.provider.isEmpty ? .secondaryLabelColor : .systemRed
        )
        detail.frame = frames.detail
        view.addSubview(detail)
        item.view = view
        return item
    }

    private func makeOverviewLabel(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeMarqueeOverviewLabel(
        _ text: String,
        font: NSFont,
        textColor: NSColor,
        frame: NSRect
    ) -> AccountMarqueeView {
        AccountMarqueeView(
            text: text,
            font: font,
            textColor: textColor,
            frame: frame
        )
    }

    private func overviewMarqueeFrame(
        _ baseFrame: NSRect,
        avoiding amountLabel: NSTextField
    ) -> NSRect {
        guard baseFrame.width > 0 else { return baseFrame }

        // The amount label is right-aligned. Its frame reserves the full
        // primary column, but the rendered value often occupies only its
        // rightmost portion (for example `77%`). Let localized detail text
        // use that empty space. If the value itself reaches the column's
        // leading edge, keep the viewport bounded by the actual safe gap and
        // let the marquee scroll. This keeps scrolling as the overflow
        // fallback, rather than the first response to a barely-overlong
        // translation.
        let amountFont = amountLabel.font ?? .systemFont(ofSize: 13)
        let amountTextWidth = AccountMarqueeView.textWidth(
            of: amountLabel.stringValue,
            font: amountFont
        )
        let renderedAmountMinX = amountLabel.frame.maxX - amountTextWidth
        let safeAmountMinX = max(amountLabel.frame.minX, renderedAmountMinX)
        let availableWidth = max(0, safeAmountMinX - baseFrame.minX)
        // Give the marquee the whole safe viewport. Its horizontal mask owns
        // the final fade inset, so the transparent edge ends exactly at the
        // rendered amount rather than introducing a second hard-cut gap.
        let expandedWidth = availableWidth
        return NSRect(
            x: baseFrame.minX,
            y: baseFrame.minY,
            width: expandedWidth,
            height: baseFrame.height
        )
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
