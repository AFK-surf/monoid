//! HTTP/TLS/EntryResolver, WebSocket, local TCP/Unix/named-pipe sockets, listeners, and ADB socket operations.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};
use tokio_tungstenite::{Connector, MaybeTlsStream};

use crate::tls;
use crate::{Answer, Done, Handle, Inner, err, id_of, str_of};

/// A socket's halves as the shell keeps them (`Handle::Tcp`).
pub(crate) type SocketRead = Arc<tokio::sync::Mutex<Box<dyn tokio::io::AsyncRead + Send + Unpin>>>;
pub(crate) type SocketWrite = Arc<tokio::sync::Mutex<Box<dyn tokio::io::AsyncWrite + Send + Unpin>>>;

/// Cancellation signal for a `Handle::Tcp` socket, triggered only by explicit `tcp.close` (never by `drop_handle`
/// ownership transfer such as `tcp.pipe` or `istream.pipe`).
#[derive(Default)]
pub(crate) struct SocketClose {
    closed: AtomicBool,
    notify: tokio::sync::Notify,
}

impl SocketClose {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub(crate) fn close(&self) {
        self.closed.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    /// Resolves immediately if already closed, or as soon as `close()` is called.
    pub(crate) async fn cancelled(&self) {
        loop {
            let notified = self.notify.notified();
            tokio::pin!(notified);
            // Register in `Notify`'s waiter list before reading `closed` so a concurrent `close()` cannot slip
            // between the check and `.await` and lose the wakeup.
            notified.as_mut().enable();
            if self.is_closed() {
                return;
            }
            notified.await;
        }
    }
}

/// A WebSocket frame as `ws.next` gives it and `ws.send`/`ws.ping` take it.
pub(crate) enum WsFrame {
    Text(String),
    Binary(Vec<u8>),
    Ping,
    Pong,
    /// The other side's Close frame, with its code and reason where it gave them (`ws.next`'s `end`, and its `code` and
    /// `reason`: a presence socket the plane replaced, 4000, or whose station it removed, 4004).
    Close(Option<(u16, String)>),
}

impl WsFrame {
    pub(crate) fn byte_len(&self) -> usize {
        match self {
            WsFrame::Text(s) => s.len(),
            WsFrame::Binary(b) => b.len(),
            WsFrame::Close(Some((_, r))) => r.len(),
            WsFrame::Ping | WsFrame::Pong | WsFrame::Close(None) => 0,
        }
    }
}

/// Bounded frame and byte limits for WebSocket incoming and outgoing channels.
#[derive(Clone, Copy)]
pub(crate) struct WsBounds {
    pub(crate) max_frames: usize,
    pub(crate) max_bytes: usize,
}

pub(crate) const DEFAULT_WS_BOUNDS: WsBounds = WsBounds {
    max_frames: 256,
    max_bytes: 16 * 1024 * 1024,
};

/// Signals `SocketClose` when the last `Handle::Ws` reference is dropped (e.g. on `Shell` teardown)
/// so the WebSocket background task always exits promptly without leaking.
pub(crate) struct WsCloseGuard(Arc<SocketClose>);

impl Drop for WsCloseGuard {
    fn drop(&mut self) {
        self.0.close();
    }
}

/// Aborts a spawned hyper connection driver task when the associated HTTP response is dropped or cancelled.
pub(crate) struct AbortOnDrop(Option<tokio::task::JoinHandle<()>>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        if let Some(h) = self.0.take() {
            h.abort();
        }
    }
}

/// Unified HTTP response backing `Handle::Response` for both default `reqwest` calls and raced `hyper` calls.
pub(crate) enum HttpResponse {
    Reqwest(reqwest::Response),
    Hyper {
        status: u16,
        headers: Value,
        body: hyper::body::Incoming,
        _conn: AbortOnDrop,
    },
}

impl HttpResponse {
    pub(crate) fn status(&self) -> u16 {
        match self {
            HttpResponse::Reqwest(r) => r.status().as_u16(),
            HttpResponse::Hyper { status, .. } => *status,
        }
    }

    pub(crate) fn headers(&self) -> Value {
        match self {
            HttpResponse::Reqwest(r) => headers_of(r),
            HttpResponse::Hyper { headers, .. } => headers.clone(),
        }
    }

    pub(crate) async fn chunk(&mut self) -> Result<Option<bytes::Bytes>, String> {
        match self {
            HttpResponse::Reqwest(r) => r.chunk().await.map_err(http_error),
            HttpResponse::Hyper { body, .. } => {
                use http_body_util::BodyExt;
                loop {
                    match body.frame().await {
                        Some(Ok(frame)) => {
                            if let Ok(data) = frame.into_data()
                                && !data.is_empty()
                            {
                                return Ok(Some(data));
                            }
                        }
                        Some(Err(e)) => return Err(e.to_string()),
                        None => return Ok(None),
                    }
                }
            }
        }
    }
}

/// Default hedge delay before starting the regional entry candidate in `race_tls_stream`.
const RACE_HEDGE_DEFAULT_MS: u64 = 1_000;

/// Default connect budget for raced HTTP requests (aligned with `station/src/cloud/transport.ts`).
const RACE_HTTP_BUDGET_MS: u64 = 10_000;

/// How long `ws.open` may take to have its socket, its TLS and its Upgrade answered where its caller says nothing (as the
/// TypeScript station's presence socket waits for its open, station/src/cloud/presence.ts).
const WS_OPEN_WITHIN_MS: u64 = 20_000;

/// How long a frame may take to be written: a socket whose other side stopped reading (a sleep, a network gone without
/// a reset) fills the kernel's buffer, and its write would wait for good, holding its reads and pings with it.
const WS_WRITE_WITHIN: std::time::Duration = std::time::Duration::from_secs(15);

/// Shared bounded deadline on `ws.close` to finish an in-flight write, drain already-accepted outgoing frames,
/// and complete the WebSocket Close handshake before dropping the socket.
const WS_CLOSE_WITHIN: std::time::Duration = std::time::Duration::from_secs(2);

/// A listening socket: TCP on this machine's loopback (one bound here, or one a launcher bound and handed down by its
/// descriptor), or a Unix socket by its path.
pub(crate) enum Listener {
    Tcp(tokio::net::TcpListener),
    #[cfg(unix)]
    Unix(tokio::net::UnixListener),
}

impl Listener {
    /// The next connection, as a socket read and written as `tcp.open`'s are, and who it came from.
    pub(crate) async fn accept(&self) -> Result<(Handle, String), String> {
        match self {
            Listener::Tcp(l) => {
                let (stream, peer) = l.accept().await.map_err(err)?;
                let _ = stream.set_nodelay(true);
                let (read, write) = stream.into_split();
                Ok((Handle::tcp(read, write), peer.to_string()))
            }
            #[cfg(unix)]
            Listener::Unix(l) => {
                let (stream, _) = l.accept().await.map_err(err)?;
                let (read, write) = stream.into_split();
                Ok((Handle::tcp(read, write), String::new()))
            }
        }
    }
}

/// As the Rust core's native host had it: HTTP/2 pings and TCP keepalive find connections a sleep or a new network left dead.
/// `follow`: redirects followed (up to ten, `redirect: "follow"`: a download's 302 to its storage); else none, its 3xx
/// answered as it came (sign-ins, the vault's proxy and the rest read the redirect itself).
pub(crate) fn http_client(tls: &rustls::ClientConfig, follow: bool) -> reqwest::Client {
    http_builder(tls, follow).build().expect("reqwest client")
}

fn http_builder(tls: &rustls::ClientConfig, follow: bool) -> reqwest::ClientBuilder {
    use std::time::Duration;
    reqwest::Client::builder()
        .tls_backend_preconfigured(tls.clone())
        .connect_timeout(Duration::from_secs(15))
        .pool_idle_timeout(Duration::from_secs(60))
        .tcp_keepalive(Duration::from_secs(30))
        .http2_keep_alive_interval(Duration::from_secs(20))
        .http2_keep_alive_timeout(Duration::from_secs(5))
        .http2_keep_alive_while_idle(true)
        .redirect(if follow { reqwest::redirect::Policy::limited(10) } else { reqwest::redirect::Policy::none() })
}

fn custom_http_client(
    default_tls: &rustls::ClientConfig,
    follow: bool,
    proxy: Option<&str>,
    ca_pem: Option<&str>,
    entry: Option<(String, u16)>,
) -> Result<reqwest::Client, String> {
    let owned_tls;
    let tls = match ca_pem {
        Some(pem) => {
            owned_tls = tls::tls_config_with_ca(Some(pem), None);
            &owned_tls
        }
        None => default_tls,
    };
    let mut builder = http_builder(tls, follow);
    builder = match proxy {
        Some(proxy_url) => builder.proxy(reqwest::Proxy::all(proxy_url).map_err(http_error)?),
        None => builder.no_proxy(),
    };
    if let Some((host, port)) = entry {
        builder = builder.dns_resolver(Arc::new(EntryResolver { host, port }));
    }
    builder.build().map_err(http_error)
}

/// Every name resolved to a cloud entry (its host and port): the TCP goes there, while TLS (its server name, the
/// certificate checked) and HTTP's Host stay the URL's own, as station/src/cloud/transport.ts dials one.
struct EntryResolver {
    host: String,
    port: u16,
}

impl reqwest::dns::Resolve for EntryResolver {
    fn resolve(&self, _name: reqwest::dns::Name) -> reqwest::dns::Resolving {
        let (host, port) = (self.host.clone(), self.port);
        Box::pin(async move {
            let addrs: Vec<std::net::SocketAddr> = tokio::net::lookup_host((host.as_str(), port)).await?.collect();
            Ok(Box::new(addrs.into_iter()) as reqwest::dns::Addrs)
        })
    }
}

