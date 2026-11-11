---
phase: 01-windows-capture-inference-feasibility
plan: "05"
subsystem: inference
tags: [whisper.cpp, windows, worker-protocol, sha256, powershell]
requires:
  - phase: 01-04
    provides: pinned large-v3 model manifest and verified-model lifecycle
provides:
  - CPU, CUDA, and Vulkan worker build identities with an immutable source/model contract
  - checksummed CC0 Vietnamese 16 kHz mono self-test fixture and provenance record
  - bounded fixed-path worker admission with typed evidence
affects: [01-06, 01-07, backend-benchmarking, readiness]
actuals:
  tokens: 21858
  tasks: 2
  commits: 4
tech-stack:
  added: [PowerShell build/harness scripts]
  patterns: [sealed-worker-inventory, bounded-json-sidecar-protocol, exact-transcript-self-test]
key-files:
  created: [workers/manifest.json, workers/fixtures/vi-self-test-16khz.wav, scripts/test-workers.ps1, src-tauri/src/inference/runner.rs, src-tauri/tests/worker_protocol.rs]
  modified: [src-tauri/src/inference/mod.rs]
key-decisions:
  - "Source control keeps only reproducible build declarations; worker binaries require a sealed release inventory before any admission."
  - "The self-test fixture is Penn Zero MSSJ's CC0 Lingua Libre recording, resampled to 16 kHz mono PCM."
  - "Nonempty transcripts never imply a pass; normalized output must exactly match the checksummed expectation."
patterns-established:
  - "Runner accepts only fixed, checksummed paths beneath the worker inventory; child arguments are supplied without a shell."
  - "Worker output uses a capped, deny-unknown-fields JSON schema with non-content typed diagnostics."
requirements-completed: [AI-03]
coverage:
  - id: D1
    description: CPU/CUDA/Vulkan source and fixture inventory is checksummed and provenance-validated.
    requirement: AI-03
    verification:
      - kind: other
        ref: powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-workers.ps1 -Mode ManifestOnly
        status: pass
    human_judgment: false
  - id: D2
    description: Fixed sealed worker admission rejects incompatible inventory and nonexact protocol evidence.
    requirement: AI-03
    verification:
      - kind: unit
        ref: src-tauri/tests/worker_protocol.rs
        status: pass
    human_judgment: false
  - id: D3
    description: Real CPU/CUDA/Vulkan candidate smoke admission on the intended Windows target PC.
    requirement: AI-03
    verification:
      - kind: manual_procedural
        ref: powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-workers.ps1 -Mode Candidate -Candidate cpu|cuda|vulkan -ModelPath <verified-model>
        status: unknown
    human_judgment: true
    rationale: CUDA/Vulkan drivers, the sealed release worker files, and the target PC model are not available in this checkout.
duration: 9min
completed: 2026-08-19
status: complete
---

# Phase 01 Plan 05: Pinned Worker Admission Summary

**A pinned CPU/CUDA/Vulkan worker contract now gates a CC0 Vietnamese exact-transcript self-test through a bounded, fixed-path JSON process boundary.**

## Performance

- **Duration:** 9 min
- **Started:** 2026-08-19T12:52:31Z
- **Completed:** 2026-08-19T13:01:23Z
- **Tasks:** 2/2
- **Files modified:** 8

## Accomplishments

- Declared reproducible x64 CPU, CUDA, and Vulkan `whisper.cpp` build targets tied to the exact Plan 04 model revision, without checking large worker binaries into source control.
- Added a checksummed 16 kHz mono signed-16-bit Vietnamese fixture from Penn Zero MSSJ's CC0 Lingua Libre recording, with the source, grant, phrase, transform, and expected-transcript hash committed alongside it.
- Added an admission runner that validates sealed inventory, fixed paths, host/model compatibility, PCM fixture integrity, capped strict JSON, exit/timing, and exact normalized transcript equality without putting transcript content in failure diagnostics.

