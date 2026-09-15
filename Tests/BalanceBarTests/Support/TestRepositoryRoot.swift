import Foundation

enum TestRepositoryRoot {
    static func locate(from filePath: String) throws -> URL {
        var directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while directory.path != "/" {
            let projectURL = directory.appendingPathComponent("BalanceBar.xcodeproj")
            if fileManager.fileExists(atPath: projectURL.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }

        struct MissingRepositoryRoot: Error {}
        throw MissingRepositoryRoot()
    }
}
