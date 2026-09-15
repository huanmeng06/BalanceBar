import Foundation

enum InitialLaunchPresentation: Equatable {
    case dashboard
    case background

    static func resolve(
        silentLaunch: Bool,
        pendingDashboardRestore: Bool = false
    ) -> Self {
        if pendingDashboardRestore {
            return .dashboard
        }
        return silentLaunch ? .background : .dashboard
    }
}

struct DashboardRestoreToken: Equatable {
    var section: DashboardSection
    var scrollOffsetY: Double
}

enum DashboardRestoreStore {
    static let sectionKey = "dashboardRestoreOnceSection"
    static let scrollOffsetKey = "dashboardRestoreOnceScrollOffset"
    /// Production keeps `.standard`. Tests may swap a suite so one-shot tokens do not leak.
    static var defaults = UserDefaults.standard

    static func record(
        _ token: DashboardRestoreToken,
        defaults: UserDefaults? = nil
    ) {
        let defaults = defaults ?? Self.defaults
        defaults.set(token.section.rawValue, forKey: sectionKey)
        defaults.set(token.scrollOffsetY, forKey: scrollOffsetKey)
        defaults.synchronize()
    }

    static func peek(defaults: UserDefaults? = nil) -> DashboardRestoreToken? {
        let defaults = defaults ?? Self.defaults
        guard defaults.object(forKey: sectionKey) != nil else { return nil }
        guard let section = DashboardSection(rawValue: defaults.integer(forKey: sectionKey)) else {
            return nil
        }
        let offset = defaults.object(forKey: scrollOffsetKey) as? Double ?? 0
        return DashboardRestoreToken(section: section, scrollOffsetY: offset)
    }

    static func clear(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? Self.defaults
        defaults.removeObject(forKey: sectionKey)
        defaults.removeObject(forKey: scrollOffsetKey)
        defaults.synchronize()
    }
}
