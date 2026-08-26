import SwiftUI

struct JobDetailView: View {
    let job: Job
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !viewModel.jobSegments.isEmpty {
                    ForEach(viewModel.jobSegments) { segment in
                        TranscriptEditor(
                            segment: segment,
                            isEditing: viewModel.editingSegmentId == segment.id,
                            editText: $viewModel.editingSegmentText,
                            onStartEdit: { viewModel.startEditingSegment(segment) },
                            onSaveEdit: { viewModel.saveSegmentEdit() },
                            onCancelEdit: { viewModel.cancelSegmentEdit() }
                        )
                    }
                } else if !job.text.isEmpty {
                    Text(job.text)
                        .font(.body)
                        .padding()
                } else {
                    Text("No transcript available.")
                        .foregroundStyle(.secondary)
                        .padding()
                }

                if let translated = job.translatedText, !translated.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Translation (\(job.translatedLanguage ?? job.targetLanguage ?? "?"))")
                            .font(.headline)
                        Text(translated)
                            .font(.body)
                    }
                    .padding()
                }
            }
            .padding()
        }
        .navigationTitle(job.name ?? "Recording")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    viewModel.showPresenterMode = true
                } label: {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                }
                .disabled(job.text.isEmpty)

                Button {
                    viewModel.showExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .onAppear {
            viewModel.selectJob(job)
        }
    }
}
