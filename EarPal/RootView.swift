import SwiftUI

struct RootView: View {
    var body: some View {
        LiveTranslateView()
    }
}

#Preview {
    let modelManager = ModelManager()
    RootView()
        .environmentObject(modelManager)
        .environmentObject(LiveTranslateViewModel(modelManager: modelManager))
}
