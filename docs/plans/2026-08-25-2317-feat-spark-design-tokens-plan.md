---
title: Spark Design Tokens for the App Window - Plan
type: feat
date: 2026-08-25
topic: spark-design-tokens
artifact_contract: x-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: x-plan-bootstrap
origin: docs/art-direction/muesli-app-shell/brief.md
execution: code
---

# Spark Design Tokens for the App Window - Plan

## Goal Capsule

- **Objective:** A person who dictates with Muesli sees one product. The coral disc beside their caret and the window they open afterwards share a palette, a corner geometry, a type voice, and a motion vocabulary — recognisably the same application rather than two that ship together.
- **Means:** Move `MuesliTheme`'s tokens onto the Contextual Spark scale and route the call sites that currently bypass it back through it (KTD1).
- **Product authority:** The settled direction in `docs/art-direction/muesli-app-shell/` — `brief.md` for invariants, the material rule, and accessibility; `spark-app-system-01.html` sections 03 and 04 for the rendered scale; `feedback.md` for decision history.
- **Open blockers:** None. The shell question (Modes vs preferences window) is out of scope and nothing here presupposes an answer.
- **Execution profile:** Seven dependency-ordered units. Two carry judgment (the semantic token split, the accent sentinel); the rest are wide sweeps whose real work is classifying call sites before editing them.
- **Stop conditions:** Stop if the floating surfaces' independent palette cannot be preserved, if the warm light ramp cannot meet the contrast the current ink ladder assumes, or if Inter cannot be shown to resolve at runtime in a built bundle.
- **Tail ownership:** The implementer carries this through focused and full native tests, a built-app visual pass on an isolated dev lane, code review, and PR delivery.

---

## Product Contract

**Product Contract preservation:** Bootstrap contract. No upstream requirements document existed; the art-direction node is the origin and is cited throughout.

### Summary

Extend the Contextual Spark visual language from Muesli's floating surfaces into the main application window. The window adopts Spark's warm charcoal palette, its continuous corner geometry, its type voice, and its motion timings, while staying opaque — glass remains the signature of a surface that floats over another application's work.

This is the first of several stacked changes. It moves tokens and the call sites that consume them. It does not move a single control to a different screen.

### Problem Frame

Muesli currently ships two visual identities. The floating surfaces settled on warm charcoal `#211f1e`, coral `#ff7043`, amber `#ffb04d`, continuous radii of 11 and 14, and motion at 0.16 s / 0.26 s / 0.14 s. The app window is on cool blue-black `#111214`, a blue accent `#6ba3f7`, SF Pro through `.system()`, radii 6 / 10 / 14 / 20, and the default circular corner curve with no shared motion vocabulary.

A user holds the hotkey, watches a coral disc stretch into a charcoal capsule beside their caret, then opens the app to change a model and lands somewhere that shares nothing with what they just saw.

### Key Decisions

