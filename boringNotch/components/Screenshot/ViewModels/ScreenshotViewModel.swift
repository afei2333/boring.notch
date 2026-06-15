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

    private func doFullscreenCapture() async {
        let service = ScreenshotService.shared

        switch selectedOutput {
        case .clipboard:
            service.captureFullScreenToClipboard()
            await finishCapture(url: nil, image: nil)
        case .shelf, .file:
            if let url = service.captureFullScreenToFile() {
                let image = NSImage(contentsOf: url)
                await finishCapture(url: url, image: image)
            } else {
                await finishCapture(url: nil, image: nil)
            }
        }
    }

    private func doAreaCapture() async {
        let service = ScreenshotService.shared

        guard let fullImage = service.captureFullScreen() else {
            await MainActor.run { self.isCapturing = false }
            return
        }

        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)

        await MainActor.run {
            self.isCapturing = false
        }

        if let cropRect = await presentCropOverlay(
            image: fullImage,
            screenSize: screenSize
        ) {
            await MainActor.run {
                self.isCapturing = true
            }

            let scaledRect = CGRect(
                x: cropRect.origin.x * screenScale,
                y: cropRect.origin.y * screenScale,
                width: cropRect.width * screenScale,
                height: cropRect.height * screenScale
            )

            let imageHeight = CGFloat(fullImage.height)
            let flippedRect = CGRect(
                x: scaledRect.origin.x,
                y: imageHeight - scaledRect.origin.y - scaledRect.height,
                width: scaledRect.width,
                height: scaledRect.height
            )

            switch selectedOutput {
            case .clipboard:
                service.captureAreaToClipboard(cropRect: flippedRect)
                await finishCapture(url: nil, image: nil)
            case .shelf, .file:
                if let url = service.captureArea(cropRect: flippedRect) {
                    let image = NSImage(contentsOf: url)
                    await finishCapture(url: url, image: image)
                } else {
                    await finishCapture(url: nil, image: nil)
                }
            }
        } else {
            await MainActor.run { self.isCapturing = false }
        }
    }

    private func doWindowCapture() async {
        let service = ScreenshotService.shared
        let windows = service.listWindows()

        guard !windows.isEmpty else {
            await MainActor.run { self.isCapturing = false }
            return
        }

        await MainActor.run { self.isCapturing = false }

        if let selectedWindow = await presentWindowPicker(windows: windows) {
            await MainActor.run { self.isCapturing = true }

            switch selectedOutput {
            case .clipboard:
                service.captureWindowToClipboard(windowID: selectedWindow.id)
                await finishCapture(url: nil, image: nil)
            case .shelf, .file:
                if let url = service.captureWindow(windowID: selectedWindow.id) {
                    let image = NSImage(contentsOf: url)
                    await finishCapture(url: url, image: image)
                } else {
                    await finishCapture(url: nil, image: nil)
                }
            }
        } else {
            await MainActor.run { self.isCapturing = false }
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

    private func presentCropOverlay(image: CGImage, screenSize: CGSize) async -> CGRect? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let overlay = CropOverlayWindow(
                    image: image,
                    screenSize: screenSize
                ) { cropRect in
                    continuation.resume(returning: cropRect)
                }
                overlay.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func presentWindowPicker(windows: [(id: CGWindowID, name: String, app: String)]) async -> (id: CGWindowID, name: String, app: String)? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let picker = WindowPickerPanel(windows: windows) { selected in
                    continuation.resume(returning: selected)
                }
                picker.makeKeyAndOrderFront(nil)
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
