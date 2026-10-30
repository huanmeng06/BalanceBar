import AppKit

extension UpdateChannel {
    func localizedTitle(using language: AppLanguage = .selected) -> String {
        switch self {
        case .stable:
            return tr(.keyDashboardGeneralAndRefreshPagesStable, language: language)
        case .beta:
            return tr(.keyDashboardGeneralAndRefreshPagesBetaTest, language: language)
        }
    }
}

struct DashboardUpdatePresentation: Equatable {
    let subtitle: String
    let buttonTitle: String
    let buttonEnabled: Bool
    let performsInstall: Bool
    let showsReleaseNotesButton: Bool
    let showsUpdateBadge: Bool

    static func make(for state: UpdateCheckState, language: AppLanguage = .selected) -> DashboardUpdatePresentation {
        switch state {
        case .idle:
            return DashboardUpdatePresentation(
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesClickToCheckGithubReleases, language: language),
                buttonTitle: tr(.keyDashboardGeneralAndRefreshPagesCheckForUpdates, language: language),
                buttonEnabled: true,
                performsInstall: false,
                showsReleaseNotesButton: false,
                showsUpdateBadge: false
            )
        case .checking:
            return DashboardUpdatePresentation(
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesCheckingForUpdates, language: language),
                buttonTitle: tr(.keyDashboardGeneralAndRefreshPagesChecking, language: language),
                buttonEnabled: false,
                performsInstall: false,
                showsReleaseNotesButton: false,
                showsUpdateBadge: false
            )
        case .latest:
            return DashboardUpdatePresentation(
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesYouAreUpToDate, language: language),
                buttonTitle: tr(.keyDashboardGeneralAndRefreshPagesCheckForUpdates2, language: language),
                buttonEnabled: true,
                performsInstall: false,
                showsReleaseNotesButton: false,
                showsUpdateBadge: false
            )
        case .available(let current, let latest):
            return DashboardUpdatePresentation(
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesNewVersionAvailableValueValue, arguments: [String(describing: current), String(describing: latest)], language: language),
                buttonTitle: tr(.keyDashboardGeneralAndRefreshPagesDownloadAndInstall, language: language),
                buttonEnabled: true,
                performsInstall: true,
                showsReleaseNotesButton: true,
                showsUpdateBadge: true
            )
        case .revalidating(let current, let latest):
            // A re-check over a retained update must keep the badge and the
            // release notes entry visible while it runs.
            return DashboardUpdatePresentation(
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesUpdateAvailableRevalidatingValueValue, arguments: [String(describing: current), String(describing: latest)], language: language),
                buttonTitle: tr(.keyDashboardGeneralAndRefreshPagesChecking, language: language),
                buttonEnabled: false,
                performsInstall: false,
                showsReleaseNotesButton: true,
                showsUpdateBadge: true
            )
        case .recheckFailed(_, let latest, let failure):
            // The retained update stays installable; the failure text covers
            // this verification attempt only.
            let subtitle: String
            if let details = localizedUpdateCheckFailureDetails(for: failure, language: language) {
                subtitle = tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailedUpdateRetainedValueValueValue,
                    arguments: [String(describing: latest), details.reason, details.suggestion],
                    language: language
                )
            } else {
                subtitle = tr(.keyDashboardGeneralAndRefreshPagesUpdateCheckFailedTryAgain, language: language)
            }
            return DashboardUpdatePresentation(
                subtitle: subtitle,
                buttonTitle: tr(.keyDashboardGeneralAndRefreshPagesDownloadAndInstall, language: language),
                buttonEnabled: true,
                performsInstall: true,
                showsReleaseNotesButton: true,
                showsUpdateBadge: true
            )
        case .downloading(_, _, let progress):
            return DashboardUpdatePresentation(
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesDownloadingTheNewVersion, language: language),
                buttonTitle: tr(.keyDashboardGeneralAndRefreshPagesDownloadingValue, arguments: [String(describing: progress)], language: language),
                buttonEnabled: false,
                performsInstall: false,
                showsReleaseNotesButton: false,
                showsUpdateBadge: false
            )
        case .installing(_, _, let progress):
            return DashboardUpdatePresentation(
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesInstallingTheNewVersion, language: language),
                buttonTitle: tr(.keyDashboardGeneralAndRefreshPagesInstallingValue, arguments: [String(describing: progress)], language: language),
                buttonEnabled: false,
                performsInstall: false,
                showsReleaseNotesButton: false,
                showsUpdateBadge: false
            )
        case .restarting:
            return DashboardUpdatePresentation(
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesInstalledRestarting, language: language),
                buttonTitle: tr(.keyDashboardGeneralAndRefreshPagesRestarting, language: language),
                buttonEnabled: false,
                performsInstall: false,
                showsReleaseNotesButton: false,
                showsUpdateBadge: false
            )
        case .failed(let failure):
            let subtitle: String
            if let details = localizedUpdateCheckFailureDetails(for: failure, language: language) {
                subtitle = tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailedTryAgainReason,
                    arguments: [details.reason, details.suggestion],
                    language: language
                )
            } else {
                switch failure {
                case .assetUnavailable:
                    subtitle = tr(.keyDashboardGeneralAndRefreshPagesNoVerifiableInstallerIsAvailableTryAgain, language: language)
                case .verificationFailed:
                    subtitle = tr(.keyDashboardGeneralAndRefreshPagesDownloadVerificationFailedTheCurrentVersionWasNotChanged, language: language)
                case .installationFailed:
                    subtitle = tr(.keyDashboardGeneralAndRefreshPagesInstallationFailedTheCurrentVersionWasNotChanged, language: language)
                case .invalidCurrentVersion:
                    subtitle = tr(.keyDashboardGeneralAndRefreshPagesTheCurrentVersionCouldNotBeReadTryAgain, language: language)
                default:
                    subtitle = tr(.keyDashboardGeneralAndRefreshPagesUpdateCheckFailedTryAgain, language: language)
                }
            }
            return DashboardUpdatePresentation(
                subtitle: subtitle,
                buttonTitle: tr(.keyDashboardGeneralAndRefreshPagesRetry, language: language),
                buttonEnabled: true,
                performsInstall: false,
                showsReleaseNotesButton: false,
                showsUpdateBadge: false
            )
        }
    }

    private static func localizedUpdateCheckFailureDetails(
        for failure: UpdateFailure,
        language: AppLanguage
    ) -> (reason: String, suggestion: String)? {
        switch failure {
        case .network:
            return (
                tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonNetwork,
                    language: language
                ),
                tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureSuggestionNetwork,
                    language: language
                )
            )
        case .httpStatus(let statusCode):
            let reasonKey: LocalizationKey
            switch statusCode {
            case 403:
                reasonKey = .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonHttpForbiddenValue
            case 404:
                reasonKey = .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonHttpNotFoundValue
            case 429:
                reasonKey = .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonHttpTooManyRequestsValue
            case 500...599:
                reasonKey = .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonHttpServerErrorValue
            default:
                reasonKey = .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonHttpStatusValue
            }
            let suggestionKey: LocalizationKey = statusCode == 429
                ? .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureSuggestionHttpTooManyRequests
                : .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureSuggestionHttp
            return (
                tr(
                    reasonKey,
                    arguments: [String(statusCode)],
                    language: language
                ),
                tr(suggestionKey, language: language)
            )
        case .rateLimited(let retryAfter):
            let suggestion: String
            if let retryAfter {
                let minutes = Int((retryAfter / 60.0).rounded(.up))
                suggestion = tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureSuggestionRateLimitedWaitValue,
                    arguments: [String(minutes)],
                    language: language
                )
            } else {
                suggestion = tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureSuggestionHttpTooManyRequests,
                    language: language
                )
            }
            return (
                tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonRateLimited,
                    language: language
                ),
                suggestion
            )
        case .invalidResponse:
            return (
                tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonInvalidResponse,
                    language: language
                ),
                tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureSuggestionInvalidResponse,
                    language: language
                )
            )
        case .invalidReleaseVersion:
            return (
                tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureReasonInvalidReleaseVersion,
                    language: language
                ),
                tr(
                    .keyDashboardGeneralAndRefreshPagesUpdateCheckFailureSuggestionInvalidReleaseVersion,
                    language: language
                )
            )
        case .assetUnavailable, .downloadFailed, .verificationFailed, .installationFailed, .invalidCurrentVersion:
            return nil
        }
    }
}

