import Foundation
import SwiftUI

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var selectedJob: Job?
    @Published var jobSegments: [Segment] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showExportSheet = false
    @Published var exportFormat: ExportFormat = .srt
    @Published var editingSegmentId: String?
    @Published var editingSegmentText: String = ""
    @Published var showPresenterMode = false
    @Published var lastExportURL: URL?

    private let repository: JobRepository

    init(repository: JobRepository = .shared) {
        self.repository = repository
    }

    func loadJobs() {
        jobs = repository.getAllJobs()
    }

    func selectJob(_ job: Job) {
        selectedJob = job
        jobSegments = repository.getSegments(forJobId: job.id)
    }

    func deleteJob(_ job: Job) {
        do {
            try repository.deleteJob(id: job.id)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
        if selectedJob?.id == job.id {
            selectedJob = nil
            jobSegments = []
        }
        loadJobs()
    }

    func exportJob(format: ExportFormat) {
        guard let job = selectedJob else { return }
        showExportSheet = false
        do {
            let url = try ExportManager.export(job: job, segments: jobSegments, format: format)
            lastExportURL = url
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func startEditingSegment(_ segment: Segment) {
        editingSegmentId = segment.id
        editingSegmentText = segment.text
    }

    func saveSegmentEdit() {
        guard let segmentId = editingSegmentId else { return }
        do {
            try repository.updateSegment(id: segmentId, text: editingSegmentText)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }

        if let idx = jobSegments.firstIndex(where: { $0.id == segmentId }) {
            jobSegments[idx].text = editingSegmentText
        }

        if let job = selectedJob {
            let fullText = jobSegments.map(\.text).joined(separator: " ")
            do {
                try repository.updateJobTranscript(id: job.id, text: fullText)
                selectedJob = repository.getJob(id: job.id)
            } catch {
                errorMessage = "Update transcript failed: \(error.localizedDescription)"
            }
        }

        editingSegmentId = nil
        editingSegmentText = ""
    }

    func cancelSegmentEdit() {
        editingSegmentId = nil
        editingSegmentText = ""
    }
}
