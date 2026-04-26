import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer.live()

    let configuration: AppConfiguration
    let analyticsService: AnalyticsServicing
    let authService: AuthServicing
    let userService: UserServicing
    let goalService: GoalServicing
    let plannerService: PlannerServicing
    let calendarSyncService: CalendarSyncServicing
    let studySessionService: StudySessionServicing
    let reflectionService: ReflectionServicing
    let assistantService: AssistantServicing
    let backendFunctionService: BackendFunctionServicing
    let aiBackendService: AIBackendServicing
    let syllabusImportService: SyllabusImportServicing
    let notificationService: NotificationServicing
    let subscriptionService: SubscriptionServicing
    let paywallService: PaywallServicing
    let databaseService: DatabaseServicing
    let storageService: StorageServicing
    let networkService: NetworkServicing
    let deepLinkService: DeepLinkServicing

    init(
        configuration: AppConfiguration,
        analyticsService: AnalyticsServicing,
        authService: AuthServicing,
        userService: UserServicing,
        goalService: GoalServicing,
        plannerService: PlannerServicing,
        calendarSyncService: CalendarSyncServicing,
        studySessionService: StudySessionServicing,
        reflectionService: ReflectionServicing,
        assistantService: AssistantServicing,
        backendFunctionService: BackendFunctionServicing,
        aiBackendService: AIBackendServicing,
        syllabusImportService: SyllabusImportServicing,
        notificationService: NotificationServicing,
        subscriptionService: SubscriptionServicing,
        paywallService: PaywallServicing,
        databaseService: DatabaseServicing,
        storageService: StorageServicing,
        networkService: NetworkServicing,
        deepLinkService: DeepLinkServicing
    ) {
        self.configuration = configuration
        self.analyticsService = analyticsService
        self.authService = authService
        self.userService = userService
        self.goalService = goalService
        self.plannerService = plannerService
        self.calendarSyncService = calendarSyncService
        self.studySessionService = studySessionService
        self.reflectionService = reflectionService
        self.assistantService = assistantService
        self.backendFunctionService = backendFunctionService
        self.aiBackendService = aiBackendService
        self.syllabusImportService = syllabusImportService
        self.notificationService = notificationService
        self.subscriptionService = subscriptionService
        self.paywallService = paywallService
        self.databaseService = databaseService
        self.storageService = storageService
        self.networkService = networkService
        self.deepLinkService = deepLinkService
    }

    static func live() -> AppContainer {
        let configuration = AppConfiguration.shared
        let analyticsService = AnalyticsService.shared
        let databaseService = DatabaseService.shared
        let storageService = StorageService.shared
        let networkService = NetworkService.shared
        let backendFunctionService = BackendFunctionService.shared
        let aiBackendService = AIBackendService.shared
        let notificationService = NotificationService.shared
        let deepLinkService = DeepLinkService.shared
        let authService = AuthService.shared
        let userService = UserService.shared
        let goalService = GoalService.shared
        let plannerService = PlannerService.shared
        let calendarSyncService = CalendarSyncService.shared
        let studySessionService = StudySessionService.shared
        let reflectionService = ReflectionService.shared
        let assistantService = AssistantService.shared
        let syllabusImportService = SyllabusImportService.shared
        let subscriptionService = SubscriptionService.shared
        let paywallService = PaywallService.shared

        AuthService.shared.databaseService = databaseService
        AuthService.shared.userService = userService
        UserService.shared.databaseService = databaseService
        GoalService.shared.databaseService = databaseService
        GoalService.shared.backendFunctionService = backendFunctionService
        PlannerService.shared.databaseService = databaseService
        CalendarSyncService.shared.databaseService = databaseService
        StudySessionService.shared.databaseService = databaseService
        ReflectionService.shared.databaseService = databaseService
        AssistantService.shared.databaseService = databaseService
        AssistantService.shared.backendFunctionService = backendFunctionService
        SyllabusImportService.shared.databaseService = databaseService
        SyllabusImportService.shared.storageService = storageService
        SyllabusImportService.shared.backendFunctionService = backendFunctionService
        BackendFunctionService.shared.networkService = networkService
        BackendFunctionService.shared.databaseService = databaseService
        BackendFunctionService.shared.storageService = storageService
        AIBackendService.shared.networkService = networkService
        NotificationService.shared.authService = authService
        NotificationService.shared.databaseService = databaseService
        NotificationService.shared.userService = userService
        SubscriptionService.shared.analyticsService = analyticsService
        PaywallService.shared.subscriptionService = subscriptionService
        PaywallService.shared.analyticsService = analyticsService
        PaywallService.shared.configuration = configuration

        return AppContainer(
            configuration: configuration,
            analyticsService: analyticsService,
            authService: authService,
            userService: userService,
            goalService: goalService,
            plannerService: plannerService,
            calendarSyncService: calendarSyncService,
            studySessionService: studySessionService,
            reflectionService: reflectionService,
            assistantService: assistantService,
            backendFunctionService: backendFunctionService,
            aiBackendService: aiBackendService,
            syllabusImportService: syllabusImportService,
            notificationService: notificationService,
            subscriptionService: subscriptionService,
            paywallService: paywallService,
            databaseService: databaseService,
            storageService: storageService,
            networkService: networkService,
            deepLinkService: deepLinkService
        )
    }
}
