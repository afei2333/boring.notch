//
//  ClipboardHistoryView.swift
//  boringNotch
//
//  Clipboard history: polls NSPasteboard for copied text and images and shows
//  them as a clickable list in the notch. Click an item to copy it back.
//  Text persists via Defaults; images are saved as PNG files in Application
//  Support with their filenames tracked in Defaults.
//

import AppKit
import Defaults
import SwiftUI

// MARK: - Manager

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [String] = Defaults[.clipboardHistory] {
        didSet { Defaults[.clipboardHistory] = items }
    }
    @Published private(set) var imageFiles: [String] = Defaults[.clipboardImages] {
        didSet { Defaults[.clipboardImages] = imageFiles }
    }

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let maxItems = 50
    private let maxImages = 10

    private static let imageDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func imageURL(_ name: String) -> URL {
        Self.imageDir.appendingPathComponent(name)
    }

    private init() {
        // Drop entries whose backing file was deleted externally.
        imageFiles = imageFiles.filter { FileManager.default.fileExists(atPath: imageURL($0).path) }
    }

    func start() {
        guard timer == nil else { return }
        // ponytail: 1s polling — macOS has no pasteboard-change notification
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // Skip transient/concealed content (password managers etc.)
        guard pb.availableType(from: [NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                                      NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]) == nil
        else { return }

        if pb.availableType(from: [.tiff, .png]) != nil, let image = NSImage(pasteboard: pb) {
            recordImage(image)
        } else if let text = pb.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record(text)
        }
    }

    private func recordImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }

        // Dedupe against the most recent image only (repeated ⌘C of the same thing).
        if let first = imageFiles.first, (try? Data(contentsOf: imageURL(first))) == png {
            return
        }

        let name = UUID().uuidString + ".png"
        do {
            try png.write(to: imageURL(name))
        } catch {
            NSLog("ClipboardManager: failed to save image: \(error)")
            return
        }
        imageFiles.insert(name, at: 0)
        while imageFiles.count > maxImages {
            let evicted = imageFiles.removeLast()
            try? FileManager.default.removeItem(at: imageURL(evicted))
        }
    }

    private func record(_ text: String) {
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
    }

    /// Copy an item back to the system pasteboard and move it to the front.
    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
        record(text)
    }

    /// Copy a stored image back to the system pasteboard and move it to the front.
    func copyImage(_ name: String) {
        guard let image = NSImage(contentsOf: imageURL(name)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        lastChangeCount = pb.changeCount
        imageFiles.removeAll { $0 == name }
        imageFiles.insert(name, at: 0)
    }

    func remove(_ text: String) {
        items.removeAll { $0 == text }
    }

    func removeImage(_ name: String) {
        try? FileManager.default.removeItem(at: imageURL(name))
        imageFiles.removeAll { $0 == name }
    }

    func clear() {
        items.removeAll()
        for name in imageFiles {
            try? FileManager.default.removeItem(at: imageURL(name))
        }
        imageFiles.removeAll()
    }
}

// MARK: - View

struct ClipboardHistoryView: View {
    @ObservedObject private var manager = ClipboardManager.shared

    var body: some View {
        Group {
            if manager.items.isEmpty && manager.imageFiles.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if !manager.imageFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(manager.imageFiles, id: \.self) { name in
                            ClipboardImageThumb(name: name)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }
                .frame(height: 64)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(manager.items, id: \.self) { text in
                        ClipboardRow(text: text)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            HStack {
                Text("\(manager.items.count) texts · \(manager.imageFiles.count) images")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                Spacer()
                Button("Clear All", role: .destructive) {
                    withAnimation(.smooth) { manager.clear() }
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.gray)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 30))
                .foregroundStyle(.gray)
            Text("No clipboard history")
                .font(.headline)
                .foregroundStyle(.gray)
            Text("Copied text and images will appear here")
                .font(.caption)
                .foregroundStyle(.gray.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClipboardImageThumb: View {
    let name: String

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            ClipboardManager.shared.copyImage(name)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
        } label: {
            // ponytail: full PNG loaded as thumbnail, add ThumbnailService if memory matters
            Group {
                if let image = NSImage(contentsOf: ClipboardManager.shared.imageURL(name)) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.gray)
                }
            }
            .frame(width: 80, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if copied {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.4))
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Click to copy")
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    withAnimation(.smooth) { ClipboardManager.shared.removeImage(name) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Remove")
                .padding(2)
            }
        }
    }
}

private struct ClipboardRow: View {
    let text: String

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            ClipboardManager.shared.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
        } label: {
            HStack(spacing: 8) {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if copied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if hovering {
                    Button {
                        withAnimation(.smooth) { ClipboardManager.shared.remove(text) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .secondarySystemFill).opacity(hovering ? 1 : 0.5))
            )
        }
        .buttonStyle(.plain)
        .help("Click to copy")
        .onHover { hovering = $0 }
    }
}
