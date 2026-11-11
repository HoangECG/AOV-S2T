# Pitfalls Research

**Domain:** Local-first Windows real-time Vietnamese livestream captions and English translation
**Researched:** 2026-08-19
**Confidence:** MEDIUM — primary Windows/OBS/runtime documentation was cross-checked; exact caption quality and latency remain hardware-, model-, and stream-specific and must be measured locally.

## Critical Pitfalls

### Pitfall 1: Treating “desktop audio” as a single, permanent capture device

**What goes wrong:**
The app lists a vendor “Stereo Mix” device, or captures the default microphone, and calls it desktop audio. It then fails on systems without that device, captures the wrong speakers after a headset is connected, or silently stops when a USB/Bluetooth endpoint is unplugged.

**Why it happens:**
Windows endpoints are dynamic. Hardware loopback devices are optional and disabled on many systems. WASAPI loopback instead captures the mix from a *specific render endpoint*; it is not exclusive-mode capture. Default-device and device-state changes must be handled.

**How to avoid:**
- Enumerate input endpoints and active render endpoints separately. Offer an explicit “system audio (loopback of …)” source, persisted by endpoint ID, rather than relying on a named Stereo Mix device.
- Use WASAPI shared-mode loopback for the selected render endpoint; resample/channel-mix its native format to the ASR pipeline’s canonical mono 16 kHz PCM.
- Subscribe to endpoint notifications. On removal, format change, or selected-device loss, stop cleanly, show a visible recovery state, and require/select a fallback rather than silently switching sources.
- Make the UI clear that protected/DRM playback may not be capturable; never claim that every desktop sound is guaranteed to be transcribed.

**Warning signs:**
- “Desktop audio” is absent on a laptop without Stereo Mix.
- The selected device is stored by display name only.
- Headphone plug/unplug causes captions to freeze with no app status change.
- The captured signal is stereo/44.1 or 48 kHz but ASR receives raw bytes as 16 kHz mono.

**Phase to address:**
Phase 1 — Windows audio-source foundation and capture harness.

---

### Pitfall 2: Blocking the capture callback or allowing unbounded audio queues

**What goes wrong:**
Transcription/translation work runs on the capture thread, or audio chunks accumulate whenever inference is slower than real time. This produces dropouts, increasing “live” delay, memory growth, and subtitles that continue long after the speaker has stopped.

**Why it happens:**
Audio capture is treated like ordinary request/response input rather than a real-time producer. A large ASR model, GPU warm-up, translation, or UI update intermittently takes longer than a chunk interval.

**How to avoid:**
- Keep capture callbacks minimal: timestamp, copy/ring-buffer, and return. Run resampling, VAD, ASR, translation, and web delivery on separate bounded workers.
- Define a latency budget and queue policy before implementation. Measure capture-to-final-caption latency and queue depth continuously.
- On overload, prefer a visible “processing behind” indication and bounded degradation (larger decode interval, lower model preset, or deliberate audio drop policy) over pretending buffered captions are live.
- Warm the chosen models before Go Live and serialize access to model state unless the runtime explicitly supports safe concurrent inference.

**Warning signs:**
- Queue age/depth only rises during a long stream.
- GPU utilization is bursty while audio callback underruns/drops occur.
- A one-minute overload takes more than a minute to recover after speech ends.

**Phase to address:**
Phase 2 — streaming pipeline, back-pressure, and observability.

---

### Pitfall 3: Naive fixed-window chunking and unstable partial subtitles

**What goes wrong:**
Words are clipped at chunk edges, pauses split sentences in unnatural places, and the overlay rewrites the same line repeatedly. Viewers see flicker and mistrust captions; waiting for huge windows eliminates flicker but makes captions late.

**Why it happens:**
Speech is not aligned to fixed 1–5 second buffers, while ASR decoders revise their hypotheses as right context arrives. A simple “replace the overlay with every result” implementation makes the model’s internal uncertainty visible.

**How to avoid:**
- Separate audio framing, VAD segmentation, ASR decoding, and caption rendering. Keep a rolling context/overlap, but emit only a deduplicated, time-bounded delta.
- Model each token/segment as `provisional` or `final`. Render provisional text distinctly or suppress it by default; never revise finalized text except as an explicit recovery rule.
- Tune and expose conservative endpointing: speech-start threshold, minimum speech duration, trailing silence, maximum segment length, and overlap. Include a manual “flush/finalize” action for testing.
- Translate only finalized Vietnamese segments for the normal overlay, so English does not churn separately from Vietnamese. Use a generation ID so late worker results cannot overwrite a newer segment.

