// CARBON: look at a slide through the glasses, pinch, and the text lands on your phone or laptop.

import MWDATCore
import SwiftUI

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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.appBecameActive() }
        }
    }
}