/// Keeps a row's existing controls side by side at normal widths and stacks
/// those same controls only when the settings row cannot fit them. The update
/// actions and refresh interval pairs both use this layout contract; their
/// controls retain their existing style, targets, and dimensions.
final class DashboardAdaptiveControlsStackView: NSStackView, SettingsRowAccessoryLayout {
    private var availableRowWidth: CGFloat = .greatestFiniteMagnitude
    private(set) var stacksControlsVertically = false
    var allowsTextDrivenDedicatedRow = false
    var minimumInlineLabelWidth: CGFloat = 0

    func updateAvailableRowWidth(_ width: CGFloat) {
        let normalizedWidth = max(0, width)
        if abs(normalizedWidth - availableRowWidth) > 0.5 {
            availableRowWidth = normalizedWidth
        }
        updateOrientationIfNeeded()
    }

    /// Natural width of this accessory in its current orientation, composed
    /// from children rather than this stack's compressed `fittingSize`.
    var naturalAccessoryWidth: CGFloat {
        let visibleButtons = arrangedSubviews.filter { !$0.isHidden }
        let widths = visibleButtons.map(Self.naturalWidth(of:))
        if orientation == .vertical {
            return widths.max() ?? 0
        }
        return widths.reduce(0, +) + max(0, CGFloat(visibleButtons.count - 1)) * spacing
    }

    private var naturalHorizontalAccessoryWidth: CGFloat {
        let visibleButtons = arrangedSubviews.filter { !$0.isHidden }
        let buttonWidth = visibleButtons.reduce(CGFloat(0)) { total, view in
            max(total, Self.naturalWidth(of: view))
        }
        let totalWidth = visibleButtons.reduce(CGFloat(0)) { total, view in
            total + Self.naturalWidth(of: view)
        }
        return max(buttonWidth, totalWidth + max(0, CGFloat(visibleButtons.count - 1)) * spacing) + 1
    }

    override func layout() {
        updateOrientationIfNeeded()
        super.layout()
    }

    private func updateOrientationIfNeeded() {
        let wantsVertical = availableRowWidth > 0 && availableRowWidth + 0.5 < naturalHorizontalAccessoryWidth
        let desiredOrientation: NSUserInterfaceLayoutOrientation = wantsVertical ? .vertical : .horizontal
        let orientationChanged = orientation != desiredOrientation
        let stackingChanged = stacksControlsVertically != wantsVertical
        if orientationChanged {
            orientation = desiredOrientation
            alignment = wantsVertical ? .trailing : .centerY
        }
        if stackingChanged {
            stacksControlsVertically = wantsVertical
        }
        if orientationChanged || stackingChanged {
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
            superview?.superview?.needsLayout = true
        }
    }

    override var intrinsicContentSize: NSSize {
        let visibleButtons = arrangedSubviews.filter { !$0.isHidden }
        guard !visibleButtons.isEmpty else { return .zero }
        if orientation == .vertical {
            return NSSize(
                width: naturalAccessoryWidth,
                height: visibleButtons.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
                    + max(0, CGFloat(visibleButtons.count - 1)) * spacing
            )
        }
        return NSSize(
            width: naturalAccessoryWidth,
            height: visibleButtons.map { $0.fittingSize.height }.max() ?? 0
        )
    }

    private static func naturalWidth(of view: NSView) -> CGFloat {
        if let stack = view as? NSStackView {
            let visible = stack.arrangedSubviews.filter { !$0.isHidden }
            let widths = visible.map(naturalWidth(of:))
            if stack.orientation == .vertical {
                return widths.max() ?? 0
            }
            return widths.reduce(0, +) + max(0, CGFloat(visible.count - 1)) * stack.spacing
        }
        let fitting = view.fittingSize.width
        return fitting.isFinite && fitting > 0 ? fitting : 0
    }

    func invalidateLayoutAfterContentChange() {
        // Button title and hidden-state changes can update the arranged views'
        // intrinsic sizes without invalidating this custom stack's cached row
        // width. Propagate the invalidation so the existing trailing anchor is
        // remeasured before the next window layout pass.
        updateOrientationIfNeeded()
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
        superview?.superview?.needsLayout = true
    }
}

