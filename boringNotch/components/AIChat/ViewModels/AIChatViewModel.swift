//
//  AIChatViewModel.swift
//  boringNotch
//
//  Drives the notch AI experience: ensures the mimo daemon is running, owns the
//  active session + message list, and turns the live SSE stream into a one-line
//  summary + progress for the closed notch. Shared singleton so the AI tab and the
//  closed-notch live activity observe the same state.
//

import Foundation
import Combine

@MainActor
final class AIChatViewModel: ObservableObject {
    static let shared = AIChatViewModel()

    enum RunState: Equatable {
        case idle
        case preparing    // bringing the daemon up
        case sending      // request in flight, nothing streamed yet
        case streaming    // receiving parts
        case error(String)
    }

    // Conversation
    @Published private(set) var messages: [MimoMessage] = []
    @Published private(set) var sessions: [MimoSession] = []
    @Published private(set) var activeSessionID: String?

    // Live state (also surfaced in the closed notch)
    @Published private(set) var runState: RunState = .idle
    @Published private(set) var streamingText: String = ""
    @Published private(set) var liveSummary: String = ""
    @Published private(set) var lastError: String?

    // User selections
    @Published var mode: AIMode = .quickChat
    @Published var model: MimoModel = .standard

    /// Whether the chat input currently has keyboard focus. Surfaced so the notch
    /// won't auto-close (and yank focus) while the user is typing.
    @Published var isInputFocused: Bool = false

    private let daemon = MimoDaemonManager.shared
    private var service: MimoService?
    private var eventTask: Task<Void, Never>?

    /// Synchronous guard against a duplicate submit re-sending the same prompt
    /// while a turn is already in flight (otherwise an agent task could run twice).
    private var isSending = false

    private init() {}

    var isBusy: Bool {
        switch runState {
        case .sending, .streaming, .preparing: return true
        case .idle, .error: return false
        }
    }

    /// Whether there is anything worth showing in the closed-notch live activity.
    var hasLiveActivity: Bool {
        isBusy || !liveSummary.isEmpty
    }

    // MARK: - Setup

    /// Brings the daemon up (if needed) and wires the event stream. Returns false
    /// with `runState == .error` if mimo can't be started.
    @discardableResult
    func prepareIfNeeded() async -> Bool {
        if service != nil, daemon.isReady { return true }

        runState = .preparing
        let ready = await daemon.ensureRunning()
        guard ready, let base = daemon.baseURL else {
            let message = daemonErrorText()
            runState = .error(message)
            lastError = message
            return false
        }

        let service = MimoService(baseURL: base)
        self.service = service
        subscribeEvents(using: service)
        runState = .idle
        return true
    }

    private func subscribeEvents(using service: MimoService) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in service.events() {
                if Task.isCancelled { break }
                self?.handle(event)
            }
        }
    }

    // MARK: - Actions

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Drop re-entrant sends (e.g. a double-fired submit). `isSending` stays set
        // for the whole turn, so the same prompt can't be dispatched twice.
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        guard await prepareIfNeeded(), let service else { return }

        if activeSessionID == nil {
            await newSession()
        }
        guard let sessionID = activeSessionID else { return }

        // Optimistic local echo so the user sees their message immediately; replaced
        // by the authoritative server copy on refresh.
        let userMessage = MimoMessage(
            info: MimoMessageInfo(id: "local-\(UUID().uuidString)", role: "user"),
            parts: [MimoPart(id: UUID().uuidString, type: "text", text: trimmed)]
        )
        messages.append(userMessage)

        streamingText = ""
        lastError = nil
        liveSummary = "发送中…"
        runState = .sending

        do {
            _ = try await service.sendMessage(sessionID: sessionID, text: trimmed, model: model, agent: mode.agent)
            await refreshMessages()
            if !isErrorState { runState = .idle }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            runState = .error(message)
            lastError = message
        }

        streamingText = ""
        if !isErrorState { liveSummary = "" }
    }

    func newSession() async {
        guard await prepareIfNeeded(), let service else { return }
        do {
            let session = try await service.createSession(title: "灵动岛对话", directory: nil)
            activeSessionID = session.id
            messages = []
            streamingText = ""
            liveSummary = ""
            sessions.insert(session, at: 0)
        } catch {
            runState = .error("无法创建会话")
            lastError = "无法创建会话"
        }
    }

    func openSession(_ id: String) async {
        activeSessionID = id
        await refreshMessages()
    }

    func loadSessions() async {
        guard await prepareIfNeeded(), let service else { return }
        sessions = (try? await service.listSessions()) ?? []
    }

    func refreshMessages() async {
        guard let service, let sessionID = activeSessionID else { return }
        if let fetched = try? await service.messages(sessionID: sessionID) {
            messages = fetched
        }
    }

    func abort() async {
        guard let service, let sessionID = activeSessionID else { return }
        try? await service.abort(sessionID: sessionID)
        runState = .idle
        streamingText = ""
        liveSummary = ""
    }

    // MARK: - Event handling

    private func handle(_ event: MimoEvent) {
        switch event {
        case .partUpdated(let sessionID, let part):
            guard sessionID == activeSessionID else { return }
            if runState == .sending { runState = .streaming }
            switch part.type {
            case "text":
                if let text = part.text {
                    streamingText = text
                    liveSummary = Self.summarize(text)
                }
            case "reasoning":
                liveSummary = "思考中…"
            case "tool":
                liveSummary = "调用 \(part.tool ?? "工具")…"
            default:
                break
            }

        case .messageUpdated(let sessionID, let info):
            guard sessionID == activeSessionID else { return }
            if info.role == "assistant", let error = info.error {
                runState = .error(error.message)
                lastError = error.message
            }

        case .sessionError(let sessionID, let error):
            guard sessionID == activeSessionID else { return }
            let message = error?.message ?? "会话出错"
            runState = .error(message)
            lastError = message
            liveSummary = ""

        case .sessionIdle(let sessionID):
            guard sessionID == activeSessionID else { return }
            if !isErrorState { runState = .idle; liveSummary = "" }
            streamingText = ""
            Task { await self.refreshMessages() }

        case .other:
            break
        }
    }

    // MARK: - Helpers

    private var isErrorState: Bool {
        if case .error = runState { return true }
        return false
    }

    private func daemonErrorText() -> String {
        switch daemon.state {
        case .notInstalled: return "未检测到 mimo（~/.mimocode/bin/mimo）"
        case .failed(let message): return message
        default: return "无法启动 mimo 服务"
        }
    }

    private static func summarize(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 50 ? String(trimmed.prefix(50)) + "…" : trimmed
    }
}
