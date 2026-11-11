# Technology Stack: Local Live Subtitle Tool

**Project:** Local Live Subtitle Tool  
**Researched:** 2026-08-19  
**Confidence:** MEDIUM — the platform, audio, overlay, and inference-runtime claims are verified against current primary documentation. Final model quality and the non-NVIDIA GPU path need benchmark validation on the target PC.

## Decision

Build a **Windows-first Tauri 2 desktop application** with a Rust capture/overlay host. Capture audio through **WASAPI directly** (not a cross-platform abstraction), run Vietnamese STT through a versioned **whisper.cpp** backend, and put the local Vietnamese-to-English translator behind a small bundled **Python/CTranslate2 worker**. Serve a static overlay from a loopback-only HTTP/WebSocket endpoint for any streaming application's Browser Source.

This is deliberately a native-host design, not a browser-only app: Windows system audio requires WASAPI loopback, and real-time local inference must remain outside the WebView process. The one Python boundary is justified by CTranslate2's maintained translation API and its Windows CPU/CUDA distribution; it must be a private local worker, never a user-managed service.

## Recommended Stack

### Core Technologies

| Technology | Version to start with | Purpose | Why recommended |
|---|---:|---|---|
| [Tauri](https://v2.tauri.app/) | JS API `2.11.1`; CLI `2.11.4` | Native Windows GUI, updater/installer packaging, WebView UI shell | A small Windows desktop host with a TypeScript settings UI; uses the system WebView2 rather than shipping a separate Chromium runtime. Use vanilla TypeScript/CSS for v1—the GUI is a control panel, not a complex web product. |
| Rust, MSVC target | current stable `x86_64-pc-windows-msvc` | Process lifecycle, settings, audio pipeline, overlay server | Keeps low-latency capture and native DLL handling in one compiled host. Tauri's Windows prerequisites explicitly require the MSVC toolchain and WebView2. |
| [`wasapi`](https://docs.rs/wasapi/latest/wasapi/) | `0.24.0` | Enumerate endpoints, microphone capture, selected-render-device loopback, device notifications | Exposes the Windows audio API features this product actually needs: loopback, event-driven buffering, endpoint change notifications, and device enumeration. WASAPI loopback works even when hardware has no dedicated “Stereo Mix” input. |
| [`whisper-rs`](https://docs.rs/whisper-rs/latest/whisper_rs/) / [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | `0.16.0` / pinned upstream revision | Offline Vietnamese STT | Rust binding to the actively maintained native Whisper runtime. Its CUDA and Vulkan features map to whisper.cpp backends, and it avoids a Python STT service on the hot audio path. Use a multilingual `large-v3-turbo` GGUF model as the *accuracy preset*; offer smaller models only as explicit performance presets. |
| [CTranslate2](https://opennmt.net/CTranslate2/) worker + [Helsinki `opus-mt-vi-en`](https://huggingface.co/Helsinki-NLP/opus-mt-vi-en) | `4.8.1` / pinned model revision | Offline Vietnamese → English subtitle translation | CTranslate2 is an efficient transformer runtime with CPU dispatch and Windows CUDA wheels; the recommended Marian Vietnamese-English model is Apache-2.0. Translate only finalized Vietnamese subtitle segments so translation does not compete with STT for every partial token. |
| [`axum`](https://docs.rs/axum/latest/axum/fn.serve.html) + [`tokio`](https://docs.rs/tokio/latest/tokio/) | `0.8.9` + `1.53.1` | Loopback-only overlay HTTP + WebSocket endpoint | The same host that owns subtitle state serves `/overlay` and broadcasts updates. This keeps the OBS-compatible overlay local, live, and independent of the desktop UI window. Bind only to `127.0.0.1` and use a random high port (or an authenticated fixed port). |

### Supporting Libraries and Assets

| Library / asset | Version | Purpose | When to use |
|---|---:|---|---|
| `serde`, `serde_json` | compatible current versions | Typed persisted settings and overlay messages | Store device IDs, language visibility, typography/layout, and selected model/backend. Version and migrate the settings schema. |
| `tracing`, `tracing-subscriber` | compatible current versions | Structured local diagnostics | Record backend selection, device failures, dropped audio, segment timing, and model load errors—never raw captions by default. |
| `ringbuf` (or bounded `tokio::sync::mpsc`) | compatible current version | Bounded PCM handoff | Capture must never block on inference. On overload, surface a health state and discard oldest/unusable audio under an explicit policy. |
| `rubato` | compatible current version | Resample endpoint PCM to 16 kHz mono float | WASAPI endpoint formats vary. Normalize once, before VAD/STT; test 44.1 kHz and 48 kHz sources. |
| WebSocket API in Axum | included | Push caption/settings changes into overlay | Use one immutable `SubtitleFrame` message with `revision`, Vietnamese text, English text, and visibility/style state. Do not poll. |
| Web Audio-free static HTML/CSS/TypeScript | bundled | Transparent `/overlay` page | The overlay only renders state; it must not capture audio or run model inference. OBS Browser Source accepts URLs and makes the page background transparent by default. |
| `webrtc-vad`-compatible local VAD, benchmark-selected | pin after Phase 2 | Speech/silence segmentation | Use only to segment and finalize Whisper windows. It is not a replacement for STT. Validate Vietnamese speech, music, and game-audio behavior before fixing the dependency. |

## Inference and Hardware Policy

### STT backend priority

1. **NVIDIA CUDA:** primary GPU target. Build/package a `whisper.cpp` CUDA backend for a detected supported NVIDIA driver; whisper.cpp documents CUDA via cuBLAS and custom kernels.
2. **CPU fallback:** always ship and test it. Use OpenBLAS-enabled whisper.cpp and a quantized multilingual model. It is the dependable universal path.
3. **Vulkan:** an experimental cross-vendor backend for Intel/AMD GPUs, gated behind a benchmark and diagnostics screen. whisper.cpp documents it as cross-vendor, but Windows multi-GPU/static-link issues are active upstream; it must not be v1's only path.

Do **not** claim that “GPU acceleration” works identically on all Windows GPUs. CUDA is a stable v1 acceleration path; Vulkan/ROCm capability belongs behind runtime probing and an explicit fallback. A CPU run that keeps up with the chosen model is preferable to an unstable GPU path.

### Translation execution

Bundle a locked Python `3.12` runtime and one small worker executable/environment containing CTranslate2, SentencePiece, and a pre-converted, revision-pinned `opus-mt-vi-en` model. Communicate over standard input/output using newline-delimited JSON; one request is one finalized Vietnamese segment. Run translation on CPU by default and permit CUDA only when enough VRAM remains after STT. CTranslate2's Windows wheel supports CPU and NVIDIA CUDA, and uses CPU dispatch (AVX/AVX2/AVX-512 as available); CUDA 12.x is the documented GPU requirement. cuDNN 8 is only relevant if that worker is later extended to run convolutional speech models.

This boundary lets v1 replace the worker with a cloud API adapter later without changing capture, subtitles, or overlay contracts.

### Model and licensing policy

- Pin every model by immutable revision and verify its SHA-256 before activation; models are large mutable artifacts, not ordinary source dependencies.
- Record and display each model's license in the app. `opus-mt-vi-en` is Apache-2.0; CTranslate2 is MIT; verify the exact Whisper model redistribution terms at the selected upstream revision before shipping an installer.
- Download model packs on first run (with disk-space display and resumable downloads) instead of silently embedding multi-GB weights in the base installer. Retain the fully offline path after that first download.
- Keep the model/backend choice in settings so users can select accuracy versus performance without altering caption or overlay behavior.

## Development Tools

| Tool | Purpose | Notes |
|---|---|---|
| Node.js LTS + npm | Tauri frontend build | Needed only for development/build; do not make the installed application depend on a system Node runtime. |
| Rustup stable MSVC + Visual Studio C++ Build Tools | Rust/Tauri/native backend build | Tauri documents `stable-msvc` and the Desktop development with C++ workload for Windows. |
| CMake + CUDA Toolkit (optional build flavor) | Build CUDA-enabled whisper.cpp | Keep CPU and CUDA builds reproducible in CI. Do not require CUDA to build/run the universal CPU installer. |
| `cargo fmt`, `clippy`, `cargo test`; Playwright or WebDriver smoke test | Code quality and overlay verification | Add a browser test that connects to `/overlay`, receives a WebSocket frame, and verifies transparent rendering plus bilingual toggles. |
| `whisper-bench` plus recorded Vietnamese fixtures | Hardware/backend admission | Capture real mic and loopback fixtures; measure real-time factor, finalization delay, dropped frames, and Vietnamese word error rate before declaring a default model. |

## Installation / Scaffold

Use the official scaffold rather than hand-assembling a desktop project:

```bash
npm create tauri-app@latest local-live-subtitle
cd local-live-subtitle
npm install

# Rust dependencies to pin in Cargo.toml during implementation
cargo add wasapi@0.24 whisper-rs@0.16 axum@0.8 tokio@1.53 \
  --features tokio/full
cargo add serde --features derive
cargo add serde_json tracing tracing-subscriber rubato ringbuf
```

The exact feature flags for `whisper-rs` (`cuda`, `vulkan`, `openblas`) must be selected per build flavor; do not enable mutually incompatible GPU assumptions in one universal package without a packaging spike.

## Alternatives Considered

| Recommended | Alternative | Use the alternative when |
|---|---|---|
| Tauri + Rust host | .NET/WPF or WinUI + NAudio | The project deliberately commits to a C#-only team and accepts a separate solution for model/native-inference bindings. It is a viable Windows-only choice, but does not simplify the local translation runtime enough to outweigh a second language here. |
| Direct `wasapi` crate | CPAL | CPAL is appropriate if cross-platform microphone capture becomes a goal. It uses WASAPI on Windows, but direct WASAPI is clearer for selected render-endpoint loopback and device-change behavior. |
| whisper.cpp via `whisper-rs` | `faster-whisper` only | The target PC is confirmed to have an NVIDIA CUDA setup and quickest implementation matters more than a non-NVIDIA GPU path. Faster-whisper/CTranslate2 is a strong CUDA/CPU option, but not the default cross-vendor story. |
| CTranslate2 worker + `opus-mt-vi-en` | NLLB/M2M-100 | Benchmark them later if translation quality proves inadequate and their model licenses, size, and hardware footprint fit. Do not add a larger multilingual model speculatively. |
| Local Axum URL + WebSocket | Direct OBS WebSocket integration | A later phase needs scene/source automation. For v1, Browser Source URL works in OBS and compatible software without granting control of the streaming app. |

## What Not To Use

| Avoid | Why | Use instead |
|---|---|---|
| Electron for v1 | Adds a Chromium runtime and another resource-heavy process alongside local AI, without solving WASAPI or inference. | Tauri/WebView2. |
| Browser `getUserMedia` for desktop/system audio | It cannot reliably enumerate/capture the selected Windows render endpoint as WASAPI loopback does. | Native WASAPI capture in the Rust host. |
| “Stereo Mix” as the desktop-audio implementation | It is a driver-dependent input and may not exist or be enabled. | WASAPI loopback on a selected render endpoint. |
| A virtual audio cable as a requirement | Adds a fragile external driver/configuration step and duplicates system loopback. | Native loopback; document virtual cables only as optional advanced routing. |
| Cloud STT/translation in v1 | Violates the offline/local-first scope and introduces API keys, cost, and network failure modes. | Local model workers behind an internal provider interface. |
| Overlay polling or writing subtitle text files | Creates stale frames/race conditions and limits configurable bilingual state. | A single loopback URL with WebSocket push and revisioned state. |
| Sending partial Whisper hypotheses to the translator | Causes flicker, wasted inference, and unstable English captions. | Translate finalized Vietnamese segments only. |

## Version Compatibility and Packaging Notes

| Component | Compatible with | Notes |
|---|---|---|
| Tauri 2.11 | Windows WebView2 + MSVC Rust toolchain | WebView2 is included on current Windows 10/11, but configure a Tauri offline WebView2 installer option only if offline *installation* is a requirement; it increases installer size. |
| `wasapi` 0.24 | Windows Core Audio / WASAPI | Supports microphone capture, loopback, and endpoint notifications. Start in shared, event-driven mode for live captions. |
| `whisper-rs` 0.16 | pinned whisper.cpp source + selected backend | Cargo features expose CUDA and Vulkan. Maintain backend-specific smoke tests and make a CPU executable mandatory. |
| CTranslate2 4.8.1 | Python >=3.9, Windows x86-64, optional NVIDIA CUDA 12.x | Python workers require the Visual C++ runtime. Translation should remain CPU-default unless the hardware probe reserves VRAM; cuDNN 8 only becomes a dependency if the worker is extended to run convolutional speech models. |
| OBS Browser Source | `http://127.0.0.1:<port>/overlay` | OBS supports URL-based Browser Source and transparency. The app need not bundle or control OBS. |

## Sources

- [Tauri Windows prerequisites](https://v2.tauri.app/start/prerequisites/) — MSVC and WebView2 requirements; checked 2026-08-19. **MEDIUM**
- [Tauri Windows installer options](https://v2.tauri.app/distribute/windows-installer/) — WebView2 packaging trade-offs. **MEDIUM**
- [Microsoft WASAPI loopback recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording) — selected-render-endpoint system-audio capture. **MEDIUM**
- [`wasapi` crate documentation](https://docs.rs/wasapi/latest/wasapi/) — current loopback/device-notification capability. **MEDIUM**
- [whisper.cpp README](https://github.com/ggml-org/whisper.cpp) and [`whisper-rs` features](https://docs.rs/crate/whisper-rs/latest/features) — CUDA, Vulkan, HIP, and CPU backends. **MEDIUM**
- [OpenAI Whisper model registry](https://github.com/openai/whisper/blob/main/whisper/__init__.py) — `large-v3-turbo` availability. **MEDIUM**
- [CTranslate2 install/hardware documentation](https://opennmt.net/CTranslate2/installation.html), [hardware support](https://opennmt.net/CTranslate2/hardware_support.html), and [repository](https://github.com/OpenNMT/CTranslate2) — Windows CPU/CUDA support and license. **MEDIUM**
- [Helsinki `opus-mt-vi-en` model card](https://huggingface.co/Helsinki-NLP/opus-mt-vi-en) — Vietnamese-English Marian architecture and Apache-2.0 license. **MEDIUM**
- [OBS Browser Source](https://obsproject.com/kb/browser-source) — URL source and transparent default CSS. **MEDIUM**

---
*Stack research for: Windows local-first livestream subtitles*  
*Researched: 2026-08-19*
