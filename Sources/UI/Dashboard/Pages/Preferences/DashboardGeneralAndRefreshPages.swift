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
        let currentProviderName: String
        let relay: DashboardPreferencePageRelay
        let updateState: UpdateCheckState
        let launchAtLoginState: LaunchAtLoginState
        let launchWithChatGPTState: LaunchWithChatGPTState

        init(
            preferences: AppPreferences,
            currentProviderName: String,
            relay: DashboardPreferencePageRelay,
            updateState: UpdateCheckState,
            launchAtLoginState: LaunchAtLoginState = LaunchAtLoginState(status: .notRegistered),
            launchWithChatGPTState: LaunchWithChatGPTState = LaunchWithChatGPTState(status: .notRegistered)
        ) {
            self.preferences = preferences
            self.currentProviderName = currentProviderName
            self.relay = relay
            self.updateState = updateState
            self.launchAtLoginState = launchAtLoginState
            self.launchWithChatGPTState = launchWithChatGPTState
        }
    }

    private var updateSubtitleLabel: NSTextField?
    private var updateButton: NSButton?
    private var updateNotesButton: NSButton?
    private var updateBadge: NSView?
    private var launchAtLoginSwitch: NSSwitch?
    private var launchAtLoginSubtitleLabel: NSTextField?
    private var launchWithChatGPTSwitch: NSSwitch?
    private var launchWithChatGPTSubtitleLabel: NSTextField?
    private var launchWithChatGPTOpenSettingsButton: NSButton?
    private var launchWithChatGPTControls: DashboardAdaptiveControlsStackView?

    func make(_ input: Input) -> NSView {
        let openButton = NSButton(
            title: tr(.keyDashboardGeneralAndRefreshPagesOpenCcSwitch),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openCCSwitch(_:))
        )
        let currentProviderText = tr(.keyDashboardGeneralAndRefreshPagesCurrentProviderValue, arguments: [String(describing: input.currentProviderName)])
        let system = SettingsSectionView(
            title: tr(.keyDashboardGeneralAndRefreshPagesSystem),
            contentViews: [
                SettingsRowView(
                    title: tr(.keyDashboardGeneralAndRefreshPagesCcSwitch),
                    detail: currentProviderText,
                    accessoryView: openButton
                )
            ]
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
        [activeRefreshPopup, trailingRefreshPopup].forEach { popup in
            for constraint in popup.constraints where constraint.firstAttribute == .width {
                constraint.priority = .defaultHigh
            }
            let preferredWidth = popup.widthAnchor.constraint(equalToConstant: commonRefreshPopupWidth)
            preferredWidth.priority = .defaultHigh
            preferredWidth.isActive = true
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
        activeRefreshControls.minimumInlineLabelWidth = SettingsRowView.minimumInlineLabelWidth
        activeRefreshControls.orientation = .horizontal
        activeRefreshControls.alignment = .centerY
        activeRefreshControls.spacing = 5
        let refreshButton = NSButton(
            title: tr(.keyDashboardGeneralAndRefreshPagesRefreshNow),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.manualRefresh(_:))
        )
        let refreshing = SettingsSectionView(
            title: tr(.keyDashboardGeneralAndRefreshPagesRefresh),
            contentViews: [
                SettingsRowView(
                    title: tr(.keyDashboardGeneralAndRefreshPagesBalanceUpdatesDuringTasks),
                    detail: tr(.keyDashboardGeneralAndRefreshPagesRequestsTheCurrentProviderSBalanceWhileAnAgentIsRunning),
                    accessoryView: activeRefreshControls
                ),
                SettingsRowView(
                    title: tr(.keyDashboardGeneralAndRefreshPagesBalanceData),
                    detail: tr(.keyDashboardGeneralAndRefreshPagesReloadTheCurrentProviderNow),
                    accessoryView: refreshButton
                )
            ]
        )

        let languagePopup = DashboardSettingsComponents.makePopUpButton(
            identifier: AppLanguage.preferenceKey,
            items: AppLanguage.allCases.map {
                DashboardSettingsComponents.PopUpItem(
                    title: $0.localizedTitle,
                    representedObject: $0.rawValue
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

        let app = SettingsSectionView(
            title: tr(.keyDashboardGeneralAndRefreshPagesApplication),
            contentViews: [
                SettingsRowView(
                    title: tr(.keyDashboardGeneralAndRefreshPagesLanguage),
                    detail: tr(.keyDashboardGeneralAndRefreshPagesChangesApplyToTheEntireInterfaceImmediately),
                    accessoryView: languagePopup
                ),
                updateChannelRow,
                updateRow
            ]
        )
        return DashboardSettingsComponents.makeSettingsPageContent([system, refreshing, startup, app])
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
