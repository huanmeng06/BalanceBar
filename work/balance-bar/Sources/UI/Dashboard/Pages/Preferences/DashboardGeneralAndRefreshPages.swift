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
final class DashboardAdaptiveControlsStackView: NSStackView, DashboardSettingsRowControlLayout {
    private var availableRowWidth: CGFloat = .greatestFiniteMagnitude
    private(set) var usesDedicatedRow = false
    var allowsTextDrivenDedicatedRow = false

    func updateAvailableRowWidth(_ width: CGFloat) {
        let normalizedWidth = max(0, width)
        if abs(normalizedWidth - availableRowWidth) > 0.5 {
            availableRowWidth = normalizedWidth
        }
        updateOrientationIfNeeded()
    }

    private var horizontalFittingWidth: CGFloat {
        let visibleButtons = arrangedSubviews.filter { !$0.isHidden }
        let buttonWidth = visibleButtons.reduce(CGFloat(0)) { total, view in
            max(total, view.fittingSize.width)
        }
        let totalWidth = visibleButtons.reduce(CGFloat(0)) { total, view in
            total + view.fittingSize.width
        }
        return max(buttonWidth, totalWidth + max(0, CGFloat(visibleButtons.count - 1)) * spacing) + 1
    }

    override func layout() {
        updateOrientationIfNeeded()
        super.layout()
    }

    private func updateOrientationIfNeeded() {
        let wantsVertical = availableRowWidth > 0 && availableRowWidth + 0.5 < horizontalFittingWidth
        let desiredOrientation: NSUserInterfaceLayoutOrientation = wantsVertical ? .vertical : .horizontal
        let orientationChanged = orientation != desiredOrientation
        let placementChanged = usesDedicatedRow != wantsVertical
        if orientationChanged {
            orientation = desiredOrientation
            alignment = wantsVertical ? .trailing : .centerY
        }
        if placementChanged {
            usesDedicatedRow = wantsVertical
        }
        if orientationChanged || placementChanged {
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
                width: visibleButtons.map { $0.fittingSize.width }.max() ?? 0,
                height: visibleButtons.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
                    + max(0, CGFloat(visibleButtons.count - 1)) * spacing
            )
        }
        return NSSize(
            width: visibleButtons.reduce(CGFloat(0)) { $0 + $1.fittingSize.width }
                + max(0, CGFloat(visibleButtons.count - 1)) * spacing,
            height: visibleButtons.map { $0.fittingSize.height }.max() ?? 0
        )
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
        let currentProviderName: String
        let relay: DashboardPreferencePageRelay
        let updateState: UpdateCheckState
        let launchAtLoginState: LaunchAtLoginState

