import Foundation
import Testing
@testable import Carbon

/// protocol/test-vectors/framing.json (via ProtocolVectors.swift, from tools/gen_test_vectors.py):
/// the same cases the Windows xUnit tests run, byte for byte.
struct ProtocolVectorTests {
    private struct Vectors: Decodable {
        struct Split: Decodable {
            var name: String
            var msgId: Int
            var chunkSize: Int
            var message: String
            var frames: [String]
        }

        struct Reassemble: Decodable {
            var name: String
            var frames: [String]
            var messages: [String]
        }

        var split: [Split]
        var reassemble: [Reassemble]
    }

    private static let vectors = try! JSONDecoder().decode(Vectors.self, from: Data(ProtocolVectors.framing.utf8))

    @Test func thereAreVectors() {
        #expect(Self.vectors.split.count >= 8)
        #expect(Self.vectors.reassemble.count >= 8)
    }

    @Test(arguments: vectors.split.map(\.name))
    func splitMatches(_ name: String) throws {
        let c = try #require(Self.vectors.split.first { $0.name == name })
        let frames = Framing.split(Data(hex: c.message), msgID: UInt16(c.msgId), chunkSize: c.chunkSize)
        #expect(frames.map(\.hex) == c.frames)
    }

    @Test(arguments: vectors.reassemble.map(\.name))
    func reassemblyMatches(_ name: String) throws {
        let c = try #require(Self.vectors.reassemble.first { $0.name == name })
        var reassembler = Reassembler()
        let messages = c.frames.compactMap { reassembler.add(Data(hex: $0)) }
        #expect(messages.map(\.hex) == c.messages)
    }
}

struct LinkMessageTests {
    @Test func messagesRoundTrip() {
        let hello = LinkMessage.hello(proto: 1, id: "6F1C2D3E", name: "ZEPHYRUS-G16")
        #expect(LinkMessage.decode(hello.encoded()) == hello)
        let ack = LinkMessage.ack(id: "A", result: .pasteBlocked, detail: nil)
        #expect(LinkMessage.decode(ack.encoded()) == ack)
        let clip = LinkMessage.clip(id: "B", ts: 1_760_030_000_000, mode: .autopaste, text: "Week 6\n• Recruit · café")
        #expect(LinkMessage.decode(clip.encoded()) == clip)
    }

    @Test func theCompanionsAckDecodes() {
        let json = #"{"v":1,"type":"ack","id":"x","result":"autopaste_disabled","detail":null}"#
        #expect(LinkMessage.decode(Data(json.utf8)) == .ack(id: "x", result: .autopasteDisabled, detail: nil))
    }

    @Test(arguments: [
        #"{"v":2,"type":"ack","id":"x","result":"copied"}"#,
        #"{"v":1,"type":"ack","id":"x","result":"teleported"}"#,
        #"{"v":1,"type":"ping","ts":1}"#,
        #"not json"#,
    ])
    func anythingElseIsIgnored(_ json: String) {
        #expect(LinkMessage.decode(Data(json.utf8)) == nil)
    }

    @Test func aPartialMessageExpiresAfterFiveSeconds() {
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        var reassembler = Reassembler(now: { now })
        let frames = Framing.split(Data(count: 40), msgID: 1, chunkSize: 20)
        #expect(reassembler.add(frames[0]) == nil)
        now = now.addingTimeInterval(6)
        #expect(reassembler.add(frames[1]) == nil)
    }

    @Test func chunkSizeStaysInBounds() {
        #expect(Framing.chunkSize(payload: 10) == Framing.minChunk)
        #expect(Framing.chunkSize(payload: 185) == 179)
        #expect(Framing.chunkSize(payload: 2_000) == Framing.maxChunk)
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
