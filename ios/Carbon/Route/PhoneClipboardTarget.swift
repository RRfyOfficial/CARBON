// The Target socket (SPEC 8.1) and the phone target. iOS drops clipboard writes from the
// background (M0 U5), so a scan that finishes while CARBON isn't on screen waits for the app to open.

import UIKit

protocol ScanTarget: AnyObject {
    var id: TargetID { get }
    /// Short name for the glasses, e.g. "PHONE" or "ZEPHYRUS".
    var displayName: String { get }
    func deliver(_ text: String, mode: PasteMode) async -> DeliveryStatus
}

final class PhoneClipboardTarget: ScanTarget {
    let id = TargetID.phone
    let displayName = "PHONE"

    func deliver(_ text: String, mode: PasteMode) async -> DeliveryStatus {
        guard UIApplication.shared.applicationState == .active else { return .awaitingAppOpen }
        UIPasteboard.general.string = text
        return .delivered(.copied)
    }

    /// Copies every scan that finished while CARBON was in the background, oldest first,
    /// separated by blank lines, so none is lost. Returns the IDs that are now on the clipboard.
    func copyAwaiting(_ scans: [Scan]) -> [Scan.ID] {
        guard UIApplication.shared.applicationState == .active, !scans.isEmpty else { return [] }
        let oldestFirst = scans.sorted { $0.createdAt < $1.createdAt }
        UIPasteboard.general.string = oldestFirst.map(\.text).joined(separator: "\n\n")
        return oldestFirst.map(\.id)
    }
}
