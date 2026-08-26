import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case translate
    case history

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .translate: return "Translate"
        case .history: return "History"
        }
    }

    var icon: String {
        switch self {
        case .translate: return "waveform"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var viewModel: LiveTranslateViewModel
    @State private var selectedTab: SidebarTab = .translate

    var body: some View {
        TabView(selection: $selectedTab) {
            LiveTranslateView()
                .tabItem {
                    Label(SidebarTab.translate.displayName, systemImage: SidebarTab.translate.icon)
                }
                .tag(SidebarTab.translate)

            NavigationStack {
                HistoryView()
            }
            .tabItem {
                Label(SidebarTab.history.displayName, systemImage: SidebarTab.history.icon)
            }
            .tag(SidebarTab.history)
        }
    }
}

#Preview {
    let modelManager = ModelManager()
    RootView()
        .environmentObject(modelManager)
        .environmentObject(LiveTranslateViewModel(modelManager: modelManager))
}
