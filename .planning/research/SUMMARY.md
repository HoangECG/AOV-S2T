# Project Research Summary

**Project:** Local Live Subtitle Tool  
**Domain:** Local-first Windows livestream captioning with a browser overlay  
**Researched:** 2026-08-19  
**Confidence:** MEDIUM

## Executive Summary

This is a single-user Windows desktop application: it captures one selected microphone/input endpoint or the loopback mix of one selected render endpoint, produces accuracy-first Vietnamese captions locally, optionally translates finalized captions to English, and exposes the result through a transparent Browser Source URL. The appropriate design is a native Windows host rather than a browser-only recorder: WASAPI is needed for reliable selected-device and system-audio capture, while model inference must remain off the GUI/capture path.

The recommended product shape is Tauri 2 with a Rust host for GUI integration, WASAPI, settings, session state, and a loopback-only HTTP/WebSocket overlay; native inference runs in a supervised local worker behind a versioned contract. Normalize capture to 16 kHz mono PCM, use bounded queues and revisioned caption snapshots, and render finalized captions by default. English translation must run only after Vietnamese finalization and must never delay or replace newer Vietnamese text.

The main delivery risks are not web UI complexity: they are Windows endpoint lifecycle, hardware/model compatibility, real-time backlog, Vietnamese quality on actual livestream audio, and OBS Browser Source lifecycle. Mitigate them with an early machine-specific feasibility benchmark, an always-tested CPU fallback, explicit device recovery states, long-run latency/overrun metrics, a locked Vietnamese evaluation set, and real OBS reconnect tests. Local-only still needs privacy controls: bind to loopback, keep the overlay read-only, escape caption text, and avoid retaining audio/transcripts by default.

## Key Findings

### Recommended Stack

Use a Windows-first Tauri 2 application with a Rust/MSVC host. Direct WASAPI support is required for shared-mode render-endpoint loopback; do not depend on Stereo Mix or browser `getUserMedia`. The host serves a static overlay through Axum/Tokio on `127.0.0.1` and pushes complete state via WebSocket rather than polling.

**Core technologies:**

- **Tauri 2 + Rust (MSVC/WebView2):** compact Windows GUI, packaging, host lifecycle, and native integration.
- **`wasapi` + resampler + bounded PCM channel:** enumerate stable endpoint IDs; capture microphones or selected render loopback; normalize to mono 16 kHz without blocking callbacks.
- **Local ASR runtime:** evaluate a pinned `whisper.cpp`/`whisper-rs` build as the primary stack recommendation; retain a generic ASR-worker interface so a benchmarked `faster-whisper` implementation remains a viable alternative. Use a multilingual accuracy preset, CPU fallback, and CUDA only after a successful runtime probe.
- **Bundled CTranslate2 worker + pinned Helsinki `opus-mt-vi-en`:** local Vietnamese-to-English translation of finalized segments; CPU by default, optional CUDA only when measured VRAM headroom exists.
- **Axum/Tokio WebSocket overlay:** one transparent local URL, snapshot on connect plus monotonic revisions, tiny static DOM, no direct OBS control.

Model assets need versioned manifests, checksums, licensing records, resumable first-run download, disk-space checks, and an offline runtime after installation. GPU support must be advertised only for validated configurations: NVIDIA CUDA is the initial supported acceleration path; CPU is mandatory; cross-vendor Vulkan is experimental until tested.

### Expected Features

**Must have (table stakes):**

- Explicit single-source picker for microphone/input or selected desktop render-loopback, with level meter, source label, and actionable device/model errors.
- Start/stop session controls and private health status: model/backend readiness, audio activity, queue/caption age, translation state, and overlay connectivity.
- Stable, short Vietnamese final captions with a bounded recent on-screen buffer; public partial rewrites are off by default.
- Optional local Vietnamese-to-English translation, with Vietnamese-only, English-only, and bilingual display choices.
- Stable transparent local overlay URL, copy action, reconnect behavior, and shared preview/render state.
- GUI configuration for language visibility/order, typography, contrast/outline or backing, position/alignment, safe padding, and visible line count.

**Should have (competitive):**

- Accuracy-first named profile with observable caption delay rather than raw decoding knobs.
- Audio-routing preflight/test-caption flow, CPU/GPU backend visibility, and degraded-state feedback.
- Reconnect-safe overlay snapshots across OBS reload, scene changes, and app GUI reload.

**Defer (v2+):** cloud providers/API keys, additional languages or automatic language detection, direct OBS/platform integrations, audio-file transcription, transcript archives/export, multi-source mixing, diarization, and automatic rewriting/moderation.

### Architecture Approach

Build one app, not a distributed system. The Rust host owns `DeviceCatalog`, `WASAPICapture`, normalization, session controller, schema-versioned settings, canonical caption reducer/store, and overlay server. A parent-supervised local inference worker owns VAD/segmentation, Vietnamese ASR, translation, warm-up, and CPU/GPU capability reporting. The GUI and overlay are independent read-only consumers of immutable, revisioned caption snapshots; GUI reloads or an overlay disconnect must not interrupt capture.

