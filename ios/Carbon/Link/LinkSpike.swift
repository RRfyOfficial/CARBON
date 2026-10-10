// M2 spike (temporary): the phone as the BLE peripheral and the laptop as the central, because the
// Zephyrus can't run a GATT server (M0 U8, retested in M2). One question before the protocol is
// built on it: once phone and laptop are bonded, does Windows reconnect by itself while CARBON is in
// the background and the phone is locked? Pair with `tools/spike/linkcheck` on the laptop.

import CoreBluetooth
import Observation
import UIKit

@Observable
final class LinkSpike: NSObject {
    /// Generated at the start of M2; PROTOCOL.md takes them over.
    enum IDs {
        static let service = CBUUID(string: "5D7FCEF4-D1AA-46A6-B187-DF5AF19C5BC5")
        static let info = CBUUID(string: "C34B4E97-BD2A-4254-A253-B8557272FEBE")
        static let secure = CBUUID(string: "B8B1C9A1-23D4-4994-A6B0-25E02DD11C99")
        static let p2l = CBUUID(string: "FA6817D4-2B2E-4AD3-ABB0-8981F0A8C674")
        static let l2p = CBUUID(string: "4414751E-1E20-4530-AA11-46485950207B")
    }

    private static let onKey = "linkSpikeOn"

    private(set) var isOn = UserDefaults.standard.bool(forKey: LinkSpike.onKey)
    private(set) var status = "OFF"
    private(set) var subscribers = 0

    @ObservationIgnored private let log: EventLog
    @ObservationIgnored private var manager: CBPeripheralManager?
    @ObservationIgnored private var p2l: CBMutableCharacteristic?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var tickCount = 0

    init(log: EventLog) {
        self.log = log
        super.init()
    }

    /// At launch: turns back on if it was on, which also lets iOS restore it in the background.
    func boot() {
        if isOn { start() }
    }

    func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.onKey)
        isOn = on
        on ? start() : stop()
    }

    func sendTest() {
        notify("test from the phone · app \(Self.appState)")
    }

    private func start() {
        guard manager == nil else { return }
        status = "STARTING"
        manager = CBPeripheralManager(delegate: self, queue: nil,
                                      options: [CBPeripheralManagerOptionRestoreIdentifierKey: "carbon.link.spike"])
    }

    private func stop() {
        ticker?.cancel()
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil
        p2l = nil
        restored = false
        subscribers = 0
        status = "OFF"
        log.add("link spike · off")
    }

    private func addService() {
        let info = CBMutableCharacteristic(type: IDs.info, properties: [.read],
                                           value: Data(#"{"proto":1,"spike":true}"#.utf8), permissions: [.readable])
        // Reading this needs an encrypted link, so the laptop's first read makes iOS ask to pair.
        let secure = CBMutableCharacteristic(type: IDs.secure, properties: [.read],
                                             value: Data("bonded".utf8), permissions: [.readEncryptionRequired])
        let p2l = CBMutableCharacteristic(type: IDs.p2l, properties: [.notify], value: nil,
                                          permissions: [.readEncryptionRequired])
        let l2p = CBMutableCharacteristic(type: IDs.l2p, properties: [.write], value: nil,
                                          permissions: [.writeEncryptionRequired])
        let service = CBMutableService(type: IDs.service, primary: true)
        service.characteristics = [info, secure, p2l, l2p]
        self.p2l = p2l
        manager?.add(service)
    }

    private func advertise() {
        manager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [IDs.service],
                                   CBAdvertisementDataLocalNameKey: "CARBON"])
    }

    private func notify(_ text: String) {
        guard let manager, let p2l else { return }
        let sent = manager.updateValue(Data(text.utf8), for: p2l, onSubscribedCentrals: nil)
        log.add("link spike · → \(text)\(sent ? "" : " · queue full, dropped")")
    }

    /// A message every 10 s while the laptop listens: shows whether the app is awake in the background.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                guard self.subscribers > 0 else { continue }
                self.tickCount += 1
                self.notify("tick \(self.tickCount) · app \(Self.appState)")
            }
        }
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

// CoreBluetooth calls back on the main queue (queue: nil), so the conformance is main-actor isolated.
extension LinkSpike: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log.add("link spike · bluetooth \(peripheral.state.rawValue) · app \(Self.appState)")
        guard peripheral.state == .poweredOn else {
            status = "BLUETOOTH \(peripheral.state.rawValue)"
            return
        }
        if restored {
            advertise()
        } else {
            addService()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        p2l = services.flatMap { $0.characteristics ?? [] }.first { $0.uuid == IDs.p2l } as? CBMutableCharacteristic
        restored = p2l != nil
        log.add("link spike · restored by iOS · \(services.count) service(s) · app \(Self.appState)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error {
            log.add("link spike · add service failed: \(error.localizedDescription)")
            status = "ERROR"
            return
        }
        advertise()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        status = error == nil ? "ADVERTISING" : "ERROR"
        log.add("link spike · advertising \(error.map { "failed: \($0.localizedDescription)" } ?? "started")")
        startTicker()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribers += 1
        status = "LAPTOP LISTENING"
        log.add("link spike · laptop subscribed · max \(central.maximumUpdateValueLength) B per update · app \(Self.appState)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { status = "ADVERTISING" }
        log.add("link spike · laptop unsubscribed · app \(Self.appState)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let text = request.value.flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            log.add("link spike · ← \(text) · app \(Self.appState)")
            notify("pong for \(text) · app \(Self.appState)")
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        log.add("link spike · ready to send again")
    }
}
