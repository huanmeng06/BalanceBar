import Foundation
// Usage: swift scripts/generate-city-time-zone-data.swift cities15000.txt admin1CodesASCII.txt output.lzfse
// Inputs: https://download.geonames.org/export/dump/ (CC BY 4.0).
// See Resources/CityTimeZoneData-LICENSE.txt for attribution and retrieval date.
guard CommandLine.arguments.count == 4 else {
    fatalError("Expected cities15000.txt, admin1CodesASCII.txt and output.lzfse paths")
}
let cities = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let admins = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
var adminNames: [String: String] = [:]
for line in admins.split(separator: "\n") {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    if fields.count >= 2 { adminNames[String(fields[0])] = String(fields[1]) }
}
func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()
}
var output = "# BalanceBar city lookup v2: geonameID, city, normalized aliases (U+001F), country, admin1 code, admin1 name, IANA zone\n"
var count = 0
for line in cities.split(separator: "\n") {
    let c = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard c.count == 19, !c[17].isEmpty else { continue }
    let country = String(c[8]), admin = String(c[10])
    let names = Set(([String(c[1]), String(c[2])] + c[3].split(separator: ",").map(String.init)).map(normalized)).filter { !$0.isEmpty }.sorted()
    let fields = [String(c[0]), String(c[1]), names.joined(separator: "\u{001F}"), country, admin, adminNames[country + "." + admin] ?? admin, String(c[17])]
    output += fields.joined(separator: "\t") + "\n"
    count += 1
}
let compressed = try NSData(data: Data(output.utf8)).compressed(using: .lzfse)
try (compressed as Data).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
print("records=\(count) rawBytes=\(output.utf8.count) compressedBytes=\(compressed.length)")
