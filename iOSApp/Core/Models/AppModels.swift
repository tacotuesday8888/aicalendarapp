import Foundation

enum AppTab: String, CaseIterable, Codable, Hashable, Sendable {
    case today
    case goals
    case calendar
    case sessions
    case settings

    var title: String {
        switch self {
        case .today: "Today"
        case .goals: "Goals"
        case .calendar: "Calendar"
        case .sessions: "Sessions"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "sun.max.fill"
        case .goals: "flag.2.crossed.fill"
        case .calendar: "calendar"
        case .sessions: "timer"
        case .settings: "gearshape.fill"
        }
    }
}

enum GoalPriority: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case critical
}

enum GoalCategory: String, Codable, CaseIterable, Sendable {
    case academic
    case career
    case wellness
    case routine
    case personal
}

enum CheckInMoment: String, Codable, CaseIterable, Sendable {
    case morning
    case midday
    case night
    case vibe
}

enum MoodLevel: String, Codable, CaseIterable, Sendable {
    case great
    case okay
    case stressed
    case overwhelmed
}

enum EnergyLevel: String, Codable, CaseIterable, Sendable {
    case high
    case steady
    case low
}

enum StressLevel: String, Codable, CaseIterable, Sendable {
    case calm
    case focused
    case tense
    case overloaded
}

enum GoalStatus: String, Codable, CaseIterable, Sendable {
    case active
    case completed
    case paused
}

enum PlannerBlockType: String, Codable, CaseIterable, Sendable {
    case classEvent
    case task
    case studySession
    case habit
    case reminder
    case wellbeing
}

enum StudySessionStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case active
    case completed
    case cancelled
}

enum NotificationPermissionState: String, Codable, CaseIterable, Sendable {
    case unknown
    case denied
    case authorized
    case provisional
}

enum SyncProvider: String, Codable, CaseIterable, Sendable {
    case app
    case appleCalendar
    case googleCalendar
}

enum SyncDirection: String, Codable, CaseIterable, Sendable {
    case importOnly
    case exportOnly
    case bidirectional
}

enum ImportStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case processing
    case completed
    case committed
    case failed
}

enum SubscriptionPlan: String, Codable, CaseIterable, Sendable {
    case none
    case monthly
    case annual
}

struct SubscriptionOffer: Codable, Hashable, Identifiable, Sendable {
    var plan: SubscriptionPlan
    var displayName: String
    var priceText: String
    var renewalText: String
    var trialText: String?
    var productID: String?

    var id: String { plan.rawValue }

    nonisolated static let fallbackAnnual = SubscriptionOffer(
        plan: .annual,
        displayName: "Annual",
        priceText: "Price shown at checkout",
        renewalText: "Renews yearly until canceled.",
        trialText: "Free trial eligibility is confirmed by the App Store.",
        productID: nil
    )

    nonisolated static let fallbackMonthly = SubscriptionOffer(
        plan: .monthly,
        displayName: "Monthly",
        priceText: "Price shown at checkout",
        renewalText: "Renews monthly until canceled.",
        trialText: nil,
        productID: nil
    )

    nonisolated static let fallbackOffers = [fallbackAnnual, fallbackMonthly]
}

enum EntitlementState: String, Codable, CaseIterable, Sendable {
    case unknown
    case inactive
    case active
}

enum AssistantDraftKind: String, Codable, CaseIterable, Sendable {
    case goalPlan
    case plannerAdjustment
    case sessionEvaluation
    case checkInSummary
}

enum PaywallTrigger: String, Codable, CaseIterable, Sendable {
    case onboardingComplete = "onboarding_complete"
    case premiumTodayPlanner = "premium_today_planner"
    case premiumGoalPlan = "premium_goal_plan"
    case premiumSyllabusImport = "premium_syllabus_import"
    case premiumAssistant = "premium_assistant"
    case premiumRestore = "premium_restore"
}

enum PremiumFeature: String, Codable, CaseIterable, Sendable {
    case assistant
    case goalPlan
    case syllabusImport

    var paywallTrigger: PaywallTrigger {
        switch self {
        case .assistant: .premiumAssistant
        case .goalPlan: .premiumGoalPlan
        case .syllabusImport: .premiumSyllabusImport
        }
    }
}

enum AppRoute: Hashable, Sendable {
    case today
    case goal(id: String)
    case session(id: String)
    case assistant(threadID: String?)
    case paywall(trigger: PaywallTrigger)
    case importedSyllabus(jobID: String)
}

enum AppCollection: String, Codable, CaseIterable, Sendable {
    case users
    case goals
    case goalPlans
    case plannerBlocks
    case courses
    case assignments
    case habits
    case studySessions
    case checkIns
    case vibeChecks
    case assistantThreads
    case imports
    case reminderRules
    case onboarding
    case subscriptions
    case aiUsageLogs
    case assistantDraftArtifacts
}

struct UserProfile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var email: String
    var displayName: String
    var academicFocus: String
    var signInProvider: String
    var assistantOptIn: Bool
    var selectedCalendarIDs: [String]
    var pushToken: String? = nil
    var createdAt: Date

    static let empty = UserProfile(
        id: UUID().uuidString,
        email: "",
        displayName: "",
        academicFocus: "",
        signInProvider: "email",
        assistantOptIn: true,
        selectedCalendarIDs: [],
        pushToken: nil,
        createdAt: .now
    )
}

