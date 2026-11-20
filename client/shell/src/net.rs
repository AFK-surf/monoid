//! HTTP/TLS/EntryResolver, WebSocket, local TCP/Unix/named-pipe sockets, listeners, and ADB socket operations.

use std::sync::Arc;

use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::Connector;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

use crate::{Answer, Done, Handle, Inner, err, id_of, str_of};

/// A socket's halves as the shell keeps them (`Handle::Tcp`).
pub(crate) type SocketRead = Arc<tokio::sync::Mutex<Box<dyn tokio::io::AsyncRead + Send + Unpin>>>;
pub(crate) type SocketWrite = Arc<tokio::sync::Mutex<Box<dyn tokio::io::AsyncWrite + Send + Unpin>>>;

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

/// How long `ws.open` may take to have its socket, its TLS and its Upgrade answered where its caller says nothing (as the
/// TypeScript station's presence socket waits for its open, station/src/cloud/presence.ts).
const WS_OPEN_WITHIN_MS: u64 = 20_000;

/// How long a frame may take to be written: a socket whose other side stopped reading (a sleep, a network gone without
/// a reset) fills the kernel's buffer, and its write would wait for good, holding its reads and pings with it.
const WS_WRITE_WITHIN: std::time::Duration = std::time::Duration::from_secs(15);

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
        fn halves<R, W>(read: R, write: W) -> Handle
        where
            R: tokio::io::AsyncRead + Send + Unpin + 'static,
            W: tokio::io::AsyncWrite + Send + Unpin + 'static,
        {
            Handle::Tcp { read: Arc::new(tokio::sync::Mutex::new(Box::new(read))), write: Arc::new(tokio::sync::Mutex::new(Box::new(write))) }
        }
        match self {
            Listener::Tcp(l) => {
                let (stream, peer) = l.accept().await.map_err(err)?;
                let _ = stream.set_nodelay(true);
                let (read, write) = stream.into_split();
                Ok((halves(read, write), peer.to_string()))
            }
            #[cfg(unix)]
            Listener::Unix(l) => {
                let (stream, _) = l.accept().await.map_err(err)?;
                let (read, write) = stream.into_split();
                Ok((halves(read, write), String::new()))
            }
        }
    }
}

