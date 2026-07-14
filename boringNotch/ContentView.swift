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
                      } else if coordinator.sneakPeek.show && (Defaults[.inlineHUD] || coordinator.sneakPeek.type == .screenshot || coordinator.sneakPeek.type == .stockAlert) && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if vm.notchState == .closed && aiChat.hasLiveActivity && !coordinator.sneakPeek.show {
                          AINotchLiveActivity()
                              .frame(alignment: .center)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && !vm.screenHasCamera && !vm.hideOnClosed {
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

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
