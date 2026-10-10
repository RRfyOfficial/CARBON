// Timestamped event log for Diagnostics, appended to Documents/logs/carbon.log so
// `mac.sh logs` can copy it off the phone. Lengths and states only, never scan text.

import Foundation
import Observation

@Observable
final class EventLog {
    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
    }

    private(set) var entries: [Entry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(fileURL: URL = URL.documentsDirectory.appending(path: "logs/carbon.log")) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfLarge()
    }

    func add(_ text: String) {
        let entry = Entry(time: .now, text: text)
        entries.append(entry)
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
        append("\(stamp.string(from: entry.time))  \(text)\n")
    }

    var allText: String {
        entries.map { "\(stamp.string(from: $0.time))  \($0.text)" }.joined(separator: "\n")
    }

    private func append(_ line: String) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Keeps the file under about 1 MB by moving the old one aside.
    private func rotateIfLarge() {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path())[.size] as? Int) ?? 0
        guard size > 1_000_000 else { return }
        let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }
}