/// A request's cloud entry (`{"entry": {"host", "port"}}`), where it says one.
fn entry_of(a: &Value) -> Result<Option<(String, u16)>, String> {
    let Some(e) = a.get("entry").filter(|e| !e.is_null()) else { return Ok(None) };
    let host = e.get("host").and_then(Value::as_str).filter(|h| !h.is_empty()).ok_or("an entry has a host")?;
    let port = e.get("port").and_then(Value::as_u64).filter(|p| (1..=65535).contains(p)).ok_or("an entry has a port")?;
    Ok(Some((host.to_string(), port as u16)))
}

fn race_of(a: &Value) -> bool {
    a.get("race").and_then(Value::as_bool).unwrap_or(false)
}

fn hedge_of(a: &Value) -> std::time::Duration {
    match a.get("hedgeMs").and_then(Value::as_f64) {
        Some(ms) if ms >= 0.0 => std::time::Duration::from_millis(ms as u64),
        _ => std::time::Duration::from_millis(RACE_HEDGE_DEFAULT_MS),
    }
}

fn alpn_of(a: &Value) -> Option<Vec<String>> {
    let arr = a.get("alpn").and_then(Value::as_array)?;
    let protos: Vec<String> = arr.iter().filter_map(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string).collect();
    (!protos.is_empty()).then_some(protos)
}

fn port_of(a: &Value) -> Result<u16, String> {
    let p = a.get("port").and_then(Value::as_u64).filter(|p| (1..=65535).contains(p)).ok_or("missing or invalid port")?;
    Ok(p as u16)
}

/// Per-address connect timeout when DNS resolves to multiple addresses (aligned with
/// `station/src/main.ts` `setDefaultAutoSelectFamilyAttemptTimeout(2_000)`), preventing a single
/// blackholed IPv6 address from consuming the entire connection budget before IPv4 is tried.
const TCP_MULTI_ADDR_ATTEMPT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

/// Dial a TCP connection to `(host, port)` with `SO_KEEPALIVE` (first probe after 30 s idle) and `TCP_NODELAY`.
pub(crate) async fn tcp_connect_keepalive(host: &str, port: u16) -> Result<tokio::net::TcpStream, String> {
    let host = host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(host);
    let addrs: Vec<std::net::SocketAddr> = tokio::net::lookup_host((host, port)).await.map_err(err)?.collect();
    let mut failed: Option<String> = None;
    for (idx, addr) in addrs.iter().copied().enumerate() {
        let socket = if addr.is_ipv4() { tokio::net::TcpSocket::new_v4() } else { tokio::net::TcpSocket::new_v6() }.map_err(err)?;
        socket.set_keepalive(true).map_err(err)?;
        keep_idle(&socket);
        let is_last = idx + 1 == addrs.len();
        let connected = if !is_last {
            // timer: per-address connect deadline when multiple addresses exist, avoiding blackhole IPv6 exhaustion
            match tokio::time::timeout(TCP_MULTI_ADDR_ATTEMPT_TIMEOUT, socket.connect(addr)).await {
                Ok(res) => res.map_err(err),
                Err(_) => Err(format!("connect {addr} timed out within {} ms", TCP_MULTI_ADDR_ATTEMPT_TIMEOUT.as_millis())),
            }
        } else {
            socket.connect(addr).await.map_err(err)
        };
        match connected {
            Ok(stream) => {
                stream.set_nodelay(true).map_err(err)?;
                return Ok(stream);
            }
            Err(e) => failed = Some(e),
        }
    }
    Err(match failed {
        Some(e) => e,
        None => format!("{host} has no address"),
    })
}

fn http_error(error: reqwest::Error) -> String {
    let mut message = error.to_string();
    let mut source = std::error::Error::source(&error);
    while let Some(cause) = source {
        message.push_str(": ");
        message.push_str(&cause.to_string());
        source = cause.source();
    }
    message
}

/// How much of a refused WebSocket handshake's body is read for why it was refused
/// (station/src/connects/surface.ts `REFUSAL_BYTES`).
const WS_REFUSAL_BYTES: usize = 4096;

/// Why a platform refused a WebSocket handshake, as its answer says: its `handshake-msg` header (Slack),
/// else its body's `error` or `message` when that is JSON (Comma), else the body's text, collapsed to one
/// line and at most 300 characters (station/src/connects/surface.ts `refusalWords`).
fn ws_refusal_words(header: Option<&str>, body: Option<&[u8]>) -> String {
    if let Some(h) = header.map(str::trim).filter(|s| !s.is_empty()) {
        return h.to_string();
    }
    let Some(bytes) = body else { return String::new() };
    let slice = &bytes[..bytes.len().min(WS_REFUSAL_BYTES)];
    let text = String::from_utf8_lossy(slice);
    let text = text.trim();
    if text.is_empty() {
        return String::new();
    }
    let mut said = text.to_string();
    if let Ok(json) = serde_json::from_str::<Value>(text) {
        if let Some(words) = json.get("error").and_then(Value::as_str).or_else(|| json.get("message").and_then(Value::as_str)) {
            said = words.to_string();
        }
    }
    let collapsed = said.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() > 300 {
        format!("{}…", collapsed.chars().take(299).collect::<String>())
    } else {
        collapsed
    }
}

fn ws_error(error: WsError) -> String {
    match error {
        WsError::Http(response) => {
            let status = response.status().as_u16();
            let header = response.headers().get("handshake-msg").and_then(|v| std::str::from_utf8(v.as_bytes()).ok());
            let why = ws_refusal_words(header, response.body().as_deref());
            if why.is_empty() {
                format!("websocket refused ({status})")
            } else {
                format!("websocket refused ({status}): {why}")
            }
        }
        error => format!("websocket: {error}"),
    }
}

/// A duration in ms a call gives as `key` (more than 0), if it gives one.
fn ms_of(a: &Value, key: &str) -> Option<std::time::Duration> {
    a.get(key).and_then(Value::as_f64).filter(|ms| *ms > 0.0).map(|ms| std::time::Duration::from_millis(ms as u64))
}

/// A TCP connection a WebSocket goes over, to `host` (a name or an address, in brackets where IPv6) and `port`.
async fn ws_tcp(host: &str, port: u16) -> Result<tokio::net::TcpStream, String> {
    tcp_connect_keepalive(host, port).await.map_err(|e| format!("websocket: {e}"))
}

/// A kept-alive socket's first probe after 30 s idle (the system's own is two hours). Where the system has no such
/// setting, its own.
fn keep_idle(socket: &tokio::net::TcpSocket) {
    #[cfg(any(target_os = "linux", target_os = "android", target_os = "macos", target_os = "ios"))]
    {
        use std::os::fd::AsRawFd;
        #[cfg(any(target_os = "linux", target_os = "android"))]
        let option = libc::TCP_KEEPIDLE;
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        let option = libc::TCP_KEEPALIVE;
        let idle: libc::c_int = 30;
        // SAFETY: setsockopt on a socket this function's caller holds, with an int it reads.
        unsafe { libc::setsockopt(socket.as_raw_fd(), libc::IPPROTO_TCP, option, (&idle as *const libc::c_int).cast(), std::mem::size_of::<libc::c_int>() as libc::socklen_t) };
    }
    #[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos", target_os = "ios")))]
    let _ = socket;
}

fn headers_of(response: &reqwest::Response) -> Value {
    headers_map_of(response.headers())
}

fn headers_map_of(headers: &http::HeaderMap) -> Value {
    Value::Array(headers.iter().map(|(k, v)| json!([k.as_str(), String::from_utf8_lossy(v.as_bytes())])).collect())
}

fn try_push_incoming(
    tx: &tokio::sync::mpsc::Sender<Result<WsFrame, String>>,
    queued_bytes: &AtomicUsize,
    max_bytes: usize,
    pending: &mut Option<Result<WsFrame, String>>,
) -> Result<bool, ()> {
    let Some(item) = pending.as_ref() else {
        return Ok(true);
    };
    let len = match item {
        Ok(f) => f.byte_len(),
        Err(_) => 0,
    };
    if len > 0 {
        let cur = queued_bytes.load(Ordering::Acquire);
        if cur > 0 && cur.saturating_add(len) > max_bytes {
            return Ok(false);
        }
    }
    let permit = match tx.try_reserve() {
        Ok(p) => p,
        Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => return Ok(false),
        Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => return Err(()),
    };
    let item = pending.take().unwrap();
    if len > 0 {
        queued_bytes.fetch_add(len, Ordering::AcqRel);
    }
    permit.send(item);
    Ok(true)
}

/// Flush a regular pending incoming frame into `incoming_tx` respecting `max_bytes`,
/// exiting immediately if `ws.close` cancels or the receiver is dropped.
async fn flush_pending_incoming(
    tx: &tokio::sync::mpsc::Sender<Result<WsFrame, String>>,
    queued_bytes: &AtomicUsize,
    max_bytes: usize,
    space: &tokio::sync::Notify,
    close: &SocketClose,
    pending: &mut Option<Result<WsFrame, String>>,
    #[cfg(test)] parked: Option<&tokio::sync::Notify>,
) {
    while pending.is_some() {
        if close.is_closed() {
            return;
        }
        match try_push_incoming(tx, queued_bytes, max_bytes, pending) {
            Ok(true) => return,
            Ok(false) => {}
            Err(()) => return,
        }
        let space_notified = space.notified();
        tokio::pin!(space_notified);
        space_notified.as_mut().enable();
        match try_push_incoming(tx, queued_bytes, max_bytes, pending) {
            Ok(true) => return,
            Ok(false) => {}
            Err(()) => return,
        }
        #[cfg(test)]
        if let Some(p) = parked {
            p.notify_waiters();
        }
        tokio::select! {
            biased;
            _ = close.cancelled() => return,
            _ = &mut space_notified => {}
        }
    }
}

