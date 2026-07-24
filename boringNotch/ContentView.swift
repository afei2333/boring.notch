//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var aiChat = AIChatViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?
    @State private var aiAutoCloseTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    private var notchTheme: NotchTheme {
        if let screen = vm.screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) ?? NSScreen.main {
            let hasNotch = screen.safeAreaInsets.top > 0
            let isBuiltIn = screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
            if !hasNotch && !isBuiltIn {
                return .liquidGlass
            }
        }
        return .classicBlack
    }

    private var isBuiltInDisplay: Bool {
        let screen = vm.screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) ?? NSScreen.main
        return screen?.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    /// Filler for the center "notch cutout" in closed-state live activities.
    /// Opaque black over a real hardware notch (classicBlack); transparent on
    /// external displays (liquidGlass) so the glass forms one continuous pill
    /// instead of showing a black gap between the left/right content.
    private var notchCutoutFill: Color {
        notchTheme == .liquidGlass ? .clear : .black
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .modifier(NotchBackground(theme: notchTheme, shape: currentNotchShape))
                    // The window server click-throughs pixels with ~0 alpha, and
                    // liquid-glass blank areas can render that transparent — a
                    // click inside the notch then lands on the desktop. Keep every
                    // notch pixel ≥1% alpha (same trick as the chin below).
                    .background(currentNotchShape.fill(Color.black.opacity(0.01)))
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(notchTheme == .liquidGlass ? Color.clear : Color.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? (notchTheme == .liquidGlass ? Color.black.opacity(0.12) : Color.black.opacity(0.7))
                            : .clear,
                        radius: notchTheme == .liquidGlass ? 8 : (Defaults[.cornerRadiusScaling] ? 6 : 4),
                        x: 0,
                        y: notchTheme == .liquidGlass ? 3 : 0
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures] && !(vm.notchState == .open && coordinator.currentView == .ai)) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures] && !(vm.notchState == .open && coordinator.currentView == .ai)) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                        checkAIAutoClose()
                    }
                    .onChange(of: coordinator.currentView) { _, _ in
                        withAnimation(.smooth) {
                            vm.syncOpenHeightWithCurrentView()
                        }
                        checkAIAutoClose()
                    }
                    .onChange(of: isHovering) { _, _ in
                        checkAIAutoClose()
                    }
                    .onChange(of: aiChat.isInputFocused) { _, _ in
                        // Focus gained cancels the pending close; focus lost re-arms it.
                        checkAIAutoClose()
                    }
                    .onChange(of: aiChat.isBusy) { _, _ in
                        // A finished turn re-arms the idle auto-close timer.
                        checkAIAutoClose()
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        // Classic-black pins dark (white content on black). Liquid Glass follows
        // the system appearance so the native material renders its adaptive
        // (bright, Control-Center-like) variant instead of the dark one.
        .preferredColorScheme(notchTheme == .liquidGlass ? nil : .dark)
        .environment(\.notchTheme, notchTheme)
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                            }

                            Rectangle()
                                .fill(notchCutoutFill)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && (Defaults[.inlineHUD] || coordinator.sneakPeek.type == .screenshot || (coordinator.sneakPeek.type == .stockAlert && !isBuiltInDisplay)) && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if vm.notchState == .closed && aiChat.hasLiveActivity && !coordinator.sneakPeek.show {
                          AINotchLiveActivity()
                              .frame(alignment: .center)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && !vm.screenHasCamera && !vm.hideOnClosed && Defaults[.enableIdlePixelAnimation] {
                          // Camera-less externals: idle pixel animation in the bar.
                          PixelIdleAnimation()
                              .frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                           if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && (coordinator.sneakPeek.type != .screenshot) && (coordinator.sneakPeek.type != .stockAlert) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    case .screenshot:
                        ScreenshotView()
                    case .ai:
                        AIChatView()
                    case .apps:
                        AppLauncherView()
                    case .clipboard:
                        ClipboardHistoryView()
                    case .stats:
                        SystemStatsView()
                    case .stocks:
                        StocksView()
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(notchCutoutFill)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func AINotchLiveActivity() -> some View {
        HStack(spacing: 0) {
            // Left of the notch — AI glyph
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .symbolEffect(.pulse, isActive: aiChat.isBusy)
            }
            .frame(width: 76, alignment: .leading)
            .padding(.leading, 10)

            Rectangle()
                .fill(notchCutoutFill)
                .frame(width: vm.closedNotchSize.width + 10)

            // Right of the notch — progress + one-line summary
            HStack(spacing: 5) {
                if aiChat.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.gray)
                }
                MarqueeText(
                    .constant(aiChat.liveSummary.isEmpty ? "AI" : aiChat.liveSummary),
                    textColor: .gray,
                    minDuration: 0.4,
                    frameWidth: 90
                )
            }
            .frame(width: 110, alignment: .trailing)
            .padding(.trailing, 10)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture {
            coordinator.currentView = .ai
            vm.open()
        }
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(notchCutoutFill)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    private func checkAIAutoClose() {
        aiAutoCloseTask?.cancel()
        aiAutoCloseTask = nil
        
        guard coordinator.currentView == .ai,
              vm.notchState == .open,
              !isHovering,
              !aiChat.isInputFocused,
              !aiChat.isBusy else {
            return
        }
        
        aiAutoCloseTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                guard self.coordinator.currentView == .ai,
                      self.vm.notchState == .open,
                      !self.isHovering else {
                    return
                }
                
                if SharingStateManager.shared.preventNotchClose {
                    SharingStateManager.shared.endInteraction()
                }
                withAnimation(self.animationSpring) {
                    self.vm.close()
                }
            }
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

/// Notch background: the body fill + edge treatment for both themes.
///
/// On macOS 26+ the `.liquidGlass` theme uses the **real** native Liquid Glass
/// material (`.glassEffect(_:in:)`), which renders true backdrop refraction,
/// dynamic specular highlights and an adaptive rim — no hand-tuned gradients.
/// Older systems fall back to `NativeLiquidGlassView` (a manual approximation).
struct NotchBackground: ViewModifier {
    let theme: NotchTheme
    let shape: NotchShape

    func body(content: Content) -> some View {
        switch theme {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                // Native Liquid Glass. `.regular` adapts tint/contrast to the
                // backdrop automatically; clipping to `shape` lets the material
                // draw its own lensing + rim along the notch silhouette.
                content.glassEffect(.regular, in: shape)
            } else {
                content
                    .background(NativeLiquidGlassView())
                    .clipShape(shape)
                    .overlay { LiquidGlassEdges(shape: shape) }
            }
        case .classicBlack:
            content
                .background(Color.black)
                .clipShape(shape)
        }
    }
}

/// Hand-painted glass rim used only as a pre-macOS 26 fallback.
private struct LiquidGlassEdges: View {
    let shape: NotchShape

    var body: some View {
        ZStack {
            // A. Outer crisp white edge (thin)
            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.45),
                            .white.opacity(0.22),
                            .white.opacity(0.08),
                            .white.opacity(0.22),
                            .white.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )

            // B. Inner volumetric highlight (thick, top-left oriented)
            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.35),
                            .white.opacity(0.12),
                            .clear,
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3.0
                )
                .blur(radius: 0.5)

            // C. Volumetric shadow edge (bottom-right oriented)
            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            .clear,
                            .clear,
                            .black.opacity(0.12),
                            .black.opacity(0.38)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2.5
                )
                .blur(radius: 1.0)
        }
    }
}

