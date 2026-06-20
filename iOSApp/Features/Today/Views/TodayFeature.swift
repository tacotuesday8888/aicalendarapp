import SwiftUI
import Combine

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var snapshot = PlannerSnapshot.empty
    @Published private(set) var checkIns = [DailyCheckIn]()
    @Published private(set) var vibeChecks = [VibeCheck]()
    @Published var vibePrompt = ""
    @Published var selectedCheckInMood: MoodLevel = .okay
    @Published var selectedVibeMood: MoodLevel = .okay
    @Published var selectedEnergy: EnergyLevel = .steady
    @Published var selectedStress: StressLevel = .focused
    @Published var checkInNotes = ""
    @Published var isSubmittingCheckIn = false
    @Published var isSubmittingVibeCheck = false
    @Published var errorMessage: String?

    private let user: UserProfile
    private let plannerService: PlannerServicing
    private let reflectionService: ReflectionServicing
    private let aiBackendService: AIBackendServicing
    private let databaseService: DatabaseServicing
    private let analyticsService: AnalyticsServicing
    private var tasks = [Task<Void, Never>]()
    private static let aiUnavailableVibeFeedback =
        "Saved. AI feedback is temporarily unavailable, but this reflection is still part of your check-in history."

    init(
        user: UserProfile,
        plannerService: PlannerServicing,
        reflectionService: ReflectionServicing,
        aiBackendService: AIBackendServicing,
        databaseService: DatabaseServicing,
        analyticsService: AnalyticsServicing
    ) {
        self.user = user
        self.plannerService = plannerService
        self.reflectionService = reflectionService
        self.aiBackendService = aiBackendService
        self.databaseService = databaseService
        self.analyticsService = analyticsService
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    func start() {
        guard tasks.isEmpty else { return }

        tasks.append(Task {
            do {
                for try await snapshot in plannerService.observeSnapshot(for: user.id, on: .now) {
                    self.snapshot = snapshot
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load today's planner.").errorDescription
            }
        })

        tasks.append(Task {
            do {
                for try await checkIns in reflectionService.fetchCheckIns(for: user.id) {
                    self.checkIns = checkIns.sorted(by: { $0.createdAt > $1.createdAt })
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load check-ins.").errorDescription
            }
        })

        tasks.append(Task {
            do {
                for try await vibeChecks in reflectionService.fetchVibeChecks(for: user.id) {
                    self.vibeChecks = vibeChecks.sorted(by: { $0.createdAt > $1.createdAt })
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load vibe checks.").errorDescription
            }
        })

        analyticsService.trackScreen("today")
    }

    func submitVibeCheck() async {
        let trimmedPrompt = vibePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !isSubmittingVibeCheck else { return }

        errorMessage = nil
        isSubmittingVibeCheck = true
        defer { isSubmittingVibeCheck = false }

        do {
            let feedback = try await vibeFeedback(for: trimmedPrompt)
            let vibe = VibeCheck(mood: selectedVibeMood, prompt: trimmedPrompt, feedback: feedback.text)
            try await reflectionService.saveVibeCheck(vibe, for: user.id)
            vibePrompt = ""
            errorMessage = nil
            analyticsService.track(
                event: "vibe_check_submitted",
                parameters: ["needs_escalation": feedback.needsEscalation, "ai_configured": aiBackendService.isConfigured]
            )
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to save vibe check.").errorDescription
        }
    }

    func submitCheckIn(moment: CheckInMoment) async {
        guard !isSubmittingCheckIn else { return }

        errorMessage = nil
        isSubmittingCheckIn = true
        defer { isSubmittingCheckIn = false }

        do {
            let checkIn = DailyCheckIn(
                moment: moment,
                mood: selectedCheckInMood,
                energy: selectedEnergy,
                stress: selectedStress,
                notes: checkInNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try await reflectionService.saveCheckIn(checkIn, for: user.id)
            checkInNotes = ""
            errorMessage = nil
            analyticsService.track(event: "daily_checkin_submitted", parameters: ["moment": moment.rawValue])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to save check-in.").errorDescription
        }
    }

    var activeSession: StudySession? {
        snapshot.sessions.first(where: { $0.status == .active })
    }

    var focusGoals: [Goal] {
        Array(snapshot.goals.prefix(3))
    }

    var upcomingBlocks: [PlannerBlock] {
        snapshot.blocks
            .filter { $0.endDate >= .now }
            .sorted(by: { $0.startDate < $1.startDate })
            .prefix(3)
            .map { $0 }
    }

    func toggleHabit(_ habit: Habit) async {
        var updated = habit
        updated.isCompletedToday = !habit.isCompletedToday
        if updated.isCompletedToday {
            updated.streak += 1
        } else {
            updated.streak = max(0, updated.streak - 1)
        }

        do {
            try await databaseService.save(updated, in: .habits, id: updated.id, userID: user.id)
            errorMessage = nil
            analyticsService.track(event: "habit_toggled", parameters: ["completed": updated.isCompletedToday])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to update habit.").errorDescription
        }
    }

    var isEmptyState: Bool {
        snapshot.goals.isEmpty && snapshot.blocks.isEmpty && snapshot.assignments.isEmpty && snapshot.habits.isEmpty && activeSession == nil
    }

    func hasCheckedIn(for moment: CheckInMoment) -> Bool {
        checkIns.contains { checkIn in
            checkIn.moment == moment && Calendar.current.isDateInToday(checkIn.createdAt)
        }
    }

    var availableCheckInMoment: CheckInMoment? {
        guard let moment = snapshot.nextCheckInMoment else { return nil }
        return hasCheckedIn(for: moment) ? nil : moment
    }

    private func vibeFeedback(for text: String) async throws -> (text: String, needsEscalation: Bool) {
        guard aiBackendService.isConfigured else {
            return (
                Self.aiUnavailableVibeFeedback,
                false
            )
        }

        do {
            let response = try await aiBackendService.run(
                workflow: .vibeFeedback,
                payload: AIVibeFeedbackPayload(
                    reflectionText: text,
                    timezone: TimeZone.current.identifier,
                    recentContext: [
                        "mood": .string(selectedVibeMood.rawValue),
                        "screen": .string("today")
                    ]
                ),
                decode: AIVibeFeedbackResult.self
            )
            return (response.result.feedback, response.result.needsEscalation)
        } catch {
            analyticsService.record(error: error, context: "today_vibe_feedback")
            return (Self.aiUnavailableVibeFeedback, false)
        }
    }
}

struct TodayView: View {
    @StateObject private var viewModel: TodayViewModel

    init(user: UserProfile, container: AppContainer) {
        _viewModel = StateObject(wrappedValue: TodayViewModel(
            user: user,
            plannerService: container.plannerService,
            reflectionService: container.reflectionService,
            aiBackendService: container.aiBackendService,
            databaseService: container.databaseService,
            analyticsService: container.analyticsService
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SummaryCard(title: "Next recommended action", content: viewModel.snapshot.nextSuggestedAction)

                if viewModel.isEmptyState {
                    EmptyStateView(
                        systemImage: "sun.max.fill",
                        title: "Start your day",
                        message: "Add a goal, import your calendar, or protect one focus block so Today has something concrete to guide."
                    )
                }

                if let moment = viewModel.availableCheckInMoment {
                    CheckInPanel(viewModel: viewModel, moment: moment)
                }

                SummaryCard(
                    title: "Assignments due",
                    content: viewModel.snapshot.assignments.map(\.title).joined(separator: ", ").ifEmpty("No urgent assignments imported yet.")
                )

                if viewModel.snapshot.habits.isEmpty {
                    SummaryCard(title: "Habits", content: "No habits configured yet.")
                } else {
                    AppCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Habits")
                                .font(.headline)
                                .foregroundStyle(AppTheme.textPrimary)
                            ForEach(viewModel.snapshot.habits) { habit in
                                HStack {
                                    Button {
                                        Task { await viewModel.toggleHabit(habit) }
                                    } label: {
                                        Image(systemName: habit.isCompletedToday ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(habit.isCompletedToday ? AppTheme.accent : AppTheme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(habit.title)
                                            .strikethrough(habit.isCompletedToday)
                                            .foregroundStyle(AppTheme.textPrimary)
                                        Text("\(habit.streak) day streak")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }

                if let activeSession = viewModel.activeSession {
                    SummaryCard(
                        title: "Active focus session",
                        content: "\(activeSession.title) • started \(activeSession.startedAt?.formatted(date: .omitted, time: .shortened) ?? "just now")"
                    )
                }

                if !viewModel.focusGoals.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Priority goals")
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)
                        ForEach(viewModel.focusGoals) { goal in
                            SummaryCard(
                                title: goal.title,
                                content: goal.detail.ifEmpty("Keep this moving with one visible next step.")
                            )
                        }
                    }
                }

                if !viewModel.upcomingBlocks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Upcoming schedule")
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)
                        ForEach(viewModel.upcomingBlocks) { block in
                            SummaryCard(
                                title: block.title,
                                content: "\(block.startDate.formatted(date: .abbreviated, time: .shortened)) • \(block.type.displayTitle)"
                            )
                        }
                    }
                }

                VibeCheckPanel(viewModel: viewModel)

                if !viewModel.checkIns.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent check-ins")
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)
                        ForEach(viewModel.checkIns.prefix(3)) { item in
                            SummaryCard(
                                title: item.moment.rawValue.capitalized,
                                content: item.notes.ifEmpty("Mood: \(item.mood.rawValue.capitalized), Energy: \(item.energy.rawValue.capitalized), Stress: \(item.stress.rawValue.capitalized)")
                            )
                        }
                    }
                }

                if let latestVibe = viewModel.vibeChecks.first {
                    SummaryCard(title: "Latest vibe feedback", content: latestVibe.feedback)
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(AppTheme.screenPadding)
        }
        .navigationTitle("Today")
        .swGlassScreenBackground()
        .task {
            viewModel.start()
        }
    }
}

private struct SummaryCard: View {
    let title: String
    let content: String

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(content)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

private struct CheckInPanel: View {
    @ObservedObject var viewModel: TodayViewModel
    let moment: CheckInMoment

    var body: some View {
        SWGlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Check-in")
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Log your \(moment.rawValue) pulse before the day drifts.")
                    .foregroundStyle(AppTheme.textSecondary)

                MoodSelector(title: "Mood", selection: $viewModel.selectedCheckInMood)
                EnergySelector(title: "Energy", selection: $viewModel.selectedEnergy)
                StressSelector(title: "Stress", selection: $viewModel.selectedStress)
                TextField("Notes (optional)", text: $viewModel.checkInNotes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await viewModel.submitCheckIn(moment: moment) }
                } label: {
                    if viewModel.isSubmittingCheckIn {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Complete now")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(SWGlassCTAButtonStyle())
                .disabled(viewModel.isSubmittingCheckIn)
            }
        }
    }
}

private struct VibeCheckPanel: View {
    @ObservedObject var viewModel: TodayViewModel

    var body: some View {
        SWGlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vibe check")
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)

                TextField("How are you feeling right now?", text: $viewModel.vibePrompt)
                    .textFieldStyle(.roundedBorder)

                MoodSelector(title: "Mood", selection: $viewModel.selectedVibeMood)

                Button {
                    Task { await viewModel.submitVibeCheck() }
                } label: {
                    if viewModel.isSubmittingVibeCheck {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Save vibe check")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(SWGlassCTAButtonStyle())
                .disabled(viewModel.isSubmittingVibeCheck || viewModel.vibePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct MoodSelector: View {
    let title: String
    @Binding var selection: MoodLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Picker(title, selection: $selection) {
                ForEach(MoodLevel.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct EnergySelector: View {
    let title: String
    @Binding var selection: EnergyLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Picker(title, selection: $selection) {
                ForEach(EnergyLevel.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct StressSelector: View {
    let title: String
    @Binding var selection: StressLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Picker(title, selection: $selection) {
                ForEach(StressLevel.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

private extension PlannerBlockType {
    var displayTitle: String {
        switch self {
        case .classEvent:
            return "Class Event"
        case .task:
            return "Task"
        case .studySession:
            return "Study Session"
        case .habit:
            return "Habit"
        case .reminder:
            return "Reminder"
        case .wellbeing:
            return "Wellbeing"
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
