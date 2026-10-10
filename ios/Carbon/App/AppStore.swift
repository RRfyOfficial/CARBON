// The single app state (SPEC 5): owns the glasses session, the glasses screens, the pipeline,
// history and sound, and turns triggers into scans.

import Foundation
import Observation
import UIKit
import MWDATInputs

@Observable
final class AppStore {
    let log: EventLog
    let history: HistoryStore
    let session: GlassesSession
    let fixtures = FixtureCheck()
    @ObservationIgnored let router: GlassesRouter
    @ObservationIgnored let pipeline: Pipeline
    @ObservationIgnored private let ticks = TickSynth()
    @ObservationIgnored private let phoneTarget: PhoneClipboardTarget
    @ObservationIgnored private var scanning = GlassesScreen.Scanning()
    @ObservationIgnored private var lastTransferSend = ContinuousClock.now

    private(set) var isScanning = false
    private(set) var cameraHintSeen: Bool {
        didSet { UserDefaults.standard.set(cameraHintSeen, forKey: Keys.cameraHintSeen) }
    }
    var keepCaptures: Bool {
        didSet {
            UserDefaults.standard.set(keepCaptures, forKey: Keys.keepCaptures)
            pipeline.keepCaptures = keepCaptures
        }
    }
    var onboardingDone: Bool {
        didSet { UserDefaults.standard.set(onboardingDone, forKey: Keys.onboardingDone) }
    }

    private enum Keys {
        static let cameraHintSeen = "cameraHintSeen"
        static let keepCaptures = "keepCaptures"
        static let onboardingDone = "onboardingDone"
    }

    init() {
        let log = EventLog()
        let session = GlassesSession(log: log)
        let target = PhoneClipboardTarget()
        self.log = log
        self.session = session
        self.history = HistoryStore()
        self.router = GlassesRouter(log: log)
        self.phoneTarget = target
        self.pipeline = Pipeline(
            photoSource: GlassesPhotoSource(session: session, log: log),
            reader: VisionLineReader(),
            formatter: AsIsFormatter(),
            target: target,
            log: log
        )
        self.cameraHintSeen = UserDefaults.standard.bool(forKey: Keys.cameraHintSeen)
        self.keepCaptures = UserDefaults.standard.bool(forKey: Keys.keepCaptures)
        self.onboardingDone = UserDefaults.standard.bool(forKey: Keys.onboardingDone)
        pipeline.keepCaptures = keepCaptures

        // Keep the screen awake while a session is on and CARBON is on screen, so the phone doesn't
        // auto-lock mid-scan and push CARBON into the background, where iOS blocks the clipboard (U5).
        session.onPhaseChanged = { phase in
            UIApplication.shared.isIdleTimerDisabled = phase != .stopped
        }
        session.onDisplayReady = { [weak self] display in self?.router.attach(display) }
        session.onDisplayGone = { [weak self] in self?.router.detach() }
        session.onInput = { [weak self] event in self?.handle(event) }
        router.onAction = { [weak self] action in self?.handle(action) }
    }

    func boot() {
        log.add("CARBON launched")
        session.boot()
        router.show(.main(mainModel()))
    }

    // MARK: - Triggers

    func scan(_ kind: ScanKind = .fast) {
        guard !isScanning, !pipeline.photoSource.isBusy else { return }  // one capture in flight
        guard session.phase == .running else {
            log.add("scan ignored: session is \(session.phase)")
            return
        }
        isScanning = true
        Task { await runScan(kind) }
    }

    private func handle(_ event: InputEvent) {
        switch event {
        case let .capture(press, _, _) where press == .shortPress:
            if !cameraHintSeen {
                cameraHintSeen = true
            }
            scan(.fast)
        case let .capture(press, _, _) where press == .hold:
            log.add("camera button hold: the detail scan arrives in M3")
        case .select:
            if router.isOnMain { scan(.fast) }
        default:
            break
        }
    }

    private func handle(_ action: GlassesRouter.Action) {
        switch action {
        case .scan, .retry:
            scan(.fast)
        case .back:
            router.show(.main(mainModel()))
        }
    }

    // MARK: - One scan

