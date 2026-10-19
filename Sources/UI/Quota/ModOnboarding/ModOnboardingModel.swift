import Foundation

/// Thresholds for the BalanceBar Mod onboarding. Kept in one place so tests and views agree.
enum ModOnboardingConfig {
    /// The menu prompt stays hidden while Mod data newer than this exists.
    static let modDataFreshnessWindow: TimeInterval = 7 * 24 * 60 * 60
    /// An enabled Mod that stays silent this long while Claude Code is active is reported as "no data".
    static let noDataWithActivityGrace: TimeInterval = 10 * 60
    static let minimumClaudeCodeVersion = ClaudeCodeVersion(major: 2, minor: 1, patch: 287)
}

/// Parsed `claude --version` value (for example "2.1.291 (Claude Code)").
struct ClaudeCodeVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    static func parse(_ text: String) -> ClaudeCodeVersion? {
        let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count >= 3, let major = parts[0], let minor = parts[1], let patch = parts[2] else { return nil }
        return ClaudeCodeVersion(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// What is known about the installed Claude Code.
enum ClaudeCodeVersionStatus: Equatable {
    /// Not detected yet; the installer decides (it falls back to "copy command" if `claude` is missing).
    case unknown
    case detected(ClaudeCodeVersion)
}

/// Headless (`claude -p` / Agent SDK) signal from the BB-12 adapter. Tests use a fake.
protocol ModHeadlessSignalProviding {
    /// True when the headless signal protocol says the Mod is worth offering.
    var isSatisfied: Bool { get }
}

struct ModPromptInputs: Equatable {
    /// Quota is read straight from the official endpoint (not a third-party relay).
    var isOfficialDirect: Bool
    var lastModDataAt: Date?
    var claudeCode: ClaudeCodeVersionStatus
    var promptDismissed: Bool
    /// A HUD snapshot exists; the headless signal must then be satisfied too.
    var hasHUDSnapshot: Bool
    var headlessSignalSatisfied: Bool

    init(
        isOfficialDirect: Bool,
        lastModDataAt: Date? = nil,
        claudeCode: ClaudeCodeVersionStatus = .unknown,
        promptDismissed: Bool = false,
        hasHUDSnapshot: Bool = false,
        headlessSignalSatisfied: Bool = true
    ) {
        self.isOfficialDirect = isOfficialDirect
        self.lastModDataAt = lastModDataAt
        self.claudeCode = claudeCode
        self.promptDismissed = promptDismissed
        self.hasHUDSnapshot = hasHUDSnapshot
        self.headlessSignalSatisfied = headlessSignalSatisfied
    }
}

enum ModPromptHiddenReason: Equatable {
    case notOfficialDirect
    case recentModData
    case claudeCodeTooOld
    case dismissed
    case headlessSignalNotSatisfied
}

enum ModPromptVisibility: Equatable {
    case visible
    case hidden(ModPromptHiddenReason)

    var isVisible: Bool { self == .visible }

    /// Menu prompt row display rule: official direct, no Mod data within 7 days, Claude Code >= v2.1.287,
    /// not dismissed, and (with a HUD snapshot) the headless signal satisfied.
    static func evaluate(_ inputs: ModPromptInputs, now: Date) -> ModPromptVisibility {
        guard inputs.isOfficialDirect else { return .hidden(.notOfficialDirect) }
        if let last = inputs.lastModDataAt, now.timeIntervalSince(last) < ModOnboardingConfig.modDataFreshnessWindow {
            return .hidden(.recentModData)
        }
        if case let .detected(version) = inputs.claudeCode, version < ModOnboardingConfig.minimumClaudeCodeVersion {
            return .hidden(.claudeCodeTooOld)
        }
        guard !inputs.promptDismissed else { return .hidden(.dismissed) }
        if inputs.hasHUDSnapshot, !inputs.headlessSignalSatisfied { return .hidden(.headlessSignalNotSatisfied) }
        return .visible
    }
}

/// Status shown in Settings > Advanced > Realtime boost.
enum ModEnhancementStatus: Equatable {
    case unsupportedClaudeCode(ClaudeCodeVersion)
    case notInstalled
    /// Installed, waiting for the first data (a new session is needed).
    case waitingForData
    case active(lastDataAt: Date)
    /// Installed, Claude Code is active, but no Mod data for `noDataWithActivityGrace`.
    case enabledButSilent

    static func resolve(
        installed: Bool,
        lastModDataAt: Date?,
        claudeActivityDetected: Bool,
        claudeCode: ClaudeCodeVersionStatus,
        now: Date
    ) -> ModEnhancementStatus {
        if case let .detected(version) = claudeCode, version < ModOnboardingConfig.minimumClaudeCodeVersion {
            return .unsupportedClaudeCode(version)
        }
        if let last = lastModDataAt, now.timeIntervalSince(last) < ModOnboardingConfig.noDataWithActivityGrace {
            return .active(lastDataAt: last)
        }
        guard installed || lastModDataAt != nil else { return .notInstalled }
        if claudeActivityDetected { return .enabledButSilent }
        if let last = lastModDataAt { return .active(lastDataAt: last) }
        return .waitingForData
    }
}
