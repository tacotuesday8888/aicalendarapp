import SwiftUI
import Combine

@MainActor
final class PaywallViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var offers = SubscriptionOffer.fallbackOffers

    private let user: UserProfile
    private let trigger: PaywallTrigger
    private let subscriptionService: SubscriptionServicing
    private let paywallService: PaywallServicing
    private let analyticsService: AnalyticsServicing

    init(
        user: UserProfile,
        trigger: PaywallTrigger = .onboardingComplete,
        subscriptionService: SubscriptionServicing,
        paywallService: PaywallServicing,
        analyticsService: AnalyticsServicing
    ) {
        self.user = user
        self.trigger = trigger
        self.subscriptionService = subscriptionService
        self.paywallService = paywallService
        self.analyticsService = analyticsService
    }

    func prepare() async {
        paywallService.registerTriggers()
        await paywallService.handle(trigger: trigger, for: user.id)

        do {
            let liveOffers = try await subscriptionService.availableOffers()
            if !liveOffers.isEmpty {
                offers = liveOffers
            }
        } catch {
            analyticsService.record(error: error, context: "paywall_offers")
        }
    }

    func purchase(plan: SubscriptionPlan) async throws -> SubscriptionState {
        guard !isLoading else { throw AppError.unknown("Purchase already in progress.") }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        return try await subscriptionService.purchase(plan: plan, for: user.id)
    }

    func restore() async throws -> SubscriptionState {
        guard !isLoading else { throw AppError.unknown("Restore already in progress.") }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        analyticsService.track(event: "restore_tapped")
        return try await subscriptionService.restore(for: user.id)
    }

    func offer(for plan: SubscriptionPlan) -> SubscriptionOffer {
        offers.first(where: { $0.plan == plan }) ?? (plan == .monthly ? .fallbackMonthly : .fallbackAnnual)
    }

    func purchaseButtonTitle(for plan: SubscriptionPlan) -> String {
        let offer = offer(for: plan)
        switch plan {
        case .annual:
            if let trialText = offer.trialText, trialText.lowercased().contains("free") {
                return "Start annual trial"
            }
            return "Choose annual"
        case .monthly:
            return "Choose monthly"
        case .none:
            return "Choose plan"
        }
    }
}

struct PaywallView: View {
    @StateObject private var viewModel: PaywallViewModel
    let onUnlocked: () -> Void
    let refreshErrorMessage: String?
    let isRefreshing: Bool
    let onRetryRefresh: (() -> Void)?
    private let configuration = AppConfiguration.shared

    init(
        viewModel: PaywallViewModel,
        onUnlocked: @escaping () -> Void,
        refreshErrorMessage: String? = nil,
        isRefreshing: Bool = false,
        onRetryRefresh: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onUnlocked = onUnlocked
        self.refreshErrorMessage = refreshErrorMessage
        self.isRefreshing = isRefreshing
        self.onRetryRefresh = onRetryRefresh
    }

    var body: some View {
        ZStack {
            SWLiquidGlassBackground()

            VStack(alignment: .leading, spacing: 24) {
                Spacer()
                Text("Unlock your student operating system.")
                    .font(.largeTitle.bold())
                Text("AI goal plans, syllabus import, premium Today planner, reminders, and the contextual assistant live behind the subscription gate.")
                    .foregroundStyle(AppTheme.textSecondary)

                if let refreshErrorMessage, let onRetryRefresh {
                    SWGlassPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Subscription check failed", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.subheadline.bold())
                            Text(refreshErrorMessage)
                                .font(.footnote)
                                .foregroundStyle(AppTheme.textSecondary)
                            Button {
                                onRetryRefresh()
                            } label: {
                                if isRefreshing {
                                    ProgressView()
                                } else {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isRefreshing)
                        }
                    }
                }

                SWGlassPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(viewModel.offers) { offer in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Label(offer.displayName, systemImage: offer.plan == .annual ? "sparkles" : "calendar")
                                    Spacer(minLength: 12)
                                    Text(offer.priceText)
                                        .font(.subheadline.weight(.semibold))
                                }
                                Text(offer.renewalText)
                                    .font(.footnote)
                                    .foregroundStyle(AppTheme.textSecondary)
                                if let trialText = offer.trialText {
                                    Text(trialText)
                                        .font(.footnote)
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                            }
                        }

                        Label("Restore purchases anytime", systemImage: "arrow.clockwise")
                    }
                }
                .font(.headline)

                Button(viewModel.purchaseButtonTitle(for: .annual)) {
                    Task {
                        do {
                            let state = try await viewModel.purchase(plan: .annual)
                            if !state.requiresPaywall {
                                onUnlocked()
                            } else {
                                viewModel.errorMessage = "Purchase is processing. Restore purchases in a moment if Pro does not unlock automatically."
                            }
                        } catch {
                            viewModel.errorMessage = AppError.wrap(error, fallback: "Purchase failed.").errorDescription
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(SWGlassCTAButtonStyle())
                .disabled(viewModel.isLoading)

                Button(viewModel.purchaseButtonTitle(for: .monthly)) {
                    Task {
                        do {
                            let state = try await viewModel.purchase(plan: .monthly)
                            if !state.requiresPaywall {
                                onUnlocked()
                            } else {
                                viewModel.errorMessage = "Purchase is processing. Restore purchases in a moment if Pro does not unlock automatically."
                            }
                        } catch {
                            viewModel.errorMessage = AppError.wrap(error, fallback: "Purchase failed.").errorDescription
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoading)

                Button("Restore purchases") {
                    Task {
                        do {
                            let state = try await viewModel.restore()
                            if !state.requiresPaywall {
                                onUnlocked()
                            } else {
                                viewModel.errorMessage = "No active subscription found."
                            }
                        } catch {
                            viewModel.errorMessage = AppError.wrap(error, fallback: "Restore failed.").errorDescription
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)

                subscriptionDisclosure

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(24)
        }
        .task {
            await viewModel.prepare()
        }
    }

    private var subscriptionDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Payment is charged to your Apple ID at confirmation. Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period. Manage or cancel in App Store account settings.")
            HStack(spacing: 12) {
                if let termsOfServiceURL = configuration.termsOfServiceURL {
                    Link("Terms", destination: termsOfServiceURL)
                }
                if let privacyPolicyURL = configuration.privacyPolicyURL {
                    Link("Privacy Policy", destination: privacyPolicyURL)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(AppTheme.textSecondary)
    }
}
