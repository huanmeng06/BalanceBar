import CryptoKit
import Darwin
import Foundation

enum ClaudeStatusLineInstallerError: Error, Equatable {
    case settingsMissing
    case invalidSettings
    case concurrentModification
    case notOwned
    case writeFailed
    case managedSettingsOverride
}

struct ClaudeStatusLineInstallResult: Equatable {
    let command: String
    let changed: Bool
}

/// Installs and restores the BalanceBar statusLine wrapper with compare-and-swap semantics.
final class ClaudeStatusLineInstaller {
    static let ownershipMarker = "--balancebar-statusline-v1"

    private let settingsURL: URL
    private let wrapperURL: URL
    private let backupURL: URL
    private let fileManager: FileManager

    init(
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
        wrapperURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BalanceBar/bin/balancebar-statusline"),
        backupURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BalanceBar/statusline-backup.json"),
        fileManager: FileManager = .default
    ) {
        self.settingsURL = settingsURL
        self.wrapperURL = wrapperURL
        self.backupURL = backupURL
        self.fileManager = fileManager
    }

    func install() throws -> ClaudeStatusLineInstallResult {
        try validateManagedSettings()
        guard let original = try? Data(contentsOf: settingsURL) else { throw ClaudeStatusLineInstallerError.settingsMissing }
        guard let object = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw ClaudeStatusLineInstallerError.invalidSettings
        }
        let existing = object["statusLine"]
        let originalStatusLineJSON = try Self.statusLineJSON(in: original)
        let originalCommand = (existing as? [String: Any])?["command"] as? String
        let alreadyOwned = originalCommand?.contains(Self.ownershipMarker) == true
        let preservedCommand: String
        if alreadyOwned, let saved = try? Data(contentsOf: backupURL),
           let savedObject = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
           let encoded = savedObject["statusLineJSON"] as? String,
           let savedJSON = Data(base64Encoded: encoded),
           let savedStatusLine = try? JSONSerialization.jsonObject(with: savedJSON) as? [String: Any],
           let savedCommand = savedStatusLine["command"] as? String {
            preservedCommand = savedCommand
        } else {
            preservedCommand = originalCommand ?? ""
        }
        let backup: [String: Any] = [
            "hadStatusLine": existing != nil,
            "statusLineJSON": originalStatusLineJSON?.base64EncodedString() ?? "",
            "settingsSHA256": Self.sha256(original)
        ]
        let backupData = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])
        let encoded = Data(preservedCommand.utf8).base64EncodedString()
        let command = "\(wrapperURL.path) \(Self.ownershipMarker) --orig-b64 \(encoded)"
        let updated = try replaceCommand(in: original, command: command)
        guard Self.sha256(try Data(contentsOf: settingsURL)) == Self.sha256(original) else {
            throw ClaudeStatusLineInstallerError.concurrentModification
        }
        try atomicWrite(updated, preserving: original)
        if !alreadyOwned { try atomicWriteBackup(backupData) }
        return ClaudeStatusLineInstallResult(command: command, changed: updated != original)
    }

    private func validateManagedSettings() throws {
        let managedURL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")
        guard let data = try? Data(contentsOf: managedURL) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatusLineInstallerError.managedSettingsOverride
        }
        if object["statusLine"] != nil || (object["disableAllHooks"] as? Bool) == true
            || (object["allowManagedHooksOnly"] as? Bool) == true {
            throw ClaudeStatusLineInstallerError.managedSettingsOverride
        }
    }

    func installBundledWrapper(bundle: Bundle = .main) throws {
        guard let bundled = bundle.url(forResource: "balancebar-statusline", withExtension: nil,
                                      subdirectory: "Helpers") else {
            throw ClaudeStatusLineInstallerError.writeFailed
        }
        try fileManager.createDirectory(at: wrapperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = wrapperURL.deletingLastPathComponent()
            .appendingPathComponent(".balancebar-statusline.\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: bundled, to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        guard rename(temporary.path, wrapperURL.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw ClaudeStatusLineInstallerError.writeFailed
        }
    }

    func canReconcileWithoutTakingOwnership() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let command = (object["statusLine"] as? [String: Any])?["command"] as? String else { return true }
        return command.contains(Self.ownershipMarker)
    }

    func uninstall() throws -> Bool {
        guard let current = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: current) as? [String: Any],
              let currentCommand = (root["statusLine"] as? [String: Any])?["command"] as? String,
              currentCommand.contains(Self.ownershipMarker) else {
            throw ClaudeStatusLineInstallerError.notOwned
        }
        guard let backupData = try? Data(contentsOf: backupURL),
              let backup = try? JSONSerialization.jsonObject(with: backupData) as? [String: Any] else {
            throw ClaudeStatusLineInstallerError.notOwned
        }
        let hadStatusLine = backup["hadStatusLine"] as? Bool ?? true
        let originalStatusLine = (backup["statusLineJSON"] as? String).flatMap { Data(base64Encoded: $0) }
        let updated = try Self.restoreStatusLine(
            in: current, hadStatusLine: hadStatusLine, originalJSON: originalStatusLine)
        guard Self.sha256(try Data(contentsOf: settingsURL)) == Self.sha256(current) else {
            throw ClaudeStatusLineInstallerError.concurrentModification
        }
        try atomicWrite(updated, preserving: current)
        try? fileManager.removeItem(at: backupURL)
        return true
    }

    private func replaceCommand(in data: Data, command: String) throws -> Data {
        let scanner = try JSONSpanScanner(data)
        let root = try scanner.objectFields()
        let encodedData = try Self.jsonString(command)
        let encoded = String(data: encodedData, encoding: .utf8)!
        guard let status = root.first(where: { $0.key == "statusLine" }) else {
            return Self.insertField(
                in: data, objectRange: scanner.rootRange, field: "\"statusLine\":{\"type\":\"command\",\"command\":\(encoded)}")
        }
        guard scanner.isObject(status.valueRange) else { throw ClaudeStatusLineInstallerError.invalidSettings }
        let statusFields = try scanner.objectFields(in: status.valueRange)
        if let commandField = statusFields.first(where: { $0.key == "command" }) {
            return Self.replace(data, range: commandField.valueRange, with: encodedData)
        }
        let typeField = statusFields.first(where: { $0.key == "type" })
        let insertion = statusFields.isEmpty
            ? "\"command\":\(encoded)"
            : ",\"command\":\(encoded)"
        _ = typeField
        return Self.insertField(in: data, objectRange: status.valueRange, field: insertion)
    }

    private func atomicWrite(_ data: Data, preserving original: Data) throws {
        let directory = settingsURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".balancebar-settings.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: (try fileManager.attributesOfItem(atPath: settingsURL.path))[.posixPermissions] ?? 0o600],
                ofItemAtPath: temporary.path)
            let fd = open(temporary.path, O_RDONLY)
            if fd >= 0 { _ = fsync(fd); close(fd) }
            guard rename(temporary.path, settingsURL.path) == 0 else { throw ClaudeStatusLineInstallerError.writeFailed }
        } catch let error as ClaudeStatusLineInstallerError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw ClaudeStatusLineInstallerError.writeFailed
        }
    }

    private func atomicWriteBackup(_ data: Data) throws {
        try fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: backupURL, options: .atomic)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    private static func jsonString(_ value: String) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [])
        return data.subdata(in: 1..<(data.count - 1))
    }

    private static func replace(_ data: Data, range: Range<Int>, with replacement: Data) -> Data {
        var result = Data(data.prefix(range.lowerBound))
        result.append(replacement)
        result.append(data.suffix(data.count - range.upperBound))
        return result
    }

    private static func insertField(in data: Data, objectRange: Range<Int>, field: String) -> Data {
        let closing = objectRange.upperBound - 1
        let bytes = [UInt8](data)
        var index = closing - 1
        while index >= objectRange.lowerBound + 1, Self.isWhitespace(bytes[index]) { index -= 1 }
        let separator = index == objectRange.lowerBound ? "" : ","
        let insertion = Data((separator + field).utf8)
        var result = Data(data.prefix(closing))
        result.append(insertion)
        result.append(data.suffix(data.count - closing))
        return result
    }

    private static func statusLineJSON(in data: Data) throws -> Data? {
        let scanner = try JSONSpanScanner(data)
        guard let field = try scanner.objectFields().first(where: { $0.key == "statusLine" }) else { return nil }
        return data.subdata(in: field.valueRange)
    }

    private static func restoreStatusLine(in data: Data, hadStatusLine: Bool, originalJSON: Data?) throws -> Data {
        let scanner = try JSONSpanScanner(data)
        let fields = try scanner.objectFields()
        guard let field = fields.first(where: { $0.key == "statusLine" }) else {
            if hadStatusLine { throw ClaudeStatusLineInstallerError.invalidSettings }
            return data
        }
        if hadStatusLine {
            guard let originalJSON else { throw ClaudeStatusLineInstallerError.notOwned }
            return replace(data, range: field.valueRange, with: originalJSON)
        }
        var start = field.keyRange.lowerBound
        var end = field.valueRange.upperBound
        let bytes = [UInt8](data)
        var before = start - 1
        while before >= scanner.rootRange.lowerBound, Self.isWhitespace(bytes[before]) { before -= 1 }
        if before >= scanner.rootRange.lowerBound, bytes[before] == 44 { start = before }
        else {
            var after = end
            while after < scanner.rootRange.upperBound, Self.isWhitespace(bytes[after]) { after += 1 }
            if after < scanner.rootRange.upperBound, bytes[after] == 44 { end = after + 1 }
        }
        return replace(data, range: start..<end, with: Data())
    }
}

