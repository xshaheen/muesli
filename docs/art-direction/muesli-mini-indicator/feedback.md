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

## 19-08-2026 — insertion-caret anchoring correction

- Replace: mouse-pointer following with focused text insertion-caret following.
- Resolve: the caret from the focused editable control's Accessibility selected-range bounds.
- Follow: the caret while preparing and recording, with a small movement threshold to avoid jitter.
- Freeze: the last caret anchor while processing.
- Reacquire: the post-insertion caret once for success or failure, then freeze for the terminal dwell.
- Fallback: use the focused element frame when range bounds are unavailable; otherwise keep the Mini hidden.
- Avoid: any mouse-location fallback, because pointer position is unrelated to keyboard dictation context.

## 19-08-2026 — Contextual Spark palette correction

- Replace: the inherited blue-black shared panel surface and white waveform glyphs.
- Use: warm charcoal `#32312f` → `#181817` for the recording surface and `#272725` → `#0e0e0d` for the processing orb.
- Use: orange `#ff7043` with amber `#ffb04d` for preparing, recording, and processing activity.
- Preserve: semantic green `#62d691` for success and coral-red `#ff6961` for failure.
- Separate: Dictation Mini color ownership from the Meeting Recording Panel and the app-wide accent setting.

## 19-08-2026 07:29 UTC — true glass and compact terminal states

- Keep: the approved warm charcoal, orange, amber, green, and coral palette.
- Replace: the nearly opaque painted gradient and doubled border with a clipped macOS material, translucent warm tint, and one fine highlight edge.
- Smooth: render at the window backing scale with antialiasing and time-based 60 Hz animation.
- Reduce: processing from 38 to 28 points and simplify its point field from seven to five columns.
- Replace: the glowing green success dot with the check mark alone.
- Fix: lifecycle audio follows the enabled sound preference on AirPods and other headphone-like outputs instead of being silently suppressed.
- Resulting node: `glass-compact-states-06`.

## 19-08-2026 08:01 UTC — original glass and vector rendering

- Keep: the 28-point processing size, warm Contextual Spark palette, and check-only success.
- Reuse: the original floating button's clipped Dark Aqua HUD material, dark tint, continuous radius, compositor shadow, and single fine border.
- Drop: the 64–76% painted gradient that obscured the blur and made the Mini look opaque.
- Replace: per-frame `NSBezierPath` waveform bars and processing dots with scale-aware Core Animation gradient and shape layers.
- Align: vector layer positions to the active window backing scale for clean 1× and 2× edges.
- Resulting node: `original-glass-vector-07`.

## 19-08-2026 08:08 UTC — paired circular preparing and completion signals

- Keep: Preparing as a surface-free coral signal beside the insertion caret.
- Match: the reference's 14-point solid coral dot with a restrained warm halo.
- Replace: the standalone success check with a compact semantic-green circle containing the check.
- Preserve: backing-scale-aware Core Animation vector geometry and transparent glow-safe window bounds.
- Resulting node: `signal-pair-08`.

## 19-08-2026 08:11 UTC — preview coordinate correction

- Keep: the sizes, colors, glow bounds, and native implementation from `signal-pair-08`.
- Correct: the HTML preview's top-left SVG coordinate system so the completion glyph reads as a check rather than a caret.
- Resulting node: `signal-pair-09`.

## 19-08-2026 09:19 UTC — recording wave on a low dark glass

- Reject: the wide 104 × 32 pt recording capsule with 31 warm bars and a lighter tint; it drifted away from the reference's compact scale and still read as a weak guess.
- Keep: the accepted 58 × 22 pt recording footprint, the HUD glass recipe, the 1 pt edge, and the Contextual Spark palette; the reference capsule measures the same scale (≈ 53 × 23 pt).
- Intensify: darkness of the recording ground (tint 44 % → 62 %) so fine bars stay legible, matching the reference's near-black interior.
- Replace: five glowing 2 pt bars with twenty-four crisp 1 pt bars at 2 pt pitch, backing-scale aligned, no per-bar shadow.
- Explore: a 30 Hz scrolling history (newest on the right) with fast attack / slow release, an amber live edge fading to a 42 % muted orange tail, and one ambient halo that breathes with the voice.
- Soften: the reference's steel-cyan is not adopted; palette ownership stays with Contextual Spark.
- Preserve: Preparing, Processing, Complete, Failure, caret placement, lifecycle sounds, and the independent meeting panel.
- Resulting node: `recording-wave-10` (rejected sibling recorded as `wide-warm-field-rejected`).

## 19-08-2026 09:54 UTC — compact signal, reminder, and meeting Record pill

- Shrink: Preparing from a 14 pt to a 10 pt coral seed.
- Unify: Processing (28 → 20 pt orb), Complete (20 → 18 pt disk) and Failure (22 → 20 pt) in one shared 20 pt window.
- Hold: Processing, Complete and Failure are placed against the held caret anchor with the same quadrant rule as Preparing, so they appear exactly where Preparing appeared; the post-insertion caret reacquire is dropped. Recording keeps following the caret.
- Add: a three-second focus reminder — the Preparing seed appears beside a newly focused text caret to remind the user that dictation is available; one per focused field, 1.5 s cooldown, never inside Muesli, never during a session, never announced; setting "Dictation reminder in text fields" (on by default).
- Return: the floating button for meetings only as a compact Record pill shown while a meeting app is actively in use; one click starts recording and hands off in place to the Meeting Recording Panel; ⌥/right-click hides it for the current meeting; setting "Floating Record button" (on by default, requires meeting detection).
- Restyle: the pill uses the Contextual Spark glass (#211f1e @ 62 %), coral record dot with amber core, ink label, hover/pressed states, shared saved position with the panel.
- Preserve: recording-wave-10, lifecycle sounds, and the dictation/meeting surface boundary.
- Resulting nodes: `compact-signal-11`, `meeting-record-pill-12`.
- Shrink (live feedback: "it too big"): the pill from 98 × 28 pt to 72 × 22 pt — the Mini's capsule height — with an 8 pt dot and 11 pt label.
