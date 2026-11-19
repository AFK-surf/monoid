//! Iroh QUIC stream lifecycle (`istream.*`), framed Unix-socket piping (`istream.pipe`, `istream.hand`), and routed
//! stream handover (`conn.hand`).

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use iroh::endpoint::{RecvStream, SendStream};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::net::{SocketRead, SocketWrite, open_unix, tell_unix};
use crate::screen_tap::ScreenTap;
use crate::{Answer, Done, Handle, Inner, err, id_of, str_of, tally};

/// The two halves of an iroh stream, and the reads waiting on it: a reset wakes them first (as the addon's).
pub(crate) struct Halves {
    /// The connection it is on: it goes when that one closes.
    pub(crate) conn: u64,
    pub(crate) send: tokio::sync::Mutex<Option<SendStream>>,
    pub(crate) recv: tokio::sync::Mutex<Option<RecvStream>>,
    pub(crate) reset: tokio::sync::watch::Sender<bool>,
    /// Read to its end; finished (or no sending half). Both: the handle goes.
    pub(crate) ended: std::sync::atomic::AtomicBool,
    pub(crate) finished: std::sync::atomic::AtomicBool,
    /// A remote screen's view, tapped (`istream.tap`): its frames read here, the picture's and the sound's said to the
    /// app as they come, the rest left for the core to read.
    pub(crate) tap: Mutex<Option<ScreenTap>>,
}

/// A stream carried whole into a socket (`istream.pipe`): each piece of it as a frame, its length (4 bytes, big-endian)
/// then its bytes; its end, or what failed it (the frame's tag, then the words' length and the words), as one of these.
pub(crate) const PIPE_END: u32 = 0xFFFF_FFFE;
pub(crate) const PIPE_FAILED: u32 = 0xFFFF_FFFD;
/// A frame no longer than this (the longest a read gives, and what the other side sends).
const PIPE_MOST: u32 = 1 << 20;

/// What a stream's other end sent first, up to its first line's end (16 KiB at most; less where it ended or failed):
/// all of what was read, to be carried on before the rest (a frame of `pipe`'s).
async fn read_head_line(halves: &Halves) -> Vec<u8> {
    let mut read = Vec::new();
    let mut buf = vec![0u8; 16 * 1024];
    let mut recv = halves.recv.lock().await;
    let Some(recv) = recv.as_mut() else { return read };
    while !read.contains(&b'\n') && read.len() < 16 * 1024 {
        match recv.read(&mut buf).await {
            Ok(Some(n)) => read.extend_from_slice(&buf[..n]),
            _ => break,
        }
    }
    read
}

/// A request's route as `conn.hand`'s `routes` say them: its head line's method (GET where none) and its path without
/// its query. None where the line is not one (wire.ts: a JSON head line).
fn route_of(read: &[u8]) -> Option<String> {
    let end = read.iter().position(|&b| b == b'\n')?;
    let head: Value = serde_json::from_slice(&read[..end]).ok()?;
    let method = head.get("method").and_then(Value::as_str).unwrap_or("GET").to_uppercase();
    let path = head.get("path")?.as_str()?;
    Some(format!("{method} {}", path.split('?').next().unwrap_or(path)))
}

/// Whether route `r` (`"GET /a/b"`) is one `pattern` names: the same method and as many segments, each the same or `*`
/// (any one, not empty).
fn route_matches(pattern: &str, r: &str) -> bool {
    let (mut p, mut r) = (pattern.split('/'), r.split('/'));
    loop {
        match (p.next(), r.next()) {
            (None, None) => return true,
            (Some("*"), Some(s)) if !s.is_empty() => {}
            (Some(a), Some(b)) if a == b => {}
            _ => return false,
        }
    }
}

impl Inner {
    fn istream_done(&self, id: u64, halves: &Halves) {
        if halves.ended.load(Ordering::Relaxed) && halves.finished.load(Ordering::Relaxed) {
            self.drop_handle(id);
        }
    }

