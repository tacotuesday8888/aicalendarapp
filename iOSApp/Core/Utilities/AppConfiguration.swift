import Foundation

struct AppConfiguration: Sendable {
    enum RevenueCatAPIKeyValidation: Equatable, Sendable {
        case valid
        case missing
        case secretAPIKey
        case oauthToken
        case testStoreKeyNotAllowed
        case placeholderKey
        case unsupportedPublicSDKKey

        var failureReason: String? {
            switch self {
            case .valid:
                return nil
            case .missing:
                return "RevenueCat API key is required."
            case .secretAPIKey:
                return "RevenueCat secret API keys must stay on the backend and cannot be used by the iOS app."
            case .oauthToken:
                return "RevenueCat OAuth access tokens cannot be used by the iOS app."
            case .testStoreKeyNotAllowed:
                return "RevenueCat Test Store API key cannot be used in non-debug builds."
            case .placeholderKey:
                return "RevenueCat API key must be replaced with a real RevenueCat key before launch."
            case .unsupportedPublicSDKKey:
                return "RevenueCat release builds must use the platform-specific iOS public SDK key."
            }
        }
    }

    enum SuperwallAPIKeyValidation: Equatable, Sendable {
        case valid
        case missing
        case placeholderKey
        case unsupportedPublicSDKKey

        var failureReason: String? {
            switch self {
            case .valid:
                return nil
            case .missing:
                return "Superwall API key is required."
            case .placeholderKey:
                return "Superwall API key must be replaced with a real public API key before launch."
            case .unsupportedPublicSDKKey:
                return "Superwall requires the public SDK API key from Settings > Keys."
            }
        }
    }

    enum GoogleSignInConfigurationValidation: Equatable, Sendable {
        case valid
        case missingClientID
        case missingReversedClientID
        case placeholderValue
        case unsupportedClientID
        case unsupportedReversedClientID
        case mismatchedReversedClientID

        var failureReason: String? {
            switch self {
            case .valid:
                return nil
            case .missingClientID:
                return "Google Sign-In client ID is required."
            case .missingReversedClientID:
                return "Google Sign-In reversed client ID URL scheme is required."
            case .placeholderValue:
                return "Google Sign-In configuration must be replaced with real Firebase/Google OAuth values."
            case .unsupportedClientID:
                return "Google Sign-In client ID must be the iOS OAuth client ending in apps.googleusercontent.com."
            case .unsupportedReversedClientID:
                return "Google Sign-In reversed client ID must use the com.googleusercontent.apps.* URL scheme."
            case .mismatchedReversedClientID:
                return "Google Sign-In reversed client ID must match the configured iOS OAuth client ID."
            }
        }
    }

    enum BackendEndpointValidation: Equatable, Sendable {
        case valid
        case missingRequiredURLs([String])
        case placeholderURLs([String])
        case unsupportedURLScheme([String])

        var failureReason: String? {
            switch self {
            case .valid:
                return nil
            case .missingRequiredURLs(let keys):
                return "Backend endpoint URLs are required for non-debug builds: \(keys.joined(separator: ", "))."
            case .placeholderURLs(let keys):
                return "Backend endpoint URLs must be replaced with deployed Firebase Functions URLs: \(keys.joined(separator: ", "))."
            case .unsupportedURLScheme(let keys):
                return "Backend endpoint URLs must use HTTPS: \(keys.joined(separator: ", "))."
            }
        }
    }

    enum LegalURLValidation: Equatable, Sendable {
        case valid
        case missingRequiredURLs([String])
        case placeholderURLs([String])
        case unsupportedURLScheme([String])

        var failureReason: String? {
            switch self {
            case .valid:
                return nil
            case .missingRequiredURLs(let keys):
                return "Legal URLs are required for non-debug builds: \(keys.joined(separator: ", "))."
            case .placeholderURLs(let keys):
                return "Legal URLs must be replaced with publicly accessible policy URLs: \(keys.joined(separator: ", "))."
            case .unsupportedURLScheme(let keys):
                return "Legal URLs must use HTTPS: \(keys.joined(separator: ", "))."
            }
        }
    }

    static let shared = AppConfiguration(bundle: .main)

