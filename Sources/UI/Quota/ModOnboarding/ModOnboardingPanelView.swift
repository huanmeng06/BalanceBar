import AppKit

/// One visible element of the panel; the view renders exactly this list, and tests snapshot it.
enum ModPanelItem: Equatable {
    case title(String)
    case hero(symbol: String?, title: String, subtitle: String?)
    case codeBlock(String, copyAction: ButtonAction)
    case detail(String)
    case text(String)
    case feature(symbol: String, title: String, detail: String)
    case step(label: String, status: StepStatus)
    case code(String)
    case checkbox(title: String, checked: Bool)
    /// The "don't show this in the menu" preference; toggling it updates the status menu.
    case menuPromptCheckbox(title: String, checked: Bool)
    case button(title: String, action: ButtonAction)

    enum StepStatus: String, Equatable { case pending, running, done }
    enum ButtonAction: Equatable { case install, close, copyCommands, copyReload, undoDismiss, uninstall, copyUninstall, copyEnable, refresh, confirmUninstall, cancelUninstall }

    var snapshotLine: String {
        switch self {
        case let .title(t): return "# \(t)"
        case let .hero(_, title, subtitle): return "# \(title)" + (subtitle.map { "\n" + $0 } ?? "")
        case let .codeBlock(c, _): return "$ " + c.replacingOccurrences(of: "\n", with: "\n$ ")
        case let .detail(text): return "> " + text
        case let .text(t): return t
        case let .feature(symbol, title, detail): return "[\(symbol)] \(title): \(detail)"
        case let .step(label, status):
            let mark = status == .done ? "[x]" : status == .running ? "[~]" : "[ ]"
            return "\(mark) \(label)"
        case let .code(c): return "$ " + c.replacingOccurrences(of: "\n", with: "\n$ ")
        case let .checkbox(title, checked): return "(\(checked ? "x" : " ")) \(title)"
        case let .menuPromptCheckbox(title, checked): return "(\(checked ? "x" : " ")) \(title)"
        case let .button(title, _): return "<\(title)>"
        }
    }
}

/// The live sync status injected by the settings entry: what the panel shows at the top
/// and whether install or uninstall actions apply. `nil` keeps the legacy menu-prompt
/// panel (dismiss checkbox, install only).
struct ModPanelSyncContext: Equatable {
    var status: ModSyncStatus
    var statusText: String
}

enum ModPanelContent {
    /// The user-scope installation states the panel treats as "the Mod is in place";
    /// only these expose the uninstall action.
    static func isInstalled(_ status: ModSyncStatus) -> Bool {
        switch status {
        case .waitingForData, .active, .silent, .disabled, .snapshotRejected: return true
        case .detecting, .claudeMissing, .claudeVersionTooOld, .inboxNotReady, .notInstalled,
             .installationUnknown: return false
        }
    }

    static func items(
        for state: ModPanelState,
        plan: ModInstallPlan,
        localize: (ModOnboardingText) -> String,
        sync: ModPanelSyncContext? = nil,
        promptDismissed: Bool = false
    ) -> [ModPanelItem] {
        let t = localize
        if let sync {
            return managementItems(for: state, plan: plan, localize: t, sync: sync,
                                   promptDismissed: promptDismissed)
        }
        switch state {
        case let .intro(checked):
            var items: [ModPanelItem] = [.title(t(.panelTitle))]
            if let sync { items.append(.text(sync.statusText)) }
            items += [
                .text("• " + t(.point1)), .text("• " + t(.point2)),
                .text("• " + t(.point3)), .text("• " + t(.point4)),
            ]
            if sync == nil {
                items.append(.checkbox(title: t(.dismissCheckbox), checked: checked))
            }
            if let sync, isInstalled(sync.status) {
                if sync.status == .disabled {
                    items.append(.button(title: t(.copyEnableCommands), action: .copyEnable))
                }
                items.append(.button(title: t(.uninstallButton), action: .uninstall))
            } else {
                items.append(.button(title: t(.installButton), action: .install))
            }
            items.append(.button(title: t(.closeButton), action: .close))
            return items
        case let .installing(current):
            let labels = [t(.step1), t(.step2), t(.step3)]
            let steps = ModInstallStep.allCases.map { step -> ModPanelItem in
                let status: ModPanelItem.StepStatus = step.rawValue < current.rawValue ? .done
                    : step == current ? .running : .pending
                return .step(label: labels[step.rawValue], status: status)
            }
            return [.title(t(.panelTitle))] + steps
        case .succeeded:
            let labels = [t(.step1), t(.step2), t(.step3)]
            return [.title(t(.enabled))]
                + labels.map { .step(label: $0, status: .done) }
                + [.text(t(.enabledNote)), .text(t(.reloadHint)),
                   .button(title: ModInstallPlan.reloadCommand, action: .copyReload),
                   .button(title: t(.closeButton), action: .close)]
        case let .failed(failure):
            let reason: ModOnboardingText
            switch failure {
            case .claudeNotFound: reason = .failureClaudeMissing
            case .inboxNotReady: reason = .failureInbox
            case .commandFailed: reason = .failureCommandFailed
            }
            return [
                .title(t(.failureTitle)), .text(t(reason)), .code(plan.copyableCommands),
                .button(title: t(.copyCommands), action: .copyCommands),
                .button(title: t(.closeButton), action: .close),
            ]
        case let .uninstalling(current):
            let labels = [t(.uninstallStep1), t(.uninstallStep2), t(.step3)]
            let steps = ModUninstallStep.allCases.map { step -> ModPanelItem in
                let status: ModPanelItem.StepStatus = step.rawValue < current.rawValue ? .done
                    : step == current ? .running : .pending
                return .step(label: labels[step.rawValue], status: status)
            }
            return [.title(t(.panelTitle))] + steps
        case .uninstallSucceeded:
            return [
                .title(t(.uninstallDone)), .text(t(.uninstallDoneNote)),
                .button(title: t(.closeButton), action: .close),
            ]
        case let .uninstallFailed(failure):
            let reason: ModOnboardingText = failure == .claudeNotFound ? .failureClaudeMissing : .failureUninstall
            return [
                .title(t(.failureTitle)), .text(t(reason)), .code(plan.copyableUninstallCommands),
                .button(title: t(.copyCommands), action: .copyUninstall),
                .button(title: t(.closeButton), action: .close),
            ]
        case .dismissConfirmed:
            return [
                .title(t(.dismissedTitle)), .text(t(.dismissedNote)),
                .button(title: t(.undoDismiss), action: .undoDismiss),
                .button(title: t(.closeButton), action: .close),
            ]
        }
    }

