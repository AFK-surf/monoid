use std::ffi::c_void;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, Mutex as StdMutex};

use futures::SinkExt;
use iroh::endpoint::presets::Minimal;
use iroh::{Endpoint, RelayMode, SecretKey};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::Message;

use crate::iroh_ops::endpoint_addr;
use crate::istream::{PIPE_END, PIPE_FAILED};
use crate::sql::DB_WAIT;
use crate::{Handle, Shell, counted, stats_json};

/// The answers of every test's shells, each told by its test (the shell's `ctx`, the test's thread's tag) and its id:
/// ids alike in tests run at once were taken by either (94_001, a dial's test's and a listening socket's, 2026-11-12).
static ANSWERS: StdMutex<Vec<(usize, u64, String, String, Option<Vec<u8>>)>> = StdMutex::new(Vec::new());
static ANSWERED: Condvar = Condvar::new();
static TAGS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);
thread_local! {
    static TAG: usize = TAGS.fetch_add(1, Ordering::Relaxed);
}

/// What a shell started on this test's thread is given to say whose its answers are.
fn ctx() -> *mut c_void {
    TAG.with(|t| *t as *mut c_void)
}

extern "C" fn complete(ctx: *mut c_void, id: u64, json: *const u8, jl: usize, e: *const u8, el: usize, b: *const u8, bl: usize, has: u8) {
    let s = |p: *const u8, l: usize| if l == 0 { String::new() } else { String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(p, l) }).into_owned() };
    let bytes = (has != 0).then(|| if bl == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(b, bl) }.to_vec() });
    ANSWERS.lock().unwrap().push((ctx as usize, id, s(json, jl), s(e, el), bytes));
    ANSWERED.notify_all();
}

/// A directory of its own under the system's temporary one, removed when dropped (after the shell started in it,
/// made after it). Not tempfile's: a dev-dependency gives the tests' build other features of the crates below it, so
/// that build compiled iroh and the rest a second time (the Windows shell's prebuild, 2026-10-23).
struct TempDir(PathBuf);
impl TempDir {
    fn new() -> Self {
        static N: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!("stillfail-shell-test-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }
    fn path(&self) -> &std::path::Path {
        &self.0
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The answer to `id`, once it comes (however long that takes).
fn answer(id: u64) -> (String, String, Option<Vec<u8>>) {
    let tag = TAG.with(|t| *t);
    let mut answers = ANSWERS.lock().unwrap();
    loop {
        if let Some(i) = answers.iter().position(|a| a.0 == tag && a.1 == id) {
            let (_, _, j, e, b) = answers.remove(i);
            return (j, e, b);
        }
        answers = ANSWERED.wait(answers).unwrap();
    }
}

/// A named pipe (a runner's on Windows, station/native/runner) opened as `unix.open`, read and written as a socket:
/// what one side wrote is read by the other, and the server's closing is the client's end.
#[cfg(windows)]
#[test]
fn opens_a_named_pipe_as_a_socket() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::windows::named_pipe::ServerOptions;
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().join("shell"), complete, ctx()).unwrap();
    let call = |id: u64, op: &str, a: Value, bytes: Option<Vec<u8>>| {
        shell.call(id, op.into(), a.to_string().as_bytes(), bytes);
        let (json, error, bytes) = answer(id);
        assert_eq!(error, "", "{op}");
        (serde_json::from_str::<Value>(&json).unwrap(), bytes)
    };
    let path = format!(r"\\.\pipe\stillfail-shell-test-{}", std::process::id());
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let server = rt.block_on(async { ServerOptions::new().first_pipe_instance(true).create(&path).unwrap() });
    let served = std::thread::spawn(move || {
        rt.block_on(async move {
            let mut server = server;
            server.connect().await.unwrap();
            let mut got = [0u8; 4];
            server.read_exact(&mut got).await.unwrap();
            assert_eq!(&got, b"ping");
            server.write_all(b"pong").await.unwrap();
            server.flush().await.unwrap();
            // (read up to what the client sends last, then closed: the client reads its end)
            let mut last = [0u8; 5];
            server.read_exact(&mut last).await.unwrap();
            assert_eq!(&last, b"leave");
            server.disconnect().unwrap();
        })
    });
    let (opened, _) = call(97_001, "unix.open", json!({ "path": path }), None);
    let conn = opened["id"].as_u64().unwrap();
    call(97_002, "tcp.write", json!({ "id": conn }), Some(b"ping".to_vec()));
    let (_, got) = call(97_003, "tcp.read", json!({ "id": conn }), None);
    assert_eq!(got.unwrap(), b"pong");
    call(97_004, "tcp.write", json!({ "id": conn }), Some(b"leave".to_vec()));
    let (end, _) = call(97_005, "tcp.read", json!({ "id": conn }), None);
    assert_eq!(end, json!({ "end": true }));
    call(97_006, "tcp.close", json!({ "id": conn }), None);
    served.join().unwrap();
}

#[test]
fn serves_a_listening_socket_bound_here_handed_down_or_unix() {
    use std::io::{Read, Write};
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().join("shell"), complete, ctx()).unwrap();
    let call = |id: u64, op: &str, a: Value, bytes: Option<Vec<u8>>| {
        shell.call(id, op.into(), a.to_string().as_bytes(), bytes);
        let (json, error, bytes) = answer(id);
        assert_eq!(error, "", "{op}");
        (serde_json::from_str::<Value>(&json).unwrap(), bytes)
    };
    // Each socket: a connection taken, what it sent read, an answer written, the end said.
    let serve = |base: u64, listener: u64, connect: &dyn Fn() -> Box<dyn ReadWrite>| {
        let mut client = connect();
        client.write_all(b"ping").unwrap();
        let (accepted, _) = call(base, "tcp.accept", json!({ "id": listener }), None);
        let conn = accepted["id"].as_u64().unwrap();
        let (_, got) = call(base + 1, "tcp.read", json!({ "id": conn }), None);
        assert_eq!(got.unwrap(), b"ping");
        call(base + 2, "tcp.write", json!({ "id": conn }), Some(b"pong".to_vec()));
        call(base + 3, "tcp.end", json!({ "id": conn }), None);
        let mut back = Vec::new();
        client.read_to_end(&mut back).unwrap();
        assert_eq!(back, b"pong");
    };
    // bound here, on 127.0.0.1, its port said
    let (bound, _) = call(96_001, "tcp.listen", json!({ "port": 0 }), None);
    let port = bound["port"].as_u64().unwrap() as u16;
    serve(96_010, bound["id"].as_u64().unwrap(), &|| Box::new(std::net::TcpStream::connect(("127.0.0.1", port)).unwrap()));
    #[cfg(unix)]
    {
        use std::os::fd::IntoRawFd;
        // one a launcher bound and handed down by its descriptor
        let launcher = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = launcher.local_addr().unwrap().port();
        let (handed, _) = call(96_020, "tcp.listen", json!({ "fd": launcher.into_raw_fd() }), None);
        assert_eq!(handed["port"].as_u64().unwrap() as u16, port);
        serve(96_030, handed["id"].as_u64().unwrap(), &|| Box::new(std::net::TcpStream::connect(("127.0.0.1", port)).unwrap()));
        // a Unix socket, by its path (one left there before replaced)
        let path = dir.path().join("front.sock");
        std::fs::write(&path, "left").unwrap();
        let (unix, _) = call(96_040, "unix.listen", json!({ "path": path.display().to_string() }), None);
        let p = path.clone();
        serve(96_050, unix["id"].as_u64().unwrap(), &move || Box::new(std::os::unix::net::UnixStream::connect(&p).unwrap()));
    }
}

#[test]
fn pipes_two_sockets_into_each_other() {
    use std::io::{Read, Write};
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().join("shell"), complete, ctx()).unwrap();
    let call = |id: u64, op: &str, a: Value| {
        shell.call(id, op.into(), a.to_string().as_bytes(), None);
        let (json, error, _) = answer(id);
        assert_eq!(error, "", "{op}");
        serde_json::from_str::<Value>(&json).unwrap()
    };
    let front = call(95_001, "tcp.listen", json!({ "port": 0 }));
    let target = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let mut client = std::net::TcpStream::connect(("127.0.0.1", front["port"].as_u64().unwrap() as u16)).unwrap();
    let accepted = call(95_002, "tcp.accept", json!({ "id": front["id"] }));
    let opened = call(95_003, "tcp.open", json!({ "port": target.local_addr().unwrap().port() }));
    let (mut server, _) = target.accept().unwrap();
    shell.call(95_004, "tcp.pipe".into(), json!({ "ids": [accepted["id"], opened["id"]] }).to_string().as_bytes(), None);
    client.write_all(b"hello").unwrap();
    client.shutdown(std::net::Shutdown::Write).unwrap();
    let mut got = Vec::new();
    server.read_to_end(&mut got).unwrap();
    assert_eq!(got, b"hello", "carried there, and its end");
    server.write_all(b"back").unwrap();
    drop(server);
    let mut back = Vec::new();
    client.read_to_end(&mut back).unwrap();
    assert_eq!(back, b"back", "carried back, and its end");
    let (json, error, _) = answer(95_004);
    assert_eq!(error, "");
    assert_eq!(serde_json::from_str::<Value>(&json).unwrap(), json!({ "there": 5, "back": 4 }));
    // the sockets are the pipe's now: not the shell's to read
    shell.call(95_005, "tcp.read".into(), json!({ "id": accepted["id"] }).to_string().as_bytes(), None);
    assert_ne!(answer(95_005).1, "");
}

trait ReadWrite: std::io::Read + std::io::Write {}
impl<T: std::io::Read + std::io::Write> ReadWrite for T {}

#[test]
fn cancelling_a_fetch_closes_the_socket_while_headers_or_body_are_stalled() {
    for (id, body) in [(93_001, false), (93_002, true)] {
        let dir = TempDir::new();
        let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
        let (listener, addr) = shell.runtime.block_on(async {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            (listener, addr)
        });
        let (ready, arrived) = tokio::sync::oneshot::channel();
        let closed = shell.runtime.spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                request.push(socket.read_u8().await.unwrap());
            }
            if body {
                socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\na").await.unwrap();
            }
            ready.send(()).unwrap();
            // No more response bytes arrive. Cancelling the fetch must drop the actual HTTP exchange.
            socket.read_u8().await
        });
        shell.call(id, "fetch".into(), serde_json::to_vec(&json!({ "url": format!("http://{addr}/credential"), "method": "GET", "headers": [] })).unwrap().as_slice(), None);
        shell.runtime.block_on(arrived).unwrap();
        let cancel = || serde_json::from_slice::<Value>(&shell.call_sync("fetch.cancel", serde_json::to_vec(&json!({ "id": id })).unwrap().as_slice())).unwrap();
        assert_eq!(cancel(), json!({ "value": true }));
        assert_eq!(answer(id).1, "cancelled");
        assert!(shell.runtime.block_on(closed).unwrap().is_err());
        assert_eq!(cancel(), json!({ "value": false }));
    }
}

/// A fetch given `timeoutMs` ends with an error once its answer's head has not come by then, and one given `stallMs`
/// once its body stayed silent that long: a server that never answers holds nobody's reading for good (the station's
/// program's updates, whose deadlines the TypeScript's `AbortSignal`s were).
#[test]
fn a_fetch_ends_when_its_answer_does_not_come_in_time() {
    for (id, body) in [(93_101, false), (93_102, true)] {
        let dir = TempDir::new();
        let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
        let (listener, addr) = shell.runtime.block_on(async {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            (listener, addr)
        });
        shell.runtime.spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                request.push(socket.read_u8().await.unwrap());
            }
            if body {
                socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\na").await.unwrap();
            }
            // Nothing more comes, and the socket stays open.
            let _ = socket.read_u8().await;
        });
        let within = if body { json!({ "stallMs": 200 }) } else { json!({ "timeoutMs": 200 }) };
        let mut args = json!({ "url": format!("http://{addr}/feed"), "method": "GET", "headers": [] });
        args.as_object_mut().unwrap().extend(within.as_object().unwrap().clone());
        shell.call(id, "fetch".into(), serde_json::to_vec(&args).unwrap().as_slice(), None);
        let (_, error, _) = answer(id);
        let said = if body { "nothing more came within 200 ms" } else { "no answer within 200 ms" };
        assert_eq!(error, said);
    }
}

/// A request through a cloud entry (`entry`): its TCP goes to the entry, its Host (and TLS, where it is https) stays the
/// URL's; a WebSocket's too, with the headers it is given.
#[test]
fn a_request_and_a_websocket_go_through_a_cloud_entry() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let (listener, addr) = shell.runtime.block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        (listener, addr)
    });
    let entry = json!({ "host": "127.0.0.1", "port": addr.port() });
    let served = shell.runtime.spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            request.push(socket.read_u8().await.unwrap());
        }
        socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok").await.unwrap();
        let (socket, _) = listener.accept().await.unwrap();
        let heard = Arc::new(Mutex::new(Vec::new()));
        let kept = heard.clone();
        let mut ws = tokio_tungstenite::accept_hdr_async(socket, move |req: &tokio_tungstenite::tungstenite::handshake::server::Request, res| {
            for (k, v) in req.headers() {
                kept.lock().unwrap().push(format!("{k}: {}", v.to_str().unwrap()));
            }
            Ok(res)
        })
        .await
        .unwrap();
        ws.send(Message::text("hi")).await.unwrap();
        let heard = heard.lock().unwrap().clone();
        (String::from_utf8(request).unwrap().to_lowercase(), heard)
    });
    shell.call(95_001, "fetch".into(), serde_json::to_vec(&json!({ "url": "http://cloud.invalid/v1/me", "method": "GET", "headers": [], "entry": entry })).unwrap().as_slice(), None);
    let (head, error, body) = answer(95_001);
    assert_eq!(error, "");
    assert_eq!(serde_json::from_str::<Value>(&head).unwrap()["status"], json!(200));
    assert_eq!(body.unwrap(), b"ok");
    shell.call(95_002, "ws.open".into(), serde_json::to_vec(&json!({ "url": "ws://cloud.invalid/v1/presence", "headers": [["x-stillfail-station", "s1"]], "entry": entry })).unwrap().as_slice(), None);
    let (opened, error, _) = answer(95_002);
    assert_eq!(error, "");
    assert!(serde_json::from_str::<Value>(&opened).unwrap()["id"].is_u64());
    let (request, heard) = shell.runtime.block_on(served).unwrap();
    assert!(request.starts_with("get /v1/me http/1.1\r\n") && request.contains("host: cloud.invalid\r\n"), "{request}");
    assert!(heard.contains(&"host: cloud.invalid".to_string()) && heard.contains(&"x-stillfail-station: s1".to_string()), "{heard:?}");
    // an entry that is none is refused before anything is dialed
    shell.call(95_003, "fetch".into(), serde_json::to_vec(&json!({ "url": "http://cloud.invalid/", "method": "GET", "headers": [], "entry": { "host": "", "port": 1 } })).unwrap().as_slice(), None);
    assert_eq!(answer(95_003).1, "an entry has a host");
}

/// A dial the core gave up (its opening ended: client/core-ts mesh.ts) is cancelled here as a fetch is: its
/// handshake dropped, which closes it (what that stops, the Initial sent again for ten minutes, the station addon's
/// `a_dial_given_up_sends_no_more` counts), and the endpoint closes at once.
#[test]
fn cancelling_a_dial_drops_its_handshake() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    // A station that never answers: a socket that takes what comes.
    let quiet = shell.runtime.block_on(tokio::net::UdpSocket::bind("127.0.0.1:0")).unwrap();
    shell.call(94_001, "iroh.bind".into(), serde_json::to_vec(&json!({ "relayUrls": [], "alpns": [] })).unwrap().as_slice(), Some(vec![3; 32]));
    let endpoint = serde_json::from_str::<Value>(&answer(94_001).0).unwrap()["id"].clone();
    let station = json!({ "id": hex::encode(SecretKey::from_bytes(&[7; 32]).public().as_bytes()), "ips": [quiet.local_addr().unwrap().to_string()] });
    shell.call(94_002, "iroh.connect".into(), serde_json::to_vec(&json!({ "id": endpoint, "addr": station })).unwrap().as_slice(), Some(b"test".to_vec()));
    // Its Initial came: the dial is under way.
    shell.runtime.block_on(quiet.recv(&mut [0u8; 2048])).unwrap();
    let cancel = || serde_json::from_slice::<Value>(&shell.call_sync("fetch.cancel", serde_json::to_vec(&json!({ "id": 94_002 })).unwrap().as_slice())).unwrap();
    assert_eq!(cancel(), json!({ "value": true }));
    assert_eq!(answer(94_002).1, "cancelled");
    assert_eq!(cancel(), json!({ "value": false }));
    shell.call(94_003, "iroh.close".into(), serde_json::to_vec(&json!({ "id": endpoint })).unwrap().as_slice(), None);
    assert_eq!(answer(94_003).1, "");
}

/// A DSCP out of range fails the bind, said, before anything is bound or marked (`mark_with_dscp`).
#[test]
fn a_dscp_out_of_range_fails_the_bind() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    for (id, dscp) in [(96_001, json!(0)), (96_002, json!(64)), (96_003, json!(-1)), (96_004, json!(4.5)), (96_005, json!("43"))] {
        shell.call(id, "iroh.bind".into(), serde_json::to_vec(&json!({ "relayUrls": [], "alpns": [], "dscp": dscp })).unwrap().as_slice(), Some(vec![3; 32]));
        let (_, error, _) = answer(id);
        assert!(error.contains("must be 1 to 63"), "{dscp}: {error}");
    }
}

