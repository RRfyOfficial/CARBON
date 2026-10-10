# M0 report: spike test results

> **Status: in progress.** Two hardware sessions on 2026-10-09. All phone-side questions are answered. Left: U8, the Wi-Fi check, and the real-slide benchmark. Spike code lives on the `spike/m0` branch (the "CARBON Lab" app). Logs come off the phone with `mac.sh logs`.
> SPEC Section 1.4 lists the questions. Section 8.3 defines the capture benchmark.

## Summary

| ID | Question | Answer so far | Status |
|---|---|---|---|
| U1 | Display + Inputs + Photo on one session? | **Yes** | ✅ Answered |
| U2 | Works with the phone locked / app backgrounded? | **Yes.** Phone locked for 7+ min: session, display, inputs and photo stayed up. Pinch captures and camera-button events worked while locked | ✅ Answered |
| U3 | Do swipes reach the app while buttons are shown? | **No, use Model B** (on-screen buttons) | ✅ Answered |
| U4 | Does the camera button reach the app? Does it also take a system photo? | **Yes, and no.** `capture(shortPress)` arrives. With CARBON subscribed, no system photo is taken | ✅ Answered |
| U5 | Can iOS write the clipboard while CARBON is in the background? | **No.** The write is silently dropped | ✅ Answered |
| U6 | Can a display `Image` load a local file or data URI? | **`UIImage` and `data:` URIs yes, `file://` no** (`https://` also works) | ✅ Answered |
| U7 | Does app audio play through the glasses speakers? | **Yes**, over A2DP ("Meta RB Display"), mixed with other audio | ✅ Answered |
| U8 | Can the Zephyrus act as a BLE peripheral? | **Flag says yes, but GATT advertising fails** | 🟡 Partial |
| U9 | Can CARBON restart a session after the hinges reopen? | **Yes, automatically.** Lab screen back 2.1 s after the glasses reconnect, without touching the phone | ✅ Answered |
| U10 | Does the first pinch on a sleeping display deliver `select`? | **Moot.** The display never slept during a session (4+ min with no app sends) | ✅ Answered (as observed) |
| Bench | Capture configuration | **Only LARGE/MEDIUM is under 6 s** in a first, easy-scene run | 🟡 Preliminary |

**Biggest risk found:** photo transfer runs over **Bluetooth at about 30–65 KB/s**, so photo *size* drives latency.
- Full resolution takes **10–16 s**, well past the 7 s promise.
- LARGE/MEDIUM took about 3 s, but only on an easy scene. It still has to be proven on dense slides, including whether the text is accurate enough.

---

## U1: one session with Display, Inputs and Photo: **yes**

All three ran together in every session, in the order Meta's BirdSpotter sample uses:
1. Camera first. Start a low-res HEVC stream to wake the sensor. It reached `streaming` 1.6–3.1 s after start.
2. `photo.start()`. It reached `started` about 100 ms later.
3. Stop the stream, then attach Display and Inputs (each about 50 ms to `started` / `active`).

BirdSpotter warns that each photo transfer knocks the display and inputs offline. **We never saw that:** across 20+ captures, both stayed `started` / `active`. CARBON should keep a cheap recovery path anyway.

## U2: background and locked: **yes**

- The phone was locked from 23:25:41 to past 23:33. The 15-second heartbeat kept running the whole time. iOS reported unlimited background time, thanks to the Bluetooth and accessory background modes. A few heartbeats were late by up to about 17 s, which looks like timer coalescing, not a suspension.
- Two pinch captures while locked: 8.5 s and 9.3 s from trigger to result on the glasses. Camera-button events also arrived while locked.
- One locked capture took **7.1 s to the first transfer progress** (normally about 2.7 s). Watch for a lock-related wake-up delay in M1 timings.
- **Proposed decision:** no extra background mode needed (no `audio` hack). SPEC 1.4 option A is enough as configured.

## U3: swipes and display focus: **Model B**

