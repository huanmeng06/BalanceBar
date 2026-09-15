import AppKit

protocol ChatGPTLaunchAgentWorkspace {
    var notificationCenter: NotificationCenter { get }

    func isApplicationRunning(bundleIdentifier: String) -> Bool
    func openApplication(
        at url: URL,
        activates: Bool,
        addsToRecentItems: Bool,
        completion: @escaping (Error?) -> Void
    )
}

final class SystemChatGPTLaunchAgentWorkspace: ChatGPTLaunchAgentWorkspace {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    var notificationCenter: NotificationCenter {
        workspace.notificationCenter
    }

    func isApplicationRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }

    func openApplication(
        at url: URL,
        activates: Bool,
        addsToRecentItems: Bool,
        completion: @escaping (Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.addsToRecentItems = addsToRecentItems
        workspace.openApplication(at: url, configuration: configuration) { _, error in
            completion(error)
        }
    }
}

final class ChatGPTLaunchAgentRuntime {
    private let workspace: ChatGPTLaunchAgentWorkspace
    private let balanceBarBundleURL: URL
    private let balanceBarBundleIdentifier: String
    private var observer: NSObjectProtocol?
    private(set) var launchInFlight = false

    init(
        workspace: ChatGPTLaunchAgentWorkspace,
        balanceBarBundleURL: URL,
        balanceBarBundleIdentifier: String
    ) {
        self.workspace = workspace
        self.balanceBarBundleURL = balanceBarBundleURL
        self.balanceBarBundleIdentifier = balanceBarBundleIdentifier
    }

    var isListening: Bool { observer != nil }

    func start() {
        guard observer == nil else { return }
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.handleLaunch(bundleIdentifier: application?.bundleIdentifier)
        }

        reconcileInitialChatGPTPresenceOnce()
    }

    func stop() {
        if let observer {
            workspace.notificationCenter.removeObserver(observer)
        }
        observer = nil
        launchInFlight = false
    }

    func handleLaunch(bundleIdentifier: String?) {
        guard isListening,
              ChatGPTLaunchDecision.shouldLaunchBalanceBar(
                  launchedBundleIdentifier: bundleIdentifier,
                  balanceBarIsRunning: workspace.isApplicationRunning(
                      bundleIdentifier: balanceBarBundleIdentifier
                  )
              ),
              !launchInFlight
        else { return }

        launchInFlight = true
        workspace.openApplication(
            at: balanceBarBundleURL,
            activates: false,
            addsToRecentItems: false
        ) { [weak self] error in
            if let error {
                NSLog("BalanceBar ChatGPT launch agent failed to open BalanceBar: %@", error.localizedDescription)
            }
            self?.launchInFlight = false
        }
    }

    private func reconcileInitialChatGPTPresenceOnce() {
        guard isListening else { return }

        for bundleIdentifier in ChatGPTApplicationIdentity.bundleIdentifiers {
            guard workspace.isApplicationRunning(bundleIdentifier: bundleIdentifier) else {
                continue
            }

            handleLaunch(bundleIdentifier: bundleIdentifier)
            break
        }
    }

    static func containingAppBundleURL(
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? ""),
        bundleURL: URL = Bundle.main.bundleURL
    ) -> URL? {
        [executableURL, bundleURL].compactMap(Self.appBundleURL(ancestorOf:)).first
    }

    private static func appBundleURL(ancestorOf url: URL) -> URL? {
        var candidate = url
        if candidate.pathExtension == "app" { return candidate }
        while candidate.path != candidate.deletingLastPathComponent().path {
            candidate = candidate.deletingLastPathComponent()
            if candidate.pathExtension == "app" { return candidate }
        }
        return nil
    }
}
