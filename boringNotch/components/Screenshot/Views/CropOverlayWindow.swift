//
//  CropOverlayWindow.swift
//  boringNotch
//
//  Created by boringNotch on 2025.
//

import AppKit
import SwiftUI

@MainActor
final class CropOverlayWindow: NSWindow {
    private let onComplete: (CGRect?) -> Void
    private let image: CGImage
    private var startPoint: NSPoint?
    private var selectionView: SelectionView!
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var hasCompleted = false
    private var selfRetainer: CropOverlayWindow?

    init(image: CGImage, screenFrame: CGRect, onComplete: @escaping (CGRect?) -> Void) {
        self.image = image
        self.onComplete = onComplete

        let screenSize = screenFrame.size

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
        isReleasedWhenClosed = false
        // Keep the overlay itself out of any concurrent screen capture.
        sharingType = .none
        setFrame(screenFrame, display: true)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let nsImage = NSImage(cgImage: image, size: screenSize)

        let overlay = FirstMouseImageView(frame: NSRect(origin: .zero, size: screenSize))
        overlay.image = nsImage
        overlay.imageScaling = .scaleProportionallyUpOrDown
        contentView!.addSubview(overlay)

        let dimView = FirstMouseView(frame: NSRect(origin: .zero, size: screenSize))
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        contentView!.addSubview(dimView)

        selectionView = SelectionView(frame: .zero)
        selectionView.isHidden = true
        contentView!.addSubview(selectionView)

        let hint = NSTextField(labelWithString: "拖拽选择截图区域，Esc 取消")
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        hint.isBezeled = false
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 8
        hint.alignment = .center
        hint.sizeToFit()
        let hintFrame = hint.frame
        hint.frame = NSRect(
            x: (screenSize.width - hintFrame.width - 32) / 2,
            y: screenSize.height - 60,
            width: hintFrame.width + 32,
            height: hintFrame.height + 16
        )
        contentView!.addSubview(hint)

        startMonitoring()
    }

    override var canBecomeKey: Bool { true }

    private func startMonitoring() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let contentView = self.contentView else { return event }
            let point = contentView.convert(event.locationInWindow, from: nil)

            switch event.type {
            case .leftMouseDown:
                self.startPoint = point
                self.selectionView.isHidden = false
                self.selectionView.frame = .zero
            case .leftMouseDragged:
                if let start = self.startPoint {
                    let rect = self.normalize(start, point)
                    self.selectionView.frame = rect
                    self.selectionView.needsDisplay = true
                }
            case .leftMouseUp:
                if let start = self.startPoint, !self.hasCompleted {
                    let rect = self.normalize(start, point)
                    self.hasCompleted = true
                    self.stopMonitoring()
                    self.close()
                    let result: CGRect? = (rect.width > 5 && rect.height > 5) ? rect : nil
                    DispatchQueue.main.async { [weak self] in
                        self?.onComplete(result)
                        self?.selfRetainer = nil
                    }
                }
            default:
                break
            }
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, !self.hasCompleted {
                self.hasCompleted = true
                self.stopMonitoring()
                self.close()
                DispatchQueue.main.async { [weak self] in
                    self?.onComplete(nil)
                    self?.selfRetainer = nil
                }
                return nil
            }
            return event
        }
    }

    private func stopMonitoring() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
    }

    override func close() {
        stopMonitoring()
        super.close()
    }

    private func normalize(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}

final class SelectionView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.white.setStroke()
        let path = NSBezierPath(rect: bounds)
        path.lineWidth = 2
        path.stroke()

        NSColor.clear.setFill()
        bounds.fill(using: .copy)
    }
}

final class FirstMouseImageView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

final class FirstMouseView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}
