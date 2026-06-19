//
//  IOSAppTests.swift
//  iOSAppTests
//
//  Created by Langqi Zhao on 4/12/26.
//

import Foundation
import Testing
@testable import aicalendarapp

private final class FailingDatabaseService: DatabaseServicing, @unchecked Sendable {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func save<T>(_ value: T, in collection: AppCollection, id: String, userID: String?) async throws where T: Decodable, T: Encodable {
        throw error
    }

    func fetch<T>(_ type: T.Type, from collection: AppCollection, id: String, userID: String?) async throws -> T where T: Decodable, T: Encodable {
        throw error
    }

    func fetchAll<T>(_ type: T.Type, from collection: AppCollection, userID: String?) async throws -> [T] where T: Decodable, T: Encodable {
        throw error
    }

    func delete(from collection: AppCollection, id: String, userID: String?) async throws {
        throw error
    }

    func observeAll<T>(_ type: T.Type, from collection: AppCollection, userID: String?) -> AsyncThrowingStream<[T], Error> where T: Decodable, T: Encodable {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    func deleteLocalData(for userID: String) async {}
}

private final class TestDatabaseService: DatabaseServicing, @unchecked Sendable {
    private var storage = [String: [String: Data]]()
    private let lock = NSLock()
    private(set) var deletedLocalUserIDs = [String]()

    func save<T>(_ value: T, in collection: AppCollection, id: String, userID: String?) async throws where T: Decodable, T: Encodable {
        let data = try JSONEncoder.appEncoder().encode(value)
        lock.withLock {
            storage[path(for: collection, userID: userID), default: [:]][id] = data
        }
    }

    func fetch<T>(_ type: T.Type, from collection: AppCollection, id: String, userID: String?) async throws -> T where T: Decodable, T: Encodable {
        let data = lock.withLock {
            storage[path(for: collection, userID: userID)]?[id]
        }
        guard let data else {
            throw AppError.dataNotFound
        }
        return try JSONDecoder.appDecoder().decode(T.self, from: data)
    }

    func fetchAll<T>(_ type: T.Type, from collection: AppCollection, userID: String?) async throws -> [T] where T: Decodable, T: Encodable {
        let values = lock.withLock {
            Array(storage[path(for: collection, userID: userID), default: [:]].values)
        }
        return try values.map { try JSONDecoder.appDecoder().decode(T.self, from: $0) }
    }

    func delete(from collection: AppCollection, id: String, userID: String?) async throws {
        lock.withLock {
            storage[path(for: collection, userID: userID)]?[id] = nil
        }
    }

    func observeAll<T>(_ type: T.Type, from collection: AppCollection, userID: String?) -> AsyncThrowingStream<[T], Error> where T: Decodable, T: Encodable {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let values = try await fetchAll(type, from: collection, userID: userID)
                    continuation.yield(values)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func deleteLocalData(for userID: String) async {
        lock.withLock {
            deletedLocalUserIDs.append(userID)
            storage["users"]?[userID] = nil
            let prefix = "users/\(userID)/"
            let paths = storage.keys.filter { $0.hasPrefix(prefix) }
            paths.forEach { storage[$0] = nil }
        }
    }

    private func path(for collection: AppCollection, userID: String?) -> String {
        switch collection {
        case .users:
            return "users"
        default:
            return "users/\(userID ?? "preview")/\(collection.rawValue)"
        }
    }
}

private final class TestAnalyticsService: AnalyticsServicing {
    private(set) var events = [String]()
    private(set) var screens = [String]()
    private(set) var errors = [String]()

    func track(event: String, parameters: [String: Any]) {
        events.append(event)
    }

    func track(event: String) {
        events.append(event)
    }

    func trackScreen(_ name: String) {
        screens.append(name)
    }

    func record(error: Error, context: String) {
        errors.append(context)
    }
}

private final class TestURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: AppError.unknown("Missing test request handler."))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class TestPlannerService: PlannerServicing {
    var snapshot = PlannerSnapshot.empty
    private(set) var savedBlocks = [PlannerBlock]()
    private(set) var deletedBlockIDs = [String]()

    func observeSnapshot(for userID: String, on date: Date) -> AsyncThrowingStream<PlannerSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    func savePlannerBlock(_ block: PlannerBlock, for userID: String) async throws {
        savedBlocks.append(block)
        snapshot.blocks.removeAll { $0.id == block.id }
        snapshot.blocks.append(block)
    }

    func deletePlannerBlock(id: String, for userID: String) async throws {
        deletedBlockIDs.append(id)
        snapshot.blocks.removeAll { $0.id == id }
    }
}

private final class TestGoalService: GoalServicing {
    private(set) var goals = [Goal]()
    private(set) var deletedGoalIDs = [String]()
    private(set) var reorderedGoals = [[Goal]]()
    var generatedPlan: GoalPlanDraft?
    var updateError: Error?

    func observeGoals(for userID: String) -> AsyncThrowingStream<[Goal], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(goals)
            continuation.finish()
        }
    }

    func createGoal(_ goal: Goal, for userID: String) async throws {
        goals.append(goal)
    }

    func updateGoal(_ goal: Goal, for userID: String) async throws {
        if let updateError {
            throw updateError
        }

        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            goals[index] = goal
        } else {
            goals.append(goal)
        }
    }

    func deleteGoal(id: String, for userID: String) async throws {
        deletedGoalIDs.append(id)
        goals.removeAll { $0.id == id }
    }

    func reorderGoals(_ goals: [Goal], for userID: String) async throws {
        reorderedGoals.append(goals)
        self.goals = goals
    }

    func generatePlan(for goal: Goal, timelineWeeks: Int, userID: String) async throws -> GoalPlanDraft {
        if let generatedPlan {
            return generatedPlan
        }
        let plan = GoalPlanDraft(
            goalID: goal.id,
            summary: "Draft plan",
            suggestedTimelineWeeks: timelineWeeks,
            checkpoints: [],
            nextActions: []
        )
        generatedPlan = plan
        return plan
    }
}

private final class TestAuthService: AuthServicing {
    var currentUserID: String?
    var profile: UserProfile?
    var authStates: [UserProfile?]?
    private(set) var didSignOut = false

    init(currentUserID: String? = nil, profile: UserProfile? = nil) {
        self.currentUserID = currentUserID
        self.profile = profile
    }

    func authStateStream() -> AsyncStream<UserProfile?> {
        AsyncStream { continuation in
            for state in authStates ?? [profile] {
                continuation.yield(state)
            }
            continuation.finish()
        }
    }

    func signIn(email: String, password: String) async throws -> UserProfile {
        throw AppError.network(description: "Not implemented in test.")
    }

    func signUp(email: String, password: String, displayName: String) async throws -> UserProfile {
        throw AppError.network(description: "Not implemented in test.")
    }

    func signInWithApple() async throws -> UserProfile {
        throw AppError.network(description: "Not implemented in test.")
    }

    func signInWithGoogle() async throws -> UserProfile {
        throw AppError.network(description: "Not implemented in test.")
    }

    func signOut() async throws {
        didSignOut = true
        currentUserID = nil
    }
}

private final class TestUserService: UserServicing {
    var profile: UserProfile
    var onboardingState = OnboardingState()
    var fetchOnboardingError: Error?
    var saveProfileError: Error?
    private(set) var savedProfiles = [UserProfile]()
    private(set) var updatedPushTokens = [(userID: String, token: String)]()
    private(set) var clearedPushTokens = [(userID: String, token: String)]()

    init(profile: UserProfile) {
        self.profile = profile
    }

    func fetchProfile(for userID: String) async throws -> UserProfile {
        profile
    }

    func saveProfile(_ profile: UserProfile) async throws {
        if let saveProfileError {
            throw saveProfileError
        }
        savedProfiles.append(profile)
        self.profile = profile
    }

    func updatePushToken(_ token: String, for userID: String) async throws {
        if let saveProfileError {
            throw saveProfileError
        }
        updatedPushTokens.append((userID: userID, token: token))
        profile.pushToken = token
    }

    func clearPushToken(_ token: String, for userID: String) async throws -> Bool {
        if let saveProfileError {
            throw saveProfileError
        }
        guard profile.pushToken == token else { return false }
        clearedPushTokens.append((userID: userID, token: token))
        profile.pushToken = nil
        return true
    }

    func fetchOnboardingState(for userID: String) async throws -> OnboardingState {
        if let fetchOnboardingError {
            throw fetchOnboardingError
        }
        return onboardingState
    }

    func saveOnboardingState(_ state: OnboardingState, for userID: String) async throws {
        onboardingState = state
    }
}

private final class TestCalendarSyncService: CalendarSyncServicing {
    var calendars = [SyncLink]()
    var availableCalendarsError: Error?
    var disconnectError: Error?
    var importError: Error?
    var importedBlocks = [PlannerBlock]()
    private(set) var importedCalendarIDs = [[String]]()
    private(set) var disconnectedUserIDs = [String]()

    func requestAccess() async throws -> Bool {
        true
    }

    func availableCalendars() async throws -> [SyncLink] {
        if let availableCalendarsError {
            throw availableCalendarsError
        }
        return calendars
    }

    func importSelectedCalendars(_ selectedCalendarIDs: [String], for userID: String) async throws -> [PlannerBlock] {
        if let importError {
            throw importError
        }
        importedCalendarIDs.append(selectedCalendarIDs)
        return importedBlocks
    }

    func disconnectCalendars(for userID: String) async throws {
        if let disconnectError {
            throw disconnectError
        }
        disconnectedUserIDs.append(userID)
    }
}

private final class TestNotificationService: NotificationServicing {
    var state: NotificationPermissionState = .unknown
    var authorizationResult: NotificationPermissionState = .authorized
    private(set) var scheduledRules = [ReminderRule]()
    private(set) var syncedRuleSets = [[ReminderRule]]()
    private(set) var cancelledReminderCounts = [Int]()
    private(set) var cancelledLocalAccountNotificationCounts = [Int]()
    private(set) var clearedRemoteTokenUserIDs = [String]()
    var queuedSessionTimerCount = 0
    var shouldClearRemoteToken = true

    func requestAuthorization() async throws -> NotificationPermissionState {
        state = authorizationResult
        return state
    }

    func currentSettings() async -> NotificationPermissionState {
        state
    }

    func schedule(rule: ReminderRule) async throws {
        scheduledRules.append(rule)
    }

    func syncReminderRules(_ rules: [ReminderRule]) async throws -> Int {
        syncedRuleSets.append(rules)
        guard state == .authorized || state == .provisional else {
            return 0
        }

        let enabledRules = rules.filter(\.enabled)
        scheduledRules = enabledRules
        return enabledRules.count
    }

    func cancelReminderNotifications() async -> Int {
        let count = scheduledRules.count
        scheduledRules.removeAll()
        cancelledReminderCounts.append(count)
        return count
    }

    func cancelLocalAccountNotifications() async -> Int {
        let count = scheduledRules.count + queuedSessionTimerCount
        scheduledRules.removeAll()
        queuedSessionTimerCount = 0
        cancelledLocalAccountNotificationCounts.append(count)
        return count
    }

    func clearRemoteToken(for userID: String) async -> Bool {
        clearedRemoteTokenUserIDs.append(userID)
        return shouldClearRemoteToken
    }

    func updateRemoteToken(_ token: String) {}
}

private final class TestSubscriptionService: SubscriptionServicing {
    var state = SubscriptionState.locked
    var availableOffersResult = SubscriptionOffer.fallbackOffers
    var availableOffersError: Error?
    private(set) var restoredUserIDs = [String]()
    private(set) var refreshedUserIDs = [String]()
    private(set) var linkedUserIDs = [String]()
    private(set) var preparedPaidAccessUserIDs = [String]()
    private(set) var confirmedPaidAccessUserIDs = [String]()
    private(set) var didUnlinkUser = false

    func observeSubscriptionState(for userID: String) -> AsyncStream<SubscriptionState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func availableOffers() async throws -> [SubscriptionOffer] {
        if let availableOffersError {
            throw availableOffersError
        }
        return availableOffersResult
    }

    func refreshStatus(for userID: String) async throws -> SubscriptionState {
        refreshedUserIDs.append(userID)
        return state
    }

    func purchase(plan: SubscriptionPlan, for userID: String) async throws -> SubscriptionState {
        state = SubscriptionState(entitlement: .active, activePlan: plan, trialEligible: false, lastSyncedAt: .now)
        return state
    }

    func restore(for userID: String) async throws -> SubscriptionState {
        restoredUserIDs.append(userID)
        return state
    }

    func linkUser(_ userID: String) async {
        linkedUserIDs.append(userID)
    }

    func unlinkUser() async {
        didUnlinkUser = true
    }

    func prepareForPaidAccess(for userID: String) async throws {
        preparedPaidAccessUserIDs.append(userID)
    }

    func confirmPaidAccess(for userID: String) async throws -> SubscriptionState {
        confirmedPaidAccessUserIDs.append(userID)
        return state
    }
}

private final class TestPaywallService: PaywallServicing {
    private(set) var registerCallCount = 0
    private(set) var handledTriggers = [PaywallTrigger]()
    private(set) var handledUserIDs = [String?]()

    func registerTriggers() {
        registerCallCount += 1
    }

    func handle(trigger: PaywallTrigger, for userID: String?) async {
        handledTriggers.append(trigger)
        handledUserIDs.append(userID)
    }
}

private final class TestBackendFunctionService: BackendFunctionServicing {
    var exportResponse: ExportUserDataResponsePayload?
    var subscriptionState = SubscriptionState.locked
    var subscriptionStateResponses = [SubscriptionState]()
    private(set) var deletedUserIDs = [String]()
    private(set) var exportedUserIDs = [String]()
    private(set) var syncedSubscriptionUserIDs = [String]()

