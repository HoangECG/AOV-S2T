---
phase: 01-windows-capture-inference-feasibility
plan: "10"
subsystem: inference
tags: [benchmark, wasm, worker, pcm, privacy, tauri]
requires:
  - phase: 01-09
    provides: sealed worker inventory and strict native worker protocol
provides:
  - fixture-gated warm native benchmark transaction for CPU and sealed accelerators
  - single IPC command that consumes temporary PCM without exposing content or paths
  - RAII cleanup for sample WAVs and PCM across success, error, cancel, and retry
affects: [01-11, 01-12, setup-readiness, target-pc-verification]
actuals:
  tokens: 8899
  tasks: 2
  commits: 3
tech-stack:
  added: []
  patterns: [sealed-input-runner, fixture-before-warm-measurement, raii-sensitive-sample-cleanup]
key-files:
  created: [src-tauri/src/inference/transaction.rs, src-tauri/tests/benchmark_transaction.rs, src-tauri/tests/benchmark_cleanup.rs]
  modified: [src-tauri/src/inference/runner.rs, src-tauri/src/inference/benchmark.rs, src-tauri/src/audio/capture.rs, src-tauri/src/commands/benchmark.rs, src-tauri/src/main.rs]
key-decisions:
  - "The native coordinator, not React, creates measurements and profile candidates from sealed worker results."
  - "CPU must pass fixture and warmed measurement gates before any accelerator profile can be selected."
  - "Controller PCM is atomically taken, zeroed, and protected by a temporary-file Drop guard; no sample bytes or path cross IPC."
requirements-completed: [AI-03]
coverage:
  - id: D1
    description: "Accepted 16 kHz PCM runs fixture-first CPU/CUDA/Vulkan warm measurement and returns a non-content profile only when CPU and a candidate pass."
    requirement: AI-03
    verification:
      - kind: integration
        ref: "powershell.exe -NoProfile -Command cargo test --manifest-path src-tauri/Cargo.toml --test benchmark_transaction"
        status: pass
    human_judgment: false
  - id: D2
    description: "User PCM and its private WAV are removed on rejection, worker failure, unwind, cancellation, and retry preparation."
    requirement: AI-03
    verification:
      - kind: integration
        ref: "powershell.exe -NoProfile -Command cargo test --manifest-path src-tauri/Cargo.toml --test benchmark_cleanup"
        status: pass
    human_judgment: false
  - id: D3
    description: "A target PC can establish an actual sealed CPU/GPU benchmark profile from a user-owned sample."
    requirement: AI-03
    verification:
      - kind: manual_procedural
        ref: "Run finish_and_run_benchmark on the target Windows PC with verified model and sealed worker inventory."
        status: unknown
    human_judgment: true
    rationale: "This environment has no target hardware, verified model bytes, or sealed worker artifacts; no benchmark outcome was fabricated."
metrics:
  duration: 25min
  completed: 2026-08-19
status: complete
---

# Phase 01 Plan 10: Reachable Private PCM Benchmark Summary

**A native fixture-first benchmark now consumes local PCM once, measures sealed CPU/GPU workers, and deletes both memory and temporary WAV state on every terminal path.**

## Accomplishments

- Added `InferenceRunner::run_input`, which accepts only a host-created WAV inside the transaction directory while retaining sealed inventory, model, timeout, output-cap, identity, and JSON protocol checks.
- Added a deterministic benchmark transaction: immutable fixture, discarded warm-up, three measured sample runs, CPU-required profile selection, and non-content evidence only.
- Replaced metadata-only sample completion with native finish-and-run, cancel, and retry commands; controller-owned PCM is atomically taken and zeroed.

## Task Commits

1. **Task 1 RED: Run one accepted sample through CPU fixture, warm measurement, and profile selection** — `85f645e` (test)
2. **Task 1 GREEN: Run one accepted sample through CPU fixture, warm measurement, and profile selection** — `48f030d` (feat)
3. **Task 2: Make sample ownership atomic and cleanup unavoidable** — `02c8510` (fix)

## Verification

- Passed: `cargo test --manifest-path src-tauri/Cargo.toml --test benchmark_transaction` (2 tests).
- Passed: `cargo test --manifest-path src-tauri/Cargo.toml --test benchmark_cleanup --test benchmark_transaction` (6 tests).
- Passed: worker-protocol and benchmark scoring tests as part of focused validation.
- `cargo test --manifest-path src-tauri/Cargo.toml --all-targets` compiled the project and passed the executed suites, but could not launch pre-existing `setup_flow` because Windows returned elevation error 740. This is environment permission debt, not a skipped Plan 01-10 assertion.

## Deviations from Plan

### Auto-fixed Issues

1. **[Rule 1 - Bug] Capture stop now records stopped state even when joining a failed capture worker returns an error.**
   - **Found during:** Task 2 cleanup integration.
   - **Fix:** Stop state is set before the join error returns, so cancel/retry cannot leave the UI believing capture is active.
   - **Files modified:** `src-tauri/src/audio/capture.rs`
   - **Verification:** `benchmark_cleanup` passes.
   - **Committed in:** `02c8510`

## Known Stubs

None. Missing sealed workers and models return explicit non-passing evidence; target-PC measurements remain required before readiness can be claimed.

## Next Phase Readiness

Plan 01-12 can call `finish_and_run_benchmark` from the setup UI and use only the returned non-content report/profile. Target-PC verification must still run the real sealed CPU and available accelerator workers.

## Self-Check: PASSED

- Confirmed `transaction.rs`, focused transaction tests, cleanup tests, and native commands exist.
- Confirmed commits `85f645e`, `48f030d`, and `02c8510` exist.
