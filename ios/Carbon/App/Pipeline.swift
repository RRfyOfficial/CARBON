// The scan pipeline: Trigger → Capture → Reader → Formatter → Target. Each stage is a
// socket, so a later upgrade (a document reader, another target) is a one-line swap here.

import Foundation

final class Pipeline {
    enum Progress {
        case stage(GlassesScreen.Scanning.Stage)
        case transfer(Double)
    }

    var photoSource: any PhotoSource
    var reader: any TextReader
    var formatter: any ScanFormatter
    var lineBreaks = true
    var keepCaptures = false

    /// Where a laptop scan's text goes when the laptop doesn't take it: the scan is never lost.
    private let fallback: PhoneClipboardTarget
    private let log: EventLog

    init(photoSource: any PhotoSource, reader: any TextReader, formatter: any ScanFormatter,
         fallback: PhoneClipboardTarget, log: EventLog) {
        self.photoSource = photoSource
        self.reader = reader
        self.formatter = formatter
        self.fallback = fallback
        self.log = log
    }

    /// Runs one scan to `target`. Returns the scan to keep in history (also for `awaitingAppOpen`
    /// and NOT DELIVERED), or the error to show. Timings are milliseconds since `startedAt`, the trigger.
    func run(_ kind: ScanKind, to target: any ScanTarget, mode: PasteMode, startedAt: ContinuousClock.Instant,
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
        let id = UUID()
        let (delivery, phoneCopyPending) = await deliver(text, id: id, to: target, mode: mode)
        timings.delivered = now()

        log.add("scan \(kind.rawValue) · \(photo.count) B · \(text.count) chars · skew \(String(format: "%.1f", read.skewDegrees))° · " +
                "first byte \(timings.firstByte ?? -1) · photo \(timings.photoReceived ?? -1) · read \(timings.readDone ?? -1) · " +
                "delivered \(timings.delivered ?? -1) ms · \(target.displayName) · \(delivery)" +
                (phoneCopyPending == true ? " · phone copy waits for CARBON" : "") +
                (read.cutEdges.isEmpty ? "" : " · cut at \(read.cutEdges.map(\.rawValue).sorted().joined(separator: "+"))"))
        return .success(Scan(id: id, createdAt: .now, text: text, target: target.id, pasteMode: mode,
                             kind: kind, timings: timings, delivery: delivery, photoBytes: photo.count,
                             cutEdges: read.cutEdges.isEmpty ? nil : read.cutEdges, phoneCopyPending: phoneCopyPending))
    }

    /// Hands text to a target. Not delivered to the laptop (or it speaks another version): the phone
    /// clipboard gets it, now if CARBON is open, otherwise the moment it opens (`phoneCopyPending`).
    /// Also used by RESEND, which sends a saved scan without a new photo.
    func deliver(_ text: String, id: UUID, to target: any ScanTarget, mode: PasteMode) async -> (DeliveryStatus, Bool?) {
        let delivery = await target.deliver(text, id: id, mode: mode)
        guard delivery == .notDelivered || delivery == .failed(.version) else { return (delivery, nil) }
        let pending = await fallback.deliver(text, id: id, mode: .clipboard) == .awaitingAppOpen
        return (delivery, pending ? true : nil)
    }

    /// Debug "Keep captures": off by default; photos are otherwise never stored.
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
