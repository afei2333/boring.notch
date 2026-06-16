//
//  AIChatView.swift
//  boringNotch
//
//  The open-notch AI conversation surface, bound to the shared AIChatViewModel.
//

import SwiftUI
import AppKit

struct AIChatView: View {
    @ObservedObject private var vm = AIChatViewModel.shared
    @State private var input: String = ""
    @FocusState private var inputFocused: Bool
    private let bottomAnchor = "ai-bottom"

    @EnvironmentObject private var boringVM: BoringViewModel
    var isStandalone: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            header
            messageList
            inputBar
        }
        .padding(.horizontal, isStandalone ? 16 : 6)
        .padding(.top, isStandalone ? 16 : 0)
        .padding(.bottom, isStandalone ? 16 : 4)
        .background(WindowAccessor { window in
            if !isStandalone {
                // The notch panel can't normally become key; allow it while this view
                // is up so the input field can receive keystrokes.
                BoringNotchSkyLightWindow.allowsKeyFocus = true
                window?.makeKey()
            }
        })
        .background(
            Color.black.opacity(0.01)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    zoomToWindow()
                }
        )
        .onAppear {
            if !isStandalone {
                BoringNotchSkyLightWindow.allowsKeyFocus = true
                // Keep the notch from auto-closing on mouse-exit while the chat is up,
                // so the user can move the cursor away and keep typing.
                SharingStateManager.shared.beginInteraction()
            }
        }
        .onDisappear {
            if !isStandalone {
                BoringNotchSkyLightWindow.allowsKeyFocus = false
                inputFocused = false
                vm.isInputFocused = false
                SharingStateManager.shared.endInteraction()
            }
        }
        .onChange(of: inputFocused) { _, focused in
            // The notch instance owns the auto-close decision; while the field is
            // focused the notch must stay open so typing can't yank focus away.
            if !isStandalone { vm.isInputFocused = focused }
        }
        .task { await vm.prepareIfNeeded() }
        .task {
            // Let the window settle, then place the cursor in the input field.
            try? await Task.sleep(for: .milliseconds(150))
            inputFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $vm.mode) {
                ForEach(AIMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if vm.isBusy {
                ProgressView().controlSize(.small)
                Button {
                    Task { await vm.abort() }
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.plain)
                .help("停止")
            }

            Button {
                Task { await vm.newSession() }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("新对话")
        }
        .font(.system(size: 12))
        .foregroundStyle(.gray)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            zoomToWindow()
        }
    }

    // MARK: - Messages

    private var visibleMessages: [MimoMessage] {
        vm.messages.filter { $0.info.role != "system" && ($0.isUser || !$0.displayText.isEmpty) }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if visibleMessages.isEmpty && vm.streamingText.isEmpty {
                        emptyState
                    }
                    ForEach(visibleMessages) { message in
                        MessageBubble(text: message.displayText, isUser: message.isUser)
                            .id(message.id)
                    }
                    if !vm.streamingText.isEmpty {
                        MessageBubble(text: vm.streamingText, isUser: false, isStreaming: true)
                    }
                    if case .error(let message) = vm.runState {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.vertical, 2)
            }
            .onChange(of: vm.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: vm.streamingText) { _, _ in
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 22))
            Text(vm.runState == .preparing ? "正在启动 mimo…" : "问点什么吧")
                .font(.system(size: 12))
        }
        .foregroundStyle(.gray)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("发消息…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.accentColor : .gray)
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.isBusy
    }

    private func send() {
        guard canSend else { return }
        let text = input
        input = ""
        Task { await vm.send(text) }
    }

    private func zoomToWindow() {
        guard !isStandalone else { return }
        AIChatWindowController.shared.showWindow()
        
        if SharingStateManager.shared.preventNotchClose {
            SharingStateManager.shared.endInteraction()
        }
        withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)) {
            boringVM.close()
        }
    }
}

// MARK: - Window access

/// Resolves the hosting NSWindow so the view can make the notch panel key.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window != nil { onResolve(nsView.window) }
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let text: String
    let isUser: Bool
    var isStreaming: Bool = false

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 28) }
            Text(text.isEmpty && isStreaming ? "…" : text)
                .font(.system(size: 12))
                .foregroundStyle(isUser ? .white : Color(white: 0.85))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isUser ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 11))
            if !isUser { Spacer(minLength: 28) }
        }
    }
}

// MARK: - Standalone AI Window Controller

class AIChatWindowController: NSWindowController {
    static let shared = AIChatWindowController()
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupWindow() {
        guard let window = window else { return }
        
        window.title = "mimo AI"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        
        // Make it behave like a regular app window with proper Spaces support
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        
        // Ensure proper window behavior
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("BoringNotchAIChatWindow")
        
        // Create the SwiftUI content
        let aiView = AIChatView(isStandalone: true)
            .environmentObject(BoringViewModel()) // Dummy to prevent crash
        let hostingView = NSHostingView(rootView: aiView)
        window.contentView = hostingView
        
        // Handle window closing
        window.delegate = self
    }
    
    func showWindow() {
        // Set app to regular mode first
        NSApp.setActivationPolicy(.regular)
        
        // If window is already visible, bring it to front properly
        if window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)
            return
        }
        
        // Show the window with proper ordering
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        
        // Activate the app and ensure window gets focus
        NSApp.activate(ignoringOtherApps: true)
        
        // Force window to front after activation
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }
    
    override func close() {
        super.close()
        relinquishFocus()
    }
    
    private func relinquishFocus() {
        window?.orderOut(nil)
        
        DispatchQueue.main.async {
            let hasVisibleRegularWindows = NSApp.windows.contains { window in
                window.isVisible && 
                !(window is BoringNotchSkyLightWindow) && 
                window.className != "NSStatusBarWindow"
            }
            if !hasVisibleRegularWindows {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

extension AIChatWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        relinquishFocus()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}
