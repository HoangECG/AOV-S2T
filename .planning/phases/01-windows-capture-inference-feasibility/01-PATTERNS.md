# Phase 1: Windows Capture & Inference Feasibility - Pattern Map

**Mapped:** 2026-08-19  
**Files analyzed:** 18 planned application files  
**Analogs found:** 0 / 18

## Codebase Finding

This is a greenfield repository: it contains GSD configuration and planning artifacts only. There is no `Cargo.toml`, frontend project, application source, test suite, or implementation analog to copy. The planner must establish the first project conventions from the locked Phase 1 contracts, rather than infer patterns from GSD support files.

Do not treat `.claude/`, `.codex/`, or `.agents/` workflow support files as application-code analogs.

## File Classification

The exact module names remain planner discretion, but this is the smallest responsibility-oriented file set implied by `01-CONTEXT.md`, `01-RESEARCH.md`, and `01-UI-SPEC.md`.

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `src-tauri/src/main.rs` | application entry | event-driven | — | none (greenfield) |
| `src-tauri/src/audio/endpoints.rs` | service/model | event-driven | — | none (greenfield) |
| `src-tauri/src/audio/capture.rs` | service | streaming | — | none (greenfield) |
| `src-tauri/src/audio/pcm.rs` | utility | transform/streaming | — | none (greenfield) |
| `src-tauri/src/audio/meter.rs` | utility | streaming | — | none (greenfield) |
| `src-tauri/src/inference/manifest.rs` | model/service | file-I/O | — | none (greenfield) |
| `src-tauri/src/inference/runner.rs` | service | request-response/process I/O | — | none (greenfield) |
| `src-tauri/src/inference/benchmark.rs` | service | batch | — | none (greenfield) |
| `src-tauri/src/setup/state.rs` | model/service | event-driven | — | none (greenfield) |
| `src-tauri/src/setup/config.rs` | service | file-I/O | — | none (greenfield) |
| `src-tauri/src/diagnostics.rs` | model/service | request-response | — | none (greenfield) |
| `src-tauri/src/commands.rs` | command/controller | request-response | — | none (greenfield) |
| `src-tauri/tests/source_config.rs` | test | event-driven/file-I/O | — | none (greenfield) |
| `src-tauri/tests/meter.rs` | test | streaming/transform | — | none (greenfield) |
| `src-tauri/tests/manifest.rs` | test | file-I/O | — | none (greenfield) |
| `src/App.tsx` | component/controller | event-driven | — | none (greenfield) |
| `src/components/SetupWizard.tsx` | component | event-driven | — | none (greenfield) |
| `src/components/ReadinessDashboard.tsx` | component | request-response/event-driven | — | none (greenfield) |

## Pattern Assignments

### Native host boundary

**Files:** `src-tauri/src/main.rs`, `src-tauri/src/commands.rs`  
**Analog:** none; establish this as the canonical host/UI boundary.

Keep Windows/WASAPI handles, worker-process control, configuration writes, and model files entirely in the native host. Expose small GUI-facing commands and status subscriptions; do not let React infer readiness from GPU names or manipulate source/config files itself. Commands should return typed success/error status that preserves the failure reason required by the UI contract.

### Audio endpoint and capture boundary

**Files:** `audio/endpoints.rs`, `audio/capture.rs`, `audio/pcm.rs`, `audio/meter.rs`  
**Analog:** none; follow the research architecture.

Use one source sum type, with opaque endpoint identity kept separate from display metadata:

```rust
enum SourceKind { Input, DesktopLoopback }

struct SelectedSource {
    kind: SourceKind,
    endpoint_id: String, // opaque: persist/compare exactly, never parse
    display_name: String,
}
```

`endpoints` owns enumeration and notification events. `capture` owns exactly one active stream, opens shared WASAPI loopback only for a selected render endpoint, and stops on invalidation. Notification callbacks must enqueue an event only; they must not reopen devices or choose Windows defaults. `pcm` performs explicit format normalization at this boundary (downmix/resample to 16 kHz mono signed-16-bit PCM). `meter` derives peak/RMS and silent state from captured PCM, not only from an endpoint peak meter.

### Inference admission boundary

**Files:** `inference/manifest.rs`, `inference/runner.rs`, `inference/benchmark.rs`  
**Analog:** none; follow the research worker contract.

Treat each CPU, CUDA, and Vulkan worker as an independently installed candidate. The worker API should be structured JSON, bounded in size, and include backend/model revision/timing/transcript/exit outcome; never make the GUI parse console prose.

