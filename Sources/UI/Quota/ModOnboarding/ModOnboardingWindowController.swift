import AppKit

/// The standalone explanation window: Esc = "later", Return = the default button, height follows the content.
private final class ModOnboardingPanel: NSPanel {
    weak var panelView: ModOnboardingPanelView?

    override func cancelOperation(_ sender: Any?) {
        panelView?.perform(.close)
    }

    override var canBecomeKey: Bool { true }
}

/// Owns the Mod explanation window (one instance, reused). Closing it never cancels a running install;
/// reopening shows the current progress.
final class ModOnboardingWindowController: NSObject, NSWindowDelegate {
    private let makeView: () -> ModOnboardingPanelView
    private var panel: ModOnboardingPanel?
    private(set) var panelView: ModOnboardingPanelView?

    var isVisible: Bool { panel?.isVisible == true }
    var window: NSWindow? { panel }

    /// - Parameter makeView: builds a fresh panel view bound to the shared controller (the controller has one
    ///   observer slot for the window, so the view is replaced on every `show`).
    init(makeView: @escaping () -> ModOnboardingPanelView) {
        self.makeView = makeView
    }

    /// Builds the window and its content for the current state without ordering it front.
    @discardableResult
    func prepare() -> NSPanel {
        let view = makeView()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panelView = view
        panel.panelView = view
        view.onRequestClose = { [weak self] in self?.close() }
        view.onContentSizeChange = { [weak self] size in self?.resize(toContentHeight: size.height) }
        view.onDefaultButtonChange = { [weak panel] button in panel?.defaultButtonCell = button?.cell as? NSButtonCell }
        panel.contentView = view
        view.layoutSubtreeIfNeeded()
        resize(toContentHeight: view.fittingSize.height, animate: false)
        view.reload()
        return panel
    }

    func show() {
        let wasVisible = isVisible
        let panel = prepare()
        if !wasVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> ModOnboardingPanel {
        let panel = ModOnboardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: ModOnboardingPanelView.fixedWidth, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        return panel
    }

    /// Resizes to the content, keeping the top edge where it is.
    private func resize(toContentHeight height: CGFloat, animate: Bool = true) {
        guard let panel else { return }
        let content = NSRect(x: 0, y: 0, width: ModOnboardingPanelView.fixedWidth, height: height)
        var frame = panel.frameRect(forContentRect: content)
        let old = panel.frame
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        guard abs(frame.height - old.height) > 0.5 || abs(frame.width - old.width) > 0.5 else { return }
        panel.setFrame(frame, display: panel.isVisible, animate: animate && panel.isVisible)
    }
}
