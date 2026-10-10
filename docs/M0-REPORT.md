# M0 report: spike test results

> **Status: all decided except U8.** Hardware sessions on 2026-10-09 and 2026-10-10. Russell approved every proposed decision on 2026-10-10. They're recorded in the SPEC decision log and the affected SPEC sections. Wi-Fi check: Xcode offers neither Hotspot nor Access Wi-Fi Information to a free Personal Team, so photos stay on Bluetooth. **Only U8 (laptop Bluetooth peripheral) is left.** Spike code lives on the `spike/m0` branch (the "CARBON Lab" app).
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
| Bench | Capture configuration | **None passes both targets.** Russell chose fast scan LARGE/MEDIUM + detail scan LARGE/HIGH, and a p95 ≤ 8 s promise | ✅ Decided |

**Biggest risk found:** photo transfer runs over **Bluetooth at roughly 25–65 KB/s**, so photo *size* drives latency.
- MEDIUM quality is fast enough to be close to budget, but it erases thin and faint text.
- HIGH quality keeps that text but doubles the transfer time.
- The Wi-Fi path, if it can be unlocked, is the one lever that changes this.

**Reading order needs deskew.** Head tilt of 1–3° broke SPEC 8.4's ordering on wide rows and long lines. Straightening the line positions first fixed it (`tools/ocr.swift --deskew`). **Proposed SPEC 8.4 change.**

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

## Slide benchmark (2026-10-10)

**Setup**
- The 10-slide fixture deck (`tools/fixture-deck/index.html`), with ground truth generated from the same source (`ios/CarbonTests/Fixtures/slides/`).
- Shown in a browser window on a 27" monitor, captured from about desk distance with the slide filling roughly 45% of the frame width. That's comparable to a projected slide seen from a middle row.
- One capture per slide per config (10 per config), using the lab's fixture mode. The photos are kept locally in the gitignored `ios/CarbonTests/Fixtures/photos/`.
- Scored with `mac.sh ocr … --truth-dir … --deskew` (Mac Vision, SPEC 8.4 settings).
- **Scorer sanity check:** on perfect 1920×1080 screenshots of the deck, 9 of 10 slides score CER 0.0000 and the code slide 0.0052. So the ground truth matches how Vision reads, and the errors below come from the capture.

**Time from request to photo on the phone**

| Config | Median size | Median | p95 | Max |
|---|---|---|---|---|
| LARGE / MEDIUM | 153 KB | **5.5 s** | **7.0 s** | 7.0 s |
| LARGE / HIGH | 224 KB | 11.3 s | 14.2 s | 14.9 s |
| FULL / MEDIUM | 471 KB | 12.4 s | 14.0 s | 14.0 s |

Add about 0.3 s of OCR (Mac Vision measured 0.25–0.5 s per photo) plus the trigger and display overhead for the full pinch-to-result time.

**Accuracy (CER), with deskew and bullet glyphs ignored**

| Slide | What it tests | LARGE/MEDIUM | LARGE/HIGH | FULL/MEDIUM |
|---|---|---|---|---|
| 1 | Title, subtitle, meta line | 1.9% | 0.0% | 1.9% |
| 2 | Bullets | 0.0% | 0.0% | 0.0% |
| 3 | Dense small paragraph | 0.0% | 0.0% | 0.5% |
| 4 | Numbered list with sub-items | 0.0% | 2.2% | 1.1% |
| 5 | Table | **39.3%** (columns missing) | 5.3% | **28.0%** |
| 6 | Code | 15.2% | 10.0% | 8.9% |
| 7 | Numbers and symbols | 0.0% | 0.0% | 2.2% |
| 8 | Bullets + faint small caption | **29.5%** (caption lost) | 1.3% | **29.5%** |
| 9 | Footer: course code, URL, slide number | 7.7% | 18.6% | 18.6% |
| 10 | Dark theme | 0.0% | 0.0% | 0.0% |
| **Mean** | | **9.4%** | **3.7%** | **9.1%** |

**What this shows**
- **Ordinary slide text is essentially solved, even at LARGE/MEDIUM:** 0–1.9% on titles, bullets, dense paragraphs, numbered lists, numbers and dark slides, once deskew is on.
- **MEDIUM compression erases thin or faint text.** Whole table columns ("Round 2", "Change", the fractions) and the grey caption vanished at MEDIUM, at both LARGE and FULL. At HIGH they come back.
- **Tiny edge text** (the footer URL and "Slide 9 / 10") is unreliable at any setting. Clean mode (M4) drops it anyway.
- **Code** suffers from Vision's language correction: `{`→`(`, `UUID`→`UUlD`, `func log`→`fune 10g`. That's not a capture problem.
- **FULL/MEDIUM is never the better choice:** slower than LARGE/MEDIUM, and less accurate than LARGE/HIGH.

