import AppKit

struct ProviderSwitchActions {
    let changed: () -> Void
    let failed: (String) -> Void
}

struct ProviderSwitchRuntime {
    struct Instance {
        let applicationURL: URL?
        let terminate: () -> Bool
        let isTerminated: () -> Bool
    }
    let running: () -> Instance?
    let reopen: (URL) -> Void

    static let live = ProviderSwitchRuntime(running: {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ccswitch.desktop").first else { return nil }
        return Instance(applicationURL: app.bundleURL, terminate: { app.terminate() }, isTerminated: { app.isTerminated })
    }, reopen: { url in
        DispatchQueue.main.async {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.ccswitch.desktop").isEmpty else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
    })
}

/// Owns the CC Switch stop/write/reopen transaction. The composition root only
/// supplies the selected Provider and routes success/failure into refresh.
final class ProviderSwitchCoordinator {
    private let repository: CCSwitchRepository
    private let aggregationRepository: CCSwitchAggregationRepository
    private let queue: DispatchQueue
    private let actions: ProviderSwitchActions
    private let runtime: ProviderSwitchRuntime
    private let isClientCurrent: (String) -> Bool

    init(
        repository: CCSwitchRepository,
        aggregationRepository: CCSwitchAggregationRepository? = nil,
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.provider-switch"),
        runtime: ProviderSwitchRuntime = .live,
        isClientCurrent: @escaping (String) -> Bool = { _ in true },
        actions: ProviderSwitchActions
    ) {
        self.repository = repository
        self.aggregationRepository = aggregationRepository ?? CCSwitchAggregationRepository(repository: repository)
        self.queue = queue
        self.actions = actions
        self.runtime = runtime
        self.isClientCurrent = isClientCurrent
    }

    func switchProvider(providerID: String, appType: String, providerName: String) {
        queue.async { [weak self] in
            guard let self else { return }
            func safety() -> CCSwitchQuickSwitchSafety {
                appType == "codex" ? self.aggregationRepository.quickSwitchSafety() : self.repository.quickSwitchSafety(appType: appType)
            }
            guard !safety().isBlocked else {
                self.actions.failed(safety().hint)
                return
            }
            let current: ProviderChoice?
            do { current = try self.repository.loadChoicesChecked(appType: appType).first(where: { $0.isCurrent }) }
            catch {
                self.actions.failed(tr(.keyCCSwitchRepositoryUnableToOpenTheCcSwitchDatabase))
                return
            }
            guard current?.id != providerID else { return }
            guard let current,
                  let currentRevision = self.repository.configurationRevision(appType: appType, providerID: current.id),
                  let targetRevision = self.repository.configurationRevision(appType: appType, providerID: providerID) else {
                self.actions.failed(tr(.keyQuickSwitchStateUntrusted))
                return
            }
            func validate() -> Bool {
                self.isClientCurrent(appType)
                    && !safety().isBlocked
                    && self.repository.configurationRevision(appType: appType, providerID: current.id) == currentRevision
                    && self.repository.configurationRevision(appType: appType, providerID: providerID) == targetRevision
                    && self.repository.loadChoices(appType: appType).first(where: { $0.isCurrent })?.id == current.id
            }
            let running = self.runtime.running()
            guard validate() else { self.actions.failed(tr(.keyQuickSwitchStateUntrusted)); return }
            var stopped = false
            defer {
                if stopped, self.runtime.running() == nil, let url = running?.applicationURL { self.runtime.reopen(url) }
            }
            if let running {
                guard !running.isTerminated(), running.terminate() else {
                    self.actions.failed(tr(.keyProviderSwitchCoordinatorSwitchFailedCcSwitchCouldNotReloadNormally))
                    return
                }
                let deadline = Date().addingTimeInterval(4)
                while !running.isTerminated() && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                guard running.isTerminated() else {
                    self.actions.failed(tr(.keyProviderSwitchCoordinatorSwitchFailedCcSwitchCouldNotReloadNormally))
                    return
                }
                stopped = true
            }
            guard validate(), !stopped || self.runtime.running() == nil else {
                self.actions.failed(tr(.keyQuickSwitchStateUntrusted))
                return
            }
            do {
                try self.repository.switchCurrent(to: providerID, appType: appType,
                    expectedCurrentRevision: currentRevision, expectedTargetRevision: targetRevision)
                guard self.repository.loadChoices(appType: appType).first(where: { $0.isCurrent })?.id == providerID else {
                    throw NSError(domain: "BalanceBar.SwitchValidation", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: tr(.keyProviderSwitchCoordinatorDatabaseVerificationFailed)])
                }
                self.actions.changed()
            } catch {
                self.actions.failed(tr(.keyProviderSwitchCoordinatorSwitchFailedValue, arguments: [error.localizedDescription]))
            }
        }
    }
}
