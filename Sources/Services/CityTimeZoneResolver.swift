import Foundation
import Compression
import Darwin
import CoreLocation
import MapKit

struct CityTimeZoneMatch: Equatable {
    let title: String
    let identifier: String
    var isExactNameMatch = false
}

enum CityTimeZoneLookupError: Error { case unavailable }

/// Forward lookup of an explicitly submitted city name. Never requests the
/// user's location, and never owns Provider requests or display preferences.
protocol CityTimeZoneResolving: AnyObject {
    func resolve(city: String, locale: Locale, completion: @escaping (Result<[CityTimeZoneMatch], CityTimeZoneLookupError>) -> Void)
    func cancel()
}

final class AppleCityTimeZoneResolver: CityTimeZoneResolving {
    private static let offlineQueue = DispatchQueue(label: "BalanceBar.city-time-zone", qos: .userInitiated)
    private var cancelRequest: (() -> Void)?
    private var version = 0

    func cancel() {
        version += 1
        cancelRequest?()
        cancelRequest = nil
    }

    func resolve(city: String, locale: Locale, completion: @escaping (Result<[CityTimeZoneMatch], CityTimeZoneLookupError>) -> Void) {
        cancel()
        let version = version
        Self.offlineQueue.async { [weak self] in
            let matches = autoreleasepool { CityTimeZoneGazetteer.lookup(city: city, locale: locale) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.version == version else { return }
                if !matches.isEmpty { completion(.success(matches)) }
                else { self.resolveWithApple(city: city, locale: locale, completion: completion) }
            }
        }
    }

    private func resolveWithApple(city: String, locale: Locale, completion: @escaping (Result<[CityTimeZoneMatch], CityTimeZoneLookupError>) -> Void) {
        if #available(macOS 26.0, *) {
            guard let request = MKGeocodingRequest(addressString: city) else {
                completion(.success([]))
                return
            }
            request.preferredLocale = locale
            cancelRequest = { request.cancel() }
            request.getMapItems { items, error in
                if let error {
                    let nativeError = error as NSError
                    if nativeError.domain == MKErrorDomain, nativeError.code == MKError.placemarkNotFound.rawValue { completion(.success([])) }
                    else { completion(.failure(.unavailable)) }
                    return
                }
                let matches = (items ?? []).compactMap { item -> CityTimeZoneMatch? in
                    guard let cityName = item.addressRepresentations?.cityName, !cityName.isEmpty,
                          let zone = item.timeZone else { return nil }
                    let title = item.addressRepresentations?.cityWithContext(.full) ?? cityName
                    return Self.onlineMatch(query: city, cityName: cityName, contextualTitle: title, identifier: zone.identifier)
                }
                completion(.success(Self.uniqueSupportedMatches(matches)))
            }
        } else {
            resolveLegacy(city: city, locale: locale, completion: completion)
        }
    }

    @available(macOS, introduced: 10.13, obsoleted: 26.0)
    private func resolveLegacy(city: String, locale: Locale, completion: @escaping (Result<[CityTimeZoneMatch], CityTimeZoneLookupError>) -> Void) {
        let geocoder = CLGeocoder()
        cancelRequest = { geocoder.cancelGeocode() }
        geocoder.geocodeAddressString(city, in: nil, preferredLocale: locale) { places, error in
            if let error {
                if (error as NSError).code == CLError.geocodeFoundNoResult.rawValue { completion(.success([])) }
                else { completion(.failure(.unavailable)) }
                return
            }
            let matches = (places ?? []).compactMap { place -> CityTimeZoneMatch? in
                guard let name = place.locality, !name.isEmpty, let zone = place.timeZone else { return nil }
                let parts = [name, place.administrativeArea, place.country].compactMap { $0 }
                return Self.onlineMatch(query: city, cityName: name, contextualTitle: parts.joined(separator: " - "), identifier: zone.identifier)
            }
            completion(.success(Self.uniqueSupportedMatches(matches)))
        }
    }

    static func onlineMatch(query: String, cityName: String, contextualTitle: String, identifier: String) -> CityTimeZoneMatch {
        CityTimeZoneMatch(title: "\(contextualTitle) (\(identifier))", identifier: identifier,
            isExactNameMatch: CityTimeZoneGazetteer.normalized(query) == CityTimeZoneGazetteer.normalized(cityName))
    }

    static func uniqueSupportedMatches(_ matches: [CityTimeZoneMatch]) -> [CityTimeZoneMatch] {
        var seen = Set<String>()
        return matches.filter {
            AppTimeZoneSelection.region(identifier: $0.identifier).isSupported
                && seen.insert($0.identifier + "|" + $0.title).inserted
        }
    }

    deinit { cancel() }
}

