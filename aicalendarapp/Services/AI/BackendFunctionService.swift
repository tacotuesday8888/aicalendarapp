import Foundation
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseAuth)
import FirebaseAuth
#endif

@MainActor
final class BackendFunctionService: BackendFunctionServicing {
    static let shared = BackendFunctionService()

    var networkService: NetworkServicing?
    var databaseService: DatabaseServicing?
    var storageService: StorageServicing?

    func assistantRespond(_ request: AssistantRequestPayload) async throws -> AssistantThread {
        let response = try await invokeRequired(
            "assistantRespond",
            body: request,
            decode: AssistantResponsePayload.self,
            feature: "The assistant"
        )
        return response.thread
    }

    func generateGoalPlan(_ request: GoalPlanRequestPayload) async throws -> GoalPlanDraft {
        try await invokeRequired(
            "generateGoalPlan",
            body: request,
            decode: GoalPlanDraft.self,
            feature: "AI goal planning"
        )
    }

    func generateVibeFeedback(_ request: VibeFeedbackRequestPayload) async throws -> VibeFeedbackResponsePayload {
        if let response = try await invoke("generateVibeFeedback", body: request, decode: VibeFeedbackResponsePayload.self) {
            return response
        }

        return VibeFeedbackResponsePayload(feedback: localVibeFeedback(for: request.prompt))
    }

    func commitAssistantDraft(_ request: AssistantDraftCommitPayload) async throws {
        _ = try await invokeRequired(
            "commitAssistantDraft",
            body: request,
            decode: OperationStatusPayload.self,
            feature: "Assistant draft commits"
        )
    }

    func importSyllabusText(_ request: ImportTextRequestPayload) async throws -> ImportJob {
        try await invokeRequired(
            "importSyllabusText",
            body: request,
            decode: ImportJob.self,
            feature: "Syllabus import"
        )
    }

    func importSyllabusFile(_ request: ImportFileRequestPayload) async throws -> ImportJob {
        try await invokeRequired(
            "importSyllabusFile",
            body: request,
            decode: ImportJob.self,
            feature: "File-based syllabus import"
        )
    }

    func commitImport(_ request: ImportCommitPayload) async throws {
        _ = try await invokeRequired(
            "commitImportJob",
            body: request,
            decode: OperationStatusPayload.self,
            feature: "Import commits"
        )
    }

    func deleteImport(_ request: DeleteImportPayload) async throws {
        _ = try await invokeRequired(
            "deleteImportJob",
            body: request,
            decode: OperationStatusPayload.self,
            feature: "Import deletion"
        )
    }

    func deleteUserAccount(_ request: UserJobRequestPayload) async throws {
        _ = try await invokeRequired(
            "deleteUserAccount",
            body: request,
            decode: OperationStatusPayload.self,
            feature: "Account deletion"
        )
    }

    func exportUserData(_ request: UserJobRequestPayload) async throws -> ExportUserDataResponsePayload {
        try await invokeRequired(
            "exportUserData",
            body: request,
            decode: ExportUserDataResponsePayload.self,
            feature: "Data export"
        )
    }

    private func invoke<Request: Encodable, Response: Decodable>(
        _ functionName: String,
        body: Request,
        decode: Response.Type
    ) async throws -> Response? {
        guard let networkService, AppConfiguration.shared.apiBaseURL != nil else {
            return nil
        }

        if let authError = backendAuthenticationErrorIfNeeded() {
            throw authError
        }

        let endpoint = APIEndpoint(
            path: functionName,
            method: .post,
            body: try JSONEncoder.appEncoder().encode(body)
        )

        return try await networkService.request(endpoint, decode: Response.self)
    }

    private func localVibeFeedback(for prompt: String) -> String {
        let normalized = prompt.lowercased()

        if normalized.contains("overwhelmed") || normalized.contains("burned out") || normalized.contains("anxious") {
            return "Lower the bar for the next hour. Pick one task you can finish in 10 to 15 minutes, then reassess with a calmer baseline."
        }

        if normalized.contains("stuck") || normalized.contains("behind") || normalized.contains("avoid") {
            return "Reduce friction instead of forcing momentum. Open the task, define the first visible move, and give yourself one short focus block to restart."
        }

        if normalized.contains("good") || normalized.contains("great") || normalized.contains("motivated") || normalized.contains("energized") {
            return "Use the momentum while it is real. Protect one meaningful block for your hardest task before the day gets fragmented."
        }

        return "Take the next 10 minutes to make one part of today easier: clear one blocker, shrink one task, or lock one study block into your schedule."
    }

    private func invokeRequired<Request: Encodable, Response: Decodable>(
        _ functionName: String,
        body: Request,
        decode: Response.Type,
        feature: String
    ) async throws -> Response {
        if let response = try await invoke(functionName, body: body, decode: decode) {
            return response
        }
        throw AppError.unknown("\(feature) requires the live backend. Configure Firebase and APIBaseURL, then sign in again.")
    }

    private func backendAuthenticationErrorIfNeeded() -> AppError? {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth)
        guard FirebaseApp.app() != nil else {
            return .integrationUnavailable("Firebase")
        }

        guard Auth.auth().currentUser != nil else {
            return .unknown("A live backend requires a Firebase-authenticated session. Sign in again after Firebase is configured.")
        }

        return nil
        #else
        return .integrationUnavailable("FirebaseAuth")
        #endif
    }
}
