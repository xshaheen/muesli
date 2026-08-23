---
title: Muesli Product Roadmap
type: roadmap
date: 2026-08-19
snapshot_utc: 19-08-2026_16-36-24
---

# Muesli Product Roadmap

## Purpose and authority

This is the canonical status and sequencing view for Muesli product work. Detailed plans remain authoritative for feature behavior and implementation. GitHub merge state and repository ancestry determine whether work is shipped; local commits, plans, and open pull requests do not.

Wispr Flow and similar products are productization benchmarks, not parity targets. Muesli's product identity remains local-first transcription, optional cloud enhancement, explicit model choice, open storage and automation, and user-controlled privacy.

## Snapshot

- **Snapshot:** 19-08-2026 16:36 UTC.
- **Remote baseline:** `origin/xshaheen/dev` at `08c6f3f6`.
- **Local state:** `xshaheen/dev` at `3404cc22`, twelve commits ahead of the remote baseline. Eleven implementation commits through `3404cc22` cover the Contextual Dictation Mini and independent meeting panel; `xshaheen/feat-language-aware-transcription` separately has the plan plus committed U1/U2 work and uncommitted U3 work. Neither stream has current pull-request or hosted-CI evidence.
- **Sources reached:** repository history and source, GitHub pull requests and checks, current implementation plans, the prior Wispr Flow comparison task, and current first-party Wispr product documentation.
- **Unavailable evidence:** deployed-release adoption, current signed-app acceptance for the local Mini commits, and hands-on Wispr Flow validation.
- **Overall confidence:** **Medium**. Shipped foundations are strongly evidenced, while current local work and future milestones lack delivered PR/CI evidence.

## Product direction

Build the strongest local-first dictation and meeting product in four layers:

1. **Reliable authority:** truthful language/model selection, complete local fallback, bounded terminal behavior, and auditable recordings and traces.
2. **Language-preserving quality:** hosted and local ASR choices, multilingual cleanup, safe dictionary behavior, measured Fast/Accurate policies, and meeting transcripts that do not translate Arabic speech into English.
3. **Contextual productization:** deterministic Writing Styles, Personal Context, filtered OCR, one-shot formatting, rewrite-selection mode, and clear lifecycle feedback.
4. **Meeting intelligence:** reliable capture, speaker attribution, and output language first; named speakers, MCP, and cross-meeting retrieval only after privacy and storage contracts are stable.

## Reconciliation

| Item / milestone | Declared state | Observed evidence | Reconciled state | Conflict / gap | Confidence |
|---|---|---|---|---|---|
| Session traces, terminal ownership, diagnostics, quality corpus | Shipped | PRs #11-#13 merged into `xshaheen/dev` | Done | Claude review automation was unavailable; merge evidence exists | High |
| Meeting and dictation retained audio | Shipped | PR #14 merged; shared playback and privacy boundaries present | Done | None known | High |
| Multilingual language profiles | Shipped | PR #15 merged at `22b930fa` | Done | Hosted review job failed because the Claude GitHub App was not installed, not because of a reported code failure | High |
| Dynamic per-app Writing Styles | Shipped through development integration | PR #10 head is contained in remote `xshaheen/dev`; resolver, groups, rulesets, UI, and tests exist | Done | PR #10 remains stale and open against its old base | High |
| Contextual Dictation Mini and independent meeting panel | Implementation-ready plan | Eleven local implementation commits through `3404cc22` implement the surfaces and lifecycle feedback | In progress | Not pushed through a focused PR; current native validation and visual acceptance are unverified here | Medium |
| Language-aware transcription, Qwen long audio, and FluidAudio 0.15.5 | Implementation-ready plan | The active plan is tracked; U1 capability routing and U2 owned Qwen runtime are committed, while U3 long-audio work is present but uncommitted on `xshaheen/feat-language-aware-transcription` | In progress | No focused PR or hosted CI; U3-U6 and real-model acceptance remain | Medium |
| Meeting speaker attribution and transcript-language integrity | User-reported product defects | Current capture has separate mic/system tracks and reconciliation seams, but speaker playback can still appear under both `You` and a remote speaker; Arabic transcript evidence can be replaced by English during final processing | Not started | Needs a focused contract that preserves genuine overlap and English technical terms while rejecting only evidence-backed duplication or translation | Low |
| Hosted final dictation and meeting ASR | Product direction | No active hosted-ASR implementation plan exists in the current checkout | Not started | Credential, consent, fallback, quality-gate, and provider-response decisions must be refreshed against the new language contract | Low |
| Multilingual cleanup, Fast/Accurate, context trust, OCR, dictionary, meeting output, lifecycle | Product direction | Shipped foundations exist, but no single active implementation contract covers the remaining sequence | Not started | Detailed plans and owners are missing | Low |
| Voice snippets and developer formatting | Wispr-inspired opportunity | No Muesli implementation or active plan | Not started | Must not displace core language quality | Low |
| Rewrite-selection mode | User-requested product direction | Selected-text transforms are not implemented and have no active product contract | Not started | Trigger, exact selection ownership, instruction input, preview/cancel, undo, permission failure, language preservation, and app-formatting behavior remain undefined | Low |
| Named speakers, local MCP, cross-meeting retrieval | Wispr-inspired meeting opportunity | Existing meeting storage, CLI, and chat provide foundations only | Not started | Privacy, identity, indexing, and permission contracts missing | Low |

