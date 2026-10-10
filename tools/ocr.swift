#!/usr/bin/env swift
// CARBON M0: Apple Vision OCR accuracy (CER) over a folder of fixture photos.
// Implements SPEC 8.4 "Reader v1" (Vision settings + reading order) and SPEC 8.3 (CER).
// Usage: swift ocr.swift <folder> [--truth <file> | --truth-dir <dir>] [--out <dir>] [--show]

import CoreGraphics
import Foundation
import ImageIO
import Vision

// MARK: - Types

enum Tool {
    static let usage = "usage: swift ocr.swift <folder> [--truth <file> | --truth-dir <dir>] [--out <dir>] [--show]"
    static let imageExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
    static let resolutions: Set<String> = ["LARGE", "FULL"]
    static let qualities: Set<String> = ["MEDIUM", "HIGH"]
}

struct ToolError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct Setup {
    let images: [URL]
    let sharedTruth: String?
    let truthDir: URL?
    let outDir: URL?
    let show: Bool
}

/// Capture settings parsed from `<anything>-<RES>-<QUALITY>.<ext>`, or "other".
struct CaptureConfig {
    let res: String
    let quality: String
    var key: String { res == "other" ? "other" : "\(res)-\(quality)" }

    static func parse(baseName: String) -> CaptureConfig {
        let parts = baseName.uppercased().split(separator: "-").map(String.init)
        guard parts.count >= 2,
              Tool.resolutions.contains(parts[parts.count - 2]),
              Tool.qualities.contains(parts[parts.count - 1])
        else { return CaptureConfig(res: "other", quality: "other") }
        return CaptureConfig(res: parts[parts.count - 2], quality: parts[parts.count - 1])
    }
}

/// One recognized line. `box` is normalized with a TOP-LEFT origin.
struct Line {
    let text: String
    let box: CGRect
}

struct Row {
    var lines: [Line]
    var top: CGFloat { lines.map { $0.box.minY }.min() ?? 0 }
    var bottom: CGFloat { lines.map { $0.box.maxY }.max() ?? 0 }
    var text: String {
        lines.sorted { $0.box.minX < $1.box.minX }.map { $0.text }.joined(separator: " ")
    }
}

struct ImageResult {
    let file: String
    let config: CaptureConfig
    let text: String
    let noText: Bool
    let ocrMs: Double
    let cer: Double?
}

// MARK: - Image loading and Vision

func loadImage(_ url: URL) throws -> (CGImage, CGImagePropertyOrientation) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw ToolError("cannot open image")
    }
    let index = CGImageSourceGetPrimaryImageIndex(source)
    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
        throw ToolError("cannot decode image")
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
    let raw = (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
    return (image, CGImagePropertyOrientation(rawValue: raw) ?? .up)
}

@available(macOS 15.0, *)
func recognizeLines(in image: CGImage, orientation: CGImagePropertyOrientation) async throws -> [Line] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
    // Docs give the return type only as `Self.Result`; the explicit annotation turns a mismatch into a compile error.
    let observations: [RecognizedTextObservation] = try await request.perform(on: image, orientation: orientation)
    return observations.compactMap { observation -> Line? in
        guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
        let r = observation.boundingBox.cgRect  // normalized, BOTTOM-LEFT origin
        return Line(text: text, box: CGRect(x: r.minX, y: 1 - r.minY - r.height, width: r.width, height: r.height))
    }
}

@available(macOS 15.0, *)
func processImage(_ url: URL, truth: String?) async throws -> ImageResult {
    let (image, orientation) = try loadImage(url)
    let start = ProcessInfo.processInfo.systemUptime
    let lines = try await recognizeLines(in: image, orientation: orientation)
    let ocrMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
    let ordered = readingOrderText(lines)
    let noText = ordered.filter { !$0.isWhitespace }.count < 2
    let text = noText ? "" : ordered
    return ImageResult(
        file: url.lastPathComponent,
        config: .parse(baseName: url.deletingPathExtension().lastPathComponent),
        text: text,
        noText: noText,
        ocrMs: ocrMs,
        cer: truth.flatMap { characterErrorRate(ocr: text, truth: $0) })
}

// MARK: - Reading order (SPEC 8.4)

func readingOrderText(_ lines: [Line]) -> String {
    let sorted = lines.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
    let rows = groupIntoRows(sorted)
    let blockGap = 1.2 * median(lines.map { $0.box.height })
    var output: [String] = []
    for (i, row) in rows.enumerated() {
        if i > 0, row.top - rows[i - 1].bottom > blockGap { output.append("") }
        output.append(trimmingTrailingWhitespace(row.text))
    }
    return trimmingTrailingWhitespace(output.joined(separator: "\n")).precomposedStringWithCanonicalMapping
}

