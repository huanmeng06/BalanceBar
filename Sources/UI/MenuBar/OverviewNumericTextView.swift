import AppKit
import QuartzCore
import SwiftUI

final class OverviewNumericInterpolator: NSObject {
    private let from: Double
    private let to: Double
    private let duration: TimeInterval
    private let apply: (Double) -> Void
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var startTime: CFTimeInterval?

    init(
        from: Double,
        to: Double,
        duration: TimeInterval = OverviewNumericTransition.duration,
        apply: @escaping (Double) -> Void
    ) {
        self.from = from
        self.to = to
        self.duration = max(0.001, duration)
        self.apply = apply
    }

    func start() {
        cancel()
        apply(from)
        startTime = CACurrentMediaTime()
        if let screen = NSScreen.main {
            let link = screen.displayLink(
                target: self,
                selector: #selector(handleDisplayLink(_:))
            )
            displayLink = link
            link.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(
                timeInterval: 1 / 60,
                target: self,
                selector: #selector(handleFallbackTimer(_:)),
                userInfo: nil,
                repeats: true
            )
            fallbackTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        startTime = nil
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        tick()
    }

    @objc private func handleFallbackTimer(_ timer: Timer) {
        tick()
    }

    private func tick() {
        let started = startTime ?? CACurrentMediaTime()
        let progress = min(1, (CACurrentMediaTime() - started) / duration)
        let eased = 1 - pow(1 - progress, 3)
        apply(from + (to - from) * eased)
        if progress >= 1 {
            cancel()
            apply(to)
        }
    }
}

private final class OverviewNumericTextModel: ObservableObject {
    @Published var amount: Double
    @Published var prefix: String
    @Published var suffix: String
    @Published var fractionLength: Int
    @Published var remainingTime = false
    @Published var countsDown = false

    init(amount: Double) {
        self.amount = amount
        prefix = ""
        suffix = ""
        fractionLength = 0
    }

    func apply(parts: OverviewNumericDisplayParts, amount: Double, countsDown: Bool) {
        self.prefix = parts.prefix
        self.suffix = parts.suffix
        self.fractionLength = parts.fractionLength
        self.remainingTime = parts.remainingTime
        self.amount = amount
        self.countsDown = countsDown
    }
}

enum OverviewNumericVerticalAlignment: Equatable {
    /// Vertically center glyphs inside the numeric frame. This is the
    /// historical SwiftUI placement used by quota, Reserve, and banked reset.
    case center
    /// Pin glyphs to the top of the numeric frame. Used when that frame's top
    /// already lines up with a shorter AppKit detail row.
    case top
}

enum OverviewNumericContentAlignment: Equatable {
    case leading
    case trailing
    case topLeading
    case topTrailing

    fileprivate var swiftUI: Alignment {
        switch self {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        case .topLeading:
            return .topLeading
        case .topTrailing:
            return .topTrailing
        }
    }
}

private struct OverviewNumericTextRoot: View {
    @ObservedObject var model: OverviewNumericTextModel
    let font: NSFont
    let color: NSColor
    var alignment: NSTextAlignment = .right
    var contentAlignment: OverviewNumericContentAlignment = .trailing

    var body: some View {
        HStack(spacing: 0) {
            if !model.prefix.isEmpty {
                Text(model.prefix)
            }
            numericValue
            if !model.suffix.isEmpty {
                Text(model.suffix)
            }
        }
        .font(Font(font))
        .foregroundStyle(Color(color))
        .monospacedDigit()
        .multilineTextAlignment(alignment == .left || alignment == .natural ? .leading : .trailing)
        .lineLimit(1)
        .minimumScaleFactor(1)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: contentAlignment.swiftUI
        )
        .geometryGroup()
        .compositingGroup()
        .clipped()
    }

    @ViewBuilder
    private var numericValue: some View {
        if model.remainingTime {
            remainingTimeValue
        } else if model.fractionLength > 0 {
            Text(model.amount, format: .number.precision(.fractionLength(model.fractionLength)))
                .contentTransition(.numericText(countsDown: model.countsDown))
                .animation(.snappy(duration: OverviewNumericTransition.currencyDigitRollDuration, extraBounce: 0), value: model.amount)
        } else {
            Text(verbatim: "\(Int(model.amount))")
                .contentTransition(.numericText(countsDown: model.countsDown))
        }
    }

