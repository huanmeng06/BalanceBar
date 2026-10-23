import Darwin
import XCTest
@testable import BalanceBar

/// Black-box checks of the built `balancebar-statusline` helper: run an original command
/// directly and through the wrapper with the same stdin, and compare what Claude Code would see.
final class StatusLineBridgeTests: XCTestCase {
    private struct Run: Equatable {
        let stdout: Data
        let stderr: Data
        let status: Int32
        let reason: Process.TerminationReason
    }

    private var directory: URL!
    private var wrapper: URL!

    override func setUpWithError() throws {
        // A space in the path exercises the quoting in the installed command.
        directory = URL(fileURLWithPath: "/tmp/bb bridge \(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        wrapper = directory.appendingPathComponent("balancebar-statusline")
        try FileManager.default.copyItem(at: ClaudeStatusLineInstaller.bundledHelperURL(in: .main), to: wrapper)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var socketPath: String { "/tmp/bbbr-\(directory.lastPathComponent.suffix(6)).sock" }

    private func run(_ command: String, input: Data, environment: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        group.wait()
        return Run(stdout: out, stderr: err, status: process.terminationStatus, reason: process.terminationReason)
    }

    private func wrapped(_ original: String) throws -> String {
        try ClaudeStatusLineInstaller.wrapperCommand(wrapperPath: wrapper.path, originalCommand: original)
            + " --socket '\(socketPath)'"
    }

    private let sample = Data(#"{"session_id":"abc","prompt_id":"p1","version":"2.1.291","cwd":"/secret/dir","rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1900000000},"seven_day":{"used_percentage":40,"resets_at":1901000000}}}"#.utf8)

    private func assertTransparent(_ original: String, input: Data? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = input ?? sample
        let direct = try run(original, input: data)
        let through = try run(try wrapped(original), input: data)
        XCTAssertEqual(through, direct, file: file, line: line)
    }

    func testColouredMultilineOutputStderrAndExitStatusAreUnchanged() throws {
        try assertTransparent(#"printf '\033[31mred\033[0m\nline 2\n'; echo "warn" >&2; exit 3"#)
    }

    func testStdinReachesOriginalByteForByte() throws {
        try assertTransparent("cat")
        try assertTransparent("wc -c", input: Data(repeating: 0x7b, count: 5 * 1_024 * 1_024))
    }

    func testPipelinesQuotesAndExpansionsBehaveAsWithoutWrapper() throws {
        try assertTransparent(#"cat | tr 'a-z' 'A-Z' | head -c 20; printf ' %s|%s' "$HOME" '$HOME'"#)
    }

    func testEnvironmentIsInherited() throws {
        let original = #"printf '%s:%s' "$BB_BRIDGE_TEST" "$PATH""#
        let env = ["BB_BRIDGE_TEST": "visible"]
        let direct = try run(original, input: sample, environment: env)
        let through = try run(try wrapped(original), input: sample, environment: env)
        XCTAssertEqual(through, direct)
        XCTAssertTrue(String(decoding: through.stdout, as: UTF8.self).hasPrefix("visible:"))
    }

    func testOriginalKilledBySignalPropagatesTheSameSignal() throws {
        let original = "kill -TERM $$"
        let direct = try run(original, input: sample)
        let through = try run(try wrapped(original), input: sample)
        XCTAssertEqual(direct.reason, .uncaughtSignal)
        XCTAssertEqual(through, direct)
    }

    func testNoOriginalPrintsNothingAndSucceeds() throws {
        let result = try run(try wrapped(""), input: sample)
        XCTAssertEqual(result.stdout, Data())
        XCTAssertEqual(result.stderr, Data())
        XCTAssertEqual(result.status, 0)
    }

    func testMissingBalanceBarFailsFast() throws {
        // Compare with the original alone, so process-launch cost in the test host cancels out.
        var direct: [TimeInterval] = [], through: [TimeInterval] = []
        for _ in 0..<5 {
            var started = Date()
            _ = try run("echo ok", input: sample)
            direct.append(Date().timeIntervalSince(started))
            started = Date()
            let result = try run(try wrapped("echo ok"), input: sample)
            through.append(Date().timeIntervalSince(started))
            XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ok\n")
        }
        XCTAssertLessThan(through.sorted()[2] - direct.sorted()[2], 0.25, "median extra time without BalanceBar")
    }

    func testPayloadCarriesOnlyQuotaFieldsAndReachesListener() throws {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener); unlink(socketPath) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        unlink(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 4), 0)

        _ = try run(try wrapped("true"), input: sample)
        let client = Darwin.accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = read(client, &buffer, buffer.count)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(buffer.prefix(max(0, count)))) as? [String: Any])
        XCTAssertEqual(object["sessionID"] as? String, "abc")
        XCTAssertEqual((object["fiveHour"] as? [String: Any])?["usedPercentage"] as? Double, 12.5)
        XCTAssertEqual((object["sevenDay"] as? [String: Any])?["resetsAt"] as? Double, 1_901_000_000)
        XCTAssertNil(object["cwd"])
        XCTAssertNotEqual(object["promptMark"] as? String, "p1", "prompt ids are hashed")
        XCTAssertFalse(String(decoding: Data(buffer.prefix(max(0, count))), as: UTF8.self).contains("/secret/dir"))
    }
}
