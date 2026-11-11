# Phase 1: Windows Capture & Inference Feasibility - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-08-19
**Phase:** 1-Windows Capture & Inference Feasibility
**Areas discussed:** Audio-source behavior, hardware target, benchmark policy, model onboarding, first-run setup, reconfiguration

---

## Audio-source behavior

| Decision | Selected |
|---|---|
| Persist selected source | Exact device; never auto-switch | 
| Source unavailable | Stop capture and request a new selection | 
| Change source during session | Stop session first | 
| Source picker | Separate input and desktop/system groups | 

## Hardware target

| Decision | Selected |
|---|---|
| Initial acceleration support | CPU, NVIDIA, AMD, and Intel GPUs | 
| Backend selection | Self-test accelerated backend, CPU fallback with explanation | 
| Readiness display | Full technical details in GUI | 
| Benchmark timing | Full automatic first-run benchmark | 

## Benchmark policy

| Decision | Selected |
|---|---|
| Benchmark audio | User-recorded real sources | 
| Latency target | Balanced; normally about three seconds for final captions | 
| Audio conditions | Normal clean-stream condition only | 
| Saved result | One app-wide best profile | 

## Model onboarding

| Decision | Selected |
|---|---|
| Acquisition | Automatic first-run download | 
| Model size | Largest model for accuracy | 
| Update policy | Pinned version; user-confirmed update and benchmark | 
| Failure policy | Block session with clear retry; do not downgrade silently | 

## First-run setup and reconfiguration

| Decision | Selected |
|---|---|
| First-run order | Download model, temporarily select a source and record a local benchmark sample, benchmark, then select the official source | 
| Ready gate | Signal plus successful Vietnamese test caption | 
| Failed setup | Stay in wizard with checklist and retry | 
| Later launches | Open main Ready screen | 
| Re-benchmark trigger | Prompt after model/driver/backend/hardware changes | 
| Reconfiguration | Wizard only; resume at affected step | 
| Wizard cancellation | Preserve last known-good configuration | 

## the agent's Discretion

- Final ASR runtime/library and concrete benchmark implementation remain evidence-driven Phase 1 planning decisions.

## Deferred Ideas

None.
