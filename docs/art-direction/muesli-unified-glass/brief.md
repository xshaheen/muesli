# Muesli unified glass redesign

## Mode

Iterate from the current neutral-glass implementation.

## Invariant brief

- Audience: a person actively recording and reviewing a meeting on macOS.
- Surfaces: compact floating recording control, expanded Transcript/Chat/Notes panel, and main meeting workspace.
- Required controls: panel toggle, pause/resume, stop, live status, Transcript, Chat, Notes, copy, and dismiss.
- Medium: high-fidelity interactive HTML visualization for a native SwiftUI/AppKit implementation.
- Geometry: preserve the compact control's small footprint. Treat the current 112 x 22 control and 360 x 320 panel as baseline evidence; a candidate may recommend a larger reading surface when the hierarchy earns it.
- Palette: neutral charcoal glass only. No decorative accent color. Semantic warning color remains reserved for actual failure states.
- Accessibility: readable opaque fallback, visible focus, minimum 24-point compact targets and 32-point targets in the expanded panel.
- Success: all three surfaces look like one product; state is clear without color; the expanded panel feels connected to the compact control; content remains legible over varied desktop backgrounds.

## Authorized references

- User-provided Muesli screenshots in this task: current meeting detail view and floating recording control. Anchor: actual density, geometry, and neutral dark appearance.
- Running `/Applications/MuesliDev.app` captured locally through macOS accessibility. Anchor: current 112 x 22 recording control.
- Repository source and `MuesliTheme`. Anchor: current tokens, 360 x 320 panel size, 20-point panel radius, and existing control inventory.

No private meeting content is reproduced. No reference was sent to an external generation service.

## Round 2 amendment

- Selected structure: Direction 01, preserving the compact pill and existing panel hierarchy.
- Keep every material surface, border, text hierarchy, and inactive control neutral.
- Add color only where it carries state: blue selection, green live/success, amber paused, and red stop/recording.
- Keep semantic color to small glyphs, dots, and low-alpha selected-control fills; never tint the glass body.
- Make the pill and panel read as one system through tighter proximity and shared chrome without coupling their independent window behavior.
