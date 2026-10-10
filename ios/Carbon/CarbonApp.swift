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
                // Lock state in the log, to line up with background scans and copy-on-open.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    store.log.add("phone locked")
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    store.log.add("phone unlocked")
                }
        }
        .onChange(of: scenePhase) { _, phase in
            store.log.add("scene → \(phase)")
            if phase == .active { store.appBecameActive(via: "scene") }
        }
    }
}
