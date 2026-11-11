---
phase: 01-windows-capture-inference-feasibility
plan: "04"
subsystem: local-model-acquisition
tags: [tauri, react, rust, reqwest, sha256, whisper.cpp]
requires:
  - phase: 01-03
    provides: Tauri/React setup wizard and native command registration conventions
provides:
  - Immutable large-v3 model provenance manifest and offline readiness checks
  - Fail-closed disk preflight, HTTPS download, SHA-256 verification, and atomic promotion
  - Host-owned model status/download/retry commands and Vietnamese acquisition UI
affects: [01-05, 01-06, 01-07, inference, setup-wizard]
actuals:
  tokens: 14171
  tasks: 2
  commits: 4
tech-stack:
  added: [reqwest blocking rustls, sha2]
  patterns: [immutable model manifest, same-filesystem atomic promotion, host-owned installer IPC]
key-files:
  created:
    - src-tauri/resources/model-manifest.json
    - src-tauri/src/inference/download.rs
    - src-tauri/src/inference/manifest.rs
    - src-tauri/src/commands/model.rs
    - src/components/ModelDownloadStep.tsx
  modified:
    - src-tauri/tests/manifest.rs
    - src/components/SetupWizard.tsx
    - src/App.tsx
key-decisions:
  - "Pin ggml-large-v3 to Hugging Face revision 5359861c739e955e79d9a303bcbc70fb988958b1 and its exact expected size/SHA-256."
  - "Store each revision below app-local data so a candidate never overwrites a known-good revision."
  - "React may only call host-owned status/download/retry commands; it cannot provide a URL or destination."
patterns-established:
  - "Model readiness means validated local bytes only; it never implies worker, benchmark, or profile readiness."
  - "Download state is explicit, retryable where appropriate, and emits byte progress from the native host."
requirements-completed: [AI-03]
coverage:
  - id: D1
    description: "Pinned model lifecycle rejects untrusted, partial, wrong-size, and checksum-mismatched bytes before activation."
    requirement: AI-03
    verification:
      - kind: unit
        ref: "powershell.exe -NoProfile -Command \"cargo test --manifest-path src-tauri/Cargo.toml --test manifest\""
        status: pass
    human_judgment: false
  - id: D2
    description: "The setup wizard presents model identity, disk destination, byte progress, verification, failures, retry, and installed states."
    requirement: AI-03
    verification:
      - kind: automated_ui
        ref: "npm run typecheck && npm run build"
        status: pass
    human_judgment: true
    rationale: "Target-PC first-run, storage, network interruption, offline restart, overflow, and focus behavior require exercising the native installer UI."
duration: 14min
completed: 2026-08-19
status: complete
---

# Phase 1 Plan 04: Verified Large-v3 Model Acquisition Summary

Immutable ggml-large-v3 provenance now gates a local-only installer that checks disk space, SHA-256, and atomic promotion before the setup wizard can call model bytes ready.

## Accomplishments

- Pinned the unquantized `ggml-large-v3.bin` model to an immutable official repository revision with exact byte size, SHA-256, license, and compatible worker revision.
- Added a host-owned installer that allows HTTPS only, checks destination-drive free space, writes to a same-filesystem temporary file, verifies size/SHA-256, and promotes only verified bytes.
- Added explicit offline status, incomplete/corrupt/storage failure reasons, determinate progress events, retry handling, and a wizard step that prevents moving to benchmark recording before `Ready`.

## Task Commits

1. **Task 1: Pin, download, checksum, and atomically install the largest default model**
   - `be9bc16` `test(01-04): add failing model lifecycle tests`
   - `b26461d` `feat(01-04): install only verified pinned models`
   - `d7e348e` `fix(01-04): report incomplete temporary model files`
2. **Task 2: Render model acquisition, verification, failure, retry, and installed states**
   - `5ea12dc` `feat(01-04): render verified model acquisition`

## Verification

- PASS: `powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml --test manifest"` — 6 fail-closed lifecycle tests pass.
- PASS: `powershell.exe -NoProfile -Command "cargo fmt --manifest-path src-tauri/Cargo.toml --check"`.
- PASS: `npm run typecheck`.
- PASS: `npm run build`.
- PASS: immutable upstream metadata was read without downloading model bytes: model revision `5359861c739e955e79d9a303bcbc70fb988958b1`, expected size `3,095,033,483`, SHA-256 `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`, and MIT license.
- PENDING TARGET-PC CHECK: exercise installed, insufficient-space, interrupted-download, checksum-mismatch, long revision, and offline-restart states against the native installer. This is recorded as open ledger entry 4 in `.planning/WINDOWS.md`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Fail-closed incomplete state] Stale temporary files now surface an explicit incomplete-file failure.**
- **Found during:** Task 2
- **Issue:** A prior interrupted transfer could leave a `.part` file while status looked merely absent.
- **Fix:** Detect the temporary file during offline status checks and return a retryable `incomplete-file` state; added a deterministic regression test.
- **Files modified:** `src-tauri/src/inference/download.rs`, `src-tauri/tests/manifest.rs`
- **Verification:** manifest test suite passes.
- **Committed in:** `d7e348e`

**2. [Execution constraint] No 3.1 GB model artifact was downloaded into the working tree.**
- **Found during:** Task 1
- **Issue:** The plan asked for a local full-artifact verification, but the execution scope explicitly forbade large model artifacts in the repository.
- **Fix:** Verified immutable upstream metadata only and implemented runtime download/size/SHA-256 validation; real full-artifact validation remains the target-PC manual check.
- **Files modified:** none
- **Verification:** immutable upstream API/HEAD metadata plus deterministic local lifecycle tests.

**Total deviations:** 1 auto-fixed correctness issue and 1 documented execution constraint. No model downgrade path or arbitrary React-provided source/destination was introduced.

## Issues Encountered

- Reqwest 0.13 uses the `rustls` feature name rather than `rustls-tls`; the dependency declaration was corrected before it was compiled. This was a direct build-configuration correction, not a package substitution.

## Known Stubs

None in the model-acquisition implementation. Model readiness intentionally remains separate from later worker/benchmark/profile readiness.

## Next Phase Readiness

- Plans 01-05 and 01-06 can consume `ModelManifest`, the verified local model path convention, and the explicit `Ready` boundary for worker admission and benchmark selection.
- Manual target-PC installer verification remains open; no model artifact was included in source control.

## Self-Check: PASSED

- Required manifest, installer, command, UI, and summary files exist.
- All four implementation commits (`be9bc16`, `b26461d`, `d7e348e`, `5ea12dc`) exist in Git history.