final class DashboardGeneralPage {
    struct Input {
        let preferences: AppPreferences
        let connectionSummaries: CCSwitchConnectionSummaries
        let relay: DashboardPreferencePageRelay
        let updateState: UpdateCheckState
        let launchAtLoginState: LaunchAtLoginState
        let launchWithChatGPTState: LaunchWithChatGPTState
        let modSyncStatus: ModSyncStatus
        let modPanelState: ModPanelState

        init(
            preferences: AppPreferences,
            connectionSummaries: CCSwitchConnectionSummaries = .unknown,
            relay: DashboardPreferencePageRelay,
            updateState: UpdateCheckState,
            launchAtLoginState: LaunchAtLoginState = LaunchAtLoginState(status: .notRegistered),
            launchWithChatGPTState: LaunchWithChatGPTState = LaunchWithChatGPTState(status: .notRegistered),
            modSyncStatus: ModSyncStatus = .detecting,
            modPanelState: ModPanelState = .intro(dismissChecked: false)
        ) {
            self.preferences = preferences
            self.connectionSummaries = connectionSummaries
            self.relay = relay
            self.updateState = updateState
            self.launchAtLoginState = launchAtLoginState
            self.launchWithChatGPTState = launchWithChatGPTState
            self.modSyncStatus = modSyncStatus
            self.modPanelState = modPanelState
        }
    }

    private var realtimeBoostRows: RealtimeBoostSettingsRows?

    private weak var timeZoneComboBox: DashboardTimeZoneComboBox?
    private weak var systemTimeZoneCheckbox: NSButton?

    private var updateSubtitleLabel: NSTextField?
    private var updateButton: NSButton?
    private var updateNotesButton: NSButton?
    private var updateBadge: NSView?
    private weak var currentProviderDetailLabel: NSTextField?
    private var connectionSummaries: CCSwitchConnectionSummaries = .unknown
    private var launchAtLoginSwitch: NSSwitch?
    private var launchAtLoginSubtitleLabel: NSTextField?
    private var launchWithChatGPTSwitch: NSSwitch?
    private var launchWithChatGPTSubtitleLabel: NSTextField?
    private var launchWithChatGPTOpenSettingsButton: NSButton?
    private var launchWithChatGPTControls: DashboardAdaptiveControlsStackView?

    func make(_ input: Input) -> NSView {
        let modRows = RealtimeBoostSettingsRows(
            status: input.modSyncStatus, operation: input.modPanelState,
            onInstall: { [weak relay = input.relay] button in relay?.installModSync(button) },
            onShowDescription: { [weak relay = input.relay] button in relay?.manageModSync(button) })
        realtimeBoostRows = modRows
        let openButton = NSButton(
            title: tr(.keyDashboardGeneralAndRefreshPagesOpenCcSwitch),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openCCSwitch(_:))
        )
        connectionSummaries = input.connectionSummaries
        let currentProviderRow = SettingsRowView(
            title: tr(.keyDashboardGeneralAndRefreshPagesCcSwitch),
            detail: DashboardSettingsFormattedCopy.ccSwitchConnectionPlainText(input.connectionSummaries),
            accessoryView: openButton
        )
        currentProviderDetailLabel = currentProviderRow.detailLabel
        applyConnectionSummaries()
        let system = SettingsSectionView(
            title: tr(.keyDashboardGeneralAndRefreshPagesSystem),
            contentViews: [currentProviderRow]
        )

