// PROTOCOL.md Section 4: every link message travels as frames with a 6-byte little-endian header
// (msgId, index, count), then a chunk. Checked against protocol/test-vectors (ProtocolVectors).

import Foundation

nonisolated enum Framing {
    static let headerSize = 6
    static let minChunk = 14
    static let maxChunk = 506
    static let maxMessage = 65_536
    static let partialTimeout: TimeInterval = 5

    /// `count = ceil(length / chunkSize)`, at least 1, so an empty message is one header-only frame.
    static func split(_ message: Data, msgID: UInt16, chunkSize: Int) -> [Data] {
        precondition(message.count <= maxMessage && (minChunk...maxChunk).contains(chunkSize))
        let bytes = [UInt8](message)
        let count = max(1, (bytes.count + chunkSize - 1) / chunkSize)
        return (0..<count).map { index in
            let start = index * chunkSize
            let end = min(start + chunkSize, bytes.count)
            var frame = Data(capacity: headerSize + max(0, end - start))
            frame.append(littleEndian: msgID)
            frame.append(littleEndian: UInt16(index))
            frame.append(littleEndian: UInt16(count))
            if start < end { frame.append(contentsOf: bytes[start..<end]) }
            return frame
        }
    }

    /// The chunk size for a payload size the link negotiated, kept inside the protocol's bounds.
    static func chunkSize(payload: Int) -> Int {
        min(max(payload - headerSize, minChunk), maxChunk)
    }
}

/// In-order reassembly per msgId. Index 0 starts a message; any other frame must be the next
/// expected one with the same count, or the partial message is dropped.
nonisolated struct Reassembler {
    private struct Partial {
        var count: UInt16
        var next: UInt16
        var started: Date
        var data: [UInt8]
    }

    private var partial: [UInt16: Partial] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Feeds one frame. Returns the message it completes, or nil.
    mutating func add(_ frame: Data) -> Data? {
        let cutoff = now().addingTimeInterval(-Framing.partialTimeout)
        partial = partial.filter { $0.value.started >= cutoff }

        let bytes = [UInt8](frame)
        guard bytes.count >= Framing.headerSize else { return nil }
        let msgID = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        let index = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        let count = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        guard count > 0, index < count else { return nil }

        var message: Partial
        if index == 0 {
            message = Partial(count: count, next: 1, started: now(), data: [])
        } else {
            guard let existing = partial[msgID], existing.count == count, existing.next == index else {
                partial[msgID] = nil
                return nil
            }
            message = existing
            message.next += 1
        }
        message.data.append(contentsOf: bytes[Framing.headerSize...])
        guard message.data.count <= Framing.maxMessage else {
            partial[msgID] = nil
            return nil
        }
        guard message.next == message.count else {
            partial[msgID] = message
            return nil
        }
        partial[msgID] = nil
        return Data(message.data)
    }

    mutating func reset() {
        partial = [:]
    }
}

private extension Data {
    nonisolated mutating func append(littleEndian value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }
}
