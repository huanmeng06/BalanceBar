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
        self.amount = amount
        self.countsDown = countsDown
    }
}

private struct OverviewNumericTextRoot: View {
    @ObservedObject var model: OverviewNumericTextModel
    let font: NSFont
    let color: NSColor

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(1)
    }

    @ViewBuilder
    private var numericValue: some View {
        if model.fractionLength > 0 {
            Text(model.amount, format: .number.precision(.fractionLength(model.fractionLength)))
                .contentTransition(.numericText(countsDown: model.countsDown))
                .animation(.snappy(duration: OverviewNumericTransition.currencyDigitRollDuration, extraBounce: 0), value: model.amount)
        } else {
            Text(verbatim: "\(Int(model.amount))")
                .contentTransition(.numericText(countsDown: model.countsDown))
        }
    }
}

final class OverviewNumericTextView: NSView {
    let textField: NSTextField
    private let model: OverviewNumericTextModel
    private let hostingView: NSHostingView<OverviewNumericTextRoot>
    private(set) var currentValue: Double
    private(set) var sample: OverviewNumericSample?
    private var pendingPlan: OverviewNumericTransitionPlan?
    private var finishWorkItem: DispatchWorkItem?

    var hasPendingAnimationForTesting: Bool { pendingPlan?.animates == true }
    var isDigitRollingForTesting: Bool { !hostingView.isHidden && textField.alphaValue == 0 }

    init(text: String, font: NSFont, value: Double) {
        currentValue = value
        textField = NSTextField(labelWithString: text)
        textField.font = font
        textField.textColor = .labelColor
        textField.alignment = .right
        textField.lineBreakMode = .byClipping
        textField.usesSingleLineMode = true
        model = OverviewNumericTextModel(amount: value)
        hostingView = NSHostingView(
            rootView: OverviewNumericTextRoot(
                model: model,
                font: font,
                color: .labelColor
            )
        )
        super.init(frame: .zero)
        wantsLayer = true
        hostingView.sizingOptions = []
        hostingView.isHidden = true
        addSubview(textField)
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        finishWorkItem?.cancel()
    }

    override func layout() {
        super.layout()
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
        textField.alphaValue = 0
        textField.stringValue = plan.endText
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(Self.digitRollAnimation(for: plan.format)) {
                self.model.amount = plan.toValue
            }
        }
    }

    private static func digitRollAnimation(for format: OverviewNumericFormat) -> Animation {
        switch format {
        case .currency:
            return .snappy(duration: OverviewNumericTransition.currencyDigitRollDuration, extraBounce: 0)
        case .integerPercent, .integerCount:
            return .easeOut(duration: OverviewNumericTransition.duration)
        }
    }

    private func applyImmediate(text: String, value: Double) {
        finishWorkItem?.cancel()
        finishWorkItem = nil
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
        textField.alphaValue = 1
        hostingView.isHidden = true
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
