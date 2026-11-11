---
phase: 01-windows-capture-inference-feasibility
plan: "11"
subsystem: setup-readiness
tags: [tauri, setup, persistence, readiness, privacy]
requires:
  - phase: 01-10
    provides: retained native benchmark profiles and PCM cleanup
provides:
  - ordered native-only setup transaction with atomic known-good persistence
  - registered native source-test, completion, cancellation, and startup revalidation commands
  - content-free restart diagnostics and drift recovery states
affects: [01-12, 01-13, setup-wizard, readiness]
actuals:
  tokens: 10343
  tasks: 3
  commits: 7
key-files:
  created: [src-tauri/tests/setup_command_flow.rs]
  modified: [src-tauri/src/setup/state.rs, src-tauri/src/setup/config.rs, src-tauri/src/commands/setup.rs, src-tauri/src/commands/benchmark.rs, src-tauri/src/inference/transaction.rs, src-tauri/src/diagnostics.rs, src-tauri/src/main.rs, src-tauri/tests/setup_flow.rs, src-tauri/tests/setup_transaction.rs, src-tauri/tests/readiness.rs]
key-decisions:
  - "Only managed native collaborators may supply model, benchmark, endpoint, signal, or caption evidence; IPC exposes no proof setters."
  - "Invalid stored bytes are never replaced during load; a setup-required flow preserves them unchanged."
  - "Later launch repeats model/worker/fixture and exact-endpoint checks, while retaining committed official-source evidence only when the endpoint remains available."
metrics:
  duration: 52min
  completed: 2026-08-19
status: complete
---

# Phase 01 Plan 11: Truthful Native Setup Transaction Summary

The native setup flow now persists a complete known-good configuration only after model, benchmark, exact-source signal, and Vietnamese one-shot evidence are produced inside the app.

## Accomplishments

- Added validated, versioned config load plus temp-write, sync, validate, and atomic replacement; corrupt files are retained unchanged.
- Added ordered native transitions and Tauri commands for model acknowledgement, retained benchmark profile, official-source one-shot, commit, cancellation, and one authoritative snapshot.
- Added startup revalidation of the pinned model, sealed worker fixture, hardware fingerprint, and exact endpoint; drift re-enters the first affected setup state.
- Removed the requirement for a fresh audio capture at every matching launch while keeping source loss and missing current evidence fail-closed.

## Task Commits

1. **Task 1 RED: transaction persistence and recovery coverage** — `2c917d3` (test)
2. **Task 1 GREEN: validated native setup transaction** — `29ec4f9` (feat)
3. **Task 2 RED: native setup command route coverage** — `a722168` (test)
4. **Task 2 GREEN: registered native setup commands** — `e181559` (feat)
5. **Task 3 RED: truthful launch readiness coverage** — `65291ba` (test)
6. **Task 3 GREEN: startup revalidation and diagnostics** — `eb19879` (feat)
7. **Deviation fix: compatible known-good profile reuse** — `fbbe748` (fix)

## Verification

- Passed compilation: `powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml --test setup_transaction --test setup_flow --test setup_command_flow --test readiness --no-run"`.
- Passed runtime suite: `readiness` (3 tests).
- The Windows runner refused to launch `setup_transaction`, `setup_flow`, and `setup_command_flow` with OS error 740 (elevation required). Their test binaries compile, but successful runtime execution remains a target-PC/elevated-session check.
- `cargo fmt --check` remains non-zero because pre-existing formatting drift includes files outside this plan; no broad formatting rewrite was made.

## Deviations from Plan

### Auto-fixed Issues

1. **[Rule 1 - Bug] Reused known-good profile evidence for official-source retests.**
   - **Found during:** Task 3 restart coverage.
   - **Issue:** A reconfiguration beginning at Official Source had a compatible persisted profile but no transient retained profile for the one-shot command.
   - **Fix:** Reconstruct a native-only runtime profile from the validated known-good evidence; no profile is accepted from IPC.
   - **Files modified:** `src-tauri/src/setup/state.rs`, `src-tauri/src/commands/setup.rs`, `src-tauri/tests/setup_command_flow.rs`
   - **Commit:** `fbbe748`

## Known Stubs

None. Actual Windows device availability, worker sealing, model bytes, and elevation failures return non-passing native evidence; no readiness is fabricated.

## Self-Check: PASSED

- Confirmed all setup, command, diagnostics, and focused test files exist.
- Confirmed commits `2c917d3`, `29ec4f9`, `a722168`, `e181559`, `65291ba`, `eb19879`, and `fbbe748` exist.
