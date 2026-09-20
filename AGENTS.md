# Imla

Local-first macOS dictation and meeting transcription for Apple Silicon. Speech-to-text runs
on-device on the Neural Engine. Native Swift/AppKit — no Electron, no Python runtime, no cloud
STT bill.

- **Dictation:** hold a hotkey, speak, release; text is pasted at the cursor.
- **Meetings:** mic (You) + system audio (Others) → VAD chunking → diarization → AI notes.
- **Agent surface:** `imla-cli` speaks JSON over stdout for scripted transcription.

Maintained by **Shaheen** <mxshaheen@gmail.com> at `xshaheen/muesli`. This is a rebranded hard
fork of `Muesli-HQ/muesli`, which stays configured as the `upstream` remote for cherry-picks.
**Never push to `upstream`.** Work lands on `dev` via `xshaheen/<topic>` branches.

The rename from Muesli to Imla is complete for paths, modules, types, and everything the OS can
observe. Four things still carry the old name, each on purpose:

| Still `muesli` | Why it must stay |
| --- | --- |
| `muesli-cksyncengine-private-v1`, `muesli-text-records-sync-zone-v1` | **CloudKit zone and subscription IDs.** Renaming orphans every synced record. |
| `muesli.sync.bridge.*`, `.muesli-download-state.json` | Persisted keys and on-disk state. Renaming silently discards bridge identity and re-downloads every ASR model. |
| `iCloud.com.mueslihq.muesli` | Minting a new container needs an Apple Developer team this fork does not have. |
| `MUESLI_*` environment variables | The script API. An unrecognised variable is ignored, not rejected, so renaming breaks existing automation *silently*. Flip them deliberately or not at all. |
| `Muesli for iPhone` copy, `muesli://`, `Muesli-HQ/muesli-ios` | Name **upstream's** iOS companion app, which this fork does not rebuild. The iCloud bridge pairs with it. |
| `/Volumes/MuesliBuildCache`, `Muesli-HQ` | A physical volume on the maintainer's disk, and the upstream GitHub org. |

Test temp-directory prefixes (`muesli-nav-test-`, `muesli-chat-test-`, …) also still read `muesli`.
They are inert, and were left alone to keep an unverifiable rename as small as possible.

The GitHub repo is still `xshaheen/muesli`; only the product renamed.

## What decisions optimize for

When these conflict, the earlier one wins.

1. **Nothing leaves the machine unless the user asked it to.** Cloud summarization, telemetry,
   and calendar sync are opt-in and individually gated. A new network path needs explicit user
   consent, visible settings copy, and a test — not a default.
2. **Never lose a recording.** A meeting cannot be re-run. Prefer writing early, partial, and
   recoverable over writing once at the end. Finalization must not block on modal UI.
3. **Dictation latency is the product.** The hotkey→paste path is measured in milliseconds.
   Work added there — a main-thread hop, a synchronous file read, a model warmup — is a
   regression even when it is correct.
4. **It works with no account, no key, and no network.** Cloud backends are enhancements layered
   on a complete offline app, never the path that makes a feature function. Hosted dictation
   (OpenAI Realtime, OpenRouter) is one of those enhancements: it is opt-in, it falls back to a
   local backend, and selecting it is the only thing that sends dictation audio off the machine.
   Model downloads go straight to Hugging Face — no plan configures a mirror, because routing a
   user's downloads through someone else's bucket is a network path they never chose.

Two consequences worth stating, because they read as sloppiness until you know the reason:

- **A bounded poll beats an event stream you cannot reason about.** macOS 26 App Nap suspends
  every timer mechanism in an `LSUIElement` app; only `NotificationCenter` observers survive.
  Polls here carry an explicit interval, total window, work cap, and cancellation path by
  design. Replacing one with an observer is a behavior change, not a cleanup.
- **Passive detection stays conservative.** Meeting detection requires mic *and* camera *and* a
  recognized app. Weak global signals must not start a recording, prompt, or launch an app the
  user closed.

## Architecture

`native/ImlaNative/` is one SwiftPM package. Three targets carry the work (the rest are small
C-interop bridges and an app shell):

| Target | Role |
| --- | --- |
| `ImlaCore` | Storage and pure logic: SQLite (`DictationStore`), path resolution (`ImlaPaths`), model downloads, language routing, transcription-quality scoring. No AppKit. |
| `ImlaNativeApp` | The app. ~230 files. |
| `ImlaCLI` | `imla-cli`, JSON over stdout. |