**Warning signs:**
- Identical words duplicate across adjacent captions.
- The last two words change multiple times per second.
- A short pause flushes incomplete Vietnamese phrases or waits 10+ seconds before finalizing.
- Translation updates arrive after a later Vietnamese caption and replace it.

**Phase to address:**
Phase 2 — VAD, segmentation, caption-state contract, and translation sequencing.

---

### Pitfall 4: Claiming Vietnamese accuracy from generic or clean-speech benchmarks

**What goes wrong:**
The selected model looks good on a demo but fails for the streamer’s regional accent, fast informal speech, names, gaming terms, mixed Vietnamese/English, music, or Discord/desktop audio. Missing diacritics and bad punctuation can materially change meaning and make English translation worse.

**Why it happens:**
Vietnamese performance varies materially by dataset/domain/dialect. Public benchmarks often normalize case, diacritics, and numerals, and do not represent a compressed livestream mix. A larger model is not automatically usable if it cannot sustain the chosen hardware’s real-time factor.

**How to avoid:**
- Choose ASR through a repeatable local benchmark, not model reputation. Build a consented evaluation set covering the owner’s microphone, desktop/voice-chat mix, Northern/Central/Southern speech where relevant, names/terms, pauses, and code-switching.
- Score both normalized word error rate and caption usefulness: diacritics, punctuation, named terms, segment timing, and finalization latency. Preserve raw model output plus normalized display text so evaluation is explainable.
- Make language/task explicit (Vietnamese transcription, not unintended translation); test the exact quantization/backend/model bundle distributed to users.
- Add a local phrase replacement/glossary only after baseline measurement; never use blind global text replacement that can corrupt ordinary words.

**Warning signs:**
- A model is selected from an English-only benchmark or a read-speech demo.
- Evaluation has no actual livestream/Discord/game-audio samples.
- Proper nouns and English loanwords regularly change between partial and final text.
- The product reports “accuracy” without a frozen test set and normalization rules.

**Phase to address:**
Phase 1 — model feasibility/benchmark gate; Phase 4 — quality regression suite.

---

### Pitfall 5: Shipping “GPU acceleration” as one universal setting

**What goes wrong:**
The installer assumes NVIDIA CUDA, crashes on missing/unsupported CUDA or cuDNN, gives poor CPU fallback, or silently runs on CPU while the UI says GPU. A quantized model fits but loses caption quality; a large model works initially but causes VRAM exhaustion when ASR and translation run together.

**Why it happens:**
Windows GPU support is runtime- and hardware-specific. For example, CTranslate2’s Windows GPU wheels require matching CUDA and, for convolutional speech models, cuDNN; cross-vendor paths such as Vulkan still need real hardware testing. Backends and model formats are not interchangeable.

**How to avoid:**
- Define supported configurations explicitly for v1: a validated CPU baseline and named GPU/backend combinations. Detect backend availability and model compatibility at startup, then show the active device, model, precision/quantization, VRAM/RAM estimate, and fallback reason.
- Bundle or document native dependencies deliberately; verify fresh Windows installation, offline model download/checksum, and no-network startup.
- Benchmark ASR and translation *together* after warm-up on each support tier. Require a real-time factor below 1 with headroom, not just a single-file throughput number.
- Treat model files as versioned artifacts with manifest, hash, source/license, disk-space check, atomic download, and rollback. Never auto-delete a known-good model on update failure.

**Warning signs:**
- “GPU” is inferred from a graphics card name instead of a successful backend self-test.
- First caption takes tens of seconds due to model load/compilation.
- GPU out-of-memory happens only when English translation is enabled.
- CPU fallback has no tested performance budget.

**Phase to address:**
Phase 1 — runtime/model distribution feasibility; Phase 4 — installer and compatibility hardening.

---

### Pitfall 6: Treating English translation as a lossless post-processing step

**What goes wrong:**
The English line invents context, mistranslates slang/names, lags Vietnamese indefinitely, or is translated from unstable ASR text. Because the English is audience-facing, a fluent but wrong line can be more harmful than an obvious ASR typo.

**Why it happens:**
Local machine translation has its own model/VRAM/CPU requirements and does not share the ASR model’s timing or domain knowledge. Segment boundaries that are reasonable for Vietnamese captions may lack enough syntactic context for English.