pub(crate) fn tls_config() -> rustls::ClientConfig {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("ring supports the default protocol versions")
        .with_root_certificates(roots)
        .with_no_client_auth()
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

/// A TCP connection a WebSocket goes over, to `host` (a name or an address, in brackets where IPv6) and `port`: kept
/// alive (SO_KEEPALIVE, its first probe after 30 s idle as `http_builder`'s) and without Nagle, each address it
/// resolves to tried in turn.
async fn ws_tcp(host: &str, port: u16) -> Result<tokio::net::TcpStream, String> {
    let host = host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(host);
    let mut failed = None;
    for addr in tokio::net::lookup_host((host, port)).await.map_err(|e| format!("websocket: {e}"))? {
        let socket = if addr.is_ipv4() { tokio::net::TcpSocket::new_v4() } else { tokio::net::TcpSocket::new_v6() }.map_err(err)?;
        socket.set_keepalive(true).map_err(err)?;
        keep_idle(&socket);
        match socket.connect(addr).await {
            Ok(stream) => {
                stream.set_nodelay(true).map_err(err)?;
                return Ok(stream);
            }
            Err(e) => failed = Some(e),
        }
    }
    Err(match failed {
        Some(e) => format!("websocket: {e}"),
        None => format!("websocket: {host} has no address"),
    })
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
    Value::Array(response.headers().iter().map(|(k, v)| json!([k.as_str(), String::from_utf8_lossy(v.as_bytes())])).collect())
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

/// Create, bind, and listen on a Unix domain socket at `path` with an explicit `backlog` and `FD_CLOEXEC`.
#[cfg(unix)]
fn listen_unix(path: &str, backlog: libc::c_int) -> Result<tokio::net::UnixListener, String> {
    use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd};
    let path_bytes = path.as_bytes();
    if path_bytes.contains(&0) {
        return Err("unix socket path contains NUL".into());
    }
    // SAFETY: `sockaddr_un` is a plain C struct; zero-initializing leaves `sun_path` NUL-terminated.
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    if path_bytes.len() >= addr.sun_path.len() {
        return Err(format!("unix socket path too long ({} >= {})", path_bytes.len(), addr.sun_path.len()));
    }
    // SAFETY: `path_bytes.len() < addr.sun_path.len()` was checked above and both pointers are valid and non-overlapping.
    unsafe {
        std::ptr::copy_nonoverlapping(path_bytes.as_ptr(), addr.sun_path.as_mut_ptr().cast::<u8>(), path_bytes.len());
    }
    let addr_len = (std::mem::offset_of!(libc::sockaddr_un, sun_path) + path_bytes.len() + 1) as libc::socklen_t;

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
    let _ = std::fs::remove_file(path);
    // SAFETY: `addr` is a properly initialized `sockaddr_un` of length `addr_len`.
    if unsafe { libc::bind(owned.as_raw_fd(), (&addr as *const libc::sockaddr_un).cast::<libc::sockaddr>(), addr_len) } < 0 {
        return Err(err(std::io::Error::last_os_error()));
    }
    // SAFETY: `owned` is a bound AF_UNIX/SOCK_STREAM socket.
    if unsafe { libc::listen(owned.as_raw_fd(), backlog) } < 0 {
        return Err(err(std::io::Error::last_os_error()));
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
        let client = match entry_of(a)? {
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

    /// The answer to the request a call says, its head within `head_within` where given, and whether it is another
    /// URL's than the one asked (a redirect followed).
    async fn sent(&self, a: &Value, body: Option<Vec<u8>>, head_within: Option<std::time::Duration>) -> Result<(reqwest::Response, bool), String> {
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
        Ok((response, redirected))
    }

    async fn ws_open(self: &Arc<Self>, a: &Value) -> Done {
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
        let connector = Some(Connector::Rustls(self.tls.clone()));
        // `entry`: the TCP to a cloud entry, TLS and the Host the URL's own (as `fetch`'s, `EntryResolver`); else the
        // URL's own host and port. TLS where the URL is `wss:`, none where `ws:` (`client_async_tls_with_config`).
        let (host, port) = match entry_of(a)? {
            Some(entry) => entry,
            None => {
                let uri = request.uri();
                let host = uri.host().ok_or("websocket: the URL has no host")?.to_string();
                let port = uri.port_u16().unwrap_or(if uri.scheme_str() == Some("wss") { 443 } else { 80 });
                (host, port)
            }
        };
        // `timeoutMs`: how long the socket, its TLS and its Upgrade may take together; a handshake into a socket that
        // never answers held its caller for good (a presence socket that never opened, nor tried again).
        let within = ms_of(a, "timeoutMs").unwrap_or(std::time::Duration::from_millis(WS_OPEN_WITHIN_MS));
        let opening = async {
            let stream = ws_tcp(&host, port).await?;
            tokio_tungstenite::client_async_tls_with_config(request, stream, None, connector).await.map_err(ws_error)
        };
        // timer: a deadline on a WebSocket's opening (its TCP, TLS and Upgrade), given or 20 s
        let (socket, _) = tokio::time::timeout(within, opening).await.map_err(|_| format!("websocket: open timed out within {} ms", within.as_millis()))??;
        // `binary`: its binary frames given too (`{binary: true}` and their bytes); else they are let go, as a socket
        // that speaks only text takes `ws.next`'s other answers for its end.
        let binary = a.get("binary").and_then(Value::as_bool).unwrap_or(false);
        // `control`: incoming Ping/Pong frames given too (`{ping: true}` / `{pong: true}`), so callers that ping can
        // track liveness; else control frames stay internal to tungstenite without surfacing on `ws.next`.
        let control = a.get("control").and_then(Value::as_bool).unwrap_or(false);
        let (incoming_tx, incoming) = tokio::sync::mpsc::unbounded_channel();
        let (outgoing, mut outgoing_rx) = tokio::sync::mpsc::unbounded_channel::<WsFrame>();
        // One task owns the socket: reading is also what answers the server's pings; what is to be sent goes between.
        tokio::spawn(async move {
            let mut socket = socket;
            loop {
                tokio::select! {
                    message = socket.next() => match message {
                        Some(Ok(Message::Text(text))) => { let _ = incoming_tx.send(Ok(WsFrame::Text(text.as_str().to_owned()))); }
                        Some(Ok(Message::Binary(b))) if binary => { let _ = incoming_tx.send(Ok(WsFrame::Binary(b.to_vec()))); }
                        Some(Ok(Message::Ping(_))) if control => { let _ = incoming_tx.send(Ok(WsFrame::Ping)); }
                        Some(Ok(Message::Pong(_))) if control => { let _ = incoming_tx.send(Ok(WsFrame::Pong)); }
                        Some(Ok(Message::Close(frame))) => {
                            let _ = incoming_tx.send(Ok(WsFrame::Close(frame.map(|f| (u16::from(f.code), f.reason.to_string())))));
                            return;
                        }
                        Some(Err(WsError::ConnectionClosed | WsError::AlreadyClosed)) | None => return,
                        Some(Ok(_)) => {}
                        Some(Err(e)) => { let _ = incoming_tx.send(Err(ws_error(e))); return; }
                    },
                    text = outgoing_rx.recv() => match text {
                        Some(frame) => {
                            let m = match frame {
                                WsFrame::Text(t) => Message::text(t),
                                WsFrame::Binary(b) => Message::binary(b),
                                WsFrame::Ping => Message::Ping(Default::default()),
                                WsFrame::Pong => Message::Pong(Default::default()),
                                WsFrame::Close(_) => Message::Close(None),
                            };
                            // timer: a deadline on a frame's write, so a socket whose other side stopped reading ends
                            match tokio::time::timeout(WS_WRITE_WITHIN, socket.send(m)).await {
                                Ok(Ok(())) => {}
                                Ok(Err(e)) => { let _ = incoming_tx.send(Err(ws_error(e))); return; }
                                Err(_) => { let _ = incoming_tx.send(Err("websocket: write timed out".into())); return; }
                            }
                        }
                        // The handle went (ws.close): the socket is closed (bounded so a half-open TCP cannot hang close).
                        // timer: timeout bounding WebSocket close handshake on a dead or half-open connection
                        None => { let _ = tokio::time::timeout(std::time::Duration::from_secs(2), socket.close(None)).await; return; }
                    },
                }
            }
        });
        let id = self.keep(Handle::Ws { incoming: Arc::new(tokio::sync::Mutex::new(incoming)), outgoing });
        Ok(Answer::json(json!({ "id": id })))
    }

    pub(crate) async fn run_net(self: &Arc<Self>, op: &str, a: &Value, bytes: Option<Vec<u8>>) -> Done {
        match op {
            "fetch" => {
                // `timeoutMs`: how long the answer's head may take to come; `stallMs`: how long its body may stay
                // silent between two pieces (a whole-download deadline would cut a large one off on a slow network).
                // Neither given: as long as the caller waits (it cancels the call).
                let (head_within, stall_within) = (ms_of(a, "timeoutMs"), ms_of(a, "stallMs"));
                let (mut response, redirected) = self.sent(a, bytes, head_within).await?;
                let (status, headers) = (response.status().as_u16(), headers_of(&response));
                let mut body = Vec::new();
                loop {
                    let piece = match stall_within {
                        Some(d) => tokio::time::timeout(d, response.chunk()).await.map_err(|_| format!("nothing more came within {} ms", d.as_millis()))?,
                        None => response.chunk().await,
                    }
                    .map_err(http_error)?;
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
                let (status, headers) = (response.status().as_u16(), headers_of(&response));
                let id = self.keep(Handle::Response(Arc::new(tokio::sync::Mutex::new(response))));
                Ok(Answer::json(json!({ "status": status, "headers": headers, "id": id, "redirected": redirected })))
            }
            // `stallMs` (else `timeoutMs`): how long its next piece may take to come.
            "stream.read" => {
                let Handle::Response(response) = self.handle(id_of(a)?)? else { return Err("not a response".into()) };
                let mut response = response.lock().await;
                let chunk = match ms_of(a, "stallMs").or_else(|| ms_of(a, "timeoutMs")) {
                    // timer: a deadline on a stream's next piece, where its caller gives one
                    Some(d) => tokio::time::timeout(d, response.chunk()).await.map_err(|_| format!("nothing more came within {} ms", d.as_millis()))?,
                    None => response.chunk().await,
                }
                .map_err(http_error)?;
                Ok(match chunk {
                    Some(c) => Answer::bytes(json!({}), c.to_vec()),
                    None => Answer::json(json!({ "end": true })),
                })
            }
            "ws.open" => self.ws_open(a).await,
            "ws.next" => {
                let Handle::Ws { incoming, .. } = self.handle(id_of(a)?)? else { return Err("not a socket".into()) };
                let frame = incoming.lock().await.recv().await;
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
                let Handle::Ws { outgoing, .. } = self.handle(id_of(a)?)? else { return Err("not a socket".into()) };
                // Bytes given: a binary frame; else `text`.
                let frame = match bytes { Some(b) => WsFrame::Binary(b), None => WsFrame::Text(str_of(a, "text")?.to_string()) };
                outgoing.send(frame).map_err(|_| "the socket is closed".to_string())?;
                Ok(Answer::json(json!({})))
            }
            "ws.ping" => {
                let Handle::Ws { outgoing, .. } = self.handle(id_of(a)?)? else { return Err("not a socket".into()) };
                outgoing.send(WsFrame::Ping).map_err(|_| "the socket is closed".to_string())?;
                Ok(Answer::json(json!({})))
            }
            "tcp.open" => {
                let port = a.get("port").and_then(Value::as_u64).ok_or("missing port")? as u16;
                let stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.map_err(err)?;
                let (read, write) = stream.into_split();
                let id = self.keep(Handle::Tcp { read: Arc::new(tokio::sync::Mutex::new(Box::new(read))), write: Arc::new(tokio::sync::Mutex::new(Box::new(write))) });
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
                let id = self.keep(Handle::Tcp { read: Arc::new(tokio::sync::Mutex::new(Box::new(read))), write: Arc::new(tokio::sync::Mutex::new(Box::new(write))) });
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
                Ok(Answer::json(json!({ "id": self.keep(Handle::Listener(Arc::new(Listener::Tcp(listener)))), "port": port })))
            }
            // A Unix socket to serve at `path` (one there before is replaced).
            "unix.listen" => {
                #[cfg(unix)]
                {
                    let path = str_of(a, "path")?;
                    let listener = listen_unix(path, UNIX_LISTEN_BACKLOG)?;
                    Ok(Answer::json(json!({ "id": self.keep(Handle::Listener(Arc::new(Listener::Unix(listener)))) })))
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
                let (Some(Handle::Tcp { read: r1, write: w1 }), Some(Handle::Tcp { read: r2, write: w2 })) = (one, two) else {
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
                let Handle::Listener(listener) = self.handle(id_of(a)?)? else { return Err("not a listening socket".into()) };
                let (conn, peer) = listener.accept().await?;
                Ok(Answer::json(json!({ "id": self.keep(conn), "peer": peer })))
            }
            "tcp.read" => {
                let Handle::Tcp { read, .. } = self.handle(id_of(a)?)? else { return Err("not a tcp connection".into()) };
                let mut buf = vec![0u8; 64 * 1024];
                // (a pipe whose other side closed says so as broken, or as not connected where it was disconnected
                // (ERROR_PIPE_NOT_CONNECTED), not as an end: the same to a reader)
                let n = match read.lock().await.read(&mut buf).await {
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
                let Handle::Tcp { write, .. } = self.handle(id_of(a)?)? else { return Err("not a tcp connection".into()) };
                write.lock().await.write_all(&bytes.unwrap_or_default()).await.map_err(err)?;
                Ok(Answer::json(json!({})))
            }
            "tcp.end" => {
                let Handle::Tcp { write, .. } = self.handle(id_of(a)?)? else { return Err("not a tcp connection".into()) };
                let _ = write.lock().await.shutdown().await;
                Ok(Answer::json(json!({})))
            }
            // A Unix socket on this machine, read and written as `tcp.open`'s is.
            "unix.open" => {
                #[cfg(unix)]
                {
                    let (read, write) = tokio::net::UnixStream::connect(str_of(a, "path")?).await.map_err(err)?.into_split();
                    let id = self.keep(Handle::Tcp { read: Arc::new(tokio::sync::Mutex::new(Box::new(read))), write: Arc::new(tokio::sync::Mutex::new(Box::new(write))) });
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
                    let id = self.keep(Handle::Tcp { read: Arc::new(tokio::sync::Mutex::new(Box::new(read))), write: Arc::new(tokio::sync::Mutex::new(Box::new(write))) });
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
        assert!(listen_unix(&too_long, UNIX_LISTEN_BACKLOG).is_err());
        assert!(listen_unix("/tmp/bad\0path.sock", UNIX_LISTEN_BACKLOG).is_err());
    }
}
