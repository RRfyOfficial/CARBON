// Tactura's signature shape: a rectangle with one 45° chamfered top-right corner.

import SwiftUI

nonisolated struct ChamferShape: Shape {
    var cut: CGFloat = Metrics.chamfer

    func path(in rect: CGRect) -> Path {
        let cut = min(cut, rect.width, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