private struct JSONSpanScanner {
    struct Field { let key: String; let keyRange: Range<Int>; let valueRange: Range<Int> }
    let bytes: [UInt8]
    private(set) var rootRange: Range<Int>

    init(_ data: Data) throws {
        bytes = Array(data)
        rootRange = 0..<0
        var index = 0
        skipWhitespace(&index)
        guard index < bytes.count, bytes[index] == 123 else { throw ClaudeStatusLineInstallerError.invalidSettings }
        let start = index
        let root = try skipValue(&index)
        skipWhitespace(&index)
        guard index == bytes.count else { throw ClaudeStatusLineInstallerError.invalidSettings }
        rootRange = start..<root.upperBound
    }

    func isObject(_ range: Range<Int>) -> Bool { bytes[range.lowerBound] == 123 }

    func objectFields(in range: Range<Int>? = nil) throws -> [Field] {
        let range = range ?? rootRange
        var index = range.lowerBound
        guard bytes[index] == 123 else { throw ClaudeStatusLineInstallerError.invalidSettings }
        index += 1
        var fields: [Field] = []
        while true {
            skipWhitespace(&index)
            if bytes[index] == 125 { return fields }
            let keyRange = try parseString(&index)
            let key = try decodeString(keyRange)
            skipWhitespace(&index)
            guard bytes[index] == 58 else { throw ClaudeStatusLineInstallerError.invalidSettings }
            index += 1
            skipWhitespace(&index)
            let valueStart = index
            _ = try skipValue(&index)
            fields.append(Field(key: key, keyRange: keyRange, valueRange: valueStart..<index))
            skipWhitespace(&index)
            if bytes[index] == 44 { index += 1; continue }
            guard bytes[index] == 125 else { throw ClaudeStatusLineInstallerError.invalidSettings }
            return fields
        }
    }

