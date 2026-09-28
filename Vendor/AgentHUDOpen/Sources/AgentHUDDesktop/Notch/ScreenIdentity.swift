import AppKit
import AgentHUDCore

/// Names a display so its HUD placement survives unplugging, sleeping and renumbering.
///
/// `NSScreen`'s display ID is reassigned when displays come and go, so it cannot key stored settings.
/// The display's UUID is stable for the same physical panel; a display that has none at all (rare, and
/// possible for virtual displays) falls back to its ID, which at least holds for the current session.
enum ScreenIdentity {
    /// Looking a display's UUID up is a system call, and SwiftUI asks for it on every pass over the settings
    /// pane — including while a slider is being dragged. The answer only changes when displays do.
    @MainActor private static var keys: [CGDirectDisplayID: String] = [:]

    @MainActor
    static func forgetKeys() { keys.removeAll(keepingCapacity: true) }

    @MainActor
    static func key(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "screen:unknown"
        }
        let id = CGDirectDisplayID(number.uint32Value)
        if let hit = keys[id] { return hit }
        let key: String
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            key = CFUUIDCreateString(nil, uuid) as String
        } else {
            key = "display:\(id)"
        }
        keys[id] = key
        return key
    }

    /// The menu bar height of a screen, which every logo-mode size is a share of.
    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        max(22, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    static func name(for screen: NSScreen) -> String {
        let name = screen.localizedName
        return name.isEmpty ? L10n.text("显示器", "Display") : name
    }

    static func hasNotch(_ screen: NSScreen) -> Bool { screen.safeAreaInsets.top > 0 }

    /// The notch's own size, for previews that should show this machine's shape rather than a stand-in.
    static func notchSize(of screen: NSScreen) -> CGSize? {
        guard hasNotch(screen) else { return nil }
        let frame = screen.frame
        let left = screen.auxiliaryTopLeftArea?.maxX ?? (frame.midX - NotchGeometry.fallbackWidth / 2)
        let right = screen.auxiliaryTopRightArea?.minX ?? (frame.midX + NotchGeometry.fallbackWidth / 2)
        return CGSize(width: max(1, right - left), height: screen.safeAreaInsets.top)
    }

    /// The stored placement for a screen, or the default its hardware deserves.
    @MainActor
    static func placement(for screen: NSScreen, in settings: AgentHUDCore.Settings) -> ScreenPlacement {
        settings.placement(on: key(for: screen), hasNotch: hasNotch(screen))
    }

    /// The screen the pointer is on, which is the one alerts belong on.
    static func underPointer(_ screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(point) } ?? screens.first
    }
}
