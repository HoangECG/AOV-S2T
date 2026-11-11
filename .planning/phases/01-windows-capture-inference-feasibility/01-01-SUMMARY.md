---
phase: 01-windows-capture-inference-feasibility
plan: "01"
subsystem: windows-audio-tracer
tags: [tauri, react, wasapi, pcm, windows]
dependency_graph:
  requires: []
  provides: [selected-source-contract, wasmapi-input-meter, tauri-audio-events]
  affects: [01-02, 01-03]
tech_stack:
  added: [Tauri 2, React 19, Vite 8, TypeScript 7, wasapi 0.24]
  patterns: [exact-endpoint-id, local-command-event-boundary, bounded-pcm-meter]
key_files:
  created: [package.json, src/App.tsx, src-tauri/src/audio/tracer.rs]
  modified: [src-tauri/src/main.rs]
decisions:
  - "The selected Windows endpoint ID is opaque and is never derived from its friendly name."
  - "The tracer uses a local Tauri command/event boundary and never transmits or persists PCM."
metrics:
  duration: "implementation session"
  completed: 2026-08-19
status: complete
actuals:
  tokens: 4800
  tasks: 2
  commits: 3
---

# Phase 01 Plan 01: Windows input PCM tracer Summary

Tauri/React setup shell with an exact-input WASAPI capture path that emits local captured-PCM signal states to the UI.

## Completed

- Added a minimal Tauri 2, React, TypeScript, and Vite desktop scaffold with generated Windows icon and reproducible lockfiles.
- Added typed source and level-event contracts, endpoint enumeration by opaque Windows endpoint ID, and a shared event-driven WASAPI input capture thread.
- Kept PCM bounded in memory, calculated peak/RMS from captured samples, emitted `Signal`, `Silent`, or `Unavailable`, and did not add network, logging, persistence, loopback, caption, translation, or overlay behavior.
- Added UI controls for one `Microphone / Input` selection and an empty `Desktop / System Audio` group label.
- Enforced D-03 by rejecting a source selection while capture is active; stopping joins the capture worker before a new selection can proceed.

## Verification

- PASS: `powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml audio::tracer"` — 3 unit tests passed.
- PASS: `powershell.exe -NoProfile -Command "npm.cmd run typecheck"`.
- PENDING MANUAL WINDOWS CHECK: Run `npm.cmd run tauri -- dev`, choose a real microphone, verify the selected label and moving PCM meter, then stop before choosing another source. The automated environment has the Windows toolchain but no verified physical input-device session was performed.

## Decisions Made

- Endpoint identity is serialized and compared only as its exact opaque ID; a friendly label is display-only.
- The initial tracer captures only `Microphone / Input`; desktop loopback remains deliberately deferred.

## Deviations from Plan

### Auto-fixed Issues

1. [Rule 3 - Blocking issue] Added `.gitignore` for `node_modules`, `dist`, and `src-tauri/target`.
   - **Reason:** Tauri and npm generated local build artifacts that must not be source-controlled.
   - **Commit:** `35d39ac`

2. [Rule 3 - Blocking issue] Added `src/main.tsx` and the minimal Windows icon inputs.
   - **Reason:** The React/Tauri bootstrap and Tauri Windows resource build require these scaffold files.
   - **Commit:** incorporated in the pre-existing scaffold commit `63e8971`.

### Execution Notes

The pre-existing commit `63e8971` included the initial scaffold plus generated build artifacts before this executor could make the required RED commit. This executor subsequently added the ignore rules and removed those generated artifacts from Git tracking in `35d39ac`; it did not alter the unrelated planning change in that earlier commit.

## Known Stubs

None. The visible `Desktop / System Audio` label is an intentional, explicitly deferred Phase-1 boundary rather than a nonfunctional replacement for the selected-input tracer.

## Self-Check: PASSED

- `src/App.tsx`, `src-tauri/src/main.rs`, and `src-tauri/src/audio/tracer.rs` exist.
- Commits `38ca9ca`, `9782631`, and `35d39ac` exist.
