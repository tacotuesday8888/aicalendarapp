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

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureGlobalAppearance()
        configureFirebaseIfAvailable()
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
        guard !apiKey.isEmpty else {
            #if DEBUG
            logger.notice("RevenueCat API key missing from configuration.")
            return
            #else
            fatalError("RevenueCat API key is required for non-debug builds.")
            #endif
        }

        #if canImport(RevenueCat)
        #if !DEBUG
        guard !apiKey.hasPrefix("test_") else {
            fatalError("RevenueCat Test Store API key cannot be used in non-debug builds.")
        }
        #endif

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
        guard !configuration.superwallAPIKey.isEmpty else {
            logger.notice("Superwall API key missing from configuration.")
            return
        }

        #if canImport(SuperwallKit)
        Superwall.configure(apiKey: configuration.superwallAPIKey)
        logger.info("Configured Superwall.")
        #else
        logger.notice("Superwall SDK not linked.")
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

#if canImport(RevenueCat)
extension AppDelegate: PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: RevenueCat.CustomerInfo) {
        guard let userID = AppContainer.shared.authService.currentUserID else { return }
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
