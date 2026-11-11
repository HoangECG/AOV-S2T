---
phase: 01-windows-capture-inference-feasibility
verified: 2026-08-19T00:00:00Z
status: gaps_found
score: 0/4 must-haves verified
behavior_unverified: 2
overrides_applied: 0
gaps:
  - truth: "A user can select one Windows render-audio endpoint and capture its desktop/system audio through WASAPI loopback."
    status: failed
    reason: "The production capture path always initializes Direction::Capture, including DesktopLoopback; SourceKind is never used to select a render-loopback mode."
    artifacts:
      - path: "src-tauri/src/audio/capture.rs"
        issue: "run_capture() hard-codes Direction::Capture at lines 145-154; capture_direction() is unused."
    missing:
      - "Branch the real WASAPI initialization on SourceKind and prove selected-render loopback on the target PC."
  - truth: "The target PC establishes one tested local CPU baseline and reports an admitted local inference profile with truthful CPU/GPU readiness."
    status: failed
    reason: "No production command runs InferenceRunner/self-test/benchmark/select_profile; no sealed worker, verified model, or target-PC benchmark evidence exists."
    artifacts:
      - path: "src-tauri/src/commands/benchmark.rs"
        issue: "Exports recording and static package-state rows only."
      - path: "src/App.tsx"
        issue: "acceptSample() maps benchmark_readiness() into placeholder rows and never starts a benchmark."
      - path: "scripts/test-workers.ps1"
        issue: "Missing/unsealed candidates exit 0, so TargetPc verification can continue without an admitted worker."
    missing:
      - "A native benchmark transaction wired from the accepted temporary sample to sealed workers, exact fixture gates, measurements, profile selection, and persisted non-content evidence."
      - "A real protocol-compatible sealed CPU worker, verified model, and target-PC CPU/available-GPU evidence."
  - truth: "Final setup can commit an exact official source and reach Ready only after model, benchmark, fixture, signal, and Vietnamese test-caption predicates pass."
    status: failed
    reason: "The managed SetupController is never given a KnownGoodConfig or candidate evidence; no registered command advances, commits, or performs the official-source caption check, and the UI completion button is permanently disabled."
    artifacts:
      - path: "src-tauri/src/commands/setup.rs"
        issue: "Only read-only readiness plus begin/cancel commands are exposed."
      - path: "src/components/SetupWizard.tsx"
        issue: "The Hoàn tất thiết lập button is hard-disabled at line 24."
    missing:
      - "Legal native transition/commit commands, authoritative UI wiring, and a command-level first-run/reconfiguration test."
  - truth: "Captured benchmark PCM is discarded on cancellation, rejection, and successful setup completion."
    status: failed
    reason: "Cancellation only hides the wizard; finish errors leave local capture flags set and accepted PCM has no consuming/discarding transaction."
    artifacts:
      - path: "src/App.tsx"
        issue: "onCancel does not invoke discard_benchmark_recording or cancel_setup_reconfiguration; acceptSample has no finally cleanup."
    missing:
      - "A native cleanup transaction wired to every terminal UI path and integration coverage proving bounded PCM is cleared."
behavior_unverified_items:
  - truth: "A user can select one active microphone/input endpoint by exact Windows ID and see its live captured-PCM level."
    test: "On the target PC, select a real input endpoint in the native app, start capture, confirm a moving meter, then stop it before changing selection."
    expected: "The displayed label/opaque ID remains the chosen endpoint and the level originates from that endpoint."
    why_human: "The Linux verifier has no Windows WASAPI endpoint or Tauri native window; Windows ledger item 1 remains open."
  - truth: "Unavailable or silent selected sources produce actionable states rather than a misleading active indication."
    test: "Exercise silence and disable/unplug the selected input/render endpoint while capture is running."
    expected: "Capture stops, UI becomes silent/unavailable with recovery copy, and no Windows default source is substituted."
    why_human: "Endpoint invalidation and WASAPI timing need target hardware; Windows ledger items 1 and 2 remain open."
---

# Phase 1: Windows Capture & Inference Feasibility Verification Report

**Phase Goal:** The user can select one live Windows audio source and confirm that a benchmarked local inference profile is ready on the target PC.

