# Architecture Research

**Domain:** Local-first Windows desktop livestream subtitles
**Researched:** 2026-08-19
**Confidence:** MEDIUM

## Recommendation

Ship one Windows desktop application with a small Rust host (Tauri 2) and a bundled, supervised Python inference sidecar. The host owns Windows audio capture, persisted settings, the desktop GUI bridge, and the local overlay server. The sidecar owns only CPU/GPU model loading and inference. This keeps Windows/streaming integration native and makes an inference or CUDA failure restartable without taking down the control window or OBS overlay.

Use a **single active audio session** in v1. It has one selected source: a capture endpoint (microphone), a render-endpoint loopback (desktop/system audio), or a user-selectable Windows device. Convert all captured audio to mono 16 kHz PCM before it leaves the host. Never expose raw audio to the overlay or persist it by default.

The app should be local-only: bind the overlay HTTP/WebSocket service to `127.0.0.1`, choose a free port at launch, and present the exact overlay URL to copy into OBS. No OBS WebSocket integration is needed.

## Standard Architecture

### System Overview

```
┌──────────────────────────── Windows desktop application ────────────────────────────┐
│  Control GUI (Tauri WebView)                                                         │
│  source/model/overlay settings · session status · caption preview                    │
│          │ Tauri commands + events                                                   │
│          ▼                                                                            │
│  Rust application host                                                               │
│  ┌─────────────┐  ┌───────────────────┐  ┌────────────────┐  ┌─────────────────────┐ │
│  │ Settings    │  │ Session controller│  │ Caption store  │  │ Overlay HTTP + WS   │ │
│  │ repository  │  │ state machine     │  │ current state  │  │ 127.0.0.1 only      │ │
│  └─────────────┘  └───────┬───────────┘  └───────▲────────┘  └─────────▲───────────┘ │
│                            │                      │                     │             │
│  ┌─────────────────────────▼──────────────────────┴─────────────────────┴──────────┐  │
│  │ Capture worker: WASAPI capture endpoint OR shared-mode render loopback          │  │
│  │ device enumeration / invalidation recovery / resample + mono PCM / bounded queue│  │
│  └──────────────────────────────────────────┬──────────────────────────────────────┘  │
│                                             │ framed PCM IPC                            │
│                               supervised local child process                             │
│                                             ▼                                             │
│  Python inference sidecar                                                               │
│  ┌─────────┐  ┌──────────────┐  ┌────────────────┐  ┌───────────────────────────────┐ │
│  │ VAD +   │→ │ ASR backend  │→ │ local EN       │→ │ caption event serializer      │ │
│  │ segment │  │ Vietnamese   │  │ translation    │  │ provisional / final / status  │ │
│  └─────────┘  └──────────────┘  └────────────────┘  └───────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                      WebSocket snapshots/events
                                              ▼
                    OBS Browser Source → `http://127.0.0.1:<port>/overlay`
