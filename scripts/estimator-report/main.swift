import Foundation

// Usage: estimator-report <shadow-log.jsonl>
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: estimator-report <shadow-log.jsonl>\n".utf8))
    exit(2)
}
do {
    let entries = try ShadowLogFileWriter.readEntries(from: URL(fileURLWithPath: CommandLine.arguments[1]))
    print(ShadowReport(entries: entries).render(), terminator: "")
} catch {
    FileHandle.standardError.write(Data("cannot read log: \(error)\n".utf8))
    exit(1)
}
