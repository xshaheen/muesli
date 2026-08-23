---
title: Drop Qwen3 ASR and Upgrade FluidAudio - Plan
type: feat
date: 2026-08-21
topic: drop-qwen3-fluidaudio-upgrade
artifact_contract: x-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: x-plan-bootstrap
execution: code
---

# Drop Qwen3 ASR and Upgrade FluidAudio - Plan

## Goal Capsule

- **Objective:** Remove the Qwen3 ASR backend and the Muesli-owned Core ML target that exists only to keep it alive, then upgrade FluidAudio from 0.15.1 to 0.15.5 — the upgrade Qwen3 was blocking.
- **Why now:** The measurement harness answered the question this decision was waiting on. Qwen3 loses every cohort it was kept for. Its removal is the only thing standing between the repository and a maintained FluidAudio.
- **Product authority:** The measured run of 21-08-2026 (`docs/transcription-quality-findings-2026-08.md`) is the evidence. This plan does not re-open the verdict; it executes it.
- **Execution profile:** Four dependency-ordered units — remove the backend, delete the owned target, upgrade the dependency, then re-measure to prove nothing regressed.
- **Stop conditions:** Stop if removal would silently change a user's selected model without telling them; if the 0.15.5 upgrade changes any model identity for a maintained backend; or if the post-upgrade paired re-measurement shows a retained backend moved with an interval excluding zero.
- **Tail ownership:** The executor owns implementation, migration, tests, the re-measurement, review, and delivery.
- **Open blockers:** None.

---

## Product Contract

### Summary

Qwen3 ASR was retained on the assumption it might earn its cost on Arabic. It does not. It is beaten on every cohort by backends already shipped, it is among the slowest, and keeping it costs 2,188 lines of Apache-derived Core ML code that Muesli owns and maintains solely because FluidAudio removed the backend in 0.15.3. Removing it deletes that target and unblocks the upgrade.

### Problem Frame

FluidAudio 0.15.5 carries maintained Parakeet long-transcription fixes plus VAD and diarization improvements that Muesli's other consumers want. Muesli is pinned to 0.15.1 for one reason: Qwen3 was removed upstream after 0.15.2, so a version bump would fail to compile and would delete a selected model. The earlier plan's answer was to own the backend — `Sources/MuesliQwenCoreML/`, nine files, plus `THIRD_PARTY_NOTICES.md` and its attribution burden.

That was the right call *while the model's value was unknown*. It is now known.

**Measured, 1,182 samples per backend, all backends on automatic language detection** (Qwen3 accepts no language argument, so pinning its competitors would have been an unfair comparison):

| cohort | Qwen3 | Whisper Large Turbo | Nemotron 3.5 |
|---|---|---|---|
| english | 0.079 | **0.057** | 0.186 |
| egyptian-arabic (pooled) | 0.644 | **0.386** | 0.406 |
| egyptian-arabic (spontaneous only) | 0.731 | **0.457** | 0.474 |
| arabic-english | 0.794 | 0.664 | **0.614** |

Qwen3 is last or near-last everywhere, including the Arabic cohorts it was kept for, where it is roughly 60-70 % worse than the leader. It is also the slowest measured backend at RTF 0.16-0.20 against Parakeet's 0.03-0.04. On code-switching it failed the faithfulness gate (0.622) — but so did every other backend, so that is not disqualifying on its own.

The harness's own verdict line: `qwen3: drop — Qwen3 lost the egyptian-arabic cohort to Whisper Large Turbo Multilingual: it did not lead the cohort, running automatic.`

### Key Decisions

- **Drop Qwen3 rather than keep maintaining an owned Core ML target for it.** (session-settled: user-directed — the user asked for Qwen3 to be evaluated rather than dropped on cost grounds, and the evaluation returned a clear loss.) Governs R1, R2.
- **A user who has Qwen3 selected is migrated to a named, measured replacement and told.** Silently switching a user's model is the failure mode the earlier plan's stop conditions named; so is leaving them on a model that no longer exists. Governs R3.
- **The verdict is conditional on automatic language detection, and that qualifier ships with it.** Qwen3 could not be pinned on this branch. A future Qwen3 with a language input is a new question, not this one. Governs R9.

