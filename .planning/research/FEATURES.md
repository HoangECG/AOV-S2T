# Feature Research

**Domain:** Local-first Windows live captioning and livestream subtitle overlays
**Researched:** 2026-08-19
**Confidence:** MEDIUM

## Feature Landscape

### Table Stakes (Users Expect These)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Explicit audio-source picker | A livestream caption tool must make it unambiguous whether it hears a microphone, a chosen Windows input, or desktop/system audio. | HIGH | Show device name, source type, permission/error state, and a level meter. Do not silently fall back to a different device. Windows Live Captions distinguishes PC audio and optional microphone audio. |
| Start/stop and live health status | The streamer needs a clear indication that capture, transcription, and overlay delivery are actually running before going live. | MEDIUM | Include one start/stop control, current source, audio activity, model readiness, GPU/CPU backend, last-caption age, and overlay connection state. |
| Stable final Vietnamese captions | Captions are the product's core output; text must be readable, Vietnamese-only, and released in short line-broken segments rather than one unbounded transcript. | HIGH | Use a two-stage state: provisional text may be shown internally, but the overlay should show finalized segments by default because v1 favors accuracy over minimum latency. Keep a small recent-caption buffer and cap visible lines. |
| Spoken-language control | Correct language selection materially improves caption accuracy and should be visible rather than inferred silently. | LOW | Fix v1 input to Vietnamese, but label it in the GUI and retain the setting boundary for later languages. Teams explicitly asks users to set the spoken language for accurate captions. |
| Optional local Vietnamese-to-English translation | The user explicitly needs bilingual output, and viewers need a deliberate choice of original versus translated text. | HIGH | Translate finalized Vietnamese segments, not unstable partial hypotheses. Offer Vietnamese only, English only, or both; clearly mark unavailable/late translation rather than displaying stale English. |
| Transparent browser-overlay URL | Streaming software commonly embeds web pages as a browser source; the overlay must be usable without a plugin for any specific broadcaster. | MEDIUM | Provide a local `http://127.0.0.1:<port>/overlay` URL, transparent page background, no controls in the rendered overlay, and a copy button. OBS Browser Source accepts a URL and uses a transparent background by default. |
| Overlay appearance and language controls | Caption consumers expect readable typography and streamers need the text to fit a scene. | MEDIUM | Persist font family/size, foreground and background/outline, position/alignment, max lines, line spacing, Vietnamese/English visibility, bilingual order, and safe-area padding. Caption customisation is present in Windows, Teams, and YouTube. |
| Accessibility/readability defaults | Captions primarily serve viewers who may be deaf or hard of hearing, but they also need to remain readable at small stream resolutions. | LOW | Ship a high-contrast default, outline or opaque backing option, adequate text size, a screen-reader-labelled settings GUI, and keyboard-accessible start/stop/configuration. Do not rely on color alone. |
| Graceful audio/model failure feedback | Local inference can fail due to a missing device, permission, model, or overloaded hardware; a blank overlay is hard to diagnose mid-stream. | MEDIUM | Show actionable error in the GUI and keep the overlay alive with a neutral hidden/idle state; never insert exception text into the public overlay. |