/// A line joins the current row if it overlaps any line already in it by >= 50% of the shorter height.
func groupIntoRows(_ sortedLines: [Line]) -> [Row] {
    var rows: [Row] = []
    for line in sortedLines {
        if let current = rows.last, current.lines.contains(where: { sameRow($0.box, line.box) }) {
            rows[rows.count - 1].lines.append(line)
        } else {
            rows.append(Row(lines: [line]))
        }
    }
    return rows
}

func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
    let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
    return overlap > 0 && overlap >= 0.5 * min(a.height, b.height)
}

func median(_ values: [CGFloat]) -> CGFloat {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

func trimmingTrailingWhitespace(_ s: String) -> String {
    var result = Substring(s)
    while let last = result.last, last.isWhitespace { result.removeLast() }
    return String(result)
}

// MARK: - CER (SPEC 8.3)

func collapseWhitespace(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// (S + D + I) / N over Characters (grapheme clusters), case-sensitive. nil when the truth is empty.
func characterErrorRate(ocr: String, truth: String) -> Double? {
    let reference = Array(collapseWhitespace(truth))
    guard !reference.isEmpty else { return nil }
    let (hypothesisIDs, referenceIDs) = characterIDs(Array(collapseWhitespace(ocr)), reference)
    return Double(levenshtein(hypothesisIDs, referenceIDs)) / Double(reference.count)
}

/// Maps Characters to small ints so the DP loop compares Ints, not grapheme clusters.
/// Character hashing respects canonical equivalence, so this preserves `==` semantics.
func characterIDs(_ a: [Character], _ b: [Character]) -> ([Int], [Int]) {
    var table: [Character: Int] = [:]
    func id(_ c: Character) -> Int {
        if let known = table[c] { return known }
        table[c] = table.count
        return table.count - 1
    }
    let ids = a.map(id)
    return (ids, b.map(id))
}

/// Two-row Levenshtein, O(min(m, n)) memory.
func levenshtein(_ a: [Int], _ b: [Int]) -> Int {
    let (long, short) = a.count >= b.count ? (a, b) : (b, a)
    var previous = Array(0...short.count)
    var current = Array(repeating: 0, count: short.count + 1)
    for i in 0..<long.count {
        current[0] = i + 1
        for j in 0..<short.count {
            let substitution = previous[j] + (long[i] == short[j] ? 0 : 1)
            current[j + 1] = min(substitution, previous[j + 1] + 1, current[j] + 1)
        }
        swap(&previous, &current)
    }
    return previous[short.count]
}

// MARK: - Command line

/// Parses and validates the arguments. Any thrown error is a usage error (exit 2).
func makeSetup(_ args: [String]) throws -> Setup {
    var folderPath: String?, truthPath: String?, truthDirPath: String?, outPath: String?, show = false
    var rest = args[...]
    while let arg = rest.popFirst() {
        switch arg {
        case "--truth": truthPath = try optionValue(for: arg, from: &rest)
        case "--truth-dir": truthDirPath = try optionValue(for: arg, from: &rest)
        case "--out": outPath = try optionValue(for: arg, from: &rest)
        case "--show": show = true
        case _ where arg.hasPrefix("-"): throw ToolError("unknown option \(arg)")
        case _ where folderPath != nil: throw ToolError("only one <folder> is allowed")
        default: folderPath = arg
        }
    }
    guard let folder = folderPath else { throw ToolError("missing <folder>") }
    let images = try imageFiles(in: folder)

    var sharedTruth: String?
    if let truthPath {
        guard let text = try? readText(URL(fileURLWithPath: truthPath)) else {
            throw ToolError("cannot read --truth file \(truthPath)")
        }
        sharedTruth = text
    }
    var truthDir: URL?
    if let truthDirPath {
        let dir = URL(fileURLWithPath: truthDirPath, isDirectory: true)
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw ToolError("not a folder: --truth-dir \(truthDirPath)")
        }
        truthDir = dir
    }
    var outDir: URL?
    if let outPath {
        let dir = URL(fileURLWithPath: outPath, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw ToolError("cannot create --out folder \(outPath)") }
        outDir = dir
    }
    return Setup(images: images, sharedTruth: sharedTruth, truthDir: truthDir, outDir: outDir, show: show)
}

func optionValue(for option: String, from rest: inout ArraySlice<String>) throws -> String {
    guard let value = rest.popFirst() else { throw ToolError("\(option) needs a value") }
    return value
}

func imageFiles(in folderPath: String) throws -> [URL] {
    let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
    guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
        throw ToolError("not a folder: \(folderPath)")
    }
    let images = try FileManager.default
        .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        .filter { Tool.imageExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !images.isEmpty else { throw ToolError("no .heic/.jpg/.jpeg/.png images in \(folderPath)") }
    return images
}

/// UTF-8 text with an optional BOM stripped (truth files may be written on Windows).
func readText(_ url: URL) throws -> String {
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
}

/// `--truth` applies to every image. `--truth-dir` maps `slide03-r1-LARGE-MEDIUM.heic` to
/// `<dir>/slide03.txt` (the name up to the first "-"). Otherwise `NAME.txt` next to `NAME.<ext>`.
func groundTruth(for image: URL, shared: String?, truthDir: URL?) -> String? {
    if let shared { return shared }
    if let truthDir {
        let prefix = image.deletingPathExtension().lastPathComponent.split(separator: "-").first.map(String.init) ?? ""
        return try? readText(truthDir.appendingPathComponent(prefix + ".txt"))
    }
    return try? readText(image.deletingPathExtension().appendingPathExtension("txt"))
}

// MARK: - Output

func fixed(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }

func cerText(_ cer: Double?) -> String { cer.map { fixed($0, 4) } ?? "n/a" }

func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func report(_ r: ImageResult, show: Bool) {
    let flag = r.noText ? " NO_TEXT" : ""
    print("RESULT \(r.file) chars=\(r.text.count) ocr_ms=\(fixed(r.ocrMs, 0)) cer=\(cerText(r.cer))\(flag)")
    guard show else { return }
    for line in (r.noText ? "(no text)" : r.text).split(separator: "\n", omittingEmptySubsequences: false) {
        print(line.isEmpty ? "" : "    \(line)")
    }
}

func summaryTable(_ results: [ImageResult]) -> String {
    let groups = Dictionary(grouping: results) { $0.config.key }
    let keys = groups.keys.filter { $0 != "other" }.sorted() + groups.keys.filter { $0 == "other" }
    var rows = [["group", "count", "mean_cer", "max_cer", "mean_ocr_ms"]]
    for key in keys {
        let items = groups[key] ?? []
        let cers = items.compactMap { $0.cer }
        rows.append([
            key,
            String(items.count),
            cers.isEmpty ? "n/a" : fixed(mean(cers), 4),
            cerText(cers.max()),
            fixed(mean(items.map { $0.ocrMs }), 0),
        ])
    }
    return alignedTable(rows)
}

/// First column left-aligned, the rest right-aligned, two spaces between columns.
func alignedTable(_ rows: [[String]]) -> String {
    let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
    return rows.map { row in
        row.indices.map { column -> String in
            let padding = String(repeating: " ", count: widths[column] - row[column].count)
            return column == 0 ? row[column] + padding : padding + row[column]
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}

func csvBlock(_ results: [ImageResult]) -> String {
    let rows = results.map { r in
        [csvField(r.file), r.config.res, r.config.quality, String(r.text.count), fixed(r.ocrMs, 0), cerText(r.cer)]
            .joined(separator: ",")
    }
    return (["file,res,quality,chars,ocr_ms,cer"] + rows).joined(separator: "\n")
}

func csvField(_ s: String) -> String {
    guard s.contains(where: { $0 == "," || $0 == "\"" }) else { return s }
    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

// MARK: - Main

@available(macOS 15.0, *)
func runTool(_ args: [String]) async -> Int32 {
    let setup: Setup
    do {
        setup = try makeSetup(args)
    } catch {
        writeError("error: \(error.localizedDescription)\n\(Tool.usage)")
        return 2
    }
    var results: [ImageResult] = []
    var failures = 0
    for url in setup.images {
        do {
            let truth = groundTruth(for: url, shared: setup.sharedTruth, truthDir: setup.truthDir)
            let result = try await processImage(url, truth: truth)
            results.append(result)
            report(result, show: setup.show)
            if let outDir = setup.outDir {
                let file = outDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".ocr.txt")
                try (result.text.isEmpty ? "" : result.text + "\n").write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            failures += 1
            writeError("ERROR \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
    print("--- SUMMARY ---")
    print(summaryTable(results))
    if failures > 0 { print("failed: \(failures)") }
    print("--- CSV ---")
    print(csvBlock(results))
    return failures > 0 ? 1 : 0
}

// Guarded so the script also compiles if the interpreter's default deployment target is below macOS 15.
if #available(macOS 15.0, *) {
    let code = await runTool(Array(CommandLine.arguments.dropFirst()))
    exit(code)
} else {
    writeError("ocr.swift needs macOS 15 or newer (Vision RecognizeTextRequest).")
    exit(1)
}
