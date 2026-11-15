import Foundation
import Network

/// User settings for the Claude official-request egress guard (Issue #686).
struct ClaudeEgressGuardSettings: Equatable {
    /// Off means Claude official requests are never sent.
    var enabled: Bool
    /// Egress IPs allowed to send Claude official requests; matching any one is enough.
    var allowedIPs: [String]

    static let disabled = ClaudeEgressGuardSettings(enabled: false, allowedIPs: [])
}

/// Why the guard kept a Claude official request on this machine.
enum ClaudeEgressGuardBlock: String, Equatable {
    /// The guard switch is off: official requests are turned off altogether.
    case disabled
    /// The guard is on but no allowed IP was entered.
    case noTargets = "no_targets"
    /// The current egress IP is not in the allowed list.
    case mismatch
    /// The egress IP could not be determined (network error, non-2xx, unparsable trace).
    case checkFailed = "check_failed"
}

enum ClaudeEgressGuardDecision: Equatable {
    case allowed
    case blocked(ClaudeEgressGuardBlock)
}

/// IP text normalization so equivalent spellings (IPv6 compression, whitespace) compare equal.
/// IPv4 and IPv6 are never converted into each other.
enum EgressIPAddress {
    /// Raw address bytes, or nil when the text is not a literal IPv4/IPv6 address.
    static func normalize(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("%") else { return nil }
        if let v4 = IPv4Address(trimmed), trimmed.split(separator: ".").count == 4 { return v4.rawValue }
        if trimmed.contains(":"), let v6 = IPv6Address(trimmed) { return v6.rawValue }
        return nil
    }

    static func isValid(_ text: String) -> Bool { normalize(text) != nil }

    /// Trimmed, valid, de-duplicated (by address bytes) list in the original order.
    static func sanitizedList(_ values: [String]) -> [String] {
        var seen = Set<Data>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let bytes = normalize(trimmed), seen.insert(bytes).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func contains(_ list: [String], _ ip: String) -> Bool {
        guard let target = normalize(ip) else { return false }
        return list.contains { normalize($0) == target }
    }
}

/// Parses Cloudflare's `/cdn-cgi/trace` plain-text body (`key=value` lines).
enum CloudflareTraceParser {
    static func ip(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("ip=") else { continue }
            let value = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return EgressIPAddress.isValid(value) ? value : nil
        }
        return nil
    }
}

/// Decides whether a Claude official request may leave this machine.
///
/// The egress IP is probed through the same proxy route as the usage request immediately before
/// each request; nothing is cached across requests. Concurrent evaluations share one probe.
/// Diagnostics name only the outcome, never an IP address.
final class ClaudeEgressGuard {
    typealias ProbeResult = Result<String, OfficialQuotaTransportError>
    typealias Probe = (@escaping (ProbeResult) -> Void) -> Void

    let settings: () -> ClaudeEgressGuardSettings
    private let probe: Probe
    private let diagnostics: (String) -> Void
    private let lock = NSLock()
    private var waiting: [(ProbeResult) -> Void] = []

    init(
        settings: @escaping () -> ClaudeEgressGuardSettings,
        probe: @escaping Probe,
        diagnostics: @escaping (String) -> Void = { SwitchLog.write($0, level: .info, category: "refresh.egress_guard") }
    ) {
        self.settings = settings
        self.probe = probe
        self.diagnostics = diagnostics
    }

    var isEnabled: Bool { settings().enabled }

    /// Calls `completion` exactly once, on any queue.
    func evaluate(completion: @escaping (ClaudeEgressGuardDecision) -> Void) {
        let current = settings()
        guard current.enabled else { return finish(.blocked(.disabled), completion) }
        let allowed = EgressIPAddress.sanitizedList(current.allowedIPs)
        guard !allowed.isEmpty else { return finish(.blocked(.noTargets), completion) }
        currentEgressIP { [self] result in
            switch result {
            case let .success(ip):
                // Re-read: the list may have changed while the probe ran.
                let latest = settings()
                let decision: ClaudeEgressGuardDecision = latest.enabled
                    ? (EgressIPAddress.contains(latest.allowedIPs, ip) ? .allowed : .blocked(.mismatch))
                    : .blocked(.disabled)
                finish(decision, completion)
            case .failure:
                finish(.blocked(.checkFailed), completion)
            }
        }
    }

    /// Probes the current egress IP (shared with concurrent callers); used by the settings
    /// "detect" button as well. Calls `completion` exactly once, on any queue.
    func currentEgressIP(completion: @escaping (ProbeResult) -> Void) {
        let starts = lock.withLock { () -> Bool in
            waiting.append(completion)
            return waiting.count == 1
        }
        guard starts else { return }
        probe { [self] result in
            let callbacks = lock.withLock { () -> [(ProbeResult) -> Void] in
                defer { waiting.removeAll() }
                return waiting
            }
            callbacks.forEach { $0(result) }
        }
    }

    private func finish(_ decision: ClaudeEgressGuardDecision, _ completion: (ClaudeEgressGuardDecision) -> Void) {
        switch decision {
        case .allowed: diagnostics("egress guard; result=passed")
        case let .blocked(block): diagnostics("egress guard; result=\(block.rawValue)")
        }
        completion(decision)
    }
}
