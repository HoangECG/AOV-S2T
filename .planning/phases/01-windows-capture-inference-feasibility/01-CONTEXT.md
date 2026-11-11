# Phase 1: Windows Capture & Inference Feasibility - Context

**Gathered:** 2026-08-19
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver reliable selection and validation of one live Windows audio source, plus a measured local Vietnamese ASR readiness baseline on the target PC. This phase covers source capture, first-run model acquisition and benchmark/setup behavior, and hardware/backend readiness only; stable caption rendering, translation, stream overlay, and general desktop controls remain in later phases.

</domain>

<decisions>
## Implementation Decisions

### Audio-source behavior
- **D-01:** Persist the exact selected audio endpoint; never silently switch to a Windows default device.
- **D-02:** If the persisted or active device becomes unavailable, stop capture and require the user to choose a source again.
- **D-03:** Require the user to stop the session before changing audio source.
- **D-04:** Present separate “Microphone / Input” and “Desktop / System Audio” groups; v1 has exactly one active source. Desktop capture uses the selected render endpoint's loopback, not Stereo Mix.

### Hardware support and readiness
- **D-05:** Target CPU plus NVIDIA, AMD, and Intel GPU acceleration in v1. — **Reversibility:** costly — Backend packaging, runtime probes, and compatibility validation span native inference builds and the supported-hardware contract.
- **D-06:** At startup, probe available backends and use accelerated GPU inference only after it passes a self-test; otherwise fall back to CPU and explain why in the UI.
- **D-07:** Show technical readiness details in the GUI, including active backend, VRAM/RAM, driver information, and selected model.
- **D-08:** Run a full automated benchmark on first run to select the best local profile, then retain a quick self-test for later launches.

### Benchmark policy
- **D-09:** Benchmark against user-recorded audio from the sources intended for real livestream use; it stays local.
- **D-10:** Use an accuracy/latency balance where finalized captions normally arrive within roughly three seconds.
- **D-11:** Benchmark the user's normal clean-stream audio condition, not a broad noisy/edge-case suite in this initial setup.
- **D-12:** Save one best profile as the default for the entire app, rather than profiles per source or a mandatory per-session choice.

### Model onboarding and lifecycle
- **D-13:** Automatically download the benchmarked default model on first run, show progress, validate disk space/checksum, and allow offline operation after it is installed.
- **D-14:** Use the largest default model to prioritize accuracy. — **Reversibility:** costly — Model size determines installer/download, memory, benchmark duration, and supported-hardware expectations.
- **D-15:** Pin the model version; update only after the user explicitly confirms and re-runs benchmark.
- **D-16:** If the model is absent, incomplete, corrupt, or cannot be stored, block the session and provide a clear error with retry; never silently downgrade quality.

### First-run and reconfiguration flow
- **D-17:** First-run flow is model download → temporary source selection and local sample recording for benchmark → benchmark → official source selection. The temporary source must not be persisted as the livestream source.
- **D-18:** Mark the app Ready only after the selected source has a live signal and a Vietnamese test caption completes.
- **D-19:** Keep the user in setup with an actionable checklist and retry action when the test caption fails; session start remains blocked.
- **D-20:** Later launches open directly to the main Ready screen; setup is entered only to change source/model or test again.
- **D-21:** When model, driver/backend, or hardware changes, ask the user to confirm before re-benchmarking.
- **D-22:** Route source/model/profile changes through the setup wizard rather than independent Settings reset controls.
- **D-23:** Resume the wizard at the affected step and reuse installed model assets; do not rerun all setup unnecessarily.
- **D-24:** Canceling the wizard preserves the last known-good configuration; new choices apply only after the wizard passes completely.

### the agent's Discretion
- Select the concrete WASAPI and local-ASR library/runtime after the Phase 1 benchmark research and evidence review.
- Define exact benchmark sample duration, scoring implementation, and hardware capability thresholds consistent with the three-second final-caption target.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project scope and requirements
- `.planning/PROJECT.md` — local-first Windows context, core value, and fixed v1 boundaries.
- `.planning/REQUIREMENTS.md` — Phase 1 requirements CAPT-01 through CAPT-03 and AI-03.
- `.planning/ROADMAP.md` — Phase 1 goal, success criteria, dependency order, and phase boundary.
- `.planning/STATE.md` — current focus and unresolved ASR/backend benchmark gate.

### Domain research
- `.planning/research/SUMMARY.md` — current stack recommendation, Windows audio/inference design, and phase-specific risks.
- `.planning/research/STACK.md` — candidate local stack and CPU/GPU packaging constraints.
- `.planning/research/ARCHITECTURE.md` — capture, model-worker, and readiness boundary recommendations.
- `.planning/research/PITFALLS.md` — device lifecycle, benchmark, and GPU fallback safeguards.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- None — this is a greenfield repository with no application source code or codebase map.

### Established Patterns
- None yet; Phase 1 establishes the initial Windows-native capture and local-inference patterns.

### Integration Points
- New application foundations will be introduced in this phase; later caption, overlay, and controls phases depend on their source/session/readiness contracts.

</code_context>

<specifics>
## Specific Ideas

- The primary user livestreams and wants a transparent web overlay later, but Phase 1 must not implement the overlay.
- Vietnamese accuracy matters more than the lowest latency, while a typical final-caption delay of about three seconds is acceptable.
- The app should avoid silent behavior: source loss, backend fallback, model failures, and benchmark readiness must all be visible to the user.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within Phase 1 scope.

</deferred>

---

*Phase: 1-Windows Capture & Inference Feasibility*
*Context gathered: 2026-08-19*
