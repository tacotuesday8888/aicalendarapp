import SwiftUI
import Combine

@MainActor
final class GoalsViewModel: ObservableObject {
    @Published private(set) var goals = [Goal]()
    @Published var title = ""
    @Published var detail = ""
    @Published var selectedPriority: GoalPriority = .high
    @Published var selectedCategory: GoalCategory = .academic
    @Published var dueDate = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @Published var plansByGoalID = [String: GoalPlanDraft]()
    @Published var editingGoal: Goal?
    @Published var pendingDeleteGoal: Goal?
    @Published var isAddingGoal = false
    @Published private(set) var planLoadingGoalIDs = Set<String>()
    @Published var goalActionID: String?
    @Published var errorMessage: String?
    @Published private(set) var isReorderingGoals = false

    private let user: UserProfile
    private let goalService: GoalServicing
    private let databaseService: DatabaseServicing
    private let analyticsService: AnalyticsServicing
    private var observationTask: Task<Void, Never>?
    private var planObservationTask: Task<Void, Never>?
    private var reorderTask: Task<Void, Never>?

    init(user: UserProfile, goalService: GoalServicing, databaseService: DatabaseServicing, analyticsService: AnalyticsServicing) {
        self.user = user
        self.goalService = goalService
        self.databaseService = databaseService
        self.analyticsService = analyticsService
    }

    deinit {
        observationTask?.cancel()
        planObservationTask?.cancel()
        reorderTask?.cancel()
    }

