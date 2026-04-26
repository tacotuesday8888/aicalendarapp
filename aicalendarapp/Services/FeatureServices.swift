import EventKit
import Foundation
import UserNotifications
#if canImport(PDFKit)
import PDFKit
#endif

private func requiredDatabaseService(_ databaseService: DatabaseServicing?) throws -> DatabaseServicing {
    guard let databaseService else {
        throw AppError.missingConfiguration("databaseService")
    }
    return databaseService
}

private func requiredBackendFunctionService(_ backendFunctionService: BackendFunctionServicing?) throws -> BackendFunctionServicing {
    guard let backendFunctionService else {
        throw AppError.missingConfiguration("backendFunctionService")
    }
    return backendFunctionService
}

private func requiredStorageService(_ storageService: StorageServicing?) throws -> StorageServicing {
    guard let storageService else {
        throw AppError.missingConfiguration("storageService")
    }
    return storageService
}

final class GoalService: GoalServicing {
    static let shared = GoalService()

    var databaseService: DatabaseServicing?
    var backendFunctionService: BackendFunctionServicing?
    var aiBackendService: AIBackendServicing?

    func observeGoals(for userID: String) -> AsyncThrowingStream<[Goal], Error> {
        databaseService?.observeAll(Goal.self, from: .goals, userID: userID) ?? AsyncThrowingStream { continuation in
            continuation.finish(throwing: AppError.missingConfiguration("databaseService"))
        }
    }

    func createGoal(_ goal: Goal, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).save(goal, in: .goals, id: goal.id, userID: userID)
    }

    func updateGoal(_ goal: Goal, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).save(goal, in: .goals, id: goal.id, userID: userID)
    }

    func deleteGoal(id: String, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).delete(from: .goals, id: id, userID: userID)
    }

    func reorderGoals(_ goals: [Goal], for userID: String) async throws {
        for (index, goal) in goals.enumerated() {
            var updated = goal
            updated.sortIndex = index
            try await updateGoal(updated, for: userID)
        }
    }

    func generatePlan(for goal: Goal, timelineWeeks: Int, userID: String) async throws -> GoalPlanDraft {
        if let aiBackendService {
            let response = try await aiBackendService.run(
                workflow: .goalPlanGeneration,
                payload: AIGoalPlanPayload(
                    goalID: goal.id,
                    goal: AIGoalDetails(goal: goal),
                    timelineWeeks: timelineWeeks,
                    startDate: ISO8601DateFormatter.appJSON.string(from: .now),
                    timezone: TimeZone.current.identifier
                ),
                decode: AIGoalPlanResult.self
            )

            return GoalPlanDraft(
                id: response.draftID ?? UUID().uuidString,
                goalID: goal.id,
                summary: response.result.summary,
                suggestedTimelineWeeks: timelineWeeks,
                checkpoints: response.result.milestones.map { milestone in
                    GoalCheckpoint(
                        title: milestone.title,
                        dueDate: Self.parseISODate(milestone.dueDate) ?? .now
                    )
                },
                nextActions: response.result.nextActions.map { action in
                    GoalStep(title: action.title, isComplete: false)
                }
            )
        }

        return try await requiredBackendFunctionService(backendFunctionService).generateGoalPlan(
            GoalPlanRequestPayload(userID: userID, goal: goal, timelineWeeks: timelineWeeks)
        )
    }

    private static func parseISODate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter.appJSON.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }
}

final class PlannerService: PlannerServicing {
    static let shared = PlannerService()

    var databaseService: DatabaseServicing?

