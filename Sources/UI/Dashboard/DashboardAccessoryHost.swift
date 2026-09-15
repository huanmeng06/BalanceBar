import AppKit

/// Mounts, updates, and removes a page's top accessory using the public
/// AppKit host that matches the requested ownership.
///
/// Window/titlebar content uses `NSTitlebarAccessoryViewController`.
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
        window = nil
        splitViewController = nil
    }

    var titlebarAccessoryForTesting: NSTitlebarAccessoryViewController? {
        if case .windowTitlebar(let accessory) = mountedAccessory {
            return accessory
        }
        return nil
    }

    var contentSplitItemAccessoryForTesting: NSViewController? {
        if case .contentSplitItem(let accessory) = mountedAccessory {
            return accessory
        }
        return nil
    }

    private enum MountedAccessory {
        case none
        case windowTitlebar(NSTitlebarAccessoryViewController)
        case contentSplitItem(NSViewController)
    }

    private func mountWindowTitlebar(_ content: NSViewController) {
        guard let window else { return }
        let accessory: NSTitlebarAccessoryViewController
        if let existing = content as? NSTitlebarAccessoryViewController {
            accessory = existing
        } else {
            accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .top
            adopt(content, into: accessory)
        }
        if accessory.layoutAttribute != .top && accessory.layoutAttribute != .bottom {
            accessory.layoutAttribute = .top
        }
        window.addTitlebarAccessoryViewController(accessory)
        mountedAccessory = .windowTitlebar(accessory)
        mountedKind = .windowTitlebar
    }

    private func mountContentSplitItem(_ content: NSViewController) {
        guard #available(macOS 26.0, *) else {
            mountedKind = .skippedUnsupportedOS
            return
        }
        guard let item = splitViewController?.contentSplitViewItem else { return }
        let accessory: NSSplitViewItemAccessoryViewController
        if let existing = content as? NSSplitViewItemAccessoryViewController {
            accessory = existing
        } else {
            accessory = NSSplitViewItemAccessoryViewController()
            adopt(content, into: accessory)
        }
        item.addTopAlignedAccessoryViewController(accessory)
        mountedAccessory = .contentSplitItem(accessory)
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
        case .windowTitlebar(let accessory):
            if let window,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            detachChildren(of: accessory)
        case .contentSplitItem(let accessory):
            if #available(macOS 26.0, *),
               let item = splitViewController?.contentSplitViewItem,
               let splitAccessory = accessory as? NSSplitViewItemAccessoryViewController,
               let index = item.topAlignedAccessoryViewControllers.firstIndex(of: splitAccessory) {
                item.removeTopAlignedAccessoryViewController(at: index)
            } else if accessory.parent != nil {
                accessory.removeFromParent()
            }
            detachChildren(of: accessory)
        }
        mountedAccessory = .none
        mountedKind = .none
    }

    private func detachChildren(of accessory: NSViewController) {
        for child in accessory.children {
            child.removeFromParent()
        }
    }
}
