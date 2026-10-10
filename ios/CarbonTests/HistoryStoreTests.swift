import Foundation
import Testing
@testable import Carbon

@MainActor
struct HistoryStoreTests {
    private func tempURL() -> URL {
        URL.temporaryDirectory.appending(path: "history-\(UUID().uuidString).json")
    }

    private func scan(_ text: String, delivery: DeliveryStatus = .delivered(.copied)) -> Scan {
        Scan(id: UUID(), createdAt: .now, text: text, target: .phone, pasteMode: .clipboard, kind: .fast,
             timings: StageTimings(), delivery: delivery)
    }

    @Test func keepsTheNewestTwentyNewestFirst() {
        let store = HistoryStore(fileURL: tempURL())
        for i in 1...25 { store.add(scan("scan \(i)")) }
        #expect(store.scans.count == 20)
        #expect(store.latest?.text == "scan 25")
        #expect(store.scans.last?.text == "scan 6")
    }

    @Test func survivesARestart() {
        let url = tempURL()
        let first = HistoryStore(fileURL: url)
        first.add(scan("kept"))
        let second = HistoryStore(fileURL: url)
        #expect(second.scans.map(\.text) == ["kept"])
    }

    @Test func tracksScansWaitingForTheAppToOpen() {
        let store = HistoryStore(fileURL: tempURL())
        let waiting = scan("waiting", delivery: .awaitingAppOpen)
        store.add(scan("done"))
        store.add(waiting)
        #expect(store.awaitingAppOpen.map(\.text) == ["waiting"])
        store.update(waiting.id) { $0.delivery = .delivered(.copied) }
        #expect(store.awaitingAppOpen.isEmpty)
    }
}