    /// Presentation only: status and snapshot acceptance remain owned by #603.
    private static func managementItems(
        for state: ModPanelState, plan: ModInstallPlan,
        localize t: (ModOnboardingText) -> String, sync: ModPanelSyncContext,
        promptDismissed: Bool
    ) -> [ModPanelItem] {
        let close = ModPanelItem.button(title: t(.closeButton), action: .close)
        let refresh = ModPanelItem.button(title: t(.refresh), action: .refresh)
        let uninstall = ModPanelItem.button(title: t(.uninstallButton), action: .uninstall)
        func steps(_ labels: [String], current: Int) -> [ModPanelItem] {
            labels.enumerated().map { index, label in
                .step(label: label, status: index < current ? .done : index == current ? .running : .pending)
            }
        }
        func reloadAdvice() -> [ModPanelItem] {
            [.text(t(.enabledNote)), .text(t(.reloadHint)),
             .codeBlock(ModInstallPlan.reloadCommand, copyAction: .copyReload),
             .button(title: t(.copyCommands), action: .copyReload)]
        }
        switch state {
        case .intro:
            switch sync.status {
            case let .notInstalled(otherScope):
                var result: [ModPanelItem] = [.hero(symbol: nil, title: t(.pitchTitle), subtitle: t(.pitchSubtitle))]
                if otherScope { result.append(.text(sync.statusText)) }
                result += [
                    .feature(symbol: "bolt.fill", title: t(.feature1Title), detail: t(.feature1Detail)),
                    .feature(symbol: "terminal", title: t(.feature2Title), detail: t(.coverageNote)),
                    .feature(symbol: "gauge.with.dots.needle.33percent", title: t(.benefitFallback), detail: t(.fallbackNote)),
                    .feature(symbol: "lock.shield", title: t(.feature4Title), detail: t(.feature4Detail)),
                    .menuPromptCheckbox(title: t(.dismissCheckbox), checked: promptDismissed),
                    .button(title: t(.copyCommands), action: .copyCommands),
                    .button(title: t(.laterButton), action: .close),
                    .button(title: t(.installButton), action: .install)]
                return result
            case .detecting:
                return [.hero(symbol: nil, title: t(.pitchTitle), subtitle: sync.statusText), close]
            case .installationUnknown:
                return [.hero(symbol: "exclamationmark.triangle.fill", title: t(.failureTitle), subtitle: nil),
                        .text(sync.statusText),
                        .codeBlock(plan.copyableListCommand, copyAction: .copyCommands),
                        .button(title: t(.copyCommands), action: .copyCommands),
                        refresh, close]
            case .claudeMissing, .claudeVersionTooOld, .inboxNotReady:
                var result: [ModPanelItem] = [.hero(symbol: "exclamationmark.triangle.fill", title: t(.failureTitle), subtitle: nil),
                    .text(sync.statusText), .codeBlock(plan.copyableCommands, copyAction: .copyCommands),
                    .button(title: t(.copyCommands), action: .copyCommands), refresh]
                if sync.status == .inboxNotReady { result.append(.button(title: t(.retry), action: .install)) }
                return result + [close]
            case .silent:
                return [.hero(symbol: "exclamationmark.triangle.fill", title: t(.silentTitle), subtitle: sync.statusText),
                        .text("•  " + t(.silentCheckVersion)), .text("•  " + t(.silentCheckSession)),
                        .text("•  " + t(.silentCheckPolicy)),
                        .codeBlock(ModInstallPlan.reloadCommand, copyAction: .copyReload),
                        .button(title: t(.copyCommands), action: .copyReload), uninstall, refresh, close]
            case .disabled:
                return [.hero(symbol: nil, title: t(.manageTitle), subtitle: sync.statusText),
                        .codeBlock(plan.copyableEnableCommand, copyAction: .copyEnable),
                        .button(title: t(.copyEnableCommands), action: .copyEnable),
                        .text(t(.reloadHint)), .codeBlock(ModInstallPlan.reloadCommand, copyAction: .copyReload),
                        .text(t(.removeNote)), uninstall, refresh, close]
            case let .snapshotRejected(event):
                return [.hero(symbol: "exclamationmark.triangle.fill", title: t(.manageTitle), subtitle: sync.statusText),
                        .text(t(event.rejection == .accountMismatch ? .accountAdvice : .cycleAdvice))]
                    + reloadAdvice() + [uninstall, refresh, close]
            case .waitingForData, .active:
                return [.hero(symbol: nil, title: t(.manageTitle), subtitle: sync.statusText)]
                    + reloadAdvice() + [.text(t(.removeNote)), uninstall, close]
            }
        case let .installing(current):
            return [.hero(symbol: nil, title: t(.pitchTitle), subtitle: nil)]
                + steps([t(.step1), t(.step2), t(.waitingStep)], current: current.rawValue) + [close]
        case .succeeded:
            // Only the current coordinator's accepted snapshot can show the green hero.
            if case .active = sync.status {
                return [.hero(symbol: "checkmark.circle.fill", title: t(.enabled), subtitle: sync.statusText), close]
            }
            return [.hero(symbol: nil, title: t(.pitchTitle), subtitle: nil),
                    .step(label: t(.step1), status: .done), .step(label: t(.step2), status: .done),
                    .step(label: t(.waitingStep), status: .running), .text(sync.statusText)]
                + reloadAdvice() + (isInstalled(sync.status) ? [uninstall, close] : [refresh, close])
        case let .failed(failure):
            let reason: ModOnboardingText
            var detail = ""
            switch failure {
            case .claudeNotFound: reason = .failureClaudeMissing
            case .inboxNotReady: reason = .failureInbox
            case let .commandFailed(_, _, message): reason = .failureCommandFailed; detail = message
            }
            var result: [ModPanelItem] = [.hero(symbol: "exclamationmark.triangle.fill", title: t(.failureTitle), subtitle: nil),
                                         .text(t(reason))]
            if !detail.isEmpty { result.append(.detail(detail.split(whereSeparator: \.isNewline).prefix(2).joined(separator: "\n"))) }
            return result + [.codeBlock(plan.copyableCommands, copyAction: .copyCommands),
                             .button(title: t(.copyCommands), action: .copyCommands),
                             .button(title: t(.retry), action: .install), close]
        case let .uninstalling(current):
            return [.hero(symbol: nil, title: t(.manageTitle), subtitle: t(.uninstallButton))]
                + steps([t(.uninstallStep1), t(.uninstallStep2), t(.step3)], current: current.rawValue) + [close]
        case .uninstallSucceeded:
            return [.hero(symbol: "checkmark.circle.fill", title: t(.uninstalledTitle), subtitle: t(.uninstallDoneNote)),
                    .codeBlock(ModInstallPlan.reloadCommand, copyAction: .copyReload), close]
        case let .uninstallFailed(failure):
            var result: [ModPanelItem] = [.hero(symbol: "exclamationmark.triangle.fill", title: t(.uninstallFailureTitle), subtitle: nil),
                .text(t(failure == .claudeNotFound ? .failureClaudeMissing : .failureUninstall))]
            if case let .commandFailed(_, _, detail) = failure, !detail.isEmpty {
                result.append(.detail(detail.split(whereSeparator: \.isNewline).prefix(2).joined(separator: "\n")))
            }
            return result + [.codeBlock(plan.copyableUninstallCommands, copyAction: .copyUninstall),
                             .button(title: t(.copyCommands), action: .copyUninstall),
                             .button(title: t(.retry), action: .uninstall), close]
        case .dismissConfirmed:
            return [.hero(symbol: nil, title: t(.dismissedTitle), subtitle: t(.dismissedNote)),
                    .button(title: t(.undoDismiss), action: .undoDismiss), close]
        }
    }


}

