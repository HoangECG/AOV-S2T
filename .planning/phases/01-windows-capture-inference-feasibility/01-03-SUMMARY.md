---
phase: 01-windows-capture-inference-feasibility
plan: "03"
subsystem: windows-audio-ui-and-validation
tags: [react, tauri, wasapi, powershell, exact-endpoint-id, pcm-meter]
dependency_graph:
  requires:
    - phase: 01-02
      provides: exact source selection, selected-render WASAPI loopback, and PCM meter events
  provides: [two-group exact-ID picker, captured-PCM status UI, Windows endpoint acceptance harness]
  affects: [setup-wizard, source-validation, phase-01-target-pc-uat]
actuals:
  tokens: 9125
  tasks: 2
  commits: 4
tech_stack:
  added: []
  patterns: [single cross-group radio selection, opaque endpoint ID IPC, non-content hardware evidence]
key_files:
  created: [src/components/DevicePicker.tsx, src/components/LevelMeter.tsx, src/components/SetupWizard.tsx, src/styles.css, src/vite-env.d.ts, scripts/test-windows-audio.ps1]
  modified: [src/App.tsx, src/main.tsx, src-tauri/src/main.rs]
key-decisions:
  - "The React UI only sends source kind plus opaque endpoint ID; device labels are displayed but never used as identity."
  - "An unavailable capture event stops the UI capture state, retains the selected label for explanation, and refreshes metadata without choosing a Windows default."
  - "The PowerShell harness enumerates Core Audio endpoint IDs directly and refuses missing, ambiguous, inactive, or default-fallback opens."
requirements-completed: [CAPT-01, CAPT-02, CAPT-03]
coverage:
  - id: D1
    description: Two source groups share one exact-ID selection and use the typed Tauri audio commands.
    requirement: CAPT-01
    verification:
      - kind: other
        ref: npm run typecheck; npm run build
        status: pass
    human_judgment: true
    rationale: Keyboard and zero/one/many-layout behaviour require a running desktop UI.
  - id: D2
    description: Captured-PCM meter distinguishes signal, silence, and unavailable state with fixed Vietnamese recovery copy.
    requirement: CAPT-03
    verification:
      - kind: unit
        ref: powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml audio"
        status: pass
    human_judgment: true
    rationale: Real signal, silence, and device invalidation require target endpoint hardware.
  - id: D3
    description: Windows harness lists exact input and selected-render IDs and rejects absent or unavailable IDs without default substitution.
    requirement: CAPT-02
    verification:
      - kind: other
        ref: powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows-audio.ps1 -ListOnly
        status: pass
    human_judgment: true
    rationale: A real selected-render loopback smoke, loss, and default-change test require an operator and active render audio.
metrics:
  duration: "4 min"
  completed: 2026-08-19
status: complete
---

# Phase 01 Plan 03: Windows audio UI and acceptance harness Summary

The setup screen now selects one exact input or render endpoint across two groups, presents captured-PCM state honestly, and includes a Windows-only exact-ID acceptance harness.

## Accomplishments

- Replaced input-only IPC with the typed catalogue/select/start/stop audio surface and connected the React screen to it.
- Added accessible source groups, 40px actions, status text plus color, scrolling eight-row lists, responsive layout, and reduced-motion meter updates.
- Added `test-windows-audio.ps1`, which opens only the supplied Core Audio input/render endpoint, emits bounded numeric PCM evidence, and does not persist PCM.

## Verification

