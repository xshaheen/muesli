# Transcription quality fixture v1

This directory freezes the quality and latency comparison contract for later
multilingual transcription changes. It contains three equally sized cohorts:
English, Arabic, and Arabic-English code-switching.

The nine prompts are project-authored and were rendered ephemerally with macOS
system voices for the captured run. Generated audio is deliberately not
redistributed; each row freezes its byte size and SHA-256 so the measured input
remains auditable. The corpus does not contain customer recordings, personal
data, credentials, or copied passages. The committed corpus is capped at 512
KiB and each text field is capped at 2 KiB. `manifest.json` records SHA-256 for
every committed fixture file except itself, avoiding a circular self-hash.

`samples.jsonl` is the source of truth. Each row contains the reference, raw
ASR output, final output, audio duration, measured ASR latency, end-to-end CLI
latency, model identity, and provenance identifier. Raw and final outputs are
intentionally identical for v1 because cleanup and dictionary transforms were
disabled during capture.

## Scoring

All text is Unicode NFC-normalized and lowercased. Punctuation is removed and
whitespace is collapsed. Arabic and mixed cohorts additionally remove Arabic
diacritics and tatweel, normalize alef variants to `ا`, and normalize `ى` to
`ي`. Word error rate uses normalized word tokens. Character error rate uses the
same normalized text without spaces. Both use Levenshtein edit distance and
micro-average errors over reference units.

Mixed-language preservation is token recall split by script: exact normalized
Latin tokens retained from the reference, and exact normalized Arabic tokens
retained from the reference. Repeated tokens are matched once per hypothesis
occurrence.

Latency distributions report sample count, nearest-rank p50/p95, maximum, and
ASR real-time factor (`asr_seconds / audio_duration_seconds`). The committed
quality baseline is descriptive, not a release threshold. Trace-overhead caps
are absolute product budgets with wide headroom for loaded CI hosts; they are
not ratios derived from the capture machine. Later behavior PRs must publish
their results using this schema and call out intentional fixture or
normalization changes.

## Reproduction

1. Build `muesli-cli` at the capture commit in `PROVENANCE.md`.
2. Re-render the project-authored reference with the recorded voice/rate and
   encode it with the recorded `afconvert` command. Confirm byte size and hash.
3. Transcribe each generated file with `--model whisper-tiny --format json`.
4. Record WhisperKit's reported transcription duration as `asrSeconds` and
   `/usr/bin/time -p` wall time as `endToEndSeconds` after one warm-up run.
5. Run `TranscriptionQualityFixtureContractTests` to verify hashes and
   recompute every score and distribution. This suite validates the captured
   fixture; it does not invoke ASR.
