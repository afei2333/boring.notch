//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Screenshot", icon: "camera.viewfinder", view: .screenshot),
    TabModel(label: "AI", icon: "sparkles", view: .ai),
    TabModel(label: "Apps", icon: "square.grid.2x2.fill", view: .apps),
    TabModel(label: "Clipboard", icon: "doc.on.clipboard", view: .clipboard),
    TabModel(label: "Stats", icon: "gauge.with.dots.needle.50percent", view: .stats),
    TabModel(label: "Stocks", icon: "chart.line.uptrend.xyaxis", view: .stocks)
]

struct TabSelectionView: View {
    /// Subset shown by this instance — camera screens split the row into two
    /// instances, one on each side of the housing.
    var visibleTabs: [TabModel] = tabs
    var compact = false

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation
    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view, compact: compact) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
