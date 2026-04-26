import SwiftUI

struct ImportReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draftJob: ImportJob
    @State private var isCommitting = false
    @State private var errorMessage: String?

    let title: String
    let commitButtonTitle: String
    let onCommit: (ImportJob) async throws -> Void

    init(
        job: ImportJob,
        title: String = "Review Import",
        commitButtonTitle: String = "Commit Import",
        onCommit: @escaping (ImportJob) async throws -> Void
    ) {
        _draftJob = State(initialValue: job)
        self.title = title
        self.commitButtonTitle = commitButtonTitle
        self.onCommit = onCommit
    }

    private var canCommit: Bool {
        !draftJob.extractedCourses.isEmpty &&
        draftJob.extractedCourses.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
        draftJob.extractedAssignments.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Summary") {
                    LabeledContent("Source", value: draftJob.sourceName)
                    LabeledContent("Courses", value: "\(draftJob.extractedCourses.count)")
                    LabeledContent("Assignments", value: "\(draftJob.extractedAssignments.count)")
                    if draftJob.status == .committed {
                        Text("This import is already committed.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Review and edit the parsed data before saving it to your planner.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !draftJob.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(draftJob.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Courses") {
                    if draftJob.extractedCourses.isEmpty {
                        Text("Add at least one course before importing.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach($draftJob.extractedCourses) { $course in
                        CourseReviewEditor(course: $course)
                    }

                    Button {
                        draftJob.extractedCourses.append(
                            Course(title: "Imported Course", instructor: "", meetingDays: [], colorHex: "#2F6BFF")
                        )
                    } label: {
                        Label("Add course", systemImage: "plus")
                    }
                }

                Section("Assignments") {
                    if draftJob.extractedAssignments.isEmpty {
                        Text("No assignments were parsed. You can still add them manually before importing.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach($draftJob.extractedAssignments) { $assignment in
                        AssignmentReviewEditor(
                            assignment: $assignment,
                            availableCourses: draftJob.extractedCourses
                        )
                    }

                    Button {
                        draftJob.extractedAssignments.append(
                            Assignment(
                                courseID: draftJob.extractedCourses.first?.id,
                                title: "New assignment",
                                dueDate: .now,
                                notes: "",
                                isComplete: false
                            )
                        )
                    } label: {
                        Label("Add assignment", systemImage: "plus")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCommitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isCommitting {
                        ProgressView()
                    } else {
                        Button(commitButtonTitle) {
                            Task { await commit() }
                        }
                        .disabled(!canCommit)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isCommitting)
    }

    private func commit() async {
        errorMessage = nil
        isCommitting = true
        defer { isCommitting = false }

        normalizeDraft()

        do {
            try await onCommit(draftJob)
            dismiss()
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to commit this import.").errorDescription
        }
    }

    private func normalizeDraft() {
        draftJob.sourceName = draftJob.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)

        draftJob.extractedCourses = draftJob.extractedCourses.map { course in
            var updated = course
            updated.title = course.title.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.instructor = course.instructor.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.meetingDays = course.meetingDays
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            updated.colorHex = course.colorHex.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("#2F6BFF")
            return updated
        }.filter { !$0.title.isEmpty }

        let validCourseIDs = Set(draftJob.extractedCourses.map(\.id))
        let fallbackCourseID = draftJob.extractedCourses.first?.id

        draftJob.extractedAssignments = draftJob.extractedAssignments.compactMap { assignment in
            let trimmedTitle = assignment.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { return nil }

            var updated = assignment
            updated.title = trimmedTitle
            updated.notes = assignment.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if let courseID = assignment.courseID, validCourseIDs.contains(courseID) {
                updated.courseID = courseID
            } else {
                updated.courseID = fallbackCourseID
            }
            return updated
        }
    }
}

private struct CourseReviewEditor: View {
    @Binding var course: Course

    private var meetingDaysText: Binding<String> {
        Binding(
            get: { course.meetingDays.joined(separator: ", ") },
            set: { newValue in
                course.meetingDays = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Course title", text: $course.title)
            TextField("Instructor", text: $course.instructor)
            TextField("Meeting days (comma separated)", text: meetingDaysText)
            TextField("Color hex", text: $course.colorHex)
                .textInputAutocapitalization(.never)
        }
        .padding(.vertical, 4)
    }
}

private struct AssignmentReviewEditor: View {
    @Binding var assignment: Assignment
    let availableCourses: [Course]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Assignment title", text: $assignment.title)
            DatePicker("Due date", selection: $assignment.dueDate, displayedComponents: [.date, .hourAndMinute])

            if !availableCourses.isEmpty {
                Picker("Course", selection: Binding(
                    get: { assignment.courseID ?? availableCourses.first?.id ?? "" },
                    set: { assignment.courseID = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(availableCourses) { course in
                        Text(course.title).tag(course.id)
                    }
                }
            }

            TextField("Notes", text: $assignment.notes, axis: .vertical)
        }
        .padding(.vertical, 4)
    }
}
