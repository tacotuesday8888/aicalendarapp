import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class SessionsViewModel: ObservableObject {
    @Published private(set) var sessions = [StudySession]()
    @Published var title = ""
    @Published var notes = ""
    @Published var plannedMinutes = 50
    @Published var pendingAttachments = [StudyAttachment]()
    @Published var isStartingSession = false
    @Published var isUploadingAttachment = false
    @Published var activeOperationSessionID: String?
    @Published var pendingDeleteSession: StudySession?
    @Published var pendingCancelSession: StudySession?
    @Published var errorMessage: String?

    private let user: UserProfile
    private let studySessionService: StudySessionServicing
    private let storageService: StorageServicing
    private let analyticsService: AnalyticsServicing
    private var observationTask: Task<Void, Never>?
    private static let maxAttachmentFileBytes = 10 * 1024 * 1024
    private static let supportedAttachmentContentTypePrefixes = ["application/", "text/", "image/"]

    init(user: UserProfile, studySessionService: StudySessionServicing, storageService: StorageServicing, analyticsService: AnalyticsServicing) {
        self.user = user
        self.studySessionService = studySessionService
        self.storageService = storageService
        self.analyticsService = analyticsService
    }

    deinit {
        observationTask?.cancel()
    }

    var activeSession: StudySession? {
        sessions.first(where: { $0.status == .active })
    }

    var sessionHistory: [StudySession] {
        sessions.filter { $0.status != .active }
    }

    func start() {
        guard observationTask == nil else { return }
        observationTask = Task {
            do {
                for try await sessions in studySessionService.observeSessions(for: user.id) {
                    self.sessions = sessions.sorted(by: { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) })
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load study sessions.").errorDescription
            }
        }
        analyticsService.trackScreen("sessions")
    }

    func startSession() async {
        guard activeSession == nil else {
            errorMessage = "Complete the current focus session before starting another one."
            return
        }
        guard !isStartingSession else { return }

        errorMessage = nil
        isStartingSession = true
        defer { isStartingSession = false }

        let session = StudySession(
            title: title.isEmpty ? "Focus Session" : title,
            notes: notes,
            plannedMinutes: plannedMinutes,
            elapsedMinutes: 0,
            status: .active,
            startedAt: .now,
            endedAt: nil,
            attachments: pendingAttachments
        )

        do {
            try await studySessionService.saveSession(session, for: user.id)
            title = ""
            notes = ""
            plannedMinutes = 50
            pendingAttachments = []
            errorMessage = nil
            analyticsService.track(event: "session_started")
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to start session.").errorDescription
        }
    }

    func complete(_ session: StudySession) async {
        guard activeOperationSessionID == nil else { return }

        errorMessage = nil
        activeOperationSessionID = session.id
        defer { activeOperationSessionID = nil }

        var updated = session
        updated.status = .completed
        updated.endedAt = .now
        if let startedAt = session.startedAt {
            updated.elapsedMinutes = max(1, Int(Date.now.timeIntervalSince(startedAt) / 60))
        } else {
            updated.elapsedMinutes = updated.plannedMinutes
        }

        do {
            try await studySessionService.saveSession(updated, for: user.id)
            errorMessage = nil
            analyticsService.track(event: "session_completed")
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to complete session.").errorDescription
        }
    }

    func requestCancel(_ session: StudySession) {
        pendingCancelSession = session
    }

    func confirmCancel() async {
        guard let session = pendingCancelSession, activeOperationSessionID == nil else { return }

        errorMessage = nil
        activeOperationSessionID = session.id
        defer {
            activeOperationSessionID = nil
            pendingCancelSession = nil
        }

        var updated = session
        updated.status = .cancelled
        updated.endedAt = .now

        do {
            try await studySessionService.saveSession(updated, for: user.id)
            errorMessage = nil
            analyticsService.track(event: "session_cancelled")
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to cancel session.").errorDescription
        }
    }

    func requestDelete(_ session: StudySession) {
        pendingDeleteSession = session
    }

    func confirmDelete() async {
        guard let session = pendingDeleteSession, activeOperationSessionID == nil else { return }

        errorMessage = nil
        activeOperationSessionID = session.id
        defer {
            activeOperationSessionID = nil
            pendingDeleteSession = nil
        }

        do {
            try await studySessionService.deleteSession(id: session.id, for: user.id)
            errorMessage = nil
            analyticsService.track(event: "session_deleted")
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to delete session.").errorDescription
        }
    }

    func addAttachment(from fileURL: URL) async {
        guard !isUploadingAttachment else { return }

        errorMessage = nil
        isUploadingAttachment = true
        defer { isUploadingAttachment = false }

        let accessedSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try Self.validateAttachmentFileSize(fileURL)
            let contentType = try Self.validatedAttachmentContentType(for: fileURL)
            let data = try Data(contentsOf: fileURL)
            let remotePath = try await storageService.upload(
                data: data,
                path: "users/\(user.id)/study-sessions/\(UUID().uuidString)-\(fileURL.lastPathComponent)",
                contentType: contentType
            )

            pendingAttachments.append(
                StudyAttachment(
                    fileName: fileURL.lastPathComponent,
                    remotePath: remotePath,
                    contentType: contentType
                )
            )
            analyticsService.track(event: "session_attachment_added")
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to attach that file.").errorDescription
        }
    }

    private static func validateAttachmentFileSize(_ fileURL: URL) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else { return }

        if fileSize >= maxAttachmentFileBytes {
            throw AppError.network(description: "Study session attachments must be smaller than 10 MB.")
        }
    }

    private static func validatedAttachmentContentType(for fileURL: URL) throws -> String {
        let inferredType = UTType(filenameExtension: fileURL.pathExtension) ?? .data
        let contentType = inferredType.preferredMIMEType ?? "application/octet-stream"
        guard supportedAttachmentContentTypePrefixes.contains(where: { contentType.hasPrefix($0) }) else {
            throw AppError.network(description: "This file type is not supported for study session attachments. Use a document, text file, or image.")
        }
        return contentType
    }

    func removePendingAttachment(_ attachment: StudyAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
        analyticsService.track(event: "session_attachment_removed_pending")
    }

    func removeAttachment(_ attachment: StudyAttachment, from session: StudySession) async {
        guard activeOperationSessionID == nil else { return }

        errorMessage = nil
        activeOperationSessionID = session.id
        defer { activeOperationSessionID = nil }

        var updated = session
        updated.attachments.removeAll { $0.id == attachment.id }

        do {
            try await studySessionService.saveSession(updated, for: user.id)
            try? await storageService.delete(path: attachment.remotePath)
            analyticsService.track(event: "session_attachment_deleted")
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to remove that attachment.").errorDescription
        }
    }
}

