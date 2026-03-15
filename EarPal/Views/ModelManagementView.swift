import SwiftUI

struct ModelManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var modelManager: ModelManager

    var body: some View {
        NavigationStack {
            List {
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
                    HStack(spacing: 8) {
                        Text(model.displayName)
                            .font(.headline)
                        if isSelected {
                            Text("Selected")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.08), in: Capsule())
                        }
                    }

                    Text(model.sizeDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.isBuiltIn {
                    Text("Built in")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if model.isInstalled {
                    Button("Delete", role: .destructive, action: onDelete)
                } else {
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
    }
}

#Preview {
    ModelManagementView()
        .environmentObject(ModelManager())
}
