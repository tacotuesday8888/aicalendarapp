import Combine
import SwiftUI

@MainActor
final class ReflectionsViewModel: ObservableObject {
    @Published private(set) var checkIns = [DailyCheckIn]()
    @Published private(set) var vibeChecks = [VibeCheck]()
    @Published var selectedMoment: CheckInMoment = .morning
    @Published var selectedMood: MoodLevel = .okay
    @Published var selectedEnergy: EnergyLevel = .steady
    @Published var selectedStress: StressLevel = .focused
    @Published var notes = ""
    @Published var vibePrompt = ""
    @Published var errorMessage: String?
    @Published var isSavingCheckIn = false
    @Published var isSavingVibeCheck = false

    private let user: UserProfile
    private let reflectionService: ReflectionServicing
    private let aiBackendService: AIBackendServicing
    private let analyticsService: AnalyticsServicing
    private var tasks = [Task<Void, Never>]()
    private static let aiUnavailableVibeFeedback =
        "Saved. AI feedback is temporarily unavailable, but this reflection is still part of your check-in history."

    init(
        user: UserProfile,
        reflectionService: ReflectionServicing,
        aiBackendService: AIBackendServicing,
        analyticsService: AnalyticsServicing
    ) {
        self.user = user
        self.reflectionService = reflectionService
        self.aiBackendService = aiBackendService
        self.analyticsService = analyticsService
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    func start() {
        guard tasks.isEmpty else { return }

        tasks.append(Task {
            do {
                for try await items in reflectionService.fetchCheckIns(for: user.id) {
                    self.checkIns = items.sorted(by: { $0.createdAt > $1.createdAt })
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load check-ins.").errorDescription
            }
        })

        tasks.append(Task {
            do {
                for try await items in reflectionService.fetchVibeChecks(for: user.id) {
                    self.vibeChecks = items.sorted(by: { $0.createdAt > $1.createdAt })
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load vibe checks.").errorDescription
            }
        })

        analyticsService.trackScreen("reflections")
    }

    func hasCheckedIn(for moment: CheckInMoment) -> Bool {
        checkIns.contains { checkIn in
            checkIn.moment == moment && Calendar.current.isDateInToday(checkIn.createdAt)
        }
    }

    func saveCheckIn() async {
        guard !isSavingCheckIn else { return }
        guard !hasCheckedIn(for: selectedMoment) else {
            errorMessage = "You already logged a \(selectedMoment.rawValue) check-in today."
            return
        }

        isSavingCheckIn = true
        defer { isSavingCheckIn = false }

        let checkIn = DailyCheckIn(
            moment: selectedMoment,
            mood: selectedMood,
            energy: selectedEnergy,
            stress: selectedStress,
            notes: notes
        )

        do {
            try await reflectionService.saveCheckIn(checkIn, for: user.id)
            notes = ""
            errorMessage = nil
            analyticsService.track(event: "check_in_saved", parameters: ["moment": selectedMoment.rawValue])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to save check-in.").errorDescription
        }
    }

    func saveVibeCheck() async {
        let trimmedPrompt = vibePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !isSavingVibeCheck else { return }

        isSavingVibeCheck = true
        defer { isSavingVibeCheck = false }

        do {
            let feedback = try await vibeFeedback(for: trimmedPrompt)
            let vibeCheck = VibeCheck(
                mood: selectedMood,
                prompt: trimmedPrompt,
                feedback: feedback.text
            )
            try await reflectionService.saveVibeCheck(vibeCheck, for: user.id)
            vibePrompt = ""
            errorMessage = nil
            analyticsService.track(
                event: "vibe_check_saved",
                parameters: ["needs_escalation": feedback.needsEscalation, "ai_configured": aiBackendService.isConfigured]
            )
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to save vibe check.").errorDescription
        }
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
                        "mood": .string(selectedMood.rawValue),
                        "screen": .string("reflections")
                    ]
                ),
                decode: AIVibeFeedbackResult.self
            )
            return (response.result.feedback, response.result.needsEscalation)
        } catch {
            analyticsService.record(error: error, context: "reflections_vibe_feedback")
            return (Self.aiUnavailableVibeFeedback, false)
        }
    }

    func deleteCheckIns(at offsets: IndexSet) {
        let items = checkIns

        for index in offsets {
            let item = items[index]
            Task {
                do {
                    try await reflectionService.deleteCheckIn(id: item.id, for: user.id)
                    await MainActor.run {
                        self.errorMessage = nil
                    }
                    analyticsService.track(event: "check_in_deleted", parameters: ["moment": item.moment.rawValue])
                } catch {
                    await MainActor.run {
                        self.errorMessage = AppError.wrap(error, fallback: "Unable to delete check-in.").errorDescription
                    }
                }
            }
        }
    }

    func deleteVibeChecks(at offsets: IndexSet) {
        let items = vibeChecks

        for index in offsets {
            let item = items[index]
            Task {
                do {
                    try await reflectionService.deleteVibeCheck(id: item.id, for: user.id)
                    await MainActor.run {
                        self.errorMessage = nil
                    }
                    analyticsService.track(event: "vibe_check_deleted")
                } catch {
                    await MainActor.run {
                        self.errorMessage = AppError.wrap(error, fallback: "Unable to delete vibe check.").errorDescription
                    }
                }
            }
        }
    }
}

