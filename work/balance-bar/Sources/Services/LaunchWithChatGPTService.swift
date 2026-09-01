import ServiceManagement

enum LaunchWithChatGPTAgent {
    static let plistName = "balancebar-chatgpt-launch-agent.plist"
}

enum LaunchWithChatGPTStatus: Equatable {
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

protocol LaunchWithChatGPTService {
    var status: LaunchWithChatGPTStatus { get }

    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

final class SystemLaunchWithChatGPTService: LaunchWithChatGPTService {
    private let service: SMAppService

    init(service: SMAppService = .agent(plistName: LaunchWithChatGPTAgent.plistName)) {
        self.service = service
    }

    var status: LaunchWithChatGPTStatus {
        LaunchWithChatGPTStatus(service.status)
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

enum LaunchWithChatGPTNotice: Equatable {
    case none
    case requiresApproval
    case operationFailed
    case unavailable
}

struct LaunchWithChatGPTState: Equatable {
    let status: LaunchWithChatGPTStatus
    let notice: LaunchWithChatGPTNotice

    init(status: LaunchWithChatGPTStatus, notice: LaunchWithChatGPTNotice? = nil) {
        self.status = status
        self.notice = notice ?? Self.defaultNotice(for: status)
    }

    private static func defaultNotice(for status: LaunchWithChatGPTStatus) -> LaunchWithChatGPTNotice {
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

struct LaunchWithChatGPTOperationOutcome {
    let state: LaunchWithChatGPTState
    let error: Error?
}

final class LaunchWithChatGPTController {
    static let toggleIdentifier = "launchWithChatGPT"

    private let service: LaunchWithChatGPTService

    init(service: LaunchWithChatGPTService = SystemLaunchWithChatGPTService()) {
        self.service = service
    }

    func currentState() -> LaunchWithChatGPTState {
        LaunchWithChatGPTState(status: service.status)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> LaunchWithChatGPTOperationOutcome {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            let observedStatus = service.status
            return LaunchWithChatGPTOperationOutcome(
                state: stateAfterOperationError(
                    requestedEnabled: enabled,
                    observedStatus: observedStatus
                ),
                error: error
            )
        }

        return LaunchWithChatGPTOperationOutcome(state: currentState(), error: nil)
    }

    func openSystemSettingsLoginItems() {
        service.openSystemSettingsLoginItems()
    }

    private func stateAfterOperationError(
        requestedEnabled: Bool,
        observedStatus: LaunchWithChatGPTStatus
    ) -> LaunchWithChatGPTState {
        switch (requestedEnabled, observedStatus) {
        case (true, .enabled):
            return LaunchWithChatGPTState(status: .enabled)
        case (true, .requiresApproval):
            return LaunchWithChatGPTState(status: .requiresApproval)
        case (false, .notRegistered):
            return LaunchWithChatGPTState(status: .notRegistered)
        case (true, _), (false, _):
            return LaunchWithChatGPTState(
                status: observedStatus,
                notice: .operationFailed
            )
        }
    }
}