## Milestones and risks

| Milestone outcome | Target | Evidence complete | Critical path | Risk | Confidence | Confidence changer |
|---|---|---|---|---|---|---|
| Observable and recoverable transcription | Complete | PRs #11-#14 | None | Low | High | Regression in trace/audio privacy gates |
| Truthful multilingual authority | Current local-language milestone | PR #15 language-profile foundation | Capability registry, Qwen ownership/long audio, meeting language split, FluidAudio upgrade | Dependency and migration breadth | Medium | Focused native tests, real-model acceptance, PR/CI merge |
| Selectable hosted final ASR | Next provider milestone | Trace, retention, terminal, and language foundations | Credential authority, consent, upload client, local fallback, benchmark gate | Audio egress, timeout, and quality regressions | Low | Approved implementation-ready plan and pre-registered corpus thresholds |
| Core language-preserving quality | After hosted/local measurements | Diagnostics and corpus foundation | Cleanup migration, dictionary safety, Fast/Accurate budgets, trusted context | Coupled latency and prompt behavior | Low | Measured English and Egyptian Arabic-English non-regression |
| Meeting transcript integrity | Next reliability milestone | Dual-track capture, diarization, retained audio, diagnostics, and transcript reconciliation seams | Evidence-backed cross-track deduplication; trusted Arabic-source preservation through finalization and cleanup; signed speaker-route fixtures | False deletion of genuine local speech or false rejection of valid English code-switching | Low | Focused implementation-ready contract, owner, deterministic fixtures, and signed-app acceptance |
| Reliable meeting experience | After language authority | Meeting capture, live preview, retention, and panel foundations | Hosted finalization, output language, lifecycle detection, routed sounds | False stop, language drift, audio-route behavior | Medium | Teams/browser signed-app matrix and terminal-state proof |
| Local meeting intelligence | Later | Meeting storage, CLI, hooks, and per-meeting chat | Named-speaker correction, permissioned local MCP, semantic index | Privacy and index lifecycle | Low | Separate accepted contracts and measurable retrieval quality |

## Priority changes

| Item | Change | Previous -> current | Reason / evidence | Decider | Impact / displaced work |
|---|---|---|---|---|---|
| Per-app Writing Styles | Completed | First Wispr-inspired priority -> shipped foundation | Code and PR #10 head are in remote `xshaheen/dev` | Maintainer delivery history | Removes styles from future parity work; only one-shot manual selection remains |
| Contextual Dictation Mini | Added and raised | Untracked opportunity -> active Now work | Ten local implementation commits already exist | User/session direction | New controller/settings work should wait until this surface lands |
| Language-aware local ASR and Qwen reliability | Consolidated and raised | Separate multilingual and Qwen drafts -> one active plan | FluidAudio upgrade, removed upstream Qwen backend, and language routing share one migration boundary | User-settled plan | Must land before hosted ASR can claim a reliable local fallback |
| Meeting transcript correctness | Added and raised | Untracked defects -> Next reliability outcome | User reports duplicated `You`/remote turns on speaker output and Arabic transcript evidence translated into English; current source exposes the relevant reconciliation and cleanup seams | User | Adds a focused correctness milestone before broader meeting intelligence |
| Hosted ASR | Sequenced after local authority | Immediate next feature -> next provider milestone | Hosted mapping and fallback depend on the new provider-neutral language contract | Current roadmap recommendation | Credential work can prepare independently; hosted behavior waits for the local contract |
| TCA pilot | Removed from critical path | Possible language-settings pilot -> no active adoption | Language profiles shipped with existing SwiftUI/AppKit and observable models | Delivered architecture | Avoids a framework migration unrelated to user outcomes |
| Voice snippets | Split and lowered | Bundled with per-app styles and selected-text commands -> Later | Core Arabic-English quality and reliability are the current objective | Current roadmap recommendation | Does not block transcription quality milestones |
| Rewrite-selection mode | Added and clarified | Generic selected-text transforms -> explicit Later outcome | User requested a dedicated mode rather than an unnamed parity item | User | Requires its own safety and replacement contract; does not displace current reliability work |
| Named speakers, MCP, cross-meeting retrieval | Retained but deferred | Near-term Wispr priorities -> Later meeting intelligence | Stable lifecycle, privacy, language, and indexing contracts are prerequisites | Current roadmap recommendation | Prevents cloud-parity work from destabilizing local meeting foundations |
| Enterprise administration and additional platforms | Deferred | Competitive gap -> outside current direction | No organizational-deployment objective | Original comparison and current roadmap | No displacement of native macOS quality work |