        let launchAtLoginSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: LaunchAtLoginController.toggleIdentifier,
            isOn: input.launchAtLoginState.status == .enabled,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.launchAtLogin(_:))
        )
        let launchAtLoginRow = SettingsRowView(
            title: tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin),
            detail: launchAtLoginSubtitle(for: input.launchAtLoginState),
            accessoryView: launchAtLoginSwitch
        )
        apply(
            input.launchAtLoginState,
            to: launchAtLoginSwitch,
            subtitle: launchAtLoginRow.detailLabel
        )

        let silentLaunchSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: AppPreferences.silentLaunchKey,
            isOn: input.preferences.silentLaunch,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let silentLaunchRow = SettingsRowView(
            title: tr(.keyDashboardGeneralAndRefreshPagesSilentLaunch),
            detail: tr(.keyDashboardGeneralAndRefreshPagesSilentLaunchDescription),
            accessoryView: silentLaunchSwitch
        )

        let launchWithChatGPTSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: LaunchWithChatGPTController.toggleIdentifier,
            isOn: input.launchWithChatGPTState.status == .enabled
                || input.launchWithChatGPTState.status == .requiresApproval,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.launchWithChatGPT(_:))
        )
        let launchWithChatGPTOpenSettingsButton = NSButton(
            title: tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginOpenSettings),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openLaunchWithChatGPTSettings(_:))
        )
        launchWithChatGPTOpenSettingsButton.bezelStyle = .rounded
        let launchWithChatGPTControls = DashboardAdaptiveControlsStackView(
            views: [launchWithChatGPTOpenSettingsButton, launchWithChatGPTSwitch]
        )
        launchWithChatGPTControls.orientation = .horizontal
        launchWithChatGPTControls.alignment = .centerY
        launchWithChatGPTControls.spacing = 8
        let launchWithChatGPTRow = SettingsRowView(
            title: tr(.keyDashboardGeneralAndRefreshPagesLaunchWithChatGPT),
            detail: launchWithChatGPTSubtitle(for: input.launchWithChatGPTState),
            accessoryView: launchWithChatGPTControls
        )
        apply(
            input.launchWithChatGPTState,
            to: launchWithChatGPTSwitch,
            subtitle: launchWithChatGPTRow.detailLabel,
            openSettingsButton: launchWithChatGPTOpenSettingsButton
        )

        let startup = SettingsSectionView(
            title: tr(.keyDashboardGeneralAndRefreshPagesStartup),
            contentViews: [launchAtLoginRow, silentLaunchRow, launchWithChatGPTRow]
        )

        let intervalTitle = { (seconds: TimeInterval) in
            tr(.keyDashboardOfficialEverySeconds, arguments: [String(Int(seconds))])
        }
        // Values saved before the shared option list (1 s, 2 s) show the nearest available choice.
        let savedAPIInterval = input.preferences.codexUsageRefreshInterval
        let selectedAPIInterval = AppPreferences.refreshIntervalOptions
            .min { abs($0 - savedAPIInterval) < abs($1 - savedAPIInterval) } ?? savedAPIInterval
        let activeRefreshPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: AppPreferences.refreshIntervalOptions.map { ($0, intervalTitle($0)) },
            selected: selectedAPIInterval,
            identifier: "codexUsageRefreshInterval",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let officialActivePopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: AppPreferences.officialUsageRefreshIntervals.map { ($0, intervalTitle($0)) },
            selected: input.preferences.officialUsageRefreshInterval, identifier: "officialUsageRefreshInterval",
            target: input.relay, action: #selector(DashboardPreferencePageRelay.interval(_:)))
        let claudeCalibrationPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: AppPreferences.claudeCalibrationIntervals.map {
                ($0, tr(.keyClaudeRefreshEveryMinutes, arguments: [String(Int($0 / 60))]))
            },
            selected: input.preferences.claudeCalibrationInterval,
            identifier: AppPreferences.claudeCalibrationIntervalKey,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        // Both selector rows share one structure: a right-aligned selector of identical width.
        let refreshPopupWidth = ceil(max(
            108, activeRefreshPopup.fittingSize.width, officialActivePopup.fittingSize.width,
            claudeCalibrationPopup.fittingSize.width
        ))
        func refreshControls(_ popup: NSPopUpButton) -> NSStackView {
            popup.translatesAutoresizingMaskIntoConstraints = false
            for constraint in popup.constraints where constraint.firstAttribute == .width {
                constraint.priority = .defaultHigh
            }
            let preferredWidth = popup.widthAnchor.constraint(equalToConstant: refreshPopupWidth)
            preferredWidth.priority = .defaultHigh
            preferredWidth.isActive = true
            // The wrapper takes the row's accessory sizing, so the popup keeps
            // the shared preferred width.
            let controls = NSStackView(views: [popup])
            controls.orientation = .vertical
            controls.alignment = .trailing
            return controls
        }
        let refreshButton = NSButton(
            title: tr(.keyDashboardGeneralAndRefreshPagesRefreshNow),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.manualRefresh(_:))
        )
        // One "Refresh" heading over two cards: the shared Codex/API selectors, then the
        // Claude rows (calibration and the Mod status).
        let refreshing = SettingsSectionView(
            title: tr(.keyDashboardGeneralAndRefreshPagesRefresh),
            contentViews: [
                SettingsRowView(
                    title: tr(.keyDashboardOfficialQuotaRefreshFrequency),
                    detail: tr(.keyDashboardRefreshOfficialScope),
                    titleAccessory: DashboardRefreshPage.agentIconStrip(["CodexIcon", "GrokIdle"]),
                    accessoryView: refreshControls(officialActivePopup)
                ),
                SettingsRowView(
                    title: tr(.keyDashboardGeneralAndRefreshPagesBalanceUpdatesDuringTasks),
                    detail: tr(.keyDashboardRefreshAPIScope),
                    titleAccessory: DashboardRefreshPage.agentIconStrip(["symbol:key"], pointSize: 18),
                    accessoryView: refreshControls(activeRefreshPopup)
                )
            ]
        )
        let refreshingClaude = SettingsSectionView(
            title: "",
            contentViews: [
                SettingsRowView(
                    title: tr(.keyClaudeQuotaCalibration),
                    detail: tr(.keyClaudeQuotaCalibrationDetail),
                    titleAccessory: DashboardRefreshPage.agentIconStrip(["Claude"], tag: tr(.keyClaudeSourceTagAllClients)),
                    accessoryView: refreshControls(claudeCalibrationPopup)
                ),
                modRows.statusRow
            ]
        )
        let refreshNow = SettingsSectionView(
            title: tr(.keyDashboardGeneralAndRefreshPagesRefreshNow),
            contentViews: [
                SettingsRowView(
                    title: tr(.keyDashboardGeneralAndRefreshPagesBalanceData),
                    detail: tr(.keyDashboardGeneralAndRefreshPagesReloadTheCurrentProviderNow),
                    accessoryView: refreshButton
                )
            ]
        )

        let languagePopup = DashboardSettingsComponents.makePopUpButton(
            identifier: AppLanguage.preferenceKey,
            items: zip(
                AppLanguage.allCases,
                DashboardSettingsFormattedCopy.languageMenuTitles()
            ).map { language, title in
                DashboardSettingsComponents.PopUpItem(
                    title: title,
                    representedObject: language.rawValue
                )
            },
            selectedIndex: AppLanguage.allCases.firstIndex(of: AppLanguage.selected),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.language(_:)),
            ignoresScrollWheel: true
        )
        let updatePresentation = DashboardUpdatePresentation.make(for: input.updateState)
        let updateBadge = DashboardUpdateBadgeView()
        updateBadge.isHidden = !updatePresentation.showsUpdateBadge
        let updateButton = NSButton(
            title: updatePresentation.buttonTitle,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.update(_:))
        )
        updateButton.identifier = NSUserInterfaceItemIdentifier("checkForUpdatesButton")
        updateButton.bezelStyle = .rounded
        let updateNotesButton = NSButton(
            title: tr(.keyDashboardGeneralAndRefreshPagesViewReleaseNotes),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openUpdateNotes(_:))
        )
        updateNotesButton.identifier = NSUserInterfaceItemIdentifier("viewUpdateNotesButton")
        updateNotesButton.bezelStyle = .rounded
        apply(updatePresentation, to: updateNotesButton)
        let updateChannelPopup = DashboardSettingsComponents.makePopUpButton(
            identifier: AppPreferences.updateChannelKey,
            items: UpdateChannel.allCases.map {
                DashboardSettingsComponents.PopUpItem(
                    title: $0.localizedTitle(),
                    representedObject: $0.rawValue
                )
            },
            selectedIndex: UpdateChannel.allCases.firstIndex(of: input.preferences.updateChannel),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.updateChannel(_:))
        )
        updateChannelPopup.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let updateChannelRow = SettingsRowView(
            title: tr(.keyDashboardGeneralAndRefreshPagesUpdateChannel),
            detail: tr(.keyDashboardGeneralAndRefreshPagesUpdateChannelDescription),
            accessoryView: updateChannelPopup
        )
        let updateControls = DashboardAdaptiveControlsStackView(views: [updateNotesButton, updateButton])
        updateControls.orientation = .horizontal
        updateControls.alignment = .centerY
        updateControls.spacing = 8
        updateControls.minimumInlineLabelWidth = SettingsRowView.minimumInlineLabelWidth
        updateControls.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateControls.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let updateRow = SettingsRowView(
            title: tr(.keyDashboardGeneralAndRefreshPagesCheckForUpdates3),
            detail: updatePresentation.subtitle,
            titleAccessory: updateBadge,
            accessoryView: updateControls
        )
        updateRow.detailLabel.identifier = NSUserInterfaceItemIdentifier("checkForUpdatesSubtitle")
        apply(updatePresentation, to: updateButton, subtitle: updateRow.detailLabel)
        self.updateSubtitleLabel = updateRow.detailLabel
        self.updateButton = updateButton
        self.updateNotesButton = updateNotesButton
        self.updateBadge = updateBadge
        self.launchAtLoginSwitch = launchAtLoginSwitch
        self.launchAtLoginSubtitleLabel = launchAtLoginRow.detailLabel
        self.launchWithChatGPTSwitch = launchWithChatGPTSwitch
        self.launchWithChatGPTSubtitleLabel = launchWithChatGPTRow.detailLabel
        self.launchWithChatGPTOpenSettingsButton = launchWithChatGPTOpenSettingsButton
        self.launchWithChatGPTControls = launchWithChatGPTControls

        let timeZoneComboBox = DashboardTimeZoneComboBox(preferences: input.preferences, relay: input.relay)
        let systemTimeZoneCheckbox = NSButton(
            checkboxWithTitle: tr(.keyTimeZoneSystem),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.followSystemTimeZone(_:))
        )
        systemTimeZoneCheckbox.identifier = NSUserInterfaceItemIdentifier(AppPreferences.displayTimeZoneKey + ".system")
        systemTimeZoneCheckbox.state = input.preferences.displayTimeZoneSelection == .system ? .on : .off
        let timeZoneControls = NSStackView(views: [systemTimeZoneCheckbox, timeZoneComboBox])
        timeZoneControls.orientation = .horizontal
        timeZoneControls.alignment = .centerY
        timeZoneControls.spacing = 12
        self.timeZoneComboBox = timeZoneComboBox
        self.systemTimeZoneCheckbox = systemTimeZoneCheckbox
        let app = SettingsSectionView(
            title: tr(.keyDashboardGeneralAndRefreshPagesApplication),
            contentViews: [
                SettingsRowView(
                    title: tr(.keyDashboardGeneralAndRefreshPagesLanguage),
                    detail: tr(.keyDashboardGeneralAndRefreshPagesChangesApplyToTheEntireInterfaceImmediately),
                    accessoryView: languagePopup
                ),
                SettingsRowView(
                    title: tr(.keyTimeZoneTitle),
                    detail: tr(.keyTimeZoneDescription),
                    accessoryView: timeZoneControls
                )
            ]
        )
        let appUpdate = SettingsSectionView(
            title: "",
            contentViews: [updateChannelRow, updateRow]
        )
        let content = DashboardSettingsComponents.makeSettingsPageContent(
            [system, refreshing, refreshingClaude, refreshNow, startup, app, appUpdate])
        // The two refresh cards belong to one heading, so they sit closer than separate sections.
        (content as? NSStackView)?.setCustomSpacing(12, after: refreshing)
        (content as? NSStackView)?.setCustomSpacing(12, after: app)
        return content
    }

    func refreshModSync(_ status: ModSyncStatus?, operation: ModPanelState?) {
        realtimeBoostRows?.update(status: status ?? .detecting, operation: operation ?? .intro(dismissChecked: false))
    }

    func refreshDisplayTimeZone(_ selection: AppTimeZoneSelection) {
        systemTimeZoneCheckbox?.state = selection == .system ? .on : .off
        timeZoneComboBox?.apply(selection)
    }

    func refreshLaunchAtLogin(_ state: LaunchAtLoginState) {
        guard let launchAtLoginSwitch,
              let launchAtLoginSubtitleLabel
        else { return }
        apply(
            state,
            to: launchAtLoginSwitch,
            subtitle: launchAtLoginSubtitleLabel
        )
        launchAtLoginSwitch.superview?.needsLayout = true
        launchAtLoginSubtitleLabel.superview?.needsLayout = true
        launchAtLoginSubtitleLabel.superview?.superview?.needsLayout = true
    }

    func refreshLaunchWithChatGPT(_ state: LaunchWithChatGPTState) {
        guard let launchWithChatGPTSwitch,
              let launchWithChatGPTSubtitleLabel,
              let launchWithChatGPTOpenSettingsButton
        else { return }
        apply(
            state,
            to: launchWithChatGPTSwitch,
            subtitle: launchWithChatGPTSubtitleLabel,
            openSettingsButton: launchWithChatGPTOpenSettingsButton
        )
        launchWithChatGPTControls?.invalidateLayoutAfterContentChange()
        launchWithChatGPTSwitch.superview?.needsLayout = true
        launchWithChatGPTSubtitleLabel.superview?.needsLayout = true
        launchWithChatGPTSubtitleLabel.superview?.superview?.needsLayout = true
    }

    func refresh(updateState: UpdateCheckState) {
        let presentation = DashboardUpdatePresentation.make(for: updateState)
        guard let updateSubtitleLabel, let updateButton else { return }
        apply(presentation, to: updateButton, subtitle: updateSubtitleLabel)
        apply(presentation, to: updateNotesButton)
        updateBadge?.isHidden = !presentation.showsUpdateBadge
        (updateButton.superview as? DashboardAdaptiveControlsStackView)?.invalidateLayoutAfterContentChange()
    }

    func refreshConnectionSummaries(_ summaries: CCSwitchConnectionSummaries) {
        connectionSummaries = summaries
        applyConnectionSummaries()
    }

    private func applyConnectionSummaries() {
        guard let currentProviderDetailLabel else { return }
        currentProviderDetailLabel.attributedStringValue = DashboardSettingsFormattedCopy.ccSwitchConnectionDetail(connectionSummaries)
        // The three lines can grow from short 未知 text to wrapped provider
        // lists; re-run the row's wrapping-height machinery so card height
        // follows instead of clipping.
        if let row = SettingsRowView.enclosing(currentProviderDetailLabel) {
            row.invalidateAfterContentChange()
        } else {
            currentProviderDetailLabel.superview?.needsLayout = true
            currentProviderDetailLabel.superview?.superview?.needsLayout = true
        }
    }

    private func launchAtLoginSubtitle(for state: LaunchAtLoginState) -> String {
        switch state.notice {
        case .none:
            return tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginDescription)
        case .requiresApproval:
            return tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginRequiresApproval)
        case .operationFailed:
            return tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginOperationFailed)
        case .unavailable:
            return tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginUnavailable)
        }
    }

    private func launchWithChatGPTSubtitle(for state: LaunchWithChatGPTState) -> String {
        switch state.notice {
        case .none:
            return tr(.keyDashboardGeneralAndRefreshPagesLaunchWithChatGPTDescription)
        case .requiresApproval:
            return tr(.keyDashboardGeneralAndRefreshPagesLaunchWithChatGPTRequiresApproval)
        case .operationFailed:
            return tr(.keyDashboardGeneralAndRefreshPagesLaunchWithChatGPTOperationFailed)
        case .unavailable:
            return tr(.keyDashboardGeneralAndRefreshPagesLaunchWithChatGPTUnavailable)
        }
    }

    private func apply(
        _ state: LaunchAtLoginState,
        to launchAtLoginSwitch: NSSwitch,
        subtitle: NSTextField
    ) {
        switch state.status {
        case .enabled:
            launchAtLoginSwitch.state = .on
            launchAtLoginSwitch.isEnabled = true
        case .notRegistered:
            launchAtLoginSwitch.state = .off
            launchAtLoginSwitch.isEnabled = true
        case .requiresApproval:
            launchAtLoginSwitch.state = .on
            launchAtLoginSwitch.isEnabled = true
        case .notFound, .unknown:
            launchAtLoginSwitch.state = .off
            launchAtLoginSwitch.isEnabled = true
        }
        if let row = SettingsRowView.enclosing(subtitle) {
            row.updateDetail(launchAtLoginSubtitle(for: state))
        } else {
            subtitle.stringValue = launchAtLoginSubtitle(for: state)
            subtitle.invalidateIntrinsicContentSize()
        }
    }

    private func apply(
        _ state: LaunchWithChatGPTState,
        to launchWithChatGPTSwitch: NSSwitch,
        subtitle: NSTextField,
        openSettingsButton: NSButton
    ) {
        switch state.status {
        case .enabled, .requiresApproval:
            launchWithChatGPTSwitch.state = .on
            launchWithChatGPTSwitch.isEnabled = true
        case .notRegistered, .notFound, .unknown:
            launchWithChatGPTSwitch.state = .off
            launchWithChatGPTSwitch.isEnabled = true
        }
        openSettingsButton.isHidden = state.notice == .none
        if let row = SettingsRowView.enclosing(subtitle) {
            row.updateDetail(launchWithChatGPTSubtitle(for: state))
        } else {
            subtitle.stringValue = launchWithChatGPTSubtitle(for: state)
            subtitle.invalidateIntrinsicContentSize()
        }
    }

    private func apply(
        _ presentation: DashboardUpdatePresentation,
        to button: NSButton,
        subtitle: NSTextField
    ) {
        button.title = presentation.buttonTitle
        button.isEnabled = presentation.buttonEnabled
        button.tag = presentation.performsInstall ? 1 : 0
        if let row = SettingsRowView.enclosing(subtitle) {
            row.updateDetail(presentation.subtitle)
        } else {
            subtitle.stringValue = presentation.subtitle
        }
    }

    private func apply(
        _ presentation: DashboardUpdatePresentation,
        to button: NSButton?
    ) {
        guard let button else { return }
        button.isHidden = !presentation.showsReleaseNotesButton
        button.isEnabled = presentation.showsReleaseNotesButton
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

enum DashboardRefreshPage {
    struct Input {
        let preferences: AppPreferences
        let providerPollInterval: TimeInterval
        let relay: DashboardPreferencePageRelay
    }

    /// Reuses the menu bar's bundled agent SVGs as small marks after a row title.
    /// A `symbol:` prefix selects an SF Symbol instead of a bundled SVG.
    /// Claude keeps its brand orange; the monochrome marks follow the secondary label color.
    static func agentIconStrip(_ resourceNames: [String], tag: String) -> NSView {
        AgentIconTagAccessoryView(iconStrip: agentIconStrip(resourceNames), tag: tag)
    }

    static func agentIconStrip(_ resourceNames: [String], pointSize: CGFloat = 14) -> NSView {
        let iconSize = NSSize(width: pointSize, height: pointSize)
        let icons: [AgentIconStripView.Icon] = resourceNames.compactMap { name in
            if let symbol = name.removingPrefix("symbol:") {
                guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: pointSize - 2, weight: .regular)) else { return nil }
                // SF Symbols draw the key horizontally with the head on the left; tilt it so the
                // head sits upper right and the tip points lower left. Keep the symbol's own aspect.
                return AgentIconStripView.Icon(image: image, isTinted: true, rotationDegrees: -45)
            }
            guard let url = Bundle.main.url(forResource: name, withExtension: "svg") else { return nil }
            // GrokIdle.svg is a framed artboard; the menu bar crops it through GrokIdleIcon.
            guard let image = name == "GrokIdle"
                ? GrokIdleIcon.make(fromSVG: url, outputSize: iconSize)
                : NSImage(contentsOf: url) else { return nil }
            image.size = iconSize
            let tinted = name != "Claude"
            image.isTemplate = tinted
            return AgentIconStripView.Icon(image: image, isTinted: tinted)
        }
        return AgentIconStripView(icons: icons, iconSize: iconSize)
    }

    static func make(_ input: Input) -> NSView {
        let root = NSView()
        let header = DashboardSettingsComponents.makePageHeader(
            tr(.keyDashboardGeneralAndRefreshPagesRefreshSettings),
            subtitle: tr(.keyDashboardGeneralAndRefreshPagesFileMonitoringIsAlwaysActivePollingPreventsMissedSystemEvents)
        )
        let pollingTitle = NSTextField(labelWithString: tr(.keyDashboardGeneralAndRefreshPagesCcSwitchFallbackPolling))
        pollingTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let pollingPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [
                (1, tr(.keyDashboardGeneralAndRefreshPagesEvery1Sec2)),
                (3, tr(.keyDashboardGeneralAndRefreshPagesEvery3Sec2)),
                (5, tr(.keyDashboardGeneralAndRefreshPagesEvery5Sec2)),
                (10, tr(.keyDashboardGeneralAndRefreshPagesEvery10Sec2))
            ],
            selected: input.providerPollInterval,
            identifier: "providerPollInterval",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let pollingRow = NSStackView(views: [pollingTitle, NSView(), pollingPopup])
        pollingRow.orientation = .horizontal
        pollingRow.alignment = .centerY

        let activityTitle = NSTextField(labelWithString: tr(.keyDashboardGeneralAndRefreshPagesCodexTaskStatusDetection))
        activityTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let activityPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [(0.25, tr(.keyDashboardGeneralAndRefreshPages025Sec)), (0.5, tr(.keyDashboardGeneralAndRefreshPages05Sec)), (1, tr(.keyDashboardGeneralAndRefreshPages1Sec))],
            selected: input.preferences.activityPollInterval,
            identifier: "activityPollInterval",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let activityRow = NSStackView(views: [activityTitle, NSView(), activityPopup])
        activityRow.orientation = .horizontal
        activityRow.alignment = .centerY

        let note = NSTextField(wrappingLabelWithString: tr(.keyDashboardGeneralAndRefreshPagesProviderChangesAreStillTriggeredImmediatelyByCcSwitchDatabaseEventsThisIntervalIsOnlyTheFallbackCheckFrequency))
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header, pollingRow, activityRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(30, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            pollingRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }
}

