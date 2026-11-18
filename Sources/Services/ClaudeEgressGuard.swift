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
    /// The egress IP is allowlisted, but Cloudflare places it outside Anthropic's supported regions,
    /// or names no country at all.
    case unsupportedRegion = "unsupported_region"
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

/// What one trace probe saw: the egress IP, the country Cloudflare places it in, and the proxy
/// route the probe went through.
struct EgressTrace: Equatable {
    let ip: String
    /// ISO 3166 code from the trace's `loc`, or nil when Cloudflare names no country (missing,
    /// `XX`, or a pseudo-code such as `T1` for Tor).
    let country: String?
    /// The proxy configuration the probe used. A usage request may only go out on this same
    /// route; nil when the prober does not report one (tests).
    let route: CCSwitchProxyConfiguration?

    init(ip: String, country: String?, route: CCSwitchProxyConfiguration? = nil) {
        self.ip = ip
        self.country = country
        self.route = route
    }
}

/// Parses Cloudflare's `/cdn-cgi/trace` plain-text body (`key=value` lines).
enum CloudflareTraceParser {
    /// Nil unless the body has a valid `ip=` line; `loc` is optional.
    static func trace(from data: Data) -> EgressTrace? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var ip: String?
        var country: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if ip == nil, line.hasPrefix("ip=") {
                let value = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                guard EgressIPAddress.isValid(value) else { return nil }
                ip = value
            } else if country == nil, line.hasPrefix("loc=") {
                country = IPCountryCode.parse(Data(line.dropFirst(4).utf8)).flatMap { $0 == "XX" ? nil : $0 }
            }
        }
        return ip.map { EgressTrace(ip: $0, country: country) }
    }

    static func ip(from data: Data) -> String? { trace(from: data)?.ip }
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

    /// "🇺🇸 United States" in the app language, with the app's naming for CN, HK, MO and TW.
    /// TW ("中国台湾") shows the Chinese flag to match that naming.
    static func displayTitle(_ code: String, locale: Locale = TimeZoneCityCatalog.locale) -> String {
        let name = TimeZoneCityCatalog.countryTitle(for: code, locale: locale)
        let flagCode = code == "TW" ? "CN" : code
        let flag = flagCode.unicodeScalars
            .compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 0x41) }
            .map(String.init).joined()
        return "\(flag) \(name)"
    }
}

/// Anthropic's Supported Regions Policy (anthropic.com/supported-countries), as ISO 3166 codes.
/// A snapshot shipped with the app. The allowlist table shows it per IP (from ipinfo.io), and the
/// guard blocks an egress whose trace `loc` is not in it. Ukraine is listed with regional exceptions that a country lookup cannot see, so it counts as
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

    /// "Territories and dependencies of a listed country are also supported" (the policy's own
    /// example is Puerto Rico). ISO 3166 gives these their own codes, so they are listed here with
    /// the country they belong to.
    static let territories: Set<String> = [
        // United States
        "PR", "GU", "VI", "AS", "MP", "UM",
        // France
        "GF", "GP", "MQ", "RE", "YT", "PM", "BL", "MF", "WF", "PF", "NC", "TF",
        // United Kingdom
        "GI", "IM", "JE", "GG", "BM", "KY", "VG", "AI", "MS", "TC", "FK", "SH", "IO", "PN", "GS",
        // Netherlands
        "AW", "CW", "SX", "BQ",
        // Denmark
        "GL", "FO",
        // Norway
        "SJ", "BV",
        // Australia
        "CX", "CC", "NF", "HM",
        // New Zealand
        "CK", "NU", "TK",
        // Finland
        "AX",
    ]

    static func isSupported(_ countryCode: String) -> Bool {
        let code = countryCode.uppercased()
        return codes.contains(code) || territories.contains(code)
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
    typealias ProbeResult = Result<EgressTrace, OfficialQuotaTransportError>
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
        evaluateTrace { decision, _ in completion(decision) }
    }

    /// Like `evaluate`, and also hands back the trace an `.allowed` decision rests on, so the
    /// caller can re-check it with `decision(for:)` right before sending.
    func evaluateTrace(completion: @escaping (ClaudeEgressGuardDecision, EgressTrace?) -> Void) {
        if let block = Self.settingsBlock(settings()) {
            return finish(.blocked(block), nil, completion)
        }
        currentEgressIP { [self] result in
            // Always judged against the latest settings: they may have changed while the probe ran.
            switch result {
            case let .success(trace):
                finish(decision(for: trace), trace, completion)
            case .failure:
                finish(.blocked(Self.settingsBlock(settings()) ?? .checkFailed), nil, completion)
            }
        }
    }

    /// The decision for `trace` under the current settings. Pure apart from reading settings, so
    /// it can be asked again at the moment a request is about to leave.
    func decision(for trace: EgressTrace) -> ClaudeEgressGuardDecision {
        let current = settings()
        if let block = Self.settingsBlock(current) { return .blocked(block) }
        guard EgressIPAddress.contains(current.allowedIPs, trace.ip) else { return .blocked(.mismatch) }
        // An unknown region is treated like an unsupported one.
        guard let country = trace.country, AnthropicSupportedRegions.isSupported(country) else {
            return .blocked(.unsupportedRegion)
        }
        return .allowed
    }

    /// Blocks that follow from the settings alone, before any probe.
    private static func settingsBlock(_ settings: ClaudeEgressGuardSettings) -> ClaudeEgressGuardBlock? {
        guard settings.enabled else { return .disabled }
        guard !EgressIPAddress.sanitizedList(settings.allowedIPs).isEmpty else { return .noTargets }
        return nil
    }

    /// Probes the current egress IP and region (shared with concurrent callers); used by the settings
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

    private func finish(
        _ decision: ClaudeEgressGuardDecision, _ trace: EgressTrace?,
        _ completion: (ClaudeEgressGuardDecision, EgressTrace?) -> Void
    ) {
        switch decision {
        case .allowed: diagnostics("egress guard; result=passed")
        case let .blocked(block): diagnostics("egress guard; result=\(block.rawValue)")
        }
        completion(decision, decision == .allowed ? trace : nil)
    }
}
