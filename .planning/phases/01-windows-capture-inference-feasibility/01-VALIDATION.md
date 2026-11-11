---
phase: 1
slug: windows-capture-inference-feasibility
status: planned
nyquist_compliant: true
wave_0_complete: false
created: 2026-08-19
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Rust unit tests plus a Windows-only integration/manual harness |
| **Config file** | none — Wave 0 establishes the Rust application scaffold |
| **Quick run command** | `cargo test` |
| **Full suite command** | `cargo test --all-targets` plus the Windows device/worker acceptance harness |
| **Estimated runtime** | Unit tests under 30 seconds; target-PC harness depends on model warm-up |

## Sampling Rate

- **After every task commit:** Run `cargo test`.
- **After every plan wave:** Run `cargo test --all-targets` and applicable Windows harness checks.
- **Before `$gsd-verify-work`:** Full suite plus target-PC capture/benchmark acceptance must be green.
- **Max feedback latency:** 30 seconds for unit checks; manual hardware checks may exceed this and must be recorded.

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 01-01-02 | 01-01 | 1 | CAPT-01, CAPT-03 | T-01-01-EI, T-01-01-AU | Tracer carries one exact input ID to an honest captured-PCM meter | unit + Windows smoke | `cargo test --manifest-path src-tauri/Cargo.toml audio::tracer` | ❌ W0 | ⬜ pending |
| 01-02-01 | 01-02 | 2 | CAPT-01 | T-01-02-EI | Exact IDs persist; loss stops capture; defaults never substitute | unit | `cargo test --manifest-path src-tauri/Cargo.toml --test source_config` | ❌ W0 | ⬜ pending |
| 01-02-02 | 01-02 | 2 | CAPT-02, CAPT-03 | T-01-02-AU, T-01-02-DO | Selected render endpoint uses shared loopback and PCM-derived state | unit + Windows integration | `cargo test --manifest-path src-tauri/Cargo.toml --test meter` | ❌ W0 | ⬜ pending |
| 01-03-01 | 01-03 | 3 | CAPT-01, CAPT-02, CAPT-03 | T-01-03-EI, T-01-03-AU | Two groups, one exact source, and empty/silent/unavailable UI states | typecheck + native tests + Windows UI | `npm run typecheck && cargo test --manifest-path src-tauri/Cargo.toml audio` | ❌ W0 | ⬜ pending |
| 01-03-02 | 01-03 | 3 | CAPT-01, CAPT-02, CAPT-03 | T-01-03-EI, T-01-03-AU | Harness opens only explicit IDs and distinguishes selected-render loopback/loss | Windows harness | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows-audio.ps1 -ListOnly` | ❌ W0 | ⬜ pending |
| 01-04-01 | 01-04 | 4 | AI-03 | T-01-04-MD, T-01-04-PP | Only the pinned provenance/size/hash/license-verified largest model is atomically activated | unit | `cargo test --manifest-path src-tauri/Cargo.toml --test manifest` | ❌ W0 | ⬜ pending |
| 01-04-02 | 01-04 | 4 | AI-03 | T-01-04-MD, T-01-04-AU | Model UI exposes honest acquisition/checksum/failure/retry state | typecheck + unit | `npm run typecheck && cargo test --manifest-path src-tauri/Cargo.toml inference::manifest` | ❌ W0 | ⬜ pending |
| 01-05-01 | 01-05 | 5 | AI-03 | T-01-05-MD, T-01-05-SC | CPU/CUDA/Vulkan builds plus the licensed 16 kHz Vietnamese fixture/expected transcript have pinned provenance, format, compatibility, and checksummed inventory | manifest harness | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-workers.ps1 -Mode ManifestOnly` | ❌ W0 | ⬜ pending |
| 01-05-02 | 01-05 | 5 | AI-03 | T-01-05-WO, T-01-05-AU | Fixed workers and bounded strict JSON reject fixture/hash or exact normalized-transcript mismatch, including nonempty wrong text, without content logs | unit + fake worker | `cargo test --manifest-path src-tauri/Cargo.toml --test worker_protocol` | ❌ W0 | ⬜ pending |
| 01-06-01 | 01-06 | 6 | AI-03 | T-01-06-AU, T-01-06-RP | CPU/GPU candidates first pass immutable-fixture equality, then use the separate nonpersistent user sample for warm accuracy/RTF/p95 admission | unit + Windows integration | `cargo test --manifest-path src-tauri/Cargo.toml --test benchmark` | ❌ W0 | ⬜ pending |
| 01-06-02 | 01-06 | 6 | AI-03 | T-01-06-RP | Matrix, selected profile, fallback reason, and diagnostics reflect measured evidence | typecheck + unit | `npm run typecheck && cargo test --manifest-path src-tauri/Cargo.toml inference::benchmark` | ❌ W0 | ⬜ pending |
| 01-07-01 | 01-07 | 7 | CAPT-01, CAPT-02, CAPT-03, AI-03 | T-01-07-CF | Ready/config commit require current fixture exact-match plus the distinct official-source signal/caption predicates; cancel preserves LKG | unit | `cargo test --manifest-path src-tauri/Cargo.toml --test setup_transaction --test setup_flow` | ❌ W0 | ⬜ pending |
| 01-07-02 | 01-07 | 7 | CAPT-01, CAPT-02, CAPT-03, AI-03 | T-01-07-MD, T-01-07-AU | Native readiness rejects fixture/hash/transcript mismatch and diagnostics remain non-content-bearing | unit | `cargo test --manifest-path src-tauri/Cargo.toml --test readiness` | ❌ W0 | ⬜ pending |
| 01-07-03 | 01-07 | 7 | CAPT-01, CAPT-02, CAPT-03, AI-03 | T-01-07-AU, T-01-07-RP | Static plus target-PC evidence covers fixture exact/mismatch paths and all roadmap truths without content logs | full harness | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/verify-phase1.ps1 -Mode Static` | ❌ W0 | ⬜ pending |

## Wave 0 Requirements

- [ ] Plan 01 creates the Rust/Tauri/React scaffold and module-level source/meter tests.
- [ ] Plan 03 creates the Windows-only input/selected-render-loopback harness and the explicit no-driver-loopback check.
- [ ] Plan 04 creates model-manifest/checksum fixtures before model bytes can become active.
- [ ] Plan 05 creates worker-manifest and fake-worker protocol fixtures plus a committed immutable 16 kHz mono Vietnamese WAV, expected normalized transcript, and genuine consent/license record; manifest and tests reject byte/expectation/match drift.
- [ ] Plan 06 records a user-owned local clean Vietnamese reading sample from a nonpersistent temporary source, with the displayed prompt as reference; no user-recorded raw audio fixture is committed, and this temporary sample remains distinct from Plan 05's licensed self-test fixture.
- [ ] Plan 06 creates benchmark scoring/profile fixtures before a backend can be selected.

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Selected microphone/input produces a visible level | CAPT-01 | Requires target Windows endpoint hardware | Select the intended endpoint and confirm its exact ID/label and moving meter. |
| Selected render device produces desktop loopback capture | CAPT-02 | Requires real active render endpoint; no Linux substitute | Play known audio, select the render endpoint, verify capture without Stereo Mix. |
| Device loss/silence is visible and capture stops | CAPT-03 | Hot-plug/default-device behavior is Windows/hardware-specific | Unplug/disable the active endpoint and confirm no default-device switch occurs. |
| CPU plus available NVIDIA/AMD/Intel backends are correctly selected or rejected | AI-03 | Driver, VRAM, and model compatibility are target-machine-specific | Run the immutable fixture self-test and first-run user-sample benchmark; inspect exact-match/mismatch result, backend, model, fallback reason, warm timing, and final-caption delay. |

## Validation Sign-Off

- [x] All implementation tasks have `<automated>` verify or an explicit Wave 0 creation path.
- [x] Sampling continuity: no 3 consecutive implementation tasks without automated verify.
- [x] Wave 0 creation paths cover all missing test references.
- [x] No watch-mode flags.
- [x] Unit/typecheck feedback targets under 30 seconds; model/hardware harnesses are separately marked target-PC checks.
- [x] `nyquist_compliant: true` set in frontmatter.

**Approval:** pending
