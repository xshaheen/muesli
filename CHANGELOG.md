# Dev Branch Changelog

This file lists unreleased features and changes in `xshaheen/dev` compared with
upstream `main`.

## Unreleased — 11-08-2026

### Meeting intelligence, audio reliability, and floating UI

#### Features

- Added multi-turn meeting chat to the Responses client and all six supported summary backends.
- Added a shared meeting-chat conversation model and a chat surface available both during and after meetings.
- Added one-tap meeting-chat recipes and access from the floating panel, so questions can be asked without leaving a call.
- Added raw and cleaned transcript storage as separate records; the original remains the durable, editable source.
- Added a single display-transcript accessor so chat, transcript views, search, and re-summarization consistently prefer a valid cleaned transcript.
- Added opt-in meeting transcript cleanup, disabled by default, with destination-aware privacy disclosure.
- Added chunked, all-or-nothing cleanup for finalized transcripts. Provider completion state, immutable structure, unit markers, and length checks prevent partial cleanup from replacing the original.
- Added mixed-language transcript repair and a mixed-language dictation preset for meetings that combine languages such as Arabic and English technical terms.
- Added notes regeneration from cleaned transcripts, preserving the original screen context and follow-up continuity, plus launch-time recovery for interrupted regeneration.
- Added microphone failover when a selected meeting microphone is silent.
- Made the floating transcript independently positioned and deliberately persistent until the user closes it.
- Added a three-tab floating panel for transcript, chat, and notes, with a meeting-pill toggle.
- Added speaker-dictionary context to cleanup requests and Whisper prompt conditioning.
- Added automatic unloading of idle cleanup models after 15 minutes.
- Added a backend residency policy, shared Nemotron captions, bounded streaming queues, and memory-pressure handling to prevent model and audio-buffer accumulation.
- Added a launch-time warming indicator while transcription models preload.
- Reordered meeting-pill controls, made the waveform non-interactive, and added menu-bar control over floating-button visibility.
- Added privacy-safe OpenAI request behavior for meeting chat and summaries by disabling server-side response storage.
- Added lightweight meeting-list and active-banner projections to avoid hydrating full transcripts for summary UI.
- Added asynchronous model deletion after unloading the resident model.
- Added test-shard assignments for the expanded native test suite.
- Added placement diagnostics for the floating pill and panel.

#### Changes and fixes

##### Meeting chat and transcript cleanup

- Fixed follow-up chat transport by using the correct role-specific Responses API history types; trimming now preserves the grounding instructions and evicts complete exchanges.
- Fixed chat availability and credential handling across configured credentials and supported environment variables.
- Fixed stale chat configuration by resolving the selected backend and credentials at send time.
- Fixed failed questions being replayed as unanswered history and orphaned assistant turns being sent after history trimming.
- Fixed hidden floating panels retaining keyboard focus across close, hover-out, reset, and meeting-stop paths.
- Fixed unavailable Chat mode leaving a blank pane; it now falls back to Notes.
- Fixed meeting deletion and “clear all” leaving chat conversations resident in memory.
- Fixed chat panels closing on internal clicks or pointer exit while composing; outside-click dismissal remains available.
- Fixed raw Markdown rendering in chat, added per-answer copy behavior, and made the panel copy action follow the visible tab.
- Fixed chat omitting the user's manual notes from model context and made notes resolve at send time.
- Fixed assistant follow-up history being encoded as `input_text`; assistant history now uses `output_text` as required by the Responses API.
- Fixed OpenAI meeting chat retention by explicitly opting requests out of server-side storage.
- Fixed unbounded in-memory meeting-chat history with a bounded conversation cache.
- Fixed cleanup token budgets on Ollama and Anthropic, surfaced ChatGPT truncation, and rejected redirects that could move transcript content to another destination.
- Fixed cleanup output that lost spacing when sentences were split across lines.
- Fixed duplicated chat state and dead toggle handlers by making the controller the single source of panel state.
- Fixed cleaned-notes provenance so `notes_source` remains truthful, and made regeneration failures observable.
- Fixed notes regeneration overwriting real notes with a raw-transcript fallback when no usable summary backend is configured.
- Fixed notes regeneration getting stranded when destination-scoped cleanup consent is automatically revoked.
- Fixed cleanup consent surviving a destination change; consent is now bound to the disclosed destination.
- Fixed OpenAI meeting summaries retaining server-side responses.
- Fixed meeting cleanup and live partials admitting short bare-digit or punctuation-only silence hallucinations while preserving numeric dictation.

