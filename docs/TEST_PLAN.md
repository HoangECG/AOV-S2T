# Test plan

## Test philosophy

A buildable package is necessary but does not prove microphone hardware, Screen
Recording consent, model compatibility, or Vietnamese accuracy. Automated tests
should cover deterministic core logic. Manual tests should cover physical
devices, permissions, local model files, and long-running behavior. The release
report must list commands actually run and mark unavailable hardware/model cases
as not run rather than passing by assumption.

Run the repeatable checks with:

~~~sh
Scripts/run_tests.sh
~~~

This runs a dependency-free Swift core-check executable and Python syntax/CLI
checks. It requires no network, model weights, microphone, Screen Recording
permission, XCTest, or Testing. Use Scripts/run_tests.sh --swift-only or
--tools-only to isolate failures.

### Current host limitation

On the inspected arm64 macOS 26.6 host, Swift 6.3.3 can build the package and
run the core-check executable with Swift Package Manager, but the selected
Command Line Tools developer directory has no full Xcode app, so xcodebuild
cannot run. Select a compatible full Xcode developer directory for Xcode scheme,
signing, and hardware release validation. The release report must record actual
output from the machine that runs those checks.

## Unit tests

| Area | Cases to automate |
| --- | --- |
| Ring buffer | Write/read ordering, wraparound, capacity overrun, underrun counter, reset, no cross-channel corruption |
| Audio processing | Channel selection, downmix average, resampler output length tolerance, 16 kHz mono output, level meter clipping |
| WAV writer | RIFF/WAVE header fields, PCM length, sample-rate and channel metadata |
| VAD | Noise-floor adaptation, hysteresis, silence/possibleSpeech/speech/ending transitions, pre-roll, minimum speech, maximum utterance |
| Endpointing | Punctuation + silence, stable partial + silence, short empty discard, maximum wait |
| ASR model manager | Missing/unreadable model, accepted extension, copy/index/selection/delete behavior |
| ASR coordinator | One inference at a time, bounded newest-final queue/drop metric, cancellation, partial revision replacement, valid no-partial short utterance final pass |
| Transcript | Stable-prefix consensus, overlap de-duplication, Vietnamese whitespace/punctuation/Unicode normalization, sentence edge cases, glossary word boundaries |
| Translation | Final-only requests, ordering, cache key, cancellation, unsupported pair response |
| Local subtitle overlay | Delay planner (zero, positive, late, missing capture timestamp), loopback-only ready URL, latest-snapshot publish/clear, transparent page, no-store header, safe text rendering, and GET-only routes |
| Storage / export | Session CRUD, corrected text preservation, recording deletion with session deletion, TXT/JSON/SRT/VTT timestamps, one dataset row per approved recorded utterance |
| Training tools | Invalid JSONL, path traversal rejection, WAV header checks, duplicate paths/IDs, session split isolation, deterministic seed, metric fixtures |

Use synthetic PCM or tone/silence fixtures. Do not commit personal, meeting, or
copyrighted voice recordings. Unit tests must not launch a real microphone,
ScreenCaptureKit session, or model inference in CI.

## Integration tests

1. Feed synthetic native-rate multi-channel frames through ring buffer,
   processing, VAD, and endpointing; verify one final utterance boundary.
2. Use MockASREngine to prove partial text replaces a revision rather than
   appending duplicate lines and that only the final result reaches a mock
   translator.
3. Run WhisperCppEngine with a user-configured local CLI and a known
   non-sensitive WAV. Verify cancellation leaves no temporary directory or
   orphan process.
4. Import a local model, unload it, delete it, and reopen the manager.
5. Export one corrected bilingual session as TXT, JSON, SRT, and VTT; validate
   timestamps are non-negative, end is not before start, and cues do not overlap
   unexpectedly.
6. Run prepare, validate, split, train preflight, and held-out scoring on a
   synthetic dataset fixture. Confirm train/validation/test session sets are
   disjoint.
7. Start the local subtitle overlay, fetch `/overlay` and `/subtitle` through
   `127.0.0.1`, verify no-store/security headers, publish/clear a caption, and
   reject a non-GET request. Do not use a LAN address for this test.

## Manual hardware and permission matrix

| Scenario | Expected result |
| --- | --- |
| Built-in microphone | Device appears, permission flow is correct, level meter responds |
| USB microphone | Selectable by name/ID; capture stays on that device |
| USB soundcard / interface | Native sample rate/channel count shown; downmix and channel selection correct |
| Aggregate device | Enumerated only if macOS exposes a usable input stream |
| Device unplug during capture | Safe stop, visible unavailable state, no silent fallback |
| System display audio | Screen consent required; audio-only capture starts/stops cleanly |
| Per-application system audio | Only offered when ScreenCaptureKit lists it; source disappearance handled |
| Denied microphone/screen consent | Clear recovery guidance and no crash |
| Local GGUF/BIN model | Load/error state is truthful; no model means no mock transcript |
| Vietnamese accents | Correct Unicode preservation for common north/central/south vocabulary |
| Noisy room/music | Energy VAD fallback is labeled and endpoint behavior is observed |
| Long session | Stable memory, responsive UI, no growing task/inference queue |
| Translation unavailable | Transcript continues; final-only translation failure is visible |
| Local browser/OBS overlay | The exact `127.0.0.1` URL opens without starting capture; page is transparent in a browser source, final captions appear, and stop clears text |
| Overlay timing | Compare `0` and a positive display delay to a known video/audio source; verify delay starts from captured speech end and does not alter exported cues |
| Overlay network boundary | A second device on the same Wi-Fi and the Mac's LAN IP cannot reach the page; changing/restarting the app requires the newly displayed URL |

## Performance and benchmark protocol

Use a fixed non-sensitive held-out set and report, per run:

- chip, macOS version, RAM, CLI/model hash and quantization;
- audio duration, processing duration, realtime factor, model-load time;
- partial latency and final latency when the realtime coordinator exists;
- peak memory if a trustworthy measurement method is available;
- ring overruns, dropped frames, empty results, and VAD fallback/engine mode;
- WER/CER and entity/number/sentence-boundary metrics.

Do not make a test fail merely because a slower machine misses a latency target.
Compare repeatable benchmark reports by hardware/model instead. A claimed target
such as sub-1.5-second partial or sub-2.5-second final latency must be backed by
the specific hardware/model measurement.

## Release gates

Before calling an MVP build ready:

1. Swift package builds and automated tests pass on the target SDK.
2. At least one microphone and one USB/interface scenario pass manually.
3. System audio either passes or is documented with its exact permission/SDK
   blocker.
4. A real local model/CLI smoke test succeeds; no cloud fallback is observed.
5. Final transcript, edit, persistence, and all export formats are tested once
   they are integrated.
6. Dataset export contains only explicitly approved utterances by default.
7. Privacy, permission denial, device removal, and model-missing states are
   exercised.
8. The final report separates tested facts from planned or untested work.
