# Transcription quality — measured findings, 21-08-2026

The first full run of the measurement harness. This document is the durable record of what
was measured and what it means; the full run receipt and rendered report stay local, outside
the repository, because the receipt is 11 MB of per-utterance detail.

- **Run:** `run-19A6C1CB-6C16-4122-8975-1E8F5F43BBF2`
- **Corpus store:** `~/Dev/oss/muesli-asr-corpus/` (local only, never published)
- **Samples:** 1,182 per backend across four corpora; 6 backends measured, 0 failed
- **Wall clock:** 2 h 40 m
- **FluidAudio:** 0.15.1

## How to read this

Every backend ran on **automatic language detection**. That was forced: Qwen3 ASR accepts no
language argument, and pinning only its competitors would have compared a hobbled model against
tuned ones. The consequence is that **this run does not describe how anyone actually uses
Muesli** — real configurations pin a language. See "What this run does not answer" below; it is
not a footnote.

A backend must clear a **faithfulness gate of 0.90** before its error rate counts. Faithfulness
measures whether the output stayed in the language that was spoken. A model that translates
Egyptian Arabic into fluent English can post an attractive-looking error rate while being
useless, so no error rate buys back a failed gate.

Word error rates are **pooled** — total errors over total reference words — not a mean of
per-utterance rates, so a long utterance carries its true weight.

## English (n=300, FLEURS en-US, read speech)

| # | Backend | WER | Faithfulness | RTF |
|---|---|---:|---:|---:|
| 1 | Cohere Transcribe | 0.055 | 1.000 | 0.07 |
| 2 | Whisper Large Turbo | 0.057 | 0.997 | 0.12 |
| 3 | Parakeet v3 | 0.063 | 1.000 | 0.04 |
| 4 | Qwen3 ASR | 0.079 | 1.000 | 0.16 |
| 5 | Nemotron 3.5 | 0.186 | 0.997 | 0.06 |
| 6 | Whisper Tiny | 0.249 | 0.973 | 0.05 |

Cohere and Whisper Large Turbo are declared a **tie**: the 0.001 margin sits inside the paired
bootstrap interval, so no winner is claimed. Parakeet v3 is separated from them but is by far
the fastest of the three.

## Egyptian Arabic (n=583)

| # | Backend | WER | Faithfulness |
|---|---|---:|---:|
| 1 | Whisper Large Turbo | 0.386 | 0.936 |
| 2 | Nemotron 3.5 | 0.406 | 0.987 |
| 3 | Qwen3 ASR | 0.644 | 0.975 |

Excluded by the faithfulness gate — these did not keep the language:

| Backend | WER | Faithfulness |
|---|---:|---:|
| Parakeet v3 | 1.063 | **0.005** |
| Cohere Transcribe | 1.517 | 0.452 |
| Whisper Tiny | 0.858 | 0.784 |

**Parakeet v3 scores 0.005 faithfulness on Arabic — it essentially never emits Arabic script.**
Parakeet v3 is Muesli's default model. Any user dictating Arabic on the default is getting
something that is not Arabic.

### The pooled figure hides a large effect

This cohort pools two corpora of different register: 283 read sentences (FLEURS ar-eg) and 300
spontaneous broadcast segments (MGB-3). They are not the same task.

| Backend | read WER | spontaneous WER | read faith. | spontaneous faith. |
|---|---:|---:|---:|---:|
| Whisper Large Turbo | 0.145 | 0.457 | 0.974 | 0.901 |
| Nemotron 3.5 | 0.176 | 0.474 | 0.990 | 0.983 |
| Qwen3 ASR | 0.351 | 0.731 | 0.993 | 0.958 |
| Whisper Tiny | 0.692 | 0.907 | 0.931 | 0.644 |
| Cohere Transcribe | 0.428 | 1.839 | 0.918 | **0.013** |
| Parakeet v3 | 1.279 | 0.999 | 0.002 | 0.008 |