Four files are the hubs; a change usually starts at one of them:

- `ImlaController.swift` — the orchestrator. Dictation, meetings, onboarding, app state.
- `TranscriptionRuntime.swift` — routes to ASR backends, post-processing, VAD, diarization.
- `MeetingSession.swift` — meeting lifecycle, capture, AEC, screen context.
- `Models.swift` — the config schema *and* `BackendOption`, the ASR model catalog.

`Models.swift` owns the config contract. Keys are **snake_case** on the wire
(`has_completed_onboarding`, not `hasCompletedOnboarding`); every new field needs a default and
a decode test, because old configs must keep loading.

`BackendOption` is the only list of ASR models. Read it rather than trusting any prose count of
"how many models Imla has" — that number has been wrong in every doc that hardcoded it.

## Conventions

- **Never hardcode the app's identity.** `AppIdentity` resolves display name, bundle name, and
  support directory from `Info.plist`, so the same binary runs as Imla, ImlaDev, or a named
  lane against separate data. Paths go through `AppIdentity.supportDirectoryURL` or
  `ImlaPaths`. A literal `"Imla"` in a path is a bug.
- **Pull decisions out of views.** Geometry, state machines, and detection logic live in
  `nonisolated static` helpers or plain structs so they are testable without a window or a run
  loop. `MeetingRecordingPanelController`'s geometry helpers are the model to copy.
- **Bound every long-lived collection.** Transcript chunks, audio buffers, AX snapshots, caches,
  and pending-sync lists need a cap, a window, or a lifecycle teardown. Timers, observers, taps,
  and tasks are cancelled on teardown.
- **Guard state writes from layout callbacks.** Unconditional `@State` writes from
  `GeometryReader`, `onPreferenceChange`, or animation completions have caused a real
  invalidation loop here: 100% CPU and multi-GB growth. Guard by equality, threshold, or
  identity.
- **Check session identity before applying async results.** Stale callbacks mutating a newer
  recording is this repo's most repeated bug class.
- **Log metadata, never content.** Counts, durations, state names, reason codes, non-content
  IDs. Never transcript text, dictated text, clipboard or screen contents, keys, or tokens.
  Telemetry routes through `scripts/imla_telemetry_channels.sh`; do not hardcode app IDs.
- **Comments carry the reason,** not a restatement of the code and not a plan or ticket ID.

## Build and test

`make help` lists the targets and is the source of truth; the Makefile is a thin wrapper over
`scripts/`, so it cannot drift from them. What the commands do not tell you:

- **Build target follows the user's request.** "Build the test/dev version" means
  `/Applications/ImlaDev.app`; "build the real/production app" means
  `/Applications/Imla.app`. Use `ImlaDevA`, `ImlaDevB`, `ImlaDevC`, or another named
  lane only when the user explicitly requests that lane, including during parallel work.
- **Signing.** Release identity is resolved at recipe time: explicit `SIGN_IDENTITY=` wins, then
  the configured identity, then the keychain's first codesigning identity. Entitlements follow —
  a non-Developer-ID cert cannot back the iCloud/CloudKit entitlements without a provisioning
  profile, so those builds sign with `scripts/ImlaLocalOnly.entitlements` and iCloud sync is
  off. Use `MUESLI_SKIP_SIGN=1` for ordinary local verification.
- **Dev builds are isolated by design.** `./scripts/dev-test.sh` installs `ImlaDev.app`
  (`com.xshaheen.imla.dev`, data under `~/Library/Application Support/ImlaDev/`). Production data is
  never touched. `--lane A|B|C` gives parallel worktrees separate bundles, data, and TCC
  identities; grant permissions once per lane and do not reset TCC unless you are testing the
  prompts themselves.
- **The rename orphaned pre-Imla data; nothing migrates automatically.** A build from before the
  rename wrote to `~/Library/Application Support/Muesli/muesli.db`; this one reads
  `~/Library/Application Support/Imla/imla.db`. To carry history across, move it once by hand
  before first launch:
  ```bash
  mv ~/Library/Application\ Support/Muesli ~/Library/Application\ Support/Imla
  cd ~/Library/Application\ Support/Imla && for f in muesli.db*; do mv "$f" "imla.db${f#muesli.db}"; done
  mv ~/.cache/muesli ~/.cache/imla        # keeps the downloaded ASR models; otherwise they re-download
  ```
  ChatGPT and Google OAuth tokens do **not** come across — they live in the Keychain under the
  old service name and must be re-authenticated. macOS also treats Imla as a new app, so every
  TCC permission is granted again from scratch.
