// 01 / SESSION (SPEC 6.6): START / STOP / RESUME and the status badges. Tap a badge for its reason.

import SwiftUI

struct SessionPanel: View {
    @Environment(AppStore.self) private var store
    @Binding var showOnboarding: Bool
    @State private var selectedBadge: String?

    var body: some View {
        let session = store.session
        Panel(number: "01", title: "SESSION", trailing: phaseText) {
            ChamferButton(title: buttonTitle, style: .primary, height: 64) {
                if !session.isRegistered && session.phase == .stopped {
                    showOnboarding = true
                } else {
                    store.startOrStop()
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Metrics.grid) {
                badge("GLASSES", session.glasses)
                badge("DISPLAY", session.display)
                badge("CAMERA", session.camera)
                badge("INPUTS", session.inputs)
            }

            if let selectedBadge, let reason = reason(for: selectedBadge), !reason.isEmpty {
                Text("\(selectedBadge) · \(reason)").tacturaLabel(10)
            }
        }
    }

    private func badge(_ name: String, _ badge: Badge) -> some View {
        StatusBadge(name: name, badge: badge)
            .onTapGesture { selectedBadge = selectedBadge == name ? nil : name }
    }

    private func reason(for name: String) -> String? {
        let session = store.session
        switch name {
        case "GLASSES": return session.glasses.reason
        case "DISPLAY": return session.display.reason
        case "CAMERA": return session.camera.reason
        case "INPUTS": return session.inputs.reason
        default: return nil
        }
    }

    private var buttonTitle: String {
        let session = store.session
        switch session.phase {
        case .stopped: return !session.isRegistered ? "CONNECT TO META AI" : (session.hasRun ? "RESUME" : "START")
        case .waitingForGlasses: return "WAITING FOR GLASSES · STOP"
        case .starting: return "STARTING · STOP"
        case .running: return "STOP"
        case .paused: return "PAUSED · STOP"
        }
    }

    private var phaseText: String {
        switch store.session.phase {
        case .stopped: "OFF"
        case .waitingForGlasses: "WAITING"
        case .starting: "STARTING"
        case .running: store.isScanning ? "SCANNING" : "LIVE"
        case .paused: "PAUSED"
        }
    }
}
