//
//  AppLauncherView.swift
//  boringNotch
//
//  Quick app launcher: a user-curated set of favorite apps shown as an icon
//  grid. Used both as a dedicated "Apps" tab and as the Home replacement when
//  no music is playing. Apps are stored as bundle identifiers in Defaults and
//  launched through LaunchServices (sandbox-safe, same path as openMusicApp()).
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Service / actions

enum AppLauncherService {
    /// Launch an app by its bundle identifier.
    static func launch(bundleID: String) {
        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            NSLog("AppLauncher: cannot resolve bundle id \(bundleID)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        workspace.openApplication(at: url, configuration: config) { _, error in
            if let error = error {
                NSLog("AppLauncher: failed to launch \(bundleID): \(error)")
            }
        }
    }

    /// Human-readable name for a bundle id, falling back to the id itself.
    static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Present an open panel to pick one or more `.app` bundles and append their
    /// bundle identifiers to the favorites list (skipping ones already present).
    @MainActor static func addApps() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose apps to add to Quick Launch"

        guard panel.runModal() == .OK else { return }

        var current = Defaults[.launcherApps]
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            if !current.contains(bundleID) {
                current.append(bundleID)
            }
        }
        Defaults[.launcherApps] = current
    }

    static func remove(bundleID: String) {
        Defaults[.launcherApps].removeAll { $0 == bundleID }
    }
}

// MARK: - Tiles

private struct AppLauncherTile: View {
    let bundleID: String
    var size: CGFloat = 52
    var showLabel: Bool = false
    var onRemove: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Button {
            AppLauncherService.launch(bundleID: bundleID)
        } label: {
            VStack(spacing: 4) {
                AppIcon(for: bundleID)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .scaleEffect(hovering ? 1.08 : 1)
                if showLabel {
                    Text(AppLauncherService.displayName(for: bundleID))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.gray)
                        .frame(maxWidth: size + 24)
                }
            }
        }
        .buttonStyle(.plain)
        .help(AppLauncherService.displayName(for: bundleID))
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if hovering, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Remove from Quick Launch")
                .offset(x: 4, y: -2)
            }
        }
        .contextMenu {
            if let onRemove {
                Button("Remove from Quick Launch", role: .destructive, action: onRemove)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
    }
}

private struct AddAppTile: View {
    var size: CGFloat = 52
    @State private var hovering = false

    var body: some View {
        Button {
            AppLauncherService.addApps()
        } label: {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                .foregroundStyle(.gray.opacity(hovering ? 0.9 : 0.45))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: size * 0.38, weight: .medium))
                        .foregroundStyle(.gray.opacity(hovering ? 0.9 : 0.55))
                }
        }
        .buttonStyle(.plain)
        .help("Add app")
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Launcher view (tab + compact)

struct AppLauncherView: View {
    @Default(.launcherApps) private var apps

    /// Compact mode is used inside Home when no music is playing.
    var compact: Bool = false

    private var iconSize: CGFloat { compact ? 38 : 52 }
    private var columnCount: Int { compact ? 4 : 6 }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: compact ? 8 : 14),
            count: columnCount
        )
    }

    var body: some View {
        Group {
            if apps.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(maxWidth: compact ? 250 : .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: compact ? 10 : 16) {
                ForEach(apps, id: \.self) { bundleID in
                    AppLauncherTile(
                        bundleID: bundleID,
                        size: iconSize,
                        showLabel: !compact
                    ) {
                        AppLauncherService.remove(bundleID: bundleID)
                    }
                }
                AddAppTile(size: iconSize)
            }
            .padding(compact ? 6 : 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: compact ? 6 : 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: compact ? 22 : 30))
                .foregroundStyle(.gray)
            Text("No quick-launch apps")
                .font(compact ? .caption : .headline)
                .foregroundStyle(.gray)
            Button {
                AppLauncherService.addApps()
            } label: {
                Label("Add apps", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
