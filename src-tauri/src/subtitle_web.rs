//! A tiny localhost-only web overlay for the current subtitle text.
//!
//! The server intentionally uses only the standard library so it can be started alongside the
//! desktop application without adding another runtime dependency.  It is not a public network
//! service: it binds to `127.0.0.1` only.

use std::{
    io::{self, Read, Write},
    net::{TcpListener, TcpStream},
    sync::{Arc, RwLock},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde::Serialize;

pub const DEFAULT_HOST: &str = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 8765;
pub const DEFAULT_URL: &str = "http://127.0.0.1:8765/";

const MAX_REQUEST_BYTES: usize = 8 * 1024;
const READ_TIMEOUT: Duration = Duration::from_secs(2);

/// A stable view of the latest caption for native callers and `/caption.json` clients.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionSnapshot {
    pub text: String,
    pub status: String,
    pub updated_at: u64,
}

/// The latest caption shared by capture/inference threads and the web overlay.
#[derive(Clone, Debug)]
pub struct CaptionStore {
    snapshot: Arc<RwLock<CaptionSnapshot>>,
}

impl CaptionStore {
    pub fn new() -> Self {
        Self {
            snapshot: Arc::new(RwLock::new(CaptionSnapshot {
                text: String::new(),
                status: "Đang chờ phụ đề…".to_owned(),
                updated_at: now_millis(),
            })),
        }
    }

    pub fn set_text(&self, text: String) {
        let mut snapshot = self
            .snapshot
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        snapshot.text = text;
        snapshot.updated_at = now_millis();
    }

    pub fn set_status(&self, status: String) {
        let mut snapshot = self
            .snapshot
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        snapshot.status = status;
        snapshot.updated_at = now_millis();
    }

    pub fn snapshot(&self) -> CaptionSnapshot {
        self.snapshot
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }
}

impl Default for CaptionStore {
    fn default() -> Self {
        Self::new()
    }
}

/// Starts the localhost overlay at [`DEFAULT_URL`].
///
/// Dropping the returned handle detaches the serving thread. The caller should retain it only if
/// it wants to join it during a controlled application shutdown.
pub fn start(store: CaptionStore) -> io::Result<thread::JoinHandle<()>> {
    start_on(DEFAULT_PORT, store)
}

/// Starts the localhost overlay on a caller-selected port.
pub fn start_on(port: u16, store: CaptionStore) -> io::Result<thread::JoinHandle<()>> {
    let listener = TcpListener::bind((DEFAULT_HOST, port))?;

    thread::Builder::new()
        .name("subtitle-web".to_owned())
        .spawn(move || {
            for incoming in listener.incoming() {
                match incoming {
                    Ok(stream) => {
                        let store = store.clone();
                        let _ = thread::Builder::new()
                            .name("subtitle-web-client".to_owned())
                            .spawn(move || handle_connection(stream, &store));
                    }
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
        })
}

fn handle_connection(mut stream: TcpStream, store: &CaptionStore) {
    let _ = stream.set_read_timeout(Some(READ_TIMEOUT));
    let response = match read_request(&mut stream) {
        Ok(request) => match request_target(&request) {
            Some("/") => html_response(),
            Some("/caption.json") => json_response(&store.snapshot()),
            Some(_) => text_response("404 Not Found", "Not found\n"),
            None => text_response("400 Bad Request", "Bad request\n"),
        },
        Err(_) => text_response("400 Bad Request", "Bad request\n"),
    };

    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn read_request(stream: &mut TcpStream) -> io::Result<String> {
    let mut bytes = Vec::with_capacity(1024);
    let mut chunk = [0_u8; 1024];
    let mut complete = false;

    while bytes.len() < MAX_REQUEST_BYTES {
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..read]);
        if bytes.windows(4).any(|window| window == b"\r\n\r\n") {
            complete = true;
            break;
        }
    }

    if !complete {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "request headers are incomplete",
        ));
    }

    String::from_utf8(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "request is not UTF-8"))
}