struct NativeLiquidGlassView: View {
    var body: some View {
        ZStack {
            // 1. Real-time macOS backdrop blur
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            
            // 2. Translucent glass body tint (slightly dark, slightly blue-tinted)
            Color(red: 0.1, green: 0.12, blue: 0.18).opacity(0.22)
            
            // 3. Chromatic Pearlescent Glow (Iridescent color shift)
            LinearGradient(
                colors: [
                    Color(red: 0.0, green: 0.95, blue: 1.0).opacity(0.18),    // Cyan
                    Color(red: 0.61, green: 0.0, blue: 1.0).opacity(0.12),   // Violet
                    Color(red: 1.0, green: 0.84, blue: 0.0).opacity(0.08),   // Soft Gold
                    Color(red: 1.0, green: 0.05, blue: 0.6).opacity(0.14)    // Magenta
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)
            
            // 4. Surface specular glare (highlights from top-left)
            RadialGradient(
                colors: [
                    .white.opacity(0.22),
                    .clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 320
            )
            .blendMode(.overlay)
            
            // 5. Center soft lighting glow
            RadialGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 180
            )
        }
    }
}

/// Idle eye-candy for camera-less (external) displays, shown in the closed
/// notch bar. Style is user-selectable in Settings › Appearance; all variants
/// are cheap low-fps Canvas redraws.
struct PixelIdleAnimation: View {
    @Default(.idlePixelAnimationStyle) private var style

    var body: some View {
        switch style {
        case .invader: InvaderPatrolPixels()
        case .matrixRain: MatrixRainPixels()
        case .gameOfLife: GameOfLifePixels()
        case .twinkle: TwinkleFieldPixels()
        case .pixelPet: PixelPetPixels()
        case .snake: SnakePixels()
        case .campfire: CampfirePixels()
        case .aquarium: AquariumPixels()
        case .shmup: ShmupPixels()
        case .pong: PongPixels()
        case .nyanCat: NyanCatPixels()
        case .dinoRun: DinoRunPixels()
        case .woodenFish: WoodenFishPixels()
        case .crab: CrabPixels()
        }
    }
}

/// 太空巡逻: a classic space invader marching back and forth through a
/// twinkling starfield. Stateless — everything derives from the clock.
private struct InvaderPatrolPixels: View {
    // Classic two-frame invader sprite, 11×8.
    private static let frames: [[String]] = [
        [
            "..#.....#..",
            "...#...#...",
            "..#######..",
            ".##.###.##.",
            "###########",
            "#.#######.#",
            "#.#.....#.#",
            "...##.##...",
        ],
        [
            "..#.....#..",
            "#..#...#..#",
            "#.#######.#",
            "###.###.###",
            ".#########.",
            "..#######..",
            "..#.....#..",
            ".#.......#.",
        ],
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate

                // Starfield backdrop: sparse deterministic twinkle.
                let cell: CGFloat = 8
                for col in 0..<max(1, Int(size.width / cell)) {
                    for row in 0..<max(1, Int(size.height / cell)) {
                        let seed = UInt32(truncatingIfNeeded: (col &* 73856093) ^ (row &* 19349663))
                        let h = Double(seed % 1000) / 1000
                        guard h > 0.8 else { continue }
                        let brightness = max(0, sin(t * (0.6 + h) + h * .pi * 2))
                        guard brightness > 0.1 else { continue }
                        let rect = CGRect(x: CGFloat(col) * cell + cell / 2,
                                          y: CGFloat(row) * cell + cell / 2,
                                          width: 1.5, height: 1.5)
                        let color: Color = seed % 3 == 0 ? .cyan : .white
                        context.fill(Path(rect), with: .color(color.opacity(0.1 + 0.4 * brightness)))
                    }
                }

                // Marching invader: triangle-wave patrol, two-frame arm wiggle.
                let rows = Self.frames[Int(t / 0.4) % 2]
                let px = max(2, ((size.height - 4) / 8).rounded(.down))
                let spriteWidth = 11 * px
                let travel = max(1, size.width - spriteWidth)
                let phase = t.truncatingRemainder(dividingBy: 22) / 22
                let tri = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                let x0 = travel * tri
                let y0 = (size.height - 8 * px) / 2
                for (row, line) in rows.enumerated() {
                    for (col, ch) in line.enumerated() where ch == "#" {
                        let rect = CGRect(x: x0 + CGFloat(col) * px,
                                          y: y0 + CGFloat(row) * px,
                                          width: px, height: px)
                        context.fill(Path(rect), with: .color(.mint.opacity(0.85)))
                    }
                }
            }
        }
    }
}

/// Clawd 吉祥物: Claude Code's crab mascot strolling along the bar, waving
/// its raised left claw and shuffling its stubby legs. Stateless — everything
/// derives from the clock.
private struct CrabPixels: View {
    // Two-frame Clawd sprite, 11×8: flat rectangular body, two dark eyes
    // ('o' left unfilled so the bar shows through), raised waving left claw,
    // small right arm, stubby legs.
    private static let frames: [[String]] = [
        [   // claw up
            "##.........",
            "##.........",
            ".#########.",
            "...#o##o##.",
            "...########",
            "...#######.",
            "....#.#.#..",
            "...#..#..#.",
        ],
        [   // claw down
            "...........",
            "##.........",
            "##########.",
            "...#o##o##.",
            "...#######.",
            "...########",
            "...#.#.#...",
            "....#..#..#",
        ],
    ]

    private static let shell = Color(red: 0.85, green: 0.47, blue: 0.34)  // Claude orange

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate

                // Faint twinkling dust so the bar isn't empty around Clawd.
                let cell: CGFloat = 8
                for col in 0..<max(1, Int(size.width / cell)) {
                    for row in 0..<max(1, Int(size.height / cell)) {
                        let seed = UInt32(truncatingIfNeeded: (col &* 73856093) ^ (row &* 19349663))
                        let h = Double(seed % 1000) / 1000
                        guard h > 0.85 else { continue }
                        let brightness = max(0, sin(t * (0.5 + h) + h * .pi * 2))
                        guard brightness > 0.1 else { continue }
                        let rect = CGRect(x: CGFloat(col) * cell + cell / 2,
                                          y: CGFloat(row) * cell + cell / 2,
                                          width: 1.5, height: 1.5)
                        context.fill(Path(rect), with: .color(Self.shell.opacity(0.1 + 0.3 * brightness)))
                    }
                }

                // Sideways patrol: triangle wave, two-frame claw/leg wiggle,
                // plus a tiny vertical bob.
                let rows = Self.frames[Int(t / 0.3) % 2]
                let px = max(2, ((size.height - 4) / 8).rounded(.down))
                let spriteWidth = 11 * px
                let travel = max(1, size.width - spriteWidth)
                let phase = t.truncatingRemainder(dividingBy: 18) / 18
                let tri = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                let x0 = travel * tri
                let y0 = (size.height - 8 * px) / 2 + (Int(t / 0.3) % 2 == 0 ? 0 : 1)
                for (row, line) in rows.enumerated() {
                    for (col, ch) in line.enumerated() where ch == "#" {
                        let rect = CGRect(x: x0 + CGFloat(col) * px,
                                          y: y0 + CGFloat(row) * px,
                                          width: px, height: px)
                        context.fill(Path(rect), with: .color(Self.shell.opacity(0.9)))
                    }
                }
            }
        }
    }
}