    private func decodeString(_ range: Range<Int>) throws -> String {
        let data = Data(bytes[range])
        guard let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { throw ClaudeStatusLineInstallerError.invalidSettings }
        return value
    }

    private func parseString(_ index: inout Int) throws -> Range<Int> {
        let start = index
        guard bytes[index] == 34 else { throw ClaudeStatusLineInstallerError.invalidSettings }
        index += 1
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 34 { index += 1; return start..<index }
            index += 1
        }
        throw ClaudeStatusLineInstallerError.invalidSettings
    }

    private func skipValue(_ index: inout Int) throws -> Range<Int> {
        let start = index
        switch bytes[index] {
        case 34: _ = try parseString(&index)
        case 123, 91:
            let opening = bytes[index]
            let closing: UInt8 = opening == 123 ? 125 : 93
            index += 1
            while true {
                skipWhitespace(&index)
                if bytes[index] == closing { index += 1; break }
                if opening == 123 {
                    _ = try parseString(&index)
                    skipWhitespace(&index)
                    guard bytes[index] == 58 else { throw ClaudeStatusLineInstallerError.invalidSettings }
                    index += 1
                    skipWhitespace(&index)
                }
                _ = try skipValue(&index)
                skipWhitespace(&index)
                if bytes[index] == 44 { index += 1; continue }
                guard bytes[index] == closing else { throw ClaudeStatusLineInstallerError.invalidSettings }
                index += 1
                break
            }
        default:
            while index < bytes.count, ![44, 125, 93, 32, 9, 10, 13].contains(bytes[index]) { index += 1 }
            guard index > start else { throw ClaudeStatusLineInstallerError.invalidSettings }
        }
        return start..<index
    }

    private func skipWhitespace(_ index: inout Int) {
        while index < bytes.count,
              bytes[index] == 32 || bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 13 {
            index += 1
        }
    }
}
