import AgentHUDCore
import SwiftUI

/// The source island panel inside a host application's expanded notch.
public struct EmbeddedAgentHUDPanel: View {
    let store: UsageStore
    let vendor: String
    let vendorChoices: [String]
    let onSelectVendor: (String) -> Void

    public init(store: UsageStore, vendor: String, vendorChoices: [String],
                onSelectVendor: @escaping (String) -> Void) {
        self.store = store
        self.vendor = vendor
        self.vendorChoices = vendorChoices
        self.onSelectVendor = onSelectVendor
    }

    public var body: some View {
        let hasQuotaRows = store.rowGroups.contains { $0.vendor == vendor }
        return VStack(alignment: .leading, spacing: 0) {
            if !hasQuotaRows {
                Menu {
                    ForEach(vendorChoices, id: \.self) { choice in
                        Button(VendorCatalog.name(choice)) { onSelectVendor(choice) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        AgentLogo(vendor: vendor, size: 14)
                        Text(VendorCatalog.name(vendor)).font(.ui(13, .bold))
                        if vendorChoices.count > 1 {
                            Image(systemName: "chevron.down").font(.ui(9))
                        }
                    }
                    .foregroundStyle(Theme.island.text)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
            HoverPanelView(store: store, onOpenStats: {}, selectedVendor: vendor,
                           vendorChoices: vendorChoices, onSelectVendor: onSelectVendor,
                           showsFooter: false, topInset: hasQuotaRows ? 12 : 8)
        }
    }
}

/// Reuses the source island's completion views inside a host-owned notch window.
public struct EmbeddedCompletionAlert: View {
    let completion: SessionCompletion
    let cameraWidth: CGFloat
    let height: CGFloat
    let onOpen: () -> Void

    public init(_ completion: SessionCompletion, cameraWidth: CGFloat = 0,
                height: CGFloat = 0, onOpen: @escaping () -> Void) {
        self.completion = completion
        self.cameraWidth = cameraWidth
        self.height = height
        self.onOpen = onOpen
    }

    public var body: some View {
        let alert = IslandAlert.completion(completion)
        IslandAlertCompactView(alert: alert, cameraWidth: cameraWidth, height: height, onOpen: onOpen)
    }
}
