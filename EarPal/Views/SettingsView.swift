import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: LiveTranslateViewModel
    @EnvironmentObject private var modelManager: ModelManager

    @State private var asrSelection: ASREngine = .apple
    @State private var translationSelection: TranslationEngine = .apple

    var body: some View {
        NavigationStack {
            List {
                speechOutputSection
                speechRecognitionSection
                senseVoiceSection
                translationSection
            }
            .navigationTitle("Settings")
            .onAppear(perform: syncSelections)
            .onChange(of: modelManager.selectedASREngine) { _, newValue in
                asrSelection = newValue
            }
            .onChange(of: modelManager.selectedTranslationEngine) { _, newValue in
                translationSelection = newValue
            }
            .onChange(of: asrSelection) { _, newValue in
                if modelManager.canUse(newValue) {
                    modelManager.select(asr: newValue)
                }
            }
            .onChange(of: translationSelection) { _, newValue in
                if modelManager.canUse(newValue) {
                    modelManager.select(translation: newValue)
                }
            }
        }
    }

    private func syncSelections() {
        asrSelection = modelManager.selectedASREngine
        translationSelection = modelManager.selectedTranslationEngine
    }

    private func asrModel(for engine: ASREngine) -> InferenceModel? {
        modelManager.asrModels.first { $0.engineID == engine.rawValue }
    }

    private func translationModel(for engine: TranslationEngine) -> InferenceModel? {
        modelManager.translationModels.first { $0.engineID == engine.rawValue }
    }

    private var translationEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isTranslationEnabled },
            set: { viewModel.setTranslationEnabled($0) }
        )
    }

    private var senseVoiceBackendSelection: Binding<SenseVoiceBackend> {
        Binding(
            get: { modelManager.selectedSenseVoiceBackend },
            set: { modelManager.selectSenseVoiceBackend($0) }
        )
    }

    private var senseVoiceLanguageSelection: Binding<SenseVoiceLanguageOption> {
        Binding(
            get: { modelManager.selectedSenseVoiceLanguage },
            set: { modelManager.selectSenseVoiceLanguage($0) }
        )
    }

    @ViewBuilder
    private var speechRecognitionSection: some View {
        Section("Speech Recognition") {
            Picker("Speech Recognition Engine", selection: $asrSelection) {
                ForEach(ASREngine.allCases) { engine in
                    Text(engine.shortName).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            if let model = asrModel(for: asrSelection) {
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
    private var senseVoiceSection: some View {
        if asrSelection == .senseVoice {
            Section("SenseVoice Speech Recognition") {
                Picker("Backend", selection: senseVoiceBackendSelection) {
                    ForEach(SenseVoiceBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }

                Text(modelManager.selectedSenseVoiceBackendStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Recognition Language", selection: senseVoiceLanguageSelection) {
                    ForEach(SenseVoiceLanguageOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Text("Match Source Language follows the current From language. Languages outside SenseVoice's bundled set fall back to auto detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var translationSection: some View {
        Section("Translation") {
            Toggle("Translation", isOn: translationEnabledBinding)

            Picker("Translation Engine", selection: $translationSelection) {
                ForEach(TranslationEngine.allCases) { engine in
                    Text(engine.shortName).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            if let model = translationModel(for: translationSelection) {
                ModelRow(
                    model: model,
                    isSelected: model.engineID == modelManager.selectedTranslationEngine.rawValue,
                    onDownload: { modelManager.downloadModel(id: model.id) },
                    onDelete: { modelManager.deleteModel(id: model.id) }
                )
            }

            Picker("From", selection: $viewModel.sourceLanguage) {
                ForEach(viewModel.languageOptions) { language in
                    Text(language.displayName)
                        .tag(language)
                }
            }

            if viewModel.isTranslationEnabled {
                Picker("To", selection: $viewModel.targetLanguage) {
                    ForEach(viewModel.languageOptions) { language in
                        Text(language.displayName)
                            .tag(language)
                    }
                }

                Button("Swap Languages") {
                    viewModel.swapLanguages()
                }
            }
        }
    }

    private var speechRatePercentageText: String {
        let normalized = ((viewModel.speechRate - 0.2) / 0.6).clamped(to: 0...1)
        return "\(Int((normalized * 100).rounded()))%"
    }

    @ViewBuilder
    private var speechOutputSection: some View {
        Section("Speech Output") {
            Toggle("Auto Speak", isOn: $viewModel.autoSpeak)

            if viewModel.availableVoices.isEmpty {
                LabeledContent("Voice") {
                    Text("No Apple voices available")
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Voice", selection: $viewModel.selectedVoiceIdentifier) {
                    ForEach(viewModel.availableVoices) { voice in
                        Text(voice.displayName)
                            .tag(voice.identifier)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Speech Speed")
                Slider(value: $viewModel.speechRate, in: 0.2...0.8, step: 0.05)
                Text(speechRatePercentageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    let modelManager = ModelManager()
    SettingsView()
        .environmentObject(modelManager)
        .environmentObject(LiveTranslateViewModel(modelManager: modelManager))
}
