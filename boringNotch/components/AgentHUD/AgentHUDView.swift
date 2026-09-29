import AgentHUDCore
import AgentHUDDesktop
import SwiftUI

private struct AgentHUDContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor
struct AgentHUDView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @State private var store = AgentHUDService.shared.store
    @State private var selectedVendor: String?

    private var availableVendors: [String] {
        guard let report = store.report else { return [] }
        var vendors: [String] = []
        func append(_ vendor: String) {
            if !vendors.contains(vendor) { vendors.append(vendor) }
        }
        report.discoveredAgents.filter(\.connected).forEach { append($0.displayVendor) }
        report.consumers.filter(\.connected).forEach { append($0.vendor) }
        return vendors
    }

    var body: some View {
        let vendors = availableVendors
        let vendor = selectedVendor.flatMap { vendors.contains($0) ? $0 : nil } ?? vendors.first
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if let vendor {
                    EmbeddedAgentHUDPanel(store: store, vendor: vendor, vendorChoices: vendors) {
                        selectedVendor = $0
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if store.isLoading {
                    ProgressView("正在读取代理数据…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ContentUnavailableView("暂无代理数据", systemImage: "terminal", description: Text("启动受支持的编程代理后会在这里显示。"))
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: AgentHUDContentHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(AgentHUDContentHeightKey.self) { height in
            vm.updateAgentContentHeight(height)
        }
        .task {
            await store.refreshAccounts()
        }
    }
}
