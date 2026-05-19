import SwiftUI
import UIKit

@main
struct ttunerApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(state: appState)
                .onAppear {
                    if appState.settings.keepScreenOn {
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
                }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
                .onChange(of: scenePhase) { _, newPhase in
                    // Backgrounding (or losing active state ahead of
                    // backgrounding) is implicit "I want live data again":
                    // PIP keeps rendering while the app sleeps, so a stuck
                    // scrub would leave the floating tuner stuck on history.
                    if newPhase != .active {
                        appState.endScrubIfNeeded()
                    }
                }
        }
    }
}
