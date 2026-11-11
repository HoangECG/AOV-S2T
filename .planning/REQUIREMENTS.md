# Requirements: Local Live Subtitle Tool

**Defined:** 2026-08-19
**Core Value:** Accurate Vietnamese live subtitles, with optional English translation, that can be reliably displayed in a livestream overlay.

## v1 Requirements

### Audio Capture

- [ ] **CAPT-01**: User can choose one active microphone or Windows input-audio device for a caption session.
- [ ] **CAPT-02**: User can choose one Windows render-audio device and capture its desktop/system audio through loopback.
- [ ] **CAPT-03**: User can see the selected source's live audio level and an actionable error when the source is unavailable or silent.

### Local AI Pipeline

- [ ] **AI-01**: User can start and stop a local Vietnamese speech-recognition session from the Windows GUI.
- [ ] **AI-02**: The app produces stable, finalized Vietnamese caption segments from the active live audio source without using a cloud API.
- [ ] **AI-03**: The app uses a tested local CPU baseline and reports the active CPU/GPU inference backend and model readiness.
- [ ] **AI-04**: User can enable local Vietnamese-to-English translation for finalized Vietnamese caption segments.
- [ ] **AI-05**: The app keeps Vietnamese captions available when translation is delayed or unavailable.

### Stream Overlay

- [ ] **OVLY-01**: User can copy a stable local URL for a transparent browser overlay that shows the current captions.
- [ ] **OVLY-02**: The overlay updates from finalized caption state and recovers the current state after a browser-source reconnect.
- [ ] **OVLY-03**: The overlay service accepts connections only from the local machine and never exposes settings controls in the public render page.

### Controls and Monitoring

- [ ] **CTRL-01**: User can select Vietnamese-only, English-only, or bilingual caption display and choose the bilingual display order.
- [ ] **CTRL-02**: User can configure overlay font, size, foreground treatment, position/alignment, safe padding, and visible line count from the Windows GUI.
- [ ] **CTRL-03**: User can see private session health for source activity, model/backend readiness, caption age, translation state, and overlay connectivity.

## v2 Requirements

### Cloud and Language Expansion

- **CLOUD-01**: User can configure a cloud speech-recognition or translation provider through an API.
- **LANG-01**: User can recognize non-Vietnamese spoken languages or select automatic language detection.

### Additional Workflows

- **MEDIA-01**: User can transcribe an imported audio file.
- **HIST-01**: User can store, search, or export a transcript archive.
- **MIX-01**: User can mix multiple audio sources or identify speakers.

## Out of Scope

| Feature | Reason |
|---------|--------|
| Audio-file transcription | v1 validates live captioning only. |
| Cloud AI/API configuration | v1 must establish reliable local CPU/GPU operation first. |
| Direct OBS or streaming-platform integration | A browser overlay remains compatible with streaming software without app-specific support. |
| Non-Vietnamese recognition | Vietnamese quality is the initial validation focus. |
| Multiple-source mixing and diarization | Routing and synchronization complexity is outside the single-source v1 workflow. |
| Transcript archive/export | Adds retention and privacy decisions unrelated to live overlay output. |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CAPT-01 | Phase 1 | Pending |
| CAPT-02 | Phase 1 | Pending |
| CAPT-03 | Phase 1 | Pending |
| AI-01 | Phase 2 | Pending |
| AI-02 | Phase 2 | Pending |
| AI-03 | Phase 1 | Pending |
| AI-04 | Phase 2 | Pending |
| AI-05 | Phase 2 | Pending |
| OVLY-01 | Phase 3 | Pending |
| OVLY-02 | Phase 3 | Pending |
| OVLY-03 | Phase 3 | Pending |
| CTRL-01 | Phase 4 | Pending |
| CTRL-02 | Phase 4 | Pending |
| CTRL-03 | Phase 4 | Pending |

**Coverage:**
- v1 requirements: 14 total
- Mapped to phases: 14
- Unmapped: 0 ✓

---
*Requirements defined: 2026-08-19*
*Last updated: 2026-08-19 after roadmap creation*
