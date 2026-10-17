// On-device accuracy check against the fixture deck (tools/fixture-deck): while it's on, each scan
// is compared with the bundled ground truth for the current slide, then the slide advances.
// M1 gates CER <= 2% on the body-text slides only.

import Foundation
import Observation

nonisolated struct FixtureResult: Identifiable, Sendable {
    let id = UUID()
    let slide: Int
    let cer: Double?
    let totalMs: Int?
    let chars: Int
}

@Observable
final class FixtureCheck {
    static let slideCount = 10
    /// Title, bullets, paragraph, numbered list, numbers, dark slide (M0, M1).
    static let bodyTextSlides: Set<Int> = [1, 2, 3, 4, 7, 10]

    var isOn = false
    var slide = 1
    private(set) var results: [FixtureResult] = []

    func record(_ scan: Scan) {
        guard isOn else { return }
        let cer = Self.truth(for: slide).flatMap { CharacterErrorRate.of(scan.text, truth: $0) }
        results.append(FixtureResult(slide: slide, cer: cer, totalMs: scan.timings.delivered, chars: scan.charCount))
        slide = slide % Self.slideCount + 1
    }

    func reset() {
        results = []
        slide = 1
    }

    var bodyTextMeanCER: Double? {
        mean(results.filter { Self.bodyTextSlides.contains($0.slide) }.compactMap(\.cer))
    }

    var allSlidesMeanCER: Double? {
        mean(results.compactMap(\.cer))
    }

    static func truth(for slide: Int) -> String? {
        guard let url = Bundle.main.url(forResource: String(format: "slide%02d", slide), withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
