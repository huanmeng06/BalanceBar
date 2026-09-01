import AppKit
import ApplicationServices

enum CCSwitchBridgeAvailability: Equatable {
    case ready
    case accessibilityPermissionRequired
    case unavailable
}

enum CCSwitchSeamlessSwitchState: Equatable {
    case disabled
    case enabledPermissionMissing
    case enabledReady
    case enabledUnavailable

    static func make(
        enabled: Bool,
        availability: CCSwitchBridgeAvailability
    ) -> Self {
        guard enabled else { return .disabled }
        switch availability {
        case .ready:
            return .enabledReady
        case .accessibilityPermissionRequired:
            return .enabledPermissionMissing
        case .unavailable:
            return .enabledUnavailable
        }
    }
}

struct CCSwitchProviderSwitchTarget: Equatable {
    let providerID: String
    let providerName: String
    let appType: String
}

enum CCSwitchAccessibilityError: LocalizedError, Equatable {
    case permissionRequired
    case ccSwitchNotRunning
    case extrasMenuBarUnavailable
    case statusItemUnavailable
    case menuDidNotOpen
    case sectionUnavailable(String)
    case providerNotFound(String)
    case duplicateProviderName(String)
    case providerDisabled(String)
    case providerNotPressable(String)
    case pressFailed(action: String, code: String)
    case verificationTimedOut
    case unsupportedAppType(String)
    case attributeUnavailable(String)
    case invalidUIElement(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "BalanceBar needs Accessibility permission to switch CC Switch without restarting it."
        case .ccSwitchNotRunning:
            return "CC Switch is not running."
        case .extrasMenuBarUnavailable:
            return "CC Switch did not expose its menu bar through Accessibility."
        case .statusItemUnavailable:
            return "CC Switch's menu bar item could not be found."
        case .menuDidNotOpen:
            return "CC Switch's menu did not open through Accessibility."
        case .sectionUnavailable(let section):
            return "The CC Switch provider section \"\(section)\" is unavailable."
        case .providerNotFound(let provider):
            return "The CC Switch provider \"\(provider)\" could not be found in its menu."
        case .duplicateProviderName(let provider):
            return "CC Switch has multiple providers named \"\(provider)\"; the switch was cancelled for safety."
        case .providerDisabled(let provider):
            return "The CC Switch provider \"\(provider)\" is disabled."
        case .providerNotPressable(let provider):
            return "The CC Switch provider \"\(provider)\" cannot be pressed through Accessibility."
        case .pressFailed(let action, let code):
            return "CC Switch Accessibility action \"\(action)\" failed (\(code))."
        case .verificationTimedOut:
            return "CC Switch did not verify the provider switch before the timeout."
        case .unsupportedAppType(let appType):
            return "CC Switch app type \"\(appType)\" is not supported."
        case .attributeUnavailable(let attribute):
            return "CC Switch Accessibility attribute \"\(attribute)\" is unavailable."
        case .invalidUIElement(let context):
            return "CC Switch returned an invalid Accessibility element (\(context))."
        }
    }
}

protocol CCSwitchAccessibilityPermissionControlling: AnyObject {
    var isTrusted: Bool { get }
    func requestIfNeeded()
}