struct ReminderRule: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var hour: Int
    var minute: Int
    var target: String
    var enabled: Bool = true
}

struct OnboardingState: Codable, Hashable, Sendable {
    var didCompleteProfile = false
    var didImportCalendar = false
    var didImportSyllabus = false
    var selectedFocusAreas = [String]()
    var reminderRules: [ReminderRule] = ReminderRule.defaultRules
    var completedAt: Date?

    var isComplete: Bool {
        didCompleteProfile && completedAt != nil
    }
}

struct SubscriptionState: Codable, Hashable, Sendable {
    var entitlement: EntitlementState
    var activePlan: SubscriptionPlan
    var trialEligible: Bool
    var lastSyncedAt: Date

    var requiresPaywall: Bool {
        #if DEBUG && targetEnvironment(simulator)
        // Local development bypass for testing gated AI workflows without starting a purchase flow.
        return false
        #else
        entitlement != .active
        #endif
    }

    func paywallTrigger(for feature: PremiumFeature, honoringDebugBypass: Bool = true) -> PaywallTrigger? {
        let isLocked = honoringDebugBypass ? requiresPaywall : entitlement != .active
        return isLocked ? feature.paywallTrigger : nil
    }

    nonisolated static var locked: SubscriptionState {
        SubscriptionState(entitlement: .inactive, activePlan: .none, trialEligible: true, lastSyncedAt: .now)
    }

    nonisolated static var unlocked: SubscriptionState {
        SubscriptionState(entitlement: .active, activePlan: .annual, trialEligible: false, lastSyncedAt: .now)
    }
}

struct GoalStep: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var isComplete: Bool
}

struct GoalCheckpoint: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var dueDate: Date
}

struct Goal: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var detail: String
    var priority: GoalPriority
    var category: GoalCategory
    var status: GoalStatus
    var dueDate: Date?
    var sortIndex: Int
    var subGoals: [GoalStep]
    var checkpoints: [GoalCheckpoint]
    var createdAt: Date = .now
}

struct GoalPlanDraft: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var goalID: String
    var summary: String
    var suggestedTimelineWeeks: Int
    var checkpoints: [GoalCheckpoint]
    var nextActions: [GoalStep]
    var createdAt: Date = .now
}

struct Course: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var instructor: String
    var meetingDays: [String]
    var colorHex: String
}

struct Assignment: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var courseID: String?
    var title: String
    var dueDate: Date?
    var notes: String
    var isComplete: Bool
}

struct Habit: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var streak: Int
    var targetCountPerWeek: Int
    var isCompletedToday: Bool
}

struct PlannerBlock: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var detail: String
    var startDate: Date
    var endDate: Date
    var type: PlannerBlockType
    var source: SyncProvider
    var linkedGoalID: String?
    var linkedAssignmentID: String?
}

struct StudyAttachment: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var fileName: String
    var remotePath: String
    var contentType: String
}

struct StudySession: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var notes: String
    var plannedMinutes: Int
    var elapsedMinutes: Int
    var status: StudySessionStatus
    var startedAt: Date?
    var endedAt: Date?
    var attachments: [StudyAttachment]
}

struct DailyCheckIn: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var moment: CheckInMoment
    var mood: MoodLevel
    var energy: EnergyLevel
    var stress: StressLevel
    var notes: String
    var createdAt: Date = .now
}

struct VibeCheck: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var mood: MoodLevel
    var prompt: String
    var feedback: String
    var createdAt: Date = .now
}

struct AssistantMessage: Codable, Identifiable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: String = UUID().uuidString
    var role: Role
    var content: String
    var createdAt: Date = .now
}

struct AssistantDraftAction: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var kind: AssistantDraftKind
    var title: String
    var detail: String
}

struct AssistantThread: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var messages: [AssistantMessage]
    var pendingDrafts: [AssistantDraftAction]
}

struct SyncLink: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var provider: SyncProvider
    var externalID: String
    var displayName: String
    var direction: SyncDirection
    var lastSyncedAt: Date
}

struct ImportJob: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var sourceName: String
    var status: ImportStatus
    var extractedCourses: [Course]
    var extractedAssignments: [Assignment]
    var warnings: [String]
    var uploadedFilePath: String? = nil
    var createdAt: Date = .now
    var committedAt: Date? = nil
}

struct PlannerSnapshot: Codable, Hashable, Sendable {
    var date: Date
    var blocks: [PlannerBlock]
    var assignments: [Assignment]
    var habits: [Habit]
    var goals: [Goal]
    var sessions: [StudySession]
    var nextSuggestedAction: String
    var nextCheckInMoment: CheckInMoment?

    static let empty = PlannerSnapshot(
        date: .now,
        blocks: [],
        assignments: [],
        habits: [],
        goals: [],
        sessions: [],
        nextSuggestedAction: "Start with the task that unlocks tomorrow.",
        nextCheckInMoment: .midday
    )
}

extension ReminderRule {
    static let defaultRules: [ReminderRule] = [
        ReminderRule(title: "Morning check-in", hour: 8, minute: 0, target: CheckInMoment.morning.rawValue),
        ReminderRule(title: "Midday check-in", hour: 13, minute: 0, target: CheckInMoment.midday.rawValue),
        ReminderRule(title: "Night check-in", hour: 20, minute: 30, target: CheckInMoment.night.rawValue)
    ]
}
