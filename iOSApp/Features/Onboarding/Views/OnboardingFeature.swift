import SwiftUI
import Combine

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var profile: UserProfile
    @Published var state = OnboardingState()
    @Published var focusArea = ""
    @Published var syllabusText = ""
    @Published var selectedCalendarIDs = Set<String>()
    @Published var availableCalendars = [SyncLink]()
    @Published var importedJob: ImportJob?
    @Published var permissionState: NotificationPermissionState = .unknown
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var isParsingSyllabus = false
    @Published var showingImportReview = false

    private let calendarSyncService: CalendarSyncServicing
    private let syllabusImportService: SyllabusImportServicing
    private let analyticsService: AnalyticsServicing
    private let notificationService: NotificationServicing

    init(
        user: UserProfile,
        calendarSyncService: CalendarSyncServicing,
        syllabusImportService: SyllabusImportServicing,
        analyticsService: AnalyticsServicing,
        notificationService: NotificationServicing
    ) {
        self.profile = user
        self.calendarSyncService = calendarSyncService
        self.syllabusImportService = syllabusImportService
        self.analyticsService = analyticsService
        self.notificationService = notificationService
    }

    func load() async {
        guard availableCalendars.isEmpty else { return }
        do {
            availableCalendars = try await calendarSyncService.availableCalendars()
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to load calendars.").errorDescription
        }
    }

    func importCalendars() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let selected = Array(selectedCalendarIDs)
            _ = try await calendarSyncService.importSelectedCalendars(selected, for: profile.id)
            profile.selectedCalendarIDs = selected
            state.didImportCalendar = !selected.isEmpty
            analyticsService.track(event: "onboarding_calendar_imported", parameters: ["count": selected.count])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to import calendars.").errorDescription
        }
    }

    func importSyllabus() async {
        guard !syllabusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isParsingSyllabus, !isLoading else { return }
        errorMessage = nil
        isParsingSyllabus = true
        defer { isParsingSyllabus = false }

        do {
            let job = try await syllabusImportService.importText(syllabusText, for: profile.id)
            importedJob = job
            showingImportReview = true
            state.didImportSyllabus = false
            analyticsService.track(event: "onboarding_syllabus_parsed", parameters: ["assignments": job.extractedAssignments.count])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to import syllabus.").errorDescription
        }
    }

    func commitImportedJob(_ job: ImportJob) async throws {
        guard !isLoading else { return }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            try await syllabusImportService.commit(job, for: profile.id)
            var committedJob = job
            committedJob.status = .committed
            committedJob.committedAt = .now
            importedJob = committedJob
            state.didImportSyllabus = true
            analyticsService.track(event: "onboarding_syllabus_imported", parameters: ["assignments": job.extractedAssignments.count])
        } catch {
            let wrapped = AppError.wrap(error, fallback: "Unable to import syllabus.")
            errorMessage = wrapped.errorDescription
            throw wrapped
        }
    }

    func requestNotifications() async {
        do {
            permissionState = try await notificationService.requestAuthorization()
            if permissionState == .authorized || permissionState == .provisional {
                _ = try await notificationService.syncReminderRules(state.reminderRules)
            }
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to configure notifications.").errorDescription
        }
    }

    func complete(using sessionViewModel: AppSessionViewModel) async {
        guard !isLoading else { return }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let trimmedFocusArea = focusArea.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDisplayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.academicFocus = trimmedFocusArea
            profile.displayName = trimmedDisplayName

            guard !trimmedFocusArea.isEmpty else {
                state.didCompleteProfile = false
                state.completedAt = nil
                errorMessage = "Add an academic focus before continuing."
                return
            }

            state.didCompleteProfile = true
            state.completedAt = .now
            try await sessionViewModel.completeOnboarding(profile: profile, onboarding: state)
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to finish onboarding.").errorDescription
        }
    }
}

struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel
    @ObservedObject var sessionViewModel: AppSessionViewModel
    @State private var presentedPaywallTrigger: PaywallTrigger?

    init(viewModel: OnboardingViewModel, sessionViewModel: AppSessionViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.sessionViewModel = sessionViewModel
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Profile") {
                    TextField("Academic focus", text: $viewModel.focusArea)
                    Text("Examples: pre-med, CS, design, finance.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Apple Calendar") {
                    if viewModel.availableCalendars.isEmpty {
                        Text("Connect Apple Calendar to pull in classes and other time anchors.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.availableCalendars) { link in
                            Toggle(isOn: Binding(
                                get: { viewModel.selectedCalendarIDs.contains(link.externalID) },
                                set: { isOn in
                                    if isOn {
                                        viewModel.selectedCalendarIDs.insert(link.externalID)
                                    } else {
                                        viewModel.selectedCalendarIDs.remove(link.externalID)
                                    }
                                }
                            )) {
                                Text(link.displayName)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Button("Import selected calendars") {
                        Task { await viewModel.importCalendars() }
                    }
                }

                Section("Syllabus Import") {
                    TextEditor(text: $viewModel.syllabusText)
                        .frame(minHeight: 120)
                    Button("Parse syllabus") {
                        guard !requirePremiumIfLocked() else { return }
                        Task { await viewModel.importSyllabus() }
                    }
                    .disabled(viewModel.isParsingSyllabus || viewModel.isLoading || viewModel.syllabusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let importedJob = viewModel.importedJob {
                        Text("\(importedJob.extractedAssignments.count) assignments parsed • \(importedJob.status.rawValue.capitalized)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !importedJob.warnings.isEmpty {
                            ForEach(importedJob.warnings, id: \.self) { warning in
                                Text(warning)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(importedJob.status == .committed ? "Review imported syllabus" : "Review before import") {
                            guard !requirePremiumIfLocked() else { return }
                            viewModel.showingImportReview = true
                        }
                    }
                }

                Section("Notifications") {
                    Button("Enable reminders") {
                        Task { await viewModel.requestNotifications() }
                    }
                    Text("Three default check-ins are scheduled for morning, midday, and night.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.complete(using: sessionViewModel) }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Continue to subscription")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isLoading)
                }
            }
            .navigationTitle("Onboarding")
            .task {
                await viewModel.load()
            }
            .sheet(isPresented: $viewModel.showingImportReview) {
                if let importedJob = viewModel.importedJob {
                    ImportReviewSheet(
                        job: importedJob,
                        title: "Review Syllabus",
                        commitButtonTitle: importedJob.status == .committed ? "Update Import" : "Import to Planner"
                    ) { updatedJob in
                        guard !requirePremiumIfLocked() else {
                            throw AppError.premiumRequired
                        }
                        try await viewModel.commitImportedJob(updatedJob)
                    }
                }
            }
            .sheet(item: $presentedPaywallTrigger) { trigger in
                PaywallView(
                    viewModel: PaywallViewModel(
                        user: viewModel.profile,
                        trigger: trigger,
                        subscriptionService: sessionViewModel.container.subscriptionService,
                        paywallService: sessionViewModel.container.paywallService,
                        analyticsService: sessionViewModel.container.analyticsService
                    ),
                    onUnlocked: {
                        presentedPaywallTrigger = nil
                        Task { await sessionViewModel.refreshSubscription() }
                    }
                )
            }
            .swGlassListChrome()
        }
    }

    private func requirePremiumIfLocked() -> Bool {
        guard let trigger = sessionViewModel.subscriptionState.paywallTrigger(for: .syllabusImport) else {
            return false
        }
        presentedPaywallTrigger = trigger
        return true
    }
}
