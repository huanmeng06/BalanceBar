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

/// ISO 3166 country codes from ipinfo.io, and how the allowlist table shows them.
enum IPCountryCode {
    /// ipinfo's `/<ip>/country` body is the bare two-letter code; anything else (a bogon JSON body,
    /// an error page) is not a country.
    static func parse(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            text.count == 2, text.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return text
    }

    /// "🇺🇸 United States" in the app language, with the app's naming for CN, HK, MO and TW. TW gets
    /// no flag so the title stays consistent with that naming.
    static func displayTitle(_ code: String, locale: Locale = TimeZoneCityCatalog.locale) -> String {
        let name = TimeZoneCityCatalog.countryTitle(for: code, locale: locale)
        guard code != "TW" else { return name }
        let flag = code.unicodeScalars
            .compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 0x41) }
            .map(String.init).joined()
        return "\(flag) \(name)"
    }
}

/// Anthropic's Supported Regions Policy (anthropic.com/supported-countries), as ISO 3166 codes.
/// A snapshot shipped with the app, for display only: it never decides whether a request is sent.
/// Ukraine is listed with regional exceptions that a country lookup cannot see, so it counts as
/// supported.
enum AnthropicSupportedRegions {
    /// The policy's effective date this snapshot was taken from.
    static let snapshotDate = "2026-11-12"
    static let codes: Set<String> = [
        "AL", "DZ", "AD", "AO", "AG", "AR", "AM", "AU", "AT", "AZ", "BS", "BH", "BD", "BB", "BE", "BZ",
        "BJ", "BT", "BO", "BA", "BW", "BR", "BN", "BG", "BF", "BI", "CV", "KH", "CM", "CA", "CF", "TD",
        "CL", "CO", "KM", "CG", "CD", "CR", "CI", "HR", "CY", "CZ", "DK", "DJ", "DM", "DO", "EC", "EG",
        "SV", "GQ", "ER", "EE", "SZ", "ET", "FJ", "FI", "FR", "GA", "GM", "GE", "DE", "GH", "GR", "GD",
        "GT", "GN", "GW", "GY", "HT", "HN", "HU", "IS", "IN", "ID", "IQ", "IE", "IL", "IT", "JM", "JP",
        "JO", "KZ", "KE", "KI", "KW", "KG", "LA", "LV", "LB", "LS", "LR", "LY", "LI", "LT", "LU", "MG",
        "MW", "MY", "MV", "ML", "MT", "MH", "MR", "MU", "MX", "FM", "MD", "MC", "MN", "ME", "MA", "MZ",
        "NA", "NR", "NP", "NL", "NZ", "NI", "NE", "NG", "MK", "NO", "OM", "PK", "PW", "PS", "PA", "PG",
        "PY", "PE", "PH", "PL", "PT", "QA", "RO", "RW", "KN", "LC", "VC", "WS", "SM", "ST", "SA", "SN",
        "RS", "SC", "SL", "SG", "SK", "SI", "SO", "SB", "ZA", "KR", "SS", "ES", "LK", "SD", "SR", "SE",
        "CH", "TW", "TJ", "TZ", "TH", "TL", "TG", "TO", "TT", "TN", "TR", "TM", "TV", "UG", "UA", "AE",
        "GB", "US", "UY", "UZ", "VU", "VA", "VN", "ZM", "ZW",
    ]

    static func isSupported(_ countryCode: String) -> Bool {
        codes.contains(countryCode.uppercased())
    }
}

/// Remembers the country of each allowlisted IP so ipinfo.io is asked once per address, not on
/// every page load. Failed lookups are not remembered and are retried the next time they are
/// asked for. Concurrent asks for one address share one lookup.
final class EgressIPCountryCache {
    typealias Lookup = (String, @escaping (String?) -> Void) -> Void

    private let lock = NSLock()
    private let load: () -> [String: String]
    private let store: ([String: String]) -> Void
    private let lookup: Lookup
    private var waiting: [String: [(String?) -> Void]] = [:]

    init(load: @escaping () -> [String: String], store: @escaping ([String: String]) -> Void, lookup: @escaping Lookup) {
        self.load = load
        self.store = store
        self.lookup = lookup
    }

    /// Spelling-independent key, so `2001:DB8::1` and `2001:db8::1` share one entry.
    static func key(for ip: String) -> String? {
        EgressIPAddress.normalize(ip)?.map { String(format: "%02x", $0) }.joined()
    }

    func cachedCode(for ip: String) -> String? {
        guard let key = Self.key(for: ip) else { return nil }
        return lock.withLock { load()[key] }
    }

    /// Calls `completion` once, on any queue, with the cached or freshly looked-up code.
    func code(for ip: String, completion: @escaping (String?) -> Void) {
        guard let key = Self.key(for: ip) else { return completion(nil) }
        let (cached, starts) = lock.withLock { () -> (String?, Bool) in
            if let cached = load()[key] { return (cached, false) }
            waiting[key, default: []].append(completion)
            return (nil, waiting[key]?.count == 1)
        }
        if let cached { return completion(cached) }
        guard starts else { return }
        lookup(ip) { [self] code in
            let callbacks = lock.withLock { () -> [(String?) -> Void] in
                if let code {
                    var saved = load()
                    saved[key] = code
                    store(saved)
                }
                return waiting.removeValue(forKey: key) ?? []
            }
            callbacks.forEach { $0(code) }
        }
    }

    /// Forgets addresses that left the allowlist.
    func prune(keeping ips: [String]) {
        let keys = Set(ips.compactMap(Self.key(for:)))
        lock.withLock {
            let saved = load()
            let kept = saved.filter { keys.contains($0.key) }
            if kept.count != saved.count { store(kept) }
        }
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
