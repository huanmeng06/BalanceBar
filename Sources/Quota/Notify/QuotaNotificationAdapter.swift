import Foundation

/// The part of the existing notification module this adapter calls. The
/// existing `BalanceNotificationCoordinator` owns thresholds, Provider
/// switches, pause, permission, per-account progress and once-per-crossing
/// deduplication; this adapter never reimplements those rules.
protocol QuotaNotificationSnapshotProcessing: AnyObject {
    func process(snapshot: Snapshot, agent: BalanceNotificationAgent, providerID: String)
}

extension BalanceNotificationCoordinator: QuotaNotificationSnapshotProcessing {}

/// Adapts Claude official quota display state and quota events to the
/// existing notification rules.
///
/// - Only official windows (grade A, or a grade-B value that passed merge
///   validation, i.e. `isEstimated == false`) are forwarded; estimates never
///   reach the threshold rules.
/// - A rise in remaining quota (which the existing rules treat as recovery)
///   is held back until `.resetConfirmed` arrives for that window, so a
///   predicted-but-unconfirmed reset never produces a recovery notification.
///
/// Safe to call from any thread. Calls are serialized, and each snapshot is
/// handed to the processor inside the same critical section that produced
/// it, so the processor sees snapshots in state-change order. The processor
/// must therefore never call back into this adapter.
final class QuotaNotificationAdapter: QuotaNotificationSink {
    private struct WindowState {
        /// Remaining percentage last handed to the existing rules.
        var forwardedRemaining: Double
        /// Newer official value that is higher than `forwardedRemaining` and
        /// waits for a confirmed reset.
        var heldRemaining: Double?
        var resetConfirmed = false
    }

    private let processor: QuotaNotificationSnapshotProcessing
    private let agent: BalanceNotificationAgent
    private let providerID: String
    private let lock = NSLock()
    private var accountScope: String?
    private var windows: [QuotaWindowKind: WindowState] = [:]
    private var order: [QuotaWindowKind] = []

    init(
        processor: QuotaNotificationSnapshotProcessing,
        agent: BalanceNotificationAgent = .claude,
        providerID: String
    ) {
        self.processor = processor
        self.agent = agent
        self.providerID = providerID
    }

    /// Forwards the official part of one merged display model.
    func update(_ model: QuotaDisplayModel, accountScope: String?) {
        lock.withLock {
            if accountScope != self.accountScope {
                self.accountScope = accountScope
                windows = [:]
                order = []
            }
            var changed = false
            for display in model.windows {
                guard let remaining = Self.officialRemaining(display) else { continue }
                guard var state = windows[display.kind] else {
                    windows[display.kind] = WindowState(forwardedRemaining: remaining)
                    order.append(display.kind)
                    changed = true
                    continue
                }
                if remaining > state.forwardedRemaining, !state.resetConfirmed {
                    state.heldRemaining = remaining
                } else {
                    state.forwardedRemaining = remaining
                    state.heldRemaining = nil
                    state.resetConfirmed = false
                    changed = true
                }
                windows[display.kind] = state
            }
            if changed { submit(makeSnapshot()) }
        }
    }

    func publish(_ event: QuotaNotificationEvent) {
        switch event {
        case let .resetConfirmed(window):
            lock.withLock {
                guard var state = windows[window] else { return }
                guard let held = state.heldRemaining else {
                    // The confirming official value has not arrived yet; let
                    // the next higher value through.
                    state.resetConfirmed = true
                    windows[window] = state
                    return
                }
                state.forwardedRemaining = held
                state.heldRemaining = nil
                state.resetConfirmed = false
                windows[window] = state
                submit(makeSnapshot())
            }
        }
    }

    /// Must be called with `lock` held; see the type's ordering contract.
    private func submit(_ snapshot: Snapshot) {
        processor.process(snapshot: snapshot, agent: agent, providerID: providerID)
    }

    private static func officialRemaining(_ display: QuotaWindowDisplay) -> Double? {
        guard !display.isEstimated,
              display.state == .inProgress || display.state == .notStarted,
              let used = display.usedPercentage,
              used.isFinite else { return nil }
        return min(100, max(0, 100 - used))
    }

    private func makeSnapshot() -> Snapshot {
        let quotaWindows = order.compactMap { kind -> OfficialQuotaWindow? in
            guard let state = windows[kind] else { return nil }
            let mapped: OfficialQuotaWindow.Kind
            let label: String
            switch kind {
            case .fiveHour: mapped = .fiveHour; label = "5h"
            case .sevenDay: mapped = .sevenDay; label = "7d"
            case let .other(name): mapped = .other; label = name
            }
            return OfficialQuotaWindow(
                kind: mapped,
                remaining: state.forwardedRemaining,
                label: label,
                daysText: label,
                reset: nil,
                durationSeconds: nil
            )
        }
        var snapshot = Snapshot.official(
            agent.title,
            quotaWindows.first?.remaining ?? 0,
            "",
            nil,
            Date(),
            windows: quotaWindows
        )
        snapshot.notificationAccountScope = accountScope
        return snapshot
    }
}
