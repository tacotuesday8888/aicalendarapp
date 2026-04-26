import SwiftUI

@main
struct aicalendarappApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessionViewModel: AppSessionViewModel
    private let container: AppContainer

    init() {
        let container = AppContainer.shared
        self.container = container
        _sessionViewModel = StateObject(wrappedValue: AppSessionViewModel(container: container))
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(container: container, viewModel: sessionViewModel)
                .tint(AppTheme.primary)
                .onOpenURL { url in
                    sessionViewModel.handle(url: url)
                }
        }
    }
}