    func start() {
        guard observationTask == nil else { return }
        observationTask = Task {
            do {
                for try await goals in goalService.observeGoals(for: user.id) {
                    self.goals = goals.sorted(by: { $0.sortIndex < $1.sortIndex })
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load goals.").errorDescription
            }
        }

        planObservationTask = Task {
            do {
                for try await plans in databaseService.observeAll(GoalPlanDraft.self, from: .goalPlans, userID: user.id) {
                    var index = [String: GoalPlanDraft]()
                    for plan in plans {
                        if let existing = index[plan.goalID] {
                            if plan.createdAt > existing.createdAt { index[plan.goalID] = plan }
                        } else {
                            index[plan.goalID] = plan
                        }
                    }
                    self.plansByGoalID.merge(index) { existing, observed in
                        observed.createdAt > existing.createdAt ? observed : existing
                    }
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load goal plans.").errorDescription
            }
        }

        analyticsService.trackScreen("goals")
    }

    func addGoal() async {
        guard !title.isEmpty, !isAddingGoal else { return }

        errorMessage = nil
        isAddingGoal = true
        defer { isAddingGoal = false }

        let goal = Goal(
            title: title,
            detail: detail,
            priority: selectedPriority,
            category: selectedCategory,
            status: .active,
            dueDate: dueDate,
            sortIndex: goals.count,
            subGoals: [],
            checkpoints: []
        )

        do {
            try await goalService.createGoal(goal, for: user.id)
            title = ""
            detail = ""
            dueDate = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
            errorMessage = nil
            analyticsService.track(event: "goal_created")
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to create goal.").errorDescription
        }
    }

    func toggleGoal(_ goal: Goal) async {
        guard goalActionID == nil else { return }

        errorMessage = nil
        goalActionID = goal.id
        defer { goalActionID = nil }

        var updated = goal
        updated.status = goal.status == .completed ? .active : .completed
        do {
            try await goalService.updateGoal(updated, for: user.id)
            errorMessage = nil
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to update goal.").errorDescription
        }
    }

    func beginEditing(_ goal: Goal) {
        editingGoal = goal
    }

    func saveEdits(_ updated: Goal) async throws {
        guard goalActionID == nil else { return }

        errorMessage = nil
        goalActionID = updated.id
        defer { goalActionID = nil }

        try await goalService.updateGoal(updated, for: user.id)
        editingGoal = nil
        errorMessage = nil
        analyticsService.track(event: "goal_updated")
    }

    func requestDelete(at offsets: IndexSet) {
        if let index = offsets.first, goals.indices.contains(index) {
            pendingDeleteGoal = goals[index]
        }
    }

    func confirmDelete() async {
        guard let goal = pendingDeleteGoal, goalActionID == nil else { return }

        errorMessage = nil
        goalActionID = goal.id
        defer {
            goalActionID = nil
            pendingDeleteGoal = nil
        }

        do {
            try await goalService.deleteGoal(id: goal.id, for: user.id)
            errorMessage = nil
            analyticsService.track(event: "goal_deleted")
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to delete goal.").errorDescription
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        guard !isReorderingGoals else { return }

        var reordered = goals
        reordered.move(fromOffsets: source, toOffset: destination)

        isReorderingGoals = true
        reorderTask?.cancel()
        reorderTask = Task {
            do {
                try await goalService.reorderGoals(reordered, for: user.id)
                await MainActor.run {
                    self.errorMessage = nil
                    self.isReorderingGoals = false
                }
                analyticsService.track(event: "goal_reordered")
            } catch {
                await MainActor.run {
                    self.errorMessage = AppError.wrap(error, fallback: "Unable to reorder goals.").errorDescription
                    self.isReorderingGoals = false
                }
            }
        }
    }

    func generatePlan(for goal: Goal) async {
        guard !planLoadingGoalIDs.contains(goal.id) else { return }

        errorMessage = nil
        planLoadingGoalIDs.insert(goal.id)
        defer { planLoadingGoalIDs.remove(goal.id) }

        do {
            let plan = try await goalService.generatePlan(for: goal, timelineWeeks: 6, userID: user.id)
            plansByGoalID[plan.goalID] = plan
            errorMessage = nil
            analyticsService.track(event: "goal_plan_requested", parameters: ["goal_id": goal.id])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to generate plan.").errorDescription
        }
    }
}

struct GoalsView: View {
    private enum FocusField {
        case newGoalTitle
    }

    @StateObject private var viewModel: GoalsViewModel
    @FocusState private var focusedField: FocusField?
    private let isPremiumLocked: Bool
    private let onRequirePremium: (() -> Void)?

    init(
        user: UserProfile,
        container: AppContainer,
        isPremiumLocked: Bool = false,
        onRequirePremium: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: GoalsViewModel(
            user: user,
            goalService: container.goalService,
            databaseService: container.databaseService,
            analyticsService: container.analyticsService
        ))
        self.isPremiumLocked = isPremiumLocked
        self.onRequirePremium = onRequirePremium
    }

    var body: some View {
        List {
            Section("Create a goal") {
                TextField("Goal title", text: $viewModel.title)
                    .focused($focusedField, equals: .newGoalTitle)
                TextField("Why this matters", text: $viewModel.detail, axis: .vertical)
                DatePicker("Target date", selection: $viewModel.dueDate, displayedComponents: .date)
                Picker("Priority", selection: $viewModel.selectedPriority) {
                    ForEach(GoalPriority.allCases, id: \.self) { priority in
                        Text(priority.rawValue.capitalized).tag(priority)
                    }
                }
                Picker("Category", selection: $viewModel.selectedCategory) {
                    ForEach(GoalCategory.allCases, id: \.self) { category in
                        Text(category.rawValue.capitalized).tag(category)
                    }
                }
                Button {
                    Task { await viewModel.addGoal() }
                } label: {
                    if viewModel.isAddingGoal {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Add goal")
                    }
                }
                .disabled(viewModel.isAddingGoal || viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Goals") {
                if viewModel.goals.isEmpty {
                    EmptyStateView(
                        systemImage: "flag.2.crossed",
                        title: "Set your first goal",
                        message: "Add one meaningful academic, career, or wellbeing goal so the planner can start organizing around it.",
                        actionTitle: "Add Goal"
                    ) {
                        focusedField = .newGoalTitle
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(viewModel.goals) { goal in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(goal.title)
                                    .font(.headline)
                                Spacer()
                                Button(goal.status == .completed ? "Reopen" : "Complete") {
                                    Task { await viewModel.toggleGoal(goal) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.goalActionID == goal.id)
                            }
                            Text(goal.detail)
                                .foregroundStyle(.secondary)
                            if let dueDate = goal.dueDate {
                                Text("Target: \(dueDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Edit") {
                                    viewModel.beginEditing(goal)
                                }
                                .buttonStyle(.borderless)
                                .disabled(viewModel.goalActionID == goal.id)

                                Button {
                                    if isPremiumLocked {
                                        onRequirePremium?()
                                    } else {
                                        Task { await viewModel.generatePlan(for: goal) }
                                    }
                                } label: {
                                    if viewModel.planLoadingGoalIDs.contains(goal.id) {
                                        ProgressView()
                                    } else {
                                        Text("Generate AI plan")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(viewModel.planLoadingGoalIDs.contains(goal.id))
                            }

                            if let plan = viewModel.plansByGoalID[goal.id] {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(plan.summary)
                                        .font(.subheadline)
                                    ForEach(plan.nextActions.prefix(3)) { action in
                                        Text("• \(action.title)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: viewModel.requestDelete)
                    .onMove(perform: viewModel.move)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Goals")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(viewModel.isReorderingGoals)
            }
        }
        .sheet(item: $viewModel.editingGoal) { goal in
            GoalEditorSheet(goal: goal) { updated in
                try await viewModel.saveEdits(updated)
            }
        }
        .confirmationDialog(
            "Delete this goal?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteGoal != nil },
                set: { if !$0 { viewModel.pendingDeleteGoal = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Goal", role: .destructive) {
                Task { await viewModel.confirmDelete() }
            }
            Button("Keep Goal", role: .cancel) {}
        } message: {
            Text("This removes the goal and its progress from your planner.")
        }
        .task {
            viewModel.start()
        }
        .swGlassListChrome()
    }
}

private struct GoalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var detail: String
    @State private var priority: GoalPriority
    @State private var category: GoalCategory
    @State private var dueDate: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let goal: Goal
    private let onSave: (Goal) async throws -> Void

    init(goal: Goal, onSave: @escaping (Goal) async throws -> Void) {
        self.goal = goal
        self.onSave = onSave
        _title = State(initialValue: goal.title)
        _detail = State(initialValue: goal.detail)
        _priority = State(initialValue: goal.priority)
        _category = State(initialValue: goal.category)
        _dueDate = State(initialValue: goal.dueDate ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Goal title", text: $title)
                TextField("Detail", text: $detail, axis: .vertical)
                DatePicker("Target date", selection: $dueDate, displayedComponents: .date)
                Picker("Priority", selection: $priority) {
                    ForEach(GoalPriority.allCases, id: \.self) { priority in
                        Text(priority.rawValue.capitalized).tag(priority)
                    }
                }
                Picker("Category", selection: $category) {
                    ForEach(GoalCategory.allCases, id: \.self) { category in
                        Text(category.rawValue.capitalized).tag(category)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Edit Goal")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            guard !isSaving else { return }
                            isSaving = true
                            errorMessage = nil
                            defer { isSaving = false }

                            var updated = goal
                            updated.title = title
                            updated.detail = detail
                            updated.priority = priority
                            updated.category = category
                            updated.dueDate = dueDate

                            do {
                                try await onSave(updated)
                                dismiss()
                            } catch {
                                errorMessage = AppError.wrap(error, fallback: "Unable to update goal.").errorDescription
                            }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
