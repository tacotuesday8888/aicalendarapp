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

        let lowercaseAPIKey = apiKey.lowercased()
        if lowercaseAPIKey.contains("your_") || lowercaseAPIKey.contains("placeholder") {
            return .placeholderKey
        }

        return apiKey.hasPrefix("appl_") ? .valid : .unsupportedPublicSDKKey
    }
}