    let bundleID: String
    let appScheme: String
    let apiBaseURL: URL?
    let aiAPIBaseURL: URL?
    let revenueCatAPIKey: String
    let revenueCatEntitlementID: String
    let superwallAPIKey: String
    let googleClientID: String
    let googleReversedClientID: String
    let privacyPolicyURL: URL?
    let termsOfServiceURL: URL?

    init(bundle: Bundle) {
        bundleID = bundle.bundleIdentifier ?? "com.langqi.aicalendarapp"
        appScheme = bundle.object(forInfoDictionaryKey: "AppURLScheme") as? String ?? "aicalendarapp"
        revenueCatAPIKey = bundle.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String ?? ""
        let configuredRevenueCatEntitlementID =
            (bundle.object(forInfoDictionaryKey: "RevenueCatEntitlementID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        revenueCatEntitlementID = configuredRevenueCatEntitlementID.isEmpty
            ? "aiefficiencyapp Pro"
            : configuredRevenueCatEntitlementID
        superwallAPIKey = bundle.object(forInfoDictionaryKey: "SuperwallAPIKey") as? String ?? ""
        googleClientID = bundle.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? ""
        googleReversedClientID = bundle.object(forInfoDictionaryKey: "GoogleReversedClientID") as? String ?? ""
        privacyPolicyURL = AppConfiguration.url(for: "PrivacyPolicyURL", in: bundle)
        termsOfServiceURL = AppConfiguration.url(for: "TermsOfServiceURL", in: bundle)

        if
            let rawURL = bundle.object(forInfoDictionaryKey: "APIBaseURL") as? String,
            let url = URL(string: rawURL),
            !rawURL.isEmpty
        {
            apiBaseURL = url
        } else {
            apiBaseURL = nil
        }

        if
            let rawURL = bundle.object(forInfoDictionaryKey: "AIAPIBaseURL") as? String,
            let url = URL(string: rawURL),
            !rawURL.isEmpty
        {
            aiAPIBaseURL = url
        } else {
            aiAPIBaseURL = nil
        }
    }

    private static func url(for key: String, in bundle: Bundle) -> URL? {
        guard
            let rawValue = bundle.object(forInfoDictionaryKey: key) as? String,
            rawValue.contains("://"),
            let url = URL(string: rawValue)
        else {
            return nil
        }
        return url
    }

    static func validateRevenueCatAPIKey(
        _ rawAPIKey: String,
        allowsTestStoreKey: Bool
    ) -> RevenueCatAPIKeyValidation {
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return .missing
        }

        if apiKey.hasPrefix("sk_") {
            return .secretAPIKey
        }

        if apiKey.hasPrefix("atk_") {
            return .oauthToken
        }

        if apiKey.hasPrefix("test_") {
            return allowsTestStoreKey ? .valid : .testStoreKeyNotAllowed
        }

        if containsPlaceholderMarker(apiKey) {
            return .placeholderKey
        }

        return apiKey.hasPrefix("appl_") ? .valid : .unsupportedPublicSDKKey
    }

    static func validateSuperwallAPIKey(_ rawAPIKey: String) -> SuperwallAPIKeyValidation {
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return .missing
        }

        if containsPlaceholderMarker(apiKey) {
            return .placeholderKey
        }

        return apiKey.hasPrefix("pk_") ? .valid : .unsupportedPublicSDKKey
    }

    static func validateGoogleSignInConfiguration(
        clientID rawClientID: String,
        reversedClientID rawReversedClientID: String
    ) -> GoogleSignInConfigurationValidation {
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let reversedClientID = rawReversedClientID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clientID.isEmpty else {
            return .missingClientID
        }

        guard !reversedClientID.isEmpty else {
            return .missingReversedClientID
        }

        if containsPlaceholderMarker(clientID) || containsPlaceholderMarker(reversedClientID) {
            return .placeholderValue
        }

        let clientIDSuffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(clientIDSuffix) else {
            return .unsupportedClientID
        }

        let reversedClientIDPrefix = "com.googleusercontent.apps."
        guard reversedClientID.hasPrefix(reversedClientIDPrefix) else {
            return .unsupportedReversedClientID
        }

        let clientIDBody = String(clientID.dropLast(clientIDSuffix.count))
        let expectedReversedClientID = "\(reversedClientIDPrefix)\(clientIDBody)"
        return reversedClientID == expectedReversedClientID ? .valid : .mismatchedReversedClientID
    }

