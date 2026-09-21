# Imla CLI Contract

## Commands

- `imla-cli spec`
- `imla-cli info`
- `imla-cli transcribe <file> [--format text|json|markdown] [--model parakeet-v3|parakeet-v2] [--summarize] [--save-meeting] [--title TITLE] [--output PATH]`
- `imla-cli meetings list [--limit N] [--folder-id ID]`
- `imla-cli meetings get <id>`
- `imla-cli meetings update-notes <id> (--stdin | --file <path>)`
- `imla-cli dictations list [--limit N]`
- `imla-cli dictations get <id>`

## Output shape

Data commands return JSON to stdout. `transcribe` returns plain transcript text by default, `--format markdown` emits markdown text with title, optional summary, and raw transcript sections, and `--format json` uses the same success envelope.

Success envelope:
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

Failure envelope:
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

## Important fields

Meeting list rows include:
- `id`
- `title`
- `startTime`
- `durationSeconds`
- `wordCount`
- `folderID`
- `notesState`

Meeting details also include:
- `rawTranscript`
- `formattedNotes`
- `calendarEventID`
- `micAudioPath`
- `systemAudioPath`

`notesState` values:
- `missing`
- `raw_transcript_fallback`
- `structured_notes`

Dictation details include:
- `rawText`
- `appContext`
- `timestamp`
- `durationSeconds`

Transcribe JSON data includes:
- `transcript`
- `summary`
- `durationSeconds`
- `wordCount`
- `model`
- `warnings`
- `savedMeetingID`
- `title`

Supported transcribe inputs (anything AVFoundation can decode; the list lives in
`ImlaCore/ImportableAudioFormat.swift`):
- recordings and exports: `.wav`, `.aiff`/`.aif`, `.caf`, `.flac`, `.mp3`, `.aac`, `.m4a`, `.mp4`, `.mov`
- voice notes: `.opus` (WhatsApp), `.ogg`/`.oga` (Telegram, Discord), `.3gp`, `.amr` (Android)
- rejected with a conversion hint: `.webm`, `.mkv`, `.mka`, `.wma` (macOS has no Matroska/WMA decoder; `ffmpeg -i in.webm -c:a aac out.m4a`)

Supported transcribe models:
- `parakeet-v3` (default)
- `parakeet-v2`

Transcribe behavior:
- progress and model logs go to stderr
- default stdout is transcript text only
- `--format json` includes warnings in both `data.warnings` and `meta.warnings`
- `--summarize` preserves the transcript if summary generation fails and returns a warning
- `--summarize` uses configured OpenAI, OpenRouter, Ollama, LM Studio, or Custom LLM settings when available; the app's ChatGPT session backend is not driven from headless CLI mode
- `--save-meeting` stores the meeting as `source = audio_import`; the retained audio is the original file for `.wav`, `.m4a`, `.caf`, `.aiff`/`.aif`, and `.mp3`, and the decoded 16 kHz mono WAV for every other container (a stderr line says so)
- `--output <path>` writes the selected output format to a file and keeps stdout clean

## Expected agent pattern

- `transcribe <file>` for raw local transcription
- `transcribe <file> --format json` when structured metadata is needed
- `transcribe <file> --save-meeting` when the imported audio should appear in Imla
- `list` to discover IDs
- `get` to fetch full text
- external summarize/analyze in the coding agent
- `update-notes` to write notes back
