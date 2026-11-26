import AppKit

enum CCSwitchApplicationLocator {
    static var applicationURL: URL? {
        if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
           ProcessInfo.processInfo.environment["BALANCEBAR_SIM_CCSWITCH_APP"] == "missing" {
            return nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ccswitch.desktop")
    }
}
