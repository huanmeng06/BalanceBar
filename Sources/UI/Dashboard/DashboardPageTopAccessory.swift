import AppKit

/// Page-level top accessory request. Current Dashboard pages report `.none`;
/// that is a valid product result and must not create an empty accessory.
enum DashboardPageTopAccessory {
    case none
    /// Spans the window titlebar. `reason` must name a window-level ownership
    /// need; an empty reason is treated as `.none`.
    case windowTitlebar(viewController: NSViewController, reason: String)
    /// Belongs only to the right Dashboard content split item.
    case contentSplitItem(viewController: NSViewController)

    var needsAccessory: Bool {
        switch self {
        case .none:
            return false
        case .windowTitlebar(_, let reason):
            return !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .contentSplitItem:
            return true
        }
    }

    static func resolved(from page: NSViewController) -> DashboardPageTopAccessory {
        (page as? DashboardPageTopAccessoryProviding)?.dashboardPageTopAccessory ?? .none
    }
}

/// Pages may adopt this to publish a top accessory. Pages that do not adopt it
/// have no accessory. Pages must not mount AppKit chrome themselves.
protocol DashboardPageTopAccessoryProviding: AnyObject {
    var dashboardPageTopAccessory: DashboardPageTopAccessory { get }
}