### Differentiators (Competitive Advantage)

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Local-first, hardware-aware operation | Keeps voice audio and captions on the PC, works without an Internet dependency, and uses the best available CPU/GPU backend. | HIGH | The UI should report the selected/actual inference backend and model-ready state. Microsoft documents on-device captions as a privacy and offline benefit; this is especially compelling for livestreamers. |
| Accuracy-first finalization policy | Lets the streamer choose a modest caption delay for better sentence boundaries and fewer visible corrections. | HIGH | Expose a simple `Balanced accuracy` delay profile in v1; defer granular decoding knobs. Measure caption age so the chosen policy is observable. |
| Deliberate bilingual composition | A single transparent overlay can show Vietnamese, English, or both in a controlled order, serving mixed-language audiences without separate scenes. | MEDIUM | English must be derived from the final Vietnamese caption and update atomically with it; show a configurable short fallback only if translation arrives later. |
| Audio-routing preflight | A visible level meter plus a short “test caption” check catches wrong Windows routing before a stream starts. | MEDIUM | This is more useful than an elaborate mixer: verify selected source produces signal, detect silence, and expose reset/retry. |
| Stream-safe overlay resilience | The overlay reconnects after OBS reloads, scene changes, or the app restarts, without requiring a new URL. | MEDIUM | Keep a stable local URL and transmit a full current state on each new overlay connection. OBS notes browser sources can unload while hidden or refresh with scene activation. |
| Caption-quality monitoring | A compact private dashboard—audio level, queue/processing delay, final-caption age, translation state, and dropped-audio warning—gives the streamer confidence without exposing diagnostics to viewers. | MEDIUM | Use threshold states rather than pretend ASR confidence is equivalent to correctness. |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Audio-file transcription/import | It seems like an easy extension of speech-to-text. | It changes the live-only UX, needs queue/progress/output-file workflows, and does not validate the livestream value proposition. | Explicitly exclude files from v1; preserve reusable transcription boundaries for later. |
| Direct OBS or platform-specific integration | A button that manipulates a broadcaster can sound convenient. | It adds install/auth/version support burden and narrows compatibility. | Ship a browser-overlay URL; OBS Browser Source can load a web page and provides transparent rendering. |
| Cloud ASR/translation in v1 | Cloud may improve some models or language coverage. | It violates local-first privacy/offline goals, introduces credentials/cost/rate-limit failure modes, and distracts from hardware-backed Vietnamese quality. | Define a provider interface later; v1 contains no API-key UI or cloud fallback. |
| Continuous raw partial-text rewrites on the public overlay | It makes captions appear faster. | Frequent corrections are visually distracting and conflict with the stated accuracy priority, especially when translated text trails behind. | Final captions by default; keep provisional hypotheses private or make them a later advanced opt-in. |
| A full audio mixer, multi-track mixing, and per-speaker diarization | Streamers may want every routing/identity feature. | Device capture, mixing, synchronization, and diarization each add substantial correctness and UI complexity. | Select one active source in v1; add explicit mixed-source support only after real usage demonstrates need. |
| Automatic language detection and broad multilingual ASR | It appears more flexible. | It is out of scope, adds model/runtime ambiguity, and can lower accuracy for Vietnamese-only streams. | Make Vietnamese explicit in v1 and add languages only with per-language validation. |
| Captions as a permanent transcript/archive | Saving text seems useful. | It adds retention, privacy, export, search, and storage decisions unrelated to rendering live subtitles. | Keep a small in-memory recent buffer for display/recovery; introduce export only after consent and retention requirements are specified. |
| Automatic content moderation/rewording | A streamer may want captions sanitized. | Mutating speech harms caption fidelity and is culturally/language sensitive. | Allow only an optional, clearly labelled profanity mask later; do not silently rewrite translation or transcript. |

## Feature Dependencies

```
Windows source enumeration + permission + level meter
    └──requires──> audio capture session
                           └──requires──> Vietnamese local ASR pipeline
                                                    └──requires──> final-segment state
                                                                              ├──requires──> overlay realtime transport
                                                                              │                    └──requires──> transparent browser overlay
                                                                              └──requires──> local Vietnamese-to-English translation

Overlay language/layout/appearance settings ──require──> overlay state model
Quality monitoring ──observes──> capture, ASR, translation, and overlay transport
Provisional public captions ──conflicts──> accuracy-first finalization default
```

### Dependency Notes

- **Source selection requires capture validation:** a persisted device ID alone is insufficient; Windows devices may disconnect or permissions may be denied, so the GUI must show signal and failure state.
- **English translation requires final Vietnamese segments:** translating unstable hypotheses compounds errors and causes mismatched two-line captions.
- **Overlay configuration requires a shared state model:** the GUI and any browser page must render the same language, style, and caption snapshot after reconnect.
- **Monitoring spans the pipeline:** source level, inference backlog, and overlay connection are distinct failure modes and need independent status.
- **Accuracy-first finalization conflicts with raw partials:** make stable final captions the normal rendering policy; do not combine continuous visible rewriting with the v1 quality goal.

## MVP Definition

### Launch With (v1)

- [ ] Select one microphone, Windows audio-input device, or desktop/system-audio source; show input level and actionable errors.
- [ ] Run local Vietnamese ASR with an accuracy-first final-caption policy, start/stop controls, and an in-memory recent caption buffer.
- [ ] Optionally translate finalized Vietnamese captions to English locally and choose Vietnamese, English, or bilingual display.
- [ ] Serve a stable transparent local web overlay URL that updates live and recovers after the browser source reloads.
- [ ] Configure overlay language visibility, order, font/size, colours or outline/background, position/alignment, and visible line count from the Windows GUI.
- [ ] Provide private health indicators for model readiness, active source, audio activity, caption age, translation state, and overlay connectivity.

