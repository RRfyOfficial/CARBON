// The Target socket (SPEC 8.1) and the phone target. iOS drops clipboard writes from the
// background (M0 U5), so a scan that finishes while CARBON isn't on screen waits for the app to open.

import UIKit

protocol ScanTarget: AnyObject {
    var id: TargetID { get }
    /// Short name for the glasses, e.g. "PHONE" or "ZEPHYRUS".
    var displayName: String { get }
    /// `id` is the scan's id; the laptop uses it to never paste the same clip twice.
    func deliver(_ text: String, id: UUID, mode: PasteMode) async -> DeliveryStatus
}

final class PhoneClipboardTarget: ScanTarget {
    let id = TargetID.phone
    let displayName = "PHONE"

    func deliver(_ text: String, id: UUID, mode: PasteMode) async -> DeliveryStatus {
        write(text) ? .delivered(.copied) : .awaitingAppOpen
    }

    /// Copies every scan that finished while CARBON was in the background, oldest first,
    /// separated by blank lines, so none is lost. Returns the IDs that are now on the clipboard.
    func copyAwaiting(_ scans: [Scan]) -> [Scan.ID] {
        guard !scans.isEmpty else { return [] }
        let oldestFirst = scans.sorted { $0.createdAt < $1.createdAt }
        return write(oldestFirst.map(\.text).joined(separator: "\n\n")) ? oldestFirst.map(\.id) : []
    }

    /// iOS drops clipboard writes it doesn't allow without an error (M0 U5: the change count stayed
    /// put), so only a changed count proves the text landed. Checking `applicationState` first
    /// wasn't enough: it can still read "inactive" when the scene has just become active.
    private func write(_ text: String) -> Bool {
        let before = UIPasteboard.general.changeCount
        UIPasteboard.general.string = text
        return UIPasteboard.general.changeCount != before
    }
}
