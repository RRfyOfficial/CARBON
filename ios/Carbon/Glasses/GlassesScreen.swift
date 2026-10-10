// What the glasses show (SPEC 6.2). Every case is one full display send. Plain values: the
// builders in Screens/ turn them into display views.

import Foundation

nonisolated enum GlassesScreen: Equatable, Sendable {
    case main(Main)
    case scanning(Scanning)
    case done(Done, filled: Bool)
    case error(ScanError, elapsed: Double?)
    /// A new laptop pairing completed during a session (SPEC 6.2, PAIR).
    case linked(name: String, filled: Bool)
    /// One saved scan (SPEC 6.2, HISTORY).
    case history(History)
    case settings(Settings)
    /// SETTINGS › PAIR NEW COMPUTER: pairing runs from the phone and the companion.
    case pairInfo
    /// The dot-matrix wordmark while the display starts (SPEC 7.4).
    case boot

    nonisolated struct History: Equatable, Sendable {
        /// 0 is the newest.
        var index: Int
        var count: Int
        /// "12:38 · ZEPHYRUS · AUTOPASTE", plus " · NOT DELIVERED" when it didn't reach the laptop.
        var meta: String
        /// Up to 8 lines of the scan, already shortened.
        var lines: [String]

        var isOldest: Bool { index >= count - 1 }
        var isNewest: Bool { index == 0 }
    }

    nonisolated struct Settings: Equatable, Sendable {
        var target: String
        /// nil when the target is the phone (PASTE is laptop only).
        var paste: String?
        var lineBreaks: Bool
        var sound: Bool
    }

    /// The rows of SETTINGS, in order (SPEC 6.2).
    nonisolated enum SettingRow: Sendable {
        case target, paste, lineBreaks, sound, pair
    }

    nonisolated struct Main: Equatable, Sendable {
        var targetLabel = "TARGET·PHONE"
        /// "LAST · 12:41 · 214 CHARS", or nil before the first scan.
        var lastLine: String?
        /// Up to 3 lines of the last scan, already shortened.
        var preview: [String] = []
        var showCameraHint = true
    }

    nonisolated struct Scanning: Equatable, Sendable {
        nonisolated enum Stage: Int, Comparable, Sendable {
            case capture, transfer, read, copy

            static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }

            /// The last stage is SEND for the laptop and COPY for the phone (SPEC 6.2).
            func railName(toLaptop: Bool) -> String {
                switch self {
                case .capture: "CAPTURE"
                case .transfer: "TRANSFER"
                case .read: "READ"
                case .copy: toLaptop ? "SEND" : "COPY"
                }
            }

            func heading(toLaptop: Bool) -> String {
                switch self {
                case .capture: "CAPTURING"
                case .transfer: "TRANSFERRING"
                case .read: "READING"
                case .copy: toLaptop ? "SENDING" : "COPYING"
                }
            }
        }

        var targetLabel = "TARGET·PHONE"
        var toLaptop = false
        var stage: Stage = .capture
        var transferPercent: Int?
        var elapsed: Double = 0
        var stillWorking = false
        var detail = false
    }

    nonisolated struct Done: Equatable, Sendable {
        var chars: Int
        var targetName = "PHONE"
        var how = "ON PHONE CLIPBOARD"
        var elapsed: Double
        /// Shown when text ran into the photo's edge, e.g. "CUT AT THE TOP · AIM HIGHER".
        var warning: String?
    }
}

nonisolated extension CutEdge {
    /// What the wearer should do about text cut off at these edges.
    static func advice(for edges: Set<CutEdge>?) -> String? {
        switch (edges?.contains(.top) ?? false, edges?.contains(.bottom) ?? false) {
        case (true, true): "TEXT CUT OFF · STEP BACK"
        case (true, false): "CUT AT THE TOP · AIM HIGHER"
        case (false, true): "CUT AT THE BOTTOM · AIM LOWER"
        case (false, false): nil
        }
    }
}

nonisolated extension ScanError {
    var heading: String {
        switch self {
        case .noText: "NO TEXT FOUND"
        case .captureFailed: "CAPTURE FAILED"
        case .timeout: "TOOK TOO LONG"
        case .notDelivered, .notDeliveredOpenToCopy: "SAVED TO PHONE"
        case .openToCopy: "SAVED"
        case .pasteBlocked, .autopasteOff: "COPIED, NOT PASTED"
        case .version: "UPDATE NEEDED"
        }
    }

    var detail: String {
        switch self {
        case .noText: "AIM AT THE BOARD AND TRY AGAIN"
        case .captureFailed: "GLASSES CAMERA DIDN'T RESPOND"
        case .timeout: "TRY AGAIN"
        case .notDelivered: "LAPTOP UNREACHABLE · ON PHONE CLIPBOARD"
        case .notDeliveredOpenToCopy: "LAPTOP UNREACHABLE · OPEN CARBON TO COPY"
        case .openToCopy: "OPEN CARBON TO COPY"
        case .pasteBlocked: "THAT WINDOW IS RUNNING AS ADMIN"
        case .autopasteOff: "AUTOPASTE IS OFF ON THIS PC"
        case .version: "UPDATE THE COMPANION APP"
        }
    }

    /// The scan is safe (saved or copied); shown like DONE, with no RETRY (SPEC 6.2).
    var isSafe: Bool {
        switch self {
        case .notDelivered, .notDeliveredOpenToCopy, .openToCopy, .pasteBlocked, .autopasteOff: true
        case .noText, .captureFailed, .timeout, .version: false
        }
    }
}
