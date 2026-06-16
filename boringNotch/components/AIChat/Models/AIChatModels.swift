//
//  AIChatModels.swift
//  boringNotch
//
//  Codable models mirroring the mimocode (opencode-based) HTTP/SSE API, plus the
//  notch-facing mode/model selection. Response decoders are written defensively
//  so an unexpected field from a future mimo build can't crash a whole fetch.
//

import Foundation

// MARK: - Mode & model selection

enum AIMode: String, Codable, CaseIterable, Identifiable {
    case quickChat   // read-only assistant; will not edit files
    case agentTask   // full agent with tools

    var id: String { rawValue }

    /// The mimo agent backing this mode.
    var agent: String {
        switch self {
        case .quickChat: return "plan"
        case .agentTask: return "build"
        }
    }

    var label: String {
        switch self {
        case .quickChat: return "快速问答"
        case .agentTask: return "Agent 任务"
        }
    }

    var systemImage: String {
        switch self {
        case .quickChat: return "bubble.left.and.bubble.right"
        case .agentTask: return "hammer"
        }
    }
}

struct MimoModel: Codable, Equatable, Hashable {
    var providerID: String
    var modelID: String

    // mimo-v2-flash is rejected on some accounts; the proven defaults are the
    // 2.5 line, matching the user's mimocode config "standard"/"ultra" groups.
    static let standard = MimoModel(providerID: "xiaomi", modelID: "mimo-v2.5-pro")
    static let ultra = MimoModel(providerID: "xiaomi", modelID: "mimo-v2.5-pro-ultraspeed")

    var displayName: String { modelID }
}

// MARK: - Session

struct MimoSession: Codable, Identifiable, Equatable {
    let id: String
    var slug: String? = nil
    var title: String? = nil
    var directory: String? = nil
    var projectID: String? = nil
    var time: MimoTime? = nil
}

struct MimoTime: Codable, Equatable {
    var created: Double? = nil
    var updated: Double? = nil
    var completed: Double? = nil
}

// MARK: - Message

struct MimoMessage: Decodable, Identifiable {
    var info: MimoMessageInfo
    var parts: [MimoPart]
    var id: String { info.id }

    init(info: MimoMessageInfo, parts: [MimoPart]) {
        self.info = info
        self.parts = parts
    }

    /// The concatenated visible text of this message (text parts only).
    ///
    /// mimo's `plan` agent appends a large `<system-reminder>…</system-reminder>`
    /// text part to every *user* message; those are internal prompt scaffolding,
    /// not something the user wrote, so they must never surface in the bubble.
    var displayText: String {
        parts
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<system-reminder") }
            .joined()
    }

    var isUser: Bool { info.role == "user" }
}

struct MimoMessageInfo: Decodable, Equatable {
    let id: String
    let role: String          // "user" | "assistant"
    var agent: String? = nil
    var modelID: String? = nil
    var providerID: String? = nil
    var cost: Double? = nil
    var tokens: MimoTokens? = nil
    var time: MimoTime? = nil
    var error: MimoErrorBox? = nil
}

struct MimoTokens: Decodable, Equatable {
    var input: Int? = nil
    var output: Int? = nil
    var reasoning: Int? = nil
    var total: Int? = nil
}

struct MimoErrorBox: Decodable, Equatable {
    var name: String? = nil
    var data: MimoErrorData? = nil

    struct MimoErrorData: Decodable, Equatable {
        var message: String? = nil
        var statusCode: Int? = nil
    }

    var message: String { data?.message ?? name ?? "未知错误" }
}

/// A message part: text, reasoning, or a tool invocation. Tolerant decoder — never
/// throws, so a malformed or unknown part type degrades gracefully.
struct MimoPart: Decodable, Identifiable, Equatable {
    var id: String
    var type: String          // "text" | "reasoning" | "tool" | "step-start" | ...
    var text: String? = nil
    var tool: String? = nil
    var callID: String? = nil
    var messageID: String? = nil
    var state: MimoToolState? = nil

    init(id: String, type: String, text: String? = nil, tool: String? = nil,
         callID: String? = nil, messageID: String? = nil, state: MimoToolState? = nil) {
        self.id = id
        self.type = type
        self.text = text
        self.tool = tool
        self.callID = callID
        self.messageID = messageID
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case id, type, text, tool, callID, messageID, state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        type = (try? c.decode(String.self, forKey: .type)) ?? "unknown"
        text = try? c.decode(String.self, forKey: .text)
        tool = try? c.decode(String.self, forKey: .tool)
        callID = try? c.decode(String.self, forKey: .callID)
        messageID = try? c.decode(String.self, forKey: .messageID)
        state = try? c.decode(MimoToolState.self, forKey: .state)
    }
}

struct MimoToolState: Decodable, Equatable {
    var status: String? = nil   // "running" | "completed" | "error"
    var title: String? = nil
}

// MARK: - SSE events

/// Normalized event emitted by the service after parsing the `/event` stream.
enum MimoEvent {
    case messageUpdated(sessionID: String, info: MimoMessageInfo)
    case partUpdated(sessionID: String, part: MimoPart)
    case sessionError(sessionID: String, error: MimoErrorBox?)
    case sessionIdle(sessionID: String)
    case other(type: String)
}

/// Raw `{ type, properties }` SSE envelope; properties decode defensively.
struct MimoRawEvent: Decodable {
    let type: String
    let properties: Properties?

    struct Properties: Decodable {
        var sessionID: String? = nil
        var info: MimoMessageInfo? = nil
        var part: MimoPart? = nil
        var error: MimoErrorBox? = nil

        enum CodingKeys: String, CodingKey { case sessionID, info, part, error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try? c.decode(String.self, forKey: .sessionID)
            info = try? c.decode(MimoMessageInfo.self, forKey: .info)
            part = try? c.decode(MimoPart.self, forKey: .part)
            error = try? c.decode(MimoErrorBox.self, forKey: .error)
        }
    }
}

// MARK: - Request bodies

struct CreateSessionBody: Encodable {
    var title: String?
    var directory: String?
}

struct SendMessageBody: Encodable {
    var model: MimoModel
    var agent: String?
    var parts: [TextPartBody]
}

struct TextPartBody: Encodable {
    var type: String = "text"
    var text: String
}
