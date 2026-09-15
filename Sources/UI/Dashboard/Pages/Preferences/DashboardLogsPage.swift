import AppKit

final class DashboardLogsPage {
    private let logView = NSTextView()

    func makeViewer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 190).isActive = true

        logView.isEditable = false
        logView.isSelectable = true
        logView.isRichText = true
        logView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let vscodeForeground = Self.vscodeColor(0xD4D4D4)
        let vscodeBackground = Self.vscodeColor(0x1E1E1E)
        let vscodeSelection = Self.vscodeColor(0x264F78)
        logView.textColor = vscodeForeground
        logView.backgroundColor = vscodeBackground
        logView.drawsBackground = true
        logView.selectedTextAttributes = [
            .foregroundColor: NSColor.white,
            .backgroundColor: vscodeSelection
        ]
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = true
        logView.autoresizingMask = []
        logView.minSize = .zero
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logView.textContainer?.widthTracksTextView = false
        logView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = logView.backgroundColor
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        refresh()
        return container
    }

    func makePage(relay: DashboardPreferencePageRelay) -> NSView {
        let root = NSView()
        let header = DashboardSettingsComponents.makePageHeader(
            tr(.keyDashboardLogsPageLogs),
            subtitle: tr(.keyDashboardLogsPageProviderSwitchingSynchronizationAndFailureDetails)
        )
        let refreshButton = NSButton(
            title: tr(.keyDashboardLogsPageRefresh),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.refreshLog(_:))
        )
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: tr(.keyDashboardLogsPageRefresh2))
        let revealButton = NSButton(
            title: tr(.keyDashboardLogsPageShowInFinder),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.revealLog(_:))
        )
        revealButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: tr(.keyDashboardLogsPageShowInFinder2))
        let buttons = NSStackView(views: [refreshButton, revealButton, NSView()])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        logView.isEditable = false
        logView.isSelectable = true
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 10, height: 10)
        logView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.documentView = logView

        [header, buttons, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            buttons.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            buttons.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28)
        ])
        return root
    }

    func refresh() {
        let text = SwitchLog.recentText() ?? tr(.keyDashboardLogsPageNoLogsYet)
        logView.textStorage?.setAttributedString(Self.styledLog(text))
        resizeDocument()
        DispatchQueue.main.async { [weak self] in
            self?.resizeDocument()
        }
        logView.scrollToEndOfDocument(nil)
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([SwitchLog.fileURL])
    }

    private func resizeDocument() {
        guard let textContainer = logView.textContainer,
              let layoutManager = logView.layoutManager else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let viewport = logView.enclosingScrollView?.contentSize ?? .zero
        let inset = logView.textContainerInset
        logView.setFrameSize(NSSize(
            width: max(viewport.width, ceil(used.width + (inset.width * 2) + 12)),
            height: max(viewport.height, ceil(used.height + (inset.height * 2)))
        ))
    }

    private static func vscodeColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static func styledLog(_ text: String) -> NSAttributedString {
        let foreground = Self.vscodeColor(0xD4D4D4)
        let timestamp = Self.vscodeColor(0x9DA5B4)
        let debug = Self.vscodeColor(0xDCDCAA)
        let info = Self.vscodeColor(0x23D18B)
        let warning = Self.vscodeColor(0xF9F1A5)
        let error = Self.vscodeColor(0xF14C4C)
        let number = Self.vscodeColor(0x4FC1FF)
        let baseFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let emphasizedFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        let output = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: foreground
        ])
        let fullRange = NSRange(location: 0, length: output.length)

        func colorMatches(_ pattern: String, color: NSColor, emphasized: Bool = false) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            expression.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                output.addAttributes([
                    .foregroundColor: color,
                    .font: emphasized ? emphasizedFont : baseFont
                ], range: range)
            }
        }

        colorMatches(#"(?<=[\$¥])-?\d+(?:\.\d+)?"#, color: number)
        colorMatches(#"(?<![\w.])-?\d+(?:\.\d+)?(?=%)"#, color: number)
        colorMatches(#"(?<==)-?\d+(?:\.\d+)?(?=(?:%|ms|s|m|h|d)?(?:[;,\s\)]|$))"#, color: number)
        colorMatches(#"(?m)^\[[^\]\n]+\]"#, color: timestamp)
        colorMatches(#"\[DEBUG\]"#, color: debug, emphasized: true)
        colorMatches(#"\[INFO\]"#, color: info, emphasized: true)
        colorMatches(#"\[WARN\]"#, color: warning, emphasized: true)
        colorMatches(#"\[ERROR\]"#, color: error, emphasized: true)
        if let categoryExpression = try? NSRegularExpression(
            pattern: #"(?m)^\[[^\]\n]+\] \[(?:DEBUG|INFO|WARN|ERROR)\] (\[[^\]\n]+\])"#
        ) {
            categoryExpression.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range(at: 1), range.location != NSNotFound else { return }
                output.addAttribute(.foregroundColor, value: foreground, range: range)
            }
        }
        return output
    }
}
