import SwiftUI
import Combine

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var thread = AssistantThread(id: "primary", messages: [], pendingDrafts: [])
    @Published private(set) var snapshot = PlannerSnapshot.empty
    @Published private(set) var goals = [Goal]()
    @Published var message = ""
    @Published var errorMessage: String?
    @Published private(set) var isSending = false

    private let user: UserProfile
    private let assistantService: AssistantServicing
    private let plannerService: PlannerServicing
    private let goalService: GoalServicing
    private let analyticsService: AnalyticsServicing
    private var tasks = [Task<Void, Never>]()

    init(user: UserProfile, assistantService: AssistantServicing, plannerService: PlannerServicing, goalService: GoalServicing, analyticsService: AnalyticsServicing) {
        self.user = user
        self.assistantService = assistantService
        self.plannerService = plannerService
        self.goalService = goalService
        self.analyticsService = analyticsService
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    func start() {
        guard tasks.isEmpty else { return }

        tasks.append(Task {
            do {
                for try await thread in assistantService.observeThread(for: user.id) {
                    self.thread = thread
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load the assistant thread.").errorDescription
            }
        })

        tasks.append(Task {
            do {
                for try await snapshot in plannerService.observeSnapshot(for: user.id, on: .now) {
                    self.snapshot = snapshot
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load your planner snapshot.").errorDescription
            }
        })

        tasks.append(Task {
            do {
                for try await goals in goalService.observeGoals(for: user.id) {
                    self.goals = goals
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load goals for the assistant.").errorDescription
            }
        })
    }

    func send() async {
        guard !isSending, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            thread = try await assistantService.sendMessage(message, for: user.id, snapshot: snapshot, goals: goals)
            analyticsService.track(event: "assistant_message_sent")
            message = ""
            errorMessage = nil
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to reach the assistant.").errorDescription
        }
    }

    func commit(_ draft: AssistantDraftAction) async {
        do {
            try await assistantService.commitDraftAction(draft, for: user.id)
            errorMessage = nil
            analyticsService.track(event: "assistant_draft_committed", parameters: ["kind": draft.kind.rawValue])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to commit draft action.").errorDescription
        }
    }
}

struct AppShellView: View {
    let container: AppContainer
    @ObservedObject var sessionViewModel: AppSessionViewModel
    @State private var selectedTab: AppTab = .today
    @State private var showAssistant = false
    @State private var presentedPaywallTrigger: PaywallTrigger?

    private var user: UserProfile? {
        sessionViewModel.currentUser
    }

    var body: some View {
        NavigationStack {
            Group {
                if let user {
                    TabView(selection: $selectedTab) {
                        TodayView(user: user, container: container)
                            .tabItem { Label(AppTab.today.title, systemImage: AppTab.today.symbolName) }
                            .tag(AppTab.today)

                        GoalsView(
                            user: user,
                            container: container,
                            isPremiumLocked: sessionViewModel.subscriptionState.requiresPaywall,
                            onRequirePremium: {
                                presentedPaywallTrigger = .premiumGoalPlan
                            }
                        )
                            .tabItem { Label(AppTab.goals.title, systemImage: AppTab.goals.symbolName) }
                            .tag(AppTab.goals)

                        CalendarView(user: user, container: container)
                            .tabItem { Label(AppTab.calendar.title, systemImage: AppTab.calendar.symbolName) }
                            .tag(AppTab.calendar)

                        SessionsView(user: user, container: container)
                            .tabItem { Label(AppTab.sessions.title, systemImage: AppTab.sessions.symbolName) }
                            .tag(AppTab.sessions)

                        SettingsView(user: user, container: container)
                            .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.symbolName) }
                            .tag(AppTab.settings)
                    }
                    .background(SWLiquidGlassBackground())
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                if sessionViewModel.subscriptionState.requiresPaywall {
                                    presentedPaywallTrigger = .premiumAssistant
                                } else {
                                    showAssistant = true
                                }
                            } label: {
                                Label("Assistant", systemImage: "sparkles")
                            }
                        }
                    }
                    .sheet(isPresented: $showAssistant) {
                        AssistantSheet(user: user, container: container)
                    }
                    .sheet(item: $presentedPaywallTrigger) { trigger in
                        PaywallView(
                            viewModel: PaywallViewModel(
                                user: user,
                                trigger: trigger,
                                subscriptionService: container.subscriptionService,
                                paywallService: container.paywallService,
                                analyticsService: container.analyticsService
                            ),
                            onUnlocked: {
                                presentedPaywallTrigger = nil
                                Task { await sessionViewModel.refreshSubscription() }
                            }
                        )
                    }
                    .onAppear { applyPendingRoute() }
                    .onChange(of: sessionViewModel.pendingRoute) { _, _ in
                        applyPendingRoute()
                    }
                } else {
                    ContentUnavailableView("Session unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                }
            }
        }
    }

    private func applyPendingRoute() {
        guard let route = sessionViewModel.pendingRoute else { return }
        sessionViewModel.pendingRoute = nil
        switch route {
        case .today:
            selectedTab = .today
        case .goal:
            selectedTab = .goals
        case .session:
            selectedTab = .sessions
        case .assistant:
            showAssistant = true
        case .paywall(let trigger):
            presentedPaywallTrigger = trigger
        case .importedSyllabus:
            selectedTab = .calendar
        }
    }
}

struct AssistantSheet: View {
    @StateObject private var viewModel: AssistantViewModel
    @Environment(\.dismiss) private var dismiss

    init(user: UserProfile, container: AppContainer) {
        _viewModel = StateObject(wrappedValue: AssistantViewModel(
            user: user,
            assistantService: container.assistantService,
            plannerService: container.plannerService,
            goalService: container.goalService,
            analyticsService: container.analyticsService
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.thread.messages) { message in
                            AppCard {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.role == .assistant ? "Assistant" : "You")
                                        .font(.caption.bold())
                                        .foregroundStyle(AppTheme.textSecondary)
                                    Text(message.content)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        if !viewModel.thread.pendingDrafts.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Draft actions")
                                    .font(.headline)
                                ForEach(viewModel.thread.pendingDrafts) { draft in
                                    AppCard {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(draft.title)
                                            Text(draft.detail)
                                                .font(.footnote)
                                                .foregroundStyle(AppTheme.textSecondary)
                                            Button("Commit draft") {
                                                Task { await viewModel.commit(draft) }
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }

                HStack {
                    TextField("Ask for a plan, schedule adjustment, or reflection.", text: $viewModel.message)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isSending)
                    Button {
                        Task { await viewModel.send() }
                    } label: {
                        if viewModel.isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Send")
                        }
                    }
                    .buttonStyle(SWGlassCTAButtonStyle())
                    .disabled(viewModel.isSending || viewModel.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Assistant")
            .swGlassScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                viewModel.start()
            }
        }
    }
}

extension PaywallTrigger: Identifiable {
    public var id: String { rawValue }
}