final class AccessibilityPermissionController: CCSwitchAccessibilityPermissionControlling {
    private let lock = NSLock()
    private var hasPrompted = false

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestIfNeeded() {
        guard !isTrusted else { return }
        lock.lock()
        guard !hasPrompted else {
            lock.unlock()
            return
        }
        hasPrompted = true
        lock.unlock()

        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

final class CCSwitchAccessibilityElement {
    fileprivate let rawElement: AXUIElement?
    let testIdentifier: String?

    init(rawElement: AXUIElement) {
        self.rawElement = rawElement
        self.testIdentifier = nil
    }

    init(testIdentifier: String) {
        self.rawElement = nil
        self.testIdentifier = testIdentifier
    }
}

struct CCSwitchAccessibilityRunningApplication: Equatable {
    let processIdentifier: pid_t
    let isActive: Bool
}

protocol CCSwitchAccessibilityRuntime {
    var isTrusted: Bool { get }
    func requestPermission()
    var frontmostProcessIdentifier: pid_t? { get }
    func runningApplication(bundleIdentifier: String) -> CCSwitchAccessibilityRunningApplication?
    func applicationElement(processIdentifier: pid_t) -> CCSwitchAccessibilityElement
    func copyElement(attribute: String, from element: CCSwitchAccessibilityElement) throws -> CCSwitchAccessibilityElement
    func copyElements(attribute: String, from element: CCSwitchAccessibilityElement) throws -> [CCSwitchAccessibilityElement]
    func copyString(attribute: String, from element: CCSwitchAccessibilityElement) throws -> String?
    func copyBool(attribute: String, from element: CCSwitchAccessibilityElement) throws -> Bool
    func actionNames(of element: CCSwitchAccessibilityElement) throws -> Set<String>
    func performAction(_ action: String, on element: CCSwitchAccessibilityElement) throws
    @discardableResult
    func activate(processIdentifier: pid_t) -> Bool
}

final class SystemCCSwitchAccessibilityRuntime: CCSwitchAccessibilityRuntime {
    private let permissionController: CCSwitchAccessibilityPermissionControlling

    init(
        permissionController: CCSwitchAccessibilityPermissionControlling = AccessibilityPermissionController()
    ) {
        self.permissionController = permissionController
    }

    var isTrusted: Bool { permissionController.isTrusted }

    func requestPermission() {
        permissionController.requestIfNeeded()
    }

    var frontmostProcessIdentifier: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func runningApplication(bundleIdentifier: String) -> CCSwitchAccessibilityRunningApplication? {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else {
            return nil
        }
        return CCSwitchAccessibilityRunningApplication(
            processIdentifier: application.processIdentifier,
            isActive: application.isActive
        )
    }

    func applicationElement(processIdentifier: pid_t) -> CCSwitchAccessibilityElement {
        let rawElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(rawElement, 1.0)
        return CCSwitchAccessibilityElement(rawElement: rawElement)
    }

    func copyElement(
        attribute: String,
        from element: CCSwitchAccessibilityElement
    ) throws -> CCSwitchAccessibilityElement {
        let value = try copyValue(attribute: attribute, from: element)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw CCSwitchAccessibilityError.invalidUIElement(attribute)
        }
        let rawElement = unsafeBitCast(value, to: AXUIElement.self)
        return CCSwitchAccessibilityElement(rawElement: rawElement)
    }

    func copyElements(
        attribute: String,
        from element: CCSwitchAccessibilityElement
    ) throws -> [CCSwitchAccessibilityElement] {
        let value = try copyValue(attribute: attribute, from: element)
        guard let array = value as? NSArray else {
            throw CCSwitchAccessibilityError.invalidUIElement(attribute)
        }
        let values: [AXUIElement] = try array.map { item in
            let itemValue = item as CFTypeRef
            guard CFGetTypeID(itemValue) == AXUIElementGetTypeID() else {
                throw CCSwitchAccessibilityError.invalidUIElement(attribute)
            }
            return unsafeBitCast(itemValue, to: AXUIElement.self)
        }
        return values.map(CCSwitchAccessibilityElement.init(rawElement:))
    }

    func copyString(
        attribute: String,
        from element: CCSwitchAccessibilityElement
    ) throws -> String? {
        let value = try copyValue(attribute: attribute, from: element)
        guard let string = value as? String else {
            throw CCSwitchAccessibilityError.invalidUIElement(attribute)
        }
        return string
    }

    func copyBool(
        attribute: String,
        from element: CCSwitchAccessibilityElement
    ) throws -> Bool {
        let value = try copyValue(attribute: attribute, from: element)
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        throw CCSwitchAccessibilityError.invalidUIElement(attribute)
    }

    func actionNames(of element: CCSwitchAccessibilityElement) throws -> Set<String> {
        guard let rawElement = element.rawElement else {
            throw CCSwitchAccessibilityError.invalidUIElement("action names")
        }
        var names: CFArray?
        let error = AXUIElementCopyActionNames(rawElement, &names)
        guard error == .success, let names else {
            throw CCSwitchAccessibilityError.attributeUnavailable("AXActions")
        }
        let values = (names as NSArray).compactMap { $0 as? String }
        return Set(values)
    }

    func performAction(
        _ action: String,
        on element: CCSwitchAccessibilityElement
    ) throws {
        guard let rawElement = element.rawElement else {
            throw CCSwitchAccessibilityError.invalidUIElement("action \(action)")
        }
        let error = AXUIElementPerformAction(rawElement, action as CFString)
        guard error == .success else {
            throw CCSwitchAccessibilityError.pressFailed(
                action: action,
                code: String(describing: error)
            )
        }
    }

    @discardableResult
    func activate(processIdentifier: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: processIdentifier)?.activate(options: []) ?? false
    }

