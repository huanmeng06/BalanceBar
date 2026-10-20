import AppKit

/// Read-only diagnostics content. It has no controls: nothing here changes any tool's configuration.
final class DiagnosticsView: NSView {
    static let fixedWidth: CGFloat = 460

    private let stack = NSStackView()
    private(set) var items: [DiagnosticsItem] = []
    var snapshotLines: [String] { items.map(\.snapshotLine) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
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
    }

    required init?(coder: NSCoder) { nil }

    func reload(_ items: [DiagnosticsItem]) {
        self.items = items
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items { stack.addArrangedSubview(makeView(item)) }
        layoutSubtreeIfNeeded()
    }

    private func makeView(_ item: DiagnosticsItem) -> NSView {
        let width = Self.fixedWidth - 28
        switch item {
        case let .title(text):
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
            return label
        case let .section(text):
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            return label
        case let .text(text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.isSelectable = true
            label.preferredMaxLayoutWidth = width
            return label
        case let .code(text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.isSelectable = true
            label.preferredMaxLayoutWidth = width
            return label
        }
    }
}

/// Owns the diagnostics window. The integration layer supplies a closure that reads current in-memory state;
/// all inputs are read-only snapshots, so opening the page never performs I/O on the main thread.
final class DiagnosticsWindowController {
    private let provider: () -> DiagnosticsInputs
    private let view = DiagnosticsView()
    private(set) var window: NSWindow?

    init(provider: @escaping () -> DiagnosticsInputs) {
        self.provider = provider
    }

    func refresh() {
        view.reload(DiagnosticsContent.items(provider()))
    }

    func show() {
        refresh()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: DiagnosticsView.fixedWidth, height: 400),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "数据来源诊断"
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
