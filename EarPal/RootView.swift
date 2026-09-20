import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case transcription
    case history
    case settings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcription: return "Transcription"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .transcription: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var viewModel: LiveTranslateViewModel
    @EnvironmentObject private var jobRepository: JobRepository
    @State private var selectedTab: SidebarTab = .transcription

    var body: some View {
        TabView(selection: $selectedTab) {
            LiveTranslateView()
                .tabItem {
                    Label(SidebarTab.transcription.displayName, systemImage: SidebarTab.transcription.icon)
                }
                .tag(SidebarTab.transcription)

            NavigationStack {
                HistoryView(repository: jobRepository)
            }
            .tabItem {
                Label(SidebarTab.history.displayName, systemImage: SidebarTab.history.icon)
            }
            .tag(SidebarTab.history)

            SettingsView()
                .tabItem {
                    Label(SidebarTab.settings.displayName, systemImage: SidebarTab.settings.icon)
                }
                .tag(SidebarTab.settings)
        }
    }
}

#Preview {
    let modelManager = ModelManager()
    let jobRepository = JobRepository.shared
    RootView()
        .environmentObject(modelManager)
        .environmentObject(LiveTranslateViewModel(modelManager: modelManager, jobRepository: jobRepository))
        .environmentObject(jobRepository)
}
