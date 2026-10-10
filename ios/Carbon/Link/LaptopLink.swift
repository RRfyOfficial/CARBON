// The phone side of the laptop link (protocol/PROTOCOL.md): a BLE peripheral that advertises the
// CARBON service whenever CARBON runs. The paired laptop (the Windows companion) connects, subscribes
// to P2L and says hello on L2P; clips go out as P2L notifications and acks come back on L2P.
// Pairing itself is the iOS Bluetooth bond: P2L and L2P need an encrypted link.

import CoreBluetooth
import Observation
import UIKit

@Observable
final class LaptopLink: NSObject {
    enum IDs {
        static let service = CBUUID(string: "5D7FCEF4-D1AA-46A6-B187-DF5AF19C5BC5")
        static let info = CBUUID(string: "C34B4E97-BD2A-4254-A253-B8557272FEBE")
        static let p2l = CBUUID(string: "FA6817D4-2B2E-4AD3-ABB0-8981F0A8C674")
        static let l2p = CBUUID(string: "4414751E-1E20-4530-AA11-46485950207B")
    }

    /// The computer this phone is paired with (one per phone, v1).
    struct Laptop: Codable, Equatable {
        var id: String
        var name: String
    }

    enum Status: Equatable {
        /// Bluetooth is off or not allowed.
        case unavailable(String)
        /// Advertising; the paired laptop isn't connected (or none is paired).
        case waiting
        /// The paired laptop is connected and said hello.
        case linked
        /// The laptop speaks another protocol version.
        case versionMismatch
    }

    /// How a clip went: the laptop's ack, or why there wasn't one.
    enum SendOutcome: Equatable {
        case acked(AckResult)
        case noLink
        case noAck
        case versionMismatch
    }

    private enum Keys {
        static let laptop = "pairedLaptop"
        static let phoneID = "phoneID"
    }

    static let ackTimeout: Duration = .seconds(2)
    static let sendBackstop: Duration = .seconds(10)

    private(set) var laptop: Laptop? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(laptop), forKey: Keys.laptop) }
    }
    private(set) var status: Status = .unavailable("STARTING")

    /// Status changed (for the glasses header).
    @ObservationIgnored var onStatusChanged: (() -> Void)?
    /// A laptop said hello for the first time: a new pairing just completed.
    @ObservationIgnored var onNewLaptop: ((Laptop) -> Void)?

    @ObservationIgnored private let log: EventLog
    @ObservationIgnored private let phoneID: String
    @ObservationIgnored private var manager: CBPeripheralManager?
    @ObservationIgnored private var p2l: CBMutableCharacteristic?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var linkedCentral: CBCentral?
    @ObservationIgnored private var reassemblers: [UUID: Reassembler] = [:]
    @ObservationIgnored private var outbox: [(frame: Data, central: CBCentral, lastOf: String?)] = []
    @ObservationIgnored private var pendingAcks: [String: CheckedContinuation<SendOutcome, Never>] = [:]
    @ObservationIgnored private var nextMsgID: UInt16 = 0

    init(log: EventLog) {
        self.log = log
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Keys.phoneID) {
            phoneID = stored
        } else {
            phoneID = UUID().uuidString
            defaults.set(phoneID, forKey: Keys.phoneID)
        }
        laptop = defaults.data(forKey: Keys.laptop).flatMap { try? JSONDecoder().decode(Laptop.self, from: $0) }
        super.init()
    }

    /// At launch. The restore identifier lets iOS relaunch CARBON for link events in the background.
    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil,
                                      options: [CBPeripheralManagerOptionRestoreIdentifierKey: "carbon.link"])
    }

    var isLinked: Bool { status == .linked }

    /// Sends a clip to the paired laptop and waits up to 2 s after the last frame for its ack.
    func send(_ text: String, id: UUID, mode: PasteMode) async -> SendOutcome {
        if status == .versionMismatch { return .versionMismatch }
        guard status == .linked, let central = linkedCentral, p2l != nil else { return .noLink }
        let clipID = id.uuidString
        let message = LinkMessage.clip(id: clipID, ts: Int64(Date.now.timeIntervalSince1970 * 1_000), mode: mode, text: text)
        let frames = Framing.split(message.encoded(), msgID: takeMsgID(),
                                   chunkSize: Framing.chunkSize(payload: central.maximumUpdateValueLength))
        return await withCheckedContinuation { continuation in
            pendingAcks[clipID] = continuation
            for (index, frame) in frames.enumerated() {
                outbox.append((frame, central, index == frames.count - 1 ? clipID : nil))
            }
            flush()
            // Backstop in case the frames never drain (the 2 s ack timer only starts after the last one).
            Task { [weak self] in
                try? await Task.sleep(for: Self.sendBackstop)
                self?.finish(clipID, .noAck)
            }
        }
    }

    /// Drops the paired computer. iOS apps can't remove the system Bluetooth bond itself.
    func forget() {
        log.add("link · forgot \(laptop?.name ?? "no laptop")")
        laptop = nil
        linkedCentral = nil
        setStatus(manager?.state == .poweredOn ? .waiting : status)
    }

    // MARK: - Sending

    private func takeMsgID() -> UInt16 {
        defer { nextMsgID &+= 1 }
        return nextMsgID
    }

    /// Hands queued frames to CoreBluetooth until its queue is full; resumes on isReady.
    private func flush() {
        guard let manager, let p2l else { return }
        while let next = outbox.first {
            guard manager.updateValue(next.frame, for: p2l, onSubscribedCentrals: [next.central]) else { return }
            outbox.removeFirst()
            if let clipID = next.lastOf { startAckTimer(clipID) }
        }
    }

    private func startAckTimer(_ clipID: String) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.ackTimeout)
            self?.finish(clipID, .noAck)
        }
    }

    private func finish(_ clipID: String, _ outcome: SendOutcome) {
        pendingAcks.removeValue(forKey: clipID)?.resume(returning: outcome)
    }

    private func notify(_ message: LinkMessage, to central: CBCentral) {
        for frame in Framing.split(message.encoded(), msgID: takeMsgID(),
                                   chunkSize: Framing.chunkSize(payload: central.maximumUpdateValueLength)) {
            outbox.append((frame, central, nil))
        }
        flush()
    }

    // MARK: - Receiving

    private func handle(_ message: LinkMessage, from central: CBCentral) {
        switch message {
        case let .hello(proto, id, name) where proto != LinkMessage.protocolVersion:
            log.add("link · \(name) speaks protocol \(proto), CARBON \(LinkMessage.protocolVersion) (\(id.prefix(8)))")
            setStatus(.versionMismatch)
        case let .hello(_, id, name):
            let isNew = laptop?.id != id
            laptop = Laptop(id: id, name: name)
            linkedCentral = central
            notify(.hello(proto: LinkMessage.protocolVersion, id: phoneID, name: "IPHONE"), to: central)
            log.add("link · linked with \(name)\(isNew ? " (new pairing)" : "") · app \(Self.appState)")
            setStatus(.linked)
            if isNew, let laptop { onNewLaptop?(laptop) }
        case let .ack(id, result, _):
            finish(id, .acked(result))
        case .clip:
            break
        }
    }

    private func setStatus(_ new: Status) {
        guard status != new else { return }
        status = new
        onStatusChanged?()
    }

    // MARK: - Service

    private func addService() {
        let info = CBMutableCharacteristic(
            type: IDs.info, properties: [.read],
            value: LinkInfo(proto: LinkMessage.protocolVersion, id: phoneID, name: "IPHONE").json, permissions: [.readable])
        let p2l = CBMutableCharacteristic(type: IDs.p2l, properties: [.notify], value: nil, permissions: [.readEncryptionRequired])
        let l2p = CBMutableCharacteristic(type: IDs.l2p, properties: [.write], value: nil, permissions: [.writeEncryptionRequired])
        let service = CBMutableService(type: IDs.service, primary: true)
        service.characteristics = [info, p2l, l2p]
        self.p2l = p2l
        manager?.add(service)
    }

    private func advertise() {
        guard let manager, !manager.isAdvertising else { return }
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [IDs.service], CBAdvertisementDataLocalNameKey: "CARBON"])
    }

    static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}

