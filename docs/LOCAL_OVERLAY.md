# Local subtitle overlay

MacSpeechTranslator renders live subtitles in a browser page served by the app,
not in the SwiftUI window. The app starts a small native HTTP listener on an
ephemeral port bound only to `127.0.0.1`; it is never advertised on the LAN.
The exact URL is shown in the main window and in Settings, for example:

~~~text
http://127.0.0.1:53124/overlay
~~~

Use **Open overlay** to open that URL in the default browser or **Copy URL** to
paste it into an OBS/browser source. Opening the page does not start audio
capture and does not request microphone or Screen Recording permission.

## Transparency and subtitle behavior

The page has a transparent CSS background and renders the Vietnamese final
sentence plus its final translation when available. Browser-source software
must enable its own transparent-page setting. A normal browser window can still
have opaque window chrome; that is outside the page's control.

Only final sentences are sent to the overlay. Partial ASR remains internal so a
caption is not repeatedly rewritten while translation is final-only. If the
local translation engine is unavailable, the final Vietnamese sentence is still
shown. The server holds only the latest caption in memory; it does not expose
audio, session history, raw ASR text, storage, or export APIs.

Stopping capture clears the current caption and cancels any queued delayed
captions. The listener remains available while the app is open so OBS/browser
sources can reconnect without starting capture again.

## Display delay

In **Settings → Local subtitle overlay**, set **Display delay** from `0` to `60`
seconds in 0.5-second steps. `0` shows a final caption as soon as its local
translation result is ready. A positive value schedules presentation from the
end of the captured sentence:

~~~text
display time = captured sentence end + display delay
~~~

This is a presentation-only video-sync holdback. It does not delay audio
capture, VAD, ASR, persistence, translation, stored timestamps, or exports. If
translation finishes after the scheduled time, the caption appears immediately.
The selected delay is captured when each final utterance is finalized, so a
setting change affects later utterances rather than moving already queued
captions.

## Privacy and local-network boundary

- The listener binds explicitly to IPv4 loopback (`127.0.0.1`), not `0.0.0.0`,
  an IPv6 wildcard, Bonjour, or a LAN address. A second device cannot use it.
- The generated port changes when the app restarts, avoiding collisions with
  unrelated local software. Use the URL currently shown by the app rather than
  guessing a port or substituting `localhost`.
- The page has no external scripts, images, analytics, cookies, CORS policy,
  or subtitle text in URL/query parameters. HTTP responses use `no-store`, a
  restrictive Content Security Policy, and `nosniff` headers.
- Browser rendering uses `textContent`, never HTML insertion, so spoken text
  such as `<script>` is displayed as text.
- A same-user local process that knows the displayed URL can read the current
  subtitle. Do not expose the URL in screenshots, screen shares, browser
  extensions, or recording configurations that are not trusted.

The current development bundle is unsandboxed. A later sandboxed distribution
must enable and validate the macOS incoming-network/server entitlement before
shipping this listener.
