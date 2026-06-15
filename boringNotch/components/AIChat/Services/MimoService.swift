//
//  MimoService.swift
//  boringNotch
//
//  Thin HTTP + SSE client for a running `mimo serve` daemon. REST calls drive
//  session/message CRUD; the `/event` SSE stream feeds live progress to the notch.
//

import Foundation

enum MimoServiceError: LocalizedError {
    case http(Int)
    case decoding
    case notReady

    var errorDescription: String? {
        switch self {
        case .http(let code): return "mimo server returned HTTP \(code)"
        case .decoding: return "could not decode mimo response"
        case .notReady: return "mimo server is not ready"
        }
    }
}

final class MimoService {
    private let baseURL: URL
    private let restSession: URLSession
    private let streamSession: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL

        let restConfig = URLSessionConfiguration.ephemeral
        restConfig.timeoutIntervalForRequest = 600  // a message round-trip can be long
        restConfig.waitsForConnectivity = false
        self.restSession = URLSession(configuration: restConfig)

        let streamConfig = URLSessionConfiguration.ephemeral
        streamConfig.timeoutIntervalForRequest = 86_400  // long-lived SSE; tolerate idle
        streamConfig.timeoutIntervalForResource = .infinity
        self.streamSession = URLSession(configuration: streamConfig)
    }

    private func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + path)!
    }

    // MARK: - REST

    func listSessions() async throws -> [MimoSession] {
        try await get("/session")
    }

    func createSession(title: String?, directory: String?) async throws -> MimoSession {
        try await post("/session", body: CreateSessionBody(title: title, directory: directory))
    }

    func messages(sessionID: String) async throws -> [MimoMessage] {
        try await get("/session/\(sessionID)/message")
    }

    /// Sends a prompt and resolves with the completed assistant message. The
    /// daemon holds the connection open until the turn finishes; live progress
    /// arrives in parallel over `events()`.
    func sendMessage(sessionID: String, text: String, model: MimoModel, agent: String?) async throws -> MimoMessage {
        let body = SendMessageBody(model: model, agent: agent, parts: [TextPartBody(text: text)])
        return try await post("/session/\(sessionID)/message", body: body)
    }

    func abort(sessionID: String) async throws {
        try await postVoid("/session/\(sessionID)/abort")
    }

    func deleteSession(_ sessionID: String) async throws {
        var request = URLRequest(url: url("/session/\(sessionID)"))
        request.httpMethod = "DELETE"
        _ = try await restSession.data(for: request)
    }

    // MARK: - SSE

    /// Subscribes to the daemon's event stream. The stream finishes when the
    /// underlying connection ends or the consuming task is cancelled.
    func events() -> AsyncStream<MimoEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url("/event"))
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await streamSession.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish()
                        return
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if let event = Self.parseEvent(payload) {
                            continuation.yield(event)
                        }
                    }
                } catch {
                    // Connection dropped or cancelled — fall through to finish.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func parseEvent(_ json: String) -> MimoEvent? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(MimoRawEvent.self, from: data) else { return nil }
        let props = raw.properties
        switch raw.type {
        case "message.updated":
            if let sid = props?.sessionID, let info = props?.info {
                return .messageUpdated(sessionID: sid, info: info)
            }
        case "message.part.updated":
            if let sid = props?.sessionID, let part = props?.part {
                return .partUpdated(sessionID: sid, part: part)
            }
        case "session.error":
            if let sid = props?.sessionID {
                return .sessionError(sessionID: sid, error: props?.error)
            }
        case "session.idle":
            if let sid = props?.sessionID {
                return .sessionIdle(sessionID: sid)
            }
        default:
            return .other(type: raw.type)
        }
        return .other(type: raw.type)
    }

    // MARK: - Low-level helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "GET"
        return try await perform(request)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func postVoid(_ path: String) async throws {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        let (_, response) = try await restSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MimoServiceError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await restSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MimoServiceError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw MimoServiceError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MimoServiceError.decoding
        }
    }
}
