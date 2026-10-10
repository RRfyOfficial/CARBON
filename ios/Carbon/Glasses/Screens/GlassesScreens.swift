// Display views for each glasses screen (SPEC 6.2, 7.3). This file imports MWDATDisplay and not
// SwiftUI, because both define Text, Button and Image. Glasses rules: system text only, at most
// one heading and one primary button per screen, uppercase microcopy, no large bright fills.

import Foundation
import MWDATDisplay

enum GlassesScreens {
    static func main(_ model: GlassesScreen.Main, onScan: @escaping @Sendable () -> Void) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 16) {
            header(model.targetLabel)
            Button(label: "SCAN", style: .primary, iconName: .videoCamera, onClick: onScan)
            if let lastLine = model.lastLine {
                Text(lastLine, style: .meta, color: .secondary)
                Text(model.preview.joined(separator: "\n"), style: .body, color: .secondary)
            } else {
                Text("NO SCANS YET", style: .meta, color: .secondary)
            }
            if model.showCameraHint {
                Text("CAMERA BUTTON ALSO SCANS", style: .meta, color: .secondary)
            }
        }
        .padding(24)
    }

    static func scanning(_ model: GlassesScreen.Scanning) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 14, alignment: .start, crossAlignment: .center) {
            header(model.targetLabel)
            Text(model.stage.heading, style: .heading, color: .primary)
            if model.detail {
                Text("DETAIL", style: .meta, color: .secondary)
            }
            Text(rail(model.stage), style: .meta, color: .primary)
            Text(subtitle(model), style: .meta, color: .secondary)
            Text(elapsed(model.elapsed), style: .meta, color: .secondary)
        }
        .padding(24)
    }

    static func done(_ model: GlassesScreen.Done, filled: Bool) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12, alignment: .center, crossAlignment: .center) {
            Icon(name: .checkmarkCircle, style: filled ? .filled : .outline)
            Text("COPIED", style: .heading, color: .primary)
            Text("\(model.chars) CHARS · \(model.targetName) · \(model.how)", style: .meta, color: .secondary)
            Text(elapsed(model.elapsed), style: .meta, color: .secondary)
        }
        .padding(24)
    }

    static func error(
        _ code: ScanError,
        elapsed: Double?,
        onRetry: @escaping @Sendable () -> Void,
        onBack: @escaping @Sendable () -> Void
    ) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12, alignment: .center, crossAlignment: .center) {
            if code.isSafe {
                Icon(name: .checkmarkCircle, style: .outline)
            }
            Text(code.heading, style: .heading, color: .primary)
            Text(code.detail, style: .meta, color: .secondary)
            if let elapsed, code.isSafe {
                Text(Self.elapsed(elapsed), style: .meta, color: .secondary)
            }
            if !code.isSafe {
                Button(label: "RETRY", style: .primary, iconName: .twoArrowsClockwise, onClick: onRetry)
                Button(label: "BACK", style: .outline, iconName: nil, onClick: onBack)
            }
        }
        .padding(24)
    }

    // MARK: - Pieces

    private static func header(_ target: String) -> some DisplayableView {
        FlexBox(direction: .row, spacing: 8) {
            Text("CARBON", style: .meta, color: .secondary)
                .flexGrow(1)
            Text(target, style: .meta, color: .secondary)
        }
    }

    /// "■ CAPTURE  ■ TRANSFER  □ READ  □ COPY": filled up to and including the current stage.
    private static func rail(_ current: GlassesScreen.Scanning.Stage) -> String {
        let stages: [GlassesScreen.Scanning.Stage] = [.capture, .transfer, .read, .copy]
        return stages.map { "\($0 <= current ? "■" : "□") \($0.railName)" }.joined(separator: "  ")
    }

    private static func subtitle(_ model: GlassesScreen.Scanning) -> String {
        if model.stillWorking { return "STILL WORKING" }
        if model.stage == .transfer, let percent = model.transferPercent { return "TRANSFER \(percent)%" }
        return " "
    }

    private static func elapsed(_ seconds: Double) -> String {
        String(format: "T+%.1fs", seconds)
    }
}
