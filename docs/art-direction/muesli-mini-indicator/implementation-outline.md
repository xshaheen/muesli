# Contextual Mini Indicator — Implementation Outline

This is a source-grounded outline, not an implementation plan artifact. It intentionally does not use `x-plan`.

## Recommended product boundary

- Replace the current generic floating indicator with **Dictation Mini**: hidden while idle, contextual while active, and dedicated to short dictation lifecycle feedback.
- Do not retain Classic/fixed positioning as a dictation presentation style.
- Extract **Meeting Recording Panel** as a separate stable, draggable, interactive surface that owns pause, stop, duration, transcript toggle, and meeting status.
- Show the Meeting Recording Panel when an actual meeting recording enters preparing/recording, and dismiss it after the meeting reaches its terminal state. Detecting a teleconference app alone does not create persistent chrome.
- The two surfaces must not share position, hover, drag, visibility, or interaction state.

## State contract

| Muesli state | Mini presentation | Lifetime |
|---|---|---|
| Idle | No panel by default | Indefinite |
| Preparing | 14 pt accent seed | Up to 180 ms before morphing |
| Recording | 58 × 22 pt live waveform capsule | Until hotkey release/cancel |
| Transcribing | 38 pt animated transcription orb | Until completion/error |
| Complete | 12 pt green confirmation spark | About 120 ms, then fade |
| Warning/error | Compact labeled capsule | Long enough to read or until replaced |

## Audio contract

| Event | Truthful trigger | Cue |
|---|---|---|
| Start | Microphone stream becomes active, not merely hotkey-down | Existing `Tink` |
| Stop | Capture terminates and the app hands off to processing | Existing `Purr` |
| Success | Non-empty text is delivered to the intended target, or voice-note output is durably saved | Proposed distinct `Pop` |
| Failure | The session wins a terminal recording, transcription, or delivery failure | Proposed distinct `Funk` |

- Respect the existing `soundEnabled` preference and test-mode suppression.
- Emit each cue at most once per dictation session.
- Do not play success for empty, cancelled, failed, stale, or target-changed output.
- Do not play Failure for user cancellation, explicit discard, or test mode. Treat empty/no-speech as a separate neutral outcome until its feedback is intentionally designed.
- Centralize Failure behind the session's terminal-outcome winner so audio-session, streaming, and pipeline error handlers cannot double-play it.
- The current code already implements Start and Stop. Rename `playDictationInsert` to the truthful Stop semantic, add `playDictationSuccess`, prewarm its sound, and invoke it only after the delivery boundary succeeds.
- Do not repeat audio while the transcription orb animates.

## Placement contract

1. Query the focused macOS Accessibility element and its selected text range.
2. Resolve `kAXBoundsForRangeParameterizedAttribute` and convert Quartz top-left coordinates to AppKit bottom-left coordinates.
3. Prefer lower-left with 10 pt clearance so the Mini sits behind the insertion direction rather than covering upcoming text.
4. If it does not fit, try lower-right, upper-left, then upper-right before clamping.
5. Poll at roughly 10 Hz while preparing or recording and reacquire after 4 pt of caret movement or a display transition.
6. If selected-range bounds are unavailable, use the focused element frame as a contextual fallback; if neither is available, keep the Mini hidden until an anchor resolves.
7. Freeze the final anchor through processing. For success or failure, reacquire the post-insertion caret once and freeze for the terminal dwell.

The exact distance and timing values remain tuning hypotheses. They should be measured during dogfooding rather than treated as Monologue parity claims.

## Source changes when the direction is selected

### 1. Configuration and migration

- Replace `showFloatingIndicator` with a dictation Mini visibility preference if an off switch is retained; Mini idle remains hidden by default.
- Remove dictation-facing `IndicatorAnchor` and custom drag controls.
- Introduce a meeting-panel origin owned only by the Meeting Recording Panel. Migrate the existing custom indicator origin only when it is useful as the initial meeting-panel position; otherwise use the meeting panel's stable default.
- Replace the current Floating Indicator settings section with separate Dictation Mini and Meeting Recording Panel settings. Do not expose a shared style or position selector.

