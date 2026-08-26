import SwiftUI

@main
struct EarPalApp: App {
    @StateObject private var modelManager: ModelManager
    @StateObject private var viewModel: LiveTranslateViewModel
    @StateObject private var jobRepository: JobRepository

    init() {
        let modelManager = ModelManager()
        let jobRepository = JobRepository.shared
        _modelManager = StateObject(wrappedValue: modelManager)
        _jobRepository = StateObject(wrappedValue: jobRepository)
        _viewModel = StateObject(wrappedValue: LiveTranslateViewModel(
            modelManager: modelManager,
            jobRepository: jobRepository
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(modelManager)
                .environmentObject(viewModel)
                .environmentObject(jobRepository)
        }
    }
}