    func assistantRespond(_ request: AssistantRequestPayload) async throws -> AssistantThread {
        throw AppError.network(description: "Not implemented in test.")
    }

    func generateGoalPlan(_ request: GoalPlanRequestPayload) async throws -> GoalPlanDraft {
        throw AppError.network(description: "Not implemented in test.")
    }

    func commitAssistantDraft(_ request: AssistantDraftCommitPayload) async throws {}

    func importSyllabusText(_ request: ImportTextRequestPayload) async throws -> ImportJob {
        throw AppError.network(description: "Not implemented in test.")
    }

    func importSyllabusFile(_ request: ImportFileRequestPayload) async throws -> ImportJob {
        throw AppError.network(description: "Not implemented in test.")
    }

    func commitImport(_ request: ImportCommitPayload) async throws {}

    func deleteImport(_ request: DeleteImportPayload) async throws {}

    func syncSubscriptionStatus(_ request: UserJobRequestPayload) async throws -> SubscriptionState {
        syncedSubscriptionUserIDs.append(request.userID)
        if !subscriptionStateResponses.isEmpty {
            return subscriptionStateResponses.removeFirst()
        }
        return subscriptionState
    }

    func deleteUserAccount(_ request: UserJobRequestPayload) async throws {
        deletedUserIDs.append(request.userID)
    }

    func exportUserData(_ request: UserJobRequestPayload) async throws -> ExportUserDataResponsePayload {
        exportedUserIDs.append(request.userID)
        if let exportResponse {
            return exportResponse
        }
        return ExportUserDataResponsePayload(
            userID: request.userID,
            requestedAt: Date(timeIntervalSince1970: 1_777_000_000),
            profile: .object([:]),
            collections: [:]
        )
    }
}

private final class TestAIBackendService: AIBackendServicing {
    var isConfigured = true
    var assistantResponse: AIWorkflowRunResponse<AIAssistantChatResult>
    private(set) var workflows = [AIWorkflow]()

    init(assistantResponse: AIWorkflowRunResponse<AIAssistantChatResult>) {
        self.assistantResponse = assistantResponse
    }

    func run<Payload, Result>(
        workflow: AIWorkflow,
        payload: Payload,
        decode: Result.Type
    ) async throws -> AIWorkflowRunResponse<Result> where Payload: Encodable, Result: Decodable {
        workflows.append(workflow)
        guard workflow == .assistantChat,
              let response = assistantResponse as? AIWorkflowRunResponse<Result> else {
            throw AppError.network(description: "Unsupported test AI workflow.")
        }
        return response
    }
}

private final class TestSyllabusImportService: SyllabusImportServicing {
    var observedJobs = [ImportJob]()
    var importTextResult: ImportJob?
    var importFileResult: ImportJob?
    var importError: Error?
    var commitError: Error?
    private(set) var importedTexts = [String]()
    private(set) var importFileURLs = [URL]()
    private(set) var committedJobs = [ImportJob]()
    private(set) var deletedJobIDs = [String]()

    func observeImports(for userID: String) -> AsyncThrowingStream<[ImportJob], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(observedJobs)
            continuation.finish()
        }
    }

    func importText(_ text: String, for userID: String) async throws -> ImportJob {
        if let importError {
            throw importError
        }
        importedTexts.append(text)
        return importTextResult ?? ImportJob(
            sourceName: "text-import",
            status: .completed,
            extractedCourses: [],
            extractedAssignments: [],
            warnings: []
        )
    }

    func importFile(at fileURL: URL, for userID: String) async throws -> ImportJob {
        if let importError {
            throw importError
        }
        importFileURLs.append(fileURL)
        return importFileResult ?? ImportJob(
            sourceName: fileURL.lastPathComponent,
            status: .completed,
            extractedCourses: [],
            extractedAssignments: [],
            warnings: []
        )
    }

    func commit(_ job: ImportJob, for userID: String) async throws {
        if let commitError {
            throw commitError
        }
        committedJobs.append(job)
    }

    func delete(_ job: ImportJob, for userID: String) async throws {
        deletedJobIDs.append(job.id)
    }
}

@MainActor
struct IOSAppTests {
    private func uniqueUserID(_ prefix: String = "test-user") -> String {
        "\(prefix)-\(UUID().uuidString)"
    }

    private struct DatedPayload: Decodable {
        var createdAt: Date
    }

    private func testProfile(id: String = UUID().uuidString) -> UserProfile {
        UserProfile(
            id: id,
            email: "\(id)@example.com",
            displayName: "Test Student",
            academicFocus: "Biology",
            signInProvider: "email",
            assistantOptIn: true,
            selectedCalendarIDs: [],
            createdAt: Date(timeIntervalSince1970: 1_776_000_000)
        )
    }

    private func testImportJob(id: String = UUID().uuidString) -> ImportJob {
        let course = Course(
            id: "course-\(id)",
            title: "Computer Science 101",
            instructor: "Dr. Rivera",
            meetingDays: ["Mon", "Wed"],
            colorHex: "#2F6BFF"
        )
        let assignment = Assignment(
            id: "assignment-\(id)",
            courseID: course.id,
            title: "Homework 1",
            dueDate: Date(timeIntervalSince1970: 1_779_724_800),
            notes: "Imported from syllabus.",
            isComplete: false
        )

        return ImportJob(
            id: id,
            sourceName: "text-import",
            status: .completed,
            extractedCourses: [course],
            extractedAssignments: [assignment],
            warnings: []
        )
    }

    private func sessionContainer(
        authService: AuthServicing,
        userService: UserServicing,
        subscriptionService: SubscriptionServicing,
        analyticsService: AnalyticsServicing = TestAnalyticsService(),
        calendarSyncService: CalendarSyncServicing = TestCalendarSyncService(),
        notificationService: NotificationServicing = TestNotificationService()
    ) -> AppContainer {
        AppContainer(
            configuration: .shared,
            analyticsService: analyticsService,
            authService: authService,
            userService: userService,
            goalService: TestGoalService(),
            plannerService: TestPlannerService(),
            calendarSyncService: calendarSyncService,
            studySessionService: StudySessionService.shared,
            reflectionService: ReflectionService.shared,
            assistantService: AssistantService.shared,
            backendFunctionService: TestBackendFunctionService(),
            aiBackendService: AIBackendService(configuration: .shared),
            syllabusImportService: SyllabusImportService.shared,
            notificationService: notificationService,
            subscriptionService: subscriptionService,
            paywallService: TestPaywallService(),
            databaseService: TestDatabaseService(),
            storageService: StorageService.shared,
            networkService: NetworkService.shared,
            deepLinkService: DeepLinkService.shared
        )
    }

    @Test func appDecoderParsesFractionalAndPlainISO8601Dates() throws {
        let decoder = JSONDecoder.appDecoder()
        let fractional = #"{"createdAt":"2026-04-26T22:33:38.123Z"}"#.data(using: .utf8)!
        let plain = #"{"createdAt":"2026-04-26T22:33:38Z"}"#.data(using: .utf8)!

        let fractionalPayload = try decoder.decode(DatedPayload.self, from: fractional)
        let plainPayload = try decoder.decode(DatedPayload.self, from: plain)

        #expect(abs(fractionalPayload.createdAt.timeIntervalSince1970 - 1_777_242_818.123) < 0.001)
        #expect(plainPayload.createdAt.timeIntervalSince1970 == 1_777_242_818)
    }

    @Test func networkServiceContinuesWhenAppCheckTokenProviderFails() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestURL = URL(string: "https://example.invalid/functions/ping")!
        let responseData = #"{"success":true}"#.data(using: .utf8)!
        TestURLProtocol.requestHandler = { request in
            #expect(request.url == requestURL)
            #expect(request.value(forHTTPHeaderField: "X-Firebase-AppCheck") == nil)
            return (
                HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                responseData
            )
        }
        defer { TestURLProtocol.requestHandler = nil }

        struct PingResponse: Decodable {
            let success: Bool
        }

        let service = NetworkService(
            session: session,
            appCheckTokenProvider: {
                throw AppError.network(description: "Debug App Check token unavailable.")
            }
        )

        let response = try await service.request(
            APIEndpoint(path: "ping", baseURL: URL(string: "https://example.invalid/functions")!, retryCount: 0),
            decode: PingResponse.self
        )