**How to avoid:**
- Use an offline Vietnamese-to-English model with a documented license and deterministic, versioned decoding settings. Benchmark it on the actual caption segment distribution.
- Translate only finalized ASR segments, retain a stable mapping from Vietnamese segment ID to English segment ID, and expire/cancel stale translations.
- Put translation behind a toggle and state “machine-translated” in documentation/settings. Preserve Vietnamese as the source of truth and allow a Vietnamese-only safe mode if translation is slow/unavailable.
- Test names, gaming vocabulary, numbers/currency, negation, slang, code-switching, and sentence fragments. Track translation latency separately from ASR latency.

**Warning signs:**
- English is updated before Vietnamese is final.
- The English subtitle includes terms absent from the final Vietnamese caption.
- Enabling English doubles queue age or causes OOM.
- No evaluation cases cover informal Vietnamese and incomplete sentence fragments.

**Phase to address:**
Phase 2 — translation worker and synchronization; Phase 4 — bilingual quality testing.

---

### Pitfall 7: Making the transparent overlay a fragile preview page

**What goes wrong:**
The overlay works in a normal browser but appears black, stale, wrong-sized, or disconnected in OBS. It stops updating after a scene switch because Browser Source can unload or refresh, or it burns CPU by rerendering the whole DOM on every partial token.

**Why it happens:**
OBS Browser Source is an embedded Chromium environment with its own lifecycle and fixed viewport. “Transparent” requires both suitable page CSS and source settings. A stream overlay needs a reconnectable display protocol, not a one-off GUI preview.

**How to avoid:**
- Serve a dedicated local overlay route/URL and a separate authenticated control UI. The overlay should establish a reconnecting read-only connection and receive a complete current state immediately after reload.
- Keep the overlay DOM small: one/few text nodes, CSS transforms/opacity for transitions, no polling, no external fonts/scripts, no unbounded caption history. Use one render per state update, not per audio frame.
- Make viewport dimensions, transparent background, safe margins, font fallback, line clamp, and language visibility configurable. Provide an in-app “Copy overlay URL” plus OBS setup checklist and a preview at the exact configured resolution.
- Test reload, visibility-off/on, scene switch, OBS restart, network port collision, and 1080p/1440p/4K DPI scaling. The overlay must reconnect without restarting capture.

**Warning signs:**
- Preview and OBS use different URLs or state channels.
- Updates use a high-frequency poll or rebuild the entire page.
- Browser Source settings are undocumented; transparency is assumed from an alpha canvas alone.
- A page reload shows blank captions until the next spoken sentence.

**Phase to address:**
Phase 3 — overlay protocol, rendering, and OBS lifecycle compatibility.

---

### Pitfall 8: Exposing local audio/transcript controls on the network

**What goes wrong:**
A local HTTP/WebSocket server binds to all interfaces, has predictable URLs, or accepts arbitrary overlay/control messages. Another process/device on the LAN can read private transcripts, change stream settings, or make the overlay show injected text.

**Why it happens:**
Developers equate “local” with “safe,” add remote control for convenience, or use one unauthenticated endpoint for both GUI and Browser Source. Audio/transcripts are sensitive even if the app never calls a cloud service.

**How to avoid:**
- Bind the server to loopback (`127.0.0.1`/`::1`) by default; do not expose a LAN mode in v1. Use a random per-install/per-session capability token in the overlay URL or an equivalent origin/session check.
- Separate read-only overlay state from privileged GUI settings/actions. Validate message schemas and size limits; never execute text or HTML received from transcripts/settings.
- Render captions as text nodes, not `innerHTML`; escape all dynamic content. Do not log raw audio or full transcripts by default. Make retention/export explicit and delete temporary files on clean shutdown.
- Document the privacy boundary: local inference does not mean other locally running software cannot read data if it is deliberately exposed.

**Warning signs:**
- Server listens on `0.0.0.0` by default.
- Opening the overlay URL from another device works without consent.
- Captions are interpolated into HTML/CSS/JavaScript.
- Debug logs contain complete spoken content or audio paths.

