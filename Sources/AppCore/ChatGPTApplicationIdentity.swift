import Foundation

enum ChatGPTApplicationIdentity {
    static let bundleIdentifiers = [
        "com.openai.codex",
        "com.openai.chat"
    ]

    static func matches(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
    }
}