    static func validateBackendEndpoints(apiBaseURL: URL?, aiAPIBaseURL: URL?) -> BackendEndpointValidation {
        var missingKeys = [String]()
        var placeholderKeys = [String]()
        var unsupportedSchemeKeys = [String]()

        if apiBaseURL == nil {
            missingKeys.append("APIBaseURL")
        } else if isPlaceholderBackendEndpoint(apiBaseURL) {
            placeholderKeys.append("APIBaseURL")
        } else if apiBaseURL?.scheme?.lowercased() != "https" {
            unsupportedSchemeKeys.append("APIBaseURL")
        }

        if aiAPIBaseURL == nil {
            missingKeys.append("AIAPIBaseURL")
        } else if isPlaceholderBackendEndpoint(aiAPIBaseURL) {
            placeholderKeys.append("AIAPIBaseURL")
        } else if aiAPIBaseURL?.scheme?.lowercased() != "https" {
            unsupportedSchemeKeys.append("AIAPIBaseURL")
        }

        if !missingKeys.isEmpty {
            return .missingRequiredURLs(missingKeys)
        }
        if !placeholderKeys.isEmpty {
            return .placeholderURLs(placeholderKeys)
        }
        if !unsupportedSchemeKeys.isEmpty {
            return .unsupportedURLScheme(unsupportedSchemeKeys)
        }
        return .valid
    }

    static func validateLegalURLs(privacyPolicyURL: URL?, termsOfServiceURL: URL?) -> LegalURLValidation {
        var missingKeys = [String]()
        var placeholderKeys = [String]()
        var unsupportedSchemeKeys = [String]()

        validateRequiredHTTPSURL(
            privacyPolicyURL,
            key: "PrivacyPolicyURL",
            missingKeys: &missingKeys,
            placeholderKeys: &placeholderKeys,
            unsupportedSchemeKeys: &unsupportedSchemeKeys
        )
        validateRequiredHTTPSURL(
            termsOfServiceURL,
            key: "TermsOfServiceURL",
            missingKeys: &missingKeys,
            placeholderKeys: &placeholderKeys,
            unsupportedSchemeKeys: &unsupportedSchemeKeys
        )

        if !missingKeys.isEmpty {
            return .missingRequiredURLs(missingKeys)
        }
        if !placeholderKeys.isEmpty {
            return .placeholderURLs(placeholderKeys)
        }
        if !unsupportedSchemeKeys.isEmpty {
            return .unsupportedURLScheme(unsupportedSchemeKeys)
        }
        return .valid
    }

    private static func validateRequiredHTTPSURL(
        _ url: URL?,
        key: String,
        missingKeys: inout [String],
        placeholderKeys: inout [String],
        unsupportedSchemeKeys: inout [String]
    ) {
        guard let url else {
            missingKeys.append(key)
            return
        }

        if isPlaceholderWebURL(url) {
            placeholderKeys.append(key)
        } else if url.scheme?.lowercased() != "https" {
            unsupportedSchemeKeys.append(key)
        }
    }

    private static func containsPlaceholderMarker(_ value: String) -> Bool {
        let lowercaseValue = value.lowercased()
        return lowercaseValue.contains("your_")
            || lowercaseValue.contains("placeholder")
            || lowercaseValue.contains("my_api_key")
            || lowercaseValue.contains("$(")
    }

    private static func isPlaceholderBackendEndpoint(_ url: URL?) -> Bool {
        guard let url else { return false }
        let value = url.absoluteString.lowercased()
        return containsPlaceholderMarker(value)
            || value.contains("your-project")
            || value.contains("your_project")
            || value.contains("example.")
    }

    private static func isPlaceholderWebURL(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return containsPlaceholderMarker(value)
            || value.contains("example.")
            || value.contains("your-domain")
            || value.contains("your_domain")
    }
}
