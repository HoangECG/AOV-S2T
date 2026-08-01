# Permissions and privacy

## Principle

The app requests only the permission needed for the source a person selected.
It never changes System Settings, begins capture, uploads audio, or uploads a
transcript without an explicit user action. A denied permission leaves the app
in a clear unavailable state; it must not silently switch to another input or a
cloud service.

## Microphone

The microphone/soundcard source checks AVFoundation audio authorization. If the
status is undetermined, its prepare step requests access; if denied or
restricted, it emits a permission-denied state and does not start capture.

App/Info.plist includes the current microphone usage description key,
NSMicrophoneUsageDescription, with text that describes local transcription.
Scripts/build_app.sh copies it into the generated development .app bundle. A
signed distribution must still verify it against its final Xcode SDK and signing
configuration.

To recover from a denial:

1. Quit the app if macOS indicates a restart is needed.
2. Open System Settings.
3. Go to Privacy & Security, then Microphone.
4. Enable MacSpeechTranslator, relaunch it, and select the intended device.

If the app is absent from the list, run the signed bundle once so macOS can
register the request. Do not instruct users to reset the entire privacy database
unless an administrator has a specific support procedure.

## Screen and system-audio capture

ScreenCaptureKit system-audio capture is controlled by Screen Recording TCC
consent. On an explicit Start action, the code preflights with
CGPreflightScreenCaptureAccess and asks with CGRequestScreenCaptureAccess when
consent is missing. It emits permissionDenied before creating a stream if access
remains unavailable.

In System Settings, open Privacy & Security and enable the app under Screen &
System Audio Recording. On older macOS releases the pane may be named Screen
Recording. macOS can require quitting and reopening the app after this change.
A person should then select a display or eligible application source in the app;
capture uses an audio stream only and excludes this app's audio for display
capture.

The default local build is ad-hoc signed. That identity applies only to the
exact build, so a code-changing rebuild can require Screen Recording consent
again. Set `CODE_SIGN_IDENTITY` to an installed Apple Development or Developer
ID Application identity when building a durable local app.

Availability of application-level audio selection varies by macOS release and
what ScreenCaptureKit reports. A missing source is a normal unavailable state,
not a reason to capture an arbitrary display.

## Sandbox, models, and exports

The current Swift Package has no entitlement file or signed sandbox profile.
That is appropriate for local development but is not release-ready entitlement
configuration.

If a later distributed build enables App Sandbox, verify the actual Xcode SDK
and signing settings and add only the required capabilities, including audio
input where applicable. User-selected external model/import/export locations
must use a platform-appropriate file-selection and security-scoped access flow.
Do not hard-code absolute paths or assume broad filesystem access. The current
model import flow uses a user file picker and stores an imported copy under
Application Support; release sandboxing and durable security-scoped bookmarks
still need verification.

## Local subtitle overlay

The transparent subtitle page is served only to `127.0.0.1` and needs no new
TCC prompt. It does not start capture, send audio, or request Screen Recording
permission. It holds only the latest subtitle in process memory; a local browser
or OBS source fetches it from the app's ephemeral loopback URL.

For a sandboxed, signed distribution, validate the appropriate incoming-network
server entitlement with the target Xcode/macOS SDK. Do not replace the explicit
loopback binding with a wildcard or LAN listener. Details are in
[LOCAL_OVERLAY.md](LOCAL_OVERLAY.md).

## Data handling

- Captured audio and transcript remain local by design.
- Do not enable utterance recording by default without a visible privacy notice.
- Explain retention, deletion, dataset export, and who can access recordings.
- Store only relative audio paths in session metadata; avoid logging transcript
  text and sensitive file paths by default.
- Do not commit recordings, datasets, model weights, model caches, or exported
  transcripts to Git.
- Ask for appropriate consent before recording other people, system audio, or
  meetings. Local processing does not remove legal or organizational obligations.

## Permission test checklist

| Scenario | Expected result |
| --- | --- |
| First microphone use | System prompt; capture starts only after approval |
| Microphone denied | Clear status and no audio callback work beyond shutdown |
| Screen consent missing | System source remains unavailable with Settings guidance |
| Permission granted after denial | Relaunch/retry succeeds without changing source implicitly |
| USB device selected then unplugged | Capture stops safely and reports device/source loss |
| App's own system audio | Excluded where ScreenCaptureKit filter supports it |
| External model selected | Read/import only after explicit file selection |

Manual permission and hardware tests are required; they cannot be faithfully
replaced by package unit tests. See [TEST_PLAN.md](TEST_PLAN.md).
