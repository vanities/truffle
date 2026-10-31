import SwiftUI
import os

@main
struct TruffleApp: App {
    private let environment = AppEnvironment.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.library)
                .environment(environment.player)
                .environment(environment.settings)
                .environment(environment.season)
                .environment(environment.router)
                .environment(environment.stats)
        }
        .onChange(of: scenePhase) { _, phase in
            Logger.ui.debug("[app] scene phase \(String(describing: phase), privacy: .public)")
            if phase == .background { environment.player.save() }
        }
    }
}
