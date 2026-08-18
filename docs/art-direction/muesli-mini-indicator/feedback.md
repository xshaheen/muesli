# Feedback history

## 18-08-2026 18:59 UTC — contextual placement correction

- Keep: a small indicator close to the user's current work.
- Keep: Muesli's animated waveform as the recording signal.
- Drop: fixed screen-edge placement as the default.
- Drop: a permanently visible idle pill.
- Intensify: near-pointer placement and automatic disappearance.
- Explore: a calm reacquisition threshold instead of continuous pixel-by-pixel following.
- Resulting node: `contextual-spark-01`.

## 18-08-2026 19:23 UTC — processing is an animated transcription orb

- Keep: the indicator remains compact and contextual beside the active work.
- Keep: recording and processing must have immediately different silhouettes.
- Drop: the quiet three-dot processing capsule from `contextual-spark-01`.
- Intensify: visible computation through an animated field of points while Muesli generates the final transcript.
- Soften: use Muesli's warm accent rather than copying Monologue's cyan matrix.
- Defer: the expanded modes/record/cancel menu is a separate interaction decision and is not part of this visual delta.
- Resulting node: `transcription-orb-02`.

## 18-08-2026 19:25 UTC — distinct lifecycle sounds

- Keep: Muesli's existing start cue when the microphone stream is actually active.
- Keep: a stop cue at the capture-to-processing handoff.
- Add: a third, clearly different success cue only after non-empty text is successfully delivered.
- Avoid: playing success for empty, cancelled, failed, or undelivered dictation.
- Preserve: the global sound-effects preference and per-session deduplication.
- Resulting node: `lifecycle-cues-03`.

## 18-08-2026 19:28 UTC — terminal failure cue

- Keep: Start, Stop, and Success as three distinct lifecycle sounds.
- Add: a fourth low, brief Failure cue for terminal recording, transcription, or delivery failures.
- Avoid: treating user cancellation as failure.
- Avoid: replaying Failure from multiple internal error handlers for the same session.
- Gate: the session's winning terminal failure owns the sound.
- Resulting node: `failure-cue-04`.

## 18-08-2026 19:31 UTC — split dictation Mini from meeting panel

- Replace: the current generic floating indicator with the contextual Dictation Mini.
- Remove: Classic/fixed floating indicator as a dictation presentation option.
- Separate: meeting recording into its own stable interactive panel and lifecycle.
- Show: the Meeting Recording Panel only when an actual meeting recording starts; detection alone does not create persistent chrome.
- Preserve: meeting pause, stop, transcript toggle, duration, and drag/position behavior in the meeting-owned surface.
- Prevent: shared visibility, hover, anchor, drag, or state between the two concepts.
- Resulting node: `split-surfaces-05`.
