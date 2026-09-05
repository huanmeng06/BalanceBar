enum AssistantClient: String {
    case codex
    case claude
    case grok

    /// CC Switch application type used for provider reads. Grok maps to the
    /// existing `grokbuild` app type; this Issue does not write Grok configs.
    var appType: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .grok: return "grokbuild"
        }
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .grok: return "Grok"
        }
    }

    var usesRotationAnimation: Bool {
        switch self {
        case .codex:
            return true
        case .claude, .grok:
            return false
        }
    }
}
