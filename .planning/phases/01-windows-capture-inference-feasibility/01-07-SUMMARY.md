---
phase: 01-windows-capture-inference-feasibility
plan: "07"
subsystem: setup-readiness
tags: [tauri, rust, react, setup, diagnostics, verification]
requires:
  - phase: 01-06
    provides: bounded benchmark sample and profile evidence contract
provides:
  - fail-closed ordered setup transaction with atomic known-good config writes
  - native-authoritative readiness and non-content diagnostics snapshots
  - Vietnamese setup/readiness UI states and a target-PC verification entry point
affects: [phase-02, caption-session, diagnostics]
actuals:
  tokens: 11556
  tasks: 3
  commits: 5
tech-stack:
  added: []
  patterns: [candidate-versus-known-good, native-readiness-authority, content-free-diagnostics, target-pc-evidence-ledger]
key-files:
  created: [src-tauri/src/setup/config.rs, src-tauri/src/setup/state.rs, src-tauri/src/diagnostics.rs, src-tauri/src/commands/setup.rs, src-tauri/tests/setup_transaction.rs, src-tauri/tests/setup_flow.rs, src-tauri/tests/readiness.rs, src/components/ReadinessDashboard.tsx, scripts/verify-phase1.ps1]
  modified: [src-tauri/src/setup/mod.rs, src-tauri/src/main.rs, src/App.tsx, src/components/SetupWizard.tsx, src/styles.css]
key-decisions:
  - "Ready remains fail-closed: a saved configuration cannot become Ready without current model/profile/fixture/signal/caption predicates."
  - "Temporary sample identifiers are candidate-only and never serialize into KnownGoodConfig or diagnostic snapshots."
  - "No target-PC source, model, worker, profile, fixture run, or Vietnamese caption is claimed from this checkout."
requirements-completed: []
coverage:
  - id: D1
    description: "Ordered setup transaction preserves last-known-good configuration and excludes temporary source/sample data."
    requirement: CAPT-01
    verification:
      - kind: unit
        ref: "src-tauri/tests/setup_transaction.rs and src-tauri/tests/setup_flow.rs"
        status: unknown
    human_judgment: true
    rationale: "The test executables cannot run in this environment (Windows os error 740); compilation succeeds but target-PC state remains required."
  - id: D2
    description: "Native readiness snapshot blocks stale predicates and exposes bounded non-content diagnostics."
    requirement: CAPT-03
    verification:
      - kind: unit
        ref: "src-tauri/tests/readiness.rs"
        status: unknown
    human_judgment: true
    rationale: "Runtime test execution is blocked by the local Windows permission boundary."
  - id: D3
    description: "Readiness UI and verification harness provide explicit blocked/unavailable/ready states and target-PC evidence procedure."
    requirement: AI-03
    verification:
      - kind: other
        ref: "npm run typecheck; cargo test --manifest-path src-tauri/Cargo.toml --all-targets --no-run"
        status: pass
    human_judgment: true
    rationale: "Actual endpoint capture, model checksum, sealed worker, benchmark, and Vietnamese test-caption proof require the target Windows PC."
completed: 2026-08-19
status: complete
---

# Phase 01 Plan 07: Transactional Setup and Truthful Readiness Summary

**Fail-closed native setup state, atomic known-good configuration seam, non-content readiness diagnostics, and a Vietnamese readiness UI without fabricated target-PC evidence.**

## Performance

- **Duration:** 32 min
- **Tasks:** 3/3
- **Files modified:** 16

## Accomplishments

- Added a four-step setup state machine, candidate-only temporary sample data, readiness predicates, and atomic validated configuration replacement.
- Added native-only readiness routing plus bounded diagnostics that preserve the selected endpoint identity on source loss and never expose audio/sample/transcript data.
- Added blocked, unavailable, and ready dashboard states, setup cancellation UI, and `verify-phase1.ps1` Static/TargetPc modes.

## Task Commits

1. **Task 1 RED: setup transaction tests** — `9392db3` (test)
2. **Task 1 GREEN: transactional known-good setup** — `c3ef2a7` (feat)
3. **Task 2 RED: readiness tests** — `a0b6d1a` (test)
4. **Task 2 GREEN: native readiness snapshots** — `a6a8e17` (feat)
5. **Task 3: readiness UI and verification harness** — `5b6e8dc` (feat)

## Decisions Made

- Candidate setup data is separate from the persisted schema, and only a fully passing candidate reaches the atomic write seam.
- Current configuration cannot be silently promoted to Ready: all native predicates, including source signal and separate Vietnamese caption completion, are required.
- Target-PC evidence is an explicit ledger item, not a placeholder pass or fabricated dashboard state.

## Deviations from Plan

None - implementation remained within the plan-owned setup, diagnostics, UI, tests, and verification files.

## Issues Encountered

- Rust test executables compile but cannot launch here because Windows reports `os error 740` (elevation required). `--no-run` compilation succeeded.
- `verify-phase1.ps1 -Mode Static` reaches `npm run typecheck` but this Windows shell cannot resolve `tsc` from the workspace's current dependency installation. Bash `npm run typecheck` and `npm run build` both pass.
- The checkout has no target endpoint, checksum-ready installed model, sealed worker sidecars, GPU/driver, benchmark sample, or official-source Vietnamese caption. Entry 7 in `.planning/WINDOWS.md` records the complete target-PC verification requirement.

## Known Stubs

None. The disabled completion path is an intentional fail-closed state while the native sidecar/model/target-PC evidence is absent; it is not reported as Ready.

## Verification

- Passed: `npm run typecheck`
- Passed: `npm run build`
- Passed: `powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml --all-targets --no-run"`
- Blocked environment execution: `cargo test --manifest-path src-tauri/Cargo.toml --test setup_transaction --test setup_flow` and `--test readiness` cannot start Windows executables (`os error 740`).
- Pending target PC: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/verify-phase1.ps1 -Mode TargetPc ...`; the required redacted checks are listed in the script and Windows ledger.

## Next Phase Readiness

Later phases can consume the authoritative setup/readiness snapshot types and must keep all live-caption content out of diagnostics. Phase 1 is not hardware-proven until the open Windows ledger entries are completed on the target PC.

## Self-Check: PASSED

- Confirmed commits `9392db3`, `c3ef2a7`, `a0b6d1a`, `a6a8e17`, and `5b6e8dc` exist.
- Confirmed all created setup, diagnostics, readiness UI, test, and verification-script files exist.
