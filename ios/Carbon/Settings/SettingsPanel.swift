// 04 / SETTINGS (SPEC 6.5). M1 has only the debug toggle; the rest arrive in M2 and M3.

import SwiftUI

struct SettingsPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Panel(number: "04", title: "SETTINGS") {
            row("TARGET", "PHONE")
            row("LINE BREAKS", "ON")
            row("SOUND", "ON")
            Toggle(isOn: $store.keepCaptures) {
                Text("KEEP CAPTURES (DEBUG)").tacturaLabel(11, color: Palette.text)
            }
            .tint(Palette.accent)
            Text("TARGET, LINE BREAKS AND SOUND BECOME SETTINGS IN M2 AND M3").tacturaLabel(9, color: Palette.textDim)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).tacturaLabel(11)
            Spacer()
            Text(value).font(Typeface.body(15)).foregroundStyle(Palette.text)
        }
    }
}
