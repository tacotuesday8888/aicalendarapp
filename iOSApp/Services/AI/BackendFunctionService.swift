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

    func syncSubscriptionStatus(_ request: UserJobRequestPayload) async throws -> SubscriptionState {
        let response = try await invokeRequired(
            "syncRevenueCatSubscription",
            body: request,
            decode: SubscriptionSyncResponsePayload.self,
            feature: "Subscription backend sync"
        )
        return response.state
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