    func observeSnapshot(for userID: String, on date: Date) -> AsyncThrowingStream<PlannerSnapshot, Error> {
        guard let databaseService else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AppError.missingConfiguration("databaseService"))
            }
        }

        return AsyncThrowingStream { continuation in
            let accumulator = PlannerAccumulator(referenceDate: date)
            let observationState = PlannerObservationState()

            let goalsTask = Task {
                do {
                    for try await goals in databaseService.observeAll(Goal.self, from: .goals, userID: userID) {
                        await accumulator.updateGoals(goals)
                        if let snapshot = await accumulator.snapshotIfReady() {
                            continuation.yield(snapshot)
                        }
                    }
                } catch {
                    await observationState.finish(continuation, error: error)
                }
            }

            let assignmentsTask = Task {
                do {
                    for try await assignments in databaseService.observeAll(Assignment.self, from: .assignments, userID: userID) {
                        await accumulator.updateAssignments(assignments)
                        if let snapshot = await accumulator.snapshotIfReady() {
                            continuation.yield(snapshot)
                        }
                    }
                } catch {
                    await observationState.finish(continuation, error: error)
                }
            }

            let habitsTask = Task {
                do {
                    for try await habits in databaseService.observeAll(Habit.self, from: .habits, userID: userID) {
                        await accumulator.updateHabits(habits)
                        if let snapshot = await accumulator.snapshotIfReady() {
                            continuation.yield(snapshot)
                        }
                    }
                } catch {
                    await observationState.finish(continuation, error: error)
                }
            }

            let blocksTask = Task {
                do {
                    for try await blocks in databaseService.observeAll(PlannerBlock.self, from: .plannerBlocks, userID: userID) {
                        await accumulator.updateBlocks(blocks)
                        if let snapshot = await accumulator.snapshotIfReady() {
                            continuation.yield(snapshot)
                        }
                    }
                } catch {
                    await observationState.finish(continuation, error: error)
                }
            }

            let sessionsTask = Task {
                do {
                    for try await sessions in databaseService.observeAll(StudySession.self, from: .studySessions, userID: userID) {
                        await accumulator.updateSessions(sessions)
                        if let snapshot = await accumulator.snapshotIfReady() {
                            continuation.yield(snapshot)
                        }
                    }
                } catch {
                    await observationState.finish(continuation, error: error)
                }
            }

            let tasks = [goalsTask, assignmentsTask, habitsTask, blocksTask, sessionsTask]
            Task { await observationState.register(tasks) }

            continuation.onTermination = { _ in
                tasks.forEach { $0.cancel() }
            }
        }
    }

    func savePlannerBlock(_ block: PlannerBlock, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).save(block, in: .plannerBlocks, id: block.id, userID: userID)
    }

    func deletePlannerBlock(id: String, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).delete(from: .plannerBlocks, id: id, userID: userID)
    }
}

final class CalendarSyncService: CalendarSyncServicing {
    static let shared = CalendarSyncService()

    var databaseService: DatabaseServicing?

    private let eventStore = EKEventStore()

    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func availableCalendars() async throws -> [SyncLink] {
        _ = try await requestAccess()
        return eventStore.calendars(for: .event).map {
            SyncLink(provider: .appleCalendar, externalID: $0.calendarIdentifier, displayName: $0.title, direction: .importOnly, lastSyncedAt: .now)
        }
    }

    func importSelectedCalendars(_ selectedCalendarIDs: [String], for userID: String) async throws -> [PlannerBlock] {
        let granted = try await requestAccess()
        guard granted else {
            throw AppError.permissionDenied("calendar access")
        }

        guard !selectedCalendarIDs.isEmpty else { return [] }

        let selectedSet = Set(selectedCalendarIDs)
        let calendars = eventStore.calendars(for: .event).filter { selectedSet.contains($0.calendarIdentifier) }
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: .now)) ?? .now
        let endDate = Calendar.current.date(byAdding: .day, value: 90, to: startDate) ?? .now
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        let blocks = events.map {
            PlannerBlock(
                id: importedPlannerBlockID(for: $0),
                title: $0.title,
                detail: $0.notes ?? "",
                startDate: $0.startDate,
                endDate: $0.endDate,
                type: .classEvent,
                source: .appleCalendar,
                linkedGoalID: nil,
                linkedAssignmentID: nil
            )
        }

        let importedIDs = Set(blocks.map(\.id))
        let selectedCalendarPrefixes = Set(selectedCalendarIDs.map { "apple-\($0)-" })
        let databaseService = try requiredDatabaseService(databaseService)
        let existingBlocks = try await databaseService.fetchAll(PlannerBlock.self, from: .plannerBlocks, userID: userID)

        for block in blocks {
            try await databaseService.save(block, in: .plannerBlocks, id: block.id, userID: userID)
        }

        for staleBlock in existingBlocks where staleBlock.source == .appleCalendar && !importedIDs.contains(staleBlock.id) {
            let belongsToSelected = selectedCalendarPrefixes.contains(where: { staleBlock.id.hasPrefix($0) })
            if belongsToSelected {
                try await databaseService.delete(from: .plannerBlocks, id: staleBlock.id, userID: userID)
            }
        }

        return blocks
    }

    private func importedPlannerBlockID(for event: EKEvent) -> String {
        let eventIdentifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let rawIdentifier = "apple-\(event.calendar.calendarIdentifier)-\(eventIdentifier)"
        return rawIdentifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

final class StudySessionService: StudySessionServicing {
    static let shared = StudySessionService()

    var databaseService: DatabaseServicing?

    private static let timerNotificationPrefix = "session_timer_"
    private let notificationCenter = UNUserNotificationCenter.current()

    func observeSessions(for userID: String) -> AsyncThrowingStream<[StudySession], Error> {
        databaseService?.observeAll(StudySession.self, from: .studySessions, userID: userID) ?? AsyncThrowingStream { continuation in
            continuation.finish(throwing: AppError.missingConfiguration("databaseService"))
        }
    }

    func saveSession(_ session: StudySession, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).save(session, in: .studySessions, id: session.id, userID: userID)

        if session.status == .active {
            scheduleTimerNotification(for: session)
        } else {
            cancelTimerNotification(for: session.id)
        }
    }

    func deleteSession(id: String, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).delete(from: .studySessions, id: id, userID: userID)
        cancelTimerNotification(for: id)
    }

    private func scheduleTimerNotification(for session: StudySession) {
        guard let startedAt = session.startedAt else { return }

        let fireDate = startedAt.addingTimeInterval(TimeInterval(session.plannedMinutes * 60))
        let interval = fireDate.timeIntervalSinceNow
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Session complete"
        content.body = "\"\(session.title)\" has reached its planned \(session.plannedMinutes) minutes."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.timerNotificationPrefix + session.id,
            content: content,
            trigger: trigger
        )
        notificationCenter.add(request) { error in
            if let error {
                AppLogger(category: "study-session").error("Unable to schedule timer notification: \(error.localizedDescription)")
            }
        }
    }

    private func cancelTimerNotification(for sessionID: String) {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [Self.timerNotificationPrefix + sessionID]
        )
    }
}