    private func copyValue(
        attribute: String,
        from element: CCSwitchAccessibilityElement
    ) throws -> CFTypeRef {
        guard let rawElement = element.rawElement else {
            throw CCSwitchAccessibilityError.invalidUIElement(attribute)
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(rawElement, attribute as CFString, &value)
        guard error == .success, let value else {
            throw CCSwitchAccessibilityError.attributeUnavailable(attribute)
        }
        return value
    }
}

final class CCSwitchAccessibilityProviderSwitchBridge: CCSwitchProviderSwitching {
    static let ccSwitchBundleIdentifier = "com.ccswitch.desktop"
    static let menuTransitionTimeout: TimeInterval = 0.75
    static let menuPollingInterval: TimeInterval = 0.02

    private let repository: CCSwitchRepository
    private let runtime: CCSwitchAccessibilityRuntime

    init(
        repository: CCSwitchRepository,
        permissionController: CCSwitchAccessibilityPermissionControlling = AccessibilityPermissionController(),
        runtime: CCSwitchAccessibilityRuntime? = nil
    ) {
        self.repository = repository
        self.runtime = runtime ?? SystemCCSwitchAccessibilityRuntime(
            permissionController: permissionController
        )
    }

    var availability: CCSwitchBridgeAvailability {
        runtime.isTrusted ? .ready : .accessibilityPermissionRequired
    }