/// Menu prompt row: the INT-2 accent-tinted block with a bolt icon, the main copy and
/// the "why" line. It sits in a menu item's custom view; a click anywhere closes the
/// menu and opens the explanation panel.
final class ModPromptRowView: NSView {
    /// Height for a one-line prompt; longer wording grows the row (see `height`).
    static let rowHeight: CGFloat = 52
    /// The row is exactly as wide as the quota card, whatever the language.
    static let width: CGFloat = OpenCodexCardLayout.cardWidth
    static let maximumMainLines = 2
    static let contentPadding: CGFloat = 10
    static let blockInset: CGFloat = OpenCodexCardLayout.horizontalInset

    private let block = NSView()
    let iconView = NSImageView()
    private let mainLabel: NSTextField
    private let whyLabel: NSTextField
    /// The row's height: one line of copy fits `rowHeight`; more lines add their height.
    private(set) var height: CGFloat = ModPromptRowView.rowHeight
    private(set) var isHovering = false { didSet { updateBackground() } }
    var onClick: () -> Void = {}

    var mainText: String { mainLabel.stringValue }
    var whyText: String { whyLabel.stringValue }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: height) }

    private static let iconWidth: CGFloat = 15
    private static let iconTextSpacing: CGFloat = 10
    private static var textWidth: CGFloat {
        width - 2 * blockInset - 2 * contentPadding - iconWidth - iconTextSpacing
    }

    init(localize: (ModOnboardingText) -> String = ModOnboardingText.defaultLocalize) {
        mainLabel = NSTextField(wrappingLabelWithString: localize(.promptMenu))
        whyLabel = NSTextField(labelWithString: localize(.promptWhy))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight))
        autoresizingMask = [.width]
        setAccessibilityRole(.button)
        setAccessibilityLabel(mainLabel.stringValue + ", " + whyLabel.stringValue)

        block.wantsLayer = true
        block.layer?.cornerRadius = 8
        block.translatesAutoresizingMaskIntoConstraints = false
        addSubview(block)

        iconView.image = Self.symbol("bolt.fill", size: 15)
        iconView.contentTintColor = .controlAccentColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        mainLabel.font = .systemFont(ofSize: 13, weight: .medium)
        mainLabel.textColor = .controlAccentColor
        mainLabel.lineBreakMode = .byWordWrapping
        mainLabel.cell?.truncatesLastVisibleLine = true
        mainLabel.maximumNumberOfLines = Self.maximumMainLines
        mainLabel.preferredMaxLayoutWidth = Self.textWidth
        mainLabel.isSelectable = false

        whyLabel.font = .systemFont(ofSize: 11)
        whyLabel.textColor = .controlAccentColor
        whyLabel.lineBreakMode = .byTruncatingTail
        whyLabel.preferredMaxLayoutWidth = Self.textWidth

        // Size the row to the wording (other languages are longer than Chinese).
        let mainHeight = mainLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.textWidth, height: .greatestFiniteMagnitude)).height ?? 16
        let whyHeight = whyLabel.cell?.cellSize.height ?? 14
        height = max(Self.rowHeight, ceil(mainHeight + 1 + whyHeight) + 20)
        setFrameSize(NSSize(width: Self.width, height: height))

        let texts = NSStackView(views: [mainLabel, whyLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.setContentHuggingPriority(.init(1), for: .horizontal)
        mainLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        whyLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [iconView, texts])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Self.iconTextSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        block.addSubview(row)
        NSLayoutConstraint.activate([
            block.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.blockInset),
            block.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.blockInset),
            block.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            block.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            row.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: Self.contentPadding),
            row.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -Self.contentPadding),
            row.centerYAnchor.constraint(equalTo: block.centerYAnchor),
        ])
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// Clicking the row closes the menu before AppKit sends mouseExited, so the hover
    /// tint can survive into the next presentation. Reset it explicitly.
    func resetHoverState() { isHovering = false }

    func setHoveringForTesting(_ hovering: Bool) { isHovering = hovering }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { isHovering = false }
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        let handler = onClick
        DispatchQueue.main.async { handler() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            block.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(isHovering ? 0.20 : 0.12).cgColor
        }
    }
}

