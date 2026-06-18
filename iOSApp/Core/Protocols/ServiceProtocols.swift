import Foundation

protocol AuthServicing: AnyObject {
    var currentUserID: String? { get }
    func authStateStream() -> AsyncStream<UserProfile?>
    func signIn(email: String, password: String) async throws -> UserProfile
    func signUp(email: String, password: String, displayName: String) async throws -> UserProfile
    func signInWithApple() async throws -> UserProfile
    func signInWithGoogle() async throws -> UserProfile
    func signOut() async throws
}

protocol UserServicing: AnyObject {
    func fetchProfile(for userID: String) async throws -> UserProfile
    func saveProfile(_ profile: UserProfile) async throws
    func fetchOnboardingState(for userID: String) async throws -> OnboardingState
    func saveOnboardingState(_ state: OnboardingState, for userID: String) async throws
}

protocol GoalServicing: AnyObject {
    func observeGoals(for userID: String) -> AsyncThrowingStream<[Goal], Error>
    func createGoal(_ goal: Goal, for userID: String) async throws
    func updateGoal(_ goal: Goal, for userID: String) async throws
    func deleteGoal(id: String, for userID: String) async throws
    func reorderGoals(_ goals: [Goal], for userID: String) async throws
    func generatePlan(for goal: Goal, timelineWeeks: Int, userID: String) async throws -> GoalPlanDraft
}

protocol PlannerServicing: AnyObject {
    func observeSnapshot(for userID: String, on date: Date) -> AsyncThrowingStream<PlannerSnapshot, Error>
    func savePlannerBlock(_ block: PlannerBlock, for userID: String) async throws
    func deletePlannerBlock(id: String, for userID: String) async throws
}

protocol CalendarSyncServicing: AnyObject {
    func requestAccess() async throws -> Bool
    func availableCalendars() async throws -> [SyncLink]
    func importSelectedCalendars(_ selectedCalendarIDs: [String], for userID: String) async throws -> [PlannerBlock]
    func disconnectCalendars(for userID: String) async throws
}

protocol StudySessionServicing: AnyObject {
    func observeSessions(for userID: String) -> AsyncThrowingStream<[StudySession], Error>
    func saveSession(_ session: StudySession, for userID: String) async throws
    func deleteSession(id: String, for userID: String) async throws
}

protocol ReflectionServicing: AnyObject {
    func fetchCheckIns(for userID: String) -> AsyncThrowingStream<[DailyCheckIn], Error>
    func fetchVibeChecks(for userID: String) -> AsyncThrowingStream<[VibeCheck], Error>
    func saveCheckIn(_ checkIn: DailyCheckIn, for userID: String) async throws
    func saveVibeCheck(_ vibeCheck: VibeCheck, for userID: String) async throws
    func deleteCheckIn(id: String, for userID: String) async throws
    func deleteVibeCheck(id: String, for userID: String) async throws
}

protocol AssistantServicing: AnyObject {
    func observeThread(for userID: String) -> AsyncThrowingStream<AssistantThread, Error>
    func sendMessage(_ text: String, for userID: String, snapshot: PlannerSnapshot, goals: [Goal]) async throws -> AssistantThread
    func commitDraftAction(_ action: AssistantDraftAction, for userID: String) async throws
}

protocol BackendFunctionServicing: AnyObject {
    func assistantRespond(_ request: AssistantRequestPayload) async throws -> AssistantThread
    func generateGoalPlan(_ request: GoalPlanRequestPayload) async throws -> GoalPlanDraft
    func commitAssistantDraft(_ request: AssistantDraftCommitPayload) async throws
    func importSyllabusText(_ request: ImportTextRequestPayload) async throws -> ImportJob
    func importSyllabusFile(_ request: ImportFileRequestPayload) async throws -> ImportJob
    func commitImport(_ request: ImportCommitPayload) async throws
    func deleteImport(_ request: DeleteImportPayload) async throws
    func syncSubscriptionStatus(_ request: UserJobRequestPayload) async throws -> SubscriptionState
    func deleteUserAccount(_ request: UserJobRequestPayload) async throws
    func exportUserData(_ request: UserJobRequestPayload) async throws -> ExportUserDataResponsePayload
}

protocol AIBackendServicing: AnyObject {
    var isConfigured: Bool { get }

    func run<Payload: Encodable, Result: Decodable>(
        workflow: AIWorkflow,
        payload: Payload,
        decode: Result.Type
    ) async throws -> AIWorkflowRunResponse<Result>
}

protocol SyllabusImportServicing: AnyObject {
    func observeImports(for userID: String) -> AsyncThrowingStream<[ImportJob], Error>
    func importText(_ text: String, for userID: String) async throws -> ImportJob
    func importFile(at fileURL: URL, for userID: String) async throws -> ImportJob
    func commit(_ job: ImportJob, for userID: String) async throws
    func delete(_ job: ImportJob, for userID: String) async throws
}

protocol NotificationServicing: AnyObject {
    func requestAuthorization() async throws -> NotificationPermissionState
    func currentSettings() async -> NotificationPermissionState
    func schedule(rule: ReminderRule) async throws
    func syncReminderRules(_ rules: [ReminderRule]) async throws -> Int
    func cancelReminderNotifications() async -> Int
    func clearRemoteToken(for userID: String) async -> Bool
    func updateRemoteToken(_ token: String)
}

protocol AnalyticsServicing: AnyObject {
    func track(event: String, parameters: [String: Any])
    func track(event: String)
    func trackScreen(_ name: String)
    func record(error: Error, context: String)
}

protocol SubscriptionServicing: AnyObject {
    func observeSubscriptionState(for userID: String) -> AsyncStream<SubscriptionState>
    func availableOffers() async throws -> [SubscriptionOffer]
    func refreshStatus(for userID: String) async throws -> SubscriptionState
    func purchase(plan: SubscriptionPlan, for userID: String) async throws -> SubscriptionState
    func restore(for userID: String) async throws -> SubscriptionState
    func linkUser(_ userID: String) async
    func unlinkUser() async
}

protocol PaywallServicing: AnyObject {
    func registerTriggers()
    func handle(trigger: PaywallTrigger, for userID: String?) async
}

protocol DatabaseServicing: AnyObject, Sendable {
    nonisolated func save<T: Codable>(_ value: T, in collection: AppCollection, id: String, userID: String?) async throws
    nonisolated func fetch<T: Codable>(_ type: T.Type, from collection: AppCollection, id: String, userID: String?) async throws -> T
    nonisolated func fetchAll<T: Codable>(_ type: T.Type, from collection: AppCollection, userID: String?) async throws -> [T]
    nonisolated func delete(from collection: AppCollection, id: String, userID: String?) async throws
    nonisolated func observeAll<T: Codable>(_ type: T.Type, from collection: AppCollection, userID: String?) -> AsyncThrowingStream<[T], Error>
}

protocol StorageServicing: AnyObject {
    func upload(data: Data, path: String, contentType: String) async throws -> String
    func delete(path: String) async throws
}

protocol NetworkServicing: AnyObject, Sendable {
    nonisolated func request<T: Decodable>(_ endpoint: APIEndpoint, decode: T.Type) async throws -> T
}

protocol DeepLinkServicing: AnyObject {
    func route(for url: URL) -> AppRoute?
}