    func switchProvider(target: CCSwitchProviderSwitchTarget) throws {
        guard runtime.isTrusted else {
            runtime.requestPermission()
            throw CCSwitchAccessibilityError.permissionRequired
        }

        let sectionPrefix = try Self.sectionPrefix(for: target.appType)
        let choices = repository.loadChoices(appType: target.appType)
        let matchingChoices = choices.filter { $0.name == target.providerName }
        guard matchingChoices.count == 1 else {
            if matchingChoices.count > 1 {
                throw CCSwitchAccessibilityError.duplicateProviderName(target.providerName)
            }
            throw CCSwitchAccessibilityError.providerNotFound(target.providerName)
        }
        guard matchingChoices[0].id == target.providerID else {
            throw CCSwitchAccessibilityError.providerNotFound(target.providerName)
        }

        guard let running = runtime.runningApplication(
            bundleIdentifier: Self.ccSwitchBundleIdentifier
        ) else {
            throw CCSwitchAccessibilityError.ccSwitchNotRunning
        }
        let previousFrontmostPID = runtime.frontmostProcessIdentifier
        let application = runtime.applicationElement(
            processIdentifier: running.processIdentifier
        )

        defer {
            restorePreviousFrontmostApplication(
                previousPID: previousFrontmostPID,
                ccSwitchPID: running.processIdentifier
            )
        }

        let extrasMenuBar: CCSwitchAccessibilityElement
        do {
            extrasMenuBar = try runtime.copyElement(
                attribute: kAXExtrasMenuBarAttribute as String,
                from: application
            )
        } catch {
            throw CCSwitchAccessibilityError.extrasMenuBarUnavailable
        }

        guard let statusItem = try findStatusItem(in: extrasMenuBar) else {
            throw CCSwitchAccessibilityError.statusItemUnavailable
        }

        try openMenu(from: statusItem)
        guard let rootMenu = waitForRootMenu(from: statusItem) else {
            throw CCSwitchAccessibilityError.menuDidNotOpen
        }

        guard let section = try findSection(
            withPrefix: sectionPrefix,
            in: rootMenu
        ) else {
            throw CCSwitchAccessibilityError.sectionUnavailable(sectionPrefix)
        }
        guard let providerMenu = try menu(for: section) else {
            throw CCSwitchAccessibilityError.sectionUnavailable(sectionPrefix)
        }
        guard let providerItem = try findProviderItem(
            named: target.providerName,
            in: providerMenu
        ) else {
            throw CCSwitchAccessibilityError.providerNotFound(target.providerName)
        }

        if stringValue(
            attribute: kAXTitleAttribute as String,
            from: providerItem
        ) == target.providerName + " ⛔" {
            throw CCSwitchAccessibilityError.providerDisabled(target.providerName)
        }

        let enabled = try runtime.copyBool(
            attribute: kAXEnabledAttribute as String,
            from: providerItem
        )
        guard enabled else {
            throw CCSwitchAccessibilityError.providerDisabled(target.providerName)
        }

        let actions = try runtime.actionNames(of: providerItem)
        guard actions.contains(kAXPressAction as String) else {
            throw CCSwitchAccessibilityError.providerNotPressable(target.providerName)
        }
        try runtime.performAction(kAXPressAction as String, on: providerItem)

        SwitchLog.write(
            "[ccswitch.ax] AXPress submitted; app_type=\(target.appType); provider_id=\(target.providerID)",
            category: "ccswitch.ax"
        )
    }

    static func sectionPrefix(for appType: String) throws -> String {
        switch appType {
        case "codex":
            return "Codex · "
        case "claude":
            return "Claude · "
        default:
            throw CCSwitchAccessibilityError.unsupportedAppType(appType)
        }
    }

