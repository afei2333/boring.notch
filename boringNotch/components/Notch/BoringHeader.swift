//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    @Environment(\.notchTheme) private var notchTheme

    /// Capsule fill for the round header controls. Solid black reads as a button
    /// on the black notch, but looks like a stray black blob on Liquid Glass, so
    /// there we use a faint translucent chip that lets the glass show through.
    private var controlButtonFill: AnyShapeStyle {
        notchTheme == .liquidGlass
            ? AnyShapeStyle(Color.primary.opacity(0.08))
            : AnyShapeStyle(Color.black)
    }

    /// Glyph color paired with `controlButtonFill` — adaptive on Liquid Glass
    /// (dark in light mode), white on the black notch.
    private var controlButtonIconColor: Color {
        notchTheme == .liquidGlass ? .primary : .white
    }

    /// Whether the tab row is enabled at all (shelf feature + content).
    private var showTabs: Bool {
        (!tvm.isEmpty || coordinator.alwaysShowTabs) && Defaults[.boringShelf]
    }

    // ponytail: fixed 5/3 tab split around the housing, sized for the 640pt
    // open notch — recompute dynamically if tabs or open width ever change.
    private static let leftTabs = Array(tabs.prefix(5))
    private static let rightTabs = Array(tabs.dropFirst(5))

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                // Camera screens: the housing hides the header's center (and the
                // cursor can't go there), so tabs hug both sides of it, compact.
                // Camera-less externals keep the full-width row on the left.
                if showTabs {
                    if vm.screenHasCamera {
                        TabSelectionView(visibleTabs: Self.leftTabs, compact: true)
                    } else {
                        TabSelectionView()
                    }
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: vm.screenHasCamera ? .trailing : .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open && vm.screenHasCamera {
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if vm.screenHasCamera && showTabs {
                            TabSelectionView(visibleTabs: Self.rightTabs, compact: true)
                            Spacer(minLength: 0)
                        }
                        if Defaults[.showMirror] {
                            Button(action: {
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(controlButtonFill)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "web.camera")
                                            .foregroundColor(controlButtonIconColor)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                                
                            }) {
                                Capsule()
                                    .fill(controlButtonFill)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "gear")
                                            .foregroundColor(controlButtonIconColor)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.showBatteryIndicator] {
                            BoringBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                isForNotification: false
                            )
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
