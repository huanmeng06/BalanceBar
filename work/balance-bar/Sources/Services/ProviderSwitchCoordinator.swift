import Foundation

struct ProviderSwitchActions {
    let changed: () -> Void
    let failed: (String) -> Void
}

enum CCSwitchProviderSwitchBridgeError: LocalizedError, Equatable {
    case unavailable
    case databaseVerificationFailed
    case databaseVerificationTimedOut

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "CC Switch does not expose a supported provider-switch bridge."
        case .databaseVerificationFailed:
            return "CC Switch did not verify the requested provider switch."
        case .databaseVerificationTimedOut:
            return "CC Switch did not verify the requested provider switch before the timeout."
        }
    }
}

protocol CCSwitchProviderSwitching {
    var availability: CCSwitchBridgeAvailability { get }
    func switchProvider(target: CCSwitchProviderSwitchTarget) throws
}

final class CCSwitchUnavailableProviderSwitchBridge: CCSwitchProviderSwitching {
    let availability: CCSwitchBridgeAvailability = .unavailable

    func switchProvider(target: CCSwitchProviderSwitchTarget) throws {
        _ = target
        throw CCSwitchProviderSwitchBridgeError.unavailable
    }
}

/// Owns the opt-in CC Switch hot-switch path and the legacy stop/write/reopen
/// path. A seamless request is fail-closed: it never falls back to a restart
/// after the running-process bridge has been selected.
final class ProviderSwitchCoordinator {
    static let databaseVerificationTimeout: TimeInterval = 15

    private let repository: CCSwitchRepository
    private let runtime: CCSwitchRuntimeControlling
    private let providerSwitchBridge: CCSwitchProviderSwitching
    private let isSeamlessSwitchEnabled: () -> Bool
    private let verificationTimeout: TimeInterval
    private let verificationPollingInterval: TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let queue: DispatchQueue
    private let actions: ProviderSwitchActions

    init(
        repository: CCSwitchRepository,
        runtime: CCSwitchRuntimeControlling = CCSwitchRuntimeController(),
        providerSwitchBridge: CCSwitchProviderSwitching = CCSwitchUnavailableProviderSwitchBridge(),
        isSeamlessSwitchEnabled: @escaping () -> Bool = { false },
        verificationTimeout: TimeInterval = ProviderSwitchCoordinator.databaseVerificationTimeout,
        verificationPollingInterval: TimeInterval = 0.05,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.provider-switch"),
        actions: ProviderSwitchActions
    ) {
        self.repository = repository
        self.runtime = runtime
        self.providerSwitchBridge = providerSwitchBridge
        self.isSeamlessSwitchEnabled = isSeamlessSwitchEnabled
        self.verificationTimeout = max(0, verificationTimeout)
        self.verificationPollingInterval = max(0.001, verificationPollingInterval)
        self.sleep = sleep
        self.queue = queue
        self.actions = actions
    }

    func switchProvider(providerID: String, appType: String, providerName: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let current = self.repository.loadChoices(appType: appType).first(where: { $0.isCurrent })
            guard current?.id != providerID else { return }

            let runtimeSnapshot = self.runtime.snapshot()
            if runtimeSnapshot.wasRunning, self.isSeamlessSwitchEnabled() {
                self.switchThroughRunningCCSwitch(
                    target: CCSwitchProviderSwitchTarget(
                        providerID: providerID,
                        providerName: providerName,
                        appType: appType
                    )
                )
                return
            }

            if let restorationPreconditionError = runtimeSnapshot.restorationPreconditionError {
                self.report(.failure(restorationPreconditionError))
                return
            }
            if runtimeSnapshot.wasRunning,
               !self.runtime.terminateAndWait(for: runtimeSnapshot, timeout: 4) {
                self.actions.failed(tr(.keyProviderSwitchCoordinatorSwitchFailedCcSwitchCouldNotReloadNormally))
                return
            }
            do {
                try self.repository.switchCurrent(to: providerID, appType: appType)
                guard self.repository.loadChoices(appType: appType).first(where: { $0.isCurrent })?.id == providerID else {
                    throw CCSwitchProviderSwitchBridgeError.databaseVerificationFailed
                }
                self.finish(.success(()), restoring: runtimeSnapshot)
            } catch {
                self.finish(.failure(error), restoring: runtimeSnapshot)
            }
        }
    }

    private func switchThroughRunningCCSwitch(target: CCSwitchProviderSwitchTarget) {
        guard providerSwitchBridge.availability != .unavailable else {
            report(.failure(CCSwitchProviderSwitchBridgeError.unavailable))
            return
        }

        do {
            // The bridge owns the complete in-process transaction, including
            // settings cache, DB/live projection, MCP, and proxy semantics.
            // Do not call CCSwitchRepository.switchCurrent on this path.
            try providerSwitchBridge.switchProvider(target: target)
            guard waitForDatabaseVerification(target: target) else {
                throw CCSwitchProviderSwitchBridgeError.databaseVerificationTimedOut
            }
            actions.changed()
        } catch {
            report(.failure(error))
        }
    }

    private func waitForDatabaseVerification(
        target: CCSwitchProviderSwitchTarget
    ) -> Bool {
        let deadline = Date().addingTimeInterval(verificationTimeout)
        repeat {
            if repository.loadChoices(appType: target.appType)
                .first(where: { $0.isCurrent })?.id == target.providerID {
                return true
            }
            guard Date() < deadline else { return false }
            sleep(min(verificationPollingInterval, max(0, deadline.timeIntervalSinceNow)))
        } while true
    }

    private func finish(
        _ result: Result<Void, Error>,
        restoring snapshot: CCSwitchRuntimeSnapshot
    ) {
        guard snapshot.wasRunning else {
            report(result)
            return
        }

        // A database write is not reported as changed until CC Switch's
        // requested presentation has completed or failed explicitly. The
        // runtime adapter must observe the process/window state; submitting a
        // launch request is not enough.
        runtime.restore(from: snapshot) { [weak self] restorationResult in
            guard let self else { return }
            self.queue.async {
                switch (result, restorationResult) {
                case (.success, .success):
                    self.actions.changed()
                case (.success, .failure(let restorationError)):
                    self.report(.failure(restorationError))
                case (.failure(let switchError), .success):
                    self.report(.failure(switchError))
                case (.failure(let switchError), .failure(let restorationError)):
                    let combined = NSError(
                        domain: "BalanceBar.ProviderSwitchCoordinator",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "\(switchError.localizedDescription); \(restorationError.localizedDescription)"
                        ]
                    )
                    self.report(.failure(combined))
                }
            }
        }
    }

    private func report(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            actions.changed()
        case .failure(let error):
            actions.failed(tr(.keyProviderSwitchCoordinatorSwitchFailedValue, arguments: [error.localizedDescription]))
        }
    }
}