        init(
            preferences: AppPreferences,
            currentProviderName: String,
            relay: DashboardPreferencePageRelay,
            updateState: UpdateCheckState,
            launchAtLoginState: LaunchAtLoginState = LaunchAtLoginState(status: .notRegistered)
        ) {
            self.preferences = preferences
            self.currentProviderName = currentProviderName
            self.relay = relay
            self.updateState = updateState
            self.launchAtLoginState = launchAtLoginState
        }
    }

    private var updateSubtitleLabel: NSTextField?
    private var updateButton: NSButton?
    private var updateNotesButton: NSButton?
    private var updateBadge: NSView?
    private var launchAtLoginSwitch: NSSwitch?
    private var launchAtLoginSubtitleLabel: NSTextField?
    private var launchAtLoginOpenSettingsButton: NSButton?
    private var launchAtLoginControls: DashboardAdaptiveControlsStackView?

    func make(_ input: Input) -> NSView {
        let openButton = NSButton(
            title: tr(.keyDashboardGeneralAndRefreshPagesOpenCcSwitch),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openCCSwitch(_:))
        )
        let currentProviderText = tr(.keyDashboardGeneralAndRefreshPagesCurrentProviderValue, arguments: [String(describing: input.currentProviderName)])
        let system = DashboardSettingsComponents.makeSettingsSection(tr(.keyDashboardGeneralAndRefreshPagesSystem), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardGeneralAndRefreshPagesCcSwitch),
                subtitle: currentProviderText,
                control: openButton
            )
        ])

        let launchAtLoginSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: LaunchAtLoginController.toggleIdentifier,
            isOn: input.launchAtLoginState.status == .enabled,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.launchAtLogin(_:))
        )
        let launchAtLoginSubtitleLabel = NSTextField(
            wrappingLabelWithString: launchAtLoginSubtitle(for: input.launchAtLoginState)
        )
        let launchAtLoginOpenSettingsButton = NSButton(
            title: tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLoginOpenSettings),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openLaunchAtLoginSettings(_:))
        )
        launchAtLoginOpenSettingsButton.bezelStyle = .rounded
        let launchAtLoginControls = DashboardAdaptiveControlsStackView(
            views: [launchAtLoginSwitch, launchAtLoginOpenSettingsButton]
        )
        launchAtLoginControls.orientation = .horizontal
        launchAtLoginControls.alignment = .centerY
        launchAtLoginControls.spacing = 8
        apply(
            input.launchAtLoginState,
            to: launchAtLoginSwitch,
            subtitle: launchAtLoginSubtitleLabel,
            openSettingsButton: launchAtLoginOpenSettingsButton
        )
        let launchAtLoginRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardGeneralAndRefreshPagesLaunchAtLogin),
            subtitle: launchAtLoginSubtitle(for: input.launchAtLoginState),
            subtitleLabel: launchAtLoginSubtitleLabel,
            control: launchAtLoginControls
        )

        let activeRefreshPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [
                (1, tr(.keyDashboardGeneralAndRefreshPagesEvery1Sec)),
                (2, tr(.keyDashboardGeneralAndRefreshPagesEvery2Sec)),
                (3, tr(.keyDashboardGeneralAndRefreshPagesEvery3Sec)),
                (5, tr(.keyDashboardGeneralAndRefreshPagesEvery5Sec)),
                (10, tr(.keyDashboardGeneralAndRefreshPagesEvery10Sec))
            ],
            selected: input.preferences.codexUsageRefreshInterval,
            identifier: "codexUsageRefreshInterval",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let trailingRefreshPopup = DashboardSettingsComponents.makeIntervalPopUpButton(
            values: [
                (0, tr(.keyDashboardGeneralAndRefreshPagesOff)),
                (6, tr(.keyDashboardGeneralAndRefreshPagesFor6Sec)),
                (12, tr(.keyDashboardGeneralAndRefreshPagesFor12Sec)),
                (30, tr(.keyDashboardGeneralAndRefreshPagesFor30Sec))
            ],
            selected: input.preferences.postCodexRefreshDuration,
            identifier: "postCodexRefreshDuration",
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.interval(_:))
        )
        let runningLabel = NSTextField(labelWithString: tr(.keyDashboardGeneralAndRefreshPagesRunning))
        let trailingLabel = NSTextField(labelWithString: tr(.keyDashboardGeneralAndRefreshPagesAfter))
        [runningLabel, trailingLabel].forEach {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .right
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        [activeRefreshPopup, trailingRefreshPopup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let commonRefreshPopupWidth = ceil(
            max(108, max(activeRefreshPopup.fittingSize.width, trailingRefreshPopup.fittingSize.width))
        )
        [activeRefreshPopup, trailingRefreshPopup].forEach {
            $0.widthAnchor.constraint(equalToConstant: commonRefreshPopupWidth).isActive = true
        }
        let runningControls = NSStackView(views: [runningLabel, activeRefreshPopup])
        runningControls.orientation = .horizontal
        runningControls.alignment = .centerY
        runningControls.spacing = 7
        let trailingControls = NSStackView(views: [trailingLabel, trailingRefreshPopup])
        trailingControls.orientation = .horizontal
        trailingControls.alignment = .centerY
        trailingControls.spacing = 7
        let activeRefreshControls = DashboardAdaptiveControlsStackView(
            views: [runningControls, trailingControls]
        )
        activeRefreshControls.allowsTextDrivenDedicatedRow = true
        activeRefreshControls.orientation = .horizontal
        activeRefreshControls.alignment = .centerY
        activeRefreshControls.spacing = 5
        let refreshButton = NSButton(
            title: tr(.keyDashboardGeneralAndRefreshPagesRefreshNow),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.manualRefresh(_:))
        )
        let refreshing = DashboardSettingsComponents.makeSettingsSection(tr(.keyDashboardGeneralAndRefreshPagesRefresh), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardGeneralAndRefreshPagesBalanceUpdatesDuringTasks),
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesRequestsTheCurrentProviderSBalanceWhileAnAgentIsRunning),
                control: activeRefreshControls,
                minimumHeight: DashboardSettingsComponents.standardRowHeight
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardGeneralAndRefreshPagesBalanceData),
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesReloadTheCurrentProviderNow),
                control: refreshButton
            )
        ])

        let languagePopup = DashboardSettingsComponents.makePopUpButton(
            items: AppLanguage.allCases.map {
                DashboardSettingsComponents.PopUpItem(
                    title: $0.localizedTitle,
                    representedObject: $0.rawValue
                )
            },
            selectedIndex: AppLanguage.allCases.firstIndex(of: AppLanguage.selected),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.language(_:))
        )
        let updatePresentation = DashboardUpdatePresentation.make(for: input.updateState)
        let updateBadge = DashboardUpdateBadgeView()
        updateBadge.isHidden = !updatePresentation.showsUpdateBadge
        let updateSubtitle = NSTextField(wrappingLabelWithString: updatePresentation.subtitle)
        updateSubtitle.identifier = NSUserInterfaceItemIdentifier("checkForUpdatesSubtitle")
        let updateButton = NSButton(
            title: updatePresentation.buttonTitle,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.update(_:))
        )
        updateButton.identifier = NSUserInterfaceItemIdentifier("checkForUpdatesButton")
        updateButton.bezelStyle = .rounded
        apply(updatePresentation, to: updateButton, subtitle: updateSubtitle)
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
        let updateChannelRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardGeneralAndRefreshPagesUpdateChannel),
            subtitle: tr(.keyDashboardGeneralAndRefreshPagesUpdateChannelDescription),
            control: updateChannelPopup
        )
        let updateControls = DashboardAdaptiveControlsStackView(views: [updateNotesButton, updateButton])
        updateControls.orientation = .horizontal
        updateControls.alignment = .centerY
        updateControls.spacing = 8
        updateControls.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateControls.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.updateSubtitleLabel = updateSubtitle
        self.updateButton = updateButton
        self.updateNotesButton = updateNotesButton
        self.updateBadge = updateBadge
        self.launchAtLoginSwitch = launchAtLoginSwitch
        self.launchAtLoginSubtitleLabel = launchAtLoginSubtitleLabel
        self.launchAtLoginOpenSettingsButton = launchAtLoginOpenSettingsButton
        self.launchAtLoginControls = launchAtLoginControls

        let app = DashboardSettingsComponents.makeSettingsSection(tr(.keyDashboardGeneralAndRefreshPagesApplication), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardGeneralAndRefreshPagesLanguage),
                subtitle: tr(.keyDashboardGeneralAndRefreshPagesChangesApplyToTheEntireInterfaceImmediately),
                control: languagePopup
            ),
            launchAtLoginRow,
            updateChannelRow,
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardGeneralAndRefreshPagesCheckForUpdates3),
                subtitle: updatePresentation.subtitle,
                subtitleLabel: updateSubtitle,
                titleAccessory: updateBadge,
                control: updateControls,
                controlWidthConstrainedToRow: true
            )
        ])
        return DashboardSettingsComponents.makeSettingsPage([system, refreshing, app])
    }

    func refreshLaunchAtLogin(_ state: LaunchAtLoginState) {
        guard let launchAtLoginSwitch,
              let launchAtLoginSubtitleLabel,
              let launchAtLoginOpenSettingsButton
        else { return }
        apply(
            state,
            to: launchAtLoginSwitch,
            subtitle: launchAtLoginSubtitleLabel,
            openSettingsButton: launchAtLoginOpenSettingsButton
        )
        launchAtLoginControls?.invalidateLayoutAfterContentChange()
        launchAtLoginSwitch.superview?.needsLayout = true
        launchAtLoginSubtitleLabel.superview?.needsLayout = true
        launchAtLoginSubtitleLabel.superview?.superview?.needsLayout = true
    }

    func refresh(updateState: UpdateCheckState) {
        let presentation = DashboardUpdatePresentation.make(for: updateState)
        guard let updateSubtitleLabel, let updateButton else { return }
        apply(presentation, to: updateButton, subtitle: updateSubtitleLabel)
        apply(presentation, to: updateNotesButton)
        updateBadge?.isHidden = !presentation.showsUpdateBadge
        (updateButton.superview as? DashboardAdaptiveControlsStackView)?.invalidateLayoutAfterContentChange()
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

    private func apply(
        _ state: LaunchAtLoginState,
        to launchAtLoginSwitch: NSSwitch,
        subtitle: NSTextField,
        openSettingsButton: NSButton
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
        openSettingsButton.isHidden = state.status != .requiresApproval
        subtitle.stringValue = launchAtLoginSubtitle(for: state)
        subtitle.invalidateIntrinsicContentSize()
    }

    private func apply(
        _ presentation: DashboardUpdatePresentation,
        to button: NSButton,
        subtitle: NSTextField
    ) {
        button.title = presentation.buttonTitle
        button.isEnabled = presentation.buttonEnabled
        button.tag = presentation.performsInstall ? 1 : 0
        subtitle.stringValue = presentation.subtitle
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

enum DashboardRefreshPage {
    struct Input {
        let preferences: AppPreferences
        let providerPollInterval: TimeInterval
        let relay: DashboardPreferencePageRelay
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
