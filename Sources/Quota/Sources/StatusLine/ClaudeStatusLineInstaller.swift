import CryptoKit
import Darwin
import Foundation

enum ClaudeStatusLineInstallerError: Error, Equatable {
    case invalidSettings
    case concurrentModification
    case notOwned
    case writeFailed
    case managedSettingsOverride
    /// The settings already run the wrapper but the backup of the original is gone; repairing
    /// automatically could wrap the wrapper, so the user has to decide.
    case backupMissing
    /// The wrapper path cannot be quoted safely for every shell Claude Code may use.
    case unsupportedWrapperPath
    case helperMissing
    /// The write landed but reading it back did not show the expected configuration.
    case verificationFailed
}

struct ClaudeStatusLineInstallResult: Equatable {
    let command: String
    let changed: Bool
}

/// Installs and restores the BalanceBar statusLine wrapper with compare-and-swap semantics.
///
/// Only `statusLine.command` is ever replaced (or a minimal `statusLine` object added), so every
/// other byte of the user's settings stays as it was. The backup is written and verified before
/// the settings change, and any failure after that rolls back.
final class ClaudeStatusLineInstaller {
    static let ownershipMarker = "--balancebar-statusline-v1"

    private let settingsURL: URL
    private let wrapperURL: URL
    private let backupURL: URL
    private let managedSettingsURL: URL
    private let fileManager: FileManager
    /// Test hook: runs right before the settings file is replaced.
    var beforeSettingsWrite: (() throws -> Void)?

    init(
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
        wrapperURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BalanceBar/bin/balancebar-statusline"),
        backupURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BalanceBar/statusline-backup.json"),
        managedSettingsURL: URL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"),
        fileManager: FileManager = .default
    ) {
        self.settingsURL = settingsURL
        self.wrapperURL = wrapperURL
        self.backupURL = backupURL
        self.managedSettingsURL = managedSettingsURL
        self.fileManager = fileManager
    }

    /// The command written to `statusLine.command`. The wrapper path is single-quoted so a
    /// path such as `~/Library/Application Support/...` survives `sh -c`, zsh, bash and fish.
    static func wrapperCommand(wrapperPath: String, originalCommand: String) throws -> String {
        guard !wrapperPath.contains("\'"), !wrapperPath.contains("\0"),
              !wrapperPath.contains("\n"), !wrapperPath.contains("\r") else {
            throw ClaudeStatusLineInstallerError.unsupportedWrapperPath
        }
        // An empty original is written as an explicit empty argument so the next option is
        // never mistaken for it.
        let encoded = originalCommand.isEmpty ? "''" : Data(originalCommand.utf8).base64EncodedString()
        return "'\(wrapperPath)' \(ownershipMarker) --orig-b64 \(encoded)"
    }

