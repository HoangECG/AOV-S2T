---
phase: 01-windows-capture-inference-feasibility
plan: "08"
subsystem: windows-audio-capture
tags: [wasapi, loopback, endpoint-validation, powershell, tauri]
dependency_graph:
  requires:
    - phase: 01-03
      provides: exact endpoint catalogue and selected-source capture lifecycle
  provides:
    - shared event-driven WASAPI loopback configuration for selected render endpoints
    - native active-catalogue validation of source selection
    - fail-closed Windows Core Audio acceptance probe
  affects: [target-pc-audio-verification, setup-readiness]
actuals:
  tokens: 4731
  tasks: 2
  commits: 2
tech-stack:
  added: []
  patterns: [render-endpoint plus capture-direction loopback, native-catalogue-derived selection]
key-files:
  created: []
  modified: [src-tauri/src/audio/capture.rs, src-tauri/src/commands/audio.rs, src-tauri/tests/source_config.rs, scripts/test-windows-audio.ps1]
key-decisions:
  - "A DesktopLoopback source opens a Render AudioClient but initializes it with Direction::Capture and EventsShared, which is the wasapi 0.24.0 shared loopback tuple."
  - "The native catalogue supplies the authoritative source kind and display name; client labels are ignored."
requirements-completed: [CAPT-01, CAPT-02, CAPT-03]
coverage:
  - id: D1
    description: Exact selected input/render source configuration and native selection validation.
    requirement: CAPT-01
    verification:
      - kind: unit
        ref: cargo test --manifest-path src-tauri/Cargo.toml --test source_config
        status: pass
    human_judgment: false
  - id: D2
    description: Shared event-loopback Core Audio probe rejects unproven default changes, signal, and invalidation checks.
    requirement: CAPT-02
    verification:
      - kind: other
        ref: powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows-audio.ps1 -ListOnly
        status: pass
    human_judgment: true
    rationale: Selected-render signal, endpoint invalidation, and default-device-change evidence require target hardware and an operator.
  - id: D3
    description: Loss keeps the selected exact ID and marks it unavailable without choosing a default replacement.
    requirement: CAPT-03
    verification:
      - kind: unit
        ref: src-tauri/tests/source_config.rs#invalidation_stops_the_selected_source_but_default_change_does_not_replace_it
        status: pass
    human_judgment: false
metrics:
  duration: 22min
  completed: 2026-08-19
status: complete
---

# Phase 01 Plan 08: Selected render WASAPI loopback Summary

Selected render endpoints now use wasapi's shared event-driven capture tuple for desktop loopback, while native active-catalogue validation rejects forged, stale, inactive, and kind-mismatched selections.

## Accomplishments

- Replaced the disconnected loopback label with a `WasapiCaptureConfig` consumed by `run_capture`; it checks endpoint data flow, creates `EventsShared` with `autoconvert: false`, verifies shared/event mode, and obtains an `AudioCaptureClient`.
- Re-enumerated the native catalogue at selection time and derived the selected source from its unique active entry instead of trusting a client display name.
- Made the Windows probe assert production's exact loopback tuple and open Core Audio with shared, event-callback, and loopback flags only for render endpoints.

## Verification

- PASS: `powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml --test source_config"` (7 tests).
- PASS: `powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml --test meter"` (4 tests).
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows-audio.ps1 -ListOnly`.

## Task Commits

1. **Task 1: Drive one exact render endpoint through the production loopback branch** — `df45fbb` (`fix`)
2. **Task 2: Make the Windows audio probe observe the repaired production contract** — `0a69f7a` (`test`)

## Files Created/Modified

- `src-tauri/src/audio/capture.rs` — production-consumed WASAPI tuple and shared/event post-initialization checks.
- `src-tauri/src/commands/audio.rs` — exact active native-catalogue selection boundary.
- `src-tauri/tests/source_config.rs` — regression coverage for loopback configuration and forged/stale selection rejection.
- `src-tauri/tests/meter.rs` — updated prior seam coverage to the production configuration.
- `scripts/test-windows-audio.ps1` — fail-closed Core Audio event-loopback probe.

## Decisions Made

- Render endpoint direction identifies the selected device; capture direction identifies the packet-producing WASAPI stream. Passing render direction to `initialize_client` is rejected as playback evidence.
- Default-device notifications never replace the selected opaque endpoint ID.

## Deviations from Plan

### Auto-fixed Issues

1. [Rule 3 - Blocking issue] Updated the prior `meter` test after replacing its obsolete `CaptureOpenMode` seam.
   - **Found during:** Task 1.
   - **Fix:** Asserted the production `WasapiCaptureConfig` endpoint/capture directions instead.
   - **Verification:** `cargo test --test meter` passes.
   - **Committed in:** `df45fbb`.

## TDD Gate Compliance

- The implementation tests pass, but Task 1 has no separate `test(...)` RED commit; its regression coverage and implementation are in the same feature commit.

## Known Stubs

None.

## Next Phase Readiness

The target-PC run still needs operator evidence for selected-render signal, silence, invalidation, and default-device change; the probe now exits nonzero when those checks are not proved.

## Self-Check: PASSED

- Verified the modified source, command, tests, and Windows probe exist.
- Verified commits `df45fbb` and `0a69f7a` exist.
