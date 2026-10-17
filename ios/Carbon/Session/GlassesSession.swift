// The glasses side of CARBON: registration, device choice, one long-lived device session with
// Camera, Display and Inputs (M0 U1), and auto-resume when the glasses reconnect (M0 U9).
// Startup order follows M0 and Meta's BirdSpotter sample: camera first, wake it with a low-res
// stream, start photo, stop the stream, then attach Display and Inputs.

import Foundation
import Observation
import MWDATCamera
import MWDATCore
import MWDATDisplay
import MWDATInputs

/// One status badge on the phone's SESSION panel.
nonisolated struct Badge: Equatable, Sendable {
    enum Level: Sendable {
        case ready
        case off
        case error
    }

    var level: Level
    var reason: String

    static let off = Badge(level: .off, reason: "")
}

/// What the camera's photo capability reports, forwarded to the photo source.
nonisolated enum PhotoEvent: Sendable {
    case ready(Bool)
    case progress(Double)
    case data(Data)
    case error(String)
}

@Observable
final class GlassesSession {
    enum Phase: Equatable {
        case stopped
        case waitingForGlasses
        case starting
        case running
        case paused
    }

    private(set) var phase: Phase = .stopped {
        didSet { if phase != oldValue { onPhaseChanged?(phase) } }
    }
    private(set) var isRegistered = false
    /// The setup checklist's fix-it line when registration failed; nil when fine.
    private(set) var registrationProblem: String?
    /// Glasses camera permission as last checked; nil until it could be checked.
    private(set) var cameraAllowed: Bool?
    /// Why the camera permission couldn't be checked or wasn't granted.
    private(set) var cameraProblem: String?
    private(set) var glasses = Badge.off
    private(set) var display = Badge.off
    private(set) var camera = Badge.off
    private(set) var inputs = Badge.off
    /// The wearer asked CARBON to run. Auto-resume only applies while this is true.
    private(set) var wantsRunning = false
    /// A session has run at least once since launch, so the phone offers RESUME rather than START.
    private(set) var hasRun = false

    @ObservationIgnored var onPhaseChanged: ((Phase) -> Void)?
    @ObservationIgnored var onDisplayReady: ((Display) -> Void)?
    @ObservationIgnored var onDisplayGone: (() -> Void)?
    @ObservationIgnored var onInput: ((InputEvent) -> Void)?
    @ObservationIgnored var onPhotoEvent: ((PhotoEvent) -> Void)?

    @ObservationIgnored private let log: EventLog
    @ObservationIgnored private var booted = false
    @ObservationIgnored private var knownDevices: [DeviceIdentifier] = []
    @ObservationIgnored private var deviceTokens: [DeviceIdentifier: [AnyListenerToken]] = [:]
    @ObservationIgnored private var deviceID: DeviceIdentifier?
    @ObservationIgnored private var hingeClosed = false
    @ObservationIgnored private var glassesAppUpdateRequired = false
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var activeCamera: Camera?
    @ObservationIgnored private var cameraTokens: [AnyListenerToken] = []
    @ObservationIgnored private var streamWoke = false
    @ObservationIgnored private var wakeStreamStopped = false
    @ObservationIgnored private var photoReady = false
    @ObservationIgnored private var activeDisplay: Display?
    @ObservationIgnored private var displayTokens: [AnyListenerToken] = []
    @ObservationIgnored private var displayStarted = false
    @ObservationIgnored private var activeInputs: Inputs?
    @ObservationIgnored private var inputsTokens: [AnyListenerToken] = []
    @ObservationIgnored private var inputsTask: Task<Void, Never>?
    @ObservationIgnored private var inputsActive = false
    @ObservationIgnored private var inputsWasActive = false

    init(log: EventLog) {
        self.log = log
    }

    // MARK: - Registration and permission

    func boot() {
        guard !booted else { return }
        booted = true
        isRegistered = Wearables.shared.registrationState == .registered
        Task {
            for await state in Wearables.shared.registrationStateStream() {
                isRegistered = state == .registered
                if isRegistered { registrationProblem = nil }
                log.add("registration → \(state)")
            }
        }
        Task {
            for await ids in Wearables.shared.devicesStream() {
                devicesChanged(ids)
            }
        }
    }

    func register() {
        log.add("registration: opening Meta AI")
        registrationProblem = nil
        Task {
            do {
                try await Wearables.shared.startRegistration()
            } catch {
                log.add("registration error: \(error)")
                registrationProblem = Self.advice(for: error)
            }
        }
    }