struct SessionsView: View {
    @StateObject private var viewModel: SessionsViewModel
    @State private var showAttachmentImporter = false

    init(user: UserProfile, container: AppContainer) {
        _viewModel = StateObject(wrappedValue: SessionsViewModel(
            user: user,
            studySessionService: container.studySessionService,
            storageService: container.storageService,
            analyticsService: container.analyticsService
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let activeSession = viewModel.activeSession {
                    ActiveSessionPanel(
                        session: activeSession,
                        isLoading: viewModel.activeOperationSessionID == activeSession.id
                    ) {
                        Task { await viewModel.complete(activeSession) }
                    } onCancel: {
                        viewModel.requestCancel(activeSession)
                    } onRemoveAttachment: { attachment in
                        Task { await viewModel.removeAttachment(attachment, from: activeSession) }
                    }
                }

                SessionComposer(viewModel: viewModel) {
                    showAttachmentImporter = true
                }

                if viewModel.sessions.isEmpty {
                    EmptyStateView(
                        systemImage: "timer",
                        title: "Ready to focus?",
                        message: "Start a session to track a focused block of work and build a visible study rhythm.",
                        actionTitle: "Start Session"
                    ) {
                        Task { await viewModel.startSession() }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("History")
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)

                        ForEach(viewModel.sessionHistory) { session in
                            SessionHistoryCard(
                                session: session,
                                isLoading: viewModel.activeOperationSessionID == session.id
                            ) {
                                viewModel.requestDelete(session)
                            } onRemoveAttachment: { attachment in
                                Task { await viewModel.removeAttachment(attachment, from: session) }
                            }
                        }
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(AppTheme.screenPadding)
        }
        .navigationTitle("Sessions")
        .swGlassScreenBackground()
        .task {
            viewModel.start()
        }
        .confirmationDialog(
            "Cancel this focus session?",
            isPresented: Binding(
                get: { viewModel.pendingCancelSession != nil },
                set: { if !$0 { viewModel.pendingCancelSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Cancel Session", role: .destructive) {
                Task { await viewModel.confirmCancel() }
            }
            Button("Keep Session", role: .cancel) {}
        } message: {
            Text("This will stop the active session and mark it as cancelled.")
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteSession != nil },
                set: { if !$0 { viewModel.pendingDeleteSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                Task { await viewModel.confirmDelete() }
            }
            Button("Keep Session", role: .cancel) {}
        } message: {
            Text("This permanently removes the session from history.")
        }
        .fileImporter(
            isPresented: $showAttachmentImporter,
            allowedContentTypes: [.item]
        ) { result in
            switch result {
            case .success(let url):
                Task { await viewModel.addAttachment(from: url) }
            case .failure(let error):
                viewModel.errorMessage = AppError.wrap(error, fallback: "Unable to access that attachment.").errorDescription
            }
        }
    }
}

private struct ActiveSessionPanel: View {
    let session: StudySession
    let isLoading: Bool
    let onComplete: () -> Void
    let onCancel: () -> Void
    let onRemoveAttachment: (StudyAttachment) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsedSeconds = resolvedElapsedSeconds(at: context.date)
            let progress = resolvedProgress(elapsedSeconds: elapsedSeconds)

            SWGlassPanel {
                VStack(spacing: 16) {
                    SessionProgressRing(progress: progress, label: formattedElapsedTime(elapsedSeconds: elapsedSeconds))

                    VStack(spacing: 6) {
                        Text(session.title)
                            .font(.title3.bold())
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(session.notes.ifEmpty("Focus in progress"))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                        Text("Planned \(session.plannedMinutes) min")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    if !session.attachments.isEmpty {
                        SessionAttachmentList(
                            attachments: session.attachments,
                            isLoading: isLoading,
                            onRemove: onRemoveAttachment
                        )
                    }

                    HStack(spacing: 12) {
                        Button(action: onComplete) {
                            if isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Complete")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(SWGlassCTAButtonStyle())
                        .disabled(isLoading)

                        Button("Cancel", action: onCancel)
                            .buttonStyle(.bordered)
                            .disabled(isLoading)
                    }
                }
            }
        }
    }

    private func resolvedElapsedSeconds(at now: Date) -> TimeInterval {
        guard let startedAt = session.startedAt else { return TimeInterval(session.elapsedMinutes * 60) }
        return max(0, now.timeIntervalSince(startedAt))
    }

    private func resolvedProgress(elapsedSeconds: TimeInterval) -> Double {
        let plannedSeconds = max(60, Double(session.plannedMinutes * 60))
        return min(1, elapsedSeconds / plannedSeconds)
    }

    private func formattedElapsedTime(elapsedSeconds: TimeInterval) -> String {
        let totalSeconds = Int(elapsedSeconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct SessionProgressRing: View {
    let progress: Double
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.border, lineWidth: 14)

            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(
                    AngularGradient(colors: [AppTheme.primary, AppTheme.accent], center: .center),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 4) {
                Text(label)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Elapsed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(width: 210, height: 210)
    }
}

private struct SessionComposer: View {
    @ObservedObject var viewModel: SessionsViewModel
    let onAddAttachment: () -> Void

    var body: some View {
        SWGlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Start a focus session")
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)

                TextField("Session title", text: $viewModel.title)
                    .textFieldStyle(.roundedBorder)

                TextField("What are you working on?", text: $viewModel.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)

                Stepper("Planned minutes: \(viewModel.plannedMinutes)", value: $viewModel.plannedMinutes, in: 15...180, step: 5)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Attachments")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        Button {
                            onAddAttachment()
                        } label: {
                            if viewModel.isUploadingAttachment {
                                ProgressView()
                            } else {
                                Label("Add file", systemImage: "paperclip")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isUploadingAttachment || viewModel.isStartingSession)
                    }

                    if viewModel.pendingAttachments.isEmpty {
                        Text("Optional: attach notes, slides, or a PDF before you start.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        SessionAttachmentList(
                            attachments: viewModel.pendingAttachments,
                            isLoading: viewModel.isUploadingAttachment || viewModel.isStartingSession,
                            onRemove: viewModel.removePendingAttachment
                        )
                    }
                }

                Button {
                    Task { await viewModel.startSession() }
                } label: {
                    if viewModel.isStartingSession {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Start Session")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(SWGlassCTAButtonStyle())
                .disabled(viewModel.activeSession != nil || viewModel.isStartingSession)
            }
        }
    }
}

private struct SessionHistoryCard: View {
    let session: StudySession
    let isLoading: Bool
    let onDelete: () -> Void
    let onRemoveAttachment: (StudyAttachment) -> Void

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(session.title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text(session.status.rawValue.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Text(session.notes.ifEmpty("No session notes"))
                    .foregroundStyle(AppTheme.textSecondary)

                if !session.attachments.isEmpty {
                    SessionAttachmentList(
                        attachments: session.attachments,
                        isLoading: isLoading,
                        onRemove: onRemoveAttachment
                    )
                }

                HStack {
                    Text("\(session.elapsedMinutes) min")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Delete")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                }
            }
        }
    }
}

private struct SessionAttachmentList: View {
    let attachments: [StudyAttachment]
    let isLoading: Bool
    let onRemove: (StudyAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(AppTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Text(attachment.contentType)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        onRemove(attachment)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                }
            }
        }
    }
}
