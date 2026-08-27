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
        let font = NSFont.toolTipsFont(ofSize: NSFont.smallSystemFontSize)
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
        label.font = font
        label.textColor = .labelColor
        label.alignment = .left
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

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
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
/// stable samples separated by the normal activity polling cadence. This
/// keeps startup, monitor recovery, and quick task transitions visible while
/// reusing the activity value emitted by ActivityCoordinator.
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
    mutating func ingest(
        mode: MenuBarIconDisplayMode,
        codexTaskRunning: Bool,
        at date: Date
    ) -> Bool {
        setMode(mode, codexTaskRunning: codexTaskRunning, at: date)
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

        guard let candidate = idleCandidate,
              candidate.sampleCount >= Self.idleConfirmationSampleCount,
              candidate.lastSampleAt.timeIntervalSince(candidate.firstSampleAt)
                >= Self.idleConfirmationInterval else {
            return shouldDisplay
        }

        shouldDisplay = false
        return shouldDisplay
    }
}

final class StatusItemController: NSObject, NSMenuDelegate {
    private static let statusItemVisibilityStabilityDelay: TimeInterval = 0.2
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
            self.visibilityChanged = visibilityChanged
        }
    }

    struct MenuBarSettings {
        let showIcon: Bool
        let showAmount: Bool
        let showReset: Bool
        let iconDisplayMode: MenuBarIconDisplayMode
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

        init(
            showIcon: Bool,
            showAmount: Bool,
            showReset: Bool,
            horizontalPadding: CGFloat,
            keepMenuOpenAfterRefresh: Bool,
            iconDisplayMode: MenuBarIconDisplayMode = .defaultValue,
            iconOffsetX: CGFloat = 0,
            iconOffsetY: CGFloat = 0,
            amountOffsetX: CGFloat = 0,
            amountOffsetY: CGFloat = 0,
            widthAdjustment: CGFloat = 0,
            fontSize: CGFloat = MenuBarLayout.primaryFontPointSize,
            quotaWindowPreference: OfficialQuotaWindowPreference = .defaultValue,
            quotaResetDisplayMode: OfficialQuotaResetDisplayMode = .defaultValue
        ) {
            self.showIcon = showIcon
            self.showAmount = showAmount
            self.showReset = showReset
            self.iconDisplayMode = iconDisplayMode
            self.horizontalPadding = horizontalPadding
            self.keepMenuOpenAfterRefresh = keepMenuOpenAfterRefresh
            self.iconOffsetX = iconOffsetX
            self.iconOffsetY = iconOffsetY
            self.amountOffsetX = amountOffsetX
            self.amountOffsetY = amountOffsetY
            self.widthAdjustment = widthAdjustment
            self.quotaWindowPreference = quotaWindowPreference
            self.quotaResetDisplayMode = quotaResetDisplayMode
            self.fontSize = CGFloat(
                AppPreferences.normalizedMenuBarFontSize(
                    Double(fontSize),
                    range: AppPreferences.menuBarFontSizeRange
                )
            )
        }
    }

    struct MenuInput {
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
    private let menuBarPrimaryLabel = PassthroughTextField(labelWithString: "…")
    private let menuBarSecondaryLabel = PassthroughTextField(labelWithString: "")
    private var isMenuBarContentStackConfigured = false
    private var lastMenuBarIconFrameDiagnostic: String?
    private var codexIconImage: NSImage?
    private var claudeIconImage: NSImage?
    private var claudeThinkingAnimator: ClaudeThinkingAnimator?
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
        showStatusMenu: true
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

    var isVisible: Bool { statusItem?.isVisible ?? false }
    var isMenuTracking: Bool { isStatusMenuTracking }
    var iconImage: NSImage? { menuBarIconView.image }

    // Exposes the controller's current outer footprint for headless layout
    // tests without exposing the underlying NSStatusItem.
    var statusItemLengthForTesting: CGFloat? { statusItem?.length }

    // Live AppKit geometry used by the single-line regression tests. These
    // are the rendered primary ink and icon bounds, not the anti-clipping
    // label/frame allocation.
    var menuBarPrimaryInkBoundsForTesting: NSRect? {
        menuBarPrimaryInkBounds(in: statusItem?.button)
    }

    var menuBarIconFrameForTesting: NSRect? {
        guard let button = statusItem?.button else { return nil }
        return menuBarIconView.convert(menuBarIconView.bounds, to: button)
    }

    var menuBarButtonBoundsForTesting: NSRect? {
        statusItem?.button?.bounds
    }

    var menuBarPrimaryTextForTesting: String { menuBarPrimaryLabel.stringValue }

    var menuBarSecondaryTextForTesting: String { menuBarSecondaryLabel.stringValue }

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

    var startupDiagnostic: String {
        let statusWindow = statusItem?.button?.window
        return "status_visible=\(isVisible); menu_bound=\(statusItem?.menu === statusMenu); menu_items=\(statusMenu.items.count); button_window=\(statusWindow != nil)"
    }

    init(actions: Actions) {
        self.actions = actions
        super.init()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.statusItem != nil else { return }
            self.scheduleStatusItemAttachmentCheck(
                reason: "screen-parameters",
                reanchor: false
            )
        }
    }

    deinit {
        removeStatusItemWindowObservation()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func start(
        snapshot: Snapshot,
        refreshDate: Date?,
        menuInput: MenuInput,
        settings: MenuBarSettings
    ) {
        lifecycleGeneration += 1
        let isNewStatusItem = statusItem == nil
        if isNewStatusItem {
            menuBarIconDisplayStateMachine.reset()
            menuBarIconDisplayStateMachine.setMode(
                settings.iconDisplayMode,
                codexTaskRunning: isCodexTaskRunning,
                at: Date()
            )
        }
        statusItemVisibilityStateMachine.reset()
        updateStatusItemVisibility(.unknown)
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
        removeStatusItemWindowObservation()
        statusItemVisibilityStateMachine.reset()
        menuBarIconDisplayStateMachine.reset()
        updateStatusItemVisibility(.unknown)
        statusItemAttachmentCheckScheduled = false
        statusItemReanchorAttempts = 0
        statusMenuNeedsRebuild = false
        isStatusMenuTracking = false
        lastMenuBarIconFrameDiagnostic = nil
        lastMenuBarGeometry = nil
        menuBarIconView.stopRotating()
        claudeThinkingAnimator?.stop()
        menuBarIconView.onImageChanged = nil
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
        let iconDisplayModeChanged = self.settings.iconDisplayMode != settings.iconDisplayMode
        self.snapshot = snapshot
        self.refreshDate = refreshDate
        self.menuInput = menuInput
        self.settings = settings
        if iconDisplayModeChanged {
            menuBarIconDisplayStateMachine.setMode(
                settings.iconDisplayMode,
                codexTaskRunning: isCodexTaskRunning,
                at: Date()
            )
        }
        layoutStatusItem(for: snapshot)
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
        layoutStatusItem(for: snapshot)
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
    }

    func updateMenu(input: MenuInput) {
        menuInput = input
        rebuildOrDeferMenu()
    }

    private func updateStatusItemVisibility(_ visibility: StatusItemVisibility) {
        guard statusItemVisibility != visibility else { return }
        statusItemVisibility = visibility
        actions.visibilityChanged(visibility)
    }

    func updateActivity(
        activeClient: AssistantClient,
        codexTaskRunning: Bool,
        claudeTaskRunning: Bool,
        animationEnabled: Bool
    ) {
        self.activeClient = activeClient
        self.isCodexTaskRunning = codexTaskRunning
        self.isClaudeTaskRunning = claudeTaskRunning
        self.animationEnabled = animationEnabled
        updateActivityIcon()
        menuBarIconDisplayStateMachine.ingest(
            mode: settings.iconDisplayMode,
            codexTaskRunning: codexTaskRunning,
            at: Date()
        )
        applyMenuBarIconDisplayPolicy()
    }

    /// Accepts a repeated Codex monitor sample without re-running the activity
    /// icon animation path. ActivityCoordinator remains the only producer of
    /// task state; this method only advances the display debounce.
    func observeCodexTaskSample(_ running: Bool) {
        isCodexTaskRunning = running
        menuBarIconDisplayStateMachine.ingest(
            mode: settings.iconDisplayMode,
            codexTaskRunning: running,
            at: Date()
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
        updateStatusItemVisibility(.unknown)
        statusItem.isVisible = menuBarIconDisplayStateMachine.shouldDisplay
        statusItem.length = 56
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = nil
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
        menuBarIconView.onImageChanged = { [weak self] image in
            guard let self else { return }
            self.menuBarIconView.image = image
            self.layoutStatusItem(for: self.snapshot)
            self.actions.iconChanged(image)
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
        button.addSubview(menuBarContentStack)
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
            NSWindow.didChangeScreenNotification
        ]
        statusItemWindowObservers = notifications.map { notificationName in
            NotificationCenter.default.addObserver(
                forName: notificationName,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.statusItem != nil else { return }
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
        let visibility = statusItemVisibilityStateMachine.ingest(
            evidence,
            at: Date()
        )
        updateStatusItemVisibility(visibility)
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
        guard let item = statusItem, let button = item.button else {
            statusItemVisibilityStateMachine.reset()
            updateStatusItemVisibility(.unknown)
            SwitchLog.write(
                "status item attachment failed; reason=missing item or button",
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
        guard menuBarIconDisplayStateMachine.shouldDisplay else {
            // An intentionally hidden status item still owns its NSStatusItem
            // and must not be mistaken for an AppKit attachment failure.
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
            if let codexIconImage {
                menuBarIconView.setSourceImage(codexIconImage)
            }
            if MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: isCodexTaskRunning,
                preferenceEnabled: animationEnabled
            ) {
                menuBarIconView.startRotating()
            } else {
                menuBarIconView.stopRotating()
            }
        case .claude:
            menuBarIconView.stopRotating()
            if let claudeIconImage {
                menuBarIconView.setSourceImage(claudeIconImage)
            }
            if MenuBarActivityAnimationPolicy.shouldAnimate(
                taskRunning: isClaudeTaskRunning,
                preferenceEnabled: animationEnabled
            ) {
                claudeThinkingAnimator?.start()
            } else {
                claudeThinkingAnimator?.stop()
            }
        }
    }

    private func applyMenuBarIconDisplayPolicy() {
        guard let statusItem else { return }
        let shouldDisplay = menuBarIconDisplayStateMachine.shouldDisplay
        guard statusItem.isVisible != shouldDisplay else { return }
        statusItem.isVisible = shouldDisplay
        SwitchLog.write(
            "menu bar display mode applied; mode=\(settings.iconDisplayMode.rawValue); codex_running=\(isCodexTaskRunning); visible=\(shouldDisplay)",
            category: "ui.status-item"
        )
        if shouldDisplay {
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

    private func logMenuBarIconFrames(
        snapshot: Snapshot,
        button: NSStatusBarButton,
        hasSecondary: Bool,
        iconYOffset: CGFloat
    ) {
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
                displayMode: settings.quotaResetDisplayMode
            )
            : ""
        let hasSecondary = settings.showAmount
            && settings.showReset
            && !reservedSecondary.isEmpty

        menuBarPrimaryLabel.stringValue = settings.showAmount ? effectiveSnapshot.menuBarPrimary : ""
        menuBarSecondaryLabel.stringValue = reservedSecondary
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

        if isSingleLineAmountMode(
            effectiveSnapshot: effectiveSnapshot,
            geometry: geometry
        ) {
            statusItem.length = MenuBarLayout.singleLineStatusItemLength(
                primaryText: effectiveSnapshot.menuBarPrimary,
                showIcon: settings.showIcon,
                isBalance: effectiveSnapshot.kind == .balance,
                horizontalPadding: settings.horizontalPadding,
                widthAdjustment: settings.widthAdjustment
            )
        } else {
            statusItem.length = MenuBarLayout.statusItemLength(
                contentWidth: geometry.contentWidth,
                horizontalPadding: settings.horizontalPadding,
                widthAdjustment: settings.widthAdjustment
            )
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
        logMenuBarIconFrames(
            snapshot: effectiveSnapshot,
            button: button,
            hasSecondary: hasSecondary,
            iconYOffset: iconYOffset
        )
        button.toolTip = effectiveSnapshot.menuBarToolTip
        button.isHidden = false
        button.isEnabled = true
        applyMenuBarIconDisplayPolicy()
    }

    private func applyMenuBarFonts() {
        menuBarPrimaryLabel.font = MenuBarLayout.primaryFont(
            size: settings.fontSize
        )
        menuBarSecondaryLabel.font = MenuBarLayout.secondaryFont(
            size: CGFloat(
                AppPreferences.secondaryMenuBarFontSize(for: Double(settings.fontSize))
            )
        )
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
            if let primaryInk = menuBarPrimaryInkBounds(in: button) {
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
            if let primaryInk = menuBarPrimaryInkBounds(in: button) {
                let automaticTextYOffset = MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                    fontSize: settings.fontSize
                )
                let targetY = button.bounds.midY + MenuBarOffsetLayout.yDelta(
                    visualY: settings.amountOffsetY + automaticTextYOffset,
                    in: .flippedFrame
                )
                let verticalCorrection = targetY - primaryInk.midY
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

    private func menuBarPrimaryInkBounds(in button: NSStatusBarButton?) -> NSRect? {
        guard let button,
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
        return menuBarPrimaryLabel.convert(localBounds, to: button)
    }

    private func menuBarSnapshot(for snapshot: Snapshot) -> Snapshot {
        let effective = OpenCodexCardPresentation.menuBarSnapshot(
            for: snapshot,
            cards: menuInput.openCodexCards
        )
        let resolved = effective.menuBarSnapshot(
            preferredQuotaWindow: settings.quotaWindowPreference
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
        statusMenu.addItem(
            withTitle: tr(.keyStatusItemControllerOpenMainWindow),
            action: #selector(openDashboard),
            keyEquivalent: ""
        ).target = self
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
        let officialQuotaWindows = snapshot.kind == .official
            ? snapshot.officialQuotaWindowsForMenu
            : []
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
            officialQuotaWindows: officialQuotaWindows
        )
        let view = NSView(frame: NSRect(origin: .zero, size: layout.cardSize))
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

        if !layout.quotaRows.isEmpty {
            for (window, row) in zip(officialQuotaWindows, layout.quotaRows) {
                let progress = QuotaProgressView(percentage: window.remaining)
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
            view.addSubview(provider)
        } else {
            if let percentage = snapshot.progressPercentage, let progressFrame = layout.progress {
                let progress = QuotaProgressView(percentage: percentage)
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
            status = tr(.keyStatusItemControllerOpencodexChosenModelsAreNotAvailableYet)
        } else {
            status = tr(.keyStatusItemControllerNoOpencodexChosenModelsAreConfigured)
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
        let view = NSView(frame: NSRect(origin: .zero, size: layout.cardSize))
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
            progress = QuotaProgressView(percentage: remaining)
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
            progress = QuotaProgressView(percentage: progressPercentage)
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
        if let websiteLink { view.addSubview(websiteLink) }
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