```text
worker --model <pinned-model> --language vi --input <normalized-wav> --json
  -> { backend, model_revision, elapsed_ms, transcript, exit_status }
```

`manifest` validates required disk space, immutable revision, size, SHA-256, and worker compatibility before an install. Download to a temporary path, verify checksum, then atomically promote; never execute a downloaded binary. `benchmark` must warm and test CPU even when a GPU succeeds, reject crash/timeout/incorrect smoke transcript/backlog, then retain the single best verified profile.

### Setup and persistent commit boundary

**Files:** `setup/state.rs`, `setup/config.rs`  
**Analog:** none; establish last-known-good as the first persistence convention.

Represent wizard values as an uncommitted candidate and persist a replacement configuration only after model verification, benchmark admission, official source signal, and Vietnamese test caption all succeed. Cancellation and all failed paths must leave the former configuration byte-for-byte usable. A temporary benchmark source/sample is candidate-only and must never become the official livestream source.

The stored configuration should contain source kind + opaque endpoint ID, pinned model revision/checksum, admitted worker/profile, hardware/driver fingerprint, and benchmark timestamp. Default-device changes must not mutate it. A changed model, driver, backend, or hardware fingerprint triggers a **confirmation request**, not an automatic benchmark.

### Diagnostics and UI boundary

**Files:** `diagnostics.rs`, `src/App.tsx`, `src/components/SetupWizard.tsx`, `src/components/ReadinessDashboard.tsx`  
**Analog:** none; implement `01-UI-SPEC.md` as the visual source of truth.

The native diagnostic snapshot is immutable, complete, and intentionally non-content-bearing: model/revision/install state, admitted backend/worker, GPU/RAM/VRAM, driver, benchmark timing, source kind/friendly name/endpoint status, and explicit missing values. Never include raw benchmark audio or transcripts by default.

React owns rendering and interaction only. Use app-owned CSS and the documented primitive components, Vietnamese copy, status labels plus color, and keyboard focus behavior. Keep `SetupWizard` as a state-driven renderer of host-provided candidate/setup state. `ReadinessDashboard` must show diagnostics persistently and present `Nguồn không khả dụng` rather than silently substituting a default source.

### Test patterns to establish

**Files:** `tests/source_config.rs`, `tests/meter.rs`, `tests/manifest.rs`  
**Analog:** none; create the repository's initial test convention.

Start with deterministic unit tests for pure rules:

- exact endpoint IDs persist and a missing ID produces `SourceUnavailable`, never a default replacement;
- PCM peak/RMS and silence-threshold transitions use controlled buffers;
- manifest schema, disk preflight decision, checksum mismatch, and atomic-promotion eligibility are testable without a real download.

Keep target-PC WASAPI loopback and CPU/CUDA/Vulkan admission as Windows-only integration/manual harnesses. Commit a Vietnamese smoke fixture only with an appropriate license/consent; keep the user's benchmark sample local and uncommitted.

## Shared Patterns

### Error and state reporting

Every fallible boundary returns a typed, actionable state rather than a generic string or a silent fallback. Required distinctions include unavailable source, silent source, model absent/incomplete/checksum failure, worker unavailable/not-installed/failure, and test-caption failure. Preserve the technical detail for diagnostics while mapping it to the fixed Vietnamese UI copy in `01-UI-SPEC.md`.

### One-active-source invariant

All layers use the same invariant: one `SelectedSource` across either input or desktop-loopback groups. Changing it requires the current capture/session to stop; this phase does not mix sources.

### Privacy and trust

Audio and model processing remain local. Treat endpoint IDs as opaque values; cap worker JSON and diagnostics strings; do not log raw audio or transcripts. Verify model artifact hash before activation and preserve the old verified asset/configuration until a full new setup commit passes.

### Frontend styling

There is no component library. Follow the custom CSS tokens and named primitives in `01-UI-SPEC.md`: Segoe UI/system fonts, 4px spacing scale, 40px minimum controls, documented dark palette, and state text in addition to color. Do not introduce a second design system in Phase 1.

## No Analog Found

All planned application files have no close code analog because the project has no application implementation yet. Planner guidance must therefore cite `01-CONTEXT.md`, `01-RESEARCH.md`, and `01-UI-SPEC.md`, and establish these patterns deliberately in the initial scaffold.

## Metadata

**Analog search scope:** repository root excluding `.git` and `.planning`; source/config manifests searched to depth 3  
**Files scanned:** 0 application source files (none exist)  
**Pattern extraction date:** 2026-08-19
