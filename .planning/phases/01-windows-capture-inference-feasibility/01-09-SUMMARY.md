---
phase: 01-windows-capture-inference-feasibility
plan: "09"
subsystem: inference
tags: [whisper.cpp, native-worker, sealed-inventory, powershell, rust]
requires:
  - phase: 01-05
    provides: worker declaration, fixture, and bounded host protocol
provides:
  - Repository-owned CPU/CUDA/Vulkan whisper.cpp worker target with compile-time identities
  - Generated-only sealed runtime inventory with per-file SHA-256 admission
  - Fail-closed fixed-path runtime manifest loader and candidate harness
affects: [01-10, 01-12, 01-13, 01-14]
tech-stack:
  added: [CMake, C++17 whisper.cpp wrapper]
  patterns: [generated-sealed-inventory, fixed-runtime-manifest, fail-closed-candidate-admission]
key-files:
  created: [workers/CMakeLists.txt, workers/src/worker_main.cpp]
  modified: [.gitignore, scripts/build-workers.ps1, scripts/test-workers.ps1, src-tauri/src/inference/runner.rs, src-tauri/tests/worker_protocol.rs]
key-decisions:
  - "The committed manifest remains a build declaration; only workers/out/x86_64-pc-windows-msvc/manifest.json may admit a runtime worker."
  - "Every explicitly requested candidate must have a sealed artifact and exact fixture result; absence is an error, never a pass."
metrics:
  duration: 18min
  completed: 2026-08-19
actuals:
  tokens: 6469
  tasks: 2
  commits: 4
status: complete
---

# Phase 01 Plan 09: Protocol Worker and Sealed Admission Summary

**A repository-owned whisper.cpp wrapper now emits the exact bounded worker JSON envelope, and runtime admission reads only a generated sealed inventory.**

## Accomplishments

- Added a CMake C++17 worker that links the pinned whisper.cpp source, accepts only the documented arguments, transcribes local PCM WAV input, and keeps file/audio/transcript details out of diagnostics.
- Replaced renamed-stock-CLI packaging with per-backend repository worker builds plus SHA-256 inventories of each executable and copied runtime DLL.
- Added fixed runtime-inventory loading, immutable source/model identity validation, and fail-closed missing-candidate handling.

## Task Commits

1. **Task 1: Build protocol-speaking worker** — `3dfe290` (feat)
2. **Task 2 RED: Cover sealed runtime admission** — `70d8108` (test)
3. **Task 2 GREEN: Enforce sealed admission and candidate failures** — `1028ed9` (fix)

## Verification

- Passed: `cargo.exe test --manifest-path src-tauri/Cargo.toml --test worker_protocol` through the Windows toolchain (5 passed).
- Passed: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-workers.ps1 -Mode ManifestOnly`.
- Passed: `Candidate -Candidate cpu` without a generated sealed inventory exits nonzero with `not verified`, proving required CPU absence cannot pass.
- Deferred to the target PC: `scripts/build-workers.ps1 -Backend cpu` and real-artifact candidate execution. This environment has no `cmake.exe` or pinned whisper.cpp checkout, so it cannot produce or execute the Windows native worker here.

## Deviations from Plan

### Auto-fixed Issues

1. **[Rule 1 - Bug] Corrected PowerShell interpolation in the build-failure ledger.**
   - **Found during:** Task 1 script syntax check
   - **Fix:** Delimited the backend variable before the colon so the build script parses on Windows PowerShell.
   - **Files modified:** `scripts/build-workers.ps1`

## Known Stubs

None. Native binaries and the sealed inventory are intentionally generated build outputs, not committed placeholders; target-PC admission remains an explicit verification step.

## Self-Check: PASSED

- Confirmed the CMake worker source, build/harness scripts, runtime loader, and protocol tests exist.
- Confirmed task commits `3dfe290`, `70d8108`, and `1028ed9` exist.