    /// The original command embedded in a wrapper command, if `command` is ours.
    static func embeddedOriginalCommand(in command: String) -> String? {
        guard command.contains(ownershipMarker) else { return nil }
        let parts = command.split(separator: " ")
        guard let index = parts.firstIndex(of: "--orig-b64"), parts.indices.contains(index + 1) else { return nil }
        if parts[index + 1] == "''" { return "" }
        guard let data = Data(base64Encoded: String(parts[index + 1])) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func install() throws -> ClaudeStatusLineInstallResult {
        try validateManagedSettings()
        let existingFile = try? Data(contentsOf: settingsURL)
        let original = existingFile ?? Data("{}\n".utf8)
        guard let object = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw ClaudeStatusLineInstallerError.invalidSettings
        }
        if let statusLine = object["statusLine"], !(statusLine is [String: Any]) {
            throw ClaudeStatusLineInstallerError.invalidSettings
        }
        let existing = object["statusLine"] as? [String: Any]
        let currentCommand = existing?["command"] as? String
        let alreadyOwned = currentCommand?.contains(Self.ownershipMarker) == true

        let preservedCommand: String
        var backupData: Data?
        if alreadyOwned {
            // Re-installing over our own wrapper (e.g. after the helper moved) keeps the saved
            // original; without the backup we stop instead of wrapping the wrapper.
            guard let backup = readBackup(), let saved = backup.originalCommand else {
                throw ClaudeStatusLineInstallerError.backupMissing
            }
            preservedCommand = saved
        } else {
            preservedCommand = currentCommand ?? ""
            let backup: [String: Any] = [
                "version": 1,
                "settingsExisted": existingFile != nil,
                "hadStatusLine": existing != nil,
                "statusLineJSON": try Self.statusLineJSON(in: original)?.base64EncodedString() ?? "",
                "originalCommand": preservedCommand,
                "settingsSHA256": Self.sha256(original)
            ]
            backupData = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])
        }

        let command = try Self.wrapperCommand(wrapperPath: wrapperURL.path, originalCommand: preservedCommand)
        if currentCommand == command { return ClaudeStatusLineInstallResult(command: command, changed: false) }
        let updated = try replaceCommand(in: original, command: command)

        // 1. The backup exists and reads back before the settings change.
        if let backupData {
            try writeBackup(backupData)
            guard (try? Data(contentsOf: backupURL)) == backupData else {
                try? fileManager.removeItem(at: backupURL)
                throw ClaudeStatusLineInstallerError.writeFailed
            }
        }
        do {
            // 2. Compare-and-swap against what was read.
            try beforeSettingsWrite?()
            guard (try? Data(contentsOf: settingsURL)) == existingFile else {
                throw ClaudeStatusLineInstallerError.concurrentModification
            }
            try atomicWrite(updated, createIfMissing: existingFile == nil)
            // 3. Read back: only the command differs from the original.
            guard let written = try? Data(contentsOf: settingsURL), written == updated,
                  Self.differsOnlyInStatusLineCommand(original: original, updated: written, command: command) else {
                rollBack(to: existingFile, ifCurrentIs: updated)
                throw ClaudeStatusLineInstallerError.verificationFailed
            }
        } catch {
            if backupData != nil { try? fileManager.removeItem(at: backupURL) }
            throw error
        }
        return ClaudeStatusLineInstallResult(command: command, changed: true)
    }

    /// Restores the original statusLine when the settings still run our wrapper.
    func uninstall() throws -> Bool {
        guard let current = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: current) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              let currentCommand = statusLine["command"] as? String,
              currentCommand.contains(Self.ownershipMarker) else {
            throw ClaudeStatusLineInstallerError.notOwned
        }
        let updated: Data
        if let backup = readBackup() {
            updated = try Self.restoreStatusLine(
                in: current, hadStatusLine: backup.hadStatusLine, originalJSON: backup.statusLineJSON)
        } else if let original = Self.embeddedOriginalCommand(in: currentCommand) {
            // Without a backup, the command itself still carries the original; only `command`
            // was ever changed, so restoring it is exact. An empty original means BalanceBar
            // added the object, which is removed only if it still has just our two keys.
            if original.isEmpty {
                guard Set(statusLine.keys) == ["type", "command"] else { throw ClaudeStatusLineInstallerError.backupMissing }
                updated = try Self.restoreStatusLine(in: current, hadStatusLine: false, originalJSON: nil)
            } else {
                updated = try replaceCommand(in: current, command: original)
            }
        } else {
            throw ClaudeStatusLineInstallerError.backupMissing
        }
        guard (try? Data(contentsOf: settingsURL)) == current else {
            throw ClaudeStatusLineInstallerError.concurrentModification
        }
        try atomicWrite(updated, createIfMissing: false)
        try? fileManager.removeItem(at: backupURL)
        return true
    }

    /// Whether the settings still run this wrapper; never changes anything.
    func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = (object["statusLine"] as? [String: Any])?["command"] as? String else { return false }
        return command.contains(Self.ownershipMarker)
    }

    private struct Backup {
        let hadStatusLine: Bool
        let statusLineJSON: Data?
        let originalCommand: String?
    }

    private func readBackup() -> Backup? {
        guard let data = try? Data(contentsOf: backupURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hadStatusLine = object["hadStatusLine"] as? Bool else { return nil }
        let json = (object["statusLineJSON"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        if hadStatusLine, json == nil { return nil }
        var command = object["originalCommand"] as? String
        if command == nil, let json,
           let statusLine = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
            command = statusLine["command"] as? String ?? ""
        }
        if command == nil, !hadStatusLine { command = "" }
        return Backup(hadStatusLine: hadStatusLine, statusLineJSON: json, originalCommand: command)
    }

    private func rollBack(to original: Data?, ifCurrentIs written: Data) {
        guard (try? Data(contentsOf: settingsURL)) == written else { return }
        if let original {
            try? atomicWrite(original, createIfMissing: false)
        } else {
            try? fileManager.removeItem(at: settingsURL)
        }
    }

    static func differsOnlyInStatusLineCommand(original: Data, updated: Data, command: String) -> Bool {
        guard var before = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
              var after = try? JSONSerialization.jsonObject(with: updated) as? [String: Any],
              var afterStatus = after["statusLine"] as? [String: Any],
              afterStatus["command"] as? String == command else { return false }
        var beforeStatus = before["statusLine"] as? [String: Any] ?? ["type": "command"]
        beforeStatus["command"] = nil
        afterStatus["command"] = nil
        before["statusLine"] = nil
        after["statusLine"] = nil
        return NSDictionary(dictionary: before).isEqual(to: after)
            && NSDictionary(dictionary: beforeStatus).isEqual(to: afterStatus)
    }

    private func validateManagedSettings() throws {
        guard let data = try? Data(contentsOf: managedSettingsURL) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatusLineInstallerError.managedSettingsOverride
        }
        if object["statusLine"] != nil || (object["disableAllHooks"] as? Bool) == true
            || (object["allowManagedHooksOnly"] as? Bool) == true {
            throw ClaudeStatusLineInstallerError.managedSettingsOverride
        }
    }

    /// `Contents/Helpers/balancebar-statusline`, where both `scripts/build.sh` and the Xcode
    /// "Embed statusLine bridge" phase place it. `Bundle.url(forResource:)` would look under
    /// `Contents/Resources` instead.
    static func bundledHelperURL(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Helpers/balancebar-statusline")
    }

    /// Copies the bundled helper to its stable path. A running wrapper keeps its inode, and an
    /// unchanged helper is not rewritten.
    func installBundledWrapper(from bundled: URL = ClaudeStatusLineInstaller.bundledHelperURL()) throws {
        guard fileManager.isExecutableFile(atPath: bundled.path) else {
            throw ClaudeStatusLineInstallerError.helperMissing
        }
        if let installed = try? Data(contentsOf: wrapperURL), let source = try? Data(contentsOf: bundled),
           installed == source, fileManager.isExecutableFile(atPath: wrapperURL.path) {
            return
        }
        let directory = wrapperURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".balancebar-statusline.\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: bundled, to: temporary)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw ClaudeStatusLineInstallerError.writeFailed
        }
        guard rename(temporary.path, wrapperURL.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw ClaudeStatusLineInstallerError.writeFailed
        }
    }

    /// Removes the installed helper. Called only after the settings no longer reference it.
    func removeInstalledWrapper() {
        try? fileManager.removeItem(at: wrapperURL)
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
        let insertion = statusFields.isEmpty
            ? "\"command\":\(encoded)"
            : ",\"command\":\(encoded)"
        return Self.insertField(in: data, objectRange: status.valueRange, field: insertion)
    }

    private func atomicWrite(_ data: Data, createIfMissing: Bool) throws {
        let directory = settingsURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".balancebar-settings.\(UUID().uuidString).tmp")
        do {
            if createIfMissing {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let permissions = (try? fileManager.attributesOfItem(atPath: settingsURL.path))?[.posixPermissions]
                ?? NSNumber(value: 0o600)
            guard fileManager.createFile(atPath: temporary.path, contents: data,
                                         attributes: [.posixPermissions: permissions]) else {
                throw ClaudeStatusLineInstallerError.writeFailed
            }
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

    private func writeBackup(_ data: Data) throws {
        let directory = backupURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: backupURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        } catch {
            throw ClaudeStatusLineInstallerError.writeFailed
        }
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
