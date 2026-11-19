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

/// A WebSocket frame as `ws.next` gives it and `ws.send` takes it.
pub(crate) enum WsFrame {
    Text(String),
    Binary(Vec<u8>),
}

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
pub(crate) fn http_client(tls: &rustls::ClientConfig) -> reqwest::Client {
    http_builder(tls).build().expect("reqwest client")
}

fn http_builder(tls: &rustls::ClientConfig) -> reqwest::ClientBuilder {
    use std::time::Duration;
    reqwest::Client::builder()
        .tls_backend_preconfigured(tls.clone())
        .connect_timeout(Duration::from_secs(15))
        .pool_idle_timeout(Duration::from_secs(60))
        .tcp_keepalive(Duration::from_secs(30))
        .http2_keep_alive_interval(Duration::from_secs(20))
        .http2_keep_alive_timeout(Duration::from_secs(5))
        .http2_keep_alive_while_idle(true)
        .redirect(reqwest::redirect::Policy::none())
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

fn ws_error(error: WsError) -> String {
    match error {
        WsError::Http(response) => format!("websocket refused ({})", response.status().as_u16()),
        error => format!("websocket: {error}"),
    }
}

fn headers_of(response: &reqwest::Response) -> Value {
    Value::Array(response.headers().iter().map(|(k, v)| json!([k.as_str(), String::from_utf8_lossy(v.as_bytes())])).collect())
}

/// A connection to the Unix socket at `path` that a stream is carried into, `head` written to it first (what tells the
/// other side which stream it is); an error where nothing listens there or it takes nothing.
pub(crate) async fn open_unix(path: &str, head: &[u8]) -> Result<(SocketRead, SocketWrite), String> {
    #[cfg(unix)]
    {
        let socket = tokio::net::UnixStream::connect(path).await.map_err(err)?;
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
        let mut socket = tokio::net::UnixStream::connect(path).await.map_err(err)?;
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
    fn request(&self, a: &Value, body: Option<Vec<u8>>) -> Result<reqwest::RequestBuilder, String> {
        let method = reqwest::Method::from_bytes(str_of(a, "method")?.as_bytes()).map_err(err)?;
        let client = match entry_of(a)? {
            None => self.http.lock().unwrap().clone(),
            Some((host, port)) => {
                let mut entries = self.entries.lock().unwrap();
                match entries.get(&(host.clone(), port)) {
                    Some(c) => c.clone(),
                    None => {
                        let c = http_builder(&self.tls).dns_resolver(Arc::new(EntryResolver { host: host.clone(), port })).build().map_err(http_error)?;
                        entries.insert((host, port), c.clone());
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
        // `entry`: the TCP to a cloud entry, TLS and the Host the URL's own (as `fetch`'s, `EntryResolver`).
        let (socket, _) = match entry_of(a)? {
            None => tokio_tungstenite::connect_async_tls_with_config(request, None, false, connector).await.map_err(ws_error)?,
            Some((host, port)) => {
                let stream = tokio::net::TcpStream::connect((host.as_str(), port)).await.map_err(err)?;
                stream.set_nodelay(true).map_err(err)?;
                tokio_tungstenite::client_async_tls_with_config(request, stream, None, connector).await.map_err(ws_error)?
            }
        };
        // `binary`: its binary frames given too (`{binary: true}` and their bytes); else they are let go, as a socket
        // that speaks only text takes `ws.next`'s other answers for its end.
        let binary = a.get("binary").and_then(Value::as_bool).unwrap_or(false);
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
                        Some(Ok(Message::Close(_))) | Some(Err(WsError::ConnectionClosed | WsError::AlreadyClosed)) | None => return,
                        Some(Ok(_)) => {}
                        Some(Err(e)) => { let _ = incoming_tx.send(Err(ws_error(e))); return; }
                    },
                    text = outgoing_rx.recv() => match text {
                        Some(frame) => { let m = match frame { WsFrame::Text(t) => Message::text(t), WsFrame::Binary(b) => Message::binary(b) }; if let Err(e) = socket.send(m).await { let _ = incoming_tx.send(Err(ws_error(e))); return; } }
                        // The handle went (ws.close): the socket is closed.
                        None => { let _ = socket.close(None).await; return; }
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
                let within = |key: &str| a.get(key).and_then(Value::as_f64).filter(|ms| *ms > 0.0).map(|ms| std::time::Duration::from_millis(ms as u64));
                let (head_within, stall_within) = (within("timeoutMs"), within("stallMs"));
                let sent = self.request(a, bytes)?.send();
                let mut response = match head_within {
                    Some(d) => tokio::time::timeout(d, sent).await.map_err(|_| format!("no answer within {} ms", d.as_millis()))?,
                    None => sent.await,
                }
                .map_err(http_error)?;
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
                Ok(Answer::bytes(json!({ "status": status, "headers": headers }), body))
            }
            "stream.open" => {
                let response = self.request(a, bytes)?.send().await.map_err(http_error)?;
                let (status, headers) = (response.status().as_u16(), headers_of(&response));
                let id = self.keep(Handle::Response(Arc::new(tokio::sync::Mutex::new(response))));
                Ok(Answer::json(json!({ "status": status, "headers": headers, "id": id })))
            }
            "stream.read" => {
                let Handle::Response(response) = self.handle(id_of(a)?)? else { return Err("not a response".into()) };
                let chunk = response.lock().await.chunk().await.map_err(http_error)?;
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
                    Some(Err(e)) => Err(e),
                    None => Ok(Answer::json(json!({ "end": true }))),
                }
            }
            "ws.send" => {
                let Handle::Ws { outgoing, .. } = self.handle(id_of(a)?)? else { return Err("not a socket".into()) };
                // Bytes given: a binary frame; else `text`.
                let frame = match bytes { Some(b) => WsFrame::Binary(b), None => WsFrame::Text(str_of(a, "text")?.to_string()) };
                outgoing.send(frame).map_err(|_| "the socket is closed".to_string())?;
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
                    let _ = std::fs::remove_file(path);
                    let listener = tokio::net::UnixListener::bind(path).map_err(err)?;
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
                *self.http.lock().unwrap() = http_client(&self.tls);
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
}
