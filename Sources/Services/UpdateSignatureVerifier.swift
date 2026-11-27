import Foundation
import CryptoKit

enum UpdateApplicationPreflight {
    static func validate(appURL: URL) -> Bool {
        let root = appURL.standardizedFileURL.path
        guard (try? appURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true,
              (try? appURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              !containsExternalSymlink(in: appURL, root: root),
              removeQuarantineAndVerifySignature(at: appURL),
              let info = Bundle(url: appURL)?.infoDictionary,
              let executableName = info["CFBundleExecutable"] as? String,
              URL(fileURLWithPath: executableName).lastPathComponent == executableName,
              let minimumSystem = info["LSMinimumSystemVersion"] as? String,
              isSupportedOnCurrentSystem(minimumSystem),
              let architecture = run("/usr/bin/uname", ["-m"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !architecture.isEmpty else { return false }
        let executable = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard let architectures = run("/usr/bin/lipo", ["-archs", executable.path]) else { return false }
        return architectures.split(whereSeparator: \.isWhitespace).contains(Substring(architecture))
    }

    private static func removeQuarantineAndVerifySignature(at appURL: URL) -> Bool {
        guard let attributes = run("/usr/bin/xattr", ["-lr", appURL.path]) else { return false }
        if attributes.contains("com.apple.quarantine") {
            guard run("/usr/bin/xattr", ["-r", "-d", "com.apple.quarantine", appURL.path]) != nil,
                  let remaining = run("/usr/bin/xattr", ["-lr", appURL.path]),
                  !remaining.contains("com.apple.quarantine") else { return false }
        }
        return run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path]) != nil
    }

    private static func containsExternalSymlink(in appURL: URL, root: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return true }
        for case let item as URL in enumerator {
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) else { continue }
            let target = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : item.deletingLastPathComponent().appendingPathComponent(destination)
            let resolvedPath = target.standardizedFileURL.path
            guard resolvedPath == root || resolvedPath.hasPrefix(root + "/") else { return true }
        }
        return false
    }

    private static func isSupportedOnCurrentSystem(_ minimumSystem: String) -> Bool {
        let components = minimumSystem.split(separator: ".").compactMap { Int($0) }
        guard !components.isEmpty else { return false }
        let current = ProcessInfo.processInfo.operatingSystemVersion
        let currentComponents = [current.majorVersion, current.minorVersion, current.patchVersion]
        for index in 0..<max(components.count, currentComponents.count) {
            let minimum = index < components.count ? components[index] : 0
            let installed = index < currentComponents.count ? currentComponents[index] : 0
            if minimum != installed { return minimum < installed }
        }
        return true
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

struct SignedUpdateManifest: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let size: Int64
        let sha256: String
    }

    struct Source: Decodable, Equatable {
        let repository: String
        let commit: String
        let runId: String
        let runAttempt: String
    }

    let schema: Int
    let bundleIdentifier: String
    let version: String
    let channel: String
    let tag: String
    let asset: Asset
    let source: Source
    let signedAt: String
}

enum UpdateSignatureError: Error, Equatable {
    case missingTrustedKeys
    case invalidSignatureFile
    case unknownKey
    case invalidSignature
    case invalidManifest
    case unsupportedSchema
}

struct UpdateSignatureVerifier {
    private struct SignatureFile: Decodable {
        let schema: Int
        let algorithm: String
        let keyId: String
        let signature: String
    }

    private let publicKeys: [String: Curve25519.Signing.PublicKey]
    private let developmentBundleIdentifier: String?

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        var keys: [String: Curve25519.Signing.PublicKey] = [:]
        if let entries = bundle.object(forInfoDictionaryKey: "BalanceBarUpdateSigningKeys") as? [[String: String]] {
            for entry in entries {
                guard let keyId = entry["keyId"], let encoded = entry["publicKey"],
                      let bytes = Data(base64Encoded: encoded),
                      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else { continue }
                keys[keyId] = key
            }
        }
        let bundleIdentifier = bundle.bundleIdentifier ?? ""
        let isDevelopmentBundle = Self.isDevelopmentBundleIdentifier(bundleIdentifier)
        if isDevelopmentBundle,
           let encoded = environment["BALANCEBAR_UPDATE_TEST_PUBLIC_KEY"],
           let bytes = Data(base64Encoded: encoded),
           let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) {
            keys["dev-test"] = key
        }
        self.publicKeys = keys
        self.developmentBundleIdentifier = isDevelopmentBundle && keys["dev-test"] != nil ? bundleIdentifier : nil
    }

    static func isDevelopmentBundleIdentifier(_ identifier: String) -> Bool {
        let developmentIdentifier = "com.huanmeng06.BalanceBar.dev"
        return identifier == developmentIdentifier || identifier.hasPrefix(developmentIdentifier + ".")
    }

    init(publicKeys: [String: Data]) {
        self.publicKeys = publicKeys.compactMapValues { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        self.developmentBundleIdentifier = nil
    }

    var hasTrustedKeys: Bool { !publicKeys.isEmpty }

    func verify(manifestData: Data, signatureData: Data) throws -> SignedUpdateManifest {
        guard !publicKeys.isEmpty else { throw UpdateSignatureError.missingTrustedKeys }
        guard manifestData.count <= 16 * 1024,
              signatureData.count <= 4 * 1024,
              let signatureFile = try? JSONDecoder().decode(SignatureFile.self, from: signatureData),
              signatureFile.algorithm == "ed25519" else {
            throw UpdateSignatureError.invalidSignatureFile
        }
        guard signatureFile.schema == 1 else { throw UpdateSignatureError.unsupportedSchema }
        guard let key = publicKeys[signatureFile.keyId] else { throw UpdateSignatureError.unknownKey }
        guard let signature = Data(base64Encoded: signatureFile.signature), signature.count == 64 else {
            throw UpdateSignatureError.invalidSignature
        }
        guard key.isValidSignature(signature, for: manifestData) else {
            throw UpdateSignatureError.invalidSignature
        }
        guard let manifest = try? JSONDecoder().decode(SignedUpdateManifest.self, from: manifestData),
              manifest.schema == 1,
              (manifest.bundleIdentifier == "com.huanmeng06.BalanceBar.app"
                || (signatureFile.keyId == "dev-test" && manifest.bundleIdentifier == developmentBundleIdentifier)),
              manifest.source.repository == "huanmeng06/BalanceBar",
              manifest.version == AppSemanticVersion(manifest.version)?.description,
              manifest.tag == "v\(manifest.version)",
              UpdateChannel(rawValue: manifest.channel) != nil,
              manifest.signedAt.hasSuffix("Z"),
              ISO8601DateFormatter().date(from: manifest.signedAt) != nil,
              manifest.asset.name == "BalanceBar-\(manifest.version).dmg",
              manifest.asset.size > 0,
              manifest.asset.sha256.count == 64,
              manifest.asset.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              manifest.source.commit.count == 40,
              manifest.source.commit.allSatisfy(\.isHexDigit),
              !manifest.source.runId.isEmpty,
              manifest.source.runId.allSatisfy(\.isNumber),
              !manifest.source.runAttempt.isEmpty,
              manifest.source.runAttempt.allSatisfy(\.isNumber) else {
            throw UpdateSignatureError.invalidManifest
        }
        return manifest
    }
}