/// Exact aliases were normalized when the bundled extract was generated.
/// Scan off the main thread per uncached query; only the small matching result
/// escapes. No decompressed gazetteer or global alias dictionary stays alive.
enum CityTimeZoneGazetteer {
    static func lookup(city query: String, locale: Locale) -> [CityTimeZoneMatch] {
        let queryKey = normalized(query)
        let queryBytes = Array(queryKey.utf8)
        guard !queryBytes.isEmpty,
              let url = Bundle.main.url(forResource: "CityTimeZoneData", withExtension: "lzfse"),
              let compressed = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        // The generated file currently expands to ~6.4 MB. Bound allocation
        // and free it explicitly after scanning; don't retain a decoded copy.
        let capacity = 16 * 1024 * 1024
        let decoded = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { decoded.deallocate() }
        let count = compressed.withUnsafeBytes { raw -> Int in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(decoded, capacity, source, raw.count, nil, COMPRESSION_LZFSE)
        }
        guard count > 0, count < capacity else { return [] }
        let bytes = UnsafeBufferPointer(start: decoded, count: count)
        var matches: [CityTimeZoneMatch] = []
        queryBytes.withUnsafeBufferPointer { needle in
            guard let base = bytes.baseAddress, let queryBase = needle.baseAddress else { return }
            var searchStart = 0
            while searchStart < bytes.count,
                  let found = memmem(base + searchStart, bytes.count - searchStart, queryBase, needle.count) {
                let offset = base.distance(to: UnsafePointer(found.assumingMemoryBound(to: UInt8.self)))
                searchStart = offset + needle.count
                // Exact normalized tokens only. Substrings in another city,
                // country or administration field must not become a match.
                guard offset > 0, searchStart < bytes.count,
                      [9, 0x1F].contains(bytes[offset - 1]),
                      [9, 0x1F].contains(bytes[searchStart]) else { continue }
                var rowStart = offset
                while rowStart > 0 && bytes[rowStart - 1] != 10 { rowStart -= 1 }
                let rowEnd = memchr(base + searchStart, 10, bytes.count - searchStart)
                    .map { base.distance(to: UnsafePointer($0.assumingMemoryBound(to: UInt8.self))) } ?? bytes.count
                let fields = String(decoding: bytes[rowStart..<rowEnd], as: UTF8.self)
                    .split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 7,
                      fields[2].split(separator: "\u{001F}").contains(where: { $0 == queryKey }) else { continue }
                let identifier = String(fields[6])
                guard AppTimeZoneSelection.region(identifier: identifier).isSupported else { continue }
                let countryCode = String(fields[3])
                let country = locale.localizedString(forRegionCode: countryCode) ?? countryCode
                let admin = localizedAdministration(country: countryCode,
                    code: String(fields[4]), name: String(fields[5]), locale: locale)
                let parts = [query, admin, country].filter { !$0.isEmpty }
                matches.append(CityTimeZoneMatch(title: "\(parts.joined(separator: " - ")) (\(identifier))", identifier: identifier, isExactNameMatch: true))
                searchStart = rowEnd
            }
        }
        return AppleCityTimeZoneResolver.uniqueSupportedMatches(matches)
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// Preserve the authoritative native admin1 name where a translation is
    /// unavailable. Chinese state/province names cover the main ambiguous
    /// English-city catalogs; countries use Foundation's selected locale.
    private static func localizedAdministration(country: String, code: String, name: String, locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "zh", let translated = chineseAdministrations[country + "." + code] else { return name }
        if locale.identifier.contains("Hant") || locale.region?.identifier == "TW" || locale.region?.identifier == "HK" {
            return translated.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? translated
        }
        return translated
    }

    private static let chineseAdministrations: [String: String] = [
        "US.AL": "阿拉巴马州", "US.AK": "阿拉斯加州", "US.AZ": "亚利桑那州", "US.AR": "阿肯色州",
        "US.CA": "加利福尼亚州", "US.CO": "科罗拉多州", "US.CT": "康涅狄格州", "US.DE": "特拉华州",
        "US.FL": "佛罗里达州", "US.GA": "佐治亚州", "US.HI": "夏威夷州", "US.ID": "爱达荷州",
        "US.IL": "伊利诺伊州", "US.IN": "印第安纳州", "US.IA": "艾奥瓦州", "US.KS": "堪萨斯州",
        "US.KY": "肯塔基州", "US.LA": "路易斯安那州", "US.ME": "缅因州", "US.MD": "马里兰州",
        "US.MA": "马萨诸塞州", "US.MI": "密歇根州", "US.MN": "明尼苏达州", "US.MS": "密西西比州",
        "US.MO": "密苏里州", "US.MT": "蒙大拿州", "US.NE": "内布拉斯加州", "US.NV": "内华达州",
        "US.NH": "新罕布什尔州", "US.NJ": "新泽西州", "US.NM": "新墨西哥州", "US.NY": "纽约州",
        "US.NC": "北卡罗来纳州", "US.ND": "北达科他州", "US.OH": "俄亥俄州", "US.OK": "俄克拉荷马州",
        "US.OR": "俄勒冈州", "US.PA": "宾夕法尼亚州", "US.RI": "罗得岛州", "US.SC": "南卡罗来纳州",
        "US.SD": "南达科他州", "US.TN": "田纳西州", "US.TX": "得克萨斯州", "US.UT": "犹他州",
        "US.VT": "佛蒙特州", "US.VA": "弗吉尼亚州", "US.WA": "华盛顿州", "US.WV": "西弗吉尼亚州",
        "US.WI": "威斯康星州", "US.WY": "怀俄明州", "US.DC": "哥伦比亚特区",
        "CA.01": "艾伯塔省", "CA.02": "不列颠哥伦比亚省", "CA.03": "曼尼托巴省", "CA.04": "新不伦瑞克省",
        "CA.05": "纽芬兰与拉布拉多省", "CA.07": "新斯科舍省", "CA.08": "安大略省", "CA.09": "爱德华王子岛省",
        "CA.10": "魁北克省", "CA.11": "萨斯喀彻温省", "CA.12": "育空地区", "CA.13": "西北地区", "CA.14": "努纳武特地区",
        "AU.01": "澳大利亚首都领地", "AU.02": "新南威尔士州", "AU.03": "北领地", "AU.04": "昆士兰州",
        "AU.05": "南澳大利亚州", "AU.06": "塔斯马尼亚州", "AU.07": "维多利亚州", "AU.08": "西澳大利亚州"
    ]
}
