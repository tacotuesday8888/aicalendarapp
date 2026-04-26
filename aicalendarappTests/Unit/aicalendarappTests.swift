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

@MainActor
struct aicalendarappTests {
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
            #expect(false)
        } catch let error as AppError {
            #expect(error.errorDescription?.contains("live backend") == true)
        } catch {
            #expect(false)
        }
    }

    @Test func deepLinkParserHandlesGoalRoutes() {
        let route = DeepLinkService.shared.route(for: URL(string: "aicalendarapp://goal/abc123")!)
        #expect(route == .goal(id: "abc123"))
    }

    @Test func databaseServiceStoresAndFetchesUserProfiles() async throws {
        let service = DatabaseService()
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

    @Test func onboardingCompletionRequiresProfileAndTimestamp() {
        var state = OnboardingState()
        #expect(!state.isComplete)

        state.didCompleteProfile = true
        state.completedAt = .now
        #expect(state.isComplete)
    }

    @Test func assistantDraftCommitRequiresLiveBackend() async throws {
        let database = DatabaseService()
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
            #expect(false)
        } catch let error as AppError {
            #expect(error.errorDescription?.contains("live backend") == true)
        } catch {
            #expect(false)
        }

        let unchanged = try await database.fetch(AssistantThread.self, from: .assistantThreads, id: "primary", userID: "test-user")
        #expect(unchanged.pendingDrafts.count == 1)
        #expect(unchanged.messages.last?.content.contains("Draft committed") != true)
    }

    @Test func assistantGoalPlanDraftCommitDoesNotWriteLocalGoalPlanWithoutBackend() async throws {
        let database = DatabaseService()
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
            #expect(false)
        } catch let error as AppError {
            #expect(error.errorDescription?.contains("live backend") == true)
        } catch {
            #expect(false)
        }

        let savedDrafts = try await database.fetchAll(GoalPlanDraft.self, from: .goalPlans, userID: "test-user")
        #expect(savedDrafts.isEmpty)
    }

    @Test func userServiceReturnsDefaultOnboardingStateWhenMissing() async throws {
        let database = DatabaseService()
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
