import AppKit

enum CCSwitchPresentationState: Equatable {
    case notRunning
    case trayOnly
    case visibleInactive
    case visibleActive
}

enum CCSwitchRuntimeError: LocalizedError, Equatable {
    case applicationURLUnavailable
    case launchTimedOut
    case launchCompletionMissing
    case launchFailed(String)
    case processDidNotStart
    case presentationDidNotRestore
    case activePresentationDidNotRestore
    case previousForegroundUnavailable
    case previousForegroundDidNotRestore
    case trayPresentationDidNotRestore

    var errorDescription: String? {
        switch self {
        case .applicationURLUnavailable:
            return "CC Switch application URL is unavailable."
        case .launchTimedOut:
            return "CC Switch did not respond to the launch request in time."
        case .launchCompletionMissing:
            return "CC Switch returned no launch result."
        case .launchFailed(let message):
            return "CC Switch launch failed: \(message)"
        case .processDidNotStart:
            return "CC Switch did not start after the launch request."
        case .presentationDidNotRestore:
            return "CC Switch did not expose a visible window after relaunch."
        case .activePresentationDidNotRestore:
            return "CC Switch did not become active after relaunch."
        case .previousForegroundUnavailable:
            return "The previously active application could not be identified."
        case .previousForegroundDidNotRestore:
            return "The previously active application could not be restored."
        case .trayPresentationDidNotRestore:
            return "CC Switch did not return to its tray-only presentation."
        }
    }
}

/// The only supported cross-process request available to BalanceBar is an
/// application open. Its completion is intentionally part of the abstraction:
/// a submitted request is not the same thing as a restored CC Switch window.
protocol CCSwitchApplicationLaunching {
    func launch(
        at applicationURL: URL,
        hides: Bool,
        activates: Bool,
        completion: @escaping (pid_t?, Error?) -> Void
    )
}

final class CCSwitchWorkspaceApplicationLauncher: CCSwitchApplicationLaunching {
    func launch(
        at applicationURL: URL,
        hides: Bool,
        activates: Bool,
        completion: @escaping (pid_t?, Error?) -> Void
    ) {
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = activates
            configuration.hides = hides
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                completion(application?.processIdentifier, error)
            }
        }
    }
}

struct CCSwitchRuntimeSnapshot: Equatable {
    let state: CCSwitchPresentationState
    let applicationURL: URL?

    fileprivate let runningApplication: NSRunningApplication?
    fileprivate let previousFrontmostProcessIdentifier: pid_t?

    init(
        state: CCSwitchPresentationState,
        applicationURL: URL? = nil,
        previousFrontmostProcessIdentifier: pid_t? = nil
    ) {
        self.state = state
        self.applicationURL = applicationURL
        self.runningApplication = nil
        self.previousFrontmostProcessIdentifier = previousFrontmostProcessIdentifier
    }

    fileprivate init(
        state: CCSwitchPresentationState,
        applicationURL: URL?,
        runningApplication: NSRunningApplication?,
        previousFrontmostProcessIdentifier: pid_t?
    ) {
        self.state = state
        self.applicationURL = applicationURL
        self.runningApplication = runningApplication
        self.previousFrontmostProcessIdentifier = previousFrontmostProcessIdentifier
    }

    var wasRunning: Bool {
        state != .notRunning
    }

    var restorationPreconditionError: CCSwitchRuntimeError? {
        if state == .visibleInactive,
           previousFrontmostProcessIdentifier == nil {
            return .previousForegroundUnavailable
        }
        return nil
    }

    static func == (lhs: CCSwitchRuntimeSnapshot, rhs: CCSwitchRuntimeSnapshot) -> Bool {
        lhs.state == rhs.state && lhs.applicationURL == rhs.applicationURL
    }
}

