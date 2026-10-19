import AppKit

/// One visible element of the panel; the view renders exactly this list, and tests snapshot it.
enum ModPanelItem: Equatable {
    case title(String)
    case text(String)
    case step(label: String, status: StepStatus)
    case code(String)
    case checkbox(title: String, checked: Bool)
    case button(title: String, action: ButtonAction)

    enum StepStatus: String, Equatable { case pending, running, done }
    enum ButtonAction: Equatable { case install, close, copyCommands, copyReload, undoDismiss }

    var snapshotLine: String {
        switch self {
        case let .title(t): return "# \(t)"
        case let .text(t): return t
        case let .step(label, status):
            let mark = status == .done ? "[x]" : status == .running ? "[~]" : "[ ]"
            return "\(mark) \(label)"
        case let .code(c): return "$ " + c.replacingOccurrences(of: "\n", with: "\n$ ")
        case let .checkbox(title, checked): return "(\(checked ? "x" : " ")) \(title)"
        case let .button(title, _): return "<\(title)>"
        }
    }
}

enum ModPanelContent {
    static func items(
        for state: ModPanelState,
        plan: ModInstallPlan,
        localize: (ModOnboardingText) -> String
    ) -> [ModPanelItem] {
        let t = localize
        switch state {
        case let .intro(checked):
            return [
                .title(t(.panelTitle)),
                .text("• " + t(.point1)), .text("• " + t(.point2)), .text("• " + t(.point3)), .text("• " + t(.point4)),
                .checkbox(title: t(.dismissCheckbox), checked: checked),
                .button(title: t(.installButton), action: .install),
                .button(title: t(.closeButton), action: .close),
            ]
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
            let reason: ModOnboardingText = failure == .claudeNotFound ? .failureClaudeMissing : .failureCommandFailed
            return [
                .title(t(.failureTitle)), .text(t(reason)), .code(plan.copyableCommands),
                .button(title: t(.copyCommands), action: .copyCommands),
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

/// Explanation panel content: renders `ModPanelContent` for the controller's current state.
final class ModOnboardingPanelView: NSView {
    static let fixedWidth: CGFloat = 320

    private let controller: ModOnboardingController
    private let localize: (ModOnboardingText) -> String
    private let stack = NSStackView()
    var onRequestClose: () -> Void = {}

    private(set) var items: [ModPanelItem] = []
    var snapshotLines: [String] { items.map(\.snapshotLine) }

    init(controller: ModOnboardingController, localize: @escaping (ModOnboardingText) -> String = ModOnboardingText.defaultLocalize) {
        self.controller = controller
        self.localize = localize
        super.init(frame: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.fixedWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        controller.onChange = { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { nil }

    func reload() {
        items = ModPanelContent.items(for: controller.state, plan: controller.plan, localize: localize)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items { stack.addArrangedSubview(makeView(item)) }
        layoutSubtreeIfNeeded()
    }

    /// Triggers a button as if clicked (used by tests).
    func perform(_ action: ModPanelItem.ButtonAction) {
        switch action {
        case .install: controller.startInstall()
        case .copyCommands: controller.copyInstallCommands()
        case .copyReload: controller.copyReloadCommand()
        case .undoDismiss: controller.setPromptEnabled(true)
        case .close: if controller.close() { onRequestClose() }
        }
    }

    private func makeView(_ item: ModPanelItem) -> NSView {
        switch item {
        case let .title(text):
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
            return label
        case let .text(text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = Self.fixedWidth - 28
            return label
        case let .step(label, status):
            let field = NSTextField(labelWithString: item.snapshotLine)
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = status == .pending ? .tertiaryLabelColor : .labelColor
            field.setAccessibilityLabel("\(label), \(status.rawValue)")
            return field
        case let .code(text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.isSelectable = true
            label.preferredMaxLayoutWidth = Self.fixedWidth - 28
            return label
        case let .checkbox(title, checked):
            let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxToggled(_:)))
            box.state = checked ? .on : .off
            box.controlSize = .small
            return box
        case let .button(title, action):
            let button = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(Self.identifier(for: action))
            if action == .install { button.keyEquivalent = "\r" }
            return button
        }
    }

    @objc private func checkboxToggled(_ sender: NSButton) { controller.setDismissChecked(sender.state == .on) }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let action = Self.action(for: id) else { return }
        perform(action)
    }

    private static func identifier(for action: ModPanelItem.ButtonAction) -> String { String(describing: action) }
    private static func action(for id: String) -> ModPanelItem.ButtonAction? {
        [.install, .close, .copyCommands, .copyReload, .undoDismiss].first { identifier(for: $0) == id }
    }
}
