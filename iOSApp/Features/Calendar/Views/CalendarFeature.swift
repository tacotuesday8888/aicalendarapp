import SwiftUI
import Combine

enum CalendarDisplayMode: String, CaseIterable {
    case week = "Week"
    case day = "Day"
}

enum CalendarPresentedSheet: Identifiable {
    case add
    case detail(PlannerBlock)
    case edit(PlannerBlock)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .detail(let block):
            return "detail-\(block.id)"
        case .edit(let block):
            return "edit-\(block.id)"
        }
    }
}

@MainActor
final class CalendarViewModel: ObservableObject {
    @Published private(set) var snapshot = PlannerSnapshot.empty
    @Published var displayMode: CalendarDisplayMode = .week
    @Published var visibleWeekStart = Calendar.current.startOfWeek(for: .now)
    @Published var selectedDay = Calendar.current.startOfDay(for: .now)
    @Published var presentedSheet: CalendarPresentedSheet?
    @Published var blockPendingDeletion: PlannerBlock?
    @Published var isSavingBlock = false
    @Published var deletingBlockID: String?
    @Published var blockTitle = ""
    @Published var blockDetail = ""
    @Published var blockStartDate = Date.now
    @Published var blockDurationMinutes = 60
    @Published var blockType: PlannerBlockType = .studySession
    @Published var errorMessage: String?

    private let user: UserProfile
    private let plannerService: PlannerServicing
    private let analyticsService: AnalyticsServicing
    private var tasks = [Task<Void, Never>]()

    init(user: UserProfile, plannerService: PlannerServicing, analyticsService: AnalyticsServicing) {
        self.user = user
        self.plannerService = plannerService
        self.analyticsService = analyticsService
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    func start() {
        guard tasks.isEmpty else { return }

        tasks.append(Task {
            do {
                for try await snapshot in plannerService.observeSnapshot(for: user.id, on: .now) {
                    self.snapshot = snapshot
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load planner blocks.").errorDescription
            }
        })

        analyticsService.trackScreen("calendar")
    }

    var visibleWeekDays: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: visibleWeekStart) }
    }

    var allBlocks: [PlannerBlock] {
        snapshot.blocks.sorted(by: { $0.startDate < $1.startDate })
    }

    var selectedDayBlocks: [PlannerBlock] {
        blocks(for: selectedDay)
    }

    var isEmptyState: Bool {
        allBlocks.isEmpty
    }

    func blocks(for day: Date) -> [PlannerBlock] {
        allBlocks.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
    }

    func shiftWeek(by value: Int) {
        visibleWeekStart = Calendar.current.date(byAdding: .day, value: value * 7, to: visibleWeekStart) ?? visibleWeekStart
        if !Calendar.current.isDate(selectedDay, equalTo: visibleWeekStart, toGranularity: .weekOfYear) {
            selectedDay = visibleWeekStart
        }
    }

    func select(day: Date) {
        selectedDay = Calendar.current.startOfDay(for: day)
        displayMode = .day
    }

    func beginAddingBlock() {
        resetDraftBlock(using: selectedDay)
        presentedSheet = .add
    }

    func presentDetail(for block: PlannerBlock) {
        presentedSheet = .detail(block)
    }

    func beginEditing(_ block: PlannerBlock) {
        presentedSheet = .edit(block)
    }

    func addPlannerBlock() async {
        guard !blockTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSavingBlock else { return }

        errorMessage = nil
        isSavingBlock = true
        defer { isSavingBlock = false }

        let block = PlannerBlock(
            title: blockTitle,
            detail: blockDetail,
            startDate: blockStartDate,
            endDate: blockStartDate.addingTimeInterval(TimeInterval(blockDurationMinutes * 60)),
            type: blockType,
            source: .app,
            linkedGoalID: nil,
            linkedAssignmentID: nil
        )

        do {
            try await plannerService.savePlannerBlock(block, for: user.id)
            blockTitle = ""
            blockDetail = ""
            blockStartDate = preferredStartDate(for: block.startDate)
            blockDurationMinutes = 60
            blockType = .studySession
            presentedSheet = nil
            selectedDay = Calendar.current.startOfDay(for: block.startDate)
            visibleWeekStart = Calendar.current.startOfWeek(for: block.startDate)
            errorMessage = nil
            analyticsService.track(event: "planner_block_saved", parameters: ["type": block.type.rawValue])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to save planner block.").errorDescription
        }
    }

    func requestDelete(_ block: PlannerBlock) {
        blockPendingDeletion = block
    }

    func confirmDelete() async {
        guard let block = blockPendingDeletion else { return }

        deletingBlockID = block.id
        defer {
            deletingBlockID = nil
            blockPendingDeletion = nil
        }

        do {
            try await plannerService.deletePlannerBlock(id: block.id, for: user.id)
            if case .detail(let selected)? = presentedSheet, selected.id == block.id {
                presentedSheet = nil
            }
            errorMessage = nil
            analyticsService.track(event: "planner_block_deleted", parameters: ["type": block.type.rawValue])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to delete planner block.").errorDescription
        }
    }

    func updateBlock(_ block: PlannerBlock) async throws {
        errorMessage = nil
        isSavingBlock = true
        defer { isSavingBlock = false }

        do {
            try await plannerService.savePlannerBlock(block, for: user.id)
            presentedSheet = nil
            errorMessage = nil
            analyticsService.track(event: "planner_block_updated", parameters: ["type": block.type.rawValue])
        } catch {
            let wrapped = AppError.wrap(error, fallback: "Unable to update planner block.")
            errorMessage = wrapped.errorDescription
            throw wrapped
        }
    }

    private func resetDraftBlock(using day: Date) {
        blockTitle = ""
        blockDetail = ""
        blockStartDate = preferredStartDate(for: day)
        blockDurationMinutes = 60
        blockType = .studySession
    }

    private func preferredStartDate(for day: Date) -> Date {
        let calendar = Calendar.current
        let selectedDayStart = calendar.startOfDay(for: day)
        if calendar.isDate(day, inSameDayAs: .now) {
            let currentHour = max(calendar.component(.hour, from: .now), 7)
            return calendar.date(bySettingHour: currentHour, minute: 0, second: 0, of: selectedDayStart) ?? .now
        }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDayStart) ?? selectedDayStart
    }
}

