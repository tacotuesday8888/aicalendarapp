import Foundation

enum AppError: LocalizedError, Equatable {
    case invalidCredentials
    case missingConfiguration(String)
    case dataNotFound
    case integrationUnavailable(String)
    case network(description: String)
    case decoding
    case permissionDenied(String)
    case premiumRequired
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Check your login details and try again."
        case .missingConfiguration(let key):
            "Missing required configuration for \(key)."
        case .dataNotFound:
            "The requested item could not be found."
        case .integrationUnavailable(let dependency):
            "\(dependency) is not linked yet. Add the SDK and credentials to enable this feature."
        case .network(let description):
            description
        case .decoding:
            "We couldn't decode the latest data."
        case .permissionDenied(let resource):
            "Permission for \(resource) was denied."
        case .premiumRequired:
            "Start a subscription to use this premium feature."
        case .unknown(let message):
            message
        }
    }

    static func wrap(_ error: Error, fallback: String) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        let description = (error as NSError).localizedDescription
        return .unknown(description.isEmpty ? fallback : description)
    }
}

enum LoadableState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(AppError)

    var value: Value? {
        if case .loaded(let value) = self {
            return value
        }
        return nil
    }
}
