---
schema_version: 1
open_count: 6
waived_count: 0
fixed_count: 1
total_count: 7
last_updated: 2026-08-19T13:23:24.856Z
---

# Broken Windows Ledger

> Cross-phase defect register. With `workflow.windows_enforce` enabled, `/gsd-ship` blocks while `open_count > 0`.
> Waive with `gsd-tools windows waive <id> "<reason>"` (reason required).
> Mark fixed with `gsd-tools windows fixed <id>`.

| id | phase | kind | file | line | description | status | reason | recorded_at | resolved_at |
|----|-------|------|------|------|-------------|--------|--------|-------------|-------------|
| 1 | 1 | unrun-verify | src/App.tsx |  | Target-PC manual WASAPI capture verification remains pending. | open |  | 2026-08-19T12:03:32.644Z |  |
| 2 | 1 | unrun-verify | src-tauri/src/audio/capture.rs |  | Target-PC selected-render WASAPI loopback, endpoint-loss, and no-default-substitution verification remains pending. | open |  | 2026-08-19T12:16:57.704Z |  |
| 3 | 1 | stub | src/components/SetupWizard.tsx | 14 | The Phase 1 benchmark-recording button is intentionally not wired until the benchmark sample flow is implemented. | fixed |  | 2026-08-19T12:33:20.443Z | 2026-08-19T13:14:30.659Z |
| 4 | 1 | unrun-verify | src/components/ModelDownloadStep.tsx |  | Target-PC manual verification of installed, insufficient-space, interrupted, checksum-failure, long revision, and offline-restart model states remains pending. | open |  | 2026-08-19T12:45:40.167Z |  |
| 5 | 01 | unrun-verify | scripts/test-workers.ps1 |  | Target-PC CPU/CUDA/Vulkan worker smoke remains unrun until sealed sidecars, pinned model bytes, and hardware are available. | open |  | 2026-08-19T13:02:36.656Z |  |
| 6 | 01 | unrun-verify | src-tauri/src/commands/benchmark.rs |  | Target-PC local clean Vietnamese sample plus sealed CPU/CUDA/Vulkan fixture and warm benchmark evidence remains required; this checkout has no sealed workers, model bytes, or target hardware. | open |  | 2026-08-19T13:14:22.586Z |  |
| 7 | 01 | unrun-verify | scripts/verify-phase1.ps1 |  | Target-PC verification remains required for exact input/render endpoints, source loss and silence, checksum-ready model, sealed CPU/available GPU fixture checks, user sample, official-source Vietnamese test caption, cancellation, restart, drift confirmation, and UI accessibility/layout. | open |  | 2026-08-19T13:23:24.856Z |  |

````json
[
  {
    "id": 1,
    "kind": "unrun-verify",
    "phase": "1",
    "file": "src/App.tsx",
    "line": null,
    "description": "Target-PC manual WASAPI capture verification remains pending.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-19T12:03:32.644Z",
    "resolved_at": null
  },
  {
    "id": 2,
    "kind": "unrun-verify",
    "phase": "1",
    "file": "src-tauri/src/audio/capture.rs",
    "line": null,
    "description": "Target-PC selected-render WASAPI loopback, endpoint-loss, and no-default-substitution verification remains pending.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-19T12:16:57.704Z",
    "resolved_at": null
  },
  {
    "id": 3,
    "kind": "stub",
    "phase": "1",
    "file": "src/components/SetupWizard.tsx",
    "line": 14,
    "description": "The Phase 1 benchmark-recording button is intentionally not wired until the benchmark sample flow is implemented.",
    "status": "fixed",
    "reason": "",
    "recorded_at": "2026-08-19T12:33:20.443Z",
    "resolved_at": "2026-08-19T13:14:30.659Z"
  },
  {
    "id": 4,
    "kind": "unrun-verify",
    "phase": "1",
    "file": "src/components/ModelDownloadStep.tsx",
    "line": null,
    "description": "Target-PC manual verification of installed, insufficient-space, interrupted, checksum-failure, long revision, and offline-restart model states remains pending.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-19T12:45:40.167Z",
    "resolved_at": null
  },
  {
    "id": 5,
    "kind": "unrun-verify",
    "phase": "01",
    "file": "scripts/test-workers.ps1",
    "line": null,
    "description": "Target-PC CPU/CUDA/Vulkan worker smoke remains unrun until sealed sidecars, pinned model bytes, and hardware are available.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-19T13:02:36.656Z",
    "resolved_at": null
  },
  {
    "id": 6,
    "kind": "unrun-verify",
    "phase": "01",
    "file": "src-tauri/src/commands/benchmark.rs",
    "line": null,
    "description": "Target-PC local clean Vietnamese sample plus sealed CPU/CUDA/Vulkan fixture and warm benchmark evidence remains required; this checkout has no sealed workers, model bytes, or target hardware.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-19T13:14:22.586Z",
    "resolved_at": null
  },
  {
    "id": 7,
    "kind": "unrun-verify",
    "phase": "01",
    "file": "scripts/verify-phase1.ps1",
    "line": null,
    "description": "Target-PC verification remains required for exact input/render endpoints, source loss and silence, checksum-ready model, sealed CPU/available GPU fixture checks, user sample, official-source Vietnamese test caption, cancellation, restart, drift confirmation, and UI accessibility/layout.",
    "status": "open",
    "reason": "",
    "recorded_at": "2026-08-19T13:23:24.856Z",
    "resolved_at": null
  }
]
````
