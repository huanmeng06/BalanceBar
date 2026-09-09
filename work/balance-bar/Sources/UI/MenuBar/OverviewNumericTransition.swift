import AppKit
import Foundation

enum OverviewNumericIdentity: Hashable {
    case officialWindow(provider: String, kind: OfficialQuotaWindow.Kind)
    case officialOther(provider: String, label: String)
    case lunaReserve(provider: String)
    case thirdPartyBalance(provider: String, unit: String)
    case bankedResetCount(provider: String)
    case bankedResetProbability(provider: String)
}

enum OverviewNumericFormat: Equatable {
    case integerPercent
    case currency(unit: String)
    case integerCount

    func isCompatible(with other: OverviewNumericFormat) -> Bool {
        switch (self, other) {
        case (.integerPercent, .integerPercent), (.integerCount, .integerCount):
            return true
        case let (.currency(left), .currency(right)):
            return left.uppercased() == right.uppercased()
        default:
            return false
        }
    }

    func displayText(for value: Double) -> String {
        switch self {
        case .integerPercent:
            return "\(Int(value))%"
        case .integerCount:
            return "\(Int(value))"
        case .currency(let unit):
            return StatusItemController.formatBalanceSummary(value, unit: unit)
        }
    }

    var displayParts: OverviewNumericDisplayParts {
        switch self {
        case .integerPercent:
            return OverviewNumericDisplayParts(prefix: "", suffix: "%", fractionLength: 0)
        case .integerCount:
            return OverviewNumericDisplayParts(prefix: "", suffix: "", fractionLength: 0)
        case .currency(let unit):
            switch unit.uppercased() {
            case "USD":
                return OverviewNumericDisplayParts(prefix: "$", suffix: "", fractionLength: 2)
            case "CNY", "CNH", "RMB":
                return OverviewNumericDisplayParts(prefix: "¥", suffix: "", fractionLength: 2)
            default:
                return OverviewNumericDisplayParts(prefix: "", suffix: " \(unit)", fractionLength: 2)
            }
        }
    }
}

struct OverviewNumericDisplayParts: Equatable {
    let prefix: String
    let suffix: String
    let fractionLength: Int
}

struct OverviewNumericSample: Equatable {
    let identity: OverviewNumericIdentity
    let format: OverviewNumericFormat
    let value: Double
    let progressPercentage: Double?

    var displayText: String { format.displayText(for: value) }
}

struct OverviewNumericTransitionPlan: Equatable {
    let identity: OverviewNumericIdentity
    let format: OverviewNumericFormat
    let fromValue: Double
    let toValue: Double
    let fromProgress: Double?
    let toProgress: Double?
    let animates: Bool

    var startValue: Double { animates ? fromValue : toValue }
    var startProgress: Double? { animates ? fromProgress : toProgress }
    var startText: String { format.displayText(for: startValue) }
    var endText: String { format.displayText(for: toValue) }

    /// Keep the marquee viewport stable for the wider of the two frames.
    var layoutReservationText: String {
        let startWidth = AccountMarqueeView.textWidth(
            of: startText,
            font: Self.reservationFont
        )
        let endWidth = AccountMarqueeView.textWidth(
            of: endText,
            font: Self.reservationFont
        )
        return startWidth >= endWidth ? startText : endText
    }

    private static let reservationFont = NSFont.monospacedDigitSystemFont(
        ofSize: OpenCodexCardLayout.quotaAmountPointSize,
        weight: .semibold
    )
}

enum OverviewNumericTransition {
    static let duration: TimeInterval = 0.72
    static let currencyDigitRollDuration: TimeInterval = 0.32
    /// Hold the last-seen overview values after the menu appears, then roll.
    static let openDelay: TimeInterval = 0.22

    static func duration(for format: OverviewNumericFormat) -> TimeInterval {
        switch format {
        case .currency:
            return currencyDigitRollDuration
        case .integerPercent, .integerCount:
            return duration
        }
    }