**Phase to address:**
Phase 3 — local server/overlay security design; Phase 4 — privacy and security review.

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Depend on Windows “Stereo Mix” | Simple device list | Fails on many drivers and hides which output is captured | Never for the desktop-audio requirement |
| Run capture, ASR, translation, and UI in one loop | Fast prototype | Dropouts, uncontrollable latency, no overload policy | Only a throwaway spike, not committed product code |
| Display every partial hypothesis | Earliest apparent text | Caption flicker and duplicate/retracted words | Only a debug mode |
| Hard-code one CUDA build/model | Quick NVIDIA demo | No CPU fallback, fragile installs, no AMD/Intel plan | Only if v1 support matrix explicitly says NVIDIA-only and CPU is still tested |
| Share one unauthenticated local URL for overlay and settings | Fewer routes | Transcript leakage and remote control surface | Never |
| Persist unlimited transcript/audio diagnostics | Easy debugging | Sensitive data, disk exhaustion, unclear privacy story | Only explicit opt-in, bounded troubleshooting bundles |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| WASAPI loopback | Look for/require a hardware loopback capture device | Initialize shared-mode loopback against the chosen active render endpoint; handle endpoint notification/recovery |
| Windows audio device selection | Persist friendly name and silently fall back after device loss | Persist endpoint ID, show state/device meter, and require an explicit recovery/fallback policy |
| ASR native runtime | Assume model format, GPU backend, and quantization work across all builds | Validate a signed/versioned model manifest against the selected runtime/backend at startup |
| Local translation runtime | Let it compete unboundedly with ASR on the same GPU | Schedule/queue it behind finalized captions and measure combined VRAM/throughput |
| OBS Browser Source | Assume browser preview lifecycle matches OBS | Reconnect from a full-state snapshot after reload/scene activation; test actual OBS source settings |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Backlog instead of back-pressure | Latency grows for the entire stream | Bounded queues, queue-age metric, overload policy | First sustained period where combined inference is slower than audio |
| Oversized model without headroom | GPU OOM, thermal throttling, subtitles late after a few minutes | Benchmark warmed ASR+translation at target model and keep headroom | Long streams, background GPU use, or English enabled |
| Full overlay rerender/animation per token | OBS CPU/GPU usage rises, stutter | State-delta updates, tiny DOM, rate-limit provisional rendering | Fast speech or 4K Browser Source |
| Repeated resampling/model reloads | Audio gaps and first-caption latency | One canonical PCM format; long-lived warmed workers | Each device switch/scene reload if resources are tied to UI |
| Unbounded caption/debug history | Memory/disk climb | Fixed retention and explicit export | Multi-hour streams |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Bind overlay server to every network interface | LAN users/processes can read captions or invoke endpoints | Loopback-only by default; no remote access in v1 |
| Put settings/actions on the overlay channel | Untrusted page/client can modify capture or display | Separate privileged GUI API from read-only overlay state and authenticate capabilities |
| Render transcript as HTML | Spoken/recognized text becomes script/markup injection in overlay | Use text-node APIs/escaped output; prohibit transcript-controlled CSS/JS |
| Log raw audio/transcripts by default | Private speech is retained/exposed in support logs | Opt-in bounded diagnostics, visible retention control, redacted operational logs |
| Unsigned/unverified model downloads | Model tampering or broken offline startup | HTTPS source provenance, checksum/manifest, atomic install and rollback |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| No live input meter/status | User discovers silence only after going live | Persistent selected-source label, level meter, VAD/speech status, and last-caption timestamp |
| Hide the accuracy/latency tradeoff | User cannot diagnose late or unstable captions | Offer named conservative presets and show measured pipeline latency/model/backend |
| Treat English as always reliable | Viewers receive confident but bad translations | Per-language toggle, Vietnamese source retained, machine-translation label in settings |
| Overlay options differ between preview and OBS | Layout breaks during stream | One shared state/renderer and exact-resolution preview |
| Device loss has no visible recovery | Captions quietly stop | Error banner, capture restart action, and explicit selected fallback |

## "Looks Done But Isn't" Checklist

