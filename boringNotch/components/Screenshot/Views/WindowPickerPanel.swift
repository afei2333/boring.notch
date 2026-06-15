//
//  WindowPickerPanel.swift
//  boringNotch
//
//  Created by boringNotch on 2025.
//

import AppKit

/// Full-desktop overlay for window capture. As the cursor moves it highlights
/// whichever window sits directly under it (like the macOS ⌘⇧4 + Space mode) and
/// returns that window's ID when the user clicks. Esc cancels. The cursor is
/// polled on a timer so highlighting works regardless of the app's active state.
@MainActor
final class WindowSelectOverlay: NSWindow {
    private let onComplete: (CGWindowID?) -> Void
    private var selfRetainer: WindowSelectOverlay?

    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var pollTimer: Timer?
    private var hasCompleted = false

    private let highlightView = NSView()
    private var currentWindowID: CGWindowID?

    private let screenFrame: CGRect
    private let primaryHeight: CGFloat

    init(screenFrame: CGRect, onComplete: @escaping (CGWindowID?) -> Void) {
        self.screenFrame = screenFrame
        self.onComplete = onComplete

        // Height of the primary display (origin at 0,0): used to flip CoreGraphics
        // top-left bounds into AppKit's bottom-left coordinate space.
        self.primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? screenFrame.height

        super.init(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        selfRetainer = self
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        sharingType = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screenFrame, display: false)

        highlightView.wantsLayer = true
        highlightView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        highlightView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        highlightView.layer?.borderWidth = 2
        highlightView.layer?.cornerRadius = 5
        highlightView.isHidden = true
        contentView?.addSubview(highlightView)

        let hint = NSTextField(labelWithString: "点击要截取的窗口，Esc 取消")
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        hint.drawsBackground = true
        hint.isBezeled = false
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 8
        hint.alignment = .center
        hint.sizeToFit()
        let hf = hint.frame
        hint.frame = NSRect(
            x: (screenFrame.width - hf.width - 32) / 2,
            y: screenFrame.height - 70,
            width: hf.width + 32,
            height: hf.height + 16
        )
        contentView?.addSubview(hint)
    }

    override var canBecomeKey: Bool { true }

    func begin() {
        makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
        startMonitoring()
        updateHighlight()
    }

    private func startMonitoring() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHighlight() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self else { return nil }
            // Only capture the window if the click occurred within this screen's overlay window
            if let window = self.clickMonitorWindow(at: NSEvent.mouseLocation) {
                if window == self {
                    self.complete(with: self.currentWindowID)
                    return nil
                }
            }
            return nil
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.complete(with: nil)
                return nil
            }
            return event
        }
    }

    private func clickMonitorWindow(at globalPoint: NSPoint) -> NSWindow? {
        let windows = NSApp.windows
        return windows.first { $0.frame.contains(globalPoint) && $0 is WindowSelectOverlay }
    }

    private func updateHighlight() {
        guard !hasCompleted, let cgLoc = CGEvent(source: nil)?.location else { return }
        
        // Convert cgLoc (y-down) to AppKit y-up coordinate to check containment
        let appKitLoc = CGPoint(x: cgLoc.x, y: primaryHeight - cgLoc.y)
        
        if screenFrame.contains(appKitLoc), let win = ScreenshotService.shared.window(at: cgLoc) {
            currentWindowID = win.id
            highlightView.frame = localRect(fromCGBounds: win.cgBounds)
            highlightView.isHidden = false
        } else {
            currentWindowID = nil
            highlightView.isHidden = true
        }
    }

    /// CoreGraphics global bounds (top-left origin) → overlay-local AppKit rect.
    private func localRect(fromCGBounds cg: CGRect) -> CGRect {
        let appKit = CGRect(
            x: cg.origin.x,
            y: primaryHeight - cg.origin.y - cg.height,
            width: cg.width,
            height: cg.height
        )
        return CGRect(
            x: appKit.origin.x - screenFrame.minX,
            y: appKit.origin.y - screenFrame.minY,
            width: appKit.width,
            height: appKit.height
        )
    }

    private func complete(with id: CGWindowID?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        stopMonitoring()
        NSCursor.arrow.set()
        orderOut(nil)
        let callback = onComplete
        DispatchQueue.main.async { [weak self] in
            callback(id)
            self?.selfRetainer = nil
        }
    }

    override func close() {
        stopMonitoring()
        super.close()
    }

    private func stopMonitoring() {
        pollTimer?.invalidate(); pollTimer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
    }
}
