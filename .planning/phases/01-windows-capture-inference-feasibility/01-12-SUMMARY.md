---
phase: 01-windows-capture-inference-feasibility
plan: "12"
subsystem: setup-wizard
tags: [react, tauri, benchmark, readiness, privacy]
requires:
  - phase: 01-11
    provides: native setup transaction and known-good configuration
provides:
  - native-command orchestration for benchmark, source validation, completion, retry, and cancellation
  - native-authoritative current-step and canComplete setup snapshot for React
  - complete setup, recovery, diagnostics, and cancellation UI states
affects: [setup-wizard, readiness-dashboard, target-pc-verification]
actuals:
  tokens: 5600
  tasks: 2
  commits: 4
key-files:
  created: [src/setupFlow.ts, src/setupFlow.test.ts]
  modified: [src/App.tsx, src/components/SetupWizard.tsx, src/components/BenchmarkStep.tsx, src/components/ReadinessDashboard.tsx, src/styles.css, src-tauri/src/commands/setup.rs, src-tauri/src/setup/state.rs, src-tauri/src/main.rs]
key-decisions:
  - "React renders native currentStep and canComplete rather than inferring readiness from local flags."
  - "Successful benchmark acceptance uses finish_and_run_benchmark followed by native profile acceptance; failures and retries await native cancellation."
  - "The snapshot exposes no benchmark PCM or recognized text; only measured non-content evidence reaches the UI."
metrics:
  completed: 2026-08-19
status: complete
---

# Phase 01 Plan 12: Native Setup UI Wiring Summary

The desktop wizard now drives the legal native setup transaction from the accepted sample through a measured benchmark, official-source test, and native-gated Ready state.

## Accomplishments

- Added `setupFlow` orchestration with regression tests for command order, native completion authority, cancellation, retry, and UI cleanup.
- Replaced static package-readiness rows with the measured `finish_and_run_benchmark` report and native retained-profile transition.
- Added a flattened authoritative setup snapshot carrying native `currentStep` and `canComplete`, plus a named `cancel_setup_transaction` cleanup command.
- Rendered official-source checks, completion gating, readiness/rebenchmark recovery, confirmation dialog, diagnostics, meter states, and responsive matrix details without exposing PCM or transcripts.

## Task Commits

1. **Task 1 RED: setup-flow regression coverage** — `f40c512` (test)
2. **Task 1 GREEN: native setup orchestration** — `b6455cb` (feat)
3. **Task 1 integration: benchmark transaction and native snapshot** — `46ad9ca` (feat)
4. **Task 2: authoritative setup and recovery rendering** — `2a3f772` (feat)

## Verification

- Passed: `npm test -- src/setupFlow.test.ts` (6 tests).
- Passed: `npm run typecheck`.
- Passed: `npm run build`.
- Not run: focused Rust tests, because `cargo` is unavailable in this environment. Target-PC behavior remains deliberately unclaimed and is handled by Plans 01-13/01-14.

## Deviations from Plan

### Auto-fixed Issues

1. **[Rule 2 - Missing critical functionality] Exposed native step and completion authority.**
   - **Found during:** Task 1.
   - **Issue:** Plan 01-11's snapshot omitted `currentStep` and `canComplete`, so the UI could not truthfully route the wizard or gate completion.
   - **Fix:** Added native snapshot fields derived from `SetupMachine` only; React treats absent/non-true completion as disabled.
   - **Files modified:** `src-tauri/src/commands/setup.rs`, `src-tauri/src/setup/state.rs`, `src-tauri/src/main.rs`.
   - **Commit:** `46ad9ca`.

2. **[Rule 2 - Missing critical functionality] Added the named setup cleanup boundary.**
   - **Found during:** Task 1.
   - **Issue:** The plan's required `cancel_setup_transaction` command did not exist, despite `cancel_setup_reconfiguration` providing its intended cleanup semantics.
   - **Fix:** Registered a semantic alias that delegates to the existing native stop/discard/candidate-cancel transaction.
   - **Files modified:** `src-tauri/src/commands/setup.rs`, `src-tauri/src/main.rs`.
   - **Commit:** `46ad9ca`.

## Known Stubs

None. Missing target-PC workers, model bytes, devices, or source evidence remain non-passing native states; this plan does not manufacture benchmark or Ready evidence.

## Self-Check: PASSED

- Confirmed `src/setupFlow.ts`, `src/setupFlow.test.ts`, native snapshot files, and UI files exist.
- Confirmed commits `f40c512`, `b6455cb`, `46ad9ca`, and `2a3f772` exist.
