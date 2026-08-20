import AppKit

struct ProviderSwitchActions {
    let changed: () -> Void
    let failed: (String) -> Void
}

/// Owns the CC Switch stop/write/reopen transaction. The composition root only
/// supplies the selected Provider and routes success/failure into refresh.
final class ProviderSwitchCoordinator {
    private let repository: CCSwitchRepository
    private let queue: DispatchQueue
    private let actions: ProviderSwitchActions

    init(
        repository: CCSwitchRepository,
        queue: DispatchQueue = DispatchQueue(label: "local.balancebar.provider-switch"),
        actions: ProviderSwitchActions
    ) {
        self.repository = repository
        self.queue = queue
        self.actions = actions
    }

    func switchProvider(providerID: String, appType: String, providerName: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let current = self.repository.loadChoices(appType: appType).first(where: { $0.isCurrent })
            guard current?.id != providerID else { return }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ccswitch.desktop").first
            let applicationURL = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ccswitch.desktop")
            if let running {
                running.terminate()
                let deadline = Date().addingTimeInterval(4)
                while !running.isTerminated && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                guard running.isTerminated else {
                    self.actions.failed(tr("切换失败：CC Switch 未能正常重载", "Switch failed: CC Switch could not reload normally"))
                    return
                }
            }
            do {
                try self.repository.switchCurrent(to: providerID, appType: appType)
                guard self.repository.loadChoices(appType: appType).first(where: { $0.isCurrent })?.id == providerID else {
                    throw NSError(domain: "BalanceBar.SwitchValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("数据库校验未通过", "Database verification failed")])
                }
                if running != nil, let applicationURL {
                    DispatchQueue.main.async {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        configuration.hides = true
                        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, _ in }
                    }
                }
                self.actions.changed()
            } catch {
                if running != nil, let applicationURL {
                    DispatchQueue.main.async {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        configuration.hides = true
                        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, _ in }
                    }
                }
                self.actions.failed(tr("切换失败：\(error.localizedDescription)", "Switch failed: \(error.localizedDescription)"))
            }
        }
    }
}
