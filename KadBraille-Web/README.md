# Kad Braille — Installable iPhone PWA & Windows App

Run and test **Kad Braille** directly on **Windows** today, and install it on your **iPhone Home Screen** as a free (`$0`) Progressive Web App (PWA) with offline audio storage (`IndexedDB` + Service Worker) and Google Drive sync.

---

## 1. Run Immediately on Windows

Double-click [`Start-KadBraille-Windows.bat`](Start-KadBraille-Windows.bat) (or run `.\server.ps1 -OpenBrowser` in PowerShell).

It starts a local web server at **`http://localhost:8080/`** with:
* **Scan & Play + Virtual Braille Card Deck:** Click any Algebra card (`12x`, `3x + x`, `4x + 5x`, `4x`, `6x`, `8x + 4x`, `9x`, `x+5x`) to simulate tapping that NFC card and hear the `.m4a` audio immediately.
* **Public Google Drive Sync (Zero API Key Needed Locally):** Includes a built-in local `/api/gdrive-list` and `/api/gdrive-download` proxy so you can paste any public Google Drive folder link and download new/updated `.m4a` audio files into offline `IndexedDB` storage.
* **Reverse-Engineered NFC Tools (`ntgui.jar`):** Generates exact NDEF Text (`'T'`) / URI (`'U'`) hex bytes, Type 2 TLV streams (`0x03 ... 0xFE`), and 4-byte Memory Page maps (`NTAG213`, `NTAG215`, `NTAG216`, `MIFARE Ultralight`).

---

## 2. Install on iPhone for Free ($0)

1. Host the `KadBraille-Web` folder on any free HTTPS static host (such as **GitHub Pages**, **Cloudflare Pages**, or **Netlify**).
2. Open the HTTPS URL in **Safari** on your iPhone.
3. Tap **Share -> Add to Home Screen**.
4. **Trigger Cards via iPhone NFC for $0 (No Paid Apple Developer Account Needed):**
   * **Method A — iOS Shortcuts NFC Automation (Best for Visually Impaired Users):**
     Open **Shortcuts -> Automation -> + -> NFC**, scan a Braille card, choose **Run Immediately**, and add **Open URLs** pointing to `https://your-site/?card=3x%2Bx` (copied from the **Database & Sync** tab).
   * **Method B — Write URLs with `nfctoolsgui.exe` on Windows:**
     Copy each card's **Web URL** from the **Database & Sync** tab and write it as a **URL / URI** record onto your NTAG cards using `nfctools-latest/nfctoolsgui.exe`.
