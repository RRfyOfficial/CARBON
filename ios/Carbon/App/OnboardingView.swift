// The setup checklist (SPEC 6.6, M5): shown on first run and from 04 / SETTINGS. Each row re-checks
// itself while the sheet is open, and a row that isn't done says exactly how to fix it.
// Registration goes through Developer Mode in Meta AI, not a Developer Center app (SPEC 11.5).

import CoreBluetooth
import SwiftUI

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var bluetooth = CBManager.authorization

    var body: some View {
        let session = store.session
        ZStack {
            DotGridBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.grid * 3) {
                    Text("CARBON").font(Typeface.display(40)).foregroundStyle(Palette.text)
                    Text("Your glasses are the camera and the screen. This phone reads the text and puts it on a clipboard: this phone's, or your laptop's.")
                        .font(Typeface.body(16))
                        .foregroundStyle(Palette.textMuted)
                    Text("SETUP CHECKLIST").tacturaLabel(11)

                    row("01", "META AI", done: session.isRegistered,
                        fix: session.registrationProblem
                            ?? "NEEDS DEVELOPER MODE IN META AI: SETTINGS › APP INFO › TAP THE VERSION NUMBER 5 TIMES. THEN CONNECT HERE",
                        problem: session.registrationProblem != nil,
                        action: ("CONNECT TO META AI", { session.register() }))

                    row("02", "GLASSES", done: session.glasses.level == .ready,
                        fix: glassesFix, problem: session.glasses.level == .error, action: nil)

                    row("03", "GLASSES CAMERA", done: session.cameraAllowed == true,
                        fix: session.cameraProblem ?? "WEAR THE GLASSES, UNFOLDED, SO META AI CAN ASK",
                        problem: session.cameraProblem != nil,
                        action: ("ALLOW THE GLASSES CAMERA", { Task { _ = await session.ensureCameraPermission() } }))

                    row("04", "BLUETOOTH", done: bluetooth == .allowedAlways,
                        fix: bluetooth == .notDetermined ? "CARBON ASKS FOR BLUETOOTH WHEN IT STARTS. ALLOW IT"
                            : "TURN IT ON IN SETTINGS › CARBON › BLUETOOTH. CARBON NEEDS IT FOR THE GLASSES AND THE LAPTOP",
                        problem: bluetooth == .denied || bluetooth == .restricted, action: nil)

                    row("05", "LAPTOP (OPTIONAL)", done: store.link.laptop != nil,
                        fix: "INSTALL CARBON COMPANION ON YOUR WINDOWS PC, KEEP CARBON OPEN HERE, AND CLICK PAIR A PHONE THERE",
                        problem: false, action: nil, optional: true)

                    ChamferButton(title: "DONE", style: .primary, height: 56) {
                        store.onboardingDone = true
                        dismiss()
                    }
                }
                .padding(Metrics.grid * 3)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(!session.isRegistered)
        .task {
            // Live re-checks while the sheet is open: the wearer fixes things in other apps.
            while !Task.isCancelled {
                bluetooth = CBManager.authorization
                if session.isRegistered, session.cameraAllowed != true { await session.refreshCameraPermission() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var glassesFix: String {
        switch store.session.glasses.reason {
        case "NO DISPLAY GLASSES FOUND": "PAIR YOUR META RAY-BAN DISPLAY GLASSES IN META AI, THEN UNFOLD THEM NEAR THE PHONE"
        case "NOT CONNECTED": "UNFOLD THE GLASSES, KEEP THEM NEAR THE PHONE, AND CHECK BLUETOOTH IS ON"
        case "UPDATE THE GLASSES APP IN META AI": "WEAR THE GLASSES, THEN IN META AI OPEN APP CONNECTIONS AND UPDATE"
        case "CHECKING": "CHECKING THE GLASSES…"
        case "": "CONNECT TO META AI FIRST"
        default: "UPDATE THE GLASSES IN META AI, THEN TRY AGAIN"
        }
    }

    private func row(_ number: String, _ title: String, done: Bool, fix: String, problem: Bool,
                     action: (title: String, run: () -> Void)?, optional: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Metrics.grid) {
            HStack {
                Text("\(number) / \(title)").tacturaLabel(11, color: Palette.text)
                Spacer()
                Text(done ? "DONE" : optional ? "LATER" : "TO DO")
                    .tacturaLabel(10, color: done ? Palette.text : problem ? Palette.accent : Palette.textDim)
            }
            if !done {
                Text(fix).tacturaLabel(10, color: problem ? Palette.accent : Palette.textMuted)
                if let action {
                    ChamferButton(title: action.title, action: action.run)
                }
            }
        }
    }
}
