import SwiftUI
import UIKit
import UserNotifications
#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif
#if canImport(FirebaseAppCheck)
import FirebaseAppCheck
#endif
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif
#if canImport(RevenueCat)
import RevenueCat
#endif
#if canImport(SuperwallKit)
import SuperwallKit
#endif

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let configuration = AppConfiguration.shared
    private let logger = AppLogger(category: "bootstrap")
    #if canImport(RevenueCat) && canImport(SuperwallKit)
    private var superwallPurchaseController: AICalendarRevenueCatPurchaseController?
    #endif

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureGlobalAppearance()
        configureFirebaseIfAvailable()
        configureGoogleSignInIfAvailable()
        validateBackendEndpointsIfAvailable()
        validateLegalURLsIfAvailable()
        configureRevenueCatIfAvailable()
        configureSuperwallIfAvailable()
        configureNotifications(for: application)
        AppContainer.shared.analyticsService.track(event: "app_launched")
        logger.info("Finished application bootstrap.")
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        #if canImport(FirebaseMessaging)
        Messaging.messaging().apnsToken = deviceToken
        #endif
        logger.info("Registered APNS device token.")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppContainer.shared.analyticsService.record(error: error, context: "apns_registration")
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        #if canImport(GoogleSignIn)
        if GIDSignIn.sharedInstance.handle(url) {
            return true
        }
        #endif
        return false
    }

    private func configureFirebaseIfAvailable() {
        #if canImport(FirebaseCore)
        let configPath = firebaseConfigurationPath()
        guard
            let configPath,
            let options = FirebaseOptions(contentsOfFile: configPath)
        else {
            #if DEBUG
            logger.notice("Firebase config file missing or invalid. Running with local infrastructure adapters.")
            return
            #else
            fatalError("Firebase configuration is required for non-debug builds.")
            #endif
        }

        if FirebaseApp.app() == nil {
            configureAppCheckIfAvailable()
            FirebaseApp.configure(options: options)
            #if canImport(FirebaseFirestore)
            let settings = Firestore.firestore().settings
            settings.cacheSettings = PersistentCacheSettings(sizeBytes: NSNumber(value: 100 * 1024 * 1024))
            Firestore.firestore().settings = settings
            #endif
            logger.info("Configured Firebase.")
        }
        #else
        logger.notice("Firebase SDK not linked. Running with local infrastructure adapters.")
        #endif
    }

    #if canImport(FirebaseCore)
    private func configureAppCheckIfAvailable() {
        #if canImport(FirebaseAppCheck)
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        logger.info("Configured Firebase App Check debug provider.")
        #else
        AppCheck.setAppCheckProviderFactory(AICalendarAppCheckProviderFactory())
        logger.info("Configured Firebase App Check App Attest provider.")
        #endif
        #endif
    }

    private func firebaseConfigurationPath() -> String? {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")
    }
    #endif

    private func configureRevenueCatIfAvailable() {
        let apiKey = configuration.revenueCatAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        let validation = AppConfiguration.validateRevenueCatAPIKey(apiKey, allowsTestStoreKey: true)
        #else
        let validation = AppConfiguration.validateRevenueCatAPIKey(apiKey, allowsTestStoreKey: false)
        #endif
        guard validation == .valid else {
            let failureReason = validation.failureReason ?? "RevenueCat API key is invalid."
            #if DEBUG
            logger.notice(failureReason)
            return
            #else
            fatalError(failureReason)
            #endif
        }

        #if canImport(RevenueCat)
        #if DEBUG
        Purchases.logLevel = .debug
        #else
        Purchases.logLevel = .info
        #endif

        let builder = Configuration.Builder(withAPIKey: apiKey)
        let configuredBuilder: Configuration.Builder
        if let currentUserID = AuthService.shared.currentUserID?.trimmingCharacters(in: .whitespacesAndNewlines), !currentUserID.isEmpty {
            configuredBuilder = builder.with(appUserID: currentUserID)
        } else {
            configuredBuilder = builder
        }

        Purchases.configure(with: configuredBuilder.build())
        Purchases.shared.delegate = self
        logger.info("Configured RevenueCat.")
        #else
        #if DEBUG
        logger.notice("RevenueCat SDK not linked.")
        #else
        fatalError("RevenueCat SDK is required for non-debug builds.")
        #endif
        #endif
    }

    private func configureSuperwallIfAvailable() {
        let apiKey = configuration.superwallAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let validation = AppConfiguration.validateSuperwallAPIKey(apiKey)
        guard validation == .valid else {
            let failureReason = validation.failureReason ?? "Superwall API key is invalid."
            #if DEBUG
            logger.notice(failureReason)
            return
            #else
            fatalError(failureReason)
            #endif
        }

        #if canImport(SuperwallKit)
        #if canImport(RevenueCat)
        let purchaseController = AICalendarRevenueCatPurchaseController(
            entitlementID: configuration.revenueCatEntitlementID
        )
        superwallPurchaseController = purchaseController
        Superwall.configure(apiKey: apiKey, purchaseController: purchaseController)
        purchaseController.syncSubscriptionStatus()
        #else
        Superwall.configure(apiKey: apiKey)
        #endif
        logger.info("Configured Superwall.")
        #else
        #if DEBUG
        logger.notice("Superwall SDK not linked.")
        #else
        fatalError("Superwall SDK is required for non-debug builds.")
        #endif
        #endif
    }

    private func configureNotifications(for application: UIApplication) {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()

        #if canImport(FirebaseMessaging)
        Messaging.messaging().delegate = self
        #endif
    }

    private func configureGlobalAppearance() {
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithTransparentBackground()
        navigationAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        navigationAppearance.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        navigationAppearance.shadowColor = UIColor.white.withAlphaComponent(0.12)
        navigationAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navigationAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]

        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithTransparentBackground()
        tabAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        tabAppearance.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        tabAppearance.shadowColor = UIColor.white.withAlphaComponent(0.10)

        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        UITableView.appearance().backgroundColor = .clear
        UITableViewCell.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
    }

    private func configureGoogleSignInIfAvailable() {
        let validation = AppConfiguration.validateGoogleSignInConfiguration(
            clientID: configuration.googleClientID,
            reversedClientID: configuration.googleReversedClientID
        )
        guard validation == .valid else {
            let failureReason = validation.failureReason ?? "Google Sign-In configuration is invalid."
            logger.notice(failureReason)
            return
        }

        #if canImport(GoogleSignIn)
        logger.info("Validated Google Sign-In configuration.")
        #else
        logger.notice("Google Sign-In SDK not linked.")
        #endif
    }

    private func validateBackendEndpointsIfAvailable() {
        let validation = AppConfiguration.validateBackendEndpoints(
            apiBaseURL: configuration.apiBaseURL,
            aiAPIBaseURL: configuration.aiAPIBaseURL
        )
        guard validation == .valid else {
            let failureReason = validation.failureReason ?? "Backend endpoint configuration is invalid."
            #if DEBUG
            logger.notice(failureReason)
            return
            #else
            fatalError(failureReason)
            #endif
        }

        logger.info("Validated backend endpoint configuration.")
    }

    private func validateLegalURLsIfAvailable() {
        let validation = AppConfiguration.validateLegalURLs(
            privacyPolicyURL: configuration.privacyPolicyURL,
            termsOfServiceURL: configuration.termsOfServiceURL
        )
        guard validation == .valid else {
            let failureReason = validation.failureReason ?? "Legal URL configuration is invalid."
            #if DEBUG
            logger.notice(failureReason)
            return
            #else
            fatalError(failureReason)
            #endif
        }

        logger.info("Validated legal URL configuration.")
    }
}