/// 数字雨: Matrix-style columns of falling green pixels with fading trails.
/// Stateless — column speed/phase derive from a per-column hash.
private struct MatrixRainPixels: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let cell: CGFloat = 4
                let cols = max(1, Int(size.width / cell))
                let rows = max(1, Int(size.height / cell))
                let trail = 5
                let span = Double(rows + trail)
                for col in 0..<cols {
                    let seed = UInt32(truncatingIfNeeded: col &* 2654435761)
                    guard seed % 10 < 6 else { continue }  // ~60% of columns rain
                    let speed = 3.0 + Double(seed % 100) / 100 * 5  // rows/second
                    let offset = Double(seed % 1000) / 1000 * span
                    let head = (t * speed + offset).truncatingRemainder(dividingBy: span)
                    for k in 0..<trail {
                        let row = Int(head) - k
                        guard row >= 0, row < rows else { continue }
                        let rect = CGRect(x: CGFloat(col) * cell + 1,
                                          y: CGFloat(row) * cell + 1,
                                          width: cell - 1.5, height: cell - 1.5)
                        let color: Color = k == 0 ? .white : .green
                        let alpha = k == 0 ? 0.9 : 0.5 * pow(0.6, Double(k))
                        context.fill(Path(rect), with: .color(color.opacity(alpha)))
                    }
                }
            }
        }
    }
}

/// 生命游戏: Conway's Game of Life on a toroidal grid, reseeded when it dies
/// out, gets stuck, or after ~45s so it never sits still forever.
private struct GameOfLifePixels: View {
    @State private var grid: [[Bool]] = []
    @State private var stale = 0
    @State private var steps = 0
    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()
    private let cell: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                for (row, line) in grid.enumerated() {
                    for (col, alive) in line.enumerated() where alive {
                        let rect = CGRect(x: CGFloat(col) * cell + 1,
                                          y: CGFloat(row) * cell + 1,
                                          width: cell - 1, height: cell - 1)
                        context.fill(Path(rect), with: .color(.mint.opacity(0.75)))
                    }
                }
            }
            .onAppear { reseed(geo.size) }
            .onReceive(timer) { _ in step(geo.size) }
        }
    }

    private func dims(_ size: CGSize) -> (rows: Int, cols: Int) {
        (max(3, Int(size.height / cell)), max(3, Int(size.width / cell)))
    }

    private func reseed(_ size: CGSize) {
        let (rows, cols) = dims(size)
        grid = (0..<rows).map { _ in (0..<cols).map { _ in Double.random(in: 0...1) < 0.3 } }
        stale = 0
        steps = 0
    }

    private func step(_ size: CGSize) {
        let (rows, cols) = dims(size)
        guard grid.count == rows, grid.first?.count == cols else { return reseed(size) }
        var next = grid
        for row in 0..<rows {
            for col in 0..<cols {
                var neighbors = 0
                for dr in -1...1 {
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        if grid[(row + dr + rows) % rows][(col + dc + cols) % cols] { neighbors += 1 }
                    }
                }
                next[row][col] = grid[row][col] ? (neighbors == 2 || neighbors == 3) : neighbors == 3
            }
        }
        stale = next == grid ? stale + 1 : 0
        grid = next
        steps += 1
        let population = grid.reduce(0) { $0 + $1.lazy.filter { $0 }.count }
        if population == 0 || stale > 3 || steps > 150 { reseed(size) }
    }
}

/// 星光闪烁: a sparse field of tiny colored pixels breathing on their own
/// phase. Stateless per-cell hash.
private struct TwinkleFieldPixels: View {
    private static let palette: [Color] = [.cyan, .mint, .orange, .pink, .purple, .white]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let cell: CGFloat = 3
                let gap: CGFloat = 4
                for col in 0..<max(1, Int(size.width / (cell + gap))) {
                    for row in 0..<max(1, Int(size.height / (cell + gap))) {
                        let seed = UInt32(truncatingIfNeeded: (col &* 73856093) ^ (row &* 19349663))
                        let h = Double(seed % 1000) / 1000
                        guard h > 0.62 else { continue }
                        let speed: Double = 0.8 + h * 1.6
                        let phase: Double = h * Double.pi * 2
                        let brightness: Double = max(0, sin(t * speed + phase))
                        guard brightness > 0.05 else { continue }
                        let rect = CGRect(x: CGFloat(col) * (cell + gap) + gap / 2,
                                          y: CGFloat(row) * (cell + gap) + gap / 2,
                                          width: cell, height: cell)
                        let color = Self.palette[Int(seed % UInt32(Self.palette.count))]
                        context.fill(Path(rect), with: .color(color.opacity(0.15 + 0.55 * brightness * brightness)))
                    }
                }
            }
        }
    }
}

/// 像素萌宠: a small square-bodied pixel pet with antenna ears, sitting in
/// place while breathing and blinking. Stateless — everything derives from
/// the clock.
private struct PixelPetPixels: View {
    private static let eyesOpen: [String] = [
        "a.......a",
        ".#######.",
        "#########",
        "##o###o##",
        "#########",
        "#########",
        "#########",
        ".#######.",
    ]
    private static let eyesClosed: [String] = [
        "a.......a",
        ".#######.",
        "#########",
        "##_###_##",
        "#########",
        "#########",
        "#########",
        ".#######.",
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let px = max(2, ((size.height - 4) / 8).rounded(.down))
                let spriteWidth = 9 * px
                let spriteHeight = 8 * px
                let x0 = (size.width - spriteWidth) / 2
                let bob = sin(t * 1.4) * min(1.5, px * 0.3)
                let y0 = (size.height - spriteHeight) / 2 + bob

                let blinking = t.truncatingRemainder(dividingBy: 3.2) < 0.15
                let rows = blinking ? Self.eyesClosed : Self.eyesOpen
                let earSway = sin(t * 2.2) * min(1.0, px * 0.2)

                for (row, line) in rows.enumerated() {
                    for (col, ch) in line.enumerated() where ch != "." && ch != "_" {
                        let dx: CGFloat = ch == "a" ? (col == 0 ? -earSway : earSway) : 0
                        let rect = CGRect(x: x0 + CGFloat(col) * px + dx,
                                          y: y0 + CGFloat(row) * px,
                                          width: px, height: px)
                        let color: Color
                        switch ch {
                        case "a", "o":
                            color = .black
                        default:
                            color = row < 4
                                ? Color(red: 1.0, green: 0.6, blue: 0.15)
                                : Color(red: 0.92, green: 0.35, blue: 0.25)
                        }
                        context.fill(Path(rect), with: .color(color.opacity(0.9)))
                    }
                }
            }
        }
    }
}

/// 贪吃蛇: a small retro snake chasing food on a pixel grid.
/// AI: BFS shortest path to food, taken only if the snake can still reach its
/// own tail afterwards; otherwise it chases its tail to stay alive.
private struct SnakePixels: View {
    struct Point: Hashable {
        var x: Int
        var y: Int
    }

