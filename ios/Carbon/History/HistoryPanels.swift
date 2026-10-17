// 02 / LAST SCAN and 03 / HISTORY. Browsing never sends anything: tapping a
// scan copies it to the phone; RESEND (and DELETE) are in each scan's long-press menu, because the
// panels are plain stacks, not Lists with swipe actions.

import SwiftUI

struct LastScanPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Panel(number: "02", title: "LAST SCAN", trailing: store.history.latest.map { statusText($0) }) {
            if let scan = store.history.latest {
                Text(scan.text)
                    .font(Typeface.body(15))
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(metaLine(scan)).tacturaLabel(10)
                HStack(spacing: Metrics.grid) {
                    ChamferButton(title: "COPY") { store.copy(scan) }
                    ShareLink(item: scan.text) {
                        Text("SHARE")
                            .font(Typeface.label(12))
                            .tracking(1.2)
                            .foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(ChamferShape().stroke(Palette.lineStrong, lineWidth: Metrics.hairline))
                    }
                }
            } else {
                Text("NO SCANS YET").tacturaLabel(11)
            }
        }
    }

    private func metaLine(_ scan: Scan) -> String {
        let time = scan.createdAt.formatted(date: .omitted, time: .shortened)
        let seconds = scan.timings.delivered.map { String(format: " · T+%.1fs", Double($0) / 1_000) } ?? ""
        let warning = CutEdge.advice(for: scan.cutEdges).map { " · \($0)" } ?? ""
        return "\(time) · \(scan.charCount) CHARS\(seconds)\(warning)"
    }
}

struct HistoryPanel: View {
    @Environment(AppStore.self) private var store
    @State private var confirmClear = false

    var body: some View {
        Panel(number: "03", title: "HISTORY", trailing: "\(store.history.scans.count) / \(HistoryStore.limit)") {
            if store.history.scans.isEmpty {
                Text("EMPTY").tacturaLabel(11)
            } else {
                ForEach(store.history.scans) { scan in
                    Button { store.copy(scan) } label: { row(scan) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Resend to \(store.usesLaptop ? store.link.laptop?.name ?? "laptop" : "phone")", systemImage: "arrow.clockwise") {
                                store.resend(scan)
                            }
                            Button("Copy", systemImage: "doc.on.doc") { store.copy(scan) }
                            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteScan(scan.id) }
                        }
                    Rectangle().fill(Palette.line).frame(height: Metrics.hairline)
                }
                Text("TAP A SCAN TO COPY IT · HOLD FOR RESEND AND DELETE").tacturaLabel(9, color: Palette.textDim)
                ChamferButton(title: "CLEAR ALL") { confirmClear = true }
                    .confirmationDialog("Clear all scans?", isPresented: $confirmClear) {
                        Button("Clear all", role: .destructive) { store.clearHistory() }
                    }
            }
        }
    }

    private func row(_ scan: Scan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(scan.createdAt.formatted(date: .omitted, time: .shortened)).tacturaLabel(10, color: Palette.text)
                Text("\(scan.charCount) CH").tacturaLabel(10)
                Spacer()
                Text(statusText(scan)).tacturaLabel(10, color: scan.delivery == .awaitingAppOpen ? Palette.accent : Palette.textMuted)
            }
            Text(scan.text.split(separator: "\n").first.map(String.init) ?? "")
                .font(Typeface.body(14))
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private func statusText(_ scan: Scan) -> String {
    switch scan.delivery {
    case .delivered(.copied): "COPIED"
    case .delivered(.pasted): "PASTED"
    case .awaitingAppOpen: "WAITING TO COPY"
    case .notDelivered: "NOT DELIVERED"
    case .failed(let code): code.rawValue
    }
}
