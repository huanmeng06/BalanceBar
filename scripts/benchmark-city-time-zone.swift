// Standalone probe: compile this file with Sources/Services/CityTimeZoneResolver.swift.
// Copy the production CityTimeZoneData.lzfse into the probe .app's Contents/Resources.
// This narrow support-type projection matches AppTimeZoneSelection's region whitelist;
// the lookup implementation and compressed data are the production files.
import Foundation

enum AppTimeZoneSelection {
    case region(identifier: String)
    static let regionIdentifiers: [String] = {
        var ids = Set(TimeZone.knownTimeZoneIdentifiers)
        if let raw = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) {
            for line in raw.split(separator: "\n") where !line.hasPrefix("#") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                if fields.count >= 3, TimeZone(identifier: String(fields[2])) != nil { ids.insert(String(fields[2])) }
            }
        }
        return ids.sorted()
    }()
    var isSupported: Bool {
        switch self { case .region(let identifier): return Self.regionIdentifiers.contains(identifier) }
    }
}
import Foundation
import Darwin

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

@main struct CityPerformanceProbe {
    static func main() {
        _ = AppTimeZoneSelection.regionIdentifiers
        guard Bundle.main.url(forResource: "CityTimeZoneData", withExtension: "lzfse") != nil else { fatalError("Missing resource") }
        DispatchQueue.global(qos: .userInitiated).sync {
            let initial = footprint()
            print("initial_footprint_bytes=\(initial)")
            let queries = ["夏延", "Springfield", "York", "夏延", "Springfield"]
            let iterations = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? queries.count
            for index in 0..<max(1, iterations) {
                let city = queries[index % queries.count]
                let start = DispatchTime.now().uptimeNanoseconds
                let matches = autoreleasepool { CityTimeZoneGazetteer.lookup(city: city, locale: Locale(identifier: "en_US")) }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                print("query=\(city) elapsed_ms=\(String(format: "%.2f", ms)) results=\(matches.count) footprint_bytes=\(footprint())")
            }
            usleep(100_000)
            print("settled_footprint_bytes=\(footprint()) growth_bytes=\(Int64(footprint()) - Int64(initial))")
        }
    }
}
