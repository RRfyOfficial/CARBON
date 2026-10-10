// Reader v1, As-is (SPEC 8.4): Apple Vision text recognition, on-device and free.

import CoreGraphics
import Foundation
import ImageIO
import Vision

nonisolated struct VisionLineReader: TextReader {
    nonisolated enum Engine: String, Sendable {
        /// RecognizeTextRequest, the Swift API (iOS 18+).
        case modern
        /// VNRecognizeTextRequest, the older API: a different code path on the device.
        case legacy
    }

    /// Counts for the reader lab: how many observations Vision returned, and how many had no text.
    nonisolated struct Stats: Sendable {
        var observations = 0
        var blank = 0
    }

    /// Smallest text Vision looks for, as a fraction of image height (Vision's default is 1/32).
    var minimumTextHeight: Float = 1.0 / 32
    /// Enlarge the photo before recognition. Slide text from a seat can be only 13-15 px tall.
    var upscale: CGFloat = 1
    var languageCorrection = true
    var engine: Engine = .modern

    func read(_ photo: Data) async throws -> ReadText {
        try await readWithStats(photo).text
    }

    func readWithStats(_ photo: Data) async throws -> (text: ReadText, stats: Stats) {
        let output = try await Self.recognize(photo, options: self)
        var text = ReadingOrder.blocks(from: output.lines)
        text.cutEdges = ReadingOrder.cutEdges(of: output.lines, imageHeight: output.imageHeight)
        return (text, output.stats)
    }

    private struct Output {
        var lines: [RecognizedLine]
        var imageHeight: CGFloat
        var stats: Stats
    }

    /// Decoding and recognition run off the main actor. Line corners are in pixels of the
    /// (possibly enlarged) upright image, top-left origin.
    @concurrent
    private static func recognize(_ photo: Data, options: VisionLineReader) async throws -> Output {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil) else {
            throw ReaderError.undecodableImage
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let decoded = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw ReaderError.undecodableImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        let image = options.upscale > 1 ? (scaled(decoded, by: options.upscale) ?? decoded) : decoded

        // Vision's points are normalized to the upright image with a bottom-left origin.
        let quarterTurn: Set<CGImagePropertyOrientation> = [.left, .leftMirrored, .right, .rightMirrored]
        let width = CGFloat(quarterTurn.contains(orientation) ? image.height : image.width)
        let height = CGFloat(quarterTurn.contains(orientation) ? image.width : image.height)
        func pixel(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * width, y: (1 - y) * height) }

        var stats = Stats()
        var lines: [RecognizedLine] = []
        switch options.engine {
        case .modern:
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = options.languageCorrection
            request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
            request.minimumTextHeightFraction = options.minimumTextHeight
            let observations: [RecognizedTextObservation] = try await request.perform(on: image, orientation: orientation)
            stats.observations = observations.count
            for observation in observations {
                guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else {
                    stats.blank += 1
                    continue
                }
                let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
                lines.append(RecognizedLine(text: text, corners: corners.map { pixel($0.x, $0.y) }))
            }
        case .legacy:
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = options.languageCorrection
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = options.minimumTextHeight
            try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
            let observations = request.results ?? []
            stats.observations = observations.count
            for observation in observations {
                guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else {
                    stats.blank += 1
                    continue
                }
                let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
                lines.append(RecognizedLine(text: text, corners: corners.map { pixel($0.x, $0.y) }))
            }
        }
        return Output(lines: lines, imageHeight: height, stats: stats)
    }

    private static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = Int(CGFloat(image.width) * factor)
        let height = Int(CGFloat(image.height) * factor)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
