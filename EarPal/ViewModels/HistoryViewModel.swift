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

    private let repository = JobRepository.shared

    func loadJobs() {
        jobs = repository.getAllJobs()
    }

    func selectJob(_ job: Job) {
        selectedJob = job
        jobSegments = repository.getSegments(forJobId: job.id)
    }

    func deleteJob(_ job: Job) {
        repository.deleteJob(id: job.id)
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
            let _ = try ExportManager.export(job: job, segments: jobSegments, format: format)
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
        repository.updateSegment(id: segmentId, text: editingSegmentText)

        if let idx = jobSegments.firstIndex(where: { $0.id == segmentId }) {
            jobSegments[idx].text = editingSegmentText
        }

        if let job = selectedJob {
            let fullText = jobSegments.map(\.text).joined(separator: " ")
            repository.updateJobTranscript(id: job.id, text: fullText)
            selectedJob = repository.getJob(id: job.id)
        }

        editingSegmentId = nil
        editingSegmentText = ""
    }

    func cancelSegmentEdit() {
        editingSegmentId = nil
        editingSegmentText = ""
    }
}
