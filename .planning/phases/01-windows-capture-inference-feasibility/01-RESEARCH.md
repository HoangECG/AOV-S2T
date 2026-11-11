# Phase 1: Windows Capture & Inference Feasibility - Research

**Researched:** 2026-08-19  
**Domain:** Windows Core Audio capture and local Vietnamese Whisper runtime admission  
**Confidence:** MEDIUM

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

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

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within Phase 1 scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CAPT-01 | Choose one active microphone or Windows input-audio device. | Enumerate active capture endpoints, persist the opaque endpoint ID, and capture only that ID. |
| CAPT-02 | Choose one render-audio device and capture system audio through loopback. | Initialize shared-mode WASAPI loopback on the selected render endpoint; never use a hardware “Stereo Mix” endpoint. |
| CAPT-03 | Show a live level and actionable unavailable/silent error. | Meter captured PCM plus endpoint notifications and `AUDCLNT_E_DEVICE_INVALIDATED`; distinguish no samples from silent samples. |
| AI-03 | Use a tested local CPU baseline and report active CPU/GPU backend and model readiness. | Ship CPU worker, test every accelerated sidecar against one corpus, benchmark warm runs, and persist the winning verified profile. |
</phase_requirements>

## Summary

Use direct Windows WASAPI for endpoint enumeration, input capture, and selected-render loopback. A render endpoint opened with shared-mode loopback captures the audio engine mix without requiring a driver-provided loopback device, so it satisfies the desktop-audio requirement even where “Stereo Mix” is absent. Endpoint IDs are opaque unique identifiers: persist and compare them verbatim, and react to notification/loss events without substituting the default device. [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording] [CITED: https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient]

