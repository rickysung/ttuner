import SwiftUI
import UIKit

@main
struct ttunerApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: appState)
                .onAppear {
                    if appState.settings.keepScreenOn {
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
                }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
}
