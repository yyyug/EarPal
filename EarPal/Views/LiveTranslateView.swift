import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct LiveTranslateView: View {
    @EnvironmentObject private var viewModel: LiveTranslateViewModel
    @EnvironmentObject private var modelManager: ModelManager
    #if canImport(Translation)
    @State private var translationConfiguration: TranslationSession.Configuration?
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    languageBar
                    engineSummary
                    transcriptCard
                    translationCard
                    primaryAction
                    utilityRow
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
            .sheet(isPresented: $viewModel.isShowingAudioOptions) {
                AudioOptionsSheet()
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $viewModel.isShowingHistory) {
                HistorySheet()
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $viewModel.isShowingModelManagement) {
                ModelManagementView()
                    .environmentObject(modelManager)
            }
            .onChange(of: viewModel.pendingAppleTranslationText) { _, _ in
                triggerAppleTranslationIfNeeded()
            }
            .onChange(of: viewModel.sourceLanguage) { _, _ in
                triggerAppleTranslationIfNeeded(forceRebuild: true)
            }
            .onChange(of: viewModel.targetLanguage) { _, _ in
                triggerAppleTranslationIfNeeded(forceRebuild: true)
            }
            .onChange(of: modelManager.selectedTranslationEngine) { _, _ in
                viewModel.refreshTranslationIfNeeded()
                triggerAppleTranslationIfNeeded(forceRebuild: true)
            }
            .modifier(
                AppleTranslationTaskModifier(
                    configuration: appleTranslationConfigurationBinding,
                    sourceText: viewModel.pendingAppleTranslationText,
                    onTranslated: { translatedText, sourceText in
                        viewModel.receiveAppleTranslation(translatedText, sourceText: sourceText)
                    },
                    onUnavailable: {
                        viewModel.handleAppleTranslationUnavailable()
                    },
                    onFailure: { error in
                        viewModel.handleAppleTranslationFailure(error)
                    }
                )
            )
        }
    }

    private var languageBar: some View {
        HStack(spacing: 12) {
            LanguageMenu(
                title: "From",
                selection: $viewModel.sourceLanguage,
                options: viewModel.languageOptions
            )

            Button {
                viewModel.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.8), in: Circle())
            }
            .accessibilityLabel("Swap languages")

            LanguageMenu(
                title: "To",
                selection: $viewModel.targetLanguage,
                options: viewModel.languageOptions
            )
        }
    }

    private var engineSummary: some View {
        HStack(spacing: 12) {
            EngineBadge(title: "ASR", value: modelManager.selectedASREngine.displayName)
            EngineBadge(title: "Translate", value: modelManager.selectedTranslationEngine.displayName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptCard: some View {
        ContentCard(title: "What I Heard", bodyText: viewModel.transcriptText, placeholder: "Incoming speech will appear here.")
    }

    private var translationCard: some View {
        ContentCard(
            title: "Translation",
            bodyText: viewModel.translatedText,
            placeholder: viewModel.statusMessage.isEmpty ? "Translated speech will appear here." : viewModel.statusMessage
        )
    }

    private var primaryAction: some View {
        Button {
            Task {
                await viewModel.toggleListening()
            }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: viewModel.isListening ? "stop.circle.fill" : "waveform.circle.fill")
                    .font(.system(size: 42))
                Text(viewModel.isListening ? "Stop Listening" : "Start Listening")
                    .font(.title2.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .foregroundStyle(Color.white)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(viewModel.isListening ? Color.red : Color.black)
            )
        }
        .accessibilityHint("Starts or stops live listening for translation.")
    }

    private var utilityRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $viewModel.autoSpeak) {
                Text("Auto Speak")
                    .font(.headline)
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)

            Button("Audio Options") {
                viewModel.isShowingAudioOptions = true
            }
            .buttonStyle(.bordered)

            Button("Models") {
                viewModel.isShowingModelManagement = true
            }
            .buttonStyle(.bordered)

            Button("History") {
                viewModel.isShowingHistory = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func triggerAppleTranslationIfNeeded(forceRebuild: Bool = false) {
        guard modelManager.selectedTranslationEngine == .apple else {
            #if canImport(Translation)
            translationConfiguration = nil
            #endif
            return
        }

        guard !viewModel.pendingAppleTranslationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            #if canImport(Translation)
            translationConfiguration = nil
            #endif
            return
        }

        #if canImport(Translation)
        guard #available(iOS 17.4, *) else {
            viewModel.handleAppleTranslationUnavailable()
            return
        }

        if translationConfiguration == nil || forceRebuild {
            translationConfiguration = TranslationSession.Configuration(
                source: .init(identifier: viewModel.sourceLanguage.id),
                target: .init(identifier: viewModel.targetLanguage.id)
            )
        } else {
            translationConfiguration?.invalidate()
        }
        #else
        viewModel.handleAppleTranslationUnavailable()
        #endif
    }

    #if canImport(Translation)
    private var appleTranslationConfigurationBinding: Binding<TranslationSession.Configuration?> {
        $translationConfiguration
    }
    #else
    private var appleTranslationConfigurationBinding: Binding<Never?> {
        .constant(nil)
    }
    #endif
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

private struct EngineBadge: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.8), in: Capsule())
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

private struct AudioOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: LiveTranslateViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speech Speed")
                        Slider(value: $viewModel.speechRate, in: 0.2...0.8, step: 0.05)
                        Text(viewModel.speechRate.formatted(.number.precision(.fractionLength(2))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Voice", selection: $viewModel.selectedVoiceLabel) {
                        ForEach(viewModel.voiceOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }

                    Toggle("Auto Speak", isOn: $viewModel.autoSpeak)
                }
            }
            .navigationTitle("Audio Options")
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

private struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: LiveTranslateViewModel

    var body: some View {
        NavigationStack {
            List {
                if viewModel.history.isEmpty {
                    Text("No saved conversations yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.history) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.transcript)
                                .font(.body.weight(.medium))
                            Text(item.translation)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Clear") {
                        viewModel.history.removeAll()
                    }
                    .disabled(viewModel.history.isEmpty)
                }
            }
        }
    }
}

private struct AppleTranslationTaskModifier: ViewModifier {
    #if canImport(Translation)
    @Binding var configuration: TranslationSession.Configuration?
    let sourceText: String
    let onTranslated: (String, String) -> Void
    let onUnavailable: () -> Void
    let onFailure: (Error) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17.4, *) {
            content.translationTask(configuration) { session in
                let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }

                do {
                    let response = try await session.translate(text)
                    await MainActor.run {
                        onTranslated(response.targetText, text)
                    }
                } catch {
                    await MainActor.run {
                        onFailure(error)
                    }
                }
            }
        } else {
            content.onAppear(perform: onUnavailable)
        }
    }
    #else
    let configuration: Binding<Never?>
    let sourceText: String
    let onTranslated: (String, String) -> Void
    let onUnavailable: () -> Void
    let onFailure: (Error) -> Void

    func body(content: Content) -> some View {
        content.onAppear(perform: onUnavailable)
    }
    #endif
}

#Preview {
    let modelManager = ModelManager()
    LiveTranslateView()
        .environmentObject(modelManager)
        .environmentObject(LiveTranslateViewModel(modelManager: modelManager))
}