    static func plan(
        previous: OverviewNumericSample?,
        current: OverviewNumericSample,
        reduceMotion: Bool
    ) -> OverviewNumericTransitionPlan {
        let previousMatches = previous.map {
            $0.identity == current.identity && $0.format.isCompatible(with: current.format)
        } ?? false
        let displayChanged = previous?.displayText != current.displayText
        let progressChanged = abs(
            (previous?.progressPercentage ?? .nan) - (current.progressPercentage ?? .nan)
        ) > 0.05
        let animates = !reduceMotion
            && previousMatches
            && (displayChanged || progressChanged)

        return OverviewNumericTransitionPlan(
            identity: current.identity,
            format: current.format,
            fromValue: previous?.value ?? current.value,
            toValue: current.value,
            fromProgress: previous?.progressPercentage ?? current.progressPercentage,
            toProgress: current.progressPercentage,
            animates: animates
        )
    }

    static func commitSeenValues(
        _ presented: [OverviewNumericSample]
    ) -> [OverviewNumericIdentity: OverviewNumericSample] {
        Dictionary(uniqueKeysWithValues: presented.map { ($0.identity, $0) })
    }
}

enum OverviewNumericPresentation {
    static func samples(
        snapshot: Snapshot,
        lunaReserveDisplayMode: LunaReserveDisplayMode,
        hideExhaustedQuota: Bool,
        showBankedReset: Bool
    ) -> [OverviewNumericSample] {
        switch snapshot.kind {
        case .placeholder, .error:
            return []
        case .balance:
            guard let amount = snapshot.amount, let unit = snapshot.unit else { return [] }
            return [
                OverviewNumericSample(
                    identity: .thirdPartyBalance(provider: snapshot.provider, unit: unit),
                    format: .currency(unit: unit),
                    value: amount,
                    progressPercentage: snapshot.progressPercentage
                )
            ]
        case .official:
            let presentation = snapshot.officialQuotaMenuPresentation(
                lunaReserveDisplayMode: lunaReserveDisplayMode,
                hideExhaustedQuota: hideExhaustedQuota
            )
            var samples: [OverviewNumericSample] = presentation.windows.map { window in
                OverviewNumericSample(
                    identity: identity(for: window, provider: snapshot.provider),
                    format: .integerPercent,
                    value: window.remaining,
                    progressPercentage: window.remaining
                )
            }
            if let remaining = presentation.lunaReserve?.remaining {
                samples.append(
                    OverviewNumericSample(
                        identity: .lunaReserve(provider: snapshot.provider),
                        format: .integerPercent,
                        value: remaining,
                        progressPercentage: remaining
                    )
                )
            }
            if showBankedReset, let bankedReset = presentation.bankedReset {
                samples.append(
                    OverviewNumericSample(
                        identity: .bankedResetCount(provider: snapshot.provider),
                        format: .integerCount,
                        value: Double(bankedReset.availableCount),
                        progressPercentage: nil
                    )
                )
                if case .percent(let percent) = presentation.resetProbability {
                    samples.append(
                        OverviewNumericSample(
                            identity: .bankedResetProbability(provider: snapshot.provider),
                            format: .integerPercent,
                            value: Double(percent),
                            progressPercentage: nil
                        )
                    )
                }
            }
            return samples
        }
    }

    static func identity(
        for window: OfficialQuotaWindow,
        provider: String
    ) -> OverviewNumericIdentity {
        switch window.kind {
        case .fiveHour, .sevenDay:
            return .officialWindow(provider: provider, kind: window.kind)
        case .other:
            return .officialOther(provider: provider, label: window.label)
        }
    }

    static func progressIdentifier(for identity: OverviewNumericIdentity) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("overview.numeric.progress.\(progressKey(for: identity))")
    }

    static func amountIdentifier(for identity: OverviewNumericIdentity) -> NSUserInterfaceItemIdentifier {
        switch identity {
        case .bankedResetCount:
            return NSUserInterfaceItemIdentifier("codex.bankedReset.count")
        case .bankedResetProbability:
            return NSUserInterfaceItemIdentifier("codex.bankedReset.probability")
        default:
            return NSUserInterfaceItemIdentifier("overview.numeric.amount.\(progressKey(for: identity))")
        }
    }

    private static func progressKey(for identity: OverviewNumericIdentity) -> String {
        switch identity {
        case let .officialWindow(_, kind):
            return "official.\(kind.rawValue)"
        case .officialOther:
            return "official.other"
        case .lunaReserve:
            return "lunaReserve"
        case .thirdPartyBalance:
            return "balance"
        case .bankedResetCount:
            return "bankedReset.count"
        case .bankedResetProbability:
            return "bankedReset.probability"
        }
    }
}
