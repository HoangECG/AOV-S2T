# Roadmap: Local Live Subtitle Tool

## Overview

The project progresses through four technical layers: prove reliable Windows audio capture and a measured local-inference baseline; turn that source into stable Vietnamese captions with optional local English translation; deliver those captions to a loopback-only transparent browser overlay; then complete the desktop controls and private monitoring needed to operate the tool during a livestream. Local-only operation, Vietnamese recognition, and a single live audio source remain fixed for v1.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Windows Capture & Inference Feasibility** - Capture one selected Windows audio source and establish the measured local ASR baseline.
- [ ] **Phase 2: Caption & Translation Pipeline** - Produce stable local Vietnamese captions and non-blocking local English translations.
- [ ] **Phase 3: Local Stream Overlay** - Publish current captions to a transparent, reconnect-safe browser overlay on the local machine only.
- [ ] **Phase 4: Desktop Controls & Monitoring** - Finish the configurable subtitle experience and private live-session health view.

## Phase Details

### Phase 1: Windows Capture & Inference Feasibility

**Goal**: The user can select one live Windows audio source and confirm that a benchmarked local inference profile is ready on the target PC.
**Depends on**: Nothing (first phase)
**Requirements**: CAPT-01, CAPT-02, CAPT-03, AI-03
**Success Criteria** (what must be TRUE):

  1. User can select one active microphone or Windows input-audio device and see its live level during a test capture.
  2. User can select one Windows render-audio device and capture its desktop/system audio through loopback rather than relying on Stereo Mix.
  3. When a selected source is unavailable or silent, the user sees an actionable state instead of a misleading active capture indication.
  4. A representative Vietnamese benchmark on the target Windows PC establishes a tested local CPU baseline before an ASR backend is selected; the app reports model readiness and the active CPU/GPU backend, with GPU support shown only after a successful probe.

**Plans**: 13/14 plans executed

- [x] 01-01-PLAN.md
- [x] 01-02-PLAN.md
- [x] 01-03-PLAN.md
- [x] 01-04-PLAN.md
- [x] 01-05-PLAN.md
- [x] 01-06-PLAN.md
- [x] 01-07-PLAN.md
- [x] 01-08-PLAN.md — Route exact selected render endpoints through production WASAPI loopback and validate native endpoint identity.
- [x] 01-09-PLAN.md — Build protocol-compatible sealed CPU/CUDA/Vulkan workers and fail missing required candidates closed.
- [x] 01-10-PLAN.md — Run the real native benchmark/profile transaction and discard temporary PCM on every outcome.
- [x] 01-11-PLAN.md — Expose legal transactional setup commands, atomic commit, restart checks, and native Ready state.
- [x] 01-12-PLAN.md — Wire the four-step React wizard to measured benchmark, official-source, cleanup, and completion commands.
- [x] 01-13-PLAN.md — Harden the target-PC verifier and generate redacted, fail-closed Phase 1 evidence.
- [ ] 01-14-PLAN.md — Run and approve the complete target-PC evidence gate, then close proven Windows debt.

**UI hint**: yes

### Phase 2: Caption & Translation Pipeline

**Goal**: The user can run an accuracy-first, fully local Vietnamese caption session with optional English translation that never displaces Vietnamese captions.
**Depends on**: Phase 1
**Requirements**: AI-01, AI-02, AI-04, AI-05
**Success Criteria** (what must be TRUE):

  1. User can start and stop a local Vietnamese speech-recognition session from the Windows GUI.
  2. During a session, the active live source produces stable, finalized Vietnamese caption segments without sending speech to a cloud API.
  3. User can enable local Vietnamese-to-English translation, and English text is generated only from finalized Vietnamese segments.
  4. Vietnamese captions remain available and current when English translation is delayed or unavailable.

**Plans**: TBD
**UI hint**: yes

### Phase 3: Local Stream Overlay

**Goal**: The user can add a transparent, read-only local web overlay to streaming software and trust it to show the current finalized captions after reconnects.
**Depends on**: Phase 2
**Requirements**: OVLY-01, OVLY-02, OVLY-03
**Success Criteria** (what must be TRUE):

  1. User can copy a stable local URL for a transparent browser overlay that shows the current finalized captions.
  2. The overlay updates from the authoritative caption state and immediately recovers the current state after a browser-source reload or reconnect.
  3. The overlay service accepts connections only from the local machine, and its public render page offers no settings or session controls.

**Plans**: TBD
**UI hint**: yes

### Phase 4: Desktop Controls & Monitoring

**Goal**: The user can configure the rendered subtitle presentation and confidently monitor the private health of a live session from the desktop GUI.
**Depends on**: Phase 3
**Requirements**: CTRL-01, CTRL-02, CTRL-03
**Success Criteria** (what must be TRUE):

  1. User can choose Vietnamese-only, English-only, or bilingual captions and set the display order for bilingual captions.
  2. User can configure overlay font, size, foreground treatment, position/alignment, safe padding, and visible line count from the Windows GUI, with the overlay reflecting those choices.
  3. User can see private session health for source activity, model/backend readiness, caption age, translation state, and overlay connectivity.

**Plans**: TBD
**UI hint**: yes

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Windows Capture & Inference Feasibility | 13/14 | In Progress|  |
| 2. Caption & Translation Pipeline | 0/TBD | Not started | - |
| 3. Local Stream Overlay | 0/TBD | Not started | - |
| 4. Desktop Controls & Monitoring | 0/TBD | Not started | - |
