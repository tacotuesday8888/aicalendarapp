import Foundation
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseAppCheck)
import FirebaseAppCheck
#endif
#if canImport(FirebaseAuth)
import FirebaseAuth
#endif

final class NetworkService: NetworkServicing {
    static let shared = NetworkService()

    private let session: URLSession
    private let configuration: AppConfiguration
    private let appCheckTokenProvider: (@Sendable () async throws -> String?)?
    private let logger = AppLogger(category: "network")

    init(
        session: URLSession = .shared,
        configuration: AppConfiguration = .shared,
        appCheckTokenProvider: (@Sendable () async throws -> String?)? = nil
    ) {
        self.session = session
        self.configuration = configuration
        self.appCheckTokenProvider = appCheckTokenProvider
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
        if let appCheckHeader = await appCheckHeaderValue(), request.value(forHTTPHeaderField: "X-Firebase-AppCheck") == nil {
            request.setValue(appCheckHeader, forHTTPHeaderField: "X-Firebase-AppCheck")
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
                    let httpError = AppError.network(
                        description: Self.errorDescription(from: data, statusCode: statusCode)
                    )
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

    nonisolated private static func errorDescription(from data: Data, statusCode: Int) -> String {
        guard let detail = errorDetail(from: data) else {
            return "Request failed with status \(statusCode)."
        }

        return "Request failed with status \(statusCode) (\(detail))."
    }

    nonisolated private static func errorDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? String, let message = safeErrorMessage(error) {
                return message
            }

            if let error = object["error"] as? [String: Any] {
                if let message = error["message"] as? String, let safeMessage = safeErrorMessage(message) {
                    return safeMessage
                }
                if let code = error["code"] as? String, isSafeErrorCode(code) {
                    return code
                }
            }

            if let message = object["message"] as? String, let safeMessage = safeErrorMessage(message) {
                return safeMessage
            }

            if let code = object["code"] as? String, isSafeErrorCode(code) {
                return code
            }
        }

        return nil
    }

    nonisolated private static func safeErrorMessage(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 240 else { return nil }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }

    nonisolated private static func isSafeErrorCode(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        return value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
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

    nonisolated private func appCheckHeaderValue() async -> String? {
        do {
            if let appCheckTokenProvider {
                return try await appCheckTokenProvider()
            }
            return try await firebaseAppCheckHeaderValue()
        } catch {
            logger.error("App Check token unavailable. Sending request without App Check header so the backend can monitor or enforce policy: \(error.localizedDescription)")
            return nil
        }
    }

    #if canImport(FirebaseCore) && canImport(FirebaseAppCheck)
    nonisolated private func firebaseAppCheckHeaderValue() async throws -> String? {
        guard FirebaseApp.app() != nil else {
            return nil
        }

        let token = try await AppCheck.appCheck().token(forcingRefresh: false)
        return token.token
    }
    #else
    nonisolated private func firebaseAppCheckHeaderValue() async throws -> String? { nil }
    #endif
}
