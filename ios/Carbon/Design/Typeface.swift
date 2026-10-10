// The three Tactura faces (SPEC 4, 7.2), bundled in Resources/Fonts and registered through
// UIAppFonts in Config/Carbon-Info.plist. Doto and Space Grotesk are variable fonts whose default
// instances are Black and Light, so weights are always set explicitly through the 'wght' axis.

import SwiftUI
import UIKit

enum Typeface {
    /// Doto: readouts, big numbers, the pairing code.
    static func display(_ size: CGFloat, weight: CGFloat = 700) -> Font {
        variable(postScriptName: "Doto-Black", size: size, weight: weight)
    }

    /// Space Mono: uppercase labels (use with `.tacturaLabel()` for tracking and case).
    static func label(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "SpaceMono-Bold" : "SpaceMono-Regular", fixedSize: size)
    }

    /// Space Grotesk: body text.
    static func body(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        variable(postScriptName: "SpaceGrotesk-Light", size: size, weight: weight)
    }

    private static func variable(postScriptName: String, size: CGFloat, weight: CGFloat) -> Font {
        let wghtAxis = 0x7767_6874  // 'wght'
        let descriptor = UIFontDescriptor(name: postScriptName, size: size).addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight],
        ])
        return Font(UIFont(descriptor: descriptor, size: size) as CTFont)
    }
}

extension View {
    /// Tactura label: Space Mono, uppercase, 0.08em tracking, muted (SPEC 7.2).
    func tacturaLabel(_ size: CGFloat = 11, color: Color = Palette.textMuted) -> some View {
        font(Typeface.label(size))
            .tracking(size * 0.08)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