final class ReflectionService: ReflectionServicing {
    static let shared = ReflectionService()

    var databaseService: DatabaseServicing?

    func fetchCheckIns(for userID: String) -> AsyncThrowingStream<[DailyCheckIn], Error> {
        databaseService?.observeAll(DailyCheckIn.self, from: .checkIns, userID: userID) ?? AsyncThrowingStream { continuation in
            continuation.finish(throwing: AppError.missingConfiguration("databaseService"))
        }
    }

    func fetchVibeChecks(for userID: String) -> AsyncThrowingStream<[VibeCheck], Error> {
        databaseService?.observeAll(VibeCheck.self, from: .vibeChecks, userID: userID) ?? AsyncThrowingStream { continuation in
            continuation.finish(throwing: AppError.missingConfiguration("databaseService"))
        }
    }

    func saveCheckIn(_ checkIn: DailyCheckIn, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).save(checkIn, in: .checkIns, id: checkIn.id, userID: userID)
    }

    func saveVibeCheck(_ vibeCheck: VibeCheck, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).save(vibeCheck, in: .vibeChecks, id: vibeCheck.id, userID: userID)
    }

    func deleteCheckIn(id: String, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).delete(from: .checkIns, id: id, userID: userID)
    }

    func deleteVibeCheck(id: String, for userID: String) async throws {
        try await requiredDatabaseService(databaseService).delete(from: .vibeChecks, id: id, userID: userID)
    }
}

final class AssistantService: AssistantServicing {
    static let shared = AssistantService()

    var databaseService: DatabaseServicing?
    var backendFunctionService: BackendFunctionServicing?

    func observeThread(for userID: String) -> AsyncThrowingStream<AssistantThread, Error> {
        guard let databaseService else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AppError.missingConfiguration("databaseService"))
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await threads in databaseService.observeAll(AssistantThread.self, from: .assistantThreads, userID: userID) {
                        let primaryThread = threads.first(where: { $0.id == "primary" }) ?? threads.first
                        continuation.yield(primaryThread ?? AssistantThread(id: "primary", messages: [], pendingDrafts: []))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func sendMessage(_ text: String, for userID: String, snapshot: PlannerSnapshot, goals: [Goal]) async throws -> AssistantThread {
        try await requiredBackendFunctionService(backendFunctionService).assistantRespond(
            AssistantRequestPayload(userID: userID, message: text, snapshot: snapshot, goals: goals)
        )
    }

    func commitDraftAction(_ action: AssistantDraftAction, for userID: String) async throws {
        try await requiredBackendFunctionService(backendFunctionService).commitAssistantDraft(
            AssistantDraftCommitPayload(userID: userID, action: action)
        )
    }
}

final class SyllabusImportService: SyllabusImportServicing {
    static let shared = SyllabusImportService()

    var databaseService: DatabaseServicing?
    var storageService: StorageServicing?
    var backendFunctionService: BackendFunctionServicing?

    func observeImports(for userID: String) -> AsyncThrowingStream<[ImportJob], Error> {
        databaseService?.observeAll(ImportJob.self, from: .imports, userID: userID) ?? AsyncThrowingStream { continuation in
            continuation.finish(throwing: AppError.missingConfiguration("databaseService"))
        }
    }

    func importText(_ text: String, for userID: String) async throws -> ImportJob {
        try await requiredBackendFunctionService(backendFunctionService).importSyllabusText(
            ImportTextRequestPayload(userID: userID, text: text)
        )
    }

