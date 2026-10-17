// Display views for each glasses screen. This file imports MWDATDisplay and not
// SwiftUI, because both define Text, Button and Image. Glasses rules: system text only, at most
// one heading and one primary button per screen, uppercase microcopy, no large bright fills.

import Foundation
import MWDATDisplay

enum GlassesScreens {
    /// Actions the screens can raise; the router turns each into a `GlassesRouter.Action`.
    struct Actions: Sendable {
        var scan: @Sendable () -> Void
        var history: @Sendable () -> Void
        var settings: @Sendable () -> Void
        var newer: @Sendable () -> Void
        var older: @Sendable () -> Void
        var resend: @Sendable () -> Void
        var back: @Sendable () -> Void
        var retry: @Sendable () -> Void
        var setting: @Sendable (GlassesScreen.SettingRow) -> Void
    }

    static func main(_ model: GlassesScreen.Main, actions: Actions) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 14) {
            header(model.targetLabel)
            Button(label: "SCAN", style: .primary, iconName: .videoCamera, onClick: actions.scan)
            if let lastLine = model.lastLine {
                Text(lastLine, style: .meta, color: .secondary)
                Text(model.preview.joined(separator: "\n"), style: .body, color: .secondary)
            } else {
                Text("NO SCANS YET", style: .meta, color: .secondary)
            }
            if model.showCameraHint {
                Text("CAMERA BUTTON ALSO SCANS", style: .meta, color: .secondary)
            }
            // Model B (M0 U3): the band moves the highlight between buttons, a pinch presses one.
            FlexBox(direction: .row, spacing: 12) {
                Button(label: "HISTORY", style: .outline, iconName: nil, onClick: actions.history).flexGrow(1)
                Button(label: "SETTINGS", style: .outline, iconName: nil, onClick: actions.settings).flexGrow(1)
            }
        }
        .padding(24)
    }

    static func history(_ model: GlassesScreen.History, actions: Actions) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12) {
            FlexBox(direction: .row, spacing: 8) {
                Text("HISTORY", style: .meta, color: .secondary).flexGrow(1)
                Text(String(format: "%02d / %02d", model.index + 1, model.count), style: .meta, color: .secondary)
            }
            Text(model.meta, style: .meta, color: .secondary)
            Text(model.lines.joined(separator: "\n"), style: .body, color: .primary)
            Button(label: "RESEND", style: .primary, iconName: .twoArrowsClockwise, onClick: actions.resend)
            // Reads like a timeline: OLDER on the left, NEWER on the right; each hides at its end.
            FlexBox(direction: .row, spacing: 12) {
                if !model.isOldest {
                    Button(label: "OLDER", style: .outline, iconName: nil, onClick: actions.older).flexGrow(1)
                }
                if !model.isNewest {
                    Button(label: "NEWER", style: .outline, iconName: nil, onClick: actions.newer).flexGrow(1)
                }
                Button(label: "BACK", style: .outline, iconName: nil, onClick: actions.back).flexGrow(1)
            }
        }
        .padding(24)
    }

    /// Each row is an outline button reading "LABEL · VALUE"; a pinch cycles it.
    static func settings(_ model: GlassesScreen.Settings, actions: Actions) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 10) {
            FlexBox(direction: .row, spacing: 8) {
                Text("SETTINGS", style: .meta, color: .secondary).flexGrow(1)
            }
            Button(label: "TARGET · \(model.target)", style: .outline, iconName: nil, onClick: { actions.setting(.target) })
            if let paste = model.paste {
                Button(label: "PASTE · \(paste)", style: .outline, iconName: nil, onClick: { actions.setting(.paste) })
            }
            Button(label: "LINE BREAKS · \(model.lineBreaks ? "ON" : "OFF")", style: .outline, iconName: nil, onClick: { actions.setting(.lineBreaks) })
            Button(label: "SOUND · \(model.sound ? "ON" : "OFF")", style: .outline, iconName: nil, onClick: { actions.setting(.sound) })
            Button(label: "PAIR NEW COMPUTER", style: .outline, iconName: nil, onClick: { actions.setting(.pair) })
            Button(label: "BACK", style: .outline, iconName: nil, onClick: actions.back)
            Text("TIP · THE CAMERA BUTTON ALSO SCANS", style: .meta, color: .secondary)
        }
        .padding(24)
    }

    static func pairInfo(actions: Actions) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 14, alignment: .center, crossAlignment: .center) {
            Text("PAIR", style: .heading, color: .primary)
            Text("OPEN CARBON ON YOUR PHONE", style: .meta, color: .secondary)
            Text("THEN PAIR A PHONE IN CARBON COMPANION", style: .meta, color: .secondary)
            Text("TAP PAIR WHEN THE PHONE ASKS", style: .meta, color: .secondary)
            Button(label: "BACK", style: .outline, iconName: nil, onClick: actions.settings)
        }
        .padding(24)
    }

    /// The wordmark while the display starts; the image is rendered in the app (GlassesArt).
    static func boot() -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12, alignment: .center, crossAlignment: .center) {
            Image(image: GlassesArt.wordmark, sizePreset: .fill)
            Text("READY", style: .meta, color: .secondary)
        }
        .padding(24)
    }

    static func scanning(_ model: GlassesScreen.Scanning) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 14, alignment: .start, crossAlignment: .center) {
            header(model.targetLabel)
            Text(model.stage.heading(toLaptop: model.toLaptop), style: .heading, color: .primary)
            if model.detail {
                Text("DETAIL", style: .meta, color: .secondary)
            }
            Text(rail(model.stage, toLaptop: model.toLaptop), style: .meta, color: .primary)
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
            if let warning = model.warning {
                Text(warning, style: .meta, color: .primary)
            }
        }
        .padding(24)
    }

    static func linked(_ name: String, filled: Bool) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12, alignment: .center, crossAlignment: .center) {
            Icon(name: .checkmarkCircle, style: filled ? .filled : .outline)
            Text("LINKED", style: .heading, color: .primary)
            Text(name, style: .meta, color: .secondary)
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
            } else {
                // The only red on the glasses: a small pre-rendered glyph.
                Image(image: GlassesArt.errorGlyph, sizePreset: .icon)
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

    private static func header(_ target: String) -> some ViewComponent {
        FlexBox(direction: .row, spacing: 8) {
            Text("CARBON", style: .meta, color: .secondary)
                .flexGrow(1)
            Text(target, style: .meta, color: .secondary)
        }
    }

    /// "■ CAPTURE  ■ TRANSFER  □ READ  □ COPY": filled up to and including the current stage.
    private static func rail(_ current: GlassesScreen.Scanning.Stage, toLaptop: Bool) -> String {
        let stages: [GlassesScreen.Scanning.Stage] = [.capture, .transfer, .read, .copy]
        return stages.map { "\($0 <= current ? "■" : "□") \($0.railName(toLaptop: toLaptop))" }.joined(separator: "  ")
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
