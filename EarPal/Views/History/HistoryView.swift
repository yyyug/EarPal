import SwiftUI

struct HistoryView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @State private var showDeleteConfirmation = false
    @State private var jobToDelete: Job?

    var body: some View {
        Group {
            if viewModel.jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.loadJobs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            viewModel.loadJobs()
        }
        .sheet(isPresented: $viewModel.showExportSheet) {
            exportPicker
        }
        .fullScreenCover(isPresented: $viewModel.showPresenterMode) {
            if let job = viewModel.selectedJob {
                PresenterView(
                    text: job.text,
                    onDismiss: { viewModel.showPresenterMode = false }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.editingSegmentId != nil },
            set: { if !$0 { viewModel.cancelSegmentEdit() } }
        )) {
            segmentEditSheet
        }
        .navigationDestination(isPresented: Binding(
            get: { viewModel.selectedJob != nil },
            set: { if !$0 { viewModel.selectedJob = nil; viewModel.jobSegments = [] } }
        )) {
            if let job = viewModel.selectedJob {
                JobDetailView(job: job, viewModel: viewModel)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Your transcription history will appear here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Job List

    private var jobList: some View {
        List {
            ForEach(viewModel.jobs) { job in
                NavigationLink {
                    JobDetailView(job: job, viewModel: viewModel)
                } label: {
                    jobRow(job)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        jobToDelete = job
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete recording?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let job = jobToDelete {
                    viewModel.deleteJob(job)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete this recording and its transcript.")
        }
    }

    private func jobRow(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.name ?? "Recording")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                statusBadge(job.status)
            }
            Text(job.displayText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(job.displayDate)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(_ status: JobStatus) -> some View {
        Text(status.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(status).opacity(0.15))
            .foregroundStyle(statusColor(status))
            .clipShape(Capsule())
    }

    private func statusColor(_ status: JobStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .transcribing, .translating: return .blue
        case .recording: return .orange
        default: return .gray
        }
    }

    // MARK: - Export Picker

    private var exportPicker: some View {
        NavigationStack {
            List {
                Section("Format") {
                    Picker("Format", selection: $viewModel.exportFormat) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.showExportSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { viewModel.exportJob(format: viewModel.exportFormat) }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Segment Edit Sheet

    private var segmentEditSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $viewModel.editingSegmentText)
                    .font(.body)
                    .frame(minHeight: 200)
                    .padding()
            }
            .navigationTitle("Edit Segment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.cancelSegmentEdit() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { viewModel.saveSegmentEdit() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