## Operational dependencies

| Dependency | Provider -> consumer | Owner | Need by | State | Risk | Next check / escalation |
|---|---|---|---|---|---|---|
| Contextual surface integration | Local Mini commits -> future controller/settings work | Current branch owner | Before new hosted-ASR UI work | In progress | Overlapping controller and settings edits | Validate, push, review, and merge; do not branch new UI work from stale remote state |
| Provider-neutral language contract | Language-aware FluidAudio plan -> hosted request mapping and meeting final ASR | Unassigned | Before hosted behavior implementation | Planned | Hosted and local semantics may diverge | Assign implementation owner and merge capability/migration foundation |
| Reliable local fallback | Qwen long-audio and backend compatibility -> hosted arbiter | Unassigned | Before hosted ASR is selectable | Planned | Hosted failure could fall into a broken local path | Prove long local dictation and missing-model terminal behavior |
| Credential authority | Keychain migration -> hosted ASR and existing OpenAI consumers | Unassigned | Before the first audio upload | Unplanned | Plaintext migration, CLI compatibility, and rollback | Create refreshed focused plan after the local language types settle |
| Hosted dictation evidence | Hosted final dictation -> hosted meeting finalization and Fast/Accurate budgets | Unassigned | Before meeting hosted ASR and final budgets | Not started | No quality/latency baseline | Run fixed English, Egyptian Arabic, and Arabic-English corpus with local comparison |
| Trusted context contract | Personal Context and source policy -> OCR, meeting output, named-speaker hints | Unassigned | Before OCR or identity enrichment | Not started | Untrusted text can become prompt instructions | Define typed source trust, freshness, caps, disclosure, and rejection reasons |
| Meeting lifecycle authority | Meeting detector and origin policy -> routed sounds and named-speaker UX | Unassigned | Before lifecycle sound completion | Not started | False automatic stops and misleading feedback | Prove native Teams and one browser flow |
| Meeting language and source evidence | Frozen meeting language plus accepted mic/system transcript evidence -> meeting transcript-integrity guard | Unassigned | Before transcript-integrity implementation | Partially available | Over-aggressive deduplication can delete real local speech; a script-only guard can reject legitimate English code-switching | Define evidence thresholds and rollback authority, then prove speaker-route and Arabic-English fixtures |
| Safe selected-text authority | Focused-app accessibility selection and reversible replacement -> rewrite-selection mode | Unassigned | Before rewrite-selection implementation | Not started | Wrong-range replacement, stale selection, inaccessible apps, or irreversible edits | Define exact selection snapshot, permission failure, preview/cancel, undo, and app-format preservation |
| Stable local data permissions | Meeting storage/privacy -> local MCP and semantic retrieval | Unassigned | Before external agent access | Not started | Over-broad data exposure and unbounded indexes | Define read scopes, redaction, retention, revocation, and deletion propagation |

## Now / Next / Later

