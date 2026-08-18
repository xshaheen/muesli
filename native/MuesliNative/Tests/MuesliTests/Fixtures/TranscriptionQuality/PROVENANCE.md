# Provenance

- Capture timestamp (UTC): `14-08-2026_02-32-20`
- Capture commit: `01350223527973044173d48a6c70687f58176764`
- Application: `muesli-cli` from the exact capture commit
- ASR backend/model: WhisperKit `whisper-tiny` (`tiny`)
- Platform: macOS arm64
- English synthesis: macOS `say`, voice `Samantha`, rate 170
- Arabic and mixed synthesis: macOS `say`, voice `Majed`, rate 155
- Encoding: `afconvert -f m4af -d aac -b 64000`
- Cleanup: disabled
- Dictionary: disabled
- Summary: disabled

All prompt text was authored specifically for this fixture. The rendered audio
was synthetic and contained no human recording. It was used only for the
measured run and is not redistributed by this repository. The corpus freezes
each ephemeral input's byte size and SHA-256 alongside the voice/rate/encoding
recipe; it does not redistribute a voice model, generated speech, or third-party
text.

The first English sample was used as a warm-up after model download. The nine
recorded rows were then run sequentially against the already-loaded local model
cache. `samples.jsonl` records the observed outputs and per-sample timings; the
baseline file records deterministic scores and nearest-rank distributions.
