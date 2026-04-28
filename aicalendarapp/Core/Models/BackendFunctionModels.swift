import Foundation

struct AssistantRequestPayload: Codable, Sendable {
    var userID: String
    var message: String
    var snapshot: PlannerSnapshot
    var goals: [Goal]
}

struct AssistantResponsePayload: Codable, Sendable {
    var thread: AssistantThread
}

struct GoalPlanRequestPayload: Codable, Sendable {
    var userID: String
    var goal: Goal
    var timelineWeeks: Int
}

struct VibeFeedbackRequestPayload: Codable, Sendable {
    var userID: String
    var prompt: String
}

struct VibeFeedbackResponsePayload: Codable, Sendable {
    var feedback: String
}

struct AssistantDraftCommitPayload: Codable, Sendable {
    var userID: String
    var action: AssistantDraftAction
}

struct ImportTextRequestPayload: Codable, Sendable {
    var userID: String
    var text: String
}

struct ImportFileRequestPayload: Codable, Sendable {
    var userID: String
    var sourceName: String
    var uploadedPath: String?
    var extractedText: String
}

struct ImportCommitPayload: Codable, Sendable {
    var userID: String
    var job: ImportJob
}

struct DeleteImportPayload: Codable, Sendable {
    var userID: String
    var job: ImportJob
}

struct UserJobRequestPayload: Codable, Sendable {
    var userID: String
}

struct OperationStatusPayload: Codable, Sendable {
    var success: Bool
}

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case object([String: JSONValue])
    case array([JSONValue])
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct ExportUserDataResponsePayload: Codable, Sendable {
    var userID: String
    var requestedAt: Date
    var profile: JSONValue
    var collections: [String: [JSONValue]]
    var systemCollections: [String: [JSONValue]]?
}
