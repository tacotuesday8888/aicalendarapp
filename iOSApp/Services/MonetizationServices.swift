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

enum SubscriptionStateResolver {
    static func resolveBackendState(
        backendState: SubscriptionState?,
        localState: SubscriptionState,
        previousState: SubscriptionState
    ) -> SubscriptionState {
        if let backendState {
            return backendState
        }

        if localState.entitlement == .active {
            return previousState.entitlement == .active ? previousState : .locked
        }

        return localState
    }

    static func pendingPaidAccessState(previousState: SubscriptionState) -> SubscriptionState {
        previousState.entitlement == .active ? previousState : .locked
    }
}

actor LinkedSubscriptionIdentityStore {
    private var linkedUserID: String?
    private var pendingUserID: String?

    func isLinked(to userID: String) -> Bool {
        linkedUserID == userID
    }

    func hasKnownUser() -> Bool {
        linkedUserID != nil || pendingUserID != nil
    }

    func markPending(_ userID: String) {
        pendingUserID = userID
    }

    func markLinked(_ userID: String) {
        linkedUserID = userID
        pendingUserID = nil
    }

    func currentLinkedUserID() -> String? {
        linkedUserID
    }

    func markUnlinked() {
        linkedUserID = nil
        pendingUserID = nil
    }
}

final class SubscriptionService: SubscriptionServicing {
    static let shared = SubscriptionService()

    var analyticsService: AnalyticsServicing?
    var backendFunctionService: BackendFunctionServicing?
    private let paidAccessConfirmationRetryDelaysNanoseconds: [UInt64]
    private let store = LocalSubscriptionStore()
    private let identityStore = LinkedSubscriptionIdentityStore()
    private let logger = AppLogger(category: "subscription-identity")

    init(paidAccessConfirmationRetryDelaysNanoseconds: [UInt64] = [1_000_000_000, 2_000_000_000]) {
        self.paidAccessConfirmationRetryDelaysNanoseconds = paidAccessConfirmationRetryDelaysNanoseconds
    }

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
        let previousState = await store.currentState(for: userID)
        #if canImport(RevenueCat)
        guard Purchases.isConfigured else {
            if let backendState = await syncBackendSubscriptionStatus(for: userID) {
                await store.set(backendState, for: userID)
                await syncSuperwallSubscriptionStatus(backendState)
                return backendState
            }
            try ensureRevenueCatConfigured()
            return previousState
        }

