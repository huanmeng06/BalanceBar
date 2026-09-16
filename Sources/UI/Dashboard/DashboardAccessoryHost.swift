import AppKit

/// Mounts, updates, and removes a page's top accessory using the public
/// AppKit host that matches the requested ownership.
///
/// Window/titlebar content uses `NSTitlebarAccessoryViewController`.
/// Ordinary host-created wrappers use `layoutAttribute = .bottom` (under the
/// titlebar). Caller-provided accessories keep the layout they already set.
/// Content-pane content uses `NSSplitViewItemAccessoryViewController` on
/// macOS 26+. Older OS versions do not fabricate a split-item overlay.
final class DashboardAccessoryHost {
    enum MountedKind: Equatable {
        case none
        case windowTitlebar
        case contentSplitItem
        case skippedUnsupportedOS
    }

    private weak var window: NSWindow?
    private weak var splitViewController: DashboardSplitViewController?
    private var mountedAccessory: MountedAccessory = .none
    private(set) var mountedKind: MountedKind = .none
    /// Window chrome (titlebar accessories) can change `contentLayoutRect`.
    /// The window controller refreshes sidebar inset from live geometry.
    var onWindowChromeNeedsRefresh: (() -> Void)?

    func attach(window: NSWindow, splitViewController: DashboardSplitViewController) {
        removeCurrentAccessory()
        self.window = window
        self.splitViewController = splitViewController
    }

    func apply(page: NSViewController) {
        removeCurrentAccessory()
        switch DashboardPageTopAccessory.resolved(from: page) {
        case .none:
            return
        case .windowTitlebar(let viewController, let reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            mountWindowTitlebar(viewController)
        case .contentSplitItem(let viewController):
            mountContentSplitItem(viewController)
        }
    }

    func detach() {
        removeCurrentAccessory()
        onWindowChromeNeedsRefresh = nil
        window = nil
        splitViewController = nil
    }

    var titlebarAccessoryForTesting: NSTitlebarAccessoryViewController? {
        if case .windowTitlebar(let accessory, _, _) = mountedAccessory {
            return accessory
        }
        return nil
    }

    var contentSplitItemAccessoryForTesting: NSViewController? {
        if case .contentSplitItem(let accessory, _, _) = mountedAccessory {
            return accessory
        }
        return nil
    }

    var createdByHostForTesting: Bool? {
        switch mountedAccessory {
        case .none:
            return nil
        case .windowTitlebar(_, let hostCreated, _),
             .contentSplitItem(_, let hostCreated, _):
            return hostCreated
        }
    }

    private enum MountedAccessory {
        case none
        case windowTitlebar(
            accessory: NSTitlebarAccessoryViewController,
            hostCreated: Bool,
            adoptedChild: NSViewController?
        )
        case contentSplitItem(
            accessory: NSViewController,
            hostCreated: Bool,
            adoptedChild: NSViewController?
        )
    }

    private func mountWindowTitlebar(_ content: NSViewController) {
        guard let window else { return }
        let accessory: NSTitlebarAccessoryViewController
        let hostCreated: Bool
        let adoptedChild: NSViewController?
        if let existing = content as? NSTitlebarAccessoryViewController {
            accessory = existing
            hostCreated = false
            adoptedChild = nil
        } else {
            accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .bottom
            adopt(content, into: accessory)
            hostCreated = true
            adoptedChild = content
        }
        window.addTitlebarAccessoryViewController(accessory)
        mountedAccessory = .windowTitlebar(
            accessory: accessory,
            hostCreated: hostCreated,
            adoptedChild: adoptedChild
        )
        mountedKind = .windowTitlebar
        onWindowChromeNeedsRefresh?()
    }

    private func mountContentSplitItem(_ content: NSViewController) {
        guard #available(macOS 26.0, *) else {
            mountedKind = .skippedUnsupportedOS
            return
        }
        guard let item = splitViewController?.contentSplitViewItem else { return }
        let accessory: NSSplitViewItemAccessoryViewController
        let hostCreated: Bool
        let adoptedChild: NSViewController?
        if let existing = content as? NSSplitViewItemAccessoryViewController {
            accessory = existing
            hostCreated = false
            adoptedChild = nil
        } else {
            accessory = NSSplitViewItemAccessoryViewController()
            adopt(content, into: accessory)
            hostCreated = true
            adoptedChild = content
        }
        item.addTopAlignedAccessoryViewController(accessory)
        mountedAccessory = .contentSplitItem(
            accessory: accessory,
            hostCreated: hostCreated,
            adoptedChild: adoptedChild
        )
        mountedKind = .contentSplitItem
    }

    private func adopt(_ content: NSViewController, into accessory: NSViewController) {
        if content.parent != nil {
            content.removeFromParent()
        }
        accessory.addChild(content)
        accessory.view = content.view
    }

    private func removeCurrentAccessory() {
        switch mountedAccessory {
        case .none:
            break
        case .windowTitlebar(let accessory, let hostCreated, let adoptedChild):
            if let window,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            releaseHostAdoptedChild(adoptedChild, from: accessory, hostCreated: hostCreated)
        case .contentSplitItem(let accessory, let hostCreated, let adoptedChild):
            if #available(macOS 26.0, *),
               let item = splitViewController?.contentSplitViewItem,
               let splitAccessory = accessory as? NSSplitViewItemAccessoryViewController,
               let index = item.topAlignedAccessoryViewControllers.firstIndex(of: splitAccessory) {
                item.removeTopAlignedAccessoryViewController(at: index)
            } else if accessory.parent != nil {
                accessory.removeFromParent()
            }
            releaseHostAdoptedChild(adoptedChild, from: accessory, hostCreated: hostCreated)
        }
        let didRemoveChrome = mountedKind != .none
        mountedAccessory = .none
        mountedKind = .none
        if didRemoveChrome {
            onWindowChromeNeedsRefresh?()
        }
    }

    private func releaseHostAdoptedChild(
        _ adoptedChild: NSViewController?,
        from accessory: NSViewController,
        hostCreated: Bool
    ) {
        guard hostCreated, let adoptedChild, adoptedChild.parent === accessory else { return }
        adoptedChild.removeFromParent()
    }
}
