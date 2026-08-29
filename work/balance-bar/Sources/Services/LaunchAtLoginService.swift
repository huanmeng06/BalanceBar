import ServiceManagement

/// The subset of ServiceManagement state that BalanceBar needs to present.
/// Unknown values are intentionally kept separate from `.enabled` so a future
/// framework status can never opt the user in by accident.
enum LaunchAtLoginStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            self = .enabled
        case .notRegistered:
            self = .notRegistered
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .unknown
        }
    }
}

/// Keeps the real login-item API behind a small boundary so the settings page
/// can be exercised without registering the test process as a login item.
protocol LaunchAtLoginService {
    var status: LaunchAtLoginStatus { get }

    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

/// Production adapter for the app's native login-item service. BalanceBar
/// deliberately uses the main app service and does not ship a helper target.
final class SystemLaunchAtLoginService: LaunchAtLoginService {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LaunchAtLoginStatus {
        LaunchAtLoginStatus(service.status)
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum LaunchAtLoginNotice: Equatable {
    case none
    case requiresApproval
    case operationFailed
    case unavailable
}

struct LaunchAtLoginState: Equatable {
    let status: LaunchAtLoginStatus
    let notice: LaunchAtLoginNotice

    init(status: LaunchAtLoginStatus, notice: LaunchAtLoginNotice? = nil) {
        self.status = status
        self.notice = notice ?? Self.defaultNotice(for: status)
    }

    private static func defaultNotice(for status: LaunchAtLoginStatus) -> LaunchAtLoginNotice {
        switch status {
        case .enabled, .notRegistered:
            return .none
        case .requiresApproval:
            return .requiresApproval
        case .notFound, .unknown:
            return .unavailable
        }
    }
}

/// Coordinates an operation and immediately reloads ServiceManagement state.
/// The result never reflects the requested value alone: it always reflects the
/// service's post-operation status, including when an operation throws.
final class LaunchAtLoginController {
    static let toggleIdentifier = "launchAtLogin"

    private let service: LaunchAtLoginService

    init(service: LaunchAtLoginService = SystemLaunchAtLoginService()) {
        self.service = service
    }

    func currentState() -> LaunchAtLoginState {
        LaunchAtLoginState(status: service.status)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> LaunchAtLoginState {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // Reading status in the error path is intentional. Registration can
            // fail after changing system state, and the UI must not trust the
            // switch value that initiated the operation.
            let observedStatus = service.status
            return LaunchAtLoginState(
                status: observedStatus,
                notice: noticeAfterOperationError(for: observedStatus)
            )
        }

        return currentState()
    }

    func openSystemSettingsLoginItems() {
        service.openSystemSettingsLoginItems()
    }

    private func noticeAfterOperationError(
        for status: LaunchAtLoginStatus
    ) -> LaunchAtLoginNotice {
        switch status {
        case .requiresApproval:
            return .requiresApproval
        case .notFound, .unknown:
            return .unavailable
        case .enabled, .notRegistered:
            return .operationFailed
        }
    }
}