    private var remainingTimeValue: some View {
        let total = max(0, Int(model.amount.rounded(.down)))
        let hours = total / 60
        let minutes = total % 60
        return HStack(spacing: 0) {
            if hours > 0 {
                rollingInteger(hours, minDigits: 1)
                Text("h")
            }
            rollingInteger(minutes, minDigits: 1)
            Text("m")
        }
    }

    @ViewBuilder
    private func rollingInteger(_ value: Int, minDigits: Int) -> some View {
        if minDigits > 1 {
            Text(value, format: .number.precision(.integerLength(minDigits)).grouping(.never))
                .contentTransition(.numericText(countsDown: model.countsDown))
        } else {
            Text(verbatim: "\(value)")
                .contentTransition(.numericText(countsDown: model.countsDown))
        }
    }
}

final class OverviewNumericTextView: NSView {
    let textField: NSTextField
    let verticalAlignment: OverviewNumericVerticalAlignment
    private let contentAlignment: OverviewNumericContentAlignment
    private let model: OverviewNumericTextModel
    private let hostingView: NSHostingView<OverviewNumericTextRoot>
    private(set) var currentValue: Double
    private(set) var sample: OverviewNumericSample?
    private var pendingPlan: OverviewNumericTransitionPlan?
    private var finishWorkItem: DispatchWorkItem?
    private var isDigitRolling = false

    var hasPendingAnimationForTesting: Bool { pendingPlan?.animates == true }
    var isDigitRollingForTesting: Bool { isDigitRolling }
    var isHostingVisibleForTesting: Bool { !hostingView.isHidden }
    var hostingClipsToBoundsForTesting: Bool { hostingView.clipsToBounds }
    var contentAlignmentForTesting: OverviewNumericContentAlignment { contentAlignment }
    var hostsFullBoundsForTesting: Bool {
        hostingView.frame == bounds && textField.frame == bounds
    }

    static func contentAlignment(
        horizontal: NSTextAlignment,
        vertical: OverviewNumericVerticalAlignment
    ) -> OverviewNumericContentAlignment {
        let leading = horizontal == .left || horizontal == .natural
        switch (leading, vertical) {
        case (true, .center):
            return .leading
        case (false, .center):
            return .trailing
        case (true, .top):
            return .topLeading
        case (false, .top):
            return .topTrailing
        }
    }

    init(
        text: String,
        font: NSFont,
        value: Double,
        textColor: NSColor = .labelColor,
        alignment: NSTextAlignment = .right,
        verticalAlignment: OverviewNumericVerticalAlignment = .center
    ) {
        currentValue = value
        self.verticalAlignment = verticalAlignment
        let contentAlignment = Self.contentAlignment(
            horizontal: alignment,
            vertical: verticalAlignment
        )
        self.contentAlignment = contentAlignment
        textField = NSTextField(labelWithString: text)
        textField.font = font
        textField.textColor = textColor
        textField.alignment = alignment
        textField.lineBreakMode = .byClipping
        textField.usesSingleLineMode = true
        textField.isHidden = true
        textField.alphaValue = 0
        textField.setAccessibilityElement(false)
        model = OverviewNumericTextModel(amount: value)
        hostingView = NSHostingView(
            rootView: OverviewNumericTextRoot(
                model: model,
                font: font,
                color: textColor,
                alignment: alignment,
                contentAlignment: contentAlignment
            )
        )
        super.init(frame: .zero)
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        applyTransitionClipping(self)
        applyTransitionClipping(hostingView)
        addSubview(textField)
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        finishWorkItem?.cancel()
    }

    override func layout() {
        super.layout()
        applyTransitionClipping(self)
        applyTransitionClipping(hostingView)
        syncInnerFrames()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncInnerFrames()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        syncInnerFrames()
    }

    private func syncInnerFrames() {
        textField.frame = bounds
        hostingView.frame = bounds
    }

    private func applyTransitionClipping(_ view: NSView) {
        view.wantsLayer = true
        view.clipsToBounds = true
        view.layer?.masksToBounds = true
    }

    func configure(plan: OverviewNumericTransitionPlan, sample: OverviewNumericSample) {
        self.sample = sample
        currentValue = plan.startValue
        pendingPlan = plan.animates ? plan : nil
        applyImmediate(text: plan.startText, value: plan.startValue)
    }