#if canImport(FirebaseAppCheck) && canImport(FirebaseCore)
private final class AICalendarAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app) ?? DeviceCheckProvider(app: app)
    }
}
#endif

#if canImport(FirebaseMessaging)
extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        AppContainer.shared.notificationService.updateRemoteToken(fcmToken)
        AppContainer.shared.analyticsService.track(event: "fcm_token_received")
    }
}
#endif

#if canImport(RevenueCat) && canImport(SuperwallKit)
enum RevenueCatSuperwallPurchaseOutcome: Equatable {
    case purchased
    case cancelled
}

struct RevenueCatSuperwallPurchaseResultMapper {
    static func outcome(userCancelled: Bool) -> RevenueCatSuperwallPurchaseOutcome {
        userCancelled ? .cancelled : .purchased
    }
}

private final class AICalendarRevenueCatPurchaseController: PurchaseController {
    private let entitlementID: String

    init(entitlementID: String) {
        self.entitlementID = entitlementID
    }

    @MainActor
    func purchase(product: SuperwallKit.StoreProduct) async -> PurchaseResult {
        do {
            let userID = try currentUserIDForPurchase()
            try await AppContainer.shared.subscriptionService.prepareForPaidAccess(for: userID)

            let revenueCatProduct: RevenueCat.StoreProduct
            if let sk2Product = product.sk2Product {
                revenueCatProduct = RevenueCat.StoreProduct(sk2Product: sk2Product)
            } else if let sk1Product = product.sk1Product {
                revenueCatProduct = RevenueCat.StoreProduct(sk1Product: sk1Product)
            } else {
                return .failed(AppError.dataNotFound)
            }
            let result = try await Purchases.shared.purchase(product: revenueCatProduct)
            switch RevenueCatSuperwallPurchaseResultMapper.outcome(userCancelled: result.userCancelled) {
            case .cancelled:
                return .cancelled
            case .purchased:
                do {
                    let state = try await AppContainer.shared.subscriptionService.confirmPaidAccess(for: userID)
                    syncSubscriptionStatus(state: state)
                    return .purchased
                } catch {
                    Superwall.shared.subscriptionStatus = .unknown
                    AppContainer.shared.analyticsService.record(error: error, context: "superwall_purchase_backend_confirmation")
                    return .pending
                }
            }
        } catch let error as RevenueCat.ErrorCode {
            return error == .paymentPendingError ? .pending : .failed(error)
        } catch {
            return .failed(error)
        }
    }

