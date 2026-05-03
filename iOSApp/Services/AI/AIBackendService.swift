import Foundation

@MainActor
final class AIBackendService: AIBackendServicing {
    static let shared = AIBackendService(configuration: .shared)

    var networkService: NetworkServicing?
    private let configuration: AppConfiguration

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func run<Payload: Encodable, Result: Decodable>(
        workflow: AIWorkflow,
        payload: Payload,
        decode: Result.Type
    ) async throws -> AIWorkflowRunResponse<Result> {
        guard let networkService else {
            throw AppError.missingConfiguration("networkService")
        }

        guard let aiBaseURL = configuration.aiAPIBaseURL else {
            throw AppError.missingConfiguration("AIAPIBaseURL")
        }

        let request = AIWorkflowRunRequest(workflow: workflow, payload: payload)
        let endpoint = APIEndpoint(
            path: "ai/run",
            method: .post,
            baseURL: aiBaseURL,
            body: try JSONEncoder.appEncoder().encode(request)
        )

        return try await networkService.request(endpoint, decode: AIWorkflowRunResponse<Result>.self)
    }
}