/// Native management content. The model describes visible content; this view owns
/// only layout, copy feedback and the transient uninstall confirmation.
final class ModOnboardingPanelView: NSView {
    static let fixedWidth: CGFloat = 380
    static let minimumWidth: CGFloat = 380
    static let maximumWidth: CGFloat = 640
    static let successDisplayDuration: TimeInterval = 2
    private let controller: ModOnboardingController
    private let localize: (ModOnboardingText) -> String
    private let stack = NSStackView()
    private var rebuilding = false
    private var ready = false
    private var previousSyncStatus: ModSyncStatus?
    private var successCloseWork: DispatchWorkItem?
    private(set) var isConfirmingUninstall = false
    private(set) var defaultButton: NSButton?
    var syncProvider: (() -> ModPanelSyncContext?)?
    var onRequestClose: () -> Void = {}
    var onRequestRefresh: () -> Void = {}
    /// The "don't show this in the menu" checkbox changed; refresh the status menu.
    var onPromptPreferenceChange: (() -> Void)?
    var onContentSizeChange: ((NSSize) -> Void)?
    private(set) var items: [ModPanelItem] = []
    var snapshotLines: [String] { items.map(\.snapshotLine) }
    override var isFlipped: Bool { true }
    // The scroll document owns its frame height. Do not pin the stack's bottom
    // to that old height while replacing a short page with taller content.
    override var fittingSize: NSSize { NSSize(width: bounds.width, height: stack.fittingSize.height) }
    private var contentWidth: CGFloat { max(1, bounds.width - 48) }

