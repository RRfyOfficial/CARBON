// 05 / DIAGNOSTICS (SPEC 6.6): real measurements only (SPEC 3 rule 5). Latency over the last 20
// scans, per-scan stage timings, the on-device fixture check, CSV export, and the event log.

import SwiftUI
import UIKit

struct DiagnosticsPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Panel(number: "05", title: "DIAGNOSTICS") {
            latency
            Rectangle().fill(Palette.line).frame(height: Metrics.hairline)
            stageTimings
            Rectangle().fill(Palette.line).frame(height: Metrics.hairline)
            FixtureCheckSection()
            Rectangle().fill(Palette.line).frame(height: Metrics.hairline)
            LinkSpikeSection()
            Rectangle().fill(Palette.line).frame(height: Metrics.hairline)
            eventLog
        }
    }

    private var latency: some View {
        HStack(alignment: .top, spacing: Metrics.grid * 3) {
            if let stats = store.latencyStats {
                Readout(value: String(format: "%.1f", stats.p50), label: "P50 S")
                Readout(value: String(format: "%.1f", stats.p95), label: "P95 S · TARGET 8")
                Readout(value: "\(stats.count)", label: "SCANS")
            } else {
                Text("NO SCANS MEASURED YET").tacturaLabel(10)
            }
        }
    }

    private var stageTimings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STAGES · MS SINCE TRIGGER").tacturaLabel(10)
            Text("FIRST BYTE · PHOTO · READ · DONE · KB")
                .font(Typeface.label(10))
                .foregroundStyle(Palette.textDim)
            ForEach(store.history.scans.prefix(8)) { scan in
                let t = scan.timings
                Text([t.firstByte, t.photoReceived, t.readDone, t.delivered].map { $0.map(String.init) ?? "-" }.joined(separator: " · ")
                     + " · \((scan.photoBytes ?? 0) / 1024)")
                    .font(Typeface.label(11))
                    .foregroundStyle(Palette.text)
            }
            ShareLink(item: store.diagnosticsCSV) {
                Text("EXPORT CSV").tacturaLabel(11, color: Palette.text)
            }
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("EVENT LOG").tacturaLabel(10)
                Spacer()
                Button("COPY") { UIPasteboard.general.string = store.log.allText }
                    .font(Typeface.label(10))
                    .foregroundStyle(Palette.text)
            }
            ForEach(store.log.entries.suffix(12).reversed()) { entry in
                Text(entry.text)
                    .font(Typeface.label(9))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(2)
            }
        }
    }
}

/// M2 spike (temporary): the phone advertises the CARBON service for `tools/spike/linkcheck`.
private struct LinkSpikeSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let spike = store.linkSpike
        VStack(alignment: .leading, spacing: Metrics.grid) {
            Toggle(isOn: Binding(get: { spike.isOn }, set: { spike.setOn($0) })) {
                Text("LINK TEST (M2)").tacturaLabel(11, color: Palette.text)
            }
            .tint(Palette.accent)
            if spike.isOn {
                Text("\(spike.status) · \(spike.subscribers) LISTENING").tacturaLabel(10, color: Palette.text)
                ChamferButton(title: "SEND TEST MESSAGE") { spike.sendTest() }
            }
        }
    }
}

/// Scan the fixture deck slide by slide; each result is scored against the bundled ground truth.
private struct FixtureCheckSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var fixtures = store.fixtures
        VStack(alignment: .leading, spacing: Metrics.grid) {
            Toggle(isOn: $fixtures.isOn) {
                Text("FIXTURE CHECK").tacturaLabel(11, color: Palette.text)
            }
            .tint(Palette.accent)
            if fixtures.isOn {
                Stepper(value: $fixtures.slide, in: 1...FixtureCheck.slideCount) {
                    Text("NEXT SCAN = SLIDE \(fixtures.slide)").tacturaLabel(10, color: Palette.text)
                }
                HStack(spacing: Metrics.grid * 3) {
                    Readout(value: percent(fixtures.bodyTextMeanCER), label: "BODY CER · TARGET 2%")
                    Readout(value: percent(fixtures.allSlidesMeanCER), label: "ALL SLIDES")
                }
                ForEach(fixtures.results.suffix(10).reversed()) { result in
                    Text("SLIDE \(result.slide) · CER \(percent(result.cer)) · \(result.totalMs.map { String(format: "%.1f s", Double($0) / 1_000) } ?? "-")")
                        .font(Typeface.label(11))
                        .foregroundStyle(FixtureCheck.bodyTextSlides.contains(result.slide) ? Palette.text : Palette.textMuted)
                }
                if !fixtures.results.isEmpty {
                    ChamferButton(title: "RESET FIXTURE RESULTS") { fixtures.reset() }
                }
            }
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
    }
}
