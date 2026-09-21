import AppKit

/// Mounts, updates, and removes a page's top accessory using the public
/// AppKit host that matches the requested ownership.
///
/// Window/titlebar content uses `NSTitlebarAccessoryViewController`.
/// Host-created wrappers use `layoutAttribute = .bottom` and an independent
/// container view. Caller-provided accessories keep the layout and child
/// containment they already set; unmount only reverses the AppKit mounting
/// relationship this host established.
/// Content-pane content uses `NSSplitViewItemAccessoryViewController` on
/// macOS 26+. Older OS versions do not fabricate a split-item overlay.
final class DashboardAccessoryHost {
    var platformCapabilities = DashboardPlatformCapabilities.current

    enum MountedKind: Equatable {
        case none
        case windowTitlebar
        case contentSplitItem
        case skippedUnsupportedOS
    }

    enum MountOwnership: Equatable {
        case none
        case hostCreatedWrapper
        case callerProvidedNative
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
        if case .windowTitlebar(let mount) = mountedAccessory {
            return mount.accessory
        }
        return nil
    }

    var contentSplitItemAccessoryForTesting: NSViewController? {
        if case .contentSplitItem(let mount) = mountedAccessory {
            return mount.accessory
        }
        return nil
    }

    var mountOwnershipForTesting: MountOwnership {
        switch mountedAccessory {
        case .none:
            return .none
        case .windowTitlebar(let mount):
            return mount.ownership.testingKind
        case .contentSplitItem(let mount):
            return mount.ownership.testingKind
        }
    }

    var createdByHostForTesting: Bool? {
        switch mountOwnershipForTesting {
        case .none:
            return nil
        case .hostCreatedWrapper:
            return true
        case .callerProvidedNative:
            return false
        }
    }

    private enum AccessoryOwnership {
        case hostCreatedWrapper(child: NSViewController)
        case callerProvidedNative

        var testingKind: MountOwnership {
            switch self {
            case .hostCreatedWrapper:
                return .hostCreatedWrapper
            case .callerProvidedNative:
                return .callerProvidedNative
            }
        }
    }

    private struct WindowTitlebarMount {
        let accessory: NSTitlebarAccessoryViewController
        let ownership: AccessoryOwnership
    }

    private struct ContentSplitItemMount {
        let accessory: NSViewController
        let ownership: AccessoryOwnership
    }

    private enum MountedAccessory {
        case none
        case windowTitlebar(WindowTitlebarMount)
        case contentSplitItem(ContentSplitItemMount)
    }

    private func mountWindowTitlebar(_ content: NSViewController) {
        guard let window else { return }
        if let existing = content as? NSTitlebarAccessoryViewController {
            window.addTitlebarAccessoryViewController(existing)
            mountedAccessory = .windowTitlebar(
                WindowTitlebarMount(accessory: existing, ownership: .callerProvidedNative)
            )
            mountedKind = .windowTitlebar
            return
        }
        guard content.parent == nil else { return }
        let wrapper = makeTitlebarWrapper(hosting: content)
        window.addTitlebarAccessoryViewController(wrapper)
        mountedAccessory = .windowTitlebar(
            WindowTitlebarMount(
                accessory: wrapper,
                ownership: .hostCreatedWrapper(child: content)
            )
        )
        mountedKind = .windowTitlebar
    }

    private func mountContentSplitItem(_ content: NSViewController) {
        guard platformCapabilities.supportsSplitItemAccessories else {
            mountedKind = .skippedUnsupportedOS
            return
        }
        guard #available(macOS 26.0, *) else {
            mountedKind = .skippedUnsupportedOS
            return
        }
        guard let item = splitViewController?.contentSplitViewItem else { return }
        if let existing = content as? NSSplitViewItemAccessoryViewController {
            item.addTopAlignedAccessoryViewController(existing)
            mountedAccessory = .contentSplitItem(
                ContentSplitItemMount(accessory: existing, ownership: .callerProvidedNative)
            )
            mountedKind = .contentSplitItem
            return
        }
        guard content.parent == nil else { return }
        let wrapper = makeSplitItemWrapper(hosting: content)
        item.addTopAlignedAccessoryViewController(wrapper)
        mountedAccessory = .contentSplitItem(
            ContentSplitItemMount(
                accessory: wrapper,
                ownership: .hostCreatedWrapper(child: content)
            )
        )
        mountedKind = .contentSplitItem
    }

    private func makeTitlebarWrapper(
        hosting content: NSViewController
    ) -> NSTitlebarAccessoryViewController {
        let wrapper = NSTitlebarAccessoryViewController()
        wrapper.layoutAttribute = .bottom
        wrapper.view = NSView(frame: content.view.bounds)
        embedUnattachedContent(content, in: wrapper)
        return wrapper
    }

    @available(macOS 26.0, *)
    private func makeSplitItemWrapper(
        hosting content: NSViewController
    ) -> NSSplitViewItemAccessoryViewController {
        let wrapper = NSSplitViewItemAccessoryViewController()
        wrapper.view = NSView(frame: content.view.bounds)
        embedUnattachedContent(content, in: wrapper)
        return wrapper
    }

    private func embedUnattachedContent(
        _ content: NSViewController,
        in wrapper: NSViewController
    ) {
        wrapper.addChild(content)
        let container = wrapper.view
        let childView = content.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            childView.topAnchor.constraint(equalTo: container.topAnchor),
            childView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func removeCurrentAccessory() {
        switch mountedAccessory {
        case .none:
            break
        case .windowTitlebar(let mount):
            if let window,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: mount.accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            releaseHostCreatedChild(from: mount.ownership, wrapper: mount.accessory)
        case .contentSplitItem(let mount):
            if #available(macOS 26.0, *),
               let item = splitViewController?.contentSplitViewItem,
               let splitAccessory = mount.accessory as? NSSplitViewItemAccessoryViewController,
               let index = item.topAlignedAccessoryViewControllers.firstIndex(of: splitAccessory) {
                item.removeTopAlignedAccessoryViewController(at: index)
            }
            releaseHostCreatedChild(from: mount.ownership, wrapper: mount.accessory)
        }
        mountedAccessory = .none
        mountedKind = .none
    }

    private func releaseHostCreatedChild(
        from ownership: AccessoryOwnership,
        wrapper: NSViewController
    ) {
        guard case .hostCreatedWrapper(let child) = ownership else { return }
        if child.view.superview === wrapper.view {
            child.view.removeFromSuperview()
        }
        if child.parent === wrapper {
            child.removeFromParent()
        }
    }
}
