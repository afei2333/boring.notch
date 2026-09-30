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
    @State private var permissions = PermissionRequests.shared
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
            VStack(alignment: .leading, spacing: 12) {
                if !permissions.pending.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("待审批 · \(permissions.pending.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        ForEach(permissions.pending) { request in
                            permissionCard(request)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
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

    private func permissionCard(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(request.vendor, systemImage: request.symbol)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(request.project ?? request.badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(request.summary)
                .font(.subheadline.weight(.medium))
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if let path = request.path {
                Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let removed = request.removed {
                Text("− \(removed)").foregroundStyle(.red).font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if let added = request.added {
                Text("+ \(added)").foregroundStyle(.green).font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if !request.isQuestion && !request.isPlan {
                    Button("允许") { permissions.resolve(request.id, .allow) }
                    Button("拒绝") { permissions.resolve(request.id, .deny) }
                }
                Button("在客户端处理") { permissions.resolve(request.id, .leave) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AgentHUDClosedNotice: View {
    let request: PermissionRequest?
    let notice: AgentHUDNotice?
    let cameraWidth: CGFloat
    let height: CGFloat
    let onOpen: () -> Void

    var body: some View {
        Group {
            if let completion = notice?.completion {
                EmbeddedCompletionAlert(completion, cameraWidth: cameraWidth,
                                        height: height, onOpen: onOpen)
            } else {
                Button(action: onOpen) {
                    HStack(spacing: 0) {
                        Label(request?.vendor ?? notice?.title ?? "Agent", systemImage: request == nil ? (notice?.symbol ?? "sparkles") : "hand.raised.fill")
                            .frame(width: 120, alignment: .leading)
                        Color.clear.frame(width: cameraWidth)
                        Text(request == nil ? (notice?.detail ?? "") : "待审批 · \(request?.summary ?? "")")
                            .frame(width: 170, alignment: .trailing)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