For inference, keep the GUI/capture path independent from native model execution. The recommended admission architecture is a pinned `whisper.cpp` worker build for CPU, a separately packaged CUDA worker for NVIDIA, and a separately packaged Vulkan worker as the common candidate for AMD/Intel. The app must run an actual Vietnamese fixture through each candidate, choose only a backend that passes correctness and real-time tests, and keep the CPU worker as the guaranteed fallback. This implements the user’s “CPU + NVIDIA + AMD + Intel” support goal without falsely treating the presence of a GPU as proof of acceleration. [CITED: https://github.com/ggml-org/whisper.cpp]

**Primary recommendation:** plan Phase 1 around a Windows-native capture service and a backend-neutral `InferenceRunner` process contract; accept a CPU/CUDA/Vulkan profile only after a warm, end-to-end Vietnamese fixture benchmark and persist it as an atomic last-known-good configuration.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|--------------|----------------|-----------|
| Endpoint discovery, source selection, lifecycle | Windows native host | GUI | COM/WASAPI owns endpoint identity and stream validity; UI only displays/chooses it. |
| Input and render-loopback capture | Windows native host | Inference worker | WASAPI owns device-format packets and level readings; worker receives normalized PCM only. |
| Resample/downmix and test recording | Windows native host | — | Normalize once at the capture boundary before every ASR test. |
| ASR backend probing and benchmark | Local worker process | Native host | Sidecar binary owns CUDA/Vulkan/CPU runtime; host owns scoring, timeout, and selection. |
| Model download/verification/config commit | Native host | GUI | Host validates manifest/hash/disk space and atomically commits only successful setup. |
| Readiness/diagnostic UI | GUI | Native host | GUI renders immutable status; it must not infer backend state from hardware names. |

## Standard Stack

### Core

| Component | Version / pin | Purpose | Why this is the standard choice here |
|-----------|---------------|---------|--------------------------------------|
| Windows Core Audio: MMDevice API + WASAPI | Windows SDK | Enumerate selected input/render endpoints and capture shared-mode PCM/loopback. | The official API provides selected-render loopback, mix format, packet status, and endpoint lifecycle notifications. [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording] |
| `whisper.cpp` source worker | immutable Git commit plus immutable GGML model manifest | Offline Vietnamese ASR, CPU baseline, CUDA and Vulkan candidate builds. | Official project documents CPU, CUDA, Vulkan, HIP and its `whisper-bench`/CSV harness. Pin source and artifacts because the executable/model interface is native, not a portable runtime abstraction. [CITED: https://github.com/ggml-org/whisper.cpp] |
| `wasapi` Rust crate `0.24.0` [WARNING: flagged as suspicious — verify before using.] | exact version after human registry/repository check | Safe Rust façade if the Windows host is Rust/Tauri. | Its published docs list capture, event-driven buffering, loopback, and disconnect/device notifications; do not install until the legitimacy checkpoint succeeds in a Windows development environment. [CITED: https://docs.rs/wasapi/latest/wasapi/] |

### Supporting

| Component | Purpose | When to use |
|-----------|---------|-------------|
| `IAudioMeterInformation` peak meter | Endpoint level UI in normalized `0.0`–`1.0` units. | Use as a UI source only; calculate actual captured-PCM RMS/peak too so silence detection represents the chosen capture stream. [CITED: https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nn-endpointvolume-iaudiometerinformation] |
| 16 kHz mono signed-16-bit PCM normalization | Common capture-to-ASR test format. | Downmix/resample every endpoint mix format at the boundary; `whisper.cpp` CLI documentation itself requires 16-bit WAV input for that example. [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/device-formats] [CITED: https://github.com/ggml-org/whisper.cpp] |
| JSON model manifest | Pin model URL/revision, SHA-256, size, license, worker compatibility, and install state. | Validate before download, verify a temporary file, then atomically promote it; preserve prior known-good model on failure. [ASSUMED] |

### Alternatives Considered

| Instead of | Could use | Tradeoff |
|------------|-----------|----------|
| Direct WASAPI | Hardware “Stereo Mix” | Rejected: hardware loopback devices are optional, manually enabled, and vendor-named inconsistently. [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording] |
| CPU/CUDA/Vulkan worker set | CUDA-only runtime | Rejected: violates the locked AMD/Intel acceleration target and leaves non-NVIDIA PCs with an unverified story. |
| `whisper.cpp` executable contract | Linking one GPU feature set into the app | Rejected: documented backends are selected at build time; isolated worker binaries make probing/fallback/package diagnostics explicit. [CITED: https://github.com/ggml-org/whisper.cpp] |

## Package Legitimacy Audit

The environment has no Rust toolchain or `cargo`, and the legitimacy seam returned `SUS` with `unknown-age`, `unknown-downloads`, and `no-repository` signals for every queried crate. This is an availability failure of the research host, not evidence that these crates are unsafe. The plan must nevertheless include a human verification checkpoint before adding any crate.

| Package | Registry | Verdict | Disposition |
|---------|----------|---------|-------------|
| `wasapi` | crates.io | SUS | Flagged — verify official repo/version and run `cargo search wasapi` before install. |
| `whisper-rs` | crates.io | SUS | Not selected for Phase 1; do not add speculatively. |
| `rubato`, `ringbuf`, `serde`, `serde_json`, `tracing`, `tracing-subscriber` | crates.io | SUS | Defer until application scaffold establishes actual needs; verify each before installation. |

**Packages removed due to [SLOP] verdict:** none.  
**Packages flagged as suspicious [SUS]:** `wasapi`, `whisper-rs`, `rubato`, `ringbuf`, `serde`, `serde_json`, `tracing`, `tracing-subscriber`.

## Architecture Patterns

### System Architecture Diagram

```text
Windows capture endpoints
  ├─ Input endpoint selected by opaque ID ─┐
  └─ Render endpoint selected by opaque ID ─┤ WASAPI shared/event capture
                                             │  (loopback flag only for render)
                                             v
                                  packet decoder → downmix/resample → PCM meter
                                             │                       │
                                   source lost/silent state           └─ UI level
                                             │
                                             v
                        temporary 16 kHz mono test WAV / bounded PCM feed
                                             │
             model manifest → verified model + CPU/CUDA/Vulkan worker candidates
                                             │
                                             v
                          warm self-test + corpus benchmark → score/profile
                                             │                 ├─ pass → atomic config commit → Ready UI
                                             │                 └─ fail → CPU fallback/error checklist
```

### Pattern 1: Persist endpoint identity, not a label or default role

**What:** Store source kind plus the endpoint ID returned by Windows. Treat the ID as opaque, use it only for exact comparison/reopen, and retain the friendly name solely for display. Microsoft says an ID uniquely identifies an endpoint and must not be parsed. [CITED: https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient]

**When to use:** At every source selection, later launch, stream startup, and notification callback.

**Implementation rule:** A missing/invalidated ID moves the state to `SourceUnavailable`, stops capture, and shows reselect/retry. A Windows default-device change updates the list but never changes this source.

### Pattern 2: Shared event-driven capture with short nonblocking callbacks

**What:** For an input endpoint, initialize a shared capture stream. For a render endpoint, initialize a shared capture stream with the loopback flag. Windows 10 version 1703 and later supports event-driven loopback; loopback is shared-mode only. [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording]

**When to use:** Both source groups in v1. Design capture callback/notification work to enqueue a lightweight event only: Microsoft explicitly requires endpoint notification callbacks to be nonblocking. [CITED: https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient]

**Packet rule:** Drain available packets, always pair `GetBuffer` with `ReleaseBuffer` on the same thread, translate `SILENT`, discontinuity, and `DEVICE_INVALIDATED` flags into telemetry/state. [CITED: https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer]

### Pattern 3: Backend admission, not hardware-name selection

**What:** Build/package CPU, CUDA, and Vulkan worker variants independently, then discover only installed candidates. CUDA is the NVIDIA path; Vulkan is explicitly cross-vendor and therefore the AMD/Intel candidate; `whisper.cpp` also documents HIP/ROCm but it needs a per-architecture AMD build and must not be assumed present on Windows. [CITED: https://github.com/ggml-org/whisper.cpp]

**Admission test:** For every candidate: launch → load pinned model → transcribe a bundled short Vietnamese smoke fixture → verify nonempty/expected normalized transcript → measure warm inference. Only then run the owner’s corpus. Always execute CPU in the full matrix even when a GPU passes.

**Scoring:** pick a candidate only if (a) no worker crash/timeout, (b) it passes all fixture transcript checks, (c) long-run real-time factor stays below `0.8`, and (d) p95 final-caption-equivalent turnaround is at most 3 s. These thresholds are proposed discretion values, not documented hardware guarantees. [ASSUMED]

### Pattern 4: Last-known-good configuration as a commit point

**What:** Keep a complete candidate setup in memory/temporary storage; write persisted model/backend/source/profile only after download, checksum, benchmark, source-level check, and Vietnamese test caption all pass. Cancellation/degradation leaves the previous configuration intact. [ASSUMED]

### Recommended Project Structure

```text
src-tauri/
├── audio/          # endpoint catalogue, stream lifecycle, PCM conversion/meter
├── inference/      # worker discovery, manifest verification, runner, benchmark scoring
├── setup/          # setup-state machine and atomic configuration commit
├── diagnostics/    # non-content hardware/backend metrics
└── commands/       # GUI-facing read/command boundary
workers/
├── cpu/            # pinned whisper.cpp CPU binary + dependency manifest
├── cuda/           # pinned CUDA binary/DLL set
└── vulkan/         # pinned Vulkan binary/DLL set
```

## Don't Hand-Roll

| Problem | Don't build | Use instead | Why |
|---------|-------------|-------------|-----|
| Desktop/system capture | Driver-specific virtual cable or “Stereo Mix” detection | WASAPI render-endpoint loopback | Microsoft documents it works without a hardware loopback capture device. [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording] |
| Endpoint lifecycle | Polling/default-device substitution | MMDevice notifications + exact ID compare | It represents add/remove/state/property/default changes and exposes IDs to compare. [CITED: https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient] |
| GPU capability inference | Heuristics based on GPU brand/VRAM | Real worker launch/self-test | Backends are build/runtime specific; a GPU name does not verify model loading or inference. [CITED: https://github.com/ggml-org/whisper.cpp] |
| Benchmark throughput | A synthetic timer only | `whisper-bench` plus end-to-end corpus runner | `whisper-bench` measures encoder time, while the product also needs decode/normalization/result timing. [CITED: https://github.com/ggml-org/whisper.cpp] |
| Audio-format assumptions | Treat every endpoint as 16 kHz mono PCM | Capture mix format then explicitly downmix/resample | Shared-mode endpoint formats are exposed through `GetMixFormat`; conversion support is limited. [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/device-formats] |

## Common Pitfalls

### Endpoint loss and silent fallback

**What goes wrong:** Reopening the Windows default after a USB/headset change can caption the wrong source.  
**Avoid:** Persist opaque exact ID, stop on `DEVICE_INVALIDATED`/unavailable notifications, and demand a new user choice. Device notification callbacks must not block or reopen inline. [CITED: https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient] [CITED: https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer]

### Incorrect loopback or format path

**What goes wrong:** Code tries a capture device named Stereo Mix, or feeds endpoint float/stereo/48 kHz data to an ASR path assumed to be 16 kHz mono.  
**Avoid:** Render endpoint + shared loopback flag, then explicit PCM conversion. Test both 44.1 and 48 kHz endpoint formats and mono/stereo channels. [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording] [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/device-formats]

### Meter says “active” but capture is unusable

**What goes wrong:** Endpoint peak meter can show a delayed endpoint-level value, while the particular capture stream is silent, protected, or disconnected.  
**Avoid:** Display peak/RMS from captured PCM and use endpoint meter only as an auxiliary reading. Treat protected content as a possible loopback limitation. [CITED: https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nf-endpointvolume-iaudiometerinformation-getpeakvalue] [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording]

### Claiming all GPUs work from a successful binary launch

**What goes wrong:** A CUDA/Vulkan process starts but fails to load the model, runs slower than CPU, or becomes unstable when warm.  
**Avoid:** Candidate-specific smoke transcript, warmed corpus, timeout/OOM capture, and CPU comparison. `whisper.cpp` requires different build flags for CUDA, Vulkan, and HIP. [CITED: https://github.com/ggml-org/whisper.cpp]

### Benchmark is not representative of the final latency target

**What goes wrong:** Encoder-only speed or a single short audio file appears fast but a live pipeline falls behind.  
**Avoid:** Record a consented normal clean-stream corpus, include timing from PCM-ready through text-result, warm every model once, and evaluate p95 on continuous audio. `whisper-bench` is encoder-only, so it cannot alone prove caption latency. [CITED: https://github.com/ggml-org/whisper.cpp]

### Model corruption or accidental downgrade

**What goes wrong:** Partial download is treated as ready, an update replaces a working model, or missing disk causes a smaller model to be used invisibly.  
**Avoid:** Use the resolved immutable-manifest policy: approved upstream repository plus pinned revision, exact artifact URL/size/SHA-256/license provenance, disk preflight, temporary download, atomic promotion, and explicit retry. A manifest missing any required provenance field fails closed. [ASSUMED]

## Code Examples

### WASAPI design skeleton

```rust
// Pseudocode based on Microsoft WASAPI lifecycle documents.
// The endpoint_id is opaque: persist/compare it exactly; never parse it.
match selected_source {
    Input { endpoint_id } => open_shared_capture(endpoint_id),
    DesktopLoopback { endpoint_id } => open_shared_loopback_capture(endpoint_id),
}

// Capture thread: drain packet -> copy/convert -> ReleaseBuffer immediately.
// Notification thread: enqueue endpoint-id event only; stream shutdown/reopen happens elsewhere.
```

Source: [Microsoft loopback recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording) and [IMMNotificationClient](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient).

### Benchmark command boundary

```text
worker --model <pinned-model> --language vi --input <normalized-wav> --json
  -> { backend, model_revision, elapsed_ms, transcript, exit_status }
```

This is an internal proposed contract. It should wrap a pinned `whisper.cpp` build rather than make the GUI parse console prose. [ASSUMED]

## State of the Art

| Old approach | Current approach | Impact |
|--------------|------------------|--------|
| Driver-specific loopback input (“Stereo Mix”) | WASAPI loopback on selected render endpoint | Works without exposing/enabling a hardware loopback device. [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording] |
| Pre-Windows 10 1703 loopback event workaround | Event-driven loopback supported from Windows 10 1703 | The resolved product floor is x64 Windows 10 22H2/Windows 11, so no legacy render-event workaround is required; older/non-x64 hosts fail compatibility preflight. [CITED: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording] |
| One generic GPU setting | CPU/CUDA/Vulkan candidate admission | Lets the UI report actual execution/fallback rather than promise brand-level support. [CITED: https://github.com/ggml-org/whisper.cpp] |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | A manifest with SHA-256 and atomic promotion is sufficient for safe local model lifecycle. | Standard Stack / pitfalls | Need stronger signature/provenance/update controls. |
| A2 | `0.8` RTF and 3 s p95 is a suitable Phase-1 admission threshold. | Pattern 3 | Target PC may need a different chunk/finalization budget. |
| A3 | A CLI/sidecar JSON contract is the lowest-risk host-to-ASR boundary. | Code Examples | Binding directly may prove simpler after packaging spike. |

## Open Questions (RESOLVED)

1. **Benchmark source flow — resolved by D-17.**
   - After the model is ready, setup asks the user to select a temporary exact endpoint and records a bounded local clean Vietnamese sample before the benchmark. This temporary endpoint is candidate-only, is never written as the livestream source, and the sample is deleted on cancellation or after the setup transaction resolves. The official livestream source is selected only after benchmark completion.

2. **Model artifact and provenance — resolved as an immutable manifest gate.**
   - The selected default is the largest unquantized multilingual `ggml-large-v3.bin` artifact compatible with the pinned `whisper.cpp` worker revision. Before download code or activation is accepted, `src-tauri/resources/model-manifest.json` must record the immutable upstream repository and commit/revision, exact artifact URL, byte size, SHA-256, GGML format, redistribution/license provenance, and compatible worker revision. Only those recorded bytes may become Ready; a missing provenance/hash/license field is a blocking manifest error rather than an invitation to choose a smaller or mutable artifact.

3. **Windows support floor and compatibility policy — resolved.**
   - Initial supported hosts are 64-bit Windows 10 22H2 and Windows 11 with WebView2 and the MSVC runtime. Older Windows releases and non-x64 hosts fail a visible compatibility preflight; the app does not advertise them as supported. CPU is the mandatory inference baseline on supported hosts. CUDA/Vulkan acceleration is reported only after its packaged worker passes the target-PC self-test and benchmark; an unsupported or failing GPU configuration visibly falls back to CPU only when CPU admission passes, otherwise setup remains blocked with the exact failure reason.

## Environment Availability

| Dependency | Required By | Available here | Version | Fallback |
|------------|-------------|----------------|---------|----------|
| Node/npm | Tauri/frontend scaffold | ✓ | Node `v22.22.1`, npm `9.2.0` | — |
| Rust/cargo/rustc | Windows host and tests | ✗ | — | Install Rust MSVC toolchain on target Windows machine. |
| CMake | `whisper.cpp` worker builds | ✗ | — | Install on Windows build machine. |
| Windows WASAPI device/driver/GPU | CAPT-01/02/03 and benchmark | ✗ (Linux research host) | — | Manual target-PC acceptance matrix; no emulator substitutes. |

**Missing dependencies with no fallback:** target Windows hardware/driver matrix for capture and GPU self-tests.  
**Missing dependencies with fallback:** Rust and CMake can be installed on the Windows build machine before execution.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | None yet — greenfield; establish Rust unit tests plus Windows-only manual/integration harness. |
| Config file | none — Wave 0 |
| Quick run command | `cargo test` (after scaffold) |
| Full suite command | `cargo test --all-targets` plus Windows device/worker acceptance script |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CAPT-01 | Exact ID persists; absent ID never switches default. | Unit + Windows manual | `cargo test audio::source_config` | ❌ Wave 0 |
| CAPT-02 | Selected render endpoint opens shared loopback. | Windows integration/manual | target-PC capture harness | ❌ Wave 0 |
| CAPT-03 | Meter follows PCM; silent/unavailable states are actionable. | Unit + Windows integration | `cargo test audio::meter` | ❌ Wave 0 |
| AI-03 | CPU and each installed worker must pass smoke/corpus admission; active backend is reported. | Windows integration/manual | target-PC benchmark harness | ❌ Wave 0 |

### Wave 0 Gaps

- [ ] Rust application scaffold and test configuration.
- [ ] Deterministic 16 kHz Vietnamese smoke WAV + expected normalized transcript, committed only with consent/license.
- [ ] Windows-only endpoint test harness (input and selected-render loopback) and a manual no-Stereo-Mix checklist.
- [ ] Model manifest fixture/checksum tests and worker-result parser tests.

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|------------------|
| V2 Authentication | No | No user/account or remote API in Phase 1. |
| V3 Session Management | No | No web session in Phase 1. |
| V4 Access Control | Yes | Local GUI commands only; do not create remote capture/model control endpoints. |
| V5 Input Validation | Yes | Validate endpoint IDs as opaque values, manifest schema/size/hash, worker JSON schema, and bounded diagnostic strings. |
| V6 Cryptography | Yes | Use platform TLS for download and a vetted SHA-256 implementation; never hand-roll hashing. |
| V10 Malicious Code | Yes | Pin worker source/model artifact provenance; verify hash before activation; do not execute a downloaded binary. |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Tampered or incomplete model | Tampering | HTTPS allowlist, immutable manifest, preflight disk check, SHA-256, temporary file then atomic promote. |
| Malicious worker result / huge output | Tampering, DoS | Strict JSON schema, output-size cap, timeout, exit-code check; keep worker unprivileged. |
| Sensitive audio in logs/fixtures | Information disclosure | Store user benchmark audio locally only; no raw audio/transcript diagnostics by default; require explicit consent for committed fixtures. |
| Endpoint ID parsing/label confusion | Tampering | Treat Windows ID opaque and compare exact string; display labels are non-authoritative. |

## Sources

### Primary

- [Microsoft WASAPI loopback recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording) — selected render-endpoint loopback, shared-mode rule, event-driven Windows 10 1703 support, and protected-content limitation.
- [Microsoft IMMNotificationClient](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient) — opaque endpoint IDs, notification types, and nonblocking callbacks.
- [Microsoft IAudioCaptureClient::GetBuffer](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer) — packet/release ordering, silent/discontinuity flags, and device invalidation.
- [Microsoft device formats](https://learn.microsoft.com/en-us/windows/win32/coreaudio/device-formats) — shared-mode mix format and format support constraints.
- [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) — worker build options, model list, CPU/CUDA/Vulkan/HIP support, and benchmark tools.

### Secondary

- [`wasapi` 0.24 docs](https://docs.rs/wasapi/latest/wasapi/) — documented Rust wrapper capability; package legitimacy still needs human verification.
- [Microsoft IAudioMeterInformation](https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nn-endpointvolume-iaudiometerinformation) — endpoint peak-meter semantics.

## Metadata

**Confidence breakdown:**
- Standard stack: MEDIUM — WASAPI and `whisper.cpp` are documented; target Windows packaging and model artifact are not yet proven.
- Architecture: MEDIUM — endpoint/worker boundaries follow official API constraints; exact host binding awaits scaffold.
- Pitfalls: HIGH for WASAPI lifecycle/format limitations; MEDIUM for backend and Vietnamese latency thresholds because they require the owner’s target PC/corpus.

**Research date:** 2026-08-19  
**Valid until:** 2026-09-18 for Windows API facts; revalidate `whisper.cpp` commit, model artifact, and hardware profile immediately before implementation.
