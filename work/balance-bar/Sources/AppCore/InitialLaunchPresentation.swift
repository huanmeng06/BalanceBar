import Foundation

enum InitialLaunchPresentation: Equatable {
    case dashboard
    case background

    static func resolve(silentLaunch: Bool) -> Self {
        silentLaunch ? .background : .dashboard
    }
}