### Requirements

- R1. The `qwen` ASR backend MUST be removed from the model catalogue, the routing table, the CLI's model enum, and the download/deletion surfaces.
- R2. `native/MuesliNative/Sources/MuesliQwenCoreML/` MUST be deleted in full, along with its target in `Package.swift`, its tests, and the `THIRD_PARTY_NOTICES.md` entries that exist only for it. Any notice covering a still-present dependency MUST remain.
- R3. A configuration selecting `qwen` for dictation, meetings, or the CLI MUST migrate to a measured replacement — Parakeet v3 for an English-dominant profile, Whisper Large Turbo otherwise — and the change MUST be surfaced to the user rather than applied silently.
- R4. The cached Qwen3 model directory MUST be offered for deletion through the existing model-deletion path rather than orphaned on disk; it is ~1.3 GB.
- R5. FluidAudio MUST be pinned to exactly 0.15.5 and `Package.resolved` updated.
- R6. Every maintained FluidAudio consumer — Parakeet v2/v3, Parakeet EOU, SenseVoice, Nemotron, VAD, diarization — MUST compile and pass its focused tests against 0.15.5.
- R7. Repository and revision identifiers for every retained model MUST match the 0.15.1 baseline. Any upstream identity change MUST block the upgrade for explicit review rather than being absorbed.
- R8. Existing complete and partial model caches MUST keep their readiness and repair behaviour across the upgrade.
- R9. The measured findings document MUST record that the Qwen3 verdict was reached under automatic language detection, and that Qwen3 accepted no language argument at the time.
- R10. After the upgrade, the harness MUST be re-run on the identical corpus and sample set, and each retained backend compared against its own 21-08-2026 figures by a **paired before-versus-after bootstrap over the same utterances**. The existing per-run interval is a leader-versus-challenger difference and MUST NOT be reused here: it measures a different quantity and comparing a single backend's before/after figure against it is dimensionally invalid. A before/after difference whose paired interval excludes zero MUST be investigated before the work is called done.

### Key Flows

- F1. A user with Qwen3 selected upgrades
  - **Steps:** Config loads → `qwen` is unknown → migration picks the replacement by language profile → the user is told which model replaced it and why → the orphaned cache is offered for deletion.
  - **Covered by:** R3, R4
- F2. The dependency upgrade
  - **Steps:** Characterization tests recorded at 0.15.1 → pin 0.15.5 → resolve → compile every consumer → identity check against the baseline → focused tests → full suite.
  - **Covered by:** R5, R6, R7, R8
- F3. Proving no regression
  - **Steps:** Re-run the harness on the same corpus → compare each retained backend per cohort against the committed baseline → investigate any move beyond its interval.
  - **Covered by:** R10

### Acceptance Examples

- AE1. Covers R1, R2. Given the work is complete, when the repository is searched for `Qwen3AsrManager`, `MuesliQwenCoreML`, or the `qwen` backend id, then nothing outside history and the findings document remains.
- AE2. Covers R3. Given a config with `stt_backend: "qwen"` and an Arabic-dominant language profile, when the app starts, then the selection migrates to Whisper Large Turbo, the config is persisted, and the user is told the model changed and why.
- AE3. Covers R3. Given the same config with an English-only profile, then the replacement is Parakeet v3.
- AE4. Covers R7. Given 0.15.5 changes a retained model's repository or revision identifier, when the identity check runs, then the upgrade fails with that model named rather than silently adopting the new identity.
- AE5. Covers R8. Given a complete Parakeet v3 cache from before the upgrade, when the app runs after it, then the cache is still recognised as ready and is not re-downloaded.
- AE6. Covers R10. Given the post-upgrade harness run over the identical sample set, when a retained backend's paired before-versus-after difference has a 95 % interval excluding zero, then that is reported as a finding rather than accepted as the new baseline; when the interval contains zero, the backend is recorded as unmoved.
- AE7. Covers R4. Given Qwen3's cache is present after removal, when the user opens model management, then the orphaned directory is offered for deletion with its size shown.

