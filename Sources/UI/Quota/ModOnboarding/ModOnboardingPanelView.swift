import AppKit

/// One visible element of the panel; the view renders exactly this list, and tests snapshot it.
enum ModPanelItem: Equatable {
    case title(String)
    case text(String)
    case feature(symbol: String, title: String, detail: String)
    case notice(symbol: String, text: String, tone: Tone)

    enum Tone: Equatable { case neutral, success, warning }
    case step(label: String, status: StepStatus)
    case code(String)
    case checkbox(title: String, checked: Bool)
    case button(title: String, action: ButtonAction)

    enum StepStatus: String, Equatable { case pending, running, done }
    enum ButtonAction: Equatable { case install, close, copyCommands, copyReload, undoDismiss, uninstall, copyUninstall, copyEnable, refresh, confirmUninstall, cancelUninstall }

    var snapshotLine: String {
        switch self {
        case let .title(t): return "# \(t)"
        case let .text(t): return t
        case let .feature(symbol, title, detail): return "[\(symbol)] \(title): \(detail)"
        case let .notice(_, text, _): return text
        case let .step(label, status):
            let mark = status == .done ? "[x]" : status == .running ? "[~]" : "[ ]"
            return "\(mark) \(label)"
        case let .code(c): return "$ " + c.replacingOccurrences(of: "\n", with: "\n$ ")
        case let .checkbox(title, checked): return "(\(checked ? "x" : " ")) \(title)"
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
        case .detecting, .claudeMissing, .claudeVersionTooOld, .inboxNotReady, .notInstalled: return false
        }
    }

    static func items(
        for state: ModPanelState,
        plan: ModInstallPlan,
        localize: (ModOnboardingText) -> String,
        sync: ModPanelSyncContext? = nil
    ) -> [ModPanelItem] {
        let t = localize
        if let sync { return managementItems(for: state, plan: plan, localize: t, sync: sync) }
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
        localize t: (ModOnboardingText) -> String, sync: ModPanelSyncContext
    ) -> [ModPanelItem] {
        let close = ModPanelItem.button(title: t(.closeButton), action: .close)
        let refresh = ModPanelItem.button(title: t(.refresh), action: .refresh)
        func steps(_ labels: [String], current: Int) -> [ModPanelItem] {
            labels.enumerated().map { index, label in
                .step(label: label, status: index < current ? .done : index == current ? .running : .pending)
            }
        }
        func reloadAdvice() -> [ModPanelItem] {
            [.text(t(.enabledNote)), .text(t(.reloadHint)), .code(ModInstallPlan.reloadCommand),
             .button(title: t(.copyCommands), action: .copyReload)]
        }
        switch state {
        case .intro:
            var result: [ModPanelItem] = [.title("Claude Code Mod"),
                .notice(symbol: symbol(for: sync.status), text: sync.statusText, tone: tone(for: sync.status)),
                .feature(symbol: "bolt.fill", title: t(.benefitRealtime), detail: t(.point1)),
                .feature(symbol: "terminal", title: "CLI · Desktop Code", detail: t(.coverageNote)),
                .feature(symbol: "checkmark.shield", title: t(.benefitFallback), detail: t(.fallbackNote)),
                .feature(symbol: "lock.shield", title: t(.benefitPrivacy), detail: t(.point3))]
            switch sync.status {
            case .detecting: break
            case .claudeMissing, .claudeVersionTooOld:
                result += [refresh, .code(plan.copyableCommands), .button(title: t(.copyCommands), action: .copyCommands)]
            case .inboxNotReady, .notInstalled:
                result += [.button(title: t(.copyCommands), action: .copyCommands),
                           .button(title: t(.installButton), action: .install), refresh]
            case .disabled:
                result += [.code(plan.copyableEnableCommand), .button(title: t(.copyEnableCommands), action: .copyEnable), refresh]
            case .waitingForData, .silent:
                result += reloadAdvice() + [refresh]
            case let .snapshotRejected(event):
                result += [.text(t(event.rejection == .accountMismatch ? .accountAdvice : .cycleAdvice))]
                    + reloadAdvice() + [refresh]
            case .active: break
            }
            if isInstalled(sync.status) {
                result.append(.button(title: t(.uninstallButton), action: .uninstall))
            }
            return result + [close]
        case let .installing(current):
            return [.title(t(.installButton))]
                + steps([t(.step1), t(.step2), t(.waitingStep)], current: current.rawValue)
                + [.text(t(.backgroundNote)), close]
        case .succeeded:
            // Command success never implies trusted data. The coordinator is the only
            // authority that can provide an active status after snapshot acceptance.
            let status = sync.status
            let text = status == .waitingForData ? t(.waitingTitle) : sync.statusText
            let active: Bool
            if case .active = status { active = true } else { active = false }
            return [.title("Claude Code Mod"), .notice(symbol: symbol(for: status), text: text, tone: tone(for: status)),
                    .step(label: t(.step1), status: .done), .step(label: t(.step2), status: .done),
                    .step(label: t(.waitingStep), status: active ? .done : .pending)]
                + reloadAdvice() + [refresh, close]
        case let .failed(failure):
            let reason: ModOnboardingText
            var detail = ""
            switch failure {
            case .claudeNotFound: reason = .failureClaudeMissing
            case .inboxNotReady: reason = .failureInbox
            case let .commandFailed(_, _, message): reason = .failureCommandFailed; detail = message
            }
            var result: [ModPanelItem] = [.title(t(.failureTitle)),
                .notice(symbol: "exclamationmark.triangle.fill", text: t(reason), tone: .warning)]
            if !detail.isEmpty { result.append(.code(String(detail.prefix(200)))) }
            return result + [.code(plan.copyableCommands), .button(title: t(.copyCommands), action: .copyCommands),
                             .button(title: t(.retry), action: .install), close]
        case let .uninstalling(current):
            return [.title(t(.uninstallButton))]
                + steps([t(.uninstallStep1), t(.uninstallStep2), t(.step3)], current: current.rawValue)
                + [.text(t(.backgroundNote)), close]
        case .uninstallSucceeded:
            return [.title(t(.uninstallDone)),
                    .notice(symbol: "checkmark.circle.fill", text: t(.uninstallDoneNote), tone: .success), close]
        case let .uninstallFailed(failure):
            var result: [ModPanelItem] = [.title(t(.uninstallFailureTitle)),
                .notice(symbol: "exclamationmark.triangle.fill",
                        text: t(failure == .claudeNotFound ? .failureClaudeMissing : .failureUninstall), tone: .warning)]
            if case let .commandFailed(_, _, detail) = failure, !detail.isEmpty {
                result.append(.code(String(detail.prefix(200))))
            }
            return result + [.code(plan.copyableUninstallCommands), .button(title: t(.copyCommands), action: .copyUninstall),
                             .button(title: t(.retry), action: .uninstall), close]
        case .dismissConfirmed:
            return [.title(t(.dismissedTitle)), .text(t(.dismissedNote)), close]
        }
    }

