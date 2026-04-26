import Foundation

struct AppConfiguration: Sendable {
    static let shared = AppConfiguration(bundle: .main)

    let bundleID: String
    let appScheme: String
    let apiBaseURL: URL?
    let aiAPIBaseURL: URL?
    let revenueCatAPIKey: String
    let superwallAPIKey: String
    let googleClientID: String
    let googleReversedClientID: String

    init(bundle: Bundle) {
        bundleID = bundle.bundleIdentifier ?? "com.langqi.aicalendarapp"
        appScheme = bundle.object(forInfoDictionaryKey: "AppURLScheme") as? String ?? "aicalendarapp"
        revenueCatAPIKey = bundle.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String ?? ""
        superwallAPIKey = bundle.object(forInfoDictionaryKey: "SuperwallAPIKey") as? String ?? ""
        googleClientID = bundle.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? ""
        googleReversedClientID = bundle.object(forInfoDictionaryKey: "GoogleReversedClientID") as? String ?? ""

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
}
