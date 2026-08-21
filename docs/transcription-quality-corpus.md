# Transcription quality corpus store

The quality harness measures ASR backends against real speech. That speech is licensed to the
maintainer who downloaded it, not to this repository, and some of it is identifiable participant
recordings. So the corpora live in a local directory **outside the repository**, and the harness
finds them through an environment variable.

This document is the runbook: where the store lives, what shape a corpus has to be in for the
harness to accept it, how to obtain each candidate corpus, and what the resulting numbers do and do
not mean.

## Rules this store exists to enforce

1. **Nothing from a corpus is ever committed.** No audio, no reference transcripts, no hypothesis
   text. What may be committed is derived: scores, corpus and model identities, content hashes, and
   provenance.
2. **A corpus without a recorded licence is not evaluated.** The store refuses it by name and the
   run reports the refusal. "No licence stated" means all rights reserved, not "probably fine".
3. **No corpus is a hard dependency.** The harness runs on whatever subset is present and reports
   which cohorts it could not cover. An absent store skips the harness rather than failing it.

## Locating the store

```bash
export MUESLI_ASR_CORPUS_DIR="$HOME/Library/Application Support/MuesliCorpora"
```

Any path outside the repository works; the example above is the maintainer's. This follows the
existing `MUESLI_COHERE_MODEL_DIR` / `MUESLI_INDIC_ASR_MODEL_DIR` convention for maintainer-only
paths, rather than adding a config key to the app.

With the variable unset, `TranscriptionCorpusStore.discover()` returns an empty store with no
error and no refusals. That is the normal state on every machine except the one running a sweep.

## Layout

Each immediate subdirectory of the store is one corpus. The directory name is how you find it on
disk; the descriptor's `id` is how a run receipt names it.

```
$MUESLI_ASR_CORPUS_DIR/
├── mgb3/
│   ├── corpus.json          # descriptor: identity, revision, licence, acquisition, cohort
│   ├── samples.jsonl        # sample index: one JSON object per line
│   └── audio/
│       ├── 0001.wav
│       └── 0002.wav
└── arzen/
    ├── corpus.json
    ├── samples.jsonl
    └── audio/…
```

### `corpus.json`

```json
{
  "schemaVersion": 1,
  "id": "mgb-3",
  "revision": "hf:9f2c1ab",
  "licence": {
    "identifier": "cc-by-nc-4.0",
    "sourceURL": "https://huggingface.co/datasets/MightyStudent/Egyptian-ASR-MGB-3"
  },
  "acquisition": "hugging-face",
  "cohort": "egyptian-arabic",
  "sampleIndex": "samples.jsonl",
  "notes": "Dev split only, resampled to 16 kHz mono."
}
```

| Field | Required | Meaning |
|---|---|---|
| `schemaVersion` | yes | Must be `1`. Any other value is refused, so an old descriptor never decodes as a new one. |
| `id` | yes | Stable identity written into run receipts. Keep it constant across revisions. |
| `revision` | yes | Whatever pins the bytes measured: a release tag, a dataset version, a Hugging Face commit (`hf:<sha>`), or the date of a request-granted copy. Free-form because corpora version themselves incompatibly. |
| `licence.identifier` | **yes in practice** | SPDX id where one exists, otherwise a plain description of the grant (`"author-granted 2026-08-21, non-redistribution"`). Optional in the schema only so its absence can be *reported*; a corpus without it is refused. |
| `licence.sourceURL` | yes | Where the terms can be re-read months from now: licence file, dataset card, or project page. |
| `acquisition` | yes | One of `hugging-face`, `direct-download`, `author-request`, `manual`. An unknown value is refused, naming it. |
| `cohort` | yes | Default cohort for every row: `english`, `egyptian-arabic`, or `arabic-english`. An unknown value is refused, naming it. |
| `sampleIndex` | no | Relative path of the index; defaults to `samples.jsonl`. |
| `notes` | no | Anything a future maintainer needs: which split, what preprocessing, what the grant permits. |

### `samples.jsonl`

One JSON object per line. Kept out of the descriptor because a large corpus's index is thousands
of rows long.

