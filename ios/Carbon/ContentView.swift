// The phone app is a minimal control room (SPEC 6.6): one scrolling screen of numbered panels.
// The glasses are the real app.

import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var showOnboarding = false

    var body: some View {
        ZStack {
            DotGridBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.grid * 2) {
                    header
                    SessionPanel(showOnboarding: $showOnboarding)
                    LastScanPanel()
                    HistoryPanel()
                    SettingsPanel()
                    DiagnosticsPanel()
                }
                .padding(Metrics.grid * 2)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .onAppear {
            if !store.onboardingDone { showOnboarding = true }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("CARBON")
                .font(Typeface.display(34))
                .foregroundStyle(Palette.text)
            Spacer()
            Text("CONTROL ROOM").tacturaLabel(10)
        }
        .padding(.top, Metrics.grid)
    }
}