    static func requiredWidth(localize t: (ModOnboardingText) -> String) -> CGFloat {
        let widths = [[t(.copyCommands), t(.laterButton), t(.installButton)],
                      [t(.uninstallButton), t(.closeButton)], [t(.retry), t(.closeButton)]].map { titles in
            titles.reduce(CGFloat(0)) { total, title in
                let button = NSButton(title: title, target: nil, action: nil)
                button.bezelStyle = .push; button.controlSize = .large
                return total + button.fittingSize.width
            } + CGFloat(titles.count) * 10 + 48
        }
        let headings = [t(.pitchTitle), t(.manageTitle), t(.silentTitle), t(.failureTitle),
                        t(.uninstallFailureTitle), t(.uninstalledTitle), t(.dismissedTitle)].map {
            ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold)]).width + 52
        }
        return min(maximumWidth, max(minimumWidth, ceil((widths + headings).max() ?? minimumWidth)))
    }

    init(controller: ModOnboardingController,
         localize: @escaping (ModOnboardingText) -> String = ModOnboardingText.defaultLocalize,
         syncProvider: (() -> ModPanelSyncContext?)? = nil) {
        self.controller = controller
        self.localize = localize
        self.syncProvider = syncProvider
        super.init(frame: NSRect(x: 0, y: 0, width: Self.requiredWidth(localize: localize), height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
        controller.onChange = { [weak self] in self?.reload() }
        ready = true
        reload()
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if changed, ready, !rebuilding { reload() }
    }

    func reload() {
        let sync = syncProvider?()
        let wasWaiting: Bool
        switch previousSyncStatus {
        case .waitingForData?, .silent?: wasWaiting = true
        default: wasWaiting = false
        }
        previousSyncStatus = sync?.status
        if controller.state != .succeeded || sync.map({ if case .active = $0.status { return false }; return true }) != false {
            successCloseWork?.cancel()
            successCloseWork = nil
        }
        if isConfirmingUninstall {
            // Async detection/account updates must not leave a stale destructive action.
            if let sync = syncProvider?(), !ModPanelContent.isInstalled(sync.status) {
                isConfirmingUninstall = false
            }
        }
        let content: [ModPanelItem]
        if isConfirmingUninstall {
            content = [.hero(symbol: "exclamationmark.triangle.fill", title: localize(.confirmUninstall),
                             subtitle: localize(.uninstallDoneNote)),
                       .button(title: localize(.uninstallButton), action: .confirmUninstall),
                       .button(title: localize(.cancel), action: .cancelUninstall)]
        } else {
            content = ModPanelContent.items(for: controller.state, plan: controller.plan,
                                            localize: localize, sync: syncProvider?(),
                                            promptDismissed: controller.isPromptDismissed
                                                || controller.isDismissCheckboxChecked)
        }
        render(content)
        // The original success animation closes after two seconds, but only after
        // a real waiting -> accepted transition while this installation page is open.
        if wasWaiting, controller.state == .succeeded, case .active? = sync?.status, window?.isVisible == true {
            successCloseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.controller.state == .succeeded,
                      case .active? = self.syncProvider?()?.status, self.window?.isVisible == true else { return }
                self.onRequestClose()
            }
            successCloseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.successDisplayDuration, execute: work)
        }
    }

    /// Also used by the offline state/appearance fixtures, without running a CLI.
    func render(_ content: [ModPanelItem]) {
        guard !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }
        items = content
        defaultButton = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var buttons: [(String, ModPanelItem.ButtonAction)] = []
        for item in content {
            if case let .button(title, action) = item { buttons.append((title, action)); continue }
            let view = makeView(item)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        // Match INT-2: a single footer with secondary actions left, close/primary
        // actions right. Inline code-copy controls never get a duplicate footer row.
        let inlineActions = content.compactMap { item -> ModPanelItem.ButtonAction? in
            if case let .codeBlock(_, action) = item { return action }; return nil
        }
        let visible = buttons.filter { !inlineActions.contains($0.1) }
        let warning = content.contains { item in
            if case let .hero(symbol, _, _) = item { return symbol?.hasPrefix("exclamation") == true }; return false
        }
        let leading = visible.filter { action in
            ![.close, .cancelUninstall, .confirmUninstall].contains(action.1) && (action.1 != .install || warning)
        }
        let trailing = visible.filter { action in
            [.close, .cancelUninstall, .confirmUninstall].contains(action.1) || (action.1 == .install && !warning)
        }.sorted { $0.1 != .install && $1.1 == .install }
        let footer = makeFooter(leading: leading, trailing: trailing)
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        defaultButton = warning ? nil : allButtons.first { $0.identifier?.rawValue == "install" }
        defaultButton = defaultButton ?? allButtons.first { ["close", "cancelUninstall"].contains($0.identifier?.rawValue ?? "") }
        defaultButton?.keyEquivalent = "\r"
        window?.defaultButtonCell = defaultButton?.cell as? NSButtonCell
        stack.needsLayout = true
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        if abs(frame.height - height) > 0.5 {
            super.setFrameSize(NSSize(width: bounds.width, height: height))
        }
        layoutSubtreeIfNeeded()
        onContentSizeChange?(NSSize(width: bounds.width, height: height))
    }

    private var allButtons: [NSButton] {
        func collect(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        return stack.subviews.flatMap(collect)
    }

    private func makeFooter(leading: [(String, ModPanelItem.ButtonAction)],
                            trailing: [(String, ModPanelItem.ButtonAction)]) -> NSView {
        let left = leading.map { makeButton(title: $0.0, action: $0.1) }
        let right = trailing.map { makeButton(title: $0.0, action: $0.1) }
        func row(_ buttons: [NSButton], pushRight: Bool) -> NSStackView {
            let row = NSStackView(); row.spacing = 10; row.alignment = .centerY
            if pushRight {
                let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                row.addArrangedSubview(spacer)
            }
            buttons.forEach { row.addArrangedSubview($0) }
            return row
        }
        let needed = (left + right).reduce(CGFloat(0)) { $0 + $1.fittingSize.width + 10 }
        if needed > contentWidth {
            let column = NSStackView(); column.orientation = .vertical; column.alignment = .leading; column.spacing = 8
            for group in [right, left] where !group.isEmpty {
                let groupWidth = group.reduce(CGFloat(0)) { $0 + $1.fittingSize.width + 10 }
                let line = row(group, pushRight: true)
                if groupWidth > contentWidth { line.orientation = .vertical; line.alignment = .trailing }
                column.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
            return column
        }
        let result = row(left, pushRight: false)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        result.addArrangedSubview(spacer)
        right.forEach { result.addArrangedSubview($0) }
        return result
    }

    func perform(_ action: ModPanelItem.ButtonAction) {
        switch action {
        case .install: controller.startInstall()
        case .copyCommands: controller.copyInstallCommands()
        case .copyReload: controller.copyReloadCommand()
        case .copyUninstall: controller.copyUninstallCommands()
        case .copyEnable: controller.copyEnableCommand()
        case .undoDismiss:
            controller.setPromptEnabled(true)
            onPromptPreferenceChange?()
        case .refresh: onRequestRefresh()
        case .uninstall:
            isConfirmingUninstall = true
            reload()
        case .confirmUninstall:
            guard isConfirmingUninstall else { return }
            isConfirmingUninstall = false
            controller.startUninstall()
        case .cancelUninstall:
            isConfirmingUninstall = false
            reload()
        case .close:
            isConfirmingUninstall = false
            if controller.close() {
                onRequestClose()
            } else {
                // "Later" with "don't show in the menu" checked turns into the
                // confirmation page that points back to Advanced.
                onPromptPreferenceChange?()
                reload()
            }
        }
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, width: CGFloat? = nil) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.preferredMaxLayoutWidth = width ?? contentWidth
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.isSelectable = false
        return field
    }

    private func symbol(_ name: String, color: NSColor, size: CGFloat = 20, box: CGFloat = 30) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: box), icon.heightAnchor.constraint(equalToConstant: box)])
        icon.setAccessibilityElement(false)
        return icon
    }

    private func makeView(_ item: ModPanelItem) -> NSView {
        switch item {
        case let .hero(name, text, subtitle):
            let icon: NSView
            if let name {
                icon = symbol(name, color: name.hasPrefix("exclamation") ? .systemOrange : .systemGreen, size: 44, box: 56)
            } else {
                let image = NSImageView(image: NSApp.applicationIconImage)
                image.imageScaling = .scaleProportionallyUpOrDown
                NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 56), image.heightAnchor.constraint(equalToConstant: 56)])
                image.setAccessibilityElement(false)
                icon = image
            }
            let title = label(text, size: 17, weight: .semibold); title.alignment = .center
            let hero = NSStackView(views: [icon, title]); hero.orientation = .vertical; hero.alignment = .centerX; hero.spacing = 8
            hero.setCustomSpacing(10, after: icon)
            title.widthAnchor.constraint(equalTo: hero.widthAnchor).isActive = true
            if let subtitle {
                let field = label(subtitle, size: 13, color: .secondaryLabelColor); field.alignment = .center
                hero.addArrangedSubview(field)
                field.widthAnchor.constraint(equalTo: hero.widthAnchor).isActive = true
            }
            return hero
        case let .codeBlock(text, action): return makeCodeBlock(text, action: action)
        case let .detail(text):
            let field = label(text, size: 11, color: .secondaryLabelColor)
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular); field.isSelectable = true
            return field
        case let .title(text):
            let image = NSImageView(image: NSApp.applicationIconImage)
            image.imageScaling = .scaleProportionallyUpOrDown
            NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 56), image.heightAnchor.constraint(equalToConstant: 56)])
            image.setAccessibilityElement(false)
            let title = label(text, size: 20, weight: .semibold)
            title.alignment = .center
            let subtitle = label(localize(.subtitle), color: .secondaryLabelColor)
            subtitle.alignment = .center
            let hero = NSStackView(views: [image, title, subtitle])
            hero.orientation = .vertical; hero.alignment = .centerX; hero.spacing = 8
            for field in [title, subtitle] { field.widthAnchor.constraint(equalTo: hero.widthAnchor).isActive = true }
            return hero
        case let .text(text): return label(text, color: .secondaryLabelColor)
        case let .feature(name, title, detail):
            let column = NSStackView(views: [label(title, weight: .semibold, width: contentWidth - 42),
                                           label(detail, size: 12, color: .secondaryLabelColor, width: contentWidth - 42)])
            column.orientation = .vertical; column.alignment = .leading; column.spacing = 2
            let row = NSStackView(views: [symbol(name, color: .controlAccentColor), column])
            row.alignment = .centerY; row.spacing = 12
            column.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -42).isActive = true
            for field in column.arrangedSubviews { field.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            return row
        case let .step(text, status):
            let indicator: NSView
            if status == .running {
                let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small
                spinner.startAnimation(nil)
                indicator = spinner
                indicator.widthAnchor.constraint(equalToConstant: 18).isActive = true
            } else {
                indicator = symbol(status == .done ? "checkmark.circle.fill" : "circle",
                                   color: status == .done ? .systemGreen : .tertiaryLabelColor, size: 16, box: 18)
            }
            let field = label(text, weight: status == .running ? .semibold : .regular,
                              color: status == .pending ? .secondaryLabelColor : .labelColor, width: contentWidth - 42)
            let row = NSStackView(views: [indicator, field]); row.spacing = 10; row.alignment = .centerY
            row.setAccessibilityLabel(item.snapshotLine)
            return row
        case let .code(text):
            let field = label(text, size: 11)
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isSelectable = true
            field.lineBreakMode = .byCharWrapping
            field.preferredMaxLayoutWidth = contentWidth - 24
            return surface(field, color: .quaternaryLabelColor, padding: NSSize(width: 12, height: 10))
        case let .checkbox(title, checked):
            let box = FirstMouseButton(checkboxWithTitle: title, target: self, action: #selector(checkboxToggled(_:)))
            box.state = checked ? .on : .off
            return box
        case let .menuPromptCheckbox(title, checked):
            let box = FirstMouseButton(checkboxWithTitle: title, target: self, action: #selector(menuPromptToggled(_:)))
            box.state = checked ? .on : .off
            box.setAccessibilityLabel(title)
            return box
        case let .button(title, action): return makeButton(title: title, action: action)
        }
    }

    private func makeCodeBlock(_ text: String, action: ModPanelItem.ButtonAction) -> NSView {
        let code = label(text, size: 11, width: contentWidth - 44)
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        code.isSelectable = true; code.lineBreakMode = .byCharWrapping
        let copy = ModCopyButton(toolTip: localize(.copyCommands))
        copy.target = self; copy.action = #selector(buttonPressed(_:))
        copy.identifier = NSUserInterfaceItemIdentifier(String(describing: action))
        let box = ModSurfaceView(color: .quaternarySystemFill, radius: 6)
        code.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(code); box.addSubview(copy)
        NSLayoutConstraint.activate([
            code.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            code.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            code.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            code.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -6),
            copy.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            copy.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
        ])
        return box
    }

    private func surface(_ content: NSView, color: NSColor, padding: NSSize) -> NSView {
        let box = ModSurfaceView(color: color)
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding.width),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding.width),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: padding.height),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -padding.height),
        ])
        return box
    }

    private func makeButton(title: String, action: ModPanelItem.ButtonAction) -> NSButton {
        let button = FirstMouseButton(title: title, target: self, action: #selector(buttonPressed(_:)))
        button.bezelStyle = .push
        button.controlSize = .large
        button.identifier = NSUserInterfaceItemIdentifier(String(describing: action))
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setAccessibilityLabel(title)
        if [.uninstall, .confirmUninstall].contains(action) { button.hasDestructiveAction = true }
        return button
    }
    @objc private func checkboxToggled(_ sender: NSButton) { controller.setDismissChecked(sender.state == .on) }

    @objc private func menuPromptToggled(_ sender: NSButton) {
        // INT-2 timing: checking only marks the box. The menu prompt is hidden when the
        // user leaves with "Later", which also shows the confirmation page.
        let dismissed = sender.state == .on
        controller.setDismissChecked(dismissed)
        sender.state = dismissed ? .on : .off
        sender.needsDisplay = true
        if !dismissed {
            // Re-enabling is immediate so a previously hidden prompt comes back at once.
            controller.setPromptEnabled(true)
            onPromptPreferenceChange?()
        }
    }
    @objc private func buttonPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let action = [ModPanelItem.ButtonAction.install, .close, .copyCommands, .copyReload, .undoDismiss,
                            .uninstall, .copyUninstall, .copyEnable, .refresh, .confirmUninstall, .cancelUninstall]
                .first(where: { String(describing: $0) == id }) else { return }
        perform(action)
        if [.copyCommands, .copyReload, .copyUninstall, .copyEnable].contains(action) {
            if let copy = sender as? ModCopyButton { copy.flashCopied(); return }
            let title = sender.title
            sender.title = localize(.copied)
            NSAccessibility.post(element: sender, notification: .valueChanged)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in sender?.title = title }
        }
    }
}