        let customerInfo = try await fetchCustomerInfo()
        let offerings = try? await fetchOfferings()
        let mapped = map(customerInfo, currentOffering: offerings?.current, fallbackPlan: previousState.activePlan)
        let resolved = SubscriptionStateResolver.resolveBackendState(
            backendState: await syncBackendSubscriptionStatus(for: userID),
            localState: mapped,
            previousState: previousState
        )
        await store.set(resolved, for: userID)
        await syncSuperwallSubscriptionStatus(resolved)
        return resolved
        #else
        if let backendState = await syncBackendSubscriptionStatus(for: userID) {
            await store.set(backendState, for: userID)
            await syncSuperwallSubscriptionStatus(backendState)
            return backendState
        }
        await syncSuperwallSubscriptionStatus(previousState)
        return previousState
        #endif
    }

    func purchase(plan: SubscriptionPlan, for userID: String) async throws -> SubscriptionState {
        #if canImport(RevenueCat)
        try ensureRevenueCatConfigured()
        try await ensureRevenueCatUserLinked(userID)
        let previousState = await store.currentState(for: userID)
        let offerings = try await fetchOfferings()

        guard
            let current = offerings.current,
            let package = package(for: plan, currentOffering: current)
        else {
            throw AppError.dataNotFound
        }

        let customerInfo = try await purchase(package: package)

        let mapped = map(customerInfo, currentOffering: current, fallbackPlan: plan)
        let state: SubscriptionState
        do {
            state = try await requireBackendConfirmation(for: userID, localState: mapped)
            analyticsService?.track(event: "subscription_purchased", parameters: [
                "plan": plan.rawValue,
                "backend_confirmed": true
            ])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            analyticsService?.record(error: error, context: "subscription_purchase_backend_confirmation")
            analyticsService?.track(event: "subscription_purchased", parameters: [
                "plan": plan.rawValue,
                "backend_confirmed": false
            ])
            state = SubscriptionStateResolver.pendingPaidAccessState(previousState: previousState)
        }
        await store.set(state, for: userID)
        await syncSuperwallSubscriptionStatus(state)
        return state
        #else
        throw AppError.integrationUnavailable("RevenueCat")
        #endif
    }

    func restore(for userID: String) async throws -> SubscriptionState {
        #if canImport(RevenueCat)
        try ensureRevenueCatConfigured()
        try await ensureRevenueCatUserLinked(userID)
        let previousState = await store.currentState(for: userID)
        let customerInfo = try await restorePurchases()
        let offerings = try? await fetchOfferings()
        let mapped = map(customerInfo, currentOffering: offerings?.current, fallbackPlan: previousState.activePlan)
        let state = try await requireBackendConfirmation(for: userID, localState: mapped)
        await store.set(state, for: userID)
        await syncSuperwallSubscriptionStatus(state)
        return state
        #else
        throw AppError.integrationUnavailable("RevenueCat")
        #endif
    }

    func linkUser(_ userID: String) async {
        let currentLinkedUserID = await identityStore.currentLinkedUserID()

        #if canImport(RevenueCat)
        if currentLinkedUserID == userID, Purchases.isConfigured, Purchases.shared.appUserID.trimmingCharacters(in: .whitespacesAndNewlines) == userID {
            return
        }

        guard Purchases.isConfigured else {
            logger.notice("linkUser called before RevenueCat was configured; skipping.")
            identifySuperwallUser(userID)
            await identityStore.markPending(userID)
            return
        }
        do {
            try await ensureRevenueCatUserLinked(userID)
        } catch {
            analyticsService?.record(error: error, context: "subscription_link_user")
        }
        #else
        identifySuperwallUser(userID)
        await identityStore.markLinked(userID)
        #endif
    }

    func unlinkUser() async {
        let hasKnownUser = await identityStore.hasKnownUser()
        guard hasKnownUser else { return }

        #if canImport(RevenueCat)
        guard Purchases.isConfigured else {
            resetSuperwallUser()
            await identityStore.markUnlinked()
            return
        }
        do {
            guard !Purchases.shared.isAnonymous else {
                resetSuperwallUser()
                await identityStore.markUnlinked()
                return
            }

            _ = try await Purchases.shared.logOut()
            resetSuperwallUser()
            await identityStore.markUnlinked()
            analyticsService?.track(event: "subscription_user_unlinked")
        } catch {
            resetSuperwallUser()
            analyticsService?.record(error: error, context: "subscription_unlink_user")
        }
        #else
        resetSuperwallUser()
        await identityStore.markUnlinked()
        #endif
    }

    func prepareForPaidAccess(for userID: String) async throws {
        #if canImport(RevenueCat)
        try ensureRevenueCatConfigured()
        try await ensureRevenueCatUserLinked(userID)
        #else
        throw AppError.integrationUnavailable("RevenueCat")
        #endif
    }

    func confirmPaidAccess(for userID: String) async throws -> SubscriptionState {
        var lastInactiveState: SubscriptionState?
        var lastError: Error?
        let attemptCount = paidAccessConfirmationRetryDelaysNanoseconds.count + 1

        for attemptIndex in 0..<attemptCount {
            do {
                let state = try await syncBackendSubscriptionStatusOrThrow(for: userID)
                guard state.entitlement == .active else {
                    lastInactiveState = state
                    lastError = nil
                    try await sleepBeforeNextPaidAccessConfirmationAttempt(attemptIndex)
                    continue
                }

                await store.set(state, for: userID)
                await syncSuperwallSubscriptionStatus(state)
                return state
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try await sleepBeforeNextPaidAccessConfirmationAttempt(attemptIndex)
            }
        }

        if let lastError, lastInactiveState == nil {
            throw lastError
        }

        throw AppError.network(description: "Your purchase was processed, but Pro access has not been confirmed on the server yet. Try restoring purchases in a moment.")
    }

    private func syncBackendSubscriptionStatus(for userID: String) async -> SubscriptionState? {
        do {
            return try await syncBackendSubscriptionStatusOrThrow(for: userID)
        } catch {
            analyticsService?.record(error: error, context: "subscription_backend_sync")
            return nil
        }
    }

    private func syncBackendSubscriptionStatusOrThrow(for userID: String) async throws -> SubscriptionState {
        guard let backendFunctionService else {
            throw AppError.integrationUnavailable("Firebase Functions")
        }

        return try await backendFunctionService.syncSubscriptionStatus(UserJobRequestPayload(userID: userID))
    }

    private func requireBackendConfirmation(for userID: String, localState: SubscriptionState) async throws -> SubscriptionState {
        guard localState.entitlement == .active else {
            return await syncBackendSubscriptionStatus(for: userID) ?? localState
        }

        return try await confirmPaidAccess(for: userID)
    }

    private func sleepBeforeNextPaidAccessConfirmationAttempt(_ attemptIndex: Int) async throws {
        guard attemptIndex < paidAccessConfirmationRetryDelaysNanoseconds.count else { return }
        try await Task.sleep(nanoseconds: paidAccessConfirmationRetryDelaysNanoseconds[attemptIndex])
    }

    #if canImport(RevenueCat)
    private var revenueCatEntitlementID: String {
        AppConfiguration.shared.revenueCatEntitlementID
    }

    private func ensureRevenueCatConfigured() throws {
        guard Purchases.isConfigured else {
            throw AppError.integrationUnavailable("RevenueCat")
        }
    }

    private func ensureRevenueCatUserLinked(_ userID: String) async throws {
        let revenueCatUserID = Purchases.shared.appUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        if revenueCatUserID == userID {
            identifySuperwallUser(userID)
            await identityStore.markLinked(userID)
            return
        }

        let currentLinkedUserID = await identityStore.currentLinkedUserID()
        let isSwitchingUser = currentLinkedUserID != nil || !Purchases.shared.isAnonymous
        let result = try await Purchases.shared.logIn(userID)
        if isSwitchingUser {
            resetSuperwallUser()
        }
        identifySuperwallUser(userID)
        await identityStore.markLinked(userID)
        analyticsService?.track(event: "subscription_user_linked", parameters: [
            "created": result.created,
            "switched": isSwitchingUser
        ])
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
        let entitlement = customerInfo.entitlements[revenueCatEntitlementID]
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

    private func identifySuperwallUser(_ userID: String) {
        #if canImport(SuperwallKit)
        guard AppConfiguration.validateSuperwallAPIKey(AppConfiguration.shared.superwallAPIKey) == .valid else {
            return
        }
        Superwall.shared.identify(userId: userID)
        Superwall.shared.setUserAttributes([
            "firebase_uid": userID,
            "revenuecat_app_user_id": userID
        ])
        #endif
    }

    private func resetSuperwallUser() {
        #if canImport(SuperwallKit)
        guard AppConfiguration.validateSuperwallAPIKey(AppConfiguration.shared.superwallAPIKey) == .valid else {
            return
        }
        Superwall.shared.subscriptionStatus = .inactive
        Superwall.shared.reset()
        #endif
    }

    private func syncSuperwallSubscriptionStatus(_ state: SubscriptionState) async {
        #if canImport(SuperwallKit)
        guard AppConfiguration.validateSuperwallAPIKey(AppConfiguration.shared.superwallAPIKey) == .valid else {
            return
        }

        let entitlementID = AppConfiguration.shared.revenueCatEntitlementID
        await MainActor.run {
            Superwall.shared.subscriptionStatus = state.entitlement == .active
                ? .active([Entitlement(id: entitlementID)])
                : .inactive
        }
        #endif
    }
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
        guard
            let configuration,
            AppConfiguration.validateSuperwallAPIKey(configuration.superwallAPIKey) == .valid
        else {
            return
        }
        Superwall.shared.register(
            placement: trigger.rawValue,
            params: ["user_id": userID ?? "guest"]
        )
        #endif
    }
}
