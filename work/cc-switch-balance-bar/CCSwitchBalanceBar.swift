import AppKit
import Foundation
import SQLite3
import Darwin

private let databasePath = NSString(string: "~/.cc-switch/cc-switch.db").expandingTildeInPath
private let ccSwitchDirectory = NSString(string: "~/.cc-switch").expandingTildeInPath
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class RotatingTemplateImageView: PassthroughImageView {
    private var sourceImage: NSImage?
    private var rotationTimer: Timer?
    private var angle: CGFloat = 0

    func setSourceImage(_ image: NSImage) {
        sourceImage = image
        self.image = image
    }

    func startRotating() {
        guard rotationTimer == nil, sourceImage != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.advanceRotation()
        }
        rotationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopRotating() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        angle = 0
        image = sourceImage
    }

    private func advanceRotation() {
        guard let sourceImage else { return }
        angle = (angle + (2 * .pi / (1.15 * 30))).truncatingRemainder(dividingBy: 2 * .pi)
        let frameAngle = angle
        let frame = NSImage(size: sourceImage.size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byRadians: frameAngle)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            sourceImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        frame.isTemplate = true
        image = frame
    }

    deinit {
        rotationTimer?.invalidate()
    }
}

private final class QuotaProgressView: NSView {
    let percentage: Double

    init(percentage: Double) {
        self.percentage = min(100, max(0, percentage))
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        let radius = track.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let width = track.width * CGFloat(percentage / 100)
        guard width > 0 else { return }
        let fill = NSRect(x: track.minX, y: track.minY, width: max(track.height, width), height: track.height)
        progressColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    private var progressColor: NSColor {
        switch percentage {
        case let value where value > 50: return .systemGreen
        case 25...50: return .systemYellow
        case 10..<25: return .systemOrange
        default: return .systemRed
        }
    }
}

private final class HoverLinkTextField: NSTextField {
    var onActivate: (() -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var pointingCursorIsPushed = false

    init(text: String) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 12, weight: .medium)
        applyStyle(text: text, underlined: false)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        applyStyle(text: stringValue, underlined: true)
        if !pointingCursorIsPushed {
            NSCursor.pointingHand.push()
            pointingCursorIsPushed = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        applyStyle(text: stringValue, underlined: false)
        if pointingCursorIsPushed {
            NSCursor.pop()
            pointingCursorIsPushed = false
        }
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.pointingHand.set()
        onActivate?()
    }

    deinit {
        if pointingCursorIsPushed { NSCursor.pop() }
    }

    private func applyStyle(text: String, underlined: Bool) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.linkColor
        ]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedStringValue = NSAttributedString(string: text, attributes: attributes)
    }
}

private enum DashboardSection: Int, CaseIterable {
    case general
    case menuBar
    case menu
    case advanced
    case about

    var title: String {
        switch self {
        case .general: return "通用"
        case .menuBar: return "菜单栏"
        case .menu: return "菜单"
        case .advanced: return "高级"
        case .about: return "关于"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .menuBar: return "menubar.rectangle"
        case .menu: return "filemenu.and.selection"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle.fill"
        }
    }

    var chipColor: NSColor {
        switch self {
        case .general: return .systemGray
        case .menuBar: return .systemBlue
        case .menu: return .systemTeal
        case .advanced: return .systemPurple
        case .about: return .systemGreen
        }
    }
}

private enum SwitchLog {
    private static let queue = DispatchQueue(label: "local.ccswitch.balancebar.switch-log")
    static let fileURL = URL(fileURLWithPath: NSString(
        string: "~/Library/Logs/CCSwitchBalanceBar/switch.log"
    ).expandingTildeInPath)

    static func write(_ message: String) {
        queue.async {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try data.write(to: fileURL, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                }
            } catch {
                NSLog("CCSwitchBalanceBar switch log error: %@", error.localizedDescription)
            }
        }
    }
}

private final class CodexActivityMonitor {
    private static let activityWindow = 10 * 60
    private static let terminalTypes: Set<String> = [
        "task_complete", "task_completed", "task_stopped", "task_failed", "task_cancelled",
        "turn_complete", "turn_completed", "turn_aborted", "turn_failed", "turn_cancelled"
    ]
    private struct SessionCache {
        let size: UInt64
        let modifiedAt: TimeInterval
        let running: Bool
    }
    private var sessionCache: [String: SessionCache] = [:]

    func isTaskRunning(now: Date = Date()) -> Bool {
        // A rollout task_complete/failure/cancellation event is authoritative.
        // Only use the delayed logs database when rollout files are unavailable.
        if let rolloutState = recentRolloutRunningState(now: now) { return rolloutState }
        return logsDatabaseIsRunning(now: now)
    }

