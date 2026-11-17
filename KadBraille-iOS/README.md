# Kad Braille — Native iOS Swift App

Native SwiftUI iPhone application for **Kad Braille** that waits for NFC tags on Braille Algebra cards, plays the corresponding `.m4a` audio clip offline, syncs audio updates manually from a public Google Drive folder, and provides built-in NFC read/write/memory/APDU tools reverse-engineered from `nfctools-latest/runtime/lib/ntgui.jar`.

---

## Requirements & Dependencies

* **Zero third-party packages required:** Uses Apple's built-in frameworks (`SwiftUI`, `CoreNFC`, `AVFoundation`, `UIKit`, `Foundation`). Nothing extra needs to be installed inside this folder.
* **Xcode 15+ / iOS 17.0+** on macOS to compile and deploy.
* **Physical iPhone (iPhone 7 or newer):** iOS Simulator does not have NFC hardware; `CoreNFC` requires testing on a real iPhone.

---

## Project Structure

```text
KadBraille-iOS/
├── KadBraille.xcodeproj/
│   └── project.pbxproj
└── KadBraille/
    ├── App/
    │   └── KadBrailleApp.swift          # App entry point & shared state injection
    ├── Models/
    │   ├── AudioTrackItem.swift         # Audio track model, UID mapping & normalizer
    │   └── NFCTagModels.swift           # Chip tech & memory page models (from TechHelper.java)
    ├── Services/
    │   ├── NDEFCodec.swift              # NDEF Text/URI & raw Type 2 TLV parser (from NDEFHelper.java)
    │   ├── LocalAudioDatabase.swift     # Offline JSON DB + Documents/AudioLibrary/ + UID/NDEF resolver
    │   ├── GoogleDriveSyncService.swift # Public Google Drive folder -> offline DB sync
    │   ├── AudioPlayerManager.swift     # AVAudioPlayer (.playback category) + haptic feedback
    │   └── NFCTagManager.swift          # CoreNFC session, GET_VERSION, page dump, write, erase, APDU
    ├── Views/
    │   ├── MainTabView.swift            # Root TabView & scanner/player event wiring
    │   ├── ScannerView.swift            # Accessible scan-and-play interface + unknown tag linking
    │   ├── DatabaseSyncView.swift       # Google Drive manual sync + track/UID management
    │   └── NFCToolsView.swift           # Info, Write, Memory Dump, Erase/Lock/APDU tabs
    ├── Resources/
    │   └── BundledAudio/                # Pre-bundled 8 UNGKAPAN ALGEBRA .m4a files
    ├── Info.plist                       # NFCReaderUsageDescription, ISO7816 AIDs & kadbraille:// URL scheme
    ├── KadBraille.entitlements          # Full CoreNFC NDEF + TAG capabilities (paid / university dev account)
    └── KadBraille-FreeSigning.entitlements # Empty entitlements for $0 personal Apple ID sideloading
└── .github/
    └── workflows/
        └── build-ios-ipa.yml            # Cloud macOS GitHub Action to build unsigned .ipa from Windows
```

---

## How Google Drive Online Database + Manual Sync Works

1. Put your `.m4a` (or `.mp3` / `.wav`) audio files in a Google Drive folder and set sharing to **"Anyone with the link" (Viewer)**.
2. Open the **Database & Sync** tab in the app and paste either the full Google Drive folder URL (`https://drive.google.com/drive/folders/...`) or just the Folder ID.
3. Tap **Sync Now from Google Drive**:
   * **Without an API Key:** Fetches Google Drive's public embedded folder view (`embeddedfolderview?id=...#list`), discovers audio files, and downloads each file into `Documents/AudioLibrary/`.
   * **With an Optional Google Drive v3 API Key:** Uses the official Drive REST API (`googleapis.com/drive/v3/files`) for folders with 50+ files.
   * **Preserves UID Bindings:** Updating an existing file (e.g., uploading a new `3x + x.m4a`) replaces the audio in offline storage while keeping all previously bound NFC tag UIDs intact.
4. **Optional `manifest.json`:** You can optionally place a `manifest.json` inside the Google Drive folder to attach custom titles, aliases, or pre-assigned tag UIDs:

```json
{
  "tracks": [
    {
      "title": "3x + x",
      "fileName": "3x + x.m4a",
      "assignedUIDs": ["04:A1:2B:3C:4D:5E:6F"],
      "aliases": ["card-01"]
    }
  ]
}
```

---

## How Audio Matching Works (Dual Mode)

When an NFC tag is scanned, `LocalAudioDatabase.resolveTrack(for:)` matches in this order:
1. **Hardware UID Match:** Checks if the chip's factory serial number (`04:A1:...`) is bound to a track in the internal database. Works even on completely blank/unwritten NFC cards.
2. **Normalized NDEF Payload Match:** Reads NDEF Text (`'T'`) or URI (`'U'`) records (with raw Type 2 TLV fallback) and normalizes spacing/case/extensions so `"3x + x"`, `"3x+x"`, and `"3x + x.m4a"` all match `3x + x.m4a`.

---

## Building & Installing on Your iPhone

### Option A: Free Student / Personal Apple ID ($0, Built via GitHub Actions on Windows)
Apple restricts the `CoreNFC` hardware entitlement to paid/university Apple Developer Program accounts, so this project includes a **free-signing mode** using `kadbraille://` URL deep links and iOS Shortcuts NFC Automation:
1. Push this project to a GitHub repository. The included [`.github/workflows/build-ios-ipa.yml`](.github/workflows/build-ios-ipa.yml) workflow compiles the app on GitHub's cloud macOS runner using `KadBraille-FreeSigning.entitlements` and produces `KadBraille-Unsigned.ipa`.
2. Download `KadBraille-Unsigned.ipa` from GitHub Actions Artifacts onto your Windows PC.
3. Plug your iPhone into Windows via USB and install the `.ipa` using **Sideloadly** or **AltStore** with your free Apple ID.
4. In the app's **Database & Sync** tab, tap **Copy NFC URL** on any track (e.g. `kadbraille://play?card=3x%2Bx`), then set up **Shortcuts -> Automation -> NFC -> Run Immediately -> Open URLs** on your iPhone (or write the URL with `nfctoolsgui.exe`).

### Option B: Full CoreNFC Mode (Paid or University Apple Developer Account + Xcode on macOS)
1. Copy the `KadBraille-iOS` folder to a Mac with Xcode installed.
2. Open `KadBraille-iOS/KadBraille.xcodeproj` in Xcode.
3. Select the **KadBraille** target -> **Signing & Capabilities**:
   * Choose your **Apple Developer Team** (must include *Near Field Communication Tag Reading*, e.g. via a University Developer Program team).
   * Change the **Bundle Identifier** if needed (e.g., `com.yourname.kadbraille`).
   * Confirm **Near Field Communication Tag Reading** is listed under Capabilities.
4. Connect your iPhone via USB, select it as the run destination, and press **Cmd + R** to build and run.

### Option C: Run Immediately on Windows or iPhone Safari PWA ($0)
See `../KadBraille-Web/` to open the app immediately on Windows (`Start-KadBraille-Windows.bat`) or install it onto your iPhone Home Screen via Safari.
