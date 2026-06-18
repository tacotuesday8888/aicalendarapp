import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ImportsViewModel: ObservableObject {
    @Published private(set) var jobs = [ImportJob]()
    @Published var importedText = ""
    @Published var latestJob: ImportJob?
    @Published var reviewingJob: ImportJob?
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    @Published var isImporting = false
    @Published var committingJobID: String?

    private let user: UserProfile
    private let syllabusImportService: SyllabusImportServicing
    private let analyticsService: AnalyticsServicing
    private var observationTask: Task<Void, Never>?

    init(user: UserProfile, syllabusImportService: SyllabusImportServicing, analyticsService: AnalyticsServicing) {
        self.user = user
        self.syllabusImportService = syllabusImportService
        self.analyticsService = analyticsService
    }

    deinit {
        observationTask?.cancel()
    }

    func start() {
        guard observationTask == nil else { return }

        observationTask = Task {
            do {
                for try await jobs in syllabusImportService.observeImports(for: user.id) {
                    self.jobs = jobs.sorted(by: { $0.createdAt > $1.createdAt })
                }
            } catch {
                self.errorMessage = AppError.wrap(error, fallback: "Unable to load imports.").errorDescription
            }
        }

        analyticsService.trackScreen("imports")
    }

    func importText() async {
        let trimmedText = importedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        do {
            let job = try await syllabusImportService.importText(trimmedText, for: user.id)
            latestJob = job
            reviewingJob = job
            statusMessage = "Parsed \(job.extractedAssignments.count) assignments from text."
            errorMessage = nil
            analyticsService.track(event: "syllabus_import_started", parameters: ["source": "text"])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to import syllabus text.").errorDescription
        }
    }

    func importFile(at url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        do {
            let job = try await syllabusImportService.importFile(at: url, for: user.id)
            latestJob = job
            reviewingJob = job
            statusMessage = "Parsed \(job.extractedAssignments.count) assignments from file."
            errorMessage = nil
            analyticsService.track(event: "syllabus_import_started", parameters: ["source": "file"])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to import selected file.").errorDescription
        }
    }

    func commit(_ job: ImportJob) async throws {
        guard committingJobID == nil else { return }
        committingJobID = job.id
        defer { committingJobID = nil }

        do {
            try await syllabusImportService.commit(job, for: user.id)
            statusMessage = "Imported \(job.extractedCourses.count) courses and \(job.extractedAssignments.count) assignments."
            errorMessage = nil
            let committedJob = ImportJob(
                id: job.id,
                sourceName: job.sourceName,
                status: .committed,
                extractedCourses: job.extractedCourses,
                extractedAssignments: job.extractedAssignments,
                warnings: job.warnings,
                uploadedFilePath: job.uploadedFilePath,
                createdAt: job.createdAt,
                committedAt: .now
            )
            latestJob = committedJob
            reviewingJob = committedJob
            analyticsService.track(event: "import_commit_confirmed")
        } catch {
            let wrapped = AppError.wrap(error, fallback: "Unable to commit import.")
            errorMessage = wrapped.errorDescription
            throw wrapped
        }
    }

    func delete(at offsets: IndexSet) {
        let items = jobs

        for index in offsets {
            let job = items[index]
            Task {
                do {
                    try await syllabusImportService.delete(job, for: user.id)
                    if latestJob?.id == job.id {
                        await MainActor.run {
                            self.latestJob = nil
                        }
                    }
                    await MainActor.run {
                        self.errorMessage = nil
                    }
                    analyticsService.track(event: "import_deleted")
                } catch {
                    await MainActor.run {
                        self.errorMessage = AppError.wrap(error, fallback: "Unable to delete import.").errorDescription
                    }
                }
            }
        }
    }
}

struct ImportsFeature: View {
    @StateObject private var viewModel: ImportsViewModel
    @State private var showFileImporter = false
    private let isPremiumLocked: Bool
    private let onRequirePremium: (PaywallTrigger) -> Void

    init(
        user: UserProfile,
        container: AppContainer,
        isPremiumLocked: Bool = false,
        onRequirePremium: @escaping (PaywallTrigger) -> Void = { _ in }
    ) {
        self.isPremiumLocked = isPremiumLocked
        self.onRequirePremium = onRequirePremium
        _viewModel = StateObject(wrappedValue: ImportsViewModel(
            user: user,
            syllabusImportService: container.syllabusImportService,
            analyticsService: container.analyticsService
        ))
    }

    var body: some View {
        List {
            Section("Paste syllabus text") {
                TextEditor(text: $viewModel.importedText)
                    .frame(minHeight: 140)

                Button {
                    guard !requirePremiumIfLocked() else { return }
                    Task { await viewModel.importText() }
                } label: {
                    if viewModel.isImporting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Parse text")
                    }
                }
                .disabled(viewModel.isImporting || viewModel.importedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Import a file") {
                Button("Choose file") {
                    guard !requirePremiumIfLocked() else { return }
                    showFileImporter = true
                }
                .disabled(viewModel.isImporting)
            }

            if let job = viewModel.latestJob {
                Section("Latest parsed import") {
                    Text(job.sourceName)
                        .font(.headline)
                    Text("\(job.extractedCourses.count) courses • \(job.extractedAssignments.count) assignments • \(job.status.rawValue.capitalized)")
                        .foregroundStyle(.secondary)

                    if !job.warnings.isEmpty {
                        ForEach(job.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Commit import") {
                        guard !requirePremiumIfLocked() else { return }
                        Task { try? await viewModel.commit(job) }
                    }
                    .disabled(viewModel.committingJobID != nil)

                    Button("Review before commit") {
                        guard !requirePremiumIfLocked() else { return }
                        viewModel.reviewingJob = job
                    }
                }
            }

            Section("Recent imports") {
                if viewModel.jobs.isEmpty {
                    Text("No imports yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.jobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.sourceName)
                                .font(.headline)
                            Text("\(job.extractedCourses.count) courses • \(job.extractedAssignments.count) assignments • \(job.status.rawValue.capitalized)")
                                .foregroundStyle(.secondary)
                            Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: viewModel.delete)
                }
            }

            if !viewModel.statusMessage.isEmpty {
                Section {
                    Text(viewModel.statusMessage)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Imports")
        .task {
            viewModel.start()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.plainText, .text, .pdf]
        ) { result in
            switch result {
            case .success(let url):
                guard !requirePremiumIfLocked() else { return }
                Task { await viewModel.importFile(at: url) }
            case .failure(let error):
                viewModel.errorMessage = AppError.wrap(error, fallback: "Unable to access the selected file.").errorDescription
            }
        }
        .sheet(item: $viewModel.reviewingJob) { job in
            ImportReviewSheet(
                job: job,
                title: "Review Import",
                commitButtonTitle: job.status == .committed ? "Update Import" : "Commit Import"
            ) { updatedJob in
                guard !requirePremiumIfLocked() else {
                    throw AppError.premiumRequired
                }
                try await viewModel.commit(updatedJob)
            }
        }
        .swGlassListChrome()
    }

    private func requirePremiumIfLocked() -> Bool {
        guard isPremiumLocked else { return false }
        onRequirePremium(PremiumFeature.syllabusImport.paywallTrigger)
        return true
    }
}
