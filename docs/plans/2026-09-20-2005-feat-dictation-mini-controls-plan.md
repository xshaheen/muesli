---
title: "feat: Make dictation Mini quieter and recovery actionable"
date: 2026-09-20
type: feat
depth: lightweight
execution: code
artifact_contract: x-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: x-plan-bootstrap
---

# Dictation Mini controls and destination feedback

## Goal Capsule

Keep dictation feedback visible while the user browses and switches apps, make retained text easy to recover, and let users hide idle feedback per app. The idle dot follows text context; active capture follows the mouse. Automatic restoration of an original text field remains outside this change.

## Product Contract

### Problem Frame

The idle dot cannot currently be hidden for one app. A completed dictation whose target app changed is retained, but its warning provides no direct way to use it. A recording indicator that follows focus can imply that its paste destination moved too.

### Requirements

- R1. Offer “Hide idle dot in this app” for an identifiable external application. Persist bundle IDs with an empty default and snake_case encoding. Settings must allow restoring each excluded app. Exclusion affects idle presentation only.
- R2. When the existing target-change failure retains a history record, offer Copy and Open dictation for that exact record. Copy requires a deliberate click; opening is the only action that activates the dashboard. Dismiss, timeout, teardown, and a new session invalidate recovery actions. Keep at most one recovery item and do not log its content.
- R3. During preparation or recording of a standard paste session, switching away from the captured destination app briefly shows “Return to [app] to paste”. Voice notes and streaming sessions do not show destination hints. Returning clears the hint and permits a future departure hint. Processing and terminal states clear destination hints. No automatic app activation or paste retargeting.
- R4. Preserve hotkey-to-audio latency, existing paste policy, display-edge avoidance, reduced-motion behavior, and session identity guards. Reuse activation notifications and the existing hint panel.
- R5. Preparing and recording feedback must follow the mouse across scrolling, windows, Spaces, and displays without requiring editable focus. Idle feedback remains near editable text. Processing and recovery retain the last mouse position so their controls remain usable.

### Key Decisions

- KD1. Extend the current Mini rather than add a separate recorder mode. Governs R1, R2, R3, R4, R5. The existing dot, waveform, hints, and terminal lifecycle already provide the required surface.
- KD2. Keep the existing delivery contract. Governs R2, R3, R4, R5. Moving recording feedback with the pointer does not change the original insertion destination.

## Planning Contract

- KTD1. Store excluded bundle IDs in config, bound and normalize them, and evaluate visibility against the current external app on activation and config changes. Keep context-monitor lifecycle separate from the recording lifecycle.
- KTD2. Pass the saved record identity through the existing lifecycle recovery action. Resolve Copy/Open from that identity at click time so deleted records cannot produce stale output. Use a nonactivating panel and generation-guarded callbacks with an explicit dismiss control and bounded lifetime.
- KTD3. Capture destination app identity with the Mini session and evaluate activation changes on the main actor. Hint ownership must be explicit so clearing a destination hint cannot erase a newer hands-free or selection toast.
- KTD4. Active tracking samples the local mouse position at 30 Hz instead of querying Accessibility. Keep one timer and an App Nap exemption only during capture, release both on teardown, and restore visibility on app/Space changes. Place the surface 12 points clear of the pointer, flipping around display edges.

## Implementation Units

### U1. Per-app idle visibility

**Requirements:** R1, R4; KD1. **Dependencies:** none.

**Files:** `native/ImlaNative/Sources/ImlaNativeApp/Models.swift`, `SettingsView.swift`, `ImlaController.swift`, `DictationMiniIndicatorController.swift` in the same directory; `native/ImlaNative/Tests/ImlaTests/ModelsTests.swift`, `DictationMiniIndicatorTests.swift`.

**Approach:** Extend the existing idle menu and config update path. Render removable exclusions beneath the idle-dot setting. Continue active recording feedback in excluded apps.

**Test scenarios:** Missing and malformed config values preserve defaults; exclusions round-trip under snake_case; app switching suppresses and restores idle state; active recording remains visible; restoring an exclusion immediately takes effect.

