//
//  ScreenshotViewModel.swift
//  boringNotch
//
//  Created by boringNotch on 2025.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum ScreenshotCaptureMode: Int, CaseIterable, Identifiable {
    case fullscreen = 0
    case area = 1
    case window = 2
    case screenRecording = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fullscreen: return "全屏"
        case .area: return "区域"
        case .window: return "窗口"
        case .screenRecording: return "录屏"
        }
    }

    var icon: String {
        switch self {
        case .fullscreen: return "rectangle.expand.vertical"
        case .area: return "crop"
        case .window: return "macwindow"
        case .screenRecording: return "video"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .screenRecording: return false
        default: return true
        }
    }
}

enum ScreenshotDelayOption: Int, CaseIterable, Identifiable {
    case none = 0
    case three = 3
    case five = 5
    case ten = 10

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return "关"
        case .three: return "3s"
        case .five: return "5s"
        case .ten: return "10s"
        }
    }
}

enum ScreenshotOutputMode: Int, CaseIterable, Identifiable {
    case shelf = 0
    case clipboard = 1
    case file = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .shelf: return "暂存架"
        case .clipboard: return "剪贴板"
        case .file: return "文件"
        }
    }
}

@MainActor
final class ScreenshotViewModel: ObservableObject {
    static let shared = ScreenshotViewModel()

    @Published var isCapturing = false
    @Published var selectedCaptureMode: ScreenshotCaptureMode = .area
    @Published var selectedDelay: ScreenshotDelayOption = .none
    @Published var selectedOutput: ScreenshotOutputMode = .shelf
    @Published var hasPermission = false
    @Published var lastCapturedURL: URL?
    @Published var lastCapturedImage: NSImage?
    @Published var countdownRemaining: Int = 0

    private var countdownTask: Task<Void, Never>?

