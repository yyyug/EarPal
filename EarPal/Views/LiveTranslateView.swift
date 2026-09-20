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
            .fullScreenCover(isPresented: $showPresenterMode) {
                PresenterView(
                    text: viewModel.translatedText.isEmpty ? viewModel.transcriptText : viewModel.translatedText,
                    onDismiss: { showPresenterMode = false }
                )
            }
            .overlay(alignment: .topLeading) {
                appleTranslationBridge
            }
            .overlay(alignment: .bottomTrailing) {
                PictureInPictureHostView(displayLayer: viewModel.pictureInPicture.displayLayer)
                    .frame(width: 16, height: 9)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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
            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
ForEach(AudioCaptureSourceOption.allCases.filter { option in
                option == .screenAudio ? viewModel.screenAudioSupported : true
            }) { source in
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

    @ViewBuilder
    private var appleTranslationBridge: some View {
        if modelManager.selectedTranslationEngine == .apple,
           let request = viewModel.appleTranslationRequest {
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

#Preview {
    let modelManager = ModelManager()
    LiveTranslateView()
        .environmentObject(modelManager)
        .environmentObject(LiveTranslateViewModel(modelManager: modelManager))
}
