import AppKit

/// Composition point for the settings entry "Claude Code Mod 实时同步": aggregates the
/// background detector's environment facts with the pipeline's snapshot evidence, drives
/// the onboarding panel, and publishes the honest status for the settings row.
///
/// Main-thread confined. Pipeline/inbox events arrive on background queues and hop to
/// main in `ingest`. Detection is throttled; the heavy probes run on the detector's own
/// queue, never on the main thread.
final class ModSyncCoordinator {
    static let detectionThrottle: TimeInterval = 30

    let controller: ModOnboardingController
    private let detector: ModSyncDetector
    private let activityProvider: () -> Bool
    private let localizePanel: (ModOnboardingText) -> String
    private let localizeSync: (RealtimeBoostText) -> String
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    private(set) var status: ModSyncStatus = .detecting
    private var environment: ModEnvironment?
    private var evidence = ModSnapshotEvidence()
    private var detectionInFlight = false
    private var lastDetectionStartedAt = Date.distantPast
    /// Guards one-shot silence rechecks against a later status/evidence change.
    private var silenceScheduleGeneration: UInt64 = 0
    /// Invalidates queued card polls when Advanced/search stops showing Mod status.
    private var visibleRefreshGeneration: UInt64 = 0
    private var advancedStatusCardVisible = false
    /// The currently presented management panel; refreshed on every status change so an
    /// open panel never keeps showing "detecting" or a finished operation's page.
    private weak var presentedPanel: ModOnboardingPanelView?
    private lazy var managementWindow = ModOnboardingWindowController { [unowned self] in self.attachPanel() }

    /// Fired on the main thread whenever sync status changes.
    var onStatusChange: ((ModSyncStatus) -> Void)?
    /// Operation progress only; does not change sync facts or status notifications.
    var onPresentationChange: (() -> Void)?
    /// The Mod was found uninstalled or disabled (a successful check, or an in-app uninstall):
    /// the pipeline must stop treating its readings as live. Fired on the main thread.
    var onModUnavailable: (() -> Void)?
    /// A successful check found the Mod installed and enabled again.
    var onModAvailable: (() -> Void)?
    /// The "don't show this in the menu" preference changed; rebuild the status menu.
    var onPromptChange: (() -> Void)?