- [ ] **Microphone capture:** Works after hot-plug, default-device change, sample-rate change, and long continuous use — verify meter, capture status, and subtitle continuity.
- [ ] **Desktop/system audio:** Uses WASAPI loopback of a user-selected render endpoint, not only Stereo Mix — verify on a machine where Stereo Mix is unavailable.
- [ ] **Real-time captions:** Have distinct provisional/final states, deduplication, bounded queue, and capture-to-final latency measurement — verify with fast speech and pauses.
- [ ] **Vietnamese accuracy:** Is measured on consented representative livestream recordings including accent, names, code-switching, and desktop audio — verify against a locked evaluation set.
- [ ] **English translation:** Is tied to final Vietnamese segment IDs and cannot overwrite a later caption — verify under delayed translation and toggling it mid-stream.
- [ ] **GPU option:** Shows the backend actually used and falls back safely — verify on no-GPU, supported-GPU, and incompatible-GPU environments.
- [ ] **OBS overlay:** Is transparent, correct at target resolution, and reconnects after Browser Source/OBS/scene reload — verify in OBS itself, not Chrome alone.
- [ ] **Privacy:** Server is loopback-only, URL capability is protected, transcript is text-escaped, and logs are bounded — verify from a second LAN device and inspect logs.

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Wrong/lost audio endpoint | LOW | Stop affected worker, refresh devices, prompt/select endpoint, recreate stream, reset VAD/segment state, show interruption rather than stale captions |
| Inference backlog | MEDIUM | Surface queue age, finalize/drop according to documented policy, restart workers if necessary, then tune model/preset from recorded metrics |
| Caption flicker/duplication | MEDIUM | Capture audio+state trace, reproduce with deterministic segment test, correct ID/finalization boundary logic, add regression fixture |
| GPU/runtime incompatibility | MEDIUM | Fall back to validated CPU preset, preserve model cache, collect non-content diagnostic details, update compatibility matrix or installer |
| Bad translation | MEDIUM | Disable English safely, retain Vietnamese source, correct segment synchronization/evaluation cases, then re-enable only after validation |
| Overlay does not update in OBS | LOW | Verify URL/token/port, force overlay full-state reconnect, test Browser Source refresh/reload, retain capture pipeline independently |
| Local endpoint exposure | HIGH | Stop listener, rotate capability token, bind loopback, inspect logs/retention, release patched build and document the incident |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Dynamic microphone/render endpoint and WASAPI loopback | Phase 1: Audio-source foundation | Device matrix with no Stereo Mix, endpoint hot-plug/default change, and resample/channel tests |
| Model/backend support and distribution | Phase 1: Local inference feasibility | Fresh-install CPU/GPU self-test, checksum model install, warmed combined benchmark against a latency budget |
| Back-pressure and worker isolation | Phase 2: Streaming caption pipeline | Long-run stress test proves bounded queue age, no capture dropouts, and defined overload behavior |
| VAD/chunking/caption stability | Phase 2: Streaming caption pipeline | Fixture tests prove no duplicate finalized text and ordered provisional/final updates through pauses and rapid speech |
| Vietnamese accuracy and bilingual quality | Phase 1 then Phase 4: Quality gate | Locked representative corpus reports ASR usefulness/WER and translation/latency regressions for every supported preset |
| OBS lifecycle/render performance | Phase 3: Transparent overlay | OBS Browser Source test covers transparency, reload/scene switch/restart, target resolution, and CPU budget |
| Local privacy and server security | Phase 3 then Phase 4: Secure overlay/hardening | Automated bind/origin/schema/XSS tests plus a manual LAN-access check and log-retention review |

## Sources

- [Microsoft: WASAPI loopback recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording) — shared-mode loopback and hardware/DRM constraints. MEDIUM confidence after cross-check.
- [Microsoft: audio endpoint notifications](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient) — device lifecycle and nonblocking callback guidance. MEDIUM confidence after cross-check.
- [OBS: Browser Source](https://obsproject.com/kb/browser-source) — transparent default CSS, URL/local-file source modes, lifecycle settings, and CEF context. MEDIUM confidence after cross-check.
- [whisper.cpp documentation](https://github.com/ggml-org/whisper.cpp) — CPU/CUDA/Vulkan/VAD capabilities; backend behaviour still requires Windows hardware testing. MEDIUM confidence after cross-check.
- [CTranslate2 installation](https://opennmt.net/CTranslate2/installation.html) and [hardware support](https://opennmt.net/CTranslate2/hardware_support.html) — Windows/CUDA/cuDNN and CPU/GPU support constraints. MEDIUM confidence after cross-check.
- [PhoWhisper](https://arxiv.org/abs/2406.02555) and [Gipformer benchmark table](https://github.com/ggroup-ai-lab/gipformer) — Vietnamese ASR requires representative domain/dialect evaluation rather than a single generic metric. MEDIUM confidence.

---
*Pitfalls research for: Local Live Subtitle Tool*
*Researched: 2026-08-19*