    @State private var snake: [Point] = []
    @State private var food: Point = Point(x: 0, y: 0)
    @State private var steps = 0
    @State private var stepsSinceFood = 0
    @State private var isGameOver = false
    @State private var gameOverTimer = 0
    private let timer = Timer.publish(every: 0.14, on: .main, in: .common).autoconnect()
    private let cell: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                // Pulsing food with a soft glow
                if !isGameOver {
                    let pulse = 0.7 + 0.3 * abs(sin(Double(steps) * 0.45))
                    let s = (cell - 1) * pulse
                    let cx = CGFloat(food.x) * cell + cell / 2
                    let cy = CGFloat(food.y) * cell + cell / 2
                    let foodRect = CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s)
                    context.fill(Path(ellipseIn: foodRect.insetBy(dx: -2, dy: -2)),
                                 with: .color(.red.opacity(0.25)))
                    context.fill(Path(ellipseIn: foodRect),
                                 with: .color(Color(red: 1.0, green: 0.32, blue: 0.28)))
                }

                // Snake: rounded segments, hue drifting green→teal toward the tail
                let count = max(snake.count - 1, 1)
                for (index, segment) in snake.enumerated() {
                    let rect = CGRect(x: CGFloat(segment.x) * cell + 0.5,
                                      y: CGFloat(segment.y) * cell + 0.5,
                                      width: cell - 1, height: cell - 1)
                    let color: Color
                    if isGameOver {
                        color = .gray
                    } else if index == 0 {
                        color = .white
                    } else {
                        let t = Double(index) / Double(count)
                        color = Color(hue: 0.36 + 0.14 * t,
                                      saturation: 0.85,
                                      brightness: 0.95 - 0.35 * t)
                    }
                    context.fill(Path(roundedRect: rect, cornerRadius: 2),
                                 with: .color(color.opacity(0.9)))
                }

                // Eyes on the head, offset toward travel direction
                if !isGameOver, snake.count > 1 {
                    let head = snake[0], neck = snake[1]
                    let dx = CGFloat(head.x - neck.x), dy = CGFloat(head.y - neck.y)
                    let cx = CGFloat(head.x) * cell + cell / 2 + dx
                    let cy = CGFloat(head.y) * cell + cell / 2 + dy
                    // Perpendicular offset separates the two eyes
                    for side: CGFloat in [-1, 1] {
                        let eye = CGRect(x: cx - dy * side * 1.2 - 0.6,
                                         y: cy - dx * side * 1.2 - 0.6,
                                         width: 1.2, height: 1.2)
                        context.fill(Path(ellipseIn: eye), with: .color(.black.opacity(0.85)))
                    }
                }

                if isGameOver {
                    let text = Text("GAME OVER")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                    context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
                }
            }
            .onAppear { reseed(geo.size) }
            .onReceive(timer) { _ in step(geo.size) }
        }
    }

    private func dims(_ size: CGSize) -> (rows: Int, cols: Int) {
        (max(3, Int(size.height / cell)), max(3, Int(size.width / cell)))
    }

    private func reseed(_ size: CGSize) {
        let (rows, cols) = dims(size)
        guard rows > 2, cols > 4 else { return }

        let midY = rows / 2
        let midX = cols / 2
        snake = [
            Point(x: midX, y: midY),
            Point(x: midX - 1, y: midY),
            Point(x: midX - 2, y: midY)
        ]

        spawnFood(rows: rows, cols: cols)
        steps = 0
        stepsSinceFood = 0
        isGameOver = false
        gameOverTimer = 0
    }

    /// Places food on a random free cell; reseeds when the board is full (= win).
    private func spawnFood(rows: Int, cols: Int) {
        let body = Set(snake)
        let free = (0..<cols).flatMap { x in
            (0..<rows).compactMap { y -> Point? in
                let p = Point(x: x, y: y)
                return body.contains(p) ? nil : p
            }
        }
        if let candidate = free.randomElement() {
            food = candidate
        } else {
            snake = []
        }
    }

    private func neighbors(_ p: Point, rows: Int, cols: Int) -> [Point] {
        [Point(x: p.x + 1, y: p.y), Point(x: p.x - 1, y: p.y),
         Point(x: p.x, y: p.y + 1), Point(x: p.x, y: p.y - 1)]
            .filter { $0.x >= 0 && $0.x < cols && $0.y >= 0 && $0.y < rows }
    }

    /// BFS shortest path from `start` to `goal` avoiding `blocked` (goal itself is
    /// always enterable). Returns the path excluding `start`, or nil if unreachable.
    private func bfsPath(from start: Point, to goal: Point, blocked: Set<Point>,
                         rows: Int, cols: Int) -> [Point]? {
        var queue = [start]
        var qi = 0
        var cameFrom: [Point: Point] = [:]
        var visited: Set<Point> = [start]
        while qi < queue.count {
            let p = queue[qi]
            qi += 1
            if p == goal {
                var path: [Point] = []
                var cur = p
                while cur != start {
                    path.append(cur)
                    cur = cameFrom[cur]!
                }
                return path.reversed()
            }
            for n in neighbors(p, rows: rows, cols: cols)
            where !visited.contains(n) && (n == goal || !blocked.contains(n)) {
                visited.insert(n)
                cameFrom[n] = p
                queue.append(n)
            }
        }
        return nil
    }

    /// After walking `path` to the food (growing by 1), can the snake still reach
    /// its own tail? Reaching the tail guarantees it is not boxed in.
    private func isSafeAfterEating(path: [Point], rows: Int, cols: Int) -> Bool {
        let future = Array((path.reversed() + snake).prefix(snake.count + 1))
        guard let newHead = future.first, let newTail = future.last else { return false }
        let blocked = Set(future.dropLast())
        return bfsPath(from: newHead, to: newTail, blocked: blocked,
                       rows: rows, cols: cols) != nil
    }

    private func step(_ size: CGSize) {
        if isGameOver {
            gameOverTimer -= 1
            if gameOverTimer <= 0 {
                reseed(size)
            }
            return
        }

        let (rows, cols) = dims(size)
        guard rows > 2, cols > 4 else { return }
        guard let head = snake.first, let tail = snake.last,
              head.x < cols, head.y < rows else {
            reseed(size)
            return
        }

        let body = Set(snake)
        var nextMove: Point?

        // Hunger breaks the tail-chase livelock: after ~1 board sweep without
        // eating, gamble on the food path even if the post-eat safety check
        // fails; after 2 sweeps, restart rather than loop forever.
        let starving = stepsSinceFood > rows * cols
        if stepsSinceFood > rows * cols * 2 {
            reseed(size)
            return
        }

        // 1. Shortest path to food, but only if we stay able to reach our tail after.
        var foodObstacles = body
        foodObstacles.remove(tail) // tail vacates as we advance
        if let path = bfsPath(from: head, to: food, blocked: foodObstacles,
                              rows: rows, cols: cols),
           starving || isSafeAfterEating(path: path, rows: rows, cols: cols) {
            nextMove = path.first
        }

        // 2. Otherwise chase the tail — always survivable while a tail path exists.
        if nextMove == nil,
           let path = bfsPath(from: head, to: tail, blocked: body.subtracting([tail]),
                              rows: rows, cols: cols),
           let first = path.first, first != food || path.count > 1 {
            nextMove = first
        }

        // 3. Last resort: any legal move.
        if nextMove == nil {
            nextMove = neighbors(head, rows: rows, cols: cols)
                .first { !body.contains($0) }
        }

        guard let move = nextMove else {
            isGameOver = true
            gameOverTimer = 14 // pause ~2s before restarting
            return
        }

        snake.insert(move, at: 0)
        if move == food {
            spawnFood(rows: rows, cols: cols)
            stepsSinceFood = 0
        } else {
            snake.removeLast()
            stepsSinceFood += 1
        }
        steps += 1
    }
}

