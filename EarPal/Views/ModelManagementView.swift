import SwiftUI

struct ModelManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var modelManager: ModelManager

    var body: some View {
        NavigationStack {
            List {
                ModelSettingsSections()
                    .environmentObject(modelManager)
            }
            .navigationTitle("Download Models")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

}

struct ModelSettingsSections: View {
    @EnvironmentObject private var modelManager: ModelManager

    private var translationSelection: Binding<TranslationEngine> {
        Binding(
            get: { modelManager.selectedTranslationEngine },
            set: { modelManager.select(translation: $0) }
        )
    }

    var body: some View {
        asrModelsSection
        translationSection
    }

    @ViewBuilder
    private var asrModelsSection: some View {
        Section("Speech Recognition") {
            ForEach(modelManager.asrModels) { model in
                ModelRow(
                    model: model,
                    isSelected: model.engineID == modelManager.selectedASREngine.rawValue,
                    onDownload: { modelManager.downloadModel(id: model.id) },
                    onDelete: { modelManager.deleteModel(id: model.id) }
                )
            }
        }
    }

    @ViewBuilder
    private var translationSection: some View {
        Section("Translation") {
            Picker("Translation Engine", selection: translationSelection) {
                ForEach(TranslationEngine.allCases) { engine in
                    Text(translationLabel(for: engine))
                        .tag(engine)
                }
            }
            .pickerStyle(.navigationLink)

            ForEach(modelManager.translationModels) { model in
                ModelRow(
                    model: model,
                    isSelected: model.engineID == modelManager.selectedTranslationEngine.rawValue,
                    onDownload: { modelManager.downloadModel(id: model.id) },
                    onDelete: { modelManager.deleteModel(id: model.id) }
                )
            }
        }
    }
    private func translationLabel(for engine: TranslationEngine) -> String {
        modelManager.canUse(engine) ? engine.displayName : "\(engine.displayName) (Install model)"
    }
}

private struct ModelRow: View {
    let model: InferenceModel
    let isSelected: Bool
    let onDownload: () -> Void
    let onDelete: () -> Void
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.headline)

                    Text(model.sizeDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !model.isBuiltIn {
                    Text(actionLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(actionColor)
                }
            }

            Text(model.statusNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isDownloading {
                ProgressView(value: model.downloadProgress)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !model.isBuiltIn, !model.isDownloading else { return }
            if model.isInstalled {
                showingDeleteConfirmation = true
            } else {
                onDownload()
            }
        }
        .confirmationDialog(
            "Delete \(model.displayName)?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the downloaded model from the device.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    private var actionLabel: String {
        if model.isDownloading {
            return "Downloading"
        }
        return model.isInstalled ? "Downloaded" : "Download"
    }

    private var actionColor: Color {
        if model.isDownloading {
            return .secondary
        }
        return model.isInstalled ? .secondary : .accentColor
    }

    private var accessibilityLabel: String {
        model.displayName
    }

    private var accessibilityValue: String {
        var values: [String] = []

        if isSelected {
            values.append("Selected")
        }

        values.append(model.sizeDescription)

        if !model.statusNote.isEmpty, model.statusNote != model.sizeDescription {
            values.append(model.statusNote)
        }

        return values.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        if model.isBuiltIn {
            return ""
        }
        if model.isInstalled {
            return "Double tap to confirm deleting this model."
        }
        if model.isDownloading {
            return "Model download in progress."
        }
        return "Double tap to download this model."
    }
}

#Preview {
    ModelManagementView()
        .environmentObject(ModelManager())
}