    /// The setup checklist's fix-it line for a failed registration. nil when it's fine.
    private static func advice(for error: any Error) -> String? {
        switch error as? RegistrationError {
        case .alreadyRegistered: nil
        case .metaAINotInstalled: "INSTALL META AI FROM THE APP STORE, SIGN IN, AND PAIR YOUR GLASSES THERE"
        // CARBON registers through Developer Mode instead of a Developer Center app.
        case .configurationInvalid: "TURN ON DEVELOPER MODE IN META AI: SETTINGS › APP INFO › TAP THE VERSION NUMBER 5 TIMES"
        case .networkUnavailable: "CONNECT THE PHONE TO THE INTERNET AND TRY AGAIN"
        default: "META AI DIDN'T FINISH REGISTERING. OPEN META AI ONCE, THEN TRY AGAIN"
        }
    }

    /// Re-reads the glasses camera permission for the setup checklist, without asking.
    func refreshCameraPermission() async {
        do {
            cameraAllowed = try await Wearables.shared.checkPermissionStatus(.camera) == .granted
            cameraProblem = nil
        } catch {
            cameraAllowed = nil
            cameraProblem = Self.permissionAdvice(for: error)
        }
    }

    private static func permissionAdvice(for error: any Error) -> String {
        switch error as? PermissionError {
        case .noDevice, .noDeviceWithConnection: "PUT THE GLASSES ON, UNFOLDED, THEN TRY AGAIN"
        case .connectionError: "THE GLASSES DROPPED THE CONNECTION. TRY AGAIN"
        case .metaAINotInstalled: "INSTALL META AI FROM THE APP STORE"
        case .requestInProgress: "FINISH THE REQUEST IN META AI"
        default: "COULDN'T CHECK. OPEN META AI, THEN TRY AGAIN"
        }
    }

