// Pre-rendered glasses images, drawn in the app with the bundled Tactura fonts rather than
// by tools/render_assets.py: the fonts are already here, nothing is hosted, and Image(image:) embeds
// the picture in the screen (M0 U6). Black is see-through on the additive display, and signal red
// appears only inside these images. Both stay far below the 600 × 600 frame.

import UIKit

enum GlassesArt {
    /// "CARBON" in Doto at 480 × 96 (46,080 px), for the boot screen.
    static let wordmark: UIImage = render(CGSize(width: 480, height: 96)) { size in
        let wghtAxis = 0x7767_6874  // 'wght'
        let descriptor = UIFontDescriptor(name: "Doto-Black", size: 76).addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: 900],
        ])
        let text = NSAttributedString(string: "CARBON", attributes: [
            .font: UIFont(descriptor: descriptor, size: 76),
            .foregroundColor: white,
            .kern: 8,
        ])
        let bounds = text.size()
        text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
    }

    /// A 96 × 96 dot-matrix "!" in signal red, for error screens that need RETRY.
    static let errorGlyph: UIImage = render(CGSize(width: 96, height: 96)) { size in
        // Two dot columns: seven dots, a gap, then one dot.
        let rows = [0, 1, 2, 3, 4, 5, 6, 8]
        let pitch: CGFloat = 10, dot: CGFloat = 7.5
        let top = (size.height - pitch * 9) / 2 + (pitch - dot) / 2
        let left = (size.width - pitch * 2) / 2 + (pitch - dot) / 2
        red.setFill()
        for row in rows {
            for column in 0..<2 {
                UIBezierPath(ovalIn: CGRect(x: left + CGFloat(column) * pitch, y: top + CGFloat(row) * pitch,
                                            width: dot, height: dot)).fill()
            }
        }
    }

    private static let white = UIColor(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF1 / 255, alpha: 1)
    private static let red = UIColor(red: 0xFF / 255, green: 0x3B / 255, blue: 0x2F / 255, alpha: 1)

    /// One image at exactly `size` pixels on black (black is transparent on the glasses).
    private static func render(_ size: CGSize, draw: (CGSize) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            draw(size)
        }
    }
}
