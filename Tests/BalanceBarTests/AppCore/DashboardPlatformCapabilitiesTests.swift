import AppKit
import XCTest
@testable import BalanceBar

final class DashboardPlatformCapabilitiesTests: XCTestCase {
    func testResolveSelectsLegacyCompatibilityBeforeMacOS26() {
        let versions = [
            OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1),
            OperatingSystemVersion(majorVersion: 25, minorVersion: 9, patchVersion: 0)
        ]
        for version in versions {
            XCTAssertEqual(
                DashboardPlatformCapabilities.resolve(for: version),
                .legacyCompatibility,
                "pre-26 \(version.majorVersion).\(version.minorVersion) must stay on the compatibility family"
            )
        }
    }

    func testResolveSelectsNativeOwnershipOnMacOS26AndLater() {
        let versions = [
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0),
            OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)
        ]
        for version in versions {
            XCTAssertEqual(
                DashboardPlatformCapabilities.resolve(for: version),
                .nativeAppKitOwnership,
                "\(version.majorVersion).\(version.minorVersion) must inherit native AppKit ownership"
            )
        }
    }

    func testCurrentMatchesProcessInfoResolution() {
        XCTAssertEqual(
            DashboardPlatformCapabilities.current,
            DashboardPlatformCapabilities.resolve(
                for: ProcessInfo.processInfo.operatingSystemVersion
            )
        )
    }

    func testNativeAndLegacyFamiliesStaySemanticallyOpposite() {
        let native = DashboardPlatformCapabilities.nativeAppKitOwnership
        let legacy = DashboardPlatformCapabilities.legacyCompatibility

        XCTAssertTrue(native.usesNativeWindowSurface)
        XCTAssertTrue(native.usesAutomaticPageContentInsets)
        XCTAssertTrue(native.usesAutomaticSidebarContentInsets)
        XCTAssertTrue(native.adjustsAdjacentContentSafeArea)
        XCTAssertTrue(native.supportsSplitItemAccessories)
        XCTAssertFalse(native.usesLegacyTitlebarClearance)

        XCTAssertFalse(legacy.usesNativeWindowSurface)
        XCTAssertFalse(legacy.usesAutomaticPageContentInsets)
        XCTAssertFalse(legacy.usesAutomaticSidebarContentInsets)
        XCTAssertFalse(legacy.adjustsAdjacentContentSafeArea)
        XCTAssertFalse(legacy.supportsSplitItemAccessories)
        XCTAssertTrue(legacy.usesLegacyTitlebarClearance)
    }

    func testScrollPoliciesFollowCapabilitiesInsteadOfLocalVersionNumbers() {
        XCTAssertEqual(
            DashboardPageScrollLayoutPolicy.forCapabilities(.nativeAppKitOwnership),
            .systemScrollEdge
        )
        XCTAssertEqual(
            DashboardPageScrollLayoutPolicy.forCapabilities(.legacyCompatibility),
            .titlebarClearance
        )
        XCTAssertEqual(
            DashboardSidebarScrollLayoutPolicy.forCapabilities(.nativeAppKitOwnership),
            .systemScrollEdge
        )
        XCTAssertEqual(
            DashboardSidebarScrollLayoutPolicy.forCapabilities(.legacyCompatibility),
            .titlebarClearance
        )

        let samples: [OperatingSystemVersion] = [
            OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1),
            OperatingSystemVersion(majorVersion: 25, minorVersion: 9, patchVersion: 0),
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)
        ]
        for version in samples {
            let capabilities = DashboardPlatformCapabilities.resolve(for: version)
            XCTAssertEqual(
                DashboardPageScrollLayoutPolicy.forOperatingSystemVersion(version),
                DashboardPageScrollLayoutPolicy.forCapabilities(capabilities)
            )
            XCTAssertEqual(
                DashboardSidebarScrollLayoutPolicy.forOperatingSystemVersion(version),
                DashboardSidebarScrollLayoutPolicy.forCapabilities(capabilities)
            )
        }
    }

    func testDashboardControllersDoNotGrowScatteredMajorVersionBranches() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let productionRoots = [
            repositoryRoot.appendingPathComponent("Sources/UI/Dashboard"),
            repositoryRoot.appendingPathComponent("Sources/AppCore/DashboardScrollClamping.swift")
        ]
        let allowlist = Set([
            repositoryRoot
                .appendingPathComponent("Sources/AppCore/DashboardPlatformCapabilities.swift")
                .standardizedFileURL.path
        ])

        var offenders: [String] = []
        for root in productionRoots {
            for file in try swiftFiles(at: root) {
                let path = file.standardizedFileURL.path
                if allowlist.contains(path) {
                    continue
                }
                let source = try String(contentsOf: file, encoding: .utf8)
                if source.contains("majorVersion") {
                    offenders.append("\(path): majorVersion")
                }
                if source.range(of: #"#available\(\s*macOS 27"#, options: .regularExpression) != nil {
                    offenders.append("\(path): #available(macOS 27")
                }
                if source.range(of: #"#available\(\s*macOS 28"#, options: .regularExpression) != nil {
                    offenders.append("\(path): #available(macOS 28")
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Dashboard chrome must resolve versions in DashboardPlatformCapabilities. Offenders: \(offenders.joined(separator: "; "))"
        )
    }

    func testCapabilityResolverIsTheOnlyDashboardMajorVersionSite() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AppCore/DashboardPlatformCapabilities.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("version.majorVersion >= 26"))
        XCTAssertFalse(source.contains("majorVersion == 26"))
        XCTAssertFalse(source.contains("majorVersion == 27"))
        XCTAssertFalse(source.contains("majorVersion == 28"))
    }

    private func swiftFiles(at root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return root.pathExtension == "swift" ? [root] : []
        }
        let enumerator = try XCTUnwrap(
            fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            files.append(file)
        }
        return files
    }
}
