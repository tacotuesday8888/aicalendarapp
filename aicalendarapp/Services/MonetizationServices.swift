import Foundation
#if canImport(RevenueCat)
import RevenueCat
#endif
#if canImport(SuperwallKit)
import SuperwallKit
#endif

actor LocalSubscriptionStore {
    private var states = [String: SubscriptionState]()
    private var continuations = [String: [UUID: AsyncStream<SubscriptionState>.Continuation]]()

    func currentState(for userID: String) -> SubscriptionState {
        states[userID] ?? SubscriptionState.locked
    }

    func set(_ state: SubscriptionState, for userID: String) {
        states[userID] = state
        continuations[userID]?.values.forEach { $0.yield(state) }
    }

    func observe(for userID: String) -> AsyncStream<SubscriptionState> {
        let token = UUID()
        return AsyncStream { continuation in
            continuations[userID, default: [:]][token] = continuation
            continuation.yield(states[userID] ?? SubscriptionState.locked)
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(for: userID, token: token) }
            }
        }
    }

    private func removeContinuation(for userID: String, token: UUID) {
        continuations[userID]?[token] = nil
    }
}

actor LinkedSubscriptionIdentityStore {
    private var linkedUserID: String?

    func link(_ userID: String) -> Bool {
        let alreadyLinked = linkedUserID == userID
        linkedUserID = userID
        return alreadyLinked
    }

    func unlink() -> Bool {
        let wasLinked = linkedUserID != nil
        linkedUserID = nil
        return wasLinked
    }
}

final class SubscriptionService: SubscriptionServicing {
    static let shared = SubscriptionService()
    private static let revenueCatEntitlementID = "aiefficiencyapp Pro"

    var analyticsService: AnalyticsServicing?
    var backendFunctionService: BackendFunctionServicing?
    private let store = LocalSubscriptionStore()
    private let identityStore = LinkedSubscriptionIdentityStore()
    private let logger = AppLogger(category: "subscription-identity")

