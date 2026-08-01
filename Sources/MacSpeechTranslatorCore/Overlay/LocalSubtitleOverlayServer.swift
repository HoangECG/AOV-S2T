import Dispatch
import Foundation
@preconcurrency import Network

/// The browser-facing state for the local subtitle overlay. The server keeps
/// only one latest caption in memory; it never exposes transcript history,
/// audio, persistence, or export data.
public struct SubtitleOverlayPayload: Codable, Sendable, Equatable {
    public let sequence: Int
    public let sourceText: String
    public let translatedText: String?
    public let isFinal: Bool

    public init(
        sequence: Int,
        sourceText: String,
        translatedText: String?,
        isFinal: Bool = true
    ) {
        self.sequence = sequence
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.isFinal = isFinal
    }
}

public struct SubtitleOverlaySnapshot: Codable, Sendable, Equatable {
    public let subtitle: SubtitleOverlayPayload?

    public init(subtitle: SubtitleOverlayPayload?) {
        self.subtitle = subtitle
    }
}

/// Computes the presentation-only holdback for a caption. The returned value
/// never changes capture, ASR, persistence, export, or translation timings.
public enum SubtitleDisplayDelay {
    public static func remainingDelay(
        captureEndUptime: TimeInterval?,
        displayDelay: TimeInterval,
        now: TimeInterval
    ) -> TimeInterval {
        guard let captureEndUptime else { return 0 }
        return max(0, captureEndUptime + max(0, displayDelay) - now)
    }
}

public enum LocalSubtitleOverlayServerError: LocalizedError, Sendable, Equatable {
    case alreadyStarting
    case stoppedBeforeReady
    case couldNotStart(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarting:
            "The local subtitle overlay is already starting."
        case .stoppedBeforeReady:
            "The local subtitle overlay stopped before it was ready."
        case .couldNotStart(let message):
            "Could not start the local subtitle overlay: \(message)"
        }
    }
}

