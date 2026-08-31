import Foundation

enum ChatGPTLaunchDecision {
    static func shouldLaunchBalanceBar(
        launchedBundleIdentifier: String?,
        balanceBarIsRunning: Bool
    ) -> Bool {
        ChatGPTApplicationIdentity.matches(bundleIdentifier: launchedBundleIdentifier)
            && !balanceBarIsRunning
    }
}