| Horizon | Outcome | Entry / done condition | Owner | Dependencies | Confidence and basis |
|---|---|---|---|---|---|
| **Now** | Deliver the Contextual Dictation Mini and independent meeting panel | Local commits pass focused/full native tests and visual QA, receive review, and merge into remote `xshaheen/dev` | Current branch owner | Existing trace and terminal contracts | Medium: implementation exists locally, delivery evidence does not |
| **Now** | Execute the consolidated local-language and FluidAudio plan | U1/U2 remain intact; U3-U6 pass their focused and full acceptance without model substitution or partial Qwen publication and merge through a focused PR | Current feature-branch owner | PR #15; current FluidAudio/Qwen cache contract | Medium: U1/U2 are committed and U3 is in progress, but delivery evidence is absent |
| **Next** | Secure credential authority | OpenAI key moves to a device-only Keychain authority; every consumer and CLI path has an explicit migration contract | Owner required | Mini merge to reduce UI conflicts; refreshed plan | Low until a current focused plan exists |
| **Next** | Selectable hosted final dictation | English/Arabic mapping, bounded upload, consent, local fallback, diagnostics, and release corpus pass | Owner required | Credential authority; local language contract; Qwen reliability | Low: dependencies and decisions remain open |
| **Next** | Hosted final meeting transcription | Mic/system chunks reconcile without missing spans; local live preview stays independent | Owner required | Hosted dictation transport/evidence; meeting spoken-language authority | Low |
| **Next** | Correct meeting speaker attribution and transcript language | Speaker output no longer duplicates evidence-backed remote turns under both `You` and the remote speaker; genuine overlap survives; trusted Arabic transcript evidence remains Arabic through finalization and optional cleanup while English technical terms remain intact | Owner required | Meeting language authority; current dual-track reconciliation and diagnostics | Low: user-reported defects and code seams are known, but no focused contract or owner exists |
| **Next** | Language-preserving transformation quality | Default multilingual cleanup, safe dictionary, and measured Fast/Accurate modes pass the frozen corpus and terminal budgets | Owner required | Hosted/local timing and quality evidence | Low |
| **Next** | Trusted personalization and output | Personal Context, trust hierarchy, OCR rejection, meeting output language, and one-shot app formatting ship with privacy diagnostics | Owner required | Language authority and cleanup contract | Low |
| **Next** | Meeting lifecycle and routed feedback | Teams/browser detection, visible recording state, origin-aware stop policy, and configurable route-aware cues pass signed-app tests | Owner required | Current meeting panel; lifecycle authority | Medium: UI foundation exists, runtime work does not |
| **Later** | Voice snippets | A separate product contract proves deterministic triggers, expansion boundaries, conflicts, and privacy behavior | Unassigned | Core quality milestone | Low |
| **Later** | Rewrite-selection mode | A user can freeze the exact focused-app selection, provide a rewrite instruction, preview or cancel, replace only that selection, and undo safely; language, technical terms, and app formatting are preserved, while unavailable accessibility permission fails without editing anything | Unassigned | Core quality milestone; safe selected-text authority | Low: requested direction is clear, but interaction and replacement contracts are unplanned |
| **Later** | Named-speaker correction | User can assign/correct names without corrupting original diarization or unrelated meetings | Unassigned | Meeting language/output/lifecycle stability | Low |
| **Later** | Local read-only MCP | Explicitly authorized tools can read bounded meeting artifacts with revocation and auditability | Unassigned | Stable data permissions and deletion propagation | Low |
| **Later** | Cross-meeting semantic retrieval | Local-first index has measurable retrieval quality, citations, retention, and complete deletion | Unassigned | Stable meeting schema and privacy policy | Low |
| **Later** | Teams, enterprise controls, and more platforms | Requires a separate organizational-deployment strategy | Unassigned | Product-direction decision | Low |

## Decision gates

Before hosted ASR becomes implementation-ready, settle and record:

1. Immediate environment-only CLI migration versus a compatibility release.
2. Keychain accessibility while the Mac is locked.
3. Human-spoken Egyptian Arabic and Arabic-English corpus provenance and numeric release thresholds.
4. Whether local/hosted script disagreement is observation-only or may reject hosted output after a measured false-rejection gate.
5. Whole-recognition deadlines that reserve finite time for local fallback and always leave the queue in a terminal state.

Before local MCP or cross-meeting retrieval starts, settle read scope, user authorization, retention, deletion propagation, sync boundaries, and whether any index or connector may leave the device.

Before meeting transcript-integrity work becomes implementation-ready, settle evidence thresholds for cross-track playback duplication, the authority used to detect Arabic-to-English replacement, behavior for mixed local/remote segments, and the exact raw-versus-cleaned rollback boundary.

Before rewrite-selection mode becomes implementation-ready, settle invocation and instruction input, selection snapshot lifetime, preview/cancel and undo semantics, accessibility-permission failures, supported app boundaries, language preservation, formatting preservation, and privacy-safe diagnostics.

## Maintenance rules

- Update this file when an outcome is added, raised, lowered, deferred, removed, merged, or explicitly abandoned.
- A plan is not implementation progress. A local commit is not shipped. A merged PR is not a released build unless release evidence exists.
- Every **Now** item needs an owner, entry condition, and done condition. Ownerless work remains **Next** or **Later**.
- Keep implementation detail in linked plans. This roadmap records outcomes, dependencies, evidence, confidence, and priority provenance.
- Refresh time-sensitive competitor claims from first-party sources and label them as vendor claims unless hands-on evidence exists.

## Active plans and evidence

- `docs/plans/2026-08-19-001-feat-contextual-dictation-mini-plan.md`
- `docs/plans/2026-08-19-002-feat-language-aware-transcription-fluidaudio-upgrade-plan.md`
- `docs/plans/2026-08-10-001-feat-dynamic-dictation-style-groups-plan.md`
- PRs #11-#15 in `xshaheen/muesli`
- Wispr Flow first-party references: <https://wisprflow.ai/features>, <https://wisprflow.ai/notetaker>, <https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode>, and <https://docs.wisprflow.ai/articles/4759919286-how-to-connect-wispr-flow-to-claude-chatgpt-and-other-ai-tools-mcp>.
