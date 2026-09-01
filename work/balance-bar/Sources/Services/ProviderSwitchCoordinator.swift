import Foundation

struct ProviderSwitchActions {
    let changed: () -> Void
    let failed: (String) -> Void
}

enum CCSwitchProviderSwitchBridgeError: LocalizedError, Equatable {
    case unavailable
    case databaseVerificationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "CC Switch does not expose a supported provider-switch bridge."
        case .databaseVerificationFailed:
            return "CC Switch did not verify the requested provider switch."
        }
    }
}

/// An implementation must call a supported CC Switch control surface which
/// executes the running process's own ProviderService::switch transaction and
/// returns only after that transaction has completed. It must not mutate CC
/// Switch files or activate/reopen its window itself.
protocol CCSwitchProviderSwitching {
    var isAvailable: Bool { get }
    func switchProvider(providerID: String, appType: String) throws
}

/// CC Switch currently has no documented cross-process provider-switch
/// contract. Keep the legacy stop/write/reopen path available until one is
/// supplied, but make the hot-switch seam explicit and injectable.
final class CCSwitchUnavailableProviderSwitchBridge: CCSwitchProviderSwitching {
    let isAvailable = false

    func switchProvider(providerID: String, appType: String) throws {
        _ = providerID
        _ = appType
        throw CCSwitchProviderSwitchBridgeError.unavailable
    }
}

/// Owns the CC Switch hot-switch path and the bounded legacy
/// stop/write/reopen fallback. The composition root supplies the selected
/// Provider and routes success/failure into refresh.
final class ProviderSwitchCoordinator {
    private let repository: CCSwitchRepository
    private let runtime: CCSwitchRuntimeControlling
    private let providerSwitchBridge: CCSwitchProviderSwitching
    private let queue: DispatchQueue
    private let actions: ProviderSwitchActions

    init(
        repository: CCSwitchRepository,
        runtime: CCSwitchRuntimeControlling = CCSwitchRuntimeController(),
        providerSwitchBridge: CCSwitchProviderSwitching = CCSwitchUnavailableProviderSwitchBridge(),
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.provider-switch"),
        actions: ProviderSwitchActions
    ) {
        self.repository = repository
        self.runtime = runtime
        self.providerSwitchBridge = providerSwitchBridge
        self.queue = queue
        self.actions = actions
    }

    func switchProvider(providerID: String, appType: String, providerName: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let current = self.repository.loadChoices(appType: appType).first(where: { $0.isCurrent })
            guard current?.id != providerID else { return }
            let runtimeSnapshot = self.runtime.snapshot()
            if runtimeSnapshot.wasRunning,
               self.providerSwitchBridge.isAvailable {
                self.switchThroughRunningCCSwitch(
                    providerID: providerID,
                    appType: appType
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
                    throw NSError(domain: "BalanceBar.SwitchValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: tr(.keyProviderSwitchCoordinatorDatabaseVerificationFailed)])
                }
                self.finish(.success(()), restoring: runtimeSnapshot)
            } catch {
                self.finish(.failure(error), restoring: runtimeSnapshot)
            }
        }
    }

    private func switchThroughRunningCCSwitch(providerID: String, appType: String) {
        do {
            // The bridge owns the complete in-process transaction, including
            // settings cache, DB/live projection, MCP, and proxy semantics.
            // Do not call CCSwitchRepository.switchCurrent on this path.
            try providerSwitchBridge.switchProvider(providerID: providerID, appType: appType)
            guard repository.loadChoices(appType: appType).first(where: { $0.isCurrent })?.id == providerID else {
                throw CCSwitchProviderSwitchBridgeError.databaseVerificationFailed
            }
            actions.changed()
        } catch {
            report(.failure(error))
        }
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
