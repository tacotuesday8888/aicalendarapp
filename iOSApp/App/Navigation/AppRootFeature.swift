import SwiftUI
import Combine

@MainActor
final class AppSessionViewModel: ObservableObject {
    @Published private(set) var authState: LoadableState<UserProfile?> = .loading
    @Published private(set) var onboardingState = OnboardingState()
    @Published private(set) var subscriptionState = SubscriptionState.locked
    @Published private(set) var subscriptionRefreshError: String?
    @Published private(set) var isRefreshingSubscription = false
    @Published var pendingRoute: AppRoute?

    let container: AppContainer
    private var tasks = [Task<Void, Never>]()
    private var subscriptionTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
        start()
    }

    deinit {
        tasks.forEach { $0.cancel() }
        subscriptionTask?.cancel()
    }

    var currentUser: UserProfile? {
        authState.value ?? nil
    }

    func start() {
        observeAuth()
    }

    func refreshSubscription() async {
        guard let userID = currentUser?.id else {
            subscriptionState = .locked
            subscriptionRefreshError = nil
            return
        }

        guard !isRefreshingSubscription else { return }
        isRefreshingSubscription = true
        defer { isRefreshingSubscription = false }

        do {
            subscriptionState = try await container.subscriptionService.refreshStatus(for: userID)
            subscriptionRefreshError = nil
        } catch {
            container.analyticsService.record(error: error, context: "subscription_refresh")
            subscriptionRefreshError = AppError.wrap(error, fallback: "Could not check your subscription. Tap retry.").errorDescription
        }
    }

    func completeOnboarding(profile: UserProfile, onboarding: OnboardingState) async throws {
        do {
            try await container.userService.saveProfile(profile)
            try await container.userService.saveOnboardingState(onboarding, for: profile.id)
            onboardingState = onboarding
            await refreshSubscription()
            if subscriptionState.requiresPaywall {
                pendingRoute = .paywall(trigger: .onboardingComplete)
            }
            container.analyticsService.track(event: "onboarding_completed", parameters: [
                "calendarImported": onboarding.didImportCalendar,
                "syllabusImported": onboarding.didImportSyllabus
            ])
        } catch {
            let wrapped = AppError.wrap(error, fallback: "Unable to complete onboarding.")
            throw wrapped
        }
    }

    func handle(url: URL) {
        pendingRoute = container.deepLinkService.route(for: url)
        container.analyticsService.track(event: "deep_link_opened", parameters: [
            "url": url.absoluteString
        ])
    }

    private func observeAuth() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        subscriptionTask?.cancel()
        subscriptionTask = nil

        let authTask = Task {
            for await profile in container.authService.authStateStream() {
                authState = .loaded(profile)

                guard let profile else {
                    onboardingState = OnboardingState()
                    subscriptionState = .locked
                    subscriptionTask?.cancel()
                    subscriptionTask = nil
                    await container.subscriptionService.unlinkUser()
                    continue
                }

                await container.subscriptionService.linkUser(profile.id)
                await loadUserContext(for: profile)
            }
        }

        tasks.append(authTask)
    }

    private func loadUserContext(for profile: UserProfile) async {
        onboardingState = OnboardingState()
        subscriptionState = .locked
        observeSubscription(for: profile.id)

        do {
            onboardingState = try await container.userService.fetchOnboardingState(for: profile.id)
        } catch {
            onboardingState = OnboardingState()
            subscriptionState = .locked
            container.analyticsService.record(error: error, context: "load_user_context")
        }
    }

    private func observeSubscription(for userID: String) {
        subscriptionTask?.cancel()
        subscriptionTask = Task {
            for await state in container.subscriptionService.observeSubscriptionState(for: userID) {
                subscriptionState = state
            }
        }
    }
}

struct AppRootView: View {
    let container: AppContainer
    @ObservedObject var viewModel: AppSessionViewModel

    var body: some View {
        Group {
            switch viewModel.authState {
            case .idle, .loading:
                ProgressView("Preparing your planner…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .swGlassScreenBackground()
            case .failed(let error):
                ContentUnavailableView("Unable to start", systemImage: "exclamationmark.triangle", description: Text(error.errorDescription ?? "Try again."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .swGlassScreenBackground()
            case .loaded(let profile):
                if let profile {
                    if !viewModel.onboardingState.isComplete {
                        OnboardingView(
                            viewModel: OnboardingViewModel(
                                user: profile,
                                calendarSyncService: container.calendarSyncService,
                                syllabusImportService: container.syllabusImportService,
                                analyticsService: container.analyticsService,
                                notificationService: container.notificationService
                            ),
                            sessionViewModel: viewModel
                        )
                    } else {
                        AppShellView(
                            container: container,
                            sessionViewModel: viewModel
                        )
                    }
                } else {
                    AuthView(
                        viewModel: AuthViewModel(
                            authService: container.authService,
                            userService: container.userService,
                            analyticsService: container.analyticsService
                        )
                    )
                }
            }
        }
        .task {
            await viewModel.refreshSubscription()
        }
    }
}
