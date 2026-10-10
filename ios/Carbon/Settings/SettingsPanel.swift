// 04 / SETTINGS (SPEC 6.5): TARGET and PASTE, the paired computer, and the debug toggle.
// LINE BREAKS and SOUND become settings in M3.

import SwiftUI

struct SettingsPanel: View {
    @Environment(AppStore.self) private var store
    @State private var forgotten: String?

    var body: some View {
        @Bindable var store = store
        Panel(number: "04", title: "SETTINGS") {
            choice("TARGET", options: [("PHONE", false), (store.link.laptop?.name.uppercased() ?? "LAPTOP", true)],
                   selected: store.usesLaptop, enabled: store.link.laptop != nil) { store.chooseTarget(laptop: $0) }
            if let note = store.targetSwitchNote {
                Text(note).tacturaLabel(9, color: Palette.text)
            }
            if store.usesLaptop {
                choice("PASTE", options: [("CLIPBOARD", PasteMode.clipboard), ("AUTOPASTE", .autopaste)],
                       selected: store.pasteMode, enabled: true) { store.pasteMode = $0 }
            }
            computer
            row("LINE BREAKS", "ON")
            row("SOUND", "ON")
            Toggle(isOn: $store.keepCaptures) {
                Text("KEEP CAPTURES (DEBUG)").tacturaLabel(11, color: Palette.text)
            }
            .tint(Palette.accent)
            Text("LINE BREAKS AND SOUND BECOME SETTINGS IN M3").tacturaLabel(9, color: Palette.textDim)
        }
    }

    /// The paired computer, or how to pair one (PROTOCOL.md Section 3).
    @ViewBuilder private var computer: some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            if let laptop = store.link.laptop {
                row("COMPUTER", "\(laptop.name.uppercased()) · \(store.link.isLinked ? "LINKED" : "NOT CONNECTED")")
                ChamferButton(title: "FORGET COMPUTER") {
                    forgotten = laptop.name.uppercased()
                    store.forgetLaptop()
                }
            } else {
                row("COMPUTER", "NONE")
                Text("TO PAIR: KEEP CARBON OPEN HERE, THEN CLICK PAIR A PHONE IN CARBON COMPANION ON THE COMPUTER. TAP PAIR WHEN THE PHONE ASKS.")
                    .tacturaLabel(9, color: Palette.textMuted)
            }
            if let forgotten {
                Text("ALSO REMOVE \(forgotten) IN SETTINGS › BLUETOOTH › (i) › FORGET THIS DEVICE, AND FORGET THE PHONE IN THE COMPANION.")
                    .tacturaLabel(9, color: Palette.accent)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).tacturaLabel(11)
            Spacer()
            Text(value).font(Typeface.body(15)).foregroundStyle(Palette.text)
        }
    }

    /// A label with two or more chamfered options; the selected one is outlined in white.
    private func choice<Value: Equatable>(_ label: String, options: [(String, Value)], selected: Value, enabled: Bool,
                                          set: @escaping (Value) -> Void) -> some View {
        HStack(spacing: Metrics.grid) {
            Text(label).tacturaLabel(11)
            Spacer()
            ForEach(options.indices, id: \.self) { index in
                let (title, value) = options[index]
                Button { set(value) } label: {
                    Text(title)
                        .tacturaLabel(10, color: value == selected ? Palette.text : Palette.textMuted)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .overlay(ChamferShape(cut: 6).stroke(value == selected ? Palette.text : Palette.line, lineWidth: Metrics.hairline))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled || value == selected ? 1 : 0.4)
            }
        }
    }
}
