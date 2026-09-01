import AppKit

enum CCSwitchPresentationState: Equatable {
    case notRunning
    case trayOnly
    case visibleInactive
    case visibleActive

    var restoration: CCSwitchPresentationRestoration? {
        switch self {
        case .notRunning:
            return nil
        case .trayOnly:
            return CCSwitchPresentationRestoration(hides: true, activates: false)
        case .visibleInactive:
            return CCSwitchPresentationRestoration(hides: false, activates: false)
        case .visibleActive:
            return CCSwitchPresentationRestoration(hides: false, activates: true)
        }
    }
}

struct CCSwitchPresentationRestoration: Equatable {
    let hides: Bool
    let activates: Bool
}

struct CCSwitchRuntimeSnapshot: Equatable {
    let state: CCSwitchPresentationState
    let applicationURL: URL?

    fileprivate let runningApplication: NSRunningApplication?

    init(state: CCSwitchPresentationState, applicationURL: URL? = nil) {
        self.state = state
        self.applicationURL = applicationURL
        self.runningApplication = nil
    }

    fileprivate init(
        state: CCSwitchPresentationState,
        applicationURL: URL?,
        runningApplication: NSRunningApplication?
    ) {
        self.state = state
        self.applicationURL = applicationURL
        self.runningApplication = runningApplication
    }

    var wasRunning: Bool {
        state != .notRunning
    }

    static func == (lhs: CCSwitchRuntimeSnapshot, rhs: CCSwitchRuntimeSnapshot) -> Bool {
        lhs.state == rhs.state && lhs.applicationURL == rhs.applicationURL
    }
}

protocol CCSwitchRuntimeControlling {
    func snapshot() -> CCSwitchRuntimeSnapshot
    func terminateAndWait(for snapshot: CCSwitchRuntimeSnapshot, timeout: TimeInterval) -> Bool
    func restore(from snapshot: CCSwitchRuntimeSnapshot)
}

final class CCSwitchRuntimeController: CCSwitchRuntimeControlling {
    static let bundleIdentifier = "com.ccswitch.desktop"

    private let windowInfoProvider: () -> [[String: Any]]

    init(
        windowInfoProvider: @escaping () -> [[String: Any]] = {
            (CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]) ?? []
        }
    ) {
        self.windowInfoProvider = windowInfoProvider
    }

    func snapshot() -> CCSwitchRuntimeSnapshot {
        guard let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).first else {
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
            runningApplication: running
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

    func restore(from snapshot: CCSwitchRuntimeSnapshot) {
        guard let restoration = snapshot.state.restoration,
              let applicationURL = snapshot.applicationURL else { return }

        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = restoration.activates
            configuration.hides = restoration.hides
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, _ in }
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