**Major components:**

1. **Windows capture subsystem** — endpoint enumeration, normal capture or render loopback, device notifications, mix-down/resampling, bounded frame handoff.
2. **Session and inference supervision** — lifecycle states, worker IPC, warm-up, capability probe, health/error reporting, explicit fallback/restart.
3. **Caption pipeline and reducer** — VAD, finalization, stable IDs and ordering, independently bounded translation queue, current-lines-only state.
4. **Overlay server and renderer** — loopback-only static page plus WebSocket snapshots/deltas; transparent, reconnecting, text-node rendering.
5. **Control GUI/settings** — validated source/model/appearance controls, diagnostics, preview, and copyable overlay URL.

### Critical Pitfalls

1. **Treating desktop audio as Stereo Mix or a permanent device** — use shared-mode WASAPI loopback for an explicitly selected render endpoint, persist endpoint IDs, normalize format, and handle hot-plug/default-device changes visibly.
2. **Blocking capture or allowing backlog to grow** — keep callbacks minimal, isolate slow inference/translation, enforce bounded queues and a declared overload policy, and measure capture-to-final delay continuously.
3. **Fixed chunks and visible unstable hypotheses** — separate framing, VAD, decoding, and rendering; deduplicate segment IDs; default to finalized captions and conservative endpointing.
4. **Selecting a model from generic benchmarks** — build a consented Vietnamese evaluation set with the owner’s mic, desktop/Discord/game audio, accents, names, code-switching, diacritics, timing, and translation usefulness; select hardware/model profiles from measured results.
5. **Assuming universal GPU support** — probe actual backend/model compatibility, warm models before Go Live, reserve combined ASR+translation headroom, show active backend/fallback, and keep a tested CPU path.
6. **Fragile or exposed overlay** — test OBS reload/scene lifecycle, use snapshot-on-reconnect and a tiny DOM, bind only to loopback, separate all controls from the read-only overlay, schema-limit inputs, and render transcript as escaped text.

## Implications for Roadmap

### Phase 1: Foundation, Windows Audio, and Local-Inference Feasibility

**Rationale:** Audio-device correctness and a demonstrated local performance/quality baseline are prerequisites for every visible caption feature. This phase should decide the actual supported ASR runtime/profile instead of baking in an unbenchmarked GPU claim.

**Delivers:** Tauri/Rust shell; session state and schema-versioned settings; stable device catalog; normal microphone/input capture; selected render-endpoint WASAPI loopback; 16 kHz mono normalization; meters and device-loss state; local model manager with verified assets; CPU self-test and CUDA probe/fallback; a benchmark harness and locked Vietnamese fixture corpus.

**Addresses:** explicit source selection, audio routing preflight, model readiness/backend status.

**Avoids:** Stereo Mix dependency, endpoint-name persistence, raw-format mistakes, unsupported GPU startup, and Vietnamese-quality assumptions.

### Phase 2: Accuracy-First Caption and Translation Pipeline

**Rationale:** Once audio and model feasibility are proven, build the real-time contract that protects liveliness and caption stability before polishing presentation.

**Delivers:** supervised inference worker and versioned IPC; bounded PCM/ASR/translation queues; VAD and conservative segmentation; provisional/final segment IDs; final Vietnamese caption reducer; local English translation only for final segments; stale-result cancellation; caption-age/queue/overrun metrics and explicit degraded behavior.

**Addresses:** local Vietnamese captions, optional bilingual output, accuracy-over-minimum-latency policy, operational health indicators.

**Avoids:** capture starvation, unbounded latency, duplicate/flickering captions, and English overwriting newer Vietnamese captions.

### Phase 3: Transparent Overlay and Control GUI

**Rationale:** A stable caption snapshot now exists, so the GUI and browser source can consume the same authoritative state without encoding inference behavior in the renderer.

**Delivers:** loopback-only Axum HTTP/WebSocket server; transparent overlay with snapshot-on-connect/revision handling; configurable bilingual layout/styles and exact-resolution preview; copyable URL/OBS checklist; start/stop, device/model/settings controls, and health dashboard.

**Addresses:** transparent stream overlay, language visibility/order, appearance/layout controls, reconnect-safe usage, and user-facing diagnostics.

**Avoids:** polling/stale DOM, overlay-controller privilege, black/incorrect OBS rendering, scene-switch disconnects, XSS, and private transcript exposure.

### Phase 4: Quality Gate, Packaging, and Stream Hardening

**Rationale:** The product becomes trustworthy only after long-running, actual-hardware and actual-OBS validation; packaging native dependencies is part of the product contract.

**Delivers:** regression suite and benchmark thresholds for Vietnamese ASR/translation; device/hot-plug, overload, CPU/GPU, and OBS lifecycle tests; first-run model download/recovery; installer/sidecar packaging and diagnostics; privacy/log-retention review; end-user setup guidance.