/// 温馨篝火: a cozy campfire animation with rising sparks and flickers.
private struct CampfirePixels: View {
    struct Ember: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var life: Double // 1.0 down to 0.0
        var size: CGFloat
        var color: Color
    }

    @State private var embers: [Ember] = []
    @State private var frameCounter = 0
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let midX = size.width / 2
                let groundY = size.height - 2
                let actionFrame = (frameCounter / 8) % 2
                let wiggle = CGFloat(frameCounter % 2)

                // 1. Draw Two People Warming Hands
                let skinColor = Color(red: 0.95, green: 0.75, blue: 0.65)
                let blueCoat = Color(red: 0.2, green: 0.5, blue: 0.7)
                let redCoat = Color(red: 0.75, green: 0.3, blue: 0.3)

                // Left Person
                context.fill(Path(CGRect(x: midX - 22, y: groundY - 12, width: 3, height: 3)), with: .color(skinColor)) // Head
                context.fill(Path(CGRect(x: midX - 23, y: groundY - 9, width: 4, height: 7)), with: .color(blueCoat))  // Body
                if actionFrame == 0 {
                    context.fill(Path(CGRect(x: midX - 19, y: groundY - 7, width: 3, height: 1.5)), with: .color(skinColor)) // Extend hand
                } else {
                    context.fill(Path(CGRect(x: midX - 21, y: groundY - 7.5 + wiggle, width: 2, height: 1.5)), with: .color(skinColor)) // Rub hand
                }

                // Right Person
                context.fill(Path(CGRect(x: midX + 19, y: groundY - 12, width: 3, height: 3)), with: .color(skinColor)) // Head
                context.fill(Path(CGRect(x: midX + 19, y: groundY - 9, width: 4, height: 7)), with: .color(redCoat))   // Body
                if actionFrame == 0 {
                    context.fill(Path(CGRect(x: midX + 16, y: groundY - 7, width: 3, height: 1.5)), with: .color(skinColor)) // Extend hand
                } else {
                    context.fill(Path(CGRect(x: midX + 19, y: groundY - 7.5 + wiggle, width: 2, height: 1.5)), with: .color(skinColor)) // Rub hand
                }

                // 2. Draw Fire Logs (Larger)
                let logPath = Path { path in
                    path.addRect(CGRect(x: midX - 12, y: groundY - 3, width: 24, height: 3))
                    path.addRect(CGRect(x: midX - 8, y: groundY - 6, width: 16, height: 3))
                }
                context.fill(logPath, with: .color(Color(red: 0.45, green: 0.25, blue: 0.1)))

                // 3. Draw Embers/Flames
                for ember in embers {
                    let rect = CGRect(
                        x: ember.x - ember.size / 2,
                        y: ember.y - ember.size / 2,
                        width: ember.size,
                        height: ember.size
                    )
                    context.fill(Path(rect), with: .color(ember.color.opacity(ember.life)))
                }
            }
            .onReceive(timer) { _ in
                updateCampfire(geo.size)
            }
        }
    }

    private func updateCampfire(_ size: CGSize) {
        let midX = size.width / 2
        let groundY = size.height - 4
        frameCounter += 1

        // Update existing embers
        var nextEmbers: [Ember] = []
        for var ember in embers {
            ember.x += ember.vx
            ember.y += ember.vy
            ember.life -= Double.random(in: 0.05...0.10)
            
            // Flicker size
            ember.size = max(1.0, ember.size * 0.9)
            
            // Shift color towards red/dark as it dies
            if ember.life < 0.4 {
                ember.color = .red
            } else if ember.life < 0.7 {
                ember.color = .orange
            }

            if ember.life > 0 && ember.y > 0 {
                nextEmbers.append(ember)
            }
        }

        // Spawn new flames/embers at the center (Larger and richer fire)
        let spawnCount = Int.random(in: 2...4)
        for _ in 0..<spawnCount {
            let colors: [Color] = [.white, .yellow, .orange]
            let color = colors.randomElement() ?? .orange
            
            let newEmber = Ember(
                x: midX + CGFloat.random(in: -6...6),
                y: groundY,
                vx: CGFloat.random(in: -1.2...1.2),
                vy: CGFloat.random(in: (-2.5)...(-1.0)),
                life: Double.random(in: 0.8...1.0),
                size: CGFloat.random(in: 4.0...9.0),
                color: color
            )
            nextEmbers.append(newEmber)
        }
        
        embers = nextEmbers
    }
}

/// 像素水族馆: neon pixel fish swim left/right and turn around at bounds, with rising bubbles.
private struct AquariumPixels: View {
    struct Fish: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var dx: CGFloat // direction: -1 or 1
        var speed: CGFloat
        var color: Color
        var size: CGFloat
    }
    struct Bubble: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var vy: CGFloat
        var size: CGFloat
    }

    @State private var fishList: [Fish] = []
    @State private var bubbles: [Bubble] = []
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                // Draw bubbles
                for bubble in bubbles {
                    let rect = CGRect(x: bubble.x, y: bubble.y, width: bubble.size, height: bubble.size)
                    context.fill(Path(rect), with: .color(.cyan.opacity(0.4)))
                }

                // Draw fish
                for fish in fishList {
                    // Simple fish shape depending on direction
                    let fishRect = CGRect(x: fish.x, y: fish.y, width: fish.size * 2, height: fish.size)
                    context.fill(Path(fishRect), with: .color(fish.color))
                    
                    // Tail fin
                    let tailX = fish.dx > 0 ? fish.x - 2 : fish.x + fish.size * 2
                    let tailRect = CGRect(x: tailX, y: fish.y + fish.size / 4, width: 2, height: fish.size / 2)
                    context.fill(Path(tailRect), with: .color(fish.color.opacity(0.7)))
                }
            }
            .onAppear {
                initAquarium(geo.size)
            }
            .onReceive(timer) { _ in
                updateAquarium(geo.size)
            }
        }
    }

    private func initAquarium(_ size: CGSize) {
        guard size.width > 0 else { return }
        let colors: [Color] = [.orange, .cyan, .pink, .yellow]
        fishList = (0..<3).map { i in
            Fish(
                x: CGFloat.random(in: 20...(size.width - 20)),
                y: CGFloat.random(in: 4...(size.height - 10)),
                dx: Bool.random() ? 1.0 : -1.0,
                speed: CGFloat.random(in: 1.0...2.5),
                color: colors[i % colors.count],
                size: 5
            )
        }
        bubbles = (0..<5).map { _ in
            Bubble(
                x: CGFloat.random(in: 10...(size.width - 10)),
                y: CGFloat.random(in: 0...size.height),
                vy: CGFloat.random(in: (-1.5)...(-0.5)),
                size: CGFloat.random(in: 1...2)
            )
        }
    }

    private func updateAquarium(_ size: CGSize) {
        guard size.width > 0 else { return }
        if fishList.isEmpty { initAquarium(size) }

        // Update fish
        for i in 0..<fishList.count {
            fishList[i].x += fishList[i].dx * fishList[i].speed
            // Bound collision
            if fishList[i].dx > 0 && fishList[i].x > size.width - 10 {
                fishList[i].dx = -1.0
            } else if fishList[i].dx < 0 && fishList[i].x < 10 {
                fishList[i].dx = 1.0
            }
        }

        // Update bubbles
        var nextBubbles: [Bubble] = []
        for var bubble in bubbles {
            bubble.y += bubble.vy
            if bubble.y > 0 {
                nextBubbles.append(bubble)
            } else {
                // Respawn at bottom
                nextBubbles.append(Bubble(
                    x: CGFloat.random(in: 10...(size.width - 10)),
                    y: size.height,
                    vy: CGFloat.random(in: (-1.5)...(-0.5)),
                    size: CGFloat.random(in: 1...2)
                ))
            }
        }
        bubbles = nextBubbles
    }
}

