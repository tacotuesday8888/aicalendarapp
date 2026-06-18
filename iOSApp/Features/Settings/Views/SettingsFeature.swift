import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var notificationState: NotificationPermissionState = .unknown
    @Published private(set) var availableCalendars = [SyncLink]()
    @Published var profile: UserProfile
    @Published var selectedCalendarIDs: Set<String>
    @Published var statusMessage = ""
    @Published var isRequestingNotifications = false
    @Published var isRestoringPurchases = false
    @Published var isSyncingCalendars = false
    @Published var isSavingProfile = false
    @Published var isSigningOut = false
    @Published var isDeletingAccount = false
    @Published var isExportingData = false
    @Published var showProfileEditor = false
    @Published var showSignOutConfirmation = false
    @Published var showDeleteAccountConfirmation = false
    @Published var showExportFileExporter = false
    @Published var exportDocument: UserDataExportDocument?
    @Published var exportFilename = ""

    private let authService: AuthServicing
    private let userService: UserServicing
    private let calendarSyncService: CalendarSyncServicing
    private let notificationService: NotificationServicing
    private let subscriptionService: SubscriptionServicing
    private let backendFunctionService: BackendFunctionServicing
    private let analyticsService: AnalyticsServicing

    init(
        user: UserProfile,
        authService: AuthServicing,
        userService: UserServicing,
        calendarSyncService: CalendarSyncServicing,
        notificationService: NotificationServicing,
        subscriptionService: SubscriptionServicing,
        backendFunctionService: BackendFunctionServicing,
        analyticsService: AnalyticsServicing
    ) {
        self.profile = user
        self.selectedCalendarIDs = Set(user.selectedCalendarIDs)
        self.authService = authService
        self.userService = userService
        self.calendarSyncService = calendarSyncService
        self.notificationService = notificationService
        self.subscriptionService = subscriptionService
        self.backendFunctionService = backendFunctionService
        self.analyticsService = analyticsService
    }

    func load() async {
        notificationState = await notificationService.currentSettings()
        do {
            availableCalendars = try await calendarSyncService.availableCalendars()
        } catch {
            statusMessage = AppError.wrap(error, fallback: "Unable to load available calendars.").errorDescription ?? ""
        }
        analyticsService.trackScreen("settings")
    }

    func saveProfile(_ updated: UserProfile) async throws {
        guard !isSavingProfile else { return }

        isSavingProfile = true
        defer { isSavingProfile = false }

        do {
            try await userService.saveProfile(updated)
            profile = updated
            statusMessage = "Profile updated."
            analyticsService.track(event: "profile_updated")
        } catch {
            let wrapped = AppError.wrap(error, fallback: "Unable to save profile.")
            statusMessage = wrapped.errorDescription ?? ""
            throw wrapped
        }
    }

    func requestNotifications() async {
        guard !isRequestingNotifications else { return }

        isRequestingNotifications = true
        defer { isRequestingNotifications = false }

        do {
            notificationState = try await notificationService.requestAuthorization()
            if notificationState == .authorized || notificationState == .provisional {
                let onboardingState = try await userService.fetchOnboardingState(for: profile.id)
                let scheduledCount = try await notificationService.syncReminderRules(onboardingState.reminderRules)
                let reminderLabel = scheduledCount == 1 ? "reminder" : "reminders"
                statusMessage = scheduledCount == 0
                    ? "Notifications are \(notificationState.rawValue). No reminder rules are enabled."
                    : "Notifications are \(notificationState.rawValue). \(scheduledCount) \(reminderLabel) scheduled."
                analyticsService.track(event: "notification_reminders_scheduled", parameters: ["count": scheduledCount])
            } else {
                statusMessage = "Notifications are \(notificationState.rawValue)."
                analyticsService.track(event: "notification_permission_denied")
            }
        } catch {
            statusMessage = AppError.wrap(error, fallback: "Unable to update notifications.").errorDescription ?? ""
        }
    }

    func syncCalendars() async {
        guard !isSyncingCalendars else { return }

        isSyncingCalendars = true
        defer { isSyncingCalendars = false }

        do {
            let selectedIDs = Array(selectedCalendarIDs).sorted()

            guard !selectedIDs.isEmpty else {
                try await calendarSyncService.disconnectCalendars(for: profile.id)
                profile.selectedCalendarIDs = []
                try await userService.saveProfile(profile)
                statusMessage = "Apple Calendar disconnected and imported blocks were removed."
                analyticsService.track(event: "calendar_sync_disconnected")
                return
            }

            profile.selectedCalendarIDs = selectedIDs
            try await userService.saveProfile(profile)
            _ = try await calendarSyncService.importSelectedCalendars(profile.selectedCalendarIDs, for: profile.id)
            statusMessage = "Calendar import refreshed."
            analyticsService.track(event: "calendar_sync_imported", parameters: ["count": profile.selectedCalendarIDs.count])
        } catch {
            statusMessage = AppError.wrap(error, fallback: "Unable to refresh calendar import.").errorDescription ?? ""
        }
    }

    func restorePurchases() async {
        guard !isRestoringPurchases else { return }

        isRestoringPurchases = true
        defer { isRestoringPurchases = false }

        do {
            let state = try await subscriptionService.restore(for: profile.id)
            statusMessage = state.requiresPaywall ? "No active subscription was found to restore." : "Purchases restored."
        } catch {
            statusMessage = AppError.wrap(error, fallback: "Unable to restore purchases.").errorDescription ?? ""
        }
    }

    func signOut() async {
        guard !isSigningOut else { return }

        isSigningOut = true
        defer { isSigningOut = false }

        do {
            try await authService.signOut()
        } catch {
            statusMessage = AppError.wrap(error, fallback: "Unable to sign out.").errorDescription ?? ""
        }
    }

    func deleteAccount() async {
        guard !isDeletingAccount else { return }

        isDeletingAccount = true
        defer { isDeletingAccount = false }

        do {
            try await backendFunctionService.deleteUserAccount(UserJobRequestPayload(userID: profile.id))
            try await authService.signOut()
        } catch {
            statusMessage = AppError.wrap(error, fallback: "Unable to delete the account.").errorDescription ?? ""
        }
    }

    func exportData() async {
        guard !isExportingData else { return }

        isExportingData = true
        defer { isExportingData = false }

        do {
            let export = try await backendFunctionService.exportUserData(UserJobRequestPayload(userID: profile.id))
            let encoder = JSONEncoder.appEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(export)
            exportDocument = UserDataExportDocument(data: data)
            exportFilename = Self.exportFilename(for: export.requestedAt)
            showExportFileExporter = true
            statusMessage = "Choose where to save your data export."
        } catch {
            statusMessage = AppError.wrap(error, fallback: "Unable to export your data.").errorDescription ?? ""
        }
    }

    func clearPreparedExport() {
        showExportFileExporter = false
        exportDocument = nil
    }

    private static func exportFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "ai-efficiency-export-\(formatter.string(from: date)).json"
    }
}