```

### Process and failure boundaries

| Boundary | Owner | Contract | Why it exists | Failure handling |
|---|---|---|---|---|
| Tauri GUI ↔ Rust host | app process | JSON commands for deliberate actions; events for state/caption updates | GUI cannot access capture/model internals directly | GUI reload does not interrupt a running session; host re-emits its snapshot |
| Host ↔ inference sidecar | parent-supervised child process over newline-delimited framed IPC on stdio | `configure`, `audio_frame`, `flush`, `stop`; sidecar emits `ready`, `caption`, `health`, `error` | Isolates Python/CUDA native dependencies and allows model restart | Host stops forwarding frames, retains last final caption, reports degraded status, then restarts with backoff |
| Capture worker ↔ session controller | bounded in-process channel of normalized PCM frames | non-blocking `AudioFrame { sequence, start_ms, pcm16 }` | Capture callbacks must not wait for VAD, ASR, translation, disk, or UI | On pressure drop oldest unprocessed frames and surface an overrun counter; do not grow memory without limit |
| Caption store ↔ GUI/overlay | immutable `CaptionSnapshot` plus monotonic revision | full snapshot at connection, then deltas | Consumers reconnect independently and never own caption state | Slow/failed consumer is removed; it cannot block capture or inference |
| Host ↔ Windows Core Audio | explicit WASAPI/MMDevice adapter | device identity, format, state and error events | Keeps COM/WASAPI assumptions out of session logic | Recreate the capture client after device invalidation; preserve settings and ask the user only if the selected device is gone |

Do not make the overlay a second controller. It receives a read-only stream of captions and style snapshot; all commands remain in the desktop GUI.

### Component Responsibilities

| Component | Responsibility | Key inputs / outputs |
|---|---|---|
| `DeviceCatalog` | Enumerate capture and render endpoints; expose stable Windows endpoint IDs and friendly names; observe add/remove/default changes | `DeviceListChanged`, selected endpoint metadata |
| `WASAPICapture` | Open the chosen endpoint; use normal capture for microphone and shared-mode loopback on a render endpoint for desktop audio; normalize format | PCM frame or typed `DeviceInvalidated` / `AccessError` |
| `AudioNormalizer` | Channel mix-down, sample-rate conversion, timestamp and bounded framing | e.g. 20–100 ms PCM16 frames at ASR-required rate |
| `SessionController` | Own lifecycle: `idle → starting → running → stopping → idle`, plus `degraded`; coordinate capture and sidecar | validated settings in; state/status out |
| `InferenceSupervisor` | Start one packaged sidecar, negotiate capability/health, send frames and configurations, restart safely | typed IPC; no model logic in host |
| `InferenceEngine` | VAD segmentation, Vietnamese ASR, local English translation, model warm-up and GPU/CPU fallback | `CaptionEvent` and health/metrics |
| `CaptionReducer` | Apply ordered provisional/final events into the canonical current caption snapshot | revisioned `CaptionSnapshot` |
| `OverlayServer` | Serve static transparent page and a WebSocket endpoint; issue a snapshot on connect | localhost HTTP/WebSocket only |
| `SettingsRepository` | Store schema-versioned, non-secret local settings and overlay theme | atomic load/save; validates before session start |
| `Control GUI` | Device/model/quality/overlay settings, start/stop, preview, diagnostics and copyable URL | Tauri command/event adapter only |

## Core Contracts

Keep these platform- and model-neutral from the first implementation. They are the seam for later cloud providers, another translation model, or a different capture backend.

```ts
type AudioSource =
  | { kind: "capture"; endpointId: string }       // microphone/input device
  | { kind: "loopback"; endpointId: string };     // desktop/render-device mix

type CaptionState = "provisional" | "final";

type CaptionEvent = {
  sessionId: string;
  eventId: number;             // strictly increasing for this session
  segmentId: string;
  state: CaptionState;
  startMs: number;
  endMs?: number;
  vietnamese: string;
  english?: string;            // omitted when translation disabled or still pending
};

type CaptionSnapshot = {
  sessionId: string;
  revision: number;
  status: "idle" | "starting" | "running" | "degraded" | "error";
  lines: CaptionEvent[];       // current on-screen line(s), never unbounded history
  overlay: { showVietnamese: boolean; showEnglish: boolean; theme: OverlayTheme };
};
```

**IPC rules:** audio frames use a binary-safe length-prefixed representation (or base64 only for the earliest spike); control/event records use newline-delimited JSON with a protocol version. A `configure` command names a **local model directory and requested profile**, never arbitrary executable paths or shell strings. Sidecar output is treated as untrusted data, size-limited, schema-validated, and discarded if its `sessionId` or ordering is stale.

## Audio and Caption Data Flow

### Session start

```
User selects device/model/profile and presses Start
  → GUI validates fields locally
  → Host validates persisted settings and resolves endpoint ID
  → Host starts/waits for sidecar `ready(capabilities)`
  → Host starts capture worker and emits `running`
  → GUI + every overlay client receive a complete CaptionSnapshot
```

### Live pipeline

```
Windows device
  → WASAPI callback (capture or render-loopback)
  → normalize to timestamped 16 kHz mono PCM
  → bounded host→sidecar queue
  → VAD accumulates one utterance with a short trailing-silence boundary
  → Vietnamese ASR emits a provisional caption only when useful
  → accuracy-oriented final decode
  → local English translation of the final Vietnamese text
  → CaptionReducer replaces the matching segment and increments revision
  → broadcast `{type: "caption", snapshot}` to GUI and WebSocket clients
  → overlay renders only enabled languages/styles on a transparent background