/// Deliver a terminal WebSocket item (`Close(code, reason)` or terminal `Err`) into `incoming_tx`
/// without silently dropping it when the bounded queue is full, strictly respecting `max_bytes`
/// (allowing delivery once `queued_bytes == 0 || queued_bytes + len <= max_bytes`), while still
/// exiting immediately if `ws.close` cancels the socket or the receiver is dropped.
async fn deliver_terminal(
    tx: &tokio::sync::mpsc::Sender<Result<WsFrame, String>>,
    queued_bytes: &AtomicUsize,
    max_bytes: usize,
    space: &tokio::sync::Notify,
    close: &SocketClose,
    item: Result<WsFrame, String>,
    #[cfg(test)] parked: Option<&tokio::sync::Notify>,
) {
    let len = match &item {
        Ok(f) => f.byte_len(),
        Err(_) => 0,
    };
    let mut pending = Some(item);
    let try_send_once = |pending: &mut Option<Result<WsFrame, String>>| -> Result<bool, ()> {
        if len > 0 {
            let cur = queued_bytes.load(Ordering::Acquire);
            if cur > 0 && cur.saturating_add(len) > max_bytes {
                return Ok(false);
            }
        }
        match tx.try_reserve() {
            Ok(permit) => {
                if len > 0 {
                    queued_bytes.fetch_add(len, Ordering::AcqRel);
                }
                permit.send(pending.take().unwrap());
                Ok(true)
            }
            Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => Err(()),
            Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => Ok(false),
        }
    };
    loop {
        if close.is_closed() {
            return;
        }
        match try_send_once(&mut pending) {
            Ok(true) | Err(()) => return,
            Ok(false) => {}
        }
        let space_notified = space.notified();
        tokio::pin!(space_notified);
        space_notified.as_mut().enable();
        // Re-check after registering waiter so a concurrent `ws.next` cannot lose a wakeup.
        match try_send_once(&mut pending) {
            Ok(true) | Err(()) => return,
            Ok(false) => {}
        }
        #[cfg(test)]
        if let Some(p) = parked {
            p.notify_waiters();
        }
        tokio::select! {
            biased;
            _ = close.cancelled() => return,
            _ = &mut space_notified => {}
        }
    }
}

fn ws_frame_to_message(frame: WsFrame) -> Message {
    match frame {
        WsFrame::Text(t) => Message::text(t),
        WsFrame::Binary(b) => Message::binary(b),
        WsFrame::Ping => Message::Ping(Default::default()),
        WsFrame::Pong => Message::Pong(Default::default()),
        WsFrame::Close(_) => Message::Close(None),
    }
}

enum SendFrameOutcome {
    Sent,
    Closed,
    Error(String),
}

async fn send_ws_frame<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    outgoing_rx: &mut tokio::sync::mpsc::Receiver<WsFrame>,
    out_bytes: &AtomicUsize,
    close_task: &SocketClose,
    frame: WsFrame,
) -> SendFrameOutcome
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let len = frame.byte_len();
    if len > 0 {
        out_bytes.fetch_sub(len, Ordering::AcqRel);
    }
    let m = ws_frame_to_message(frame);
    let continue_drain_until = {
        let mut send_fut = std::pin::pin!(socket.send(m));
        // timer: a deadline on a frame's write, so a socket whose other side stopped reading ends
        let write_deadline = tokio::time::sleep(WS_WRITE_WITHIN);
        tokio::pin!(write_deadline);
        tokio::select! {
            biased;
            _ = close_task.cancelled() => {
                outgoing_rx.close();
                let deadline = tokio::time::Instant::now() + WS_CLOSE_WITHIN;
                // timer: shared 2 s close deadline bounding an in-flight write plus queued drain on ws.close
                match tokio::time::timeout_at(deadline, &mut send_fut).await {
                    Ok(Ok(())) => Some(deadline),
                    Ok(Err(_)) | Err(_) => return SendFrameOutcome::Closed,
                }
            }
            res = &mut send_fut => {
                return match res {
                    Ok(()) => SendFrameOutcome::Sent,
                    Err(e) => SendFrameOutcome::Error(ws_error(e)),
                };
            }
            _ = &mut write_deadline => {
                return SendFrameOutcome::Error("websocket: write timed out".into());
            }
        }
    };
    if let Some(deadline) = continue_drain_until {
        drain_outgoing_and_close_until(socket, outgoing_rx, out_bytes, deadline).await;
    }
    SendFrameOutcome::Closed
}

/// Close `outgoing_rx` immediately to reject any concurrent `ws.send`, then gracefully flush all
/// already-accepted outgoing frames and send a WebSocket Close frame until `deadline` so normal
/// `ws.send` + `ws.close` never drops accepted messages while still guaranteeing bounded exit on
/// stalled/half-open connections.
async fn drain_outgoing_and_close_until<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    outgoing_rx: &mut tokio::sync::mpsc::Receiver<WsFrame>,
    out_bytes: &AtomicUsize,
    deadline: tokio::time::Instant,
) where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    outgoing_rx.close();
    let work = async {
        while let Some(frame) = outgoing_rx.recv().await {
            let len = frame.byte_len();
            if len > 0 {
                out_bytes.fetch_sub(len, Ordering::AcqRel);
            }
            if socket.send(ws_frame_to_message(frame)).await.is_err() {
                return;
            }
        }
        let _ = socket.close(None).await;
    };
    // timer: bounded deadline to flush accepted outgoing frames and close handshake on ws.close
    let _ = tokio::time::timeout_at(deadline, work).await;
}

async fn drain_outgoing_and_close<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    outgoing_rx: &mut tokio::sync::mpsc::Receiver<WsFrame>,
    out_bytes: &AtomicUsize,
) where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    drain_outgoing_and_close_until(socket, outgoing_rx, out_bytes, tokio::time::Instant::now() + WS_CLOSE_WITHIN).await;
}

fn ws_enqueue(
    outgoing: &tokio::sync::mpsc::Sender<WsFrame>,
    outgoing_bytes: &AtomicUsize,
    bounds: WsBounds,
    close: &SocketClose,
    frame: WsFrame,
) -> Result<(), String> {
    if close.is_closed() || outgoing.is_closed() {
        return Err("the socket is closed".into());
    }
    let len = frame.byte_len();
    if len > 0 {
        let mut cur = outgoing_bytes.load(Ordering::Acquire);
        loop {
            let Some(next) = cur.checked_add(len).filter(|&n| n <= bounds.max_bytes) else {
                return Err(format!("websocket: outgoing buffer limit exceeded ({} bytes)", bounds.max_bytes));
            };
            match outgoing_bytes.compare_exchange_weak(cur, next, Ordering::AcqRel, Ordering::Acquire) {
                Ok(_) => break,
                Err(actual) => cur = actual,
            }
        }
    }
    match outgoing.try_send(frame) {
        Ok(()) => Ok(()),
        Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
            if len > 0 {
                outgoing_bytes.fetch_sub(len, Ordering::AcqRel);
            }
            Err(format!("websocket: outgoing queue full ({} frames)", bounds.max_frames))
        }
        Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
            if len > 0 {
                outgoing_bytes.fetch_sub(len, Ordering::AcqRel);
            }
            Err("the socket is closed".into())
        }
    }
}

/// Backoff intervals (in ms, ~2 s total) when retrying transient Unix-socket connect failures while the socket path
/// still exists on disk (e.g. macOS listen backlog transiently full).
#[cfg(unix)]
const UNIX_CONNECT_BACKOFF_MS: &[u64] = &[5, 10, 20, 40, 80, 160, 250, 250, 250, 250, 250, 250, 250];

/// Listen backlog for `unix.listen` (higher than Rust std's hardcoded 128 so bursts during brief main-thread stalls do
/// not immediately trigger ECONNREFUSED on macOS).
#[cfg(unix)]
const UNIX_LISTEN_BACKLOG: libc::c_int = 1024;

/// Connect to a Unix domain socket at `path`, retrying transient `ConnectionRefused`/`WouldBlock`/`Interrupted` errors
/// with bounded backoff while `path` still exists on disk. Fails immediately if `path` is missing (`NotFound`).
#[cfg(unix)]
pub(crate) async fn connect_unix(path: &str) -> Result<tokio::net::UnixStream, String> {
    use std::io::ErrorKind;
    let mut attempt = 0usize;
    loop {
        match tokio::net::UnixStream::connect(path).await {
            Ok(socket) => return Ok(socket),
            Err(e) if matches!(e.kind(), ErrorKind::ConnectionRefused | ErrorKind::WouldBlock | ErrorKind::Interrupted) => {
                let exists = !matches!(std::fs::symlink_metadata(path), Err(meta_err) if meta_err.kind() == ErrorKind::NotFound);
                if !exists || attempt >= UNIX_CONNECT_BACKOFF_MS.len() {
                    return Err(err(e));
                }
                // timer: retry after transient Unix socket ECONNREFUSED/EAGAIN (full backlog) with bounded backoff
                tokio::time::sleep(std::time::Duration::from_millis(UNIX_CONNECT_BACKOFF_MS[attempt])).await;
                attempt += 1;
            }
            Err(e) => return Err(err(e)),
        }
    }
}