    private func findStatusItem(
        in extrasMenuBar: CCSwitchAccessibilityElement
    ) throws -> CCSwitchAccessibilityElement? {
        let children = try runtime.copyElements(
            attribute: kAXChildrenAttribute as String,
            from: extrasMenuBar
        )
        let candidates = children.filter { element in
            let role = stringValue(
                attribute: kAXRoleAttribute as String,
                from: element
            )
            let actions = (try? runtime.actionNames(of: element)) ?? []
            return role == (kAXMenuBarItemRole as String)
                || actions.contains(kAXPressAction as String)
                || actions.contains(kAXShowMenuAction as String)
        }
        let namedCandidates = candidates.filter { element in
            let labels = [
                stringValue(attribute: kAXTitleAttribute as String, from: element),
                stringValue(attribute: kAXDescriptionAttribute as String, from: element)
            ].compactMap { $0?.lowercased() }
            return labels.contains { $0.contains("cc switch") }
        }
        if namedCandidates.count == 1 {
            return namedCandidates[0]
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private func openMenu(
        from element: CCSwitchAccessibilityElement
    ) throws {
        let actions = try runtime.actionNames(of: element)
        if actions.contains(kAXPressAction as String) {
            do {
                try runtime.performAction(kAXPressAction as String, on: element)
                return
            } catch {
                guard actions.contains(kAXShowMenuAction as String) else {
                    throw error
                }
                try runtime.performAction(kAXShowMenuAction as String, on: element)
                return
            }
        }
        if actions.contains(kAXShowMenuAction as String) {
            try runtime.performAction(kAXShowMenuAction as String, on: element)
            return
        }
        throw CCSwitchAccessibilityError.statusItemUnavailable
    }

    private func waitForRootMenu(
        from statusItem: CCSwitchAccessibilityElement
    ) -> CCSwitchAccessibilityElement? {
        waitUntil(timeout: Self.menuTransitionTimeout) {
            do {
                return try self.menu(for: statusItem)
            } catch {
                return nil
            }
        }
    }

    private func menu(
        for element: CCSwitchAccessibilityElement
    ) throws -> CCSwitchAccessibilityElement? {
        do {
            return try runtime.copyElement(
                attribute: "AXMenu",
                from: element
            )
        } catch {
            // Some NSStatusItem trees expose the menu as an AXMenu child
            // instead of through the AXMenu attribute.
        }
        let children = (try? runtime.copyElements(
            attribute: kAXChildrenAttribute as String,
            from: element
        )) ?? []
        return children.first { child in
            stringValue(
                attribute: kAXRoleAttribute as String,
                from: child
            ) == (kAXMenuRole as String)
        }
    }

    private func findSection(
        withPrefix prefix: String,
        in rootMenu: CCSwitchAccessibilityElement
    ) throws -> CCSwitchAccessibilityElement? {
        let matches = try descendants(of: rootMenu).filter { element in
            guard let title = stringValue(
                attribute: kAXTitleAttribute as String,
                from: element
            ), title.hasPrefix(prefix) else { return false }
            if (try? runtime.copyBool(
                attribute: kAXHiddenAttribute as String,
                from: element
            )) == true {
                return false
            }
            if let enabled = try? runtime.copyBool(
                attribute: kAXEnabledAttribute as String,
                from: element
            ), !enabled {
                return false
            }
            do {
                return try menu(for: element) != nil
            } catch {
                return false
            }
        }
        guard matches.count <= 1 else { return nil }
        return matches.first
    }

    private func findProviderItem(
        named providerName: String,
        in providerMenu: CCSwitchAccessibilityElement
    ) throws -> CCSwitchAccessibilityElement? {
        let disabledSuffix = " ⛔"
        let matches = try descendants(of: providerMenu).filter { element in
            guard let title = stringValue(
                attribute: kAXTitleAttribute as String,
                from: element
            ) else { return false }
            return title == providerName || title == providerName + disabledSuffix
        }
        guard matches.count <= 1 else {
            throw CCSwitchAccessibilityError.duplicateProviderName(providerName)
        }
        return matches.first
    }

    private func stringValue(
        attribute: String,
        from element: CCSwitchAccessibilityElement
    ) -> String? {
        do {
            return try runtime.copyString(attribute: attribute, from: element)
        } catch {
            return nil
        }
    }

    private func descendants(
        of root: CCSwitchAccessibilityElement,
        depth: Int = 0
    ) throws -> [CCSwitchAccessibilityElement] {
        guard depth < 8 else { return [] }
        let children = (try? runtime.copyElements(
            attribute: kAXChildrenAttribute as String,
            from: root
        )) ?? []
        var result = children
        for child in children {
            result.append(contentsOf: try descendants(of: child, depth: depth + 1))
        }
        return result
    }

    private func waitUntil<T>(
        timeout: TimeInterval,
        _ probe: () -> T?
    ) -> T? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            if let value = probe() {
                return value
            }
            guard Date() < deadline else { return nil }
            Thread.sleep(forTimeInterval: Self.menuPollingInterval)
        } while true
    }

    private func restorePreviousFrontmostApplication(
        previousPID: pid_t?,
        ccSwitchPID: pid_t
    ) {
        guard let previousPID,
              previousPID != ccSwitchPID,
              runtime.frontmostProcessIdentifier == ccSwitchPID else {
            return
        }
        _ = runtime.activate(processIdentifier: previousPID)
    }
}