fn request_target(request: &str) -> Option<&str> {
    let request_line = request.lines().next()?;
    let mut fields = request_line.split_whitespace();
    if fields.next()? != "GET" {
        return None;
    }
    let target = fields.next()?;
    if fields.next().is_none() {
        return None;
    }
    Some(target.split('?').next().unwrap_or(target))
}

fn html_response() -> String {
    response(
        "200 OK",
        "text/html; charset=utf-8",
        r#"<!doctype html>
<html lang="vi">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Live Subtitle Overlay</title>
  <style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #111827; color: #fff; font-family: system-ui, sans-serif; }
    #overlay { display: grid; justify-items: center; gap: .6rem; }
    #caption { max-width: min(92vw, 1100px); padding: .5em .8em; border-radius: .25em; background: rgb(0 0 0 / 72%); font-size: clamp(28px, 5vw, 72px); font-weight: 700; line-height: 1.25; text-align: center; text-shadow: 0 2px 4px #000; }
    #caption.empty { visibility: hidden; }
    #status { max-width: min(88vw, 800px); padding: .3em .6em; border-radius: .25em; background: rgb(15 23 42 / 82%); color: #cbd5e1; font-size: clamp(13px, 1.5vw, 18px); line-height: 1.3; text-align: center; }
    #status.empty { visibility: hidden; }
  </style>
</head>
<body>
  <div id="overlay">
    <main id="caption" class="empty" aria-live="polite"></main>
    <aside id="status" class="empty" aria-live="polite"></aside>
  </div>
  <script>
    const caption = document.getElementById('caption');
    const status = document.getElementById('status');
    const REVEAL_INTERVAL_MS = 55;
    let previousText = null;
    let previousStatus = null;
    let revealVersion = 0;

    function clearCaption() {
      revealVersion += 1;
      caption.textContent = '';
      caption.classList.add('empty');
    }

    function revealCaption(text) {
      const version = ++revealVersion;
      const displayed = caption.textContent;
      const appendsToDisplayed = displayed && text.startsWith(displayed);
      const nextText = appendsToDisplayed ? text.slice(displayed.length) : text;
      const words = nextText.match(/\s*\S+\s*/g) || [];
      let index = 0;

      if (!appendsToDisplayed) caption.textContent = '';
      caption.classList.remove('empty');

      if (!words.length) {
        caption.textContent += nextText;
        return;
      }

      function appendWord() {
        if (version !== revealVersion) return;
        caption.textContent += words[index++];
        if (index < words.length) window.setTimeout(appendWord, REVEAL_INTERVAL_MS);
      }

      appendWord();
    }

    function updateStatus(text) {
      status.textContent = text;
      status.classList.toggle('empty', !text);
    }

    function statusClearsCaption(statusText) {
      const normalized = statusText.trim().toLocaleLowerCase();
      return [
        'đã dừng phụ đề',
        'nguồn audio đã dừng',
        'nguồn đã chọn không còn khả dụng',
        'đã bỏ kết quả không phải lời nói',
        'đang chờ tín hiệu audio',
      ].some((prefix) => normalized.startsWith(prefix));
    }

    function updateOverlay(text, statusText) {
      const textChanged = text !== previousText;
      const statusChanged = statusText !== previousStatus;

      if (statusChanged) updateStatus(statusText);
      if (textChanged && text) {
        revealCaption(text);
      } else if (statusChanged && statusClearsCaption(statusText)) {
        clearCaption();
      }

      previousText = text;
      previousStatus = statusText;
    }

    async function refresh() {
      try {
        const response = await fetch('/caption.json', { cache: 'no-store' });
        if (!response.ok) throw new Error('caption unavailable');
        const { text = '', status = '' } = await response.json();
        updateOverlay(
          typeof text === 'string' ? text : '',
          typeof status === 'string' ? status : ''
        );
      } catch (_) {
        updateOverlay('', '');
      }
    }
    refresh();
    setInterval(refresh, 250);
  </script>
</body>
</html>"#,
    )
}

