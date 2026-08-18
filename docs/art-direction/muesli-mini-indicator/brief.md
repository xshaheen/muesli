# Muesli Mini Indicator — Direction Brief

## Invariant

- Audience: people dictating into any macOS app.
- Medium: non-activating AppKit floating panel.
- Core behavior: hidden while idle; appears near the mouse pointer when dictation starts; never depends on a fixed screen location.
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
3. Motion feels attached to intent, not attached to every pixel of cursor travel.
4. Every terminal state disappears without requiring cleanup from the user.
5. The design remains legible at 1x and 2x scale and does not cover the pointer hotspot.
6. A user can distinguish start, stop, successful delivery, and failure without looking at the indicator.

## Authorized references

- User-provided Monologue settings screenshot. Anchors: compact dark capsule, cyan activity signal, and explicit Mini/None presentation choices. The visual treatment is a benchmark, not an asset source.
- User-provided Mini state screenshots. Anchors: a collapsed point beside the active text context, a separately disclosed command/mode menu, and a denser animated circular state while transcription is being generated. The menu's exact contents and Monologue branding are not adopted by this direction.
- Installed Monologue 1.4.2 behavior and local binary metadata. Anchors: hidden idle behavior, pointer/caret geometry inputs, mouse/scroll/key monitoring, and a borderless follower panel.
- Current Muesli `FloatingIndicatorController`. Anchors: 22 pt compact height, waveform animation, glass surface, semantic dictation states, and existing cursor-relative panel geometry.

## Working interpretation

The pointer location is sampled at activation. The indicator remains stable for small cursor movements, then gently reacquires the pointer after a meaningful move. This preserves the observed contextual placement without creating a distracting cursor trailer. Meeting recording never uses this follower behavior.
