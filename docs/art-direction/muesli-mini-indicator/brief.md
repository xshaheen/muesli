# Muesli Mini Indicator — Direction Brief

## Invariant

- Audience: people dictating into any macOS app.
- Medium: non-activating AppKit floating panel.
- Core behavior: hidden while idle; appears beside the focused text insertion caret when dictation starts; never depends on a fixed screen location.
- Required states: preparing, recording, processing, success, warning/error.
- Required auditory feedback: distinct cues for recording start, recording stop/processing handoff, successful text delivery, and terminal failure. All respect the existing sound-effects preference; cancellation remains silent.
- Required constraints: no focus stealing, no interception of normal pointer events, multi-display safe, high-contrast and Reduce Motion aware.
- Product continuity: preserve Muesli's waveform vocabulary and configurable accent in the dictation Mini. Stop, pause, transcript, and meeting-specific controls belong exclusively to a separate Meeting Recording Panel.

## Surface boundary

- **Dictation Mini Indicator:** replaces the current generic floating indicator. It is contextual, short-lived, and dedicated to dictation lifecycle feedback.
- **Meeting Recording Panel:** a separate stable, interactive surface. It appears only for an actual meeting recording lifecycle and disappears when that recording terminates.
- The two surfaces do not share position, visibility, hover, drag, or interaction state.

## Success criteria

1. The user can locate dictation feedback without looking away from the active context.
2. Idle contributes zero persistent screen chrome by default.
3. Motion follows the active insertion context without jittering on tiny caret changes.
4. Every terminal state disappears without requiring cleanup from the user.
5. The design remains legible at 1x and 2x scale and does not cover the insertion point or upcoming text.
6. A user can distinguish start, stop, successful delivery, and failure without looking at the indicator.

## Authorized references

- User-provided Monologue settings screenshot. Anchors: compact dark capsule, cyan activity signal, and explicit Mini/None presentation choices. The visual treatment is a benchmark, not an asset source.
- User-provided Mini state screenshots. Anchors: a collapsed point beside the active text context, a separately disclosed command/mode menu, and a denser animated circular state while transcription is being generated. The menu's exact contents and Monologue branding are not adopted by this direction.
- Installed Monologue 1.4.2 behavior and local binary metadata. Anchors: hidden idle behavior, contextual geometry inputs, and a borderless follower panel.
- Current Muesli `FloatingIndicatorController`. Anchors: 22 pt compact height, waveform animation, glass surface, and semantic dictation states.

## Working interpretation

The Mini resolves the focused editable control through macOS Accessibility, derives the insertion caret from the selected text range, and follows it while preparing or recording. Processing freezes at the last resolved caret. Success and failure reacquire the post-insertion caret once, then freeze for their terminal dwell. If range bounds are unavailable, the focused element frame is the contextual fallback; without either anchor the Mini stays hidden. Meeting recording never uses this follower behavior.