**Addresses:** reliable livestream operation and measured local-first quality.

**Avoids:** regressions in accents/terms/diacritics, VRAM exhaustion with English enabled, fresh-install failures, silent CPU fallback, and unsafe diagnostic retention.

### Phase Ordering Rationale

- Capture and model feasibility must precede segmentation because accurate caption policy is meaningless without reliable audio and a measured real-time profile.
- The caption state contract precedes overlay work so GUI and OBS consume revisions/snapshots rather than ad-hoc appended text.
- Translation belongs beside finalization: it depends on finalized Vietnamese IDs but must remain isolated so Vietnamese captions survive translation delay/failure.
- Reliability, privacy, and packaging are explicit release work because local native dependencies and OBS lifecycle cannot be validated by unit tests alone.

### Research Flags

Phases likely needing deeper research during planning:

- **Phase 1:** benchmark the conflicting ASR-runtime candidates (`whisper.cpp`/`whisper-rs` recommendation versus `faster-whisper` implementation option), Vietnamese model/quantization, and target-PC CPU/GPU packaging. This is the highest-impact unresolved decision.
- **Phase 2:** choose and tune VAD/endpointing against representative Vietnamese livestream audio; establish measurable latency and overload thresholds.
- **Phase 4:** research/validate Tauri sidecar distribution, CUDA dependency packaging, signing, and the final supported Windows hardware matrix.

Phases with standard patterns (skip research-phase unless implementation evidence contradicts them):

- **Phase 3:** Tauri control UI, local WebSocket snapshots, static transparent HTML/CSS, and OBS Browser Source are documented patterns; focus on integration and real OBS tests.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM | Windows/WASAPI, Tauri, OBS, and CTranslate2 claims are anchored in official documentation; the final ASR runtime and non-NVIDIA path need target-machine benchmarks. |
| Features | MEDIUM | Feature set is well supported by official Windows/Teams/OBS behavior and project scope, but only one primary user has validated workflow priorities. |
| Architecture | MEDIUM | Process isolation, bounded queues, snapshots, and local overlay boundaries follow established patterns; native sidecar packaging needs a spike. |
| Pitfalls | MEDIUM | Risks are strongly corroborated by platform docs and domain behavior, while exact WER/latency/VRAM limits remain hardware and audio-domain specific. |

**Overall confidence:** MEDIUM

### Gaps to Address

- **ASR backend and model profile:** run repeatable accuracy/real-time-factor benchmarks on the actual Windows machine before locking `whisper.cpp`/`whisper-rs` or `faster-whisper`; include warmed ASR plus English translation.
- **Supported hardware matrix:** define the minimum CPU baseline and exact initial NVIDIA CUDA versions/VRAM; leave AMD/Intel GPU acceleration experimental until verified.
- **Vietnamese quality acceptance bar:** create consented representative recordings and decide target thresholds for WER/usefulness, diacritics/punctuation, finalization delay, and translation latency.
- **Overlay security detail:** decide whether a loopback-only URL alone is adequate or a per-session capability token is required; keep privileged settings/actions inaccessible either way.
- **Installer/model-distribution policy:** decide model pack size, first-run download/import flow, offline-install requirements, signing, and update/rollback behavior.
- **Translation UX:** decide the maximum tolerated English delay and fallback behavior; Vietnamese must remain correct/useful when translation is unavailable.

## Sources

### Primary (HIGH confidence)

- [Microsoft WASAPI loopback recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording) — selected render-endpoint, shared-mode system audio capture.
- [Microsoft audio endpoint notifications](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient) — endpoint lifecycle handling.
- [Tauri Windows prerequisites](https://v2.tauri.app/start/prerequisites/) and [sidecars](https://tauri.app/develop/sidecar/) — Windows build/runtime and packaged child-process boundaries.
- [OBS Browser Source](https://obsproject.com/kb/browser-source) — URL browser sources and transparent overlay behavior.

### Secondary (MEDIUM confidence)

- [`wasapi` documentation](https://docs.rs/wasapi/latest/wasapi/) and [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — capture and native ASR backend capabilities.
- [CTranslate2 installation/hardware support](https://opennmt.net/CTranslate2/installation.html) and [Helsinki `opus-mt-vi-en`](https://huggingface.co/Helsinki-NLP/opus-mt-vi-en) — local translation runtime/model support and license.
- [Windows Live Captions](https://support.microsoft.com/en-US/accessibility/windows/use-live-captions-to-better-understand-audio) and [Teams live captions](https://support.microsoft.com/en-us/teams/meetings/use-live-captions-in-microsoft-teams-meetings) — expected caption, translation, and style controls.
- [PhoWhisper](https://arxiv.org/abs/2406.02555) and [Gipformer benchmarks](https://github.com/ggroup-ai-lab/gipformer) — need for Vietnamese domain/dialect evaluation.

---
*Research completed: 2026-08-19*  
*Ready for roadmap: yes*
