# Audio pipeline

## Input sources

The package exposes two native sources:

- DefaultMicrophoneAudioSource uses Core Audio device discovery and an
  AVAudioEngine input node. It can request the default microphone or set a
  selected AudioDeviceID, which covers built-in inputs, USB microphones,
  soundcards, audio interfaces, and aggregate devices exposed by macOS.
- SystemAudioInputSource uses ScreenCaptureKit with capturesAudio enabled and
  no video output. It can enumerate displays and eligible applications; it
  excludes this process's audio when building a display filter.

Neither path sends samples to a network endpoint. A selected input may disappear
between enumeration and start; preparation/start returns an unavailable or
failed state instead of continuing against an accidental device.

## Device selection and AUHAL note

AudioDeviceManager enumerates Core Audio HAL input devices and exposes their
name, nominal sample rate, channel count, and default-device flag. The current
microphone source applies a selected AudioDeviceID to AVAudioEngine's input
audio unit. It is not a dedicated AUHAL capture implementation. This keeps the
MVP source small while retaining explicit device selection, but a future AUHAL
source is appropriate if AVAudioEngine cannot reliably retain a selected
interface across device changes or if lower-level stream control is required.
That replacement belongs behind AudioInputSource and must preserve the same
callback/ring-buffer rules.

## Format contract

Capture preserves the source's native Float32 format. The ASR-facing contract is
strict:

| Property | ASR internal value |
| --- | --- |
| Sample rate | 16,000 Hz |
| Channels | Mono |
| Sample type | Float32 |
| Processing frame | Default 20 ms; configurable through AudioInputConfiguration |
| Clock | Session-relative monotonic timestamps for transcript/export; capture-end uptime retained only for live latency metrics |

On the processing side, AudioProcessingPipeline applies channel selection or
downmix first, resamples next, and emits a mono AudioFrame. DSP belongs after
the ring buffer—not in the capture callback.

AudioProcessingPipeline prefers AVAudioConverterResampler, configured for the
short live-input frames used by the app. PreferredAudioResampler falls back to
the deterministic LinearAudioResampler if Core Audio rejects a malformed or
unexpected format. The fallback is not a substitute for a measured Core Audio
converter in difficult production audio; benchmark the selected path before
using it for long recordings or music-heavy sources.

## Capture and backpressure

~~~mermaid
sequenceDiagram
    participant C as Capture callback
    participant R as AudioRingBuffer
    participant D as Drain queue
    participant P as Processing task
    C->>R: Copy samples only
    D->>R: Read fixed-duration frame
    D->>P: Yield AudioFrame
    P->>P: Downmix, resample, meter, VAD
    P->>P: Queue/cancel ASR outside callback
~~~

Each source has approximately three seconds of native-audio ring capacity and
an eight-frame newest-only processing stream. On
overrun, the ring drops the oldest samples and increments its counter; this is a
deliberate live-latency choice. An empty read increments the underrun counter.
Diagnostics should display overrun/dropped-frame counts and should not conceal
repeated loss by claiming a transcript is continuous.

The callback copies data under a short lock and returns. It must not call
Whisper, translation, database code, file writers, or MainActor UI code. The
drain queue runs every configured frame interval (20 ms for ScreenCaptureKit;
the microphone source honors its configuration) and is the first place where an
AsyncStream of AudioFrame values is emitted.

The microphone tap copies directly into the ring. SystemAudioInputSource creates
its AudioBufferList scratch storage during preparation and reuses it in the
ScreenCaptureKit callback; it does not allocate an app-owned temporary list for
each sample. Core Media owns any retained block-buffer bookkeeping. Neither
callback runs inference, persistence, resampling, translation, or MainActor UI
updates.

## Channel handling

AudioChannelSelection.downmix averages all channels. A chosen channel is clamped
to the device's available range, preventing a stale selector from indexing
outside the buffer. The UI shows native sample rate/channel count and a channel
selector before recording starts.

## VAD, pre-roll, and endpointing

The processing path keeps a 250 ms PreRollAudioBuffer by default. The currently
functional VAD is EnergyVADFallback, which measures RMS, tracks an adaptive
noise floor, and uses separate enter/release thresholds to avoid rapid
switching. It exposes silence, possibleSpeech, speech, and ending states.

EndpointDetector does more than VAD: it considers minimum speech duration,
punctuation plus 300 ms silence, stable partial text plus 700 ms silence, and a
20-second maximum utterance. These values are defaults, not accuracy claims.
Settings exposes partial interval, rolling window, final silence, minimum
speech, maximum utterance, and Energy VAD enter/release thresholds; pre-roll
and the remaining VAD timing values retain safe defaults in this MVP.

SileroVADAdapter is an explicit placeholder that returns an unavailable error
until a separately distributed, real model integration is implemented. The UI
must label Energy VAD as a fallback because it is more vulnerable to music and
high background noise.

## ScreenCaptureKit details

System audio requires Screen Recording consent. The source calls
CGPreflightScreenCaptureAccess before it creates an SCStream; a denied state is
emitted instead of trying to prompt or capture silently. It requests an audio
output only and stops the stream cleanly. If a selected display or application no
longer appears in SCShareableContent, preparation fails with a clear unavailable
state.

Application capture has OS-level availability and privacy behavior that vary by
macOS release. Validate it on the target macOS version; a display source is the
fallback when an application source is absent. See [PERMISSIONS.md](PERMISSIONS.md).

## Device removal and recovery

Current behavior watches `kAudioDevicePropertyDeviceIsAlive` for the selected
microphone device, treats ScreenCaptureKit stream termination as a failure, and
has AppState stop the pipeline safely while preserving completed final
utterances. This needs real unplug/source-close validation on a target device;
the app never silently switches to another microphone.

## Manual audio checks

Before relying on a device/model combination, verify:

1. Built-in microphone, one USB microphone, and one multichannel interface.
2. Selected channel and downmix with a known left/right test signal.
3. 16 kHz mono frame output duration stays close to source duration.
4. Ring-overrun behavior under intentional processing pressure.
5. Device unplug during capture stops cleanly and reports the loss.
6. Display and application system-audio capture after Screen Recording consent.

The full matrix is in [TEST_PLAN.md](TEST_PLAN.md).
