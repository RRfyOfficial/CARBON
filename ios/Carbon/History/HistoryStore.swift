// Scan history: the last 20 scans, newest first, stored as JSON on the phone.

import Foundation
import Observation

@Observable
final class HistoryStore {
    static let limit = 20

    private(set) var scans: [Scan] = []

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = HistoryStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "history.json")
    }

    var latest: Scan? { scans.first }

    /// Scans that finished while CARBON was in the background and still need the phone clipboard
    /// (M0 U5): phone-target scans, and laptop scans that weren't delivered.
    var awaitingAppOpen: [Scan] {
        scans.filter { $0.delivery == .awaitingAppOpen || $0.phoneCopyPending == true }
    }

    func add(_ scan: Scan) {
        scans.insert(scan, at: 0)
        if scans.count > Self.limit {
            scans.removeLast(scans.count - Self.limit)
        }
        save()
    }

    func update(_ id: Scan.ID, _ change: (inout Scan) -> Void) {
        guard let index = scans.firstIndex(where: { $0.id == id }) else { return }
        change(&scans[index])
        save()
    }

    func remove(_ id: Scan.ID) {
        scans.removeAll { $0.id == id }
        save()
    }

    func clear() {
        scans = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        scans = (try? JSONDecoder().decode([Scan].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(scans).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // History is best effort on disk; the in-memory copy still serves this run.
        }
    }
}