    private func runScan(_ kind: ScanKind) async {
        let startedAt = ContinuousClock.now
        scanning = GlassesScreen.Scanning(detail: kind == .detail)
        lastTransferSend = startedAt - .seconds(1)
        ticks.play(.start)
        router.show(.scanning(scanning))

        let stillWorkingAfter: Duration = kind == .fast ? .seconds(8) : .seconds(15)
        let watchdog = Task {
            try? await Task.sleep(for: stillWorkingAfter)
            guard !Task.isCancelled, case .scanning = router.screen else { return }
            scanning.stillWorking = true
            scanning.elapsed = Self.seconds(since: startedAt)
            router.show(.scanning(scanning))
        }

        let result = await pipeline.run(kind, startedAt: startedAt) { [weak self] progress in
            self?.scanProgressed(progress, startedAt: startedAt)
        }
        watchdog.cancel()
        let elapsed = Self.seconds(since: startedAt)

        switch result {
        case .success(let scan):
            history.add(scan)
            fixtures.record(scan)
            if scan.delivery == .awaitingAppOpen {
                ticks.play(.done)
                router.show(.error(.openToCopy, elapsed: elapsed))
                await returnToMain(after: .milliseconds(2_500))
            } else {
                let done = GlassesScreen.Done(chars: scan.charCount, elapsed: elapsed, warning: CutEdge.advice(for: scan.cutEdges))
                await router.showDoneWithTick(done)
                ticks.play(.done)
                // Linger a little longer when there's advice to read.
                await returnToMain(after: .milliseconds(done.warning == nil ? 1_500 : 3_000))
            }
        case .failure(let error):
            ticks.play(.error)
            router.show(.error(error, elapsed: elapsed))
        }
        isScanning = false
        session.reviveIfNeeded()
    }

    private func scanProgressed(_ progress: Pipeline.Progress, startedAt: ContinuousClock.Instant) {
        switch progress {
        case .stage(let stage):
            scanning.stage = stage
        case .transfer(let fraction):
            // At most every 250 ms (SPEC 6.2). totalBytes under-reports, so never show 100% early.
            guard ContinuousClock.now - lastTransferSend >= .milliseconds(250) else { return }
            lastTransferSend = .now
            scanning.transferPercent = min(99, Int(fraction * 100))
        }
        scanning.elapsed = Self.seconds(since: startedAt)
        router.show(.scanning(scanning))
    }

    private func returnToMain(after delay: Duration) async {
        try? await Task.sleep(for: delay)
        switch router.screen {
        case .done, .error(.openToCopy, _):
            router.show(.main(mainModel()))
        default:
            break
        }
    }

    // MARK: - Phone controls

    /// The SESSION panel's big button: START / RESUME, or STOP while anything is running.
    func startOrStop() {
        if session.phase == .stopped {
            Task {
                // Ask for the glasses camera first when they're connected; otherwise start waiting.
                if session.glasses.level == .ready, !(await session.ensureCameraPermission()) {
                    log.add("camera permission not granted")
                }
                session.start()
            }
        } else {
            session.stop()
        }
    }

    /// Copies a scan from the phone app; also settles it if it was waiting for the app to open.
    func copy(_ scan: Scan) {
        UIPasteboard.general.string = scan.text
        if scan.delivery == .awaitingAppOpen {
            history.update(scan.id) { $0.delivery = .delivered(.copied) }
        }
    }

    /// p50 / p95 of trigger-to-delivered over the last 20 fast scans, in seconds (SPEC 8.6).
    var latencyStats: (p50: Double, p95: Double, count: Int)? {
        let totals = history.scans.filter { $0.kind == .fast }.prefix(20).compactMap(\.timings.delivered)
        guard !totals.isEmpty else { return nil }
        let sorted = totals.map { Double($0) / 1_000 }.sorted()
        func percentile(_ p: Double) -> Double {
            let k = p * Double(sorted.count - 1)
            let (low, high) = (Int(k), min(Int(k) + 1, sorted.count - 1))
            return sorted[low] + (sorted[high] - sorted[low]) * (k - Double(low))
        }
        return (percentile(0.5), percentile(0.95), sorted.count)
    }

