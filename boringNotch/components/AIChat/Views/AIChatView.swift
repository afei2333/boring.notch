//
//  AIChatView.swift
//  boringNotch
//
//  The open-notch AI conversation surface, bound to the shared AIChatViewModel.
//

import SwiftUI

struct AIChatView: View {
    @ObservedObject private var vm = AIChatViewModel.shared
    @State private var input: String = ""
    @FocusState private var inputFocused: Bool
    private let bottomAnchor = "ai-bottom"

    var body: some View {
        VStack(spacing: 8) {
            header
            messageList
            inputBar
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .background(WindowAccessor { window in
            // The notch panel can't normally become key; allow it while this view
            // is up so the input field can receive keystrokes.
            BoringNotchSkyLightWindow.allowsKeyFocus = true
            window?.makeKey()
        })
        .onAppear {
            BoringNotchSkyLightWindow.allowsKeyFocus = true
            // Keep the notch from auto-closing on mouse-exit while the chat is up,
            // so the user can move the cursor away and keep typing.
            SharingStateManager.shared.beginInteraction()
        }
        .onDisappear {
            BoringNotchSkyLightWindow.allowsKeyFocus = false
            inputFocused = false
            SharingStateManager.shared.endInteraction()
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
    }

    // MARK: - Messages

    private var visibleMessages: [MimoMessage] {
        vm.messages.filter { $0.isUser || !$0.displayText.isEmpty }
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
                .foregroundStyle(.white)
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
