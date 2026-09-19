import AppKit

/// Pure delay/interval policy for long-press auto-repeat of the fine-tune
/// direction buttons. Press-and-hold starts stepping after `initialDelay`,
/// then repeats every `initialInterval`, accelerating by `accelerationFactor`
/// per step and floored at `minimumInterval`.
struct MenuBarOffsetRepeatPolicy: Equatable {
    static let standard = MenuBarOffsetRepeatPolicy(
        initialDelay: 0.35,
        initialInterval: 0.1,
        accelerationFactor: 0.9,
        minimumInterval: 0.03
    )

    let initialDelay: TimeInterval
    let initialInterval: TimeInterval
    let accelerationFactor: Double
    let minimumInterval: TimeInterval

    /// Interval before the `step`-th repeat fires. `step == 0` is the initial
    /// press-and-hold delay before auto-repeat starts.
    func interval(afterStep step: Int) -> TimeInterval {
        guard step > 0 else { return initialDelay }
        let multiplier = pow(accelerationFactor, Double(step - 1))
        return max(minimumInterval, initialInterval * multiplier)
    }
}

/// Drives auto-repeat steps after a press-and-hold. Fires `onStep` once after
/// the policy's initial delay, then repeatedly at policy intervals on the main
/// run loop until stopped.
final class MenuBarOffsetRepeatDriver {
    private let policy: MenuBarOffsetRepeatPolicy
    private let onStep: () -> Void
    private var delayWorkItem: DispatchWorkItem?
    private var repeatTimer: Timer?
    private var stepCount = 0

    init(policy: MenuBarOffsetRepeatPolicy, onStep: @escaping () -> Void) {
        self.policy = policy
        self.onStep = onStep
    }

    var isRunning: Bool { delayWorkItem != nil || repeatTimer != nil }

    func start() {
        stop()
        stepCount = 0
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performStep()
            self.scheduleNext()
        }
        delayWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + policy.initialDelay,
            execute: item
        )
    }

    func stop() {
        delayWorkItem?.cancel()
        delayWorkItem = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func performStep() {
        stepCount += 1
        onStep()
    }

    private func scheduleNext() {
        let interval = policy.interval(afterStep: stepCount)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.performStep()
            self.scheduleNext()
        }
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Direction button that auto-repeats while pressed and held. A short press
/// fires the action exactly once; holding past the policy delay starts
/// repeating the action at policy intervals. Releasing, dragging outside the
/// button, or the window losing key status stops the repeat immediately.
final class RepeatOffsetButton: NSButton {
    private enum PressPhase {
        case idle
        case waiting
        case repeating
    }

    private let policy: MenuBarOffsetRepeatPolicy
    private lazy var driver = MenuBarOffsetRepeatDriver(policy: policy) { [weak self] in
        guard let self,
              self.pressPhase == .waiting || self.pressPhase == .repeating else {
            return
        }
        if self.pressPhase == .waiting {
            self.pressPhase = .repeating
        }
        _ = self.sendAction(self.action, to: self.target)
    }
    private var pressPhase: PressPhase = .idle
    private var resignObserver: NSObjectProtocol?
    private var driverWasUsed = false

    init(
        title: String,
        policy: MenuBarOffsetRepeatPolicy,
        target: AnyObject?,
        action: Selector?
    ) {
        self.policy = policy
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if driverWasUsed {
            driver.stop()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isHighlighted = true
        pressPhase = .waiting
        driverWasUsed = true
        observeWindowResignIfNeeded()
        driver.start()
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressPhase != .idle else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !bounds.contains(point) {
            isHighlighted = false
            stopPress(removeObserver: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressPhase != .idle else { return }
        let wasRepeating = pressPhase == .repeating
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isHighlighted = false
        stopPress(removeObserver: true)
        if inside && !wasRepeating {
            _ = sendAction(action, to: target)
        }
    }

    private func observeWindowResignIfNeeded() {
        guard resignObserver == nil, let window else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.stopPress(removeObserver: true)
        }
    }

    private func stopPress(removeObserver: Bool) {
        isHighlighted = false
        pressPhase = .idle
        if driverWasUsed {
            driver.stop()
        }
        if removeObserver, let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}

final class MenuBarWidthSlider: NSSlider {
    var onEditingEnded: (() -> Void)?

    private var isPointerTracking = false
    private var lastPointerValue: Double?

    /// Tick marks below the track add a 1pt-class bottom alignment inset on
    /// some macOS 26 SDKs. Native settings rows and `NSStackView` center
    /// using alignment rects, which then shows up as a bounds offset against
    /// the row's geometric center. Keep alignment identical to bounds so the
    /// slider can stay centered without rewriting the control.
    override var alignmentRectInsets: NSEdgeInsets { .init() }

    override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }

    override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }

    static func integerValuesCrossed(
        from previousValue: Double,
        to currentValue: Double,
        minimum: Double,
        maximum: Double
    ) -> [Int] {
        guard previousValue != currentValue else { return [] }

        let previous = snappedIntegerValue(previousValue)
        let current = snappedIntegerValue(currentValue)
        let first: Int
        let last: Int

        if current > previous {
            // Include an integer when arriving at it, but not when leaving
            // an integer that was already reached at the start of the drag.
            first = Int(floor(previous)) + 1
            last = Int(floor(current))
        } else {
            // Reverse the same rule for a leftward drag.
            first = Int(ceil(current))
            last = Int(ceil(previous)) - 1
        }

        let lowerBound = Int(ceil(minimum))
        let upperBound = Int(floor(maximum))
        guard first <= last else { return [] }

        let clampedFirst = max(first, lowerBound)
        let clampedLast = min(last, upperBound)
        guard clampedFirst <= clampedLast else { return [] }

        let values = Array(clampedFirst...clampedLast)
        return current > previous ? values : Array(values.reversed())
    }

    override func mouseDown(with event: NSEvent) {
        isPointerTracking = true
        lastPointerValue = doubleValue
        super.mouseDown(with: event)
        notifyIntegerBoundaryIfNeeded(for: doubleValue)
        isPointerTracking = false
        lastPointerValue = nil
        onEditingEnded?()
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if isPointerTracking {
            notifyIntegerBoundaryIfNeeded(for: doubleValue)
        }
        return super.sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        onEditingEnded?()
    }

    private func notifyIntegerBoundaryIfNeeded(for value: Double) {
        guard let previousValue = lastPointerValue else {
            lastPointerValue = value
            return
        }

        let crossedValues = Self.integerValuesCrossed(
            from: previousValue,
            to: value,
            minimum: minValue,
            maximum: maxValue
        )
        for _ in crossedValues {
            // The system performer silently suppresses this on devices that
            // do not provide Force Touch, such as a regular mouse.
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
        }
        lastPointerValue = value
    }

    private static func snappedIntegerValue(_ value: Double) -> Double {
        let rounded = value.rounded()
        return abs(value - rounded) < 0.000_001 ? rounded : value
    }
}