    func handleURL(_ url: URL) {
        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
            } catch {
                log.add("handleUrl error: \(error)")
            }
        }
    }

    /// Camera permission on the glasses, granted in Meta AI. Returns whether it's granted.
    func ensureCameraPermission() async -> Bool {
        do {
            if try await Wearables.shared.checkPermissionStatus(.camera) != .granted {
                _ = try await Wearables.shared.requestPermission(.camera)
            }
            let granted = try await Wearables.shared.checkPermissionStatus(.camera) == .granted
            cameraAllowed = granted
            cameraProblem = granted ? nil : "NOT ALLOWED YET. ALLOW CARBON'S CAMERA ACCESS WHEN META AI ASKS"
            return granted
        } catch {
            log.add("camera permission error: \(error)")
            cameraAllowed = nil
            cameraProblem = Self.permissionAdvice(for: error)
            return false
        }
    }

    // MARK: - Start, stop, auto-resume

    func start() {
        wantsRunning = true
        startSessionIfPossible()
    }

    func stop() {
        wantsRunning = false
        if let session {
            log.add("stop requested")
            session.stop()
        } else {
            phase = .stopped
        }
    }

    private func startSessionIfPossible() {
        guard wantsRunning, session == nil else { return }
        guard let id = deviceID, isReady(id) else {
            phase = .waitingForGlasses
            return
        }
        do {
            let newSession = try Wearables.shared.createSession(deviceSelector: SpecificDeviceSelector(device: id))
            session = newSession
            phase = .starting
            let states = newSession.stateStream()
            let errors = newSession.errorStream()
            sessionTasks = [
                Task { for await state in states { self.sessionChanged(state) } },
                Task { for await error in errors { self.sessionFailed("\(error)") } },
            ]
            try newSession.start()
            log.add("session starting")
        } catch {
            log.add("couldn't start a session: \(error)")
            session = nil
            phase = .stopped
        }
    }

    private func sessionChanged(_ state: DeviceSessionState) {
        log.add("session → \(state)")
        switch state {
        case .started:
            phase = .running
            hasRun = true
            glassesAppUpdateRequired = false
            refreshGlassesBadge()
            if activeCamera == nil { attachCamera() }
        case .paused:
            phase = .paused
        case .stopped:
            let byHinges = hingeClosed
            tearDown()
            if !byHinges {
                // Ended by the wearer (system back) or the system: show RESUME rather than restart.
                wantsRunning = false
            }
            phase = wantsRunning ? .waitingForGlasses : .stopped
        default:
            break
        }
    }

    private func sessionFailed(_ description: String) {
        log.add("session error: \(description)")
        if description.contains("datAppOnTheGlassesUpdateRequired") {
            glassesAppUpdateRequired = true
            refreshGlassesBadge()
        }
    }

    private func tearDown() {
        inputsTask?.cancel()
        inputsTask = nil
        inputsTokens = []
        displayTokens = []
        cameraTokens = []
        activeInputs = nil
        activeDisplay = nil
        activeCamera = nil
        photoReady = false
        displayStarted = false
        inputsActive = false
        inputsWasActive = false
        streamWoke = false
        wakeStreamStopped = false
        display = .off
        camera = .off
        inputs = .off
        sessionTasks.forEach { $0.cancel() }
        sessionTasks = []
        session = nil
        onPhotoEvent?(.ready(false))
        onDisplayGone?()
    }

    // MARK: - Devices

    private func devicesChanged(_ ids: [DeviceIdentifier]) {
        knownDevices = ids
        for id in deviceTokens.keys where !ids.contains(id) {
            deviceTokens[id] = nil
        }
        for id in ids where deviceTokens[id] == nil {
            guard let device = Wearables.shared.deviceForIdentifier(id) else { continue }
            deviceTokens[id] = [
                device.addLinkStateListener { [weak self] state in
                    let connected = state == .connected
                    Task { @MainActor in self?.linkChanged(connected: connected) }
                },
                device.addDeviceStateListener { [weak self] state in
                    let closed = state.hingeState == .closed
                    Task { @MainActor in
                        self?.hingeClosed = closed
                        self?.refreshGlassesBadge()
                    }
                },
            ]
        }
        chooseDevice()
    }

    /// Prefer glasses with a display that are connected and compatible.
    private func chooseDevice() {
        let devices = knownDevices.compactMap { id in Wearables.shared.deviceForIdentifier(id).map { (id, $0) } }
        let pick = devices.first { $0.1.supportsDisplay() && isReady($0.0) }
            ?? devices.first { $0.1.supportsDisplay() }
        deviceID = pick?.0
        refreshGlassesBadge()
    }

    private func isReady(_ id: DeviceIdentifier) -> Bool {
        guard let device = Wearables.shared.deviceForIdentifier(id) else { return false }
        return device.linkState == .connected && device.compatibility() == .compatible
    }

    private func linkChanged(connected: Bool) {
        chooseDevice()
        if connected, wantsRunning, session == nil {
            log.add("glasses reconnected · resuming automatically")
            startSessionIfPossible()
        }
    }

    /// Recomputed from the device on every link or state change. Compatibility reads `undefined`
    /// for a moment after connecting, which is "checking", not an error.
    private func refreshGlassesBadge() {
        if glassesAppUpdateRequired {
            glasses = Badge(level: .error, reason: "UPDATE THE GLASSES APP IN META AI")
            return
        }
        guard let id = deviceID, let device = Wearables.shared.deviceForIdentifier(id) else {
            glasses = Badge(level: .off, reason: "NO DISPLAY GLASSES FOUND")
            return
        }
        let compatibility = device.compatibility()
        if device.linkState != .connected {
            glasses = Badge(level: .off, reason: "NOT CONNECTED")
        } else if compatibility == .compatible {
            glasses = Badge(level: .ready, reason: hingeClosed ? "FOLDED" : "CONNECTED")
        } else if compatibility == .undefined {
            glasses = Badge(level: .off, reason: "CHECKING")
        } else {
            glasses = Badge(level: .error, reason: "\(compatibility)".uppercased())
        }
    }

    // MARK: - Camera and photo

    private func attachCamera() {
        guard let session else { return }
        do {
            let config = StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 7)
            guard let newCamera = try session.addCamera(config: config) else {
                log.add("addCamera returned nil")
                return
            }
            activeCamera = newCamera
            streamWoke = false
            wakeStreamStopped = false
            photoReady = false
            camera = Badge(level: .off, reason: "STARTING")
            let photo = newCamera.photo
            cameraTokens = [
                newCamera.stream.statePublisher.listen { [weak self] state in
                    let streaming = state == .streaming
                    Task { @MainActor in self?.streamChanged(streaming: streaming) }
                },
                photo.statePublisher.listen { [weak self] state in
                    let started = state == .started
                    Task { @MainActor in self?.photoStateChanged(started: started) }
                },
                photo.transferProgressPublisher.listen { [weak self] progress in
                    let fraction = progress.fraction
                    Task { @MainActor in self?.onPhotoEvent?(.progress(fraction)) }
                },
                photo.photoDataPublisher.listen { [weak self] data in
                    let bytes = data.imageData
                    Task { @MainActor in self?.onPhotoEvent?(.data(bytes)) }
                },
                photo.errorPublisher.listen { [weak self] error in
                    let text = "\(error)"
                    Task { @MainActor in
                        self?.log.add("photo error: \(text)")
                        self?.onPhotoEvent?(.error(text))
                    }
                },
            ]
            newCamera.stream.start()
            log.add("camera attached · waking it with a low-res stream")

            // If the stream never streams, fall back to the docs path: photo.start() on its own.
            Task {
                try? await Task.sleep(for: .seconds(8))
                if self.activeCamera === newCamera, !self.streamWoke, !self.photoReady {
                    self.log.add("wake stream didn't start · trying photo.start() directly")
                    photo.start()
                }
            }
        } catch {
            log.add("addCamera failed: \(error)")
            camera = Badge(level: .error, reason: "CAMERA UNAVAILABLE")
        }
    }

    private func streamChanged(streaming: Bool) {
        guard streaming, !streamWoke, let activeCamera else { return }
        streamWoke = true
        activeCamera.photo.start()
    }

    private func photoStateChanged(started: Bool) {
        photoReady = started
        camera = started ? Badge(level: .ready, reason: "READY") : Badge(level: .off, reason: "STARTING")
        onPhotoEvent?(.ready(started))
        guard started, let activeCamera else { return }
        if streamWoke, !wakeStreamStopped {
            wakeStreamStopped = true
            activeCamera.stream.stop()  // a running stream makes captures fail (M0)
        }
        attachDisplay()
        attachInputs()
    }

    var isPhotoReady: Bool { photoReady }

    /// Asks the glasses for one photo. Fast scan LARGE/MEDIUM, detail scan LARGE/HIGH.
    func capturePhoto(_ kind: ScanKind) -> Bool {
        guard photoReady, let activeCamera else { return false }
        activeCamera.photo.capturePhoto(resolution: .large, quality: kind == .fast ? .medium : .high)
        return true
    }

    /// A fresh camera for the bounded retry. Display and Inputs stay attached.
    func restartCamera() {
        guard session != nil else { return }
        log.add("restarting the camera")
        cameraTokens = []
        activeCamera?.stop()
        activeCamera = nil
        photoReady = false
        onPhotoEvent?(.ready(false))
        attachCamera()
    }

    /// M0 never saw a photo transfer take Display or Inputs down, but recovery is cheap.
    func reviveIfNeeded() {
        if let activeDisplay, !displayStarted {
            log.add("reviving display")
            activeDisplay.start()
        }
        if activeInputs != nil, inputsWasActive, !inputsActive {
            log.add("reviving inputs")
            reattachInputs()
        }
    }

    // MARK: - Display

    private func attachDisplay(attempt: Int = 1) {
        guard let session, activeDisplay == nil else { return }
        do {
            let newDisplay = try session.addDisplay()
            activeDisplay = newDisplay
            displayTokens = [
                newDisplay.statePublisher.listen { [weak self] state in
                    let started = state == .started
                    Task { @MainActor in self?.displayStateChanged(started: started) }
                },
            ]
            newDisplay.start()
        } catch {
            log.add("addDisplay attempt \(attempt) failed: \(error)")
            guard attempt < 10 else {
                display = Badge(level: .error, reason: "DISPLAY UNAVAILABLE")
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(750))
                self.attachDisplay(attempt: attempt + 1)
            }
        }
    }

    private func displayStateChanged(started: Bool) {
        displayStarted = started
        display = started ? Badge(level: .ready, reason: "ON") : Badge(level: .off, reason: "OFF")
        if started, let activeDisplay {
            onDisplayReady?(activeDisplay)
        }
    }

    // MARK: - Inputs

    /// Model B (M0 U3): never subscribe to the Neural Band, or pinch stops pressing buttons.
    private func attachInputs(attempt: Int = 1) {
        guard let session, activeInputs == nil else { return }
        do {
            let configuration = InputsConfiguration(sources: [.captouch, .captureButton, .actionButton], consumeBack: true)
            guard let newInputs = try session.addInputs(configuration: configuration) else { return }
            activeInputs = newInputs
            inputsActive = false
            inputsWasActive = false
            inputsTokens = [
                newInputs.statePublisher.listen { [weak self] state in
                    let active = state == .active
                    Task { @MainActor in self?.inputsStateChanged(active: active) }
                },
                newInputs.errorPublisher.listen { [weak self] error in
                    let text = "\(error)"
                    Task { @MainActor in self?.log.add("inputs error: \(text)") }
                },
            ]
            let events = newInputs.events
            inputsTask = Task {
                for await event in events {
                    self.onInput?(event)
                }
            }
        } catch {
            log.add("addInputs attempt \(attempt) failed: \(error)")
            guard attempt < 5 else {
                inputs = Badge(level: .error, reason: "INPUTS UNAVAILABLE")
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(750))
                self.attachInputs(attempt: attempt + 1)
            }
        }
    }

    private func inputsStateChanged(active: Bool) {
        inputsActive = active
        if active { inputsWasActive = true }
        inputs = active ? Badge(level: .ready, reason: "ACTIVE") : Badge(level: .off, reason: "INACTIVE")
    }

    private func reattachInputs() {
        guard let session else { return }
        inputsTask?.cancel()
        inputsTask = nil
        inputsTokens = []
        if activeInputs != nil {
            try? session.removeInputs()
        }
        activeInputs = nil
        attachInputs()
    }
}
