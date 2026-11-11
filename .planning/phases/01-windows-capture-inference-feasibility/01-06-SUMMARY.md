---
phase: 01-windows-capture-inference-feasibility
plan: "06"
subsystem: inference
tags: [benchmark, cpu-baseline, wasm-api, tauri, react, privacy]
requires:
  - phase: 01-05
    provides: sealed-worker admission contract and immutable Vietnamese fixture checks
provides:
  - deterministic CPU/CUDA/Vulkan warm-measurement profile policy
  - bounded local-only temporary benchmark PCM capture and non-content evidence UI
  - explicit development/target-PC evidence debt for unavailable sealed workers
affects: [01-07, setup-transaction, readiness, diagnostics]
actuals:
  tokens: 12130
  tasks: 2
  commits: 3
tech-stack:
  added: []
  patterns: [cpu-always-in-matrix, fixture-before-scoring, non-content-profile, bounded-temporary-pcm]
key-files:
  created: [src-tauri/src/inference/benchmark.rs, src-tauri/src/commands/benchmark.rs, src-tauri/src/setup/profile.rs, src-tauri/tests/benchmark.rs, src/components/BenchmarkStep.tsx, src/components/DiagnosticPanel.tsx]
  modified: [src-tauri/src/audio/capture.rs, src-tauri/src/main.rs, src/App.tsx, src/components/SetupWizard.tsx, src/styles.css]
key-decisions:
  - "CPU is always represented in the candidate matrix; acceleration wins only with better passing warmed measurements."
  - "Profiles and diagnostics keep hashes, timings, hardware/build evidence, and fixture identity but never the temporary sample or recognized transcript."
  - "An unsealed or unavailable worker is explicit evidence debt, never a passed backend."
requirements-completed: [AI-03]
coverage:
  - id: D1
    description: "Benchmark selection deterministically requires CPU, exact fixture admission, documented correctness, warmed RTF, and p95 gates."
    requirement: AI-03
    verification:
      - kind: unit
        ref: powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml --test benchmark"
        status: pass
    human_judgment: false
  - id: D2
    description: "Temporary non-silent native PCM capture and non-content CPU/CUDA/Vulkan evidence UI are wired without claiming a hardware pass from presence."
    requirement: AI-03
    verification:
      - kind: other
        ref: npm run typecheck && powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml --all-targets"
        status: pass
    human_judgment: false
  - id: D3
    description: "A complete first-run benchmark obtains target-PC CPU plus physically available CUDA/Vulkan evidence from the local Vietnamese sample."
    requirement: AI-03
    verification:
      - kind: manual_procedural
        ref: target Windows PC with sealed workers, verified model, and actual available hardware
        status: unknown
    human_judgment: true
    rationale: "The checkout has no sealed worker binaries, verified model bytes, target Windows audio endpoint, GPU, or driver."
duration: 12min
completed: 2026-08-19
status: complete
---

# Phase 01 Plan 06: Local Benchmark Evidence Summary

**Fixture-gated CPU/CUDA/Vulkan profile scoring now retains a bounded local PCM sample only in native memory and renders non-content backend evidence.**

## Performance

- **Duration:** 12 min
- **Tasks:** 2/2
- **Files modified:** 15

## Accomplishments

- Added portable tests and deterministic policy for the unconditional CPU baseline, fixture mismatch, Vietnamese correctness threshold, warmed RTF/p95 gates, acceleration selection, and profile privacy.
- Added native commands for the fixed Vietnamese prompt, 16 kHz mono bounded temporary sample capture, explicit worker packaging readiness, and cleanup.
- Added benchmark and diagnostic UI states that distinguish checking, pass, failure, and absent workers without rendering sample audio or recognized text.

## Task Commits

1. **Task 1 RED: Record the local clean-stream sample and select one measured profile** — `9300054` (test)
2. **Task 1 GREEN: Record the local clean-stream sample and select one measured profile** — `8114486` (feat)
3. **Task 2: Render benchmark progress, backend evidence, fallback, and diagnostics** — `b0a47d2` (feat)

## Decisions Made

- Cold-load timing is displayed separately; it never determines candidate admission or winner selection.
- A passing profile serializes only non-content evidence. Temporary PCM stays in a bounded native buffer for the setup transaction and is exposed only as duration/frame metadata.
- Worker packaging readiness is intentionally separate from a benchmark pass; an unsealed current development manifest renders `Không được cài`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Corrected temporary string lifetimes in Vietnamese correctness scoring.**
- **Found during:** Task 1 GREEN verification
- **Fix:** Bound normalized strings before collecting word references.
- **Verification:** Benchmark tests pass.
- **Committed in:** `8114486`

**2. [Rule 2 - Missing critical functionality] Added bounded native temporary PCM retention.**
- **Found during:** Task 2 integration
- **Issue:** The existing meter discarded captured PCM, so the UI could not create a real local benchmark sample.
- **Fix:** Added a 20-second, 16 kHz bounded buffer, non-silence check, metadata-only IPC, and discard command.
- **Verification:** Rust all-target tests and TypeScript typecheck pass.
- **Committed in:** `b0a47d2`

## Issues Encountered

- The task's documented `cargo test ... inference::benchmark` filter matches no integration-test names; the required benchmark suite was also run directly with `--test benchmark` and passed.
- No sealed worker binaries, verified model bytes, target endpoint, GPU, or driver are present. No target-PC outcome was invented; the outstanding local sample/hardware run is entry 6 in `.planning/WINDOWS.md`.

## Known Stubs

None. The absent worker state is an explicit fail-closed evidence outcome, not a passing placeholder.

## Verification

- Passed: `powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml --test benchmark"` (4 tests)
- Passed: `powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml --all-targets"` (23 tests)
- Passed: `npm run typecheck`
- Pending target PC: record the user-owned clean Vietnamese sample and run the sealed CPU plus physically available CUDA/Vulkan candidates. The ledger records this as open, and no profile is claimed.

## Next Phase Readiness

Plan 07 can consume the temporary sample handle, `InferenceProfile` evidence type, and the fail-closed matrix to make the setup transaction and Ready state authoritative. It must delete the temporary sample after cancellation or transaction resolution.

## Self-Check: PASSED

- Confirmed benchmark engine, native command, setup profile, capture, UI components, and benchmark test files exist.
- Confirmed commits `9300054`, `8114486`, and `b0a47d2` exist.

---
*Phase: 01-windows-capture-inference-feasibility*
*Completed: 2026-08-19*