##### Meeting persistence, sync, and recording integrity

- Fixed system-audio callbacks racing stop/teardown and writing after WAV finalization.
- Fixed one-sided recording backlogs by draining against bounded zero-fill, preserving alignment without unbounded memory growth or duplicate tails.
- Fixed failed and timed-out system-audio starts leaving capture active, and added recoverable device-change restart behavior with surfaced failures.
- Fixed resumed meetings losing prior recording alignment.
- Fixed microphone failover handoffs not being reported and handoffs abandoned during stop.
- Fixed timeline origin being stamped before preload completed.
- Fixed caption drops erasing the last durable transcript checkpoint.
- Fixed transcript timing invariants across repaired and resumed recordings.
- Fixed system-audio capture failures being silent to the meeting controller.
- Fixed 16 detached meeting updates being able to resurrect soft-deleted records.
- Fixed dictation streaks using UTC-style buckets instead of the local-day semantics shown in Insights.
- Fixed SQLite text/blob bindings relying on temporary pointers instead of `SQLITE_TRANSIENT`.
- Fixed the SQLite leak probe for portability and parallel test execution.
- Fixed manual-note Markdown ranges mixing grapheme counts with UTF-16, which truncated emoji-bearing lines.
- Fixed meeting list metadata wrapping onto multiple lines, template chips collapsing to icons, and toolbar/content misalignment.

##### Calendar, CLI, Computer Use, and model/runtime reliability

- Fixed Google Calendar 401 recovery exiting pagination as a successful empty result and wiping cached events; token refresh is now forced and the same page is retried.
- Fixed concurrent ChatGPT and Google auth refreshes racing the same refresh token.
- Fixed CLI summary configuration ignoring the app's snake_case keys.
- Fixed CLI help returning validation errors instead of actual help with exit status zero.
- Fixed planner-supplied non-finite or out-of-range numbers trapping integer conversions.
- Fixed Computer Use clicks ignoring button/count arguments, risky-action confirmation trusting only planner labels, and AppleScript pipe deadlocks above the pipe buffer.
- Fixed cursor-coordinate Y conversion on multi-display setups.
- Fixed Cohere transcription trapping on zero-frame audio.
- Fixed Cohere tail trimming deleting natural repeated interjections.
- Fixed interrupted Nemotron downloads being treated as complete by inconsistent cache checks.
- Fixed Gemma stale loads clearing another load's state or replacing a live engine without cleanup.
- Fixed live-caption download completion crossing actor boundaries unsafely.
- Fixed queued Qwen cleanup being reset mid-generation by moving reset before inference-gate release.
- Fixed streaming dictation leaking its recorder on stop.
- Fixed short-turn deduplication deleting both equally ranked copies instead of retaining the earliest.
- Fixed resident model deletion racing live model ownership by unloading before deleting files and moving file removal off the main actor.
- Fixed WhisperKit's `promptTokens` empty-transcription regression by pinning past the affected dependency version.
- Fixed staged app copies silently retaining a stale read-only LiteRT dynamic library.
- Fixed a stale upstream `isToggleDictation` reference on the Computer Use failure path.

##### Microphone routing

- Fixed automatic microphone routing preferring the built-in mic whenever headset output was connected. Auto now follows the system default input for dictation and meetings; explicit selections still override it.
- Fixed AirPods connection changes causing repeated microphone restart storms.
- Fixed hotkey setting edits and sub-threshold presses stopping an active meeting.
- Fixed a synchronous Nemotron stop path being overwritten back to Transcribing.

##### Floating pill and panel