```json
{"id":"mgb3-0001","audio":"audio/0001.wav","reference":"الاجتماع الساعة تسعة","durationSeconds":4.2}
{"id":"arzen-0007","audio":"audio/0007.wav","reference":"يعني ال deadline بتاعنا الأسبوع الجاي","cohort":"arabic-english"}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique within the corpus; appears in per-sample issue reports. |
| `audio` | yes | Path relative to the corpus directory. Must resolve inside it. |
| `reference` | yes | The transcript the backend should produce. Capped at 2048 UTF-8 bytes, mirroring `maximumTextFieldBytes` in the frozen fixture manifest — a reference far past that is an adapter that swallowed a whole transcript file into one row, not a long utterance. |
| `cohort` | no | Overrides the descriptor's cohort for this row. Use it when a code-switching corpus also contains monolingual utterances. |
| `durationSeconds` | no | Informational; the harness measures duration from the audio itself. |

Reference transcripts go in as the corpus publishes them, relying on the repository's existing
Arabic normalization at scoring time. Corpus-specific quirks — speaker tags, overlap markers,
code-switch annotations — are stripped when writing the index, never by weakening the shared
normalizer.

## What the store refuses, and what it merely reports

A **corpus-level refusal** removes the whole corpus from the run and names it in the report:
missing `corpus.json`, a descriptor that does not decode (with the offending key or value quoted),
an unsupported `schemaVersion`, a missing or blank licence, an unreadable sample index.

A **per-sample issue** drops one row and keeps the rest of the corpus: a missing audio file, an
audio path escaping the corpus directory, an empty reference, a reference over the byte cap, or an
index line that does not decode (reported with its line number). One bad row must never cost a
whole cohort.

Cohorts with no usable samples anywhere are listed as uncovered. That is a reported result, not a
failure.

## Acquiring corpora

The candidates below were surveyed for Egyptian Arabic, English, and Arabic-English code-switching.
Verify the licence yourself at acquisition time and record what you find — the notes here are a
starting point, not permission.

### ArzEn — the target corpus

12 hours of spontaneous Egyptian Arabic-English code-switched speech, from informal interviews.
This is the exact profile the harness cares most about.

- Paper: <https://aclanthology.org/2020.lrec-1.523/>
- Project page: <https://sites.google.com/view/arzen-corpus/home>
- **Licence: not published.** The recordings are identifiable participant speech, so access is
  very likely request-gated.
- Acquisition: `author-request`. Contact the authors; the ArzEn-ST corresponding author is
  `injy.hamed@nyu.edu`. Ask explicitly for permission to use it for local, non-redistributed
  evaluation, and record the reply's terms in `licence.identifier` and `notes`.
- Cohort: `arabic-english`.

**ArzEn-ST** (<https://aclanthology.org/2022.wanlp-1.12/>) extends the same speech with monolingual
Arabic and English translations; the same access terms apply. Its monolingual side can populate
`egyptian-arabic` and `english` rows via per-row `cohort` overrides.

Expect this to take weeks or to not arrive at all. Nothing in the harness depends on it: the report
names which cohort rests on which corpus, and an uncovered cohort is an honest result.

### MGB-3 — Egyptian, monolingual

16 hours of Egyptian Arabic from YouTube, transcribed by four transcribers.

- <https://huggingface.co/datasets/MightyStudent/Egyptian-ASR-MGB-3>
- Licence: check the dataset card at download time and record the result. The original MGB-3
  challenge data carried its own terms; the mirror may not restate them.
- Acquisition: `hugging-face`. Pin the commit sha as `revision`.
- Cohort: `egyptian-arabic`.

### Mixat — Emirati-English code-switching

15 hours. Right language pair, wrong dialect: Emirati, not Egyptian. Useful as code-switching
evidence, not as evidence about Egyptian speech; say so in the report if it carries the
`arabic-english` cohort alone.

- Licence: check before use.
- Cohort: `arabic-english`.

### ZAEBUC-Spoken — multidialectal Arabic-English code-switching

12 hours, several dialects.

- Licence: check before use.
- Cohort: `arabic-english`, with per-row overrides where the dialect is identified.

### Casablanca — 8 dialects including Egyptian

48 hours across 8 Arabic dialects.

- Paper: <https://aclanthology.org/2024.emnlp-main.1211/>
- Ships **YouTube URLs, not audio**, for copyright reasons. You assemble the audio yourself, so
  acquisition is `manual` and coverage degrades over time as videos are removed. Record the
  fetch date in `notes`; a rerun months later is not the same corpus.
- Cohort: `egyptian-arabic` for the Egyptian portion.

### MAdel121/arabic-egy-cleaned — excluded

72 hours of Egyptian Arabic, 16 kHz mono WAV, roughly 85% male speakers. Attractive size and
format, but the dataset **states no licence**, which defaults to all rights reserved.

**Excluded until the authors clarify.** If you place it in the store anyway, the store refuses it
by name and the run reports the refusal — which is the intended behaviour, not a bug to work
around by inventing a licence string.

### MASC — subscription-gated

1000 hours, multi-dialect, distributed through IEEE DataPort behind a subscription. Only usable if
the subscription's terms permit this use; check before spending time on it.

## Adding a corpus: checklist

1. Obtain it under its own terms. Record the terms verbatim in `notes` if they are not an SPDX id.
2. Create `$MUESLI_ASR_CORPUS_DIR/<name>/`, put the audio under it, and write `corpus.json`.
3. Write `samples.jsonl`, stripping corpus-specific annotation markers as you go.
4. Run the harness. Read the refusals and per-sample issues before reading the scores — a corpus
   that lost most of its rows produces a real but very narrow number.

## What these numbers mean

Every corpus above is broadcast, interview, or podcast speech. **None of them contains technical
dictation vocabulary** — identifiers, product names, acronyms, the code-switched half-sentences
this app is actually used for. A backend can win here and still disappoint in daily use.

Read any ranking produced from this store as *a ranking on public broadcast-style data*, and state
that in the report alongside which cohort rests on which corpus. Closing that gap needs a personal
dictation corpus, which is deliberately out of scope.

## Verifying nothing leaked

Before committing anything from a measured run:

```bash
git status --short
git ls-files | rg -i '\.(wav|mp3|m4a|flac|ogg)$'
rg -l '"(reference|hypothesis|rawASR|finalOutput|transcript)"' --glob 'docs/**' --glob 'native/**/Fixtures/**'
```

Known, expected matches as of this document:

- Audio: `assets/audio/bbc_world_news.mp3` and `assets/audio/ndtv.mp3` — the app's own sound-effect
  clips, unrelated to the harness. Any other tracked audio file is a leak.
- Transcript-shaped fields: the frozen v1 fixture under
  `native/MuesliNative/Tests/MuesliTests/Fixtures/TranscriptionQuality/` (synthetic,
  maintainer-authored text, not corpus content) and this document, which names the field keys.
  Anything else is a leak.

`.gitignore` also blocks the directory names a corpus store is likely to be created under by
mistake (`asr-corpus/`, `asr-corpora/`, `transcription-corpora/`), and `*.wav` is already ignored
repository-wide. Those are backstops; the store belongs outside the repository.