    func playPendingIfNeeded() {
        guard let plan = pendingPlan, plan.animates else { return }
        pendingPlan = nil
        play(plan)
    }

    func apply(plan: OverviewNumericTransitionPlan, sample: OverviewNumericSample) {
        if self.sample == sample, currentValue == plan.toValue, !plan.animates {
            return
        }
        self.sample = sample
        pendingPlan = nil
        if plan.animates, window != nil {
            play(plan)
        } else if plan.animates {
            currentValue = plan.startValue
            pendingPlan = plan
            applyImmediate(text: plan.startText, value: plan.startValue)
        } else {
            applyImmediate(text: plan.endText, value: plan.toValue)
        }
    }

    private func play(_ plan: OverviewNumericTransitionPlan) {
        finishWorkItem?.cancel()
        isDigitRolling = true
        currentValue = plan.toValue
        let parts = plan.format.displayParts
        var startTransaction = Transaction()
        startTransaction.disablesAnimations = true
        withTransaction(startTransaction) {
            model.apply(
                parts: parts,
                amount: plan.startValue,
                countsDown: plan.toValue < plan.fromValue
            )
        }
        hostingView.isHidden = false
        textField.isHidden = true
        textField.alphaValue = 0
        textField.stringValue = plan.endText
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(Self.digitRollAnimation(for: plan.format)) {
                self.model.amount = plan.toValue
            }
            let finish = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.settle(plan)
            }
            self.finishWorkItem = finish
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OverviewNumericTransition.duration(for: plan.format),
                execute: finish
            )
        }
    }

    private func settle(_ plan: OverviewNumericTransitionPlan) {
        isDigitRolling = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.apply(
                parts: plan.format.displayParts,
                amount: plan.toValue,
                countsDown: plan.toValue < plan.fromValue
            )
        }
        hostingView.isHidden = false
        textField.isHidden = true
        textField.alphaValue = 0
        textField.stringValue = plan.endText
    }

    private static func digitRollAnimation(for format: OverviewNumericFormat) -> Animation {
        switch format {
        case .currency:
            return .snappy(duration: OverviewNumericTransition.currencyDigitRollDuration, extraBounce: 0)
        case .integerPercent, .integerCount, .remainingMinutes:
            return .easeOut(duration: OverviewNumericTransition.duration)
        }
    }

    private func applyImmediate(text: String, value: Double) {
        finishWorkItem?.cancel()
        finishWorkItem = nil
        isDigitRolling = false
        currentValue = value
        if let sample {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.apply(
                    parts: sample.format.displayParts,
                    amount: value,
                    countsDown: false
                )
            }
        }
        textField.stringValue = text
        textField.isHidden = true
        textField.alphaValue = 0
        hostingView.isHidden = false
    }
}

final class OverviewNumericHoverLinkTextField: HoverLinkTextField {
    private(set) var currentValue: Double = 0
    private(set) var sample: OverviewNumericSample?
    private var pendingTo: Double?
    private var interpolator: OverviewNumericInterpolator?

    func configure(plan: OverviewNumericTransitionPlan, sample: OverviewNumericSample) {
        interpolator?.cancel()
        interpolator = nil
        self.sample = sample
        currentValue = plan.startValue
        stringValue = plan.startText
        pendingTo = plan.animates ? plan.toValue : nil
        if !plan.animates {
            currentValue = plan.toValue
            stringValue = plan.endText
        }
    }

    func playPendingIfNeeded() {
        guard let pendingTo else { return }
        self.pendingTo = nil
        animate(to: pendingTo)
    }

    func apply(plan: OverviewNumericTransitionPlan, sample: OverviewNumericSample) {
        interpolator?.cancel()
        interpolator = nil
        self.sample = sample
        if plan.animates, window != nil {
            pendingTo = nil
            stringValue = plan.startText
            currentValue = plan.startValue
            animate(to: plan.toValue)
        } else {
            configure(plan: plan, sample: sample)
        }
    }

    private func animate(to value: Double) {
        let from = currentValue
        let interpolator = OverviewNumericInterpolator(from: from, to: value) { [weak self] current in
            guard let self, let sample else { return }
            self.currentValue = current
            self.stringValue = sample.format.displayText(for: current)
        }
        self.interpolator = interpolator
        interpolator.start()
    }

    deinit {
        interpolator?.cancel()
    }
}