    func observeSubscriptionState(for userID: String) -> AsyncStream<SubscriptionState> {
        AsyncStream { continuation in
            let task = Task {
                for await state in await store.observe(for: userID) {
                    continuation.yield(state)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func availableOffers() async throws -> [SubscriptionOffer] {
        #if canImport(RevenueCat)
        try ensureRevenueCatConfigured()
        let offerings = try await fetchOfferings()
        guard let current = offerings.current else {
            throw AppError.dataNotFound
        }

        return [
            current.annual.map { offer(for: .annual, package: $0) },
            current.monthly.map { offer(for: .monthly, package: $0) }
        ].compactMap { $0 }
        #else
        throw AppError.integrationUnavailable("RevenueCat")
        #endif
    }

    func refreshStatus(for userID: String) async throws -> SubscriptionState {
        #if canImport(RevenueCat)
        try ensureRevenueCatConfigured()
        let previousState = await store.currentState(for: userID)
        let customerInfo = try await fetchCustomerInfo()
        let offerings = try? await fetchOfferings()
        let mapped = map(customerInfo, currentOffering: offerings?.current, fallbackPlan: previousState.activePlan)
        await store.set(mapped, for: userID)
        await syncBackendSubscriptionStatus(for: userID)
        return mapped
        #else
        return await store.currentState(for: userID)
        #endif
    }

    func purchase(plan: SubscriptionPlan, for userID: String) async throws -> SubscriptionState {
        #if canImport(RevenueCat)
        try ensureRevenueCatConfigured()
        let offerings = try await fetchOfferings()

        guard
            let current = offerings.current,
            let package = package(for: plan, currentOffering: current)
        else {
            throw AppError.dataNotFound
        }

        let customerInfo = try await purchase(package: package)

        let state = map(customerInfo, currentOffering: current, fallbackPlan: plan)
        analyticsService?.track(event: "subscription_purchased", parameters: ["plan": plan.rawValue])
        await store.set(state, for: userID)
        await syncBackendSubscriptionStatus(for: userID)
        return state
        #else
        throw AppError.integrationUnavailable("RevenueCat")
        #endif
    }

    func restore(for userID: String) async throws -> SubscriptionState {
        #if canImport(RevenueCat)
        try ensureRevenueCatConfigured()
        let previousState = await store.currentState(for: userID)
        let customerInfo = try await restorePurchases()
        let offerings = try? await fetchOfferings()
        let state = map(customerInfo, currentOffering: offerings?.current, fallbackPlan: previousState.activePlan)
        await store.set(state, for: userID)
        await syncBackendSubscriptionStatus(for: userID)
        return state
        #else
        throw AppError.integrationUnavailable("RevenueCat")
        #endif
    }

    func linkUser(_ userID: String) async {
        let alreadyLinked = await identityStore.link(userID)
        guard !alreadyLinked else { return }

        #if canImport(RevenueCat)
        guard Purchases.isConfigured else {
            logger.notice("linkUser called before RevenueCat was configured; skipping.")
            return
        }
        do {
            let result = try await Purchases.shared.logIn(userID)
            analyticsService?.track(event: "subscription_user_linked", parameters: [
                "created": result.created
            ])
        } catch {
            analyticsService?.record(error: error, context: "subscription_link_user")
        }
        #endif
    }

    func unlinkUser() async {
        let wasLinked = await identityStore.unlink()
        guard wasLinked else { return }

        #if canImport(RevenueCat)
        guard Purchases.isConfigured else { return }
        do {
            _ = try await Purchases.shared.logOut()
            analyticsService?.track(event: "subscription_user_unlinked")
        } catch {
            analyticsService?.record(error: error, context: "subscription_unlink_user")
        }
        #endif
    }

    private func syncBackendSubscriptionStatus(for userID: String) async {
        guard let backendFunctionService else { return }

        do {
            try await backendFunctionService.syncSubscriptionStatus(UserJobRequestPayload(userID: userID))
        } catch {
            analyticsService?.record(error: error, context: "subscription_backend_sync")
        }
    }

    #if canImport(RevenueCat)
    private func ensureRevenueCatConfigured() throws {
        guard Purchases.isConfigured else {
            throw AppError.integrationUnavailable("RevenueCat")
        }
    }

    private func fetchCustomerInfo() async throws -> RevenueCat.CustomerInfo {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RevenueCat.CustomerInfo, Error>) in
            Purchases.shared.getCustomerInfo { customerInfo, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let customerInfo {
                    continuation.resume(returning: customerInfo)
                } else {
                    continuation.resume(throwing: AppError.dataNotFound)
                }
            }
        }
    }

    private func fetchOfferings() async throws -> RevenueCat.Offerings {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RevenueCat.Offerings, Error>) in
            Purchases.shared.getOfferings { offerings, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let offerings {
                    continuation.resume(returning: offerings)
                } else {
                    continuation.resume(throwing: AppError.dataNotFound)
                }
            }
        }
    }