/// AppKit owns the editable field and list. Only confirmed city matches commit;
/// every display update is applied to this same mounted control instance.
/// Menu header view for a continent section.
final class MenuHeaderView: NSView {
    private let background = NSView()
    private let label = NSTextField(labelWithString: "")
    private let accentBar = NSView()
    private let topSpacing: CGFloat = 4

    init(title: String, width: CGFloat = 240) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        autoresizingMask = [.width]
        wantsLayer = true

        [background, accentBar].forEach {
            $0.wantsLayer = true
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(background)
        addSubview(accentBar)

        label.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.controlAccentColor,
                .kern: 1.2
            ]
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor, constant: topSpacing),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),

            accentBar.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            accentBar.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
            accentBar.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.10).cgColor
            accentBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            accentBar.layer?.cornerRadius = 1.5
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class TimeZoneFallbackDisplayLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A native pop-up menu with custom, non-selectable continent headings.
/// City entries are the only menu items with actions.
final class DashboardTimeZoneComboBox: NSPopUpButton, SettingsRowAccessoryLayout, NSMenuDelegate {
    private let preferences: AppPreferences
    private weak var relay: DashboardPreferencePageRelay?
    private var applying = false
    private var menuBuilt = false
    private var displayedTitle = ""
    private let fallbackDisplayLabel = TimeZoneFallbackDisplayLabel(labelWithString: "")