### 2. Pure placement policy

- Introduce a small `ContextualIndicatorPlacement` value type beside `FloatingIndicatorController`.
- Keep quadrant selection, caret clearance, display selection, and clamping pure so they can be exhaustively unit tested.
- Reuse the coordinate-conversion lessons already captured by `computerUseCursorFrame`; do not mix AppKit bottom-left points with Quartz top-left points.

### 3. Dictation caret follower

- Add an Accessibility-backed caret anchor provider responsible only for focused-element lookup, selected-range bounds, coordinate conversion, and element-frame fallback.
- Feed resolved anchors to `DictationMiniIndicatorController`; do not let the provider own chrome or dictation state.
- Poll only while preparing or recording. Do not install mouse event monitors or read focused text content for indicator placement.

### 4. Split the shared controller

- Create `DictationMiniIndicatorController` for preparing, listening, transcription orb, completion, warning/failure, contextual geometry, and lifecycle sounds.
- Create `MeetingRecordingPanelController` by extracting `isMeetingRecording`, pause/stop actions, transcript toggling, drag state, and meeting sizing from the current `FloatingIndicatorController`.
- Keep `FloatingMeetingTranscriptPanelController` under the Meeting Recording Panel; Dictation Mini never owns or toggles it.
- Reuse the current non-activating `NSPanel`, surface styles, waveform layers, and accessibility contrast handling where appropriate, but do not preserve a shared controller merely to reuse code.
- Add a dedicated processing point-field layer to Dictation Mini. Its animation represents transcription generation and never uses microphone amplitude.
- Reuse the existing computer-use cursor mode's contextual geometry as an implementation reference, separating its CUA-specific content from dictation Mini.

### 5. Verification

- Extend `FloatingIndicatorPlacementTests.swift` with all four quadrants, every screen edge, negative-origin displays, mixed display arrangements, and capsules wider than the visible frame.
- Extend `FloatingIndicatorGeometryTests.swift` with hysteresis, stable processing anchors, and display-transition behavior.
- Add config decoding/migration coverage for existing floating-indicator preferences, removed dictation anchors, new Mini defaults, and the meeting-only saved origin.
- Extend `SoundControllerTests` with disabled/enabled Success and Failure coverage. Add lifecycle tests proving one Start, one Stop, and one terminal Success or Failure per session, with silent cancellation and no duplicate Failure across nested error handlers.
- Native visual QA: 1x/2x displays, Reduce Motion, Increase Contrast, VoiceOver announcement, caret clearance, typing, selection changes, scrolling, window movement, full-screen apps, and multiple Spaces.
- Dogfood short dictation separately from meetings; the two presentations have different interaction requirements.
- Add routing tests proving dictation state changes cannot show/move the Meeting Recording Panel and meeting events cannot show/move Dictation Mini.

## Existing code leverage

- `FloatingIndicatorController.setState` currently centralizes dictation chrome, while `setMeetingRecording` and related fields add meeting behavior to the same class; this is the seam to split.
- `showComputerUseCursor(at:label:)` already proves that the current panel can animate to contextual geometry and become mouse-transparent.
- `computerUseCursorFrame` already handles Quartz-to-AppKit conversion and display clamping.
- `FloatingIndicatorSurfaceStyle` and the existing waveform layers preserve Muesli's visual identity.
- Existing placement/geometry tests can be divided into Dictation Mini follower tests and Meeting Recording Panel anchor tests.

## Settled placement decision

The Mini follows the focused insertion caret rather than the mouse pointer. Dogfood the 10 Hz polling interval, 4 pt movement threshold, lower-left preference, and focused-element fallback during real 30–60 second dictations; tune those values without changing the caret-owned context model.
