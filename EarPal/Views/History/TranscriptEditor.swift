import SwiftUI

struct TranscriptEditor: View {
    let segment: Segment
    let isEditing: Bool
    @Binding var editText: String
    let onStartEdit: () -> Void
    let onSaveEdit: () -> Void
    let onCancelEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(formatTime(segment.startTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
                .padding(.top, 2)

            if isEditing {
                VStack(spacing: 8) {
                    TextField("Text", text: $editText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)

                    HStack {
                        Button("Cancel") { onCancelEdit() }
                            .buttonStyle(.bordered)
                        Button("Save") { onSaveEdit() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Text(segment.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onStartEdit() }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
