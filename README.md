# OpenWispr

Local-first voice dictation for macOS. Hold a hotkey, speak, and your words paste at the cursor.
100% on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper on the Apple Neural Engine).
No cloud, no account, no audio leaves your Mac.

Inspired by [Muesli](https://github.com/Muesli-HQ/muesli) — this is the dictation subset.

## Requirements

- macOS 14.0 or later, Apple Silicon
- ~1.5 GB disk for the default model (downloaded on first launch)

## Install (unsigned build)

**Fastest — one line in Terminal (no security prompt):**

```bash
curl -fsSL https://openwispr.vercel.app/install.sh | sh
```

**Or manually:**

1. Download `OpenWispr.dmg` (or unzip `OpenWispr.zip`).
2. Move it to `/Applications`.
3. First launch: macOS shows **"OpenWispr" Not Opened** (the build is not notarized). Click **Done**, open **System Settings → Privacy & Security**, scroll down to "OpenWispr was blocked", and click **Open Anyway**. Terminal alternative: `xattr -dr com.apple.quarantine /Applications/OpenWispr.app`. Later launches open normally.
4. OpenWispr lives in the menu bar (mic icon), not the Dock. Clicking the app in Applications opens its home window (stats, transcripts, settings). The setup wizard runs on first launch.

## First launch

- A short setup wizard runs: **Microphone** (with a live level meter) → **Accessibility**
  (fn trigger + auto-paste) → speech model download (`large-v3-v20240930_turbo`, ~1.5 GB once)
  → pick and press-test your hotkey → optional practice dictation.
- Menu bar status shows download/load progress if the model is still fetching.
- Without Accessibility, transcripts land on the clipboard and you paste manually.
- OpenWispr lives in the **menu bar** (mic icon), not the Dock.

## Use

- **Hold the `fn` key** (or your chosen trigger — Right ⌘, Left ⌃, or a custom shortcut), speak, then **release**. A floating pill shows a live preview while recording.
- On release OpenWispr transcribes and pastes the text where your cursor is.
- **Snippets** — say a trigger phrase and it expands. "add my email" pastes your address, "add my linkedin" your link. Use a phrase, not a bare word: "email" on its own would fire in every sentence that mentions one. An expansion pastes verbatim even with an AI rewrite style on.

## Settings (menu bar → Settings…)

- **Hotkey** — rebind the push-to-talk shortcut.
- **Model** — switch between turbo / small / base / tiny; it downloads and reloads live.
- **Auto-paste** — turn off for copy-to-clipboard only.
- **Launch at login**.

## Home window (menu bar → Open OpenWispr)

- **Snippets** — add and edit trigger phrases. Several phrases per snippet, because Whisper writes "add my linkedin" and "add my linked in". **Add my details** seeds starter rows for email, LinkedIn, X, GitHub, phone and signature; fill in the ones you want and leave the rest empty to keep them off. Where two triggers overlap the longer phrase wins, so list order does not matter.
- **Dictionary** — preferred spellings and exact phrase replacements, fuzzy-matched against what it heard.
- **Dictations**, **Insights**, **Meetings**, **Transcribe File**, **Models**, **AI**, **Apps**.

## Build from source

```bash
git clone https://github.com/SirCharan/openwispr.git
cd openwispr
./build_app.sh          # compiles + assembles build/OpenWispr.app (ad-hoc signed)
open build/OpenWispr.app
```

Headless self-checks:

```bash
./build/OpenWispr.app/Contents/MacOS/OpenWispr --selftest                 # WAV encoder
./build/OpenWispr.app/Contents/MacOS/OpenWispr --record-test 3 out.wav    # mic capture pipeline
./build/OpenWispr.app/Contents/MacOS/OpenWispr --transcribe-file out.wav  # full ASR path
```

## Notes

- First model load takes ~1–2 min (CoreML compiles for the Neural Engine once, then caches).
- Models are cached under `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`.
- **Not notarized, by choice.** Notarization needs a paid Apple Developer ID, which this project does not have, so there is no signed DMG and no Homebrew cask. The install step above (or `install.sh`, which clears the quarantine flag for you) is the supported route.
- Builds are signed with a local self-signed identity so macOS keeps your microphone and Screen Recording grants across upgrades instead of asking again each time.

## License

MIT
