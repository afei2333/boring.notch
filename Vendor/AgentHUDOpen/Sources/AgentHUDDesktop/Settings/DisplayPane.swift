import AppKit
import SwiftUI
import AgentHUDCore

struct DisplayPane: View {
    let settings: SettingsStore
    let store: UsageStore
    let theme: Theme
    /// Which display the panes below are editing. Owned here so the glow preview can show that screen's
    /// mode rather than always the notch.
    @State private var screen: String = ScreensPane.attached().first?.key ?? ""

    private var selection: NSScreen? {
        NSScreen.screens.first { ScreenIdentity.key(for: $0) == screen } ?? NSScreen.main
    }

    private var placement: ScreenPlacement {
        guard let selection else { return .default(hasNotch: false) }
        return ScreenIdentity.placement(for: selection, in: settings.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ScreensPane(settings: settings, theme: theme, selected: $screen)
            GlowPane(settings: settings, store: store, theme: theme, placement: placement,
                     metrics: ScreenMetrics(screen: selection), screen: screen)
            IslandPane(settings: settings, theme: theme)
            SettingsSection(title: L10n.text("菜单栏", "Menu bar"), theme: theme) {
                SettingsToggleRow(
                    label: L10n.text("显示菜单栏图标", "Show menu bar icon"),
                    subtitle: L10n.text("快速查看用量、刷新数据和打开设置。", "Quick access to usage, refresh and settings."),
                    isOn: settings.binding(\.showMenuBarIcon)
                )
            }
        }
    }
}

/// Decorative wallpaper for the glow preview.
struct SettingsPreview<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { geometry in
                    Image(nsImage: SettingsPreviewArtwork.wallpaper)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(12)
            .accessibilityHidden(true)
            // A glow reaches past the box it is previewed in, and the preview sits in front of the rows
            // above it. Left interactive, that overhang silently swallows their clicks: AppKit-backed
            // controls keep working because they are real views, and plain SwiftUI buttons stop responding.
            .allowsHitTesting(false)
    }
}

@MainActor
private enum SettingsPreviewArtwork {
    static let wallpaper = NSImage(contentsOf: AppResources.bundle.url(forResource: "settings-wallpaper", withExtension: "png")!)!
}