    init(
        controller: ModOnboardingController,
        detector: ModSyncDetector,
        activityProvider: @escaping () -> Bool,
        localizePanel: @escaping (ModOnboardingText) -> String = ModOnboardingText.defaultLocalize,
        localizeSync: @escaping (RealtimeBoostText) -> String = RealtimeBoostText.defaultLocalize,
        now: @escaping () -> Date = Date.init,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        }
    ) {
        self.controller = controller
        self.detector = detector
        self.activityProvider = activityProvider
        self.localizePanel = localizePanel
        self.localizeSync = localizeSync
        self.now = now
        self.schedule = schedule
        controller.onPresentationChange = { [weak self] in
            self?.onPresentationChange?()
        }
        controller.onInstallCompleted = { [weak self] result in
            // A (re)install invalidates the previous plugin's snapshot evidence: until a
            // new trusted snapshot arrives the status is "waiting for data", never active.
            if case .success = result { self?.resetSnapshotEvidence() }
            self?.startDetectionIfNeeded(force: true)
        }
        controller.onUninstallCompleted = { [weak self] result in
            if case .success = result {
                self?.onModUnavailable?()
                self?.resetSnapshotEvidence()
            }
            self?.startDetectionIfNeeded(force: true)
        }
    }

    /// The status menu's prompt row: official Claude provider only, and only while the
    /// Mod is confirmed not installed and the user has not dismissed the prompt.
    func menuRow(isOfficialDirect: Bool) -> ModMenuRow {
        ModMenuRow.resolve(
            isOfficialDirect: isOfficialDirect,
            status: status,
            promptDismissed: controller.isPromptDismissed)
    }

    /// Status plus its localized text, for the settings row and the panel header.
    var syncContext: ModPanelSyncContext {
        ModPanelSyncContext(
            status: status,
            statusText: RealtimeBoostPresentation.make(status: status, localize: localizeSync).statusText)
    }

    /// Runs detection at most once per throttle window unless forced (install/uninstall
    /// completions force it). The activity sample is taken here, on the main thread.
    func startDetectionIfNeeded(force: Bool = false) {
        let now = now()
        guard !detectionInFlight,
              force || now.timeIntervalSince(lastDetectionStartedAt) >= Self.detectionThrottle else { return }
        lastDetectionStartedAt = now
        detectionInFlight = true
        let processRunning = activityProvider()
        detector.detect(claudeProcessRunning: processRunning) { [weak self] environment in
            guard let self else { return }
            self.detectionInFlight = false
            self.environment = environment
            // An uninstall done outside BalanceBar (CLI / plugin manager) must invalidate
            // the old plugin's evidence just like the in-app path; a missing CLI or a failed
            // plugin-list check is not proof of removal. Disabling ends live eligibility the
            // same way: re-enabling must wait for a new snapshot.
            let modUnavailable = environment.claudeFound && environment.installationCheck == .ok
                && environment.installation?.isEnabled != true
            if modUnavailable {
                self.onModUnavailable?()
            } else if environment.claudeFound, environment.installationCheck == .ok {
                self.onModAvailable?()
            }
            if modUnavailable {
                self.resetSnapshotEvidence()
            } else {
                self.recomputeStatus()
            }
        }
    }

    /// Polls for external CLI changes only while the Advanced Mod card or its global
    /// search projection is visible. Each probe still uses the existing 30-second
    /// throttle, and `detectionInFlight` prevents overlapping CLI commands.
    func setAdvancedStatusCardVisible(_ visible: Bool) {
        guard advancedStatusCardVisible != visible else { return }
        advancedStatusCardVisible = visible
        visibleRefreshGeneration &+= 1
        guard visible else { return }
        let generation = visibleRefreshGeneration
        startDetectionIfNeeded()
        scheduleVisibleRefresh(generation: generation)
    }

    private func scheduleVisibleRefresh(generation: UInt64) {
        schedule(Self.detectionThrottle) { [weak self] in
            guard let self,
                  self.advancedStatusCardVisible,
                  self.visibleRefreshGeneration == generation else { return }
            self.startDetectionIfNeeded()
            self.scheduleVisibleRefresh(generation: generation)
        }
    }

    /// Receives one pipeline snapshot event. Safe to call from any thread.
    func ingest(_ event: ClaudeQuotaPipeline.ModSnapshotEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch event.kind {
            case let .processed(accepted):
                guard accepted else { break }
                let at = event.observedAt ?? event.receivedAt
                if self.evidence.lastAcceptedAt.map({ at > $0 }) ?? true {
                    self.evidence.lastAcceptedAt = at
                }
            case let .rejected(reason):
                self.evidence.lastRejection = ModRejectionEvent(
                    rejection: Self.uiRejection(reason), at: event.receivedAt)
            case .accountChanged:
                // Snapshot evidence belongs to the account that produced it; a switch must
                // never let the new account inherit the old one's "realtime" display.
                self.resetSnapshotEvidence()
            }
            self.recomputeStatus()
        }
    }

    /// Open from the single settings entry, with a parent that owns its lifetime.
    func presentPanel(from anchor: NSView) {
        guard let owner = anchor.window else { return }
        managementWindow.show(owner: owner)
        startDetectionIfNeeded()
    }

    /// Open the explanation panel on its own (status-menu prompt). Deliberately does not
    /// touch the dashboard: the reminder must show the small window only.
    func presentPanelStandalone() {
        managementWindow.show()
        startDetectionIfNeeded()
    }

    /// Builds the management panel for presentation: resets finished operation pages to
    /// the management intro (running operations keep their progress) and registers the
    /// panel so later status changes refresh it live.
    func attachPanel() -> ModOnboardingPanelView {
        // "View error" in Advanced must retain the actual CLI failure and retry.
        // Successful pages still reset to the current management state on reopen.
        switch controller.state {
        case .failed, .uninstallFailed: break
        default: controller.resetToIntro()
        }
        let panel = ModOnboardingPanelView(
            controller: controller,
            localize: localizePanel,
            syncProvider: { [weak self] in self.map { $0.syncContext } })
        panel.onRequestRefresh = { [weak self] in self?.startDetectionIfNeeded(force: true) }
        panel.onPromptPreferenceChange = { [weak self] in self?.onPromptChange?() }
        presentedPanel = panel
        return panel
    }

    /// Drops all accepted/rejected snapshot evidence and recomputes the status.
    private func resetSnapshotEvidence() {
        evidence = ModSnapshotEvidence()
        recomputeStatus()
    }

    private func recomputeStatus() {
        let newStatus = ModSyncStatus.resolve(environment: environment, evidence: evidence, now: now())
        // Even when the status string is unchanged a new accepted snapshot moves the
        // silence deadline, so the recheck is scheduled before the equality guard.
        scheduleSilenceRecheck(for: newStatus)
        guard newStatus != status else { return }
        status = newStatus
        presentedPanel?.reload()
        onStatusChange?(status)
    }

    /// The status only changes when something recomputes it; time passing is not an
    /// event. Schedule one detection at the grace deadline so "active" can become
    /// "silent" even while the user keeps the Advanced page open.
    private func scheduleSilenceRecheck(for status: ModSyncStatus) {
        silenceScheduleGeneration &+= 1
        let generation = silenceScheduleGeneration
        guard let deadline = silenceDeadline(for: status) else { return }
        let delay = deadline.timeIntervalSince(now())
        guard delay > 0 else { return }
        schedule(delay) { [weak self] in
            guard let self, self.silenceScheduleGeneration == generation else { return }
            self.startDetectionIfNeeded(force: true)
        }
    }

    private func silenceDeadline(for status: ModSyncStatus) -> Date? {
        guard let environment, environment.inboxReady,
              environment.installation?.isEnabled == true else { return nil }
        switch status {
        case let .active(lastAcceptedAt):
            return lastAcceptedAt.addingTimeInterval(ModOnboardingConfig.noDataWithActivityGrace)
        case .waitingForData:
            return environment.installation?.installedAt?
                .addingTimeInterval(ModOnboardingConfig.noDataWithActivityGrace)
        default:
            return nil
        }
    }

    private static func uiRejection(_ reason: SnapshotRejectionReason) -> ModSnapshotRejection {
        switch reason {
        case .accountEmailHashMismatch, .missingAccountEmailHash: return .accountMismatch
        case .cycleUnverified: return .unverifiedCycle
        }
    }
}

