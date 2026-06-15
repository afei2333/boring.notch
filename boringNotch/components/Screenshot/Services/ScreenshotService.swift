//
//  ScreenshotService.swift
//  boringNotch
//
//  Created by boringNotch on 2025.
//

import AppKit
import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenshotService {
    static let shared = ScreenshotService()

    private let screenshotDir: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        screenshotDir = appSupport.appendingPathComponent("boringNotch/Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
    }

    // MARK: - Permission

    func checkScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Capture (ScreenCaptureKit)
    //
    // The legacy CoreGraphics capture APIs (`CGDisplayCreateImage`,
    // `CGWindowListCreateImage`) are deprecated and on recent macOS return only
    // the desktop wallpaper (no windows) or nil. ScreenCaptureKit is the
    // supported path and actually captures window content.

    private var ownBundleID: String? { Bundle.main.bundleIdentifier }

    /// Full capture of one display, excluding our own app's windows (so the open
    /// notch / overlays never appear). Returns a native-resolution image.
    func captureDisplay(displayID: CGDirectDisplayID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else { return nil }

            let ourApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
            let filter = SCContentFilter(display: scDisplay, excludingApplications: ourApps, exceptingWindows: [])

            let scale = screenScale(forDisplayID: displayID) ?? 2.0
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(scDisplay.width) * scale)
            config.height = Int(CGFloat(scDisplay.height) * scale)
            config.showsCursor = false
            config.ignoreShadowsDisplay = true

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            NSLog("[Screenshot] captureDisplay failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Capture a single window by ID (desktop-independent), at native resolution.
    func captureWindowImage(windowID: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)

            let scale = scaleForWindowFrame(scWindow.frame)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(scWindow.frame.width * scale))
            config.height = max(1, Int(scWindow.frame.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            NSLog("[Screenshot] captureWindowImage failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Window hit-testing (metadata only — still valid on modern macOS)

    /// The frontmost normal window (excluding our own) whose bounds contain the
    /// given point. The point is in CoreGraphics global coordinates (top-left
    /// origin, y growing downward) — the same space `kCGWindowBounds` uses.
    /// Returns the window's ID and its bounds in that same coordinate space.
    func window(at cgPoint: CGPoint) -> (id: CGWindowID, cgBounds: CGRect)? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // CGWindowListCopyWindowInfo returns windows front-to-back, so the first
        // match under the cursor is the topmost one.
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName != "boringNotch",
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 1, bounds.height > 1
            else { continue }
            if bounds.contains(cgPoint) {
                return (id: id, cgBounds: bounds)
            }
        }
        return nil
    }

    // MARK: - Image helpers

    /// Crops a captured image to the given pixel rect (top-left origin),
    /// clamped to the image bounds.
    func cropImage(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clampedRect = rect.intersection(imageRect).integral
        guard !clampedRect.isEmpty, clampedRect.width > 0, clampedRect.height > 0 else { return nil }
        return image.cropping(to: clampedRect)
    }

    func saveToFile(_ image: CGImage) -> URL? {
        return saveImage(image)
    }

    func copyToClipboard(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
    }

    // MARK: - Private

    private func screenScale(forDisplayID displayID: CGDirectDisplayID) -> CGFloat? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }?.backingScaleFactor
    }

    /// Backing scale of the display that holds a window (frame is in top-left
    /// global points), defaulting to 2.0.
    private func scaleForWindowFrame(_ frame: CGRect) -> CGFloat {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let akCenter = CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(akCenter, $0.frame, false) } ?? NSScreen.main
        return screen?.backingScaleFactor ?? 2.0
    }

    private func saveImage(_ image: CGImage) -> URL? {
        let url = makeOutputURL()
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
            return url
        }
        return nil
    }

    private func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "Screenshot \(timestamp).png"
        return screenshotDir.appendingPathComponent(filename)
    }
}

#if DEBUG
// MARK: - Temporary capture self-test harness (DEBUG only)
// Drives the exact production capture methods from a shell-written command file
// so screenshot output can be verified without GUI interaction. Remove after use.
@MainActor
final class ScreenshotSelfTest {
    static let shared = ScreenshotSelfTest()
    private var timer: Timer?

    private var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("boringNotch", isDirectory: true)
    }
    private var cmdURL: URL { baseDir.appendingPathComponent("selftest_cmd.txt") }
    private var outURL: URL { baseDir.appendingPathComponent("selftest_out.txt") }
    private var heartbeat = 0

    func start() {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? "started \(Date())".write(to: baseDir.appendingPathComponent("selftest_started.txt"), atomically: true, encoding: .utf8)
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        heartbeat += 1
        if heartbeat % 10 == 0 {
            try? "hb=\(heartbeat) \(Date())".write(to: baseDir.appendingPathComponent("selftest_hb.txt"), atomically: true, encoding: .utf8)
        }
        guard let cmd = try? String(contentsOf: cmdURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: cmdURL)
        let mode = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await run(mode) }
    }

    private func run(_ mode: String) async {
        let service = ScreenshotService.shared
        let loc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) } ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
        var out: [String] = []
        out.append("mode=\(mode)")
        out.append("mouseLoc=\(Int(loc.x)),\(Int(loc.y))")
        if let f = screen?.frame {
            out.append("chosenScreen=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) main=\(screen == NSScreen.main)")
        }

        switch mode {
        case "fullscreen":
            if let img = await service.captureDisplay(displayID: displayID), let url = service.saveToFile(img) {
                out.append("RESULT=ok size=\(img.width)x\(img.height) path=\(url.lastPathComponent)")
            } else { out.append("RESULT=FAIL") }
        case "area":
            if let img = await service.captureDisplay(displayID: displayID), let f = screen?.frame {
                let sx = CGFloat(img.width) / f.width, sy = CGFloat(img.height) / f.height
                let pts = CGRect(x: f.width * 0.25, y: f.height * 0.25, width: f.width * 0.5, height: f.height * 0.5)
                let scaled = CGRect(x: pts.minX * sx, y: pts.minY * sy, width: pts.width * sx, height: pts.height * sy)
                let flipped = CGRect(x: scaled.minX, y: CGFloat(img.height) - scaled.minY - scaled.height, width: scaled.width, height: scaled.height)
                if let c = service.cropImage(img, to: flipped), let url = service.saveToFile(c) {
                    out.append("RESULT=ok full=\(img.width)x\(img.height) crop=\(c.width)x\(c.height) path=\(url.lastPathComponent)")
                } else { out.append("RESULT=FAIL crop") }
            } else { out.append("RESULT=FAIL") }
        case "window":
            let cg = CGEvent(source: nil)?.location ?? .zero
            out.append("cursorCG=\(Int(cg.x)),\(Int(cg.y))")
            if let win = service.window(at: cg) {
                if let img = await service.captureWindowImage(windowID: win.id), let url = service.saveToFile(img) {
                    out.append("RESULT=ok winID=\(win.id) cgBounds=\(Int(win.cgBounds.width))x\(Int(win.cgBounds.height)) img=\(img.width)x\(img.height) path=\(url.lastPathComponent)")
                } else { out.append("RESULT=FAIL nil-window-image") }
            } else { out.append("RESULT=FAIL no-window-under-cursor") }
        default:
            out.append("RESULT=FAIL unknown-mode")
        }

        try? out.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
    }
}
#endif