Read Arabic is roughly **3× easier** than spontaneous. Whisper Large Turbo's real-world Egyptian
figure is ~0.457, not the 0.386 the pooled number suggests.

Two diagnoses only the split makes visible:

- **Cohere collapses rather than degrades.** It handles read Arabic acceptably (0.428 WER,
  0.918 faithfulness) and abandons the language almost entirely on spontaneous speech (0.013).
  Its pooled 0.452 reads as "mediocre at Arabic" and is really "fine until the speech is real".
- **Nemotron is the most faithful model measured**, and nearly unaffected by register
  (0.990 → 0.983) where every other backend drops. It is second on error rate and first on
  keeping the language.

## Arabic–English code-switching (n=299, ArzEn)

**No backend passed the faithfulness gate.**

| Backend | WER | Faithfulness |
|---|---:|---:|
| Nemotron 3.5 | 0.614 | 0.675 |
| Whisper Large Turbo | 0.664 | 0.660 |
| Qwen3 ASR | 0.794 | 0.622 |
| Parakeet v3 | 0.936 | 0.172 |
| Whisper Tiny | 0.949 | 0.509 |
| Cohere Transcribe | 1.823 | 0.204 |

Under automatic detection, no local backend preserves both languages through a code-switched
utterance. This is the measured form of the complaint that Muesli "translates Arabic to English
and vice versa".

**This conclusion is the one most likely to be overturned** — see below.

## What this run does not answer

- **Pinned language.** Everything above is automatic detection. Field experience with Nemotron
  **pinned to `ar`** reports good Egyptian Arabic *with English keywords preserved* — which the
  automatic-mode code-switching figure (0.675) does not predict. Pinning is what real
  configurations do. A pinned pass is the next run, and it may overturn the code-switching
  conclusion entirely. Nothing here should be read as "code-switching is unfixable".
- **Technical dictation.** Every corpus is read, broadcast, or interview speech. None contains
  identifiers, acronyms, or code. The English ranking may not transfer to how a developer
  actually dictates.
- **Cleanup quality.** The cleanup stage ran, but this document reports raw-ASR figures.
  Field feedback is that the raw live caption is already good and wants *refining* — which
  makes cleanup, not model choice, the higher-value target for meetings.
- **Whisper tiny.en** was refused as a partial install: it has `AudioEncoder.mlpackage` but no
  `.mlmodelc`, no `generation_config.json`, and no completion marker. The refusal is correct
  behaviour, not a harness failure.

## Decisions this supports

1. **Drop Qwen3 ASR.** Last or near-last on every cohort including the Arabic ones it was kept
   for, and among the slowest (RTF 0.16–0.20). It cannot be pinned, so no pinned re-run will
   rescue it. Planned in
   `docs/plans/2026-08-21-002-feat-drop-qwen3-and-upgrade-fluidaudio-plan.md`.
2. **Per-language model routing is now evidence-backed.** Parakeet v3 is the best fast English
   model (0.063 at RTF 0.04) and unusable for Arabic (0.005 faithfulness). One global default
   cannot serve a bilingual user; the current compromise costs English accuracy, since Nemotron
   as the dictation default is ~3× worse than Parakeet on English.
3. **Meeting cleanup outranks meeting ASR.** The meeting chain already runs the two backends
   that passed the gate — Nemotron live, Whisper Large Turbo final. The gap is refinement.

## Reproducing

```bash
MUESLI_ASR_CORPUS_DIR="$HOME/Dev/oss/muesli-asr-corpus" \
MUESLI_ASR_HARNESS=1 \
MUESLI_ASR_HARNESS_OUT="$HOME/Dev/oss/muesli-asr-runs" \
swift test --package-path native/MuesliNative --filter TranscriptionQualityHarnessTests
```

The harness refuses to run in CI, refuses to download models, and never copies corpus text into
its receipt. Corpus acquisition is documented in `docs/transcription-quality-corpus.md`.