/// Create, bind, and listen on a Unix domain socket at `path` with an explicit `backlog`, optional permission `mode`,
/// and `FD_CLOEXEC`.
#[cfg(unix)]
fn listen_unix(path: &str, backlog: libc::c_int, mode: Option<u32>) -> Result<tokio::net::UnixListener, String> {
    use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd};
    if path.as_bytes().contains(&0) {
        return Err("unix socket path contains NUL".into());
    }
    let make_addr = |bind_path: &str| -> Result<(libc::sockaddr_un, libc::socklen_t), String> {
        let bytes = bind_path.as_bytes();
        // SAFETY: `sockaddr_un` is a plain C struct; zero-initializing leaves `sun_path` NUL-terminated.
        let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
        addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
        if bytes.len() >= addr.sun_path.len() {
            return Err(format!("unix socket path too long ({} >= {})", bytes.len(), addr.sun_path.len()));
        }
        // SAFETY: `bytes.len() < addr.sun_path.len()` was checked above and both pointers are valid and non-overlapping.
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), addr.sun_path.as_mut_ptr().cast::<u8>(), bytes.len());
        }
        let len = (std::mem::offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1) as libc::socklen_t;
        Ok((addr, len))
    };

    let (target_addr, target_len) = make_addr(path)?;

    // When an explicit `mode` is requested, bind exclusively on a unique sibling path, apply `mode` and `listen`
    // while that inode is private to this call, and atomically `rename` it into `path`. That prevents a concurrent
    // `unix.listen` on the same `path` from having its mode overwritten or its inode unlinked by a racing call.
    let staged: Option<(String, libc::sockaddr_un, libc::socklen_t)> = if mode.is_some() {
        let mut random = [0u8; 4];
        getrandom::fill(&mut random).map_err(err)?;
        let parent = std::path::Path::new(path).parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| std::path::Path::new("."));
        let tmp = parent.join(format!(".u{}", hex::encode(random)));
        let tmp_str = tmp.to_str().ok_or_else(|| "unix socket path is not valid UTF-8".to_string())?.to_string();
        let (addr, len) = make_addr(&tmp_str)?;
        Some((tmp_str, addr, len))
    } else {
        None
    };

    // SAFETY: standard POSIX socket creation; wrapped in `OwnedFd` immediately so no error path can leak it.
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(err(std::io::Error::last_os_error()));
    }
    let owned = unsafe { OwnedFd::from_raw_fd(fd) };

    // SAFETY: setting FD_CLOEXEC on our newly created descriptor.
    if unsafe { libc::fcntl(owned.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
        return Err(err(std::io::Error::last_os_error()));
    }
    if let Some((tmp_path, addr, addr_len)) = staged {
        // SAFETY: `addr` is a properly initialized `sockaddr_un` of length `addr_len`.
        if unsafe { libc::bind(owned.as_raw_fd(), (&addr as *const libc::sockaddr_un).cast::<libc::sockaddr>(), addr_len) } < 0 {
            return Err(err(std::io::Error::last_os_error()));
        }
        let publish = (|| -> Result<(), String> {
            if let Some(m) = mode {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&tmp_path, std::fs::Permissions::from_mode(m)).map_err(err)?;
            }
            // SAFETY: `owned` is a bound AF_UNIX/SOCK_STREAM socket.
            if unsafe { libc::listen(owned.as_raw_fd(), backlog) } < 0 {
                return Err(err(std::io::Error::last_os_error()));
            }
            std::fs::rename(&tmp_path, path).map_err(err)
        })();
        if let Err(e) = publish {
            let _ = std::fs::remove_file(&tmp_path);
            return Err(e);
        }
    } else {
        let _ = std::fs::remove_file(path);
        // SAFETY: `target_addr` is a properly initialized `sockaddr_un` of length `target_len`.
        if unsafe { libc::bind(owned.as_raw_fd(), (&target_addr as *const libc::sockaddr_un).cast::<libc::sockaddr>(), target_len) } < 0 {
            return Err(err(std::io::Error::last_os_error()));
        }
        // SAFETY: `owned` is a bound AF_UNIX/SOCK_STREAM socket.
        if unsafe { libc::listen(owned.as_raw_fd(), backlog) } < 0 {
            return Err(err(std::io::Error::last_os_error()));
        }
    }
    // SAFETY: transfers ownership of the listening AF_UNIX socket descriptor to `std::os::unix::net::UnixListener`.
    let std_listener = unsafe { std::os::unix::net::UnixListener::from_raw_fd(owned.into_raw_fd()) };
    std_listener.set_nonblocking(true).map_err(err)?;
    tokio::net::UnixListener::from_std(std_listener).map_err(err)
}

/// A connection to the Unix socket at `path` that a stream is carried into, `head` written to it first (what tells the
/// other side which stream it is); an error where nothing listens there or it takes nothing.
pub(crate) async fn open_unix(path: &str, head: &[u8]) -> Result<(SocketRead, SocketWrite), String> {
    #[cfg(unix)]
    {
        let socket = connect_unix(path).await?;
        {
            use std::os::fd::AsRawFd;
            // A stream's pieces written a megabyte ahead of the other side's reads (a Unix socket's own is 8 KiB on
            // macOS): fewer turns of both for what a stream carries.
            let size: libc::c_int = 1 << 20;
            // SAFETY: setsockopt on a socket this function holds, with an int it reads.
            unsafe { libc::setsockopt(socket.as_raw_fd(), libc::SOL_SOCKET, libc::SO_SNDBUF, (&size as *const libc::c_int).cast(), std::mem::size_of::<libc::c_int>() as libc::socklen_t) };
        }
        let (read, mut write) = socket.into_split();
        write.write_all(head).await.map_err(err)?;
        let read: SocketRead = Arc::new(tokio::sync::Mutex::new(Box::new(read)));
        let write: SocketWrite = Arc::new(tokio::sync::Mutex::new(Box::new(write)));
        Ok((read, write))
    }
    #[cfg(not(unix))]
    {
        let _ = (path, head);
        Err("Unix sockets are Unix's".into())
    }
}

/// `bytes` said to the Unix socket at `path` on a connection of their own, then that connection ended.
pub(crate) async fn tell_unix(path: &str, bytes: &[u8]) -> Result<(), String> {
    #[cfg(unix)]
    {
        let mut socket = connect_unix(path).await?;
        socket.write_all(bytes).await.map_err(err)?;
        shut(socket.shutdown().await)
    }
    #[cfg(not(unix))]
    {
        let _ = (path, bytes);
        Err("Unix sockets are Unix's".into())
    }
}

/// A connection's end (`shutdown`) as `tell_unix` takes it: the other side gone already is what it was told for (the
/// station's Node reads the bytes it waits for and closes at once, so on macOS the shutdown that follows races it and
/// says ENOTCONN, os error 57), not a failure.
#[cfg_attr(not(unix), allow(dead_code))]
fn shut(done: std::io::Result<()>) -> Result<(), String> {
    match done {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotConnected => Ok(()),
        Err(e) => Err(err(e)),
    }
}

impl Inner {
    /// The request a call says, and its client. `redirect: "follow"`: redirects followed; else (`"manual"`, or none
    /// said) its answer is the first one, a 3xx too.
    fn request(&self, a: &Value, body: Option<Vec<u8>>) -> Result<reqwest::RequestBuilder, String> {
        let method = reqwest::Method::from_bytes(str_of(a, "method")?.as_bytes()).map_err(err)?;
        let follow = a.get("redirect").and_then(Value::as_str) == Some("follow");
        let proxy = a.get("proxy").and_then(Value::as_str).filter(|s| !s.is_empty());
        let ca_pem = a.get("caPem").and_then(Value::as_str).filter(|s| !s.is_empty());
        let entry = entry_of(a)?;
        let client = if proxy.is_none() && ca_pem.is_none() {
            match entry {
                None if follow => self.http_follow.lock().unwrap().clone(),
                None => self.http.lock().unwrap().clone(),
                Some((host, port)) => {
                    let mut entries = self.entries.lock().unwrap();
                    match entries.get(&(host.clone(), port, follow)) {
                        Some(c) => c.clone(),
                        None => {
                            let c = http_builder(&self.tls, follow).dns_resolver(Arc::new(EntryResolver { host: host.clone(), port })).build().map_err(http_error)?;
                            entries.insert((host, port, follow), c.clone());
                            c
                        }
                    }
                }
            }
        } else {
            custom_http_client(&self.tls, follow, proxy, ca_pem, entry)?
        };
        let mut builder = client.request(method, str_of(a, "url")?);
        for pair in a.get("headers").and_then(Value::as_array).into_iter().flatten() {
            if let (Some(k), Some(v)) = (pair.get(0).and_then(Value::as_str), pair.get(1).and_then(Value::as_str)) {
                builder = builder.header(k, v);
            }
        }
        if let Some(body) = body {
            builder = builder.body(body);
        }
        Ok(builder)
    }

