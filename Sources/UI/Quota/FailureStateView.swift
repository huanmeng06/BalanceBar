import AppKit

/// Level-6 fallback: one-sentence reason plus one recovery button. Most failures open the
/// client's official usage page; a signed-out client copies its sign-in command instead
/// (`claude` or `codex login`), and a failure the card cannot fix (an unreadable keychain)
/// shows the reason alone.
final class FailureStateView: NSView {
    static let officialUsageURL = URL(string: "https://claude.ai/settings/usage")!
    static let signInCommand = "claude"
    static let codexUsageURL = URL(string: "https://chatgpt.com/codex/settings/usage")!
    static let codexSignInCommand = "codex login"

    /// The client's official usage page; Codex never opens claude.ai.
    static func usageURL(for client: AssistantClient) -> URL {
        client == .codex ? codexUsageURL : officialUsageURL
    }

    /// The terminal command that signs the client in again.
    static func signInCommand(for client: AssistantClient) -> String {
        client == .codex ? codexSignInCommand : signInCommand
    }
    /// Horizontal text inset of a frame-placed `NSTextField` label.
    static let labelTextInset: CGFloat = 2

    typealias Action = FailureRecovery

    private let reasonLabel = NSTextField(wrappingLabelWithString: "")
    let actionButton: NSButton
    let action: Action
    let client: AssistantClient
    private let localize: (StatusSlotText) -> String
    private let onOpenUsagePage: () -> Void
    private let onOpenEgressGuardSettings: () -> Void
    private let copyToPasteboard: (String) -> Void

    var reasonForTesting: String { reasonLabel.stringValue }
    /// Kept for existing callers and tests that address the button by its original role.
    var openUsageButton: NSButton { actionButton }

    /// - Parameters:
    ///   - reason: Already-localized one-sentence failure reason.
    ///   - action: Which recovery button to show.
    ///   - client: Whose command is copied and whose usage page opens.
    ///   - font: Font of the reason; callers that pre-measure the height must pass the font they measured with.
    ///   - onOpenUsagePage: Called for `.openUsagePage`; defaults to opening the client's usage page.
    ///   - copyToPasteboard: Called for `.copySignInCommand`; defaults to the general pasteboard.
    ///   - onOpenEgressGuardSettings: Called for `.openEgressGuardSettings`.
    init(
        reason: String,
        action: Action = .openUsagePage,
        client: AssistantClient = .claude,
        font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize),
        localize: @escaping (StatusSlotText) -> String = StatusSlotText.defaultLocalize,
        onOpenUsagePage: (() -> Void)? = nil,
        copyToPasteboard: @escaping (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        },
        onOpenEgressGuardSettings: @escaping () -> Void = {}
    ) {
        self.action = action
        self.client = client
        self.localize = localize
        self.onOpenUsagePage = onOpenUsagePage ?? { NSWorkspace.shared.open(FailureStateView.usageURL(for: client)) }
        self.onOpenEgressGuardSettings = onOpenEgressGuardSettings
        self.copyToPasteboard = copyToPasteboard
        let title: String
        switch action {
        case .copySignInCommand: title = localize(client == .codex ? .copyCodexLoginCommand : .copySignInCommand)
        case .openEgressGuardSettings: title = localize(.openEgressGuardSettings)
        case .openUsagePage, .none: title = localize(.openUsagePage)
        }
        actionButton = NSButton(title: title, target: nil, action: nil)
        super.init(frame: .zero)
        reasonLabel.font = font
        reasonLabel.textColor = .secondaryLabelColor
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.setAccessibilityLabel(title)

        let stack = NSStackView(views: action == .none ? [reasonLabel] : [reasonLabel, actionButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // The stack aligns alignment rects, which drop a text field's ~2pt cell inset; frame-placed
            // labels above keep it, so shift the stack to put glyphs on the same left edge.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelTextInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        update(reason: reason)
    }

    required init?(coder: NSCoder) { nil }

    func update(reason: String) {
        reasonLabel.stringValue = reason
        reasonLabel.setAccessibilityLabel(reason)
    }

    @objc private func performAction() {
        switch action {
        case .openUsagePage:
            onOpenUsagePage()
        case .copySignInCommand:
            copyToPasteboard(Self.signInCommand(for: client))
            actionButton.title = localize(.copied)
        case .openEgressGuardSettings:
            onOpenEgressGuardSettings()
        case .none:
            break
        }
    }
}