    static func symbol(for status: ModSyncStatus) -> String {
        switch status {
        case .active: return "checkmark.circle.fill"
        case .detecting: return "magnifyingglass"
        case .notInstalled: return "arrow.down.circle"
        case .waitingForData: return "clock"
        default: return "exclamationmark.triangle.fill"
        }
    }

    static func tone(for status: ModSyncStatus) -> ModPanelItem.Tone {
        switch status {
        case .active: return .success
        case .detecting, .notInstalled, .waitingForData: return .neutral
        default: return .warning
        }
    }

}

/// Menu prompt row. Plain button so it can sit in a menu item's custom view.
final class ModPromptRowView: NSView {
    let button: NSButton
    var onClick: () -> Void = {}

    init(localize: (ModOnboardingText) -> String = ModOnboardingText.defaultLocalize) {
        button = NSButton(title: localize(.promptRow), target: nil, action: nil)
        super.init(frame: .zero)
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.contentTintColor = .controlAccentColor
        button.target = self
        button.action = #selector(clicked)
        button.setAccessibilityLabel(localize(.promptRow))
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func clicked() { onClick() }
}

/// Native management content. The model describes visible content; this view owns
/// only layout, copy feedback and the transient uninstall confirmation.
final class ModOnboardingPanelView: NSView {
    static let fixedWidth: CGFloat = 480
    static let minimumWidth: CGFloat = 420
    private let controller: ModOnboardingController
    private let localize: (ModOnboardingText) -> String
    private let stack = NSStackView()
    private var rebuilding = false
    private var ready = false
    private(set) var isConfirmingUninstall = false
    private(set) var defaultButton: NSButton?
    var syncProvider: (() -> ModPanelSyncContext?)?
    var onRequestClose: () -> Void = {}
    var onRequestRefresh: () -> Void = {}
    var onContentSizeChange: ((NSSize) -> Void)?
    private(set) var items: [ModPanelItem] = []
    var snapshotLines: [String] { items.map(\.snapshotLine) }
    override var isFlipped: Bool { true }
    private var contentWidth: CGFloat { max(1, bounds.width - 48) }