struct ReflectionsFeature: View {
    @StateObject private var viewModel: ReflectionsViewModel

    init(user: UserProfile, container: AppContainer) {
        _viewModel = StateObject(wrappedValue: ReflectionsViewModel(
            user: user,
            reflectionService: container.reflectionService,
            aiBackendService: container.aiBackendService,
            analyticsService: container.analyticsService
        ))
    }

    var body: some View {
        List {
            Section("Daily check-in") {
                Picker("Moment", selection: $viewModel.selectedMoment) {
                    ForEach([CheckInMoment.morning, .midday, .night], id: \.self) { moment in
                        Text(moment.rawValue.capitalized).tag(moment)
                    }
                }

                Picker("Mood", selection: $viewModel.selectedMood) {
                    ForEach(MoodLevel.allCases, id: \.self) { mood in
                        Text(mood.rawValue.capitalized).tag(mood)
                    }
                }

                Picker("Energy", selection: $viewModel.selectedEnergy) {
                    ForEach(EnergyLevel.allCases, id: \.self) { energy in
                        Text(energy.rawValue.capitalized).tag(energy)
                    }
                }

                Picker("Stress", selection: $viewModel.selectedStress) {
                    ForEach(StressLevel.allCases, id: \.self) { stress in
                        Text(stress.rawValue.capitalized).tag(stress)
                    }
                }

                TextField("Notes", text: $viewModel.notes, axis: .vertical)

                if viewModel.hasCheckedIn(for: viewModel.selectedMoment) {
                    Text("You already logged a \(viewModel.selectedMoment.rawValue) check-in today.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Save check-in") {
                    Task { await viewModel.saveCheckIn() }
                }
                .disabled(viewModel.hasCheckedIn(for: viewModel.selectedMoment) || viewModel.isSavingCheckIn)
            }

            Section("Vibe check") {
                TextField("How are you feeling right now?", text: $viewModel.vibePrompt, axis: .vertical)
                Button("Save vibe check") {
                    Task { await viewModel.saveVibeCheck() }
                }
                .disabled(viewModel.isSavingVibeCheck || viewModel.vibePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Recent check-ins") {
                if viewModel.checkIns.isEmpty {
                    Text("No check-ins yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.checkIns.prefix(10)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.moment.rawValue.capitalized)
                                .font(.headline)
                            Text(item.notes.ifEmpty("No notes"))
                                .foregroundStyle(.secondary)
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: viewModel.deleteCheckIns)
                }
            }

            Section("Recent vibe checks") {
                if viewModel.vibeChecks.isEmpty {
                    Text("No vibe checks yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.vibeChecks.prefix(10)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.prompt)
                            Text(item.feedback)
                                .foregroundStyle(.secondary)
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: viewModel.deleteVibeChecks)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Reflections")
        .task {
            viewModel.start()
        }
        .swGlassListChrome()
    }
}