    override var stringValue: String {
        get { displayedTitle }
        set { displayedTitle = newValue }
    }

    init(preferences: AppPreferences, relay: DashboardPreferencePageRelay) {
        self.preferences = preferences
        self.relay = relay
        super.init(frame: .zero, pullsDown: false)
        identifier = NSUserInterfaceItemIdentifier(AppPreferences.displayTimeZoneKey)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        let preferredWidth = widthAnchor.constraint(equalToConstant: 280)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel(tr(.keyTimeZoneTitle))
        fallbackDisplayLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackDisplayLabel.alignment = .left
        fallbackDisplayLabel.lineBreakMode = .byTruncatingTail
        fallbackDisplayLabel.drawsBackground = true
        fallbackDisplayLabel.backgroundColor = .controlBackgroundColor
        fallbackDisplayLabel.isSelectable = false
        fallbackDisplayLabel.isHidden = true
        addSubview(fallbackDisplayLabel)
        NSLayoutConstraint.activate([
            fallbackDisplayLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fallbackDisplayLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            fallbackDisplayLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        target = self
        action = #selector(selectTimeZone(_:))
        autoenablesItems = false
        menu?.delegate = self
        apply(preferences.displayTimeZoneSelection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var completes: Bool { false }
    var minimumInlineLabelWidth: CGFloat { 120 }
    var naturalAccessoryWidth: CGFloat { 280 }
    func updateAvailableRowWidth(_ width: CGFloat) {}
    override var intrinsicContentSize: NSSize {
        NSSize(width: 280, height: super.intrinsicContentSize.height)
    }

    func apply(_ selection: AppTimeZoneSelection) {
        applying = true
        defer { applying = false }
        if !menuBuilt {
            removeAllItems()
            let cities = TimeZoneCityCatalog.all.sorted {
            let left = TimeZoneCityCatalog.continentTitle(for: $0)
            let right = TimeZoneCityCatalog.continentTitle(for: $1)
            if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            return TimeZoneCityCatalog.compare($0, $1)
        }
        var currentContinent: String?
        for city in cities {
            let continent = TimeZoneCityCatalog.continentTitle(for: city)
            if currentContinent != continent {
                menu?.addItem(makeHeaderItem(title: continent))
                currentContinent = continent
            }
            let item = NSMenuItem(title: city.title, action: #selector(selectTimeZone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = city.identifier
            menu?.addItem(item)
            }
            menuBuilt = true
        }
        // Never assign `title` to text absent from the menu: AppKit would
        // implicitly create a selectable menu item. For an internal fixed
        // offset fallback, update only the popup cell's displayed text.
        let identifier = selection.resolved().identifier
        if let item = menu?.items.first(where: { ($0.representedObject as? String) == identifier }) {
            fallbackDisplayLabel.isHidden = true
            select(item)
            displayedTitle = item.title
        } else {
            // The fallback value is not a menu item. Clear the previous city
            // selection so AppKit cannot report a stale selectedItem.
            select(nil)
            displayedTitle = TimeZoneCityCatalog.displayTitle(for: selection)
            fallbackDisplayLabel.stringValue = displayedTitle
            fallbackDisplayLabel.isHidden = false
        }
        // A fallback value only changes the presentation; the city menu must
        // remain usable so the user can choose a supported region immediately.
        isEnabled = selection != .system
        toolTip = selection.title()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Re-evaluate dynamic UTC offsets when the user opens the list, including
        // DST transitions that occurred while a manual region was selected.
        refreshDynamicMenuTitles()
        apply(preferences.displayTimeZoneSelection)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshDynamicMenuTitles()
    }

    private func refreshDynamicMenuTitles() {
        let titles = Dictionary(uniqueKeysWithValues: TimeZoneCityCatalog.all.map { ($0.identifier, $0.title) })
        for item in menu?.items ?? [] {
            guard let identifier = item.representedObject as? String,
                  let title = titles[identifier] else { continue }
            item.title = title
        }
    }

    private func makeHeaderItem(title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = title
        item.view = MenuHeaderView(title: title)
        item.isEnabled = false
        return item
    }

    @objc private func selectTimeZone(_ sender: NSMenuItem) {
        guard !applying, let identifier = sender.representedObject as? String else { return }
        let selection = AppTimeZoneSelection.region(identifier: identifier)
        guard selection != preferences.displayTimeZoneSelection else { return }
        relay?.onTimeZone?(selection)
    }
}

/// Loads the small bundled agent marks for inline text attachments. The same
/// resources and Grok crop rules as `DashboardRefreshPage.agentIconStrip`.
enum AgentMark {
    static func image(named resource: String, pointSize: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "svg") else { return nil }
        let size = NSSize(width: pointSize, height: pointSize)
        // GrokIdle.svg is a framed artboard; the menu bar crops it too.
        let image = resource == "GrokIdle"
            ? GrokIdleIcon.make(fromSVG: url, outputSize: size)
            : NSImage(contentsOf: url)
        guard let image else { return nil }
        image.size = size
        image.isTemplate = false
        return image
    }
}

/// Renders one agent mark inside the CC Switch row's detail text. Monochrome
/// marks are re-tinted at draw time so they follow the label color across
/// light/dark appearances; Claude keeps its brand colors.
final class AgentMarkAttachmentCell: NSTextAttachmentCell {
    private let tintsWithLabel: Bool
    private let baselineOffset: CGFloat

    init(image: NSImage?, tintsWithLabel: Bool, baselineOffset: CGFloat = 0) {
        self.tintsWithLabel = tintsWithLabel
        self.baselineOffset = baselineOffset
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// NSTextAttachmentCell positions its image on the text baseline by
    /// default, which sits a 13pt mark visibly above the 12pt text mass. The
    /// formatter passes a negative offset to optically center the mark.
    override func cellBaselineOffset() -> CGPoint {
        CGPoint(x: 0, y: baselineOffset)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {
        render(in: cellFrame)
    }

    func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        render(in: cellFrame)
    }

    private func render(in cellFrame: NSRect) {
        guard let image else { return }
        guard tintsWithLabel else {
            image.draw(in: cellFrame)
            return
        }
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSColor.secondaryLabelColor.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
        tinted.unlockFocus()
        tinted.draw(in: cellFrame)
    }
}

/// Fixed-size row of small agent marks. Like the update badge it reports an exact intrinsic
/// size, so the settings row measures its title and detail text as if it were a plain label.
/// Title accessory for the Claude quota sources: the agent mark, then a small tag naming who the source is for.
final class AgentIconTagAccessoryView: NSView {
    static let spacing: CGFloat = 6
    let iconStrip: NSView
    let tagView: SourceAudienceTagView

    init(iconStrip: NSView, tag: String) {
        self.iconStrip = iconStrip
        tagView = SourceAudienceTagView(text: tag)
        super.init(frame: .zero)
        addSubview(iconStrip)
        addSubview(tagView)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let icon = iconStrip.intrinsicContentSize
        let tag = tagView.intrinsicContentSize
        return NSSize(width: icon.width + Self.spacing + tag.width, height: max(icon.height, tag.height))
    }

    override func layout() {
        super.layout()
        let icon = iconStrip.intrinsicContentSize
        let tag = tagView.intrinsicContentSize
        iconStrip.frame = NSRect(x: 0, y: (bounds.height - icon.height) / 2, width: icon.width, height: icon.height)
        tagView.frame = NSRect(x: icon.width + Self.spacing, y: (bounds.height - tag.height) / 2,
                               width: tag.width, height: tag.height)
    }
}

/// A rounded capsule with short secondary text, e.g. "全端通用".
final class SourceAudienceTagView: NSView {
    static let horizontalPadding: CGFloat = 6
    static let height: CGFloat = 16
    let text: String
    private var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedText.size().width) + Self.horizontalPadding * 2, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let label = attributedText
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

final class AgentIconStripView: NSView {
    struct Icon {
        let image: NSImage
        let isTinted: Bool
        var rotationDegrees: CGFloat = 0
    }

    private static let spacing: CGFloat = 4
    private let icons: [Icon]
    private let iconSize: NSSize

    init(icons: [Icon], iconSize: NSSize) {
        self.icons = icons
        self.iconSize = iconSize
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(icons.count)
        let width = count * iconSize.width + max(0, count - 1) * Self.spacing
        return NSSize(width: width, height: iconSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x: CGFloat = 0
        let y = (bounds.height - iconSize.height) / 2
        for icon in icons {
            let natural = icon.image.size
            let fit = min(iconSize.width / max(natural.width, 1), iconSize.height / max(natural.height, 1))
            let drawSize = icon.rotationDegrees == 0
                ? iconSize
                : NSSize(width: natural.width * min(fit, 1), height: natural.height * min(fit, 1))
            let rect = NSRect(
                x: x + (iconSize.width - drawSize.width) / 2,
                // The tilted key's mass sits above its frame's center; nudge it down to the title's optical center.
                y: y + (iconSize.height - drawSize.height) / 2 - (icon.rotationDegrees == 0 ? 0 : 2),
                width: drawSize.width,
                height: drawSize.height
            )
            var drawable = icon.image
            if icon.isTinted {
                let tinted = icon.image.copy() as? NSImage ?? icon.image
                tinted.lockFocus()
                NSColor.secondaryLabelColor.set()
                NSRect(origin: .zero, size: tinted.size).fill(using: .sourceIn)
                tinted.unlockFocus()
                tinted.isTemplate = false
                drawable = tinted
            }
            if icon.rotationDegrees != 0, let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: rect.midX, yBy: rect.midY)
                transform.rotate(byDegrees: icon.rotationDegrees)
                transform.translateX(by: -rect.midX, yBy: -rect.midY)
                transform.concat()
                drawable.draw(in: rect)
                context.restoreGraphicsState()
            } else {
                drawable.draw(in: rect)
            }
            x += iconSize.width + Self.spacing
        }
    }
}