**Verified:** 2026-08-19T00:00:00Z  
**Status:** gaps_found  
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
| --- | --- | --- | --- |
| 1 | Select one active microphone/input by exact ID and observe a live PCM level. | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | React invokes typed enumerate/select/start commands and listens for `audio-level` (`src/App.tsx:37-113`); native capture opens `source.endpoint_id` (`capture.rs:138-159`). No target-PC app/endpoint result exists, and selection is not revalidated against the native catalogue (`commands/audio.rs:16-20`). |
| 2 | Select a render endpoint and capture system audio by selected-endpoint loopback, not Stereo Mix. | ✗ FAILED | `capture_direction()` labels DesktopLoopback but `run_capture()` always calls `initialize_client(... Direction::Capture, ...)` (`capture.rs:31-36`, `145-154`). No selected-render loopback branch exists. |
| 3 | Silent/unavailable sources are actionable and never look active. | ⚠️ PRESENT_BEHAVIOR_UNVERIFIED | Native error/invalidation marks unavailable and emits a meter event (`capture.rs:169-173`, `225-233`); React renders recovery copy (`App.tsx:58-64`). Hardware behavior and no-default substitution are unrun. |
| 4 | A target-PC Vietnamese CPU baseline establishes a ready profile; GPU is shown ready only after a successful probe. | ✗ FAILED | `InferenceRunner` and `select_profile` have no production caller (`runner.rs:225-341`, `benchmark.rs:110`); `benchmark_readiness()` only reports manifest packaging (`commands/benchmark.rs:61-74`). The repo has no sealed sidecar/model evidence and six target-PC ledger items remain open. |

**Score:** 0/4 truths verified (2 present but behavior-unverified)

## Required Artifacts

| Artifact | Status | Evidence |
| --- | --- | --- |
| `src-tauri/src/audio/tracer.rs` | ✗ MISSING | Declared by Plan 01, but absent. Its apparent replacement capture path is not documented as an accepted override. |
| `src-tauri/src/audio/{endpoints,capture,meter}.rs` | ⚠️ PARTIAL | Substantive exact-ID catalogue/meter code exists and is registered, but real loopback is not selected by `SourceKind`. |
| `src/components/{DevicePicker,LevelMeter}.tsx` | ⚠️ PRESENT | IPC/event wiring exists; target-PC source, silence, loss, and accessibility behavior is unverified. |
| `src-tauri/resources/model-manifest.json` + `inference/download.rs` + `ModelDownloadStep.tsx` | ⚠️ PRESENT | Manifest/download/UI are wired, but no target-PC model install/checksum/offline lifecycle evidence exists. |
| `workers/manifest.json` + `inference/runner.rs` + fixture assets | ⚠️ ORPHANED | The protocol implementation and fixture checks exist, but no production command constructs/runs the runner; worker build copies incompatible stock `whisper-cli.exe` (`build-workers.ps1:43-50`). |
| `inference/benchmark.rs` + `BenchmarkStep.tsx` + `setup/profile.rs` | ✗ HOLLOW | Policy/scoring/UI exist, but accepted PCM does not flow into a benchmark, result matrix, or selected profile. |
| `setup/{state,config}.rs` + `commands/setup.rs` + `ReadinessDashboard.tsx` | ✗ HOLLOW | State/config are substantive, but only snapshot/begin/cancel are exposed; no configuration can be committed or reach Ready. |
| `scripts/verify-phase1.ps1` | ✗ PARTIAL | It invokes target checks, but candidate scripts return success when workers are missing/unsealed, so it cannot attest readiness. |

## Key Link Verification

| From | To | Status | Details |
| --- | --- | --- | --- |
| `App.tsx` | audio commands/events | WIRED | `invoke()` and `listen("audio-level")` are used. |
| `SelectedSource.kind` | WASAPI capture initialization | NOT_WIRED | `SourceKind` does not control `initialize_client`; actual loopback link is absent. |
| `App.tsx:acceptSample` | benchmark engine/runner | NOT_WIRED | It calls only `finish_benchmark_recording` then static `benchmark_readiness`; no `InferenceRunner`, self-test, or scoring path is invoked. |
| `SetupMachine` | `SetupConfigStore` commit | NOT_WIRED | `commit()` exists but no production caller/store exists; main manages a default controller only. |
| worker build output | strict worker protocol | NOT_WIRED | Build copies stock CLI while runner/harness demand the custom JSON envelope. |

## Data-Flow Trace

