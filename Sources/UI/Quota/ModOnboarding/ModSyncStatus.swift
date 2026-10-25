import Foundation

/// What `claude plugin list --json` reports about one BalanceBar Mod installation entry.
struct ModPluginInstallation: Equatable {
    var scope: String
    var isEnabled: Bool
    var version: String?
    /// Parsed `installedAt`; drives the "installed but Claude Code is in use and still
    /// silent" distinction instead of guessing from unknown ages.
    var installedAt: Date?
}

/// Whether `claude plugin list --json` actually produced a usable answer. A failed
/// probe must never be presented as "not installed".
enum ModInstallationCheck: Equatable {
    case ok
    case failed(reason: String)
}

/// Read-only environment facts gathered off the main thread by `ModSyncDetector`.
struct ModEnvironment: Equatable {
    var claudeFound: Bool
    var claudeVersion: ClaudeCodeVersion?
    /// The plugin's user-scope entry, when present. Other scopes are reported separately:
    /// only a user-scope install counts as the cross-project installation this flow manages.
    var installation: ModPluginInstallation?
    var hasNonUserScopeInstall: Bool
    var installationCheck: ModInstallationCheck = .ok
    /// The default inbox exists, is writable and owned by the current user.
    var inboxReady: Bool
    /// Sampled on the main thread when detection starts, from the activity coordinator.
    var claudeProcessRunning: Bool
}

/// Why the last Mod snapshot did not become trusted evidence. Mirrors the inbox's
/// `SnapshotRejectionReason` in UI terms.
enum ModSnapshotRejection: Equatable {
    case accountMismatch
    case unverifiedCycle
}

struct ModRejectionEvent: Equatable {
    var rejection: ModSnapshotRejection
    var at: Date
}

/// What the snapshot evidence currently says (pipeline events, main-thread confined).
struct ModSnapshotEvidence: Equatable {
    var lastAcceptedAt: Date?
    var lastRejection: ModRejectionEvent?
}

/// The settings entry's honest state. Installed is never conflated with collecting:
/// only the merge engine's acceptance of a trusted snapshot produces `.active`.
enum ModSyncStatus: Equatable {
    case detecting
    case claudeMissing
    case claudeVersionTooOld(ClaudeCodeVersion)
    case inboxNotReady
    /// No user-scope install. `hasOtherScopeInstall` distinguishes a project/local
    /// install, which never counts as the cross-project installation.
    case notInstalled(hasOtherScopeInstall: Bool)
    /// `claude plugin list` failed, so the installation state is unknown, not "absent".
    case installationUnknown
    /// Installed but disabled: the Mod writes nothing until enabled again.
    case disabled
    /// Installed and enabled, no trusted snapshot accepted yet.
    case waitingForData
    /// The merge engine accepted a trusted snapshot; realtime is genuinely working.
    case active(lastAcceptedAt: Date)
    /// Installed and enabled, Claude Code is running, but no accepted data for the
    /// activity grace period — the session probably predates the install.
    case silent
    /// A newer snapshot was rejected than the last accepted one; realtime is not working.
    case snapshotRejected(ModRejectionEvent)

    /// Pure composition of environment facts and pipeline evidence.
    static func resolve(
        environment: ModEnvironment?,
        evidence: ModSnapshotEvidence,
        now: Date
    ) -> ModSyncStatus {
        guard let environment else { return .detecting }
        guard environment.claudeFound else { return .claudeMissing }
        if let version = environment.claudeVersion, version < ModOnboardingConfig.minimumClaudeCodeVersion {
            return .claudeVersionTooOld(version)
        }
        guard environment.inboxReady else { return .inboxNotReady }
        if case .failed = environment.installationCheck { return .installationUnknown }
        guard let installation = environment.installation else {
            return .notInstalled(hasOtherScopeInstall: environment.hasNonUserScopeInstall)
        }
        guard installation.isEnabled else { return .disabled }
        // A rejection newer than the last acceptance is the current situation; an older
        // one was superseded by accepted data.
        if let rejection = evidence.lastRejection,
           evidence.lastAcceptedAt.map({ rejection.at > $0 }) ?? true {
            return .snapshotRejected(rejection)
        }
        if let accepted = evidence.lastAcceptedAt {
            if now.timeIntervalSince(accepted) < ModOnboardingConfig.noDataWithActivityGrace {
                return .active(lastAcceptedAt: accepted)
            }
            if environment.claudeProcessRunning { return .silent }
            return .active(lastAcceptedAt: accepted)
        }
        if environment.claudeProcessRunning,
           let installedAt = installation.installedAt,
           now.timeIntervalSince(installedAt) >= ModOnboardingConfig.noDataWithActivityGrace {
            return .silent
        }
        return .waitingForData
    }
}