/// 太空射击: horizontal retro shooter ship firing lasers at incoming obstacles.
private struct ShmupPixels: View {
    struct Laser: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
    }
    struct Asteroid: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var speed: CGFloat
        var size: CGFloat
    }
    struct Spark: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var life: Double
        var color: Color
    }

    @State private var shipY: CGFloat = 10
    @State private var lasers: [Laser] = []
    @State private var asteroids: [Asteroid] = []
    @State private var sparks: [Spark] = []
    @State private var frameCounter = 0
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                // Draw ship (sleek retro jet fighter plane)
                let planePath = Path { path in
                    // Start at nose (x: 18, y: shipY)
                    path.move(to: CGPoint(x: 18, y: shipY))
                    // Fuselage top to front of wing
                    path.addLine(to: CGPoint(x: 13, y: shipY - 1.5))
                    // Wing leading edge sweeps back
                    path.addLine(to: CGPoint(x: 9, y: shipY - 5))
                    // Wing tip
                    path.addLine(to: CGPoint(x: 7, y: shipY - 5))
                    // Wing trailing edge sweeps forward
                    path.addLine(to: CGPoint(x: 10, y: shipY - 1.5))
                    // Fuselage top to tail
                    path.addLine(to: CGPoint(x: 5, y: shipY - 1.5))
                    // Tail fin top leading edge sweeps back
                    path.addLine(to: CGPoint(x: 3, y: shipY - 4))
                    // Tail fin top tip
                    path.addLine(to: CGPoint(x: 2, y: shipY - 4))
                    // Tail trailing edge to back-center engine nozzle
                    path.addLine(to: CGPoint(x: 4, y: shipY))
                    
                    // Mirror for bottom side:
                    // Tail fin bottom tip
                    path.addLine(to: CGPoint(x: 2, y: shipY + 4))
                    path.addLine(to: CGPoint(x: 3, y: shipY + 4))
                    // Fuselage bottom to wing trailing edge
                    path.addLine(to: CGPoint(x: 5, y: shipY + 1.5))
                    path.addLine(to: CGPoint(x: 10, y: shipY + 1.5))
                    // Wing trailing edge
                    path.addLine(to: CGPoint(x: 7, y: shipY + 5))
                    // Wing tip
                    path.addLine(to: CGPoint(x: 9, y: shipY + 5))
                    // Wing leading edge back to fuselage
                    path.addLine(to: CGPoint(x: 13, y: shipY + 1.5))
                    
                    path.closeSubpath()
                }
                context.fill(planePath, with: .color(.cyan))

                // Engine exhaust fire (animated/flickering)
                let fireOffset = (frameCounter % 2 == 0) ? CGFloat(2) : CGFloat(5)
                let engineFirePath = Path { path in
                    path.move(to: CGPoint(x: 4, y: shipY - 1))
                    path.addLine(to: CGPoint(x: 4 - fireOffset, y: shipY))
                    path.addLine(to: CGPoint(x: 4, y: shipY + 1))
                    path.closeSubpath()
                }
                context.fill(engineFirePath, with: .color(.orange))

                // Cockpit window (tiny white details)
                let cockpitRect = CGRect(x: 13, y: shipY - 0.75, width: 2, height: 1.5)
                context.fill(Path(cockpitRect), with: .color(.white))

                // Draw lasers (red rays)
                for laser in lasers {
                    let laserRect = CGRect(x: laser.x, y: laser.y, width: 6, height: 1.5)
                    context.fill(Path(laserRect), with: .color(.red))
                }

                // Draw asteroids (gray)
                for asteroid in asteroids {
                    let path = Path(ellipseIn: CGRect(x: asteroid.x, y: asteroid.y - asteroid.size / 2, width: asteroid.size, height: asteroid.size))
                    context.fill(path, with: .color(.gray))
                }

                // Draw sparks
                for spark in sparks {
                    let rect = CGRect(x: spark.x, y: spark.y, width: 1.5, height: 1.5)
                    context.fill(Path(rect), with: .color(spark.color.opacity(spark.life)))
                }
            }
            .onReceive(timer) { _ in
                updateShmup(geo.size)
            }
        }
    }

    private func updateShmup(_ size: CGSize) {
        guard size.width > 0 else { return }
        frameCounter += 1

        // Ship movement (automatic sine wave)
        let t = Double(frameCounter) * 0.15
        shipY = size.height / 2 + CGFloat(sin(t) * Double(size.height / 3))

        // Shoot lasers periodically
        if frameCounter % 5 == 0 {
            lasers.append(Laser(x: 18, y: shipY - 0.75))
        }

        // Move lasers
        lasers = lasers.map { var l = $0; l.x += 8; return l }.filter { $0.x < size.width }

        // Spawn asteroids periodically
        if frameCounter % 15 == 0 {
            asteroids.append(Asteroid(
                x: size.width + 10,
                y: CGFloat.random(in: 4...(size.height - 8)),
                speed: CGFloat.random(in: 2.0...4.0),
                size: CGFloat.random(in: 4...8)
            ))
        }

        // Move asteroids
        asteroids = asteroids.map { var a = $0; a.x -= a.speed; return a }.filter { $0.x > -10 }

        // Bullet-asteroid collisions
        var nextLasers: [Laser] = []
        var nextAsteroids = asteroids
        
        for laser in lasers {
            var hit = false
            for (idx, asteroid) in nextAsteroids.enumerated() {
                // Check simple bounding box collision
                let distY = abs(laser.y - asteroid.y)
                let distX = laser.x - asteroid.x
                if distX >= 0 && distX <= asteroid.size && distY <= asteroid.size / 2 + 2 {
                    hit = true
                    // Spawn explosion sparks
                    for _ in 0..<8 {
                        sparks.append(Spark(
                            x: asteroid.x + asteroid.size / 2,
                            y: asteroid.y,
                            vx: CGFloat.random(in: -3...3),
                            vy: CGFloat.random(in: -3...3),
                            life: 1.0,
                            color: Bool.random() ? .yellow : .orange
                        ))
                    }
                    nextAsteroids.remove(at: idx)
                    break
                }
            }
            if !hit {
                nextLasers.append(laser)
            }
        }
        lasers = nextLasers
        asteroids = nextAsteroids

        // Update sparks
        var nextSparks: [Spark] = []
        for var spark in sparks {
            spark.x += spark.vx
            spark.y += spark.vy
            spark.life -= 0.1
            if spark.life > 0 {
                nextSparks.append(spark)
            }
        }
        sparks = nextSparks
    }
}

/// 像素乒乓: classic Pong game simulating two paddles playing automatically against each other.
private struct PongPixels: View {
    @State private var ballX: CGFloat = 50
    @State private var ballY: CGFloat = 10
    @State private var ballDX: CGFloat = 3.0
    @State private var ballDY: CGFloat = 1.5
    
    @State private var paddleLeftY: CGFloat = 10
    @State private var paddleRightY: CGFloat = 10
    
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let paddleHeight: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                // Draw middle dotted line
                let midX = size.width / 2
                var dY: CGFloat = 0
                while dY < size.height {
                    let rect = CGRect(x: midX - 0.5, y: dY, width: 1, height: 2)
                    context.fill(Path(rect), with: .color(.white.opacity(0.15)))
                    dY += 4
                }

                // Draw Left Paddle
                let leftRect = CGRect(x: 4, y: paddleLeftY - paddleHeight / 2, width: 2, height: paddleHeight)
                context.fill(Path(leftRect), with: .color(.white))

                // Draw Right Paddle
                let rightRect = CGRect(x: size.width - 6, y: paddleRightY - paddleHeight / 2, width: 2, height: paddleHeight)
                context.fill(Path(rightRect), with: .color(.white))

