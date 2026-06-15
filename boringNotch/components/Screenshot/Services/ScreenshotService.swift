//
//  ScreenshotService.swift
//  boringNotch
//
//  Created by boringNotch on 2025.
//

import AppKit
import Foundation

@MainActor
final class ScreenshotService {
    static let shared = ScreenshotService()

    private let screenshotDir: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        screenshotDir = appSupport.appendingPathComponent("boringNotch/Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
    }

    func checkScreenRecordingPermission() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        if let image = CGWindowListCreateImage(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            .optionOnScreenOnly,
            kCGNullWindowID,
            .boundsIgnoreFraming
        ) {
            return image.width > 1 && image.height > 1
        }
        return false
    }

    func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }

    func captureFullScreen() -> CGImage? {
        guard let displayID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return CGDisplayCreateImage(displayID)
    }

    func captureFullScreenToFile() -> URL? {
        guard let image = captureFullScreen() else { return nil }
        return saveImage(image)
    }

    func captureFullScreenToClipboard() {
        guard let image = captureFullScreen() else { return }
        let nsImage = NSImage(cgImage: image, size: NSScreen.main?.frame.size ?? .zero)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
    }

    func captureArea(cropRect: CGRect) -> URL? {
        guard let fullImage = captureFullScreen() else { return nil }
        let imageRect = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        let clampedRect = cropRect.intersection(imageRect)
        guard !clampedRect.isEmpty, clampedRect.width > 0, clampedRect.height > 0 else { return nil }
        guard let cropped = fullImage.cropping(to: clampedRect) else { return nil }
        return saveImage(cropped)
    }

    func captureAreaToClipboard(cropRect: CGRect) {
        guard let fullImage = captureFullScreen() else { return }
        let imageRect = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        let clampedRect = cropRect.intersection(imageRect)
        guard !clampedRect.isEmpty, clampedRect.width > 0, clampedRect.height > 0 else { return }
        guard let cropped = fullImage.cropping(to: clampedRect) else { return }
        let nsImage = NSImage(cgImage: cropped, size: NSSize(width: clampedRect.width, height: clampedRect.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
    }

    func captureWindow(windowID: CGWindowID) -> URL? {
        guard let image = CGWindowListCreateImage(
            CGRect.null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }
        return saveImage(image)
    }

    func captureWindowToClipboard(windowID: CGWindowID) {
        guard let image = CGWindowListCreateImage(
            CGRect.null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
    }

    func listWindows() -> [(id: CGWindowID, name: String, app: String)] {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [(id: CGWindowID, name: String, app: String)] = []
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let ownerName = info[kCGWindowOwnerName as String] as? String else { continue }
            let name = (info[kCGWindowName as String] as? String) ?? ""
            if ownerName != "boringNotch" {
                result.append((id: id, name: name.isEmpty ? ownerName : name, app: ownerName))
            }
        }
        return result
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