    init(controller: ModOnboardingController,
         localize: @escaping (ModOnboardingText) -> String = ModOnboardingText.defaultLocalize,
         syncProvider: (() -> ModPanelSyncContext?)? = nil) {
        self.controller = controller
        self.localize = localize
        self.syncProvider = syncProvider
        super.init(frame: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        if isConfirmingUninstall {
            // Async detection/account updates must not leave a stale destructive action.
            if let sync = syncProvider?(), !ModPanelContent.isInstalled(sync.status) {
                isConfirmingUninstall = false
            }
        }
        let content: [ModPanelItem]
        if isConfirmingUninstall {
            content = [.title(localize(.confirmUninstall)),
                       .notice(symbol: "trash", text: localize(.uninstallDoneNote), tone: .warning),
                       .button(title: localize(.uninstallButton), action: .confirmUninstall),
                       .button(title: localize(.cancel), action: .cancelUninstall)]
        } else {
            content = ModPanelContent.items(for: controller.state, plan: controller.plan,
                                            localize: localize, sync: syncProvider?())
        }
        render(content)
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
        let divider = NSBox(); divider.boxType = .separator
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        // Commands are in a separate row. Footer falls back to vertical at narrow widths
        // or for long translations; no button title is truncated.
        let utilities = buttons.filter { Self.isUtility($0.1) }
        let actions = buttons.filter { !Self.isUtility($0.1) }
        for group in [utilities, actions] where !group.isEmpty {
            let controls = group.map { makeButton(title: $0.0, action: $0.1) }
            let needed = controls.reduce(CGFloat(0)) { $0 + $1.fittingSize.width + 10 }
            let row = NSStackView(views: controls)
            row.orientation = needed > contentWidth ? .vertical : .horizontal
            row.alignment = row.orientation == .vertical ? .trailing : .centerY
            row.distribution = .fill
            row.spacing = 10
            if row.orientation == .horizontal {
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                row.insertArrangedSubview(spacer, at: 0)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        // Return installs only when that action is offered. Destructive actions never
        // become the default, including the second confirmation click.
        defaultButton = allButtons.first { $0.identifier?.rawValue == "install" }
            ?? allButtons.first { ["close", "cancelUninstall"].contains($0.identifier?.rawValue ?? "") }
        defaultButton?.keyEquivalent = "\r"
        window?.defaultButtonCell = defaultButton?.cell as? NSButtonCell
        layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        if abs(frame.height - height) > 0.5 {
            super.setFrameSize(NSSize(width: bounds.width, height: height))
        }
        onContentSizeChange?(NSSize(width: bounds.width, height: height))
    }

    private var allButtons: [NSButton] {
        func collect(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        return stack.subviews.flatMap(collect)
    }

    private static func isUtility(_ action: ModPanelItem.ButtonAction) -> Bool {
        [.copyCommands, .copyReload, .copyUninstall, .copyEnable, .refresh].contains(action)
    }

    func perform(_ action: ModPanelItem.ButtonAction) {
        switch action {
        case .install: controller.startInstall()
        case .copyCommands: controller.copyInstallCommands()
        case .copyReload: controller.copyReloadCommand()
        case .copyUninstall: controller.copyUninstallCommands()
        case .copyEnable: controller.copyEnableCommand()
        case .undoDismiss: controller.setPromptEnabled(true)
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
            if controller.close() { onRequestClose() }
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
        return field
    }

    private func symbol(_ name: String, color: NSColor, size: CGFloat = 22) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 30), icon.heightAnchor.constraint(equalToConstant: 30)])
        icon.setAccessibilityElement(false)
        return icon
    }

    private func makeView(_ item: ModPanelItem) -> NSView {
        switch item {
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
            let column = NSStackView(views: [label(title, weight: .semibold, width: contentWidth - 44),
                                           label(detail, size: 12, color: .secondaryLabelColor, width: contentWidth - 44)])
            column.orientation = .vertical; column.alignment = .leading; column.spacing = 3
            let row = NSStackView(views: [symbol(name, color: .controlAccentColor), column])
            row.alignment = .top; row.spacing = 14
            column.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -44).isActive = true
            for field in column.arrangedSubviews { field.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            return row
        case let .notice(name, text, tone):
            let color: NSColor = tone == .success ? .systemGreen : tone == .warning ? .systemOrange : .controlAccentColor
            let field = label(text, weight: .medium, width: contentWidth - 72)
            let row = NSStackView(views: [symbol(name, color: color), field]); row.spacing = 14; row.alignment = .centerY
            return surface(row, color: color.withAlphaComponent(0.08), padding: NSSize(width: 14, height: 12))
        case let .step(text, status):
            let indicator: NSView
            if status == .running {
                let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small
                spinner.startAnimation(nil)
                indicator = spinner
                indicator.widthAnchor.constraint(equalToConstant: 30).isActive = true
            } else {
                indicator = symbol(status == .done ? "checkmark.circle.fill" : "circle",
                                   color: status == .done ? .systemGreen : .tertiaryLabelColor)
            }
            let field = label(text, weight: status == .running ? .semibold : .regular,
                              color: status == .pending ? .secondaryLabelColor : .labelColor, width: contentWidth - 44)
            let row = NSStackView(views: [indicator, field]); row.spacing = 14; row.alignment = .centerY
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
            let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxToggled(_:)))
            box.state = checked ? .on : .off
            return box
        case let .button(title, action): return makeButton(title: title, action: action)
        }
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
        let button = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.identifier = NSUserInterfaceItemIdentifier(String(describing: action))
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setAccessibilityLabel(title)
        if [.uninstall, .confirmUninstall].contains(action) { button.hasDestructiveAction = true }
        return button
    }
    @objc private func checkboxToggled(_ sender: NSButton) { controller.setDismissChecked(sender.state == .on) }
    @objc private func buttonPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let action = [ModPanelItem.ButtonAction.install, .close, .copyCommands, .copyReload, .undoDismiss,
                            .uninstall, .copyUninstall, .copyEnable, .refresh, .confirmUninstall, .cancelUninstall]
                .first(where: { String(describing: $0) == id }) else { return }
        perform(action)
        if [.copyCommands, .copyReload, .copyUninstall, .copyEnable].contains(action) {
            let title = sender.title
            sender.title = localize(.copied)
            NSAccessibility.post(element: sender, notification: .valueChanged)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in sender?.title = title }
        }
    }
}

