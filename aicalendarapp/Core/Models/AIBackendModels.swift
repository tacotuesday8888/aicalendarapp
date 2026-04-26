import Foundation

enum AIWorkflow: String, Codable, Sendable {
    case assistantChat = "assistant_chat"
    case goalPlanGeneration = "goal_plan_generation"
    case vibeFeedback = "vibe_feedback"
    case syllabusImport = "syllabus_import"
}

struct AIWorkflowRunRequest<Payload: Encodable>: Encodable {
    var workflow: AIWorkflow
    var payload: Payload
}

struct AIWorkflowRunResponse<Result: Decodable>: Decodable {
    var workflow: AIWorkflow
    var result: Result
    var draftID: String?
}

struct AIAssistantChatPayload: Codable, Sendable {
    var message: String
    var timezone: String
    var currentScreen: String?
    var date: String?
    var contextHints: [String: JSONValue]
}

struct AIAssistantDraftAction: Codable, Hashable, Sendable {
    var type: String
    var title: String
    var dueAt: String?
    var reason: String
}

struct AIAssistantChatResult: Codable, Hashable, Sendable {
    var message: String
    var draftActions: [AIAssistantDraftAction]
}

struct AIGoalDetails: Codable, Hashable, Sendable {
    var title: String
    var description: String

    init(title: String, description: String) {
        self.title = title
        self.description = description
    }

    init(goal: Goal) {
        title = goal.title
        description = goal.detail
    }
}

struct AIGoalPlanPayload: Codable, Sendable {
    var goalID: String?
    var goal: AIGoalDetails?
    var timelineWeeks: Int
    var startDate: String
    var timezone: String
}

struct AIGoalMilestone: Codable, Hashable, Sendable {
    var title: String
    var dueDate: String
    var description: String
}

struct AIGoalNextAction: Codable, Hashable, Sendable {
    var title: String
    var estimatedMinutes: Int
    var priority: String
}

struct AIGoalPlanResult: Codable, Hashable, Sendable {
    var summary: String
    var milestones: [AIGoalMilestone]
    var nextActions: [AIGoalNextAction]
}

struct AIVibeFeedbackPayload: Codable, Sendable {
    var reflectionText: String
    var timezone: String
    var recentContext: [String: JSONValue]?
}

struct AIVibeFeedbackResult: Codable, Hashable, Sendable {
    var feedback: String
    var needsEscalation: Bool

    enum CodingKeys: String, CodingKey {
        case feedback
        case needsEscalation = "needs_escalation"
    }
}

struct AISyllabusImportPayload: Codable, Sendable {
    var extractedText: String
    var currentDate: String?
    var timezone: String
    var sourceName: String?
    var uploadedFilePath: String?
}

struct AISyllabusAssignment: Codable, Hashable, Sendable {
    var title: String
    var type: String?
    var dueDate: String?
    var confidence: String
    var sourceText: String
}

struct AISyllabusCourse: Codable, Hashable, Sendable {
    var name: String
    var instructor: String?
    var assignments: [AISyllabusAssignment]
}

struct AISyllabusWarning: Codable, Hashable, Sendable {
    var message: String
    var sourceText: String?
}

struct AISyllabusImportResult: Codable, Hashable, Sendable {
    var courses: [AISyllabusCourse]
    var warnings: [AISyllabusWarning]
}