/// The INFO characteristic: plain JSON, readable before pairing, no secrets.
private nonisolated struct LinkInfo: Encodable {
    var proto: Int
    var id: String
    var name: String

    var json: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

// CoreBluetooth calls back on the main queue (queue: nil), so the conformance is main-actor isolated.
extension LaptopLink: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log.add("link · bluetooth \(peripheral.state.rawValue) · app \(Self.appState)")
        switch peripheral.state {
        case .poweredOn:
            setStatus(linkedCentral == nil ? .waiting : .linked)
            if restored { advertise() } else { addService() }
        case .poweredOff:
            linkedCentral = nil
            setStatus(.unavailable("BLUETOOTH OFF"))
        case .unauthorized:
            setStatus(.unavailable("BLUETOOTH NOT ALLOWED"))
        default:
            setStatus(.unavailable("BLUETOOTH UNAVAILABLE"))
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        p2l = services.flatMap { $0.characteristics ?? [] }.first { $0.uuid == IDs.p2l } as? CBMutableCharacteristic
        restored = p2l != nil
        // A restored link won't get a new hello until the laptop reconnects; its subscriber is the bonded laptop.
        if laptop != nil, let central = p2l?.subscribedCentrals?.first {
            linkedCentral = central
        }
        log.add("link · restored by iOS · \(p2l?.subscribedCentrals?.count ?? 0) subscriber(s) · app \(Self.appState)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error {
            log.add("link · add service failed: \(error.localizedDescription)")
            return
        }
        advertise()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        log.add("link · advertising \(error.map { "failed: \($0.localizedDescription)" } ?? "started")")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        reassemblers[central.identifier] = Reassembler()
        log.add("link · a computer subscribed (\(central.maximumUpdateValueLength) B per notification) · app \(Self.appState)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        reassemblers[central.identifier] = nil
        outbox.removeAll { $0.central.identifier == central.identifier }
        guard central.identifier == linkedCentral?.identifier else { return }
        linkedCentral = nil
        log.add("link · \(laptop?.name ?? "laptop") disconnected · app \(Self.appState)")
        for clipID in pendingAcks.keys { finish(clipID, .noAck) }
        if status == .linked { setStatus(.waiting) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == IDs.l2p {
            guard let value = request.value else { continue }
            var reassembler = reassemblers[request.central.identifier] ?? Reassembler()
            let message = reassembler.add(value)
            reassemblers[request.central.identifier] = reassembler
            if let message, let decoded = LinkMessage.decode(message) {
                handle(decoded, from: request.central)
            }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flush()
    }
}
