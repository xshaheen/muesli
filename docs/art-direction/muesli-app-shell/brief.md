# Muesli app shell — Direction Brief

## Mode

Extend a settled direction. The Contextual Spark language shipped on the floating surfaces
(`muesli-mini-indicator`, nodes 01–17) is the parent; this node carries it into the main
application window and reorganises settings around it.

## Invariant brief

- Audience: an existing Muesli user who dictates all day and reviews meetings a few times a week.
- Surfaces: the main window (Dictations, Meetings, Insights, libraries), the settings surface,
  and the onboarding flow that reuses both.
- Medium: high-fidelity HTML visualisation for a native SwiftUI/AppKit implementation.
- Palette: the approved Contextual Spark palette — warm charcoal `#211f1e`/`#32312f`,
  coral `#ff7043`, amber `#ffb04d`, green `#48e57b`, coral-red `#ff6961`, ink `#f3f2ef`.
  No second accent family. Semantic colour stays on small carriers, never on a surface body.
- Material: HUD glass belongs to floating panels only. In-window surfaces are opaque at the
  same hex values. Faking glass inside an opaque window is out of scope and out of taste.
- Geometry: continuous corner curve everywhere; radii 4 / 6 / 10 / 14 / 22; 4 pt grid retained;
  22 pt is the shared module (Mini capsule height, list row, sidebar item, control height).
- Motion: reuse the shipped durations verbatim — 0.16 s morph, 0.26 s pop-in (0.55 → 1.06 → 1),
  0.14 s fade, 0.4 s hover grace. Reduce Motion collapses all of them to the fade.
- Accessibility: Reduce Transparency, Increase Contrast (2 pt border, 80 % hairline),
  Reduce Motion, full keyboard traversal of the settings sidebar, and a visible focus ring
  drawn in coral at 60 %.
- Success: the app window and the Mini read as one product; no setting is configured in two
  places; every current capability keeps a home; a privacy-conscious user can read one page
  top to bottom and understand what leaves the device.

## Authorized references

- Muesli source tree — `MuesliTheme.swift`, `FloatingIndicatorSurfaceStyle.swift`,
  `ContextualSparkGlassSurface.swift`, `DictationMiniIndicatorController.swift`,
  `SettingsView.swift`, `SidebarView.swift`, `AppState.swift`. Anchor: shipped tokens,
  the full settings row inventory, and the current navigation.
- `docs/art-direction/muesli-mini-indicator/` brief and feedback history. Anchor: the settled
  Contextual Spark palette, geometry and motion, and the Mini's independent colour ownership.
- `docs/art-direction/muesli-unified-glass/` brief. Anchor: the neutral-with-semantic-colour rule.
- Public documentation and published reviews for Wispr Flow, Superwhisper, VoiceInk, Monologue
  and Granola. Anchor: competitor information architecture only. No visual asset is reproduced,
  and no reference was sent to an external generation service.

## Contested question

Everything above is settled by the parent node. The genuinely open decision is the
**navigation model**, because it bounds how far the settings reorganisation can go.
Three variants are drawn for it (A Continuum / B Workbench / C Modes), plus four smaller
decisions recorded with leans: the fate of the user-selectable accent, Inter vs SF Pro in the
window, whether the light appearance goes warm, and how far the credentials registry goes in v1.

## Working interpretation

Muesli's settings sprawled because it does three jobs (dictation, meetings, on-device model
management) that competitors each do one of. The fix is not fewer settings — it is grouping
them by the **object being configured** rather than the feature that first needed them.
Two objects carry most of the win: an **AI provider**, configured once and then assigned to
the four features that use one; and a **model**, whose download, selection and language
options stop being spread across three tabs.
