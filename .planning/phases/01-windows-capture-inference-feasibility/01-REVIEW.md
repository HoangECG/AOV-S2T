---
phase: 01-windows-capture-inference-feasibility
reviewed: 2026-08-19T00:00:00Z
depth: standard
files_reviewed: 59
files_reviewed_list:
  - .gitignore
  - index.html
  - package.json
  - scripts/build-workers.ps1
  - scripts/test-windows-audio.ps1
  - scripts/test-workers.ps1
  - scripts/verify-phase1.ps1
  - src-tauri/Cargo.toml
  - src-tauri/build.rs
  - src-tauri/resources/model-manifest.json
  - src-tauri/src/audio/capture.rs
  - src-tauri/src/audio/endpoints.rs
  - src-tauri/src/audio/meter.rs
  - src-tauri/src/audio/mod.rs
  - src-tauri/src/audio/pcm.rs
  - src-tauri/src/audio/source.rs
  - src-tauri/src/commands/audio.rs
  - src-tauri/src/commands/benchmark.rs
  - src-tauri/src/commands/mod.rs
  - src-tauri/src/commands/model.rs
  - src-tauri/src/commands/setup.rs
  - src-tauri/src/diagnostics.rs
  - src-tauri/src/inference/benchmark.rs
  - src-tauri/src/inference/download.rs
  - src-tauri/src/inference/manifest.rs
  - src-tauri/src/inference/mod.rs
  - src-tauri/src/inference/runner.rs
  - src-tauri/src/lib.rs
  - src-tauri/src/main.rs
  - src-tauri/src/setup/config.rs
  - src-tauri/src/setup/mod.rs
  - src-tauri/src/setup/profile.rs
  - src-tauri/src/setup/state.rs
  - src-tauri/tauri.conf.json
  - src-tauri/tests/benchmark.rs
  - src-tauri/tests/manifest.rs
  - src-tauri/tests/meter.rs
  - src-tauri/tests/readiness.rs
  - src-tauri/tests/setup_flow.rs
  - src-tauri/tests/setup_transaction.rs
  - src-tauri/tests/source_config.rs
  - src-tauri/tests/worker_protocol.rs
  - src/App.tsx
  - src/components/BenchmarkStep.tsx
  - src/components/DevicePicker.tsx
  - src/components/DiagnosticPanel.tsx
  - src/components/LevelMeter.tsx
  - src/components/ModelDownloadStep.tsx
  - src/components/ReadinessDashboard.tsx
  - src/components/SetupWizard.tsx
  - src/main.tsx
  - src/styles.css
  - src/vite-env.d.ts
  - tsconfig.app.json
  - tsconfig.json
  - tsconfig.node.json
  - vite.config.ts
  - workers/fixtures/vi-self-test.expected.json
  - workers/manifest.json
findings:
  critical: 5
  warning: 2
  info: 0
  total: 7
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-08-19T00:00:00Z
**Depth:** standard
**Files Reviewed:** 59
**Status:** issues_found

## Summary

The Phase 01 source was reviewed against all seven plan summaries, including the Windows audio path, model/worker boundary, benchmark path, setup/readiness state, UI, and verification scripts. The frontend typecheck and production build pass. Rust compilation could not be run in this environment because `cargo` is unavailable.

The key Phase 01 flows are not wired end-to-end: selected render devices do not enable WASAPI loopback; the UI never invokes the worker/benchmark engine or commits setup; and cancellation leaves captured benchmark PCM resident. The worker build and target-PC verifier also cannot prove the claimed worker protocol.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: Desktop source never enables WASAPI loopback

**File:** `src-tauri/src/audio/capture.rs:145-154`

**Issue:** Every selected device, including `SourceKind::DesktopLoopback`, is initialized with `Direction::Capture`. `capture_direction()` only returns a test-only enum and is never consumed by `run_capture`; consequently the selected render endpoint never receives the render/loopback initialization required for system-audio capture. The regression check has the same blind spot: it only searches for the unused function declaration, not its use ([`scripts/test-windows-audio.ps1:246-252`](../../../scripts/test-windows-audio.ps1)). CAPT-02 cannot work as implemented.

**Fix:** Branch initialization on `source.kind` and pass the WASAPI render-loopback mode/flag for `DesktopLoopback`; keep capture-mode initialization only for input endpoints. Add a Windows-target test or smoke assertion that observes the actual call mode rather than testing `capture_direction()` in isolation.

### CR-02: The benchmark and worker admission implementation is unreachable from the application

**File:** `src-tauri/src/commands/benchmark.rs:38-74`

**Issue:** Production commands only record PCM and return package-state rows. No command constructs `InferenceRunner`, calls `run`/`self_test`, calls `select_profile`, records CPU/CUDA/Vulkan measurements, or returns an `InferenceProfile`. The frontend accepts a sample then converts only `benchmark_readiness` into static “installed/not installed” rows ([`src/App.tsx:126-135`](../../../src/App.tsx)); it never runs a benchmark. The complete worker and scoring implementations are therefore test-only code, so AI-03's required measured CPU baseline, fixture gate, GPU fallback, and profile selection cannot occur.

