// Reader v1, As-is (SPEC 8.4): Apple Vision text recognition, on-device and free.

import CoreGraphics
import CoreML
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

    /// Where Vision runs its main (model) stage. The phone dropped whole lines of slide 3 that the iOS
    /// simulator, which has no Neural Engine, read perfectly from the same photos (M1 reader lab).
    nonisolated enum Processor: String, Sendable, CaseIterable {
        case cpu, gpu, neuralEngine

        func matches(_ device: MLComputeDevice) -> Bool {
            switch (self, device) {
            case (.cpu, .cpu), (.gpu, .gpu), (.neuralEngine, .neuralEngine): true
            default: false
            }
        }
    }

    /// Counts for the reader lab: how many observations Vision returned, how many had no text,
    /// and the device the main stage was pinned to.
    nonisolated struct Stats: Sendable {
        var observations = 0
        var blank = 0
        var device: String?
    }

    /// Smallest text Vision looks for, as a fraction of image height. nil leaves Vision's own default,
    /// which behaves better on the phone than setting the documented default of 1/32 explicitly:
    /// a slide-3 photo read perfectly unset and returned nothing at an explicit 1/32 (M1 reader lab).
    var minimumTextHeight: Float?
    /// Enlarge the photo (or crop) before recognition. Slide text from a seat can be only 13-15 px tall.
    var upscale: CGFloat = 1
    var languageCorrection = true
    var engine: Engine = .modern
    /// Read only this region, normalized to the upright image with a top-left origin. Lines come
    /// back in full-image pixels either way.
    var crop: CGRect?
    /// Pin the main stage to this processor (modern engine only); nil lets Vision choose.
    var processor: Processor?
    /// Turn the whole upright photo by this many degrees before reading (negative = clockwise, which
    /// levels text rising to the right). Ignores `crop` and `upscale`; lines come back in pixels of
    /// the turned canvas.
    var rotateDegrees: Double = 0
    /// Redraw the decoded photo into a plain 8-bit RGB bitmap before reading.
    var redraw = false
    /// Hand Vision the file itself instead of our decoded image (modern engine only). Ignores
    /// `crop`, `upscale`, `rotateDegrees` and `redraw`.
    var visionDecodes = false

    /// The devices Vision offers for each stage of text recognition on this device, for the log.
    static func computeDevices() -> String {
        RecognizeTextRequest().supportedComputeStageDevices
            .sorted { "\($0.key)" < "\($1.key)" }
            .map { "\($0.key): \($0.value.map(String.init(describing:)).joined(separator: ", "))" }
            .joined(separator: " · ")
    }

    func read(_ photo: Data) async throws -> ReadText {
        try await readWithStats(photo).text
    }

    func readWithStats(_ photo: Data) async throws -> (text: ReadText, stats: Stats) {
        let output = try await recognizeLines(photo)
        var text = ReadingOrder.blocks(from: output.lines)
        text.cutEdges = ReadingOrder.cutEdges(of: output.lines, imageHeight: output.imageSize.height)
        return (text, output.stats)
    }

    struct Output: Sendable {
        var lines: [RecognizedLine]
        var imageSize: CGSize
        var stats: Stats
    }

    /// The raw lines in full-image pixels, top-left origin, plus the full upright image size.
    func recognizeLines(_ photo: Data) async throws -> Output {
        try await Self.recognize(photo, options: self)
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
        let fullWidth = CGFloat(decoded.width), fullHeight = CGFloat(decoded.height)

        // Cropping works in the stored pixel grid, so it's only applied to upright photos
        // (the glasses deliver .up); anything else is read whole.
        var region = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        var input = decoded
        var image = decoded
        var uprightSize = CGSize(width: fullWidth, height: fullHeight)
        if options.visionDecodes {
            // Vision reads the file; nothing of ours touches the pixels.
        } else if options.rotateDegrees != 0, orientation == .up,
                  let turned = rotated(decoded, by: options.rotateDegrees * .pi / 180) {
            image = turned
            region = CGRect(x: 0, y: 0, width: turned.width, height: turned.height)
            uprightSize = region.size
        } else {
            if let crop = options.crop, orientation == .up {
                let wanted = CGRect(x: crop.minX * fullWidth, y: crop.minY * fullHeight,
                                    width: crop.width * fullWidth, height: crop.height * fullHeight).integral
                    .intersection(region)
                if !wanted.isEmpty, let cropped = decoded.cropping(to: wanted) {
                    region = wanted
                    input = cropped
                }
            }
            image = options.upscale > 1 || options.redraw ? (scaled(input, by: max(options.upscale, 1)) ?? input) : input
        }
        let scale = CGFloat(image.width) / region.width

        // Vision's points are normalized to the (cropped, scaled) upright image with a bottom-left
        // origin. Map them back to full-image pixels with a top-left origin.
        let quarterTurn: Set<CGImagePropertyOrientation> = [.left, .leftMirrored, .right, .rightMirrored]
        let width = CGFloat(quarterTurn.contains(orientation) ? image.height : image.width)
        let height = CGFloat(quarterTurn.contains(orientation) ? image.width : image.height)
        func pixel(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: region.minX + x * width / scale, y: region.minY + (1 - y) * height / scale)
        }
        if quarterTurn.contains(orientation) {
            uprightSize = CGSize(width: uprightSize.height, height: uprightSize.width)
        }

        var stats = Stats()
        var lines: [RecognizedLine] = []
        switch options.engine {
        case .modern:
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = options.languageCorrection
            request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
            if let minimum = options.minimumTextHeight {
                request.minimumTextHeightFraction = minimum
            }
            if let processor = options.processor {
                let device = request.supportedComputeStageDevices[.main]?.first(where: processor.matches)
                request.setComputeDevice(device, for: .main)
                stats.device = device.map(String.init(describing:)) ?? "\(processor.rawValue) not offered, Vision chose"
            }
            let observations: [RecognizedTextObservation] = options.visionDecodes
                ? try await request.perform(on: photo, orientation: nil)
                : try await request.perform(on: image, orientation: orientation)
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
            if let minimum = options.minimumTextHeight {
                request.minimumTextHeight = minimum
            }
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
        return Output(lines: lines, imageSize: uprightSize, stats: stats)
    }

    /// The region around the given lines, padded by `margin` of its own size on every side,
    /// normalized to the image (top-left origin). nil when there are no lines.
    static func textRegion(of lines: [RecognizedLine], in size: CGSize, margin: CGFloat = 0.25) -> CGRect? {
        let points = lines.flatMap(\.corners)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              size.width > 0, size.height > 0 else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -(maxX - minX) * margin, dy: -(maxY - minY) * margin)
        let normalized = CGRect(x: box.minX / size.width, y: box.minY / size.height,
                                width: box.width / size.width, height: box.height / size.height)
        return normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The image turned by `radians` around its centre (negative = clockwise on screen), on a canvas
    /// big enough to keep every corner; the uncovered corners are white.
    private static func rotated(_ image: CGImage, by radians: CGFloat) -> CGImage? {
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        let (c, s) = (abs(cos(radians)), abs(sin(radians)))
        let (width, height) = (Int((w * c + h * s).rounded(.up)), Int((w * s + h * c).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // CoreGraphics is y-up, so a negative angle turns the picture clockwise.
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: radians)
        context.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return context.makeImage()
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