- **SwiftPM scratch paths are shared, not package-local.** `scripts/imla_spm_cache.sh` resolves
  them, so worktrees do not each grow a multi-GB `.build`. Concurrent builds must not share one
  path — give each channel, agent, or simultaneous build its own.
- **LocalVQE gates signed packaging.** Meeting AEC defaults to LocalVQE, whose dylibs are
  gitignored. `build_native_app.sh` refuses *signed* packaging without a complete runtime; build
  it once with `./scripts/build_localvqe.sh`, or stay unsigned.
- **This fork ships nothing and updates from nothing.** Notarized release needs a Developer ID
  certificate it does not have, so `scripts/release*.sh` cannot complete. Builds omit `SUFeedURL`
  entirely rather than inheriting upstream's appcast, which would have updated a fork build into
  upstream's binary. `MUESLI_SPARKLE_FEED_URL` and `MUESLI_SPARKLE_EDKEY` re-enable updates and
  must be set together — the build refuses a feed without a key.
- **Shipped builds go through xcodebuild,** not SwiftPM, because App Intents metadata only
  extracts for a real Xcode application target. Needs `xcodegen` and full Xcode.
  `MUESLI_USE_XCODE_BUILD=0` is the escape hatch and ships without Shortcuts support.
- **The toolchain floor is Xcode 26.6 / macOS 26,** because MLX Swift needs Swift 6.3. That is
  what building natively and running the full test suite require; the app's deployment target is
  still macOS 14.2. Builds and test shards pin `--build-system native`: the default engine stages
  every binary target's headers into one flat `include/`, where two vendored xcframeworks'
  module maps collide.
- **CI is Linux-first for anything it can run there.** Agents on Linux cannot build the app or
  run `swift test`. They can run the whole `classifier-tests` job:
  `test_classify_changed_files.sh`, `test_ci_test_shards.sh`, `test_merge_appcast_item.py`, and
  `test_localvqe_runtime_validation.sh`, plus `test_verify_cloud_entitlements.py`. Swift tests
  are sharded (`core`, `dictation-transcription`, `meetings`) — a new suite must be assigned a
  shard in `run_ci_test_shard.sh`, not appended to `ci_unsharded_test_suites.txt`.

## Traps macOS will not warn you about

- **Accessibility permission needs an app restart** to take effect. Onboarding handles this with
  a detached-shell relaunch; `NSApp.terminate(nil)` inside a SwiftUI animation context crashes.
- **`NSHostingView` drives its window's frame by default.** Any controller that owns its own
  window frame must set `hostingView.sizingOptions = []`, or SwiftUI's async content pass will
  silently re-place the window after every `setFrame`. This was misdiagnosed as three separate
  window-attachment bugs before the real cause was found.
- **`NSSavePanel` must use `beginSheetModal(for:)` in SwiftUI.** `runModal()` deadlocks, and so
  does `NSAttributedString(html:)` on the main thread — build attributed strings manually.
- **Timers are unreliable in this app.** See App Nap, above. Calendar notifications hang off
  `EKEventStoreChangedNotification` for exactly this reason; the 60s poll is a fallback that may
  never fire.
- **`CGWindowListCreateImage` conflicts with an active `SCStream`.** Meetings default to the
  CoreAudio tap (`use_core_audio_tap`), which has no such conflict and uses audio-capture TCC
  instead of Screen Recording — that is why screenshot-based screen context works during
  meetings again. The `SCStream` recorder survives behind the flag; the conflict returns with it.

## Reference

| Read when | File |
| --- | --- |
| Reviewing a change, or judging a finding's severity | `REVIEW.md` |
| Setting up a contributor environment, or the DCO and AI-disclosure rules | `CONTRIBUTING.md` |
| Changing the SQLite schema | `database-schema.md` |
| Driving the app from a script or agent | `skills/imla-agent/references/cli-contract.md` |

Subsystem behavior is documented **in the source**, next to the code that implements it —
language routing, reverse-leak suppression, panel geometry, and the WhisperKit revision pin all
carry their reasoning in-file. Read the file, not a summary of it; every prose copy of those
details in this repo had gone stale against the code by the time it was noticed.

Working notes do not belong in the repo root. Durable rationale goes in the commit message, in
this file, or beside the code it explains.
