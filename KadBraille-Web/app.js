(() => {
  "use strict";

  const BUNDLED_FILES = [
    "12x.m4a",
    "3x + x.m4a",
    "4x + 5x.m4a",
    "4x.m4a",
    "6x.m4a",
    "8x + 4x.m4a",
    "9x.m4a",
    "x+5x.m4a"
  ];

  const AUDIO_EXTS = [".m4a", ".mp3", ".wav", ".aac", ".caf"];

  // NFC Forum RTD-URI prefix table (0x00..0x23) from ntgui.jar (k/e.class NDEFUri.java)
  const URI_PREFIX_TABLE = [
    "", "http://www.", "https://www.", "http://", "https://", "tel:", "mailto:",
    "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://", "sftp://", "smb://",
    "nfs://", "ftp://", "dav://", "news:", "telnet://", "imap:", "rtsp://", "urn:",
    "pop:", "sip:", "sips:", "tftp:", "btspp://", "btl2cap://", "btgoep://",
    "tcpobex://", "irdaobex://", "file://", "urn:epc:id:", "urn:epc:tag:",
    "urn:epc:pat:", "urn:epc:raw:", "urn:epc:", "urn:nfc:"
  ];

  // Chip configurations from ntgui.jar (l/*.class & TechHelper.java)
  const CHIP_PROFILES = {
    ntag213: { name: "NXP - NTAG213", pages: 45, ccByte: 0x12 },
    ntag215: { name: "NXP - NTAG215", pages: 135, ccByte: 0x3e },
    ntag216: { name: "NXP - NTAG216", pages: 231, ccByte: 0x6d },
    ultralight: { name: "NXP - MIFARE Ultralight", pages: 16, ccByte: 0x06 }
  };

  // MARK: - Normalization Helpers (mirrors AudioTrackItem.swift)

  function normalizeKey(raw) {
    let cleaned = String(raw || "").trim().toLowerCase();
    for (const ext of AUDIO_EXTS) {
      if (cleaned.endsWith(ext)) {
        cleaned = cleaned.slice(0, -ext.length);
        break;
      }
    }
    return cleaned.replace(/\s+/g, "");
  }

  function cleanTitleFromFileName(fileName) {
    const trimmed = String(fileName || "").trim();
    const lower = trimmed.toLowerCase();
    for (const ext of AUDIO_EXTS) {
      if (lower.endsWith(ext)) {
        return trimmed.slice(0, -ext.length);
      }
    }
    return trimmed;
  }

  function normalizeUID(uid) {
    const hexOnly = String(uid || "").toUpperCase().replace(/[^0-9A-F]/g, "");
    const pairs = [];
    for (let i = 0; i < hexOnly.length; i += 2) {
      pairs.push(hexOnly.slice(i, i + 2));
    }
    return pairs.join(":");
  }

  function deterministicUID(seedStr) {
    let hash = 2166136261;
    for (let i = 0; i < seedStr.length; i++) {
      hash ^= seedStr.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    const bytes = [
      0x04,
      (hash >>> 24) & 0xff,
      (hash >>> 16) & 0xff,
      (hash >>> 8) & 0xff,
      hash & 0xff,
      ((hash >>> 4) ^ 0x5a) & 0xff,
      ((hash >>> 12) ^ 0xa5) & 0xff
    ];
    return bytes.map((b) => b.toString(16).toUpperCase().padStart(2, "0")).join(":");
  }

  // MARK: - IndexedDB Persistence

  const DB_NAME = "KadBrailleIndexedDB";
  const DB_VERSION = 1;

  function openIDB() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains("tracks")) {
          db.createObjectStore("tracks", { keyPath: "id" });
        }
        if (!db.objectStoreNames.contains("audioBlobs")) {
          db.createObjectStore("audioBlobs");
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  async function idbGetAllTracks() {
    const db = await openIDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction("tracks", "readonly");
      const req = tx.objectStore("tracks").getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = () => reject(req.error);
    });
  }

  async function idbPutTrack(track) {
    const db = await openIDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction("tracks", "readwrite");
      tx.objectStore("tracks").put(track);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  async function idbDeleteTrack(id) {
    const db = await openIDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(["tracks", "audioBlobs"], "readwrite");
      tx.objectStore("tracks").delete(id);
      tx.objectStore("audioBlobs").delete(id);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  async function idbClearAll() {
    const db = await openIDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(["tracks", "audioBlobs"], "readwrite");
      tx.objectStore("tracks").clear();
      tx.objectStore("audioBlobs").clear();
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  async function idbPutAudioBlob(id, blob) {
    const db = await openIDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction("audioBlobs", "readwrite");
      tx.objectStore("audioBlobs").put(blob, id);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  async function idbGetAudioBlob(id) {
    const db = await openIDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction("audioBlobs", "readonly");
      const req = tx.objectStore("audioBlobs").get(id);
      req.onsuccess = () => resolve(req.result || null);
      req.onerror = () => reject(req.error);
    });
  }

  // MARK: - App State

  const state = {
    tracks: [],
    isScanning: false,
    ndefReader: null,
    audio: new Audio(),
    activeBlobUrl: null,
    currentTrack: null,
    pendingUnlockTrack: null,
    unmatchedTag: null,
    bindModalTrackId: null
  };

  // MARK: - DOM Elements

  const el = {
    toast: document.getElementById("toastBanner"),
    scanHeroBtn: document.getElementById("scanHeroBtn"),
    scanBtnTitle: document.getElementById("scanBtnTitle"),
    scanStatusText: document.getElementById("scanStatusText"),
    autoRescanToggle: document.getElementById("autoRescanToggle"),
    unmatchedCard: document.getElementById("unmatchedCard"),
    unmatchedMeta: document.getElementById("unmatchedMeta"),
    unmatchedTrackSelect: document.getElementById("unmatchedTrackSelect"),
    bindUnmatchedBtn: document.getElementById("bindUnmatchedBtn"),
    dismissUnmatchedBtn: document.getElementById("dismissUnmatchedBtn"),
    nowPlayingCard: document.getElementById("nowPlayingCard"),
    playerStateLabel: document.getElementById("playerStateLabel"),
    playerTrackTitle: document.getElementById("playerTrackTitle"),
    playerSourceBadge: document.getElementById("playerSourceBadge"),
    playerProgressFill: document.getElementById("playerProgressFill"),
    playerCurrentTime: document.getElementById("playerCurrentTime"),
    playerDuration: document.getElementById("playerDuration"),
    replayBtn: document.getElementById("replayBtn"),
    stopBtn: document.getElementById("stopBtn"),
    lastTagCard: document.getElementById("lastTagCard"),
    lastTagUID: document.getElementById("lastTagUID"),
    lastTagTech: document.getElementById("lastTagTech"),
    lastTagNDEF: document.getElementById("lastTagNDEF"),
    virtualCardDeck: document.getElementById("virtualCardDeck"),
    simulateUnknownBtn: document.getElementById("simulateUnknownBtn"),
    driveFolderInput: document.getElementById("driveFolderInput"),
    driveApiKeyInput: document.getElementById("driveApiKeyInput"),
    syncDriveBtn: document.getElementById("syncDriveBtn"),
    localAudioImport: document.getElementById("localAudioImport"),
    syncProgressWrap: document.getElementById("syncProgressWrap"),
    syncProgressFill: document.getElementById("syncProgressFill"),
    syncStatusText: document.getElementById("syncStatusText"),
    lastSyncText: document.getElementById("lastSyncText"),
    syncLogBox: document.getElementById("syncLogBox"),
    dbCountTitle: document.getElementById("dbCountTitle"),
    databaseList: document.getElementById("databaseList"),
    resetDbBtn: document.getElementById("resetDbBtn"),
    toolModeSelect: document.getElementById("toolModeSelect"),
    toolPresetWrap: document.getElementById("toolPresetWrap"),
    toolTrackSelect: document.getElementById("toolTrackSelect"),
    toolCustomWrap: document.getElementById("toolCustomWrap"),
    toolCustomInput: document.getElementById("toolCustomInput"),
    toolChipSelect: document.getElementById("toolChipSelect"),
    toolPayloadPreview: document.getElementById("toolPayloadPreview"),
    toolNdefHex: document.getElementById("toolNdefHex"),
    toolTlvHex: document.getElementById("toolTlvHex"),
    copyPayloadStringBtn: document.getElementById("copyPayloadStringBtn"),
    memoryTableTitle: document.getElementById("memoryTableTitle"),
    memoryTableBody: document.getElementById("memoryTableBody"),
    unlockOverlay: document.getElementById("unlockOverlay"),
    unlockPlayBtn: document.getElementById("unlockPlayBtn"),
    unlockCardTitle: document.getElementById("unlockCardTitle"),
    bindModal: document.getElementById("bindModal"),
    bindModalTitle: document.getElementById("bindModalTitle"),
    bindUidInput: document.getElementById("bindUidInput"),
    bindModalCancel: document.getElementById("bindModalCancel"),
    bindModalSave: document.getElementById("bindModalSave")
  };

  // MARK: - Initialization

  async function init() {
    registerServiceWorker();
    loadSavedSettings();
    setupTabs();
    setupAudioEvents();
    setupEventListeners();

    await loadOrSeedDatabase();
    renderAll();
    updateNfcToolsPreview();
    handleIncomingUrlTrigger();
  }

  function registerServiceWorker() {
    if ("serviceWorker" in navigator) {
      navigator.serviceWorker.register("./sw.js").catch(() => {});
    }
  }

  function loadSavedSettings() {
    el.driveFolderInput.value = localStorage.getItem("kadbraille_gdrive_folder") || "";
    el.driveApiKeyInput.value = localStorage.getItem("kadbraille_gdrive_apikey") || "";
    const lastSync = localStorage.getItem("kadbraille_gdrive_last_sync");
    if (lastSync) {
      el.lastSyncText.textContent = "Last synced: " + new Date(lastSync).toLocaleString();
    }
    const autoRescan = localStorage.getItem("kadbraille_auto_rescan");
    if (autoRescan !== null) {
      el.autoRescanToggle.checked = autoRescan === "true";
    }
  }

  async function loadOrSeedDatabase() {
    const existing = await idbGetAllTracks();
    if (existing.length > 0) {
      state.tracks = sortTracks(existing);
      return;
    }
    await seedBundledTracks();
  }

  async function seedBundledTracks() {
    const seeded = BUNDLED_FILES.map((fileName) => {
      const title = cleanTitleFromFileName(fileName);
      return {
        id: "bundled-" + normalizeKey(title),
        title,
        normalizedKey: normalizeKey(title),
        fileName,
        source: "Bundled",
        driveFileId: null,
        assignedUIDs: [],
        ndefAliases: [],
        updatedAt: new Date().toISOString()
      };
    });
    for (const item of seeded) {
      await idbPutTrack(item);
    }
    state.tracks = sortTracks(seeded);
  }

  function sortTracks(list) {
    return [...list].sort((a, b) => a.title.localeCompare(b.title, undefined, { numeric: true }));
  }

  // MARK: - URL Deep Link & NFC Resolution

  function buildWebCardUrl(track) {
    const base = window.location.origin + window.location.pathname;
    return `${base}?card=${encodeURIComponent(track.normalizedKey)}`;
  }

  function buildNativeCardUrl(track) {
    return `kadbraille://play?card=${encodeURIComponent(track.normalizedKey)}`;
  }

  function resolveTrack({ uid, textCandidates = [] }) {
    const normUID = normalizeUID(uid || "");
    if (normUID) {
      const uidMatch = state.tracks.find((t) =>
        (t.assignedUIDs || []).some((u) => normalizeUID(u) === normUID)
      );
      if (uidMatch) return uidMatch;
    }

    for (const raw of textCandidates) {
      const cleaned = String(raw || "").trim();
      if (!cleaned) continue;

      let candidateKey = normalizeKey(cleaned);
      // Extract ?card=... if payload is a URL
      try {
        if (cleaned.includes("://") || cleaned.includes("?")) {
          const u = new URL(cleaned, window.location.origin);
          const qCard = u.searchParams.get("card") || u.searchParams.get("key") || u.searchParams.get("play");
          if (qCard) {
            candidateKey = normalizeKey(qCard);
          } else {
            const seg = u.pathname.split("/").filter(Boolean).pop();
            if (seg && seg.toLowerCase() !== "play") {
              candidateKey = normalizeKey(decodeURIComponent(seg));
            }
          }
        }
      } catch (_) {}

      const textMatch = state.tracks.find((t) => {
        if (
          t.normalizedKey === candidateKey ||
          normalizeKey(t.title) === candidateKey ||
          normalizeKey(t.fileName) === candidateKey
        ) {
          return true;
        }
        return (t.ndefAliases || []).some((a) => normalizeKey(a) === candidateKey);
      });
      if (textMatch) return textMatch;
    }
    return null;
  }

  function handleIncomingUrlTrigger() {
    const url = new URL(window.location.href);
    const hashParams = new URLSearchParams(url.hash.replace(/^#/, ""));
    const cardParam =
      url.searchParams.get("card") ||
      url.searchParams.get("key") ||
      url.searchParams.get("play") ||
      hashParams.get("card");
    const uidParam = url.searchParams.get("uid") || hashParams.get("uid");

    if (!cardParam && !uidParam) return;

    const matched = resolveTrack({
      uid: uidParam || "",
      textCandidates: cardParam ? [cardParam] : []
    });

    if (matched) {
      showLastTagSnapshot({
        uid: uidParam || deterministicUID(matched.normalizedKey),
        tech: "iOS Background NFC / URL",
        ndefText: cardParam || matched.title
      });
      playTrackWithAutoplayFallback(matched);
    } else {
      showToast("No matching audio found for NFC link");
    }
  }

  // MARK: - Audio Playback (Offline IndexedDB Blob or Bundled Audio)

  async function getPlayableAudioSrc(track) {
    const blob = await idbGetAudioBlob(track.id);
    if (blob) {
      if (state.activeBlobUrl) URL.revokeObjectURL(state.activeBlobUrl);
      state.activeBlobUrl = URL.createObjectURL(blob);
      return state.activeBlobUrl;
    }
    return `./audio/${encodeURIComponent(track.fileName)}`;
  }

  async function playTrack(track) {
    try {
      const src = await getPlayableAudioSrc(track);
      state.audio.pause();
      state.audio.src = src;
      state.audio.currentTime = 0;
      state.currentTrack = track;

      updatePlayerUI(true);
      await state.audio.play();
      if (navigator.vibrate) navigator.vibrate(60);
      el.scanStatusText.textContent = `Playing: ${track.title}`;
    } catch (err) {
      if (err && err.name === "NotAllowedError") {
        throw err;
      }
      showToast(`Audio error: ${err?.message || "Unable to play file"}`);
    }
  }

  async function playTrackWithAutoplayFallback(track) {
    try {
      await playTrack(track);
    } catch (err) {
      if (err && err.name === "NotAllowedError") {
        state.pendingUnlockTrack = track;
        el.unlockCardTitle.textContent = `Tap to Play "${track.title}"`;
        el.unlockOverlay.classList.remove("hidden");
      }
    }
  }

  function stopAudio() {
    state.audio.pause();
    state.audio.currentTime = 0;
    updatePlayerUI(false);
  }

  function setupAudioEvents() {
    state.audio.addEventListener("timeupdate", () => {
      const dur = state.audio.duration || 0;
      const cur = state.audio.currentTime || 0;
      el.playerCurrentTime.textContent = formatTime(cur);
      el.playerDuration.textContent = formatTime(dur);
      el.playerProgressFill.style.width = dur > 0 ? `${Math.min(100, (cur / dur) * 100)}%` : "0%";
    });

    state.audio.addEventListener("loadedmetadata", () => {
      el.playerDuration.textContent = formatTime(state.audio.duration || 0);
    });

    state.audio.addEventListener("ended", () => {
      updatePlayerUI(false);
      el.playerProgressFill.style.width = "100%";
      if (el.autoRescanToggle.checked && state.isScanning) {
        el.scanStatusText.textContent = "Waiting for next NFC tag...";
      }
    });
  }

  function updatePlayerUI(isPlaying) {
    if (!state.currentTrack) {
      el.nowPlayingCard.classList.add("hidden");
      return;
    }
    el.nowPlayingCard.classList.remove("hidden");
    el.playerStateLabel.textContent = isPlaying ? "NOW PLAYING" : "LAST PLAYED";
    el.playerTrackTitle.textContent = state.currentTrack.title;
    el.playerSourceBadge.textContent = state.currentTrack.source;
    el.playerSourceBadge.className = `pill ${state.currentTrack.source === "Bundled" ? "bundled" : ""}`;
  }

  // MARK: - NFC Tag Detection (Web NFC + Simulator)

  async function toggleScanMode() {
    if (state.isScanning) {
      state.isScanning = false;
      el.scanHeroBtn.classList.remove("scanning");
      el.scanBtnTitle.textContent = "Tap to Wait for NFC Tag";
      el.scanStatusText.textContent = "Scanner paused";
      return;
    }

    state.isScanning = true;
    el.scanHeroBtn.classList.add("scanning");
    el.scanBtnTitle.textContent = "Waiting for NFC Tag...";

    if ("NDEFReader" in window) {
      try {
        if (!state.ndefReader) {
          state.ndefReader = new NDEFReader();
          state.ndefReader.onreading = (event) => {
            const uid = normalizeUID(event.serialNumber || "");
            const textCandidates = decodeWebNFCRecords(event.message?.records || []);
            processDetectedTag({
              uid,
              tech: "Web NFC (NDEF)",
              textCandidates
            });
          };
          state.ndefReader.onreadingerror = () => {
            showToast("Could not read NFC tag — try tapping again.");
          };
        }
        await state.ndefReader.scan();
        el.scanStatusText.textContent = "Hold an NFC card near your device...";
        return;
      } catch (err) {
        el.scanStatusText.textContent = `Listening (Web NFC note: ${err.message})`;
      }
    } else {
      el.scanStatusText.textContent =
        "Waiting — tap a Virtual Braille Card below (Windows) or trigger via iOS NFC / Shortcuts.";
    }
  }

  function decodeWebNFCRecords(records) {
    const out = [];
    const decoder = new TextDecoder();
    for (const record of records) {
      try {
        if (record.recordType === "text") {
          const bytes = new Uint8Array(record.data.buffer, record.data.byteOffset, record.data.byteLength);
          if (bytes.length > 0) {
            const langLen = bytes[0] & 0x3f;
            out.push(decoder.decode(bytes.slice(1 + langLen)));
          }
        } else if (record.recordType === "url") {
          out.push(decoder.decode(record.data));
        } else {
          out.push(decoder.decode(record.data));
        }
      } catch (_) {}
    }
    return out;
  }

  function processDetectedTag({ uid, tech, textCandidates }) {
    const primaryText = textCandidates.find((s) => String(s).trim().length > 0) || "";
    showLastTagSnapshot({ uid, tech, ndefText: primaryText || "(Blank)" });

    const matched = resolveTrack({ uid, textCandidates });
    if (matched) {
      state.unmatchedTag = null;
      el.unmatchedCard.classList.add("hidden");
      playTrackWithAutoplayFallback(matched);
      showToast(`Matched: ${matched.title}`);
    } else {
      if (navigator.vibrate) navigator.vibrate([40, 40, 40]);
      state.unmatchedTag = { uid, tech, ndefText: primaryText };
      el.unmatchedMeta.textContent = `UID: ${uid || "Unknown"} | NDEF: ${primaryText || "Empty"}`;
      el.unmatchedCard.classList.remove("hidden");
      el.scanStatusText.textContent = `Unrecognized tag (${uid || "No UID"})`;
    }
  }

  function showLastTagSnapshot({ uid, tech, ndefText }) {
    el.lastTagCard.classList.remove("hidden");
    el.lastTagUID.textContent = uid || "N/A";
    el.lastTagTech.textContent = tech || "Unknown";
    el.lastTagNDEF.textContent = ndefText || "—";
  }

  // MARK: - Google Drive Sync

  function extractDriveFolderID(input) {
    const trimmed = String(input || "").trim();
    if (!trimmed) return null;
    const folderMatch = trimmed.match(/\/folders\/([a-zA-Z0-9_-]+)/);
    if (folderMatch) return folderMatch[1];
    try {
      const u = new URL(trimmed);
      const id = u.searchParams.get("id");
      if (id) return id;
    } catch (_) {}
    if (/^[a-zA-Z0-9_-]{10,}$/.test(trimmed)) return trimmed;
    return null;
  }

  function appendSyncLog(line) {
    el.syncLogBox.classList.remove("hidden");
    const ts = new Date().toLocaleTimeString();
    el.syncLogBox.textContent += `[${ts}] ${line}\n`;
    el.syncLogBox.scrollTop = el.syncLogBox.scrollHeight;
  }

  async function syncFromGoogleDrive() {
    const rawInput = el.driveFolderInput.value.trim();
    const apiKey = el.driveApiKeyInput.value.trim();
    localStorage.setItem("kadbraille_gdrive_folder", rawInput);
    localStorage.setItem("kadbraille_gdrive_apikey", apiKey);

    const folderId = extractDriveFolderID(rawInput);
    if (!folderId) {
      showToast("Enter a valid public Google Drive Folder URL or ID");
      el.syncStatusText.textContent = "Invalid Google Drive folder URL/ID";
      return;
    }

    el.syncDriveBtn.disabled = true;
    el.syncProgressWrap.classList.remove("hidden");
    el.syncProgressFill.style.width = "8%";
    el.syncLogBox.textContent = "";
    el.syncStatusText.textContent = "Scanning Google Drive folder...";
    appendSyncLog(`Folder ID: ${folderId}`);

    try {
      let files = [];
      const isLocalServer =
        window.location.hostname === "localhost" ||
        window.location.hostname === "127.0.0.1" ||
        window.location.port === "8080";

      if (apiKey) {
        appendSyncLog("Querying Google Drive v3 API (CORS-enabled)...");
        const apiUrl = `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(`'${folderId}' in parents and trashed = false`)}&key=${encodeURIComponent(apiKey)}&fields=files(id,name,mimeType)&pageSize=200`;
        const resp = await fetch(apiUrl);
        if (!resp.ok) throw new Error(`Drive API HTTP ${resp.status}`);
        const json = await resp.json();
        files = json.files || [];
      } else if (isLocalServer) {
        appendSyncLog("Using local Windows server proxy for public Google Drive folder...");
        const resp = await fetch(`/api/gdrive-list?folderId=${encodeURIComponent(folderId)}`);
        if (!resp.ok) throw new Error(await resp.text());
        const json = await resp.json();
        files = json.files || [];
      } else {
        appendSyncLog("Reading public embeddedfolderview via CORS fallback...");
        const target = `https://drive.google.com/embeddedfolderview?id=${encodeURIComponent(folderId)}#list`;
        const resp = await fetch(`https://api.allorigins.win/raw?url=${encodeURIComponent(target)}`);
        if (!resp.ok) throw new Error(`Proxy HTTP ${resp.status}`);
        const html = await resp.text();
        files = parseEmbeddedDriveHtml(html);
      }

      // Check optional manifest.json
      let manifestMap = {};
      const manifestEntry = files.find((f) => f.name.toLowerCase() === "manifest.json");
      if (manifestEntry) {
        appendSyncLog("Found manifest.json — reading custom UID/title metadata...");
        const mBlob = await downloadDriveFileBlob(manifestEntry.id, apiKey, isLocalServer);
        const mJson = JSON.parse(await mBlob.text());
        const list = Array.isArray(mJson) ? mJson : (mJson.tracks || []);
        for (const item of list) {
          if (item.fileName) {
            manifestMap[normalizeKey(item.fileName)] = item;
          }
        }
      }

      const audioFiles = files.filter((f) =>
        AUDIO_EXTS.some((ext) => f.name.toLowerCase().endsWith(ext))
      );
      if (audioFiles.length === 0) {
        throw new Error("No .m4a/.mp3/.wav/.aac audio files found in that Google Drive folder.");
      }

      appendSyncLog(`Discovered ${audioFiles.length} audio file(s). Downloading offline...`);
      let count = 0;

      for (const file of audioFiles) {
        el.syncStatusText.textContent = `Downloading ${file.name} (${count + 1}/${audioFiles.length})...`;
        const blob = await downloadDriveFileBlob(file.id, apiKey, isLocalServer);
        const meta = manifestMap[normalizeKey(file.name)];
        const title = (meta && meta.title) ? meta.title : cleanTitleFromFileName(file.name);
        const key = normalizeKey(title);

        const existing = state.tracks.find(
          (t) =>
            t.driveFileId === file.id ||
            t.normalizedKey === key ||
            t.fileName.toLowerCase() === file.name.toLowerCase()
        );

        const mergedUIDs = new Set([
          ...(existing?.assignedUIDs || []),
          ...((meta?.assignedUIDs || []).map(normalizeUID).filter(Boolean))
        ]);
        const mergedAliases = new Set([
          ...(existing?.ndefAliases || []),
          ...(meta?.aliases || [])
        ]);

        const updatedTrack = {
          id: existing ? existing.id : `gdrive-${file.id}`,
          title,
          normalizedKey: key,
          fileName: file.name,
          source: "Google Drive",
          driveFileId: file.id,
          assignedUIDs: [...mergedUIDs],
          ndefAliases: [...mergedAliases],
          updatedAt: new Date().toISOString()
        };

        await idbPutAudioBlob(updatedTrack.id, blob);
        await idbPutTrack(updatedTrack);
        count++;
        el.syncProgressFill.style.width = `${15 + Math.round((85 * count) / audioFiles.length)}%`;
        appendSyncLog(`Saved offline: ${file.name} (${Math.round(blob.size / 1024)} KB)`);
      }

      state.tracks = sortTracks(await idbGetAllTracks());
      renderAll();
      updateNfcToolsPreview();

      const nowIso = new Date().toISOString();
      localStorage.setItem("kadbraille_gdrive_last_sync", nowIso);
      el.lastSyncText.textContent = "Last synced: " + new Date(nowIso).toLocaleString();
      el.syncStatusText.textContent = `Sync complete — ${count} file(s) stored offline.`;
      showToast(`Synced ${count} audio file(s) from Google Drive`);
    } catch (err) {
      el.syncStatusText.textContent = `Sync failed: ${err.message}`;
      appendSyncLog(`ERROR: ${err.message}`);
      showToast("Google Drive sync failed — check log");
    } finally {
      el.syncDriveBtn.disabled = false;
    }
  }

  function parseEmbeddedDriveHtml(html) {
    if (html.includes("ServiceLogin") || html.includes("accounts.google.com/v3/signin")) {
      throw new Error("Folder appears private. Set Drive sharing to 'Anyone with the link'.");
    }
    const entries = [];
    const seen = new Set();
    const regex = /id="entry-([a-zA-Z0-9_-]+)"[\s\S]*?class="flip-entry-title"[^>]*>([^<]+)</g;
    let match;
    while ((match = regex.exec(html)) !== null) {
      const id = match[1];
      const name = decodeHtmlEntities(match[2]).trim();
      if (id && name && !seen.has(id)) {
        seen.add(id);
        entries.push({ id, name });
      }
    }
    return entries;
  }

  async function downloadDriveFileBlob(fileId, apiKey, isLocalServer) {
    let url;
    if (apiKey) {
      url = `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?alt=media&key=${encodeURIComponent(apiKey)}`;
    } else if (isLocalServer) {
      url = `/api/gdrive-download?fileId=${encodeURIComponent(fileId)}`;
    } else {
      const direct = `https://drive.google.com/uc?export=download&id=${encodeURIComponent(fileId)}`;
      url = `https://api.allorigins.win/raw?url=${encodeURIComponent(direct)}`;
    }
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`Download HTTP ${resp.status}`);
    const blob = await resp.blob();
    const head = await blob.slice(0, 40).text();
    if (head.toLowerCase().includes("<html") || head.toLowerCase().includes("<!doctype")) {
      throw new Error("Google Drive returned HTML instead of audio. Check folder public sharing.");
    }
    return blob;
  }

  function decodeHtmlEntities(str) {
    const txt = document.createElement("textarea");
    txt.innerHTML = str;
    return txt.value;
  }

  async function importLocalFiles(fileList) {
    let imported = 0;
    for (const file of fileList) {
      const title = cleanTitleFromFileName(file.name);
      const key = normalizeKey(title);
      const existing = state.tracks.find((t) => t.normalizedKey === key);
      const track = {
        id: existing ? existing.id : `local-${Date.now()}-${Math.random().toString(16).slice(2, 6)}`,
        title,
        normalizedKey: key,
        fileName: file.name,
        source: "Local Import",
        driveFileId: null,
        assignedUIDs: existing?.assignedUIDs || [],
        ndefAliases: existing?.ndefAliases || [],
        updatedAt: new Date().toISOString()
      };
      await idbPutAudioBlob(track.id, file);
      await idbPutTrack(track);
      imported++;
    }
    if (imported > 0) {
      state.tracks = sortTracks(await idbGetAllTracks());
      renderAll();
      updateNfcToolsPreview();
      showToast(`Imported ${imported} offline audio file(s)`);
    }
  }

  // MARK: - Reverse-Engineered NDEF & Type 2 Memory Map (from ntgui.jar)

  function encodeNDEFText(text, lang = "en") {
    const enc = new TextEncoder();
    const langBytes = enc.encode(lang);
    const textBytes = enc.encode(text);
    const payload = [langBytes.length & 0x3f, ...langBytes, ...textBytes];
    return buildNDEFRecordFrame(0x01, [0x54], payload); // TNF=0x01 (Well-Known), Type='T'
  }

  function encodeNDEFUri(urlString) {
    const enc = new TextEncoder();
    let prefixCode = 0x00;
    let stripped = urlString;
    const lower = urlString.toLowerCase();

    for (let i = 1; i < URI_PREFIX_TABLE.length; i++) {
      if (lower.startsWith(URI_PREFIX_TABLE[i])) {
        prefixCode = i;
        stripped = urlString.slice(URI_PREFIX_TABLE[i].length);
        break;
      }
    }
    const suffixBytes = enc.encode(stripped);
    const payload = [prefixCode, ...suffixBytes];
    return buildNDEFRecordFrame(0x01, [0x55], payload); // TNF=0x01 (Well-Known), Type='U'
  }

  function buildNDEFRecordFrame(tnf, typeBytes, payloadBytes) {
    const len = payloadBytes.length;
    if (len <= 255) {
      // MB=1, ME=1, CF=0, SR=1, IL=0 -> 0xD0 | tnf
      return [0xd0 | (tnf & 0x07), typeBytes.length, len, ...typeBytes, ...payloadBytes];
    }
    // MB=1, ME=1, CF=0, SR=0, IL=0 -> 0xC0 | tnf
    return [
      0xc0 | (tnf & 0x07),
      typeBytes.length,
      (len >>> 24) & 0xff,
      (len >>> 16) & 0xff,
      (len >>> 8) & 0xff,
      len & 0xff,
      ...typeBytes,
      ...payloadBytes
    ];
  }

  function wrapType2TLV(ndefBytes) {
    const len = ndefBytes.length;
    if (len < 0xff) {
      return [0x03, len, ...ndefBytes, 0xfe];
    }
    return [0x03, 0xff, (len >> 8) & 0xff, len & 0xff, ...ndefBytes, 0xfe];
  }

  function buildType2MemoryPages(tlvBytes, chipKey) {
    const profile = CHIP_PROFILES[chipKey] || CHIP_PROFILES.ntag213;
    const totalPages = profile.pages;
    const pages = [];

    const fixedHeader = [
      [0x04, 0xa1, 0x2b, 0x8e], // Page 0
      [0x3c, 0x4d, 0x5e, 0x6f], // Page 1
      [0x7a, 0x48, 0x00, 0x00], // Page 2
      [0xe1, 0x10, profile.ccByte, 0x00] // Page 3 CC
    ];

    for (let p = 0; p < totalPages; p++) {
      let bytes;
      if (p < 4) {
        bytes = fixedHeader[p];
      } else if (totalPages >= 45 && p >= totalPages - 5) {
        bytes = p === totalPages - 2 ? [0xff, 0xff, 0xff, 0xff] : [0x00, 0x00, 0x00, 0x00];
      } else {
        const offset = (p - 4) * 4;
        bytes = [
          tlvBytes[offset] ?? 0x00,
          tlvBytes[offset + 1] ?? 0x00,
          tlvBytes[offset + 2] ?? 0x00,
          tlvBytes[offset + 3] ?? 0x00
        ];
      }

      const hex = bytes.map((b) => b.toString(16).toUpperCase().padStart(2, "0")).join(":");
      const ascii = bytes.map((b) => (b >= 0x20 && b <= 0x7e ? String.fromCharCode(b) : ".")).join("");

      let region = "User Memory";
      if (p === 0) region = "UID0 - UID2 / BCC0";
      else if (p === 1) region = "UID3 - UID6";
      else if (p === 2) region = "BCC1 / INT. / LOCK0 - LOCK1";
      else if (p === 3) region = "OTP0 - OTP3 (CC)";
      else if (totalPages >= 45 && p === totalPages - 5) region = "LOCK2 - LOCK4";
      else if (totalPages >= 45 && p === totalPages - 4) region = "CFG 0 (MIRROR / AUTH0)";
      else if (totalPages >= 45 && p === totalPages - 3) region = "CFG 1 (ACCESS)";
      else if (totalPages >= 45 && p === totalPages - 2) region = "PWD0 - PWD3";
      else if (totalPages >= 45 && p === totalPages - 1) region = "PACK0 - PACK1";

      pages.push({
        addr: `0x${p.toString(16).toUpperCase().padStart(2, "0")}`,
        hex,
        ascii,
        region
      });
    }
    return pages;
  }

  function updateNfcToolsPreview() {
    const mode = el.toolModeSelect.value;
    const isCustom = mode.startsWith("custom-");
    el.toolPresetWrap.classList.toggle("hidden", isCustom);
    el.toolCustomWrap.classList.toggle("hidden", !isCustom);

    const selectedTrack =
      state.tracks.find((t) => t.id === el.toolTrackSelect.value) || state.tracks[0];

    let payloadValue = "";
    let isUri = false;

    if (mode === "preset-text" && selectedTrack) {
      payloadValue = selectedTrack.title;
      isUri = false;
    } else if (mode === "preset-web" && selectedTrack) {
      payloadValue = buildWebCardUrl(selectedTrack);
      isUri = true;
    } else if (mode === "preset-native" && selectedTrack) {
      payloadValue = buildNativeCardUrl(selectedTrack);
      isUri = true;
    } else if (mode === "custom-text") {
      payloadValue = el.toolCustomInput.value || "3x + x";
      isUri = false;
    } else if (mode === "custom-uri") {
      payloadValue = el.toolCustomInput.value || "https://example.com/?card=3x%2Bx";
      isUri = true;
    }

    const ndefBytes = isUri ? encodeNDEFUri(payloadValue) : encodeNDEFText(payloadValue);
    const tlvBytes = wrapType2TLV(ndefBytes);
    const chipKey = el.toolChipSelect.value;
    const pages = buildType2MemoryPages(tlvBytes, chipKey);

    el.toolPayloadPreview.textContent = payloadValue;
    el.toolNdefHex.textContent = ndefBytes.map((b) => b.toString(16).toUpperCase().padStart(2, "0")).join(" ");
    el.toolTlvHex.textContent = tlvBytes.map((b) => b.toString(16).toUpperCase().padStart(2, "0")).join(" ");

    const lastAddr = pages[pages.length - 1]?.addr || "0x2C";
    el.memoryTableTitle.textContent = `Memory Map (Pages 0x00 – ${lastAddr}, ${pages.length} pages)`;

    el.memoryTableBody.innerHTML = "";
    for (const p of pages.slice(0, 64)) {
      const tr = document.createElement("tr");
      tr.innerHTML = `<td>${p.addr}</td><td>${p.hex}</td><td>${escapeHtml(p.ascii)}</td><td>${p.region}</td>`;
      el.memoryTableBody.appendChild(tr);
    }
  }

  // MARK: - Rendering

  function renderAll() {
    renderVirtualDeck();
    renderDatabaseList();
    renderSelectOptions();
  }

  function renderSelectOptions() {
    const prevToolId = el.toolTrackSelect.value;
    el.toolTrackSelect.innerHTML = "";
    el.unmatchedTrackSelect.innerHTML = "";

    for (const track of state.tracks) {
      const opt1 = document.createElement("option");
      opt1.value = track.id;
      opt1.textContent = `${track.title} (${track.fileName})`;
      el.toolTrackSelect.appendChild(opt1);

      const opt2 = document.createElement("option");
      opt2.value = track.id;
      opt2.textContent = track.title;
      el.unmatchedTrackSelect.appendChild(opt2);
    }

    if (prevToolId && state.tracks.some((t) => t.id === prevToolId)) {
      el.toolTrackSelect.value = prevToolId;
    }
  }

  function renderVirtualDeck() {
    el.virtualCardDeck.innerHTML = "";
    for (const track of state.tracks) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "braille-sim-card";
      const simUID = track.assignedUIDs[0] || deterministicUID(track.normalizedKey);
      btn.innerHTML = `
        <span class="braille-sim-title">${escapeHtml(track.title)}</span>
        <span class="braille-sim-meta mono">${simUID}</span>
        <span class="braille-sim-meta">${escapeHtml(track.source)}</span>
      `;
      btn.addEventListener("click", () => {
        processDetectedTag({
          uid: simUID,
          tech: "Simulated NTAG213",
          textCandidates: [track.title]
        });
      });
      el.virtualCardDeck.appendChild(btn);
    }
  }

  function renderDatabaseList() {
    el.dbCountTitle.textContent = `Internal App Database (${state.tracks.length} Tracks)`;
    el.databaseList.innerHTML = "";

    for (const track of state.tracks) {
      const row = document.createElement("div");
      row.className = "db-row";

      const header = document.createElement("div");
      header.className = "card-header-row";
      header.innerHTML = `
        <div>
          <strong>${escapeHtml(track.title)}</strong>
          <div class="muted small">${escapeHtml(track.fileName)}</div>
        </div>
        <span class="pill ${track.source === "Bundled" ? "bundled" : ""}">${escapeHtml(track.source)}</span>
      `;
      row.appendChild(header);

      const uidsWrap = document.createElement("div");
      uidsWrap.className = "uid-chips";
      if ((track.assignedUIDs || []).length > 0) {
        for (const uid of track.assignedUIDs) {
          const chip = document.createElement("span");
          chip.className = "pill uid mono";
          chip.innerHTML = `&#x1F3F7; ${escapeHtml(uid)}`;
          const rmBtn = document.createElement("button");
          rmBtn.type = "button";
          rmBtn.className = "pill-x";
          rmBtn.textContent = "×";
          rmBtn.title = "Remove UID";
          rmBtn.addEventListener("click", async () => {
            track.assignedUIDs = track.assignedUIDs.filter((u) => u !== uid);
            await idbPutTrack(track);
            renderAll();
          });
          chip.appendChild(rmBtn);
          uidsWrap.appendChild(chip);
        }
      } else {
        const note = document.createElement("span");
        note.className = "muted small";
        note.textContent = `No UIDs bound (matches via text "${track.title}")`;
        uidsWrap.appendChild(note);
      }
      row.appendChild(uidsWrap);

      const actions = document.createElement("div");
      actions.className = "row-actions";

      const playBtn = makeBtn("▶ Play", "btn btn-sm btn-secondary", () => playTrack(track));
      const bindBtn = makeBtn("Bind UID", "btn btn-sm btn-secondary", () => openBindModal(track));
      const copyWebBtn = makeBtn("Copy Web URL", "btn btn-sm btn-secondary", () =>
        copyText(buildWebCardUrl(track), `Copied Web URL for ${track.title}`)
      );
      const copyNativeBtn = makeBtn("Copy kadbraille://", "btn btn-sm btn-primary", () =>
        copyText(buildNativeCardUrl(track), `Copied kadbraille:// link for ${track.title}`)
      );

      actions.append(playBtn, bindBtn, copyWebBtn, copyNativeBtn);

      if (track.source !== "Bundled") {
        const delBtn = makeBtn("Delete", "btn btn-sm btn-danger", async () => {
          await idbDeleteTrack(track.id);
          state.tracks = sortTracks(await idbGetAllTracks());
          renderAll();
          updateNfcToolsPreview();
        });
        actions.appendChild(delBtn);
      }

      row.appendChild(actions);
      el.databaseList.appendChild(row);
    }
  }

  function makeBtn(label, className, onClick) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = className;
    b.textContent = label;
    b.addEventListener("click", onClick);
    return b;
  }

  // MARK: - Modals & Event Wiring

  function openBindModal(track) {
    state.bindModalTrackId = track.id;
    el.bindModalTitle.textContent = `Bind UID to "${track.title}"`;
    el.bindUidInput.value = "";
    el.bindModal.classList.remove("hidden");
    el.bindUidInput.focus();
  }

  async function assignUidToTrack(uidRaw, trackId) {
    const normUID = normalizeUID(uidRaw);
    if (!normUID) {
      showToast("Enter a valid hex UID (e.g. 04:A1:2B:3C:4D:5E:6F)");
      return false;
    }
    for (const t of state.tracks) {
      const beforeLen = (t.assignedUIDs || []).length;
      t.assignedUIDs = (t.assignedUIDs || []).filter((u) => normalizeUID(u) !== normUID);
      if (t.id === trackId) {
        t.assignedUIDs.push(normUID);
        await idbPutTrack(t);
      } else if (t.assignedUIDs.length !== beforeLen) {
        await idbPutTrack(t);
      }
    }
    state.tracks = sortTracks(await idbGetAllTracks());
    renderAll();
    showToast(`Bound ${normUID}`);
    return true;
  }

  function setupTabs() {
    const buttons = document.querySelectorAll(".tab-item");
    const panels = document.querySelectorAll(".tab-panel");
    buttons.forEach((btn) => {
      btn.addEventListener("click", () => {
        const target = btn.getAttribute("data-tab");
        buttons.forEach((b) => b.classList.toggle("active", b === btn));
        panels.forEach((p) => p.classList.toggle("active", p.id === `tab-${target}`));
      });
    });
  }

  function setupEventListeners() {
    el.scanHeroBtn.addEventListener("click", toggleScanMode);

    el.autoRescanToggle.addEventListener("change", () => {
      localStorage.setItem("kadbraille_auto_rescan", String(el.autoRescanToggle.checked));
    });

    el.replayBtn.addEventListener("click", () => {
      if (state.currentTrack) playTrack(state.currentTrack);
    });

    el.stopBtn.addEventListener("click", stopAudio);

    el.simulateUnknownBtn.addEventListener("click", () => {
      const randBytes = Array.from({ length: 7 }, () =>
        Math.floor(Math.random() * 256).toString(16).toUpperCase().padStart(2, "0")
      ).join(":");
      processDetectedTag({
        uid: randBytes,
        tech: "Simulated Blank NTAG213",
        textCandidates: []
      });
    });

    el.dismissUnmatchedBtn.addEventListener("click", () => {
      el.unmatchedCard.classList.add("hidden");
      state.unmatchedTag = null;
    });

    el.bindUnmatchedBtn.addEventListener("click", async () => {
      if (!state.unmatchedTag) return;
      const trackId = el.unmatchedTrackSelect.value;
      const ok = await assignUidToTrack(state.unmatchedTag.uid, trackId);
      if (ok) {
        el.unmatchedCard.classList.add("hidden");
        const track = state.tracks.find((t) => t.id === trackId);
        if (track) playTrack(track);
        state.unmatchedTag = null;
      }
    });

    el.syncDriveBtn.addEventListener("click", syncFromGoogleDrive);

    el.localAudioImport.addEventListener("change", (e) => {
      if (e.target.files?.length) {
        importLocalFiles(e.target.files);
        e.target.value = "";
      }
    });

    el.resetDbBtn.addEventListener("click", async () => {
      if (!confirm("Reset internal database to the 8 bundled UNGKAPAN ALGEBRA tracks?")) return;
      await idbClearAll();
      await seedBundledTracks();
      renderAll();
      updateNfcToolsPreview();
      showToast("Database reset to bundled defaults");
    });

    el.toolModeSelect.addEventListener("change", updateNfcToolsPreview);
    el.toolTrackSelect.addEventListener("change", updateNfcToolsPreview);
    el.toolCustomInput.addEventListener("input", updateNfcToolsPreview);
    el.toolChipSelect.addEventListener("change", updateNfcToolsPreview);
    el.copyPayloadStringBtn.addEventListener("click", () =>
      copyText(el.toolPayloadPreview.textContent || "", "Copied payload value")
    );

    el.unlockPlayBtn.addEventListener("click", async () => {
      el.unlockOverlay.classList.add("hidden");
      if (state.pendingUnlockTrack) {
        const track = state.pendingUnlockTrack;
        state.pendingUnlockTrack = null;
        await playTrack(track);
      }
    });

    el.bindModalCancel.addEventListener("click", () => {
      el.bindModal.classList.add("hidden");
      state.bindModalTrackId = null;
    });

    el.bindModalSave.addEventListener("click", async () => {
      if (!state.bindModalTrackId) return;
      const ok = await assignUidToTrack(el.bindUidInput.value, state.bindModalTrackId);
      if (ok) {
        el.bindModal.classList.add("hidden");
        state.bindModalTrackId = null;
      }
    });
  }

  // MARK: - Utilities

  function formatTime(sec) {
    if (!Number.isFinite(sec)) return "0:00";
    const s = Math.max(0, Math.floor(sec));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  }

  let toastTimer = null;
  function showToast(msg) {
    el.toast.textContent = msg;
    el.toast.classList.remove("hidden");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.toast.classList.add("hidden"), 2600);
  }

  async function copyText(text, toastMsg) {
    try {
      await navigator.clipboard.writeText(text);
      showToast(toastMsg);
    } catch (_) {
      window.prompt("Copy this value:", text);
    }
  }

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  init();
})();
