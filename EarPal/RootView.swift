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
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $selectedTab) { tab in
                Label(tab.displayName, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationTitle("EarPal")
        } detail: {
            switch selectedTab {
            case .translate:
                LiveTranslateView()
            case .history:
                NavigationStack {
                    HistoryView()
                }
            }
        }
    }
}

#Preview {
    let modelManager = ModelManager()
    RootView()
        .environmentObject(modelManager)
        .environmentObject(LiveTranslateViewModel(modelManager: modelManager))
}