| Rendered value | Source | Status |
| --- | --- | --- |
| Meter state | Tauri `audio-level` event from native captured PCM | ⚠️ PRESENT, hardware-unverified |
| Benchmark matrix | `benchmark_readiness()` manifest/package state | ✗ STATIC — never measurements/self-test results |
| Readiness dashboard | `setup_readiness()` with default controller and no known-good config | ✗ DISCONNECTED — always setup-required; cannot become Ready |
| Technical diagnostics | Literal label-only values in `SetupWizard.tsx:22` until a config exists | ✗ HOLLOW_PROP |

## Behavioral Spot-Checks

| Behavior | Command | Result | Status |
| --- | --- | --- | --- |
| Frontend type safety | `npm run typecheck` | completed successfully | ✓ PASS |
| Frontend production build | `npm run build` | completed successfully | ✓ PASS |
| Rust focused behavior tests | `cargo test --manifest-path src-tauri/Cargo.toml --test setup_flow -- --list` | unavailable: `cargo: command not found` in this verifier environment | ? SKIP |
| Target-PC capture/worker/benchmark acceptance | `scripts/verify-phase1.ps1 -Mode TargetPc ...` | not run; no IDs, sealed worker, verified model, or target hardware evidence | ? SKIP |

No conventional `scripts/**/tests/probe-*.sh` probes are declared for this phase.

## Requirements Coverage

| Requirement | Plans | Status | Evidence |
| --- | --- | --- | --- |
| CAPT-01 | 01, 02, 03, 07 | NEEDS HUMAN | Exact-ID UI/native path is present but has no target-PC live endpoint proof; final transactional source commit is unreachable. |
| CAPT-02 | 02, 03, 07 | BLOCKED | Production WASAPI initialization does not select loopback mode. |
| CAPT-03 | 01, 02, 03, 07 | NEEDS HUMAN | Code contains silent/unavailable states, but endpoint-loss/silence/default-device behavior is unrun on target hardware. |
| AI-03 | 04, 05, 06, 07 | BLOCKED | Benchmark/worker/profile/setup path is disconnected and no target-PC baseline/profile evidence exists. |

All Phase 1 requirement IDs are claimed by at least one PLAN; no orphaned Phase 1 requirement was found.

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| --- | --- | --- | --- |
| `src-tauri/src/audio/capture.rs` | 145-154 | Hard-coded capture direction | 🛑 Blocker | Render-loopback is nonfunctional. |
| `src/App.tsx` | 126-135, 139 | Static readiness mapping / cancellation only hides UI | 🛑 Blocker | No benchmark result, profile, or safe sample cleanup. |
| `src/components/SetupWizard.tsx` | 24 | Permanently disabled completion control | 🛑 Blocker | The first-run path cannot reach Ready. |
| `scripts/test-workers.ps1` | 104-112 | Missing/unsealed candidates exit 0 | 🛑 Blocker | Target-PC verifier can treat absent prerequisites as successful command execution. |
| `scripts/build-workers.ps1` | 43-50 | Stock CLI is copied under a custom-protocol worker name | 🛑 Blocker | Built artifact cannot meet runner/harness JSON protocol. |
| Phase source/scripts | — | `TBD`/`FIXME`/`XXX` scan | ✓ Clear | No unresolved debt markers found. |

## Human Verification Required After Gap Closure

1. **Live input and loss behavior** — select an input, verify moving PCM, test silence, unplug/disable it, and confirm capture stops without default-device substitution.
2. **Selected render loopback** — play known desktop audio on the chosen render endpoint and verify loopback without Stereo Mix; repeat with loss/invalidation.
3. **Model and benchmark evidence** — install/verify the pinned model, run sealed CPU and every physically available CUDA/Vulkan candidate through fixture self-test and warm Vietnamese sample, and inspect measured RTF/p95/fallback rows.
4. **Transactional readiness** — complete first run, cancel/retry at every step, restart, change hardware/driver/model, and verify last-known-good preservation, confirmation, source test caption, and Ready gating.

## Gaps Summary

The phase goal is not achieved. The render-audio path is explicitly wrong in the production WASAPI call, while the benchmark, worker admission, profile selection, setup commit, and Ready UI are implemented as disconnected pieces rather than an executable user flow. Target-PC evidence remains outstanding, but it is not merely a human-verification concern: the static source proves several required production links are absent or invalid. Fix these blocking links first, then run the target-PC ledger checks without treating missing workers or model artifacts as a passing result.

---

_Verified: 2026-08-19T00:00:00Z_  
_Verifier: the agent (gsd-verifier)_
