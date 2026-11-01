import SwiftUI

@main
@MainActor
struct VXTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var dependencies: AppDependencies

    init() {
        let repository = HtmlScraperVideoRepository()
        let resolver = NativeStreamResolver(repository: repository)
        _dependencies = State(initialValue: AppDependencies(repository: repository, resolver: resolver))
    }

    var body: some Scene {
        WindowGroup {
            HomeView(dependencies: dependencies)
                .tint(.vxAccent)
                .preferredColorScheme(colorScheme)
                .task { AppOrientation.browse() }
        }
    }

    private var colorScheme: ColorScheme? {
        switch AppSettings.shared.themeMode {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}