### Add After Validation (v1.x)

- [ ] Optional public provisional captions — only if tests show viewers prefer lower latency over the existing stable-final behavior.
- [ ] Caption themes/profiles and quick scene-oriented presets — add when the user repeatedly changes settings per stream.
- [ ] Optional profanity mask — add only as an explicit render-time choice, without altering stored/final transcript content.
- [ ] Per-source remembered settings — add when changing microphones or loopback devices is a frequent workflow.

### Future Consideration (v2+)

- [ ] Pluggable cloud ASR and translation providers — defer until v1 establishes a local quality baseline and API-key/cost/privacy UX is designed.
- [ ] Additional input and target languages — defer until Vietnamese quality has dedicated evaluation coverage.
- [ ] Direct platform integrations or embedded closed-caption delivery — defer because the browser overlay is platform-independent.
- [ ] File transcription, export, archives, speaker labels, and multi-source mixing — defer as separate products/workflows with their own privacy and synchronization requirements.

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Source selection with meter/error state | HIGH | HIGH | P1 |
| Local Vietnamese final-caption pipeline | HIGH | HIGH | P1 |
| Transparent overlay URL and realtime updates | HIGH | MEDIUM | P1 |
| Bilingual render control and local English translation | HIGH | HIGH | P1 |
| Overlay appearance/layout settings | HIGH | MEDIUM | P1 |
| Health/status monitoring | HIGH | MEDIUM | P1 |
| Reconnect-safe overlay | HIGH | MEDIUM | P1 |
| Caption style presets | MEDIUM | LOW | P2 |
| Public provisional captions | MEDIUM | HIGH | P2 |
| Profanity masking | LOW | LOW | P3 |
| Cloud providers | MEDIUM | HIGH | P3 |
| File transcription/export | LOW | MEDIUM | P3 |

## Competitor Feature Analysis

| Feature | Windows Live Captions | Microsoft Teams Live Captions | Our Approach |
|---------|-----------------------|-------------------------------|--------------|
| Local/system audio and microphone | Captions audio passing through the PC and can optionally include microphone audio; processing is on-device. | Captions meeting/call audio, not a general broadcast source selector. | Let the user explicitly choose a single microphone, device, or desktop/system source and verify it with a meter. |
| Translation | On Copilot+ PCs, translates supported languages into English or Simplified Chinese; capabilities depend on Windows hardware/version. | Supports translated captions with language selection, subject to product licensing. | Local Vietnamese-to-English translation of final caption segments, with render-time language choices. |
| Caption appearance | Offers position and custom caption styles. | Offers font/colour/line-count/position controls. | GUI-controlled stream-specific typography, backing/outline, language ordering, and line limits in a transparent page. |
| Stream embedding | Designed as a desktop accessibility window. | Designed within meeting UI. | A stable local browser-overlay URL, avoiding v1 dependence on a particular streaming application. |
| Operational resilience | User-facing OS accessibility behavior. | Managed meeting service behavior. | Health dashboard and reconnect-safe browser state for unattended livestream operation. |

## Sources

- [Microsoft: Windows Live Captions](https://support.microsoft.com/en-US/accessibility/windows/use-live-captions-to-better-understand-audio) — current official documentation for on-device processing, PC/microphone audio, display styles, performance guidance, and privacy. Confidence: MEDIUM (web source, official, cross-checked).
- [Microsoft: Teams live captions](https://support.microsoft.com/en-us/teams/meetings/use-live-captions-in-microsoft-teams-meetings) — current official documentation for real-time captions, spoken-language controls, translated captions, and caption appearance. Confidence: MEDIUM (web source, official, cross-checked).
- [OBS: Browser Source](https://obsproject.com/kb/browser-source) — official documentation for URL sources, transparent default CSS, dimensions, and refresh/unload behavior. Confidence: MEDIUM (web source, official, cross-checked).
- [YouTube: Live caption requirements](https://support.google.com/youtube/answer/3068031) and [caption settings](https://support.google.com/youtube/answer/100078) — official evidence that live captions and readable caption styling are standard expectations, while platform delivery is a separate integration concern. Confidence: MEDIUM (web source, official, cross-checked).

---
*Feature research for: Local Live Subtitle Tool*
*Researched: 2026-08-19*