// MARK: - Localization wiring

/// Maps the panel's text enum onto the localized tables; the defaults stay as the
/// Simplified Chinese fallback for any key that has not shipped yet.
func modOnboardingLocalize(_ text: ModOnboardingText) -> String {
    tr(LocalizationKey.key(for: text))
}

func realtimeBoostLocalize(_ text: RealtimeBoostText) -> String {
    realtimeBoostLocalize(text, language: .selected)
}

/// Presentation accepts a format template; render the localized positional argument
/// as a literal placeholder here, then let Presentation insert the actual value.
func realtimeBoostLocalize(_ text: RealtimeBoostText, language: AppLanguage) -> String {
    switch text {
    case .statusActive, .statusUnsupported, .statusVersionTooOld, .lastData,
         .cardOtherScopeAction, .cardDisabledAction, .cardVersionTooOldReason,
         .cardInboxAction, .cardViewErrorAction:
        return tr(LocalizationKey.key(for: text), arguments: ["%@"], language: language)
    default:
        return tr(LocalizationKey.key(for: text), language: language)
    }
}

extension LocalizationKey {
    static func key(for text: ModOnboardingText) -> LocalizationKey {
        switch text {
        case .pitchTitle: return .modInt2PitchTitle
        case .pitchSubtitle: return .modInt2PitchSubtitle
        case .laterButton: return .modInt2LaterButton
        case .feature1Title: return .modInt2Feature1Title
        case .feature1Detail: return .modInt2Feature1Detail
        case .feature2Title: return .modInt2Feature2Title
        case .feature4Title: return .modInt2Feature4Title
        case .feature4Detail: return .modInt2Feature4Detail
        case .manageTitle: return .modInt2ManageTitle
        case .removeNote: return .modInt2RemoveNote
        case .silentTitle: return .modInt2SilentTitle
        case .uninstalledTitle: return .modInt2UninstalledTitle
        case .silentCheckVersion: return .modInt2SilentCheckVersion
        case .silentCheckSession: return .modInt2SilentCheckSession
        case .silentCheckPolicy: return .modInt2SilentCheckPolicy
        case .subtitle: return .modUISubtitle
        case .benefitRealtime: return .modUIBenefitRealtime
        case .benefitFallback: return .modUIBenefitFallback
        case .benefitPrivacy: return .modUIBenefitPrivacy
        case .coverageNote: return .modUICoverageNote
        case .fallbackNote: return .modUIFallbackNote
        case .waitingTitle: return .modUIWaitingTitle
        case .waitingStep: return .modUIWaitingStep
        case .backgroundNote: return .modUIBackgroundNote
        case .refresh: return .modUIRefresh
        case .retry: return .modUIRetry
        case .confirmUninstall: return .modUIConfirmUninstall
        case .cancel: return .modUICancel
        case .viewStatus: return .modUIViewStatus
        case .confirmUninstallNote: return .modUIConfirmUninstallNote
        case .confirmUninstallAction: return .modUIConfirmUninstallAction
        case .uninstallReloadHint: return .modUIUninstallReloadHint
        case .backToIntro: return .modUIBackToIntro
        case .lastDataNote: return .modUILastDataNote
        case .uninstallFailureTitle: return .modUIUninstallFailureTitle
        case .accountAdvice: return .modUIAccountAdvice
        case .cycleAdvice: return .modUICycleAdvice
        case .promptRow: return .modPromptRow
        case .promptWhy: return .modPromptWhy
        case .promptMenu: return .modPromptMenu
        case .panelTitle: return .modPanelTitle
        case .point1: return .modPanelPoint1
        case .point2: return .modPanelPoint2
        case .point3: return .modPanelPoint3
        case .point4: return .modPanelPoint4
        case .installButton: return .modPanelInstall
        case .dismissCheckbox: return .modPanelDismissCheckbox
        case .closeButton: return .modPanelClose
        case .step1: return .modInstallStep1
        case .step2: return .modInstallStep2
        case .step3: return .modInstallStep3
        case .enabled: return .modInstallEnabled
        case .enabledNote: return .modInstallEnabledNote
        case .reloadHint: return .modInstallReloadHint
        case .failureTitle: return .modFailureTitle
        case .failureClaudeMissing: return .modFailureClaudeMissing
        case .failureCommandFailed: return .modFailureCommandFailed
        case .copyCommands: return .modFailureCopy
        case .copied: return .modFailureCopied
        case .dismissedTitle: return .modDismissedTitle
        case .dismissedNote: return .modDismissedNote
        case .undoDismiss: return .modDismissedUndo
        case .uninstallButton: return .modPanelUninstall
        case .uninstallStep1: return .modUninstallStep1
        case .uninstallStep2: return .modUninstallStep2
        case .uninstallDone: return .modUninstallDone
        case .uninstallDoneNote: return .modUninstallDoneNote
        case .failureUninstall: return .modFailureUninstall
        case .copyEnableCommands: return .modFailureCopyEnable
        case .failureInbox: return .modFailureInbox
        }
    }