struct CalendarView: View {
    @StateObject private var viewModel: CalendarViewModel

    init(user: UserProfile, container: AppContainer) {
        _viewModel = StateObject(wrappedValue: CalendarViewModel(
            user: user,
            plannerService: container.plannerService,
            analyticsService: container.analyticsService
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                calendarHeader

                if viewModel.isEmptyState {
                    EmptyStateView(
                        systemImage: "calendar.badge.plus",
                        title: "Your schedule is clear",
                        message: "Add a planner block to start shaping study time, deadlines, and routines for the week.",
                        actionTitle: "Add Block"
                    ) {
                        viewModel.beginAddingBlock()
                    }
                } else if viewModel.displayMode == .week {
                    WeekCalendarGrid(viewModel: viewModel)
                } else {
                    DayTimelineView(viewModel: viewModel)
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(AppTheme.screenPadding)
        }
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.beginAddingBlock()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $viewModel.presentedSheet) { sheet in
            switch sheet {
            case .add:
                CalendarBlockEditorSheet(viewModel: viewModel)
            case .detail(let block):
                CalendarBlockDetailSheet(
                    block: block,
                    isDeleting: viewModel.deletingBlockID == block.id,
                    onEdit: {
                        viewModel.beginEditing(block)
                    },
                    onDelete: {
                        viewModel.presentedSheet = nil
                        viewModel.requestDelete(block)
                    }
                )
            case .edit(let block):
                CalendarBlockEditSheet(block: block) { updated in
                    try await viewModel.updateBlock(updated)
                }
            }
        }
        .confirmationDialog(
            "Delete this planner block?",
            isPresented: Binding(
                get: { viewModel.blockPendingDeletion != nil },
                set: { if !$0 { viewModel.blockPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Block", role: .destructive) {
                Task { await viewModel.confirmDelete() }
            }
            Button("Keep Block", role: .cancel) {}
        } message: {
            Text("This removes the block from your planner.")
        }
        .swGlassScreenBackground()
        .task {
            viewModel.start()
        }
    }

    private var calendarHeader: some View {
        SWGlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.visibleWeekStart.formatted(.dateTime.month(.wide).year()))
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(viewModel.selectedDay.formatted(.dateTime.weekday(.wide).month().day()))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            viewModel.shiftWeek(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            viewModel.shiftWeek(by: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Picker("Mode", selection: $viewModel.displayMode) {
                    ForEach(CalendarDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

private struct WeekCalendarGrid: View {
    @ObservedObject var viewModel: CalendarViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 7)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(viewModel.visibleWeekDays, id: \.self) { day in
                let blocks = viewModel.blocks(for: day)
                Button {
                    viewModel.select(day: day)
                } label: {
                    SWGlassPanel(cornerRadius: 18, padding: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(day.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.textSecondary)

                            Text(day.formatted(.dateTime.day()))
                                .font(.title3.bold())
                                .foregroundStyle(AppTheme.textPrimary)

                            HStack(spacing: 4) {
                                ForEach(Array(blocks.prefix(3).enumerated()), id: \.offset) { _, block in
                                    Circle()
                                        .fill(block.type.calendarColor)
                                        .frame(width: 8, height: 8)
                                }
                                if blocks.count > 3 {
                                    Text("+\(blocks.count - 3)")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                            }
                            .frame(maxHeight: .infinity, alignment: .bottomLeading)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                Calendar.current.isDate(day, inSameDayAs: viewModel.selectedDay) ? AppTheme.primary : Color.clear,
                                lineWidth: 2
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct DayTimelineView: View {
    @ObservedObject var viewModel: CalendarViewModel
    private let startHour = 6
    private let endHour = 22
    private let hourHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.selectedDay.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            if viewModel.selectedDayBlocks.isEmpty {
                EmptyStateView(
                    systemImage: "clock.badge.xmark",
                    title: "No blocks for this day",
                    message: "Tap the plus button to add a class, task, focus session, or reminder for this day.",
                    actionTitle: "Add Block"
                ) {
                    viewModel.beginAddingBlock()
                }
            } else {
                SWGlassPanel {
                    ScrollView(.vertical, showsIndicators: false) {
                        GeometryReader { geometry in
                            let items = layoutItems(for: viewModel.selectedDayBlocks)
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 0) {
                                    ForEach(startHour...endHour, id: \.self) { hour in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(hourLabel(hour))
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.textSecondary)
                                                .frame(width: 48, alignment: .leading)

                                            Rectangle()
                                                .fill(AppTheme.border)
                                                .frame(height: 1)
                                                .offset(y: 10)
                                        }
                                        .frame(height: hourHeight, alignment: .top)
                                    }
                                }

                                ForEach(items) { item in
                                    Button {
                                        viewModel.presentDetail(for: item.block)
                                    } label: {
                                        TimelineBlockCard(block: item.block)
                                            .frame(
                                                width: itemWidth(for: item, availableWidth: geometry.size.width),
                                                height: max(blockHeight(for: item.block), 48),
                                                alignment: .topLeading
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .offset(
                                        x: xOffset(for: item, availableWidth: geometry.size.width),
                                        y: yOffset(for: item.block)
                                    )
                                }
                            }
                            .frame(
                                width: geometry.size.width,
                                height: CGFloat(endHour - startHour + 1) * hourHeight,
                                alignment: .topLeading
                            )
                        }
                        .frame(height: CGFloat(endHour - startHour + 1) * hourHeight)
                    }
                    .frame(height: 560)
                }
            }
        }
    }

    private func yOffset(for block: PlannerBlock) -> CGFloat {
        let calendar = Calendar.current
        let startOfSelectedDay = calendar.startOfDay(for: viewModel.selectedDay)
        let dayStart = calendar.date(byAdding: .hour, value: startHour, to: startOfSelectedDay) ?? startOfSelectedDay
        let minutes = max(0, block.startDate.timeIntervalSince(dayStart) / 60)
        return CGFloat(minutes / 60) * hourHeight
    }

    private func blockHeight(for block: PlannerBlock) -> CGFloat {
        let durationMinutes = max(30, block.endDate.timeIntervalSince(block.startDate) / 60)
        return CGFloat(durationMinutes / 60) * hourHeight
    }

    private func xOffset(for item: TimelineLayoutItem, availableWidth: CGFloat) -> CGFloat {
        let laneSpacing: CGFloat = 8
        return 64 + CGFloat(item.lane) * (itemWidth(for: item, availableWidth: availableWidth) + laneSpacing)
    }

    private func itemWidth(for item: TimelineLayoutItem, availableWidth: CGFloat) -> CGFloat {
        let laneSpacing: CGFloat = 8
        let usableWidth = max(availableWidth - 76, 140)
        let totalSpacing = CGFloat(max(item.laneCount - 1, 0)) * laneSpacing
        return max((usableWidth - totalSpacing) / CGFloat(max(item.laneCount, 1)), 112)
    }

    private func layoutItems(for blocks: [PlannerBlock]) -> [TimelineLayoutItem] {
        let sortedBlocks = blocks.sorted { lhs, rhs in
            if lhs.startDate == rhs.startDate {
                return lhs.endDate < rhs.endDate
            }
            return lhs.startDate < rhs.startDate
        }

        var laidOut = [TimelineLayoutItem]()
        var activeLaneEndDates = [Date]()
        var currentCluster = [TimelineLayoutItem]()
        var clusterMaxLanes = 0
        var clusterEndDate: Date?

        func flushCluster() {
            guard !currentCluster.isEmpty else { return }
            laidOut.append(contentsOf: currentCluster.map {
                TimelineLayoutItem(block: $0.block, lane: $0.lane, laneCount: max(clusterMaxLanes, 1))
            })
            currentCluster.removeAll()
            activeLaneEndDates.removeAll()
            clusterMaxLanes = 0
            clusterEndDate = nil
        }

        for block in sortedBlocks {
            if let clusterEndDate, block.startDate >= clusterEndDate {
                flushCluster()
            }

            let lane: Int
            if let reusableLane = activeLaneEndDates.firstIndex(where: { $0 <= block.startDate }) {
                lane = reusableLane
                activeLaneEndDates[reusableLane] = block.endDate
            } else {
                lane = activeLaneEndDates.count
                activeLaneEndDates.append(block.endDate)
            }

            clusterMaxLanes = max(clusterMaxLanes, activeLaneEndDates.count)
            clusterEndDate = max(clusterEndDate ?? block.endDate, block.endDate)
            currentCluster.append(TimelineLayoutItem(block: block, lane: lane, laneCount: 1))
        }

        flushCluster()
        return laidOut
    }

    private func hourLabel(_ hour: Int) -> String {
        let period = hour >= 12 ? "PM" : "AM"
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return "\(displayHour) \(period)"
    }
}

private struct TimelineLayoutItem: Identifiable {
    let block: PlannerBlock
    let lane: Int
    let laneCount: Int

    var id: String {
        block.id
    }
}

private struct TimelineBlockCard: View {
    let block: PlannerBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(block.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(block.startDate.formatted(date: .omitted, time: .shortened) + " - " + block.endDate.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            if !block.detail.ifEmpty("").isEmpty {
                Text(block.detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(block.type.calendarColor.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(block.type.calendarColor.opacity(0.42), lineWidth: 1)
        )
    }
}

private struct CalendarBlockDetailSheet: View {
    let block: PlannerBlock
    let isDeleting: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SummaryRow(title: "Type", value: block.type.displayTitle)
                    SummaryRow(title: "Starts", value: block.startDate.formatted(date: .abbreviated, time: .shortened))
                    SummaryRow(title: "Ends", value: block.endDate.formatted(date: .abbreviated, time: .shortened))
                    SummaryRow(title: "Details", value: block.detail.ifEmpty("No extra details for this block."))

                    Button {
                        onEdit()
                    } label: {
                        Text("Edit Block")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SWGlassCTAButtonStyle())

                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        if isDeleting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Delete Block")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeleting)
                }
                .padding(AppTheme.screenPadding)
            }
            .navigationTitle(block.title)
            .swGlassScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct CalendarBlockEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var detail: String
    @State private var startDate: Date
    @State private var durationMinutes: Int
    @State private var blockType: PlannerBlockType
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let block: PlannerBlock
    private let onSave: (PlannerBlock) async throws -> Void

    init(block: PlannerBlock, onSave: @escaping (PlannerBlock) async throws -> Void) {
        self.block = block
        self.onSave = onSave
        _title = State(initialValue: block.title)
        _detail = State(initialValue: block.detail)
        _startDate = State(initialValue: block.startDate)
        _durationMinutes = State(initialValue: max(15, Int(block.endDate.timeIntervalSince(block.startDate) / 60)))
        _blockType = State(initialValue: block.type)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SWGlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Block title", text: $title)
                                .textFieldStyle(.roundedBorder)

                            TextField("Detail", text: $detail, axis: .vertical)
                                .textFieldStyle(.roundedBorder)

                            DatePicker("Start", selection: $startDate)

                            Stepper(
                                "Duration: \(durationMinutes) min",
                                value: $durationMinutes,
                                in: 15...240,
                                step: 15
                            )

                            Picker("Type", selection: $blockType) {
                                ForEach(PlannerBlockType.allCases, id: \.self) { type in
                                    Text(type.displayTitle).tag(type)
                                }
                            }
                            .pickerStyle(.menu)

                            if let errorMessage {
                                Text(errorMessage)
                                    .foregroundStyle(.red)
                            }

                            Button {
                                Task {
                                    guard !isSaving else { return }
                                    isSaving = true
                                    errorMessage = nil
                                    defer { isSaving = false }

                                    var updated = block
                                    updated.title = title
                                    updated.detail = detail
                                    updated.startDate = startDate
                                    updated.endDate = startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
                                    updated.type = blockType

                                    do {
                                        try await onSave(updated)
                                        dismiss()
                                    } catch {
                                        errorMessage = AppError.wrap(error, fallback: "Unable to update planner block.").errorDescription
                                    }
                                }
                            } label: {
                                if isSaving {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Save Changes")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(SWGlassCTAButtonStyle())
                            .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(AppTheme.screenPadding)
            }
            .navigationTitle("Edit Block")
            .swGlassScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct SummaryRow: View {
    let title: String
    let value: String

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(value)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

private struct CalendarBlockEditorSheet: View {
    @ObservedObject var viewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SWGlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Block title", text: $viewModel.blockTitle)
                                .textFieldStyle(.roundedBorder)

                            TextField("Detail", text: $viewModel.blockDetail, axis: .vertical)
                                .textFieldStyle(.roundedBorder)

                            DatePicker("Start", selection: $viewModel.blockStartDate)

                            Stepper(
                                "Duration: \(viewModel.blockDurationMinutes) min",
                                value: $viewModel.blockDurationMinutes,
                                in: 15...240,
                                step: 15
                            )

                            Picker("Type", selection: $viewModel.blockType) {
                                ForEach(PlannerBlockType.allCases, id: \.self) { type in
                                    Text(type.displayTitle).tag(type)
                                }
                            }
                            .pickerStyle(.menu)

                            Button {
                                Task { await viewModel.addPlannerBlock() }
                            } label: {
                                if viewModel.isSavingBlock {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Save Planner Block")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(SWGlassCTAButtonStyle())
                            .disabled(viewModel.isSavingBlock || viewModel.blockTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if let errorMessage = viewModel.errorMessage {
                                Text(errorMessage)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                .padding(AppTheme.screenPadding)
            }
            .navigationTitle("Add Block")
            .swGlassScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private extension PlannerBlockType {
    var calendarColor: Color {
        switch self {
        case .studySession:
            return AppTheme.primary
        case .classEvent:
            return AppTheme.accent
        case .task:
            return AppTheme.textPrimary.opacity(0.85)
        case .habit:
            return AppTheme.accent.opacity(0.86)
        case .reminder:
            return AppTheme.primary.opacity(0.72)
        case .wellbeing:
            return AppTheme.accent.opacity(0.62)
        }
    }

    var displayTitle: String {
        switch self {
        case .studySession:
            return "Study Session"
        case .classEvent:
            return "Class Event"
        case .task:
            return "Task"
        case .habit:
            return "Habit"
        case .reminder:
            return "Reminder"
        case .wellbeing:
            return "Wellbeing"
        }
    }
}

private extension Calendar {
    func startOfWeek(for date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)?.start ?? startOfDay(for: date)
    }
}
