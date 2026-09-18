<p align="center">
  <img src="assets/imla-readme-og.jpg" alt="Imla - Speech that is free, Speech that is yours" width="900" />
</p>

<h1 align="center">Imla</h1>

<p align="center">
  <strong>Local-first dictation & meeting transcription for macOS</strong><br>
  100% on-device speech-to-text · Zero cloud costs · Privacy by default
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014.2%2B-lightgrey?logo=apple" alt="macOS 14.2+" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-optimized-green" alt="Apple Silicon" />
</p>

---

> **This is a fork.** Maintained by [Shaheen](https://github.com/xshaheen) at
> [`xshaheen/muesli`](https://github.com/xshaheen/muesli), forked from
> [`Muesli-HQ/imla`](https://github.com/Muesli-HQ/imla) and substantially changed since.
> It is not affiliated with or endorsed by the upstream project. For upstream's releases,
> support, and sponsors, go to upstream.

---

## What is Imla?

Imla is a **lightweight native macOS app** that combines **WisprFlow-style dictation** and **Granola-style meeting transcription** in one tool. Speech-to-text runs locally on Apple Silicon and audio is not sent to a transcription service. Optional hosted cleanup and meeting-note providers receive text only when you configure and use them.

<p align="center">
  <img src="assets/imla-github-ss.png" alt="Imla 0.8.4 Timeline with illustrative dictation, meeting, iPhone, and Computer Use entries" width="900" />
</p>

<p align="center"><sub>Illustrative entries and usage statistics. Personal content has been replaced.</sub></p>

### New in 0.8.4

| Feature | What you can do |
|---|---|
| **Quill** | Ask a question, rewrite selected text, or create text at the cursor with your voice. |
| **Bodhan for Indic languages** | Dictate across Indic languages and English, including code-switching. |
| **Live meeting transcripts** | Use Apple Speech on macOS 26+. Live transcription is off by default. |
| **Re-summarize meetings** | Choose a different summary model for a saved meeting. |
| **BYOK dictation** | Use OpenAI or OpenRouter when you want hosted transcription. Local by default. |

This release also adds S1-mini English cleanup, Apple Shortcuts and Siri actions, clearer macOS calendar management, and iCloud reconnection recovery. [Read the full 0.8.4 release notes](docs/release-notes/0.8.4.md).

### Dictation
Hold your hotkey (or double-tap for hands-free mode) → speak → release → transcribed text is pasted at your cursor. **~0.13 second latency** via Parakeet TDT on the Apple Neural Engine.

By default, dictation uses an on-device model. You can instead opt into OpenAI Speech-to-Text with your own API key, which streams microphone audio directly to OpenAI over a Realtime WebSocket, or connect OpenRouter and explicitly choose a transcription model. OpenRouter dictation sends the completed recording through OpenRouter to the selected upstream model. Imla retains the local recording only long enough to fall back to a compatible installed on-device model if the hosted request fails; streaming-only models are excluded from fallback.

### Quill
Select text and speak an instruction to rewrite it, or ask a question and generate text at the cursor with no selection. Choose your model in **Models → Quill**. If a required local model is missing or a selected account is signed out, Imla prompts you to download the model or sign in before use.

### Meeting Transcription
Start a meeting recording → Imla captures your mic (You) and system audio (Others) simultaneously → VAD-driven chunked transcription happens during the meeting at natural speech boundaries → speaker diarization identifies individual remote speakers (Speaker 1, Speaker 2, etc.) → when you stop, the transcript is ready in seconds, not minutes. Generate structured meeting notes via OpenAI, free OpenRouter models, your ChatGPT Plus/Pro subscription, or local Ollama models.

Live meeting transcripts have two explicit modes. **Nemotron 3.5** provides a multilingual continuous transcript and defaults to using it as the final raw transcript before diarization and note generation. You can instead select any downloaded meeting model as the authoritative final transcript while keeping Nemotron for live preview. **Parakeet Realtime EOU** is a low-latency English preview paired with a separately selected final model. Settings always shows which model owns the final transcript.

Live transcription is off by default. Choose Apple Speech, or download Parakeet Realtime EOU or Nemotron 3.5, from Models and then select one under **Settings → Meetings → Transcription**. The waveform-hover preview can be enabled separately from the same section. Making a live model available does not activate it automatically.

---

## Features

- **Native macOS architecture** — Swift, AppKit, and SwiftUI app code with in-process CoreML/ANE, Metal, and LiteRT-LM inference.
- **Multiple ASR providers** — Apple Speech (system-managed on macOS 26+), Parakeet TDT and Nemotron 3.5 (Neural Engine), Cohere Transcribe 2B (mixed precision CoreML), multilingual Whisper Tiny/Small/Large Turbo (CoreML/ANE via WhisperKit), Qwen3 ASR, SenseVoice Small, Bodhan Core/Flex for Indic and English speech, and experimental Gemma 4 E2B.
- **Hold-to-talk & hands-free** — Hold hotkey for quick dictation, or double-tap for sustained recording.
- **Quill voice writing and answers** — Highlight text to rewrite it from a spoken instruction, or generate new text at the cursor with no selection. Quill supports local and hosted models, hands-free activation, and an independent toggle for its activation and release sounds.
- **Apple Shortcuts & Siri** — Six preconfigured actions out of the box: Start/Stop Dictation (latched hands-free mode, same as double-tapping the hotkey), Start/Stop Meeting Recording, Get Last Dictation, and Get Last Meeting Notes. Trigger them from Spotlight, Siri ("Start a meeting recording in Imla"), keyboard shortcuts, or Shortcuts automations — e.g. auto-record when a calendar event starts, or pipe your last dictation into Notes, Messages, or Files.
- **Meeting recording** — Captures mic + system audio (including Bluetooth/AirPods) with a CoreAudio process tap by default and ScreenCaptureKit fallback. System audio from Zoom, Teams, and other call clients stays on the Others side of the transcript.
- **Live meeting transcript** — Choose Nemotron 3.5 for multilingual live text with either Nemotron or a separate downloaded final model, or Parakeet Realtime EOU for an English live preview.
- **VAD-driven chunk rotation** — Silero VAD detects natural speech boundaries in real-time, splitting mic audio at pauses instead of fixed intervals. No mid-sentence cuts.
- **Speaker diarization** — Identifies individual speakers in system audio (Speaker 1, Speaker 2, etc.) using FluidAudio's pyannote-based CoreML diarization model.
- **Camera-based meeting detection** — Detects when your webcam + mic activate in a recognized meeting app (Zoom, Chrome, Teams, FaceTime, Slack, WhatsApp). Camera alone (e.g. Photo Booth) won't trigger false positives.
- **Join & Transcribe** — Extracts meeting URLs from calendar events (Zoom, Google Meet, Teams, Webex, Chime, FaceTime). Split-button notification: "Join & Transcribe" opens the meeting + starts transcription, "Join Only" opens without transcribing, "Transcribe Only" starts transcription without joining. Platform icons (Zoom, Meet) in the notification panel.
- **macOS Calendar integration** — See upcoming meetings from calendars connected to your Mac, including iCloud, Google, and Exchange, in the Coming Up section and status bar. Choose whether Imla watches today, two days, or three days of upcoming events. Event-driven notifications via `EKEventStoreChangedNotification` for instant calendar change detection. Pre-meeting countdowns via Marauder's Map easter egg.
- **Import Audio** — Import m4a, mp4, wav, or mp3 files for offline transcription, speaker diarization, title generation, summaries, and saved meeting history.
- **Meeting export** — Export meeting notes or transcripts as PDF (paginated US Letter) or Markdown. Format picker in the save panel, auto-opens the exported file.
- **Meeting templates** — Built-in and custom templates for meeting notes. Choose a template before or after recording — re-summarize any meeting with a different template.
- **Dismiss calendar events** — Hide irrelevant events from Coming Up, status bar, and menu bar. Dismissed events are pruned automatically.
- **iCloud Text Sync & iPhone Bridge** — Privately sync dictation text, meeting transcripts, notes, summaries, and manual notes with Muesli for iPhone through iCloud. Audio recordings are never synced.
- **Writing Styles** — Opt in to editable app groups with exact or full-value wildcard bundle-ID and hostname matchers, plus exact target exceptions and a global fallback. Matching is deterministic and local; versioned JSON import/export moves only styles, groups, matchers, exceptions, and the global default. Style rules and local history provenance do not sync to iCloud.
- **Local or hosted AI cleanup** — Keep cleanup on-device with Qwen/Gemma, or configure a hosted provider. Hosted cleanup receives transcript text plus the selected style instructions; separately enabled App Context is included only when that feature is on.
- **Optional transcript cleanup** — Refine dictated text locally with **[S1-mini by Superwhisper](https://huggingface.co/superwhisper/s1-mini-GGUF)**, Imla's GGUF cleanup models, or on-device Gemma 4 E2B; hosted providers are also available when preferred.
- **Filler word removal** — Automatically strips "uh", "um", "er", "hmm" and verbal disfluencies.
- **AI meeting notes** — BYOK with OpenAI or OpenRouter, sign in with your ChatGPT Plus/Pro subscription (no API key needed), or use local Ollama models. Auto-generated meeting titles. Re-summarize any saved meeting with a different summary model.
- **ChatGPT OAuth** — Sign in with your existing ChatGPT subscription via browser-based OAuth (PKCE). Tokens stored in the app support directory with owner-only file permissions.
- **Computer Use planner** — Optional voice-driven planner that can execute local app and browser actions from dictated commands with configurable model and timeout settings.
- **Post-meeting hooks** — Run a user-supplied executable after completed meetings. Hooks receive a JSON payload on stdin and log results in the app support directory.
- **Personal dictionary** — Add custom words, phrase matches, and replacement pairs. Jaro-Winkler fuzzy matching auto-corrects transcription output.
- **Model management** — Download, delete, and switch between models from the Models tab. Background downloads that don't block the app.
- **Configurable hotkeys** — Choose any modifier key (Cmd, Option, Ctrl, Fn, Shift) for dictation.
- **Onboarding** — First-launch wizard with model selection, real OS permission verification, hotkey configuration, smoother Accessibility handoff, live dictation test to verify the full pipeline works, and optional summary setup for ChatGPT, OpenAI, OpenRouter, or Ollama. Progress saved on every step — survives crashes and manual quits.
- **Launch at Login** — Start Imla automatically with macOS login items, with approval-state refresh in Settings.
- **Dark & light mode** — Adaptive theme with toggle in sidebar.
- **SwiftUI dashboard** — Dictation history, meeting notes (Notes-style split view), meeting folders, dictionary, models, shortcuts, settings, about page.
- **Floating indicator** — Frosted glass pill with dynamic waveform, accent color customization, and click-to-stop for meetings.

---

## Install

This fork ships no prebuilt binaries: notarization needs a Developer ID Application
certificate it does not have, and the Homebrew cask named `imla` belongs to upstream.
Build from source.

**Requirements:** macOS 14.2+, Xcode 16+, Apple Silicon

```bash
git clone https://github.com/xshaheen/muesli.git
cd imla

make build                       # signed with your own identity, installs to /Applications
MUESLI_SKIP_SIGN=1 make dev      # isolated ImlaDev.app, separate bundle ID and data
```

`make help` lists every target. Builds signed with anything other than a Developer ID
certificate are not notarized — fine on your own machine, but Gatekeeper warns elsewhere,
and iCloud sync is off because those entitlements need a provisioning profile.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the full local development workflow.

The selected transcription model downloads on demand (~565 MB for the default English Parakeet Unified; ~450 MB for multilingual Parakeet v3).
The app bundle also includes the arm64 LiteRT-LM runtime (~61 MB) for experimental
Gemma 4 support; its ~2.6 GB model weights download only when Gemma is selected.

---

## Agent CLI

Imla bundles an agent-friendly local CLI inside the app bundle:

- Installed path: `/Applications/Imla.app/Contents/MacOS/imla-cli`
- Dev path: `native/ImlaNative/.build/arm64-apple-macosx/debug/imla-cli`
- Future Homebrew alias: `imla` once the official cask exposes the bundled binary as a command

The CLI is designed for coding agents such as Codex and Claude Code. It exposes meetings, dictations, raw transcripts, stored notes, and local audio-file transcription. Existing data commands return stable JSON so an agent can analyze them with its own model and write notes back without requiring a user-supplied OpenAI or OpenRouter key. `transcribe` prints plain transcript text by default so it works naturally in shell pipelines.

### What agents should do

1. Discover the CLI:
   ```bash
   command -v imla-cli || echo "/Applications/Imla.app/Contents/MacOS/imla-cli"
   ```
2. Inspect the command contract:
   ```bash
   /Applications/Imla.app/Contents/MacOS/imla-cli spec
   ```
3. Transcribe a local audio file:
   ```bash
   /Applications/Imla.app/Contents/MacOS/imla-cli transcribe file.mp3
   ```
   Homebrew users should eventually be able to use:
   ```bash
   imla transcribe file.mp3
   ```
4. List recent meetings or dictations:
   ```bash
   /Applications/Imla.app/Contents/MacOS/imla-cli meetings list --limit 10
   /Applications/Imla.app/Contents/MacOS/imla-cli dictations list --limit 10
   ```
5. Fetch a full record:
   ```bash
   /Applications/Imla.app/Contents/MacOS/imla-cli meetings get 125
   /Applications/Imla.app/Contents/MacOS/imla-cli dictations get 42
   ```
6. Summarize or analyze locally in the agent.
7. Write improved meeting notes back:
   ```bash
   cat notes.md | /Applications/Imla.app/Contents/MacOS/imla-cli meetings update-notes 125 --stdin
   ```

### Commands

- `imla-cli spec`
- `imla-cli info`
- `imla-cli transcribe <file> [--format text|json|markdown] [--model parakeet-v3|parakeet-v2|parakeet-eou-320ms|sensevoice|qwen3-asr|nemotron35|whisper-tiny|whisper-tiny-english|whisper-small|whisper-small-english|whisper-medium-english|whisper-large-turbo] [--dictionary PATH] [--summarize] [--save-meeting] [--title TITLE] [--output PATH]`
- `imla-cli meetings list [--limit N] [--folder-id ID]`
- `imla-cli meetings get <id>`
- `imla-cli meetings update-notes <id> (--stdin | --file <path>)`
- `imla-cli dictations list [--limit N]`
- `imla-cli dictations get <id>`

### Audio transcription

Supported input files: `.mp3`, `.mp4`, `.m4a`, and `.wav`.

Default output is transcript text only:

```bash
imla-cli transcribe interview.mp3
```

Agent-friendly JSON output uses the normal CLI envelope:

```bash
imla-cli transcribe interview.m4a --format json
```

```json
{
  "ok": true,
  "command": "imla-cli transcribe",
  "data": {
    "transcript": "Raw transcript text...",
    "summary": null,
    "durationSeconds": 123.4,
    "wordCount": 420,
    "model": "parakeet-v3",
    "warnings": [],
    "savedMeetingID": null,
    "title": "interview"
  },
  "meta": {
    "schemaVersion": 1,
    "generatedAt": "2026-07-08T00:00:00Z",
    "dbPath": "/Users/example/Library/Application Support/Imla/imla.db",
    "warnings": []
  }
}
```

Generate markdown notes with the configured API/local summary backend when available:

```bash
imla-cli transcribe interview.mp4 --summarize --format markdown --output notes.md
```

`--summarize` uses configured OpenAI, OpenRouter, Ollama, LM Studio, or Custom LLM settings. If the configured backend is unavailable in headless CLI mode, Imla keeps the transcript and reports a warning instead of discarding the transcription.

Save the import into Imla as `source = audio_import`:

```bash
imla-cli transcribe interview.wav --save-meeting --title "Customer Interview"
```

### Dictionary import and export

The app's **Dictionary** tab supports importing and exporting the personal dictionary as JSON. Import merges entries by match word, updates an existing match when the imported definition differs, and appends new words. Export produces the same portable format accepted by `imla-cli --dictionary`:

```json
[
  {
    "word": "museli",
    "replacement": "imla",
    "matching_threshold": 0.85
  }
]
```

The CLI also accepts an app `config.json` directly when it contains a `custom_words` array:

```bash
imla-cli transcribe interview.wav --dictionary ~/Library/Application\ Support/Imla/config.json
```

`parakeet-eou-320ms` is available for batch file transcription. The CLI chunks the audio internally and returns the completed transcript; it does not expose streaming partials for file transcription.

Direct app-bundle fallback path:

```bash
/Applications/Imla.app/Contents/MacOS/imla-cli transcribe file.mp3
```

### JSON contract

Data commands return JSON on stdout. `transcribe` returns plain text by default; pass `--format json` to use the envelope below.

Success shape:

```json
{
  "ok": true,
  "command": "imla-cli meetings get",
  "data": {},
  "meta": {
    "schemaVersion": 1,
    "generatedAt": "2026-03-17T00:00:00Z",
    "dbPath": "/Users/example/Library/Application Support/Imla/imla.db",
    "warnings": []
  }
}
```

Failure shape:

```json
{
  "ok": false,
  "command": "imla-cli meetings get 999",
  "error": {
    "code": "not_found",
    "message": "No meeting exists with id 999.",
    "fix": "Run `imla-cli meetings list` to find a valid ID."
  },
  "meta": {
    "schemaVersion": 1,
    "generatedAt": "2026-03-17T00:00:00Z",
    "dbPath": "",
    "warnings": []
  }
}
```

Important meeting fields:

- `rawTranscript`
- `formattedNotes`
- `notesState`
- `calendarEventID`
- `micAudioPath`
- `systemAudioPath`

`notesState` values:

- `missing`
- `raw_transcript_fallback`
- `structured_notes`

### Notes for agent authors

- The CLI is JSON-first and intended to be machine-consumed.
- `transcribe` is text-first by default; use `--format json` for structured agent workflows.
- `formattedNotes` is the only write-back surface in v1.
- `rawTranscript` is read-only and should be treated as source material.
- If `notesState` is `missing` or `raw_transcript_fallback`, agents should prefer summarizing from `rawTranscript`.
- Use `--db-path` or `--support-dir` only when the default Imla data location is wrong.
- Read the [SQLite database guide](database-schema.md) before adding tables,
  columns, migrations, direct queries, or new sync fields.

---

## Models

| Model | Backend | Runtime | Size | Languages | Latency |
|-------|---------|---------|------|-----------|---------|
| **Apple Speech** | SpeechAnalyzer / SpeechTranscriber | System-managed | No Imla model download | System-supported locales | Dictation, live + final meetings on macOS 26+ |
| **Parakeet Unified** (default for English) | FluidAudio | CoreML / Neural Engine | ~565 MB | English | Offline batch |
| **Parakeet v3** (multilingual) | FluidAudio | CoreML / Neural Engine | ~450 MB | 25 languages | ~0.13s |
| Parakeet v2 | FluidAudio | CoreML / Neural Engine | ~450 MB | English only | ~0.13s |
| Parakeet Realtime EOU | FluidAudio | CoreML / Neural Engine | ~430 MB | English only | Live preview |
| **Cohere Transcribe 2B** | CoreML | FP16 encoder + INT8 decoder | ~3.8 GB | 14 languages | ~1s |
| Nemotron 3.5 Multilingual | FluidInference | CoreML / Neural Engine | ~665 MB | 100+ locales | Live; optional final |
| SenseVoice Small | FluidAudio | INT8 CoreML / Neural Engine | ~240 MB | 50+ languages | ~1s |
| Qwen3 ASR | FluidAudio | CoreML / Neural Engine | ~1.3 GB | 52 languages | ~2-3s |
| Bodhan Core | CoreML + MLX | CoreML encoder + autoregressive decoder | ~2.46 GB FP16 / ~1.27 GB INT8 weights | 25 languages, including English; auto-detect | Final transcription |
| Bodhan Flex | CoreML + MLX | CoreML encoder + autoregressive decoder | ~2.46 GB FP16 / ~1.27 GB INT8 weights | 27 languages, including English; auto-detect | Final transcription |
| Gemma 4 E2B | LiteRT-LM | Metal GPU decoder + CPU audio encoder | ~2.6 GB | Multilingual | Experimental |
| Whisper Tiny Multilingual | WhisperKit | CoreML / Neural Engine | ~153 MB | Multilingual | Fastest Whisper option |
| Whisper Tiny English | WhisperKit | CoreML / Neural Engine | ~153 MB | English only | Fastest English Whisper option |
| Whisper Small Multilingual | WhisperKit | CoreML / Neural Engine | ~250 MB | Multilingual | ~1-2s |
| Whisper Small English | WhisperKit | CoreML / Neural Engine | ~250 MB | English only | ~1-2s |
| Whisper Medium English | WhisperKit | CoreML / Neural Engine | ~1.5 GB | English only | Slower, more accurate English option |
| Whisper Large Turbo Multilingual | WhisperKit | CoreML / Neural Engine | ~626 MB | Multilingual | ~2-4s |

**Bodhan Core and Flex** replace the former seven-language AI4Bharat IndicASR integration. Core uses native-script output, including many English terms spoken within Indic utterances. Flex supports mixed-script output—Indic text in its native script and English terms in Latin letters—and spoken-number formatting. Output quality varies, so try both from the production model catalog. Each card has a precision dropdown beside the language selector, with independently downloadable FP16 and INT8 choices. Both require macOS 15 or later and warm up before the app reports readiness. Longer recordings are processed in overlapping chunks.

Both FP16 and INT8 use a CoreML encoder and a native MLX decoder. The precision dropdown changes weight precision for both components, with no development settings required. Fresh FP16 downloads include the MLX decoder instead of the older CoreML decoder and cross-projection packages. The variants have separate downloads and can be removed independently. INT8 is **weight-only quantization**: activations and KV cache remain floating point. The 1.27 GB figure covers encoder and MLX decoder weights, excluding compilation caches. These are storage sizes, not RAM requirements: runtime memory also includes activations, decoder KV cache, and CoreML/MLX allocations. CoreML device placement is runtime-dependent; Neural Engine execution is not guaranteed.

Existing saved IndicASR selections migrate to Bodhan Flex, preserving their language preference. Previously downloaded legacy model files are not automatically deleted.

Apple Speech uses the system `SpeechAnalyzer` and `SpeechTranscriber` APIs on
macOS 26 and compatible Apple hardware. Its language assets are managed by the
operating system rather than downloaded into Imla's model cache; older macOS
versions continue to use Imla's downloadable local ASR backends.

Whisper's Tiny and Small sizes are available as either multilingual or
English-only downloads. The multilingual variants auto-detect the spoken
language by default and also let you pin a language; the English variants stay
focused on English and therefore do not show a language control. Medium English
is available when English accuracy matters more than download size and speed,
while Large Turbo is the strongest multilingual choice for accents, background
noise, and mixed-language audio. Every variant can be downloaded, deleted, and
downloaded again from the Models tab.

The app and `imla-cli` share Nemotron 3.5's model cache at
`~/.cache/imla/models/nemotron35-multilingual-2240ms`; downloading it in one
surface makes it available to the other without a second copy.

Cohere Transcribe is a 2B parameter model (#1 on Open ASR Leaderboard) running in mixed precision — FP16 FastConformer encoder on the Neural Engine with INT8 quantized decoders. Includes VAD-gated silence detection to prevent hallucination. Best for high-accuracy multilingual dictation.

Gemma 4 E2B is an experimental multimodal LiteRT-LM backend for direct transcription or on-device transcript cleanup. It is not an ASR-tuned model, so assistant-style outputs are rejected and Parakeet remains the recommended transcription backend. Gemma cannot be selected for ASR and cleanup at the same time.

Meeting echo cancellation uses LocalVQE by default. Release builds ship the
bundled `localvqe-v1.2-1.3M-f32.gguf` model plus the LocalVQE shared libraries,
so users do not need to download an AEC model before their first meeting
transcription. DTLN remains available as the fallback AEC path when LocalVQE
cannot load.

Source/dev builds need the LocalVQE runtime built once with
`./scripts/build_localvqe.sh` (the model is committed; the dylibs under
`native/ImlaNative/LocalVQE/lib/` are not). Signed packaging refuses to proceed without the complete runtime, including
`liblocalvqe` and its required `libggml` libraries. A warm SwiftPM cache does not
supply these gitignored libraries. See [CONTRIBUTING.md](CONTRIBUTING.md).

Models download on demand from HuggingFace. Manage them from the **Models** tab in the dashboard.

---

## Permissions

Imla needs these macOS permissions (guided during onboarding):

| Permission | Why |
|---|---|
| **Microphone** | Record audio for dictation and meetings |
| **System Audio Recording** | Capture call audio from Zoom/Meet/Teams |
| **Accessibility** | Simulate Cmd+V to paste; when App Context is enabled, read bounded focused-app text and browser URL context. Bundle-ID matching does not need it; hostname matching only reuses an already available browser hostname. |
| **Screen Recording** *(OCR opt-in)* | Capture OCR screen context separately from Accessibility; Writing Styles never trigger or use OCR |
| **Input Monitoring** | Detect hotkey presses globally |
| **Camera** *(implicit)* | Detect webcam activation for meeting detection |
| **Calendar** *(optional)* | Read calendars connected to macOS to show upcoming meetings and reminders |

---

## Calendar setup and management

Imla uses macOS Calendar through EventKit. A direct Google Calendar sign-in is not currently available in Imla.

1. In **System Settings → Internet Accounts**, add your Google, Exchange, or other calendar account and enable **Calendars**. Accounts already available in Apple Calendar can be used by Imla.
2. Allow Imla full Calendar access during onboarding or from **Settings → Meetings → Calendars**. If access was denied, use **Open Calendar Privacy Settings…** to enable it in macOS. Calendar access is optional; you can choose **Not now** during onboarding.
3. In Imla's **Settings → Meetings → Calendars**, select which calendars to include. Unchecking a calendar hides its meetings and notifications in Imla without deleting calendar data.

**Manage accounts…** opens macOS Internet Accounts, where you can add or remove accounts. Account changes there also affect other apps on your Mac. **Open Calendar…** opens Apple Calendar, where you can create or delete individual calendars and manage subscriptions. Imla refreshes its calendar list when you return from macOS settings.

---

## Tech Stack

| Component | Technology |
|---|---|
| App | Swift, AppKit, SwiftUI |
| Primary ASR | [FluidAudio](https://github.com/FluidInference/FluidAudio) and FluidInference models (Parakeet TDT, Nemotron 3.5, SenseVoice Small, and Qwen3 ASR on CoreML/ANE) |
| Cohere ASR | [Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) (FP16 encoder + INT8 decoder on CoreML) |
| Bodhan ASR | [Bodhan AI](https://huggingface.co/bodhan-ai) Core/Flex with a CoreML encoder and native [MLX Swift](https://github.com/ml-explore/mlx-swift) decoder |
| Gemma ASR / cleanup | [Google LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) with Gemma 4 E2B (Metal GPU decoder + CPU audio encoder) |
| Whisper ASR | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML/ANE) |
| Voice activity | Silero VAD via FluidAudio (streaming, event-driven) |
| Speaker diarization | pyannote via FluidAudio (CoreML on ANE) |
| Camera detection | CoreMediaIO property listeners (event-driven) |
| System audio | CoreAudio process tap by default; ScreenCaptureKit (`SCStream`) fallback |
| Meeting notes | OpenAI / OpenRouter (BYOK), ChatGPT subscription (OAuth), or Ollama |
| Calendar | Apple EventKit (macOS Calendar accounts) |
| Sync | CloudKit private database for text-only iCloud sync |
| Automation | Computer Use planner and post-meeting executable hooks |
| Export | Meeting PDF/Markdown + versioned Writing Styles JSON |
| Word correction | Jaro-Winkler similarity (native Swift) |
| Storage | SQLite (WAL mode) |
| Signing | Developer ID + hardened runtime (notarization ready) |

Writing Styles affect standard record-then-transcribe dictation. Nemotron double-tap streaming remains live and skips adaptive cleanup; local history records that limitation as `skipped_streaming`. The exported Writing Styles JSON excludes credentials, backend/model settings, App Context preferences, telemetry settings, history, and transcript data, but it does contain configured app/site identities, group and style names, and custom instructions—share it intentionally.

TelemetryDeck receives only coarse enum values for dictation backend, paste method, style-selection source, built-in/custom class, cleanup outcome, and cleanup backend. It never receives app or website identity, style IDs/names, prompts, transcripts, URLs, selected text, OCR, or App Context. Optional developer cleanup JSONL logs remain local, may contain bounded transcript/context and style provenance, and rotate after 5 MB. See the [privacy policy](docs/privacy.html) for the complete data-flow boundaries.

---

## Contributing

Contributions welcome! To get started:

```bash
git clone https://github.com/xshaheen/muesli.git
cd imla
swift build --package-path native/ImlaNative --scratch-path "$HOME/Library/Caches/imla-spm/contributor" -c release
swift test --package-path native/ImlaNative --scratch-path "$HOME/Library/Caches/imla-spm/contributor"
./scripts/test_packaged_cli.sh
```

The suite covers model configuration, custom word and phrase matching, filler removal, transcription routing, data persistence, CLI contract/path-resolution logic, speaker diarization alignment, token consolidation, camera-based meeting detection, CoreAudio system capture, ChatGPT OAuth logic, Ollama summaries, launch at login, paste/clipboard safety, meeting export, meeting navigation, upcoming-meeting window behavior, and Google Calendar URL extraction.

Current test scope:

- Covered by tests: CLI command contract generation, CLI path-resolution logic, SQLite read/write behavior, note-state classification, meeting/dictation retrieval/update flows, update-flow policy, CoreAudio cleanup, paste/clipboard safety, launch at login, Ollama summary routing, and Computer Use planner foundations.
- Not covered by Swift unit tests: app-bundle packaging and copying `imla-cli` into `/Applications/Imla.app/Contents/MacOS`.
- Packaging is verified by `scripts/test_packaged_cli.sh`, which builds an isolated app bundle, checks that `Contents/MacOS/imla-cli` exists and is executable, and runs `imla-cli spec` from the packaged path.

Please open an issue before submitting large PRs.

---

## Acknowledgements

Imla is built on this work:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — CoreML speech models for Apple devices (Parakeet TDT, Qwen3 ASR, Silero VAD, speaker diarization)
- [localai-org/LocalVQE](https://github.com/localai-org/LocalVQE) — on-device acoustic echo cancellation for meeting transcription
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — Swift Whisper inference on CoreML/ANE
- [Core Audio](https://developer.apple.com/documentation/coreaudio) by Apple — system audio process taps
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) by Apple — system audio fallback capture
- [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) — FastConformer TDT speech recognition model
- [Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) — 2B parameter autoregressive ASR (#1 Open ASR Leaderboard)
- [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) — Multilingual speech recognition (52 languages)
- [Bodhan AI Core](https://huggingface.co/bodhan-ai/indic-transcribe-core) and [Flex](https://huggingface.co/bodhan-ai/indic-transcribe-flex) — multilingual Indic/English ASR; community [Core](https://huggingface.co/phequals/indic-transcribe-core-coreml) and [Flex](https://huggingface.co/phequals/indic-transcribe-flex-coreml) CoreML/MLX conversions
- [MLX Swift](https://github.com/ml-explore/mlx-swift) — native Apple-silicon decoding for both FP16 and INT8 Bodhan hybrid runtimes
- [Google LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) — Native on-device Gemma runtime with Swift APIs and Metal acceleration
- [Gemma 4 E2B LiteRT-LM](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) — Experimental multimodal transcription and cleanup model
- [pyannote](https://github.com/pyannote/pyannote-audio) — Speaker diarization (via FluidAudio CoreML conversion)

---

## License

[MIT](LICENSE) — free and open source. Copyright is shared with the upstream project the
fork descends from; see [LICENSE](LICENSE).