    private func purchase(package: RevenueCat.Package) async throws -> RevenueCat.CustomerInfo {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RevenueCat.CustomerInfo, Error>) in
            Purchases.shared.purchase(package: package) { _, customerInfo, error, userCancelled in
                if userCancelled {
                    continuation.resume(throwing: AppError.unknown("Purchase was cancelled."))
                } else if let error {
                    continuation.resume(throwing: error)
                } else if let customerInfo {
                    continuation.resume(returning: customerInfo)
                } else {
                    continuation.resume(throwing: AppError.dataNotFound)
                }
            }
        }
    }

    private func restorePurchases() async throws -> RevenueCat.CustomerInfo {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RevenueCat.CustomerInfo, Error>) in
            Purchases.shared.restorePurchases { customerInfo, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let customerInfo {
                    continuation.resume(returning: customerInfo)
                } else {
                    continuation.resume(throwing: AppError.dataNotFound)
                }
            }
        }
    }

    private func map(
        _ customerInfo: RevenueCat.CustomerInfo,
        currentOffering: RevenueCat.Offering?,
        fallbackPlan: SubscriptionPlan
    ) -> SubscriptionState {
        let entitlement = customerInfo.entitlements[Self.revenueCatEntitlementID]
        let isActive = entitlement?.isActive == true

        let activePlan: SubscriptionPlan
        if isActive, let productID = entitlement?.productIdentifier {
            activePlan = resolvePlan(
                for: productID,
                currentOffering: currentOffering,
                fallbackPlan: fallbackPlan
            )
        } else {
            activePlan = .none
        }

        return SubscriptionState(
            entitlement: isActive ? .active : .inactive,
            activePlan: activePlan,
            trialEligible: !isActive,
            lastSyncedAt: .now
        )
    }

    private func resolvePlan(
        for productID: String,
        currentOffering: RevenueCat.Offering?,
        fallbackPlan: SubscriptionPlan
    ) -> SubscriptionPlan {
        guard let currentOffering else { return fallbackPlan }

        if currentOffering.monthly?.storeProduct.productIdentifier == productID {
            return .monthly
        }

        if currentOffering.annual?.storeProduct.productIdentifier == productID {
            return .annual
        }

        return fallbackPlan
    }

    private func package(for plan: SubscriptionPlan, currentOffering: RevenueCat.Offering) -> RevenueCat.Package? {
        switch plan {
        case .monthly:
            currentOffering.monthly
        case .annual:
            currentOffering.annual
        case .none:
            nil
        }
    }

    private func offer(for plan: SubscriptionPlan, package: RevenueCat.Package) -> SubscriptionOffer {
        let product = package.storeProduct
        return SubscriptionOffer(
            plan: plan,
            displayName: displayName(for: plan),
            priceText: package.localizedPriceString,
            renewalText: renewalText(for: product.subscriptionPeriod),
            trialText: trialText(for: product.introductoryDiscount),
            productID: product.productIdentifier
        )
    }

    private func displayName(for plan: SubscriptionPlan) -> String {
        switch plan {
        case .annual:
            return "Annual"
        case .monthly:
            return "Monthly"
        case .none:
            return "Subscription"
        }
    }

    private func renewalText(for period: RevenueCat.SubscriptionPeriod?) -> String {
        guard let period else {
            return "Renews automatically unless canceled."
        }
        return "Renews every \(periodDescription(period)) until canceled."
    }

    private func trialText(for discount: RevenueCat.StoreProductDiscount?) -> String? {
        guard let discount else {
            return nil
        }

        let period = periodDescription(discount.subscriptionPeriod)
        if discount.price == 0 {
            return "Free for \(period), then renews automatically."
        }
        return "Intro offer: \(discount.localizedPriceString) for \(period)."
    }

    private func periodDescription(_ period: RevenueCat.SubscriptionPeriod) -> String {
        let unit = unitName(for: period.unit, plural: period.value != 1)
        return period.value == 1 ? unit : "\(period.value) \(unit)"
    }

    private func unitName(for unit: RevenueCat.SubscriptionPeriod.Unit, plural: Bool) -> String {
        switch unit {
        case .day:
            return plural ? "days" : "day"
        case .week:
            return plural ? "weeks" : "week"
        case .month:
            return plural ? "months" : "month"
        case .year:
            return plural ? "years" : "year"
        @unknown default:
            return plural ? "periods" : "period"
        }
    }
    #endif
}

final class PaywallService: PaywallServicing {
    static let shared = PaywallService()

    var subscriptionService: SubscriptionServicing?
    var analyticsService: AnalyticsServicing?
    var configuration: AppConfiguration?

    func registerTriggers() {
        PaywallTrigger.allCases.forEach {
            analyticsService?.track(event: "paywall_trigger_registered", parameters: ["trigger": $0.rawValue])
        }
    }

    func handle(trigger: PaywallTrigger, for userID: String?) async {
        analyticsService?.track(event: "paywall_requested", parameters: ["trigger": trigger.rawValue])

        #if canImport(SuperwallKit)
        guard let configuration, !configuration.superwallAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        Superwall.shared.register(
            placement: trigger.rawValue,
            params: ["user_id": userID ?? "guest"]
        )
        #endif
    }
}