    /// A stream given to the Unix socket at `path` (`istream.hand`): connected, `head` written, carried. Reset where
    /// the socket does not take it.
    async fn hand(self: &Arc<Self>, id: u64, halves: Arc<Halves>, path: &str, head: &[u8]) -> Result<(), String> {
        match open_unix(path, head).await {
            Ok((read, write)) => {
                self.pipe(id, halves, read, write).await;
                Ok(())
            }
            Err(e) => {
                self.reset_stream(id).await;
                Err(e)
            }
        }
    }

    /// A stream ended at once both ways, and let go (`istream.reset`'s).
    async fn reset_stream(&self, id: u64) {
        if let Some(Handle::IStream(halves)) = self.drop_handle(id) {
            let _ = halves.reset.send(true);
            if let Some(send) = halves.send.lock().await.as_mut() {
                let _ = send.reset(0u32.into());
            }
            if let Some(recv) = halves.recv.lock().await.as_mut() {
                let _ = recv.stop(0u32.into());
            }
        }
    }

    /// A stream carried whole into a socket, both ways (`istream.pipe`, which says how), till both ways are done.
    async fn pipe(&self, id: u64, halves: Arc<Halves>, read: SocketRead, write: SocketWrite) {
        let down = async {
            let mut write = write.lock().await;
            let mut reset = halves.reset.subscribe();
            let mut buf = vec![0u8; 4 + 256 * 1024];
            loop {
                if *reset.borrow() {
                    break;
                }
                let read = {
                    let mut recv = halves.recv.lock().await;
                    // (one way: nothing comes)
                    let Some(recv) = recv.as_mut() else { break };
                    tokio::select! {
                        read = recv.read(&mut buf[4..]) => read,
                        _ = reset.changed() => break,
                    }
                };
                let frame: &[u8] = match read {
                    Ok(Some(n)) => {
                        buf[..4].copy_from_slice(&(n as u32).to_be_bytes());
                        &buf[..4 + n]
                    }
                    Ok(None) => {
                        halves.ended.store(true, Ordering::Relaxed);
                        let _ = write.write_all(&PIPE_END.to_be_bytes()).await;
                        break;
                    }
                    Err(e) => {
                        let words = e.to_string();
                        let mut failed = PIPE_FAILED.to_be_bytes().to_vec();
                        failed.extend((words.len() as u32).to_be_bytes());
                        failed.extend(words.as_bytes());
                        let _ = write.write_all(&failed).await;
                        break;
                    }
                };
                if write.write_all(frame).await.is_err() {
                    break;
                }
            }
            let _ = write.shutdown().await;
        };
        let up = async {
            let mut read = read.lock().await;
            let mut reset = halves.reset.subscribe();
            let mut head = [0u8; 4];
            let mut buf = Vec::new();
            let mut written_end = false;
            let finished = loop {
                if *reset.borrow() {
                    break false;
                }
                let ok = tokio::select! {
                    r = read.read_exact(&mut head) => r.is_ok(),
                    _ = reset.changed() => break false,
                };
                if !ok {
                    break false;
                }
                let n = u32::from_be_bytes(head);
                if n == PIPE_END {
                    break true;
                }
                if n > PIPE_MOST {
                    break false;
                }
                buf.resize(n as usize, 0);
                let ok = tokio::select! {
                    r = read.read_exact(&mut buf) => r.is_ok(),
                    _ = reset.changed() => break false,
                };
                if !ok {
                    break false;
                }
                let mut send = halves.send.lock().await;
                let Some(send) = send.as_mut() else { break false };
                let sent = tokio::select! {
                    r = send.write_all(&buf) => r.is_ok(),
                    _ = reset.changed() => false,
                };
                if !sent {
                    // (reset by either end: the socket's frames go nowhere now)
                    written_end = true;
                    break false;
                }
            };
            if !written_end && !*reset.borrow() {
                let mut send = halves.send.lock().await;
                if let Some(send) = send.as_mut() {
                    if finished {
                        let _ = send.finish();
                    } else {
                        let _ = send.reset(0u32.into());
                    }
                }
            }
            halves.finished.store(true, Ordering::Relaxed);
        };
        tokio::join!(down, up);
        // Let go once both ways are done, unless its sending half is still to be asked when it is acknowledged.
        if halves.recv.lock().await.is_some() {
            self.istream_done(id, &halves);
        }
    }

