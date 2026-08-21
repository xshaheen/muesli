# Transcription quality run receipts (schema v2)

Run receipts produced by the transcription quality harness, in the v2 schema defined by
`Sources/MuesliCore/TranscriptionQualityReceipt.swift`.

## Why this is a separate directory

`Fixtures/TranscriptionQuality/` holds the frozen v1 baseline. Its contract test asserts *exact set
equality* over every regular file in that directory against its own manifest, plus a 512 KiB
total-bytes cap. Adding any file beside it — including a new-schema receipt — breaks the mandatory
v1 gate. So v2 lives here, with its own manifest and its own loader, and the v1 assertions stay
exactly as they were (R15, KTD3).

Nothing in this directory may be written into `Fixtures/TranscriptionQuality/`, and nothing there
may be moved here.

## What may be committed here

Only derived results (R2):

- scores — error rates, faithfulness, script distributions, latency
- identities — corpus id and revision, licence, backend and model identifiers, sample ids
- provenance — host facts, generation time, the thresholds the verdict was reached under

Never audio, never a reference transcript, never a hypothesis transcript. The receipt schema has no
field that can hold one, and `TranscriptionQualityReceiptTests` asserts that against the encoded
bytes twice over:

- **Keys.** Every JSON key in a committed receipt must appear in an explicit allow-list, so a text
  field added to the schema fails the suite instead of leaking quietly.
- **Values.** A key on the allow-list can still hold text, so every encoded string must be ASCII and
  no longer than 160 characters. Identities and closed vocabularies satisfy that by construction; the
  only two free-form fields — a maintainer's note and a thrown error's description — are put through
  `ReceiptProse`, which drops every non-ASCII scalar and caps the length. No Arabic reference can
  survive it in any form.

The not-runnable reason is a code plus scalars rather than a rendered sentence, and the samples one of
its cases names travel in `failures` — each with the id *and* the thrown error's description, because
a backend that scored nothing is undiagnosable from an id list alone. Those descriptions are the
second `ReceiptProse` field. The sentence a reader sees is rendered by the report at read time, so
nothing a future case might interpolate can reach a committed file.

## Files

| File | What it is |
| --- | --- |
| `manifest.json` | Byte counts, SHA-256, and the size cap for every other file here. |
| `run-example-v2.json` | **Synthetic.** Hand-authored numbers, not a measured run. |

`run-example-v2.json` exists so the v2 schema is proved to decode from disk, and so the decision
policy and report renderer have a committed input that does not depend on a maintainer having a
corpus. Its scores are invented. Do not cite them, and do not treat them as a regression baseline —
a real measured receipt lands separately and is named for its run.

## Adding a measured receipt

1. Run the harness (see `docs/transcription-quality-corpus.md`).
2. Write the receipt here as `run-<date>-<host>.json`.
3. Add its path, byte count, and SHA-256 to `manifest.json`.
4. Re-read the leak checklist in `docs/transcription-quality-corpus.md` before committing.