                // Draw Ball
                let ballRect = CGRect(x: ballX - 1, y: ballY - 1, width: 2, height: 2)
                context.fill(Path(ballRect), with: .color(.yellow))
            }
            .onAppear {
                resetBall(geo.size)
            }
            .onReceive(timer) { _ in
                updatePong(geo.size)
            }
        }
    }

    private func resetBall(_ size: CGSize) {
        ballX = size.width / 2
        ballY = size.height / 2
        ballDX = Bool.random() ? 3.0 : -3.0
        ballDY = CGFloat.random(in: -1.5...1.5)
        paddleLeftY = size.height / 2
        paddleRightY = size.height / 2
    }

    private func updatePong(_ size: CGSize) {
        guard size.width > 0 else { return }

        // Move Ball
        ballX += ballDX
        ballY += ballDY

        // Collision with top & bottom
        if ballY <= 1 {
            ballY = 1
            ballDY = -ballDY
        } else if ballY >= size.height - 1 {
            ballY = size.height - 1
            ballDY = -ballDY
        }

        // Left paddle tracking ball (with some delay/speed limit to look natural)
        let targetLeft = ballY
        let diffLeft = targetLeft - paddleLeftY
        paddleLeftY += diffLeft * 0.22

        // Right paddle tracking ball
        let targetRight = ballY
        let diffRight = targetRight - paddleRightY
        paddleRightY += diffRight * 0.22

        // Paddle boundaries
        paddleLeftY = min(size.height - paddleHeight / 2, max(paddleHeight / 2, paddleLeftY))
        paddleRightY = min(size.height - paddleHeight / 2, max(paddleHeight / 2, paddleRightY))

        // Collision with Left Paddle
        if ballDX < 0 && ballX <= 6 && ballX >= 4 {
            if ballY >= paddleLeftY - paddleHeight / 2 - 1 && ballY <= paddleLeftY + paddleHeight / 2 + 1 {
                ballX = 6
                ballDX = -ballDX
                // Add vertical variation based on where it hit
                ballDY += (ballY - paddleLeftY) * 0.3
            }
        }

        // Collision with Right Paddle
        if ballDX > 0 && ballX >= size.width - 8 && ballX <= size.width - 6 {
            if ballY >= paddleRightY - paddleHeight / 2 - 1 && ballY <= paddleRightY + paddleHeight / 2 + 1 {
                ballX = size.width - 8
                ballDX = -ballDX
                ballDY += (ballY - paddleRightY) * 0.3
            }
        }

        // Out of bounds reset
        if ballX < 0 || ballX > size.width {
            resetBall(size)
        }
    }
}

/// 彩虹猫: classic animated Nyan Cat with a waving rainbow trail.
private struct NyanCatPixels: View {
    private let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple]
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    @State private var tOffset: Double = 0.0

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let midY = size.height / 2
                let catX = size.width / 2 - 10
                
                // Draw waving rainbow trail
                let waveAmplitude: CGFloat = 2.0
                let waveFrequency: CGFloat = 0.15
                
                for col in stride(from: 0.0, to: catX + 2, by: 3.0) {
                    let phase = col * waveFrequency - tOffset * 4
                    let waveY = midY + sin(phase) * waveAmplitude
                    
                    // Draw vertical colored stripe stack
                    for (index, color) in colors.enumerated() {
                        let stripeHeight: CGFloat = 2
                        let rY = waveY - 6 + CGFloat(index) * stripeHeight
                        let rect = CGRect(x: col, y: rY, width: 3, height: stripeHeight)
                        context.fill(Path(rect), with: .color(color))
                    }
                }

                // Draw Nyan Cat (10x8 pixels boxy representation)
                let bobY = midY - 4 + sin(tOffset * 8) * 0.8
                
                // Feet (moving toggle)
                let legToggle = Int(tOffset * 8) % 2 == 0
                
                // Pop-Tart Body (Pink filling, beige crust)
                let bodyRect = CGRect(x: catX, y: bobY + 1, width: 14, height: 8)
                context.fill(Path(bodyRect), with: .color(Color(red: 0.9, green: 0.7, blue: 0.5))) // Crust
                let fillingRect = CGRect(x: catX + 2, y: bobY + 2, width: 10, height: 6)
                context.fill(Path(fillingRect), with: .color(.pink)) // Filling
                
                // Sprinkles
                context.fill(Path(CGRect(x: catX + 4, y: bobY + 3, width: 1, height: 1)), with: .color(.red))
                context.fill(Path(CGRect(x: catX + 8, y: bobY + 4, width: 1, height: 1)), with: .color(.red))
                context.fill(Path(CGRect(x: catX + 6, y: bobY + 6, width: 1, height: 1)), with: .color(.red))

                // Head (Grey)
                let headRect = CGRect(x: catX + 11, y: bobY + 2, width: 6, height: 5)
                context.fill(Path(headRect), with: .color(.gray))
                // Ears
                context.fill(Path(CGRect(x: catX + 12, y: bobY, width: 1.5, height: 2)), with: .color(.gray))
                context.fill(Path(CGRect(x: catX + 15, y: bobY, width: 1.5, height: 2)), with: .color(.gray))
                // Eyes (Black)
                context.fill(Path(CGRect(x: catX + 13, y: bobY + 3, width: 1, height: 1)), with: .color(.black))
                context.fill(Path(CGRect(x: catX + 15, y: bobY + 3, width: 1, height: 1)), with: .color(.black))
                // Cheeks (Rose pink)
                context.fill(Path(CGRect(x: catX + 12, y: bobY + 5, width: 1, height: 1)), with: .color(.pink))
                context.fill(Path(CGRect(x: catX + 16, y: bobY + 5, width: 1, height: 1)), with: .color(.pink))

                // Tail (Grey, waving)
                let tailY = bobY + 4 + (legToggle ? 1 : -1)
                context.fill(Path(CGRect(x: catX - 4, y: tailY, width: 4, height: 2)), with: .color(.gray))

                // Legs
                if legToggle {
                    context.fill(Path(CGRect(x: catX + 2, y: bobY + 9, width: 2, height: 1.5)), with: .color(.gray))
                    context.fill(Path(CGRect(x: catX + 10, y: bobY + 9, width: 2, height: 1.5)), with: .color(.gray))
                } else {
                    context.fill(Path(CGRect(x: catX + 4, y: bobY + 9, width: 2, height: 1.5)), with: .color(.gray))
                    context.fill(Path(CGRect(x: catX + 12, y: bobY + 9, width: 2, height: 1.5)), with: .color(.gray))
                }
            }
            .onReceive(timer) { _ in
                tOffset += 0.05
            }
        }
    }
}

/// 恐龙奔跑: automatic mini chrome dinosaur jumping over cactus obstacles.
private struct DinoRunPixels: View {
    // Classic 9x10 T-Rex sprite frames
    private static let dinoFrame1: [String] = [
        "....#####.",
        "....#.#.##",
        "....######",
        "....####..",
        "##..#####.",
        "#######...",
        ".#####....",
        "..##.##...",
        "..#...#..."
    ]
    private static let dinoFrame2: [String] = [
        "....#####.",
        "....#.#.##",
        "....######",
        "....####..",
        "##..#####.",
        "#######...",
        ".#####....",
        "...##.....",
        "....#....."
    ]

    @State private var dinoY: CGFloat = 0.0
    @State private var dinoVY: CGFloat = 0.0
    @State private var isJumping = false
    @State private var runFrame = false
    
    // Cacti x positions
    @State private var cactiX: [CGFloat] = []
    @State private var score = 0
    @State private var speed: CGFloat = 2.5
    
    private let timer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()
    private let groundOffsetY: CGFloat = 4.0

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let groundY = size.height - groundOffsetY
                