#[test]
fn keeps_files_and_records_as_client_ffi_does() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    shell.call(1, "storage.set".into(), br#"{"key":"device"}"#, Some(vec![1, 2, 3]));
    assert_eq!(answer(1).1, "");
    assert!(dir.path().join("device").exists());
    // A value kept is its user's alone, whatever the process's umask (0644 by the umask of most, before): made
    // so, and one written over a file from before, or over a partial one a crash left, is made so too.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = |name: &str| std::fs::metadata(dir.path().join(name)).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode("device"), 0o600);
        std::fs::set_permissions(dir.path().join("device"), std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::write(dir.path().join("device.partial"), b"left").unwrap();
        std::fs::set_permissions(dir.path().join("device.partial"), std::fs::Permissions::from_mode(0o644)).unwrap();
        shell.call(1, "storage.set".into(), br#"{"key":"device"}"#, Some(vec![1, 2, 3]));
        assert_eq!(answer(1).1, "");
        assert_eq!(mode("device"), 0o600);
        assert!(!dir.path().join("device.partial").exists());
        // A partial one left that is a link to somewhere is taken away, never written through: what it led to
        // is as it was, and the value is a file of its own.
        std::fs::write(dir.path().join("elsewhere"), b"another's").unwrap();
        std::os::unix::fs::symlink(dir.path().join("elsewhere"), dir.path().join("device.partial")).unwrap();
        shell.call(1, "storage.set".into(), br#"{"key":"device"}"#, Some(vec![4, 5]));
        assert_eq!(answer(1).1, "");
        assert_eq!(std::fs::read(dir.path().join("elsewhere")).unwrap(), b"another's");
        assert_eq!(std::fs::read(dir.path().join("device")).unwrap(), vec![4, 5]);
        assert!(std::fs::symlink_metadata(dir.path().join("device")).unwrap().file_type().is_file());
        assert_eq!(mode("device"), 0o600);
        shell.call(1, "storage.set".into(), br#"{"key":"device"}"#, Some(vec![1, 2, 3]));
        assert_eq!(answer(1).1, "");
    }
    shell.call(2, "storage.get".into(), br#"{"key":"device"}"#, None);
    assert_eq!(answer(2).2, Some(vec![1, 2, 3]));
    shell.call(3, "storage.get".into(), br#"{"key":"a/b"}"#, None);
    assert_eq!(answer(3).0, r#"{"none":true}"#);
    // Where a value is kept, read there by the app itself: none while it is not.
    let path = |key: &str| -> Value { serde_json::from_slice::<Value>(&shell.call_sync("storage.path", format!(r#"{{"key":"{key}"}}"#).as_bytes())).unwrap()["value"].clone() };
    assert_eq!(path("device"), json!(dir.path().join("device").to_string_lossy()));
    assert_eq!(path("a/b"), Value::Null);
    // The former records store, as client/ffi wrote it: read only.
    {
        let conn = rusqlite::Connection::open(dir.path().join("core.db")).unwrap();
        conn.execute_batch("CREATE TABLE records (tbl TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY (tbl, key)) WITHOUT ROWID;").unwrap();
        for (k, v) in [("s\u{1}a", b"1".to_vec()), ("s\u{1}b", b"22".to_vec()), ("t\u{1}a", Vec::new())] {
            conn.execute("INSERT INTO records (tbl, key, value) VALUES ('row', ?1, ?2)", rusqlite::params![k, v]).unwrap();
        }
    }
    shell.call(5, "db.read".into(), "{\"table\":\"row\",\"from\":\"s\\u0001\",\"to\":\"s\\u0002\"}".as_bytes(), None);
    let (json, _, bytes) = answer(5);
    assert_eq!(json, "{\"keys\":[\"s\\u0001a\",\"s\\u0001b\"],\"sizes\":[1,2]}");
    assert_eq!(bytes, Some(b"122".to_vec()));
    assert!(dir.path().join("core.db").exists());
    let out = shell.call_sync("conn.remoteId", br#"{"id":999}"#);
    assert_eq!(String::from_utf8(out).unwrap(), r#"{"error":"no handle 999"}"#);
}

#[test]
fn takes_zstd_apart_a_piece_at_a_time() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    // A reply as a station compresses it (two frames, as a stream flushed twice sends them, and a JSON reply),
    // given in pieces cut anywhere.
    let first: Vec<u8> = (0..40_000).map(|i| format!("{{\"seq\":{i}}},")).collect::<String>().into_bytes();
    let second = b"{\"entries\":[]}".to_vec();
    let mut packed = zstd::stream::encode_all(&first[..], 3).unwrap();
    packed.extend(zstd::stream::encode_all(&second[..], 9).unwrap());
    shell.call(9001, "zstd.open".into(), b"{}", None);
    let id = serde_json::from_str::<Value>(&answer(9001).0).unwrap()["id"].as_u64().unwrap();
    let mut made = Vec::new();
    let mut call = 9002;
    let mut whole = Vec::new();
    for piece in packed.chunks(7_001) {
        shell.call(call, "zstd.push".into(), format!(r#"{{"id":{id}}}"#).as_bytes(), Some(piece.to_vec()));
        let (json, error, bytes) = answer(call);
        assert_eq!(error, "");
        made.extend(bytes.unwrap_or_default());
        whole.push(serde_json::from_str::<Value>(&json).unwrap()["whole"] == json!(true));
        call += 1;
    }
    let mut both = first.clone();
    both.extend(&second);
    assert_eq!(made, both);
    // mid frame, not whole; at the end, whole
    assert!(!whole[0]);
    assert!(whole[whole.len() - 1]);
    shell.call(call, "zstd.close".into(), format!(r#"{{"id":{id}}}"#).as_bytes(), None);
    assert_eq!(answer(call).1, "");
    // gone once closed
    shell.call(call + 1, "zstd.push".into(), format!(r#"{{"id":{id}}}"#).as_bytes(), Some(vec![0]));
    assert_eq!(answer(call + 1).1, format!("no handle {id}"));
    // cut short: what came is given, and it is not whole
    let cut = zstd::stream::encode_all(&first[..], 3).unwrap();
    shell.call(call + 2, "zstd.open".into(), b"{}", None);
    let id = serde_json::from_str::<Value>(&answer(call + 2).0).unwrap()["id"].as_u64().unwrap();
    shell.call(call + 3, "zstd.push".into(), format!(r#"{{"id":{id}}}"#).as_bytes(), Some(cut[..cut.len() - 1].to_vec()));
    let (json, error, bytes) = answer(call + 3);
    assert_eq!(error, "");
    assert!(first.starts_with(&bytes.unwrap_or_default()));
    assert_eq!(serde_json::from_str::<Value>(&json).unwrap()["whole"], json!(false));
    // and what is not zstd fails
    shell.call(call + 4, "zstd.open".into(), b"{}", None);
    let id = serde_json::from_str::<Value>(&answer(call + 4).0).unwrap()["id"].as_u64().unwrap();
    shell.call(call + 5, "zstd.push".into(), format!(r#"{{"id":{id}}}"#).as_bytes(), Some(b"not zstd at all".to_vec()));
    assert_ne!(answer(call + 5).1, "");

    // zstd.stream + zstd.push with finish: true ends the frame cleanly (both multi-chunk and empty).
    shell.call(call + 6, "zstd.stream".into(), b"{\"level\":3,\"window\":20}", None);
    let sid = serde_json::from_str::<Value>(&answer(call + 6).0).unwrap()["id"].as_u64().unwrap();
    let mut streamed = Vec::new();
    for (i, piece) in [b"{\"status\":200,\"body\":1}\n".as_slice(), b"{\"status\":200,\"body\":2}\n".as_slice()].into_iter().enumerate() {
        shell.call(call + 7 + i as u64, "zstd.push".into(), format!(r#"{{"id":{sid}}}"#).as_bytes(), Some(piece.to_vec()));
        let (_, error, bytes) = answer(call + 7 + i as u64);
        assert_eq!(error, "");
        streamed.extend(bytes.unwrap_or_default());
    }
    shell.call(call + 9, "zstd.push".into(), format!(r#"{{"id":{sid},"finish":true}}"#).as_bytes(), Some(Vec::new()));
    let (_, error, tail) = answer(call + 9);
    assert_eq!(error, "");
    streamed.extend(tail.unwrap_or_default());
    shell.call(call + 10, "zstd.close".into(), format!(r#"{{"id":{sid}}}"#).as_bytes(), None);
    assert_eq!(answer(call + 10).1, "");
    let decoded = zstd::stream::decode_all(&streamed[..]).unwrap();
    assert_eq!(decoded, b"{\"status\":200,\"body\":1}\n{\"status\":200,\"body\":2}\n");

    // Empty zstd.stream finished immediately produces a valid empty zstd frame.
    shell.call(call + 11, "zstd.stream".into(), b"{\"level\":3,\"window\":20}", None);
    let esid = serde_json::from_str::<Value>(&answer(call + 11).0).unwrap()["id"].as_u64().unwrap();
    shell.call(call + 12, "zstd.push".into(), format!(r#"{{"id":{esid},"finish":true}}"#).as_bytes(), Some(Vec::new()));
    let (_, error, empty_frame) = answer(call + 12);
    assert_eq!(error, "");
    let empty_frame = empty_frame.unwrap_or_default();
    assert!(!empty_frame.is_empty());
    assert_eq!(zstd::stream::decode_all(&empty_frame[..]).unwrap(), b"");
    shell.call(call + 13, "zstd.close".into(), format!(r#"{{"id":{esid}}}"#).as_bytes(), None);
    assert_eq!(answer(call + 13).1, "");
}

#[test]
fn packs_a_syncs_pieces_checking_each_files_id_and_scans_files() {
    use sha1::Digest;
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().join("shell"), complete, ctx()).unwrap();
    let at = |p: &str| dir.path().join(p).display().to_string();
    let blob = |b: &[u8]| {
        let mut h = sha1::Sha1::new();
        h.update(format!("blob {}\0", b.len()).as_bytes());
        h.update(b);
        hex::encode(h.finalize())
    };
    let content: Vec<u8> = (0..300_000u32).map(|i| (i * 7 % 251) as u8).collect();
    std::fs::write(at("f"), &content).unwrap();
    std::fs::write(at("empty"), b"").unwrap();
    let id_f = blob(&content);
    let call = |n: u64, op: &str, a: Value| {
        shell.call(n, op.into(), a.to_string().as_bytes(), None);
        let (json, error, _) = answer(n);
        (serde_json::from_str::<Value>(&json).unwrap_or(Value::Null), error)
    };
    let pack = call(9201, "pack.open", json!({})).0["id"].as_u64().unwrap();
    // in two calls, the file's id checked at its last piece; the empty one in the first
    let (one, e) = call(9202, "zstd.pack", json!({ "id": pack, "out": at("1.zst"), "pieces": [[at("f"), 0, 200_000, 300_000, id_f, false], [at("empty"), 0, 0, 0, blob(b""), false]] }));
    assert_eq!((one["raw"].clone(), e.as_str()), (json!(200_000), ""));
    // packed anew (a station from before, its request split): not counted twice
    let (again, _) = call(9203, "zstd.pack", json!({ "id": pack, "out": at("1.zst"), "pieces": [[at("f"), 0, 200_000, 300_000, id_f, false]] }));
    assert_eq!(again["raw"], json!(200_000));
    let (two, e) = call(9204, "zstd.pack", json!({ "id": pack, "out": at("2.zst"), "pieces": [[at("f"), 200_000, 100_000, 300_000, id_f, false]] }));
    assert_eq!((two["raw"].clone(), e.as_str()), (json!(100_000), ""));
    let mut whole = zstd::decode_all(std::fs::File::open(at("1.zst")).unwrap()).unwrap();
    whole.extend(zstd::decode_all(std::fs::File::open(at("2.zst")).unwrap()).unwrap());
    assert_eq!(whole, content);
    assert_eq!(two["packed"].as_u64().unwrap(), std::fs::metadata(at("2.zst")).unwrap().len());
    // its last piece packed again after its id was checked: as it was
    assert_eq!(call(9205, "zstd.pack", json!({ "id": pack, "out": at("2.zst"), "pieces": [[at("f"), 200_000, 100_000, 300_000, id_f, false]] })).0["raw"], json!(100_000));
    // grown since it was listed, its first bytes as they were (and an empty one written in): changed
    std::fs::write(at("g"), b"").unwrap();
    let (one, _) = call(9215, "zstd.pack", json!({ "id": pack, "out": at("g.zst"), "pieces": [[at("g"), 0, 0, 0, blob(b""), false]] }));
    assert_eq!(one["raw"], json!(0));
    std::fs::write(at("g"), b"now").unwrap();
    assert_eq!(call(9216, "zstd.pack", json!({ "id": pack, "out": at("g.zst"), "pieces": [[at("g"), 0, 0, 0, blob(b""), false]] })).0, json!({ "changed": 0 }));
    let mut longer = content.clone();
    longer.extend_from_slice(b"more");
    std::fs::write(at("f"), &longer).unwrap();
    assert_eq!(call(9217, "zstd.pack", json!({ "id": pack, "out": at("3.zst"), "pieces": [[at("f"), 0, 300_000, 300_000, id_f, false]] })).0, json!({ "changed": 0 }));
    // changed since it was listed: its piece named
    std::fs::write(at("f"), &content[..299_999]).unwrap();
    let changed = json!([[at("empty"), 0, 0, 0, blob(b""), false], [at("f"), 0, 300_000, 300_000, id_f, false]]);
    assert_eq!(call(9206, "zstd.pack", json!({ "id": pack, "out": at("3.zst"), "pieces": changed })).0, json!({ "changed": 1 }));
    let mut other = content.clone();
    other[5] ^= 1;
    std::fs::write(at("f"), &other).unwrap();
    assert_eq!(call(9207, "zstd.pack", json!({ "id": pack, "out": at("3.zst"), "pieces": [[at("f"), 0, 300_000, 300_000, id_f, false]] })).0, json!({ "changed": 0 }));
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink("f", at("l")).unwrap();
        assert_eq!(call(9208, "zstd.pack", json!({ "id": pack, "out": at("4.zst"), "pieces": [[at("l"), 0, 1, 1, blob(b"f"), true]] })).0["raw"], json!(1));
        assert_eq!(zstd::decode_all(std::fs::File::open(at("4.zst")).unwrap()).unwrap(), b"f");
        assert_eq!(call(9209, "zstd.pack", json!({ "id": pack, "out": at("4.zst"), "pieces": [[at("l"), 0, 1, 1, blob(b"g"), true]] })).0, json!({ "changed": 0 }));
        // a file made a link (to one outside, say): not followed, changed
        std::fs::write(at("h"), b"h").unwrap();
        std::fs::remove_file(at("h")).unwrap();
        std::os::unix::fs::symlink("/etc/hosts", at("h")).unwrap();
        assert_eq!(call(9218, "zstd.pack", json!({ "id": pack, "out": at("4.zst"), "pieces": [[at("h"), 0, 1, 1, blob(b"h"), false]] })).0, json!({ "changed": 0 }));
        // scanned: kinds, a file's id (of one within `most`), a link's target, nothing there
        std::fs::write(at("f"), &content).unwrap();
        let (scan, e) = call(9210, "fs.scan", json!({ "paths": [at("f"), at("l"), at("none"), at("empty")], "hash": true, "most": 1_000_000 }));
        assert_eq!(e, "");
        assert_eq!((scan[0]["kind"].clone(), scan[0]["hash"].clone(), scan[0]["size"].clone()), (json!("file"), json!(id_f), json!(300_000)));
        assert_eq!((scan[1]["kind"].clone(), scan[1]["link"].clone()), (json!("link"), json!("f")));
        assert_eq!(scan[2], Value::Null);
        assert_eq!(scan[3]["hash"], json!(blob(b"")));
        assert!(scan[0]["dev"].as_u64().unwrap() > 0);
        let (small, _) = call(9211, "fs.scan", json!({ "paths": [at("f"), at("l")], "hash": true, "most": 10 }));
        assert_eq!(small[0]["hash"], Value::Null);
        let (followed, _) = call(9212, "fs.scan", json!({ "paths": [at("l")], "follow": true }));
        assert_eq!((followed[0]["kind"].clone(), followed[0]["link"].clone()), (json!("file"), Value::Null));
    }
    assert_eq!(call(9213, "pack.close", json!({ "id": pack })).1, "");
    assert_eq!(call(9214, "zstd.pack", json!({ "id": pack, "out": at("5.zst"), "pieces": [] })).1, format!("no handle {pack}"));
}

#[test]
fn unpacks_zstd_whole_up_to_its_bound() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let plain: Vec<u8> = (0..100_000u32).flat_map(|i| i.to_le_bytes()).collect();
    let packed = zstd::stream::encode_all(&plain[..], 3).unwrap();
    // given, or in a file
    shell.call(9101, "zstd.unpack".into(), br#"{"most":400000}"#, Some(packed.clone()));
    assert_eq!(answer(9101).2, Some(plain.clone()));
    let at = dir.path().join("packed.zst");
    std::fs::write(&at, &packed).unwrap();
    let args = json!({ "path": at.to_string_lossy(), "most": 400_000 }).to_string();
    shell.call(9102, "zstd.unpack".into(), args.as_bytes(), None);
    assert_eq!(answer(9102).2, Some(plain.clone()));
    // a byte more than its bound is refused, as is what is not zstd
    shell.call(9103, "zstd.unpack".into(), br#"{"most":399999}"#, Some(packed));
    assert_eq!(answer(9103).1, "more than 399999 bytes unpacked");
    shell.call(9104, "zstd.unpack".into(), br#"{"most":10}"#, Some(b"not zstd at all".to_vec()));
    assert_ne!(answer(9104).1, "");
}

#[test]
fn attaches_a_database_another_process_keeps() {
    let dir = TempDir::new();
    let path = dir.path().join("station.db");
    // the station's own connection, in WAL, holding it while the shell's is open beside it
    let station = rusqlite::Connection::open(&path).unwrap();
    station.execute_batch("PRAGMA journal_mode = WAL; CREATE TABLE t (k TEXT, n INTEGER); INSERT INTO t VALUES ('a', 1);").unwrap();
    let shell = Shell::start(dir.path().join("shell"), complete, ctx()).unwrap();
    let sync = |op: &str, json: &str| -> Value { serde_json::from_slice(&shell.call_sync(op, json.as_bytes())).unwrap() };
    let at = serde_json::to_string(&path.display().to_string()).unwrap();
    let id = sync("sql.attach", &format!(r#"{{"path":{at},"wait":0}}"#))["value"]["id"].as_u64().unwrap();
    let rows = sync("sql.all", &format!(r#"{{"id":{id},"sql":"SELECT k, n FROM t","named":true}}"#));
    assert_eq!(rows["value"], json!({ "columns": ["k", "n"], "rows": [["a", 1]] }));
    // both write: neither holds it for itself
    station.execute("INSERT INTO t VALUES ('b', 2)", []).unwrap();
    let checkpoint = sync("sql.all", &format!(r#"{{"id":{id},"sql":"PRAGMA wal_checkpoint(PASSIVE)","named":true}}"#));
    assert_eq!(checkpoint["value"]["columns"], json!(["busy", "log", "checkpointed"]));
    // a path with no database is not made one
    let missing = serde_json::to_string(&dir.path().join("none.db").display().to_string()).unwrap();
    assert!(sync("sql.attach", &format!(r#"{{"path":{missing}}}"#))["error"].is_string());
    assert!(!dir.path().join("none.db").exists());
}

#[test]
fn writes_hashes_and_moves_the_station_programs_files() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().join("shell"), complete, ctx()).unwrap();
    let sync = |op: &str, a: Value| -> Value { serde_json::from_slice(&shell.call_sync(op, a.to_string().as_bytes())).unwrap() };
    let at = |p: &str| dir.path().join(p).display().to_string();
    // written whole, its folders made, nothing left beside it; zstd's frame of it read back as what it holds
    let plain = sync("fs.write", json!({ "path": at("a/b/plain.txt"), "text": "中\n" }));
    use sha2::Digest;
    assert_eq!(plain["value"]["sha256"], json!(hex::encode(sha2::Sha256::digest("中\n".as_bytes()))));
    assert_eq!(plain["value"]["size"], json!(4));
    assert_eq!(std::fs::read(dir.path().join("a/b/plain.txt")).unwrap(), "中\n".as_bytes());
    let packed = sync("fs.write", json!({ "path": at("a/packed.zst"), "text": "x".repeat(1000), "zstd": true }));
    let bytes = std::fs::read(dir.path().join("a/packed.zst")).unwrap();
    assert!(bytes.len() < 100);
    assert_eq!(packed["value"], json!({ "sha256": hex::encode(sha2::Sha256::digest(&bytes)), "size": bytes.len() }));
    assert_eq!(sync("fs.read", json!({ "path": at("a/packed.zst"), "zstd": true }))["value"], json!("x".repeat(1000)));
    assert_eq!(std::fs::read_dir(dir.path().join("a")).unwrap().count(), 2);
    assert_eq!(sync("fs.hash", json!({ "path": at("a/b/plain.txt") }))["value"], plain["value"]["sha256"]);
    // a piece of a file as hex, a frame of it decompressed, and one that ends early
    assert_eq!(sync("fs.bytes", json!({ "path": at("a/packed.zst"), "zstd": true }))["value"], json!(hex::encode("x".repeat(1000))));
    let whole = sync("fs.bytes", json!({ "path": at("a/b/plain.txt") }))["value"].as_str().unwrap().to_string();
    assert_eq!(sync("fs.bytes", json!({ "path": at("a/b/plain.txt"), "from": 1, "length": 2 }))["value"], json!(whole[2..6]));
    assert!(sync("fs.bytes", json!({ "path": at("a/b/plain.txt"), "from": 1, "length": 1_000_000, "exact": true }))["error"].is_string());
    assert_eq!(sync("fs.bytes", json!({ "path": at("none") }))["value"], Value::Null);
    assert_eq!(sync("fs.hash", json!({ "path": at("none") }))["value"], Value::Null);
    // a program's output, and one that fails, runs too long or writes too much; a link as lstat says it
    #[cfg(unix)]
    {
        assert_eq!(sync("proc.run", json!({ "command": "printf", "args": ["a\\nb"] }))["value"], json!("a\nb"));
        assert_eq!(sync("proc.run", json!({ "command": "false" }))["value"], Value::Null);
        assert_eq!(sync("proc.run", json!({ "command": "sleep", "args": ["5"], "timeoutMs": 50 }))["value"], Value::Null);
        assert_eq!(sync("proc.run", json!({ "command": "printf", "args": ["abcdef"], "maxBytes": 3 }))["value"], Value::Null);
        assert_eq!(sync("proc.run", json!({ "command": "/no/such/program" }))["value"], Value::Null);
        std::os::unix::fs::symlink(at("a/b/plain.txt"), at("a/link")).unwrap();
        assert_eq!(sync("fs.stat", json!({ "path": at("a/link"), "lstat": true }))["value"], json!("link"));
        assert_eq!(sync("fs.stat", json!({ "path": at("a/link") }))["value"], json!("file"));
        std::fs::remove_file(at("a/link")).unwrap();
        // what lstat says, a link made, a mode set, a hard link once, a Git blob id (`printf '中\n' | git hash-object --stdin`)
        let st = sync("fs.lstat", json!({ "path": at("a/b/plain.txt") }))["value"].clone();
        assert_eq!((st["kind"].clone(), st["size"].clone()), (json!("file"), json!(4)));
        assert!(st["ino"].as_u64().unwrap() > 0 && st["mtimeMs"].as_f64().unwrap() > 0.0 && st["ctimeMs"].as_f64().unwrap() > 0.0);
        assert_eq!(sync("fs.symlink", json!({ "target": "b/plain.txt", "path": at("a/rel") }))["value"], Value::Null);
        assert_eq!(sync("fs.lstat", json!({ "path": at("a/rel") }))["value"]["kind"], json!("link"));
        assert_eq!(sync("fs.chmod", json!({ "path": at("a/b/plain.txt"), "mode": 0o755 }))["value"], Value::Null);
        assert_eq!(sync("fs.lstat", json!({ "path": at("a/b/plain.txt") }))["value"]["mode"].as_u64().unwrap() & 0o777, 0o755);
        assert_eq!(sync("fs.link", json!({ "from": at("a/b/plain.txt"), "to": at("a/hard") }))["value"], json!(true));
        assert_eq!(sync("fs.link", json!({ "from": at("a/b/plain.txt"), "to": at("a/hard") }))["value"], json!(false));
        assert_eq!(sync("fs.gitblob", json!({ "path": at("a/b/plain.txt"), "size": 4 }))["value"], json!("74088efd486cfe7ecada1b668aa911b8f767b99a"));
        assert!(sync("fs.gitblob", json!({ "path": at("a/b/plain.txt"), "size": 5 }))["error"].is_string());
        assert_eq!(sync("fs.lstat", json!({ "path": at("nothing") }))["value"], Value::Null);
        assert_eq!(sync("proc.run", json!({ "command": "sh", "args": ["-c", "printf '\\001'; exit 1"], "hex": true, "code": true }))["value"], json!({ "code": 1, "out": "01" }));
        assert_eq!(sync("proc.run", json!({ "command": "sh", "args": ["-c", "printf %s \"$X\""], "env": { "X": "y" } }))["value"], json!("y"));
        std::fs::remove_file(at("a/rel")).unwrap();
        std::fs::remove_file(at("a/hard")).unwrap();
    }
    // copied, renamed, a folder made, then let go with what it holds; nothing there is no failure
    assert_eq!(sync("fs.copy", json!({ "from": at("a/b/plain.txt"), "to": at("a/copy.txt") }))["value"], Value::Null);
    assert_eq!(sync("fs.rename", json!({ "from": at("a/copy.txt"), "to": at("a/moved.txt") }))["value"], Value::Null);
    assert_eq!(std::fs::read(dir.path().join("a/moved.txt")).unwrap(), "中\n".as_bytes());
    assert_eq!(sync("fs.mkdir", json!({ "path": at("c/d") }))["value"], Value::Null);
    assert!(dir.path().join("c/d").is_dir());
    // fs.mkdir with recursive=false is atomic and returns EEXIST when the directory already exists;
    // recursive=true / omitted remains idempotent.
    assert_eq!(sync("fs.mkdir", json!({ "path": at("c/d") }))["value"], Value::Null);
    assert_eq!(sync("fs.mkdir", json!({ "path": at("c/d"), "recursive": true }))["value"], Value::Null);
    assert_eq!(sync("fs.mkdir", json!({ "path": at("c/lock"), "recursive": false }))["value"], Value::Null);
    assert!(dir.path().join("c/lock").is_dir());
    let eexist = sync("fs.mkdir", json!({ "path": at("c/lock"), "recursive": false }))["error"]
        .as_str()
        .expect("non-recursive mkdir on existing dir must error")
        .to_string();
    assert!(eexist.contains("EEXIST"), "expected EEXIST in error, got: {eexist}");
    // fs.utimes updates mtimeMs on both regular files and directories (OAuth lock heartbeat target).
    let target_ms = 1_700_000_123_456.0_f64;
    assert_eq!(sync("fs.utimes", json!({ "path": at("a/moved.txt"), "mtimeMs": target_ms }))["value"], Value::Null);
    let file_mtime = sync("fs.lstat", json!({ "path": at("a/moved.txt") }))["value"]["mtimeMs"].as_f64().unwrap();
    assert!((file_mtime - target_ms).abs() < 2.0, "file mtimeMs expected ~{target_ms}, got {file_mtime}");
    assert_eq!(sync("fs.utimes", json!({ "path": at("c/lock"), "mtimeMs": target_ms }))["value"], Value::Null);
    let dir_mtime = sync("fs.lstat", json!({ "path": at("c/lock") }))["value"]["mtimeMs"].as_f64().unwrap();
    assert!((dir_mtime - target_ms).abs() < 2.0, "dir mtimeMs expected ~{target_ms}, got {dir_mtime}");
    assert!(sync("fs.utimes", json!({ "path": at("c/missing"), "mtimeMs": target_ms }))["error"].is_string());
    assert!(sync("fs.remove", json!({ "path": at("a") }))["error"].is_string());
    assert_eq!(sync("fs.remove", json!({ "path": at("a"), "recursive": true }))["value"], Value::Null);
    assert!(!dir.path().join("a").exists());
    assert_eq!(sync("fs.remove", json!({ "path": at("a") }))["value"], Value::Null);
    assert_eq!(sync("crypto.random", json!({ "bytes": 4 }))["value"].as_str().unwrap().len(), 8);
    // a database of the program's own, made with `create`
    assert!(sync("sql.attach", json!({ "path": at("own.db") }))["error"].is_string());
    assert!(sync("sql.attach", json!({ "path": at("own.db"), "create": true }))["value"]["id"].is_u64());
    assert!(dir.path().join("own.db").exists());
}

#[test]
fn keeps_an_accounts_database() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let sync = |op: &str, json: &str| -> Value { serde_json::from_slice(&shell.call_sync(op, json.as_bytes())).unwrap() };
    let id = sync("sql.open", r#"{"name":"account-a"}"#)["value"]["id"].as_u64().unwrap();
    assert!(dir.path().join("databases/account-a.db").exists());
    assert_eq!(sync("sql.exec", &format!(r#"{{"id":{id},"sql":"CREATE TABLE t (k TEXT PRIMARY KEY, n INTEGER, x REAL, j TEXT)"}}"#))["value"], Value::Null);
    assert_eq!(sync("sql.run", &format!(r#"{{"id":{id},"sql":"INSERT INTO t VALUES (?, ?, ?, ?)","params":["a",1,1.5,"{{\"x\":\"中\"}}"]}}"#))["value"], json!(1));
    assert_eq!(sync("sql.run", &format!(r#"{{"id":{id},"sql":"INSERT INTO t VALUES (?, ?, ?, ?)","params":["b",null,null,null]}}"#))["value"], json!(1));
    let rows = sync("sql.all", &format!(r#"{{"id":{id},"sql":"SELECT k, n, x, j FROM t ORDER BY k","params":[]}}"#));
    assert_eq!(rows["value"], json!([["a", 1, 1.5, "{\"x\":\"中\"}"], ["b", null, null, null]]));
    let bad = sync("sql.run", &format!(r#"{{"id":{id},"sql":"INSERT INTO t VALUES (?, 1, 1, 1)","params":["a"]}}"#));
    assert!(bad["error"].as_str().unwrap().contains("UNIQUE"));
    assert_eq!(sync("sql.inTransaction", &format!(r#"{{"id":{id}}}"#))["value"], json!(false));
    assert_eq!(sync("sql.exec", &format!(r#"{{"id":{id},"sql":"BEGIN IMMEDIATE"}}"#))["value"], Value::Null);
    assert_eq!(sync("sql.inTransaction", &format!(r#"{{"id":{id}}}"#))["value"], json!(true));
    assert_eq!(sync("sql.exec", &format!(r#"{{"id":{id},"sql":"COMMIT"}}"#))["value"], Value::Null);
    assert_eq!(sync("sql.inTransaction", &format!(r#"{{"id":{id}}}"#))["value"], json!(false));
    assert_eq!(sync("sql.close", &format!(r#"{{"id":{id}}}"#))["value"], Value::Null);
    assert!(sync("sql.all", &format!(r#"{{"id":{id},"sql":"SELECT 1"}}"#))["error"].is_string());
    assert_eq!(sync("sql.delete", r#"{"name":"account-a"}"#)["value"], Value::Null);
    assert!(!dir.path().join("databases/account-a.db").exists());
    assert!(sync("sql.open", r#"{"name":"../x"}"#)["error"].is_string());
    let memory = sync("sql.open", r#"{"name":":memory:"}"#)["value"]["id"].as_u64().unwrap();
    assert_eq!(sync("sql.all", &format!(r#"{{"id":{memory},"sql":"SELECT 2"}}"#))["value"], json!([[2]]));
}

#[test]
fn a_window_of_its_own_finds_an_accounts_database_held_busy_at_once() {
    let dir = TempDir::new();
    let app = Shell::start_waiting(dir.path().to_path_buf(), complete, ctx(), DB_WAIT).unwrap();
    let window = Shell::start_waiting(dir.path().to_path_buf(), complete, ctx(), std::time::Duration::ZERO).unwrap();
    let sync = |shell: &Shell, op: &str, json: &str| -> Value { serde_json::from_slice(&shell.call_sync(op, json.as_bytes())).unwrap() };
    assert!(sync(&app, "sql.open", r#"{"name":"account-a"}"#)["value"]["id"].is_u64());
    // held by the app's run: busy, said at once (not after DB_WAIT)
    let asked = std::time::Instant::now();
    let busy = sync(&window, "sql.open", r#"{"name":"account-a"}"#);
    assert!(busy["error"].as_str().unwrap().contains("locked"), "{busy}");
    assert!(asked.elapsed() < DB_WAIT / 5, "{:?}", asked.elapsed());
    // one no one holds: opened as ever
    assert!(sync(&window, "sql.open", r#"{"name":"account-b"}"#)["value"]["id"].is_u64());
}

#[test]
fn signs_with_an_ed25519_seed() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let sync = |op: &str, json: &str| -> Value { serde_json::from_slice(&shell.call_sync(op, json.as_bytes())).unwrap() };
    // RFC 8032's test 2
    let signed = sync("ed25519.sign", r#"{"seed":"4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb","message":"72"}"#);
    assert_eq!(signed["value"]["publicKey"], json!("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"));
    assert_eq!(
        signed["value"]["signature"],
        json!("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
    );
    assert!(sync("ed25519.sign", r#"{"seed":"4ccd","message":"72"}"#)["error"].is_string());
}

#[test]
fn checks_ed25519_and_p256_signatures() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let sync = |op: &str, json: &str| -> Value { serde_json::from_slice(&shell.call_sync(op, json.as_bytes())).unwrap() };
    // RFC 8032's test 2; then the message changed
    let ed = |message: &str| sync("crypto.verify", &format!(r#"{{"alg":"Ed25519","key":"3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c","signature":"92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00","message":"{message}"}}"#));
    assert_eq!(ed("72")["value"], json!(true));
    assert_eq!(ed("73")["value"], json!(false));
    // RFC 6979 A.2.5, P-256 with SHA-256, message "sample": r‖s, then DER
    let key = "0460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299";
    let r = "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716";
    let s = "f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8";
    let p = |alg: &str, signature: &str, message: &str| sync("crypto.verify", &format!(r#"{{"alg":"{alg}","key":"{key}","signature":"{signature}","message":"{message}"}}"#));
    assert_eq!(p("ES256", &format!("{r}{s}"), "73616d706c65")["value"], json!(true));
    assert_eq!(p("ES256", &format!("{r}{s}"), "73616d706c66")["value"], json!(false));
    assert_eq!(p("ES256-der", &format!("3046022100{r}022100{s}"), "73616d706c65")["value"], json!(true));
    assert_eq!(p("ES256", "00", "73616d706c65")["value"], json!(false));
    assert!(sync("crypto.verify", r#"{"alg":"RS256","key":"00","signature":"00","message":"00"}"#)["error"].is_string());
}

#[test]
fn counts_calls_by_operation() {
    counted("test.op", true);
    counted("test.op", true);
    counted("test.op", false);
    let stats = stats_json();
    assert_eq!(stats["calls"]["test.op"], json!([2, 1]));
}

// The DHT's lines as the core takes them: none kept until it takes with `keep`, none once it takes without.
#[test]
fn dht_said() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let said = |keep: bool| shell.inner.run_sync("dht.said", &json!({ "keep": keep })).unwrap();
    assert_eq!(said(false), json!({ "lines": [], "dropped": 0 }));
    assert_eq!(said(true), json!({ "lines": [], "dropped": 0 }));
}

#[test]
fn answers_of_a_closed_endpoint() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let endpoint = Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let id = inner.keep(Handle::Endpoint(endpoint.clone(), Arc::default()));
        inner.run("iroh.close", json!({ "id": id }), None).await.unwrap();
        // A dial on it failing after another was bound in its place asks it still (the app's core died of "no handle 3").
        assert_eq!(inner.run_sync("iroh.endpointId", &json!({ "id": id })).unwrap(), json!(hex::encode(endpoint.id().as_bytes())));
        assert_eq!(inner.run_sync("iroh.relayStatus", &json!({ "id": id })).unwrap(), json!([]));
        assert_eq!(inner.run("iroh.accept", json!({ "id": id }), None).await.unwrap().json, json!({ "end": true }));
        let addr = json!({ "id": hex::encode(endpoint.id().as_bytes()), "ips": ["127.0.0.1:1"] });
        assert!(inner.run("iroh.connect", json!({ "id": id, "addr": addr }), Some(b"stillfail/test".to_vec())).await.is_err());
        assert!(inner.run("iroh.close", json!({ "id": id }), None).await.is_ok());
    });
}

/// An endpoint closed (`iroh.close`, let go or kept as closed) is bound again at its fixed port at once, though its
/// accepting was waiting in iroh's `accept`, a connection it took is kept for the core, one coming is held unanswered and
/// an `iroh.accept` waits on it (its answer then the end). Each of those held a clone of the endpoint (or of its sockets)
/// past the answer, and a station's front binding the same port at once found it in use (`Failed to bind sockets`,
/// `EADDRINUSE`); what iroh itself still holds a moment longer is waited out (iroh_ops.rs `RECENTLY_CLOSED`).
#[test]
fn a_closed_endpoint_is_bound_again_at_its_fixed_port_at_once() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let alpn = b"stillfail/test".to_vec();
        let fixed = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap().to_string();
        let key = [7u8; 32];
        let addr = endpoint_addr(&json!({ "id": hex::encode(SecretKey::from_bytes(&key).public().as_bytes()), "ips": [fixed] })).unwrap();
        let dialer = Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let accept = |id: u64| {
            let inner = inner.clone();
            tokio::spawn(async move { inner.run("iroh.accept", json!({ "id": id }), None).await.unwrap().json })
        };
        let bind = || inner.run("iroh.bind", json!({ "relayUrls": [], "alpns": [hex::encode(&alpn)], "bindAddr": fixed }), Some(key.to_vec()));
        let mut id = bind().await.unwrap().json["id"].as_u64().unwrap();
        for round in 0..30 {
            let forget = round % 2 == 0;
            let Handle::Endpoint(_, kept) = inner.handle(id).unwrap() else { panic!("not an endpoint") };
            // a connection taken, kept for the core
            let taking = accept(id);
            let _theirs = dialer.connect(addr.clone(), &alpn).await.unwrap();
            let taken = taking.await.unwrap()["id"].as_u64().unwrap();
            // the next one coming held unanswered, its dial never done
            inner.run("iroh.holdIncoming", json!({ "id": id, "n": 1 }), None).await.unwrap();
            let held = {
                let (dialer, addr, alpn) = (dialer.clone(), addr.clone(), alpn.clone());
                tokio::spawn(async move { dialer.connect(addr, &alpn).await })
            };
            while kept.held.lock().unwrap().1.is_empty() {
                tokio::task::yield_now().await;
            }
            // an `iroh.accept` waiting (holding what it waits on) as it closes
            let waiting = accept(id);
            while kept.accepted.try_lock().is_ok() {
                tokio::task::yield_now().await;
            }
            inner.run("iroh.close", json!({ "id": id, "forget": forget }), None).await.unwrap();
            // nothing of it left holding its sockets once answered
            assert!(kept.held.lock().unwrap().1.is_empty());
            assert!(kept.conns.lock().unwrap().is_empty());
            assert!(kept.accept_task.lock().unwrap().is_none());
            assert!(matches!(inner.handle(taken), Ok(Handle::Gone { .. })), "the connection it took still kept");
            let again = bind().await.unwrap_or_else(|e| panic!("round {round} (forget: {forget}): not bound again at once: {e}"));
            assert!(!crate::iroh_ops::closed_lately(fixed.parse().unwrap()), "kept as closed once bound again");
            assert_eq!(waiting.await.unwrap(), json!({ "end": true }));
            assert_eq!(inner.handle(id).is_ok(), !forget);
            held.abort();
            id = again.json["id"].as_u64().unwrap();
        }
        inner.run("iroh.close", json!({ "id": id, "forget": true }), None).await.unwrap();
        dialer.close().await;
    });
}

/// A fixed port another program holds (not an endpoint closed here) fails a bind at once, never tried again.
#[test]
fn a_fixed_port_held_elsewhere_fails_a_bind_at_once() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let other = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let fixed = other.local_addr().unwrap().to_string();
        let said = inner.run("iroh.bind", json!({ "relayUrls": [], "alpns": [], "bindAddr": fixed }), Some(vec![8; 32])).await.err().unwrap();
        assert!(said.contains("Failed to bind sockets"), "{said}");
        drop(other);
    });
}

/// An endpoint closed while an `iroh.online` of it waits (no relay answering, never online) cancels that wait, which
/// lets go of the endpoint: its fixed port is bound again at once.
#[test]
fn closing_an_endpoint_cancels_what_waits_on_it() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let fixed = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap().to_string();
        // (a relay at a port nothing answers on: never online)
        let silent = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let options = json!({ "relayUrls": [format!("http://127.0.0.1:{silent}/")], "alpns": [], "bindAddr": fixed, "dht": false });
        let id = inner.run("iroh.bind", options.clone(), Some(vec![9; 32])).await.unwrap().json["id"].as_u64().unwrap();
        let Handle::Endpoint(_, kept) = inner.handle(id).unwrap() else { panic!("not an endpoint") };
        let online = {
            let inner = inner.clone();
            tokio::spawn(async move { inner.run("iroh.online", json!({ "id": id }), None).await })
        };
        // (waiting once it listens for the close: taking `ops` here to look would refuse it its permit)
        while kept.closing.receiver_count() == 0 {
            assert!(!online.is_finished(), "online answered before the close");
            tokio::task::yield_now().await;
        }
        inner.run("iroh.close", json!({ "id": id, "forget": true }), None).await.unwrap();
        assert_eq!(online.await.unwrap().err().unwrap(), "the endpoint is closed");
        let again = inner.run("iroh.bind", options, Some(vec![9; 32])).await.unwrap().json["id"].as_u64().unwrap();
        inner.run("iroh.close", json!({ "id": again, "forget": true }), None).await.unwrap();
    });
}

/// Two `iroh.close` of one endpoint at once: the second answers only once the first is done (its handle `Unbound`).
#[test]
fn a_second_close_answers_once_the_first_is_done() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let id = inner.run("iroh.bind", json!({ "relayUrls": [], "alpns": [] }), Some(vec![10; 32])).await.unwrap().json["id"].as_u64().unwrap();
        let Handle::Endpoint(_, kept) = inner.handle(id).unwrap() else { panic!("not an endpoint") };
        // (an operation holding it: the first close waits for it)
        let op = kept.ops.read().await;
        let close = || {
            let inner = inner.clone();
            tokio::spawn(async move { inner.run("iroh.close", json!({ "id": id }), None).await })
        };
        let first = close();
        while !kept.closed.load(std::sync::atomic::Ordering::SeqCst) {
            tokio::task::yield_now().await;
        }
        let second = close();
        // (each close waits on it: the first for its own task)
        while kept.closed_done.receiver_count() < 2 {
            tokio::task::yield_now().await;
        }
        assert!(!first.is_finished() && !second.is_finished());
        drop(op);
        second.await.unwrap().unwrap();
        assert!(matches!(inner.handle(id), Ok(Handle::Unbound { .. })), "the second answered before the first was done");
        first.await.unwrap().unwrap();
    });
}

/// A connection let go (`Gone`) while `conn.hand` takes its streams: a stream that comes after is refused, never kept
/// (no `IStream` left of it) nor handed to `path`.
#[cfg(unix)]
#[test]
fn conn_hand_keeps_and_hands_nothing_once_its_connection_is_gone() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let alpn = b"stillfail/test".to_vec();
        let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
        let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
        let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
        let addr = endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
        let taken = tokio::spawn({
            let b = b.clone();
            async move { b.accept().await.unwrap().await.unwrap() }
        });
        let id = inner.keep_conn(a.connect(addr, &alpn).await.unwrap());
        let theirs = taken.await.unwrap();
        let node = dir.path().join("gone-node.sock");
        let (said_to, mut said) = tokio::sync::mpsc::unbounded_channel();
        let node_task = taking_streams(tokio::net::UnixListener::bind(&node).unwrap(), "node", said_to);
        let handing = {
            let inner = inner.clone();
            let a = json!({ "id": id, "path": node.to_str().unwrap() });
            tokio::spawn(async move { inner.run("conn.hand", a, None).await })
        };
        // the first, handed
        let (mut send0, mut recv0) = theirs.open_bi().await.unwrap();
        send0.write_all(b"{\"hello\":1}\n").await.unwrap();
        send0.finish().unwrap();
        assert_eq!(String::from_utf8(recv0.read_to_end(1 << 16).await.unwrap()).unwrap(), "node");
        assert_eq!(said.recv().await.unwrap().2, 0);
        let streams_of = || inner.handles.lock().unwrap().values().filter(|h| matches!(h, Handle::IStream(halves) if halves.conn == id)).count();
        // (the first carried whole and let go)
        while streams_of() > 0 {
            tokio::task::yield_now().await;
        }
        // let go (as `release_conn` does) while the connection itself goes on
        inner.handles.lock().unwrap().insert(id, Handle::Gone { remote: String::new(), alpn: String::new(), reason: json!({}), stats: json!({}) });
        let (mut send1, _recv1) = theirs.open_bi().await.unwrap();
        send1.write_all(b"{\"method\":\"GET\",\"path\":\"/late\"}\n").await.unwrap();
        send1.finish().unwrap();
        handing.await.unwrap().unwrap();
        assert_eq!(streams_of(), 0, "a stream kept after its connection was let go");
        node_task.abort();
        let _ = node_task.await;
        assert!(said.try_recv().is_err(), "a stream handed after its connection was let go");
        a.close().await;
        b.close().await;
    });
}

/// A stream reset (`istream.reset`) while `conn.hand` still waits for its head line (one that may go to a program,
/// `front`): given up at once with the reset's code, its reader let go (the reset waited on it for good before), Node
/// told to pass over its index, and the connection's next stream handed as ever.
#[cfg(unix)]
#[test]
fn a_stream_reset_before_it_is_carried_is_given_up_at_once() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let alpn = b"stillfail/test".to_vec();
        let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
        let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
        let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
        let addr = endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
        let taken = tokio::spawn({
            let b = b.clone();
            async move { b.accept().await.unwrap().await.unwrap() }
        });
        let id = inner.keep_conn(a.connect(addr, &alpn).await.unwrap());
        let theirs = taken.await.unwrap();
        let (node, front) = (dir.path().join("reset-node.sock"), dir.path().join("reset-front.sock"));
        let (said_to, mut said) = tokio::sync::mpsc::unbounded_channel();
        let node_task = taking_streams(tokio::net::UnixListener::bind(&node).unwrap(), "node", said_to.clone());
        let front_task = taking_streams(tokio::net::UnixListener::bind(&front).unwrap(), "front", said_to);
        let handing = {
            let inner = inner.clone();
            let a = json!({ "id": id, "path": node.to_str().unwrap(), "front": [front.to_str().unwrap()], "routes": ["GET /routed"] });
            tokio::spawn(async move { inner.run("conn.hand", a, None).await })
        };
        let (mut send0, mut recv0) = theirs.open_bi().await.unwrap();
        send0.write_all(b"{\"hello\":1}\n").await.unwrap();
        send0.finish().unwrap();
        assert_eq!(String::from_utf8(recv0.read_to_end(1 << 16).await.unwrap()).unwrap(), "node");
        assert_eq!(said.recv().await.unwrap().2, 0);
        let streams_of = || inner.handles.lock().unwrap().iter().filter(|(_, h)| matches!(h, Handle::IStream(halves) if halves.conn == id)).map(|(k, _)| *k).collect::<Vec<_>>();
        while !streams_of().is_empty() {
            tokio::task::yield_now().await;
        }
        // a second, its head line never ending: `conn.hand` waits on its reader
        let (mut send1, mut recv1) = theirs.open_bi().await.unwrap();
        send1.write_all(b"{\"method\":\"GET\"").await.unwrap();
        let stream = loop {
            if let Some(stream) = streams_of().first().copied() {
                break stream;
            }
            tokio::task::yield_now().await;
        };
        let reset = inner.run("istream.reset", json!({ "id": stream, "code": 42 }), None);
        tokio::time::timeout(std::time::Duration::from_secs(10), reset).await.expect("the reset waited on the stream's reader").unwrap();
        let said_reset = format!("{:?}", recv1.read_to_end(1 << 16).await.err().expect("the stream not reset"));
        assert!(said_reset.contains("Reset(42)"), "{said_reset}");
        // Node told to pass over it (a kind 3), not given it
        assert_eq!(said.recv().await.unwrap(), ("node", 3, 1, vec![]));
        assert!(streams_of().is_empty());
        // the next on the same connection handed as ever
        let (mut send2, mut recv2) = theirs.open_bi().await.unwrap();
        send2.write_all(b"{\"method\":\"GET\",\"path\":\"/elsewhere\"}\n").await.unwrap();
        send2.finish().unwrap();
        assert_eq!(String::from_utf8(recv2.read_to_end(1 << 16).await.unwrap()).unwrap(), "node");
        let (who, kind, index, _) = said.recv().await.unwrap();
        assert_eq!((who, kind, index), ("node", 2, 2));
        node_task.abort();
        front_task.abort();
        let _ = (node_task.await, front_task.await);
        assert!(said.try_recv().is_err(), "a stream reset was handed");
        a.close().await;
        b.close().await;
        let _ = handing.await;
    });
}

/// `iroh.probeRelay` reaches iroh_ops's probe (station/mb's front and live_p5_1_mesh ask it), never "no operation".
#[test]
fn probe_relay_is_an_operation() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let probe = |id: u64, url: &str| inner.run("iroh.probeRelay", json!({ "id": id, "url": url }), None);
        let endpoint = Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let id = inner.keep(Handle::Endpoint(endpoint, Arc::default()));
        let said = probe(id, "not a url").await.err().unwrap();
        assert!(!said.contains("no operation"), "{said}");
        let other = inner.keep(Handle::Unbound { id: "x".into() });
        assert_eq!(probe(other, "https://relay.example/").await.err().unwrap(), "the endpoint is closed");
        inner.run("iroh.close", json!({ "id": id }), None).await.unwrap();
        assert_eq!(probe(id, "https://relay.example/").await.err().unwrap(), "the endpoint is closed");
        let written = inner.keep(Handle::Gone { remote: String::new(), alpn: String::new(), reason: json!({}), stats: json!({}) });
        assert_eq!(probe(written, "https://relay.example/").await.err().unwrap(), "not an endpoint");
    });
}

#[cfg(unix)]
#[test]
fn pipes_a_stream_into_a_socket_in_frames() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let alpn = b"stillfail/test".to_vec();
        let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
        let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
        let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
        let addr = endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
        let taking = b.clone();
        let taken = tokio::spawn(async move { taking.accept().await.unwrap().await.unwrap() });
        let id = inner.keep_conn(a.connect(addr, &alpn).await.unwrap());
        let theirs = taken.await.unwrap();
        let stream = inner.run("conn.openBi", json!({ "id": id }), None).await.unwrap().json["id"].as_u64().unwrap();
        let (ours, node) = tokio::net::UnixStream::pair().unwrap();
        let (read, write) = ours.into_split();
        let socket = inner.keep(Handle::tcp(read, write));
        let Handle::Tcp { close: socket_close, .. } = inner.handle(socket).unwrap() else { panic!("expected tcp handle") };
        let piping = {
            let inner = inner.clone();
            tokio::spawn(async move { inner.run("istream.pipe", json!({ "id": stream, "to": socket }), None).await })
        };
        // what the socket's side writes, in frames, its end finishing the stream
        let (mut node_read, mut node_write) = node.into_split();
        let sent: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
        let mut framed = Vec::new();
        for piece in sent.chunks(70_000) {
            framed.extend((piece.len() as u32).to_be_bytes());
            framed.extend(piece);
        }
        framed.extend(PIPE_END.to_be_bytes());
        node_write.write_all(&framed).await.unwrap();
        let (mut send, mut recv) = theirs.accept_bi().await.unwrap();
        assert_eq!(recv.read_to_end(1 << 20).await.unwrap(), sent);
        // what comes on the stream, read in frames by the socket's side, then its end
        send.write_all(b"back").await.unwrap();
        send.finish().unwrap();
        let mut got = Vec::new();
        node_read.read_to_end(&mut got).await.unwrap();
        let mut want = 4u32.to_be_bytes().to_vec();
        want.extend(b"back");
        want.extend(PIPE_END.to_be_bytes());
        assert_eq!(got, want);
        piping.await.unwrap().unwrap();
        assert!(!socket_close.is_closed(), "istream.pipe ownership transfer must not trigger SocketClose");

        // the socket ending without its end resets the stream; the other end's reset is said as what failed it
        let stream = inner.run("conn.openBi", json!({ "id": id }), None).await.unwrap().json["id"].as_u64().unwrap();
        let (ours, node) = tokio::net::UnixStream::pair().unwrap();
        let (read, write) = ours.into_split();
        let socket = inner.keep(Handle::tcp(read, write));
        let piping = {
            let inner = inner.clone();
            tokio::spawn(async move { inner.run("istream.pipe", json!({ "id": stream, "to": socket }), None).await })
        };
        let (mut node_read, mut node_write) = node.into_split();
        node_write.write_all(&[0, 0, 0, 1, 7]).await.unwrap();
        let (mut send, mut recv) = theirs.accept_bi().await.unwrap();
        let mut one = [0u8; 1];
        recv.read_exact(&mut one).await.unwrap();
        drop(node_write);
        assert!(recv.read_to_end(1024).await.is_err());
        send.reset(5u32.into()).unwrap();
        let mut got = Vec::new();
        node_read.read_to_end(&mut got).await.unwrap();
        assert_eq!(&got[..4], &PIPE_FAILED.to_be_bytes());
        assert!(String::from_utf8_lossy(&got[8..]).contains('5'), "{}", String::from_utf8_lossy(&got[8..]));
        piping.await.unwrap().unwrap();
    });
}

/// A stand-in for what `conn.hand` gives streams to (Node's socket, a `--serve` program's): each connection's head
/// read, a skip said as it is, else the stream's first frame said and answered with `who`; kept open till its end.
#[cfg(unix)]
fn taking_streams(listener: tokio::net::UnixListener, who: &'static str, said: tokio::sync::mpsc::UnboundedSender<(&'static str, u8, u64, Vec<u8>)>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Ok((socket, _)) = listener.accept().await {
            let said = said.clone();
            tokio::spawn(async move {
                let (mut read, mut write) = socket.into_split();
                let mut head = [0u8; 25];
                if read.read_exact(&mut head).await.is_err() {
                    return;
                }
                let index = u64::from_be_bytes(head[17..25].try_into().unwrap());
                if head[16] == 3 {
                    let _ = said.send((who, 3, index, vec![]));
                    return;
                }
                let mut len = [0u8; 4];
                read.read_exact(&mut len).await.unwrap();
                let mut body = vec![0u8; u32::from_be_bytes(len) as usize];
                read.read_exact(&mut body).await.unwrap();
                let _ = said.send((who, head[16], index, body));
                let mut out = (who.len() as u32).to_be_bytes().to_vec();
                out.extend(who.as_bytes());
                out.extend(PIPE_END.to_be_bytes());
                // (the stream may be gone by now: a test that ends its connection)
                let _ = write.write_all(&out).await;
                let mut rest = vec![];
                let _ = read.read_to_end(&mut rest).await;
            });
        }
    })
}

// A `--serve` program ended and the next not listening yet (station/mb's served.ts starts one again): a routed
// request on a connection already handed went to it, Node was told to skip its index, and the stream was reset.
#[cfg(unix)]
#[test]
fn a_routed_stream_goes_to_the_next_program_listening_or_else_to_node_never_reset() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    let (node, live, dead) = (dir.path().join("node.sock"), dir.path().join("serve-b.sock"), dir.path().join("serve-a.sock"));
    shell.runtime.block_on(async move {
        let alpn = b"stillfail/test".to_vec();
        let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
        let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
        let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
        let addr = endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
        let taking = b.clone();
        let taken = tokio::spawn(async move { taking.accept().await.unwrap().await.unwrap() });
        let id = inner.keep_conn(a.connect(addr, &alpn).await.unwrap());
        let theirs = taken.await.unwrap();
        let (said_to, mut said) = tokio::sync::mpsc::unbounded_channel();
        let _node = taking_streams(tokio::net::UnixListener::bind(&node).unwrap(), "node", said_to.clone());
        let serving = taking_streams(tokio::net::UnixListener::bind(&live).unwrap(), "served", said_to);
        let handing = {
            let inner = inner.clone();
            // the one that is not there first in turn for the routed stream (index 1)
            let a = json!({ "id": id, "path": node.to_str().unwrap(), "front": [live.to_str().unwrap(), dead.to_str().unwrap()], "routes": ["GET /served"] });
            tokio::spawn(async move { inner.run("conn.hand", a, None).await })
        };
        let ask = |line: &'static str| {
            let theirs = theirs.clone();
            async move {
                let (mut send, mut recv) = theirs.open_bi().await.unwrap();
                send.write_all(line.as_bytes()).await.unwrap();
                send.finish().unwrap();
                String::from_utf8(recv.read_to_end(1 << 16).await.expect("answered, not reset")).unwrap()
            }
        };
        // the credential's (first) stream: Node's
        assert_eq!(ask("{\"hello\":1}\n").await, "node");
        assert_eq!(said.recv().await.unwrap(), ("node", 2, 0, b"{\"hello\":1}\n".to_vec()));
        // routed: the program not listening passed over for the next, Node told the index went elsewhere
        let routed = "{\"method\":\"GET\",\"path\":\"/served?x=1\"}\n";
        assert_eq!(ask(routed).await, "served");
        let mut got = vec![said.recv().await.unwrap(), said.recv().await.unwrap()];
        got.sort();
        assert_eq!(got, [("node", 3, 1, vec![]), ("served", 2, 1, routed.as_bytes().to_vec())]);
        // none listening: Node answers it, with what was read of it, and is told no skip
        serving.abort();
        let _ = serving.await;
        std::fs::remove_file(&live).unwrap();
        assert_eq!(ask(routed).await, "node");
        assert_eq!(said.recv().await.unwrap(), ("node", 2, 2, routed.as_bytes().to_vec()));
        // and one not routed, as before
        assert_eq!(ask("{\"method\":\"GET\",\"path\":\"/host\"}\n").await, "node");
        assert_eq!(said.recv().await.unwrap(), ("node", 2, 3, b"{\"method\":\"GET\",\"path\":\"/host\"}\n".to_vec()));
        assert!(said.try_recv().is_err(), "nothing else said");
        theirs.close(0u32.into(), b"bye");
        handing.await.unwrap().unwrap();
    });
}

#[cfg(unix)]
fn bind_unlistening_unix(path: &std::path::Path) -> std::os::fd::OwnedFd {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let _ = std::fs::remove_file(path);
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    assert!(fd >= 0, "socket: {}", std::io::Error::last_os_error());
    let owned = unsafe { OwnedFd::from_raw_fd(fd) };
    assert!(unsafe { libc::fcntl(owned.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } >= 0);
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let bytes = path.as_os_str().as_encoded_bytes();
    assert!(bytes.len() < addr.sun_path.len());
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), addr.sun_path.as_mut_ptr().cast::<u8>(), bytes.len());
    }
    let len = (std::mem::offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1) as libc::socklen_t;
    assert_eq!(
        unsafe { libc::bind(owned.as_raw_fd(), (&addr as *const libc::sockaddr_un).cast::<libc::sockaddr>(), len) },
        0,
        "bind: {}",
        std::io::Error::last_os_error()
    );
    owned
}

#[cfg(unix)]
fn start_listening_unix(fd: std::os::fd::OwnedFd) -> tokio::net::UnixListener {
    use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
    assert_eq!(unsafe { libc::listen(fd.as_raw_fd(), 16) }, 0, "listen: {}", std::io::Error::last_os_error());
    let std_listener = unsafe { std::os::unix::net::UnixListener::from_raw_fd(fd.into_raw_fd()) };
    std_listener.set_nonblocking(true).unwrap();
    tokio::net::UnixListener::from_std(std_listener).unwrap()
}

#[cfg(unix)]
#[test]
fn open_unix_retries_transient_connection_refused_and_fails_fast_when_missing() {
    let dir = TempDir::new();
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    rt.block_on(async move {
        // Missing path (ENOENT) fails immediately without waiting through the retry budget.
        let missing = dir.path().join("missing.sock");
        let start = std::time::Instant::now();
        assert!(crate::net::open_unix(missing.to_str().unwrap(), b"hello").await.is_err());
        assert!(crate::net::tell_unix(missing.to_str().unwrap(), b"hello").await.is_err());
        assert!(start.elapsed() < std::time::Duration::from_millis(500), "missing path should fail fast, took {:?}", start.elapsed());

        // Bound-but-not-yet-listening socket returns ECONNREFUSED while the socket file exists;
        // once listen() starts 30ms later, open_unix retries and delivers the head.
        let open_path = dir.path().join("transient-open.sock");
        let fd = bind_unlistening_unix(&open_path);
        let server = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(30)).await;
            let listener = start_listening_unix(fd);
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut got = [0u8; 5];
            socket.read_exact(&mut got).await.unwrap();
            got
        });
        let (_r, _w) = crate::net::open_unix(open_path.to_str().unwrap(), b"hello").await.expect("open_unix should recover from transient ECONNREFUSED");
        assert_eq!(&server.await.unwrap(), b"hello");

        // Same transient recovery for tell_unix.
        let tell_path = dir.path().join("transient-tell.sock");
        let fd = bind_unlistening_unix(&tell_path);
        let server = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(30)).await;
            let listener = start_listening_unix(fd);
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut got = [0u8; 4];
            socket.read_exact(&mut got).await.unwrap();
            got
        });
        crate::net::tell_unix(tell_path.to_str().unwrap(), b"skip").await.expect("tell_unix should recover from transient ECONNREFUSED");
        assert_eq!(&server.await.unwrap(), b"skip");
    });
}

#[cfg(unix)]
#[test]
fn conn_hand_sends_skip_on_delivery_failure_and_closes_when_unreachable() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let alpn = b"stillfail/test".to_vec();
        let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
        let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
        let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
        let addr = endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
        let dial = || {
            let (inner, a, b, addr, alpn) = (inner.clone(), a.clone(), b.clone(), addr.clone(), alpn.clone());
            async move {
                let taken = tokio::spawn(async move { b.accept().await.unwrap().await.unwrap() });
                let id = inner.keep_conn(a.connect(addr, &alpn).await.unwrap());
                (id, taken.await.unwrap())
            }
        };

        // Case 1: index == 0 fails (path unreachable) -> connection is closed rather than hung.
        {
            let (id, theirs) = dial().await;
            let missing = dir.path().join("case1-missing.sock");
            let handing = {
                let inner = inner.clone();
                let a = json!({ "id": id, "path": missing.to_str().unwrap() });
                tokio::spawn(async move { inner.run("conn.hand", a, None).await })
            };
            let (mut send, _recv) = theirs.open_bi().await.unwrap();
            send.write_all(b"{\"hello\":1}\n").await.unwrap();
            send.finish().unwrap();
            tokio::time::timeout(std::time::Duration::from_secs(2), theirs.closed())
                .await
                .expect("index 0 failure must close QUIC connection");
            handing.await.unwrap().unwrap();
        }

        // Case 2: index > 0 fails and path is permanently unreachable -> connection is closed.
        {
            let (id, theirs) = dial().await;
            let node = dir.path().join("case2-node.sock");
            let (said_to, mut said) = tokio::sync::mpsc::unbounded_channel();
            let node_task = taking_streams(tokio::net::UnixListener::bind(&node).unwrap(), "node", said_to);
            let handing = {
                let inner = inner.clone();
                let a = json!({ "id": id, "path": node.to_str().unwrap() });
                tokio::spawn(async move { inner.run("conn.hand", a, None).await })
            };
            let (mut send0, mut recv0) = theirs.open_bi().await.unwrap();
            send0.write_all(b"{\"hello\":1}\n").await.unwrap();
            send0.finish().unwrap();
            assert_eq!(String::from_utf8(recv0.read_to_end(1 << 16).await.unwrap()).unwrap(), "node");
            assert_eq!(said.recv().await.unwrap().2, 0);

            node_task.abort();
            let _ = node_task.await;
            std::fs::remove_file(&node).unwrap();

            let (mut send1, _recv1) = theirs.open_bi().await.unwrap();
            send1.write_all(b"{\"method\":\"GET\",\"path\":\"/lost\"}\n").await.unwrap();
            send1.finish().unwrap();
            tokio::time::timeout(std::time::Duration::from_secs(2), theirs.closed())
                .await
                .expect("unreachable path on index > 0 must close QUIC connection");
            handing.await.unwrap().unwrap();
        }

        // Case 3: routed stream succeeds at front, but tell_unix(node, skip) fails -> connection is closed.
        {
            let (id, theirs) = dial().await;
            let node = dir.path().join("case3-node.sock");
            let serve = dir.path().join("case3-serve.sock");
            let (said_to, mut said) = tokio::sync::mpsc::unbounded_channel();
            let node_task = taking_streams(tokio::net::UnixListener::bind(&node).unwrap(), "node", said_to.clone());
            let _serve_task = taking_streams(tokio::net::UnixListener::bind(&serve).unwrap(), "served", said_to);
            let handing = {
                let inner = inner.clone();
                let a = json!({ "id": id, "path": node.to_str().unwrap(), "front": [serve.to_str().unwrap()], "routes": ["GET /served"] });
                tokio::spawn(async move { inner.run("conn.hand", a, None).await })
            };
            let (mut send0, mut recv0) = theirs.open_bi().await.unwrap();
            send0.write_all(b"{\"hello\":1}\n").await.unwrap();
            send0.finish().unwrap();
            assert_eq!(String::from_utf8(recv0.read_to_end(1 << 16).await.unwrap()).unwrap(), "node");
            assert_eq!(said.recv().await.unwrap().2, 0);

            node_task.abort();
            let _ = node_task.await;
            std::fs::remove_file(&node).unwrap();

            let (mut send1, _recv1) = theirs.open_bi().await.unwrap();
            send1.write_all(b"{\"method\":\"GET\",\"path\":\"/served\"}\n").await.unwrap();
            send1.finish().unwrap();
            tokio::time::timeout(std::time::Duration::from_secs(2), theirs.closed())
                .await
                .expect("failed skip after routed stream must close QUIC connection");
            handing.await.unwrap().unwrap();
        }

        // Case 4: index > 0 delivery fails transiently, path recovers for skip -> kind 3 skip frame sent and next stream delivered.
        {
            let (id, theirs) = dial().await;
            let node = dir.path().join("case4-node.sock");
            let (said_to, mut said) = tokio::sync::mpsc::unbounded_channel();
            let node_task = taking_streams(tokio::net::UnixListener::bind(&node).unwrap(), "node", said_to.clone());
            let handing = {
                let inner = inner.clone();
                let a = json!({ "id": id, "path": node.to_str().unwrap() });
                tokio::spawn(async move { inner.run("conn.hand", a, None).await })
            };
            let (mut send0, mut recv0) = theirs.open_bi().await.unwrap();
            send0.write_all(b"{\"hello\":1}\n").await.unwrap();
            send0.finish().unwrap();
            assert_eq!(String::from_utf8(recv0.read_to_end(1 << 16).await.unwrap()).unwrap(), "node");
            assert_eq!(said.recv().await.unwrap(), ("node", 2, 0, b"{\"hello\":1}\n".to_vec()));

            // Stop listening while keeping a bound (unlistening) socket so open_unix exhausts retries and resets stream 1.
            node_task.abort();
            let _ = node_task.await;
            let unlistening_fd = bind_unlistening_unix(&node);

            let (mut send1, mut recv1) = theirs.open_bi().await.unwrap();
            send1.write_all(b"{\"method\":\"GET\",\"path\":\"/drop\"}\n").await.unwrap();
            send1.finish().unwrap();
            // Once stream 1 is reset, open_unix has failed and skip_or_close is about to tell_unix(node, skip).
            assert!(recv1.read_to_end(1 << 16).await.is_err());

            let _node_back = taking_streams(start_listening_unix(unlistening_fd), "node", said_to);
            let skip_msg = tokio::time::timeout(std::time::Duration::from_secs(2), said.recv())
                .await
                .expect("skip frame must arrive")
                .unwrap();
            assert_eq!(skip_msg, ("node", 3, 1, vec![]));

            // Subsequent stream (index 2) continues to be delivered normally on the same connection.
            let (mut send2, mut recv2) = theirs.open_bi().await.unwrap();
            send2.write_all(b"{\"method\":\"GET\",\"path\":\"/after\"}\n").await.unwrap();
            send2.finish().unwrap();
            assert_eq!(String::from_utf8(recv2.read_to_end(1 << 16).await.unwrap()).unwrap(), "node");
            assert_eq!(said.recv().await.unwrap(), ("node", 2, 2, b"{\"method\":\"GET\",\"path\":\"/after\"}\n".to_vec()));

            theirs.close(0u32.into(), b"bye");
            handing.await.unwrap().unwrap();
        }
    });
}

#[test]
fn lets_a_closed_connection_and_its_streams_go() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let alpn = b"stillfail/test".to_vec();
        let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
        let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
        let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
        let addr = endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
        // The other end kept, so its close is sent rather than its endpoint gone.
        let taking = b.clone();
        let taken = tokio::spawn(async move { taking.accept().await.unwrap().await.unwrap() });
        let id = inner.keep_conn(a.connect(addr, &alpn).await.unwrap());
        let theirs = taken.await.unwrap();
        let opened = inner.run("conn.openBi", json!({ "id": id }), None).await.unwrap();
        let stream = opened.json["id"].as_u64().unwrap();
        assert!(matches!(inner.handle(stream), Ok(Handle::IStream(_))));
        let remote = inner.run_sync("conn.remoteId", &json!({ "id": id })).unwrap();
        let alpn = inner.run_sync("conn.alpn", &json!({ "id": id })).unwrap();
        assert_eq!(alpn, json!(hex::encode(b"stillfail/test")));
        theirs.close(7u32.into(), b"bye");
        for _ in 0..200 {
            if matches!(inner.handle(id), Ok(Handle::Gone { .. })) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        // Let go, its stream with it; what the core asks after still answers.
        assert!(matches!(inner.handle(id), Ok(Handle::Gone { .. })));
        assert!(inner.handle(stream).is_err());
        assert_eq!(inner.run_sync("conn.closeReason", &json!({ "id": id })).unwrap(), json!({ "kind": "application", "reason": "bye", "text": "closed by peer: bye (code 7)" }));
        assert_eq!(inner.run_sync("conn.remoteId", &json!({ "id": id })).unwrap(), remote);
        assert_eq!(inner.run_sync("conn.alpn", &json!({ "id": id })).unwrap(), alpn);
        assert_eq!(inner.run_sync("conn.via", &json!({ "id": id })).unwrap(), Value::Null);
        assert!(inner.run_sync("conn.stats", &json!({ "id": id })).is_ok());
        assert_eq!(inner.run_sync("conn.paths", &json!({ "id": id })).unwrap(), json!([]));
        assert_eq!(inner.run("conn.closed", json!({ "id": id }), None).await.unwrap().json, json!({ "kind": "application", "reason": "bye", "text": "closed by peer: bye (code 7)" }));
        assert!(inner.run("conn.openBi", json!({ "id": id }), None).await.is_err());
        assert_eq!(inner.run("conn.acceptBi", json!({ "id": id }), None).await.unwrap().json, json!({ "end": true }));
    });
}

#[test]
fn forgets_closed_connections_and_endpoints_when_asked() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let alpn = b"stillfail/test".to_vec();
        let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
        let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
        let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
        let addr = endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
        let dial = || {
            let (inner, a, b, addr, alpn) = (inner.clone(), a.clone(), b.clone(), addr.clone(), alpn.clone());
            async move {
                let taken = tokio::spawn(async move { b.accept().await.unwrap().await.unwrap() });
                let id = inner.keep_conn(a.connect(addr, &alpn).await.unwrap());
                (id, taken.await.unwrap())
            }
        };

        // Closed by us, live with a stream open: let go at once, and its close later keeps nothing of it.
        let (id, theirs) = dial().await;
        let stream = inner.run("conn.openBi", json!({ "id": id }), None).await.unwrap().json["id"].as_u64().unwrap();
        assert!(matches!(inner.handle(stream), Ok(Handle::IStream(_))));
        inner.run("conn.close", json!({ "id": id, "code": 3, "reason": "done", "forget": true }), None).await.unwrap();
        theirs.closed().await;
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert!(inner.handle(id).is_err());
        assert!(inner.handle(stream).is_err());
        assert!(inner.run("conn.close", json!({ "id": id, "forget": true }), None).await.is_err());

        // Closed by the peer first: what was kept of it goes when the core is done with it.
        let (id, theirs) = dial().await;
        theirs.close(7u32.into(), b"bye");
        for _ in 0..200 {
            if matches!(inner.handle(id), Ok(Handle::Gone { .. })) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert!(matches!(inner.handle(id), Ok(Handle::Gone { .. })));
        inner.run("conn.close", json!({ "id": id, "forget": true }), None).await.unwrap();
        assert!(inner.handle(id).is_err());

        // Not a connection: refused, and kept.
        let other = inner.keep(Handle::Unbound { id: "x".into() });
        assert!(inner.run("conn.close", json!({ "id": other, "forget": true }), None).await.is_err());
        assert!(matches!(inner.handle(other), Ok(Handle::Unbound { .. })));

        // An endpoint let go as it closes, and one closed before let go after.
        let endpoint = inner.keep(Handle::Endpoint(bind(vec![]).await.unwrap(), Arc::default()));
        inner.run("iroh.close", json!({ "id": endpoint, "forget": true }), None).await.unwrap();
        assert!(inner.handle(endpoint).is_err());
        let endpoint = inner.keep(Handle::Endpoint(bind(vec![]).await.unwrap(), Arc::default()));
        inner.run("iroh.close", json!({ "id": endpoint }), None).await.unwrap();
        assert!(matches!(inner.handle(endpoint), Ok(Handle::Unbound { .. })));
        inner.run("iroh.close", json!({ "id": endpoint, "forget": true }), None).await.unwrap();
        assert!(inner.handle(endpoint).is_err());
    });
}

#[cfg(unix)]
#[test]
fn closing_a_connection_stops_a_half_open_piped_socket() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let alpn = b"stillfail/test".to_vec();
        let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
        let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
        let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
        let addr = endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
        let taking = b.clone();
        let taken = tokio::spawn(async move { taking.accept().await.unwrap().await.unwrap() });
        let id = inner.keep_conn(a.connect(addr, &alpn).await.unwrap());
        let theirs = taken.await.unwrap();
        let stream = inner.run("conn.openBi", json!({ "id": id }), None).await.unwrap().json["id"].as_u64().unwrap();
        let (ours, node) = tokio::net::UnixStream::pair().unwrap();
        let (read, write) = ours.into_split();
        let socket = inner.keep(Handle::tcp(read, write));
        let piping = {
            let inner = inner.clone();
            tokio::spawn(async move { inner.run("istream.pipe", json!({ "id": stream, "to": socket }), None).await })
        };
        let (mut _node_read, mut node_write) = node.into_split();
        node_write.write_all(&[0, 0, 0, 1, 9]).await.unwrap();
        let _peer = theirs.accept_bi().await.unwrap();
        // Even while Node keeps its Unix socket open, closing the connection ends the pipe.
        theirs.close(0u32.into(), b"bye");
        piping.await.unwrap().unwrap();
        assert!(inner.handle(stream).is_err());
    });
}

#[test]
fn puts_a_transcript_away_in_segments_and_reads_it_back_whole() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().join("shell"), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    let at = |p: &str| dir.path().join(p).display().to_string();
    let run = |op: &str, a: Value| shell.runtime.block_on(inner.run(op, a, None)).map(|answer| answer.json);
    let sizes = |v: &Value| v["frames"].as_array().unwrap().iter().map(|f| f[1].as_u64().unwrap()).collect::<Vec<_>>();
    // The frames as a table lists them: [at, packed, size].
    let listed = |v: &Value| {
        let mut from = 0;
        Value::Array(v["frames"].as_array().unwrap().iter().map(|f| {
            let (packed, size) = (f[0].as_u64().unwrap(), f[1].as_u64().unwrap());
            from += packed;
            json!([from - packed, packed, size])
        }).collect())
    };
    // Where each segment ends, 8 bytes at most: at its last line's end, at 8 where a line is longer, one made only
    // once more than 8 came (exactly 8: one; nothing: one, empty).
    for (content, want) in [
        (&b"abcdefg\n"[..], vec![8]),
        (b"abc\ndefgh", vec![4, 5]),
        (b"abcdefghijklmnopqrst", vec![8, 8, 4]),
        (b"", vec![0]),
        (b"1234567\n12345678", vec![8, 8]),
        (b"a\nb\nc\nd\ne\nf\ng\nh\n", vec![8, 8]),
        ("中文\n😀😀\n".as_bytes(), vec![7, 8, 1]),
    ] {
        std::fs::write(at("t.jsonl"), content).unwrap();
        let made = run("zstd.segments", json!({ "path": at("t.jsonl"), "out": at("t.zst"), "segment": 8 })).unwrap();
        assert_eq!(sizes(&made), want, "{content:?}");
        #[cfg(unix)]
        assert_eq!(std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(at("t.zst")).unwrap().permissions()) & 0o777, 0o600);
        // Each frame level 3 with its checksum, one stream to any zstd reader.
        let packed = std::fs::read(at("t.zst")).unwrap();
        assert_eq!(zstd::decode_all(packed.as_slice()).unwrap(), content);
        assert_ne!(packed[4] & 4, 0, "checksummed");
        let checked = run("zstd.check", json!({ "path": at("t.zst"), "frames": listed(&made), "same": at("t.jsonl") })).unwrap();
        use sha2::Digest;
        assert_eq!(checked, json!({ "size": content.len(), "sha256": hex::encode(sha2::Sha256::digest(content)) }));
    }
    // Compared with a file that changed meanwhile: how.
    let content: Vec<u8> = (0..5000u32).map(|i| if i % 97 == 96 { b'\n' } else { b'a' + (i % 26) as u8 }).collect();
    std::fs::write(at("t.jsonl"), &content).unwrap();
    let made = run("zstd.segments", json!({ "path": at("t.jsonl"), "out": at("t.zst"), "segment": 1000 })).unwrap();
    assert!(sizes(&made).len() >= 5);
    let check = |same: &str| run("zstd.check", json!({ "path": at("t.zst"), "frames": listed(&made), "same": at(same) })).unwrap();
    std::fs::write(at("short"), &content[..4000]).unwrap();
    assert_eq!(check("short"), json!({ "differs": "shortened" }));
    let mut longer = content.clone();
    longer.push(b'x');
    std::fs::write(at("longer"), &longer).unwrap();
    assert_eq!(check("longer"), json!({ "differs": "changed" }));
    let mut other = content.clone();
    other[4321] ^= 1;
    std::fs::write(at("other"), &other).unwrap();
    assert_eq!(check("other"), json!({ "differs": "changed" }));
    // Restored: written whole, 0600, as the frames hold it; without a table too.
    let whole = run("zstd.check", json!({ "path": at("t.zst"), "frames": listed(&made), "into": at("back") })).unwrap();
    assert_eq!((whole["size"].as_u64(), std::fs::read(at("back")).unwrap()), (Some(5000), content.clone()));
    assert_eq!(run("zstd.check", json!({ "path": at("t.zst"), "into": at("back2") })).unwrap(), whole);
    assert_eq!(std::fs::read(at("back2")).unwrap(), content);
    // Put away again from what zstd frames hold: one frame, several, with a skippable frame among them.
    let mut old = zstd::encode_all(&content[..3000], 19).unwrap();
    old.extend([0x5e, 0x2a, 0x4d, 0x18, 3, 0, 0, 0, 1, 2, 3]);
    old.extend(zstd::encode_all(&content[3000..], 1).unwrap());
    std::fs::write(at("old.zst"), &old).unwrap();
    let again = run("zstd.segments", json!({ "path": at("old.zst"), "unzstd": true, "out": at("new.zst"), "segment": 1000 })).unwrap();
    assert_eq!(sizes(&again), sizes(&made));
    assert_eq!(run("zstd.check", json!({ "path": at("new.zst"), "frames": listed(&again) })).unwrap(), whole);
    assert_eq!(run("zstd.check", json!({ "path": at("old.zst") })).unwrap(), whole);
    // A frame cut (its checksum's last byte), no frame at all, bytes after a frame within its place, a size the
    // table does not say: none read as whole.
    let one = {
        let mut z = zstd::bulk::Compressor::new(3).unwrap();
        z.set_parameter(zstd::zstd_safe::CParameter::ChecksumFlag(true)).unwrap();
        z.compress(b"the only copy of this history\n").unwrap()
    };
    std::fs::write(at("cut.zst"), &one[..one.len() - 1]).unwrap();
    assert!(run("zstd.check", json!({ "path": at("cut.zst") })).is_err());
    assert!(run("zstd.check", json!({ "path": at("cut.zst"), "frames": [[0, one.len() - 1, 30]] })).is_err());
    assert!(run("zstd.segments", json!({ "path": at("cut.zst"), "unzstd": true, "out": at("x.zst"), "segment": 8 })).is_err());
    assert!(run("zstd.check", json!({ "path": at("cut.zst"), "frames": [[0, 0, 0]] })).is_err());
    std::fs::write(at("empty.zst"), b"").unwrap();
    assert!(run("zstd.check", json!({ "path": at("empty.zst") })).is_err());
    assert!(run("zstd.segments", json!({ "path": at("empty.zst"), "unzstd": true, "out": at("x.zst"), "segment": 8 })).is_err());
    let mut trailing = one.clone();
    trailing.extend(b"xy");
    std::fs::write(at("trailing.zst"), &trailing).unwrap();
    assert!(run("zstd.check", json!({ "path": at("trailing.zst"), "frames": [[0, trailing.len(), 30]] })).is_err());
    std::fs::write(at("one.zst"), &one).unwrap();
    assert!(run("zstd.check", json!({ "path": at("one.zst"), "frames": [[0, one.len(), 31]] })).is_err());
    assert_eq!(run("zstd.check", json!({ "path": at("one.zst"), "frames": [[0, one.len(), 30]] })).unwrap()["size"], json!(30));
    assert!(run("zstd.segments", json!({ "path": at("none"), "out": at("x.zst"), "segment": 8 })).is_err());
}


/// A remote screen's view at 60 frames a second over a real iroh connection on this machine, its frames as datagrams
/// (screen_dgram.rs) with 2% and then 5% of them lost on the way, with the parity made for that loss and with none:
/// how many frames came, how many were given up (a key frame asked for instead), how long each took to come.
#[test]
fn a_screens_frames_as_datagrams_come_through_loss_at_once() {
    use crate::screen_dgram::{KEYFRAME_FRAME, MediaIn, MediaOut, MediaRx, route};
    use std::collections::HashMap;
    use tokio::time::{Duration, Instant};

    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    shell.runtime.block_on(async move {
        let alpn = b"stillfail/test".to_vec();
        let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
        let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
        let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
        let addr = endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
        let taking = b.clone();
        let taken = tokio::spawn(async move { taking.accept().await.unwrap().await.unwrap() });
        let client = a.connect(addr, &alpn).await.unwrap();
        let station = taken.await.unwrap();
        assert!(client.max_datagram_size().unwrap() >= 1024);
        let slot = StdMutex::default();
        const FRAMES: u64 = 240;
        let mut report = Vec::new();
        for (token, (loss, parity)) in [(0.02, true), (0.02, false), (0.05, true), (0.05, false)].into_iter().enumerate() {
            let token = token as u32 + 1;
            let (mut csend, mut crecv) = client.open_bi().await.unwrap();
            let (route, rx) = route(&slot, &client, token).unwrap();
            let mut rx = MediaRx { media: MediaIn::new(token, true), rx, rx_done: false, _route: route };
            csend.write_all(b"{\"screen\":{}}\n").await.unwrap();
            let (mut ssend, mut srecv) = station.accept_bi().await.unwrap();
            let sent: Arc<StdMutex<HashMap<u64, Instant>>> = Arc::default();
            let want_key = Arc::new(std::sync::atomic::AtomicBool::new(false));
            // the station: its head, a config, then the frames, a key frame every 2 s or as asked
            let sending = {
                let (station, sent, want_key) = (station.clone(), sent.clone(), want_key.clone());
                tokio::spawn(async move {
                    let mut line = [0u8; 14];
                    srecv.read_exact(&mut line).await.unwrap();
                    let asked = want_key.clone();
                    tokio::spawn(async move {
                        let mut f = [0u8; 5];
                        while srecv.read_exact(&mut f).await.is_ok() {
                            if f == KEYFRAME_FRAME {
                                asked.store(true, Ordering::Relaxed);
                            }
                        }
                    });
                    let mut media = MediaOut::new(station, token).unwrap();
                    media.lose = Some((loss, 0x9e37_79b9_7f4a_7c15 ^ token as u64));
                    media.assumed_loss = Some(loss);
                    media.no_parity = !parity;
                    media.write(&mut ssend, b"{\"status\":200}\n").await.unwrap();
                    let config = br#"{"codec":"h264","width":1920,"height":1080}"#;
                    let mut f = vec![1u8];
                    f.extend((config.len() as u32).to_be_bytes());
                    f.extend(config);
                    media.write(&mut ssend, &f).await.unwrap();
                    let start = Instant::now();
                    for i in 0..FRAMES {
                        tokio::time::sleep_until(start + Duration::from_micros(16_667 * i)).await;
                        let key = i % 120 == 0 || want_key.swap(false, Ordering::Relaxed);
                        let len = if key { 90_000 } else { 9_000 + (i as usize * 7919) % 12_000 };
                        let mut body = vec![key as u8];
                        body.extend(i.to_be_bytes());
                        body.extend((0..len).map(|j| (j as u64 * 31 + i) as u8));
                        let mut f = vec![2u8];
                        f.extend((body.len() as u32).to_be_bytes());
                        f.extend(body);
                        sent.lock().unwrap().insert(i, Instant::now());
                        media.write(&mut ssend, &f).await.unwrap();
                    }
                    ssend.finish().unwrap();
                })
            };
            // the client: what a read gives, its frames taken apart
            let mut buf = vec![0u8; 64 * 1024];
            let mut bytes: Vec<u8> = Vec::new();
            let mut line = false;
            let mut got: Vec<(u64, bool, Duration)> = Vec::new();
            loop {
                if rx.media.at_boundary() {
                    rx.media.drain_into(&mut bytes);
                }
                if rx.media.take_keyframe(Instant::now()) {
                    csend.write_all(&KEYFRAME_FRAME).await.unwrap();
                }
                if !line {
                    if let Some(at) = bytes.iter().position(|&b| b == b'\n') {
                        bytes.drain(..=at);
                        line = true;
                    }
                }
                while line && bytes.len() >= 5 {
                    let len = u32::from_be_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
                    if bytes.len() < 5 + len {
                        break;
                    }
                    if bytes[0] == 2 {
                        let i = u64::from_be_bytes(bytes[6..14].try_into().unwrap());
                        assert!(bytes[14..5 + len].iter().enumerate().all(|(j, &v)| v == (j as u64 * 31 + i) as u8), "frame {i} made whole as it was sent");
                        let at = sent.lock().unwrap()[&i];
                        got.push((i, bytes[5] & 1 == 1, at.elapsed()));
                    }
                    bytes.drain(..5 + len);
                }
                let deadline = rx.media.deadline();
                tokio::select! {
                    read = crecv.read(&mut buf) => match read.unwrap() {
                        Some(n) => {
                            let chunk = &buf[..n];
                            match rx.media.stream(chunk, Instant::now()) {
                                Some(b) => {
                                    bytes.extend_from_slice(&chunk[..b]);
                                    rx.media.drain_into(&mut bytes);
                                    bytes.extend_from_slice(&chunk[b..]);
                                }
                                None => bytes.extend_from_slice(chunk),
                            }
                        }
                        None => break,
                    },
                    d = rx.next() => rx.take_waiting(d, Instant::now()),
                    _ = crate::screen_dgram::until(deadline) => rx.media.tick(Instant::now()),
                }
            }
            sending.await.unwrap();
            // never a frame that lost the one before it: each a key frame or the one after the last given
            for w in got.windows(2) {
                assert!(w[1].1 || w[1].0 == w[0].0 + 1, "frame {} given after {}", w[1].0, w[0].0);
            }
            let mut ms: Vec<f64> = got.iter().map(|g| g.2.as_secs_f64() * 1000.0).collect();
            ms.sort_by(f64::total_cmp);
            let pct = |p: f64| if ms.is_empty() { f64::NAN } else { ms[((ms.len() - 1) as f64 * p).round() as usize] };
            let c = rx.media.counts;
            let line = format!(
                "loss {:.0}% parity {}: {}/{} frames ({:.1}%), {} given up, {} key frames asked, P50 {:.2} ms P99 {:.2} ms max {:.2} ms",
                loss * 100.0, if parity { "adaptive" } else { "none" }, got.len(), FRAMES, got.len() as f64 * 100.0 / FRAMES as f64, c.given_up, c.keyframes, pct(0.5), pct(0.99), pct(1.0)
            );
            eprintln!("{line}");
            report.push((loss, parity, got.len() as f64 / FRAMES as f64));
        }
        // with parity for the loss, nearly every frame comes; without, many are given up
        for (loss, parity, came) in &report {
            if *parity {
                assert!(*came >= if *loss < 0.03 { 0.97 } else { 0.93 }, "{loss} {came}");
            }
        }
        assert!(report[0].2 > report[1].2 && report[2].2 > report[3].2);
    });
}

/// With `control: true`, `ws.ping` sends a Ping frame and `ws.next` surfaces incoming Pong and Ping frames (while
/// tungstenite still replies with Pong to server Pings).
#[test]
fn ws_control_frames_and_ping_roundtrip() {
    use futures::StreamExt;
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let call = |id: u64, op: &str, a: Value| {
        shell.call(id, op.into(), a.to_string().as_bytes(), None);
        let (json, error, _) = answer(id);
        assert_eq!(error, "", "{op}");
        serde_json::from_str::<Value>(&json).unwrap()
    };
    let (listener, addr) = shell.runtime.block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        (listener, addr)
    });
    let served = shell.runtime.spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(socket).await.unwrap();
        // Receive client's ws.ping and reply with Pong.
        let got_ping = ws.next().await.unwrap().unwrap();
        match got_ping {
            Message::Ping(payload) => ws.send(Message::Pong(payload)).await.unwrap(),
            other => panic!("expected Ping from client, got {other:?}"),
        }
        // Send a server Ping and expect client's automatic Pong reply.
        ws.send(Message::Ping(Default::default())).await.unwrap();
        let got_pong = ws.next().await.unwrap().unwrap();
        assert!(matches!(got_pong, Message::Pong(_)), "expected Pong from client, got {got_pong:?}");
        // Wait for client close.
        let _ = ws.next().await;
    });
    let opened = call(98_001, "ws.open", json!({ "url": format!("ws://{addr}/"), "control": true }));
    let ws_id = opened["id"].as_u64().unwrap();
    call(98_002, "ws.ping", json!({ "id": ws_id }));
    assert_eq!(call(98_003, "ws.next", json!({ "id": ws_id })), json!({ "pong": true }));
    assert_eq!(call(98_004, "ws.next", json!({ "id": ws_id })), json!({ "ping": true }));
    call(98_005, "ws.close", json!({ "id": ws_id }));
    shell.runtime.block_on(served).unwrap();
}

/// Without `control`, Ping and Pong frames stay internal and `ws.next` skips straight to the next data frame.
#[test]
fn ws_without_control_skips_ping_and_pong_frames() {
    use futures::StreamExt;
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let call = |id: u64, op: &str, a: Value| {
        shell.call(id, op.into(), a.to_string().as_bytes(), None);
        let (json, error, _) = answer(id);
        assert_eq!(error, "", "{op}");
        serde_json::from_str::<Value>(&json).unwrap()
    };
    let (listener, addr) = shell.runtime.block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        (listener, addr)
    });
    let served = shell.runtime.spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(socket).await.unwrap();
        ws.send(Message::Ping(Default::default())).await.unwrap();
        ws.send(Message::Pong(Default::default())).await.unwrap();
        ws.send(Message::text("hi")).await.unwrap();
        let _ = ws.next().await;
    });
    let opened = call(98_011, "ws.open", json!({ "url": format!("ws://{addr}/") }));
    let ws_id = opened["id"].as_u64().unwrap();
    assert_eq!(call(98_012, "ws.next", json!({ "id": ws_id })), json!({ "text": "hi" }));
    call(98_013, "ws.close", json!({ "id": ws_id }));
    shell.runtime.block_on(served).unwrap();
}

/// A test's server on 127.0.0.1, its listener taken by `serve` on the shell's runtime; its address.
fn served<F, T>(shell: &Shell, serve: impl FnOnce(tokio::net::TcpListener) -> F) -> (std::net::SocketAddr, tokio::task::JoinHandle<T>)
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let listener = shell.runtime.block_on(tokio::net::TcpListener::bind("127.0.0.1:0")).unwrap();
    let addr = listener.local_addr().unwrap();
    (addr, shell.runtime.spawn(serve(listener)))
}

/// What came of call `id` asked with `a`: its JSON, or its error.
fn asked(shell: &Shell, id: u64, op: &str, a: Value) -> Result<Value, String> {
    shell.call(id, op.into(), a.to_string().as_bytes(), None);
    let (json, error, _) = answer(id);
    if error.is_empty() { Ok(serde_json::from_str(&json).unwrap()) } else { Err(error) }
}

/// An HTTP request's head read off `socket`.
async fn head_of(socket: &mut tokio::net::TcpStream) -> String {
    let mut request = Vec::new();
    while !request.ends_with(b"\r\n\r\n") {
        request.push(socket.read_u8().await.unwrap());
    }
    String::from_utf8(request).unwrap()
}

/// The other side's Close frame reaches `ws.next` with its code and reason (the plane's 4000, a presence socket
/// replaced, and 4004, its station removed); one with none, and the socket's end after it, say only its end.
#[test]
fn a_close_frames_code_and_reason_reach_ws_next() {
    use tokio_tungstenite::tungstenite::protocol::CloseFrame;
    use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let (addr, server) = served(&shell, |listener| async move {
        for frame in [Some((4000, "replaced")), Some((4004, "removed")), None] {
            let (socket, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(socket).await.unwrap();
            ws.close(frame.map(|(code, reason)| CloseFrame { code: CloseCode::from(code), reason: reason.into() })).await.unwrap();
        }
    });
    for (n, said) in [(0, json!({ "end": true, "code": 4000, "reason": "replaced" })), (1, json!({ "end": true, "code": 4004, "reason": "removed" })), (2, json!({ "end": true }))] {
        let ws = asked(&shell, 96_000 + n * 10, "ws.open", json!({ "url": format!("ws://{addr}/v1/presence") })).unwrap()["id"].clone();
        assert_eq!(asked(&shell, 96_001 + n * 10, "ws.next", json!({ "id": ws })), Ok(said));
        assert_eq!(asked(&shell, 96_002 + n * 10, "ws.next", json!({ "id": ws })), Ok(json!({ "end": true })));
        asked(&shell, 96_003 + n * 10, "ws.close", json!({ "id": ws })).unwrap();
    }
    shell.runtime.block_on(server).unwrap();
}

/// A WebSocket whose Upgrade is never answered fails once its `timeoutMs` passed, directly and through an entry; one
/// cancelled while it waits (`fetch.cancel`) drops its socket, and nothing of it is kept.
#[test]
fn a_websocket_opening_ends_by_its_deadline_or_when_cancelled() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let (heard, mut hearing) = tokio::sync::mpsc::unbounded_channel();
    let (addr, _server) = served(&shell, |listener| async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let heard = heard.clone();
            tokio::spawn(async move {
                head_of(&mut socket).await;
                let _ = heard.send(());
                // Never answered; what the read ends with is the client's socket closing.
                let _ = socket.read_u8().await;
                let _ = heard.send(());
            });
        }
    });
    let entry = json!({ "host": "127.0.0.1", "port": addr.port() });
    for (id, a) in [(96_101, json!({ "url": format!("ws://{addr}/"), "timeoutMs": 150 })), (96_102, json!({ "url": "ws://cloud.invalid/", "entry": entry, "timeoutMs": 150 }))] {
        assert_eq!(asked(&shell, id, "ws.open", a), Err("websocket: open timed out within 150 ms".to_string()));
    }
    let kept = shell.inner.handles.lock().unwrap().len();
    shell.call(96_103, "ws.open".into(), json!({ "url": format!("ws://{addr}/") }).to_string().as_bytes(), None);
    shell.runtime.block_on(async {
        for _ in 0..5 {
            hearing.recv().await.unwrap();
        }
    });
    let cancel = || serde_json::from_slice::<Value>(&shell.call_sync("fetch.cancel", json!({ "id": 96_103 }).to_string().as_bytes())).unwrap();
    assert_eq!(cancel(), json!({ "value": true }));
    assert_eq!(answer(96_103).1, "cancelled");
    shell.runtime.block_on(hearing.recv()).unwrap();
    assert_eq!(cancel(), json!({ "value": false }));
    assert_eq!(shell.inner.handles.lock().unwrap().len(), kept);
}

/// `stream.open` given `timeoutMs` fails once its head has not come by then; `stream.read` given `stallMs` (or
/// `timeoutMs`) once its next piece has not.
#[test]
fn a_streams_head_and_pieces_end_by_their_deadlines() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let (addr, _server) = served(&shell, |listener| async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            tokio::spawn(async move {
                if head_of(&mut socket).await.starts_with("GET /body") {
                    socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\na").await.unwrap();
                }
                // Nothing more comes, and the socket stays open.
                let _ = socket.read_u8().await;
            });
        }
    });
    let at = |path: &str, within: Value| {
        let mut a = json!({ "url": format!("http://{addr}{path}"), "method": "GET", "headers": [] });
        a.as_object_mut().unwrap().extend(within.as_object().unwrap().clone());
        a
    };
    assert_eq!(asked(&shell, 96_201, "stream.open", at("/head", json!({ "timeoutMs": 150 }))), Err("no answer within 150 ms".to_string()));
    let stream = asked(&shell, 96_202, "stream.open", at("/body", json!({ "timeoutMs": 5000 }))).unwrap();
    assert_eq!((stream["status"].clone(), stream["redirected"].clone()), (json!(200), json!(false)));
    shell.call(96_203, "stream.read".into(), json!({ "id": stream["id"] }).to_string().as_bytes(), None);
    assert_eq!(answer(96_203).2.unwrap(), b"a");
    for (id, within) in [(96_204, json!({ "stallMs": 150 })), (96_205, json!({ "timeoutMs": 150 }))] {
        let mut a = json!({ "id": stream["id"] });
        a.as_object_mut().unwrap().extend(within.as_object().unwrap().clone());
        assert_eq!(asked(&shell, id, "stream.read", a), Err("nothing more came within 150 ms".to_string()));
    }
}

/// A 302 is answered as it came where `redirect` is not `"follow"` (said or not: `"manual"`), `redirected` false;
/// followed where it is, its target's answer `redirected`, for `fetch` and `stream.open` alike.
#[test]
fn redirects_are_followed_only_when_asked() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let (addr, _server) = served(&shell, |listener| async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            tokio::spawn(async move {
                loop {
                    let head = head_of(&mut socket).await;
                    let answer: &[u8] = if head.starts_with("GET /from ") {
                        b"HTTP/1.1 302 Found\r\nLocation: /to\r\nContent-Length: 0\r\n\r\n"
                    } else {
                        b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nthere"
                    };
                    if socket.write_all(answer).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    let from = |redirect: Option<&str>| {
        let mut a = json!({ "url": format!("http://{addr}/from"), "method": "GET", "headers": [] });
        if let Some(r) = redirect {
            a["redirect"] = json!(r);
        }
        a
    };
    for (n, redirect) in [None, Some("manual")].into_iter().enumerate() {
        let n = n as u64 * 10;
        shell.call(96_301 + n, "fetch".into(), from(redirect).to_string().as_bytes(), None);
        let (said, error, body) = answer(96_301 + n);
        assert_eq!(error, "");
        let said: Value = serde_json::from_str(&said).unwrap();
        assert_eq!((said["status"].clone(), said["redirected"].clone(), body.unwrap()), (json!(302), json!(false), Vec::new()));
        let stream = asked(&shell, 96_302 + n, "stream.open", from(redirect)).unwrap();
        assert_eq!((stream["status"].clone(), stream["redirected"].clone()), (json!(302), json!(false)));
    }
    shell.call(96_321, "fetch".into(), from(Some("follow")).to_string().as_bytes(), None);
    let (said, error, body) = answer(96_321);
    assert_eq!(error, "");
    let said: Value = serde_json::from_str(&said).unwrap();
    assert_eq!((said["status"].clone(), said["redirected"].clone(), body.unwrap()), (json!(200), json!(true), b"there".to_vec()));
    let stream = asked(&shell, 96_322, "stream.open", from(Some("follow"))).unwrap();
    assert_eq!((stream["status"].clone(), stream["redirected"].clone()), (json!(200), json!(true)));
}

/// A WebSocket handshake refusal carries why the server refused it (Slack's `handshake-msg` header, Comma's JSON
/// `error`/`message`, or plain body text collapsed to one line and capped at 300 characters), while an empty body
/// keeps the bare `websocket refused (<status>)` form.
#[test]
fn ws_open_preserves_handshake_refusal_words() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let long_zh_body = format!("  {}\n\t{}  ", "冲突提示".repeat(80), "尾部");
    let expected_zh = format!("{}…", "冲突提示".repeat(80).chars().take(299).collect::<String>());
    let long_zh_for_server = long_zh_body.clone();
    let (addr, _server) = served(&shell, move |listener| {
        let long_zh = long_zh_for_server.clone();
        async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let long_zh = long_zh.clone();
                tokio::spawn(async move {
                    let head = head_of(&mut socket).await;
                    let answer: Vec<u8> = if head.starts_with("GET /comma-conflict ") {
                        let body = r#"{"error":"this still.fail workspace is connected to station Alpha already"}"#;
                        format!("HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).into_bytes()
                    } else if head.starts_with("GET /slack-header ") {
                        let body = r#"{"error":"ignored when handshake-msg is present"}"#;
                        format!("HTTP/1.1 403 Forbidden\r\nhandshake-msg:  too_many_websockets \r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).into_bytes()
                    } else if head.starts_with("GET /empty-502 ") {
                        b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec()
                    } else if head.starts_with("GET /long-utf8 ") {
                        format!("HTTP/1.1 409 Conflict\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{long_zh}", long_zh.len()).into_bytes()
                    } else {
                        let body = r#"{"message":"  line one\n\tline two  "}"#;
                        format!("HTTP/1.1 400 Bad Request\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).into_bytes()
                    };
                    let _ = socket.write_all(&answer).await;
                });
            }
        }
    });
    let open = |id: u64, path: &str| {
        asked(&shell, id, "ws.open", json!({ "url": format!("ws://{addr}{path}"), "headers": [] }))
    };
    assert_eq!(
        open(96_401, "/comma-conflict"),
        Err("websocket refused (409): this still.fail workspace is connected to station Alpha already".to_string())
    );
    assert_eq!(
        open(96_402, "/slack-header"),
        Err("websocket refused (403): too_many_websockets".to_string())
    );
    assert_eq!(
        open(96_403, "/empty-502"),
        Err("websocket refused (502)".to_string())
    );
    assert_eq!(
        open(96_404, "/long-utf8"),
        Err(format!("websocket refused (409): {expected_zh}"))
    );
    assert_eq!(
        open(96_405, "/message-field"),
        Err("websocket refused (400): line one line two".to_string())
    );
}

#[test]
fn rotates_a_log_in_place_keeping_its_tail_and_inode() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().join("shell"), complete, ctx()).unwrap();
    let rotate = |id: u64, args: Value| -> Value {
        shell.call(id, "fs.rotate".into(), args.to_string().as_bytes(), None);
        let (json, error, _) = answer(id);
        assert_eq!(error, "");
        serde_json::from_str::<Value>(&json).unwrap()
    };

    // Missing file returns false.
    let missing = dir.path().join("missing.log");
    assert_eq!(rotate(96_501, json!({ "path": missing.display().to_string(), "cap": 100 })), json!(false));

    // File at or below cap returns false and leaves no .1 or .1.tmp behind.
    let log = dir.path().join("job.log");
    let backup = dir.path().join("job.log.1");
    let tmp = dir.path().join("job.log.1.tmp");
    std::fs::write(&log, vec![b'a'; 100]).unwrap();
    assert_eq!(rotate(96_502, json!({ "path": log.display().to_string(), "cap": 100.0 })), json!(false));
    assert!(!backup.exists() && !tmp.exists());
    assert_eq!(std::fs::metadata(&log).unwrap().len(), 100);

    // File past cap (> 64 KiB so the streaming buffer loops) with custom keep < cap (as floats).
    let data: Vec<u8> = (0..150_000u32).map(|i| (i % 251) as u8).collect();
    std::fs::write(&log, &data).unwrap();
    #[cfg(unix)]
    let ino_before = {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(&log).unwrap().ino()
    };
    assert_eq!(
        rotate(96_503, json!({ "path": log.display().to_string(), "cap": 100_000.0, "keep": 80_000.0 })),
        json!(true)
    );
    assert_eq!(std::fs::metadata(&log).unwrap().len(), 0);
    assert!(!tmp.exists());
    assert_eq!(std::fs::read(&backup).unwrap(), &data[data.len() - 80_000..]);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        assert_eq!(std::fs::metadata(&log).unwrap().ino(), ino_before);
        assert_eq!(std::fs::metadata(&backup).unwrap().permissions().mode() & 0o777, 0o600);
    }

    // Default keep (omitted) equals cap.
    let data2: Vec<u8> = (0..120_000u32).map(|i| ((i * 3) % 251) as u8).collect();
    std::fs::write(&log, &data2).unwrap();
    assert_eq!(rotate(96_504, json!({ "path": log.display().to_string(), "cap": 70_000 })), json!(true));
    assert_eq!(std::fs::metadata(&log).unwrap().len(), 0);
    assert!(!tmp.exists());
    assert_eq!(std::fs::read(&backup).unwrap(), &data2[data2.len() - 70_000..]);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        assert_eq!(std::fs::metadata(&log).unwrap().ino(), ino_before);
        assert_eq!(std::fs::metadata(&backup).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

#[test]
fn iroh_insert_relay_preserves_entries_and_disabled_relays_applies() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let call = |id: u64, op: &str, a: Value, bytes: Option<Vec<u8>>| {
        shell.call(id, op.into(), a.to_string().as_bytes(), bytes);
        let (json, error, _) = answer(id);
        assert_eq!(error, "", "{op}");
        serde_json::from_str::<Value>(&json).unwrap()
    };
    let r1 = "https://r1.invalid/";
    let r2 = "https://r2.invalid/";
    let entry1 = "https://entry1.invalid/";
    let entry2 = "https://entry2.invalid/";
    let bound = call(
        97_101,
        "iroh.bind",
        json!({
            "relayUrls": [r1, r2],
            "relayEntries": [{ "entry": entry1, "relay": r1 }],
            "alpns": [],
            "lookup": false,
            "relayOnly": true,
        }),
        Some(vec![9; 32]),
    );
    let ep = bound["id"].as_u64().unwrap();

    // Update entries, remove r1, re-insert r1, and verify the kept entries stay intact and disabledRelays succeeds.
    call(
        97_102,
        "iroh.setRelayEntries",
        json!({ "id": ep, "entries": [{ "entry": entry2, "relay": r1 }] }),
        None,
    );
    call(97_103, "iroh.removeRelay", json!({ "id": ep, "url": r1 }), None);
    call(97_104, "iroh.insertRelay", json!({ "id": ep, "url": r1 }), None);
    let peer = hex::encode(SecretKey::from_bytes(&[11; 32]).public().as_bytes());
    call(
        97_105,
        "iroh.disabledRelays",
        json!({ "id": ep, "peer": peer, "relays": [r2] }),
        None,
    );
    call(
        97_106,
        "iroh.disabledRelays",
        json!({ "id": ep, "peer": peer, "relays": [] }),
        None,
    );

    let (endpoint, kept) = match shell.inner.handles.lock().unwrap().get(&ep) {
        Some(Handle::Endpoint(endpoint, kept)) => (endpoint.clone(), kept.clone()),
        _ => panic!("expected endpoint handle"),
    };
    let kept_entries = shell.runtime.block_on(async { kept.entries.lock().await.clone() });
    assert_eq!(kept_entries.len(), 1);
    assert_eq!(kept_entries[0].0.to_string(), entry2);
    assert_eq!(kept_entries[0].1.to_string(), r1);
    let r1_url: iroh::RelayUrl = r1.parse().unwrap();
    let removed = shell.runtime.block_on(endpoint.remove_relay(&r1_url)).expect("r1 should be present after insertRelay");
    assert_eq!(removed.entries.len(), 1);
    assert_eq!(removed.entries[0].to_string(), entry2);

    call(97_107, "iroh.close", json!({ "id": ep, "forget": true }), None);
}

#[test]
fn tcp_close_aborts_blocked_tcp_read() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let (ours, _peer) = tokio::io::duplex(256);
        let (r, w) = tokio::io::split(ours);
        let conn = inner.keep(Handle::tcp(r, w));
        let Handle::Tcp { close, .. } = inner.handle(conn).unwrap() else { panic!("expected tcp handle") };

        let mut reader = std::pin::pin!(inner.run("tcp.read", json!({ "id": conn }), None));
        assert!(futures::poll!(reader.as_mut()).is_pending(), "tcp.read should park waiting for peer data");

        inner.run("tcp.close", json!({ "id": conn }), None).await.unwrap();
        assert!(close.is_closed(), "tcp.close must mark SocketClose closed");
        let err = tokio::time::timeout(std::time::Duration::from_secs(3), reader)
            .await
            .expect("tcp.read should return promptly after tcp.close")
            .err()
            .expect("tcp.read should fail on tcp.close");
        assert!(err.contains("closed"), "unexpected error: {err}");

        // Repeated tcp.close is idempotent and subsequent tcp.read fails with unknown handle.
        inner.run("tcp.close", json!({ "id": conn }), None).await.unwrap();
        let after = inner.run("tcp.read", json!({ "id": conn }), None).await.err().unwrap();
        assert!(after.contains("no handle"), "unexpected error after close: {after}");
    });
}

#[test]
fn tcp_close_aborts_backpressured_tcp_write() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let (ours, mut peer) = tokio::io::duplex(256);
        let (r, w) = tokio::io::split(ours);
        let conn = inner.keep(Handle::tcp(r, w));
        let Handle::Tcp { close, .. } = inner.handle(conn).unwrap() else { panic!("expected tcp handle") };

        let payload = vec![0x5au8; 4096];
        let writer = {
            let inner = inner.clone();
            tokio::spawn(async move { inner.run("tcp.write", json!({ "id": conn }), Some(payload)).await })
        };
        // Read 1 byte from peer to prove tcp.write has entered write_all and filled the 256-byte duplex.
        let mut first = [0u8; 1];
        tokio::time::timeout(std::time::Duration::from_secs(3), peer.read_exact(&mut first))
            .await
            .expect("tcp.write should start writing into duplex")
            .unwrap();
        assert_eq!(first, [0x5a]);
        tokio::task::yield_now().await;
        assert!(!writer.is_finished(), "tcp.write should block on duplex backpressure while peer stops reading");

        inner.run("tcp.close", json!({ "id": conn }), None).await.unwrap();
        assert!(close.is_closed(), "tcp.close must mark SocketClose closed");
        let err = tokio::time::timeout(std::time::Duration::from_secs(3), writer)
            .await
            .expect("tcp.write should return promptly after tcp.close")
            .unwrap()
            .err()
            .expect("tcp.write should fail on tcp.close");
        assert!(err.contains("closed"), "unexpected error: {err}");
    });
}

#[test]
fn tcp_close_aborts_queued_tcp_read_and_write_on_mutex_lock() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let (ours, _peer) = tokio::io::duplex(256);
        let (r, w) = tokio::io::split(ours);
        let conn = inner.keep(Handle::tcp(r, w));
        let Handle::Tcp { read, write, close } = inner.handle(conn).unwrap() else { panic!("expected tcp handle") };

        // Hold both mutex guards across tcp.close so tcp.read, tcp.write, and tcp.end can only complete via
        // the lock-wait `select!` on `close.cancelled()` (not by acquiring the lock after an earlier holder exits).
        let read_guard = read.lock().await;
        let write_guard = write.lock().await;

        let mut queued_read = std::pin::pin!(inner.run("tcp.read", json!({ "id": conn }), None));
        let mut queued_write = std::pin::pin!(inner.run("tcp.write", json!({ "id": conn }), Some(b"queued".to_vec())));
        let mut queued_end = std::pin::pin!(inner.run("tcp.end", json!({ "id": conn }), None));
        // Deterministically advance each future past handle lookup and into its lock-wait `select!`.
        assert!(futures::poll!(queued_read.as_mut()).is_pending());
        assert!(futures::poll!(queued_write.as_mut()).is_pending());
        assert!(futures::poll!(queued_end.as_mut()).is_pending());

        inner.run("tcp.close", json!({ "id": conn }), None).await.unwrap();
        assert!(close.is_closed());

        let read_err = tokio::time::timeout(std::time::Duration::from_secs(3), queued_read)
            .await
            .expect("queued tcp.read should abort while read lock is still held")
            .err()
            .expect("queued tcp.read should fail on tcp.close");
        let write_err = tokio::time::timeout(std::time::Duration::from_secs(3), queued_write)
            .await
            .expect("queued tcp.write should abort while write lock is still held")
            .err()
            .expect("queued tcp.write should fail on tcp.close");
        let end_res = tokio::time::timeout(std::time::Duration::from_secs(3), queued_end)
            .await
            .expect("queued tcp.end should return promptly while write lock is still held");
        assert!(read_err.contains("closed"), "unexpected read error: {read_err}");
        assert!(write_err.contains("closed"), "unexpected write error: {write_err}");
        assert!(end_res.is_ok(), "queued tcp.end should succeed on tcp.close: {:?}", end_res.err());

        drop((read_guard, write_guard));
    });
}

#[test]
fn tcp_end_preserves_half_close_for_in_flight_tcp_read() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let conn = inner.run("tcp.open", json!({ "port": port }), None).await.unwrap().json["id"].as_u64().unwrap();
        let (peer, _) = listener.accept().await.unwrap();
        let (mut peer_read, mut peer_write) = peer.into_split();
        let Handle::Tcp { close, .. } = inner.handle(conn).unwrap() else { panic!("expected tcp handle") };

        let mut reader = std::pin::pin!(inner.run("tcp.read", json!({ "id": conn }), None));
        assert!(futures::poll!(reader.as_mut()).is_pending(), "tcp.read should park waiting for peer data");

        // Half-close write side; peer observes EOF, while in-flight tcp.read stays open.
        inner.run("tcp.end", json!({ "id": conn }), None).await.unwrap();
        assert!(!close.is_closed(), "tcp.end must not trigger SocketClose");
        let mut peer_eof = Vec::new();
        let n = tokio::time::timeout(std::time::Duration::from_secs(3), peer_read.read_to_end(&mut peer_eof))
            .await
            .expect("peer should observe EOF after tcp.end")
            .unwrap();
        assert_eq!(n, 0);
        assert!(futures::poll!(reader.as_mut()).is_pending(), "tcp.end must not cancel in-flight tcp.read");

        peer_write.write_all(b"after-half-close").await.unwrap();
        drop(peer_write);

        let first = tokio::time::timeout(std::time::Duration::from_secs(3), reader)
            .await
            .expect("in-flight tcp.read should receive peer data after tcp.end")
            .unwrap();
        let mut received = first.bytes.unwrap_or_default();
        if first.json.get("end") != Some(&json!(true)) {
            loop {
                let next = tokio::time::timeout(
                    std::time::Duration::from_secs(3),
                    inner.run("tcp.read", json!({ "id": conn }), None),
                )
                .await
                .expect("tcp.read should reach peer EOF")
                .unwrap();
                if let Some(chunk) = next.bytes {
                    received.extend_from_slice(&chunk);
                }
                if next.json.get("end") == Some(&json!(true)) {
                    break;
                }
            }
        }
        assert_eq!(received, b"after-half-close");

        inner.run("tcp.close", json!({ "id": conn }), None).await.unwrap();
        assert!(close.is_closed());
    });
}

#[test]
fn tcp_pipe_transfers_ownership_without_cancelling_stream() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let front = inner.run("tcp.listen", json!({ "port": 0 }), None).await.unwrap().json;
        let front_port = front["port"].as_u64().unwrap() as u16;
        let target = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target_port = target.local_addr().unwrap().port();

        let client = tokio::net::TcpStream::connect(("127.0.0.1", front_port)).await.unwrap();
        let accepted = inner.run("tcp.accept", json!({ "id": front["id"] }), None).await.unwrap().json["id"].as_u64().unwrap();
        let opened = inner.run("tcp.open", json!({ "port": target_port }), None).await.unwrap().json["id"].as_u64().unwrap();
        let (server, _) = target.accept().await.unwrap();

        let Handle::Tcp { close: close_accepted, .. } = inner.handle(accepted).unwrap() else { panic!("expected tcp handle") };
        let Handle::Tcp { close: close_opened, .. } = inner.handle(opened).unwrap() else { panic!("expected tcp handle") };

        let piping = {
            let inner = inner.clone();
            tokio::spawn(async move { inner.run("tcp.pipe", json!({ "ids": [accepted, opened] }), None).await })
        };

        let (mut client_read, mut client_write) = client.into_split();
        let (mut server_read, mut server_write) = server.into_split();
        let forward: Vec<u8> = (0..262_144u32).map(|i| (i % 251) as u8).collect();
        let backward: Vec<u8> = (0..131_072u32).map(|i| ((i * 7) % 251) as u8).collect();

        let forward_expected = forward.clone();
        let send_forward = tokio::spawn(async move {
            client_write.write_all(&forward).await.unwrap();
            client_write.shutdown().await.unwrap();
        });
        let mut got_forward = Vec::new();
        tokio::time::timeout(std::time::Duration::from_secs(3), server_read.read_to_end(&mut got_forward))
            .await
            .expect("forward pipe transfer should finish")
            .unwrap();
        send_forward.await.unwrap();
        assert_eq!(got_forward, forward_expected);

        let backward_expected = backward.clone();
        let send_backward = tokio::spawn(async move {
            server_write.write_all(&backward).await.unwrap();
            server_write.shutdown().await.unwrap();
        });
        let mut got_backward = Vec::new();
        tokio::time::timeout(std::time::Duration::from_secs(3), client_read.read_to_end(&mut got_backward))
            .await
            .expect("backward pipe transfer should finish")
            .unwrap();
        send_backward.await.unwrap();
        assert_eq!(got_backward, backward_expected);

        let piped = tokio::time::timeout(std::time::Duration::from_secs(3), piping)
            .await
            .expect("tcp.pipe should finish")
            .unwrap()
            .unwrap()
            .json;
        assert_eq!(piped, json!({ "there": 262_144, "back": 131_072 }));
        assert!(!close_accepted.is_closed(), "tcp.pipe ownership transfer must not trigger SocketClose");
        assert!(!close_opened.is_closed(), "tcp.pipe ownership transfer must not trigger SocketClose");
        assert!(inner.run("tcp.read", json!({ "id": accepted }), None).await.is_err());
        assert!(inner.run("tcp.read", json!({ "id": opened }), None).await.is_err());
    });
}

#[test]
fn tcp_close_stops_mesh_subscribe_without_tearing_partial_write() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let endpoint = Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let kept = Arc::new(crate::iroh_ops::Kept::default());
        let ep_id = inner.keep(Handle::Endpoint(endpoint, kept.clone()));

        let (ours, peer) = tokio::io::duplex(64);
        let (r, w) = tokio::io::split(ours);
        let sock_id = inner.keep(Handle::tcp(r, w));
        let Handle::Tcp { write: sock_write, close: sock_close, .. } = inner.handle(sock_id).unwrap() else {
            panic!("expected tcp handle");
        };
        let write_weak = Arc::downgrade(&sock_write);

        // Subscribe and consume the initial snapshot line so the subscription task parks in `changed.changed()`.
        inner.run("iroh.meshSubscribe", json!({ "id": ep_id, "socket": sock_id }), None).await.unwrap();
        let mut peer = tokio::io::BufReader::new(peer);
        let mut initial = String::new();
        tokio::time::timeout(std::time::Duration::from_secs(3), tokio::io::AsyncBufReadExt::read_line(&mut peer, &mut initial))
            .await
            .expect("initial meshScopes snapshot should arrive")
            .unwrap();
        let parsed: Value = serde_json::from_str(&initial).unwrap();
        assert_eq!(parsed["event"], json!("meshScopes"));

        // Start a backpressured tcp.write that writes a partial JSON prefix into the 64-byte duplex and blocks.
        let prefix = vec![b'x'; 512];
        let writer = {
            let inner = inner.clone();
            tokio::spawn(async move { inner.run("tcp.write", json!({ "id": sock_id }), Some(prefix)).await })
        };
        // Drop the test's strong write ref so only tcp.write, handles, and meshSubscribe hold it.
        drop(sock_write);
        // Read 1 byte from peer to deterministically prove tcp.write has written a partial prefix and is parked
        // inside write_all on the 64-byte duplex (leaving > 384 bytes still unwritten).
        let mut first_prefix = [0u8; 1];
        tokio::time::timeout(std::time::Duration::from_secs(3), peer.read_exact(&mut first_prefix))
            .await
            .expect("tcp.write should begin writing partial prefix")
            .unwrap();
        assert_eq!(first_prefix, [b'x']);
        tokio::task::yield_now().await;
        assert!(!writer.is_finished(), "tcp.write should stay blocked on duplex backpressure");

        // Trigger a meshScopes update while tcp.write holds the lock, then close the socket.
        kept.mesh.notify_changed();
        tokio::task::yield_now().await;

        inner.run("tcp.close", json!({ "id": sock_id }), None).await.unwrap();
        assert!(sock_close.is_closed());
        let write_err = tokio::time::timeout(std::time::Duration::from_secs(3), writer)
            .await
            .expect("tcp.write should abort promptly on tcp.close")
            .unwrap()
            .err()
            .expect("tcp.write should fail on tcp.close");
        assert!(write_err.contains("closed"), "unexpected write error: {write_err}");

        // Trigger another meshScopes update after tcp.close and drain peer to EOF.
        kept.mesh.notify_changed();
        let mut drained = Vec::new();
        tokio::time::timeout(std::time::Duration::from_secs(3), peer.read_to_end(&mut drained))
            .await
            .expect("peer should reach clean EOF once subscription exits and releases SocketWrite")
            .unwrap();
        assert!(
            drained.iter().all(|&b| b == b'x'),
            "meshSubscribe must not append meshScopes onto torn prefix: {:?}",
            String::from_utf8_lossy(&drained)
        );
        assert_eq!(write_weak.strong_count(), 0, "meshSubscribe task must exit and release SocketWrite");

        inner.run("iroh.close", json!({ "id": ep_id, "forget": true }), None).await.unwrap();
    });
}

#[test]
fn tcp_close_stops_mesh_subscribe_while_scopes_lock_is_held() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    let inner = shell.inner.clone();
    shell.runtime.block_on(async move {
        let endpoint = Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let kept = Arc::new(crate::iroh_ops::Kept::default());
        let ep_id = inner.keep(Handle::Endpoint(endpoint, kept.clone()));

        let (ours, peer) = tokio::io::duplex(64);
        let (r, w) = tokio::io::split(ours);
        let sock_id = inner.keep(Handle::tcp(r, w));
        let Handle::Tcp { write: sock_write, close: sock_close, .. } = inner.handle(sock_id).unwrap() else {
            panic!("expected tcp handle");
        };
        let write_weak = Arc::downgrade(&sock_write);
        drop(sock_write);

        // Subscribe and consume the initial snapshot so the subscription task parks on `changed.changed()`.
        inner.run("iroh.meshSubscribe", json!({ "id": ep_id, "socket": sock_id }), None).await.unwrap();
        let mut peer = tokio::io::BufReader::new(peer);
        let mut initial = String::new();
        tokio::time::timeout(std::time::Duration::from_secs(3), tokio::io::AsyncBufReadExt::read_line(&mut peer, &mut initial))
            .await
            .expect("initial meshScopes snapshot should arrive")
            .unwrap();
        assert_eq!(serde_json::from_str::<Value>(&initial).unwrap()["event"], json!("meshScopes"));

        // Hold `scopes` lock and wait deterministically for the subscription task to wake from `changed()` and
        // reach `scopes.lock().await`.
        let scopes_guard = kept.mesh.lock_scopes_for_test().await;
        let wait_notify = kept.mesh.scopes_lock_wait();
        let entering_scopes_lock = wait_notify.notified();
        tokio::pin!(entering_scopes_lock);
        entering_scopes_lock.as_mut().enable();
        kept.mesh.notify_changed();
        tokio::time::timeout(std::time::Duration::from_secs(3), entering_scopes_lock)
            .await
            .expect("meshSubscribe task should wake from changed() and reach scopes.lock()");

        // Close the socket while `scopes_guard` is still held: the outer select! must cancel `scopes.lock().await`
        // immediately and release `SocketWrite` so the peer observes clean EOF before `scopes_guard` is dropped.
        inner.run("tcp.close", json!({ "id": sock_id }), None).await.unwrap();
        assert!(sock_close.is_closed());

        let mut drained = Vec::new();
        tokio::time::timeout(std::time::Duration::from_secs(3), peer.read_to_end(&mut drained))
            .await
            .expect("peer should observe EOF while scopes lock is still held")
            .unwrap();
        assert!(drained.is_empty(), "no extra frame should be written after tcp.close");
        assert_eq!(write_weak.strong_count(), 0, "meshSubscribe task must drop SocketWrite while scopes lock is held");

        drop(scopes_guard);
        inner.run("iroh.close", json!({ "id": ep_id, "forget": true }), None).await.unwrap();
    });
}

#[test]
fn tcp_close_mesh_snapshot_checks_closed_after_acquiring_write_lock() {
    let dir = TempDir::new();
    let shell = Shell::start(dir.path().to_path_buf(), complete, ctx()).unwrap();
    shell.runtime.block_on(async move {
        let (ours, mut peer) = tokio::io::duplex(64);
        let (_, w) = tokio::io::split(ours);
        let write: crate::net::SocketWrite = Arc::new(tokio::sync::Mutex::new(Box::new(w)));
        let close = crate::net::SocketClose::new();

        // Hold the write lock so `write_mesh_snapshot` passes its entry `is_closed()` check and parks on
        // `write.lock().await`.
        let err = {
            let guard = write.lock().await;
            let mut send = std::pin::pin!(crate::iroh_ops::write_mesh_snapshot(&write, &close, vec![]));
            assert!(futures::poll!(send.as_mut()).is_pending());

            // Simulate the same-poll race: `tcp.close` flips `closed = true` and releases the write lock without the
            // outer select! polling `cancel` first. The post-lock `is_closed()` check must still reject the write.
            close.close();
            drop(guard);
            tokio::time::timeout(std::time::Duration::from_secs(3), send)
                .await
                .expect("write_mesh_snapshot should return promptly once lock is released")
                .expect_err("write_mesh_snapshot must abort after acquiring lock on closed socket")
        };
        assert!(err.contains("closed"), "unexpected error: {err}");

        drop(write);
        let mut drained = Vec::new();
        tokio::time::timeout(std::time::Duration::from_secs(3), peer.read_to_end(&mut drained))
            .await
            .expect("peer should observe EOF")
            .unwrap();
        assert!(drained.is_empty(), "closed socket must receive 0 bytes, got: {:?}", String::from_utf8_lossy(&drained));
    });
}