- **Glass never enters the main window.** (chosen over reusing `ContextualSparkGlassSurfaceView` for in-window cards: an opaque window has nothing behind it to blur, so the material would be decoration imitating a function it cannot perform.) Governs R11.
- **The floating surfaces keep independent colour ownership.** (chosen over unifying every surface on one accent: `DictationMiniPalette` deliberately owns its palette so a user's accent choice cannot make dictation feedback unreadable — the boundary is stated in `docs/art-direction/muesli-mini-indicator/brief.md`.) Governs R12.

### Requirements

**Palette**

- R1. The window's dark ramp is warm charcoal: ink-well `#0e0e0d`, ground `#141312`, base `#1a1918`, raised `#211f1e`, hover `#2a2826`, surface `#32312f`. The `raised` value equals `DictationMiniPalette.glassTintHex` so an in-window card and the Mini sit at one value.
- R2. The window's light ramp is warm paper: base `#fffdfb`, ground `#f7f4ef`, raised `#f0ece5`, hover `#e7e2d9`, surface `#d9d3c8`, ink `#1a1918`.
- R3. Ink and hairline opacity change hue, not value, where the app already has a value. Today `MuesliTheme` carries dark ink at 92 / 62 / 40 %, light ink at 88 / 55 / 33 %, and a hairline at 7 % dark and 8 % light. Those numbers are preserved.
- R3a. The ladder gains what it currently lacks: a disabled ink step, and a hairline that resolves to 80 % when Increase Contrast is on. `MuesliTheme` has no Increase Contrast path today, so this is new behaviour rather than a preserved value.
- R4. Coral `#ff7043` is the default accent. The existing accent presets remain selectable and affect selection and highlight only.

**Semantic state**

- R5. Recording state reads coral `#ff7043`; in-progress work reads amber `#ffb04d`; success reads `#48e57b`.
- R6. Destructive actions, validation errors, and failure messages read `#ff6961` through a token distinct from the recording token, so recolouring recording state cannot recolour a delete button. This covers every expression of the role, not only token references: direct `.red` and `Color.red` literals carry the same role today in at least `DictationRowView.swift:175`, `:316`, `ModelsView.swift:480`, `:770`, `:1086`, `SettingsView.swift:1872`, `:1961`, `InsightsShareView.swift:51`, `:70`, `:72`, and four sites in `OnboardingView.swift`.

**Geometry and motion**

- R7. Corner radii follow one continuous-curve scale: 4 chip, 6 control, 10 field or row, 14 card or panel, 22 window. Surfaces on this scale render with the continuous curve, not the default circular one.
- R8. The window's animations run on shared constants: 0.16 s morph, 0.26 s pop-in easing 0.55 → 1.06 → 1, 0.14 s fade, 0.4 s hover grace.
- R8a. When Reduce Motion is on, nothing in the window moves. A shorter duration is not compliance — SwiftUI still interpolates a changed offset, scale, or position. Transform changes apply without animation, transitions become opacity-only, scrolling is not animated, and repeating animations stop. Three files read `accessibilityReduceMotion` today, so most of the window's 54 animation sites currently ignore the setting.

**Typography**

- R9. Window text renders in Inter at the Spark scale. SF Symbols keep the system face so glyph metrics hold, deliberately monospaced displays keep a monospaced face, and SF Pro remains on AppKit-drawn system controls the app does not render itself.
- R10. When Inter cannot be resolved at runtime, text falls back to the system font without a crash or a blank run.

**Boundaries**

- R11. No main-window view uses glass or blur, by any mechanism: `NSVisualEffectView`, a SwiftUI `Material`, or a blur modifier. This is a state the window reaches, not only a rule for new code — `InsightsShareView.swift:109` currently applies `.background(.regularMaterial)` and must move to an opaque theme surface.
- R12. `DictationMiniPalette`, `DictationMiniRendering`, `FloatingIndicatorSurfaceStyle`, and `ContextualSparkGlassSurfaceView` are unchanged by this work.

### Success Criteria

- A reviewer placing a screenshot of the Mini beside a screenshot of the window identifies them as one product without being told.
- Dark and light appearances read as the same design, not as one redesigned and one not.
- No control changes position, label, or behaviour.

### Scope Boundaries

**In scope:** token values, the tokens' call sites, corner-curve adoption, type routing, motion constants, accent defaulting.

**Deferred to follow-up work:**

- The settings reorganisation and the nine-section settings sidebar (`docs/art-direction/muesli-app-shell/settings-ia.md`).
- The Mode object and the Modes sidebar.
- The AI-provider credentials registry and its config migration.
- Onboarding, which consumes these surfaces and should follow them.
- The meeting detail view's document treatment.

**Outside this change's identity:** any glass or blur inside the window (R11); any edit to the floating surfaces' palette (R12).

### Outstanding Questions

- Q1 (resolved by KTD5). The accent presets include an entry named "Dark" whose hex `1e1e2e` is also the sentinel meaning "no override" (`MuesliController.swift:705`, `:1905`; `Models.swift:1910`; `SettingsView.swift:421`), so the two are indistinguishable in stored config. KTD5 introduces an explicit default marker, keeps Dark selectable, and migrates legacy `1e1e2e` to the default — preserving today's rendering for every existing install and accepting one stated loss for anyone who had deliberately chosen Dark.

### Sources

- `docs/art-direction/muesli-app-shell/brief.md` — invariants, material rule, accessibility floor.
- `docs/art-direction/muesli-app-shell/spark-app-system-01.html` — sections 03 Tokens, 04 Components.
- `docs/art-direction/muesli-mini-indicator/brief.md` — the colour-ownership boundary behind R12.
- `native/MuesliNative/Sources/MuesliNativeApp/MuesliTheme.swift` — the tokens being changed.
- `native/MuesliNative/Sources/MuesliNativeApp/DictationMiniIndicatorController.swift:826-898` — `DictationMiniPalette` and `DictationMiniRendering`, the shipped Spark values this plan copies from.
- `native/MuesliNative/Sources/MuesliNativeApp/InsightsShareView.swift:352` — the established `Font(AppFonts.bold(30))` bridge from `NSFont` to SwiftUI `Font`.
- `scripts/build_native_app.sh:238-239` — `assets/fonts` is copied into `Contents/Resources/fonts`; `scripts/dev-test.sh:235` delegates to this script, so dev-lane builds carry Inter too.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Change colour values inside `MuesliTheme` and leave colour call sites alone. Repo scan: 39 files reference `MuesliTheme`, but they reference it by name (`MuesliTheme.backgroundBase`), so the warm ramp lands with no call-site churn. Governs R1, R2, R3.
- KTD2. Split the overloaded semantic tokens rather than recolouring them, and treat all three overloaded tokens as one problem. `MuesliTheme.recording` is used 38 times across 13 files, and the majority are destructive buttons, validation borders, and error text — not recording state (`SettingsView.swift:2512`, `:3139`; `TranscriptCleanupPromptsManagerView.swift:299`, `:469`; `MeetingTemplatesManagerView.swift:171`, `:381`). `transcribing` carries both in-progress work and failure states (`AboutView.swift:210-259`, `DictationRowView.swift:255-259`). `accent` carries a processing state in `MeetingStatusDisplay`, which makes that state follow whatever preset the user picked. Moving `recording` to coral alone would turn every "Clear dictation history" button coral while leaving failure amber and processing preset-dependent. Add a `danger` token at `#ff6961`, then classify every site of all three tokens by meaning. Governs R4, R5, R6.
- KTD3. Adopt the continuous curve through shared shape helpers on `MuesliTheme`, then migrate call sites to them. 331 `cornerRadius` sites exist and only 8 already pass `style: .continuous`; editing each inline would scatter the geometry decision across 39 files again. A helper keeps one owner for the scale and makes the sweep mechanically uniform. Governs R7.
- KTD4. Bridge Inter into SwiftUI through `Font(AppFonts.regular(_:))` rather than `Font.custom("Inter", size:)`. `AppFonts` already carries the family-name candidates and the system-font fallback, and `InsightsShareView.swift:352` establishes the bridge. `Font.custom` would duplicate the fallback logic and fail silently to a default face. Governs R9, R10.
- KTD4a. Migrate only the text roles. The 382 `.system(size:)` sites are not one population: some size SF Symbols, where the glyph metric must stay on the system face, and some are deliberately monospaced for versions, clocks, traces, and paths. Classify each site as text, symbol, or monospaced; move only text to Inter; give monospaced its own token rather than forcing it through an Inter helper. The source-scan gate in R9 is written against text sites only, so it cannot force a pointless wrapper around a symbol. Governs R9.
- KTD5. Give "use the product default" its own stored value instead of overloading a colour. Today `recording_color_hex` defaults to `1e1e2e`, `MuesliController.swift:705` and `:1905` read `1e1e2e` as "no override", and `SettingsView.swift:421` also offers `1e1e2e` as a selectable preset named "Dark" — so a deliberate Dark choice and an untouched default are the same bytes and cannot be told apart. Introduce an explicit default marker, keep all seven presets selectable, and let Dark persist as a real override going forward. Migrate a legacy stored `1e1e2e` to the default marker: that is exactly what the app does with it today, so every existing install keeps its current appearance. The cost is stated rather than hidden — a user who deliberately picked Dark before this change lands on the new default, because the old format did not record the difference. Governs R4; resolves Q1.
- KTD6. Put motion constants on `MuesliTheme` beside the radii, and treat Reduce Motion as an effect-level decision at the call site rather than a duration substitution. A resolver can hand back the right duration, but only the call site knows whether it is animating opacity or a transform, and R8a is satisfied by not interpolating the transform at all. The floating surfaces already hold these durations in `DictationMiniRendering`; the window gets its own copy on the theme rather than importing the Mini's rendering type, which would couple the window to a surface R12 forbids it from touching. Governs R8.

### Assumptions

These were proposed to the owner and not answered before planning began. They are implemented as stated and are safe to revisit — none is load-bearing for another unit.

- A1. The accent presets survive and are scoped to selection and highlight, rather than being removed. Removing a preference people already set would be a regression, and the Mini's independent palette already prevents the accent from harming dictation feedback.
- A2. Inter is used in the window, with SF Pro left on AppKit-drawn system controls. Moving the floating surfaces to SF Pro instead would undo settled visual QA on 22 pt chrome.
- A3. The light appearance goes warm rather than staying neutral grey. A half-applied redesign reads as a defect.

### Implementation Constraints

- Config JSON keys stay snake_case.
- This is a git worktree. Pass a shared SwiftPM scratch path rather than growing a package-local `.build`; `scripts/muesli_spm_cache.sh` resolves it.
- `FloatingIndicatorStyleTests.swift:77-79` pins `defaultAccentDarkHex`, `recordingHex`, and `transcribingHex` to their current values. These pins encode the old palette and are updated as part of the units that change those values — they are not incidental breakage to route around.

### Sequencing

U1 establishes the tokens every later unit reads. U2 must land before or with U1's semantic change, because U1 alone would recolour destructive controls. U3, U4, U5, and U7 are independent of each other and each depend only on U1. U6 runs last: it adds the contrast path and enforces the two boundary gates over the finished result.

---

## Implementation Units

### U1. Warm token ramps

**Goal:** `MuesliTheme` carries the Spark palette in both appearances, with the ink and hairline ladders unchanged.

**Requirements:** R1, R2, R3.

**Dependencies:** none.

**Files:**
- `native/MuesliNative/Sources/MuesliNativeApp/MuesliTheme.swift`
- `native/MuesliNative/Tests/MuesliTests/FloatingIndicatorStyleTests.swift`

**Approach:**
1. Replace the five background and surface values with the warm dark ramp from R1, and add the ink-well value.
2. Replace the light half of each `Color.adaptive` pair with the warm paper ramp from R2.
3. Leave `textPrimary`, `textSecondary`, `textTertiary`, and `surfaceBorder` alphas at their current numbers; only their base colours change where the ramp requires it.
4. Update the palette pins in `FloatingIndicatorStyleTests` to the new values, keeping the tests as pins rather than deleting them.

**Patterns to follow:** the existing `Color.adaptive(dark:light:)` and `Color.adaptiveAlpha` helpers already in the file; do not introduce a second colour-construction path.

**Test scenarios:**
- `raised` resolves to `#211f1e` and equals `DictationMiniPalette.glassTintHex`, so the shared-value intent behind R1 cannot silently drift.
- The dark ramp is monotonically lighter from ink-well through surface.
- Each ink alpha is unchanged from its pre-change value.
- Light and dark resolve to different values for every background token.

**Verification:** the theme's own tests pass and the full suite is green. Colour call sites are untouched, so a green suite plus an unchanged diff outside the two files above is the evidence that KTD1 held.

---

### U2. Give each semantic state its own token

**Goal:** each semantic state reads its own token — recording coral, in-progress amber, failure `#ff6961` — so recolouring one state cannot recolour another, and no state depends on the user's accent preset.

**Requirements:** R4, R5, R6.

**Dependencies:** U1.

**Files:**
- `native/MuesliNative/Sources/MuesliNativeApp/MuesliTheme.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/SettingsView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/TranscriptCleanupPromptsManagerView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/MeetingTemplatesManagerView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/WritingStylesView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/MeetingsView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/AboutView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/DictationRowView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/DictationsView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/DictionaryView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/MeetingDetailView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/MeetingListItemView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/MeetingStatusDisplay.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/OnboardingView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/ModelsView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/InsightsShareView.swift`
- `native/MuesliNative/Tests/MuesliTests/FloatingIndicatorStyleTests.swift`

**Approach:**
1. Add `danger` (`#ff6961`) and keep `success` as it is; move `recording` to `#ff7043` and `transcribing` to `#ffb04d`.
2. Walk all 38 `MuesliTheme.recording` sites and classify each as recording-state or danger. Destructive button foreground, fill, and border; validation borders; error text; and "failed" status text are danger. Live-recording indicators and recording status dots stay on `recording`.
3. Walk the `MuesliTheme.transcribing` sites and move the failure ones to `danger`, leaving genuine in-progress ones on amber. `AboutView.swift:210-259` and `DictationRowView.swift:255-259` carry both meanings on this one token.
4. Walk the `MuesliTheme.accent` sites and move any that carry a *state* to a semantic token. `MeetingStatusDisplay`'s processing state is the known case: state must not follow the user's accent preset, which is what R4 means by scoping presets to selection and highlight.
5. Sweep the direct colour literals that carry a semantic role without touching a token — `.red` and `Color.red` at the sites listed in R6, and any `.orange` or `.green` found alongside them. A token-reference audit alone leaves these untouched and R6 unmet in ordinary flows such as a failed model download.
6. Update the semantic pins in `FloatingIndicatorStyleTests`.

**Execution note:** classify every site explicitly rather than replacing by regex. The meanings are indistinguishable by token name, which is what produced the conflation in the first place.

**Patterns to follow:** the `isDestructive ? … : …` ternaries that already exist in `SettingsView.swift:2512`, `TranscriptCleanupPromptsManagerView.swift:469`, and `MeetingTemplatesManagerView.swift:381` mark the destructive sites unambiguously.

**Test scenarios:**
- `danger`, `recording`, `transcribing`, and `success` all resolve to different values.
- A destructive action row resolves its foreground to `danger`, not `recording`.
- A validation-error border resolves to `danger`.
- A live recording indicator resolves to `recording`.
- An update-check failure resolves to `danger`, not `transcribing`.
- A processing state resolves to `transcribing` and does not change when an accent preset is stored — this is the R4 scoping rule, tested rather than asserted.
- No `MuesliTheme.recording` reference remains inside an `isDestructive` branch.

**Verification:** the full suite is green, and a grep for `MuesliTheme.recording` returns only recording-state sites. This is the unit where a wrong call is visible in the built app as a coral delete button, so the dev-lane pass in U6 covers it too.

---

### U3. Continuous corner geometry

**Goal:** window surfaces use one continuous-curve radius scale.

**Requirements:** R7.

**Dependencies:** U1.

**Files:**
- `native/MuesliNative/Sources/MuesliNativeApp/MuesliTheme.swift`
- the main-window view files carrying the 323 non-continuous `cornerRadius` sites
- `native/MuesliNative/Tests/MuesliTests/` — a new test file for the shape helpers

**Approach:**
1. Add the radius scale from R7 to `MuesliTheme`, keeping the existing names where the value is unchanged so unrelated call sites do not churn.
2. Add shape helpers that return a continuous `RoundedRectangle` for a named scale step, plus a view modifier for the common "clip and stroke a hairline" pairing.
3. Migrate call sites to the helpers, scale step by scale step, so each commit is one radius value.
4. Leave `cornerRadius` sites inside floating-surface files untouched per R12.

**Technical design (directional):** one helper keyed by a scale case, so a call site names the role rather than the number — a card asks for the card shape, not for 14. This is the mechanism that keeps R7 enforceable later; the exact helper shape is the implementer's call.

**Test scenarios:**
- Each scale step returns the expected radius.
- The helper's returned shape uses the continuous style.
- No main-window view constructs a `RoundedRectangle` with the default corner style. Assert this as a source scan, in the manner of `MeetingDetailResponsiveLayoutTests.swift:32`, which already asserts on source text.

**Verification:** the source-scan test passes, the full suite is green, and the dev-lane build shows squircle corners on cards, rows, and controls.

---

### U4. Inter typography

**Goal:** window text renders in Inter, and falls back to the system font when Inter is absent.

**Requirements:** R9, R10.

**Dependencies:** U1.

**Files:**
- `native/MuesliNative/Sources/MuesliNativeApp/MuesliTheme.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/AppFonts.swift`
- the main-window view files carrying the 382 direct `.system(size:)` sites
- `native/MuesliNative/Tests/MuesliTests/` — a new test file for type resolution

**Approach:**
1. Route `MuesliTheme`'s eight existing type helpers through `Font(AppFonts.…(size))` per KTD4.
2. Classify the 382 `.system(size:)` sites into text, SF Symbol, and monospaced per KTD4a before editing any of them. The classification is the unit's real work; the edits follow from it.
3. Add the missing steps from the Spark scale so every *text* site has a named destination, plus a monospaced token for the clock, version, trace, and path displays.
4. Migrate the text sites to the named helpers. Each hunk has the same shape, so review reads as one repeated edit rather than a pile of decisions.
5. Leave SF Symbol sizing on the system face.
6. Add tabular figures to the monospaced token so durations and counts stop shifting width.

**Execution note:** registration already precedes window construction — `AppDelegate.swift:32` runs before `MuesliController` is constructed at line 36 — so no ordering change is needed. Prove that rather than assume it, because `AppFonts.register` silently no-ops when it finds no font files and the app would ship SF Pro with no error.

**Patterns to follow:** `InsightsShareView.swift:352` for the `Font(NSFont)` bridge; `AppFonts.swift:59-66` for the candidate-name fallback chain.

**Test scenarios:**
- Each theme type helper returns a font at the requested size and weight.
- With Inter registered, a text helper resolves to an Inter family name.
- With Inter unavailable, the helper resolves to the system font rather than throwing or returning nil — this is R10.
- The monospaced token resolves to a monospaced face and requests tabular figures.
- No main-window view applies `.system(size:)` to a **text** run. Assert as a source scan scoped to text sites; SF Symbol sizing is outside the gate per KTD4a, so the scan must exclude `Image(systemName:)` modifiers rather than banning the call outright.

**Verification:** the full suite is green, and the dev-lane build renders Inter — confirmed against a built bundle, since `scripts/build_native_app.sh:238` is what puts the fonts in `Contents/Resources/fonts`.

---

### U5. Coral accent default

**Goal:** the product default accent is coral, presets stay selectable for selection and highlight, and the sentinel keeps its meaning.

**Requirements:** R4.

**Dependencies:** U1.

**Files:**
- `native/MuesliNative/Sources/MuesliNativeApp/MuesliTheme.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/SettingsView.swift`
- `native/MuesliNative/Sources/MuesliNativeApp/SidebarView.swift`
- `native/MuesliNative/Tests/MuesliTests/FloatingIndicatorStyleTests.swift`

**Approach:**
1. Set the default accent to coral in both appearances.
2. Introduce the explicit default marker from KTD5 and stop treating `1e1e2e` as "no override". Keep all seven presets, Dark included, and store a chosen Dark as a real override.
3. Migrate on decode: a legacy stored `1e1e2e` becomes the default marker. Keep decoding the legacy shape for at least one release, in the manner already used for the retired indicator keys.
4. Confirm `SidebarView.swift:68-90`'s luminance branch still picks a readable foreground against coral.
5. Update the accent pins in `FloatingIndicatorStyleTests`.

**Execution note:** the migration is one-way and cannot be perfect, because the old format never recorded the difference between a chosen Dark and an untouched default. Choosing the default preserves today's rendering for every existing install, which is the safer error.

**Test scenarios:**
- With nothing stored, the accent resolves to coral.
- With a legacy `1e1e2e` stored, decode yields the default marker and the accent resolves to coral — matching what that config renders today.
- With Dark chosen after the migration, the accent resolves to Dark and survives a save/reload round trip.
- With any other preset stored, the accent resolves to that preset.
- With a malformed override stored, the accent falls back to coral rather than throwing.
- Config JSON keys stay snake_case through the round trip.
- The sidebar's update-CTA foreground stays readable against coral.

**Verification:** the full suite is green, and a config file written by the current shipping version opens, renders as it does today, and re-saves without a decode error.

---

### U7. Motion adoption and Reduce Motion

**Goal:** window animations run on the shared constants and respect Reduce Motion.

**Requirements:** R8, R8a.

**Dependencies:** U1.

**Files:**
- `native/MuesliNative/Sources/MuesliNativeApp/MuesliTheme.swift`
- the main-window view files carrying the 54 animation sites
- `native/MuesliNative/Tests/MuesliTests/` — a new test file for motion resolution

**Approach:**
1. Add the R8 constants to `MuesliTheme` beside the radii, per KTD6.
2. Build an inventory of every animation site in main-window views before editing any of them: `withAnimation`, `.animation(`, every direct animation constructor, and every `repeatForever`. The known shape is 54 sites — 27 `easeInOut`, 11 `easeOut`, 2 `linear`, and 14 implicit `withAnimation`. The inventory is the unit's contract; the gate in step 5 is written against it.
3. Classify each site by the effect it animates, not by its duration: opacity-only, transform (offset, scale, position), transition, scroll, or repeating.
4. Apply the R8a policy per class. Opacity-only keeps the fade. Transform sites apply the state change with no animation under Reduce Motion — not a faster one. Transitions become opacity-only. Scrolling drops its animated variant. Repeating animations stop and hold a static frame. A resolver may carry the durations, but it cannot carry compliance on its own: returning a shorter animation still interpolates the transform.
5. Gate the sweep on the inventory, not on one constructor name. Every site in step 2 either routes through the shared motion path or appears on an explicit audited exception list with a reason.
6. Leave the three files that already read `accessibilityReduceMotion` working as they do; move them onto the shared path only if it does not change their behaviour.

**Execution note:** a shortened spinner still spins and a faster slide still slides. Reduce Motion compliance is decided by what the frame does, so verify the representative transform, scroll, and repeating paths by observation on the dev lane as well as by test.

**Test scenarios:**
- Each motion role returns its documented duration with Reduce Motion off.
- With Reduce Motion on, a scale change applies with no interpolation.
- With Reduce Motion on, an offset or position change applies with no interpolation.
- With Reduce Motion on, a transition resolves to opacity-only.
- With Reduce Motion on, a repeating animation stops rather than shortening.
- With Reduce Motion on, a programmatic scroll is not animated.
- Every site in the step-2 inventory routes through the shared motion path or appears on the audited exception list. Assert as a source scan over the whole inventory — `withAnimation`, `.animation(`, animation constructors, and `repeatForever` — not over a single constructor name.

**Verification:** the full suite is green, and on the dev lane with Reduce Motion enabled no window element moves, scales, scrolls, or loops. A green suite alone does not close this unit; the observed pass is part of the evidence.

---

### U6. Appearance and accessibility pass

**Goal:** the change holds in both appearances and under the accessibility settings the brief names.

**Requirements:** R1, R2, R3, R3a, R7, R11, R12.

**Dependencies:** U1, U2, U3, U4, U5, U7.

**Files:**
- `native/MuesliNative/Sources/MuesliNativeApp/MuesliTheme.swift` — the Increase Contrast path from R3a
- `native/MuesliNative/Sources/MuesliNativeApp/InsightsShareView.swift` — the `.regularMaterial` violation at line 109
- `native/MuesliNative/Tests/MuesliTests/` — boundary tests

**Approach:**
1. Add the disabled ink step and the Increase Contrast hairline resolution from R3a. `MuesliTheme` has no contrast path today, so this is new code, not a verification-only step.
2. Move `InsightsShareView.swift:109` off `.background(.regularMaterial)` onto an opaque theme surface, then add a boundary test covering every glass mechanism — `NSVisualEffectView`, SwiftUI `Material` styles, and blur modifiers. A gate written against `NSVisualEffectView` alone passes today's known violation, which is how the violation survived.
3. Add a boundary test asserting the floating-surface palette constants still hold their shipped values — this is R12, and it converts the ownership boundary from a convention into a gate.
4. Walk the built app on an isolated dev lane in light and dark, then under Reduce Transparency, Increase Contrast, and Reduce Motion.

**Test scenarios:**
- No main-window view references `NSVisualEffectView`, a SwiftUI `Material` style, or a blur modifier.
- The Insights share sheet renders on an opaque surface.
- `DictationMiniPalette.glassTintHex`, `accentHex`, `successHex`, and `failureHex` hold their shipped values.
- With Increase Contrast off, the hairline resolves to its preserved 7 % dark and 8 % light values.
- With Increase Contrast on, the hairline resolves to 80 %.
- The disabled ink step resolves below the tertiary step in both appearances.

**Verification:** the full suite is green and the dev-lane walk finds no unreadable text, no coral destructive control, and no circular-curve surface. Record what was walked; an unwalked appearance is not a passed one.

---

## Verification Contract

- Focused tests during development, then the full suite:
  `swift test --package-path native/MuesliNative --scratch-path <resolved muesli-spm path>`
  Resolve the scratch path through `scripts/muesli_spm_cache.sh` rather than letting SwiftPM grow a `.build` inside this worktree.
- Visual verification on an isolated lane: `./scripts/dev-test.sh --lane A`. This builds `MuesliDevA.app` with its own bundle ID and support directory and never touches production data.
- Boundary gates that must pass before the work is done:
  - no glass or blur under the main-window views, covering `NSVisualEffectView`, SwiftUI `Material` styles, and blur modifiers (R11);
  - the floating-surface palette constants unchanged (R12);
  - no `.system(size:)` applied to a text run in a main-window view, with SF Symbol sizing excluded from the scan (R9);
  - no default-curve `RoundedRectangle` in a main-window view (R7);
  - every main-window animation site — `withAnimation`, `.animation(`, animation constructors, `repeatForever` — routes through the shared motion path or sits on the audited exception list (R8a).
- The palette pins in `FloatingIndicatorStyleTests.swift` are updated deliberately in the unit that changes each value, never deleted to make a suite green.

## Definition of Done

**Global**

- All seven units are complete and the full native suite passes.
- The built app has been walked in light and dark, and under Reduce Transparency, Increase Contrast, and Reduce Motion, with what was walked recorded.
- The diff touches no floating-surface palette or rendering file.
- No control changed position, label, or behaviour.
- Dead ends are removed. A wide mechanical sweep accumulates half-migrated helpers and abandoned shims; none remain in the diff.

**Per unit**

- U1: warm ramps land with no colour call-site churn outside the theme and its tests.
- U2: every site of `recording`, `transcribing`, and `accent` has been classified, no destructive or validation site reads the recording token, and no state colour follows the accent preset.
- U3: the radius scale has one owner and the source scan passes.
- U4: text, symbol, and monospaced sites are classified; Inter resolves in a built bundle; the system-font fallback is proven rather than assumed; no SF Symbol was forced through a text helper.
- U5: every accent resolution path behaves, Dark survives a round trip as a real override, and a config written by the shipping version renders unchanged after migration.
- U7: the animation inventory is complete and gated; under Reduce Motion no window element moves, scales, scrolls, or loops, verified by observation on the dev lane and not by duration assertions alone.
- U6: the Increase Contrast path exists and both boundary gates are enforced by tests, not by convention.
