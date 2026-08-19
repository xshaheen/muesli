# Monologue 1.4.2 "FollowerKit" — reverse-engineering notes (19-08-2026)

Source: strings and Swift metadata of the locally installed `/Applications/Monologue.app` (bundle `com.zeitalabs.jottleai`, 1.4.2). No code was executed or decompiled; these are type/field names, log strings and UI copy. Used as a behavioural benchmark for the Muesli Dictation Mini, not as an asset source.

## What their Mini is

- Indicator styles: `mini` (caret follower), `classic` (docked at the screen edge), `none`. Each has an idle toggle:
  - Mini: *"Keep Mini's idle dot near your text context when you're not dictating. Turn off to only show it while recording or processing."*
  - Classic: *"Keep Classic docked at the screen edge when you're not dictating…"*
- So the idle dot is **persistent while a text context exists**, not a timed reminder. It is suppressed during activity and can be snoozed (`followerIdleIndicatorHiddenUntil`, `scheduledHideUntil`, `restoreTimer`).
- Follower state (`FollowerState`): `phase, mode, activity, isHandsFree, level, averagePowerDb, isUserTyping, isScrolling, caretRect, caretFieldRect, caretTier, windowRect, windowPinSlot, isWindowMoving, visibleRect, pointerAnchor, modePicker, toast, hoverMenu, dictionaryAction, hasSelection, selectionHint`.
- Controller monitors: `pollTask` + `AsyncCoalescer`, `mouseMonitor`, `localMouseMonitor`, `keyMonitor`, `scrollMonitor`, `escapeMonitor`, `spaceMonitor`, `swipeMonitor` (`isSpaceSwipeActive`, `swipeFallbackTask`), `typingResetTask`, `scrollResetTask`, `windowMoveResetTask`. → hide while typing / scrolling / window moving / Space swipe; Escape hides; re-show after the reset tasks fire.
- Interaction: hover menu (Add/Remove from dictionary), mode picker, hotkey keycaps (`FollowerKeyCapsView`), recording controls (toggle/stop/cancel), drag to a window **pin slot** (`windowPinSlot`, `View+Pinned`), selection hint (*"Hold while speaking to rewrite selected text or draft at the cursor. Release to apply."*), toasts (*"Hands-free mode enabled"*).
- Skin: `MonophoneSkin` with `CaretDotView` (idle dot), `SpikeWaveView`/`SpikeEngine` (`bars, sparks, quiet, sparkCarry, lastFrame, seed` — a seeded spike/spark waveform), `FloatingGradientView`, `RecordingControlButton`.

## How they find the caret (`CaretLocator`)

- Tiers (`CaretTier`): `caret → char → charPrev → chromium → marker → empty → field → mouse → none → bottom`.
- Log strings: "no Accessibility trust", "no focused element", "not a text input", "drilled" (they drill into the focused element's children to find the text input), "no caret bounds".
- Editability in web content: `AXEditableAncestor`, `AXHighestEditableAncestor`; per-app role hints `caretHostingRolesByBundleId`.
- Chromium: `AXManualAccessibility` (forces Chrome/Electron to build the AX tree), `AXScreenPointForLayoutPoint`; `ChromiumAccessibility`, `ChromiumCaret` types.
- WebKit: `AXSelectedTextMarkerRange`, `AXBoundsForTextMarkerRange`, `AXTextMarkerForIndex`, `AXTextMarkerRangeForUnorderedTextMarkers`.
- Hysteresis: `heldCaret`, `lastCaretAt`, `noCaretStreak` (a few empty polls before hiding); `PointerLocator` / `WindowLocator` / `FrontWindow` for the mouse and window fallbacks; `FollowerScreenManager` for multi-display.

## Adopted in Muesli (19-08-2026)

- `AXManualAccessibility` set once per focused process (caret provider + focus monitor).
- WebKit text-marker caret tier after the range-based tiers.
- `AXEditableAncestor` counts as editable for the reminder's text-input test (with a settable value).

## Deliberately not adopted (decisions, not gaps)

- Mouse-position fallback (`mouse` tier) — rejected earlier: pointer position is unrelated to keyboard dictation context.
- Persistent idle dot — the user asked for a 3 s reminder; switching to Monologue's persistent-with-suppression model is a product decision, see feedback.
- Hover menu / pin slots / selection hint / keycaps — outside the Mini's current scope.
