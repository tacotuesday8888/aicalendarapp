import Foundation
import UserNotifications
#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif

final class AnalyticsService: AnalyticsServicing {
    static let shared = AnalyticsService()

    private let logger = AppLogger(category: "analytics")

    func track(event: String, parameters: [String: Any] = [:]) {
        logger.info("Tracked event: \(event)")
        #if canImport(FirebaseAnalytics)
        Analytics.logEvent(event, parameters: parameters)
        #endif
    }

    func track(event: String) {
        track(event: event, parameters: [:])
    }

    func trackScreen(_ name: String) {
        track(event: "screen_view", parameters: ["screen_name": name])
    }

    func record(error: Error, context: String) {
        logger.error("Recorded error in \(context): \(error.localizedDescription)")
        #if canImport(FirebaseCrashlytics)
        Crashlytics.crashlytics().record(error: error, userInfo: ["context": context])
        #endif
    }
}

final class NotificationService: NotificationServicing {
    static let shared = NotificationService()

    var authService: AuthServicing?
    var databaseService: DatabaseServicing?
    var userService: UserServicing?

    private let center = UNUserNotificationCenter.current()
    private let logger = AppLogger(category: "notifications")
    private var remoteToken: String?
    private var authStateTask: Task<Void, Never>?
    private static let reminderTypeUserInfoKey = "aicalendar_notification_type"
    private static let reminderRuleIDUserInfoKey = "aicalendar_reminder_rule_id"
    private static let checkInReminderType = "check_in_reminder"

    func requestAuthorization() async throws -> NotificationPermissionState {
        let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }

        return granted ? .authorized : .denied
    }

    func currentSettings() async -> NotificationPermissionState {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let state: NotificationPermissionState
                switch settings.authorizationStatus {
                case .authorized:
                    state = .authorized
                case .provisional, .ephemeral:
                    state = .provisional
                case .denied:
                    state = .denied
                default:
                    state = .unknown
                }
                continuation.resume(returning: state)
            }
        }
    }

    func schedule(rule: ReminderRule) async throws {
        var components = DateComponents()
        components.hour = rule.hour
        components.minute = rule.minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let content = UNMutableNotificationContent()
        content.title = rule.title
        content.body = "Take a minute to keep your plan aligned."
        content.sound = .default
        content.userInfo = [
            Self.reminderTypeUserInfoKey: Self.checkInReminderType,
            Self.reminderRuleIDUserInfoKey: rule.id,
            "target": rule.target
        ]

        let request = UNNotificationRequest(identifier: rule.id, content: content, trigger: trigger)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func syncReminderRules(_ rules: [ReminderRule]) async throws -> Int {
        let state = await currentSettings()
        guard state == .authorized || state == .provisional else {
            return 0
        }

        let currentRuleIDs = Set(rules.map(\.id))
        let pendingRequests = await pendingNotificationRequests()
        let staleReminderIDs = pendingRequests.compactMap { request -> String? in
            let isCheckInReminder = request.content.userInfo[Self.reminderTypeUserInfoKey] as? String == Self.checkInReminderType
            let isCurrentRule = currentRuleIDs.contains(request.identifier)
            return isCheckInReminder || isCurrentRule ? request.identifier : nil
        }

        if !staleReminderIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: staleReminderIDs)
        }

        let enabledRules = rules.filter(\.enabled)
        for rule in enabledRules {
            try await schedule(rule: rule)
        }
        return enabledRules.count
    }

    func updateRemoteToken(_ token: String) {
        remoteToken = token
        logger.info("Updated remote push token.")
        persistRemoteTokenIfPossible()
    }

    func startAuthStateSync() {
        guard authStateTask == nil, let authService else { return }

        authStateTask = Task { [weak self] in
            for await profile in authService.authStateStream() {
                guard profile != nil else { continue }
                self?.persistRemoteTokenIfPossible()
            }
        }
    }

    private func persistRemoteTokenIfPossible() {
        guard let token = remoteToken, let userID = authService?.currentUserID, let userService else { return }

        Task {
            do {
                var profile = try await userService.fetchProfile(for: userID)
                guard profile.pushToken != token else { return }
                profile.pushToken = token
                try await userService.saveProfile(profile)
                logger.info("Persisted remote push token for \(userID).")
            } catch {
                logger.error("Failed to persist remote push token: \(error.localizedDescription)")
            }
        }
    }

    private func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }
}

final class DeepLinkService: DeepLinkServicing {
    static let shared = DeepLinkService()

    func route(for url: URL) -> AppRoute? {
        let host = url.host ?? ""
        let components = url.pathComponents.filter { $0 != "/" }

        switch host.lowercased() {
        case "today":
            return .today
        case "goal":
            return components.first.map { .goal(id: $0) }
        case "session":
            return components.first.map { .session(id: $0) }
        case "assistant":
            return .assistant(threadID: components.first)
        case "paywall":
            let rawTrigger = components.first ?? PaywallTrigger.premiumTodayPlanner.rawValue
            return .paywall(trigger: PaywallTrigger(rawValue: rawTrigger) ?? .premiumTodayPlanner)
        case "import":
            return components.first.map { .importedSyllabus(jobID: $0) }
        default:
            return nil
        }
    }
}