    @MainActor
    func restorePurchases() async -> RestorationResult {
        do {
            let userID = try currentUserIDForPurchase()
            try await AppContainer.shared.subscriptionService.prepareForPaidAccess(for: userID)
            let customerInfo = try await Purchases.shared.restorePurchases()
            if hasActiveEntitlement(customerInfo: customerInfo) {
                let state = try await AppContainer.shared.subscriptionService.confirmPaidAccess(for: userID)
                syncSubscriptionStatus(state: state)
            } else if let state = try? await AppContainer.shared.subscriptionService.refreshStatus(for: userID) {
                syncSubscriptionStatus(state: state)
            } else {
                Superwall.shared.subscriptionStatus = .inactive
            }
            return .restored
        } catch {
            return .failed(error)
        }
    }

    func syncSubscriptionStatus() {
        Task { @MainActor in
            do {
                let userID = try currentUserIDForPurchase()
                let state = try await AppContainer.shared.subscriptionService.refreshStatus(for: userID)
                syncSubscriptionStatus(state: state)
            } catch {
                Superwall.shared.subscriptionStatus = .unknown
                AppContainer.shared.analyticsService.record(error: error, context: "superwall_subscription_status_sync")
            }
        }
    }

    @MainActor
    private func syncSubscriptionStatus(state: SubscriptionState) {
        Superwall.shared.subscriptionStatus = state.entitlement == .active
            ? .active([Entitlement(id: entitlementID)])
            : .inactive
    }

    private func currentUserIDForPurchase() throws -> String {
        guard let userID = AppContainer.shared.authService.currentUserID?.trimmingCharacters(in: .whitespacesAndNewlines), !userID.isEmpty else {
            throw AppError.invalidCredentials
        }

        return userID
    }

    private func hasActiveEntitlement(customerInfo: RevenueCat.CustomerInfo) -> Bool {
        customerInfo.entitlements[entitlementID]?.isActive == true
    }
}
#endif

#if canImport(RevenueCat)
extension AppDelegate: PurchasesDelegate {
    func purchases(_: Purchases, receivedUpdated _: RevenueCat.CustomerInfo) {
        guard let userID = AppContainer.shared.authService.currentUserID?.trimmingCharacters(in: .whitespacesAndNewlines), !userID.isEmpty else { return }
        Task {
            do {
                _ = try await AppContainer.shared.subscriptionService.refreshStatus(for: userID)
            } catch {
                AppContainer.shared.analyticsService.record(error: error, context: "subscription_customer_info_update")
            }
        }
    }
}
#endif