    func importFile(at fileURL: URL, for userID: String) async throws -> ImportJob {
        let accessedSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let extractedText = try extractImportText(from: fileURL)
        let data = try Data(contentsOf: fileURL)
        let contentType = fileURL.pathExtension.lowercased() == "pdf" ? "application/pdf" : "text/plain"
        let remotePath = try await requiredStorageService(storageService).upload(
            data: data,
            path: "users/\(userID)/imports/\(UUID().uuidString)-\(fileURL.lastPathComponent)",
            contentType: contentType
        )
        return try await requiredBackendFunctionService(backendFunctionService).importSyllabusFile(
            ImportFileRequestPayload(userID: userID, sourceName: fileURL.lastPathComponent, uploadedPath: remotePath, extractedText: extractedText)
        )
    }

    func commit(_ job: ImportJob, for userID: String) async throws {
        try await requiredBackendFunctionService(backendFunctionService).commitImport(
            ImportCommitPayload(userID: userID, job: job)
        )
    }

    func delete(_ job: ImportJob, for userID: String) async throws {
        try await requiredBackendFunctionService(backendFunctionService).deleteImport(
            DeleteImportPayload(userID: userID, job: job)
        )
    }

    private func extractImportText(from fileURL: URL) throws -> String {
        if fileURL.pathExtension.lowercased() == "pdf" {
            #if canImport(PDFKit)
            guard let document = PDFDocument(url: fileURL) else {
                throw AppError.network(description: "Unable to open this PDF. Try a text-based syllabus file instead.")
            }
            let text = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                throw AppError.network(description: "This PDF does not contain readable text. Use a text-based syllabus or a searchable PDF.")
            }
            return text
            #else
            throw AppError.integrationUnavailable("PDFKit")
            #endif
        }

        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let data = try Data(contentsOf: fileURL)
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }

        throw AppError.network(description: "We could not extract readable text from this file. Import a plain text file or a searchable PDF.")
    }
}

private actor PlannerAccumulator {
    private var blocks = [PlannerBlock]()
    private var assignments = [Assignment]()
    private var habits = [Habit]()
    private var goals = [Goal]()
    private var sessions = [StudySession]()
    private var didLoadBlocks = false
    private var didLoadAssignments = false
    private var didLoadHabits = false
    private var didLoadGoals = false
    private var didLoadSessions = false

    init(referenceDate _: Date) {}

    func updateBlocks(_ blocks: [PlannerBlock]) {
        self.blocks = blocks.sorted(by: { $0.startDate < $1.startDate })
        didLoadBlocks = true
    }

    func updateAssignments(_ assignments: [Assignment]) {
        self.assignments = assignments.sorted(by: { $0.dueDate < $1.dueDate })
        didLoadAssignments = true
    }

    func updateHabits(_ habits: [Habit]) {
        self.habits = habits
        didLoadHabits = true
    }

    func updateGoals(_ goals: [Goal]) {
        self.goals = goals.sorted(by: { $0.sortIndex < $1.sortIndex })
        didLoadGoals = true
    }

    func updateSessions(_ sessions: [StudySession]) {
        self.sessions = sessions.sorted(by: { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) })
        didLoadSessions = true
    }

    func snapshotIfReady() -> PlannerSnapshot? {
        guard didLoadBlocks, didLoadAssignments, didLoadHabits, didLoadGoals, didLoadSessions else {
            return nil
        }

        return snapshot()
    }

    private func snapshot() -> PlannerSnapshot {
        let incompleteAssignments = assignments.filter { !$0.isComplete }
        let activeGoals = goals.filter { $0.status == .active }
        let suggestedAction = incompleteAssignments.first.map { "Finish \($0.title)" } ?? activeGoals.first.map { "Move \( $0.title ) forward" } ?? "Protect one study block for your most important work."

        let currentDate = Date.now
        let hour = Calendar.current.component(.hour, from: currentDate)
        let nextMoment: CheckInMoment? =
            if hour < 11 {
                .morning
            } else if hour < 18 {
                .midday
            } else {
                .night
            }

        return PlannerSnapshot(
            date: currentDate,
            blocks: blocks,
            assignments: incompleteAssignments,
            habits: habits,
            goals: activeGoals,
            sessions: sessions,
            nextSuggestedAction: suggestedAction,
            nextCheckInMoment: nextMoment
        )
    }
}

private actor PlannerObservationState {
    private var didFinish = false
    private var siblingTasks: [Task<Void, Never>] = []

    func register(_ tasks: [Task<Void, Never>]) {
        guard !didFinish else {
            tasks.forEach { $0.cancel() }
            return
        }
        siblingTasks = tasks
    }

    func finish(_ continuation: AsyncThrowingStream<PlannerSnapshot, Error>.Continuation, error: Error) {
        guard !didFinish else { return }
        didFinish = true
        let toCancel = siblingTasks
        siblingTasks.removeAll()
        toCancel.forEach { $0.cancel() }
        continuation.finish(throwing: error)
    }
}