- Fixed indicator resizes collapsing the expanded panel's union frame, which caused torn silhouettes, stray borders, and malformed pill corners.
- Fixed inline Markdown inside list items and headings rendering literal formatting markers.
- Fixed the pill drifting inward after hover expansion near a screen edge.
- Fixed panel shadows clipping into dark outlines and removed a frame-measurement feedback loop.
- Fixed the pill disappearing or teleporting when dragged during recording.
- Fixed click hit regions shifting with the Live/Paused label and chat/status clicks invoking the wrong action.
- Fixed preset anchors following `NSScreen.main` rather than the intended primary display, and fixed custom positions being re-derived during unrelated configuration or sync updates.
- Fixed drag persistence double-counting screen-edge clamps, display selection, and stale animation landings.
- Fixed transcript placement using an anchor-derived phantom instead of the pill's live frame.
- Fixed the panel flipping sides for tiny movements or overlapping the pill when neither side fit.
- Fixed saved custom origins overriding newly selected preset anchors.
- Fixed display topology changes leaving the pill and transcript stranded after monitor attach/detach.
- Fixed compact Chat mode painting over the panel's translucent material.
- Fixed child-window animation translating the transcript away from its resolved placement.
- Fixed `NSHostingView` content sizing asynchronously collapsing or relocating the transcript window.
- Fixed meeting-pill drag chrome, stop-glyph placement, waveform sizing, click geometry, cursor-mode transitions, and loading/warning state races.
- Fixed normal click jitter being interpreted as a drag and persisted as a new position.
- Fixed background configuration refreshes, iCloud sync, and loading states re-showing or teleporting dismissed meeting UI.
- Fixed loading, warning, and computer-use exits leaving stale panel lifecycle state.

##### Settings and editor behavior

- Fixed the custom audio picker blocking through a modal loop; it now uses a sheet.
- Fixed folder rename focus, blur-to-commit, and Escape-to-cancel behavior.
- Fixed Markdown toolbar edits lacking undo grouping and stripping paragraph terminators that were not present.

### Dynamic dictation Writing Styles

#### Features

- Added opt-in adaptive cleanup styles for standard dictation while preserving the existing global prompt for current users.
- Replaced fixed categories with an editable, group-first Writing Styles workspace containing starter and custom groups.
- Added exact app bundle-ID and hostname matchers, `*` wildcard matchers, and exact exceptions.
- Added deterministic local resolution: exact exception, hostname group, app group, global style, then built-in fallback.
- Added exact-over-wildcard and narrower-over-broader specificity ranking; unresolved equal-rank cross-group overlaps block Save.
- Added immutable per-dictation request snapshots. Target identity, style, prompt, backend, local model URL, vocabulary, and authorized context are frozen when recording starts.
- Added strict, versioned JSON import/export with deterministic output, bounded regular-file input, a replacement-only preview, and atomic persistence.
- Added one-time migration from legacy per-app/category rules into editable groups while preserving existing cleanup behavior.
- Added local dictation-history provenance for the selected style, selection source, and cleanup outcome without syncing this metadata to CloudKit.
- Added privacy-safe diagnostics and coarse allowlisted telemetry that exclude app identifiers, hostnames, URLs, prompts, transcripts, and other user content.
- Added local browser-host routing that keeps only the normalized hostname, never URL paths or queries, and never triggers OCR or a new permission prompt.

#### Changes and fixes

- Fixed cleanup requests reading mutable global state after recording stopped; each request now uses the complete start-of-session snapshot, including the pinned local model and speaker vocabulary.
- Fixed ambiguous matcher validation comparing specificity without exact/wildcard rank, which could reject or permit the wrong cross-group overlap.
- Fixed JSON import reading unbounded or unsafe file targets; import now accepts only bounded regular, non-symbolic-link files.
- Fixed import previews treating wildcard patterns as literal targets and comparing only style ID/prompt; previews now generate matching witnesses and compare the full resolved selection.
- Fixed configured exact matchers being absent from known-target previews and deduplication.
- Fixed edits made in the custom-style editor not counting as unsaved, allowing close/import/export before the edits were applied. Save now validates and atomically applies pending edits, and close/cancel behavior reflects them.
- Added accessible labels and hints for style instructions and preserved textual conflict feedback when Save is blocked.

### Cross-feature changes

- CloudKit system fields and local Writing Styles provenance coexist in the combined dictation upsert path. Style provenance remains local, survives same-text acknowledgements, and is cleared when remote text replaces the local text or the record is deleted.
- The meeting Markdown renderer keeps non-web links visible and inert while preserving heading, list, editor, and inline-formatting behavior.