### Success Criteria

- FluidAudio is at 0.15.5 with every maintained model working and its identity unchanged.
- No user is left on a model that no longer exists, and none is switched without being told.
- The repository carries no Apache-derived Core ML target and no attribution obligation for a backend it does not ship.
- The retained backends measure the same after the upgrade as before, within their recorded intervals.

### Scope Boundaries

#### Included

Qwen3 removal, the owned target's deletion, config migration, cache cleanup, the FluidAudio 0.15.5 upgrade, and the post-upgrade re-measurement.

#### Deferred to Follow-Up Work

- Evaluating any *new* FluidAudio 0.15.5 model. The upgrade makes them available; measuring them is the harness's next run, not this plan.
- Per-language dynamic model switching. The measurements make the case for it — Parakeet v3 is best at English and scores 0.005 faithfulness on Arabic — but it is its own product decision.
- Anything about the code-switching cohort, where no backend passed the gate **under automatic detection**. Note the measurement gap this leaves: users run *pinned* — the maintainer's own meeting config pins Nemotron to `ar` — and field experience with that configuration reports good Arabic with English keywords preserved, which the automatic-mode figure (faithfulness 0.675) does not predict. A pinned pass is the harness's next run and may overturn the code-switching conclusion. It does not affect the Qwen3 verdict, which loses on every cohort and cannot be pinned at all.
- Meeting transcript cleanup. Field feedback is that the raw live caption is already good and wants refining rather than replacing — a cleanup problem, not an ASR problem.

#### Outside This Product Slice

- Changing the faithfulness gate, the winner policy, or any harness metric to alter the verdict.

### Sources / Research

- `docs/transcription-quality-findings-2026-08.md` — the measured run this plan executes.
- `docs/plans/2026-08-19-002-feat-language-aware-transcription-fluidaudio-upgrade-plan.md` — the earlier plan whose U2 built the owned Qwen target and whose U5 is the upgrade. Its R10-R13 and R17 (Qwen ownership, long audio, shared app/CLI semantics) are **superseded** by this plan; its language-routing requirements are not.
- `native/MuesliNative/Sources/MuesliQwenCoreML/` — the nine files to delete.
- `native/MuesliNative/Sources/MuesliNativeApp/Models.swift` — `BackendOption.all`, the catalogue entry to remove.
- `native/MuesliNative/Sources/MuesliCLI/TranscribeCommand.swift` — `TranscribeModel.qwen3Asr` and its CLI transcriber.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Remove before upgrading.** Qwen3's removal is what unblocks the version bump; doing them in one step would make a compile failure ambiguous between "the upgrade broke a consumer" and "the removal missed a reference".
- KTD2. **Migration is resolved from the language profile, not a fixed fallback.** The measurements show no single replacement is right for both — Parakeet v3 wins English and is unusable for Arabic. A fixed fallback would hand an Arabic user a model with 0.005 faithfulness.
- KTD3. **Characterize before the bump.** Record deterministic 0.15.1 behaviour for cache readiness, VAD transitions, diarization invariants, and result shapes; the same tests must pass unchanged after. This is the earlier plan's U5 approach and it still applies.
- KTD4. **Model identity is a gate, not a diff.** An upstream repository or revision change for a retained model blocks the upgrade for review; absorbing it silently would swap a user's model under the same label.
- KTD5. **Re-measurement is a paired before-versus-after bootstrap, not a reuse of the ranking interval.** The run receipt's interval answers "is this backend separated from the leader in this run?" — a different question from "did this backend move between runs?". Because both runs score the identical sample set, the correct test resamples per-utterance before/after pairs and asks whether the difference interval excludes zero. Reusing the ranking interval would compare a single-backend delta against a two-backend difference's spread.

