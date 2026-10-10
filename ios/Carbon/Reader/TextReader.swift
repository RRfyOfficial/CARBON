// The Reader socket (SPEC 8.1): photo bytes in, text in reading order out.

import CoreGraphics
import Foundation

/// One recognized line: its string and corner points in pixels, top-left origin,
/// in the order top-left, top-right, bottom-right, bottom-left.
nonisolated struct RecognizedLine: Sendable, Equatable {
    let text: String
    let corners: [CGPoint]
}

/// Text in reading order: blocks of rows, top to bottom. Each row is already joined left to right.
nonisolated struct ReadText: Sendable, Equatable {
    var blocks: [[String]]
    var skewDegrees: Double = 0

    /// Fewer than 2 recognized characters counts as no text (SPEC 8.4).
    var isEmpty: Bool {
        blocks.joined().joined().filter { !$0.isWhitespace }.count < 2
    }
}

nonisolated enum ReaderError: Error, Equatable {
    case undecodableImage
}

protocol TextReader: Sendable {
    func read(_ photo: Data) async throws -> ReadText
}