### U2. Actionable saved-dictation recovery

**Requirements:** R2, R4; KD1, KD2. **Dependencies:** none; sequence after U1 because controller files overlap.

**Files:** `native/ImlaNative/Sources/ImlaNativeApp/DictationLifecycleFeedback.swift`, `DictationMiniIndicatorController.swift`, `DictationMiniHintPanel.swift`, `ImlaController.swift`, `AppState.swift`, `DictationsView.swift` in the same directory; `native/ImlaNative/Tests/ImlaTests/DictationLifecycleFeedbackTests.swift`, `DictationMiniIndicatorTests.swift`.

**Approach:** Add actions to the existing hint surface, associate them with one retained record, and reuse dashboard navigation and clipboard helpers. Use a readable saved-to-history message, a primary Copy action, a compact Open action, and an accessible icon-only dismissal. Measure the text field and stack controls on narrow displays. Saved recovery uses an amber tray cue; other failures retain failure feedback.

**Test scenarios:** Only the foreground failed session produces recovery; Copy/Open identify the retained record; callbacks from an old session do nothing after a new session, dismissal, or teardown; deleted records do not copy unrelated text; buttons are interactive while ordinary hints remain mouse-transparent.

### U3. Destination awareness

**Requirements:** R3, R4; KD1, KD2. **Dependencies:** U2 for shared hint ownership.

**Files:** `native/ImlaNative/Sources/ImlaNativeApp/DictationMiniIndicatorController.swift`, `ImlaController.swift`; `native/ImlaNative/Tests/ImlaTests/DictationMiniIndicatorTests.swift`.

**Approach:** Reuse the app activation observer and captured destination identity, show once per departure, clear on return or lifecycle transition, and move visible hints with the Mini.

**Test scenarios:** Same app produces no hint; leaving produces one; repeated unrelated activations do not spam; returning clears it; leaving again permits another; processing/new sessions clear old destination state; clearing a destination hint preserves an unrelated toast.

### U4. Follow the mouse during active capture

**Requirements:** R4, R5; KD1, KD2. **Dependencies:** U2 and U3.

**Files:** `native/ImlaNative/Sources/ImlaNativeApp/DictationMiniIndicatorController.swift`, `DictationMiniPlacement.swift`, `DictationCaretAnchorProvider.swift`; `native/ImlaNative/Tests/ImlaTests/DictationMiniIndicatorTests.swift`, `MeetingRecordingPanelTests.swift`.

**Approach:** Replace active caret resolution with local pointer sampling while preserving the idle text-context monitor. Keep the active panel visible on deactivation, reassert it on workspace changes, and retain its final anchor after capture. Remove the now-unused active caret resolver.

**Test scenarios:** Pointer movement without a focused text field moves the indicator; typing/scrolling/window activity does not hide recording; app/Space visibility restoration reorders the panel; both displays and all display edges preserve a clear click target; tracking and its activity token end at processing or teardown; dictation feedback cannot mutate the meeting panel.

## Verification Contract

Run focused Models, DictationLifecycleFeedback, and DictationMiniIndicator suites, plus the independent meeting-panel routing test, using a nonconcurrent SwiftPM scratch path. Build all affected app sources through those tests. Inspect nonactivating panel layout and action wiring; live cross-app typing/Space behavior must be reported separately if not exercised.

## Definition of Done

All behaviors are wired to the real controller and settings, focused tests pass, old configs decode, action lifetime is bounded and guarded, and the diff contains no delivery-policy changes or new network paths. Report any unavailable runtime verification explicitly.

## Sources

- Monologue launch email, August 25, 2026, “Meet Dot: Monologue's new recorder”; public announcement: https://x.com/usemonologue/status/2092272951584580045.
- Current indicator documentation: https://www.monologue.to/docs/dictation/mac-preferences.
- Existing Mini controller, text-context monitor, lifecycle feedback, and standard dictation delivery path in `native/ImlaNative/Sources/ImlaNativeApp/`.
