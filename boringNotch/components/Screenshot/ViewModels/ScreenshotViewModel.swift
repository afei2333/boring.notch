//
//  ScreenshotViewModel.swift
//  boringNotch
//
//  Created by boringNotch on 2025.
//

import AppKit
import Combine
import Foundation

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
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
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

    private func doAreaCapture() async {
        let service = ScreenshotService.shared
        let targetScreen = mouseScreen
        let screenFrame = targetScreen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        guard let fullImage = await service.captureDisplay(displayID: displayID(for: targetScreen)) else {
            await MainActor.run { self.isCapturing = false }
            return
        }

        // Derive the point→pixel scale from the actual captured image so we stay
        // correct under scaled ("More Space"/"Larger Text") display resolutions.
        let scaleX = CGFloat(fullImage.width) / screenFrame.width
        let scaleY = CGFloat(fullImage.height) / screenFrame.height

        await MainActor.run {
            self.isCapturing = false
        }

        if let cropRect = await presentCropOverlay(
            image: fullImage,
            screenFrame: screenFrame
        ) {
            await MainActor.run {
                self.isCapturing = true
            }

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
                await finishCapture(url: nil, image: nil)
                return
            }
            await deliver(image: cropped, service: service)
        } else {
            await MainActor.run { self.isCapturing = false }
        }
    }

    private func doWindowCapture() async {
        let service = ScreenshotService.shared

        await MainActor.run { self.isCapturing = false }

        // Interactive selection: the overlay highlights whichever window is under
        // the cursor and returns its ID on click (Esc cancels).
        if let windowID = await presentWindowSelector() {
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
        switch selectedOutput {
        case .clipboard:
            service.copyToClipboard(image)
            await finishCapture(url: nil, image: nil)
        case .shelf, .file:
            if let url = service.saveToFile(image) {
                let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                await finishCapture(url: url, image: nsImage)
            } else {
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
        lastCapturedURL = nil
        lastCapturedImage = nil
    }

    func cancelCapture() {
        countdownTask?.cancel()
        countdownTask = nil
        isCapturing = false
        countdownRemaining = 0
    }

    private func presentCropOverlay(image: CGImage, screenFrame: CGRect) async -> CGRect? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let overlay = CropOverlayWindow(
                    image: image,
                    screenFrame: screenFrame
                ) { cropRect in
                    continuation.resume(returning: cropRect)
                }
                overlay.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func presentWindowSelector() async -> CGWindowID? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let overlay = WindowSelectOverlay { windowID in
                    continuation.resume(returning: windowID)
                }
                overlay.begin()
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
