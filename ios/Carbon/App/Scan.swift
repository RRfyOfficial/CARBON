// Core scan types (SPEC 8.1). Plain values, usable from any isolation domain.

import Foundation

/// Where a scan's text goes: the iPhone itself, or a paired laptop (M2).
nonisolated enum TargetID: Codable, Hashable, Sendable {
    case phone
    case laptop(deviceID: String)
}

nonisolated enum PasteMode: String, Codable, Sendable {
    case clipboard
    case autopaste
}

/// Fast scan on every pinch (LARGE/MEDIUM); detail scan on a camera-button hold (LARGE/HIGH, M3).
nonisolated enum ScanKind: String, Codable, Sendable {
    case fast
    case detail
}

/// The error codes shown on the glasses (SPEC 6.2, ERROR).
nonisolated enum ScanError: String, Codable, Error, Sendable {
    case noText = "NO_TEXT"
    case captureFailed = "CAPTURE_FAILED"
    case timeout = "TIMEOUT"
    case notDelivered = "NOT_DELIVERED"
    case openToCopy = "OPEN_TO_COPY"
    case pasteBlocked = "PASTE_BLOCKED"
    case autopasteOff = "AUTOPASTE_OFF"
    case version = "VERSION"
}

nonisolated enum DeliveryStatus: Codable, Equatable, Sendable {
    nonisolated enum How: String, Codable, Sendable {
        case copied
        case pasted
    }

    /// Phone target while CARBON was in the background: iOS blocks the clipboard (M0 U5),
    /// so the text is copied the moment CARBON opens.
    case awaitingAppOpen
    case delivered(How)
    case notDelivered
    case failed(ScanError)
}

/// Milliseconds since the trigger.
nonisolated struct StageTimings: Codable, Equatable, Sendable {
    var captureRequested: Int?
    var firstByte: Int?
    var photoReceived: Int?
    var readDone: Int?
    var formatted: Int?
    var delivered: Int?
}

nonisolated struct Scan: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    var text: String
    var html: String?
    var target: TargetID
    var pasteMode: PasteMode
    var kind: ScanKind
    var timings: StageTimings
    var delivery: DeliveryStatus
    var photoBytes: Int?
    /// Text ran into the photo's top or bottom edge, so some was probably cut off.
    var cutEdges: Set<CutEdge>?

    var charCount: Int { text.count }
}
