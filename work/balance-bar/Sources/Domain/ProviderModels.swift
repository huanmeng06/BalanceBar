import Foundation

struct ProviderBalanceSnapshotCache {
    private struct Key: Hashable {
        let clientID: String
        let providerID: String
    }

    private var snapshots: [Key: Snapshot] = [:]

    mutating func store(_ snapshot: Snapshot, clientID: String, providerID: String) {
        guard snapshot.kind == .balance else { return }
        snapshots[Key(clientID: clientID, providerID: providerID)] = snapshot
    }

    func errorSnapshot(
        clientID: String,
        providerID: String,
        providerName: String,
        reason: String
    ) -> Snapshot {
        Snapshot.providerError(
            providerName,
            reason: reason,
            cachedBalance: snapshots[Key(clientID: clientID, providerID: providerID)]
        )
    }
}

struct ProviderChoice {
    let id: String
    let name: String
    let isCurrent: Bool
}

struct ProviderSummarySource {
    let id: String
    let isOfficial: Bool
    let query: BalanceQuery?
    let officialAccessToken: String?
    let openCodexCandidate: OpenCodexEndpointCandidate?
}