```

For accuracy-first v1, use provisional text sparingly: retain it only while the VAD segment is open, replace it with one finalized Vietnamese segment, then attach or replace English translation. This avoids visually noisy word-by-word churn while still proving the pipeline is alive. The caption store keeps a small screen window (for example, current and previous finalized line), not a full transcript; transcription history is a later, opt-in feature.

### Reconnect and ordering

1. On WebSocket connect, `OverlayServer` sends a full `snapshot` with revision `N`.
2. Subsequent messages contain revision `N + 1`; a client that sees a gap reconnects and replaces local state from the snapshot.
3. On session stop or restart, session ID changes. Clients discard events from an older session.
4. Overlay rendering must be idempotent: repeated snapshots produce the same screen.

## Model Lifecycle and Hardware Policy

1. **First run / model manager:** download or import approved model assets into an app-owned directory, verify a manifest/checksum, and record exact model/version. This network-only bootstrap is distinct from runtime transcription; v1 runtime uses `local_files_only`.
2. **Capability probe:** sidecar reports detected backend, GPU name/VRAM when available, supported compute types, and available model assets. The GUI offers only compatible profiles.
3. **Warm-up:** load ASR and translation models once per session/configuration and run a short warm-up before capture starts. Never reload a model per audio chunk.
4. **Profile selection:** prefer configured supported GPU execution; if it cannot load or runs out of memory, fall back to a documented smaller/quantized local profile or CPU profile and mark the session `degraded`. Do not silently change accuracy settings.
5. **Bounded work:** process only one ASR segment at a time in v1. Translation consumes finalized captions in its own bounded queue so it cannot delay final Vietnamese captions.
6. **Shutdown:** stop accepting PCM, flush a bounded final segment with a timeout, then terminate the child gracefully; kill only after timeout. Free models when the process exits.

`faster-whisper`/CTranslate2 is a plausible initial ASR backend because it provides local model loading, CPU threading and CUDA/compute-type choices. Its NVIDIA runtime dependencies are version-sensitive, so they must be packaged/probed as a deployment concern—not assumed at app startup. The model interface remains generic:

```text
AsrBackend.transcribe(segment, language="vi", profile) -> VietnameseSegment
TranslationBackend.translate(vietnamese, source="vi", target="en", profile) -> EnglishText
```

## Windows-Specific Integration Boundaries

| Boundary | Required behavior | Keep out of |
|---|---|---|
| WASAPI normal capture | Capture from the selected input endpoint; negotiate shared-mode format then normalize | GUI components and ASR code |
| WASAPI render loopback | Select a render endpoint and initialize **shared-mode** loopback to capture its system mix; it is not a “Stereo Mix” hardware device | generic `AudioSource` callers |
| Device lifecycle | Register endpoint notifications; retain stable endpoint ID; distinguish changed default device from removed selected device | overlay/model sidecar |
| COM/threading | Initialize and release COM in the capture worker according to the chosen Rust Windows binding’s requirements; confine interfaces to their owning thread | app-wide state |
| Packaged sidecar | Bundle per Windows target architecture, launch via Tauri’s explicit sidecar configuration, supervise PID and stdio | arbitrary GUI shell execution |
| Windows security/antivirus | Sign/release-test host and child together; make child path fixed and internal; do not spawn user-provided executables | settings values |

Microsoft documents that WASAPI loopback captures a render endpoint’s audio in shared mode, even without a hardware loopback device. It also documents `AUDCLNT_E_DEVICE_INVALIDATED` recovery and endpoint notifications. Treat device loss as an ordinary state transition, not a crash.

## Recommended Project Structure

```
apps/desktop/
├── src/                         # Control UI: settings, preview, diagnostics
│   ├── features/session/
│   ├── features/overlay/
│   └── lib/tauri-client.ts       # typed command/event client only
├── src-tauri/
│   └── src/
│       ├── commands/             # narrow GUI-facing API
│       ├── audio/                # WASAPI adapter, normalizer, device catalogue
│       ├── session/              # lifecycle controller and typed state
│       ├── captions/             # reducer and snapshot store
│       ├── overlay/              # HTTP/WebSocket and static asset serving
│       ├── settings/             # schema, migration and atomic repository
│       └── inference/            # sidecar protocol and supervisor
└── src-tauri/binaries/           # packaged inference child, target-suffixed
services/inference/
├── app.py                        # IPC entry point; no HTTP/UI server
├── protocol.py                   # versioned message schema
├── vad.py
├── asr.py
├── translate.py
├── models.py                     # capability probe/load/warm-up/cleanup
└── tests/
packages/contracts/               # JSON schema/types shared at the process boundary
```

This is intentionally one product, not microservices. The only process split is where native AI dependencies make graceful restart and packaging worth the cost.

## Dependency-Respecting Build Order

1. **Foundation and contracts:** create the Tauri shell, schema-versioned settings, session state machine, `CaptionSnapshot` reducer, and local static overlay with simulated captions. Verify overlay reconnect/snapshot behavior before AI work.
2. **Windows audio capture:** build endpoint enumeration, microphone capture, shared-mode loopback, normalizing/resampling and device-change recovery. Verify with generated metering and bounded-queue overload tests.
3. **Local ASR sidecar:** define versioned IPC, supervision/health reporting, local Vietnamese ASR model manager, warm-up and CPU path. Verify known Vietnamese fixtures and restart recovery.
4. **GPU profiles and accurate segmentation:** add capability probing, CUDA packaging checks, VAD/segment state, accuracy-oriented final captions, metrics and explicit CPU/degraded fallback. Verify no capture stalls when inference is slow.
5. **Local English translation and caption policy:** add translation backend, translated-final updates, language toggles and current-line window. Verify ordering and that ASR final output is not blocked by translation failure.
6. **Operator UX and release hardening:** complete settings/diagnostics, model/download UX, packaging/signing, streaming-software setup instructions, and long-running/manual device-loss tests.

## Anti-Patterns

### Put capture, inference, HTTP server, and GUI on one event loop

**Why it fails:** model load, CUDA failure, a slow translation, or a stalled WebSocket can interrupt audio capture and break the livestream.

**Instead:** isolate blocking capture work and the inference child; connect every slow boundary with bounded queues and state transitions.

### Treat desktop audio as just another microphone device

**Why it fails:** “desktop audio” is the mix rendered to a selected output endpoint. It may not appear as a capture device and depends on WASAPI loopback/shared mode.

**Instead:** model capture and loopback as separate source kinds, expose render endpoints for loopback, and label them clearly in the GUI.

### Broadcast append-only text to the overlay

**Why it fails:** ASR revisions and translation arrival cause duplicated or stale lines after reconnect.

**Instead:** use segment IDs, revisions, `provisional`/`final` state, and authoritative snapshots.

### Open a LAN-accessible control/overlay API

**Why it fails:** other local-network clients could read stream content or control a microphone/session.

**Instead:** bind to loopback only; no remote control API in v1. The overlay is read-only and its URL should use a per-launch random token if the server ever needs to bind beyond loopback.

### Assume any Windows GPU is compatible with the first model backend

**Why it fails:** CUDA/cuBLAS/cuDNN compatibility and VRAM differ; an unsupported GPU can make startup fail or exhaust memory.

**Instead:** capability-probe at launch, show the selected execution profile, verify it on warm-up, and offer an explicit local CPU fallback.

## Scaling Considerations

This is a single-user desktop product. The first limits are inference latency/VRAM and device resilience, not concurrent users. Keep one active capture session and a small number of overlay clients. If future work adds remote consumers or cloud AI, add an authenticated service boundary then; do not prebuild multi-user infrastructure in v1.

## Sources

- [Microsoft: WASAPI loopback recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording) — MEDIUM via official documentation.
- [Microsoft: recovering from invalid-device errors](https://learn.microsoft.com/en-us/windows/win32/coreaudio/recovering-from-an-invalid-device-error) and [endpoint notifications](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient) — MEDIUM via official documentation.
- [Tauri: inter-process communication](https://v2.tauri.app/concept/inter-process-communication/) and [embedding external binaries](https://tauri.app/develop/sidecar/) — MEDIUM via official documentation.
- [faster-whisper README](https://github.com/SYSTRAN/faster-whisper) — MEDIUM; project documentation, confirm exact CUDA packaging during implementation.

---
*Architecture research for: Local Live Subtitle Tool*
*Researched: 2026-08-19*
