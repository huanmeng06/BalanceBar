import AppKit

final class DashboardAdvancedPage {
    static let logViewerHeight: CGFloat = 190
    static let logViewerHostIdentifier = NSUserInterfaceItemIdentifier(
        "dashboard.advanced.logViewer"
    )

    struct Input {
        let relay: DashboardPreferencePageRelay
        let logViewer: NSView

        let includeLogViewer: Bool

        init(
            relay: DashboardPreferencePageRelay,
            logViewer: NSView,
            includeLogViewer: Bool = true
        ) {
            self.relay = relay
            self.logViewer = logViewer
            self.includeLogViewer = includeLogViewer
        }
    }

    func make(_ input: Input) -> NSView {
        let refreshLog = NSButton(
            title: tr(.keyDashboardAdvancedPageReload),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.refreshLog(_:))
        )
        let revealLog = NSButton(
            title: tr(.keyDashboardAdvancedPageShowInFinder),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.revealLog(_:))
        )
        let logButtons = NSStackView(views: [refreshLog, revealLog])
        logButtons.orientation = .horizontal
        logButtons.spacing = 8
        logButtons.setHuggingPriority(.required, for: .horizontal)
        logButtons.setClippingResistancePriority(.required, for: .horizontal)
        logButtons.setContentHuggingPriority(.required, for: .horizontal)
        logButtons.setContentCompressionResistancePriority(.required, for: .horizontal)
        logButtons.setContentHuggingPriority(.required, for: .vertical)
        let debugLogRow = SettingsRowView(
            title: tr(.keyDashboardAdvancedPageDebugLog),
            detail: tr(.keyDashboardAdvancedPageRecordsRuntimeStatusAndErrors),
            accessoryView: logButtons
        )
        var contentViews: [NSView] = [debugLogRow]
        if input.includeLogViewer {
            contentViews.append(Self.makePinnedLogViewer(input.logViewer))
        }
        let logs = SettingsSectionView(
            title: tr(.keyDashboardAdvancedPageDiagnostics),
            contentViews: contentViews
        )
        return DashboardSettingsComponents.makeSettingsPageContent([logs])
    }

    /// Keeps the Diagnostics log pane at the historical 190pt slot. The real
    /// viewer hosts a vertically resizable `NSTextView` whose intrinsic /
    /// document height is the full log; without a required host height the
    /// native section card grows with that document instead of scrolling.
    static func makePinnedLogViewer(_ viewer: NSView) -> NSView {
        let host = NSView()
        host.identifier = logViewerHostIdentifier
        host.translatesAutoresizingMaskIntoConstraints = false
        host.clipsToBounds = true
        host.setContentHuggingPriority(.required, for: .vertical)
        host.setContentCompressionResistancePriority(.required, for: .vertical)
        host.heightAnchor.constraint(equalToConstant: logViewerHeight).isActive = true

        if viewer.superview != nil {
            viewer.removeFromSuperview()
        }
        viewer.translatesAutoresizingMaskIntoConstraints = false
        suppressVerticalIntrinsicGrowth(viewer)
        host.addSubview(viewer)
        NSLayoutConstraint.activate([
            viewer.topAnchor.constraint(equalTo: host.topAnchor),
            viewer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            viewer.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        return host
    }

    private static func suppressVerticalIntrinsicGrowth(_ view: NSView) {
        view.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        for subview in view.subviews {
            // Leave the clip view and document frame-based so extra log text
            // can scroll inside the 190pt slot instead of being compressed.
            if subview is NSClipView {
                continue
            }
            suppressVerticalIntrinsicGrowth(subview)
        }
    }
}