    private func debugLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dirURL = appSupport.appendingPathComponent("boringNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let logURL = dirURL.appendingPathComponent("screenshot_debug.log")
        
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                } else {
                    try? data.write(to: logURL)
                }
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
        NSLog(message)
    }

    private init() {
        refreshPermission()
    }

    func refreshPermission() {
        hasPermission = ScreenshotService.shared.checkScreenRecordingPermission()
    }

    func requestPermission() {
        ScreenshotService.shared.requestScreenRecordingPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPermission()
        }
    }

    func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true

        NotificationCenter.default.post(name: NSNotification.Name("closeBoringNotch"), object: nil)

        let delay = TimeInterval(selectedDelay.rawValue)

        Task { [weak self] in
            guard let self else { return }

            if delay > 0 {
                await self.runCountdown(seconds: self.selectedDelay.rawValue)
                guard !Task.isCancelled else {
                    await MainActor.run { self.isCapturing = false }
                    return
                }
            }

            switch self.selectedCaptureMode {
            case .fullscreen:
                await self.doFullscreenCapture()
            case .area:
                await self.doAreaCapture()
            case .window:
                await self.doWindowCapture()
            case .screenRecording:
                await MainActor.run { self.isCapturing = false }
            }
        }
    }

    /// The display the mouse cursor is currently on. Fullscreen / area captures
    /// target this screen, so the user grabs whatever monitor they are pointing
    /// at the instant the capture fires (multi-display aware). Pairing a delay
    /// with this lets the user move to the screen they want before it triggers.
    private var mouseScreen: NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) } ?? NSScreen.main
    }

    private func displayID(for screen: NSScreen?) -> CGDirectDisplayID {
        screen?.displayID ?? CGMainDisplayID()
    }

    private func doFullscreenCapture() async {
        let service = ScreenshotService.shared
        let targetScreen = mouseScreen

        guard let image = await service.captureDisplay(displayID: displayID(for: targetScreen)) else {
            await finishCapture(url: nil, image: nil)
            return
        }

        await deliver(image: image, service: service)
    }

    struct CropResult {
        let rect: CGRect
        let screen: NSScreen
        let image: CGImage
    }

    private func presentCropOverlays(screenCaptures: [NSScreen: CGImage]) async -> CropResult? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                
                var overlays: [CropOverlayWindow] = []
                var hasCompleted = false
                
                let onCompleteBlock: (CGRect?, NSScreen, CGImage) -> Void = { rect, screen, img in
                    guard !hasCompleted else { return }
                    hasCompleted = true
                    
                    // Close all overlay windows
                    for overlay in overlays {
                        overlay.close()
                    }
                    overlays.removeAll()
                    
                    if let rect = rect {
                        continuation.resume(returning: CropResult(rect: rect, screen: screen, image: img))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
                
                for (screen, image) in screenCaptures {
                    let overlay = CropOverlayWindow(
                        image: image,
                        screenFrame: screen.frame
                    ) { rect in
                        onCompleteBlock(rect, screen, image)
                    }
                    overlay.makeKeyAndOrderFront(nil)
                    overlays.append(overlay)
                }
            }
        }
    }

    private func doAreaCapture() async {
        let service = ScreenshotService.shared
        debugLog("[Screenshot] doAreaCapture started for all screens.")

        // Capture each connected screen
        var screenCaptures: [NSScreen: CGImage] = [:]
        for screen in NSScreen.screens {
            let dispID = screen.displayID ?? CGMainDisplayID()
            if let img = await service.captureDisplay(displayID: dispID) {
                screenCaptures[screen] = img
            }
        }

        guard !screenCaptures.isEmpty else {
            debugLog("[Screenshot] doAreaCapture failed: no screen images captured")
            await MainActor.run { self.isCapturing = false }
            return
        }

        await MainActor.run {
            self.isCapturing = false
        }

        if let result = await presentCropOverlays(screenCaptures: screenCaptures) {
            let cropRect = result.rect
            let targetScreen = result.screen
            let fullImage = result.image
            let screenFrame = targetScreen.frame
            
            debugLog("[Screenshot] doAreaCapture: cropRect received on screen \(targetScreen): \(cropRect)")
            await MainActor.run {
                self.isCapturing = true
            }

            // Derive the point→pixel scale from the actual captured image for the target display
            let scaleX = CGFloat(fullImage.width) / screenFrame.width
            let scaleY = CGFloat(fullImage.height) / screenFrame.height

            // cropRect is in points, bottom-left origin, relative to the screen.
            let scaledRect = CGRect(
                x: cropRect.origin.x * scaleX,
                y: cropRect.origin.y * scaleY,
                width: cropRect.width * scaleX,
                height: cropRect.height * scaleY
            )

            // CGImage cropping uses a top-left origin, so flip vertically.
            let imageHeight = CGFloat(fullImage.height)
            let flippedRect = CGRect(
                x: scaledRect.origin.x,
                y: imageHeight - scaledRect.origin.y - scaledRect.height,
                width: scaledRect.width,
                height: scaledRect.height
            )

            guard let cropped = service.cropImage(fullImage, to: flippedRect) else {
                debugLog("[Screenshot] doAreaCapture: cropImage returned nil for flippedRect: \(flippedRect)")
                await finishCapture(url: nil, image: nil)
                return
            }
            debugLog("[Screenshot] doAreaCapture: cropped image successfully \(cropped.width)x\(cropped.height)")
            await deliver(image: cropped, service: service)
        } else {
            debugLog("[Screenshot] doAreaCapture: cropRect is nil (user cancelled)")
            await MainActor.run { self.isCapturing = false }
        }
    }

    private func doWindowCapture() async {
        let service = ScreenshotService.shared

        await MainActor.run { self.isCapturing = false }

        // Interactive selection: the overlay highlights whichever window is under
        // the cursor and returns its ID on click (Esc cancels).
        if let windowID = await presentWindowSelectors() {
            await MainActor.run { self.isCapturing = true }

            // Let our selection overlay fully disappear before snapshotting.
            try? await Task.sleep(for: .milliseconds(80))

            guard let image = await service.captureWindowImage(windowID: windowID) else {
                await finishCapture(url: nil, image: nil)
                return
            }
            await deliver(image: image, service: service)
        } else {
            await MainActor.run { self.isCapturing = false }
        }
    }

    /// Routes a captured image to the selected output (clipboard or file/shelf).
    private func deliver(image: CGImage, service: ScreenshotService) async {
        debugLog("[Screenshot] deliver started. output mode: \(selectedOutput)")
        switch selectedOutput {
        case .clipboard:
            service.copyToClipboard(image)
            debugLog("[Screenshot] deliver: copied to clipboard")
            await finishCapture(url: nil, image: nil)
            await MainActor.run {
                BoringViewCoordinator.shared.toggleSneakPeek(
                    status: true,
                    type: .screenshot,
                    duration: 2.0,
                    value: 0,
                    icon: "camera.viewfinder",
                    message: "已复制"
                )
            }
        case .shelf:
            if let url = service.saveToFile(image) {
                debugLog("[Screenshot] deliver: saved to shelf URL: \(url)")
                let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                await finishCapture(url: url, image: nsImage)
                await MainActor.run {
                    BoringViewCoordinator.shared.toggleSneakPeek(
                        status: true,
                        type: .screenshot,
                        duration: 2.0,
                        value: 0,
                        icon: "camera.viewfinder",
                        message: "已保存"
                    )
                }
            } else {
                debugLog("[Screenshot] deliver: failed to save to file for shelf")
                await finishCapture(url: nil, image: nil)
            }
        case .file:
            NSApp.activate(ignoringOtherApps: true)
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.png]
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let timestamp = formatter.string(from: Date())
            savePanel.nameFieldStringValue = "Screenshot \(timestamp).png"
            
            debugLog("[Screenshot] deliver: presenting NSSavePanel")
            let response = await withCheckedContinuation { continuation in
                savePanel.begin { response in
                    continuation.resume(returning: response)
                }
            }
            
            debugLog("[Screenshot] deliver: NSSavePanel response: \(response)")
            if response == .OK, let url = savePanel.url {
                if service.saveToFile(image, to: url) {
                    debugLog("[Screenshot] deliver: saved to custom URL: \(url)")
                    let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    await finishCapture(url: url, image: nsImage)
                    await MainActor.run {
                        BoringViewCoordinator.shared.toggleSneakPeek(
                            status: true,
                            type: .screenshot,
                            duration: 2.0,
                            value: 0,
                            icon: "camera.viewfinder",
                            message: "已保存"
                        )
                    }
                } else {
                    debugLog("[Screenshot] deliver: failed to save to custom URL")
                    await finishCapture(url: nil, image: nil)
                }
            } else {
                debugLog("[Screenshot] deliver: NSSavePanel cancelled or failed")
                await finishCapture(url: nil, image: nil)
            }
        }
    }

    private func finishCapture(url: URL?, image: NSImage?) async {
        await MainActor.run {
            if let url {
                self.lastCapturedURL = url
                self.lastCapturedImage = image
                if self.selectedOutput == .shelf {
                    self.addToShelf(url: url)
                }
            }
            self.isCapturing = false
            self.hasPermission = true
        }
    }

    func copyLastScreenshot() {
        guard let url = lastCapturedURL else { return }
        if let image = NSImage(contentsOf: url) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
        }
    }

    func deleteLastScreenshot() {
        guard let url = lastCapturedURL else { return }
        try? FileManager.default.removeItem(at: url)
        
        let path = url.path
        let itemsToRemove = ShelfStateViewModel.shared.items.filter { item in
            if case .file(let data) = item.kind {
                let bookmark = Bookmark(data: data)
                if let resolvedURL = bookmark.resolveURL() {
                    return resolvedURL.path == path
                }
            }
            return false
        }
        
        for item in itemsToRemove {
            ShelfStateViewModel.shared.remove(item)
        }
        
        lastCapturedURL = nil
        lastCapturedImage = nil
    }

    func cancelCapture() {
        countdownTask?.cancel()
        countdownTask = nil
        isCapturing = false
        countdownRemaining = 0
    }

    private func presentWindowSelectors() async -> CGWindowID? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                
                var overlays: [WindowSelectOverlay] = []
                var hasCompleted = false
                
                let onCompleteBlock: (CGWindowID?) -> Void = { windowID in
                    guard !hasCompleted else { return }
                    hasCompleted = true
                    
                    // Close all overlay windows
                    for overlay in overlays {
                        overlay.close()
                    }
                    overlays.removeAll()
                    
                    continuation.resume(returning: windowID)
                }
                
                for screen in NSScreen.screens {
                    let overlay = WindowSelectOverlay(screenFrame: screen.frame) { windowID in
                        onCompleteBlock(windowID)
                    }
                    overlay.begin()
                    overlays.append(overlay)
                }
            }
        }
    }

    private func runCountdown(seconds: Int) async {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            for i in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                await MainActor.run { self.countdownRemaining = i }
                try? await Task.sleep(for: .seconds(1))
            }
            await MainActor.run { self.countdownRemaining = 0 }
        }
        await countdownTask?.value
    }

    private func addToShelf(url: URL) {
        guard let bookmark = try? Bookmark(url: url) else { return }
        let item = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: false)
        ShelfStateViewModel.shared.add([item])
    }
}
