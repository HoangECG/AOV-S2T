# Local Live Subtitle Tool

## What This Is

A Windows desktop tool for producing real-time Vietnamese subtitles from a selected microphone, audio device, or desktop/system audio. It displays a configurable transparent web overlay that can be added to streaming software, and can translate each Vietnamese subtitle into English.

The initial release runs AI locally and uses available CPU/GPU hardware to prioritize transcription accuracy. Cloud AI integrations are a future upgrade path, not part of v1.

## Core Value

Accurate Vietnamese live subtitles, with optional English translation, that can be reliably displayed in a livestream overlay.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] User can select a microphone, Windows audio device, or desktop/system-audio source.
- [ ] Tool transcribes Vietnamese speech locally in near real time, prioritizing accuracy.
- [ ] Tool translates Vietnamese subtitles into English locally.
- [ ] User can configure a transparent web subtitle overlay for use in streaming software.
- [ ] User can control subtitle languages, layout, and appearance from the desktop GUI.

### Out of Scope

- Audio-file transcription — v1 is for live audio input only.
- Cloud AI/API transcription and translation — defer until local-first v1 is working.
- Direct integration with a particular streaming application — a browser/web overlay keeps v1 broadly compatible.
- Non-Vietnamese speech recognition — v1 is scoped to Vietnamese input.

## Context

- Primary user is the project owner, using the tool for livestream subtitles.
- The target environment is Windows.
- The tool needs a desktop GUI for audio-source selection and subtitle/overlay settings.
- Subtitle output is consumed through a transparent web page added to streaming software.
- Accuracy is more important than the lowest possible latency.

## Constraints

- **Platform**: Windows desktop — the tool will run locally on the user's PC.
- **AI execution**: Local CPU/GPU inference — avoids cloud dependence for v1 and uses available hardware.
- **Input**: Live microphone/device/desktop audio only — the intended use is livestream captioning.
- **Language**: Vietnamese speech recognition with English translation — the captioning workflow requires this pair.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Local-first AI inference | Enable offline operation and make use of the user's CPU/GPU | — Pending |
| Accuracy over minimum latency | More stable captions matter more for the livestream use case | — Pending |
| Transparent web overlay | Lets the user add captions to streaming software without app-specific integration | — Pending |
| Vietnamese input and optional English translation | Matches the primary live-captioning workflow | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `$gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `$gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-08-19 after initialization*
