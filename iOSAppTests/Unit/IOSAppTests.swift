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
}

private final class TestDatabaseService: DatabaseServicing, @unchecked Sendable {
    private var storage = [String: [String: Data]]()
    private let lock = NSLock()

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
    private(set) var didSignOut = false

    init(currentUserID: String? = nil, profile: UserProfile? = nil) {
        self.currentUserID = currentUserID
        self.profile = profile
    }

    func authStateStream() -> AsyncStream<UserProfile?> {
        AsyncStream { continuation in
            continuation.yield(profile)
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
    private(set) var savedProfiles = [UserProfile]()

    init(profile: UserProfile) {
        self.profile = profile
    }

    func fetchProfile(for userID: String) async throws -> UserProfile {
        profile
    }

    func saveProfile(_ profile: UserProfile) async throws {
        savedProfiles.append(profile)
        self.profile = profile
    }

    func fetchOnboardingState(for userID: String) async throws -> OnboardingState {
        onboardingState
    }

    func saveOnboardingState(_ state: OnboardingState, for userID: String) async throws {}
}

private final class TestCalendarSyncService: CalendarSyncServicing {
    var calendars = [SyncLink]()
    private(set) var importedCalendarIDs = [[String]]()

    func requestAccess() async throws -> Bool {
        true
    }

    func availableCalendars() async throws -> [SyncLink] {
        calendars
    }

    func importSelectedCalendars(_ selectedCalendarIDs: [String], for userID: String) async throws -> [PlannerBlock] {
        importedCalendarIDs.append(selectedCalendarIDs)
        return []
    }
}

private final class TestNotificationService: NotificationServicing {
    var state: NotificationPermissionState = .unknown
    private(set) var scheduledRules = [ReminderRule]()

    func requestAuthorization() async throws -> NotificationPermissionState {
        state = .authorized
        return state
    }

    func currentSettings() async -> NotificationPermissionState {
        state
    }

    func schedule(rule: ReminderRule) async throws {
        scheduledRules.append(rule)
    }

    func updateRemoteToken(_ token: String) {}
}

private final class TestSubscriptionService: SubscriptionServicing {
    var state = SubscriptionState.locked
    private(set) var restoredUserIDs = [String]()
    private(set) var refreshedUserIDs = [String]()
    private(set) var linkedUserIDs = [String]()
    private(set) var didUnlinkUser = false

    func observeSubscriptionState(for userID: String) -> AsyncStream<SubscriptionState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func availableOffers() async throws -> [SubscriptionOffer] {
        SubscriptionOffer.fallbackOffers
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

    private func sessionContainer(
        authService: AuthServicing,
        userService: UserServicing,
        subscriptionService: SubscriptionServicing,
        analyticsService: AnalyticsServicing = TestAnalyticsService()
    ) -> AppContainer {
        AppContainer(
            configuration: .shared,
            analyticsService: analyticsService,
            authService: authService,
            userService: userService,
            goalService: TestGoalService(),
            plannerService: TestPlannerService(),
            calendarSyncService: TestCalendarSyncService(),
            studySessionService: StudySessionService.shared,
            reflectionService: ReflectionService.shared,
            assistantService: AssistantService.shared,
            backendFunctionService: TestBackendFunctionService(),
            aiBackendService: AIBackendService(configuration: .shared),
            syllabusImportService: SyllabusImportService.shared,
            notificationService: TestNotificationService(),
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

    @Test func subscriptionServiceRefreshUsesBackendBetaStateWhenRevenueCatIsUnavailable() async throws {
        let userID = uniqueUserID("subscription-beta")
        let backendService = TestBackendFunctionService()
        backendService.subscriptionState = SubscriptionState(
            entitlement: .active,
            activePlan: .none,
            trialEligible: false,
            lastSyncedAt: Date(timeIntervalSince1970: 1_777_204_800)
        )
        let service = SubscriptionService()
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

    @Test func settingsViewModelDeletesAccountThroughBackendThenSignsOut() async {
        let profile = testProfile(id: uniqueUserID("settings-delete"))
        let authService = TestAuthService(currentUserID: profile.id)
        let backendService = TestBackendFunctionService()
        let viewModel = SettingsViewModel(
            user: profile,
            authService: authService,
            userService: TestUserService(profile: profile),
            calendarSyncService: TestCalendarSyncService(),
            notificationService: TestNotificationService(),
            subscriptionService: TestSubscriptionService(),
            backendFunctionService: backendService,
            analyticsService: TestAnalyticsService()
        )

        await viewModel.deleteAccount()

        #expect(backendService.deletedUserIDs == [profile.id])
        #expect(authService.didSignOut)
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
            analyticsService: TestAnalyticsService()
        )

        await viewModel.restorePurchases()

        #expect(subscriptionService.restoredUserIDs == [profile.id])
        #expect(viewModel.statusMessage == "Purchases restored.")
        #expect(!viewModel.isRestoringPurchases)
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
