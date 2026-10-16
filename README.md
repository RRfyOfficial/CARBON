# CARBON

**REQUIRES iOS 26 OR NEWER.**

Look at a text, slide or screen through **Meta Ray-Ban Display** glasses, pinch once, and the text lands on your **iPhone's clipboard** or on your **Windows laptop**, where it can even paste itself. Just like a carbon copy of whatever is in front of you.

```
pinch SCAN (or press the camera button)
  → the glasses take a photo
  → the iPhone reads the text on-device (Apple Vision: free, offline)
  → the text goes to the target: the iPhone clipboard, or the laptop over Bluetooth
  → the glasses show COPIED and tick
```

- No internet in the scan path
- No paid services used 
- No cloud OCR.

## Requirements

- iPhone on **iOS 26 or newer**.
- **Meta Ray-Ban Display** glasses with the Neural Band, Meta AI app v272+, glasses firmware v125+.
- **Developer Mode** on in the Meta AI app: Settings › App Info › tap the version number 5 times. CARBON doesn't use a Wearables Developer Center project.
- A Mac with Xcode 26 to build. A free Apple ID works, but builds expire after 7 days.
- For the laptop target: a **Windows 10/11** PC with Bluetooth LE. The companion comes prebuilt from [Releases](https://github.com/RRfyOfficial/CARBON/releases), or you build it with the .NET 8 SDK.

## Build it yourself

About 30 minutes from a fresh clone. CARBON isn't on the App Store: you build it onto your own iPhone with your own Apple ID.

### 1. The iPhone app (on a Mac)

1. Install **Xcode 26 or newer** from the App Store and open it once. In **Xcode › Settings › Accounts**, add your Apple ID (a free one works). Select its team, click **Manage Certificates**, and add an **Apple Development** certificate if there isn't one.
2. Get the code and run the setup script:
   ```bash
   git clone https://github.com/RRfyOfficial/CARBON.git
   cd CARBON
   bash ios/scripts/setup.sh
   ```
   It checks Xcode, finds your Team ID, suggests a bundle ID, writes `ios/Config/Local.xcconfig` (gitignored: your identity never goes into the repo), and opens the project. If you have several teams, it asks which one.
3. In Xcode, wait until the **Meta Wearables** package has finished downloading (progress at the top of the window).
4. Plug in your iPhone, pick it next to the **Carbon** scheme at the top, and press **Run** (⌘R).
5. First time only, on the iPhone: turn on **Settings › Privacy & Security › Developer Mode** (the phone restarts), then trust your Apple ID in **Settings › General › VPN & Device Management**. Press Run again.

With a free Apple ID the app stops opening after **7 days**. Plug the phone in and press Run again; nothing is lost.

### 2. The glasses

1. Install **Meta AI** (v272+) and pair your Meta Ray-Ban Display glasses (firmware v125+).
2. Turn on **Developer Mode** in Meta AI: **Settings › App Info**, tap the version number 5 times. CARBON registers through Developer Mode, so you don't need a Meta developer account. Only one Developer Mode app can be registered at a time.
3. Open CARBON. Its **setup checklist** walks you through the rest: connect to Meta AI, glasses connected, glasses camera allowed, Bluetooth. Any row that isn't done says how to fix it. You can reopen the checklist later from **04 / Settings**.
4. Tap **START** and look for CARBON on the glasses.

### 3. The laptop companion (optional, Windows)

- **Prebuilt:** download `CARBON-Companion.exe` from [Releases](https://github.com/RRfyOfficial/CARBON/releases). Move it to a folder you'll keep (it starts itself at login from wherever it is), then run it. It isn't code-signed, so Windows SmartScreen warns the first time: click **More info › Run anyway**.
- **From source:** install the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0), then run `powershell -ExecutionPolicy Bypass -File windows\install.ps1`. It builds the same single `.exe`, installs it for your user (no admin), and adds it to the Start menu.

Then pair it with the phone: see **The laptop target** below.

### Troubleshooting

| Problem | Fix |
|---|---|
| The checklist says Meta AI isn't connected, or registration fails | Developer Mode is off in Meta AI (step 2.2), or another Developer Mode app is registered. Turn it on and tap CONNECT TO META AI again |
| The glasses show "update required" or nothing happens on START | With the glasses on: Meta AI › App connections, and update the toolkit app on the glasses |
| Xcode: "Failed to register bundle identifier" | That bundle ID is taken. Run `bash ios/scripts/setup.sh --bundle com.yourname.SomethingElse` |
| Xcode can't resolve the Meta Wearables package | File › Packages › Reset Package Caches, then build again |
| The laptop won't link after re-pairing | Forget the pairing on **both** sides (FORGET PHONE in the companion, and Settings › Bluetooth › your PC › Forget This Device on the phone), then pair again |
| Scans miss lines of small text | Move closer, or hold the camera button for a detail scan |

## Using it

1. Open CARBON on the iPhone. On first run, the setup checklist connects it to Meta AI and the glasses.
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
- **Tables and fine print:** hold the camera button for a **detail scan**. It takes about 11 s instead of 5-6, and reads small text the fast scan misses. Table rows occasionally come out in the wrong order; the planned Clean mode fixes that.
- Bullet dots aren't copied. Apple's text reader doesn't return them, so each bullet item comes out as a plain line.

### The laptop target (Windows)

1. **Install the companion** (see Build it yourself, step 3). It runs in the tray and launches at every login (switch that off in its panel).
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
| `ios/` | The iPhone app (Swift 6, SwiftUI, Meta Wearables Device Access Toolkit) |
| `windows/` | CARBON Companion, the Windows tray app (C#, .NET 8, WPF) and its tests |
| [protocol/](protocol/PROTOCOL.md) | The phone ↔ laptop Bluetooth protocol, and the test vectors both sides must match |
| `tools/` | The fixture slide deck, the OCR accuracy tool run on the Mac, the test-vector generator |
| `assets/` | Brand and app icon sources |
| `docs/` | Milestone reports |

## License and credits

- CARBON is released under the [MIT License](LICENSE).
- Fonts: Doto, Space Mono, Space Grotesk under the SIL Open Font License (licences in `ios/Carbon/Resources/Fonts/`).
- Meta Wearables Device Access Toolkit: Meta's [Wearables Developer Terms](https://wearables.developer.meta.com/terms).
- Design language: Tactura.
