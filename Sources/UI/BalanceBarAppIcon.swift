import AppKit

enum BalanceBarAppIcon {
    /// Returns the system-rendered app icon, including the fallback on older macOS.
    static func image() -> NSImage {
        let systemIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let image = systemIcon.copy() as! NSImage
        // NSWorkspace defaults to 32 pt. Allow larger views that only scale down.
        image.size = NSSize(width: 512, height: 512)
        return image
    }
}