## Task Commits

1. **Task 1: Produce pinned CPU, CUDA, and Vulkan worker artifacts** — `a1101ed` (feat)
2. **Task 2 RED: Admit only fixed manifest-listed workers through a bounded protocol** — `21ebf68` (test)
3. **Task 2 GREEN: Admit only fixed manifest-listed workers through a bounded protocol** — `63abd1c` (feat)
4. **Task 2 correction: report unsealed candidate status accurately** — `7ce3470` (fix)

## Files Created/Modified

- `workers/manifest.json` — pinned worker/model/fixture declaration; its `build-required` state cannot be admitted by the runner.
- `workers/fixtures/vi-self-test-16khz.wav` — CC0 source recording resampled to 16 kHz mono PCM.
- `workers/fixtures/vi-self-test.expected.json` — normalized phrase and complete provenance metadata.
- `scripts/build-workers.ps1` — pinned source checkout and separately labelled CPU/CUDA/Vulkan build pipeline.
- `scripts/test-workers.ps1` — manifest/provenance validator and real-candidate smoke harness.
- `src-tauri/src/inference/runner.rs` — safe sidecar preflight, execution, strict parser, and self-test evidence.
- `src-tauri/tests/worker_protocol.rs` — TDD coverage for inventory, protocol, and transcript failures.

## Decisions Made

- Binaries remain outside Git; a candidate must be sealed with complete checksums before `InferenceRunner` can launch it.
- CUDA/Vulkan absence is reported as `not present`, not as a pass or an implicit CPU success.
- The text normalizer is deliberately narrow and shared: trim, lowercase, and collapse Unicode whitespace; the committed expected asset stores its exact normalized result and hash.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed PowerShell candidate-presence validation**
- **Found during:** Task 2 verification
- **Issue:** PowerShell attempted to coerce the candidate string directly to a Boolean before emitting the intended `not present` status.
- **Fix:** Explicitly test that the candidate string is nonempty.
- **Files modified:** `scripts/test-workers.ps1`
- **Verification:** Candidate CPU mode now returns `not present: cpu is not sealed with checksummed release files.`
- **Committed in:** `7ce3470`

---

**Total deviations:** 1 auto-fixed (Rule 1)
**Impact on plan:** The correction preserves the fail-closed candidate evidence contract with no scope expansion.

## Issues Encountered

- The repository intentionally has no sealed CPU/CUDA/Vulkan sidecar binary, target GPU driver, or installed large-v3 model. The harness verifies this as `build-required`/`not present`; no worker was claimed as passed.

## Known Stubs

None. The unsealed worker state is an intentional admission boundary, not a worker implementation placeholder; it cannot report a passing backend.

## Verification

- Passed: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-workers.ps1 -Mode ManifestOnly`
- Passed: `cargo test --manifest-path src-tauri/Cargo.toml --test worker_protocol` (4 tests)
- Passed: `cargo test --manifest-path src-tauri/Cargo.toml --all-targets` (19 tests)
- Target-PC only: `scripts/test-workers.ps1 -Mode Candidate` reports the current unsealed CPU candidate as `not present`; CUDA/Vulkan GPU admission has not been run because required sealed sidecars, model bytes, and target hardware are absent.

## Next Phase Readiness

Plan 06 can consume `InferenceRunner::self_test` as a correctness gate before benchmarking or CPU fallback. A release build must first seal the generated worker inventory and run candidate smoke tests on the target Windows hardware; that evidence remains intentionally outstanding.

## Self-Check: PASSED

- Confirmed all worker manifest, fixture, build/harness, runner, protocol test, and summary files exist.
- Confirmed task commits `a1101ed`, `21ebf68`, `63abd1c`, and `7ce3470`, plus summary commit `42e92d0`, are present in Git history.

---
*Phase: 01-windows-capture-inference-feasibility*
*Completed: 2026-08-19*