final class ModCopyButton: NSButton {
    static let side: CGFloat = 22
    private var isHovering = false { didSet { updateFill() } }
    private var isPressed = false { didSet { updateFill() } }
    private var feedback: DispatchWorkItem?
    private let idleImage = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
    private let doneImage = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))

    /// `true` while the check mark is showing.
    private(set) var isShowingFeedback = false

    init(toolTip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        image = idleImage
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        isBordered = false
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 5
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.side).isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
        updateFill()
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A plain NSButton pads its frame beyond the aligned rect, which made the 22x22 constraints a taller frame.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)   // tracks until the button is released
        isPressed = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    /// Shows the check mark for 1.2 s.
    func flashCopied() {
        feedback?.cancel()
        isShowingFeedback = true
        image = doneImage
        contentTintColor = .systemGreen
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowingFeedback = false
            self.image = self.idleImage
            self.contentTintColor = .secondaryLabelColor
        }
        feedback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let alpha: CGFloat = isPressed ? 0.16 : isHovering ? 0.09 : 0
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }
}

private final class ModSurfaceView: NSView {
    private let color: NSColor
    private let radius: CGFloat
    init(color: NSColor, radius: CGFloat = 12) { self.color = color; self.radius = radius; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// A nonactivating panel's first click normally only makes the window key. Controls in
/// the Mod panel must act on that first click.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ModManagementPanel: NSPanel {
    weak var managementView: ModOnboardingPanelView?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { managementView?.perform(.close) }

    /// A floating panel can be frontmost without being key. Make it key before the
    /// click is dispatched so the control under the pointer acts on the first press.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

/// One reusable window. Normally a child of the settings window (no app activation or
/// floating level); the status-menu prompt shows it standalone so the dashboard never
/// rises with it. Closing never cancels the shared background task.
final class ModOnboardingWindowController: NSObject, NSWindowDelegate {
    private let makeView: () -> ModOnboardingPanelView
    private(set) var panelView: ModOnboardingPanelView?
    private(set) var window: NSPanel?
    private weak var owner: NSWindow?
    private var ownerCloseObserver: NSObjectProtocol?

    init(makeView: @escaping () -> ModOnboardingPanelView) { self.makeView = makeView }
    deinit {
        if let ownerCloseObserver { NotificationCenter.default.removeObserver(ownerCloseObserver) }
        if let window { owner?.removeChildWindow(window) }
        window?.orderOut(nil)
    }

    @discardableResult
    func prepare(owner: NSWindow?) -> NSPanel {
        close()
        self.owner = owner
        let panel = window as? ModManagementPanel ?? ModManagementPanel(
            contentRect: NSRect(x: 0, y: 0, width: ModOnboardingPanelView.fixedWidth, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Claude Code Mod"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        if let owner {
            panel.styleMask.remove(.nonactivatingPanel)
            panel.isFloatingPanel = false
            panel.level = .normal
        } else {
            // Standalone prompt: take the keyboard and stay above other apps without
            // activating BalanceBar, so the dashboard never rises with the panel.
            panel.styleMask.insert(.nonactivatingPanel)
            panel.isFloatingPanel = true
            panel.level = .floating
        }
        panel.minSize = NSSize(width: ModOnboardingPanelView.minimumWidth, height: 220)
        panel.delegate = self
        window = panel
        let view = makeView()
        panel.minSize = NSSize(width: view.frame.width, height: 220)
        panel.setContentSize(NSSize(width: view.frame.width, height: 400))
        panelView = view
        panel.managementView = view
        view.onRequestClose = { [weak self] in self?.close() }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // The window is sized to its content; without this a page that fits still
        // rubber-bands under the pointer, which reads as a broken scroll area.
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.documentView = view
        panel.contentView = scroll
        view.autoresizingMask = [.width]
        view.setFrameSize(NSSize(width: scroll.contentSize.width, height: view.fittingSize.height))
        view.onContentSizeChange = { [weak self] size in self?.fitInitialContent(size) }
        fitInitialContent(view.frame.size)
        panel.defaultButtonCell = view.defaultButton?.cell as? NSButtonCell
        if let owner {
            ownerCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: owner, queue: .main
            ) { [weak self] _ in self?.close() }
        }
        ApplicationWindowPresentation.prepare(panel)
        return panel
    }

    /// Opens the panel on its own, with no dashboard owner. The status-menu prompt uses
    /// this so clicking the reminder never raises the main window.
    func show() {
        if window?.isVisible == true, owner == nil {
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
            return
        }
        let panel = prepare(owner: nil)
        panel.center()
        if AutomatedTestHost.isRunning {
            ApplicationWindowPresentation.presentInBackground(panel)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    func show(owner: NSWindow) {
        if window?.isVisible == true, self.owner === owner { return }
        let panel = prepare(owner: owner)
        let frame = owner.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        owner.addChildWindow(panel, ordered: .above)
        if AutomatedTestHost.isRunning {
            ApplicationWindowPresentation.presentInBackground(panel)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        if let ownerCloseObserver { NotificationCenter.default.removeObserver(ownerCloseObserver) }
        ownerCloseObserver = nil
        if let window { owner?.removeChildWindow(window); window.orderOut(nil) }
        owner = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }

    private func fitInitialContent(_ size: NSSize) {
        guard let window else { return }
        let limit = (owner?.screen?.visibleFrame.height ?? 900) - 120
        let contentSize = NSSize(width: window.contentView?.bounds.width ?? size.width,
                                 height: min(max(size.height, 220), limit))
        let old = window.frame
        guard abs((window.contentView?.bounds.height ?? 0) - contentSize.height) > 0.5 else { return }
        window.setContentSize(contentSize)
        window.setFrameOrigin(NSPoint(x: old.minX, y: old.maxY - window.frame.height))
    }
}
