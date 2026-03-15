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
            .navigationTitle("Models & Engines")
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

    private var asrSelection: Binding<ASREngine> {
        Binding(
            get: { modelManager.selectedASREngine },
            set: { modelManager.select(asr: $0) }
        )
    }

    private var translationSelection: Binding<TranslationEngine> {
        Binding(
            get: { modelManager.selectedTranslationEngine },
            set: { modelManager.select(translation: $0) }
        )
    }

    var body: some View {
        speechRecognitionSection
        translationSection
    }

    @ViewBuilder
    private var speechRecognitionSection: some View {
        Section("Speech Recognition") {
            Picker("ASR Engine", selection: asrSelection) {
                ForEach(ASREngine.allCases) { engine in
                    Text(asrLabel(for: engine))
                        .tag(engine)
                }
            }
            .pickerStyle(.navigationLink)

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

    private func asrLabel(for engine: ASREngine) -> String {
        modelManager.canUse(engine) ? engine.displayName : "\(engine.displayName) (Install model)"
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

                if model.isInstalled && !model.isBuiltIn {
                    Button("Delete", role: .destructive, action: onDelete)
                } else if !model.isBuiltIn {
                    Button(model.isDownloading ? "Downloading" : "Download", action: onDownload)
                        .disabled(model.isDownloading)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
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
            return "Double tap to delete this model."
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