- PASS: `npm run typecheck`.
- PASS: `npm run build`.
- PASS: `powershell.exe -NoProfile -Command "cargo test --manifest-path src-tauri/Cargo.toml audio"`.
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows-audio.ps1 -ListOnly` — emitted separate Input and RenderLoopback endpoint groups with opaque IDs and availability.
- PASS: exact-ID input and selected-render loopback smoke calls opened active endpoints and produced non-content `silent` peak/RMS evidence; no default endpoint was substituted.
- PENDING TARGET-PC CHECK: keyboard zero/one/many states, live input, selected-render loopback with known audio, silence, invalidation, default-device change, narrow layout, and reduced motion. Existing open entries in `.planning/WINDOWS.md` record this hardware verification debt; it was not duplicated.

## Task Commits

1. **Task 1: Render exact two-group selection and honest capture states** — `66d6a2c` (`feat`)
2. **Task 2: Prove exact input and render-loopback behavior on the target PC** — `d93dc67` (`test`), `d0c9220` and `afcd74e` (`fix`)

## Files Created/Modified

- `src/App.tsx` — owns typed Tauri calls, audio-level subscription, no-default loss handling, and source selection state.
- `src/components/DevicePicker.tsx` — renders one radio group across input and desktop-loopback catalogues.
- `src/components/LevelMeter.tsx` — presents captured peak/RMS and silent/unavailable recovery states.
- `src/components/SetupWizard.tsx` and `src/styles.css` — implement the benchmark-source screen and its responsive accessibility contract.
- `src-tauri/src/main.rs` — exposes only the expanded typed audio command surface.
- `scripts/test-windows-audio.ps1` — lists and opens exact Core Audio IDs for input/render loopback, returning numeric state evidence only.

## Decisions Made

- Selection uses `kind + endpointId` throughout; the friendly name remains UI-only text.
- Device loss sets the visible state to unavailable and refreshes catalogue metadata without substituting a default endpoint.
- The harness keeps evidence to source kind, endpoint ID, availability, and meter state/percentage; raw PCM and transcripts are never written.

## Deviations from Plan

### Auto-fixed Issues

1. [Rule 3 - Blocking issue] Added the minimal app integration and Vite CSS declaration needed to render the planned components.
   - **Found during:** Task 1
   - **Issue:** The plan listed the new components and stylesheet but the existing `App.tsx` still rendered the superseded input-only tracer; TypeScript also lacked a declaration for the stylesheet import.
   - **Fix:** Replaced the tracer view with `SetupWizard`, imported the app-owned CSS, and added `vite-env.d.ts`.
   - **Files modified:** `src/App.tsx`, `src/main.tsx`, `src/vite-env.d.ts`
   - **Verification:** `npm run typecheck` and `npm run build` pass.
   - **Committed in:** `66d6a2c`

2. [Rule 1 - Bug] Changed the initial harness from smoke instructions to an actual exact-ID WASAPI open and bounded numeric capture probe.
   - **Found during:** Task 2
   - **Issue:** Enumerating IDs and prompting for a UI smoke could not itself prove that the supplied input or render endpoint was opened.
   - **Fix:** Activated the exact `IMMDevice`, initialized shared WASAPI with loopback only for a selected render endpoint, and returned peak/RMS/state without persisting packet content.
   - **Files modified:** `scripts/test-windows-audio.ps1`
   - **Verification:** exact active input and render endpoints opened successfully and returned `silent` numeric evidence.
   - **Committed in:** `d0c9220`

3. [Rule 1 - Bug] Decoded each endpoint mix format according to its PCM/float representation.
   - **Found during:** Task 2
   - **Issue:** Treating every 32-bit mix format as floating point would misreport a 32-bit integer endpoint.
   - **Fix:** Distinguished float, 16-bit, 24-bit, and 32-bit integer sample formats before calculating bounded peak/RMS values.
   - **Files modified:** `scripts/test-windows-audio.ps1`
   - **Verification:** selected-render exact-ID smoke opens and returns numeric `silent` evidence.
   - **Committed in:** `afcd74e`

**Impact:** The deviation is limited to the integration required for the requested components to become observable; it adds no persistence, transcription, default-device fallback, or extra audio scope.

## Issues Encountered

- The pre-existing Windows-only TypeScript optional binary prevented `npm run typecheck` under the execution host. `npm ci` restored the lockfile-pinned Linux optional binary without changing project manifests or lockfiles, after which typecheck passed.

## Known Stubs

| File | Line | Stub | Reason |
| --- | --- | --- | --- |
| `src/components/SetupWizard.tsx` | 14 | `Bắt đầu ghi mẫu` is intentionally not wired yet. | The benchmark sample recording flow belongs to the later benchmark implementation plan. Logged as entry 3 in `.planning/WINDOWS.md`. |

## Next Phase Readiness

The setup wizard can now receive both endpoint catalogues and PCM events. Target-PC manual evidence remains required before shipping: one input, one selected-render loopback without Stereo Mix, silence, endpoint loss, and a Windows-default change with no source substitution.

## Self-Check: PASSED

- Created UI components, stylesheet, native command registration, and `scripts/test-windows-audio.ps1` exist.
- Commits `66d6a2c` and `d93dc67` exist.
