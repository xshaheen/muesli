# Feedback history

## 24-08-2026 — carry the floating language into the app, and reorganise settings

- Request: the floating indicator and meeting panel are settled; redesign the app's design
  system and UI on the same concepts, reorganise settings, research competitors first, and
  produce visual designs to review.
- Keep: the Contextual Spark palette, the 22 pt module, continuous radii, and the shipped
  0.16 / 0.26 / 0.14 s motion durations.
- Drop: the cool blue-black shell palette (`#111214` / `#161719` / `#1c1d20`), the blue default
  accent, the default circular corner curve, and the six-pane segmented settings picker.
- Intensify: one identity across window and floating surfaces; semantic colour restricted to
  small carriers.
- Add: a settings sidebar, an AI-provider credentials registry with per-feature assignments,
  a Library section for the four collections that live in modal sheets, and a sidebar entry
  for Insights (which currently has none).
- Explore: three navigation models — A Continuum (one window, nested settings), B Workbench
  (content window + native preferences window), C Modes (per-context profile as the primary
  object).
- Rule established: HUD glass belongs to floating panels only. In-window surfaces are opaque
  at the same hex values; there is nothing behind an opaque window to blur.
- Resulting node: `spark-app-system-01` (proposal; awaiting selection on D1–D5).

## 25-08-2026 — decisions taken at their recommended values (provisional)

- Context: D1–D5 were put to the owner and not answered within the session. Rather than block
  the node, each is recorded at its recommended value so the design is planable. None is
  implemented in code, so any one reverses with a document edit.
- **D1 — shell: B (Workbench).** Content window plus a native ⌘, preferences window, each with
  a short sidebar. A stays on file as the fallback if a second window is judged too costly;
  C (Modes) is recorded as the destination after this slice, not part of it.
- **D2 — accent: option 2.** Coral is the default; the seven presets survive but are scoped to
  selection and highlight only. The record dot, the Mini and every semantic signal stay coral
  regardless of the preset, matching the colour-ownership boundary already documented in the
  mini-indicator brief.
- **D3 — type: option 1.** Inter in the app window, SF Pro left on AppKit-drawn system controls
  we do not render ourselves.
- **D4 — light appearance: option 1.** Warm paper `#f7f4ef`, warm greys, coral accent — one
  identity in both appearances.
- **D5 — credentials registry: option 1, conditional.** Full registry with a tolerant config
  migration (read the four legacy key sets, write the registry, keep decoding both for one
  release). If that migration turns out not to be tolerable, this drops to option 2 rather than
  shipping a lossy rewrite — and that fallback is a decision to bring back to the owner, not to
  take unilaterally.
- Not settled here, deliberately: onboarding (consumes these surfaces, should follow), the
  meeting detail document treatment (its own node), and the Modes object.
- Node status: `spark-app-system-01` moves from `candidate` to `selected`, variant B.

## 25-08-2026 — D1 overridden: C now

- Decision (owner-directed): **shell C (Modes) now**, not B. B's provisional selection above is
  superseded; A and B stay on file as alternatives.
- **Correction to the earlier cost estimate.** C was priced from the mockup as "a new persisted
  object … not a one-release change". Reading `DictationStyleResolver.swift` and
  `Models.swift` afterwards showed that was wrong:
  - `DictationStyleGroup` is already `{ id, name, styleID, matchers[] }`, and a
    `DictationStyleMatcher` is already `{ kind: bundle_id|hostname, pattern }` — a Mode with a
    one-field payload.
  - `DictationStyleResolver.resolve` already ships the precedence ladder (exact hostname
    exception → exact bundle exception → best hostname group → best bundle group → legacy
    domain/app rules → category), with normalisation, collision detection, malformed-config
    quarantine and a `LegacyProjection` for pre-ruleset configs.
  - `WritingStylesView` is already the routing editor: "Choose a global style, reusable app
    groups, and exact exceptions."
  C is therefore **widen the payload a group carries, and promote the editor from a sheet to
  the sidebar** — materially cheaper than estimated.
- **IA correction.** The 24-08 entry listed Styles *and* Prompts as library items. They are two
  halves of one system: `WritingStylesView` is the routing, `TranscriptCleanupPromptsManagerView`
  ("Manage Cleanup Styles") is the prompt bodies. Under C the routing half becomes Modes and
  leaves the library. Library is **Dictionary · Prompts · Templates**.
- Mode anatomy settled: matchers are the only required field; every other field defaults to
  *inherit* (hotkey, model, languages, dictionary scope, cleanup on/off + prompt, cleanup
  provider, app context). A Mode stores only overrides, and **never holds a credential** — it
  references an assignment from the provider registry. This makes D5 more necessary, not less.
- Precedence: the shipped ladder is reused unchanged; C adds one tier above it — an explicitly
  invoked Mode (own hotkey, or picked from the Mini's menu) wins for a single dictation and does
  not persist. The inspector must state the winning tier in words.
- Migration bar: **behaviour-identical on day one.** Ruleset groups become Modes with the same
  id, name and matchers and everything else inheriting; pre-ruleset configs keep resolving
  through the legacy tier and are not force-migrated; the quarantine path survives the widening
  and surfaces its reason in Modes. The Writing Styles sheet is removed in the same change that
  adds the sidebar — two editors on one ruleset is the failure mode to avoid.
- **D6 opened by this choice:** under C, do the remaining global settings live in the same
  window (as the C mockup draws) or in a ⌘, preferences window? Lean is the split window, but
  it is close; unanswered, build the split.
- Node status: variant C `selected`, B and A `alternative`.
