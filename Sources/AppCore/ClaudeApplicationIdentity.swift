import Foundation

enum ClaudeApplicationIdentity {
    static let desktopBundleIdentifier = "com.anthropic.claudefordesktop"
    static let desktopLocalizedName = "Claude"

    /// Bundle id match is authoritative; the exact localized name is a
    /// fallback only. Look-alikes such as ClaudeBar never match.
    static func matchesDesktop(bundleIdentifier: String?, localizedName: String?) -> Bool {
        if bundleIdentifier?.lowercased() == desktopBundleIdentifier { return true }
        return localizedName?.lowercased() == desktopLocalizedName.lowercased()
    }
}