    /// Stage timings (and fixture results) as CSV for the share sheet. Lengths only, no scan text.
    var diagnosticsCSV: String {
        var rows = ["time,kind,chars,photo_bytes,capture_ms,first_byte_ms,photo_ms,read_ms,formatted_ms,delivered_ms,delivery"]
        for scan in history.scans.reversed() {
            let t = scan.timings
            let cells: [String] = [
                scan.createdAt.ISO8601Format(), scan.kind.rawValue, "\(scan.charCount)", scan.photoBytes.map(String.init) ?? "",
                t.captureRequested.map(String.init) ?? "", t.firstByte.map(String.init) ?? "", t.photoReceived.map(String.init) ?? "",
                t.readDone.map(String.init) ?? "", t.formatted.map(String.init) ?? "", t.delivered.map(String.init) ?? "",
                "\(scan.delivery)".replacingOccurrences(of: ",", with: ";"),
            ]
            rows.append(cells.joined(separator: ","))
        }
        if !fixtures.results.isEmpty {
            rows.append("")
            rows.append("fixture_slide,cer,total_ms,chars")
            for result in fixtures.results {
                rows.append("\(result.slide),\(result.cer.map { String(format: "%.4f", $0) } ?? ""),\(result.totalMs.map(String.init) ?? ""),\(result.chars)")
            }
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - Reader lab (debug)

    /// Re-reads the newest kept photos (Keep captures) with several reader variants and logs
    /// characters, CER against fixture slide `slide`, Vision's observation counts, and reading time.
    func rereadKeptCaptures(slide: Int) {
        let dir = URL.documentsDirectory.appending(path: "captures", directoryHint: .isDirectory)
        let photos = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "heic" && Int($0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .suffix(3)
        let truth = FixtureCheck.truth(for: slide)
        let center = CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
        log.add("reader lab · \(photos.count) photo(s) · against slide \(slide)")
        Task {
            for url in photos {
                guard let data = try? Data(contentsOf: url) else { continue }
                // Vision's own minimum text height (unset) against explicit values, then a crop.
                let unset = await labRead(url, "min unset (default)", VisionLineReader(), data, truth)
                await labRead(url, "min 1/100", VisionLineReader(minimumTextHeight: 1.0 / 100), data, truth)
                await labRead(url, "min 1/32 explicit", VisionLineReader(minimumTextHeight: 1.0 / 32), data, truth)
                let region = unset.flatMap { VisionLineReader.textRegion(of: $0.lines, in: $0.imageSize) } ?? center
                await labRead(url, "min unset · text crop 2x", VisionLineReader(upscale: 2, crop: region), data, truth)
            }
            log.add("reader lab · done")
        }
    }

    @discardableResult
    private func labRead(_ url: URL, _ name: String, _ reader: VisionLineReader, _ data: Data, _ truth: String?) async -> VisionLineReader.Output? {
        let startedAt = ContinuousClock.now
        do {
            let output = try await reader.recognizeLines(data)
            let text = AsIsFormatter().format(ReadingOrder.blocks(from: output.lines), lineBreaks: true)
            let cer = truth.flatMap { CharacterErrorRate.of(text, truth: $0) }.map { String(format: "%.2f%%", $0 * 100) } ?? "-"
            log.add("reader lab · \(url.lastPathComponent) · \(name) · \(text.count) chars · CER \(cer) · " +
                    "\(output.stats.observations) obs (\(output.stats.blank) blank) · \(Pipeline.ms(since: startedAt)) ms")
            return output
        } catch {
            log.add("reader lab · \(url.lastPathComponent) · \(name) · failed: \(error)")
            return nil
        }
    }

    // MARK: - App lifecycle

    /// Copy-on-open (M0 U5): scans that finished in the background go on the clipboard now.
    func appBecameActive() {
        let waiting = history.awaitingAppOpen
        let copied = phoneTarget.copyAwaiting(waiting)
        guard !copied.isEmpty else { return }
        for id in copied {
            history.update(id) { $0.delivery = .delivered(.copied) }
        }
        log.add("copied \(copied.count) waiting scan(s) on open")
        if router.isOnMain {
            router.show(.main(mainModel()))
        }
    }

    // MARK: - MAIN

    func mainModel() -> GlassesScreen.Main {
        var model = GlassesScreen.Main(showCameraHint: !cameraHintSeen)
        if let last = history.latest {
            let time = last.createdAt.formatted(date: .omitted, time: .shortened)
            model.lastLine = "LAST · \(time) · \(last.charCount) CHARS"
            model.preview = Self.preview(last.text)
        }
        return model
    }

    /// Up to 3 lines of about 40 characters, ellipsized: the "gray box" on MAIN (SPEC 6.2).
    static func preview(_ text: String, lines: Int = 3, width: Int = 40) -> [String] {
        var result: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard result.count < lines else { break }
            result.append(line.count > width ? String(line.prefix(width - 1)) + "…" : String(line))
        }
        if text.split(separator: "\n").count > lines, var last = result.popLast() {
            if !last.hasSuffix("…") { last += " …" }
            result.append(last)
        }
        return result
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        Double(Pipeline.ms(since: start)) / 1_000
    }
}
