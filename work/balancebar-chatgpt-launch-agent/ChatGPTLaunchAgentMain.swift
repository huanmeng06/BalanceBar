import AppKit

@main
enum ChatGPTLaunchAgentMain {
    static func main() {
        guard let balanceBarBundleURL = ChatGPTLaunchAgentRuntime.containingAppBundleURL(),
              let balanceBarBundleIdentifier = Bundle(url: balanceBarBundleURL)?.bundleIdentifier
        else {
            NSLog("BalanceBar ChatGPT launch agent could not locate its containing app bundle")
            return
        }

        let runtime = ChatGPTLaunchAgentRuntime(
            workspace: SystemChatGPTLaunchAgentWorkspace(),
            balanceBarBundleURL: balanceBarBundleURL,
            balanceBarBundleIdentifier: balanceBarBundleIdentifier
        )
        runtime.start()
        withExtendedLifetime(runtime) {
            RunLoop.main.run()
        }
    }
}
