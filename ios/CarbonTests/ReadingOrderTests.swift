import CoreGraphics
import Foundation
import Testing
@testable import Carbon

struct ReadingOrderTests {
    /// A line whose box starts at (x, y) and is rotated by `degrees` (y down, negative = rising to the right).
    /// `levelQuad` mimics Vision returning an axis-aligned quad for a tilted line (seen in M0).
    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 25,
                      degrees: CGFloat = 0, levelQuad: Bool = false) -> RecognizedLine {
        let a = levelQuad ? 0 : degrees * .pi / 180
        let tl = CGPoint(x: x, y: y)
        let tr = CGPoint(x: x + w * cos(a), y: y + w * sin(a))
        let br = CGPoint(x: tr.x - h * sin(a), y: tr.y + h * cos(a))
        let bl = CGPoint(x: x - h * sin(a), y: y + h * cos(a))
        return RecognizedLine(text: text, corners: [tl, tr, br, bl])
    }

    @Test func levelLinesStayInOrderInOneBlock() {
        let lines = [
            line("third", x: 0, y: 80, w: 300),
            line("first", x: 0, y: 0, w: 300),
            line("second", x: 0, y: 40, w: 300),
        ]
        #expect(ReadingOrder.blocks(from: lines).blocks == [["first", "second", "third"]])
    }

    @Test func aLargeGapStartsANewBlock() {
        let lines = [
            line("title", x: 0, y: 0, w: 300),
            line("body one", x: 0, y: 100, w: 300),
            line("body two", x: 0, y: 135, w: 300),
        ]
        #expect(ReadingOrder.blocks(from: lines).blocks == [["title"], ["body one", "body two"]])
    }

    @Test func itemsOnTheSameRowJoinLeftToRight() {
        let lines = [
            line("Value", x: 400, y: 2, w: 100),
            line("Name", x: 0, y: 0, w: 100),
        ]
        #expect(ReadingOrder.blocks(from: lines).blocks == [["Name Value"]])
    }

    /// M0: long lines tilted by head roll merged into each other without deskew.
    @Test func deskewKeepsTiltedLongLinesApart() {
        let lines = (0..<3).map { i in
            line("line \(i)", x: 0, y: 200 + CGFloat(i) * 40, w: 1400, h: 30, degrees: -3)
        }
        let plain = ReadingOrder.blocks(from: lines, deskew: false).blocks.joined()
        let fixed = ReadingOrder.blocks(from: lines)
        #expect(plain.count < 3)
        #expect(fixed.blocks.joined().map { $0 } == ["line 0", "line 1", "line 2"])
        #expect(abs(fixed.skewDegrees + 3) < 0.5)
    }

    /// M0: a tilted table whose cells came back as level quads chained rows into columns.
    @Test func deskewRecoversRowsOfATiltedTableWithLevelQuads() {
        let slope = tan(-2 * CGFloat.pi / 180)
        var cells: [RecognizedLine] = []
        for row in 0..<4 {
            for col in 0..<4 {
                let x = 100 + CGFloat(col) * 250
                let y = 100 + CGFloat(row) * 37 + CGFloat(col) * 250 * slope
                cells.append(line("r\(row)c\(col)", x: x, y: y, w: 120, degrees: -2, levelQuad: true))
            }
        }
        let rows = ReadingOrder.blocks(from: cells).blocks.joined().map { $0 }
        #expect(rows == (0..<4).map { r in (0..<4).map { "r\(r)c\($0)" }.joined(separator: " ") })
    }

    @Test func fewerThanTwoCharactersIsEmpty() {
        #expect(ReadText(blocks: [["x"]]).isEmpty)
        #expect(!ReadText(blocks: [["ok"]]).isEmpty)
    }
}
