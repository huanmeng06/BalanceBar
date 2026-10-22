import CryptoKit
import Darwin
import Foundation

private let maximumInputBytes = 4 * 1_024 * 1_024

struct StatusLineBridge {
    let arguments: [String]

    func run() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if input.count <= maximumInputBytes, let payload = makePayload(input) {
            send(payload)
        }
        guard let command = originalCommand() else { return 0 }
        return forward(input, command: command)
    }

    private func makePayload(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let sessionID = object["session_id"] as? String ?? ""
        var payload: [String: Any] = [
            "schemaVersion": 1,
            "sessionID": sessionID,
            "eventReceivedAt": Date().timeIntervalSince1970,
            "ccVersion": object["version"] as? String ?? ""
        ]
        if let prompt = object["prompt_id"] as? String {
            payload["promptMark"] = digest(prompt, length: 16)
        }
        guard let limits = object["rate_limits"] as? [String: Any] else { return nil }
        for (sourceKey, outputKey) in [("five_hour", "fiveHour"), ("seven_day", "sevenDay")] {
            guard let source = limits[sourceKey] as? [String: Any],
                  let used = source["used_percentage"] as? NSNumber else { continue }
            var value: [String: Any] = ["usedPercentage": used]
            if let reset = source["resets_at"] as? NSNumber { value["resetsAt"] = reset }
            payload[outputKey] = value
        }
        guard payload["fiveHour"] != nil || payload["sevenDay"] != nil else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private func send(_ data: Data) {
        guard data.count <= 1_024 else { return }
        let path = socketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(fd, base, data.count)
        }
    }

    private func forward(_ input: Data, command: String) -> Int32 {
        let shell = argument(after: "--shell") ?? "/bin/sh"
        signal(SIGPIPE, SIG_IGN)
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return 0 }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(descriptors[0]); close(descriptors[1]); return 0
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, descriptors[0], STDIN_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        var processID: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-c"), strdup(command), nil]
        let spawnResult = argv.withUnsafeBufferPointer { buffer in
            posix_spawn(&processID, shell, &actions, nil, buffer.baseAddress, nil)
        }
        argv.dropLast().forEach { if let pointer = $0 { free(pointer) } }
        guard spawnResult == 0 else {
            close(descriptors[0]); close(descriptors[1]); return 127
        }
        close(descriptors[0])
        input.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < input.count {
                let result = Darwin.write(descriptors[1], base.advanced(by: written), input.count - written)
                if result <= 0 { break }
                written += result
            }
        }
        close(descriptors[1])
        var status: Int32 = 0
        waitpid(processID, &status, 0)
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }

    private func originalCommand() -> String? {
        guard let encoded = argument(after: "--orig-b64"),
              let data = Data(base64Encoded: encoded),
              let command = String(data: data, encoding: .utf8), !command.isEmpty else { return nil }
        return command
    }

    private func argument(after key: String) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func socketPath() -> String {
        if let explicit = argument(after: "--socket") { return explicit }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BalanceBar/run/sl.sock").path
    }

    private func digest(_ value: String, length: Int) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length).description
    }
}

exit(StatusLineBridge(arguments: Array(CommandLine.arguments.dropFirst())).run())