**Fix:** Add a native benchmark transaction that consumes the bounded sample, constructs a verified model/worker runner, self-tests each candidate, measures warm runs, calls `select_profile`, and returns/emits the complete result matrix. Wire it from `acceptSample`, and retain only non-content profile evidence after resolution.

### CR-03: Setup can never produce a known-good configuration or reach Ready

**File:** `src-tauri/src/commands/setup.rs:6-15`

**Issue:** The only setup commands expose a read-only readiness snapshot plus begin/cancel. Nothing can set candidate model/profile/source/evidence, advance the state machine, run the official-source caption check, or call `SetupMachine::commit`. On the UI side, the completion button is permanently disabled ([`src/components/SetupWizard.tsx:24`](../../../src/components/SetupWizard.tsx)), and its handlers do not invoke any setup command ([`src/App.tsx:138-139`](../../../src/App.tsx)). `SetupController` always starts without `known_good`, so every real application session remains `SetupRequired` regardless of the passing internal unit tests.

**Fix:** Expose only legal native state-machine transition commands for each verified step, bind them to the actual model/benchmark/source evidence, and add a completion command that commits through `SetupConfigStore` only after all predicates pass. Enable the UI completion control from the authoritative native snapshot and cover the command-level flow in an integration test.

### CR-04: Cancel/finish leaves the user's benchmark PCM retained and may leave capture running

**File:** `src/App.tsx:116-135,139`

**Issue:** `start_benchmark_recording` retains PCM in the native `CaptureController`, but cancellation merely sets `showWizard` to false. It never invokes `discard_benchmark_recording` or `cancel_setup_reconfiguration`; after successful `finish_benchmark_recording`, the sample also remains in memory indefinitely because no code consumes or discards it. If finishing fails after native `stop()`, the catch block likewise leaves `captureOpen` and `sampleRecording` true, disabling source selection even though native capture has stopped. This violates the candidate-only, delete-on-cancel-or-resolution privacy boundary and can continue capturing after the user selects “Hủy thiết lập.”

**Fix:** Make cancellation and all failure/success terminal paths call native stop/discard/cancel in a `finally`-safe transaction, reset UI capture state from the native result, and add an integration test that proves the sample buffer is empty and no worker remains after cancel, rejected sample, and completed setup.

### CR-05: The built worker cannot satisfy the enforced protocol, while TargetPc verification treats absent workers as success

**File:** `scripts/build-workers.ps1:43-50`

**Issue:** The build script copies stock `whisper-cli.exe` under the manifest's `worker-*.exe` name. The runner and candidate script then require a custom `--input --json` invocation and a sealed JSON envelope containing `backend`, `workerBuild`, `modelRevision`, `elapsedMs`, `transcript`, `exitStatus`, and `diagnostics` ([`src-tauri/src/inference/runner.rs:301-341`](../../../src-tauri/src/inference/runner.rs); [`scripts/test-workers.ps1:116-127`](../../../scripts/test-workers.ps1)). No wrapper is built to implement that contract, so sealing a stock CLI cannot make candidate admission pass. Additionally, unsealed/missing candidates write “not present” and exit 0 ([`scripts/test-workers.ps1:102-112`](../../../scripts/test-workers.ps1)); `verify-phase1.ps1` accepts that zero exit and continues through every backend as though TargetPc verification succeeded ([`scripts/verify-phase1.ps1:28-31`](../../../scripts/verify-phase1.ps1)).

**Fix:** Build a dedicated fixed-path worker wrapper that implements the exact argument and JSON protocol, checksum every produced dependency, and test it against a real built artifact. Return a non-zero/purposeful “not verified” result for missing required CPU or requested available backends so TargetPc cannot report success without an admitted candidate.

## Warnings

### WR-01: Native source selection accepts unvalidated endpoint/kind data

**File:** `src-tauri/src/commands/audio.rs:16-20`

**Issue:** `select_audio_source` accepts a client-supplied `SelectedSource` without confirming that its opaque ID belongs to the selected source kind, is active, or was present in the catalogue. `run_capture` then opens only the ID and does not consume `SourceKind` when selecting the WASAPI mode. A crafted/stale desktop selection can therefore be recorded as a desktop source while opening a different endpoint type, weakening the exact-source invariant.

**Fix:** Re-enumerate or validate against a native catalogue in the selection command, derive display name/kind from the native result, and reject missing/inactive/mismatched IDs before saving the selection.

### WR-02: Failed sample acceptance leaves the UI in an incorrect, unrecoverable capture state

**File:** `src/App.tsx:126-135`

**Issue:** `finish_benchmark_recording` stops capture before it detects a silent/empty sample. Its error path only displays a message, leaving `captureOpen` and `sampleRecording` true. The device picker stays disabled and the sample button remains in the accept-only state, so the user cannot choose another source or restart recording without reloading the app.

**Fix:** In the error path, clear both local flags and discard the rejected sample; expose a retry action that starts a fresh capture after the native state confirms it is stopped.

---

_Reviewed: 2026-08-19T00:00:00Z_
_Reviewer: the agent (gsd-code-reviewer)_
_Depth: standard_