/// A small native HTTP server for a browser/OBS subtitle source. It binds only
/// to IPv4 loopback and serves a transparent page plus the latest in-memory
/// subtitle snapshot. It deliberately has no LAN, CORS, history, or audio API.
public final class LocalSubtitleOverlayServer: @unchecked Sendable {
    private static let loopbackHost = "127.0.0.1"
    private static let maximumRequestBytes = 8_192
    private static let headerTerminator = Data([13, 10, 13, 10])

    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "MacSpeechTranslator.LocalSubtitleOverlay")
    private let lock = NSLock()
    private var listener: NWListener?
    private var overlayURL: URL?
    private var startupContinuation: CheckedContinuation<URL, Error>?
    private var latestSubtitle: SubtitleOverlayPayload?

    /// Port zero asks the system for a free loopback port and avoids collision
    /// with unrelated local software. The actual URL is available after start.
    public init(port: UInt16 = 0) {
        requestedPort = port
    }

    deinit {
        stop()
    }

    public var url: URL? {
        withLock { overlayURL }
    }

    public var isRunning: Bool {
        withLock { listener != nil && overlayURL != nil }
    }

    public func start() async throws -> URL {
        if let url { return url }

        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            let port: NWEndpoint.Port
            if requestedPort == 0 {
                port = .any
            } else if let requestedPort = NWEndpoint.Port(rawValue: requestedPort) {
                port = requestedPort
            } else {
                throw LocalSubtitleOverlayServerError.couldNotStart("Invalid loopback port.")
            }
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(Self.loopbackHost), port: port)
            parameters.acceptLocalOnly = true
            parameters.includePeerToPeer = false
            listener = try NWListener(using: parameters)
        } catch let error as LocalSubtitleOverlayServerError {
            throw error
        } catch {
            throw LocalSubtitleOverlayServerError.couldNotStart(error.localizedDescription)
        }

        let accepted = withLock {
            guard self.listener == nil, startupContinuation == nil else { return false }
            self.listener = listener
            return true
        }
        guard accepted else {
            if let url { return url }
            throw LocalSubtitleOverlayServerError.alreadyStarting
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.handle(listenerState: state, for: listener)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.serve(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let shouldStart = self.withLock {
                guard self.listener === listener else { return false }
                self.startupContinuation = continuation
                return true
            }
            guard shouldStart else {
                continuation.resume(throwing: LocalSubtitleOverlayServerError.stoppedBeforeReady)
                return
            }
            listener.start(queue: self.queue)
        }
    }

    public func stop() {
        let state = withLock { () -> (NWListener?, CheckedContinuation<URL, Error>?) in
            let state = (listener, startupContinuation)
            listener = nil
            overlayURL = nil
            startupContinuation = nil
            latestSubtitle = nil
            return state
        }
        state.0?.cancel()
        state.1?.resume(throwing: LocalSubtitleOverlayServerError.stoppedBeforeReady)
    }

    public func publish(_ subtitle: SubtitleOverlayPayload) {
        withLock {
            latestSubtitle = subtitle
        }
    }

    public func clear() {
        withLock {
            latestSubtitle = nil
        }
    }

    /// A delayed clear from an older caption must never erase a newer caption.
    public func clear(ifCurrentSequence sequence: Int) {
        withLock {
            guard latestSubtitle?.sequence == sequence else { return }
            latestSubtitle = nil
        }
    }

    private func handle(listenerState state: NWListener.State, for listener: NWListener) {
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue,
                  let url = URL(string: "http://\(Self.loopbackHost):\(port)/overlay") else {
                finishStarting(
                    .failure(LocalSubtitleOverlayServerError.couldNotStart("No loopback URL was assigned.")),
                    for: listener
                )
                listener.cancel()
                return
            }
            finishStarting(.success(url), for: listener)
        case .failed(let error):
            finishStarting(
                .failure(LocalSubtitleOverlayServerError.couldNotStart(error.localizedDescription)),
                for: listener
            )
        case .cancelled:
            finishStarting(.failure(LocalSubtitleOverlayServerError.stoppedBeforeReady), for: listener)
        default:
            break
        }
    }

    private func finishStarting(_ result: Result<URL, Error>, for listener: NWListener) {
        let continuation = withLock { () -> CheckedContinuation<URL, Error>? in
            guard self.listener === listener else { return nil }
            switch result {
            case .success(let url):
                overlayURL = url
            case .failure:
                self.listener = nil
                overlayURL = nil
                latestSubtitle = nil
            }
            defer { startupContinuation = nil }
            return startupContinuation
        }
        continuation?.resume(with: result)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumRequestBytes) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = accumulated
            if let content { request.append(content) }

            if request.range(of: Self.headerTerminator) != nil {
                self.respond(to: request, on: connection)
            } else if request.count >= Self.maximumRequestBytes {
                self.send(status: "431 Request Header Fields Too Large", body: "Request header is too large.", on: connection)
            } else if error == nil, !isComplete {
                self.receiveRequest(on: connection, accumulated: request)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let requestText = String(decoding: request, as: UTF8.self)
        guard let requestLine = requestText.components(separatedBy: "\r\n").first else {
            send(status: "400 Bad Request", body: "Malformed request.", on: connection)
            return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            send(status: "400 Bad Request", body: "Malformed request.", on: connection)
            return
        }
        guard parts[0] == "GET" else {
            send(status: "405 Method Not Allowed", body: "Only GET is supported.", on: connection, extraHeaders: ["Allow": "GET"])
            return
        }
        let path = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        switch path {
        case "/", "/overlay":
            send(status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.overlayPage, on: connection)
        case "/subtitle":
            do {
                let snapshot = withLock { SubtitleOverlaySnapshot(subtitle: latestSubtitle) }
                let body = try JSONEncoder().encode(snapshot)
                send(status: "200 OK", contentType: "application/json; charset=utf-8", body: body, on: connection)
            } catch {
                send(status: "500 Internal Server Error", body: "Could not encode subtitle state.", on: connection)
            }
        case "/health":
            send(status: "200 OK", contentType: "application/json; charset=utf-8", body: Data("{\"status\":\"ok\"}".utf8), on: connection)
        default:
            send(status: "404 Not Found", body: "Not found.", on: connection)
        }
    }

    private func send(
        status: String,
        contentType: String = "text/plain; charset=utf-8",
        body: String,
        on connection: NWConnection,
        extraHeaders: [String: String] = [:]
    ) {
        send(status: status, contentType: contentType, body: Data(body.utf8), on: connection, extraHeaders: extraHeaders)
    }

    private func send(
        status: String,
        contentType: String,
        body: Data,
        on connection: NWConnection,
        extraHeaders: [String: String] = [:]
    ) {
        var headerLines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'",
            "X-Content-Type-Options: nosniff",
            "Connection: close"
        ]
        headerLines.append(contentsOf: extraHeaders.map { "\($0.key): \($0.value)" })
        var response = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static let overlayPage = """
    <!doctype html>
    <html lang="vi">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>MacSpeechTranslator Overlay</title>
      <style>
        html, body { width: 100%; height: 100%; margin: 0; background: transparent !important; overflow: hidden; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        #caption { position: fixed; left: 6%; right: 6%; bottom: 8%; text-align: center; color: white; font-size: clamp(28px, 4vw, 64px); font-weight: 700; line-height: 1.22; text-shadow: 0 2px 5px #000, 0 0 12px #000; }
        #translation { margin-top: 0.35em; color: #d7f0ff; font-size: 0.78em; font-weight: 600; }
      </style>
    </head>
    <body>
      <main id="caption" hidden aria-live="polite">
        <div id="source"></div>
        <div id="translation"></div>
      </main>
      <script>
        const caption = document.getElementById('caption');
        const source = document.getElementById('source');
        const translation = document.getElementById('translation');

        function render(subtitle) {
          const sourceText = subtitle && subtitle.sourceText ? subtitle.sourceText : '';
          const translatedText = subtitle && subtitle.translatedText ? subtitle.translatedText : '';
          source.textContent = sourceText;
          translation.textContent = translatedText;
          caption.hidden = sourceText.length === 0 && translatedText.length === 0;
        }

        async function poll() {
          try {
            const response = await fetch('/subtitle', { cache: 'no-store', credentials: 'omit' });
            if (response.ok) {
              const snapshot = await response.json();
              render(snapshot.subtitle);
            }
          } catch (_) {
            // A restart is normal; the next poll reconnects without retaining text.
            render(null);
          } finally {
            window.setTimeout(poll, 150);
          }
        }

        poll();
      </script>
    </body>
    </html>
    """
}
