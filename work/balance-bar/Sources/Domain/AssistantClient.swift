enum AssistantClient: String {
    case codex
    case claude

    var appType: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}
