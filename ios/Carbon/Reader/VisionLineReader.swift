// Reader v1, As-is (SPEC 8.4): Apple Vision RecognizeTextRequest, on-device and free.

import CoreGraphics
import Foundation
import ImageIO
import Vision

nonisolated struct VisionLineReader: TextReader {
    /// Smallest text Vision looks for, as a fraction of image height. Vision's default is 1/32
    /// (about 34 px in a 1080 px photo). Slide text from a seat can be 13-15 px; text below the
    /// minimum is handled inconsistently (M1: the phone dropped lines the Mac kept).
    var minimumTextHeight: Float = 1.0 / 32

    func read(_ photo: Data) async throws -> ReadText {
        let (lines, imageHeight) = try await Self.recognize(photo, minimumTextHeight: minimumTextHeight)
        var text = ReadingOrder.blocks(from: lines)
        text.cutEdges = ReadingOrder.cutEdges(of: lines, imageHeight: imageHeight)
        return text
    }

    /// Decoding and recognition run off the main actor. Returns the lines and the upright image height.
    @concurrent
    private static func recognize(_ photo: Data, minimumTextHeight: Float) async throws -> (lines: [RecognizedLine], imageHeight: CGFloat) {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil) else {
            throw ReaderError.undecodableImage
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw ReaderError.undecodableImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        request.minimumTextHeightFraction = minimumTextHeight
        let observations: [RecognizedTextObservation] = try await request.perform(on: image, orientation: orientation)

        // Vision's points are normalized to the upright image with a bottom-left origin.
        let quarterTurn: Set<CGImagePropertyOrientation> = [.left, .leftMirrored, .right, .rightMirrored]
        let width = CGFloat(quarterTurn.contains(orientation) ? image.height : image.width)
        let height = CGFloat(quarterTurn.contains(orientation) ? image.width : image.height)
        func pixel(_ p: NormalizedPoint) -> CGPoint { CGPoint(x: p.x * width, y: (1 - p.y) * height) }

        let lines = observations.compactMap { observation -> RecognizedLine? in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            return RecognizedLine(text: text, corners: corners.map(pixel))
        }
        return (lines, height)
    }
}
