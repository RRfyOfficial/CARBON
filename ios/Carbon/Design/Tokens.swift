// Tactura design tokens (SPEC 7.2). The CSS block in the SPEC is the source of truth;
// keep these values identical to it and to the companion's Tokens.xaml.

import SwiftUI

nonisolated enum Palette {
    static let bg = Color(hex: 0x0A0A0B)
    static let surface = Color(hex: 0x111113, opacity: 0.72)
    static let surfaceSolid = Color(hex: 0x111113)
    static let surface2 = Color(hex: 0x18181B)
    static let line = Color(hex: 0x2A2A2F)          // 1 px hairlines
    static let lineStrong = Color(hex: 0x3D3D44)
    static let text = Color(hex: 0xF4F4F1)
    static let textMuted = Color(hex: 0x8C8C93)
    static let textDim = Color(hex: 0x55555C)
    static let accent = Color(hex: 0xFF3B2F)        // signal red: only fresh events and errors
    static let accentSoft = Color(hex: 0xFF3B2F, opacity: 0.14)
    static let ok = text                            // success is white, not green
}

nonisolated enum Metrics {
    static let radius: CGFloat = 0
    static let chamfer: CGFloat = 10                // 45° cut, top-right corner
    static let grid: CGFloat = 8
    static let hairline: CGFloat = 1
}

nonisolated enum Motion {
    static let fast: Double = 0.12
    static let med: Double = 0.18
    static let flash: Double = 0.30
    /// cubic-bezier(0.2, 0.8, 0.2, 1), the Tactura default easing.
    static func easeOut(_ duration: Double = med) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    }
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
