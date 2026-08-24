import Foundation

/// A SemVer value used for release comparison. Build metadata is retained for
/// display but intentionally ignored when ordering versions.
struct AppSemanticVersion: Comparable, Equatable, Hashable, CustomStringConvertible {
    enum PrereleaseIdentifier: Equatable, Hashable {
        case numeric(Int)
        case text(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [PrereleaseIdentifier]
    let buildMetadata: [String]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        guard !value.isEmpty else { return nil }

        let buildParts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        let coreAndPrerelease = String(buildParts[0])
        let buildMetadata = buildParts.count == 2
            ? Self.parseBuildMetadata(String(buildParts[1]))
            : []
        guard buildParts.count == 1 || buildMetadata != nil else { return nil }

        let prereleaseParts = coreAndPrerelease.split(separator: "-", omittingEmptySubsequences: false)
        guard prereleaseParts.count <= 2 else { return nil }
        let core = prereleaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.parseNumericCore(String(core[0])),
              let minor = Self.parseNumericCore(String(core[1])),
              let patch = Self.parseNumericCore(String(core[2]))
        else { return nil }

        let prerelease: [PrereleaseIdentifier]
        if prereleaseParts.count == 1 {
            prerelease = []
        } else {
            guard let parsed = Self.parsePrerelease(String(prereleaseParts[1])) else { return nil }
            prerelease = parsed
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildMetadata = buildMetadata ?? []
    }

    var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            value += "-" + prerelease.map { identifier in
                switch identifier {
                case .numeric(let number): return String(number)
                case .text(let text): return text
                }
            }.joined(separator: ".")
        }
        if !buildMetadata.isEmpty {
            value += "+" + buildMetadata.joined(separator: ".")
        }
        return value
    }

    /// The release asset convention uses the normalized version without the
    /// optional `v` prefix. Stable releases normally have no prerelease or
    /// build metadata, but retaining all SemVer components keeps this helper
    /// deterministic for injected test releases.
    var normalizedAssetVersion: String { description }

    static func < (lhs: AppSemanticVersion, rhs: AppSemanticVersion) -> Bool {
        let coreComparison: ComparisonResult
        if lhs.major != rhs.major {
            coreComparison = lhs.major < rhs.major ? .orderedAscending : .orderedDescending
        } else if lhs.minor != rhs.minor {
            coreComparison = lhs.minor < rhs.minor ? .orderedAscending : .orderedDescending
        } else if lhs.patch != rhs.patch {
            coreComparison = lhs.patch < rhs.patch ? .orderedAscending : .orderedDescending
        } else {
            coreComparison = .orderedSame
        }
        if coreComparison != .orderedSame { return coreComparison == .orderedAscending }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            switch (left, right) {
            case (.numeric(let left), .numeric(let right)):
                if left != right { return left < right }
            case (.numeric, .text):
                return true
            case (.text, .numeric):
                return false
            case (.text(let left), .text(let right)):
                if left != right { return left < right }
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func parseNumericCore(_ value: String) -> Int? {
        guard !value.isEmpty,
              (value == "0" || !value.hasPrefix("0")),
              value.allSatisfy(\.isNumber)
        else { return nil }
        return Int(value)
    }

    private static func parsePrerelease(_ value: String) -> [PrereleaseIdentifier]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var parsed: [PrereleaseIdentifier] = []
        for part in parts {
            let identifier = String(part)
            guard !identifier.isEmpty,
                  identifier.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" })
            else { return nil }
            if identifier.allSatisfy(\.isNumber) {
                guard identifier == "0" || !identifier.hasPrefix("0"),
                      let number = Int(identifier)
                else { return nil }
                parsed.append(.numeric(number))
            } else {
                parsed.append(.text(identifier))
            }
        }
        return parsed
    }

    private static func parseBuildMetadata(_ value: String) -> [String]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0.isLetter || $0 == "-" } })
        else { return nil }
        return parts
    }
}

struct GitHubReleaseAsset: Decodable, Equatable {
    let name: String
    let browserDownloadURL: URL?
    let size: Int?
    let digest: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case digest
    }
}

enum UpdateChannel: String, CaseIterable, Equatable {
    case stable
    case beta

    /// Stable is the default channel. Beta is deliberately opt-in and may
    /// include both GitHub prereleases and ordinary releases.
    func accepts(_ release: GitHubRelease) -> Bool {
        guard !release.draft else { return false }
        return self == .beta || !release.prerelease
    }
}

struct GitHubRelease: Decodable, Equatable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]
    let body: String?
    let htmlURL: URL?

    init(
        tagName: String,
        draft: Bool,
        prerelease: Bool,
        assets: [GitHubReleaseAsset],
        body: String? = nil,
        htmlURL: URL? = nil
    ) {
        self.tagName = tagName
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
        self.body = body
        self.htmlURL = htmlURL
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
        case body
        case htmlURL = "html_url"
    }

    var version: AppSemanticVersion? {
        AppSemanticVersion(tagName)
    }

    var stableVersion: AppSemanticVersion? {
        guard UpdateChannel.stable.accepts(self) else { return nil }
        return version
    }

    func candidate(for channel: UpdateChannel) -> UpdateReleaseCandidate? {
        guard channel.accepts(self),
              let version,
              matchingAsset(for: version) != nil
        else { return nil }
        return UpdateReleaseCandidate(release: self, version: version)
    }

    func matchingAsset(for version: AppSemanticVersion) -> GitHubReleaseAsset? {
        let expectedName = "BalanceBar-\(version.normalizedAssetVersion).dmg"
        return assets.first {
            $0.name == expectedName && $0.browserDownloadURL != nil
        }
    }

    var releaseURL: URL? {
        if let htmlURL,
           let scheme = htmlURL.scheme?.lowercased(),
           (scheme == "https" || scheme == "http"),
           htmlURL.host != nil {
            return htmlURL
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/huanmeng06/BalanceBar/releases/tag/\(tagName)"
        return components.url
    }
}

struct UpdateReleaseCandidate: Equatable {
    let release: GitHubRelease
    let version: AppSemanticVersion
}

enum UpdateFailure: Equatable {
    case network
    case httpStatus(Int)
    case invalidResponse
    case invalidReleaseVersion
    case assetUnavailable
    case downloadFailed
    case verificationFailed
    case installationFailed
    case invalidCurrentVersion
}

enum UpdateCheckState: Equatable {
    case idle(current: AppSemanticVersion)
    case checking(current: AppSemanticVersion)
    case latest(current: AppSemanticVersion)
    case available(current: AppSemanticVersion, latest: AppSemanticVersion)
    case downloading(current: AppSemanticVersion, latest: AppSemanticVersion, progress: Int)
    case installing(current: AppSemanticVersion, latest: AppSemanticVersion, progress: Int)
    case restarting(current: AppSemanticVersion, latest: AppSemanticVersion)
    case failed(UpdateFailure)
}
