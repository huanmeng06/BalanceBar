import Foundation

struct ProviderSwitchActions {
    let changed: () -> Void
    let failed: (String) -> Void
}

/// Owns the CC Switch stop/write/reopen transaction. The composition root only
/// supplies the selected Provider and routes success/failure into refresh.
final class ProviderSwitchCoordinator {
    private let repository: CCSwitchRepository
    private let runtime: CCSwitchRuntimeControlling
    private let queue: DispatchQueue
    private let actions: ProviderSwitchActions

    init(
        repository: CCSwitchRepository,
        runtime: CCSwitchRuntimeControlling = CCSwitchRuntimeController(),
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.provider-switch"),
        actions: ProviderSwitchActions
    ) {
        self.repository = repository
        self.runtime = runtime
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

    private func finish(
        _ result: Result<Void, Error>,
        restoring snapshot: CCSwitchRuntimeSnapshot
    ) {
        if snapshot.wasRunning {
            runtime.restore(from: snapshot)
        }

        switch result {
        case .success:
            actions.changed()
        case .failure(let error):
            actions.failed(tr(.keyProviderSwitchCoordinatorSwitchFailedValue, arguments: [String(describing: error.localizedDescription)]))
        }
    }
}
