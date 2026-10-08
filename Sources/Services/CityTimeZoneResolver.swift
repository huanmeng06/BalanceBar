import Foundation
import CoreLocation
import MapKit

struct CityTimeZoneMatch: Equatable {
    let title: String
    let identifier: String
}

enum CityTimeZoneLookupError: Error { case unavailable }

/// Forward lookup of an explicitly submitted city name. Never requests the
/// user's location, and never owns Provider requests or display preferences.
protocol CityTimeZoneResolving: AnyObject {
    func resolve(city: String, locale: Locale, completion: @escaping (Result<[CityTimeZoneMatch], CityTimeZoneLookupError>) -> Void)
    func cancel()
}

final class AppleCityTimeZoneResolver: CityTimeZoneResolving {
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let matches = CityTimeZoneGazetteer.lookup(city: city, locale: locale)
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
                    return CityTimeZoneMatch(title: title, identifier: zone.identifier)
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
                return CityTimeZoneMatch(title: parts.joined(separator: " - "), identifier: zone.identifier)
            }
            completion(.success(Self.uniqueSupportedMatches(matches)))
        }
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

/// Exact multilingual city aliases from the bundled GeoNames extract. It is
/// indexed lazily off the UI thread; timezone IDs come from the record itself,
/// never from a guessed offset or the geographically closest representative.
enum CityTimeZoneGazetteer {
    private struct City {
        let country: String
        let identifier: String
    }
    private static let index: [String: [City]] = {
        guard let url = Bundle.main.url(forResource: "CityTimeZoneData", withExtension: "lzfse"),
              let compressed = NSData(contentsOf: url),
              let data = try? compressed.decompressed(using: .lzfse),
              let text = String(data: data as Data, encoding: .utf8) else { return [:] }
        var index: [String: [City]] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 5 else { continue }
            let identifier = String(columns[4])
            guard AppTimeZoneSelection.region(identifier: identifier).isSupported else { continue }
            let city = City(country: String(columns[3]), identifier: identifier)
            let aliases = [String(columns[0]), String(columns[1])] + columns[2].split(separator: ",").map(String.init)
            for name in Set(aliases.map(normalized)) where !name.isEmpty {
                index[name, default: []].append(city)
            }
        }
        return index
    }()

    static func lookup(city query: String, locale: Locale) -> [CityTimeZoneMatch] {
        let matches = (index[normalized(query)] ?? []).map { city in
            let country = locale.localizedString(forRegionCode: city.country) ?? city.country
            return CityTimeZoneMatch(title: "\(query) - \(country) (\(city.identifier))", identifier: city.identifier)
        }
        return AppleCityTimeZoneResolver.uniqueSupportedMatches(matches)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}
