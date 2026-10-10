// CARBON: look at a slide through the glasses, pinch, and the text lands on your phone or laptop.

import MWDATCore
import SwiftUI
import UIKit

@main
struct CarbonApp: App {
    @State private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must run once, before anything touches Wearables.shared.
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Meta Wearables toolkit failed to configure: \(error)")
        }
        _store = State(initialValue: AppStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task { store.boot() }
                .onOpenURL { store.session.handleURL($0) }
                // Posted once the app is fully active, which can be after the scene phase changes.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    store.appBecameActive(via: "app")
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.appBecameActive(via: "scene") }
        }
    }
}
