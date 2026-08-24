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

---

# Post-upgrade re-measurement — 25-08-2026 (U4)

The FluidAudio 0.15.1 → 0.15.6 upgrade, re-measured against the identical corpus and
compared to the 21-08 baseline. This is R10's gate, and it is the only evidence that the
upgrade did not move transcription quality.

- **Run:** `run-7DE3FC4A-AB7F-487C-BAE0-255901AB7F81`, FluidAudio **0.15.6**
- **Baseline:** `run-19A6C1CB-6C16-4122-8975-1E8F5F43BBF2`, FluidAudio 0.15.1 (recorded as
  `unrecorded` in that receipt — the provenance field postdates it, so the version is known
  from the pin at the time rather than from the receipt)
- **Samples:** 1,182 per backend, 5 backends, 0 failures. Identical corpora and revisions,
  so the pairing precondition holds.

## Why this comparison and not the ranking's interval

The run's own bootstrap compares two *backends within one run* — "is this backend separated
from the leader today?". Reusing it here would compare a single backend's before/after delta
against the spread of a two-backend difference: different quantities, and a gate that would
pass and fail for the wrong reasons. An earlier draft of the upgrade plan specified exactly
that mistake.

What is correct is pairing each backend against **itself** across the two runs. Both runs
scored the same utterances, so the corpus's own difficulty cancels. A movement whose 95%
interval excludes zero is reported; one whose interval contains zero is recorded as unmoved.

## Result: 13 of 15 unmoved

| Backend | Cohort | before | after | delta | 95% interval | verdict |
|---|---|---:|---:|---:|---|---|
| Parakeet v3 | english | 0.0628 | 0.0609 | −0.0019 | [−0.0045, −0.0001] | **moved, better** |
| Parakeet v3 | egyptian-arabic | 1.0632 | 1.0627 | −0.0005 | [−0.0023, +0.0013] | unmoved |
| Parakeet v3 | arabic-english | 0.9362 | 0.9343 | −0.0019 | [−0.0063, +0.0016] | unmoved |
| Whisper Large Turbo | english | 0.0566 | 0.0542 | −0.0024 | [−0.0076, +0.0004] | unmoved |
| Whisper Large Turbo | egyptian-arabic | 0.3856 | 0.3912 | +0.0055 | [−0.0067, +0.0188] | unmoved |
| Whisper Large Turbo | arabic-english | 0.6643 | 0.6594 | −0.0048 | [−0.0234, +0.0140] | unmoved |
| Whisper Tiny | english | 0.2489 | 0.2430 | −0.0059 | [−0.0242, +0.0096] | unmoved |
| Whisper Tiny | egyptian-arabic | 0.8578 | 0.8581 | +0.0003 | [−0.0071, +0.0078] | unmoved |
| Whisper Tiny | arabic-english | 0.9488 | 0.9657 | +0.0168 | [+0.0024, +0.0317] | **moved, worse** |
| Cohere Transcribe | all three | — | — | 0.0000 | [0, 0] | unmoved |
| Nemotron 3.5 | all three | — | — | 0.0000 | [0, 0] | unmoved |

**Neither movement is a reason to hold the upgrade.**

- *Parakeet v3 on English improved*, by 3% relative — and it is the backend the 0.15.6 chunk
  work actually touches, so an improvement is the expected direction. The interval's upper
  bound is −0.0001, which is as marginal as separation gets; treat it as "did not get worse"
  rather than as a demonstrated gain.
- *Whisper Tiny degraded on code-switching*, on a cohort where it already scored 0.949 WER and
  failed the faithfulness gate at 0.509. It is unusable there before and after; the movement is
  between two unusable numbers.

**Cohere and Nemotron reproduced bit-identically** across the two runs — delta exactly zero on
every cohort. Neither routes through FluidAudio's parakeet pipeline (Cohere is its own Core ML,
Nemotron runs Muesli's own engine), so no change was expected, and the exact reproduction is
also a useful check that the harness itself is deterministic.

## This answers the open P1

The review flagged that 0.15.6 rewrote FluidAudio's parakeet long-form pipeline — seam-gap
repair on by default, final-window re-cutting, timestamp clamping instead of sorting — affecting
every transcript over 15 s, with nothing measuring it. It is measured now: Parakeet's three
cohorts are unmoved-or-better, so the rewrite did not degrade transcription on this corpus.

## What it still does not cover

- **Diarization.** No test and no measurement exercises `performCompleteDiarization`, and the
  0.15.6 diarizer refactor is unverified. Speaker attribution is the path behind the
  "published as both You and the remote speaker" bug, so this gap sits directly on a known
  defect.
- **Run-to-run nondeterminism is unquantified.** The comparison attributes all movement to the
  upgrade. Cohere and Nemotron reproducing exactly is evidence for determinism, but Whisper is
  neither a FluidAudio ASR backend nor bit-identical here, which suggests some movement comes
  from somewhere other than the parakeet pipeline — plausibly the shared audio converter. A
  same-version repeat run would separate noise from effect and has not been done.
- **Latency is not compared.** A build briefly contended for the machine early in this run.
  It was blocked on the SwiftPM lock rather than consuming CPU, so the effect should be nil,
  but the figures were not taken under a contention-free guarantee and no latency claim is made
  from them. Real-time factors this run: Parakeet 0.034, Whisper Tiny 0.064, Nemotron 0.065,
  Cohere 0.084, Whisper Large Turbo 0.149.
- **Automatic detection only**, as before. The pinned-language configuration users actually run
  remains unmeasured.