### Assumptions

- The corpus store and downloaded models remain available for the R10 re-measurement.
- No user-visible feature depends on Qwen3 beyond its presence as a selectable model.
- FluidAudio 0.15.5's API differences are confined to the surfaces the earlier plan's U5 enumerated.

### Sequencing

1. U1 remove the Qwen3 backend and migrate configs — unblocks U2, U3.
2. U2 delete the owned Core ML target and its attribution.
3. U3 upgrade FluidAudio to 0.15.5 and migrate consumers.
4. U4 re-measure and compare against the baseline.

### Risks and Mitigations

- **A user silently loses their model.** R3 and AE2/AE3 make migration explicit and language-aware; the stop conditions name silent switching.
- **The upgrade changes a model identity.** KTD4 turns that into a blocking check rather than a silent swap.
- **A retained backend regresses on 0.15.5 in a way tests do not catch.** U4's re-measurement is the net; it compares real transcription quality, not just compilation. Its comparison must be the paired test of KTD5 — an earlier draft of this plan reused the ranking interval, which measures a different quantity and would have produced a gate that passes and fails for the wrong reasons.
- **Removal misses a reference and the build breaks late.** KTD1's ordering makes the failure unambiguous, and AE1 is a repository-wide search.

---

## Implementation Units

### U1. Remove the Qwen3 backend and migrate selections

- **Goal:** No configuration, route, or surface can select Qwen3, and anyone who had it is moved to a measured replacement and told.
- **Requirements:** R1, R3, R4; KTD1, KTD2; AE2, AE3, AE7.
- **Dependencies:** None.
- **Files:** `Sources/MuesliNativeApp/Models.swift`; `TranscriptionRuntime.swift`; `Qwen3AsrBackend.swift` (delete); `ModelDeletionExecutor.swift`; `Sources/MuesliCLI/TranscribeCommand.swift`; `Sources/MuesliCore/ManagedASRModelDownloads.swift`; `Tests/MuesliTests/BackendTests.swift`, `ModelsTests.swift`, `MuesliCLITests.swift`.
- **Approach:** Remove the catalogue entry, the routing case, the CLI enum case and its transcriber, and the download plan. Add a migration that maps a persisted `qwen` selection to Parakeet v3 or Whisper Large Turbo by language profile, persists it, and surfaces the change through the existing model-changed notification path. Offer the orphaned cache through the existing deletion surface.
- **Test scenarios:** Arabic-dominant profile migrates to Whisper Large Turbo; English-only migrates to Parakeet v3; migration persists and is announced once; the CLI rejects `qwen3-asr` with a message naming the replacement; a config with no Qwen selection is untouched.
- **Verification:** `--filter BackendTests --filter AppConfigTests --filter MuesliCLITests` green; package builds.

### U2. Delete the owned Core ML target

- **Goal:** Remove the code and the attribution obligation that existed only for Qwen3.
- **Requirements:** R2; AE1.
- **Dependencies:** U1.
- **Files:** `Sources/MuesliQwenCoreML/` (delete, 9 files); `Package.swift`; `THIRD_PARTY_NOTICES.md`; `Tests/MuesliTests/Qwen3CoreMLTests.swift`, `Qwen3LongAudioTests.swift` (delete); `scripts/run_ci_test_shard.sh`.
- **Approach:** Delete the target and its tests, remove the target and its dependency edges from the package manifest, and remove only the notices covering the deleted source. Deregister the deleted suites from their shard.
- **Test scenarios:** No reference to `MuesliQwenCoreML` or `Qwen3AsrManager` remains outside history and the findings document; `THIRD_PARTY_NOTICES.md` still covers every remaining bundled dependency; the shard guard passes.
- **Verification:** `./scripts/test_ci_test_shards.sh` green; full suite green.

