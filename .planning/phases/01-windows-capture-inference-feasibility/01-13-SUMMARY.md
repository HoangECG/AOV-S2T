---
phase: 01-windows-capture-inference-feasibility
plan: "13"
subsystem: verification
tags: [windows, cng, hmac, tauri, target-pc, powershell]
requires:
  - phase: 01-12
    provides: native audio, benchmark, and setup command results
provides:
  - CNG-random one-shot receipt protocol with chained HMAC authentication
  - Direct pinned-driver TargetPc launcher without serialized-evidence import
  - Native handler receipt hooks and fail-closed static contract checks
affects: [01-14, target-pc-evidence, phase-verification]
actuals:
  tokens: 11850
  tasks: 3
  commits: 4
tech-stack:
  added: []
  patterns: [driver-owned ephemeral bootstrap, content-free receipt digests, create-new report output]
key-files:
  created: [src-tauri/src/verification.rs, src-tauri/src/bin/phase1-evidence-driver.rs, scripts/invoke-phase1-target.ps1, scripts/test-verification-contract.ps1]
  modified: [src-tauri/src/commands/audio.rs, src-tauri/src/commands/benchmark.rs, src-tauri/src/commands/setup.rs, scripts/verify-phase1.ps1]
key-decisions:
  - "A SHA-256 receipt chain is integrity metadata only; a CNG-generated HMAC session authenticates live frames."
  - "The target launcher accepts operational selections only and fails before launch until a reviewed Windows binary pair supplies the pins."
  - "The durable report is an audit record, not evidence against same-user code replacement, process-memory access, injection/debugging, or post-run editing."
patterns-established:
  - "Native verification values do not cross Tauri IPC; driver bootstrap travels only on private inherited stdio."
  - "TargetPc has no JSON/evidence import mode and will not overwrite a prior report."
requirements-completed: [CAPT-01, CAPT-02, CAPT-03, AI-03]
coverage:
  - id: D1
    description: Content-free session, HMAC receipt, replay, mutation, and complete-order validation.
    requirement: CAPT-01
    verification:
      - kind: unit
        ref: "powershell.exe -NoProfile -Command '& cargo test --manifest-path src-tauri/Cargo.toml --lib'"
        status: pass
    human_judgment: false
  - id: D2
    description: Independently pinned TargetPc launch and report generation from a live Windows app run.
    requirement: AI-03
    verification:
      - kind: manual_procedural
        ref: "scripts/invoke-phase1-target.ps1 after a reviewed app/driver pair is built on the target PC"
        status: unknown
    human_judgment: true
    rationale: Target hardware, reviewed binary pins, real endpoints, and real setup lifecycle are intentionally not synthesized in this environment.
duration: 61min
completed: 2026-08-19
status: complete
---

# Phase 01 Plan 13: Native Target-PC Evidence Summary

**CNG-HMAC-authenticated native receipt protocol and a fail-closed TargetPc launcher that has no serialized-evidence import path.**

## Accomplishments

- Added strict operational target inputs, chained authenticated native receipts, redacted report types, replay/mutation tests, and an explicit local threat-model boundary.
- Added a fixed-path driver that requires a compile-time app SHA-256 pin, creates a one-shot CNG session, launches the app through private stdio, validates receipt order, and writes a new report only after all predicates pass.
- Bound audio selection/capture, benchmark/PCM cleanup, and setup results to native receipt emission; PowerShell only validates operational input and the independently pinned driver bytes.
- Added static regression checks showing that fabricated/rehashed envelopes and caller-selected provenance have no TargetPc acceptance path.

## Task Commits

1. **Task 1: Authenticate one native command receipt through the pinned one-shot driver** — `c66f48e` (feat)
2. **Task 2: Record the registered audio, benchmark, setup, restart, drift, and Ready path** — `8d67d6e` (feat)
3. **Task 3: Delegate TargetPc directly to the pinned driver and reject every serialized-evidence substitute** — `558e05e` (test), `5992e1d` (fix)

## Verification

- Passed: `cargo test --manifest-path src-tauri/Cargo.toml --lib` (5 protocol/transport tests).
- Passed: `scripts/test-verification-contract.ps1`.
- Not claimed: a TargetPc report or hardware result. The launcher intentionally refuses its `UNREVIEWED_BUILD_REQUIRES_WINDOWS_BINARY_REVIEW` pin until the reviewed Windows app/driver pair is built and its real hashes are inserted.
- The aggregate `scripts/verify-phase1.ps1 -Mode Static` began successfully through TypeScript checking and Cargo compilation, but its all-target test completion could not be captured in this execution host; Plan 01-14 must rerun it on the target Windows PC before producing evidence.

## Deviations from Plan

### Auto-fixed Issues

1. **[Rule 1 - Bug] Preserved source identity before native selection consumes it**
- **Found during:** Task 2
- **Issue:** The receipt digest attempted to read a moved `SelectedSource` after native selection.
- **Fix:** Compute the content-free source digest before moving the value.
- **Verification:** Rust library tests compile and pass.
- **Committed in:** `8d67d6e`

2. **[Rule 1 - Bug] Preserved static-check success status for chained callers**
- **Found during:** Task 3
- **Issue:** A static-only PowerShell test left `$LASTEXITCODE` unset, causing callers that chain it to stop before static verification.
- **Fix:** Set a zero native process exit status after static assertions.
- **Verification:** `scripts/test-verification-contract.ps1` passes.
- **Committed in:** `5992e1d`

## Security Boundary

The reviewed launcher, pinned driver/app binaries, and unchanged probes are the local trust base. This closes request-controlled provenance and rehashable-file fabrication; it does not resist a same-user attacker who changes trusted code, reads process memory, injects/debugs either native process, or edits the report after the run.

## Next Phase Readiness

Plan 01-14 must build the Windows app first, compile the driver with the real app hash, review and insert the real driver hash literal, then run the target-PC lifecycle. No target-PC evidence file was created here.

## Self-Check: PASSED

- Verified commits `c66f48e`, `8d67d6e`, `558e05e`, and `5992e1d` exist.
- Verified all created driver, verification, and PowerShell contract files exist.
