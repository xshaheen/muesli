# Settings information architecture — current inventory and proposed map

Implementation-facing companion to `spark-app-system-01.html`. Line references are against
`native/MuesliNative/Sources/MuesliNativeApp/SettingsView.swift` at the time of writing
(3,448 lines, 6 panes defined by `SettingsPane` in `AppState.swift:23`).

## 1. Defects this reorganisation fixes

| # | Defect | Evidence |
|---|---|---|
| D-1 | AI provider credentials are configured in **four** places for the same six providers | `dictationCleanupSettingsSection` (937), `meetingSummarySettingsSection` (1219), `meetingTranscriptCleanupSection` (1195), `computerUseSettingsPane` (1435) |
| D-2 | Language is configured in **three** places | `languageProfileSettingsSection` (745), Nemotron `prompt_id` picker in `ModelsView.swift`, Cohere language card in `ModelsView.swift` |
| D-3 | Model **download** and model **selection** are in different tabs | `ModelsView.swift` vs `dictationModelSettingsSection` (719) vs `meetingTranscriptionSettingsSection` (841) |
| D-4 | A segmented picker carries panes of wildly unequal weight | `settingsPanePicker` (504); Meetings holds 8 sections / ~25 rows, Sync holds 2 rows |
| D-5 | Appearance is a junk drawer | `appearanceSettingsPane` (1684): theme, menu-bar icon, hotkey display, accent, sounds, idle dot, next meeting, Marauder's Map |
| D-6 | Four curated collections have no navigation home | `WritingStylesView` (sheet, `SettingsView.swift:370`), `MeetingTemplatesManagerView` (sheet, `MeetingsView.swift:250`), `TranscriptCleanupPromptsManagerView` (sheet), `DictionaryView` (tab) |
| D-7 | Insights has **no sidebar entry** | `SidebarView.swift:106-116` lists dictations, meetings, dictionary, models, shortcuts, settings, about; `.insights` is reachable only via `StatsHeaderView.swift:44` |

## 2. Proposed sections

Settings surface (sidebar, 9 sections):

1. **General** — launch at login, open dashboard on launch, dock visibility, menu bar (icon
   style, show hotkey, show next meeting), sound effects, iOS companion prompt, updates.
2. **Dictation** — hotkeys summary, microphone + priority order, indicator & idle dot,
   save dictation recording, pause/mute media during dictation, cleanup on/off + assignment
   link, dictionary suggestions.
3. **Meetings** — recording (auto-record, floating Record button, save recording, format),
   notes & default template, notifications, calendars, auto-export.
4. **Models & Languages** — downloads and updates, dictation model, meeting live model,
   meeting final-transcript source, per-model language pickers (Nemotron `prompt_id`, Cohere),
   spoken languages, dominant language, save profile.
5. **AI Providers** — *registry*: ChatGPT OAuth, OpenAI, OpenRouter, Ollama, LM Studio, Custom.
   *Assignments*: dictation cleanup, meeting summaries, meeting transcript cleanup, computer use.
6. **Shortcuts** — every hotkey in one table (absorbs the `Shortcuts` tab).
7. **Privacy & Data** — permissions, app context, screen OCR context, iCloud sync, retention,
   session diagnostics, clear dictation/meeting history.
8. **Appearance** — theme, accent, density, Marauder's Map.
9. **Advanced** — computer use planner, post-meeting hooks, experimental, backup & restore.

Main window sidebar (content only):

```
Dictations · Meetings · Insights
Library: Dictionary · Styles · Templates · Prompts
Settings · About
```

## 3. Row-by-row map

