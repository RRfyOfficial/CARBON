// PROTOCOL.md Section 5: UTF-8 JSON with "v": 1 and a "type". Unknown types, unknown fields and
// other versions are ignored (decode returns nil).

import Foundation

nonisolated enum LinkMessage: Equatable, Sendable {
    /// Once per connection, both directions: the laptop first, the phone answers.
    case hello(proto: Int, id: String, name: String)
    /// Phone → laptop.
    case clip(id: String, ts: Int64, mode: PasteMode, text: String)
    /// Laptop → phone.
    case ack(id: String, result: AckResult, detail: String?)

    static let protocolVersion = 1

    func encoded() -> Data {
        var object: [String: Any] = ["v": 1]
        switch self {
        case let .hello(proto, id, name):
            object.merge(["type": "hello", "proto": proto, "id": id, "name": name]) { $1 }
        case let .clip(id, ts, mode, text):
            object.merge(["type": "clip", "id": id, "ts": ts, "mode": mode.rawValue, "text": text, "html": NSNull()]) { $1 }
        case let .ack(id, result, detail):
            object.merge(["type": "ack", "id": id, "result": result.rawValue, "detail": detail.map { $0 as Any } ?? NSNull()]) { $1 }
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    static func decode(_ data: Data) -> LinkMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["v"] as? NSNumber)?.intValue == 1,
              let type = object["type"] as? String else { return nil }
        switch type {
        case "hello":
            guard let proto = (object["proto"] as? NSNumber)?.intValue,
                  let id = object["id"] as? String, let name = object["name"] as? String else { return nil }
            return .hello(proto: proto, id: id, name: name)
        case "clip":
            guard let id = object["id"] as? String, let ts = (object["ts"] as? NSNumber)?.int64Value,
                  let mode = (object["mode"] as? String).flatMap(PasteMode.init(rawValue:)),
                  let text = object["text"] as? String else { return nil }
            return .clip(id: id, ts: ts, mode: mode, text: text)
        case "ack":
            guard let id = object["id"] as? String,
                  let result = (object["result"] as? String).flatMap(AckResult.init(rawValue:)) else { return nil }
            return .ack(id: id, result: result, detail: object["detail"] as? String)
        default:
            return nil
        }
    }
}

/// What the laptop did with a clip (PROTOCOL.md Section 5).
nonisolated enum AckResult: String, Sendable {
    case copied
    case pasted
    case pasteBlocked = "paste_blocked"
    case autopasteDisabled = "autopaste_disabled"
    case error
}