    private func recentRolloutRunningState(now: Date) -> Bool? {
        let paths = recentRolloutPaths()
        var nextCache: [String: SessionCache] = [:]
        var parsedAny = false
        var anyRunning = false
        for path in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { continue }
            parsedAny = true
            let sizeValue = size.uint64Value
            let modifiedValue = modified.timeIntervalSince1970
            if let cached = sessionCache[path],
               cached.size == sizeValue,
               cached.modifiedAt == modifiedValue {
                nextCache[path] = cached
                anyRunning = anyRunning || cached.running
                continue
            }
            let running = parseSession(path: path)
            let entry = SessionCache(size: sizeValue, modifiedAt: modifiedValue, running: running)
            nextCache[path] = entry
            anyRunning = anyRunning || running
        }
        sessionCache = nextCache
        return parsedAny ? anyRunning : nil
    }

    private func recentRolloutPaths() -> [String] {
        guard let databasePath = Self.latestDatabase(prefix: "state_") else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)
        let sql = "SELECT rollout_path FROM threads WHERE rollout_path <> '' ORDER BY updated_at DESC, updated_at_ms DESC LIMIT 24"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            paths.append(String(cString: text))
        }
        return paths
    }

    private func parseSession(path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let size = try? handle.seekToEnd() else { return false }
        let offset = size > 256 * 1024 ? size - 256 * 1024 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return false }
        let text = String(decoding: data, as: UTF8.self)
        var running = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let topType = object["type"] as? String else { continue }
            if topType == "event_msg", let payload = object["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String {
                if payloadType == "task_started" || payloadType == "user_message" || payloadType == "agent_message" {
                    running = true
                } else if Self.terminalTypes.contains(payloadType) {
                    running = false
                }
            } else if topType == "response_item", let payload = object["payload"] as? [String: Any] {
                let phase = payload["phase"] as? String
                if phase == "final" || phase == "final_answer" {
                    running = false
                } else {
                    running = true
                }
            }
        }
        return running
    }

    private func logsDatabaseIsRunning(now: Date) -> Bool {
        guard let databasePath = Self.latestDatabase(prefix: "logs_") else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return false }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)

        // This follows codex-monitor's activity model: streaming/in-progress
        // events start activity, while task/turn terminal events stop it.
        let normalized = "replace(feedback_log_body, ' ', '')"
        let activity = """
        \(normalized) like '%response.output_item.added%'
        or \(normalized) like '%response.output_text.delta%'
        or \(normalized) like '%\"status\":\"in_progress\"%'
        """
        let terminalTypes = [
            "task_complete", "task_completed", "task_stopped", "task_failed", "task_cancelled",
            "turn_complete", "turn_completed", "turn_aborted", "turn_failed", "turn_cancelled"
        ]
        let completion = ([
            "\(normalized) like '%\"phase\":\"final\"%'",
            "\(normalized) like '%\"phase\":\"final_answer\"%'"
        ] + terminalTypes.map { "\(normalized) like '%\"type\":\"\($0)\"%'" })
            .joined(separator: " or ")
        let sql = """
        select
          max(case when \(activity) then ts else 0 end) as latest_activity,
          max(case when \(completion) then ts else 0 end) as latest_done
        from logs indexed by idx_logs_ts
        where thread_id is not null
          and ts >= ?
          and (\(activity) or \(completion))
        group by thread_id
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let nowEpoch = Int64(now.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 1, nowEpoch - Int64(Self.activityWindow))

        while sqlite3_step(statement) == SQLITE_ROW {
            let latestActivity = sqlite3_column_int64(statement, 0)
            let latestDone = sqlite3_column_int64(statement, 1)
            if latestActivity > latestDone, nowEpoch - latestActivity < Int64(Self.activityWindow) {
                return true
            }
            // Events can share a one-second timestamp. Keep a short grace
            // period so an active stream does not flicker off at that boundary.
            if latestActivity > 0, latestActivity >= latestDone, nowEpoch - latestActivity < 20 {
                return true
            }
        }
        return false
    }

    private static func latestDatabase(prefix: String) -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        return files.compactMap { url -> (version: Int, path: String)? in
            guard url.pathExtension == "sqlite" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix), let version = Int(name.dropFirst(prefix.count)) else { return nil }
            return (version, url.path)
        }.max { $0.version < $1.version }?.path
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusMenu = NSMenu()
    private let menuBarIconView = RotatingTemplateImageView()
    private let menuBarPrimaryLabel = PassthroughTextField(labelWithString: "…")
    private let menuBarSecondaryLabel = PassthroughTextField(labelWithString: "")
    private let dashboardProviderLabel = NSTextField(labelWithString: "正在读取…")
    private let dashboardAmountLabel = NSTextField(labelWithString: "—")
    private let dashboardQuotaLabel = NSTextField(labelWithString: "等待额度信息")
    private let dashboardResetLabel = NSTextField(labelWithString: "")
    private let dashboardRefreshLabel = NSTextField(labelWithString: "--:--:--")
    private let dashboardStatusLabel = NSTextField(labelWithString: "正在连接 CC Switch")
    private let dashboardProvidersStack = NSStackView()
    private let dashboardProgressHost = NSView()
    private let dashboardContentHost = NSView()
    private let dashboardLogView = NSTextView()
    private let dashboardMenuPreviewIcon = NSImageView()
    private let dashboardMenuPreviewIconSlot = NSView()
    private let dashboardMenuPreviewText = NSStackView()
    private let dashboardMenuPreviewPrimary = NSTextField(labelWithString: "…")
    private let dashboardMenuPreviewSecondary = NSTextField(labelWithString: "")
    private let dashboardMenuPreviewCapsule = NSView()
    private var dashboardMenuPreviewCapsuleLeadingConstraint: NSLayoutConstraint?
    private var dashboardMenuPreviewCapsuleTrailingConstraint: NSLayoutConstraint?
    private let dashboardMenuPreviewChromeInset: CGFloat = 10
    private let dashboardProviderSearch = NSSearchField()
    private let dashboardProviderList = NSStackView()
    private let dashboardProviderCountLabel = NSTextField(labelWithString: "")
    private let monitorQueue = DispatchQueue(label: "local.ccswitch.balancebar.monitor")
    private let codexActivityMonitor = CodexActivityMonitor()
    private var dashboard: NSWindow?
    private var dashboardNavigationButtons: [DashboardSection: NSButton] = [:]
    private var dashboardNavigationRows: [DashboardSection: NSView] = [:]
    private var dashboardProviderButtons: [String: NSButton] = [:]
    private var dashboardSection: DashboardSection = .general
    private var dashboardSelectedProviderID: String?
    private var timer: Timer?
    private var activityTimer: Timer?
    private var databaseWatchers: [DispatchSourceFileSystemObject] = []
    private var syncWorkItem: DispatchWorkItem?
    private var lastSuccessfulRefresh: Date?
    private var lastProviderID: String?
    private var lastBalanceFetch: Date?
    private var lastOfficialFetch: Date?
    private var lastQuickSwitchFetch: Date?
    private let quickSwitchSummaryLock = NSLock()
    private var quickSwitchSummaries: [String: String] = [:]
    private var snapshot = Snapshot.placeholder
    private var activeProviderWebsite: URL?
    private var isCodexTaskRunning = false
    private var statusLayoutGeneration = 0

    private var showMenuBarReset: Bool {
        get { UserDefaults.standard.object(forKey: "showMenuBarReset") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showMenuBarReset") }
    }

    private var showMenuBarIcon: Bool {
        get { UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showMenuBarIcon") }
    }

    private var showMenuBarAmount: Bool {
        get { UserDefaults.standard.object(forKey: "showMenuBarAmount") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showMenuBarAmount") }
    }

    private var animateCodexActivity: Bool {
        get { UserDefaults.standard.object(forKey: "animateCodexActivity") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "animateCodexActivity") }
    }

    private var providerPollInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: "providerPollInterval")
            return value > 0 ? value : 3
        }
        set { UserDefaults.standard.set(newValue, forKey: "providerPollInterval") }
    }

    private var activityPollInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: "activityPollInterval")
            return value > 0 ? value : 0.25
        }
        set { UserDefaults.standard.set(newValue, forKey: "activityPollInterval") }
    }

    private var showQuickSwitchMenu: Bool {
        get { UserDefaults.standard.object(forKey: "showQuickSwitchMenu") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showQuickSwitchMenu") }
    }

    private var showOpenCCSwitchMenu: Bool {
        get { UserDefaults.standard.object(forKey: "showOpenCCSwitchMenu") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showOpenCCSwitchMenu") }
    }

    private var keepMenuOpenAfterRefresh: Bool {
        get { UserDefaults.standard.object(forKey: "keepMenuOpenAfterRefresh") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepMenuOpenAfterRefresh") }
    }

    private var sortProvidersAlphabetically: Bool {
        get { UserDefaults.standard.bool(forKey: "sortProvidersAlphabetically") }
        set { UserDefaults.standard.set(newValue, forKey: "sortProvidersAlphabetically") }
    }

    private var menuBarHorizontalPadding: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: "menuBarHorizontalPadding")
            return value > 0 ? CGFloat(value) : 12
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "menuBarHorizontalPadding") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A normal window is intentional for the first prototype: macOS Tahoe may
        // hide new menu extras, and this gives the user an always-visible fallback.
        NSApp.setActivationPolicy(.regular)
        showDashboard()
        statusItem.menu = statusMenu
        configureStatusItem()
        statusItem.button?.title = ""
        startDatabaseWatchers()
        SwitchLog.write("app launched; database=\(databasePath)")
        refresh(forceBalance: true)
        refreshQuickSwitchSummaries(force: true)
        refreshCodexActivity()
        // The file watcher handles normal CC Switch writes. This inexpensive
        // read is a fallback for a missed filesystem notification.
        configureRefreshTimers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        activityTimer?.invalidate()
        databaseWatchers.forEach { $0.cancel() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDashboard() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dashboard else { return }
        // Keep the menu-bar service alive, but remove its Dock presence once
        // the optional configuration window is closed.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func manualRefresh() {
        refresh(forceBalance: true)
        refreshQuickSwitchSummaries(force: true)

        // A native NSMenu closes after invoking an item's action. Re-open the
        // same status-item menu on the next run-loop turn so manual refresh
        // keeps the balance panel visible while the new data is fetched.
        if keepMenuOpenAfterRefresh {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }
    }

    @objc private func switchProvider(_ sender: NSMenuItem) {
        guard let providerID = sender.representedObject as? String else { return }
        // The visible menu title also contains the cached balance. Keep the
        // actual Provider name separate for logs and CC Switch synchronization.
        let providerName = Provider.loadChoices().first(where: { $0.id == providerID })?.name ?? sender.title
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let current = Provider.loadChoices().first(where: { $0.isCurrent })
            SwitchLog.write("switch requested; from=\(current?.name ?? "none"); to=\(providerName); id=\(providerID)")
            if current?.id == providerID {
                SwitchLog.write("switch skipped; target is already current")
                return
            }

            let ccSwitch = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.ccswitch.desktop"
            ).first
            let ccSwitchURL = ccSwitch?.bundleURL ?? NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.ccswitch.desktop"
            )
            if let ccSwitch {
                SwitchLog.write("CC Switch graceful stop requested; pid=\(ccSwitch.processIdentifier)")
                ccSwitch.terminate()
                let deadline = Date().addingTimeInterval(4)
                while !ccSwitch.isTerminated && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard ccSwitch.isTerminated else {
                    SwitchLog.write("switch failed; CC Switch did not terminate within 4s")
                    self.render(.error("切换失败：CC Switch 未能正常重载"))
                    return
                }
                SwitchLog.write("CC Switch stopped cleanly")
            } else {
                SwitchLog.write("CC Switch was not running; switching live configuration directly")
            }

            do {
                try Provider.switchCurrent(to: providerID)
                let confirmed = Provider.loadChoices().first(where: { $0.isCurrent })
                guard confirmed?.id == providerID else {
                    throw NSError(
                        domain: "CCSwitchBalanceBar.SwitchValidation",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "数据库校验未通过"]
                    )
                }
                SwitchLog.write("database and Codex live config updated; current=\(confirmed?.name ?? providerName)")

                if ccSwitch != nil, let ccSwitchURL {
                    DispatchQueue.main.async {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        configuration.hides = true
                        configuration.addsToRecentItems = false
                        NSWorkspace.shared.openApplication(at: ccSwitchURL, configuration: configuration) { _, error in
                            if let error {
                                SwitchLog.write("CC Switch background reopen failed; error=\(error.localizedDescription)")
                            } else {
                                SwitchLog.write("CC Switch reopened hidden; target=\(providerName)")
                            }
                        }
                    }
                }
                self.lastProviderID = nil
                self.lastBalanceFetch = nil
                self.lastOfficialFetch = nil
                self.refresh(forceBalance: true)
            } catch {
                SwitchLog.write("switch failed; target=\(providerName); error=\(error.localizedDescription)")
                if ccSwitch != nil, let ccSwitchURL {
                    DispatchQueue.main.async {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        configuration.hides = true
                        NSWorkspace.shared.openApplication(at: ccSwitchURL, configuration: configuration) { _, _ in }
                    }
                }
                self.render(.error("切换失败：\(error.localizedDescription)"))
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openCCSwitch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ccswitch.desktop") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    @objc private func openProviderWebsite() {
        guard let activeProviderWebsite else { return }
        NSWorkspace.shared.open(activeProviderWebsite)
    }

    @objc private func selectDashboardSection(_ sender: NSButton) {
        guard let section = DashboardSection(rawValue: sender.tag) else { return }
        showDashboardSection(section)
    }

    @objc private func dashboardToggleChanged(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "showMenuBarIcon":
            if sender.state == .off && !showMenuBarAmount {
                sender.state = .on
            }
            showMenuBarIcon = sender.state == .on
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showMenuBarAmount":
            if sender.state == .off && !showMenuBarIcon {
                sender.state = .on
            }
            showMenuBarAmount = sender.state == .on
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showMenuBarReset":
            showMenuBarReset = sender.state == .on
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showQuickSwitchMenu":
            showQuickSwitchMenu = sender.state == .on
            render(snapshot)
        case "showOpenCCSwitchMenu":
            showOpenCCSwitchMenu = sender.state == .on
            render(snapshot)
        case "keepMenuOpenAfterRefresh":
            keepMenuOpenAfterRefresh = sender.state == .on
        case "animateCodexActivity":
            animateCodexActivity = sender.state == .on
            setCodexTaskRunning(isCodexTaskRunning, force: true)
        default:
            break
        }
    }

    @objc private func dashboardIntervalChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? NSNumber else { return }
        switch sender.identifier?.rawValue {
        case "providerPollInterval": providerPollInterval = value.doubleValue
        case "activityPollInterval": activityPollInterval = value.doubleValue
        default: return
        }
        configureRefreshTimers()
    }

    @objc private func dashboardMenuBarPaddingChanged(_ sender: NSSlider) {
        menuBarHorizontalPadding = CGFloat(sender.doubleValue)
        updateStatusItem(for: snapshot)
    }

    @objc private func dashboardSwitchProvider(_ sender: NSButton) {
        guard let providerID = sender.identifier?.rawValue else { return }
        let item = NSMenuItem(title: sender.toolTip ?? "", action: nil, keyEquivalent: "")
        item.representedObject = providerID
        switchProvider(item)
    }

    @objc private func dashboardProviderSearchChanged(_ sender: NSSearchField) {
        rebuildDashboardProviderList()
    }

    @objc private func dashboardSortProviders(_ sender: NSButton) {
        sortProvidersAlphabetically.toggle()
        sender.contentTintColor = sortProvidersAlphabetically ? .controlAccentColor : .secondaryLabelColor
        rebuildDashboardProviderList()
    }

    @objc private func dashboardSelectProvider(_ sender: NSButton) {
        guard let providerID = sender.identifier?.rawValue else { return }
        showDashboardProvider(providerID)
    }

    @objc private func refreshDashboardLog() {
        let text = (try? String(contentsOf: SwitchLog.fileURL, encoding: .utf8)) ?? "暂无日志"
        dashboardLogView.string = text
        dashboardLogView.scrollToEndOfDocument(nil)
    }

    @objc private func revealDashboardLog() {
        NSWorkspace.shared.activateFileViewerSelecting([SwitchLog.fileURL])
    }

    @objc private func openDashboard() {
        NSApp.setActivationPolicy(.regular)
        if let dashboard {
            dashboard.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        showDashboard()
    }

    private func showDashboard() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = DashboardSection.general.title
        window.minSize = NSSize(width: 800, height: 540)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let splitView = NSSplitView(frame: window.contentView?.bounds ?? .zero)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]

        let sidebar = makeDashboardSidebar()
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: splitView.bounds.height)
        dashboardContentHost.frame = NSRect(x: 261, y: 0, width: splitView.bounds.width - 261, height: splitView.bounds.height)
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(dashboardContentHost)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        sidebar.widthAnchor.constraint(equalToConstant: 260).isActive = true

        window.contentView = splitView
        dashboard = window
        showDashboardSection(.general)
        updateDashboard(for: snapshot, refreshDate: lastSuccessfulRefresh ?? snapshot.date)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeDashboardSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active

        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 4
        dashboardNavigationButtons.removeAll()
        dashboardNavigationRows.removeAll()
        for section in DashboardSection.allCases {
            navigation.addArrangedSubview(makeDashboardNavigationRow(for: section))
        }

        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navigation)
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 22),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12)
        ])
        return sidebar
    }

    private func makeDashboardNavigationRow(for section: DashboardSection) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.backgroundColor = NSColor.clear.cgColor
        row.widthAnchor.constraint(equalToConstant: 236).isActive = true
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let button = NSButton(title: "", target: self, action: #selector(selectDashboardSection(_:)))
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .clear
        button.tag = section.rawValue
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])

        let chip = PassthroughView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = section.chipColor.cgColor
        chip.layer?.cornerRadius = 7
        chip.translatesAutoresizingMaskIntoConstraints = false
        let icon = PassthroughImageView()
        icon.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = PassthroughTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(chip)
        row.addSubview(icon)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            chip.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 28),
            chip.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        dashboardNavigationButtons[section] = button
        dashboardNavigationRows[section] = row
        return row
    }

    private func showDashboardSection(_ section: DashboardSection) {
        dashboardSection = section
        dashboardSelectedProviderID = nil
        dashboard?.title = section.title
        dashboardNavigationButtons.forEach {
            let isCurrent = $0.key == section
            $0.value.state = isCurrent ? .on : .off
            $0.value.isBordered = false
            $0.value.contentTintColor = .clear
            $0.value.superview?.layer?.backgroundColor = isCurrent
                ? NSColor.controlAccentColor.withAlphaComponent(0.96).cgColor
                : NSColor.clear.cgColor
        }
        rebuildDashboardProviderList()
        dashboardContentHost.subviews.forEach { $0.removeFromSuperview() }

        let page: NSView
        switch section {
        case .general: page = makeGeneralDashboardPage()
        case .menuBar: page = makeMenuBarDashboardPage()
        case .menu: page = makeMenuDashboardPage()
        case .advanced: page = makeAdvancedDashboardPage()
        case .about: page = makeAboutDashboardPage()
        }
        page.frame = dashboardContentHost.bounds
        page.autoresizingMask = [.width, .height]
        dashboardContentHost.addSubview(page)
        updateDashboard(for: snapshot, refreshDate: lastSuccessfulRefresh ?? snapshot.date)
    }

    private func rebuildDashboardProviderList() {
        guard dashboard != nil else { return }
        for child in dashboardProviderList.arrangedSubviews {
            dashboardProviderList.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        dashboardProviderButtons.removeAll()

        let query = dashboardProviderSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var choices = Provider.loadChoices().filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
        if sortProvidersAlphabetically {
            choices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        dashboardProviderCountLabel.stringValue = "\(Provider.loadChoices().count) 个"

        for choice in choices {
            let button = NSButton(title: choice.name, target: self, action: #selector(dashboardSelectProvider(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            let isSelected = dashboardSelectedProviderID == choice.id
            button.isBordered = isSelected
            button.state = isSelected ? .on : .off
            button.alignment = .left
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 13, weight: choice.isCurrent ? .semibold : .regular)
            button.contentTintColor = isSelected ? .controlAccentColor : (choice.isCurrent ? .labelColor : .secondaryLabelColor)
            button.focusRingType = .none
            button.identifier = NSUserInterfaceItemIdentifier(choice.id)
            button.toolTip = choice.isCurrent ? "当前 Provider" : "查看 \(choice.name)"
            if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg"),
               let image = NSImage(contentsOf: iconURL) {
                image.size = NSSize(width: 16, height: 16)
                image.isTemplate = true
                button.image = image
            }
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 228).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            dashboardProviderButtons[choice.id] = button
            dashboardProviderList.addArrangedSubview(button)
        }
    }

    private func showDashboardProvider(_ providerID: String) {
        guard let choice = Provider.loadChoices().first(where: { $0.id == providerID }) else { return }
        dashboardSelectedProviderID = providerID
        dashboard?.title = choice.name
        dashboardNavigationButtons.values.forEach {
            $0.state = .off
            $0.isBordered = false
            $0.contentTintColor = .labelColor
        }
        rebuildDashboardProviderList()
        dashboardContentHost.subviews.forEach { $0.removeFromSuperview() }
        let page = makeProviderDashboardPage(choice)
        page.frame = dashboardContentHost.bounds
        page.autoresizingMask = [.width, .height]
        dashboardContentHost.addSubview(page)
        updateDashboard(for: snapshot, refreshDate: lastSuccessfulRefresh ?? snapshot.date)
    }

    private func makeSettingsPage(_ sections: [NSView]) -> NSView {
        let root = NSView()
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 38),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -38)
        ])
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return root
    }

    private func makeSettingsSection(_ title: String, rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        for (index, row) in rows.enumerated() {
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if index < rows.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                rowsStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -32).isActive = true
            }
        }

        let section = NSStackView(views: [heading, card])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 9
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeSettingsRow(
        _ title: String,
        subtitle: String? = nil,
        control: NSView? = nil,
        minimumHeight: CGFloat = 58
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let labels = NSStackView(views: [label])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        if let subtitle, !subtitle.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: subtitle)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            labels.addArrangedSubview(detail)
        }
        labels.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        var constraints = [
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 9),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -9)
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(control)
            constraints.append(contentsOf: [
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16)
            ])
        } else {
            constraints.append(labels.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func makeGeneralDashboardPage() -> NSView {
        let openButton = NSButton(title: "打开 CC Switch", target: self, action: #selector(openCCSwitch))
        let currentName = Provider.loadChoices().first(where: { $0.isCurrent })?.name ?? "未找到"
        let system = makeSettingsSection("系统", rows: [
            makeSettingsRow("CC Switch", subtitle: "当前 Provider：\(currentName)", control: openButton),
            makeSettingsRow("后台运行", subtitle: "关闭主窗口后保留菜单栏服务")
        ])

        let pollingPopup = makeIntervalPopup(
            values: [(1, "1 秒"), (3, "3 秒"), (5, "5 秒"), (10, "10 秒")],
            selected: providerPollInterval,
            identifier: "providerPollInterval"
        )
        let refreshButton = NSButton(title: "立即刷新", target: self, action: #selector(manualRefresh))
        let refreshing = makeSettingsSection("刷新", rows: [
            makeSettingsRow("后备轮询间隔", subtitle: "数据库事件监听始终保持开启", control: pollingPopup),
            makeSettingsRow("余额数据", subtitle: "立即重新读取当前 Provider", control: refreshButton)
        ])

        let quitButton = NSButton(title: "退出应用", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded
        let app = makeSettingsSection("应用", rows: [
            makeSettingsRow("BalanceBar", subtitle: "菜单栏余额与 Provider 快速切换", control: quitButton)
        ])
        return makeSettingsPage([system, refreshing, app])
    }

    private func makeMenuDashboardPage() -> NSView {
        let quickSwitch = NSButton(checkboxWithTitle: "", target: self, action: #selector(dashboardToggleChanged(_:)))
        quickSwitch.identifier = NSUserInterfaceItemIdentifier("showQuickSwitchMenu")
        quickSwitch.state = showQuickSwitchMenu ? .on : .off
        quickSwitch.setButtonType(.switch)
        let openCC = NSButton(checkboxWithTitle: "", target: self, action: #selector(dashboardToggleChanged(_:)))
        openCC.identifier = NSUserInterfaceItemIdentifier("showOpenCCSwitchMenu")
        openCC.state = showOpenCCSwitchMenu ? .on : .off
        openCC.setButtonType(.switch)
        let keepOpen = NSButton(checkboxWithTitle: "", target: self, action: #selector(dashboardToggleChanged(_:)))
        keepOpen.identifier = NSUserInterfaceItemIdentifier("keepMenuOpenAfterRefresh")
        keepOpen.state = keepMenuOpenAfterRefresh ? .on : .off
        keepOpen.setButtonType(.switch)

        let items = makeSettingsSection("展开菜单", rows: [
            makeSettingsRow("快速切换", subtitle: "显示 CC Switch Provider 子菜单", control: quickSwitch),
            makeSettingsRow("打开 CC Switch", subtitle: "显示 CC Switch 启动项", control: openCC),
            makeSettingsRow("刷新后保持展开", subtitle: "点击立即刷新后重新打开菜单", control: keepOpen)
        ])
        let order = makeSettingsSection("固定项目", rows: [
            makeSettingsRow("打开主窗口", subtitle: "始终显示"),
            makeSettingsRow("退出 BalanceBar", subtitle: "始终显示")
        ])
        return makeSettingsPage([items, order])
    }

    private func makeAdvancedDashboardPage() -> NSView {
        let activityPopup = makeIntervalPopup(
            values: [(0.25, "0.25 秒"), (0.5, "0.5 秒"), (1, "1 秒")],
            selected: activityPollInterval,
            identifier: "activityPollInterval"
        )
        let animation = NSButton(checkboxWithTitle: "", target: self, action: #selector(dashboardToggleChanged(_:)))
        animation.identifier = NSUserInterfaceItemIdentifier("animateCodexActivity")
        animation.state = animateCodexActivity ? .on : .off
        animation.setButtonType(.switch)
        let activity = makeSettingsSection("Codex 任务状态", rows: [
            makeSettingsRow("检测间隔", subtitle: "决定图标开始与停止旋转的响应速度", control: activityPopup),
            makeSettingsRow("任务运行时旋转图标", control: animation)
        ])

        let refreshLog = NSButton(title: "刷新", target: self, action: #selector(refreshDashboardLog))
        let revealLog = NSButton(title: "在 Finder 中显示", target: self, action: #selector(revealDashboardLog))
        let logButtons = NSStackView(views: [refreshLog, revealLog])
        logButtons.orientation = .horizontal
        logButtons.spacing = 8
        let logs = makeSettingsSection("诊断", rows: [
            makeSettingsRow("切换日志", subtitle: "Provider 同步和失败原因", control: logButtons)
        ])
        return makeSettingsPage([activity, logs])
    }

    private func makeAboutDashboardPage() -> NSView {
        let root = NSView()
        let icon = NSImageView()
        if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg") {
            icon.image = NSImage(contentsOf: iconURL)
        }
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let name = NSTextField(labelWithString: "BalanceBar")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        let version = NSTextField(labelWithString: "版本 0.1.0")
        version.textColor = .secondaryLabelColor
        let detail = NSTextField(labelWithString: "与 CC Switch 同步的 Codex Provider 余额菜单栏工具")
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, name, version, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 92)
        ])
        return root
    }

    private func makeProviderDashboardPage(_ choice: ProviderChoice) -> NSView {
        dashboardProviderLabel.stringValue = choice.name
        dashboardProviderLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        let status = NSTextField(labelWithString: choice.isCurrent ? "当前 Provider" : "可用 Provider")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = choice.isCurrent ? .systemGreen : .secondaryLabelColor
        let heading = NSStackView(views: [dashboardProviderLabel, status])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        quickSwitchSummaryLock.lock()
        let cachedSummary = quickSwitchSummaries[choice.id]
        quickSwitchSummaryLock.unlock()
        dashboardAmountLabel.stringValue = choice.isCurrent ? snapshot.overviewLargeAmount : (cachedSummary ?? "正在读取…")
        dashboardAmountLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        dashboardQuotaLabel.stringValue = "剩余额度"
        dashboardResetLabel.stringValue = choice.isCurrent
            ? snapshot.overviewReset(refreshDate: lastSuccessfulRefresh, formatter: Self.timeFormatter)
            : "选择为当前 Provider 后显示详细重置时间"
        let usage = makeSettingsSection("用量", rows: [
            makeSettingsRow("剩余额度", subtitle: dashboardResetLabel.stringValue, control: dashboardAmountLabel, minimumHeight: 76)
        ])

        let action: NSButton
        if choice.isCurrent {
            action = NSButton(title: "立即刷新", target: self, action: #selector(manualRefresh))
        } else {
            action = NSButton(title: "切换到此 Provider", target: self, action: #selector(dashboardSwitchProvider(_:)))
            action.identifier = NSUserInterfaceItemIdentifier(choice.id)
            action.toolTip = choice.name
        }
        let connection = makeSettingsSection("CC Switch", rows: [
            makeSettingsRow("同步状态", subtitle: choice.isCurrent ? "正在跟随此 Provider" : "当前未使用此 Provider", control: action)
        ])
        return makeSettingsPage([heading, usage, connection])
    }

    private func makePageHeader(_ title: String, subtitle: String) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func makeOverviewDashboardPage() -> NSView {
        let root = NSView()
        let header = makePageHeader("概览", subtitle: "当前余额、同步状态和 Codex Provider")

        dashboardProviderLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        dashboardProviderLabel.lineBreakMode = .byTruncatingTail
        dashboardRefreshLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dashboardRefreshLabel.textColor = .secondaryLabelColor
        dashboardRefreshLabel.alignment = .right
        let providerSpacer = NSView()
        let providerRow = NSStackView(views: [dashboardProviderLabel, providerSpacer, dashboardRefreshLabel])
        providerRow.orientation = .horizontal
        providerRow.alignment = .centerY

        dashboardQuotaLabel.font = .systemFont(ofSize: 13, weight: .medium)
        dashboardResetLabel.font = .systemFont(ofSize: 13)
        dashboardResetLabel.textColor = .secondaryLabelColor
        let quotaStack = NSStackView(views: [dashboardQuotaLabel, dashboardResetLabel])
        quotaStack.orientation = .vertical
        quotaStack.alignment = .leading
        quotaStack.spacing = 5

        dashboardAmountLabel.font = .monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        dashboardAmountLabel.alignment = .right
        let quotaSpacer = NSView()
        let quotaRow = NSStackView(views: [quotaStack, quotaSpacer, dashboardAmountLabel])
        quotaRow.orientation = .horizontal
        quotaRow.alignment = .centerY

        dashboardProgressHost.translatesAutoresizingMaskIntoConstraints = false
        dashboardProgressHost.heightAnchor.constraint(equalToConstant: 6).isActive = true
        dashboardStatusLabel.font = .systemFont(ofSize: 12)
        dashboardStatusLabel.textColor = .secondaryLabelColor

        let separator = NSBox()
        separator.boxType = .separator
        let providersTitle = NSTextField(labelWithString: "Providers")
        providersTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        dashboardProvidersStack.orientation = .vertical
        dashboardProvidersStack.alignment = .leading
        dashboardProvidersStack.spacing = 0

        let stack = NSStackView(views: [
            header, providerRow, quotaRow, dashboardProgressHost,
            dashboardStatusLabel, separator, providersTitle, dashboardProvidersStack
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(24, after: header)
        stack.setCustomSpacing(7, after: dashboardProgressHost)
        stack.setCustomSpacing(18, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            providerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            quotaRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dashboardProgressHost.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dashboardProvidersStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }

    private func makeMenuBarDashboardPage() -> NSView {
        let preview = NSVisualEffectView()
        preview.material = .menu
        preview.state = .active
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 190).isActive = true
        dashboardMenuPreviewIcon.imageScaling = .scaleProportionallyDown
        dashboardMenuPreviewIcon.translatesAutoresizingMaskIntoConstraints = false
        dashboardMenuPreviewIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        dashboardMenuPreviewIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        dashboardMenuPreviewPrimary.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        dashboardMenuPreviewPrimary.textColor = .labelColor
        dashboardMenuPreviewSecondary.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        dashboardMenuPreviewSecondary.textColor = .secondaryLabelColor
        let previewText = dashboardMenuPreviewText
        previewText.addArrangedSubview(dashboardMenuPreviewPrimary)
        previewText.addArrangedSubview(dashboardMenuPreviewSecondary)
        previewText.orientation = .vertical
        previewText.alignment = .leading
        previewText.spacing = 0
        previewText.wantsLayer = true
        previewText.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -2))
        let previewIconSlot = dashboardMenuPreviewIconSlot
        previewIconSlot.translatesAutoresizingMaskIntoConstraints = false
        previewIconSlot.widthAnchor.constraint(equalToConstant: 18).isActive = true
        previewIconSlot.heightAnchor.constraint(equalToConstant: 18).isActive = true
        previewIconSlot.addSubview(dashboardMenuPreviewIcon)
        NSLayoutConstraint.activate([
            dashboardMenuPreviewIcon.centerXAnchor.constraint(equalTo: previewIconSlot.centerXAnchor),
            dashboardMenuPreviewIcon.centerYAnchor.constraint(equalTo: previewIconSlot.centerYAnchor, constant: 1)
        ])
        let previewRow = NSStackView(views: [previewIconSlot, previewText])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = 6
        previewRow.translatesAutoresizingMaskIntoConstraints = false
        dashboardMenuPreviewCapsule.wantsLayer = true
        dashboardMenuPreviewCapsule.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        dashboardMenuPreviewCapsule.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        dashboardMenuPreviewCapsule.layer?.borderWidth = 0.5
        dashboardMenuPreviewCapsule.layer?.cornerRadius = 12
        dashboardMenuPreviewCapsule.layer?.masksToBounds = true
        dashboardMenuPreviewCapsule.isHidden = true
        dashboardMenuPreviewCapsule.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(dashboardMenuPreviewCapsule)
        preview.addSubview(previewRow)
        let capsuleLeading = dashboardMenuPreviewCapsule.leadingAnchor.constraint(
            equalTo: previewRow.leadingAnchor,
            constant: -(menuBarHorizontalPadding + dashboardMenuPreviewChromeInset)
        )
        let capsuleTrailing = dashboardMenuPreviewCapsule.trailingAnchor.constraint(
            equalTo: previewRow.trailingAnchor,
            constant: menuBarHorizontalPadding + dashboardMenuPreviewChromeInset
        )
        dashboardMenuPreviewCapsuleLeadingConstraint = capsuleLeading
        dashboardMenuPreviewCapsuleTrailingConstraint = capsuleTrailing
        NSLayoutConstraint.activate([
            previewRow.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            previewRow.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            previewRow.leadingAnchor.constraint(greaterThanOrEqualTo: preview.leadingAnchor, constant: 14),
            previewRow.trailingAnchor.constraint(lessThanOrEqualTo: preview.trailingAnchor, constant: -14),
            capsuleLeading,
            capsuleTrailing,
            dashboardMenuPreviewCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: preview.leadingAnchor, constant: 6),
            dashboardMenuPreviewCapsule.trailingAnchor.constraint(lessThanOrEqualTo: preview.trailingAnchor, constant: -6),
            dashboardMenuPreviewCapsule.topAnchor.constraint(equalTo: previewRow.topAnchor, constant: -3),
            dashboardMenuPreviewCapsule.bottomAnchor.constraint(equalTo: previewRow.bottomAnchor, constant: 3),
            preview.heightAnchor.constraint(equalToConstant: 42)
        ])
        let iconToggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(dashboardToggleChanged(_:)))
        iconToggle.identifier = NSUserInterfaceItemIdentifier("showMenuBarIcon")
        iconToggle.state = showMenuBarIcon ? .on : .off
        let amountToggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(dashboardToggleChanged(_:)))
        amountToggle.identifier = NSUserInterfaceItemIdentifier("showMenuBarAmount")
        amountToggle.state = showMenuBarAmount ? .on : .off
        let resetToggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(dashboardToggleChanged(_:)))
        resetToggle.identifier = NSUserInterfaceItemIdentifier("showMenuBarReset")
        resetToggle.state = showMenuBarReset ? .on : .off
        let paddingSlider = NSSlider(
            value: Double(menuBarHorizontalPadding),
            minValue: 6,
            maxValue: 24,
            target: self,
            action: #selector(dashboardMenuBarPaddingChanged(_:))
        )
        paddingSlider.numberOfTickMarks = 7
        paddingSlider.allowsTickMarkValuesOnly = false
        paddingSlider.isContinuous = true
        paddingSlider.toolTip = "调整菜单栏选中椭圆的宽度"
        paddingSlider.translatesAutoresizingMaskIntoConstraints = false
        paddingSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let previewSection = makeSettingsSection("预览", rows: [
            makeSettingsRow("当前布局", subtitle: "菜单栏会随 Provider 数据实时更新", control: preview, minimumHeight: 66)
        ])
        let displaySection = makeSettingsSection("显示项目", rows: [
            makeSettingsRow("Codex 图标", subtitle: "显示当前任务运行状态", control: iconToggle),
            makeSettingsRow("额度数字", subtitle: "显示百分比或 API 余额", control: amountToggle),
            makeSettingsRow("重置倒计时", subtitle: "仅在官方额度可用时显示", control: resetToggle),
            makeSettingsRow("按钮左右内边距", subtitle: "调整选中椭圆与内容之间的距离", control: paddingSlider)
        ])
        refreshDashboardMenuBarPage()
        return makeSettingsPage([previewSection, displaySection])
    }

    private func refreshDashboardMenuBarPage() {
        guard dashboardSection == .menuBar else { return }
        dashboardMenuPreviewIconSlot.isHidden = !showMenuBarIcon
        dashboardMenuPreviewText.isHidden = !showMenuBarAmount
        dashboardMenuPreviewPrimary.isHidden = !showMenuBarAmount
        dashboardMenuPreviewSecondary.isHidden = !showMenuBarReset || !showMenuBarAmount || snapshot.kind != .official
        dashboardMenuPreviewPrimary.stringValue = showMenuBarAmount ? snapshot.menuBarPrimary : ""
        dashboardMenuPreviewSecondary.stringValue = showMenuBarReset ? snapshot.menuBarSecondary : ""
        dashboardMenuPreviewCapsuleLeadingConstraint?.constant = -(
            menuBarHorizontalPadding + dashboardMenuPreviewChromeInset
        )
        dashboardMenuPreviewCapsuleTrailingConstraint?.constant =
            menuBarHorizontalPadding + dashboardMenuPreviewChromeInset
        if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            dashboardMenuPreviewIcon.image = icon
            dashboardMenuPreviewIcon.contentTintColor = .labelColor
        }
    }

    private func makeRefreshDashboardPage() -> NSView {
        let root = NSView()
        let header = makePageHeader("刷新设置", subtitle: "文件监听始终开启，轮询用于防止遗漏系统事件")
        let pollingTitle = NSTextField(labelWithString: "CC Switch 轮询兜底")
        pollingTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let pollingPopup = makeIntervalPopup(
            values: [(1, "每 1 秒"), (3, "每 3 秒"), (5, "每 5 秒"), (10, "每 10 秒")],
            selected: providerPollInterval,
            identifier: "providerPollInterval"
        )
        let pollingSpacer = NSView()
        let pollingRow = NSStackView(views: [pollingTitle, pollingSpacer, pollingPopup])
        pollingRow.orientation = .horizontal
        pollingRow.alignment = .centerY

        let activityTitle = NSTextField(labelWithString: "Codex 任务状态检测")
        activityTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let activityPopup = makeIntervalPopup(
            values: [(0.25, "0.25 秒"), (0.5, "0.5 秒"), (1, "1 秒")],
            selected: activityPollInterval,
            identifier: "activityPollInterval"
        )
        let activitySpacer = NSView()
        let activityRow = NSStackView(views: [activityTitle, activitySpacer, activityPopup])
        activityRow.orientation = .horizontal
        activityRow.alignment = .centerY

        let animationToggle = NSButton(checkboxWithTitle: "Codex 有任务运行时旋转菜单栏图标", target: self, action: #selector(dashboardToggleChanged(_:)))
        animationToggle.identifier = NSUserInterfaceItemIdentifier("animateCodexActivity")
        animationToggle.state = animateCodexActivity ? .on : .off
        let note = NSTextField(wrappingLabelWithString: "Provider 变化仍由 CC Switch 数据库事件即时触发；这里的秒数只是没有收到事件时的后备检查频率。")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header, pollingRow, activityRow, animationToggle, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(30, after: header)
        stack.setCustomSpacing(24, after: activityRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            pollingRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }

    private func makeIntervalPopup(
        values: [(Double, String)],
        selected: TimeInterval,
        identifier: String
    ) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.identifier = NSUserInterfaceItemIdentifier(identifier)
        popup.target = self
        popup.action = #selector(dashboardIntervalChanged(_:))
        for (index, value) in values.enumerated() {
            popup.addItem(withTitle: value.1)
            popup.item(at: index)?.representedObject = NSNumber(value: value.0)
            if abs(value.0 - selected) < 0.001 { popup.selectItem(at: index) }
        }
        return popup
    }

    private func makeLogsDashboardPage() -> NSView {
        let root = NSView()
        let header = makePageHeader("日志", subtitle: "Provider 切换、同步和失败原因")
        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshDashboardLog))
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        let revealButton = NSButton(title: "在 Finder 中显示", target: self, action: #selector(revealDashboardLog))
        revealButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "在 Finder 中显示")
        let buttonSpacer = NSView()
        let buttons = NSStackView(views: [refreshButton, revealButton, buttonSpacer])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        dashboardLogView.isEditable = false
        dashboardLogView.isSelectable = true
        dashboardLogView.isVerticallyResizable = true
        dashboardLogView.isHorizontallyResizable = false
        dashboardLogView.autoresizingMask = [.width]
        dashboardLogView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        dashboardLogView.textContainerInset = NSSize(width: 10, height: 10)
        dashboardLogView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = dashboardLogView

        [header, buttons, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            buttons.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            buttons.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28)
        ])
        return root
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        statusItem.length = 56
        button.title = ""
        button.image = nil
        button.toolTip = "BalanceBar"

        if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = true
            menuBarIconView.setSourceImage(icon)
        }
        menuBarIconView.imageScaling = .scaleProportionallyDown
        menuBarPrimaryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        menuBarPrimaryLabel.textColor = .labelColor
        menuBarPrimaryLabel.lineBreakMode = .byClipping
        menuBarSecondaryLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        // A menu-bar button is frequently drawn over a translucent or
        // highlighted background. Keep the reset label high-contrast too.
        menuBarSecondaryLabel.textColor = .labelColor
        menuBarSecondaryLabel.lineBreakMode = .byClipping
        [menuBarIconView, menuBarPrimaryLabel, menuBarSecondaryLabel].forEach { button.addSubview($0) }
        layoutStatusItem(hasSecondary: false, isBalance: false)
    }

    private func configureRefreshTimers() {
        timer?.invalidate()
        activityTimer?.invalidate()

        let providerTimer = Timer(timeInterval: providerPollInterval, repeats: true) { [weak self] _ in
            self?.refresh(forceBalance: false)
            self?.refreshQuickSwitchSummaries(force: false)
        }
        timer = providerTimer
        RunLoop.main.add(providerTimer, forMode: .common)

        let taskTimer = Timer(timeInterval: activityPollInterval, repeats: true) { [weak self] _ in
            self?.refreshCodexActivity()
        }
        activityTimer = taskTimer
        RunLoop.main.add(taskTimer, forMode: .common)
    }

    private func refreshCodexActivity() {
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let running = self.codexActivityMonitor.isTaskRunning()
            DispatchQueue.main.async {
                self.setCodexTaskRunning(running)
            }
        }
    }

    private func setCodexTaskRunning(_ running: Bool, force: Bool = false) {
        guard force || running != isCodexTaskRunning else { return }
        isCodexTaskRunning = running
        if running && animateCodexActivity {
            menuBarIconView.startRotating()
        } else {
            menuBarIconView.stopRotating()
        }
    }

    private func layoutStatusItem(hasSecondary: Bool, isBalance: Bool) {
        guard let button = statusItem.button else { return }
        let width = button.bounds.width
        let height = button.bounds.height
        let iconWidth: CGFloat = showMenuBarIcon ? 16 : 0
        let glyphSlack: CGFloat = 3
        let secondaryWidth = hasSecondary ? menuBarSecondaryLabel.intrinsicContentSize.width : 0
        let textWidth = showMenuBarAmount
            ? ceil(max(menuBarPrimaryLabel.intrinsicContentSize.width, secondaryWidth)) + glyphSlack
            : 0
        let gap: CGFloat = showMenuBarIcon && showMenuBarAmount ? 3 : 0
        let groupWidth = iconWidth + gap + textWidth
        let groupX = max(1, floor((width - groupWidth) / 2))
        let iconY = floor((height - 16) / 2) + ((hasSecondary || isBalance) ? 0 : -1)
        menuBarIconView.frame = NSRect(x: groupX, y: iconY, width: 16, height: 16)
        menuBarIconView.isHidden = !showMenuBarIcon
        let textX = groupX + iconWidth + gap
        let actualTextWidth = max(0, width - textX - max(1, groupX))
        menuBarPrimaryLabel.isHidden = !showMenuBarAmount
        if hasSecondary && showMenuBarAmount {
            // The two text rows deliberately use a 2:1 height split.
            // NSStatusBarButton is flipped: y = 0 is the visual top.
            menuBarPrimaryLabel.frame = NSRect(x: textX, y: -2, width: actualTextWidth, height: 15)
            menuBarSecondaryLabel.frame = NSRect(x: textX, y: 11, width: actualTextWidth, height: 11)
        } else {
            let singleLineYOffset: CGFloat = isBalance ? 1 : -1
            menuBarPrimaryLabel.frame = NSRect(x: textX, y: floor((height - 15) / 2) + singleLineYOffset, width: actualTextWidth, height: 15)
            menuBarSecondaryLabel.frame = .zero
        }
    }

    private func updateStatusItem(for snapshot: Snapshot) {
        statusLayoutGeneration += 1
        let layoutGeneration = statusLayoutGeneration
        let secondary = showMenuBarReset && showMenuBarAmount ? snapshot.menuBarSecondary : ""
        menuBarPrimaryLabel.stringValue = snapshot.menuBarPrimary
        menuBarSecondaryLabel.stringValue = secondary
        menuBarSecondaryLabel.isHidden = secondary.isEmpty
        let glyphSlack: CGFloat = 3
        let textWidth = showMenuBarAmount
            ? ceil(max(menuBarPrimaryLabel.intrinsicContentSize.width, secondary.isEmpty ? 0 : menuBarSecondaryLabel.intrinsicContentSize.width)) + glyphSlack
            : 0
        let groupWidth = (showMenuBarIcon ? 16 : 0) + (showMenuBarIcon && showMenuBarAmount ? 3 : 0) + textWidth
        // NSStatusBarButton draws its selected capsule across the status-item
        // width. Reserve explicit symmetric padding so long and negative
        // balances never touch or disappear beneath the capsule edge.
        statusItem.length = max(30, ceil(groupWidth + (menuBarHorizontalPadding * 2)))
        statusItem.button?.layoutSubtreeIfNeeded()
        layoutStatusItem(hasSecondary: !secondary.isEmpty, isBalance: snapshot.kind == .balance)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.statusLayoutGeneration == layoutGeneration else { return }
            self.statusItem.button?.layoutSubtreeIfNeeded()
            self.layoutStatusItem(hasSecondary: !secondary.isEmpty, isBalance: snapshot.kind == .balance)
        }
        statusItem.button?.toolTip = snapshot.menuBarToolTip
        refreshDashboardMenuBarPage()
    }

    private func updateDashboard(for snapshot: Snapshot, refreshDate: Date?) {
        guard dashboard != nil else { return }
        if let selectedID = dashboardSelectedProviderID,
           let choice = Provider.loadChoices().first(where: { $0.id == selectedID }) {
            dashboardProviderLabel.stringValue = choice.name
            if choice.isCurrent {
                dashboardAmountLabel.stringValue = snapshot.overviewLargeAmount
                dashboardResetLabel.stringValue = snapshot.overviewReset(
                    refreshDate: refreshDate,
                    formatter: Self.timeFormatter
                )
            } else {
                quickSwitchSummaryLock.lock()
                let cached = quickSwitchSummaries[selectedID]
                quickSwitchSummaryLock.unlock()
                dashboardAmountLabel.stringValue = cached ?? "正在读取…"
                dashboardResetLabel.stringValue = "选择为当前 Provider 后显示详细重置时间"
            }
        }
        rebuildDashboardProviderList()
        refreshDashboardMenuBarPage()
    }

    private func refreshDashboardProviderRows() {
        guard dashboard != nil else { return }
        for child in dashboardProvidersStack.arrangedSubviews {
            dashboardProvidersStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }

        let choices = Provider.loadChoices()
        if choices.isEmpty {
            let empty = NSTextField(labelWithString: "未找到 Codex Provider")
            empty.textColor = .secondaryLabelColor
            dashboardProvidersStack.addArrangedSubview(empty)
            return
        }

        quickSwitchSummaryLock.lock()
        let summaries = quickSwitchSummaries
        quickSwitchSummaryLock.unlock()
        for (index, choice) in choices.enumerated() {
            let name = NSTextField(labelWithString: choice.name)
            name.font = .systemFont(ofSize: 13, weight: choice.isCurrent ? .semibold : .regular)
            name.lineBreakMode = .byTruncatingTail
            let summary = NSTextField(labelWithString: summaries[choice.id] ?? "正在读取…")
            summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            summary.textColor = .secondaryLabelColor
            summary.alignment = .right
            summary.translatesAutoresizingMaskIntoConstraints = false
            summary.widthAnchor.constraint(equalToConstant: 112).isActive = true
            let spacer = NSView()
            let action = NSButton(
                title: choice.isCurrent ? "当前" : "切换",
                target: self,
                action: #selector(dashboardSwitchProvider(_:))
            )
            action.bezelStyle = .roundRect
            action.controlSize = .small
            action.isEnabled = !choice.isCurrent
            action.identifier = NSUserInterfaceItemIdentifier(choice.id)
            action.toolTip = choice.name
            action.translatesAutoresizingMaskIntoConstraints = false
            action.widthAnchor.constraint(equalToConstant: 58).isActive = true
            let row = NSStackView(views: [name, spacer, summary, action])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 34).isActive = true
            dashboardProvidersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: dashboardProvidersStack.widthAnchor).isActive = true

            if index < choices.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.widthAnchor.constraint(equalTo: dashboardProvidersStack.widthAnchor).isActive = true
                dashboardProvidersStack.addArrangedSubview(separator)
            }
        }
    }

    private func refresh(forceBalance: Bool) {
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let current = Provider.loadCurrent()
            guard let current else {
                self.render(.error("未找到 CC Switch 当前 Codex Provider"))
                return
            }

            let switched = current.id != self.lastProviderID
            if switched {
                SwitchLog.write("provider observed; id=\(current.id); name=\(current.name); source=database watcher/poll")
            }
            self.lastProviderID = current.id
            guard let query = current.query else {
                guard current.isOfficial else {
                    self.render(.error("\(current.name)：未启用 CC Switch 余额查询"))
                    return
                }
                let due = self.lastOfficialFetch.map { Date().timeIntervalSince($0) >= 60 } ?? true
                guard forceBalance || switched || due else { return }
                self.lastOfficialFetch = Date()
                self.fetchOfficialQuota(providerID: current.id, providerName: current.name)
                return
            }

            let interval = TimeInterval(max(query.intervalMinutes, 1) * 60)
            let due = self.lastBalanceFetch.map { Date().timeIntervalSince($0) >= interval } ?? true
            guard forceBalance || switched || due else { return }
            self.lastBalanceFetch = Date()
            self.fetchBalance(providerID: current.id, providerName: current.name, query: query)
        }
    }

    private func startDatabaseWatchers() {
        // SQLite commits usually update the WAL file; watching both the main DB
        // and its WAL gives near-instant provider-switch detection.
        let paths = [databasePath, "\(databasePath)-wal", ccSwitchDirectory]
        databaseWatchers = paths.compactMap { makeWatcher(for: $0) }
    }

    private func makeWatcher(for path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: monitorQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleImmediateSync()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleImmediateSync() {
        syncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            // A CC Switch database write may represent either a Provider
            // switch or a credential/configuration update. Bypass the normal
            // provider interval so the menu follows it immediately.
            self?.refresh(forceBalance: true)
            self?.refreshQuickSwitchSummaries(force: true)
        }
        syncWorkItem = workItem
        // CC Switch commits several SQLite/WAL writes per action. Coalesce
        // them, while keeping the post-switch refresh visually immediate.
        monitorQueue.asyncAfter(deadline: .now() + .milliseconds(80), execute: workItem)
    }

    private func refreshQuickSwitchSummaries(force: Bool) {
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let due = self.lastQuickSwitchFetch.map { Date().timeIntervalSince($0) >= 60 } ?? true
            guard force || due else { return }
            self.lastQuickSwitchFetch = Date()

            for source in Provider.loadSummarySources() {
                if source.isOfficial {
                    guard let token = source.officialAccessToken else { continue }
                    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
                    request.timeoutInterval = 15
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                        guard let self,
                              let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode),
                              let data,
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let quota = Self.extractOfficialQuota(from: object) else { return }
                        self.updateQuickSwitchSummary(
                            providerID: source.id,
                            text: "\(Int(quota.remaining))% / \(quota.daysText)"
                        )
                    }.resume()
                    continue
                }

                guard let query = source.query,
                      let url = URL(string: query.url),
                      url.scheme?.lowercased() == "https" else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = TimeInterval(query.timeoutSeconds)
                request.setValue("Bearer \(query.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                    guard let self,
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          let data,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let balance = Self.extractBalance(from: object, rightCode: query.isRightCode) else { return }
                    let unit = Self.stringValue(object["unit"])
                        ?? Self.stringValue((object["quota"] as? [String: Any])?["unit"])
                        ?? "USD"
                    self.updateQuickSwitchSummary(
                        providerID: source.id,
                        text: Self.formatBalanceSummary(balance, unit: unit)
                    )
                }.resume()
            }
        }
    }

    private func updateQuickSwitchSummary(providerID: String, text: String) {
        quickSwitchSummaryLock.lock()
        quickSwitchSummaries[providerID] = text
        quickSwitchSummaryLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let names = Dictionary(uniqueKeysWithValues: Provider.loadChoices().map { ($0.id, $0.name) })
            if let submenu = self.statusMenu.items.first(where: { $0.title == "快速切换" })?.submenu {
                for item in submenu.items {
                    guard let id = item.representedObject as? String, let name = names[id] else { continue }
                    self.applyQuickSwitchTitle(to: item, providerID: id, providerName: name)
                }
            }
            self.rebuildDashboardProviderList()
            self.updateDashboard(for: self.snapshot, refreshDate: self.lastSuccessfulRefresh ?? self.snapshot.date)
        }
    }

    private func quickSwitchTitle(providerID: String, providerName: String) -> String {
        quickSwitchSummaryLock.lock()
        let summary = quickSwitchSummaries[providerID]
        quickSwitchSummaryLock.unlock()
        return "\(providerName)\t\(summary ?? "…")"
    }

    private func applyQuickSwitchTitle(to item: NSMenuItem, providerID: String, providerName: String) {
        let title = quickSwitchTitle(providerID: providerID, providerName: providerName)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 170)]
        paragraph.defaultTabInterval = 170
        item.title = title
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .paragraphStyle: paragraph
            ]
        )
    }

    private static func formatBalanceSummary(_ amount: Double, unit: String) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        return unit.uppercased() == "USD" ? "$\(number)" : "\(number) \(unit)"
    }

    private func fetchBalance(providerID: String, providerName: String, query: BalanceQuery) {
        guard let url = URL(string: query.url), url.scheme?.lowercased() == "https" else {
            renderForCurrentProvider(.error("\(providerName)：余额接口不是 HTTPS"), providerID: providerID)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(query.timeoutSeconds)
        request.setValue("Bearer \(query.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.renderForCurrentProvider(.error("\(providerName)：\(error.localizedDescription)"), providerID: providerID)
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                self.renderForCurrentProvider(.error("\(providerName)：余额接口返回异常"), providerID: providerID)
                return
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                guard let balance = Self.extractBalance(from: object, rightCode: query.isRightCode) else {
                    self.renderForCurrentProvider(.error("\(providerName)：未识别余额格式"), providerID: providerID)
                    return
                }
                let unit = Self.stringValue(object["unit"]) ?? Self.stringValue((object["quota"] as? [String: Any])?["unit"]) ?? "USD"
                self.updateQuickSwitchSummary(providerID: providerID, text: Self.formatBalanceSummary(balance, unit: unit))
                self.renderForCurrentProvider(.balance(providerName, balance, unit, query.websiteURL, Date()), providerID: providerID)
            } catch {
                self.renderForCurrentProvider(.error("\(providerName)：余额响应无法解析"), providerID: providerID)
            }
        }.resume()
    }

    private func fetchOfficialQuota(providerID: String, providerName: String) {
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            renderForCurrentProvider(.error("官方 Codex：未找到本机登录态"), providerID: providerID)
            return
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.renderForCurrentProvider(.error("官方 Codex：\(error.localizedDescription)"), providerID: providerID)
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.renderForCurrentProvider(.error("官方 Codex：额度接口返回异常"), providerID: providerID)
                return
            }
            guard let quota = Self.extractOfficialQuota(from: object) else {
                self.renderForCurrentProvider(.error("官方 Codex：未识别额度格式"), providerID: providerID)
                return
            }
            self.updateQuickSwitchSummary(providerID: providerID, text: "\(Int(quota.remaining))% / \(quota.daysText)")
            self.renderForCurrentProvider(.official(providerName, quota.remaining, quota.label, quota.reset, Date()), providerID: providerID)
        }.resume()
    }

    private func renderForCurrentProvider(_ next: Snapshot, providerID: String) {
        monitorQueue.async { [weak self] in
            guard let self, self.lastProviderID == providerID else { return }
            self.render(next)
        }
    }

    private static func extractBalance(from object: [String: Any], rightCode: Bool) -> Double? {
        if rightCode {
            let cash = numberValue(object["balance"]) ?? 0
            let subscriptions = object["subscriptions"] as? [[String: Any]] ?? []
            let subscriptionBalance = subscriptions.reduce(0.0) { total, subscription in
                let prefixes = subscription["available_prefixes"] as? [String] ?? []
                guard prefixes.contains("/codex") else { return total }
                let remaining = numberValue(subscription["remaining_quota"]) ?? 0
                let limit = numberValue(subscription["total_quota"]) ?? 0
                let resetsToday = (subscription["reset_today"] as? Bool) ?? false
                return total + (resetsToday ? remaining : remaining + limit)
            }
            return cash + subscriptionBalance
        }
        if let direct = numberValue(object["remaining"]) ?? numberValue(object["balance"]) { return direct }
        if let quota = object["quota"] as? [String: Any] { return numberValue(quota["remaining"]) }
        return nil
    }

    private static func extractOfficialQuota(from object: [String: Any]) -> (remaining: Double, label: String, daysText: String, reset: String?)? {
        let limits = (object["rate_limit"] as? [String: Any]) ?? object
        let primary = limits["primary_window"] as? [String: Any]
        let secondary = limits["secondary_window"] as? [String: Any]
        // Select the longest actual window; CC Switch may expose weekly quota
        // in either primary_window or secondary_window.
        let windows = [primary, secondary].compactMap { $0 }
        guard let chosen = windows.max(by: {
            (numberValue($0["limit_window_seconds"]) ?? 0) <
            (numberValue($1["limit_window_seconds"]) ?? 0)
        }), let used = numberValue(chosen["used_percent"]) else { return nil }
        let remaining = max(0, min(100, 100 - used))
        let duration = numberValue(chosen["limit_window_seconds"]) ?? 0
        let isWeekly = duration >= 6 * 86_400
        let reset = resetDescription(chosen["reset_after_seconds"])
            ?? resetDescription(chosen["reset_at"])
            ?? (chosen["reset_description"] as? String)
        return (remaining, isWeekly ? "7 日额度" : "额度", isWeekly ? "7 天" : "额度", reset)
    }

    private static func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func resetDescription(_ value: Any?) -> String? {
        if let number = numberValue(value) {
            let timestamp = number > 10_000_000_000 ? number / 1_000 : number
            let date = timestamp > 1_000_000_000
                ? Date(timeIntervalSince1970: timestamp)
                : Date().addingTimeInterval(timestamp)
            return remainingTime(until: date)
        }
        guard let text = stringValue(value), !text.isEmpty else { return nil }
        if let number = Double(text) { return resetDescription(number) }
        if let date = ISO8601DateFormatter().date(from: text) { return remainingTime(until: date) }
        return text
    }

    private static func remainingTime(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded(.down)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }

    private func render(_ next: Snapshot) {
        DispatchQueue.main.async {
            self.snapshot = next
            self.activeProviderWebsite = next.websiteURL
            self.statusItem.button?.title = ""
            self.updateStatusItem(for: next)
            self.statusMenu.removeAllItems()
            if next.kind != .error, next.kind != .placeholder { self.lastSuccessfulRefresh = next.date }
            let refreshDate = self.lastSuccessfulRefresh ?? next.date
            self.updateDashboard(for: next, refreshDate: refreshDate)
            self.statusMenu.addItem(self.makeOverviewMenuItem(for: next, refreshDate: refreshDate))
            self.statusMenu.addItem(.separator())
            if self.showQuickSwitchMenu {
                self.statusMenu.addItem(self.makeQuickSwitchMenuItem())
            }
            self.statusMenu.addItem(withTitle: "立即刷新", action: #selector(self.manualRefresh), keyEquivalent: "r").target = self
            self.statusMenu.addItem(.separator())
            if self.showOpenCCSwitchMenu {
                self.statusMenu.addItem(withTitle: "打开 CC Switch", action: #selector(self.openCCSwitch), keyEquivalent: "").target = self
            }
            self.statusMenu.addItem(withTitle: "打开主窗口", action: #selector(self.openDashboard), keyEquivalent: "").target = self
            self.statusMenu.addItem(.separator())
            self.statusMenu.addItem(withTitle: "退出 BalanceBar", action: #selector(self.quit), keyEquivalent: "q").target = self
        }
    }

    private func makeQuickSwitchMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "快速切换", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "快速切换")
        submenu.minimumWidth = 210
        let choices = Provider.loadChoices()
        if choices.isEmpty {
            let empty = NSMenuItem(title: "未找到 Codex Provider", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for choice in choices {
                let item = NSMenuItem(
                    title: "",
                    action: #selector(switchProvider(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = choice.id
                item.state = choice.isCurrent ? .on : .off
                applyQuickSwitchTitle(to: item, providerID: choice.id, providerName: choice.name)
                submenu.addItem(item)
            }
        }
        parent.submenu = submenu
        return parent
    }

    private func makeOverviewMenuItem(for snapshot: Snapshot, refreshDate: Date?) -> NSMenuItem {
        let item = NSMenuItem()
        // The overview is deliberately a static card, not a selectable menu
        // command. Custom labels keep it bright while the item stays disabled.
        item.isEnabled = snapshot.kind == .balance && snapshot.websiteURL != nil
        let isBalance = snapshot.kind == .balance
        let viewHeight: CGFloat = isBalance ? 86 : 102
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: viewHeight))

        let provider = makeOverviewLabel(snapshot.overviewProvider, font: .systemFont(ofSize: 15, weight: .semibold))
        provider.frame = NSRect(x: 14, y: isBalance ? 58 : 75, width: 205, height: 20)

        if snapshot.kind == .official || snapshot.kind == .balance {
            let timeText = refreshDate.map { Self.timeFormatter.string(from: $0) } ?? "--:--:--"
            let refreshTime = makeOverviewLabel(timeText, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
            refreshTime.textColor = .secondaryLabelColor
            refreshTime.alignment = .right
            refreshTime.frame = NSRect(x: 225, y: isBalance ? 59 : 76, width: 81, height: 17)
            view.addSubview(refreshTime)
        }

        if let percentage = snapshot.progressPercentage {
            let progress = QuotaProgressView(percentage: percentage)
            // Keep the header clean. The progress bar belongs below the two
            // quota-detail rows, in the otherwise empty space above actions.
            progress.frame = NSRect(x: 14, y: 8, width: 292, height: 5)
            view.addSubview(progress)
        }

        let quotaDetail = makeOverviewLabel(snapshot.overviewQuotaDetail, font: .systemFont(ofSize: 13, weight: .medium))
        let amount = makeOverviewLabel(snapshot.overviewLargeAmount, font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold))
        amount.alignment = .right

        if isBalance {
            // A third-party balance has no percentage for a progress bar.
            // Align the number with these two compact text rows instead.
            // Preserve the previous spacing above these rows. Only the empty
            // space below the link is reduced by the shorter card height.
            quotaDetail.frame = NSRect(x: 14, y: 31, width: 140, height: 18)
            amount.frame = NSRect(x: 157, y: 5, width: 149, height: 48)

            let linkPrefix = makeOverviewLabel("官方链接：", font: .systemFont(ofSize: 12, weight: .regular))
            linkPrefix.textColor = .secondaryLabelColor
            linkPrefix.frame = NSRect(x: 14, y: 10, width: 62, height: 17)
            view.addSubview(linkPrefix)

            if snapshot.websiteURL != nil {
                let link = HoverLinkTextField(text: snapshot.provider)
                link.onActivate = { [weak self] in self?.openProviderWebsite() }
                // Match the prefix label's exact baseline and line box.
                link.frame = NSRect(x: 75, y: 10, width: 148, height: 17)
                view.addSubview(link)
            }
        } else {
            // The following two rows form the left half of the quota display;
            // the amount spans both on right.
            quotaDetail.frame = NSRect(x: 14, y: 47, width: 140, height: 18)
            let reset = makeOverviewLabel(snapshot.overviewReset(refreshDate: refreshDate, formatter: Self.timeFormatter), font: .systemFont(ofSize: 13, weight: .regular))
            reset.textColor = .secondaryLabelColor
            reset.frame = NSRect(x: 14, y: 28, width: 140, height: 17)
            // Visually center the large percentage across the combined height
            // of the two left-hand rows (equivalent to merged-cell centering).
            amount.frame = NSRect(x: 157, y: 18, width: 149, height: 48)
            view.addSubview(reset)
        }

        [provider, quotaDetail, amount].forEach(view.addSubview)
        item.view = view
        return item
    }

    private func makeOverviewLabel(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

@main
enum CCSwitchBalanceBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

private struct Snapshot {
    enum Kind { case placeholder, official, balance, error }
    let kind: Kind
    let provider: String
    let amount: Double?
    let unit: String?
    let date: Date?
    let message: String?
    let websiteURL: URL?

    static let placeholder = Snapshot(kind: .placeholder, provider: "", amount: nil, unit: nil, date: nil, message: nil, websiteURL: nil)
    static func official(_ provider: String, _ remaining: Double, _ lane: String, _ reset: String?, _ date: Date) -> Snapshot { Snapshot(kind: .official, provider: provider, amount: remaining, unit: lane, date: date, message: reset, websiteURL: nil) }
    static func balance(_ provider: String, _ amount: Double, _ unit: String, _ websiteURL: URL?, _ date: Date) -> Snapshot { Snapshot(kind: .balance, provider: provider, amount: amount, unit: unit, date: date, message: nil, websiteURL: websiteURL) }
    static func error(_ message: String) -> Snapshot { Snapshot(kind: .error, provider: "", amount: nil, unit: nil, date: nil, message: message, websiteURL: nil) }

    var menuBarTitle: String {
        switch kind {
        case .placeholder: return " …"
        case .official: return " \(Int(amount ?? 0))%"
        case .balance: return " \(format(amount ?? 0, unit ?? "USD"))"
        case .error: return " !"
        }
    }

    var menuBarPrimary: String {
        switch kind {
        case .placeholder: return "…"
        case .official: return "\(Int(amount ?? 0))%"
        case .balance: return format(amount ?? 0, unit ?? "USD")
        case .error: return "!"
        }
    }

    var menuBarSecondary: String {
        kind == .official ? (message ?? "—") : ""
    }

    var menuBarToolTip: String {
        guard kind == .official else { return title }
        return "\(title) · 重置：\(message ?? "未知")"
    }

    var overviewProvider: String {
        switch kind {
        case .placeholder: return "CC Switch"
        case .official, .balance: return provider
        case .error: return "CC Switch"
        }
    }

    func overviewReset(refreshDate: Date?, formatter: DateFormatter) -> String {
        switch kind {
        case .official: return "重置：\(message ?? "未知")"
        case .balance: return "最后刷新：\(formatter.string(from: refreshDate ?? date ?? Date()))"
        case .placeholder: return "正在读取当前 Provider…"
        case .error: return message ?? "余额读取失败"
        }
    }

    var overviewQuotaTitle: String {
        switch kind {
        case .official: return "可用额度"
        case .balance: return "可用余额"
        case .placeholder: return "额度状态"
        case .error: return "额度状态"
        }
    }

    var overviewQuotaDetail: String {
        switch kind {
        case .official: return unit ?? "7 日额度"
        case .balance: return "剩余额度"
        case .placeholder: return "等待刷新"
        case .error: return "读取失败"
        }
    }

    var overviewLargeAmount: String {
        switch kind {
        case .official: return "\(Int(amount ?? 0))%"
        case .balance: return format(amount ?? 0, unit ?? "USD")
        case .placeholder: return "—"
        case .error: return "—"
        }
    }

    var progressPercentage: Double? {
        kind == .official ? amount : nil
    }

    var title: String {
        switch kind {
        case .placeholder: return "正在读取 CC Switch…"
        case .official: return "\(provider) 剩余：\(Int(amount ?? 0))%（\(unit ?? "额度")）"
        case .balance: return "\(provider) 剩余：\(format(amount ?? 0, unit ?? "USD"))"
        case .error: return "余额读取失败"
        }
    }

    var compactQuotaTitle: String {
        switch kind {
        case .official:
            return "\(unit ?? "额度")剩余：\(Int(amount ?? 0))%"
        default:
            return title
        }
    }

    var compactResetTitle: String {
        switch kind {
        case .official:
            return "重置：\(message ?? "等待额度信息")"
        default:
            return ""
        }
    }

    var detail: String {
        switch kind {
        case .balance:
            return "更新：\(date?.formatted(date: .omitted, time: .shortened) ?? "刚刚") · 随 CC Switch 自动切换"
        case .official:
            let resetText = message.map { " · 重置：\($0)" } ?? ""
            return "每分钟更新官方额度\(resetText)"
        case .error: return message ?? "未知错误"
        case .placeholder: return "等待 CC Switch 状态"
        }
    }

    private func format(_ amount: Double, _ unit: String) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        return unit.uppercased() == "USD" ? "$\(number)" : "\(number) \(unit)"
    }
}

private struct ProviderChoice {
    let id: String
    let name: String
    let isCurrent: Bool
}

private struct ProviderSummarySource {
    let id: String
    let isOfficial: Bool
    let query: BalanceQuery?
    let officialAccessToken: String?
}

private struct Provider {
    let id: String
    let name: String
    let isOfficial: Bool
    let query: BalanceQuery?

    static func loadCurrent() -> Provider? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { return nil }
        defer { sqlite3_close(database) }
        let sql = "SELECT id, name, settings_config, meta, category, website_url FROM providers WHERE app_type = 'codex' AND is_current = 1 LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let configText = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
              let metaText = sqlite3_column_text(statement, 3).map({ String(cString: $0) }) else { return nil }
        let category = sqlite3_column_text(statement, 4).map({ String(cString: $0) })
        let websiteText = sqlite3_column_text(statement, 5).map({ String(cString: $0) })
        guard category != "official", let query = BalanceQuery.make(settingsText: configText, metaText: metaText, websiteText: websiteText) else {
            return Provider(id: id, name: name, isOfficial: category == "official", query: nil)
        }
        return Provider(id: id, name: name, isOfficial: false, query: query)
    }

    static func loadChoices() -> [ProviderChoice] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }
        let sql = "SELECT id, name, is_current FROM providers WHERE app_type = 'codex' ORDER BY COALESCE(sort_index, 999999), created_at, id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [ProviderChoice] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let nameText = sqlite3_column_text(statement, 1) else { continue }
            result.append(ProviderChoice(
                id: String(cString: idText),
                name: String(cString: nameText),
                isCurrent: sqlite3_column_int(statement, 2) != 0
            ))
        }
        return result
    }

    static func loadSummarySources() -> [ProviderSummarySource] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3_000)

        let sql = "SELECT id, settings_config, meta, category, website_url FROM providers WHERE app_type = 'codex' ORDER BY COALESCE(sort_index, 999999), created_at, id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        var result: [ProviderSummarySource] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            let settingsText = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "{}"
            let metaText = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "{}"
            let category = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let websiteText = sqlite3_column_text(statement, 4).map { String(cString: $0) }

            if category == "official" {
                let stored = settingsText.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let auth = stored?["auth"] as? [String: Any]
                let tokens = auth?["tokens"] as? [String: Any]
                let accessToken = tokens?["access_token"] as? String
                result.append(ProviderSummarySource(
                    id: id,
                    isOfficial: true,
                    query: nil,
                    officialAccessToken: accessToken
                ))
            } else {
                result.append(ProviderSummarySource(
                    id: id,
                    isOfficial: false,
                    query: BalanceQuery.make(
                        settingsText: settingsText,
                        metaText: metaText,
                        websiteText: websiteText
                    ),
                    officialAccessToken: nil
                ))
            }
        }
        return result
    }

    static func switchCurrent(to providerID: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw switchError("无法打开 CC Switch 数据库") }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3_000)

        guard let target = loadSwitchTarget(providerID, database: database) else {
            throw switchError("Provider 不存在")
        }

        let settingsURL = URL(fileURLWithPath: NSString(string: "~/.cc-switch/settings.json").expandingTildeInPath)
        var appSettings = (try? Data(contentsOf: settingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let preserveOfficialAuth = appSettings["preserveCodexOfficialAuthOnSwitch"] as? Bool ?? false
        let unifyHistory = appSettings["unifyCodexSessionHistory"] as? Bool ?? true

        if !proxyTakeoverIsActive(database) {
            guard let stored = try? JSONSerialization.jsonObject(with: Data(target.settingsConfig.utf8)) as? [String: Any],
                  let auth = stored["auth"],
                  var config = stored["config"] as? String else {
                throw switchError("Provider 的 Codex 配置不完整")
            }

            let codexDirectory = URL(fileURLWithPath: NSString(string: "~/.codex").expandingTildeInPath, isDirectory: true)
            let authURL = codexDirectory.appendingPathComponent("auth.json")
            let configURL = codexDirectory.appendingPathComponent("config.toml")
            try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)

            // CC Switch syncs MCP entries separately after a provider switch.
            // Preserve the currently enabled live MCP sections here as well.
            let liveConfig = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            config = replacingMCPSections(in: config, with: mcpSections(from: liveConfig))

            if target.category == "official", unifyHistory {
                config = injectingUnifiedOfficialRoute(into: config)
            }

            if target.category != "official", preserveOfficialAuth {
                if let authObject = auth as? [String: Any],
                   let token = authObject["OPENAI_API_KEY"] as? String, !token.isEmpty {
                    config = injectingBearerToken(token, into: config)
                }
            } else {
                let authData = try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys])
                try authData.write(to: authURL, options: .atomic)
            }
            try Data(config.utf8).write(to: configURL, options: .atomic)
        }

        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw switchError("CC Switch 数据库正忙")
        }
        var committed = false
        defer { if !committed { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) } }
        try execute(database, sql: "UPDATE providers SET is_current = 0 WHERE app_type = 'codex'")
        try execute(database, sql: "UPDATE providers SET is_current = 1 WHERE id = ? AND app_type = 'codex'", binding: providerID)
        guard sqlite3_changes(database) == 1 else { throw switchError("未能选中 Provider") }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw switchError("无法保存 Provider 切换")
        }
        committed = true

        appSettings["currentProviderCodex"] = providerID
        let settingsData = try JSONSerialization.data(withJSONObject: appSettings, options: [.prettyPrinted, .sortedKeys])
        try settingsData.write(to: settingsURL, options: .atomic)
    }

    private struct SwitchTarget {
        let settingsConfig: String
        let category: String?
    }

    private static func loadSwitchTarget(_ id: String, database: OpaquePointer) -> SwitchTarget? {
        var statement: OpaquePointer?
        let sql = "SELECT settings_config, category FROM providers WHERE id = ? AND app_type = 'codex' LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let settingsText = sqlite3_column_text(statement, 0) else { return nil }
        return SwitchTarget(
            settingsConfig: String(cString: settingsText),
            category: sqlite3_column_text(statement, 1).map { String(cString: $0) }
        )
    }

    private static func proxyTakeoverIsActive(_ database: OpaquePointer) -> Bool {
        let sql = "SELECT EXISTS(SELECT 1 FROM proxy_config WHERE app_type = 'codex' AND (live_takeover_active = 1 OR enabled = 1)) OR EXISTS(SELECT 1 FROM proxy_live_backup WHERE app_type = 'codex')"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) != 0
    }

    private static func execute(_ database: OpaquePointer, sql: String, binding: String? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw switchError("数据库写入准备失败") }
        defer { sqlite3_finalize(statement) }
        if let binding { sqlite3_bind_text(statement, 1, binding, -1, sqliteTransient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw switchError("数据库写入失败") }
    }

    private static func mcpSections(from config: String) -> String {
        var collecting = false
        var lines: [String] = []
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                collecting = trimmed == "[mcp_servers]" || trimmed.hasPrefix("[mcp_servers.")
            }
            if collecting { lines.append(line) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingMCPSections(in config: String, with replacement: String) -> String {
        var skipping = false
        var lines: [String] = []
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                skipping = trimmed == "[mcp_servers]" || trimmed.hasPrefix("[mcp_servers.")
            }
            if !skipping { lines.append(line) }
        }
        var result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !replacement.isEmpty { result += "\n\n" + replacement }
        return result + "\n"
    }

    private static func injectingUnifiedOfficialRoute(into config: String) -> String {
        if config.range(of: #"(?m)^\s*model_provider\s*="# , options: .regularExpression) != nil { return config }
        if config.contains("[model_providers.custom]") { return config }
        return "model_provider = \"custom\"\n" + config.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" +
            "[model_providers.custom]\nname = \"OpenAI\"\nrequires_openai_auth = true\nsupports_websockets = true\nwire_api = \"responses\"\n"
    }

    private static func injectingBearerToken(_ token: String, into config: String) -> String {
        let escaped = token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let line = "experimental_bearer_token = \"\(escaped)\""
        if config.range(of: #"(?m)^\s*experimental_bearer_token\s*="# , options: .regularExpression) != nil {
            return config.replacingOccurrences(of: #"(?m)^\s*experimental_bearer_token\s*=.*$"#, with: line, options: .regularExpression)
        }
        guard let header = config.range(of: #"(?m)^\[model_providers\.[^\]]+\]\s*$"#, options: .regularExpression) else {
            return config + "\n" + line + "\n"
        }
        return config[..<header.upperBound] + "\n" + line + config[header.upperBound...]
    }

    private static func switchError(_ message: String) -> NSError {
        NSError(domain: "CCSwitchBalanceBar.ProviderSwitch", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct BalanceQuery {
    let url: String
    let websiteURL: URL?
    let apiKey: String
    let intervalMinutes: Int
    let timeoutSeconds: Int
    let isRightCode: Bool

    static func make(settingsText: String, metaText: String, websiteText: String?) -> BalanceQuery? {
        guard let settings = jsonObject(settingsText),
              let meta = jsonObject(metaText),
              let script = usageScript(from: meta),
              boolValue(script["enabled"]) == true,
              let code = script["code"] as? String else { return nil }

        let apiKey = findString(in: script, names: ["apiKey", "api_key", "key"]) ??
            findString(in: settings, names: ["OPENAI_API_KEY", "apiKey", "api_key", "key", "token"])
        let baseURL = findString(in: script, names: ["baseUrl", "base_url", "url"]) ??
            findString(in: settings, names: ["baseUrl", "base_url", "url"]) ??
            tomlBaseURL(in: settings["config"] as? String)
        guard let apiKey, !apiKey.isEmpty, let baseURL, !baseURL.isEmpty else { return nil }

        guard let template = capture("url\\s*:\\s*[`\\\"]([^`\\\"]+)", in: code) else { return nil }
        let url = template.replacingOccurrences(of: "{{baseUrl}}", with: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let interval = (script["autoQueryInterval"] as? NSNumber)?.intValue ?? 30
        let timeout = (script["timeout"] as? NSNumber)?.intValue ?? 15
        let configuredWebsite = websiteText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let websiteURL = configuredWebsite.flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? URL(string: baseURL)
        return BalanceQuery(url: url, websiteURL: websiteURL, apiKey: apiKey, intervalMinutes: interval, timeoutSeconds: timeout, isRightCode: url.contains("/account/summary"))
    }

    private static func usageScript(from meta: [String: Any]) -> [String: Any]? {
        if let script = meta["usage_script"] as? [String: Any] { return script }
        if let scriptText = meta["usage_script"] as? String { return jsonObject(scriptText) }
        return nil
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func findString(in value: Any, names: [String]) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if names.contains(key), let string = nested as? String, !string.isEmpty { return string }
            }
            for nested in dictionary.values {
                if let result = findString(in: nested, names: names) { return result }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let result = findString(in: nested, names: names) { return result }
            }
        }
        return nil
    }

    private static func tomlBaseURL(in config: String?) -> String? {
        guard let config else { return nil }
        return capture("base_url\\s*=\\s*\\\"([^\\\"]+)\\\"", in: config)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        default: return nil
        }
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
