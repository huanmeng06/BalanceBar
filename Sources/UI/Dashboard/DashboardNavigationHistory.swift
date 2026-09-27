import Foundation

/// A value that identifies a Dashboard page without coupling navigation to a
/// particular page implementation. `route` is reserved for feature-owned
/// destinations that can be added by later Dashboard work (for example,
/// notification Agent/provider/resource pages) without putting those routes in
/// the toolbar or creating a second history stack.
enum DashboardNavigationDestination: Equatable, Hashable {
    case section(DashboardSection)
    case provider(String)
    case route(String)
}

/// Browser-style history for one Dashboard page session.
///
/// The cursor points at the currently displayed destination. Pushing a new
/// destination after moving backwards discards the forward branch. Moving the
/// cursor never pushes, which keeps Back/Forward restoration from creating
/// duplicate entries.
final class DashboardNavigationHistory {
    private(set) var destinations: [DashboardNavigationDestination] = []
    private(set) var cursor = -1

    var currentDestination: DashboardNavigationDestination? {
        guard destinations.indices.contains(cursor) else { return nil }
        return destinations[cursor]
    }

    var canGoBack: Bool { cursor > 0 }
    var canGoForward: Bool {
        cursor >= 0 && cursor < destinations.count - 1
    }

    @discardableResult
    func push(_ destination: DashboardNavigationDestination) -> Bool {
        guard currentDestination != destination else { return false }

        if cursor + 1 < destinations.count {
            destinations.removeSubrange((cursor + 1)..<destinations.count)
        }
        destinations.append(destination)
        cursor = destinations.count - 1
        return true
    }

    /// Reconciles the current cursor with a destination that was restored by
    /// the shell after the original destination became unavailable. This does
    /// not create a new visit or alter the forward branch.
    @discardableResult
    func replaceCurrent(with destination: DashboardNavigationDestination) -> Bool {
        guard destinations.indices.contains(cursor) else {
            return push(destination)
        }
        if cursor > 0, destinations[cursor - 1] == destination {
            destinations.remove(at: cursor)
            cursor -= 1
        } else {
            destinations[cursor] = destination
        }
        return true
    }

    func goBack() -> DashboardNavigationDestination? {
        guard canGoBack else { return nil }
        cursor -= 1
        return currentDestination
    }

    func goForward() -> DashboardNavigationDestination? {
        guard canGoForward else { return nil }
        cursor += 1
        return currentDestination
    }
}