    pub(crate) async fn run_istream(self: &Arc<Self>, op: &str, a: &Value, bytes: Option<Vec<u8>>) -> Done {
        match op {
            "istream.tap" => {
                // A remote screen's view (`call` the app's): its frames read here from now on, beginning with `bytes`
                // (what the core read past the stream's reply); false where nothing says to the app from here.
                let Handle::IStream(halves) = self.handle(id_of(a)?)? else { return Err("not a stream".into()) };
                let call = a.get("call").and_then(Value::as_u64).ok_or("no call")?;
                if self.say.lock().unwrap().is_none() {
                    return Ok(Answer::json(json!({ "tapped": false })));
                }
                let mut tap = ScreenTap::new(call);
                tap.take(&bytes.unwrap_or_default(), &**self);
                *halves.tap.lock().unwrap() = Some(tap);
                tally("tap.views");
                Ok(Answer::json(json!({ "tapped": true })))
            }
            "istream.read" => {
                let id = id_of(a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                let mut reset = halves.reset.subscribe();
                if *reset.borrow() {
                    return Ok(Answer::json(json!({ "end": true })));
                }
                // tapped: read on here, saying what is the app's, until something is the core's (or the end)
                if halves.tap.lock().unwrap().is_some() {
                    let mut buf = vec![0u8; 64 * 1024];
                    loop {
                        {
                            let mut tap = halves.tap.lock().unwrap();
                            let tap = tap.as_mut().unwrap();
                            if !tap.out.is_empty() {
                                return Ok(Answer::bytes(json!({}), std::mem::take(&mut tap.out)));
                            }
                        }
                        let read = {
                            let mut recv = halves.recv.lock().await;
                            let Some(recv) = recv.as_mut() else { return Ok(Answer::json(json!({ "end": true }))) };
                            tokio::select! {
                                read = recv.read(&mut buf) => read.map_err(err)?,
                                _ = reset.changed() => None,
                            }
                        };
                        match read {
                            Some(n) => {
                                let mut tap = halves.tap.lock().unwrap();
                                tap.as_mut().unwrap().take(&buf[..n], &**self);
                            }
                            None => {
                                // what is left (a frame cut short) the core's, which says so
                                let left = {
                                    let mut tap = halves.tap.lock().unwrap();
                                    let tap = tap.as_mut().unwrap();
                                    let mut left = std::mem::take(&mut tap.out);
                                    left.append(&mut tap.pending);
                                    left
                                };
                                if !left.is_empty() {
                                    return Ok(Answer::bytes(json!({}), left));
                                }
                                halves.ended.store(true, Ordering::Relaxed);
                                self.istream_done(id, &halves);
                                return Ok(Answer::json(json!({ "end": true })));
                            }
                        }
                    }
                }
                let mut buf = vec![0u8; 64 * 1024];
                let read = {
                    let mut recv = halves.recv.lock().await;
                    let Some(recv) = recv.as_mut() else { return Ok(Answer::json(json!({ "end": true }))) };
                    tokio::select! {
                        read = recv.read(&mut buf) => read.map_err(err)?,
                        _ = reset.changed() => None,
                    }
                };
                match read {
                    Some(n) => {
                        buf.truncate(n);
                        Ok(Answer::bytes(json!({}), buf))
                    }
                    None => {
                        halves.ended.store(true, Ordering::Relaxed);
                        self.istream_done(id, &halves);
                        Ok(Answer::json(json!({ "end": true })))
                    }
                }
            }
            "istream.write" => {
                let Handle::IStream(halves) = self.handle(id_of(a)?)? else { return Err("not a stream".into()) };
                let mut send = halves.send.lock().await;
                send.as_mut().ok_or("no sending half")?.write_all(&bytes.unwrap_or_default()).await.map_err(err)?;
                Ok(Answer::json(json!({})))
            }
            "istream.finish" => {
                let id = id_of(a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                if let Some(send) = halves.send.lock().await.as_mut() {
                    send.finish().map_err(err)?;
                }
                halves.finished.store(true, Ordering::Relaxed);
                // A stream one way (a measurement) is let go once `stopped` answers; one both ways once read to its end.
                // (Let go here, a measurement's `stopped` found no stream and every relay measured on Android came to
                // nothing, 2026-10-05.)
                if halves.recv.lock().await.is_some() {
                    self.istream_done(id, &halves);
                }
                Ok(Answer::json(json!({})))
            }
            "istream.stopped" => {
                let id = id_of(a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                // Taken under the lock and awaited without it, so writes go on meanwhile.
                let stopped = match halves.send.lock().await.as_mut() {
                    Some(send) => send.stopped(),
                    None => return Ok(Answer::json(json!({ "code": null }))),
                };
                let code = stopped.await;
                if halves.recv.lock().await.is_none() && halves.finished.load(Ordering::Relaxed) {
                    self.drop_handle(id);
                }
                let code = code.map_err(err)?;
                Ok(Answer::json(json!({ "code": code.map(|c| c.into_inner()) })))
            }
            "istream.reset" => {
                let id = id_of(a)?;
                let code = a.get("code").and_then(Value::as_u64).unwrap_or(0) as u32;
                if let Some(Handle::IStream(halves)) = self.drop_handle(id) {
                    let _ = halves.reset.send(true);
                    if let Some(send) = halves.send.lock().await.as_mut() {
                        let _ = send.reset(code.into());
                    }
                    if let Some(recv) = halves.recv.lock().await.as_mut() {
                        let _ = recv.stop(code.into());
                    }
                }
                Ok(Answer::json(json!({})))
            }
            // A stream carried whole into a socket (`to`, taken), both ways, here: what comes on it written to the socket
            // in frames (PIPE_END its end, PIPE_FAILED what failed it), and the frames the socket sends written on it, its
            // PIPE_END finishing it; the socket ending without one resets it. What the station's Node reads and writes of
            // a stream the front keeps for it (station/mb's front), none of it through the front's program. Answered once
            // both ways are done; `istream.stopped` and `istream.reset` are asked of the stream meanwhile as before.
            "istream.pipe" => {
                let id = id_of(a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                let to = a.get("to").and_then(Value::as_u64).ok_or("missing to")?;
                let Some(Handle::Tcp { read, write }) = self.drop_handle(to) else { return Err("not a socket".into()) };
                self.pipe(id, halves, read, write).await;
                Ok(Answer::json(json!({})))
            }
            // A stream given to the Unix socket at `path`: a connection to it, `bytes` written first (what tells the
            // other side which stream it is), then the stream carried into it as `istream.pipe` carries it.
            "istream.hand" => {
                let id = id_of(a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                self.hand(id, halves, str_of(a, "path")?, &bytes.unwrap_or_default()).await?;
                Ok(Answer::json(json!({})))
            }
            // Each stream the other end of a connection opens, given as it comes to the Unix socket at `path` as
            // `istream.hand` gives one, its head the connection's id and the stream's (8 bytes each, big-endian), a 2
            // and the stream's index on the connection (QUIC's, 8 bytes): each is handed by a task of its own, so their
            // sockets come to the other side in any order, which puts them back in the order they were opened by it
            // (a device's credential stream is its first; 2026-11-13, its requests came first and were refused as
            // one). A 0 there and no index: a front from before. Kept as a stream here meanwhile
            // (`istream.stopped`, `istream.reset`). Answered once the connection is gone.
            // What station/mb's front gives its Node, with no step of the program's for each stream.
            //
            // With `front` (Unix sockets' paths, each taking the next in turn) and `routes` ("GET /admin/api/chats", …): a stream past the first
            // whose head line (its first, read here) asks one of those, by its method and its path without the query,
            // goes there instead, with what was read of it, and `path` is told its index went elsewhere (its head the
            // ids, a 3 and the index): what the front answers itself. A route's segment `*` is any one segment. One
            // of them that takes no connection (its program ended, the next not listening yet) is passed over for the
            // next in turn; none taking it, the stream goes to `path` as any other does, with what was read of it, and
            // Node answers it (`path` told nothing went elsewhere): a request is not reset for a program between two runs.
            "conn.hand" => {
                let on = id_of(a)?;
                let path = str_of(a, "path")?.to_string();
                let fronts: Arc<Vec<String>> = Arc::new(a.get("front").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect());
                let mut turn = 0usize;
                let routes: Arc<Vec<String>> = Arc::new(
                    a.get("routes").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect(),
                );
                let Handle::Conn(conn) = self.handle(on)? else { return Ok(Answer::json(json!({}))) };
                while let Ok((mut send, mut recv)) = conn.accept_bi().await {
                    if !matches!(self.handle(on), Ok(Handle::Conn(_))) {
                        let _ = send.reset(0u32.into());
                        let _ = recv.stop(0u32.into());
                        break;
                    }
                    let index = recv.id().index();
                    let halves = Arc::new(Halves {
                        conn: on,
                        ended: false.into(),
                        finished: false.into(),
                        send: tokio::sync::Mutex::new(Some(send)),
                        recv: tokio::sync::Mutex::new(Some(recv)),
                        reset: tokio::sync::watch::channel(false).0,
                        tap: Mutex::default(),
                    });
                    let id = self.keep(Handle::IStream(halves.clone()));
                    let mut head = on.to_be_bytes().to_vec();
                    head.extend(id.to_be_bytes());
                    head.push(2);
                    head.extend(index.to_be_bytes());
                    let start = turn;
                    turn = turn.wrapping_add(1);
                    let (inner, path, routes, fronts) = (self.clone(), path.clone(), routes.clone(), fronts.clone());
                    tokio::spawn(async move {
                        let mut head = head;
                        if index > 0 && !fronts.is_empty() && !routes.is_empty() {
                            let read = read_head_line(&halves).await;
                            let routed = route_of(&read).is_some_and(|r| routes.iter().any(|p| route_matches(p, &r)));
                            // (as the frame `pipe` would have carried it: its length first; the same to a program or Node)
                            if !read.is_empty() {
                                head.extend((read.len() as u32).to_be_bytes());
                                head.extend(read);
                            }
                            if routed {
                                for k in 0..fronts.len() {
                                    let front = &fronts[start.wrapping_add(k) % fronts.len()];
                                    match open_unix(front, &head).await {
                                        Ok((read, write)) => {
                                            // Node told the index went elsewhere only once it has: else it waits for it.
                                            let mut skip = head[..16].to_vec();
                                            skip.push(3);
                                            skip.extend(index.to_be_bytes());
                                            if let Err(e) = tell_unix(&path, &skip).await {
                                                crate::log::info(&format!("mesh: a stream's index not told: {e}"));
                                            }
                                            inner.pipe(id, halves, read, write).await;
                                            return;
                                        }
                                        Err(e) => crate::log::info(&format!("mesh: a routed stream not taken at {front} ({e}); the next")),
                                    }
                                }
                                crate::log::info(&format!("mesh: no program took a routed stream; Node answers it"));
                            }
                        }
                        if let Err(e) = inner.hand(id, halves, &path, &head).await {
                            crate::log::info(&format!("mesh: a stream not given: {e}"));
                        }
                    });
                }
                Ok(Answer::json(json!({})))
            }
            other => Err(format!("no operation {other}")),
        }
    }
}
