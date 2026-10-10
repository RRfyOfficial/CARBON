# CARBON link protocol, v1

The source of truth for the iPhone ↔ Windows link. SPEC Section 9 summarizes it. A change lands here first, with its test vectors, then on both sides in the same milestone (SPEC rule 9).

## 1. Roles

| Side | Role | API |
|---|---|---|
| iPhone (CARBON) | BLE **peripheral** / GATT server | `CBPeripheralManager`, background mode `bluetooth-peripheral`, restore identifier `carbon.link` |
| Windows (companion) | BLE **central** / GATT client | `BluetoothLEDevice`, `GattSession` with `MaintainConnection = true` |

Why this way round: the Zephyrus's Bluetooth can't advertise a GATT server (M0 U8, retested in M2), while every Windows Bluetooth LE adapter can be a central. The phone advertises the CARBON service whenever CARBON runs. In the background iOS hides the service UUID from non-Apple scanners, but a **bonded** laptop still reconnects on its own (M2 link spike: 7 s after a Bluetooth restart, under 2 s for a fresh start, phone locked).

## 2. GATT layout

Service `5D7FCEF4-D1AA-46A6-B187-DF5AF19C5BC5`

| Characteristic | UUID | Properties | Permission | Carries |
|---|---|---|---|---|
| `INFO` | `C34B4E97-BD2A-4254-A253-B8557272FEBE` | read | readable | Plain JSON, no secrets: `{"proto":1,"id":"<phone id>","name":"IPHONE"}`. Readable before pairing |
| `P2L` | `FA6817D4-2B2E-4AD3-ABB0-8981F0A8C674` | notify | encryption required | Frames, phone → laptop: `hello`, `clip` |
| `L2P` | `4414751E-1E20-4530-AA11-46485950207B` | write with response | encryption required | Frames, laptop → phone: `hello`, `ack` |

The phone id is a random UUID made once per CARBON install. The laptop id is a random UUID made once per companion install.

## 3. Pairing and security

Pairing is the operating systems' own Bluetooth bond. There is no CARBON-level key exchange or encryption on top.

1. CARBON is open on the phone (so its service is visible) and the wearer clicks **PAIR A PHONE** in the companion.
2. The companion scans for the CARBON service, connects, and reads `INFO`. A different `proto` stops here with a version badge (Section 7).
3. The companion calls `DeviceInformationCustomPairing.PairAsync(ConfirmPinMatch | DisplayPin | ConfirmOnly, EncryptionAndAuthentication)`. That is LE Secure Connections with numeric comparison: both devices show the same **6-digit code**.
4. The companion panel shows the code with **CONFIRM** / **REJECT**. It calls `Accept()` only on CONFIRM. The iPhone shows its own *Bluetooth Pairing Request* with the same code; the wearer taps **Pair**.
5. Bonded. The companion sets `ProtectionLevel = EncryptionRequired` on `P2L` and `L2P` (Windows only encrypts when asked), subscribes to `P2L`, and writes its `hello` to `L2P`.
6. The phone stores the laptop (id, name) as its paired computer and answers with its own `hello` on `P2L`. Both sides now show **LINKED**.

What this guarantees:

- The link is encrypted and the pairing is protected against a device in the middle (numeric comparison).
- `P2L` and `L2P` need an encrypted, bonded link, so an unpaired computer can't subscribe or write: iOS answers *Insufficient Authentication*.
- The phone sends clips only to the central whose `hello` carried its paired laptop id (`updateValue(_:for:onSubscribedCentrals:)` with that one central).
- One paired laptop per phone and one paired phone per laptop (v1).

Forgetting: the companion's **FORGET PHONE** removes the Windows bond. The phone's **FORGET COMPUTER** drops the stored laptop, but iOS apps can't remove a system bond, so both sides tell the wearer to also remove it in system settings (iPhone: *Settings → Bluetooth → the laptop → Forget This Device*). A bond left on only one side makes Windows reuse dead keys, and every connection fails with `Unreachable`.

On every reconnect the companion fetches the characteristics again (uncached), renews the `P2L` subscription, and sends `hello` again. The phone answers each `hello`.

## 4. Framing

BLE writes and notifications are small, so every message is split into frames, each with a 6-byte little-endian header:

```
offset  size  field
0       2     msgId   u16, increments per message in this direction, wraps at 65535 → 0
2       2     index   u16, 0-based frame index
4       2     count   u16, frames in this message, at least 1
6       n     chunk   n ≤ chunk size
```

- **Chunk size:** `P2L`: `central.maximumUpdateValueLength − 6`. `L2P`: `GattSession.MaxPduSize − 3 − 6`. At least 14 (the default 23-byte ATT MTU) and never more than 506 (frames stay within the 512-byte attribute limit).
- `count = ceil(length / chunk size)`, at least 1, so an empty message is one frame with an empty chunk. Every chunk but the last is exactly the chunk size.
- **Maximum message:** 65,536 bytes. A sender never builds anything larger; a receiver drops a partial message as soon as it grows past that.
- **Reassembly**, per direction and per `msgId`:
  - `index == 0` starts the message (replacing any partial one with that `msgId`) and records `count`.
  - Any other frame must carry the next expected index and the same `count`; otherwise the partial message is dropped.
  - When `index == count − 1` arrives, the message is complete and handed up.
  - `count == 0` or `index ≥ count` drops the frame. A partial message older than **5 s** is dropped.
  - Messages with different `msgId`s may interleave.
- Payloads are UTF-8 JSON (Section 5).

## 5. Messages

Every message has `"v": 1` and a `"type"`. Unknown types and unknown fields are ignored, so v1 readers survive v1.x additions.

**`hello`**, both directions, sent once per connection (laptop first, the phone answers):

```json
{ "v": 1, "type": "hello", "proto": 1, "id": "6F1C…", "name": "ZEPHYRUS-G16" }
```

**`clip`**, phone → laptop:

```json
{ "v": 1, "type": "clip", "id": "UUID", "ts": 1760030000000,
  "mode": "clipboard", "text": "Week 6: Usability Testing\n• Recruit 5 participants", "html": null }
```

`mode` is `clipboard` or `autopaste`. `ts` is Unix milliseconds. `html` stays `null` until M4.

**`ack`**, laptop → phone:

```json
{ "v": 1, "type": "ack", "id": "UUID", "result": "pasted", "detail": null }
```

| `result` | Meaning | Glasses show |
|---|---|---|
| `copied` | On the laptop clipboard | DONE · ON CLIPBOARD |
| `pasted` | On the clipboard and Ctrl+V sent | DONE · PASTED |
| `paste_blocked` | Copied, but the foreground window is elevated | `PASTE_BLOCKED` |
| `autopaste_disabled` | Copied, the local autopaste switch is off | `AUTOPASTE_OFF` |
| `error` | Couldn't set the clipboard | `NOT_DELIVERED` path |

JSON Schemas: `schema/hello.v1.json`, `schema/clip.v1.json`, `schema/ack.v1.json`.

## 6. Delivery semantics

- Target LAPTOP with no linked laptop (not subscribed, or no `hello` yet): `NOT_DELIVERED` right away.
- Otherwise the phone sends the `clip` and waits up to **2.0 s** after its last frame for the `ack`.
- `copied` / `pasted` → DONE. `paste_blocked` / `autopaste_disabled` → their screens (the text is on the laptop clipboard).
- No ack in time, or `error` → mark the scan NOT DELIVERED, put the text on the phone clipboard (right away if CARBON is open, otherwise the moment it opens: M0 U5), and show `NOT_DELIVERED`. **The scan is never lost.**
- The laptop remembers the last 50 clip ids. A repeated id is acked again with the same result but **never pasted twice**.
- The phone truncates text over 32,000 characters before sending (SPEC 6.8).

## 7. Versioning

`proto` (in `INFO` and `hello`) is the protocol version: **1**. On a mismatch the companion shows a VERSION badge and doesn't link, and the phone shows `VERSION` on the glasses and sends no clips.

## 8. Test vectors

`tools/gen_test_vectors.py` (standard-library Python) is the neutral referee. It writes `test-vectors/framing.json`, and the same JSON into `ios/CarbonTests/ProtocolVectors.swift`, so the Swift tests don't depend on files outside the app's test bundle.

- `split`: message bytes, `msgId` and chunk size → the exact frames.
- `reassemble`: a sequence of frames → the messages completed, in order.

The Swift tests and the xUnit tests must reproduce every case byte for byte.
