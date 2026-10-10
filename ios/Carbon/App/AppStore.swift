// The single app state (SPEC 5): owns the glasses session, the glasses screens, the pipeline,
// the laptop link, history and sound, and turns triggers into scans.

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
    let link: LaptopLink
    @ObservationIgnored let router: GlassesRouter
    @ObservationIgnored let pipeline: Pipeline
    @ObservationIgnored private let ticks = TickSynth()
    @ObservationIgnored private let phoneTarget: PhoneClipboardTarget
    @ObservationIgnored private let laptopTarget: LaptopTarget
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
    /// TARGET (SPEC 6.5): the paired laptop when true and one is paired, otherwise the phone.
    var targetIsLaptop: Bool {
        didSet {
            UserDefaults.standard.set(targetIsLaptop, forKey: Keys.targetIsLaptop)
            refreshMain()
        }
    }
    /// PASTE (SPEC 6.5), laptop only.
    var pasteMode: PasteMode {
        didSet { UserDefaults.standard.set(pasteMode.rawValue, forKey: Keys.pasteMode) }
    }

    private enum Keys {
        static let cameraHintSeen = "cameraHintSeen"
        static let keepCaptures = "keepCaptures"
        static let onboardingDone = "onboardingDone"
        static let targetIsLaptop = "targetIsLaptop"
        static let pasteMode = "pasteMode"
    }

    init() {
        let log = EventLog()
        let session = GlassesSession(log: log)
        let phone = PhoneClipboardTarget()
        let link = LaptopLink(log: log)
        self.log = log
        self.session = session
        self.history = HistoryStore()
        self.router = GlassesRouter(log: log)
        self.link = link
        self.phoneTarget = phone
        self.laptopTarget = LaptopTarget(link: link)
        self.pipeline = Pipeline(
            photoSource: GlassesPhotoSource(session: session, log: log),
            reader: VisionLineReader(),
            formatter: AsIsFormatter(),
            fallback: phone,
            log: log
        )
        let defaults = UserDefaults.standard
        self.cameraHintSeen = defaults.bool(forKey: Keys.cameraHintSeen)
        self.keepCaptures = defaults.bool(forKey: Keys.keepCaptures)
        self.onboardingDone = defaults.bool(forKey: Keys.onboardingDone)
        self.targetIsLaptop = defaults.bool(forKey: Keys.targetIsLaptop)
        self.pasteMode = defaults.string(forKey: Keys.pasteMode).flatMap(PasteMode.init(rawValue:)) ?? .clipboard
        pipeline.keepCaptures = keepCaptures

        link.onStatusChanged = { [weak self] in self?.refreshMain() }
        link.onNewLaptop = { [weak self] laptop in self?.newLaptopLinked(laptop) }

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
        link.start()
        router.show(.main(mainModel()))
    }

    // MARK: - Target

    /// The laptop is the target only once one is paired.
    var usesLaptop: Bool { targetIsLaptop && link.laptop != nil }

    private var target: any ScanTarget { usesLaptop ? laptopTarget : phoneTarget }

    /// The glasses header: TARGET·PHONE, LINK·ZEPHYRUS, or LINK·LOST (SPEC 6.2).
    var targetLabel: String {
        guard usesLaptop, let laptop = link.laptop else { return "TARGET·PHONE" }
        return link.isLinked ? "LINK·\(laptop.name.uppercased())" : "LINK·LOST"
    }

    /// The SESSION panel's LINK badge (SPEC 6.6).
    var linkBadge: Badge {
        let name = link.laptop?.name.uppercased()
        switch link.status {
        case .linked: return Badge(level: .ready, reason: name ?? "")
        case .waiting: return Badge(level: .off, reason: name.map { "\($0) NOT CONNECTED" } ?? "NO COMPUTER PAIRED")
        case .versionMismatch: return Badge(level: .error, reason: "UPDATE CARBON OR THE COMPANION")
        case .unavailable(let reason): return Badge(level: .error, reason: reason)
        }
    }

    /// What switching TARGET did with the latest scan, e.g. "LAST SCAN (214 CHARS) COPIED TO PHONE".
    private(set) var targetSwitchNote: String?

    /// TARGET picked in the phone app. The latest scan follows the switch (Russell, M2): to PHONE it
    /// goes on the phone clipboard (CARBON is on screen, so iOS allows it); to the laptop it's sent
    /// as CLIPBOARD whatever PASTE says, so a switch never types into whatever window is active.
    func chooseTarget(laptop: Bool) {
        let wasLaptop = usesLaptop
        targetIsLaptop = laptop
        targetSwitchNote = nil
        guard wasLaptop != usesLaptop, let last = history.latest else { return }
        switch (last.target, usesLaptop) {
        case (.laptop, false):
            copy(last)
            targetSwitchNote = "LAST SCAN (\(last.charCount) CHARS) COPIED TO PHONE"
            log.add("target → phone · latest laptop scan copied to the phone")
        case (.phone, true):
            targetSwitchNote = "SENDING LAST SCAN (\(last.charCount) CHARS)…"
            Task {
                // A new clip id: this is a deliberate resend, so the laptop's dedupe mustn't skip it.
                let delivery = await laptopTarget.deliver(last.text, id: UUID(), mode: .clipboard)
                let name = laptopTarget.displayName
                targetSwitchNote = if case .delivered = delivery {
                    "LAST SCAN (\(last.charCount) CHARS) ON \(name)'S CLIPBOARD"
                } else {
                    "COULDN'T REACH \(name) · LAST SCAN NOT SENT"
                }
                log.add("target → laptop · latest phone scan sent as clipboard · \(delivery)")
            }
        default:
            break
        }
    }

    /// Drops the paired computer; the target goes back to the phone.
    func forgetLaptop() {
        link.forget()
        targetIsLaptop = false
    }

    /// A new pairing completed: make the laptop the target and say so on the glasses.
    private func newLaptopLinked(_ laptop: LaptopLink.Laptop) {
        targetIsLaptop = true
        guard session.phase == .running, !isScanning else { return }
        Task {
            await router.showLinkedWithTick(laptop.name.uppercased())
            ticks.play(.done)
            await returnToMain(after: .milliseconds(2_000))
        }
    }

    private func refreshMain() {
        if router.isOnMain { router.show(.main(mainModel())) }
    }

    // MARK: - Triggers

    func scan(_ kind: ScanKind = .fast) {
        guard !isScanning, !pipeline.photoSource.isBusy else {  // one capture in flight
            log.add("scan ignored: one is in flight (scanning \(isScanning), photo slot busy \(pipeline.photoSource.isBusy))")
            return
        }
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
        let toLaptop = usesLaptop
        let target = self.target
        scanning = GlassesScreen.Scanning(targetLabel: targetLabel, toLaptop: toLaptop, detail: kind == .detail)
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

        let result = await pipeline.run(kind, to: target, mode: toLaptop ? pasteMode : .clipboard, startedAt: startedAt) { [weak self] progress in
            self?.scanProgressed(progress, startedAt: startedAt)
        }
        watchdog.cancel()
        let elapsed = Self.seconds(since: startedAt)

        switch result {
        case .success(let scan):
            history.add(scan)
            fixtures.record(scan)
            switch scan.delivery {
            case .delivered(let how):
                let done = GlassesScreen.Done(
                    chars: scan.charCount, targetName: toLaptop ? target.displayName : "PHONE",
                    how: !toLaptop ? "ON PHONE CLIPBOARD" : (how == .pasted ? "PASTED" : "ON CLIPBOARD"),
                    elapsed: elapsed, warning: CutEdge.advice(for: scan.cutEdges))
                await router.showDoneWithTick(done)
                ticks.play(.done)
                // Linger a little longer when there's advice to read.
                await returnToMain(after: .milliseconds(done.warning == nil ? 1_500 : 3_000))
            case .awaitingAppOpen:
                ticks.play(.done)
                router.show(.error(.openToCopy, elapsed: elapsed))
                await returnToMain(after: .milliseconds(2_500))
            case .notDelivered, .failed(.version):
                // The laptop didn't take it; the phone clipboard has it (or will when CARBON opens).
                let code: ScanError = scan.delivery == .failed(.version) ? .version
                    : (scan.phoneCopyPending == true ? .notDeliveredOpenToCopy : .notDelivered)
                ticks.play(.error)
                router.show(.error(code, elapsed: elapsed))
                await returnToMain(after: .milliseconds(3_000))
            case .failed(let code):
                // PASTE_BLOCKED / AUTOPASTE_OFF: the text is on the laptop clipboard, just not pasted.
                ticks.play(.done)
                router.show(.error(code, elapsed: elapsed))
                await returnToMain(after: .milliseconds(3_000))
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
        case .done, .linked:
            router.show(.main(mainModel()))
        case .error(let code, _) where code.isSafe:
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
        if scan.delivery == .awaitingAppOpen || scan.phoneCopyPending == true {
            history.update(scan.id, settle)
        }
    }

    /// A scan that was waiting for the phone clipboard has it now.
    private func settle(_ scan: inout Scan) {
        if scan.delivery == .awaitingAppOpen { scan.delivery = .delivered(.copied) }
        scan.phoneCopyPending = nil
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

    // MARK: - App lifecycle

    /// Copy-on-open (M0 U5): scans that finished in the background go on the clipboard now.
    /// Called when the scene and when the app become active (either can come first); a write
    /// iOS drops is tried once more shortly after.
    func appBecameActive(via trigger: String, retry: Bool = true) {
        let waiting = history.awaitingAppOpen
        guard !waiting.isEmpty else { return }
        let copied = phoneTarget.copyAwaiting(waiting)
        guard !copied.isEmpty else {
            log.add("copy on open didn't land (\(trigger)) · \(waiting.count) waiting · app \(Self.appStateName)")
            if retry {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    appBecameActive(via: "\(trigger) retry", retry: false)
                }
            }
            return
        }
        for id in copied {
            history.update(id, settle)
        }
        log.add("copied \(copied.count) waiting scan(s) on open (\(trigger))")
        if router.isOnMain {
            router.show(.main(mainModel()))
        }
    }

    private static var appStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    // MARK: - MAIN

    func mainModel() -> GlassesScreen.Main {
        var model = GlassesScreen.Main(targetLabel: targetLabel, showCameraHint: !cameraHintSeen)
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
