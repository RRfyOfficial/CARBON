// Near-black background with a faint dot grid, about 3% opacity.

import SwiftUI

struct DotGridBackground: View {
    var spacing: CGFloat = Metrics.grid * 2

    var body: some View {
        Canvas { context, size in
            let dot = Path(ellipseIn: CGRect(x: -0.75, y: -0.75, width: 1.5, height: 1.5))
            let shading = GraphicsContext.Shading.color(Palette.text.opacity(0.035))
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                    context.fill(dot.offsetBy(dx: x, dy: y), with: shading)
                }
            }
        }
        .background(Palette.bg)
        .ignoresSafeArea()
    }
}