                // Draw ground line
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: groundY))
                    p.addLine(to: CGPoint(x: size.width, y: groundY))
                }, with: .color(.white.opacity(0.3)), lineWidth: 1)

                // Draw T-Rex Dino Sprite pixel-by-pixel (10x9 pixels)
                let dY = groundY - 9 + dinoY
                let dX: CGFloat = 20
                let spriteRows = runFrame ? Self.dinoFrame1 : Self.dinoFrame2
                
                for (rowIdx, line) in spriteRows.enumerated() {
                    for (colIdx, ch) in line.enumerated() where ch == "#" {
                        let pixelRect = CGRect(x: dX + CGFloat(colIdx), y: dY + CGFloat(rowIdx), width: 1, height: 1)
                        context.fill(Path(pixelRect), with: .color(.white))
                    }
                }

                // Draw Cacti (greenish vertical blocks)
                for cx in cactiX {
                    let path = Path { p in
                        p.addRect(CGRect(x: cx, y: groundY - 8, width: 3, height: 8)) // center trunk
                        p.addRect(CGRect(x: cx - 2, y: groundY - 6, width: 2, height: 3)) // left branch
                        p.addRect(CGRect(x: cx + 3, y: groundY - 7, width: 2, height: 4)) // right branch
                    }
                    context.fill(path, with: .color(.mint))
                }
            }
            .onAppear {
                resetGame(geo.size)
            }
            .onReceive(timer) { _ in
                updateGame(geo.size)
            }
        }
    }

    private func resetGame(_ size: CGSize) {
        dinoY = 0
        dinoVY = 0
        isJumping = false
        // Prevent cacti from spawning on top of the dino at startup (when size.width might be 0)
        let spawnWidth = size.width > 50 ? size.width : 300
        cactiX = [spawnWidth + 50, spawnWidth + 180]
        speed = 2.5
        score = 0
    }

    private func updateGame(_ size: CGSize) {
        guard size.width > 0 else { return }
        runFrame.toggle()

        // Move Cacti
        cactiX = cactiX.map { $0 - speed }
        
        // Spawn/recycling cacti
        cactiX = cactiX.filter { x in
            if x < -10 {
                score += 1
                if score % 5 == 0 {
                    speed = min(5.0, speed + 0.3)
                }
                return false
            }
            return true
        }
        
        if cactiX.isEmpty || (cactiX.last ?? 0) < size.width - CGFloat.random(in: 80...150) {
            cactiX.append(size.width + 10)
        }

        // Physics-based Automatic Jump trigger
        // Find nearest cactus in front of dino (collision point is roughly x=28)
        if let nextCactus = cactiX.first(where: { $0 > 24 }) {
            let ticksToCollision = (nextCactus - 26) / speed
            if ticksToCollision >= 0 && ticksToCollision < 6.0 && !isJumping {
                // Jump!
                dinoVY = -5.0
                isJumping = true
            }
        }

        // Apply physics
        if isJumping {
            dinoY += dinoVY
            dinoVY += 0.75 // Gravity
            if dinoY >= 0 {
                dinoY = 0
                dinoVY = 0
                isJumping = false
            }
        }

        // Collide if overlapping bounds
        for cx in cactiX {
            if cx >= 15 && cx <= 30 {
                if dinoY > -8.0 {
                    resetGame(size)
                    break
                }
            }
        }
    }
}

/// 电子木鱼: a pixel-art wooden fish struck from above by a mallet, with
/// "功德+1" floating up on its left. Fish scales with the bar height.
private struct WoodenFishPixels: View {
    // 17×11 muyu sprite: round body, classic slit mouth on the lower left.
    // '#' wood, 'o' highlight.
    private static let sprite: [String] = [
        ".....#######.....",
        "...####oo######..",
        "..####oo#######..",
        ".###############.",
        "#################",
        "#################",
        "#.......#########",
        "##.....##########",
        ".###############.",
        "..#############..",
        "....#########....",
    ]

    private static let wood = Color(red: 0.72, green: 0.53, blue: 0.34)
    private static let woodLight = Color(red: 0.85, green: 0.68, blue: 0.48)

    struct FloatingText: Identifiable {
        let id = UUID()
        var yOffset: CGFloat
        var opacity: Double
    }

    @State private var floatingTexts: [FloatingText] = []
    @State private var frameCounter = 0
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let t = frameCounter % 24  // 24 * 0.05s = 1.2s cycle

                let px = max(1.5, ((size.height - 4) / 11).rounded(.down))
                let fishW = 17 * px
                let fishH = 11 * px
                // Fish sits slightly right of center, leaving room for text.
                let fx0 = size.width / 2 - fishW / 2 + 10
                let fy0 = size.height - 1 - fishH  // grounded at the bottom

                // 1. Mallet strike progress: 0 = raised, 1 = hitting the top.
                let strike: CGFloat
                if t < 3 {
                    strike = CGFloat(t) / 3
                } else if t < 8 {
                    strike = 1 - CGFloat(t - 3) / 5
                } else {
                    strike = 0
                }

                // 2. Wooden fish, squashed vertically on impact.
                let squash: CGFloat = (t >= 3 && t <= 5) ? 0.88 : 1.0
                context.drawLayer { ctx in
                    let cx = fx0 + fishW / 2
                    ctx.translateBy(x: cx, y: fy0 + fishH)
                    ctx.scaleBy(x: 2 - squash, y: squash)
                    ctx.translateBy(x: -cx, y: -(fy0 + fishH))
                    for (rowIdx, line) in Self.sprite.enumerated() {
                        for (colIdx, ch) in line.enumerated() where ch != "." {
                            let rect = CGRect(x: fx0 + CGFloat(colIdx) * px,
                                              y: fy0 + CGFloat(rowIdx) * px,
                                              width: px, height: px)
                            ctx.fill(Path(rect), with: .color(ch == "o" ? Self.woodLight : Self.wood))
                        }
                    }
                }

                // 3. Mallet striking straight down onto the fish top.
                let headR = 1.6 * px
                let gap = 4 * px  // travel distance above the fish
                let headX = fx0 + fishW / 2
                let headY = fy0 - headR - gap * (1 - strike)
                let stick = Path { p in
                    p.move(to: CGPoint(x: headX, y: headY))
                    p.addLine(to: CGPoint(x: headX + 7 * px, y: max(1, headY - 4 * px)))
                }
                context.stroke(stick, with: .color(.gray), lineWidth: max(1.5, px * 0.7))
                let headRect = CGRect(x: headX - headR, y: headY - headR,
                                      width: headR * 2, height: headR * 2)
                context.fill(Path(ellipseIn: headRect), with: .color(Self.woodLight))

                // 4. Floating merit text, rising on the fish's left.
                for textItem in floatingTexts {
                    let text = Text("功德+1")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.yellow.opacity(textItem.opacity))
                    context.draw(
                        text,
                        at: CGPoint(x: max(20, fx0 - 24),
                                    y: size.height / 2 + 6 - textItem.yOffset),
                        anchor: .center
                    )
                }
            }
            .onReceive(timer) { _ in
                updateWoodenFish()
            }
        }
    }

    private func updateWoodenFish() {
        frameCounter += 1
        let t = frameCounter % 24

        // Add merit text on hit
        if t == 3 {
            floatingTexts.append(FloatingText(yOffset: 0, opacity: 1.0))
        }

        // Update floating texts
        var nextTexts: [FloatingText] = []
        for var textItem in floatingTexts {
            textItem.yOffset += 0.8
            textItem.opacity -= 0.05
            if textItem.opacity > 0 {
                nextTexts.append(textItem)
            }
        }
        floatingTexts = nextTexts
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
