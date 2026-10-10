# CARBON

**REQUIRES iOS 26 OR NEWER.**

Look at a board, slide or screen through **Meta Ray-Ban Display** glasses, pinch once, and the text lands on your **iPhone's clipboard**. The laptop target, where text can paste itself, comes in M2. Think of it as a carbon copy of whatever is in front of you.

```
pinch SCAN (or press the camera button)
  → the glasses take a photo
  → the iPhone reads the text on-device (Apple Vision: free, offline)
  → the text goes onto the iPhone clipboard
  → the glasses show COPIED and tick
```

No internet in the scan path, no paid services, no cloud OCR.

## Status

| Milestone | State |
|---|---|
| M0: spike tests | ✅ Done ([docs/M0-REPORT.md](docs/M0-REPORT.md)) |
| M1: scan → phone clipboard | 🛠 In progress: works end to end on hardware, acceptance runs next |
| M2–M5 | Planned ([SPEC.md](SPEC.md), Section 12) |

## What you need

- iPhone on **iOS 26 or newer**.
- **Meta Ray-Ban Display** glasses with the Neural Band, Meta AI app v272+, glasses firmware v125+.
- **Developer Mode** on in the Meta AI app: Settings › App Info › tap the version number 5 times. CARBON doesn't use a Wearables Developer Center project (SPEC 11.5).
- A Mac with Xcode 26 to build. A free Apple ID works, but builds expire after 7 days.

A step-by-step "build it yourself" guide comes with M5. Until then, this repo is built with the remote workflow in [CLAUDE.md](CLAUDE.md): code is written on Windows and compiled on a lab iMac over SSH.

## Using it

1. Open CARBON on the iPhone. On first run, connect to Meta AI and allow the glasses camera.
2. Tap **START**. The glasses show MAIN with a **SCAN** button.
3. Look at the text and **pinch SCAN**, or short-press the **camera button** on the glasses.
4. About 5–6 seconds later the glasses show **COPIED**. Paste anywhere on the phone.

| On the glasses | Does |
|---|---|
| Wristband swipe | Moves the highlight between buttons |
| Pinch | Presses the highlighted button |
| Camera button, short press | Scans |
| Two-finger tap on the temple | Meta's system back: ends the display session. The phone then offers RESUME |

**Good to know**
- **Keep CARBON open on the phone while scanning.** iOS doesn't let apps write the clipboard from the background. If CARBON wasn't on screen, the glasses say **SAVED · OPEN CARBON TO COPY**, and the text is copied the moment you open CARBON. While a session runs, CARBON keeps the screen from auto-locking.
- **Folding the glasses ends the session.** Unfolding them brings CARBON back by itself in about 2 seconds.
- **Tables and fine print are hard for the fast scan.** A slower detail scan (a camera-button hold) comes in M3.
- Bullet dots aren't copied. Apple's text reader doesn't return them, so each bullet item comes out as a plain line.

## Privacy

Photos never leave the iPhone and are deleted right after reading. History is the last 20 text scans, stored on the phone. The diagnostics log records lengths and timings, never scan text.

## Repo map

| Path | What |
|---|---|
| [SPEC.md](SPEC.md) | What to build: the source of truth. Section 14 is the **decision log** |
| [CLAUDE.md](CLAUDE.md) | How to work here: machines, the remote build loop, gotchas |
| `ios/` | The iPhone app (Swift 6, SwiftUI, Meta Wearables Device Access Toolkit) |
| `tools/` | The fixture slide deck, and the OCR accuracy tool run on the Mac |
| `assets/` | Brand and app icon sources |
| `docs/` | Milestone reports |

## Credits and licenses

- Fonts: Doto, Space Mono, Space Grotesk under the SIL Open Font License (licences in `ios/Carbon/Resources/Fonts/`).
- Meta Wearables Device Access Toolkit: Meta's [Wearables Developer Terms](https://wearables.developer.meta.com/terms).
- Design language: Tactura.
