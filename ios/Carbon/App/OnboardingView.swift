// First run (SPEC 6.6): register with the Meta AI app, allow the glasses camera, and one line on
// host vs target. Developer Mode in Meta AI covers registration (SPEC 11.5).

import SwiftUI

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var cameraGranted = false
    @State private var cameraAsked = false

    var body: some View {
        ZStack {
            DotGridBackground()
            VStack(alignment: .leading, spacing: Metrics.grid * 3) {
                Text("CARBON").font(Typeface.display(40)).foregroundStyle(Palette.text)
                Text("Your glasses are the camera and the screen. This phone reads the text and puts it on a clipboard: this phone's for now, your laptop's later.")
                    .font(Typeface.body(16))
                    .foregroundStyle(Palette.textMuted)

                step("01", "CONNECT TO META AI",
                     detail: "Developer Mode must be on in Meta AI (Settings › App Info › tap the version 5 times).",
                     done: store.session.isRegistered) {
                    store.session.register()
                }
                step("02", "ALLOW THE GLASSES CAMERA",
                     detail: cameraAsked && !cameraGranted ? "Not granted yet. Put the glasses on and try again." : "Wear the glasses, unfolded, so Meta AI can ask.",
                     done: cameraGranted) {
                    Task {
                        cameraGranted = await store.session.ensureCameraPermission()
                        cameraAsked = true
                    }
                }

                Spacer()
                ChamferButton(title: "DONE", style: .primary, height: 56) {
                    store.onboardingDone = true
                    dismiss()
                }
            }
            .padding(Metrics.grid * 3)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(!store.session.isRegistered)
    }

    private func step(_ number: String, _ title: String, detail: String, done: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            HStack {
                Text("\(number) / \(title)").tacturaLabel(11, color: Palette.text)
                Spacer()
                Text(done ? "DONE" : "TO DO").tacturaLabel(10, color: done ? Palette.text : Palette.textDim)
            }
            Text(detail).font(Typeface.body(14)).foregroundStyle(Palette.textMuted)
            if !done {
                ChamferButton(title: title, action: action)
            }
        }
    }
}
