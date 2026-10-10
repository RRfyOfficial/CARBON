# CARBON

**REQUIRES iOS 26 OR NEWER.**

Look at a board, slide or screen through **Meta Ray-Ban Display** glasses, pinch once, and the text lands on your **iPhone's clipboard** or on your **Windows laptop**, where it can even paste itself. Think of it as a carbon copy of whatever is in front of you.

```
pinch SCAN (or press the camera button)
  → the glasses take a photo
  → the iPhone reads the text on-device (Apple Vision: free, offline)
  → the text goes to the target: the iPhone clipboard, or the laptop over Bluetooth
  → the glasses show COPIED and tick
```

No internet in the scan path, no paid services, no cloud OCR.

## Status

| Milestone | State |
|---|---|
| M0: spike tests | ✅ Done 2026-10-10 ([docs/M0-REPORT.md](docs/M0-REPORT.md)) |
| M1: scan → phone clipboard | ✅ Done 2026-10-10. Body-text slides read with 0% errors; 95% of scans finish within 7.5 s |
| M2: laptop target | ✅ Done 2026-10-10. Clipboard and autopaste on Windows; autopaste 11/11 in the right window; 95% of scans within 6.7 s; nothing lost when the laptop is out of reach |
| M3: settings, history, detail scan, polish | ✅ Done 2026-10-10. Settings and history on the glasses, RESEND, and a detail scan that reads fine print (the dense slide went from 24% errors to 0%) |
| M4: Clean mode (headings, lists, tables) | Next |
| M5: public release (build it yourself) | Planned |

Details and acceptance criteria: [SPEC.md](SPEC.md), Section 12. Every decision along the way: Section 14.

## What you need

- iPhone on **iOS 26 or newer**.
- **Meta Ray-Ban Display** glasses with the Neural Band, Meta AI app v272+, glasses firmware v125+.
- **Developer Mode** on in the Meta AI app: Settings › App Info › tap the version number 5 times. CARBON doesn't use a Wearables Developer Center project (SPEC 11.5).
- A Mac with Xcode 26 to build. A free Apple ID works, but builds expire after 7 days.
- For the laptop target: a **Windows 10/11** PC with Bluetooth LE, and the .NET 8 SDK to build the companion.

A step-by-step "build it yourself" guide comes with M5. Until then, this repo is built with the remote workflow in [CLAUDE.md](CLAUDE.md): code is written on Windows and compiled on a lab iMac over SSH.

## Using it

1. Open CARBON on the iPhone. On first run, connect to Meta AI and allow the glasses camera.
2. Tap **START**. The glasses show MAIN with **SCAN**, **HISTORY** and **SETTINGS**.
3. Look at the text and **pinch SCAN**, or short-press the **camera button** on the glasses.
4. About 5–6 seconds later the glasses show **COPIED**. Paste anywhere on the phone (or see the laptop target below).
5. **HISTORY** browses your last 20 scans (OLDER / NEWER) and **RESEND**s one to the current target. **SETTINGS** switches TARGET, PASTE, LINE BREAKS and SOUND, the same settings as the phone app's 04 / Settings.

| On the glasses | Does |
|---|---|
| Wristband swipe | Moves the highlight between buttons |
| Pinch | Presses the highlighted button |
| Camera button, short press | Scans |
| Camera button, hold | **Detail scan**: slower (about 11 s), for tables and fine print |
| Two-finger tap on the temple | Meta's system back: ends the display session. The phone then offers RESUME |

**Good to know**
- **Phone target: keep CARBON open on the phone while scanning.** iOS doesn't let apps write the clipboard from the background. If CARBON wasn't on screen, the glasses say **SAVED · OPEN CARBON TO COPY**, and the text is copied the moment you open CARBON. While a session runs, CARBON keeps the screen from auto-locking.
- **Folding the glasses ends the session.** Unfolding them brings CARBON back by itself in about 2 seconds.
- **Tables and fine print:** hold the camera button for a **detail scan**. It takes about 11 s instead of 5-6, and reads small text the fast scan misses. Table rows occasionally come out in the wrong order; Clean mode (M4) fixes that.
- Bullet dots aren't copied. Apple's text reader doesn't return them, so each bullet item comes out as a plain line.

### The laptop target (Windows)

1. **Install the companion** (no admin rights needed): `powershell -ExecutionPolicy Bypass -File windows\install.ps1`. It builds one `CARBON Companion.exe`, adds it to the Start menu, starts it, and launches it at every login (switch that off in its panel).
2. **Pair once:** open CARBON on the phone, click the dotted **C** in the tray, then **PAIR A PHONE**, and tap **Pair** when the phone asks.
3. On the phone, **04 / Settings**: set **TARGET** to your laptop, and **PASTE** to **CLIPBOARD** (you press Ctrl+V) or **AUTOPASTE** (CARBON pastes into the window you last clicked).

- The phone can be locked in your pocket: the laptop link keeps working in the background, and reconnects by itself when the laptop wakes up.
- **Nothing is lost:** if the laptop doesn't confirm a scan within 2 s, the glasses say **SAVED TO PHONE** and the text goes to the phone clipboard.
- Switching TARGET takes the latest scan along: to the phone clipboard, or to the laptop as CLIPBOARD (never autopasted).
- Forgetting a pairing: **FORGET PHONE** in the companion, and on the phone **Settings › Bluetooth › your laptop › Forget This Device**.

## Privacy

Photos never leave the iPhone and are deleted right after reading. History is the last 20 text scans, stored on the phone. The laptop gets only the text, over the encrypted Bluetooth pairing, and keeps its recent list in memory. Both logs record lengths and timings, never scan text.

## Repo map

| Path | What |
|---|---|
| [SPEC.md](SPEC.md) | What to build: the source of truth. Section 14 is the **decision log** |
| [CLAUDE.md](CLAUDE.md) | How to work here: machines, the remote build loop, gotchas |
| `ios/` | The iPhone app (Swift 6, SwiftUI, Meta Wearables Device Access Toolkit) |
| `windows/` | CARBON Companion, the Windows tray app (C#, .NET 8, WPF) and its tests |
| [protocol/](protocol/PROTOCOL.md) | The phone ↔ laptop Bluetooth protocol, and the test vectors both sides must match |
| `tools/` | The fixture slide deck, the OCR accuracy tool run on the Mac, the test-vector generator |
| `assets/` | Brand and app icon sources |
| `docs/` | Milestone reports |

## Credits and licenses

- Fonts: Doto, Space Mono, Space Grotesk under the SIL Open Font License (licences in `ios/Carbon/Resources/Fonts/`).
- Meta Wearables Device Access Toolkit: Meta's [Wearables Developer Terms](https://wearables.developer.meta.com/terms).
- Design language: Tactura.
