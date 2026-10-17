// The Capture socket and its v1 implementation, a photo from the glasses.

import Foundation

protocol PhotoSource: AnyObject {
    /// True from a request until its photo or error arrives, even after a timeout was reported.
    var isBusy: Bool { get }

    /// Takes one photo. `onProgress` gets the approximate transfer fraction (0...1).
    func capture(_ kind: ScanKind, onProgress: @escaping (Double) -> Void) async throws(ScanError) -> Data
}

final class GlassesPhotoSource: PhotoSource {
    private(set) var isBusy = false

    private let session: GlassesSession
    private let log: EventLog
    private var waiter: CheckedContinuation<Result<Data, ScanError>, Never>?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var onProgress: ((Double) -> Void)?
    private var firedAt: ContinuousClock.Instant?
    private var lastProgressAt: ContinuousClock.Instant?
    private var serial = 0

    init(session: GlassesSession, log: EventLog) {
        self.session = session
        self.log = log
        session.onPhotoEvent = { [weak self] event in self?.handle(event) }
    }

    func capture(_ kind: ScanKind, onProgress: @escaping (Double) -> Void) async throws(ScanError) -> Data {
        guard !isBusy else { throw .captureFailed }
        // Bounded retry: one silent retry with a fresh camera, then CAPTURE_FAILED.
        for attempt in 1...2 {
            if !(await waitUntilReady(timeout: .seconds(5))) {
                log.add("photo not ready (attempt \(attempt))")
                if attempt == 1 { session.restartCamera(); continue }
                throw .captureFailed
            }
            switch await captureOnce(kind, onProgress: onProgress) {
            case .success(let data):
                return data
            case .failure(.timeout):
                throw .timeout
            case .failure:
                if attempt == 1 { session.restartCamera() }
            }
        }
        throw .captureFailed
    }

    // MARK: - One request

    private func captureOnce(_ kind: ScanKind, onProgress: @escaping (Double) -> Void) async -> Result<Data, ScanError> {
        guard session.capturePhoto(kind) else { return .failure(.captureFailed) }
        serial += 1
        let mySerial = serial
        isBusy = true
        firedAt = .now
        lastProgressAt = nil
        self.onProgress = onProgress
        log.add("capture \(kind.rawValue) requested")
        startWatchdog(serial: mySerial)
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    /// TIMEOUT after 10 s with no transfer progress or 30 s in total. The slot stays
    /// busy until the photo or an SDK error still arrives, because the glasses queue requests (M0).
    private func startWatchdog(serial mySerial: Int) {
        Task {
            while let firedAt, serial == mySerial, waiter != nil {
                try? await Task.sleep(for: .milliseconds(500))
                let now = ContinuousClock.now
                if now - (lastProgressAt ?? firedAt) > .seconds(10) || now - firedAt > .seconds(30) {
                    log.add("capture timed out · keeping the slot until the photo or an error arrives")
                    finish(.failure(.timeout), releaseSlot: false)
                    releaseSlotEventually(serial: mySerial)
                    return
                }
            }
        }
    }

    private func releaseSlotEventually(serial mySerial: Int) {
        Task {
            try? await Task.sleep(for: .seconds(45))
            if serial == mySerial, isBusy, waiter == nil {
                log.add("no late photo after 45 s · releasing the capture slot")
                isBusy = false
            }
        }
    }

    private func finish(_ result: Result<Data, ScanError>, releaseSlot: Bool) {
        let continuation = waiter
        waiter = nil
        onProgress = nil
        if releaseSlot { isBusy = false }
        continuation?.resume(returning: result)
    }

    // MARK: - Events from the glasses

    private func handle(_ event: PhotoEvent) {
        switch event {
        case .ready(let ready):
            if ready {
                readyWaiters.forEach { $0.resume() }
                readyWaiters = []
            }
        case .progress(let fraction):
            lastProgressAt = .now
            onProgress?(fraction)
        case .data(let data):
            if waiter != nil {
                log.add("photo arrived · \(data.count) B")
                finish(.success(data), releaseSlot: true)
            } else if isBusy {
                log.add("late photo after a timeout · discarded (\(data.count) B)")
                isBusy = false
            } else {
                log.add("unrequested photo ignored (\(data.count) B)")
            }
        case .error(let description):
            if waiter != nil {
                finish(.failure(.captureFailed), releaseSlot: true)
            } else if isBusy {
                log.add("late photo error after a timeout: \(description)")
                isBusy = false
            }
        }
    }

    private func waitUntilReady(timeout: Duration) async -> Bool {
        if session.isPhotoReady { return true }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
        }
        await withCheckedContinuation { readyWaiters.append($0) }
        deadline.cancel()
        return session.isPhotoReady
    }
}