struct SettingsView: View {
    private let user: UserProfile
    private let container: AppContainer
    private let isPremiumLocked: Bool
    private let onRequirePremium: (PaywallTrigger) -> Void
    @StateObject private var viewModel: SettingsViewModel

    init(
        user: UserProfile,
        container: AppContainer,
        isPremiumLocked: Bool = false,
        onRequirePremium: @escaping (PaywallTrigger) -> Void = { _ in }
    ) {
        self.user = user
        self.container = container
        self.isPremiumLocked = isPremiumLocked
        self.onRequirePremium = onRequirePremium
        _viewModel = StateObject(wrappedValue: SettingsViewModel(
            user: user,
            authService: container.authService,
            userService: container.userService,
            calendarSyncService: container.calendarSyncService,
            notificationService: container.notificationService,
            subscriptionService: container.subscriptionService,
            backendFunctionService: container.backendFunctionService,
            analyticsService: container.analyticsService
        ))
    }

    var body: some View {
        List {
            Section("Profile") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.profile.displayName.ifEmpty("Student Planner"))
                        Text(viewModel.profile.email.ifEmpty("No email available"))
                            .foregroundStyle(.secondary)
                        if !viewModel.profile.academicFocus.isEmpty {
                            Text(viewModel.profile.academicFocus)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Edit") {
                        viewModel.showProfileEditor = true
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Tools") {
                NavigationLink("Reflections") {
                    ReflectionsFeature(user: viewModel.profile, container: container)
                }
                NavigationLink("Imports") {
                    ImportsFeature(
                        user: viewModel.profile,
                        container: container,
                        isPremiumLocked: isPremiumLocked,
                        onRequirePremium: onRequirePremium
                    )
                }
            }

            Section("Calendar Sync") {
                if viewModel.availableCalendars.isEmpty {
                    Text("No Apple calendars available yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.availableCalendars) { calendar in
                        Toggle(isOn: Binding(
                            get: { viewModel.selectedCalendarIDs.contains(calendar.externalID) },
                            set: { enabled in
                                if enabled {
                                    viewModel.selectedCalendarIDs.insert(calendar.externalID)
                                } else {
                                    viewModel.selectedCalendarIDs.remove(calendar.externalID)
                                }
                            }
                        )) {
                            Text(calendar.displayName)
                        }
                    }
                }

                Button {
                    Task { await viewModel.syncCalendars() }
                } label: {
                    if viewModel.isSyncingCalendars {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Refresh Apple Calendar import")
                    }
                }
                .disabled(viewModel.isSyncingCalendars)
            }

            Section("Notifications") {
                Text("Current status: \(viewModel.notificationState.rawValue.capitalized)")
                Button {
                    Task { await viewModel.requestNotifications() }
                } label: {
                    if viewModel.isRequestingNotifications {
                        ProgressView()
                    } else {
                        Text("Request notification access")
                    }
                }
                .disabled(viewModel.isRequestingNotifications)
            }

            Section("Subscription") {
                Button {
                    Task { await viewModel.restorePurchases() }
                } label: {
                    if viewModel.isRestoringPurchases {
                        ProgressView()
                    } else {
                        Text("Restore purchases")
                    }
                }
                .disabled(viewModel.isRestoringPurchases)

                VStack(alignment: .leading, spacing: 6) {
                    Text("RevenueCat App User ID")
                        .font(.subheadline.weight(.semibold))
                    Text(viewModel.profile.id)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Data") {
                Button {
                    Task { await viewModel.exportData() }
                } label: {
                    if viewModel.isExportingData {
                        ProgressView()
                    } else {
                        Text("Export My Data")
                    }
                }
                .disabled(viewModel.isExportingData || viewModel.isDeletingAccount)
            }

            Section("Account") {
                Button("Sign out", role: .destructive) {
                    viewModel.showSignOutConfirmation = true
                }
                .disabled(viewModel.isSigningOut || viewModel.isDeletingAccount)

                Button("Delete Account", role: .destructive) {
                    viewModel.showDeleteAccountConfirmation = true
                }
                .disabled(viewModel.isSigningOut || viewModel.isDeletingAccount)
            }

            if !viewModel.statusMessage.isEmpty {
                Section {
                    Text(viewModel.statusMessage)
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            await viewModel.load()
        }
        .confirmationDialog(
            "Sign out of AI Efficiency?",
            isPresented: $viewModel.showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await viewModel.signOut() }
            }
            Button("Stay Signed In", role: .cancel) {}
        } message: {
            Text("You can sign back in later without losing your saved data.")
        }
        .alert(
            "Delete Account?",
            isPresented: $viewModel.showDeleteAccountConfirmation
        ) {
            Button("Delete Account", role: .destructive) {
                Task { await viewModel.deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your goals, sessions, imports, reflections, and account data.")
        }
        .sheet(isPresented: $viewModel.showProfileEditor) {
            ProfileEditorSheet(profile: viewModel.profile) { updated in
                try await viewModel.saveProfile(updated)
            }
        }
        .fileExporter(
            isPresented: $viewModel.showExportFileExporter,
            document: viewModel.exportDocument,
            contentType: .json,
            defaultFilename: viewModel.exportFilename
        ) { result in
            switch result {
            case .success:
                viewModel.statusMessage = "Data export saved."
            case .failure(let error):
                viewModel.statusMessage = AppError.wrap(error, fallback: "Unable to save your data export.").errorDescription ?? ""
            }
            viewModel.clearPreparedExport()
        }
        .swGlassListChrome()
    }
}

struct UserDataExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var academicFocus: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let profile: UserProfile
    private let onSave: (UserProfile) async throws -> Void

    init(profile: UserProfile, onSave: @escaping (UserProfile) async throws -> Void) {
        self.profile = profile
        self.onSave = onSave
        _displayName = State(initialValue: profile.displayName)
        _academicFocus = State(initialValue: profile.academicFocus)
    }

    private var isSaveDisabled: Bool {
        isSaving || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display Name") {
                    TextField("Name", text: $displayName)
                        .disabled(isSaving)
                }
                Section("Academic Focus") {
                    TextField("e.g. pre-med, CS, design", text: $academicFocus)
                        .disabled(isSaving)
                }
                Section {
                    Text(profile.email.ifEmpty("No email"))
                        .foregroundStyle(.secondary)
                    Text("Signed in with \(profile.signInProvider)")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(isSaveDisabled)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        var updated = profile
        updated.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.academicFocus = academicFocus.trimmingCharacters(in: .whitespacesAndNewlines)

        errorMessage = nil
        isSaving = true
        do {
            try await onSave(updated)
            isSaving = false
            dismiss()
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to save profile.").errorDescription
            isSaving = false
        }
    }
}