private final class ModSurfaceView: NSView {
    private let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}

private final class ModManagementPanel: NSPanel {
    weak var managementView: ModOnboardingPanelView?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { managementView?.perform(.close) }
}

/// One reusable child window, owned by the settings window. No app activation or
/// floating level; closing either window never cancels the shared background task.
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
    func prepare(owner: NSWindow) -> NSPanel {
        close()
        self.owner = owner
        let panel = window as? ModManagementPanel ?? ModManagementPanel(
            contentRect: NSRect(x: 0, y: 0, width: ModOnboardingPanelView.fixedWidth, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Claude Code Mod"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.minSize = NSSize(width: ModOnboardingPanelView.minimumWidth, height: 360)
        panel.delegate = self
        window = panel
        let view = makeView()
        panelView = view
        panel.managementView = view
        view.onRequestClose = { [weak self] in self?.close() }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = view
        panel.contentView = scroll
        view.autoresizingMask = [.width]
        view.setFrameSize(NSSize(width: scroll.contentSize.width, height: view.fittingSize.height))
        view.onContentSizeChange = { [weak self] size in self?.fitInitialContent(size) }
        fitInitialContent(view.frame.size)
        panel.defaultButtonCell = view.defaultButton?.cell as? NSButtonCell
        ownerCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: owner, queue: .main
        ) { [weak self] _ in self?.close() }
        ApplicationWindowPresentation.prepare(panel)
        return panel
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
        guard let window, !window.isVisible else { return }
        let limit = (owner?.screen?.visibleFrame.height ?? 900) - 120
        window.setContentSize(NSSize(width: window.contentView?.bounds.width ?? size.width,
                                     height: min(max(size.height, 360), limit)))
    }
}
