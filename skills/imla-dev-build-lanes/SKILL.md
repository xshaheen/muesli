---
name: imla-dev-build-lanes
description: Use when working on Imla local dev builds, fixed dev lanes, parallel worktrees, SwiftPM scratch paths, app bundle IDs, app support directories, signing, entitlements, iCloud/APNs-capable builds, or local-only builds that should omit cloud entitlements.
---

# Imla Dev Build Lanes

## Overview

Use this skill to build and reason about local Imla dev apps across multiple worktrees without overwriting app bundles, sharing support data, or accidentally requiring iCloud/APNs entitlements.

## Core Workflow

1. Read `AGENTS.md` first for current scratch-path and lane policy.
2. Inspect `scripts/dev-test.sh`, `scripts/build_native_app.sh`, and `scripts/imla_spm_cache.sh` before changing build behavior.
3. Preserve default `./scripts/dev-test.sh` behavior unless explicitly changing the default dev app.
4. Prefer fixed lanes `A`, `B`, and `C`; do not create arbitrary branch-named bundle IDs unless the user explicitly accepts repeated macOS permission prompts.
5. Do not delete app support data or reset TCC permissions unless explicitly asked.

## Lane Mapping

Default dev app:

```text
App:        /Applications/ImlaDev.app
Bundle ID:  com.xshaheen.imla.dev
Support:    ~/Library/Application Support/ImlaDev
```

Fixed lanes:

```text
A -> ImlaDevA, com.xshaheen.imla.dev.a, process ImlaDevA, ~/Library/Application Support/ImlaDevA
B -> ImlaDevB, com.xshaheen.imla.dev.b, process ImlaDevB, ~/Library/Application Support/ImlaDevB
C -> ImlaDevC, com.xshaheen.imla.dev.c, process ImlaDevC, ~/Library/Application Support/ImlaDevC
```

## Entitlement Modes

Use local-only entitlements when testing non-sync features:

```bash
./scripts/dev-test.sh --lane A --local-only
```

Named lanes default to local-only entitlements. This uses `scripts/ImlaLocalOnly.entitlements` and clears provisioning/APNs env for the build.

Use cloud entitlements only when iCloud/APNs behavior is under test and the bundle ID has a matching Apple Developer profile:

```bash
MUESLI_PROVISIONING_PROFILE="/path/to/profile.provisionprofile" \
MUESLI_SIGN_IDENTITY="Apple Development: Name (TEAMID)" \
MUESLI_CODESIGN_TIMESTAMP=none \
./scripts/dev-test.sh --lane A --cloud-entitlements
```

Plain `./scripts/dev-test.sh` keeps the existing cloud-entitlement-capable `ImlaDev` behavior.

## Build Cache Rules

Use the shared SwiftPM scratch path resolver. For direct SwiftPM commands, pass `--scratch-path` yourself. Never run concurrent worktrees into the same scratch path.

If `/Volumes/MuesliBuildCache/imla-spm` is mounted, prefer it. Otherwise scripts fall back to `~/Library/Caches/imla-spm`.
