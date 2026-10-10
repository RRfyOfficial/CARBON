// Reading order for Reader v1 (SPEC 8.4), including the deskew step added in M0.
// Pure geometry, no Vision: the same algorithm as tools/ocr.swift --deskew.

import CoreGraphics
import Foundation

nonisolated enum ReadingOrder {
    /// Groups lines into rows and blocks. With `deskew`, all corners are first rotated by the
    /// page's tilt, so a slightly tilted photo doesn't inflate line boxes and merge rows.
    static func blocks(from lines: [RecognizedLine], deskew: Bool = true) -> ReadText {
        let theta = deskew ? estimateSkew(lines) : 0
        let boxed = lines.map { Boxed(text: $0.text, box: boundingBox(of: $0.corners, rotatedBy: theta)) }
        let sorted = boxed.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
        let rows = groupIntoRows(sorted)
        let blockGap = 1.2 * median(boxed.map { $0.box.height })

        var blocks: [[String]] = []
        for (i, row) in rows.enumerated() {
            if i == 0 || row.top - rows[i - 1].bottom > blockGap {
                blocks.append([])
            }
            blocks[blocks.count - 1].append(row.text)
        }
        return ReadText(blocks: blocks, skewDegrees: Double(theta) * 180 / .pi)
    }

    /// Edges the text runs into. The 16:9 LARGE photo crops the top and bottom of the camera's view
    /// (M0), so a slide that sits high or low loses lines without the wearer noticing (M1 fixture run).
    /// A recognized line within 1.5 line-heights of the top or bottom edge suggests one beyond it was cut.
    static func cutEdges(of lines: [RecognizedLine], imageHeight: CGFloat) -> Set<CutEdge> {
        guard !lines.isEmpty, imageHeight > 0 else { return [] }
        let boxes = lines.map { boundingBox(of: $0.corners, rotatedBy: 0) }
        let margin = max(0.015 * imageHeight, 1.5 * median(boxes.map { $0.height }))
        var edges: Set<CutEdge> = []
        if let top = boxes.map({ $0.minY }).min(), top < margin { edges.insert(.top) }
        if let bottom = boxes.map({ $0.maxY }).max(), bottom > imageHeight - margin { edges.insert(.bottom) }
        return edges
    }

    /// Page tilt in radians (pixel space, y down): the weighted median of
    /// - slopes of lines at least half as long as the longest, skipping exactly level quads
    ///   (Vision returns those on some tilted photos, M0), weighted by length, and
    /// - centre-to-centre slopes of side-by-side items on roughly the same row, weighted by distance.
    static func estimateSkew(_ lines: [RecognizedLine]) -> CGFloat {
        let quads = lines.compactMap { line -> (angle: CGFloat, weight: CGFloat)? in
            let dx = line.corners[1].x - line.corners[0].x
            let dy = line.corners[1].y - line.corners[0].y
            guard line.text.count >= 4, dy != 0 else { return nil }
            return (atan2(dy, dx), hypot(dx, dy))
        }
        let longest = quads.map { $0.weight }.max() ?? 0
        var samples = quads.filter { $0.weight >= 0.5 * longest }

        let boxes = lines.map { boundingBox(of: $0.corners, rotatedBy: 0) }
        for i in boxes.indices {
            for j in boxes.indices where boxes[j].minX > boxes[i].maxX {
                let (a, b) = (boxes[i], boxes[j])
                let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                guard overlap >= 0.3 * min(a.height, b.height) else { continue }
                samples.append((atan2(b.midY - a.midY, b.midX - a.midX), b.midX - a.midX))
            }
        }

        samples.sort { $0.angle < $1.angle }
        let half = samples.reduce(0) { $0 + $1.weight } / 2
        var running: CGFloat = 0
        for sample in samples {
            running += sample.weight
            if running >= half { return sample.angle }
        }
        return 0
    }

    // MARK: - Internals

    private struct Boxed {
        let text: String
        let box: CGRect
    }

    private struct Row {
        var lines: [Boxed]
        var top: CGFloat { lines.map { $0.box.minY }.min() ?? 0 }
        var bottom: CGFloat { lines.map { $0.box.maxY }.max() ?? 0 }
        var text: String {
            lines.sorted { $0.box.minX < $1.box.minX }.map { $0.text }.joined(separator: " ")
        }
    }

    /// A line joins the current row if it overlaps any line in it by at least 50% of the shorter height.
    private static func groupIntoRows(_ sortedLines: [Boxed]) -> [Row] {
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

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > 0 && overlap >= 0.5 * min(a.height, b.height)
    }

    private static func boundingBox(of corners: [CGPoint], rotatedBy theta: CGFloat) -> CGRect {
        let (c, s) = (cos(theta), sin(theta))
        let points = corners.map { CGPoint(x: $0.x * c + $0.y * s, y: -$0.x * s + $0.y * c) }
        let xs = points.map { $0.x }, ys = points.map { $0.y }
        let (minX, maxX, minY, maxY) = (xs.min() ?? 0, xs.max() ?? 0, ys.min() ?? 0, ys.max() ?? 0)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