### U3. Upgrade FluidAudio to 0.15.5

- **Goal:** Take the maintained release, with every retained model working and unchanged in identity.
- **Requirements:** R5, R6, R7, R8; KTD3, KTD4; AE4, AE5.
- **Dependencies:** U2.
- **Files:** `Package.swift`; `Package.resolved`; `Sources/MuesliNativeApp/DiarizerRuntimePolicy.swift`; affected download and cache adapters; `Tests/MuesliTests/BackendTests.swift`, `StreamingVadControllerTests.swift`, and any suite an API diff or compiler error proves affected.
- **Approach:** First record deterministic 0.15.1 characterization tests per KTD3. Then pin exactly 0.15.5, resolve, and compile the full dependency surface. Treat `rg -l '^import FluidAudio' Sources Tests` as the audit inventory. Adapt only what the API diff or the compiler proves must change. Add the KTD4 identity check.
- **Execution note:** Characterization first — the 0.15.1 tests must exist and pass before the pin changes, or a post-upgrade failure is unattributable.
- **Test scenarios:** Package resolution records 0.15.5; the characterization tests pass unchanged either side of the pin; every retained model's repository and revision matches the baseline; existing caches keep readiness; telemetry reports the new version.
- **Verification:** `swift build`; full suite; a signed dev-lane build.

### U4. Re-measure and compare against the baseline

- **Goal:** Prove the upgrade did not move transcription quality.
- **Requirements:** R9, R10; KTD5; AE6.
- **Dependencies:** U3.
- **Files:** `docs/transcription-quality-findings-2026-08.md` (append the post-upgrade comparison).
- **Approach:** Re-run the harness against the same corpus store with the same thresholds and seed. For each retained backend and cohort, pair the two runs' utterances by (corpusID, sampleID) and bootstrap the before/after difference; report any difference whose interval excludes zero. Record the FluidAudio version in the run's provenance so the two runs are distinguishable. Pairing requires the identical sample set — if the corpus changed at all, the comparison is void and must say so rather than proceeding.
- **Test scenarios:** Test expectation: none — this unit executes the harness and records evidence.
- **Verification:** A committed comparison showing each retained backend within its interval, or a named investigation for any that is not.

---

## Verification Contract

| Gate | Command / check | Applies to |
|---|---|---|
| Focused suites | `swift test --package-path native/MuesliNative --filter BackendTests --filter AppConfigTests --filter MuesliCLITests` | U1 |
| No residue | `rg 'MuesliQwenCoreML\|Qwen3AsrManager\|"qwen"' native/MuesliNative` returns nothing outside history | U2 |
| Shard guard | `./scripts/test_ci_test_shards.sh` | U2, U3 |
| Package pin | `Package.resolved` records exactly 0.15.5 | U3 |
| Model identity | Every retained model's repository and revision matches the 0.15.1 baseline | U3 |
| Full suite | `swift test --package-path native/MuesliNative` | before PR |
| Dev build | `./scripts/dev-test.sh` | U3 |
| Re-measurement | Harness re-run on the identical sample set; per-backend paired before/after bootstrap interval contains zero | U4 |

---

## Definition of Done

- R1-R10 implemented; AE1-AE7 demonstrated by tests or by the re-measurement.
- No reference to Qwen3 or the owned Core ML target remains outside git history and the findings document.
- `THIRD_PARTY_NOTICES.md` covers every remaining bundled dependency and nothing that was removed.
- FluidAudio is pinned to 0.15.5 with every retained model's identity unchanged.
- A user who had Qwen3 selected is migrated by language profile and told; the orphaned cache is offered for deletion.
- The post-upgrade run shows every retained backend's paired before/after interval containing zero, or names what moved and why.
- The findings document states the verdict was reached under automatic language detection, with Qwen3 accepting no language argument at the time.
- No abandoned experimental code remains in the diff.