| Current location | Rows | Destination | Note |
|---|---|---|---|
| General › Launch at login, Open dashboard on launch | 2 | General | unchanged |
| General › Clear dictation / meeting history | 2 | Privacy & Data | |
| General › Session diagnostics | 1 | Privacy & Data | |
| General › Permissions (2114) | section | Privacy & Data | |
| Sync › Private iCloud sync | 1 | Privacy & Data › Sync | |
| Sync › Show iOS companion prompt | 1 | General | it is a prompt preference, not sync |
| Dictation › Spoken languages, Dominant language, Save profile | 3 | Models & Languages | joins the two stranded per-model pickers |
| Dictation › Dictation model | 1 | Models & Languages | selection beside download |
| Dictation › Microphone | 1 | Dictation › Audio | add priority order with fallback (VoiceInk pattern) |
| Dictation › Save dictation recording | 1 | Dictation | |
| Dictation › AI transcript cleanup (toggle) | 1 | Dictation | body of the prompt moves to Library › Prompts |
| Dictation › Dictionary suggestions | 1 | Dictation | |
| Dictation › Cleanup backend / Account / API key / Model / URL ×6 | ~14 | **AI Providers** | one row survives in Dictation: "Cleanup uses …" |
| Dictation › Pause media, Mute system audio | 2 | Dictation › Audio | audio-session behaviour, not "advanced" |
| Dictation › App context, Screen OCR context | 2 | Privacy & Data | both read the screen |
| Computer Use › Enable, Account, Planner model, Timeout | 4 | Advanced (credentials → AI Providers) | |
| Meetings › Meeting context | 1 | Privacy & Data | |
| Meetings › Default template, Summary retries, Templates… | 3 | Meetings › Notes | manager sheet → Library › Templates |
| Meetings › Auto-record, Floating Record button, Save recording, Format | 4 | Meetings › Recording | unchanged |
| Meetings › Auto Export | 4 | Meetings › Export | unchanged |
| Meetings › Notifications | 4 | Meetings › Notifications | unchanged |
| Meetings › Calendars, Google Calendar | 2 | Meetings › Calendars | unchanged |
| Meetings › Meeting model, Final transcript | 2 | Models & Languages | all three model choices in pipeline order |
| Meetings › Transcript cleanup, Summary backend + Account/Key/Model ×7 | ~16 | **AI Providers** | |
| Meetings › Post-meeting hook, Script, Timeout | 3 | Advanced › Automation | |
| Appearance › Dark mode, Accent colour | 2 | Appearance | see decision D2 |
| Appearance › Menu bar icon, Show hotkey, Show next meeting | 3 | General › Menu bar | |
| Appearance › Play sound effects | 1 | General › Feedback | sits with the lifecycle cues it gates |
| Appearance › Idle dot near your text | 1 | Dictation › Indicator | dictation behaviour with a visual side effect |
| Appearance › Marauder's Map | 2 | Appearance › Extras | unchanged |
| `Models` tab | view | Settings › Models & Languages | |
| `Shortcuts` tab | view | Settings › Shortcuts | |
| `Dictionary` tab | view | Library › Dictionary | curated content stays in the main window |
| Writing Styles (sheet) | view | Library › Styles | |
| Meeting Templates (sheet) | view | Library › Templates | |
| Cleanup Prompts (sheet) | view | Library › Prompts | |
| Insights (orphaned) | view | Main sidebar | |

Net: ~30 provider rows collapse to 6 provider entries + 4 assignment rows. The Meetings
section drops from ~25 rows to ~14. Nothing is removed; three sheet-only collections and one
orphaned view gain a navigation home.

## 4. Config-key implications

The credentials registry (decision D5, option 1) needs a tolerant migration: read the four
existing provider key sets, write one registry plus four assignment keys, and keep decoding
the legacy keys for at least one release — the same pattern already used for
`show_dictation_focus_reminder` → `show_dictation_idle_dot` and for the retired
`show_floating_indicator` / `indicator_anchor` / `indicator_origin` keys.

Config JSON stays snake_case.

## 5. Not in scope for this node

- Onboarding flow redesign (it consumes these surfaces; it should follow, not lead).
- The meeting detail view's document treatment (Granola's "the note is the product" idea is
  recorded in the research but is a separate node).
- The Modes object itself (variant C) — recorded as the next destination, not this slice.
