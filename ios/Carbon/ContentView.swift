// Placeholder root view for M1 phase 1. Replaced by the control room in phase 3.

import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            DotGridBackground()
            VStack(alignment: .leading, spacing: Metrics.grid * 2) {
                Text("01 / CARBON").tacturaLabel()
                Text("CARBON")
                    .font(Typeface.display(56))
                    .foregroundStyle(Palette.text)
                Text("Carbon copy of whatever is in front of you.")
                    .font(Typeface.body(17))
                    .foregroundStyle(Palette.textMuted)
                Text("M1 · FOUNDATION")
                    .tacturaLabel(11, color: Palette.text)
                    .padding(.horizontal, Metrics.grid * 2)
                    .padding(.vertical, Metrics.grid)
                    .overlay(ChamferShape().stroke(Palette.lineStrong, lineWidth: Metrics.hairline))
            }
            .padding(Metrics.grid * 3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