**SPEC 8.3 rule result:** no configuration has p95 ≤ 6.0 s. LARGE/MEDIUM is the closest at 7.0 s. The rule can't pick a winner, so this goes to Russell (see "Decisions needed").

### Reading order: deskew (proposed SPEC 8.4 change)

- Photos are tilted by **1.0–3.2°** (median about 1.9°), right side higher, from natural head tilt.
- SPEC 8.4 groups lines into rows by axis-aligned boxes. A tilted long line's box is taller than the text, so neighbouring lines overlap by more than 50% and merge. On the paragraph slide that interleaved lines (CER 28–50%). On the table, rows chained into columns.
- **Fix (now in `tools/ocr.swift --deskew`):**
  1. Estimate the tilt as a weighted median of (a) line slopes from Vision's corner points, counting only the longer lines and skipping exactly-level quads, and (b) centre-to-centre slopes of side-by-side items on roughly the same row.
  2. Rotate every line's quadrilateral by the tilt.
  3. Apply SPEC 8.4's grouping unchanged.
- Result: the paragraph went from 28–50% to **0%**, and the table at LARGE/HIGH from 50% to 5%.
- Vision returned **exactly level quads for every line** on the table photo, even though it was tilted. That's why the neighbour-slope evidence is needed.
- **Proposed decision:** SPEC 8.4 gains a deskew step before grouping (Reader v1, M1).

### Bullets

Vision **does not output list bullets** at all: "•" never appears in its results. The As-is formatter (SPEC 8.5) can't normalize glyphs that never arrive. **Proposed decision:**
- v1 output has no bullet glyphs.
- If bullets matter later, detect them from layout: a consistent left indent with a gap to a small mark.
- The CER scorer ignores bullet glyphs.

## Decisions (made by Russell on 2026-10-10)

**Outcome:** 1 → C (fast scan + detail scan). 2 → relax to 8 s. 3 → approved, along with the U2, U3, U5, U6 and U9 decisions. 4 → local only. D was ruled out because Xcode doesn't offer Hotspot to a free Personal Team. All of it is in the SPEC decision log. The options as they were presented:

1. **Capture configuration.** No option meets both p95 ≤ 6 s and CER ≤ 2%:
   - **A. LARGE/MEDIUM** (recommended default). About 5.5 s median, 7 s p95. Near-perfect on normal slide text. Loses thin table digits, faint captions and tiny footers.
   - **B. LARGE/HIGH.** Best accuracy (3.7%, and solid on tables and captions), but about 11 s median, 14 s p95.
   - **C. Both.** A as the normal scan, plus a "detail scan" on a different trigger (for example a camera-button hold) that uses B.
   - **D.** First check whether the **Wi-Fi path** can be unlocked (step 2 below). If photos move over Wi-Fi, HIGH or even FULL may fit the budget and the trade-off goes away.
2. **Promise.** SPEC says p95 ≤ 7 s. With A, the capture alone is about 7.0 s at p95, so the full pinch-to-paste time will be around 7.5 s. Relax the promise to ≤ 8 s, or keep 7 s as the goal and accept a miss until Wi-Fi?
3. **Deskew and bullets:** approve the two proposed SPEC changes above.
4. **Fixture photos:** keep them local-only (current state), or commit them under `ios/CarbonTests/Fixtures/`? They show the lab and the laptop screen, so re-shoot with a clean background before committing.

## Other findings

- **`datAppOnTheGlassesUpdateRequired`**: every session failed until the toolkit app *on the glasses* was updated from Meta AI. Meta AI has two devices on this account (old Ray-Ban Meta + Display). The docs warn that registration installs the glasses app on only one of them.
- **Reserved gestures** (docs): a one-finger tap pauses the session and tap-and-hold stops it, when no interactive content is showing.
- One display `send()` took about 1.2 s (the CAPTURING frame). Others completed in tens of milliseconds. Keep sends small and rare during transfers.
- Registration, the camera permission, and the `carbon://` callback all work in Developer Mode with empty `MetaAppID` / `ClientToken`.

## Remaining M0 work

1. ~~Fixtures and the real benchmark~~: done 2026-10-10 (see "Slide benchmark").
2. **At the iMac (2 min):** the Carbon target's Signing & Capabilities → + Capability. Is **Hotspot** offered to the Personal Team? This decides whether the Wi-Fi path (decision option D) is even possible.
3. **U8 (laptop only):** Bluetooth off and on, retest, then retest with other devices disconnected.
4. **Russell reads this report** and decides "Decisions needed" plus the proposed decisions (U2, U3, U5, U6, U9, deskew, bullets). They then go into the SPEC decision log.
