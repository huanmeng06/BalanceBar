import AppKit

/// Level-6 fallback: one-sentence reason plus one recovery button. Most failures open the
/// official usage page; a signed-out Claude Code copies the `claude` command instead, and a
/// failure the card cannot fix (an unreadable keychain) shows the reason alone.
final class FailureStateView: NSView {
    static let officialUsageURL = URL(string: "https://claude.ai/settings/usage")!
    static let signInCommand = "claude"
    /// Horizontal text inset of a frame-placed `NSTextField` label.
    static let labelTextInset: CGFloat = 2

    typealias Action = FailureRecovery

    private let reasonLabel = NSTextField(wrappingLabelWithString: "")
    let actionButton: NSButton
    let action: Action
    private let localize: (StatusSlotText) -> String
    private let onOpenUsagePage: () -> Void
    private let copyToPasteboard: (String) -> Void

    var reasonForTesting: String { reasonLabel.stringValue }
    /// Kept for existing callers and tests that address the button by its original role.
    var openUsageButton: NSButton { actionButton }

    /// - Parameters:
    ///   - reason: Already-localized one-sentence failure reason.
    ///   - action: Which recovery button to show.
    ///   - font: Font of the reason; callers that pre-measure the height must pass the font they measured with.
    ///   - onOpenUsagePage: Called for `.openUsagePage`; defaults to opening `officialUsageURL`.
    ///   - copyToPasteboard: Called for `.copySignInCommand`; defaults to the general pasteboard.
    init(
        reason: String,
        action: Action = .openUsagePage,
        font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize),
        localize: @escaping (StatusSlotText) -> String = StatusSlotText.defaultLocalize,
        onOpenUsagePage: @escaping () -> Void = { NSWorkspace.shared.open(FailureStateView.officialUsageURL) },
        copyToPasteboard: @escaping (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.action = action
        self.localize = localize
        self.onOpenUsagePage = onOpenUsagePage
        self.copyToPasteboard = copyToPasteboard
        let title = action == .copySignInCommand ? localize(.copySignInCommand) : localize(.openUsagePage)
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
            copyToPasteboard(Self.signInCommand)
            actionButton.title = localize(.copied)
        case .none:
            break
        }
    }
}