| Setup | Neural Band swipes | Pinch | On-screen buttons |
|---|---|---|---|
| App does **not** subscribe to the band (BirdSpotter's choice) | Go to the display (the app sees nothing) | Presses the focused button (`onClick`) | **Work** |
| App subscribes to `.neuralBand` | Reach the app as `nav` events | **Lost**: no `onClick` and no `select` | Dead |
| Touchpad swipes (either setup) | Nothing reaches the app, and focus doesn't move | | |

**Proposed decision:** Model B (SPEC 1.4). Navigation uses on-screen buttons, and the display's own focus and pinch drive them. CARBON's Inputs subscription is `[.captouch, .captureButton, .actionButton]` (for the camera-button shortcut, U4), never `.neuralBand`.

**Watch out:** with the band subscribed, a **band swipe left was followed about 1.5 s later by "Session ended by device"**, twice. This looks like a system back gesture. RESUME has to handle a device-ended session.

## U5: clipboard from the background: **no**

- A capture that arrived in the background wrote `UIPasteboard.general.string`. The change counter stayed `0 → 0`, and pasting in Notes produced nothing.
- **Proposed decision:** the SPEC fallback. The phone target needs CARBON in the foreground. The laptop target is unaffected, because the laptop writes its own clipboard.

## U4: camera button: **reaches the app, no system photo**

- Each short press arrived as `capture(shortPress, captureButton)`. Inputs was subscribed to `[.captouch, .captureButton, .actionButton]`.
- With the shortcut off, presses produced **no photo**: none on our publisher, and none in Meta AI's gallery. With it on, a press ran a normal CARBON capture.
- The shortcut is safe to ship as SPEC describes. The "Camera button scans" switch in the lab resets on app restart, which explained one "it didn't work".

## U6: display images: **`UIImage`, `data:` and `https:` work, `file://` doesn't**

- A 360×140 boxed "CARBON" label, sent at `.fill`, rendered via `Image(image:)` and via a base64 `data:` URI. Via `file://` it showed nothing, and `send()` still reported success, so failure is silent.
- An `https://` favicon also rendered.
- **Proposed decision:** pre-rendered assets (SPEC 7.4) ship inside the app and are sent with `Image(image:)`. No GitHub Pages hosting, and they work offline. (`VideoPlayer` still needs HTTPS per the docs.)

## U7: audio: **plays through the glasses**

- `AVAudioSession` `.playback` + `.mixWithOthers`, a synthesized 25 ms 2 kHz tick. The route was `BluetoothA2DPOutput "Meta RB Display 0005"`, and the wearer heard it in the glasses.

## U9: auto-restart after the hinges: **yes**

- Folding: the session was "ended by device" 0.2 s after `hinge=closed`, and the link dropped 3 s later.
- Unfolding: the link went `connected`, CARBON called `createSession` + `start()` at once, and the lab screen was back **2.1 s** later, with no phone interaction. Only the device session restarts. The app, its state and the counters survive.
- The Display docs' "users must explicitly initiate a display session" was not enforced for this app-initiated restart.
- **Proposed decision:** auto-resume on reconnect. The "GLASSES BACK · TAP TO RESUME" notification fallback isn't needed.

## U10: display sleep: **didn't happen**

- With the lab screen up and no app sends, the display stayed on for 4+ minutes. The docs say it dims at 20 s and sleeps at 25 s. So the "first pinch only wakes" case never came up.
- Keep the SPEC rule "re-send the current screen on wake" anyway (it's cheap). Measure battery drain in M1, since a display that never sleeps costs power.

## U8: Zephyrus as a BLE peripheral: **partial**

Tested with a throwaway .NET 8 console program (unpackaged, like the planned companion) on Windows 11 build 26200, with the Intel Wireless Bluetooth adapter on driver 24.40.10.3.

| Test | Result |
|---|---|
| `IsPeripheralRoleSupported`, `IsLowEnergySupported`, central role | all `True` |
| Plain `BluetoothLEAdvertisementPublisher` (non-connectable) | ✅ `Started` in about 50 ms |
| `GattServiceProvider` advertising, connectable + discoverable | ❌ `Aborted` after about 28 ms (error `Success`) |
| `GattServiceProvider`, connectable only / discoverable only | ❌ stays `Created`, never starts |
| Same, with Phone Link and Cross Device services stopped | ❌ unchanged |

Microsoft describes `Aborted` as *"unable to submit the advertisement request, or canceled due to resource contention."* SimpleBLE's Windows peripheral support was validated on a USB dongle and lists adapter/driver resource limits as a known failure mode.

**Next:**
1. Switch Bluetooth off and on.
2. Retry with the other Bluetooth devices disconnected (mouse, headphones, EEG headset).
3. If it still fails, try either the same code with package identity, or a USB dongle.
4. **Fallback** (SPEC 9.1): swap the roles. iOS background advertising limits make that harder, so prove or rule out the Windows peripheral role first.

## Capture benchmark (preliminary)

**Scene:** a whiteboard with one large handwritten word, 1–2 m away, 3 runs per configuration. That's not yet the SPEC 8.3 setup (10 runs, ≥10 real slides, a middle-row seat, CER).

| Config | Pixels | Size on the wire | Request → photo on phone | ≤ 6.0 s? |
|---|---|---|---|---|
| LARGE / MEDIUM | 1920×1080 | 79–88 KB | **2.85–3.12 s** | ✅ |
| LARGE / HIGH | 1920×1080 | 174–185 KB | 6.7–7.3 s | ❌ |
| FULL / MEDIUM | 4032×3024 | 349–374 KB | 8.9–9.9 s | ❌ |
| FULL / HIGH | 4032×3024 | 1.04–1.07 MB | about 36–40 s | ❌ |

Other FULL/MEDIUM shots:
- Dense text on a laptop screen: **645 KB, 16.0 s**
- Whiteboard: 268–666 KB, 6.8–16.5 s

The time from the photo arriving to the result showing on the glasses is about 0.1–0.2 s.

**What we learned about capture:**
- **Transport is Bluetooth.** CARBON never appeared under Settings → Local Network, so the toolkit never tried Wi-Fi. Meta's CameraAccess sample carries the Hotspot Configuration and Access Wi-Fi Information entitlements. Adding them failed at provisioning: the free team's profile lacks them, and `xcodebuild` also tried another lab user's Apple ID (see CLAUDE.md gotchas). **Inconclusive.** Next, check Xcode's capability picker at the iMac.
- **Time ≈ 2.7–2.9 s to the first progress event, plus the transfer.** It's roughly proportional to bytes. Dense text compresses worse, so it costs more.
- **LARGE is a crop.** It's 16:9 and covers about 87% of FULL's width and about 65% of its height, so tall slides can lose their top and bottom.
- **Photos arrive as HEIC**, not JPEG (an ISO `ftyp` box). `UIImage(data:)` decodes them in 6–67 ms.
- `PhotoTransferProgress.totalBytes` **under-reports**: about 70% of the final size.
- **The glasses queue captures.** A client-side timeout that frees the "one in flight" slot early lets a second request through, and both photos arrive later with no request ID. Hold the slot until the photo or an SDK error arrives. The toolkit's own rule is 30 s without progress.

**LARGE/MEDIUM varies with the scene** (second session):

| Shot | Size | Trigger → result on glasses |
|---|---|---|
| Whiteboard "TEXT" | 91–94 KB | 3.0 s, 8.5 s (locked, slow start) |
| Busy scene, no text (OCR: `NO_TEXT`) | 320 KB | 10.4 s |
| Unknown scene, phone locked | 262 KB | 9.3 s |

The file size, and so the latency, depends on how much detail is in view. A dense slide is the case that matters, and it's still unmeasured.

**OCR timing:** `tools/ocr.swift` (Mac Vision, accurate, language correction) read "TEXT" from every whiteboard shot in **160–200 ms** (2.9 s for the first image only, a one-time model load). The reading step is a small part of the 7 s budget.

**Tentative choice:** LARGE/MEDIUM, if it reads real slides accurately and they stay small enough. If not, the options are a longer latency promise, LARGE/HIGH (about 7 s on an easy scene), or the Wi-Fi path.

## Other findings

- **`datAppOnTheGlassesUpdateRequired`**: every session failed until the toolkit app *on the glasses* was updated from Meta AI. Meta AI has two devices on this account (old Ray-Ban Meta + Display). The docs warn that registration installs the glasses app on only one of them.
- **Reserved gestures** (docs): a one-finger tap pauses the session and tap-and-hold stops it, when no interactive content is showing.
- One display `send()` took about 1.2 s (the CAPTURING frame). Others completed in tens of milliseconds. Keep sends small and rare during transfers.
- Registration, the camera permission, and the `carbon://` callback all work in Developer Mode with empty `MetaAppID` / `ClientToken`.

## Remaining M0 work

1. **Fixtures and the real benchmark (the big one):**
   - ≥10 slides (projector, whiteboard, monitor), photographed from a middle-row seat in a real room.
   - Typed ground truth for each slide.
   - 10 runs per config, at least LARGE/MEDIUM and LARGE/HIGH.
   - Then `mac.sh captures` + `mac.sh ocr` for CER. The tool is built and smoke-tested.
2. **At the iMac (2 min):** the Carbon target's Signing & Capabilities → + Capability. Is **Hotspot** offered to the Personal Team? This decides whether the Wi-Fi path is even possible.
3. **U8 (laptop only):** Bluetooth off and on, retest, then retest with other devices disconnected.
4. **Russell reads this report** and agrees or disagrees with the proposed decisions (U2, U3, U5, U6, U9). They then go into the SPEC decision log.