    static func key(for text: RealtimeBoostText) -> LocalizationKey {
        switch text {
        case .statusEnabledShort: return .modSettingsStatusEnabledShort
        case .lastData: return .modSettingsLastData
        case .viewNote: return .modSettingsViewNote
        case .manage: return .modSettingsManage
        case .viewError: return .modSettingsViewError
        case .cardNotInstalledTitle: return .modCardNotInstalledTitle
        case .cardNotInstalledReason: return .modCardNotInstalledReason
        case .cardOtherScopeTitle: return .modCardOtherScopeTitle
        case .cardOtherScopeReason: return .modCardOtherScopeReason
        case .cardOtherScopeAction: return .modCardOtherScopeAction
        case .cardWaitingTitle: return .modCardWaitingTitle
        case .cardWaitingReason: return .modCardWaitingReason
        case .cardWaitingAction: return .modCardWaitingAction
        case .cardSilentTitle: return .modCardSilentTitle
        case .cardSilentReason: return .modCardSilentReason
        case .cardSilentAction: return .modCardSilentAction
        case .cardDisabledTitle: return .modCardDisabledTitle
        case .cardDisabledReason: return .modCardDisabledReason
        case .cardDisabledAction: return .modCardDisabledAction
        case .cardClaudeMissingTitle: return .modCardClaudeMissingTitle
        case .cardClaudeMissingReason: return .modCardClaudeMissingReason
        case .cardClaudeMissingAction: return .modCardClaudeMissingAction
        case .cardVersionTooOldTitle: return .modCardVersionTooOldTitle
        case .cardVersionTooOldReason: return .modCardVersionTooOldReason
        case .cardVersionTooOldAction: return .modCardVersionTooOldAction
        case .cardInboxTitle: return .modCardInboxTitle
        case .cardInboxReason: return .modCardInboxReason
        case .cardInboxAction: return .modCardInboxAction
        case .cardRejectedTitle: return .modCardRejectedTitle
        case .cardRejectedAccountReason: return .modCardRejectedAccountReason
        case .cardRejectedAccountAction: return .modCardRejectedAccountAction
        case .cardRejectedCycleReason: return .modCardRejectedCycleReason
        case .cardRejectedCycleAction: return .modCardRejectedCycleAction
        case .cardUnknownTitle: return .modCardUnknownTitle
        case .cardUnknownReason: return .modCardUnknownReason
        case .cardUnknownAction: return .modCardUnknownAction
        case .cardInstallFailedTitle: return .modCardInstallFailedTitle
        case .cardUninstallFailedTitle: return .modCardUninstallFailedTitle
        case .cardViewErrorAction: return .modCardViewErrorAction
        case .cardRowTitle: return .modCardRowTitle
        case .cardRowDescription: return .modCardRowDescription
        case .cardLearnMore: return .modCardLearnMore
        case .title: return .modSettingsTitle
        case .statusNotInstalled: return .modSettingsStatusNotInstalled
        case .statusWaiting: return .modSettingsStatusWaiting
        case .statusActive: return .modSettingsStatusActive
        case .statusSilent: return .modSettingsStatusSilent
        case .statusUnsupported: return .modSettingsStatusUnsupported
        case .install: return .modSettingsActionInstall
        case .copyCommands: return .modSettingsActionCopy
        case .promptToggle: return .modSettingsPromptToggle
        case .statusDetecting: return .modSyncStatusDetecting
        case .statusClaudeMissing: return .modSyncStatusClaudeMissing
        case .statusVersionTooOld: return .modSyncStatusVersionTooOld
        case .statusInboxNotReady: return .modSyncStatusInboxNotReady
        case .statusOtherScope: return .modSyncStatusOtherScope
        case .statusDisabled: return .modSyncStatusDisabled
        case .statusRejectedAccount: return .modSyncStatusRejectedAccount
        case .statusRejectedCycle: return .modSyncStatusRejectedCycle
        case .statusInstallationUnknown: return .modSyncStatusInstallationUnknown
        }
    }
}
