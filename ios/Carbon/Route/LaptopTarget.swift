// The laptop target (protocol/PROTOCOL.md Section 6): the clip goes over the link and the
// laptop's ack decides the outcome. Anything short of an ack is NOT DELIVERED, and the pipeline then
// puts the text on the phone clipboard, so a scan is never lost.

import Foundation

final class LaptopTarget: ScanTarget {
    /// Longer text is cut before sending.
    static let maxCharacters = 32_000

    private let link: LaptopLink

    init(link: LaptopLink) {
        self.link = link
    }

    var id: TargetID { .laptop(deviceID: link.laptop?.id ?? "") }
    var displayName: String { (link.laptop?.name ?? "LAPTOP").uppercased() }

    func deliver(_ text: String, id: UUID, mode: PasteMode) async -> DeliveryStatus {
        let clip = text.count > Self.maxCharacters ? String(text.prefix(Self.maxCharacters)) : text
        switch await link.send(clip, id: id, mode: mode) {
        case .acked(.copied): return .delivered(.copied)
        case .acked(.pasted): return .delivered(.pasted)
        case .acked(.pasteBlocked): return .failed(.pasteBlocked)
        case .acked(.autopasteDisabled): return .failed(.autopasteOff)
        case .versionMismatch: return .failed(.version)
        case .acked(.error), .noLink, .noAck: return .notDelivered
        }
    }
}