protocol CCSwitchRuntimeControlling {
    func snapshot() -> CCSwitchRuntimeSnapshot
    func terminateAndWait(for snapshot: CCSwitchRuntimeSnapshot, timeout: TimeInterval) -> Bool
    /// Completion means that the requested presentation has been observed, or
    /// that restoration failed with an explicit error.
    func restore(
        from snapshot: CCSwitchRuntimeSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

final class CCSwitchRuntimeController: CCSwitchRuntimeControlling {
    static let bundleIdentifier = "com.ccswitch.desktop"

    private let runningApplicationProvider: () -> NSRunningApplication?
    private let previousFrontmostProcessIdentifierProvider: () -> pid_t?
    private let windowInfoProvider: () -> [[String: Any]]
    private let processExistsProvider: (pid_t) -> Bool
    private let activeStateProvider: (pid_t) -> Bool
    private let hideApplication: (pid_t) -> Bool
    private let activateApplication: (pid_t) -> Bool
    private let applicationLauncher: CCSwitchApplicationLaunching
    private let restorationTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let restorationQueue: DispatchQueue

    init(
        runningApplicationProvider: @escaping () -> NSRunningApplication? = {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: CCSwitchRuntimeController.bundleIdentifier
            ).first
        },
        previousFrontmostProcessIdentifierProvider: @escaping () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        windowInfoProvider: @escaping () -> [[String: Any]] = {
            (CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]) ?? []
        },
        processExistsProvider: @escaping (pid_t) -> Bool = { processIdentifier in
            NSRunningApplication.runningApplications(
                withBundleIdentifier: CCSwitchRuntimeController.bundleIdentifier
            ).contains { $0.processIdentifier == processIdentifier }
        },
        activeStateProvider: @escaping (pid_t) -> Bool = { processIdentifier in
            NSRunningApplication.runningApplications(
                withBundleIdentifier: CCSwitchRuntimeController.bundleIdentifier
            ).first { $0.processIdentifier == processIdentifier }?.isActive ?? false
        },
        hideApplication: @escaping (pid_t) -> Bool = { processIdentifier in
            guard let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: CCSwitchRuntimeController.bundleIdentifier
            ).first(where: { $0.processIdentifier == processIdentifier }) else {
                return false
            }
            return application.hide()
        },
        activateApplication: @escaping (pid_t) -> Bool = { processIdentifier in
            guard let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: CCSwitchRuntimeController.bundleIdentifier
            ).first(where: { $0.processIdentifier == processIdentifier }) else {
                return false
            }
            return application.activate(options: [])
        },
        applicationLauncher: CCSwitchApplicationLaunching = CCSwitchWorkspaceApplicationLauncher(),
        restorationTimeout: TimeInterval = 4,
        pollInterval: TimeInterval = 0.05,
        restorationQueue: DispatchQueue = DispatchQueue(
            label: "local.balancebar.cc-switch-restore",
            qos: .userInitiated
        )
    ) {
        self.runningApplicationProvider = runningApplicationProvider
        self.previousFrontmostProcessIdentifierProvider = previousFrontmostProcessIdentifierProvider
        self.windowInfoProvider = windowInfoProvider
        self.processExistsProvider = processExistsProvider
        self.activeStateProvider = activeStateProvider
        self.hideApplication = hideApplication
        self.activateApplication = activateApplication
        self.applicationLauncher = applicationLauncher
        self.restorationTimeout = max(0, restorationTimeout)
        self.pollInterval = max(0.001, pollInterval)
        self.restorationQueue = restorationQueue
    }

    func snapshot() -> CCSwitchRuntimeSnapshot {
        guard let running = runningApplicationProvider() else {
            return CCSwitchRuntimeSnapshot(state: .notRunning)
        }

        let hasVisibleWindow = Self.hasVisibleStandardWindow(
            for: running.processIdentifier,
            windowInfo: windowInfoProvider()
        )
        let state: CCSwitchPresentationState
        if !hasVisibleWindow {
            state = .trayOnly
        } else if running.isActive {
            state = .visibleActive
        } else {
            state = .visibleInactive
        }

        let applicationURL = running.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
        return CCSwitchRuntimeSnapshot(
            state: state,
            applicationURL: applicationURL,
            runningApplication: running,
            previousFrontmostProcessIdentifier: previousFrontmostProcessIdentifierProvider()
        )
    }

    func terminateAndWait(for snapshot: CCSwitchRuntimeSnapshot, timeout: TimeInterval) -> Bool {
        guard let running = snapshot.runningApplication else { return true }

        running.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while !running.isTerminated && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return running.isTerminated
    }

    func restore(
        from snapshot: CCSwitchRuntimeSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard snapshot.state != .notRunning else {
            completion(.success(()))
            return
        }
        guard let applicationURL = snapshot.applicationURL else {
            completion(.failure(CCSwitchRuntimeError.applicationURLUnavailable))
            return
        }
        if snapshot.state == .visibleInactive,
           snapshot.previousFrontmostProcessIdentifier == nil {
            completion(.failure(CCSwitchRuntimeError.previousForegroundUnavailable))
            return
        }

        restorationQueue.async { [weak self] in
            guard let self else { return }
            completion(self.restoreSynchronously(from: snapshot, applicationURL: applicationURL))
        }
    }

    private func restoreSynchronously(
        from snapshot: CCSwitchRuntimeSnapshot,
        applicationURL: URL
    ) -> Result<Void, Error> {
        // The first launch is deliberately hidden and non-activating. These
        // flags are only launch hints: CC Switch can override them during its
        // Tauri startup or Lightweight Mode lifecycle, so no success is
        // reported until the resulting process/window state is observed.
        switch launch(
            at: applicationURL,
            hides: true,
            activates: false
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let launchedProcessIdentifier):
            guard let processIdentifier = waitForProcess(
                preferredProcessIdentifier: launchedProcessIdentifier
            ) else {
                return .failure(CCSwitchRuntimeError.processDidNotStart)
            }
            return restorePresentation(
                snapshot,
                applicationURL: applicationURL,
                processIdentifier: processIdentifier
            )
        }
    }

    private func restorePresentation(
        _ snapshot: CCSwitchRuntimeSnapshot,
        applicationURL: URL,
        processIdentifier: pid_t
    ) -> Result<Void, Error> {
        switch snapshot.state {
        case .notRunning:
            return .success(())
        case .trayOnly:
            guard hideApplication(processIdentifier) else {
                return .failure(CCSwitchRuntimeError.trayPresentationDidNotRestore)
            }
            guard waitUntil({
                !Self.hasVisibleStandardWindow(
                    for: processIdentifier,
                    windowInfo: windowInfoProvider()
                )
            }) else {
                return .failure(CCSwitchRuntimeError.trayPresentationDidNotRestore)
            }
            if let previousProcessIdentifier = snapshot.previousFrontmostProcessIdentifier,
               !restorePreviousForeground(
                   previousProcessIdentifier,
                   processIdentifier: processIdentifier
               ) {
                return .failure(CCSwitchRuntimeError.previousForegroundDidNotRestore)
            }
            return .success(())
        case .visibleInactive, .visibleActive:
            // CC Switch's documented macOS surface does not expose a
            // non-focusing "show main window" operation. Opening the running
            // app is therefore used only as a compatibility bridge to its
            // own Reopen handler, which may recreate Lightweight Mode's
            // destroyed Tauri window. The bridge is never considered success
            // by itself: both window evidence and the requested foreground
            // state must be observed below.
            switch launch(
                at: applicationURL,
                hides: false,
                activates: false
            ) {
            case .failure(let error):
                if let previousProcessIdentifier = snapshot.previousFrontmostProcessIdentifier {
                    _ = restorePreviousForeground(
                        previousProcessIdentifier,
                        processIdentifier: processIdentifier
                    )
                }
                return .failure(error)
            case .success(let reopenedProcessIdentifier):
                guard let reopenedProcessIdentifier = waitForProcess(
                    preferredProcessIdentifier: reopenedProcessIdentifier ?? processIdentifier
                ) else {
                    if let previousProcessIdentifier = snapshot.previousFrontmostProcessIdentifier {
                        _ = restorePreviousForeground(
                            previousProcessIdentifier,
                            processIdentifier: processIdentifier
                        )
                    }
                    return .failure(CCSwitchRuntimeError.processDidNotStart)
                }

                let presentationResult: Result<Void, Error>
                if waitUntil({
                    Self.hasVisibleStandardWindow(
                        for: reopenedProcessIdentifier,
                        windowInfo: windowInfoProvider()
                    )
                }) {
                    if snapshot.state == .visibleActive {
                        presentationResult = waitUntil({
                            activeStateProvider(reopenedProcessIdentifier)
                        })
                            ? .success(())
                            : .failure(CCSwitchRuntimeError.activePresentationDidNotRestore)
                    } else {
                        presentationResult = .success(())
                    }
                } else {
                    presentationResult = .failure(CCSwitchRuntimeError.presentationDidNotRestore)
                }

                guard snapshot.state == .visibleInactive,
                      let previousProcessIdentifier = snapshot.previousFrontmostProcessIdentifier else {
                    return presentationResult
                }

                // CC Switch's Reopen handler currently calls set_focus. For
                // visibleInactive we compensate explicitly and verify the
                // previous foreground app is back before reporting success.
                // If the window probe failed, still make a best-effort focus
                // cleanup so a failed switch does not leave CC Switch active.
                let foregroundRestored = restorePreviousForeground(
                    previousProcessIdentifier,
                    processIdentifier: reopenedProcessIdentifier
                )
                switch presentationResult {
                case .success where foregroundRestored:
                    return .success(())
                case .success:
                    return .failure(CCSwitchRuntimeError.previousForegroundDidNotRestore)
                case .failure(let error):
                    _ = foregroundRestored
                    return .failure(error)
                }
            }
        }
    }

    private func launch(
        at applicationURL: URL,
        hides: Bool,
        activates: Bool
    ) -> Result<pid_t?, Error> {
        var launchResult: Result<pid_t?, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        applicationLauncher.launch(
            at: applicationURL,
            hides: hides,
            activates: activates
        ) { processIdentifier, error in
            if let error {
                launchResult = .failure(CCSwitchRuntimeError.launchFailed(error.localizedDescription))
            } else {
                launchResult = .success(processIdentifier)
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + restorationTimeout) == .success else {
            return .failure(CCSwitchRuntimeError.launchTimedOut)
        }
        return launchResult ?? .failure(CCSwitchRuntimeError.launchCompletionMissing)
    }

    private func waitForProcess(preferredProcessIdentifier: pid_t?) -> pid_t? {
        var processIdentifier = preferredProcessIdentifier
        guard waitUntil({
            if let processIdentifier {
                return processExistsProvider(processIdentifier)
            }
            guard let discovered = runningApplicationProvider()?.processIdentifier else {
                return false
            }
            processIdentifier = discovered
            return processExistsProvider(discovered)
        }) else {
            return nil
        }
        return processIdentifier
    }

    private func restorePreviousForeground(
        _ previousProcessIdentifier: pid_t,
        processIdentifier: pid_t
    ) -> Bool {
        if previousFrontmostProcessIdentifierProvider() == previousProcessIdentifier,
           !activeStateProvider(processIdentifier) {
            return true
        }
        guard activateApplication(previousProcessIdentifier) else { return false }
        return waitUntil {
            previousFrontmostProcessIdentifierProvider() == previousProcessIdentifier
                && !activeStateProvider(processIdentifier)
        }
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(restorationTimeout)
        while true {
            if condition() { return true }
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    static func hasVisibleStandardWindow(
        for processIdentifier: pid_t,
        windowInfo: [[String: Any]]
    ) -> Bool {
        windowInfo.contains { window in
            guard
                (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                !bounds.isEmpty
            else {
                return false
            }
            return true
        }
    }
}
