import SwiftUI

struct LiveTranslateView: View {
    @EnvironmentObject private var viewModel: LiveTranslateViewModel
    @EnvironmentObject private var modelManager: ModelManager
    @State private var showPresenterMode = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    transcriptCard
                    if viewModel.isTranslationEnabled {
                        translationCard
                    }
                }
                .padding(20)
            }
            .background(
                LinearGradient(
                    colors: [Color(red: 0.95, green: 0.97, blue: 0.92), Color(red: 0.88, green: 0.92, blue: 0.84)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("EarPal")
            .sheet(isPresented: settingsPresented) {
                SettingsSheet()
                    .environmentObject(viewModel)
                    .environmentObject(modelManager)
            }
            .fullScreenCover(isPresented: $showPresenterMode) {
                PresenterView(
                    text: viewModel.translatedText.isEmpty ? viewModel.transcriptText : viewModel.translatedText,
                    onDismiss: { showPresenterMode = false }
                )
            }
            .overlay(alignment: .topLeading) {
                appleTranslationBridge
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .onChange(of: viewModel.sourceLanguage) { _, _ in
                viewModel.refreshAvailableVoices()
                viewModel.refreshTranslationIfNeeded()
            }
            .onChange(of: viewModel.targetLanguage) { _, _ in
                viewModel.refreshAvailableVoices()
                viewModel.refreshTranslationIfNeeded()
            }
            .onChange(of: modelManager.selectedTranslationEngine) { _, _ in
                viewModel.refreshTranslationIfNeeded()
            }
        }
    }

    private var transcriptCard: some View {
        ContentCard(title: "What I Heard", bodyText: viewModel.transcriptText, placeholder: "Incoming speech will appear here.")
    }

    private var translationCard: some View {
        ContentCard(
            title: "Translation",
            bodyText: viewModel.translatedText,
            placeholder: viewModel.translationStatusMessage.isEmpty ? "Translated speech will appear here." : viewModel.translationStatusMessage
        )
    }

    private var primaryAction: some View {
        Button {
            Task {
                await viewModel.toggleListening()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: viewModel.isListening ? "stop.circle.fill" : "waveform.circle.fill")
                    .font(.title3.weight(.semibold))
                Text(viewModel.isListening ? "Stop" : "Start")
                    .font(.headline.weight(.bold))
            }
            .padding(.horizontal, 20)
            .frame(minWidth: 132, minHeight: 52)
            .foregroundStyle(Color.white)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(viewModel.isListening ? Color.red : Color.black)
            )
        }
        .accessibilityHint("Starts or stops live listening for translation.")
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            sourceSelector

            HStack(spacing: 12) {
                primaryAction

                Spacer()

                Button {
                    showPresenterMode = true
                } label: {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .font(.title3)
                }
                .disabled(viewModel.transcriptText.isEmpty)
                .accessibilityLabel("Presenter Mode")

                Button("Settings") {
                    viewModel.isShowingAudioOptions = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var sourceSelector: some View {
        VStack(spacing: 6) {
            Picker(
                "Audio Source",
                selection: Binding(
                    get: { viewModel.audioSource },
                    set: { viewModel.setAudioSource($0) }
                )
            ) {
                ForEach(AudioCaptureSourceOption.allCases) { source in
                    Label(source.displayName, systemImage: source.iconName)
                        .tag(source)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.audioSource == .screenAudio {
                Text(screenSourceStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var screenSourceStatusText: String {
        if viewModel.isPreparingScreenCapture {
            return "Choose the screen whose audio you want to translate..."
        }
        if viewModel.isScreenCapturePrepared {
            return "Screen audio ready. Tap Start to translate what is playing."
        }
        return "Tap Start to choose the screen whose audio you want to translate."
    }

    private var settingsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.isShowingAudioOptions || viewModel.isShowingModelManagement },
            set: { isPresented in
                viewModel.isShowingAudioOptions = isPresented
                viewModel.isShowingModelManagement = isPresented
            }
        )
    }

    @ViewBuilder
    private var appleTranslationBridge: some View {
        if modelManager.selectedTranslationEngine == .apple,
           let request = viewModel.appleTranslationRequest {
            if #available(iOS 18.0, *) {
                AppleTranslationBridge(
                    request: request,
                    onTranslated: { translatedText in
                        viewModel.receiveAppleTranslation(translatedText, for: request)
                    },
                    onFailure: { error in
                        viewModel.failAppleTranslation(error, for: request)
                    }
                )
                .frame(width: 0, height: 0)
                .hidden()
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
                    .task(id: request.id) {
                        viewModel.appleTranslationUnavailable(for: request)
                    }
            }
        }
    }

}

private struct LanguageMenu: View {
    let title: String
    @Binding var selection: TranslationLanguage
    let options: [TranslationLanguage]

    var body: some View {
        Menu {
            ForEach(options) { language in
                Button(language.displayName) {
                    selection = language
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(selection.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

private struct ContentCard: View {
    let title: String
    let bodyText: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(bodyText.isEmpty ? placeholder : bodyText)
                .font(.body)
                .foregroundStyle(bodyText.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: LiveTranslateViewModel
    @EnvironmentObject private var modelManager: ModelManager

    var body: some View {
        NavigationStack {
            List {
                speechOutputSection

                Section("Speech Recognition") {
                    Picker(
                        "Speech Recognition Engine",
                        selection: Binding(
                            get: { modelManager.selectedASREngine },
                            set: { modelManager.select(asr: $0) }
                        )
                    ) {
                        ForEach(ASREngine.allCases) { engine in
                            Text(speechRecognitionLabel(for: engine))
                                .tag(engine)
                        }
                    }
                }

                if modelManager.selectedASREngine == .senseVoice {
                    Section("SenseVoice Speech Recognition") {
                        Picker(
                            "Backend",
                            selection: Binding(
                                get: { modelManager.selectedSenseVoiceBackend },
                                set: { modelManager.selectSenseVoiceBackend($0) }
                            )
                        ) {
                            ForEach(SenseVoiceBackend.allCases) { backend in
                                Text(backend.displayName)
                                    .tag(backend)
                            }
                        }

                        Text(modelManager.selectedSenseVoiceBackendStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker(
                            "Recognition Language",
                            selection: Binding(
                                get: { modelManager.selectedSenseVoiceLanguage },
                                set: { modelManager.selectSenseVoiceLanguage($0) }
                            )
                        ) {
                            ForEach(SenseVoiceLanguageOption.allCases) { option in
                                Text(option.displayName)
                                    .tag(option)
                            }
                        }

                        Text("Match Source Language follows the current From language. Languages outside SenseVoice's bundled set fall back to auto detection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Translation") {
                    Toggle(
                        "Translation",
                        isOn: Binding(
                            get: { viewModel.isTranslationEnabled },
                            set: { viewModel.setTranslationEnabled($0) }
                        )
                    )

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

                Section("Models") {
                    NavigationLink("Download Models") {
                        ModelManagementView()
                            .environmentObject(modelManager)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
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

    private func speechRecognitionLabel(for engine: ASREngine) -> String {
        modelManager.canUse(engine) ? engine.displayName : "\(engine.displayName) (Install model)"
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    let modelManager = ModelManager()
    LiveTranslateView()
        .environmentObject(modelManager)
        .environmentObject(LiveTranslateViewModel(modelManager: modelManager))
}
