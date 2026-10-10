// The single app state (SPEC 5): owns the glasses session, the glasses screens, the pipeline,
// history and sound, and turns triggers into scans.

import Foundation
import Observation
import MWDATInputs

@Observable
final class AppStore {
    let log: EventLog
    let history: HistoryStore
    let session: GlassesSession
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

    private enum Keys {
        static let cameraHintSeen = "cameraHintSeen"
        static let keepCaptures = "keepCaptures"
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
        pipeline.keepCaptures = keepCaptures

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
            if scan.delivery == .awaitingAppOpen {
                ticks.play(.done)
                router.show(.error(.openToCopy, elapsed: elapsed))
                await returnToMain(after: .milliseconds(2_500))
            } else {
                await router.showDoneWithTick(GlassesScreen.Done(chars: scan.charCount, elapsed: elapsed))
                ticks.play(.done)
                await returnToMain(after: .milliseconds(1_500))
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
