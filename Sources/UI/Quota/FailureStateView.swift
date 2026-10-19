import AppKit

/// Level-6 fallback: one-sentence reason plus a button that opens the official usage page.
final class FailureStateView: NSView {
    static let officialUsageURL = URL(string: "https://claude.ai/settings/usage")!

    private let reasonLabel = NSTextField(wrappingLabelWithString: "")
    let openUsageButton: NSButton
    private let onOpenUsagePage: () -> Void

    var reasonForTesting: String { reasonLabel.stringValue }

    /// - Parameters:
    ///   - reason: Already-localized one-sentence failure reason.
    ///   - onOpenUsagePage: Called when the button is pressed; defaults to opening `officialUsageURL`.
    init(
        reason: String,
        localize: (StatusSlotText) -> String = StatusSlotText.defaultLocalize,
        onOpenUsagePage: @escaping () -> Void = { NSWorkspace.shared.open(FailureStateView.officialUsageURL) }
    ) {
        self.onOpenUsagePage = onOpenUsagePage
        openUsageButton = NSButton(title: localize(.openUsagePage), target: nil, action: nil)
        super.init(frame: .zero)
        reasonLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reasonLabel.textColor = .secondaryLabelColor
        openUsageButton.bezelStyle = .rounded
        openUsageButton.controlSize = .small
        openUsageButton.target = self
        openUsageButton.action = #selector(openUsagePage)
        openUsageButton.setAccessibilityLabel(localize(.openUsagePage))

        let stack = NSStackView(views: [reasonLabel, openUsageButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(reason: reason)
    }

    required init?(coder: NSCoder) { nil }

    func update(reason: String) {
        reasonLabel.stringValue = reason
        reasonLabel.setAccessibilityLabel(reason)
    }

    @objc private func openUsagePage() { onOpenUsagePage() }
}