    /// Send an HTTPS request over the single winning TLS stream from `race_tls_stream`.
    /// Request headers and body are strictly sent ONCE over the single winning connection.
    async fn sent_raced(
        &self,
        a: &Value,
        entry: (String, u16),
        body: Option<Vec<u8>>,
        head_within: Option<std::time::Duration>,
    ) -> Result<(HttpResponse, bool), String> {
        if a.get("proxy").and_then(Value::as_str).is_some_and(|s| !s.is_empty()) {
            return Err("race does not support proxy".into());
        }
        if a.get("redirect").and_then(Value::as_str) == Some("follow") {
            return Err("race does not support redirect: follow".into());
        }
        let method = http::Method::from_bytes(str_of(a, "method")?.as_bytes()).map_err(err)?;
        let url_str = str_of(a, "url")?;
        // Use `reqwest::Url::parse` so invalid ports (`:65536`, `:abc`) are rejected and dot-segments
        // (`/folder/../file`) are normalized identically to `reqwest`.
        let url = reqwest::Url::parse(url_str).map_err(err)?;
        if url.scheme() != "https" {
            return Err("race requires https URL".into());
        }
        let url_host = url.host_str().ok_or("URL has no host")?.to_string();
        let url_port = url.port_or_known_default().unwrap_or(443);
        let ca_pem = a.get("caPem").and_then(Value::as_str).filter(|s| !s.is_empty());
        let hedge = hedge_of(a);
        let max_connect = std::time::Duration::from_millis(RACE_HTTP_BUDGET_MS);
        let connect_budget = head_within.map(|d| d.min(max_connect)).unwrap_or(max_connect);
        let tls_cfg = match ca_pem {
            Some(pem) => Arc::new(tls::tls_config_with_strict_ca(pem, Some(&["http/1.1".to_string()]))?),
            None => self.tls_h1.clone(),
        };

        let path_and_query = match url.query() {
            Some(q) => format!("{}?{q}", url.path()),
            None => url.path().to_string(),
        };
        let mut req_builder = http::Request::builder().method(method).uri(path_and_query);
        let mut has_host = false;
        let mut has_accept = false;
        for pair in a.get("headers").and_then(Value::as_array).into_iter().flatten() {
            if let (Some(k), Some(v)) = (pair.get(0).and_then(Value::as_str), pair.get(1).and_then(Value::as_str)) {
                if k.eq_ignore_ascii_case("host") {
                    has_host = true;
                } else if k.eq_ignore_ascii_case("accept") {
                    has_accept = true;
                }
                req_builder = req_builder.header(k, v);
            }
        }
        if !has_host {
            let host_hdr = if url_port == 443 { url_host.clone() } else { format!("{url_host}:{url_port}") };
            req_builder = req_builder.header(http::header::HOST, host_hdr);
        }
        if !has_accept {
            req_builder = req_builder.header(http::header::ACCEPT, "*/*");
        }
        let req = req_builder
            .body(http_body_util::Full::new(bytes::Bytes::from(body.unwrap_or_default())))
            .map_err(err)?;

        let work = async move {
            let winner = tls::race_tls_stream((url_host.clone(), url_port), entry, &url_host, tls_cfg, hedge, connect_budget).await?;
            let io = hyper_util::rt::TokioIo::new(winner);
            let (mut sender, conn) = hyper::client::conn::http1::handshake(io).await.map_err(err)?;
            let conn_guard = AbortOnDrop(Some(tokio::spawn(async move {
                let _ = conn.await;
            })));
            let resp = sender.send_request(req).await.map_err(err)?;
            let status = resp.status().as_u16();
            let headers = headers_map_of(resp.headers());
            let resp_body = resp.into_body();
            Ok::<(HttpResponse, bool), String>((
                HttpResponse::Hyper {
                    status,
                    headers,
                    body: resp_body,
                    _conn: conn_guard,
                },
                false,
            ))
        };

        match head_within {
            // timer: a deadline on an answer's head (covering TLS race + HTTP response head)
            Some(d) => tokio::time::timeout(d, work).await.map_err(|_| format!("no answer within {} ms", d.as_millis()))?,
            None => work.await,
        }
    }

    /// The answer to the request a call says, its head within `head_within` where given, and whether it is another
    /// URL's than the one asked (a redirect followed).
    async fn sent(&self, a: &Value, body: Option<Vec<u8>>, head_within: Option<std::time::Duration>) -> Result<(HttpResponse, bool), String> {
        if race_of(a)
            && let Some(entry) = entry_of(a)?
        {
            return self.sent_raced(a, entry, body, head_within).await;
        }
        let (client, request) = self.request(a, body)?.build_split();
        let request = request.map_err(http_error)?;
        let asked = request.url().clone();
        let sent = client.execute(request);
        let response = match head_within {
            // timer: a deadline on an answer's head, where its caller gives one
            Some(d) => tokio::time::timeout(d, sent).await.map_err(|_| format!("no answer within {} ms", d.as_millis()))?,
            None => sent.await,
        }
        .map_err(http_error)?;
        let redirected = response.url() != &asked;
        Ok((HttpResponse::Reqwest(response), redirected))
    }

    async fn ws_open(self: &Arc<Self>, a: &Value) -> Done {
        self.ws_open_with_bounds(
            a,
            DEFAULT_WS_BOUNDS,
            #[cfg(test)]
            None,
        )
        .await
    }

