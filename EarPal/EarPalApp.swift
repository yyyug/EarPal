import SwiftUI

@main
struct EarPalApp: App {
    @StateObject private var modelManager: ModelManager
    @StateObject private var viewModel: LiveTranslateViewModel

    init() {
        let modelManager = ModelManager()
        _modelManager = StateObject(wrappedValue: modelManager)
        _viewModel = StateObject(wrappedValue: LiveTranslateViewModel(modelManager: modelManager))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(modelManager)
                .environmentObject(viewModel)
        }
    }
}