        #expect(response.success)
    }

    @Test func networkServiceBuildsBackendErrorMessage() {
        let responseData = #"{"success":false,"error":"App Check is misconfigured."}"#.data(using: .utf8)!
        let description = NetworkService.errorDescription(from: responseData, statusCode: 412)

        #expect(description.contains("412"))
        #expect(description.contains("App Check is misconfigured."))
    }

    #if canImport(RevenueCat) && canImport(SuperwallKit)
    @Test func revenueCatSuperwallPurchaseMapperTreatsCancellationAsCancelled() {
        #expect(RevenueCatSuperwallPurchaseResultMapper.outcome(userCancelled: true) == .cancelled)
        #expect(RevenueCatSuperwallPurchaseResultMapper.outcome(userCancelled: false) == .purchased)
    }
    #endif

    @Test func revenueCatAPIKeyValidationAllowsIOSPublicSDKKey() {
        #expect(
            AppConfiguration.validateRevenueCatAPIKey("  appl_public_ios_key  ", allowsTestStoreKey: false) == .valid
        )
    }

    @Test func revenueCatAPIKeyValidationAllowsTestStoreKeyOnlyWhenRequested() {
        #expect(
            AppConfiguration.validateRevenueCatAPIKey("test_local_store_key", allowsTestStoreKey: true) == .valid
        )
        #expect(
            AppConfiguration.validateRevenueCatAPIKey(
                "test_local_store_key",
                allowsTestStoreKey: false
            ) == .testStoreKeyNotAllowed
        )
    }

    @Test func revenueCatAPIKeyValidationRejectsSecretsAndUnsupportedKeys() {
        #expect(AppConfiguration.validateRevenueCatAPIKey("", allowsTestStoreKey: false) == .missing)
        #expect(
            AppConfiguration.validateRevenueCatAPIKey("sk_server_secret", allowsTestStoreKey: true) == .secretAPIKey
        )
        #expect(
            AppConfiguration.validateRevenueCatAPIKey("atk_oauth_token", allowsTestStoreKey: true) == .oauthToken
        )
        #expect(
            AppConfiguration.validateRevenueCatAPIKey("goog_android_public_key", allowsTestStoreKey: false)
                == .unsupportedPublicSDKKey
        )
        #expect(
            AppConfiguration.validateRevenueCatAPIKey(
                "appl_your_revenuecat_ios_public_sdk_key",
                allowsTestStoreKey: false
            ) == .placeholderKey
        )
    }

    @Test func superwallAPIKeyValidationAllowsPublicSDKKey() {
        #expect(AppConfiguration.validateSuperwallAPIKey("  pk_public_superwall_key  ") == .valid)
    }

    @Test func superwallAPIKeyValidationRejectsMissingPlaceholderAndUnsupportedKeys() {
        #expect(AppConfiguration.validateSuperwallAPIKey("") == .missing)
        #expect(AppConfiguration.validateSuperwallAPIKey("pk_your_superwall_public_api_key") == .placeholderKey)
        #expect(AppConfiguration.validateSuperwallAPIKey("MY_API_KEY") == .placeholderKey)
        #expect(AppConfiguration.validateSuperwallAPIKey("sk_server_secret") == .unsupportedPublicSDKKey)
        #expect(AppConfiguration.validateSuperwallAPIKey("appl_revenuecat_ios_key") == .unsupportedPublicSDKKey)
    }

    @Test func googleSignInConfigurationValidationAllowsMatchingOAuthValues() {
        #expect(
            AppConfiguration.validateGoogleSignInConfiguration(
                clientID: "1234567890-abcdef.apps.googleusercontent.com",
                reversedClientID: "com.googleusercontent.apps.1234567890-abcdef"
            ) == .valid
        )
    }

    @Test func googleSignInConfigurationValidationRejectsMissingAndPlaceholderValues() {
        #expect(
            AppConfiguration.validateGoogleSignInConfiguration(
                clientID: "",
                reversedClientID: "com.googleusercontent.apps.123"
            ) == .missingClientID
        )
        #expect(
            AppConfiguration.validateGoogleSignInConfiguration(
                clientID: "123.apps.googleusercontent.com",
                reversedClientID: ""
            ) == .missingReversedClientID
        )
        #expect(
            AppConfiguration.validateGoogleSignInConfiguration(
                clientID: "your_google_client_id.apps.googleusercontent.com",
                reversedClientID: "com.googleusercontent.apps.your_google_client_id"
            ) == .placeholderValue
        )
    }

    @Test func googleSignInConfigurationValidationRejectsUnsupportedOrMismatchedValues() {
        #expect(
            AppConfiguration.validateGoogleSignInConfiguration(
                clientID: "1234567890-abcdef",
                reversedClientID: "com.googleusercontent.apps.1234567890-abcdef"
            ) == .unsupportedClientID
        )
        #expect(
            AppConfiguration.validateGoogleSignInConfiguration(
                clientID: "1234567890-abcdef.apps.googleusercontent.com",
                reversedClientID: "aicalendarapp"
            ) == .unsupportedReversedClientID
        )
        #expect(
            AppConfiguration.validateGoogleSignInConfiguration(
                clientID: "1234567890-abcdef.apps.googleusercontent.com",
                reversedClientID: "com.googleusercontent.apps.other-client"
            ) == .mismatchedReversedClientID
        )
    }

    @Test func goalPlanGenerationRequiresLiveBackend() async throws {
        let service = GoalService()
        service.backendFunctionService = BackendFunctionService()
        let goal = Goal(
            title: "Raise chemistry grade",
            detail: "Reach an A by finals week.",
            priority: .high,
            category: .academic,
            status: .active,
            dueDate: .now.addingTimeInterval(60 * 60 * 24 * 30),
            sortIndex: 0,
            subGoals: [],
            checkpoints: []
        )

        do {
            _ = try await service.generatePlan(for: goal, timelineWeeks: 6, userID: "test-user")
            #expect(Bool(false))
        } catch let error as AppError {
            #expect(error.errorDescription?.contains("live backend") == true)
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func deepLinkParserHandlesGoalRoutes() {
        let route = DeepLinkService.shared.route(for: URL(string: "aicalendarapp://goal/abc123")!)
        #expect(route == .goal(id: "abc123"))
    }

    @Test func databaseServiceStoresAndFetchesUserProfiles() async throws {
        let service = TestDatabaseService()
        let profile = UserProfile(
            id: UUID().uuidString,
            email: "planner@example.com",
            displayName: "Planner",
            academicFocus: "Computer Science",
            signInProvider: "email",
            assistantOptIn: true,
            selectedCalendarIDs: [],
            createdAt: .now
        )

        try await service.save(profile, in: .users, id: profile.id, userID: nil)
        let fetched = try await service.fetch(UserProfile.self, from: .users, id: profile.id, userID: nil)
        #expect(fetched.email == profile.email)
    }

    @Test func userServiceClearsPushTokenInLocalFallback() async throws {
        let database = TestDatabaseService()
        let service = UserService()
        service.databaseService = database
        var profile = testProfile(id: uniqueUserID("user-clear-token"))
        profile.pushToken = "token-to-clear"
        try await database.save(profile, in: .users, id: profile.id, userID: nil)

        let cleared = try await service.clearPushToken("token-to-clear", for: profile.id)

        let fetched = try await service.fetchProfile(for: profile.id)
        #expect(cleared)
        #expect(fetched.pushToken == nil)
    }

    @Test func userServiceDoesNotClearMismatchedPushTokenInLocalFallback() async throws {
        let database = TestDatabaseService()
        let service = UserService()
        service.databaseService = database
        var profile = testProfile(id: uniqueUserID("user-mismatched-token"))
        profile.pushToken = "current-token"
        try await database.save(profile, in: .users, id: profile.id, userID: nil)

        let cleared = try await service.clearPushToken("old-token", for: profile.id)

        let fetched = try await service.fetchProfile(for: profile.id)
        #expect(!cleared)
        #expect(fetched.pushToken == "current-token")
    }

    @Test func databaseServicePurgesLocalUserData() async throws {
        let service = DatabaseService.shared
        let userID = uniqueUserID("local-delete")
        let profile = testProfile(id: userID)
        let start = Date(timeIntervalSince1970: 1_776_000_000)
        let block = PlannerBlock(
            title: "Local cleanup check",
            detail: "Should be removed with account deletion.",
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            type: .studySession,
            source: .app,
            linkedGoalID: nil,
            linkedAssignmentID: nil
        )

        try await service.save(profile, in: .users, id: userID, userID: nil)
        try await service.save(block, in: .plannerBlocks, id: block.id, userID: userID)

        await service.deleteLocalData(for: userID)

        await #expect(throws: AppError.dataNotFound) {
            try await service.fetch(UserProfile.self, from: .users, id: userID, userID: nil)
        }
        await #expect(throws: AppError.dataNotFound) {
            try await service.fetch(PlannerBlock.self, from: .plannerBlocks, id: block.id, userID: userID)
        }
    }

    @Test func plannerBlocksPersistThroughServiceLayerAndDeleteCleanly() async throws {
        let userID = uniqueUserID("planner")
        let database = TestDatabaseService()
        let service = PlannerService()
        service.databaseService = database
        let start = Date(timeIntervalSince1970: 1_776_000_000)
        let block = PlannerBlock(
            title: "Chemistry review",
            detail: "Practice equilibrium problems.",
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            type: .studySession,
            source: .app,
            linkedGoalID: nil,
            linkedAssignmentID: nil
        )

        try await service.savePlannerBlock(block, for: userID)
        var updated = block
        updated.title = "Chemistry review updated"
        updated.endDate = start.addingTimeInterval(90 * 60)
        try await service.savePlannerBlock(updated, for: userID)

        let relaunchedDatabase = database
        let persisted = try await relaunchedDatabase.fetch(
            PlannerBlock.self,
            from: .plannerBlocks,
            id: block.id,
            userID: userID
        )
        #expect(persisted.title == "Chemistry review updated")
        #expect(persisted.endDate == updated.endDate)

        try await service.deletePlannerBlock(id: block.id, for: userID)
        await #expect(throws: AppError.dataNotFound) {
            try await relaunchedDatabase.fetch(PlannerBlock.self, from: .plannerBlocks, id: block.id, userID: userID)
        }
    }

    @Test func calendarViewModelSavesUpdatesAndDeletesPlannerBlocks() async throws {
        let profile = testProfile(id: uniqueUserID("calendar-vm"))
        let plannerService = TestPlannerService()
        let analyticsService = TestAnalyticsService()
        let viewModel = CalendarViewModel(
            user: profile,
            plannerService: plannerService,
            analyticsService: analyticsService
        )

        let start = Date(timeIntervalSince1970: 1_776_200_000)
        viewModel.beginAddingBlock()
        viewModel.blockTitle = "Review biology notes"
        viewModel.blockDetail = "Focus on chapter 4 diagrams."
        viewModel.blockStartDate = start
        viewModel.blockDurationMinutes = 45
        viewModel.blockType = .studySession

        await viewModel.addPlannerBlock()

        let savedBlock = try #require(plannerService.savedBlocks.first)
        #expect(savedBlock.title == "Review biology notes")
        #expect(savedBlock.endDate == start.addingTimeInterval(45 * 60))
        #expect(viewModel.presentedSheet == nil)
        #expect(analyticsService.events.contains("planner_block_saved"))

        var updatedBlock = savedBlock
        updatedBlock.title = "Review biology notes updated"
        updatedBlock.detail = "Add practice questions."
        try await viewModel.updateBlock(updatedBlock)

        #expect(plannerService.savedBlocks.last?.title == "Review biology notes updated")
        #expect(analyticsService.events.contains("planner_block_updated"))

        viewModel.presentDetail(for: updatedBlock)
        viewModel.requestDelete(updatedBlock)
        await viewModel.confirmDelete()

        #expect(plannerService.deletedBlockIDs == [updatedBlock.id])
        #expect(viewModel.blockPendingDeletion == nil)
        #expect(viewModel.presentedSheet == nil)
        #expect(analyticsService.events.contains("planner_block_deleted"))
    }

    @Test func goalLifecyclePersistsCompletionReorderAndDeleteThroughServiceLayer() async throws {
        let userID = uniqueUserID("goals")
        let database = TestDatabaseService()
        let service = GoalService()
        service.databaseService = database
        var midtermGoal = Goal(
            title: "Prepare for biology midterm",
            detail: "Review chapters 5 through 8.",
            priority: .high,
            category: .academic,
            status: .active,
            dueDate: Date(timeIntervalSince1970: 1_776_864_000),
            sortIndex: 0,
            subGoals: [],
            checkpoints: []
        )
        let essayGoal = Goal(
            title: "Draft history essay",
            detail: "Outline and write first draft.",
            priority: .medium,
            category: .academic,
            status: .active,
            dueDate: Date(timeIntervalSince1970: 1_777_728_000),
            sortIndex: 1,
            subGoals: [],
            checkpoints: []
        )

        try await service.createGoal(midtermGoal, for: userID)
        try await service.createGoal(essayGoal, for: userID)

        midtermGoal.status = .completed
        midtermGoal.detail = "Completed final review packet."
        try await service.updateGoal(midtermGoal, for: userID)
        try await service.reorderGoals([essayGoal, midtermGoal], for: userID)

        let relaunchedDatabase = database
        let persistedGoals = try await relaunchedDatabase.fetchAll(Goal.self, from: .goals, userID: userID)
        let persistedMidterm = try #require(persistedGoals.first { $0.id == midtermGoal.id })
        let persistedEssay = try #require(persistedGoals.first { $0.id == essayGoal.id })
        #expect(persistedMidterm.status == .completed)
        #expect(persistedMidterm.detail == "Completed final review packet.")
        #expect(persistedEssay.sortIndex == 0)
        #expect(persistedMidterm.sortIndex == 1)

        try await service.deleteGoal(id: essayGoal.id, for: userID)
        await #expect(throws: AppError.dataNotFound) {
            try await relaunchedDatabase.fetch(Goal.self, from: .goals, id: essayGoal.id, userID: userID)
        }
    }

    @Test func goalsViewModelCreatesCompletesEditsAndDeletesGoals() async throws {
        let profile = testProfile(id: uniqueUserID("goals-vm"))
        let goalService = TestGoalService()
        let analyticsService = TestAnalyticsService()
        let viewModel = GoalsViewModel(
            user: profile,
            goalService: goalService,
            databaseService: TestDatabaseService(),
            analyticsService: analyticsService
        )

        let dueDate = Date(timeIntervalSince1970: 1_776_500_000)
        viewModel.title = "Finish biology chapter"
        viewModel.detail = "Read, annotate, and summarize."
        viewModel.selectedPriority = .high
        viewModel.selectedCategory = .academic
        viewModel.dueDate = dueDate

        await viewModel.addGoal()

        let createdGoal = try #require(goalService.goals.first)
        #expect(createdGoal.title == "Finish biology chapter")
        #expect(createdGoal.status == .active)
        #expect(viewModel.title.isEmpty)
        #expect(analyticsService.events.contains("goal_created"))

        await viewModel.toggleGoal(createdGoal)

        let completedGoal = try #require(goalService.goals.first)
        #expect(completedGoal.status == .completed)

        var editedGoal = completedGoal
        editedGoal.title = "Finish biology chapter and quiz"
        editedGoal.detail = "Add end-of-chapter quiz questions."
        viewModel.beginEditing(completedGoal)
        try await viewModel.saveEdits(editedGoal)

        #expect(goalService.goals.first?.title == "Finish biology chapter and quiz")
        #expect(viewModel.editingGoal == nil)
        #expect(analyticsService.events.contains("goal_updated"))

        viewModel.pendingDeleteGoal = editedGoal
        await viewModel.confirmDelete()

        #expect(goalService.deletedGoalIDs == [editedGoal.id])
        #expect(goalService.goals.isEmpty)
        #expect(viewModel.pendingDeleteGoal == nil)
        #expect(analyticsService.events.contains("goal_deleted"))
    }

    @Test func goalsViewModelShowsGeneratedPlanImmediatelyWithoutClientWrite() async throws {
        let profile = testProfile(id: uniqueUserID("goals-plan-vm"))
        let goalService = TestGoalService()
        let database = TestDatabaseService()
        let analyticsService = TestAnalyticsService()
        let viewModel = GoalsViewModel(
            user: profile,
            goalService: goalService,
            databaseService: database,
            analyticsService: analyticsService
        )
        let goal = Goal(
            title: "Raise chemistry grade",
            detail: "Reach an A by finals week.",
            priority: .high,
            category: .academic,
            status: .active,
            dueDate: Date(timeIntervalSince1970: 1_779_724_800),
            sortIndex: 0,
            subGoals: [],
            checkpoints: []
        )
        goalService.generatedPlan = GoalPlanDraft(
            goalID: goal.id,
            summary: "Draft plan",
            suggestedTimelineWeeks: 6,
            checkpoints: [],
            nextActions: [
                GoalStep(title: "Review chapter notes", isComplete: false),
                GoalStep(title: "Practice exam questions", isComplete: false)
            ]
        )

        await viewModel.generatePlan(for: goal)

        let visiblePlan = try #require(viewModel.plansByGoalID[goal.id])
        #expect(visiblePlan.summary == "Draft plan")
        #expect(visiblePlan.nextActions.map(\.title) == ["Review chapter notes", "Practice exam questions"])
        #expect(viewModel.planLoadingGoalIDs.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(analyticsService.events.contains("goal_plan_requested"))

        let savedDrafts = try await database.fetchAll(GoalPlanDraft.self, from: .goalPlans, userID: profile.id)
        #expect(savedDrafts.isEmpty)
    }

    @Test func goalsViewModelAppliesGeneratedPlanWithoutDuplicatingExistingProgress() async throws {
        let profile = testProfile(id: uniqueUserID("goals-plan-apply"))
        let goalService = TestGoalService()
        let analyticsService = TestAnalyticsService()
        let viewModel = GoalsViewModel(
            user: profile,
            goalService: goalService,
            databaseService: TestDatabaseService(),
            analyticsService: analyticsService
        )
        let existingCheckpointDate = Date(timeIntervalSince1970: 1_779_724_800)
        let newCheckpointDate = Date(timeIntervalSince1970: 1_780_329_600)
        let goal = Goal(
            title: "Raise chemistry grade",
            detail: "Reach an A by finals week.",
            priority: .high,
            category: .academic,
            status: .active,
            dueDate: Date(timeIntervalSince1970: 1_781_193_600),
            sortIndex: 0,
            subGoals: [
                GoalStep(title: "Review chapter notes", isComplete: true)
            ],
            checkpoints: [
                GoalCheckpoint(title: "Meet advisor", dueDate: existingCheckpointDate)
            ]
        )
        try await goalService.createGoal(goal, for: profile.id)
        let plan = GoalPlanDraft(
            goalID: goal.id,
            summary: "Draft plan",
            suggestedTimelineWeeks: 6,
            checkpoints: [
                GoalCheckpoint(title: "Meet advisor", dueDate: existingCheckpointDate),
                GoalCheckpoint(title: "Take practice final", dueDate: newCheckpointDate)
            ],
            nextActions: [
                GoalStep(title: "Review chapter notes", isComplete: false),
                GoalStep(title: "Practice exam questions", isComplete: false)
            ]
        )

        viewModel.start()
        for _ in 0..<10 where viewModel.goals.isEmpty {
            await Task.yield()
        }
        let visibleGoalBeforeApply = try #require(viewModel.goals.first)
        #expect(visibleGoalBeforeApply.id == goal.id)

        await viewModel.applyPlan(plan, to: goal)

        let updated = try #require(goalService.goals.first)
        #expect(updated.subGoals.map(\.title) == ["Review chapter notes", "Practice exam questions"])
        #expect(updated.subGoals.first?.isComplete == true)
        #expect(updated.checkpoints.map(\.title) == ["Meet advisor", "Take practice final"])
        #expect(viewModel.isPlanApplied(plan, to: updated))
        let visibleGoalAfterApply = try #require(viewModel.goals.first)
        #expect(visibleGoalAfterApply.subGoals.map(\.title) == ["Review chapter notes", "Practice exam questions"])
        #expect(visibleGoalAfterApply.subGoals.first?.isComplete == true)
        #expect(visibleGoalAfterApply.checkpoints.map(\.title) == ["Meet advisor", "Take practice final"])
        #expect(viewModel.isPlanApplied(plan, to: visibleGoalAfterApply))
        #expect(viewModel.goalActionID == nil)
        #expect(viewModel.errorMessage == nil)
        #expect(analyticsService.events.contains("goal_plan_applied"))

        let applyEventCount = analyticsService.events.filter { $0 == "goal_plan_applied" }.count
        await viewModel.applyPlan(plan, to: visibleGoalAfterApply)
        let reapplied = try #require(goalService.goals.first)
        #expect(reapplied.subGoals.map(\.title) == ["Review chapter notes", "Practice exam questions"])
        #expect(reapplied.checkpoints.map(\.title) == ["Meet advisor", "Take practice final"])
        #expect(analyticsService.events.filter { $0 == "goal_plan_applied" }.count == applyEventCount)
    }

    @Test func goalsViewModelRejectsPlanForDifferentGoalWithoutUpdating() async throws {
        let profile = testProfile(id: uniqueUserID("goals-plan-mismatch"))
        let goalService = TestGoalService()
        let analyticsService = TestAnalyticsService()
        let viewModel = GoalsViewModel(
            user: profile,
            goalService: goalService,
            databaseService: TestDatabaseService(),
            analyticsService: analyticsService
        )
        let goal = Goal(
            title: "Raise chemistry grade",
            detail: "Reach an A by finals week.",
            priority: .high,
            category: .academic,
            status: .active,
            dueDate: Date(timeIntervalSince1970: 1_781_193_600),
            sortIndex: 0,
            subGoals: [],
            checkpoints: []
        )
        try await goalService.createGoal(goal, for: profile.id)
        let plan = GoalPlanDraft(
            goalID: "other-goal-id",
            summary: "Draft plan",
            suggestedTimelineWeeks: 6,
            checkpoints: [
                GoalCheckpoint(title: "Take practice final", dueDate: Date(timeIntervalSince1970: 1_780_329_600))
            ],
            nextActions: [
                GoalStep(title: "Practice exam questions", isComplete: false)
            ]
        )

        await viewModel.applyPlan(plan, to: goal)

        let storedGoal = try #require(goalService.goals.first)
        #expect(storedGoal.subGoals.isEmpty)
        #expect(storedGoal.checkpoints.isEmpty)
        #expect(viewModel.goalActionID == nil)
        #expect(viewModel.errorMessage?.contains("no longer matches") == true)
        #expect(!analyticsService.events.contains("goal_plan_applied"))
    }

    @Test func goalsViewModelApplyPlanKeepsGoalUnchangedWhenUpdateFails() async throws {
        let profile = testProfile(id: uniqueUserID("goals-plan-failure"))
        let goalService = TestGoalService()
        let analyticsService = TestAnalyticsService()
        let viewModel = GoalsViewModel(
            user: profile,
            goalService: goalService,
            databaseService: TestDatabaseService(),
            analyticsService: analyticsService
        )
        let goal = Goal(
            title: "Raise chemistry grade",
            detail: "Reach an A by finals week.",
            priority: .high,
            category: .academic,
            status: .active,
            dueDate: Date(timeIntervalSince1970: 1_781_193_600),
            sortIndex: 0,
            subGoals: [],
            checkpoints: []
        )
        try await goalService.createGoal(goal, for: profile.id)
        goalService.updateError = AppError.network(description: "Apply failed.")
        let plan = GoalPlanDraft(
            goalID: goal.id,
            summary: "Draft plan",
            suggestedTimelineWeeks: 6,
            checkpoints: [
                GoalCheckpoint(title: "Take practice final", dueDate: Date(timeIntervalSince1970: 1_780_329_600))
            ],
            nextActions: [
                GoalStep(title: "Practice exam questions", isComplete: false)
            ]
        )

        await viewModel.applyPlan(plan, to: goal)

        let storedGoal = try #require(goalService.goals.first)
        #expect(storedGoal.subGoals.isEmpty)
        #expect(storedGoal.checkpoints.isEmpty)
        #expect(viewModel.goalActionID == nil)
        #expect(viewModel.errorMessage == "Apply failed.")
        #expect(!analyticsService.events.contains("goal_plan_applied"))
    }

    @Test func goalsViewModelRejectsPlanWithoutApplicableItems() async throws {
        let profile = testProfile(id: uniqueUserID("goals-plan-empty"))
        let goalService = TestGoalService()
        let analyticsService = TestAnalyticsService()
        let viewModel = GoalsViewModel(
            user: profile,
            goalService: goalService,
            databaseService: TestDatabaseService(),
            analyticsService: analyticsService
        )
        let goal = Goal(
            title: "Raise chemistry grade",
            detail: "Reach an A by finals week.",
            priority: .high,
            category: .academic,
            status: .active,
            dueDate: Date(timeIntervalSince1970: 1_781_193_600),
            sortIndex: 0,
            subGoals: [],
            checkpoints: []
        )
        try await goalService.createGoal(goal, for: profile.id)
        let plan = GoalPlanDraft(
            goalID: goal.id,
            summary: "Draft plan",
            suggestedTimelineWeeks: 6,
            checkpoints: [
                GoalCheckpoint(title: "   ", dueDate: Date(timeIntervalSince1970: 1_780_329_600))
            ],
            nextActions: [
                GoalStep(title: "   ", isComplete: false)
            ]
        )

        #expect(!viewModel.hasApplicablePlanItems(plan))
        await viewModel.applyPlan(plan, to: goal)

        let storedGoal = try #require(goalService.goals.first)
        #expect(storedGoal.subGoals.isEmpty)
        #expect(storedGoal.checkpoints.isEmpty)
        #expect(viewModel.goalActionID == nil)
        #expect(viewModel.errorMessage?.contains("does not include") == true)
        #expect(!analyticsService.events.contains("goal_plan_applied"))
    }

    @Test func goalsViewModelSkipsNormalizedDuplicatePlanItems() async throws {
        let profile = testProfile(id: uniqueUserID("goals-plan-normalized"))
        let goalService = TestGoalService()
        let analyticsService = TestAnalyticsService()
        let viewModel = GoalsViewModel(
            user: profile,
            goalService: goalService,
            databaseService: TestDatabaseService(),
            analyticsService: analyticsService
        )
        let existingCheckpointDate = Date(timeIntervalSince1970: 1_779_724_800)
        let differentCheckpointDate = Date(timeIntervalSince1970: 1_780_329_600)
        let goal = Goal(
            title: "Raise chemistry grade",
            detail: "Reach an A by finals week.",
            priority: .high,
            category: .academic,
            status: .active,
            dueDate: Date(timeIntervalSince1970: 1_781_193_600),
            sortIndex: 0,
            subGoals: [
                GoalStep(title: "Review chapter notes", isComplete: true)
            ],
            checkpoints: [
                GoalCheckpoint(title: "Meet advisor", dueDate: existingCheckpointDate)
            ]
        )
        try await goalService.createGoal(goal, for: profile.id)
        let plan = GoalPlanDraft(
            goalID: goal.id,
            summary: "Draft plan",
            suggestedTimelineWeeks: 6,
            checkpoints: [
                GoalCheckpoint(title: " meet advisor ", dueDate: existingCheckpointDate.addingTimeInterval(60 * 60)),
                GoalCheckpoint(title: "Meet advisor", dueDate: differentCheckpointDate)
            ],
            nextActions: [
                GoalStep(title: " review chapter notes ", isComplete: false),
                GoalStep(title: "Practice exam questions", isComplete: false)
            ]
        )

        await viewModel.applyPlan(plan, to: goal)

        let updated = try #require(goalService.goals.first)
        #expect(updated.subGoals.map(\.title) == ["Review chapter notes", "Practice exam questions"])
        #expect(updated.subGoals.first?.isComplete == true)
        #expect(updated.checkpoints.map(\.title) == ["Meet advisor", "Meet advisor"])
        #expect(updated.checkpoints.map(\.dueDate) == [existingCheckpointDate, differentCheckpointDate])
        #expect(analyticsService.events.contains("goal_plan_applied"))
    }

    @Test func habitsCanBeCreatedPersistedAndUpdatedOutsideCheckInFlow() async throws {
        let userID = uniqueUserID("habits")
        let database = TestDatabaseService()
        var habit = Habit(
            title: "Read before class",
            streak: 0,
            targetCountPerWeek: 4,
            isCompletedToday: false
        )

        try await database.save(habit, in: .habits, id: habit.id, userID: userID)
        habit.streak = 1
        habit.isCompletedToday = true
        try await database.save(habit, in: .habits, id: habit.id, userID: userID)

        let relaunchedDatabase = database
        let persisted = try await relaunchedDatabase.fetch(Habit.self, from: .habits, id: habit.id, userID: userID)
        #expect(persisted.title == "Read before class")
        #expect(persisted.streak == 1)
        #expect(persisted.targetCountPerWeek == 4)
        #expect(persisted.isCompletedToday)
    }

    @Test func localSubscriptionStorePublishesRestoreAndPurchaseStateChanges() async {
        let userID = uniqueUserID("subscription")
        let store = LocalSubscriptionStore()
        var iterator = await store.observe(for: userID).makeAsyncIterator()

        let initialState = await iterator.next()
        #expect(initialState?.entitlement == .inactive)
        #expect(initialState?.activePlan == SubscriptionPlan.none)

        let restoredState = SubscriptionState(
            entitlement: .active,
            activePlan: .annual,
            trialEligible: false,
            lastSyncedAt: Date(timeIntervalSince1970: 1_776_000_000)
        )
        await store.set(restoredState, for: userID)

        let observedState = await iterator.next()
        #expect(observedState?.entitlement == .active)
        #expect(observedState?.activePlan == .annual)
        #expect(observedState?.trialEligible == false)
    }

    @Test func linkedSubscriptionIdentityStoreRequiresExplicitSuccessfulMark() async {
        let store = LinkedSubscriptionIdentityStore()
        let userID = uniqueUserID("subscription-identity")

        let initiallyLinked = await store.isLinked(to: userID)
        let initiallyKnown = await store.hasKnownUser()
        let initialLinkedUserID = await store.currentLinkedUserID()
        #expect(!initiallyLinked)
        #expect(initiallyKnown == false)
        #expect(initialLinkedUserID == nil)

        await store.markPending(userID)

        let pendingKnown = await store.hasKnownUser()
        let pendingLinked = await store.isLinked(to: userID)
        let pendingLinkedUserID = await store.currentLinkedUserID()
        #expect(pendingKnown)
        #expect(pendingLinked == false)
        #expect(pendingLinkedUserID == nil)

        await store.markLinked(userID)

        let linked = await store.isLinked(to: userID)
        let linkedUserID = await store.currentLinkedUserID()
        #expect(linked)
        #expect(linkedUserID == userID)
        let otherUserLinked = await store.isLinked(to: "\(userID)-other")
        #expect(!otherUserLinked)

        await store.markUnlinked()

        let linkedAfterUnlink = await store.isLinked(to: userID)
        let knownAfterUnlink = await store.hasKnownUser()
        let linkedUserIDAfterUnlink = await store.currentLinkedUserID()
        #expect(!linkedAfterUnlink)
        #expect(knownAfterUnlink == false)
        #expect(linkedUserIDAfterUnlink == nil)
    }

    @Test func subscriptionSyncResponseMapsBackendBetaSnapshot() throws {
        let data = """
        {
          "success": true,
          "subscription": {
            "entitlement": "active",
            "activePlan": "none",
            "trialEligible": false,
            "entitlementIDs": ["beta_pro"],
            "source": "beta_pro_user_ids",
            "lastSyncedAt": "2026-04-26T12:00:00.000Z"
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder.appDecoder().decode(SubscriptionSyncResponsePayload.self, from: data)
        let state = response.state

        #expect(response.success)
        #expect(state.entitlement == .active)
        #expect(state.activePlan == .none)
        #expect(state.trialEligible == false)
        #expect(state.lastSyncedAt == Date(timeIntervalSince1970: 1_777_204_800))
    }

    @Test func premiumFeatureGateMapsLockedStateToFeaturePaywallTriggers() {
        let locked = SubscriptionState.locked
        let unlocked = SubscriptionState.unlocked

        #expect(locked.paywallTrigger(for: .assistant, honoringDebugBypass: false) == .premiumAssistant)
        #expect(locked.paywallTrigger(for: .goalPlan, honoringDebugBypass: false) == .premiumGoalPlan)
        #expect(locked.paywallTrigger(for: .syllabusImport, honoringDebugBypass: false) == .premiumSyllabusImport)
        #expect(unlocked.paywallTrigger(for: .assistant, honoringDebugBypass: false) == nil)
        #expect(unlocked.paywallTrigger(for: .goalPlan, honoringDebugBypass: false) == nil)
        #expect(unlocked.paywallTrigger(for: .syllabusImport, honoringDebugBypass: false) == nil)
    }

    @Test func subscriptionStateResolverRequiresBackendConfirmationForNewActiveAccess() {
        let rawRevenueCatActive = SubscriptionState(
            entitlement: .active,
            activePlan: .annual,
            trialEligible: false,
            lastSyncedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
        let backendInactive = SubscriptionState(
            entitlement: .inactive,
            activePlan: .none,
            trialEligible: true,
            lastSyncedAt: Date(timeIntervalSince1970: 1_777_000_100)
        )
        let backendActive = SubscriptionState(
            entitlement: .active,
            activePlan: .annual,
            trialEligible: false,
            lastSyncedAt: Date(timeIntervalSince1970: 1_777_000_200)
        )
        let previouslyConfirmedActive = SubscriptionState(
            entitlement: .active,
            activePlan: .monthly,
            trialEligible: false,
            lastSyncedAt: Date(timeIntervalSince1970: 1_776_000_000)
        )

        let backendRejected = SubscriptionStateResolver.resolveBackendState(
            backendState: backendInactive,
            localState: rawRevenueCatActive,
            previousState: .locked
        )
        let backendUnavailableForLockedUser = SubscriptionStateResolver.resolveBackendState(
            backendState: nil,
            localState: rawRevenueCatActive,
            previousState: .locked
        )
        let backendUnavailableForPreviouslyActiveUser = SubscriptionStateResolver.resolveBackendState(
            backendState: nil,
            localState: rawRevenueCatActive,
            previousState: previouslyConfirmedActive
        )
        let backendConfirmedActive = SubscriptionStateResolver.resolveBackendState(
            backendState: backendActive,
            localState: .locked,
            previousState: .locked
        )

        #expect(backendRejected.entitlement == .inactive)
        #expect(backendUnavailableForLockedUser.entitlement == .inactive)
        #expect(backendUnavailableForPreviouslyActiveUser.entitlement == .active)
        #expect(backendUnavailableForPreviouslyActiveUser.activePlan == .monthly)
        #expect(backendConfirmedActive.entitlement == .active)
        #expect(backendConfirmedActive.activePlan == .annual)
        #expect(SubscriptionStateResolver.pendingPaidAccessState(previousState: .locked).entitlement == .inactive)
        #expect(SubscriptionStateResolver.pendingPaidAccessState(previousState: previouslyConfirmedActive).entitlement == .active)
        #expect(SubscriptionStateResolver.pendingPaidAccessState(previousState: previouslyConfirmedActive).activePlan == .monthly)
    }

    @Test func subscriptionServiceRefreshUsesBackendBetaStateWhenRevenueCatIsUnavailable() async throws {
        let userID = uniqueUserID("subscription-beta")
        let backendService = TestBackendFunctionService()
        backendService.subscriptionState = SubscriptionState(
            entitlement: .active,
            activePlan: .none,
            trialEligible: false,
            lastSyncedAt: Date(timeIntervalSince1970: 1_777_204_800)
        )
        let service = SubscriptionService(paidAccessConfirmationRetryDelaysNanoseconds: [])
        service.backendFunctionService = backendService

        let state = try await service.refreshStatus(for: userID)
        var iterator = service.observeSubscriptionState(for: userID).makeAsyncIterator()
        let observed = await iterator.next()

        #expect(backendService.syncedSubscriptionUserIDs == [userID])
        #expect(state.entitlement == .active)
        #expect(state.activePlan == .none)
        #expect(state.trialEligible == false)
        #expect(observed?.entitlement == .active)
    }

    @Test func subscriptionServiceConfirmPaidAccessRequiresBackendActiveState() async throws {
        let userID = uniqueUserID("subscription-confirm")
        let backendService = TestBackendFunctionService()
        backendService.subscriptionState = SubscriptionState(
            entitlement: .active,
            activePlan: .annual,
            trialEligible: false,
            lastSyncedAt: Date(timeIntervalSince1970: 1_776_000_000)
        )
        let service = SubscriptionService(paidAccessConfirmationRetryDelaysNanoseconds: [])
        service.backendFunctionService = backendService

        let state = try await service.confirmPaidAccess(for: userID)

        #expect(backendService.syncedSubscriptionUserIDs == [userID])
        #expect(state.entitlement == .active)
        #expect(state.activePlan == .annual)
    }

    @Test func subscriptionServiceConfirmPaidAccessRetriesUntilBackendBecomesActive() async throws {
        let userID = uniqueUserID("subscription-confirm-retry")
        let backendService = TestBackendFunctionService()
        backendService.subscriptionStateResponses = [
            .locked,
            SubscriptionState(
                entitlement: .active,
                activePlan: .monthly,
                trialEligible: false,
                lastSyncedAt: Date(timeIntervalSince1970: 1_776_000_500)
            )
        ]
        let service = SubscriptionService(paidAccessConfirmationRetryDelaysNanoseconds: [0])
        service.backendFunctionService = backendService

        let state = try await service.confirmPaidAccess(for: userID)

        #expect(backendService.syncedSubscriptionUserIDs == [userID, userID])
        #expect(state.entitlement == .active)
        #expect(state.activePlan == .monthly)
    }

    @Test func subscriptionServiceConfirmPaidAccessRejectsInactiveBackendState() async {
        let userID = uniqueUserID("subscription-confirm-inactive")
        let backendService = TestBackendFunctionService()
        backendService.subscriptionState = .locked
        let service = SubscriptionService(paidAccessConfirmationRetryDelaysNanoseconds: [])
        service.backendFunctionService = backendService

        await #expect(throws: AppError.network(description: "Your purchase was processed, but Pro access has not been confirmed on the server yet. Try restoring purchases in a moment.")) {
            _ = try await service.confirmPaidAccess(for: userID)
        }
        #expect(backendService.syncedSubscriptionUserIDs == [userID])
    }

    @Test func appSessionRefreshesSubscriptionAfterExistingUserContextLoads() async throws {
        let profile = testProfile(id: uniqueUserID("session-subscription"))
        var onboarding = OnboardingState()
        onboarding.didCompleteProfile = true
        onboarding.completedAt = Date(timeIntervalSince1970: 1_777_000_000)

        let userService = TestUserService(profile: profile)
        userService.onboardingState = onboarding
        let subscriptionService = TestSubscriptionService()
        subscriptionService.state = SubscriptionState.unlocked
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: profile.id, profile: profile),
            userService: userService,
            subscriptionService: subscriptionService
        )

        let viewModel = AppSessionViewModel(container: container)
        for _ in 0..<20 where subscriptionService.refreshedUserIDs.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(subscriptionService.linkedUserIDs == [profile.id])
        #expect(subscriptionService.refreshedUserIDs == [profile.id])
        #expect(viewModel.onboardingState.isComplete)
        #expect(viewModel.subscriptionState.entitlement == .active)
    }

    @Test func appSessionSyncsSavedReminderRulesAfterUserContextLoads() async throws {
        let profile = testProfile(id: uniqueUserID("session-reminders"))
        var onboarding = OnboardingState()
        onboarding.didCompleteProfile = true
        onboarding.completedAt = Date(timeIntervalSince1970: 1_777_000_000)
        onboarding.reminderRules = [
            ReminderRule(title: "Morning check-in", hour: 8, minute: 0, target: CheckInMoment.morning.rawValue),
            ReminderRule(title: "Disabled night check-in", hour: 20, minute: 30, target: CheckInMoment.night.rawValue, enabled: false)
        ]
        let userService = TestUserService(profile: profile)
        userService.onboardingState = onboarding
        let notificationService = TestNotificationService()
        notificationService.state = .authorized
        let analyticsService = TestAnalyticsService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: profile.id, profile: profile),
            userService: userService,
            subscriptionService: TestSubscriptionService(),
            analyticsService: analyticsService,
            notificationService: notificationService
        )

        let viewModel = AppSessionViewModel(container: container)
        for _ in 0..<20 where notificationService.syncedRuleSets.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.onboardingState.isComplete)
        #expect(notificationService.syncedRuleSets.first?.map(\.title) == ["Morning check-in", "Disabled night check-in"])
        #expect(notificationService.scheduledRules.map(\.title) == ["Morning check-in"])
        #expect(analyticsService.events.contains("notification_reminders_synced"))
    }

    @Test func appSessionDoesNotScheduleReminderRulesWhenNotificationsAreUnavailable() async throws {
        let profile = testProfile(id: uniqueUserID("session-reminders-denied"))
        var onboarding = OnboardingState()
        onboarding.didCompleteProfile = true
        onboarding.completedAt = Date(timeIntervalSince1970: 1_777_000_000)
        onboarding.reminderRules = ReminderRule.defaultRules
        let userService = TestUserService(profile: profile)
        userService.onboardingState = onboarding
        let notificationService = TestNotificationService()
        notificationService.state = .denied
        let analyticsService = TestAnalyticsService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: profile.id, profile: profile),
            userService: userService,
            subscriptionService: TestSubscriptionService(),
            analyticsService: analyticsService,
            notificationService: notificationService
        )

        _ = AppSessionViewModel(container: container)
        for _ in 0..<20 where notificationService.syncedRuleSets.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(notificationService.syncedRuleSets.first?.count == ReminderRule.defaultRules.count)
        #expect(notificationService.scheduledRules.isEmpty)
        #expect(!analyticsService.events.contains("notification_reminders_synced"))
    }

    @Test func appSessionDoesNotSyncReminderRulesBeforeOnboardingCompletes() async throws {
        let profile = testProfile(id: uniqueUserID("session-reminders-incomplete"))
        let userService = TestUserService(profile: profile)
        userService.onboardingState = OnboardingState()
        let notificationService = TestNotificationService()
        notificationService.state = .authorized
        let subscriptionService = TestSubscriptionService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: profile.id, profile: profile),
            userService: userService,
            subscriptionService: subscriptionService,
            notificationService: notificationService
        )

        let viewModel = AppSessionViewModel(container: container)
        for _ in 0..<20 where subscriptionService.refreshedUserIDs.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!viewModel.onboardingState.isComplete)
        #expect(notificationService.syncedRuleSets.isEmpty)
        #expect(notificationService.scheduledRules.isEmpty)
    }

    @Test func appSessionCancelsLocalAccountNotificationsWhenAuthStateIsSignedOut() async throws {
        let profile = testProfile(id: uniqueUserID("session-signed-out-reminders"))
        let notificationService = TestNotificationService()
        try await notificationService.schedule(rule: ReminderRule.defaultRules[0])
        notificationService.queuedSessionTimerCount = 1
        let analyticsService = TestAnalyticsService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: nil, profile: nil),
            userService: TestUserService(profile: profile),
            subscriptionService: TestSubscriptionService(),
            analyticsService: analyticsService,
            notificationService: notificationService
        )

        _ = AppSessionViewModel(container: container)
        for _ in 0..<20 where notificationService.cancelledLocalAccountNotificationCounts.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(notificationService.cancelledLocalAccountNotificationCounts == [2])
        #expect(notificationService.scheduledRules.isEmpty)
        #expect(notificationService.queuedSessionTimerCount == 0)
        #expect(analyticsService.events.contains("notification_local_account_notifications_cancelled"))
    }

    @Test func appSessionClearsRemoteTokenWhenSignedInUserLeavesAuthState() async throws {
        let profile = testProfile(id: uniqueUserID("session-remote-token"))
        let authService = TestAuthService(currentUserID: profile.id, profile: profile)
        authService.authStates = [profile, nil]
        let notificationService = TestNotificationService()
        let analyticsService = TestAnalyticsService()
        let container = sessionContainer(
            authService: authService,
            userService: TestUserService(profile: profile),
            subscriptionService: TestSubscriptionService(),
            analyticsService: analyticsService,
            notificationService: notificationService
        )

        _ = AppSessionViewModel(container: container)
        for _ in 0..<50 where notificationService.clearedRemoteTokenUserIDs.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(notificationService.clearedRemoteTokenUserIDs == [profile.id])
        #expect(analyticsService.events.contains("notification_remote_token_cleared"))
    }

    @Test func notificationServiceClearsRemoteTokenThroughDedicatedUserServicePath() async throws {
        var profile = testProfile(id: uniqueUserID("notification-clear-token"))
        profile.pushToken = "fcm-token"
        let userService = TestUserService(profile: profile)
        let notificationService = NotificationService()
        notificationService.userService = userService
        notificationService.updateRemoteToken("fcm-token")

        let cleared = await notificationService.clearRemoteToken(for: profile.id)

        let clearedToken = try #require(userService.clearedPushTokens.first)
        #expect(cleared)
        #expect(userService.clearedPushTokens.count == 1)
        #expect(clearedToken.userID == profile.id)
        #expect(clearedToken.token == "fcm-token")
        #expect(userService.savedProfiles.isEmpty)
        #expect(userService.profile.pushToken == nil)
    }

    @Test func notificationServicePersistsRemoteTokenThroughDedicatedUserServicePath() async throws {
        let profile = testProfile(id: uniqueUserID("notification-update-token"))
        let userService = TestUserService(profile: profile)
        let authService = TestAuthService(currentUserID: profile.id, profile: profile)
        let notificationService = NotificationService()
        notificationService.userService = userService
        notificationService.authService = authService

        notificationService.updateRemoteToken("new-fcm-token")
        for _ in 0..<50 where userService.updatedPushTokens.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let updatedToken = try #require(userService.updatedPushTokens.first)
        #expect(userService.updatedPushTokens.count == 1)
        #expect(updatedToken.userID == profile.id)
        #expect(updatedToken.token == "new-fcm-token")
        #expect(userService.savedProfiles.isEmpty)
        #expect(userService.profile.pushToken == "new-fcm-token")
    }

    @Test func appSessionShowsRetryableUserContextErrorInsteadOfCompletingOnboardingOnLoadFailure() async throws {
        let profile = testProfile(id: uniqueUserID("session-context-failure"))
        let userService = TestUserService(profile: profile)
        userService.fetchOnboardingError = AppError.network(description: "Temporary backend outage.")
        let analyticsService = TestAnalyticsService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: profile.id, profile: profile),
            userService: userService,
            subscriptionService: TestSubscriptionService(),
            analyticsService: analyticsService
        )

        let viewModel = AppSessionViewModel(container: container)
        for _ in 0..<20 where viewModel.userContextLoadError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.currentUser?.id == profile.id)
        #expect(!viewModel.onboardingState.isComplete)
        #expect(viewModel.userContextLoadError == "Temporary backend outage.")
        #expect(!viewModel.isLoadingUserContext)
        #expect(analyticsService.errors.contains("load_user_context"))
    }

    @Test func appSessionRefreshesSelectedCalendarImportsFromLatestProfile() async throws {
        var initialProfile = testProfile(id: uniqueUserID("session-calendar-refresh"))
        initialProfile.selectedCalendarIDs = []
        var savedProfile = initialProfile
        savedProfile.selectedCalendarIDs = ["school", "personal"]
        let userService = TestUserService(profile: savedProfile)
        let calendarSyncService = TestCalendarSyncService()
        calendarSyncService.importedBlocks = [
            PlannerBlock(
                id: "apple-school-class",
                title: "Biology lecture",
                detail: "",
                startDate: Date(timeIntervalSince1970: 1_776_000_000),
                endDate: Date(timeIntervalSince1970: 1_776_003_600),
                type: .classEvent,
                source: .appleCalendar,
                linkedGoalID: nil,
                linkedAssignmentID: nil
            )
        ]
        let analyticsService = TestAnalyticsService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: initialProfile.id, profile: initialProfile),
            userService: userService,
            subscriptionService: TestSubscriptionService(),
            analyticsService: analyticsService,
            calendarSyncService: calendarSyncService
        )
        let viewModel = AppSessionViewModel(container: container)
        for _ in 0..<20 where viewModel.currentUser == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await viewModel.refreshCalendarImports(trigger: "test")

        #expect(calendarSyncService.importedCalendarIDs == [["school", "personal"]])
        #expect(viewModel.currentUser?.selectedCalendarIDs == ["school", "personal"])
        #expect(viewModel.calendarRefreshError == nil)
        #expect(analyticsService.events.contains("calendar_sync_auto_refreshed"))
    }

    @Test func appSessionSkipsCalendarRefreshWhenNoCalendarsAreSelected() async {
        let profile = testProfile(id: uniqueUserID("session-calendar-refresh-empty"))
        let calendarSyncService = TestCalendarSyncService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: profile.id, profile: profile),
            userService: TestUserService(profile: profile),
            subscriptionService: TestSubscriptionService(),
            calendarSyncService: calendarSyncService
        )
        let viewModel = AppSessionViewModel(container: container)
        for _ in 0..<20 where viewModel.currentUser == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        await viewModel.refreshCalendarImports(trigger: "test")

        #expect(calendarSyncService.importedCalendarIDs.isEmpty)
        #expect(viewModel.calendarRefreshError == nil)
    }

    @Test func appSessionReportsCalendarRefreshFailureWithoutClearingSelection() async {
        var profile = testProfile(id: uniqueUserID("session-calendar-refresh-failure"))
        profile.selectedCalendarIDs = ["school"]
        let calendarSyncService = TestCalendarSyncService()
        calendarSyncService.importError = AppError.permissionDenied("calendar access")
        let analyticsService = TestAnalyticsService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: profile.id, profile: profile),
            userService: TestUserService(profile: profile),
            subscriptionService: TestSubscriptionService(),
            analyticsService: analyticsService,
            calendarSyncService: calendarSyncService
        )
        let viewModel = AppSessionViewModel(container: container)
        for _ in 0..<20 where viewModel.currentUser == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        await viewModel.refreshCalendarImports(trigger: "test")

        #expect(calendarSyncService.importedCalendarIDs.isEmpty)
        #expect(viewModel.currentUser?.selectedCalendarIDs == ["school"])
        #expect(viewModel.calendarRefreshError == "Permission for calendar access was denied.")
        #expect(analyticsService.errors.contains("calendar_sync_auto_refresh"))
    }

    @Test func notificationServiceRecognizesCurrentMarkedAndLegacyReminderRequests() {
        let currentRuleIDs: Set<String> = ["morning-rule"]

        #expect(NotificationService.shouldRemovePendingReminderRequest(
            identifier: "morning-rule",
            userInfo: [:],
            body: "Different body",
            currentRuleIDs: currentRuleIDs
        ))
        #expect(NotificationService.shouldRemovePendingReminderRequest(
            identifier: "old-rule",
            userInfo: ["aicalendar_notification_type": "check_in_reminder"],
            body: "Different body",
            currentRuleIDs: currentRuleIDs
        ))
        #expect(NotificationService.shouldRemovePendingReminderRequest(
            identifier: "old-unmarked-rule",
            userInfo: [:],
            body: "Take a minute to keep your plan aligned.",
            currentRuleIDs: currentRuleIDs
        ))
        #expect(!NotificationService.shouldRemovePendingReminderRequest(
            identifier: "session_timer_abc",
            userInfo: [:],
            body: "Session complete",
            currentRuleIDs: currentRuleIDs
        ))
    }

    @Test func notificationServiceRecognizesSessionTimersForAccountExitCleanup() {
        #expect(NotificationService.shouldRemovePendingAccountNotification(
            identifier: "session_timer_abc",
            userInfo: [:],
            body: "Session complete",
            currentRuleIDs: []
        ))
        #expect(NotificationService.shouldRemovePendingAccountNotification(
            identifier: "old-check-in-rule",
            userInfo: [:],
            body: "Take a minute to keep your plan aligned.",
            currentRuleIDs: []
        ))
        #expect(!NotificationService.shouldRemovePendingAccountNotification(
            identifier: "third_party_notification",
            userInfo: [:],
            body: "Different body",
            currentRuleIDs: []
        ))
    }

    @Test func settingsViewModelPreparesExportDocumentFromBackendPayload() async throws {
        let profile = testProfile(id: uniqueUserID("settings-export"))
        let backendService = TestBackendFunctionService()
        backendService.exportResponse = ExportUserDataResponsePayload(
            userID: profile.id,
            requestedAt: Date(timeIntervalSince1970: 1_777_000_000),
            profile: .object(["email": .string(profile.email)]),
            collections: [
                "goals": [
                    .object(["title": .string("Prepare for biology midterm")])
                ]
            ]
        )
        let viewModel = SettingsViewModel(
            user: profile,
            authService: TestAuthService(currentUserID: profile.id),
            userService: TestUserService(profile: profile),
            calendarSyncService: TestCalendarSyncService(),
            notificationService: TestNotificationService(),
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: backendService,
            databaseService: TestDatabaseService(),
            analyticsService: TestAnalyticsService()
        )

        await viewModel.exportData()

        let exportDocument = try #require(viewModel.exportDocument)
        let json = try #require(String(data: exportDocument.data, encoding: .utf8))
        #expect(backendService.exportedUserIDs == [profile.id])
        #expect(json.contains("Prepare for biology midterm"))
        #expect(viewModel.showExportFileExporter)
        #expect(viewModel.exportFilename.hasPrefix("ai-efficiency-export-"))
        #expect(viewModel.statusMessage == "Choose where to save your data export.")
    }

    @Test func settingsViewModelCancelsLocalAccountNotificationsAfterSignOut() async throws {
        let profile = testProfile(id: uniqueUserID("settings-sign-out-reminders"))
        let authService = TestAuthService(currentUserID: profile.id)
        let notificationService = TestNotificationService()
        try await notificationService.schedule(rule: ReminderRule.defaultRules[0])
        notificationService.queuedSessionTimerCount = 1
        let analyticsService = TestAnalyticsService()
        let viewModel = SettingsViewModel(
            user: profile,
            authService: authService,
            userService: TestUserService(profile: profile),
            calendarSyncService: TestCalendarSyncService(),
            notificationService: notificationService,
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: TestBackendFunctionService(),
            databaseService: TestDatabaseService(),
            analyticsService: analyticsService
        )

        await viewModel.signOut()

        #expect(authService.didSignOut)
        #expect(notificationService.clearedRemoteTokenUserIDs == [profile.id])
        #expect(notificationService.cancelledLocalAccountNotificationCounts == [2])
        #expect(notificationService.scheduledRules.isEmpty)
        #expect(notificationService.queuedSessionTimerCount == 0)
        #expect(analyticsService.events.contains("notification_remote_token_cleared"))
        #expect(analyticsService.events.contains("notification_local_account_notifications_cancelled"))
    }

    @Test func settingsViewModelDeletesAccountThroughBackendThenSignsOut() async {
        let profile = testProfile(id: uniqueUserID("settings-delete"))
        let authService = TestAuthService(currentUserID: profile.id)
        let backendService = TestBackendFunctionService()
        let notificationService = TestNotificationService()
        try? await notificationService.schedule(rule: ReminderRule.defaultRules[0])
        notificationService.queuedSessionTimerCount = 1
        let analyticsService = TestAnalyticsService()
        let databaseService = TestDatabaseService()
        let viewModel = SettingsViewModel(
            user: profile,
            authService: authService,
            userService: TestUserService(profile: profile),
            calendarSyncService: TestCalendarSyncService(),
            notificationService: notificationService,
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: backendService,
            databaseService: databaseService,
            analyticsService: analyticsService
        )

        await viewModel.deleteAccount()

        #expect(backendService.deletedUserIDs == [profile.id])
        #expect(databaseService.deletedLocalUserIDs == [profile.id])
        #expect(authService.didSignOut)
        #expect(notificationService.cancelledLocalAccountNotificationCounts == [2])
        #expect(notificationService.scheduledRules.isEmpty)
        #expect(notificationService.queuedSessionTimerCount == 0)
        #expect(analyticsService.events.contains("notification_local_account_notifications_cancelled"))
        #expect(!viewModel.isDeletingAccount)
        #expect(viewModel.statusMessage.isEmpty)
    }

    @Test func settingsViewModelRestorePurchasesUsesSubscriptionState() async {
        let profile = testProfile(id: uniqueUserID("settings-restore"))
        let subscriptionService = TestSubscriptionService()
        subscriptionService.state = SubscriptionState.unlocked
        let viewModel = SettingsViewModel(
            user: profile,
            authService: TestAuthService(currentUserID: profile.id),
            userService: TestUserService(profile: profile),
            calendarSyncService: TestCalendarSyncService(),
            notificationService: TestNotificationService(),
            subscriptionService: subscriptionService,
            backendFunctionService: TestBackendFunctionService(),
            databaseService: TestDatabaseService(),
            analyticsService: TestAnalyticsService()
        )

        await viewModel.restorePurchases()

        #expect(subscriptionService.restoredUserIDs == [profile.id])
        #expect(viewModel.statusMessage == "Purchases restored.")
        #expect(!viewModel.isRestoringPurchases)
    }

    @Test func settingsViewModelSchedulesEnabledRemindersAfterNotificationAuthorization() async {
        let profile = testProfile(id: uniqueUserID("settings-reminders"))
        let userService = TestUserService(profile: profile)
        userService.onboardingState.reminderRules = [
            ReminderRule(title: "Morning check-in", hour: 8, minute: 0, target: CheckInMoment.morning.rawValue),
            ReminderRule(title: "Disabled night check-in", hour: 20, minute: 30, target: CheckInMoment.night.rawValue, enabled: false)
        ]
        let notificationService = TestNotificationService()
        notificationService.authorizationResult = .authorized
        let analyticsService = TestAnalyticsService()
        let viewModel = SettingsViewModel(
            user: profile,
            authService: TestAuthService(currentUserID: profile.id),
            userService: userService,
            calendarSyncService: TestCalendarSyncService(),
            notificationService: notificationService,
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: TestBackendFunctionService(),
            databaseService: TestDatabaseService(),
            analyticsService: analyticsService
        )

        await viewModel.requestNotifications()

        #expect(viewModel.notificationState == .authorized)
        #expect(notificationService.scheduledRules.map(\.title) == ["Morning check-in"])
        #expect(viewModel.statusMessage == "Notifications are authorized. 1 reminder scheduled.")
        #expect(analyticsService.events.contains("notification_reminders_scheduled"))
        #expect(!viewModel.isRequestingNotifications)
    }

    @Test func settingsViewModelDoesNotScheduleRemindersWhenNotificationsAreDenied() async {
        let profile = testProfile(id: uniqueUserID("settings-reminders-denied"))
        let notificationService = TestNotificationService()
        notificationService.authorizationResult = .denied
        let analyticsService = TestAnalyticsService()
        let viewModel = SettingsViewModel(
            user: profile,
            authService: TestAuthService(currentUserID: profile.id),
            userService: TestUserService(profile: profile),
            calendarSyncService: TestCalendarSyncService(),
            notificationService: notificationService,
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: TestBackendFunctionService(),
            databaseService: TestDatabaseService(),
            analyticsService: analyticsService
        )

        await viewModel.requestNotifications()

        #expect(viewModel.notificationState == .denied)
        #expect(notificationService.scheduledRules.isEmpty)
        #expect(viewModel.statusMessage == "Notifications are denied.")
        #expect(analyticsService.events.contains("notification_permission_denied"))
    }

    @Test func settingsViewModelReportsCalendarPermissionFailureDuringLoad() async {
        let profile = testProfile(id: uniqueUserID("settings-calendar-load-denied"))
        let calendarSyncService = TestCalendarSyncService()
        calendarSyncService.availableCalendarsError = AppError.permissionDenied("calendar access")
        let viewModel = SettingsViewModel(
            user: profile,
            authService: TestAuthService(currentUserID: profile.id),
            userService: TestUserService(profile: profile),
            calendarSyncService: calendarSyncService,
            notificationService: TestNotificationService(),
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: TestBackendFunctionService(),
            databaseService: TestDatabaseService(),
            analyticsService: TestAnalyticsService()
        )

        await viewModel.load()

        #expect(viewModel.availableCalendars.isEmpty)
        #expect(viewModel.statusMessage == "Permission for calendar access was denied.")
    }

    @Test func settingsViewModelDisconnectsCalendarsAndRemovesImportedBlocks() async {
        var profile = testProfile(id: uniqueUserID("settings-calendar-disconnect"))
        profile.selectedCalendarIDs = ["school"]
        let calendarSyncService = TestCalendarSyncService()
        let userService = TestUserService(profile: profile)
        let analyticsService = TestAnalyticsService()
        let viewModel = SettingsViewModel(
            user: profile,
            authService: TestAuthService(currentUserID: profile.id),
            userService: userService,
            calendarSyncService: calendarSyncService,
            notificationService: TestNotificationService(),
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: TestBackendFunctionService(),
            databaseService: TestDatabaseService(),
            analyticsService: analyticsService
        )
        viewModel.selectedCalendarIDs = []

        await viewModel.syncCalendars()

        #expect(userService.savedProfiles.last?.selectedCalendarIDs == [])
        #expect(calendarSyncService.disconnectedUserIDs == [profile.id])
        #expect(calendarSyncService.importedCalendarIDs.isEmpty)
        #expect(viewModel.statusMessage == "Apple Calendar disconnected and imported blocks were removed.")
        #expect(analyticsService.events.contains("calendar_sync_disconnected"))
    }

    @Test func settingsViewModelKeepsCalendarSelectionWhenDisconnectCleanupFails() async {
        var profile = testProfile(id: uniqueUserID("settings-calendar-disconnect-failure"))
        profile.selectedCalendarIDs = ["school"]
        let calendarSyncService = TestCalendarSyncService()
        calendarSyncService.disconnectError = AppError.network(description: "Cleanup failed.")
        let userService = TestUserService(profile: profile)
        let viewModel = SettingsViewModel(
            user: profile,
            authService: TestAuthService(currentUserID: profile.id),
            userService: userService,
            calendarSyncService: calendarSyncService,
            notificationService: TestNotificationService(),
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: TestBackendFunctionService(),
            databaseService: TestDatabaseService(),
            analyticsService: TestAnalyticsService()
        )
        viewModel.selectedCalendarIDs = []

        await viewModel.syncCalendars()

        #expect(userService.savedProfiles.map(\.selectedCalendarIDs) == [[], ["school"]])
        #expect(viewModel.profile.selectedCalendarIDs == ["school"])
        #expect(viewModel.selectedCalendarIDs == ["school"])
        #expect(calendarSyncService.importedCalendarIDs == [["school"]])
        #expect(viewModel.statusMessage == "Cleanup failed.")
    }

    @Test func settingsViewModelDoesNotDisconnectCalendarsWhenSelectionSaveFails() async {
        var profile = testProfile(id: uniqueUserID("settings-calendar-disconnect-save-failure"))
        profile.selectedCalendarIDs = ["school"]
        let calendarSyncService = TestCalendarSyncService()
        let userService = TestUserService(profile: profile)
        userService.saveProfileError = AppError.network(description: "Profile save failed.")
        let viewModel = SettingsViewModel(
            user: profile,
            authService: TestAuthService(currentUserID: profile.id),
            userService: userService,
            calendarSyncService: calendarSyncService,
            notificationService: TestNotificationService(),
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: TestBackendFunctionService(),
            databaseService: TestDatabaseService(),
            analyticsService: TestAnalyticsService()
        )
        viewModel.selectedCalendarIDs = []

        await viewModel.syncCalendars()

        #expect(calendarSyncService.disconnectedUserIDs.isEmpty)
        #expect(calendarSyncService.importedCalendarIDs.isEmpty)
        #expect(userService.savedProfiles.isEmpty)
        #expect(viewModel.profile.selectedCalendarIDs == ["school"])
        #expect(viewModel.selectedCalendarIDs == ["school"])
        #expect(viewModel.statusMessage == "Profile save failed.")
    }

    @Test func settingsViewModelDoesNotPersistCalendarSelectionWhenImportFails() async {
        var profile = testProfile(id: uniqueUserID("settings-calendar-import-failure"))
        profile.selectedCalendarIDs = ["school"]
        let calendarSyncService = TestCalendarSyncService()
        calendarSyncService.importError = AppError.permissionDenied("calendar access")
        let userService = TestUserService(profile: profile)
        let viewModel = SettingsViewModel(
            user: profile,
            authService: TestAuthService(currentUserID: profile.id),
            userService: userService,
            calendarSyncService: calendarSyncService,
            notificationService: TestNotificationService(),
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: TestBackendFunctionService(),
            databaseService: TestDatabaseService(),
            analyticsService: TestAnalyticsService()
        )
        viewModel.selectedCalendarIDs = ["personal"]

        await viewModel.syncCalendars()

        #expect(calendarSyncService.importedCalendarIDs.isEmpty)
        #expect(userService.savedProfiles.map(\.selectedCalendarIDs) == [["personal"], ["school"]])
        #expect(calendarSyncService.disconnectedUserIDs == [profile.id])
        #expect(viewModel.profile.selectedCalendarIDs == ["school"])
        #expect(viewModel.selectedCalendarIDs == ["school"])
        #expect(viewModel.statusMessage == "Permission for calendar access was denied.")
    }

    @Test func settingsViewModelDoesNotImportCalendarsWhenSelectionSaveFails() async {
        var profile = testProfile(id: uniqueUserID("settings-calendar-save-failure"))
        profile.selectedCalendarIDs = ["school"]
        let calendarSyncService = TestCalendarSyncService()
        let userService = TestUserService(profile: profile)
        userService.saveProfileError = AppError.network(description: "Profile save failed.")
        let viewModel = SettingsViewModel(
            user: profile,
            authService: TestAuthService(currentUserID: profile.id),
            userService: userService,
            calendarSyncService: calendarSyncService,
            notificationService: TestNotificationService(),
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: TestBackendFunctionService(),
            databaseService: TestDatabaseService(),
            analyticsService: TestAnalyticsService()
        )
        viewModel.selectedCalendarIDs = ["personal"]

        await viewModel.syncCalendars()

        #expect(calendarSyncService.importedCalendarIDs.isEmpty)
        #expect(calendarSyncService.disconnectedUserIDs.isEmpty)
        #expect(userService.savedProfiles.isEmpty)
        #expect(viewModel.profile.selectedCalendarIDs == ["school"])
        #expect(viewModel.selectedCalendarIDs == ["school"])
        #expect(viewModel.statusMessage == "Profile save failed.")
    }

    @Test func calendarDisconnectDeletesOnlyAppleCalendarPlannerBlocks() async throws {
        let userID = uniqueUserID("calendar-disconnect")
        let database = TestDatabaseService()
        let service = CalendarSyncService()
        service.databaseService = database
        let start = Date(timeIntervalSince1970: 1_776_000_000)
        let importedBlock = PlannerBlock(
            id: "apple-school-event",
            title: "Imported lecture",
            detail: "From Apple Calendar",
            startDate: start,
            endDate: start.addingTimeInterval(60 * 60),
            type: .classEvent,
            source: .appleCalendar,
            linkedGoalID: nil,
            linkedAssignmentID: nil
        )
        let appBlock = PlannerBlock(
            id: "app-study-block",
            title: "Study block",
            detail: "Created inside the app",
            startDate: start.addingTimeInterval(2 * 60 * 60),
            endDate: start.addingTimeInterval(3 * 60 * 60),
            type: .studySession,
            source: .app,
            linkedGoalID: nil,
            linkedAssignmentID: nil
        )
        try await database.save(importedBlock, in: .plannerBlocks, id: importedBlock.id, userID: userID)
        try await database.save(appBlock, in: .plannerBlocks, id: appBlock.id, userID: userID)

        try await service.disconnectCalendars(for: userID)

        await #expect(throws: AppError.dataNotFound) {
            try await database.fetch(PlannerBlock.self, from: .plannerBlocks, id: importedBlock.id, userID: userID)
        }
        let persistedAppBlock = try await database.fetch(PlannerBlock.self, from: .plannerBlocks, id: appBlock.id, userID: userID)
        #expect(persistedAppBlock.title == "Study block")
    }

    @Test func importedCalendarBlockIDDistinguishesRecurringOccurrences() {
        let firstOccurrence = Date(timeIntervalSince1970: 1_776_000_000)
        let secondOccurrence = firstOccurrence.addingTimeInterval(7 * 24 * 60 * 60)

        let firstID = CalendarSyncService.importedPlannerBlockID(
            calendarIdentifier: "school/calendar",
            externalIdentifier: "external-recurring-class",
            localIdentifier: "local-event-1",
            occurrenceDate: firstOccurrence,
            isRecurring: true
        )
        let secondID = CalendarSyncService.importedPlannerBlockID(
            calendarIdentifier: "school/calendar",
            externalIdentifier: "external-recurring-class",
            localIdentifier: "local-event-1",
            occurrenceDate: secondOccurrence,
            isRecurring: true
        )

        #expect(firstID != secondID)
        #expect(firstID.contains("external-recurring-class"))
        #expect(secondID.contains("external-recurring-class"))
        #expect(!firstID.contains("/"))
        #expect(!firstID.contains(":"))
    }

    @Test func importedCalendarBlockIDStaysStableWhenLocalEventIdentifierChanges() {
        let occurrence = Date(timeIntervalSince1970: 1_776_000_000)

        let originalID = CalendarSyncService.importedPlannerBlockID(
            calendarIdentifier: "school",
            externalIdentifier: "external-class-id",
            localIdentifier: "local-event-before-sync",
            occurrenceDate: occurrence,
            isRecurring: true
        )
        let syncedID = CalendarSyncService.importedPlannerBlockID(
            calendarIdentifier: "school",
            externalIdentifier: "external-class-id",
            localIdentifier: "local-event-after-sync",
            occurrenceDate: occurrence,
            isRecurring: true
        )

        #expect(originalID == syncedID)
    }

    @Test func importedCalendarBlockIDStaysStableWhenNonRecurringEventMoves() {
        let originalID = CalendarSyncService.importedPlannerBlockID(
            calendarIdentifier: "school",
            externalIdentifier: "external-one-off-id",
            localIdentifier: "local-event-id",
            occurrenceDate: Date(timeIntervalSince1970: 1_776_000_000),
            isRecurring: false
        )
        let movedID = CalendarSyncService.importedPlannerBlockID(
            calendarIdentifier: "school",
            externalIdentifier: "external-one-off-id",
            localIdentifier: "local-event-id",
            occurrenceDate: Date(timeIntervalSince1970: 1_776_086_400),
            isRecurring: false
        )

        #expect(originalID == movedID)
        #expect(originalID == "apple-school-external-one-off-id")
    }

    @Test func importedCalendarPrefixUsesSameSanitizationAsImportedBlockIDs() {
        let prefix = CalendarSyncService.importedCalendarPrefix(for: "school/calendar:primary")
        let id = CalendarSyncService.importedPlannerBlockID(
            calendarIdentifier: "school/calendar:primary",
            externalIdentifier: "external-class-id",
            localIdentifier: nil,
            occurrenceDate: Date(timeIntervalSince1970: 1_776_000_000),
            isRecurring: false
        )

        #expect(prefix == "apple-school_calendar_primary-")
        #expect(id.hasPrefix(prefix))
    }

    @Test func paywallViewModelPrepareRegistersAndHandlesTrigger() async {
        let profile = testProfile(id: uniqueUserID("paywall-prepare"))
        let paywallService = TestPaywallService()
        let viewModel = PaywallViewModel(
            user: profile,
            trigger: .premiumAssistant,
            subscriptionService: TestSubscriptionService(),
            paywallService: paywallService,
            analyticsService: TestAnalyticsService()
        )

        await viewModel.prepare()

        #expect(paywallService.registerCallCount == 1)
        #expect(paywallService.handledTriggers == [.premiumAssistant])
        #expect(paywallService.handledUserIDs.first == profile.id)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func paywallViewModelPrepareSurfacesOfferLoadFailure() async {
        let profile = testProfile(id: uniqueUserID("paywall-offer-error"))
        let subscriptionService = TestSubscriptionService()
        subscriptionService.availableOffersError = AppError.integrationUnavailable("RevenueCat")
        let analyticsService = TestAnalyticsService()
        let viewModel = PaywallViewModel(
            user: profile,
            trigger: .premiumAssistant,
            subscriptionService: subscriptionService,
            paywallService: TestPaywallService(),
            analyticsService: analyticsService
        )

        await viewModel.prepare()

        #expect(viewModel.offers == SubscriptionOffer.fallbackOffers)
        #expect(viewModel.errorMessage == "Unable to load current subscription offers. Prices will be shown at checkout.")
        #expect(analyticsService.errors == ["paywall_offers"])
    }

    @Test func paywallViewModelPrepareSurfacesEmptyLiveOffers() async {
        let profile = testProfile(id: uniqueUserID("paywall-offer-empty"))
        let subscriptionService = TestSubscriptionService()
        subscriptionService.availableOffersResult = []
        let analyticsService = TestAnalyticsService()
        let viewModel = PaywallViewModel(
            user: profile,
            trigger: .premiumAssistant,
            subscriptionService: subscriptionService,
            paywallService: TestPaywallService(),
            analyticsService: analyticsService
        )

        await viewModel.prepare()

        #expect(viewModel.offers == SubscriptionOffer.fallbackOffers)
        #expect(viewModel.errorMessage == "Unable to load current subscription offers. Prices will be shown at checkout.")
        #expect(analyticsService.errors == ["paywall_offers_empty"])
    }

    @Test func paywallViewModelPurchaseAndRestoreUseSubscriptionService() async throws {
        let profile = testProfile(id: uniqueUserID("paywall-purchase"))
        let subscriptionService = TestSubscriptionService()
        let analyticsService = TestAnalyticsService()
        let viewModel = PaywallViewModel(
            user: profile,
            trigger: .premiumGoalPlan,
            subscriptionService: subscriptionService,
            paywallService: TestPaywallService(),
            analyticsService: analyticsService
        )

        let purchasedState = try await viewModel.purchase(plan: .annual)
        #expect(purchasedState.entitlement == .active)
        #expect(purchasedState.activePlan == .annual)
        #expect(!viewModel.isLoading)

        let restoredState = try await viewModel.restore()
        #expect(restoredState.entitlement == .active)
        #expect(subscriptionService.restoredUserIDs == [profile.id])
        #expect(analyticsService.events.contains("restore_tapped"))
        #expect(!viewModel.isLoading)
    }

    @Test func onboardingCompletionRequiresProfileAndTimestamp() {
        var state = OnboardingState()
        #expect(!state.isComplete)

        state.didCompleteProfile = true
        state.completedAt = .now
        #expect(state.isComplete)
    }

    @Test func onboardingCompletionRejectsWhitespaceOnlyProfile() async {
        var profile = testProfile(id: uniqueUserID("onboarding-whitespace"))
        profile.displayName = "   "
        profile.academicFocus = ""
        let userService = TestUserService(profile: profile)
        let analyticsService = TestAnalyticsService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: profile.id, profile: profile),
            userService: userService,
            subscriptionService: TestSubscriptionService(),
            analyticsService: analyticsService
        )
        let sessionViewModel = AppSessionViewModel(container: container)
        let viewModel = OnboardingViewModel(
            user: profile,
            calendarSyncService: TestCalendarSyncService(),
            syllabusImportService: SyllabusImportService.shared,
            analyticsService: analyticsService,
            notificationService: TestNotificationService()
        )

        viewModel.focusArea = " \n\t "
        await viewModel.complete(using: sessionViewModel)

        #expect(!viewModel.state.isComplete)
        #expect(viewModel.errorMessage == "Add an academic focus before continuing.")
        #expect(userService.savedProfiles.isEmpty)
        #expect(!userService.onboardingState.isComplete)
        #expect(!analyticsService.events.contains("onboarding_completed"))
        #expect(!viewModel.isLoading)
    }

    @Test func onboardingCompletionRequiresAcademicFocusEvenWhenDisplayNameExists() async {
        var profile = testProfile(id: uniqueUserID("onboarding-focus-required"))
        profile.displayName = "Riley"
        profile.academicFocus = ""
        let userService = TestUserService(profile: profile)
        let analyticsService = TestAnalyticsService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: profile.id, profile: profile),
            userService: userService,
            subscriptionService: TestSubscriptionService(),
            analyticsService: analyticsService
        )
        let sessionViewModel = AppSessionViewModel(container: container)
        let viewModel = OnboardingViewModel(
            user: profile,
            calendarSyncService: TestCalendarSyncService(),
            syllabusImportService: SyllabusImportService.shared,
            analyticsService: analyticsService,
            notificationService: TestNotificationService()
        )

        viewModel.focusArea = "   "
        await viewModel.complete(using: sessionViewModel)

        #expect(!viewModel.state.isComplete)
        #expect(viewModel.errorMessage == "Add an academic focus before continuing.")
        #expect(userService.savedProfiles.isEmpty)
        #expect(!userService.onboardingState.isComplete)
        #expect(!analyticsService.events.contains("onboarding_completed"))
    }

    @Test func onboardingCompletionTrimsProfileBeforePersisting() async throws {
        var profile = testProfile(id: uniqueUserID("onboarding-trim"))
        profile.displayName = "  Riley  "
        profile.academicFocus = ""
        let userService = TestUserService(profile: profile)
        let subscriptionService = TestSubscriptionService()
        subscriptionService.state = .unlocked
        let analyticsService = TestAnalyticsService()
        let container = sessionContainer(
            authService: TestAuthService(currentUserID: profile.id, profile: profile),
            userService: userService,
            subscriptionService: subscriptionService,
            analyticsService: analyticsService
        )
        let sessionViewModel = AppSessionViewModel(container: container)
        for _ in 0..<20 where sessionViewModel.currentUser == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let viewModel = OnboardingViewModel(
            user: profile,
            calendarSyncService: TestCalendarSyncService(),
            syllabusImportService: SyllabusImportService.shared,
            analyticsService: analyticsService,
            notificationService: TestNotificationService()
        )

        viewModel.focusArea = "  Computer Science  "
        await viewModel.complete(using: sessionViewModel)

        let savedProfile = try #require(userService.savedProfiles.last)
        #expect(savedProfile.displayName == "Riley")
        #expect(savedProfile.academicFocus == "Computer Science")
        #expect(userService.onboardingState.isComplete)
        #expect(sessionViewModel.onboardingState.isComplete)
        #expect(sessionViewModel.currentUser?.academicFocus == "Computer Science")
        #expect(viewModel.state.isComplete)
        #expect(viewModel.errorMessage == nil)
        #expect(analyticsService.events.contains("onboarding_completed"))
        #expect(!viewModel.isLoading)
    }

    @Test func importsViewModelParsesTrimmedTextForReview() async throws {
        let profile = testProfile(id: uniqueUserID("imports-text"))
        let importService = TestSyllabusImportService()
        let job = testImportJob(id: "text-job")
        importService.importTextResult = job
        let analyticsService = TestAnalyticsService()
        let viewModel = ImportsViewModel(
            user: profile,
            syllabusImportService: importService,
            analyticsService: analyticsService
        )

        viewModel.importedText = " \n  CS 101\nHomework 1 due Friday  \t"
        await viewModel.importText()

        #expect(importService.importedTexts == ["CS 101\nHomework 1 due Friday"])
        #expect(viewModel.latestJob == job)
        #expect(viewModel.reviewingJob == job)
        #expect(viewModel.statusMessage == "Parsed 1 assignments from text.")
        #expect(viewModel.errorMessage == nil)
        #expect(analyticsService.events.contains("syllabus_import_started"))
        #expect(!viewModel.isImporting)
    }

    @Test func importsViewModelCommitUpdatesVisibleCommittedJob() async throws {
        let profile = testProfile(id: uniqueUserID("imports-commit"))
        let importService = TestSyllabusImportService()
        let analyticsService = TestAnalyticsService()
        let viewModel = ImportsViewModel(
            user: profile,
            syllabusImportService: importService,
            analyticsService: analyticsService
        )
        let job = testImportJob(id: "commit-job")

        try await viewModel.commit(job)

        #expect(importService.committedJobs == [job])
        #expect(viewModel.latestJob?.id == job.id)
        #expect(viewModel.latestJob?.status == .committed)
        #expect(viewModel.latestJob?.committedAt != nil)
        #expect(viewModel.reviewingJob?.id == job.id)
        #expect(viewModel.reviewingJob?.status == .committed)
        #expect(viewModel.statusMessage == "Imported 1 courses and 1 assignments.")
        #expect(viewModel.errorMessage == nil)
        #expect(analyticsService.events.contains("import_commit_confirmed"))
        #expect(viewModel.committingJobID == nil)
    }

    @Test func assistantLocalFallbackDropsUnsupportedDraftActions() async throws {
        let service = AssistantService()
        let aiBackend = TestAIBackendService(
            assistantResponse: AIWorkflowRunResponse(
                workflow: .assistantChat,
                result: AIAssistantChatResult(
                    message: "This belongs in the assistant reply, not a committable draft.",
                    draftActions: [
                        AIAssistantDraftAction(
                            type: "no_op",
                            title: "Suggestion only",
                            dueAt: nil,
                            reason: "There is nothing the app can safely commit."
                        ),
                        AIAssistantDraftAction(
                            type: "session_evaluation",
                            title: "Review the session",
                            dueAt: nil,
                            reason: "This should not create a commit button."
                        )
                    ]
                ),
                draftID: "draft-unsupported",
                degraded: nil
            )
        )
        service.aiBackendService = aiBackend

        let thread = try await service.sendMessage(
            "How did that study session go?",
            for: uniqueUserID("assistant-fallback-unsupported"),
            snapshot: .empty,
            goals: []
        )

        #expect(aiBackend.workflows == [.assistantChat])
        #expect(thread.messages.count == 2)
        #expect(thread.messages[0].content == "How did that study session go?")
        #expect(thread.messages[1].content == "This belongs in the assistant reply, not a committable draft.")
        #expect(thread.pendingDrafts.isEmpty)
    }

    @Test func assistantLocalFallbackKeepsSupportedPlannerDraftActions() async throws {
        let service = AssistantService()
        let aiBackend = TestAIBackendService(
            assistantResponse: AIWorkflowRunResponse(
                workflow: .assistantChat,
                result: AIAssistantChatResult(
                    message: "I drafted one planner adjustment.",
                    draftActions: [
                        AIAssistantDraftAction(
                            type: "planner_adjustment",
                            title: "Protect chemistry review",
                            dueAt: "2026-04-27T14:30:00.000Z",
                            reason: "Add this if it still fits your day."
                        )
                    ]
                ),
                draftID: "draft-1",
                degraded: nil
            )
        )
        service.aiBackendService = aiBackend

        let thread = try await service.sendMessage(
            "Add a study block.",
            for: uniqueUserID("assistant-fallback-planner"),
            snapshot: .empty,
            goals: []
        )

        #expect(thread.pendingDrafts.count == 1)
        #expect(thread.pendingDrafts[0].id == "draft-1-action-1")
        #expect(thread.pendingDrafts[0].kind == .plannerAdjustment)
        #expect(thread.pendingDrafts[0].title == "Protect chemistry review")
        #expect(thread.pendingDrafts[0].detail == "Add this if it still fits your day. Suggested time: 2026-04-27T14:30:00.000Z")
    }

    @Test func assistantDraftCommitRequiresLiveBackend() async throws {
        let database = TestDatabaseService()
        let service = BackendFunctionService()
        service.databaseService = database

        let draft = AssistantDraftAction(kind: .plannerAdjustment, title: "Protect a focus block", detail: "Add an hour for deep work.")
        let thread = AssistantThread(
            id: "primary",
            messages: [AssistantMessage(role: .assistant, content: "Try protecting a block.")],
            pendingDrafts: [draft]
        )

        try await database.save(thread, in: .assistantThreads, id: thread.id, userID: "test-user")
        do {
            try await service.commitAssistantDraft(.init(userID: "test-user", action: draft))
            #expect(Bool(false))
        } catch let error as AppError {
            #expect(error.errorDescription?.contains("live backend") == true)
        } catch {
            #expect(Bool(false))
        }

        let unchanged = try await database.fetch(AssistantThread.self, from: .assistantThreads, id: "primary", userID: "test-user")
        #expect(unchanged.pendingDrafts.count == 1)
        #expect(unchanged.messages.last?.content.contains("Draft committed") != true)
    }

    @Test func assistantGoalPlanDraftCommitDoesNotWriteLocalGoalPlanWithoutBackend() async throws {
        let database = TestDatabaseService()
        let service = BackendFunctionService()
        service.databaseService = database

        let goal = Goal(
            title: "Raise chemistry grade",
            detail: "Reach an A by finals week.",
            priority: .high,
            category: .academic,
            status: .active,
            dueDate: .now.addingTimeInterval(60 * 60 * 24 * 30),
            sortIndex: 0,
            subGoals: [],
            checkpoints: []
        )
        try await database.save(goal, in: .goals, id: goal.id, userID: "test-user")

        let draft = AssistantDraftAction(
            kind: .goalPlan,
            title: "Draft a plan for Raise chemistry grade",
            detail: "Break Raise chemistry grade into weekly checkpoints and 3 immediate next actions."
        )
        let thread = AssistantThread(id: "primary", messages: [], pendingDrafts: [draft])

        try await database.save(thread, in: .assistantThreads, id: thread.id, userID: "test-user")
        do {
            try await service.commitAssistantDraft(.init(userID: "test-user", action: draft))
            #expect(Bool(false))
        } catch let error as AppError {
            #expect(error.errorDescription?.contains("live backend") == true)
        } catch {
            #expect(Bool(false))
        }

        let savedDrafts = try await database.fetchAll(GoalPlanDraft.self, from: .goalPlans, userID: "test-user")
        #expect(savedDrafts.isEmpty)
    }

    @Test func exportUserDataRequiresLiveBackend() async {
        let service = BackendFunctionService()

        await #expect(throws: AppError.self) {
            try await service.exportUserData(UserJobRequestPayload(userID: uniqueUserID("export")))
        }
    }

    @Test func userServiceReturnsDefaultOnboardingStateWhenMissing() async throws {
        let database = TestDatabaseService()
        let service = UserService()
        service.databaseService = database

        let onboardingState = try await service.fetchOnboardingState(for: "missing-user")
        #expect(onboardingState == OnboardingState())
    }

    @Test func userServicePropagatesOnboardingFetchFailures() async {
        let service = UserService()
        service.databaseService = FailingDatabaseService(error: AppError.network(description: "disk failure"))

        await #expect(throws: AppError.network(description: "disk failure")) {
            try await service.fetchOnboardingState(for: "test-user")
        }
    }
}