    pub(crate) async fn ws_open_with_bounds(
        self: &Arc<Self>,
        a: &Value,
        bounds: WsBounds,
        #[cfg(test)] parked: Option<Arc<tokio::sync::Notify>>,
    ) -> Done {
        let mut request = str_of(a, "url")?.into_client_request().map_err(ws_error)?;
        let protocols: Vec<&str> = a.get("protocols").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).collect();
        if !protocols.is_empty() {
            request.headers_mut().insert("sec-websocket-protocol", protocols.join(", ").parse().map_err(err)?);
        }
        // `headers`: [[name, value]…] the request carries besides (a presence socket's `x-stillfail-*`).
        for pair in a.get("headers").and_then(Value::as_array).into_iter().flatten() {
            if let (Some(k), Some(v)) = (pair.get(0).and_then(Value::as_str), pair.get(1).and_then(Value::as_str)) {
                let name = tokio_tungstenite::tungstenite::http::HeaderName::from_bytes(k.as_bytes()).map_err(err)?;
                request.headers_mut().append(name, v.parse().map_err(err)?);
            }
        }
        let ca_pem = a.get("caPem").and_then(Value::as_str).filter(|s| !s.is_empty());
        let tls_cfg = match ca_pem {
            Some(pem) => Arc::new(tls::tls_config_with_strict_ca(pem, None)?),
            None => self.tls.clone(),
        };
        let entry = entry_of(a)?;
        let use_race = race_of(a) && entry.is_some();
        let hedge = hedge_of(a);
        let mut ws_config = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default();
        ws_config.max_message_size = Some(bounds.max_bytes);
        ws_config.max_frame_size = Some(bounds.max_bytes);
        // `timeoutMs`: how long the socket, its TLS and its Upgrade may take together; a handshake into a socket that
        // never answers held its caller for good (a presence socket that never opened, nor tried again).
        let within = ms_of(a, "timeoutMs").unwrap_or(std::time::Duration::from_millis(WS_OPEN_WITHIN_MS));
        let opening = async {
            if use_race {
                let entry = entry.unwrap();
                let uri = request.uri();
                if uri.scheme_str() != Some("wss") {
                    return Err("websocket: race requires wss URL".into());
                }
                let url_host = uri.host().ok_or("websocket: the URL has no host")?.to_string();
                let url_port = uri.port_u16().unwrap_or(443);
                let winner = tls::race_tls_stream((url_host.clone(), url_port), entry, &url_host, tls_cfg, hedge, within).await?;
                // Upgrade bytes are strictly sent ONCE over the single winning TLS stream.
                tokio_tungstenite::client_async_with_config(request, MaybeTlsStream::Rustls(winner), Some(ws_config))
                    .await
                    .map_err(ws_error)
            } else {
                // `entry` without `race: true`: TCP directly to the cloud entry, TLS/Host the URL's own.
                let (host, port) = match entry {
                    Some(entry) => entry,
                    None => {
                        let uri = request.uri();
                        let host = uri.host().ok_or("websocket: the URL has no host")?.to_string();
                        let port = uri.port_u16().unwrap_or(if uri.scheme_str() == Some("wss") { 443 } else { 80 });
                        (host, port)
                    }
                };
                let connector = Some(Connector::Rustls(tls_cfg));
                let stream = ws_tcp(&host, port).await?;
                tokio_tungstenite::client_async_tls_with_config(request, stream, Some(ws_config), connector)
                    .await
                    .map_err(ws_error)
            }
        };
        // timer: a deadline on a WebSocket's opening (its TCP, TLS and Upgrade), given or 20 s
        let (socket, _) = tokio::time::timeout(within, opening).await.map_err(|_| format!("websocket: open timed out within {} ms", within.as_millis()))??;
        // `binary`: its binary frames given too (`{binary: true}` and their bytes); else they are let go, as a socket
        // that speaks only text takes `ws.next`'s other answers for its end.
        let binary = a.get("binary").and_then(Value::as_bool).unwrap_or(false);
        // `control`: incoming Ping/Pong frames given too (`{ping: true}` / `{pong: true}`), so callers that ping can
        // track liveness; else control frames stay internal to tungstenite without surfacing on `ws.next`.
        let control = a.get("control").and_then(Value::as_bool).unwrap_or(false);
        let (id, _task) = self.spawn_ws_stream(
            socket,
            binary,
            control,
            bounds,
            #[cfg(test)]
            parked,
        );
        Ok(Answer::json(json!({ "id": id })))
    }

    pub(crate) fn spawn_ws_stream<S>(
        self: &Arc<Self>,
        socket: tokio_tungstenite::WebSocketStream<S>,
        binary: bool,
        control: bool,
        bounds: WsBounds,
        #[cfg(test)] parked: Option<Arc<tokio::sync::Notify>>,
    ) -> (u64, tokio::task::JoinHandle<()>)
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        let (incoming_tx, incoming) = tokio::sync::mpsc::channel::<Result<WsFrame, String>>(bounds.max_frames.max(1));
        let (outgoing, mut outgoing_rx) = tokio::sync::mpsc::channel::<WsFrame>(bounds.max_frames.max(1));
        let incoming_bytes = Arc::new(AtomicUsize::new(0));
        let outgoing_bytes = Arc::new(AtomicUsize::new(0));
        let incoming_space = Arc::new(tokio::sync::Notify::new());
        let close = SocketClose::new();
        let guard = Arc::new(WsCloseGuard(close.clone()));

        let in_bytes_task = incoming_bytes.clone();
        let out_bytes_task = outgoing_bytes.clone();
        let in_space_task = incoming_space.clone();
        let close_task = close.clone();
        // One task owns the socket: reading is also what answers the server's pings; what is to be sent goes between.
        // Backpressure never blocks `ws.close` or outgoing writes: when `incoming_tx` is full, the pending frame waits
        // on `incoming_space` alongside `close.cancelled()` and `outgoing_rx.recv()`.
        let task = tokio::spawn(async move {
            let mut socket = socket;
            let mut pending_in: Option<Result<WsFrame, String>> = None;
            loop {
                if close_task.is_closed() {
                    drain_outgoing_and_close(&mut socket, &mut outgoing_rx, &out_bytes_task).await;
                    return;
                }
                if pending_in.is_some() {
                    match try_push_incoming(&incoming_tx, &in_bytes_task, bounds.max_bytes, &mut pending_in) {
                        Ok(true) | Ok(false) => {}
                        Err(()) => {
                            drain_outgoing_and_close(&mut socket, &mut outgoing_rx, &out_bytes_task).await;
                            return;
                        }
                    }
                }
                if pending_in.is_some() {
                    let space_notified = in_space_task.notified();
                    tokio::pin!(space_notified);
                    space_notified.as_mut().enable();
                    // Re-check after registering waiter so a concurrent `ws.next` cannot lose a wakeup.
                    match try_push_incoming(&incoming_tx, &in_bytes_task, bounds.max_bytes, &mut pending_in) {
                        Ok(true) => continue,
                        Ok(false) => {}
                        Err(()) => {
                            drain_outgoing_and_close(&mut socket, &mut outgoing_rx, &out_bytes_task).await;
                            return;
                        }
                    }
                    #[cfg(test)]
                    if let Some(p) = parked.as_deref() {
                        p.notify_waiters();
                    }
                    tokio::select! {
                        biased;
                        _ = close_task.cancelled() => {
                            drain_outgoing_and_close(&mut socket, &mut outgoing_rx, &out_bytes_task).await;
                            return;
                        }
                        _ = &mut space_notified => continue,
                        frame = outgoing_rx.recv() => match frame {
                            Some(frame) => match send_ws_frame(&mut socket, &mut outgoing_rx, &out_bytes_task, &close_task, frame).await {
                                SendFrameOutcome::Sent => {}
                                SendFrameOutcome::Closed => return,
                                SendFrameOutcome::Error(write_err) => {
                                    // Close outgoing_rx and release the dead TCP socket before waiting for the consumer to drain.
                                    outgoing_rx.close();
                                    drop(socket);
                                    flush_pending_incoming(
                                        &incoming_tx,
                                        &in_bytes_task,
                                        bounds.max_bytes,
                                        &in_space_task,
                                        &close_task,
                                        &mut pending_in,
                                        #[cfg(test)]
                                        parked.as_deref(),
                                    )
                                    .await;
                                    deliver_terminal(
                                        &incoming_tx,
                                        &in_bytes_task,
                                        bounds.max_bytes,
                                        &in_space_task,
                                        &close_task,
                                        Err(write_err),
                                        #[cfg(test)]
                                        parked.as_deref(),
                                    )
                                    .await;
                                    return;
                                }
                            },
                            None => {
                                drain_outgoing_and_close(&mut socket, &mut outgoing_rx, &out_bytes_task).await;
                                return;
                            }
                        },
                    }
                } else {
                    tokio::select! {
                        biased;
                        _ = close_task.cancelled() => {
                            drain_outgoing_and_close(&mut socket, &mut outgoing_rx, &out_bytes_task).await;
                            return;
                        }
                        frame = outgoing_rx.recv() => match frame {
                            Some(frame) => match send_ws_frame(&mut socket, &mut outgoing_rx, &out_bytes_task, &close_task, frame).await {
                                SendFrameOutcome::Sent => {}
                                SendFrameOutcome::Closed => return,
                                SendFrameOutcome::Error(write_err) => {
                                    outgoing_rx.close();
                                    drop(socket);
                                    deliver_terminal(
                                        &incoming_tx,
                                        &in_bytes_task,
                                        bounds.max_bytes,
                                        &in_space_task,
                                        &close_task,
                                        Err(write_err),
                                        #[cfg(test)]
                                        parked.as_deref(),
                                    )
                                    .await;
                                    return;
                                }
                            },
                            None => {
                                drain_outgoing_and_close(&mut socket, &mut outgoing_rx, &out_bytes_task).await;
                                return;
                            }
                        },
                        message = socket.next() => match message {
                            Some(Ok(Message::Text(text))) => {
                                let s = text.as_str().to_owned();
                                if s.len() > bounds.max_bytes {
                                    outgoing_rx.close();
                                    drop(socket);
                                    deliver_terminal(
                                        &incoming_tx,
                                        &in_bytes_task,
                                        bounds.max_bytes,
                                        &in_space_task,
                                        &close_task,
                                        Err(format!("websocket: incoming frame exceeds buffer limit ({} bytes)", bounds.max_bytes)),
                                        #[cfg(test)]
                                        parked.as_deref(),
                                    )
                                    .await;
                                    return;
                                }
                                pending_in = Some(Ok(WsFrame::Text(s)));
                            }
                            Some(Ok(Message::Binary(b))) if binary => {
                                let v = b.to_vec();
                                if v.len() > bounds.max_bytes {
                                    outgoing_rx.close();
                                    drop(socket);
                                    deliver_terminal(
                                        &incoming_tx,
                                        &in_bytes_task,
                                        bounds.max_bytes,
                                        &in_space_task,
                                        &close_task,
                                        Err(format!("websocket: incoming frame exceeds buffer limit ({} bytes)", bounds.max_bytes)),
                                        #[cfg(test)]
                                        parked.as_deref(),
                                    )
                                    .await;
                                    return;
                                }
                                pending_in = Some(Ok(WsFrame::Binary(v)));
                            }
                            Some(Ok(Message::Ping(_))) if control => {
                                pending_in = Some(Ok(WsFrame::Ping));
                            }
                            Some(Ok(Message::Pong(_))) if control => {
                                pending_in = Some(Ok(WsFrame::Pong));
                            }
                            Some(Ok(Message::Close(frame))) => {
                                let close_frame = WsFrame::Close(frame.map(|f| (u16::from(f.code), f.reason.to_string())));
                                // Close outgoing_rx immediately so subsequent ws.send fails with closed,
                                // flush tungstenite's auto-queued Close reply within a short bound, and
                                // drop the TCP socket before waiting for a slow consumer to drain.
                                outgoing_rx.close();
                                // timer: bounded close reply flush after peer Close frame
                                let _ = tokio::time::timeout(std::time::Duration::from_millis(500), async {
                                    let _ = socket.flush().await;
                                    let _ = socket.close(None).await;
                                })
                                .await;
                                drop(socket);
                                deliver_terminal(
                                    &incoming_tx,
                                    &in_bytes_task,
                                    bounds.max_bytes,
                                    &in_space_task,
                                    &close_task,
                                    Ok(close_frame),
                                    #[cfg(test)]
                                    parked.as_deref(),
                                )
                                .await;
                                return;
                            }
                            Some(Err(WsError::ConnectionClosed | WsError::AlreadyClosed)) | None => {
                                outgoing_rx.close();
                                return;
                            }
                            Some(Ok(_)) => {}
                            Some(Err(e)) => {
                                outgoing_rx.close();
                                drop(socket);
                                deliver_terminal(
                                    &incoming_tx,
                                    &in_bytes_task,
                                    bounds.max_bytes,
                                    &in_space_task,
                                    &close_task,
                                    Err(ws_error(e)),
                                    #[cfg(test)]
                                    parked.as_deref(),
                                )
                                .await;
                                return;
                            }
                        },
                    }
                }
            }
        });
        let id = self.keep(Handle::Ws {
            incoming: Arc::new(tokio::sync::Mutex::new(incoming)),
            incoming_bytes,
            incoming_space,
            outgoing,
            outgoing_bytes,
            bounds,
            close,
            _guard: guard,
        });
        (id, task)
    }

    pub(crate) async fn run_net(self: &Arc<Self>, op: &str, a: &Value, bytes: Option<Vec<u8>>) -> Done {
        match op {
            "fetch" => {
                // `timeoutMs`: how long the answer's head may take to come; `stallMs`: how long its body may stay
                // silent between two pieces (a whole-download deadline would cut a large one off on a slow network).
                // Neither given: as long as the caller waits (it cancels the call).
                let (head_within, stall_within) = (ms_of(a, "timeoutMs"), ms_of(a, "stallMs"));
                let (mut response, redirected) = self.sent(a, bytes, head_within).await?;
                let (status, headers) = (response.status(), response.headers());
                let mut body = Vec::new();
                loop {
                    let piece = match stall_within {
                        // timer: a deadline on an answer's next body piece, where its caller gives one
                        Some(d) => tokio::time::timeout(d, response.chunk()).await.map_err(|_| format!("nothing more came within {} ms", d.as_millis()))??,
                        None => response.chunk().await?,
                    };
                    match piece {
                        Some(piece) => body.extend_from_slice(&piece),
                        None => break,
                    }
                }
                Ok(Answer::bytes(json!({ "status": status, "headers": headers, "redirected": redirected }), body))
            }
            // `timeoutMs`: how long its head may take, as `fetch`'s.
            "stream.open" => {
                let (response, redirected) = self.sent(a, bytes, ms_of(a, "timeoutMs")).await?;
                let (status, headers) = (response.status(), response.headers());
                let id = self.keep(Handle::Response(Arc::new(tokio::sync::Mutex::new(response))));
                Ok(Answer::json(json!({ "status": status, "headers": headers, "id": id, "redirected": redirected })))
            }
            // `stallMs` (else `timeoutMs`): how long its next piece may take to come.
            "stream.read" => {
                let Handle::Response(response) = self.handle(id_of(a)?)? else { return Err("not a response".into()) };
                let mut response = response.lock().await;
                let chunk = match ms_of(a, "stallMs").or_else(|| ms_of(a, "timeoutMs")) {
                    // timer: a deadline on a stream's next piece, where its caller gives one
                    Some(d) => tokio::time::timeout(d, response.chunk()).await.map_err(|_| format!("nothing more came within {} ms", d.as_millis()))??,
                    None => response.chunk().await?,
                };
                Ok(match chunk {
                    Some(c) => Answer::bytes(json!({}), c.to_vec()),
                    None => Answer::json(json!({ "end": true })),
                })
            }
            "ws.open" => self.ws_open(a).await,
            "ws.next" => {
                let Handle::Ws { incoming, incoming_bytes, incoming_space, close, .. } = self.handle(id_of(a)?)? else { return Err("not a socket".into()) };
                if close.is_closed() {
                    return Ok(Answer::json(json!({ "end": true })));
                }
                let mut guard = tokio::select! {
                    biased;
                    _ = close.cancelled() => return Ok(Answer::json(json!({ "end": true }))),
                    guard = incoming.lock() => guard,
                };
                let frame = tokio::select! {
                    biased;
                    _ = close.cancelled() => None,
                    frame = guard.recv() => frame,
                };
                if let Some(Ok(ref f)) = frame {
                    let len = f.byte_len();
                    if len > 0 {
                        incoming_bytes.fetch_sub(len, Ordering::AcqRel);
                    }
                    incoming_space.notify_one();
                } else if frame.is_some() {
                    incoming_space.notify_one();
                }
                match frame {
                    Some(Ok(WsFrame::Text(text))) => Ok(Answer::json(json!({ "text": text }))),
                    // A binary frame (Feishu's long connection speaks protobuf): its bytes, said `binary`.
                    Some(Ok(WsFrame::Binary(b))) => Ok(Answer::bytes(json!({ "binary": true }), b)),
                    Some(Ok(WsFrame::Ping)) => Ok(Answer::json(json!({ "ping": true }))),
                    Some(Ok(WsFrame::Pong)) => Ok(Answer::json(json!({ "pong": true }))),
                    // Its end, with the Close frame's code and reason where the other side gave them.
                    Some(Ok(WsFrame::Close(Some((code, reason))))) => Ok(Answer::json(json!({ "end": true, "code": code, "reason": reason }))),
                    Some(Ok(WsFrame::Close(None))) | None => Ok(Answer::json(json!({ "end": true }))),
                    Some(Err(e)) => Err(e),
                }
            }
            "ws.send" => {
                let Handle::Ws { outgoing, outgoing_bytes, bounds, close, .. } = self.handle(id_of(a)?)? else { return Err("not a socket".into()) };
                // Bytes given: a binary frame; else `text`.
                let frame = match bytes { Some(b) => WsFrame::Binary(b), None => WsFrame::Text(str_of(a, "text")?.to_string()) };
                ws_enqueue(&outgoing, &outgoing_bytes, bounds, &close, frame)?;
                Ok(Answer::json(json!({})))
            }
            "ws.ping" => {
                let Handle::Ws { outgoing, outgoing_bytes, bounds, close, .. } = self.handle(id_of(a)?)? else { return Err("not a socket".into()) };
                ws_enqueue(&outgoing, &outgoing_bytes, bounds, &close, WsFrame::Ping)?;
                Ok(Answer::json(json!({})))
            }
            "tcp.open" => {
                let port = a.get("port").and_then(Value::as_u64).ok_or("missing port")? as u16;
                let stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.map_err(err)?;
                let (read, write) = stream.into_split();
                let id = self.keep(Handle::tcp(read, write));
                Ok(Answer::json(json!({ "id": id })))
            }
            // Outbound raw TCP dial to `(host, port)`, optionally writing `bytes` (`head`) immediately after connect.
            "tcp.dial" => {
                let host = str_of(a, "host")?;
                if host.is_empty() {
                    return Err("missing host".into());
                }
                let port = port_of(a)?;
                let timeout = ms_of(a, "timeoutMs");
                let host_owned = host.to_string();
                let work = async move {
                    let mut stream = tcp_connect_keepalive(&host_owned, port).await?;
                    if let Some(head) = bytes.filter(|b| !b.is_empty()) {
                        stream.write_all(&head).await.map_err(err)?;
                    }
                    Ok::<tokio::net::TcpStream, String>(stream)
                };
                let stream = match timeout {
                    // timer: caller-specified deadline on outbound TCP connect + head write
                    Some(d) => tokio::time::timeout(d, work).await.map_err(|_| format!("tcp.dial timed out within {} ms", d.as_millis()))??,
                    None => work.await?,
                };
                let (read, write) = stream.into_split();
                let id = self.keep(Handle::tcp(read, write));
                Ok(Answer::json(json!({ "id": id })))
            }
            // Upgrade an accepted raw `Handle::Tcp` to a server-side TLS stream (with optional pre-read `bytes` and `timeoutMs`).
            // Note: once validated and removed from `handles`, cancelling an in-flight handshake consumes and closes the underlying TCP socket.
            "tls.upgrade_server" => {
                let old_id = id_of(a)?;
                let cert_pem = str_of(a, "certPem")?;
                let key_pem = str_of(a, "keyPem")?;
                let alpn = alpn_of(a);
                let timeout = ms_of(a, "timeoutMs");
                // Validate cert/key PEM before touching the handle table.
                let server_cfg = Arc::new(tls::server_tls_config(cert_pem, key_pem, alpn.as_deref())?);
                let removed = {
                    let mut handles = self.handles.lock().unwrap();
                    match handles.get(&old_id) {
                        Some(Handle::Tcp { read, write, close }) => {
                            if close.is_closed() {
                                return Err("tcp socket closed".into());
                            }
                            if Arc::strong_count(read) != 1 || Arc::strong_count(write) != 1 {
                                return Err("tcp socket is in use".into());
                            }
                        }
                        Some(_) => return Err("not a tcp connection".into()),
                        None => return Err(format!("no handle {old_id}")),
                    }
                    handles.remove(&old_id)
                };
                let Some(Handle::Tcp { read, write, .. }) = removed else {
                    return Err("not a tcp connection".into());
                };
                let read = Arc::try_unwrap(read).map_err(|_| "tcp socket is in use".to_string())?.into_inner();
                let write = Arc::try_unwrap(write).map_err(|_| "tcp socket is in use".to_string())?.into_inner();
                let upgraded = tls::upgrade_server_tls_with_config(read, write, bytes.unwrap_or_default(), server_cfg, timeout).await?;
                let id = self.keep(upgraded);
                Ok(Answer::json(json!({ "id": id })))
            }
            // Outbound client TLS dial to `(host, port)` with optional SNI, extra CA PEM, ALPN, timeout, and `head` bytes.
            "tls.connect" => {
                let host = str_of(a, "host")?;
                if host.is_empty() {
                    return Err("missing host".into());
                }
                let port = port_of(a)?;
                let sni = a.get("sni").and_then(Value::as_str).filter(|s| !s.is_empty());
                let ca_pem = a.get("caPem").and_then(Value::as_str).filter(|s| !s.is_empty());
                let alpn = alpn_of(a);
                let timeout = ms_of(a, "timeoutMs");
                let handle = tls::connect_client_tls(host, port, sni, ca_pem, alpn.as_deref(), timeout, bytes).await?;
                let id = self.keep(handle);
                Ok(Answer::json(json!({ "id": id })))
            }
            // The phone's own adb (adb.rs): paired once, its session held, a station's session on it read and written as a
            // socket is.
            "adb.pair" => {
                let port = a.get("port").and_then(Value::as_u64).ok_or("missing port")? as u16;
                self.adb.pair(port, str_of(a, "code")?).await?;
                Ok(Answer::json(json!({})))
            }
            "adb.hold" => {
                let port = a.get("port").and_then(Value::as_u64).ok_or("missing port")? as u16;
                self.adb.hold(port).await?;
                Ok(Answer::json(json!({})))
            }
            "adb.state" => Ok(Answer::json(json!({ "port": self.adb.state().await }))),
            "adb.open" => {
                let (read, write) = tokio::io::split(self.adb.open().await?);
                let id = self.keep(Handle::tcp(read, write));
                Ok(Answer::json(json!({ "id": id })))
            }
            // A socket to serve (station/mb's programs): a launcher's, handed down by its descriptor (`fd`, Unix), or one
            // bound here on 127.0.0.1 (`port`, 0 for any free one); its port said. Only this machine's: no other address.
            "tcp.listen" => {
                let listener = match a.get("fd").and_then(Value::as_i64) {
                    #[cfg(unix)]
                    Some(fd) => {
                        use std::os::fd::FromRawFd;
                        // SAFETY: the descriptor was handed to this process to serve, and is taken over once here.
                        let std = unsafe { std::net::TcpListener::from_raw_fd(fd as i32) };
                        std.set_nonblocking(true).map_err(err)?;
                        tokio::net::TcpListener::from_std(std).map_err(err)?
                    }
                    #[cfg(not(unix))]
                    Some(_) => return Err("a socket handed down by its descriptor is Unix's".into()),
                    None => {
                        let port = a.get("port").and_then(Value::as_u64).unwrap_or(0) as u16;
                        tokio::net::TcpListener::bind(("127.0.0.1", port)).await.map_err(err)?
                    }
                };
                let port = listener.local_addr().map_err(err)?.port();
                Ok(Answer::json(json!({ "id": self.keep(Handle::Listener { listener: Arc::new(Listener::Tcp(listener)), close: SocketClose::new() }), "port": port })))
            }
            // A Unix socket to serve at `path` (one there before is replaced).
            "unix.listen" => {
                #[cfg(unix)]
                {
                    let path = str_of(a, "path")?;
                    let mode = crate::fs_ops::optional_mode(a)?;
                    let listener = listen_unix(path, UNIX_LISTEN_BACKLOG, mode)?;
                    Ok(Answer::json(json!({ "id": self.keep(Handle::Listener { listener: Arc::new(Listener::Unix(listener)), close: SocketClose::new() }) })))
                }
                #[cfg(not(unix))]
                Err("Unix sockets are Unix's".into())
            }
            // Two sockets carried into each other, both ways, here (each side's end said to the other as it comes),
            // answered once both ways ended: what a station's program passes on whole, with no step of its own per piece.
            "tcp.pipe" => {
                let ids = a.get("ids").and_then(Value::as_array).ok_or("missing ids")?;
                let id = |i: usize| ids.get(i).and_then(Value::as_u64).ok_or_else(|| "missing ids".to_string());
                let (one, two) = (self.drop_handle(id(0)?), self.drop_handle(id(1)?));
                let (Some(Handle::Tcp { read: r1, write: w1, .. }), Some(Handle::Tcp { read: r2, write: w2, .. })) = (one, two) else {
                    return Err("not two tcp connections".into());
                };
                async fn carry(from: SocketRead, to: SocketWrite) -> u64 {
                    let (mut from, mut to) = (from.lock().await, to.lock().await);
                    let n = tokio::io::copy(&mut *from, &mut *to).await.unwrap_or(0);
                    let _ = to.shutdown().await;
                    n
                }
                let (there, back) = tokio::join!(carry(r1, w2), carry(r2, w1));
                Ok(Answer::json(json!({ "there": there, "back": back })))
            }
            // The next connection to a listening socket: a socket read and written as `tcp.open`'s are (`tcp.read`,
            // `tcp.write`, `tcp.end`, `tcp.close`), and who it came from.
            "tcp.accept" => {
                let Handle::Listener { listener, close } = self.handle(id_of(a)?)? else { return Err("not a listening socket".into()) };
                if close.is_closed() {
                    return Err("listener closed".into());
                }
                let (conn, peer) = tokio::select! {
                    biased;
                    _ = close.cancelled() => return Err("listener closed".into()),
                    accepted = listener.accept() => accepted?,
                };
                Ok(Answer::json(json!({ "id": self.keep(conn), "peer": peer })))
            }
            "tcp.read" => {
                let Handle::Tcp { read, close, .. } = self.handle(id_of(a)?)? else { return Err("not a tcp connection".into()) };
                if close.is_closed() {
                    return Err("tcp socket closed".into());
                }
                let mut guard = tokio::select! {
                    biased;
                    _ = close.cancelled() => return Err("tcp socket closed".into()),
                    guard = read.lock() => guard,
                };
                if close.is_closed() {
                    return Err("tcp socket closed".into());
                }
                let mut buf = vec![0u8; 64 * 1024];
                // (a pipe whose other side closed says so as broken, or as not connected where it was disconnected
                // (ERROR_PIPE_NOT_CONNECTED), not as an end: the same to a reader)
                let result = tokio::select! {
                    biased;
                    _ = close.cancelled() => return Err("tcp socket closed".into()),
                    r = guard.read(&mut buf) => r,
                };
                let n = match result {
                    Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe || (cfg!(windows) && e.raw_os_error() == Some(233)) => 0,
                    n => n.map_err(err)?,
                };
                if n == 0 {
                    return Ok(Answer::json(json!({ "end": true })));
                }
                buf.truncate(n);
                Ok(Answer::bytes(json!({}), buf))
            }
            "tcp.write" => {
                let Handle::Tcp { write, close, .. } = self.handle(id_of(a)?)? else { return Err("not a tcp connection".into()) };
                if close.is_closed() {
                    return Err("tcp socket closed".into());
                }
                let mut guard = tokio::select! {
                    biased;
                    _ = close.cancelled() => return Err("tcp socket closed".into()),
                    guard = write.lock() => guard,
                };
                if close.is_closed() {
                    return Err("tcp socket closed".into());
                }
                let payload = bytes.unwrap_or_default();
                tokio::select! {
                    biased;
                    _ = close.cancelled() => return Err("tcp socket closed".into()),
                    r = async {
                        guard.write_all(&payload).await?;
                        guard.flush().await
                    } => r.map_err(err)?,
                }
                Ok(Answer::json(json!({})))
            }
            "tcp.end" => {
                let Handle::Tcp { write, close, .. } = self.handle(id_of(a)?)? else { return Err("not a tcp connection".into()) };
                if close.is_closed() {
                    return Ok(Answer::json(json!({})));
                }
                let mut guard = tokio::select! {
                    biased;
                    _ = close.cancelled() => return Ok(Answer::json(json!({}))),
                    guard = write.lock() => guard,
                };
                if close.is_closed() {
                    return Ok(Answer::json(json!({})));
                }
                tokio::select! {
                    biased;
                    _ = close.cancelled() => {}
                    _ = guard.shutdown() => {}
                }
                Ok(Answer::json(json!({})))
            }
            // A Unix socket on this machine, read and written as `tcp.open`'s is.
            "unix.open" => {
                #[cfg(unix)]
                {
                    let (read, write) = tokio::net::UnixStream::connect(str_of(a, "path")?).await.map_err(err)?.into_split();
                    let id = self.keep(Handle::tcp(read, write));
                    Ok(Answer::json(json!({ "id": id })))
                }
                // Windows: a named pipe (`\\.\pipe\…`, a runner's: station/native/runner), its instances one connection
                // each. All taken a moment (the runner makes its next as it takes one): waited for, up to a bound.
                #[cfg(windows)]
                {
                    use tokio::net::windows::named_pipe::ClientOptions;
                    const ERROR_PIPE_BUSY: i32 = 231;
                    let path = str_of(a, "path")?;
                    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
                    let pipe = loop {
                        match ClientOptions::new().open(path) {
                            Ok(pipe) => break pipe,
                            // timer: a retry after a failure (every instance busy), up to a deadline
                            Err(e) if e.raw_os_error() == Some(ERROR_PIPE_BUSY) && tokio::time::Instant::now() < deadline => {
                                tokio::time::sleep(std::time::Duration::from_millis(20)).await
                            }
                            Err(e) => return Err(err(e)),
                        }
                    };
                    let (read, write) = tokio::io::split(pipe);
                    let id = self.keep(Handle::tcp(read, write));
                    Ok(Answer::json(json!({ "id": id })))
                }
                #[cfg(not(any(unix, windows)))]
                Err("no local sockets here".into())
            }
            "reset" => {
                // Requests already on the old pool keep it until they end.
                *self.http.lock().unwrap() = http_client(&self.tls, false);
                *self.http_follow.lock().unwrap() = http_client(&self.tls, true);
                self.entries.lock().unwrap().clear();
                Ok(Answer::json(json!({})))
            }
            other => Err(format!("no operation {other}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A told connection whose other side is gone before its shutdown (ENOTCONN on macOS) told it; any other failure
    /// of the shutdown is still said.
    #[test]
    fn a_shutdown_after_the_other_side_closed_is_no_failure() {
        use std::io::{Error, ErrorKind};
        assert_eq!(shut(Ok(())), Ok(()));
        assert_eq!(shut(Err(Error::from(ErrorKind::NotConnected))), Ok(()));
        #[cfg(unix)]
        assert_eq!(shut(Err(Error::from_raw_os_error(libc::ENOTCONN))), Ok(()));
        assert!(shut(Err(Error::from(ErrorKind::BrokenPipe))).is_err());
    }

    /// The Unix socket's other side reads what it waits for and closes at once (as the station's Node does): what was
    /// said reached it, and `tell_unix` says no failure, however the shutdown raced the close.
    #[cfg(unix)]
    #[tokio::test]
    async fn telling_a_socket_that_closes_at_once_is_no_failure() {
        let dir = std::env::temp_dir().join(format!("tell-unix-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("s.sock");
        let _ = std::fs::remove_file(&path);
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let reader = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut head = [0u8; 25];
            socket.read_exact(&mut head).await.unwrap();
            drop(socket);
            head
        });
        let bytes = [7u8; 25];
        assert_eq!(tell_unix(path.to_str().unwrap(), &bytes).await, Ok(()));
        assert_eq!(reader.await.unwrap(), bytes);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn listen_unix_rejects_too_long_or_nul_paths() {
        let too_long = "a".repeat(256);
        assert!(listen_unix(&too_long, UNIX_LISTEN_BACKLOG, None).is_err());
        assert!(listen_unix("/tmp/bad\0path.sock", UNIX_LISTEN_BACKLOG, None).is_err());
    }

    #[test]
    fn custom_ca_pem_and_proxy_client_build_succeeds() {
        use rustls::pki_types::{CertificateDer, pem::PemObject};
        const TEST_CA_PEM: &str = "\
-----BEGIN CERTIFICATE-----
MIIBjjCCATOgAwIBAgIUYHYbOqqZy+eYaN4rkS9jP4ZVUSAwCgYIKoZIzj0EAwIw
HDEaMBgGA1UEAwwRc3RpbGxmYWlsLXRlc3QtY2EwHhcNMjYxMTIxMDcxNDI5WhcN
MzYxMTE4MDcxNDI5WjAcMRowGAYDVQQDDBFzdGlsbGZhaWwtdGVzdC1jYTBZMBMG
ByqGSM49AgEGCCqGSM49AwEHA0IABBHI57/Y6OgmY0jrusLuT9YsWur9nhLWy3MC
yYt4aLNl+r2RcaD82cn6it76323wjsp0AAif/Z8e4TdGQXzFohCjUzBRMB0GA1Ud
DgQWBBSZ97ne31/pRCtnnorzMIezJVw1UDAfBgNVHSMEGDAWgBSZ97ne31/pRCtn
norzMIezJVw1UDAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQCD
dGDcGBkuuoBMO1MRy/K1ejVmX4CeIcQLmX1ri75nigIhAOljuAdmxyT6pTXrMsse
VuGw5P1LAmsKR9BKtrU6UfbY
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
not-valid-base64!!!
-----END CERTIFICATE-----
";
        let base_len = webpki_roots::TLS_SERVER_ROOTS.len();
        let mut roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
        for item in CertificateDer::pem_slice_iter(TEST_CA_PEM.as_bytes()) {
            if let Ok(cert) = item {
                let _ = roots.add(cert);
            }
        }
        assert_eq!(roots.len(), base_len + 1);

        let default_tls = tls::tls_config();
        assert!(custom_http_client(&default_tls, false, Some("http://user:pass@127.0.0.1:8080"), Some(TEST_CA_PEM), None).is_ok());
        assert!(custom_http_client(&default_tls, true, None, Some(TEST_CA_PEM), None).is_ok());
    }
}
