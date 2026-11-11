---
phase: 01-windows-capture-inference-feasibility
plan: "02"
subsystem: windows-audio-capture
tags: [tauri, rust, wasapi, loopback, pcm, metering]
dependency_graph:
  requires:
    - phase: 01-01
      provides: Tauri desktop scaffold and exact-input tracer contract
  provides: [exact-source-selection, selected-render-wasapi-loopback, normalized-pcm-metering]
  affects: [01-03, windows-audio-harness, setup-wizard]
actuals:
  tokens: 7952
  tasks: 2
  commits: 4
tech_stack:
  added: []
  patterns: [opaque-endpoint-id, nonblocking-device-notifications, one-active-stream, bounded-pcm-normalization]
key_files:
  created: [src-tauri/src/audio/capture.rs, src-tauri/src/audio/pcm.rs, src-tauri/src/audio/meter.rs, src-tauri/tests/source_config.rs, src-tauri/tests/meter.rs]
  modified: [src-tauri/src/audio/endpoints.rs, src-tauri/src/audio/source.rs, src-tauri/src/commands/audio.rs, src-tauri/src/main.rs]
decisions:
  - "Source identity is SourceKind plus the exact opaque Windows endpoint ID; display labels are never authoritative."
  - "Desktop audio opens shared WASAPI capture on the selected render endpoint, which enables loopback without Stereo Mix."
  - "Endpoint loss, discontinuity, and missing packets fail closed as Unavailable rather than selecting a Windows default."
requirements-completed: [CAPT-01, CAPT-02, CAPT-03]
coverage:
  - id: D1
    description: Exact single-source selection, serialisation, grouping, and active-capture conflict handling.
    requirement: CAPT-01
    verification:
      - kind: unit
        ref: src-tauri/tests/source_config.rs
        status: pass
    human_judgment: false
  - id: D2
    description: Selected-render shared WASAPI loopback and endpoint-loss behavior.
    requirement: CAPT-02
    verification:
      - kind: unit
        ref: src-tauri/tests/meter.rs
        status: pass
      - kind: manual_procedural
        ref: target-PC WASAPI hardware check
        status: unknown
    human_judgment: true
    rationale: Physical Windows render hardware is required to confirm real loopback and hot-unplug behavior.
  - id: D3
    description: Normalized captured-PCM peak/RMS with Signal, Silent, and Unavailable states.
    requirement: CAPT-03
    verification:
      - kind: unit
        ref: src-tauri/tests/meter.rs
        status: pass
    human_judgment: false
metrics:
  duration: "implementation session"
  completed: 2026-08-19
status: complete
---

# Phase 01 Plan 02: Exact Windows source capture Summary

Exact endpoint selection now drives one shared WASAPI input or selected-render loopback stream, normalized to bounded 16 kHz mono PCM with honest level and loss states.

## Accomplishments

- Added separate active microphone and render catalogues while retaining one exact `SelectedSource` slot across them.
- Added nonblocking MMDevice notification callbacks that enqueue only; capture processing stops the selected stream on removal/invalidation and ignores Windows default changes.
- Added selected-render shared loopback, endpoint-format decoding, downmix/resample to signed 16-bit 16 kHz mono, and PCM-derived peak/RMS/silence state.
- Replaced the input-only tracer runtime path with typed Tauri commands that return Vietnamese recovery copy plus technical diagnostics.

## Verification

- PASS: `cargo test --manifest-path src-tauri/Cargo.toml --test source_config` — 5 source-selection/lifecycle tests.
- PASS: `cargo test --manifest-path src-tauri/Cargo.toml --test meter` — 4 PCM, meter, and source-routing tests.
- PASS: `cargo test --manifest-path src-tauri/Cargo.toml` — full Rust suite.
- PASS: `npm run typecheck`.
- PENDING TARGET-PC CHECK: Play known desktop audio on a selected render endpoint, confirm level movement without Stereo Mix, then unplug/disable it and confirm capture becomes unavailable without changing to a default device. This is recorded in `.planning/WINDOWS.md`.

## Task Commits

1. Task 1 RED — `2ae6790` `test(01-02): add failing source selection contracts`
2. Task 1 GREEN — `1efcb27` `feat(01-02): add exact audio source selection`
3. Task 2 RED — `b8fcc19` `test(01-02): add failing PCM meter contracts`
4. Task 2 GREEN — `fdd41e6` `feat(01-02): capture selected input and render loopback`

## Decisions Made

- The exact endpoint ID and source kind are persisted and compared verbatim; names only support display.
- Render-loopback uses the selected render endpoint with shared WASAPI capture rather than any driver loopback device.
- PCM and notifications stay bounded in-memory and no raw audio or transcript content is logged or persisted.

## Deviations from Plan

### Auto-fixed Issues

1. [Rule 1 - Bug] Preserved short normalized packets and consumed only returned capture frames.
   - **Found during:** Task 2
   - **Issue:** Floor-rounded resampling dropped a short 44.1 kHz packet, and an untrimmed WASAPI buffer would include unwritten zero bytes in meter input.
   - **Fix:** Used ceiling output sizing and truncated each packet to the returned frame count before decoding.
   - **Files modified:** `src-tauri/src/audio/pcm.rs`, `src-tauri/src/audio/capture.rs`
   - **Verification:** `src-tauri/tests/meter.rs` passes.
   - **Committed in:** `fdd41e6`

2. [Rule 2 - Missing critical functionality] Registered notifications and fail-closed on no-packet/discontinuity states.
   - **Found during:** Task 2
   - **Issue:** The first capture implementation did not yet bind the nonblocking notification adapter to the active stream lifecycle or reject an empty signalled capture cycle.
   - **Fix:** Registered `DeviceEventCallbacks`, drained their bounded queue off-callback, and transitioned the selected stream to `Unavailable` on invalidation, discontinuity, or no packets.
   - **Files modified:** `src-tauri/src/audio/endpoints.rs`, `src-tauri/src/audio/capture.rs`
   - **Verification:** Rust source-config and meter tests pass.
   - **Committed in:** `fdd41e6`

3. [Rule 3 - Blocking issue] Introduced the Rust library/command boundary and removed the obsolete tracer runtime module.
   - **Found during:** Task 1
   - **Issue:** Plan 01's single binary-only tracer could not be imported by integration tests or expose the complete command contract.
   - **Fix:** Added the minimal library and command modules, migrated the entry point, and removed the replaced tracer implementation.
   - **Files modified:** `src-tauri/src/lib.rs`, `src-tauri/src/commands/`, `src-tauri/src/main.rs`, `src-tauri/src/audio/tracer.rs`
   - **Verification:** full Rust suite and TypeScript check pass.
   - **Committed in:** `1efcb27`, `fdd41e6`

**Impact:** All deviations are correctness or integration necessities; no extra source, mixing, driver-loopback, persistence, caption, or network behavior was added.

## Known Stubs

None.

## Next Phase Readiness

Plan 03 can render both endpoint catalogues and invoke the typed native commands. The Windows-only selected-render loopback and device-loss acceptance check remains open for a target PC.

## Self-Check: PASSED

- All listed Rust modules and integration tests exist.
- Commits `2ae6790`, `1efcb27`, `b8fcc19`, and `fdd41e6` exist.
