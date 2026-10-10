// The scan pipeline (SPEC 8.1): Trigger → Capture → Reader → Formatter → Target. Each stage is a
// socket, so a later upgrade (a document reader, a laptop target) is a one-line swap here.

import Foundation

final class Pipeline {
    enum Progress {
        case stage(GlassesScreen.Scanning.Stage)
        case transfer(Double)
    }

    var photoSource: any PhotoSource
    var reader: any TextReader
    var formatter: any ScanFormatter
    var target: any ScanTarget
    var lineBreaks = true
    var keepCaptures = false

    private let log: EventLog

    init(photoSource: any PhotoSource, reader: any TextReader, formatter: any ScanFormatter,
         target: any ScanTarget, log: EventLog) {
        self.photoSource = photoSource
        self.reader = reader
        self.formatter = formatter
        self.target = target
        self.log = log
    }

    /// Runs one scan. Returns the scan to keep in history (also for `awaitingAppOpen`), or the
    /// error to show. Timings are milliseconds since `startedAt`, the trigger.
    func run(_ kind: ScanKind, startedAt: ContinuousClock.Instant,
             progress: @escaping (Progress) -> Void) async -> Result<Scan, ScanError> {
        var timings = StageTimings()
        func now() -> Int { Self.ms(since: startedAt) }

        progress(.stage(.capture))
        timings.captureRequested = now()
        let photo: Data
        do {
            photo = try await photoSource.capture(kind) { fraction in
                if timings.firstByte == nil {
                    timings.firstByte = now()
                    progress(.stage(.transfer))
                }
                progress(.transfer(fraction))
            }
        } catch {
            log.add("capture failed: \(error.rawValue)")
            return .failure(error)
        }
        timings.photoReceived = now()
        if keepCaptures { save(photo) }

        progress(.stage(.read))
        let read: ReadText
        do {
            read = try await reader.read(photo)
        } catch {
            log.add("reader failed: \(error)")
            return .failure(.noText)
        }
        timings.readDone = now()
        guard !read.isEmpty else {
            log.add("no text found · \(photo.count) B · read \(timings.readDone ?? -1) ms")
            return .failure(.noText)
        }

        let text = formatter.format(read, lineBreaks: lineBreaks)
        timings.formatted = now()

        progress(.stage(.copy))
        let delivery = await target.deliver(text, mode: .clipboard)
        timings.delivered = now()

        log.add("scan \(kind.rawValue) · \(photo.count) B · \(text.count) chars · skew \(String(format: "%.1f", read.skewDegrees))° · " +
                "first byte \(timings.firstByte ?? -1) · photo \(timings.photoReceived ?? -1) · read \(timings.readDone ?? -1) · " +
                "delivered \(timings.delivered ?? -1) ms · \(delivery)")
        return .success(Scan(id: UUID(), createdAt: .now, text: text, target: target.id, pasteMode: .clipboard,
                             kind: kind, timings: timings, delivery: delivery, photoBytes: photo.count))
    }

    /// Debug "Keep captures" (SPEC 3 rule 7): off by default; photos are otherwise never stored.
    private func save(_ photo: Data) {
        let dir = URL.documentsDirectory.appending(path: "captures", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? photo.write(to: dir.appending(path: "\(Int(Date.now.timeIntervalSince1970)).heic"))
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