fn json_response(snapshot: &CaptionSnapshot) -> String {
    response(
        "200 OK",
        "application/json; charset=utf-8",
        &format!(
            r#"{{"text":"{}","status":"{}","updatedAt":{}}}"#,
            escape_json(&snapshot.text),
            escape_json(&snapshot.status),
            snapshot.updated_at,
        ),
    )
}

fn text_response(status: &str, body: &str) -> String {
    response(status, "text/plain; charset=utf-8", body)
}

fn response(status: &str, content_type: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n{body}",
        body.len()
    )
}

fn escape_json(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            character if character <= '\u{1f}' => {
                use std::fmt::Write as _;
                let _ = write!(escaped, "\\u{:04x}", character as u32);
            }
            character => escaped.push(character),
        }
    }
    escaped
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caption_store_is_shared_across_clones() {
        let store = CaptionStore::new();
        store.set_text("xin chào".to_owned());
        store.set_status("Đang nhận dạng".to_owned());

        let snapshot = store.clone().snapshot();
        assert_eq!(snapshot.text, "xin chào");
        assert_eq!(snapshot.status, "Đang nhận dạng");
        assert!(snapshot.updated_at > 0);
    }

    #[test]
    fn snapshot_serializes_with_camel_case_fields() {
        let snapshot = CaptionSnapshot {
            text: "xin chào".to_owned(),
            status: "Đang nhận dạng".to_owned(),
            updated_at: 1,
        };

        assert_eq!(
            serde_json::to_string(&snapshot).unwrap(),
            r#"{"text":"xin chào","status":"Đang nhận dạng","updatedAt":1}"#
        );
    }

    #[test]
    fn json_escapes_control_characters() {
        let response = json_response(&CaptionSnapshot {
            text: "say \"hi\"\\now\n".to_owned(),
            status: "ok".to_owned(),
            updated_at: 1,
        });

        assert!(response.ends_with(
            "{\"text\":\"say \\\"hi\\\"\\\\now\\n\",\"status\":\"ok\",\"updatedAt\":1}"
        ));
    }

    #[test]
    fn overlay_retains_caption_until_a_reset_status() {
        let html = html_response();

        assert!(html.contains(r#"<main id="caption" class="empty" aria-live="polite"></main>"#));
        assert!(html.contains(r#"<aside id="status" class="empty" aria-live="polite"></aside>"#));
        assert!(html.contains("function revealCaption"));
        assert!(html.contains("const { text = '', status = '' } = await response.json();"));
        assert!(html.contains("const displayed = caption.textContent;"));
        assert!(html.contains("text.startsWith(displayed)"));
        assert!(html.contains("function statusClearsCaption(statusText)"));
        assert!(html.contains("if (textChanged && text) {\n        revealCaption(text);"));
        assert!(html.contains("statusChanged && statusClearsCaption(statusText)"));
        assert!(html.contains(
            "else if (statusChanged && statusClearsCaption(statusText)) {\n        clearCaption();"
        ));
        assert!(html.contains("'đã dừng phụ đề'"));
        assert!(html.contains("'nguồn audio đã dừng'"));
        assert!(html.contains("'nguồn đã chọn không còn khả dụng'"));
        assert!(html.contains("'đã bỏ kết quả không phải lời nói'"));
        assert!(html.contains("'đang chờ tín hiệu audio'"));
        assert!(!html.contains("'đang nghe'"));
        assert!(!html.contains("'đang nhận dạng'"));
        assert!(!html.contains("'đang ổn định'"));
        assert!(!html.contains("'đang chờ'"));
        assert!(!html.contains("MIN_CAPTION_DISPLAY_MS"));
        assert!(!html.contains("requestCaptionClear"));
        assert!(!html.contains("text || status"));
        assert!(!html.contains("caption.textContent = status"));
        assert!(!html.contains("Đang chờ phụ đề"));
        assert!(!html.contains("Đang kết nối"));
    }

    #[test]
    fn only_get_requests_are_accepted() {
        assert_eq!(
            request_target("GET /caption.json HTTP/1.1\r\n\r\n"),
            Some("/caption.json")
        );
        assert_eq!(request_target("POST /caption.json HTTP/1.1\r\n\r\n"), None);
    }
}
