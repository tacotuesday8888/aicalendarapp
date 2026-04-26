import Foundation
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseAuth)
import FirebaseAuth
#endif

final class NetworkService: NetworkServicing {
    static let shared = NetworkService()

    private let session: URLSession
    private let configuration: AppConfiguration
    private let logger = AppLogger(category: "network")

    init(session: URLSession = .shared, configuration: AppConfiguration = .shared) {
        self.session = session
        self.configuration = configuration
    }

    nonisolated func request<T: Decodable>(_ endpoint: APIEndpoint, decode: T.Type) async throws -> T {
        guard let baseURL = endpoint.baseURL ?? configuration.apiBaseURL else {
            throw AppError.missingConfiguration("APIBaseURL")
        }

        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: false)
        components?.queryItems = endpoint.queryItems.isEmpty ? nil : endpoint.queryItems

        guard let url = components?.url else {
            throw AppError.network(description: "Unable to build request URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = endpoint.body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationHeader = try await authorizationHeaderValue(), request.value(forHTTPHeaderField: "Authorization") == nil {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        endpoint.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        var attempt = 0
        var lastError: Error?

        while attempt <= endpoint.retryCount {
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AppError.network(description: "Invalid server response.")
                }

                let statusCode = httpResponse.statusCode
                guard (200..<300).contains(statusCode) else {
                    let httpError = AppError.network(description: "Request failed with status \(statusCode).")
                    if (400..<500).contains(statusCode) { throw httpError }
                    lastError = httpError
                    attempt += 1
                    guard attempt <= endpoint.retryCount else { break }
                    try? await Task.sleep(for: .seconds(Double(attempt)))
                    continue
                }

                return try JSONDecoder.appDecoder().decode(T.self, from: data)
            } catch let error as AppError {
                throw error
            } catch is DecodingError {
                throw AppError.decoding
            } catch {
                lastError = error
                attempt += 1
                guard attempt <= endpoint.retryCount else { break }
                try? await Task.sleep(for: .seconds(Double(attempt)))
            }
        }

        throw AppError.wrap(lastError ?? AppError.network(description: "Request failed."), fallback: "Request failed.")
    }

    #if canImport(FirebaseCore) && canImport(FirebaseAuth)
    nonisolated private func authorizationHeaderValue() async throws -> String? {
        guard FirebaseApp.app() != nil, let currentUser = Auth.auth().currentUser else {
            return nil
        }

        let token = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            currentUser.getIDToken { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: AppError.unknown("FirebaseAuth did not return an ID token."))
                }
            }
        }

        return "Bearer \(token)"
    }
    #else
    nonisolated private func authorizationHeaderValue() async throws -> String? { nil }
    #endif
}
