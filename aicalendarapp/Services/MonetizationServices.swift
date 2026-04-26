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

    func refreshStatus(for userID: String) async throws -> SubscriptionState {
        #if canImport(RevenueCat)
        let previousState = await store.currentState(for: userID)
        let customerInfo = try await fetchCustomerInfo()
        let offerings = try? await fetchOfferings()
        let mapped = map(customerInfo, currentOffering: offerings?.current, fallbackPlan: previousState.activePlan)
        await store.set(mapped, for: userID)
        return mapped
        #else
        return await store.currentState(for: userID)
        #endif
    }

    func purchase(plan: SubscriptionPlan, for userID: String) async throws -> SubscriptionState {
        #if canImport(RevenueCat)
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
        return state
        #else
        let state = SubscriptionState(entitlement: .active, activePlan: plan, trialEligible: false, lastSyncedAt: .now)
        analyticsService?.track(event: "subscription_unlocked_locally", parameters: ["plan": plan.rawValue])
        await store.set(state, for: userID)
        return state
        #endif
    }

    func restore(for userID: String) async throws -> SubscriptionState {
        #if canImport(RevenueCat)
        let previousState = await store.currentState(for: userID)
        let customerInfo = try await restorePurchases()
        let offerings = try? await fetchOfferings()
        let state = map(customerInfo, currentOffering: offerings?.current, fallbackPlan: previousState.activePlan)
        await store.set(state, for: userID)
        return state
        #else
        let state = SubscriptionState.unlocked
        await store.set(state, for: userID)
        return state
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

    #if canImport(RevenueCat)
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
