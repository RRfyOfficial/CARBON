// Tactura building blocks for the phone app (SPEC 6.6, 7.2): numbered panels with hairlines,
// chamfered buttons and badges, Doto readouts. Signal red only for errors.

import SwiftUI

/// A numbered panel, like a technical manual: "01 / SESSION".
struct Panel<Content: View>: View {
    let number: String
    let title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.grid * 1.5) {
            HStack {
                Text("\(number) / \(title)").tacturaLabel(11, color: Palette.text)
                Spacer()
                if let trailing {
                    Text(trailing).tacturaLabel(10)
                }
            }
            Rectangle().fill(Palette.line).frame(height: Metrics.hairline)
            content
        }
        .padding(Metrics.grid * 2)
        .background(Palette.surface, in: ChamferShape())
        .overlay(ChamferShape().stroke(Palette.line, lineWidth: Metrics.hairline))
    }
}

struct ChamferButton: View {
    enum Style {
        case primary
        case secondary
    }

    let title: String
    var style: Style = .secondary
    var height: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.label(style == .primary ? 15 : 12, bold: style == .primary))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(style == .primary ? Palette.bg : Palette.text)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(style == .primary ? Palette.text : Color.clear, in: ChamferShape())
                .overlay(ChamferShape().stroke(style == .primary ? Color.clear : Palette.lineStrong, lineWidth: Metrics.hairline))
                .contentShape(ChamferShape())
        }
        .buttonStyle(.plain)
    }
}

/// A status badge, like Tactura's stage badges: name plus READY / OFF / ERROR.
struct StatusBadge: View {
    let name: String
    let badge: Badge

    var body: some View {
        HStack(spacing: Metrics.grid) {
            Rectangle().fill(color).frame(width: 6, height: 6)
            Text(name).tacturaLabel(10, color: Palette.text)
            Spacer(minLength: 0)
            Text(levelText).tacturaLabel(10, color: color)
        }
        .padding(.horizontal, Metrics.grid * 1.25)
        .frame(height: 30)
        .overlay(ChamferShape(cut: 6).stroke(Palette.line, lineWidth: Metrics.hairline))
    }

    private var levelText: String {
        switch badge.level {
        case .ready: "READY"
        case .off: "OFF"
        case .error: "ERROR"
        }
    }

    private var color: Color {
        switch badge.level {
        case .ready: Palette.text
        case .off: Palette.textDim
        case .error: Palette.accent
        }
    }
}

/// A big Doto number with a Space Mono label underneath.
struct Readout: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Typeface.display(28))
                .monospacedDigit()
                .foregroundStyle(Palette.text)
            Text(label).tacturaLabel(9)
        }
    }
}
