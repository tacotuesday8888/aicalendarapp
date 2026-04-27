//
//  aicalendarappTests.swift
//  aicalendarappTests
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

@MainActor
struct aicalendarappTests {
    private func uniqueUserID(_ prefix: String = "test-user") -> String {
        "\(prefix)-\(UUID().uuidString)"
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
