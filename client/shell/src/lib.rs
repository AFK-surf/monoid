//! The native shell of the core in TypeScript in the apps (client/core-ts `hosts/bridge.ts`; apps/mbui/engine runs it
//! in Hermes from C++): everything the core asks of its host that a JS engine has not, done on tokio's threads and on
//! a thread for the disk, and answered through a C callback. What it does is what the Rust core's native host (client/ffi) did (reqwest,
//! tokio-tungstenite, a file per storage key in the data directory, TCP to adbd) and what the station's addon does for
//! Node (iroh), so a phone moving from the Rust core keeps its sign-in. Each signed-in account's database is SQLite,
//! `databases/<name>.db` (beside the storage keys' files: `accounts` is one), used synchronously by the core's thread
//! (`sql.*`); the former `core.db` is only read, once.
//!
//! Operations are named and take JSON and maybe bytes; bridge.ts lists them. `sf_shell_call` answers later through
//! `complete(ctx, id, json, error, bytes)` from any thread; `sf_shell_call_sync` answers at once.

use std::collections::{BTreeMap, HashMap};
use std::ffi::{CStr, c_char, c_void};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};

use futures::{SinkExt, StreamExt};
use iroh::endpoint::{Connection, QuicTransportConfig, RecvStream, SendStream, presets::Minimal};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, Watcher};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::Connector;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

mod adb;
mod keep;
mod mesh;
mod log;

const MDNS_SERVICE: &str = "stillfail";

/// The nodes a DHT starts from: n0-mainline's defaults, with ours (cloud/dht-node, on the relays' machines) in place of relay.pkarr.org.
fn dht() -> n0_mainline::DhtBuilder {
    let mut dht = n0_mainline::DhtBuilder::default();
    dht.bootstrap(&[
        "router.bittorrent.com:6881",
        "dht.transmissionbt.com:6881",
        "dht.libtorrent.org:25401",
        "39.105.157.122:6881",
        "47.79.40.84:6881",
        "120.24.233.158:6881",
    ]);
    dht
}

/// `complete(ctx, id, json, json_len, error, error_len, bytes, bytes_len, has_bytes)`: an operation's answer, its JSON
/// (when it succeeded) or its error, and its bytes if it has any. Called on any thread.
pub type Complete = extern "C" fn(*mut c_void, u64, *const u8, usize, *const u8, usize, *const u8, usize, u8);

struct Ctx(*mut c_void);
// SAFETY: the engine's context is made to be told from any thread (the C++ side queues what it is given).
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

/// An answer: JSON, and bytes where the operation has them.
struct Answer {
    json: Value,
    bytes: Option<Vec<u8>>,
}

impl Answer {
    fn json(json: Value) -> Answer {
        Answer { json, bytes: None }
    }
    fn bytes(json: Value, bytes: Vec<u8>) -> Answer {
        Answer { json, bytes: Some(bytes) }
    }
}

type Done = Result<Answer, String>;

/// `say(ctx, json, json_len, bytes, bytes_len)`: a message for the app, as the core says one (its JSON, and the bytes
/// beside it, or none: `bytes` null), straight from the shell (a remote screen's frames: `istream.tap`). Any thread.
pub type Say = extern "C" fn(*mut c_void, *const u8, usize, *const u8, usize);

/// `media(ctx, call, kind, key, seq, ts, bytes, bytes_len)`: a tapped remote screen's record offered to the app's host as
/// it is, before it is said (`Say`): a video frame (kind 2: `key`, `ts`, its access unit), a sound packet (6: `ts`, its
/// PCM), or a config (1) or the sound's (5), offered only to be seen (the host stops taking that view's records until
/// the app has taken it). `seq` numbers every record said of any tapped view, from 1. 1: the host took it (decoded,
/// played and acknowledged there), nothing said; 0: said to the app as before. Any of the shell's threads, a view's
/// records in order.
pub type Media = extern "C" fn(*mut c_void, u64, u8, u8, u64, u64, *const u8, usize) -> u8;

/// Where a tapped view's records go (ScreenTap::said): offered to the host (`media`), said to the app.
trait Tell {
    /// Record `kind` of view `call` offered to the host: whether it took it.
    fn media(&self, call: u64, kind: u8, key: bool, seq: u64, ts: u64, bytes: &[u8]) -> bool;
    /// A message for the app (its JSON, the bytes beside it).
    fn say(&self, json: &[u8], bytes: Option<&[u8]>);
}

/// The number of the next record said of a tapped view (`Media`'s `seq`): one count for all, so a view tapped again on
/// another stream (`screen.bounds`) goes on from where it was.
static MEDIA_SEQ: AtomicU64 = AtomicU64::new(1);

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// A file being read a part at a time (`text.open`).
struct TextReader {
    source: Box<dyn std::io::Read + Send>,
    /// Read and not given yet.
    held: Vec<u8>,
    lines: bool,
    done: bool,
}

/// How much of a file a part holds at most, past a line's end (counter.ts CHUNK).
const TEXT_PART: usize = 8 << 20;

impl TextReader {
    fn fill(&mut self, want: usize) {
        while !self.done && self.held.len() < want {
            let mut buf = vec![0u8; (want - self.held.len()).max(64 << 10)];
            match self.source.read(&mut buf) {
                Ok(0) | Err(_) => self.done = true,
                Ok(n) => self.held.extend_from_slice(&buf[..n]),
            }
        }
    }

    fn next(&mut self) -> Option<String> {
        self.fill(TEXT_PART);
        if self.lines {
            // (a part ends at the last line end in its window, else at the first after it, as counter.ts `partsOf`)
            let window = self.held.len().min(TEXT_PART);
            let cut = match self.held[..window].iter().rposition(|&b| b == b'\n') {
                Some(i) => i,
                None => loop {
                    if let Some(i) = self.held.iter().position(|&b| b == b'\n') {
                        break i;
                    }
                    if self.done {
                        return None;
                    }
                    let more = self.held.len() + TEXT_PART;
                    self.fill(more);
                },
            };
            let part: Vec<u8> = self.held.drain(..=cut).collect();
            return Some(String::from_utf8_lossy(&part).into_owned());
        }
        if self.held.is_empty() {
            return None;
        }
        // (a piece ends where a character does, but at the end)
        let mut end = self.held.len().min(TEXT_PART);
        if end < self.held.len() || !self.done {
            let mut back = 0;
            while back < 3 && end > back && (self.held[end - 1 - back] & 0xc0) == 0x80 {
                back += 1;
            }
            if end > back && self.held[end - 1 - back] >= 0xc0 {
                let lead = self.held[end - 1 - back];
                let len = if lead >= 0xf0 { 4 } else if lead >= 0xe0 { 3 } else { 2 };
                if back + 1 < len {
                    end -= back + 1;
                }
            }
        }
        if end == 0 {
            end = self.held.len();
        }
        let piece: Vec<u8> = self.held.drain(..end).collect();
        Some(String::from_utf8_lossy(&piece).into_owned())
    }
}

/// `path` made absolute and its `.` and `..` taken out by their names alone, as Node's path.resolve does.
fn lexical(path: &std::path::Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            c => out.push(c),
        }
    }
    out
}

/// A link's target without Windows' `\\?\` (as libuv's readlink gives it).
fn plain(target: PathBuf) -> PathBuf {
    let s = target.to_string_lossy().into_owned();
    if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
        PathBuf::from(format!(r"\\{rest}"))
    } else if let Some(rest) = s.strip_prefix(r"\\?\") {
        PathBuf::from(rest)
    } else {
        target
    }
}

/// Node's realpathSync (lib/fs.js, its JavaScript one): the path resolved, then each part from the root looked at
/// (lstat) and a link replaced by its target resolved against the parts before it, again from the root.
fn node_realpath(path: &str) -> std::io::Result<String> {
    use std::path::Component;
    let mut path = lexical(&std::path::absolute(path)?);
    let mut links = 0;
    'again: loop {
        let parts: Vec<Component> = path.components().collect();
        let mut done = PathBuf::new();
        for (i, part) in parts.iter().enumerate() {
            if !matches!(part, Component::Normal(_)) {
                done.push(part);
                continue;
            }
            let next = done.join(part);
            if std::fs::symlink_metadata(&next)?.file_type().is_symlink() {
                links += 1;
                if links > 256 {
                    return Err(std::io::Error::other("too many links"));
                }
                let mut resolved = lexical(&done.join(plain(std::fs::read_link(&next)?)));
                for rest in &parts[i + 1..] {
                    resolved.push(rest);
                }
                path = resolved;
                continue 'again;
            }
            done = next;
        }
        return Ok(done.to_string_lossy().into_owned());
    }
}

/// The two halves of an iroh stream, and the reads waiting on it: a reset wakes them first (as the addon's).
struct Halves {
    /// The connection it is on: it goes when that one closes.
    conn: u64,
    send: tokio::sync::Mutex<Option<SendStream>>,
    recv: tokio::sync::Mutex<Option<RecvStream>>,
    reset: tokio::sync::watch::Sender<bool>,
    /// Read to its end; finished (or no sending half). Both: the handle goes.
    ended: std::sync::atomic::AtomicBool,
    finished: std::sync::atomic::AtomicBool,
    /// A remote screen's view, tapped (`istream.tap`): its frames read here, the picture's and the sound's said to the
    /// app as they come, the rest left for the core to read.
    tap: Mutex<Option<ScreenTap>>,
}

/// A remote screen's stream read in the shell (docs/remote-screens.md, Wire; client/core-ts screen-frames.ts): its
/// frames taken apart as its pieces come; a config, a video frame, the sound's config and its packets said to the app at
/// once as the core's progress of the view's call (`{id, value}`, the bytes beside it: what screens.ts says of them),
/// so they go through neither the core's JS nor its thread; the rest (its state, a clipboard, what is not one of them)
/// kept, as they came, for the core's next read, with a video frame's head alone the first time one comes after a
/// config (what tells the core the picture is live). Sound that comes as Opus (a view asked it: client/core-ts mesh.ts
/// `decodesOpus`) is decoded here, each packet into the 20 ms of PCM16 the hosts play, and said to the app as PCM.
struct ScreenTap {
    /// the app's call the view is (its progress' id)
    call: u64,
    /// what came and is not a whole frame yet
    pending: Vec<u8>,
    /// frames for the core, whole
    out: Vec<u8>,
    /// a video frame's head given the core since the last config
    told_video: bool,
    /// the view's sound is Opus (its config said so): what decodes it, and the capture time the next packet follows
    /// on from (0: none decoded since it was made)
    opus: Option<Box<opus_rs::OpusDecoder>>,
    opus_next: u64,
}

const FRAME_CONFIG: u8 = 1;
const FRAME_VIDEO: u8 = 2;
const FRAME_AUDIO_CONFIG: u8 = 5;
const FRAME_AUDIO: u8 = 6;
/// A frame longer than this is no frame (screen-frames.ts MAX_FRAME): left to the core, which says so.
const FRAME_MAX: usize = 64 * 1024 * 1024;
/// A packet of sound as the hosts play it: 960 frames of interleaved stereo PCM16 (20 ms at 48 kHz); the longest Opus
/// packet (RFC 6716 3.2.1).
const PCM_PACKET: usize = 3840;
const OPUS_MAX: usize = 1275;
/// A packet's capture time this far (µs) from where the last one ended still follows on from it: half a packet (the
/// sources that encode Opus give each packet of a run its time 20 ms on from the last exactly: the Helper's
/// AudioPackets, stillfail-screen's Runs); one further is after a gap (packets left out before the round trip was
/// known, while muted, silence not sent), decoded by a decoder made anew, as its encoder was.
const OPUS_SLACK: u64 = 10_000;

impl ScreenTap {
    fn new(call: u64) -> Self {
        ScreenTap { call, pending: Vec::new(), out: Vec::new(), told_video: false, opus: None, opus_next: 0 }
    }

    /// What came next: its whole frames said or kept.
    fn take(&mut self, chunk: &[u8], tell: &dyn Tell) {
        // (whole frames read where they came, not copied first; what is left of one kept)
        if self.pending.is_empty() {
            let used = self.frames_in(chunk, tell);
            self.pending.extend_from_slice(&chunk[used..]);
            return;
        }
        let mut pending = std::mem::take(&mut self.pending);
        pending.extend_from_slice(chunk);
        let used = self.frames_in(&pending, tell);
        pending.drain(..used);
        self.pending = pending;
    }

    /// The whole frames at the start of `data` said or kept: how many bytes they were.
    fn frames_in(&mut self, data: &[u8], tell: &dyn Tell) -> usize {
        let mut at = 0;
        loop {
            let rest = &data[at..];
            if rest.len() < 5 {
                break;
            }
            let len = u32::from_be_bytes([rest[1], rest[2], rest[3], rest[4]]) as usize;
            if len > FRAME_MAX {
                // out of step: all of it the core's, which fails the view
                self.out.extend_from_slice(rest);
                at = data.len();
                break;
            }
            if rest.len() < 5 + len {
                break;
            }
            let (kind, body) = (rest[0], &rest[5..5 + len]);
            if !self.said(kind, body, tell) {
                self.out.extend_from_slice(&rest[..5 + len]);
            }
            at += 5 + len;
        }
        at
    }

    /// Frame `kind` said to the app (and what the core needs of it kept: a config, a video frame's head); false: one
    /// for the core alone.
    fn said(&mut self, kind: u8, body: &[u8], tell: &dyn Tell) -> bool {
        let id = self.call;
        match kind {
            FRAME_VIDEO if body.len() >= 9 => {
                let (key, ts) = (body[0] & 1 == 1, u64::from_be_bytes(body[1..9].try_into().unwrap()));
                let n = MEDIA_SEQ.fetch_add(1, Ordering::Relaxed);
                // the host's decoder's at once where it takes it; else said (written as it is: no JSON value made)
                if tell.media(id, FRAME_VIDEO, key, n, ts, &body[9..]) {
                    tally("tap.direct.video");
                } else {
                    let text = format!(r#"{{"id":{id},"value":{{"frame":{{"key":{key},"ts":{ts},"n":{n}}}}}}}"#);
                    tell.say(text.as_bytes(), Some(&body[9..]));
                }
                tally("tap.video");
                if !self.told_video {
                    self.told_video = true;
                    self.out.extend_from_slice(&[FRAME_VIDEO, 0, 0, 0, 9]);
                    self.out.extend_from_slice(&body[..9]);
                }
                true
            }
            FRAME_AUDIO if body.len() > 8 && (if self.opus.is_some() { body.len() <= 8 + OPUS_MAX } else { body.len() == 8 + PCM_PACKET }) => {
                let ts = u64::from_be_bytes(body[..8].try_into().unwrap());
                let mut decoded = [0u8; PCM_PACKET];
                let pcm = match &mut self.opus {
                    None => &body[8..],
                    Some(decoder) => {
                        if self.opus_next != 0 && ts.abs_diff(self.opus_next) > OPUS_SLACK {
                            match opus_rs::OpusDecoder::new(48_000, 2) {
                                Ok(fresh) => **decoder = fresh,
                                Err(_) => return true,
                            }
                            tally("tap.audio.resumed");
                        }
                        let mut samples = [0f32; PCM_PACKET / 2];
                        // (one that does not decode to 20 ms is none: the sound goes on with the next, its decoder made
                        // anew; a panic of the decoder on bytes the station sent is that too, not the end of the view)
                        let packet = &body[8..];
                        let decoded_n = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| decoder.decode(packet, PCM_PACKET / 4, &mut samples)));
                        match decoded_n {
                            Ok(Ok(n)) if n * 4 == PCM_PACKET => self.opus_next = ts + 20_000,
                            _ => {
                                self.opus_next = 0;
                                if let Ok(fresh) = opus_rs::OpusDecoder::new(48_000, 2) {
                                    **decoder = fresh;
                                }
                                tally("tap.audio.undecoded");
                                return true;
                            }
                        }
                        for (i, v) in samples.iter().enumerate() {
                            let v = if v.is_finite() { (v.clamp(-1.0, 1.0) * 32767.0).round() as i16 } else { 0 };
                            decoded[i * 2..i * 2 + 2].copy_from_slice(&v.to_le_bytes());
                        }
                        &decoded[..]
                    }
                };
                let n = MEDIA_SEQ.fetch_add(1, Ordering::Relaxed);
                if tell.media(id, FRAME_AUDIO, false, n, ts, pcm) {
                    tally("tap.direct.audio");
                } else {
                    let text = format!(r#"{{"id":{id},"value":{{"audio":{{"ts":{ts},"n":{n}}}}}}}"#);
                    tell.say(text.as_bytes(), Some(pcm));
                }
                tally("tap.audio");
                true
            }
            FRAME_AUDIO_CONFIG => {
                let Ok(c) = serde_json::from_slice::<Value>(body) else { return false };
                let codec = c.get("codec").and_then(Value::as_str);
                if !matches!(codec, Some("pcm_s16le" | "opus")) || c.get("sampleRate").and_then(Value::as_f64) != Some(48000.0) || c.get("channels").and_then(Value::as_f64) != Some(2.0) {
                    return false;
                }
                // (the app is told PCM either way: what it plays is what is said from here)
                self.opus = None;
                self.opus_next = 0;
                if codec == Some("opus") {
                    match opus_rs::OpusDecoder::new(48_000, 2) {
                        Ok(decoder) => self.opus = Some(Box::new(decoder)),
                        Err(_) => return false,
                    }
                }
                // (seen by the host first: no packet taken there until the app has taken this)
                tell.media(id, FRAME_AUDIO_CONFIG, false, MEDIA_SEQ.fetch_add(1, Ordering::Relaxed), 0, &[]);
                let text = format!(r#"{{"id":{id},"value":{{"audioConfig":{{"codec":"pcm_s16le","sampleRate":48000,"channels":2}}}}}}"#);
                tell.say(text.as_bytes(), None);
                true
            }
            FRAME_CONFIG => {
                // said as screen-frames.ts reads it and screens.ts says it; the core keeps it too (its state's size)
                let Ok(c) = serde_json::from_slice::<Value>(body) else { return false };
                let Some(codec) = c.get("codec").and_then(Value::as_str) else { return false };
                let whole = |k: &str| c.get(k).and_then(Value::as_f64).filter(|v| v.is_finite() && *v > 0.0).map(|v| v.round()).unwrap_or(0.0);
                let description = match c.get("description").and_then(Value::as_str) {
                    Some(d) if !d.is_empty() => match base64_decode(d) {
                        Some(b) => Some(b),
                        None => return false,
                    },
                    _ => None,
                };
                let mut config = json!({ "codec": codec, "width": whole("width"), "height": whole("height") });
                if let Some(r) = region_of(c.get("region")) {
                    config["region"] = r;
                }
                // (seen by the host first: no frame taken there until the app has taken this)
                tell.media(id, FRAME_CONFIG, false, MEDIA_SEQ.fetch_add(1, Ordering::Relaxed), 0, &[]);
                tell.say(&serde_json::to_vec(&json!({ "id": id, "value": { "config": config } })).unwrap_or_default(), description.as_deref());
                self.told_video = false;
                false
            }
            _ => false,
        }
    }
}

/// A part of the screen as a station says it (screen-frames.ts regionOf): within the screen, more than nothing each way.
fn region_of(v: Option<&Value>) -> Option<Value> {
    let v = v?.as_object()?;
    let n = |k: &str| v.get(k).and_then(Value::as_f64).filter(|x| x.is_finite());
    let (x, y, w, h) = (n("x")?, n("y")?, n("w")?, n("h")?);
    (x >= 0.0 && y >= 0.0 && w > 0.0 && h > 0.0 && x + w <= 1.0001 && y + h <= 1.0001).then(|| json!({ "x": x, "y": y, "w": w, "h": h }))
}

/// Standard base64 (padded or not); None when it is not.
fn base64_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            _ => return None,
        } as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

/// The connections coming to an endpoint whose handshakes are done, as each finishes (`iroh.accept`), once one was
/// first asked for.
type Accepted = Arc<tokio::sync::Mutex<Option<tokio::sync::mpsc::UnboundedReceiver<Connection>>>>;

/// What an endpoint keeps beside iroh's own: the connections whose handshakes are done (`iroh.accept`); a station's
/// keepers on relays it is not home on (`iroh.keep`), and those it is home on (bound with); the next connections to come
/// held unanswered, not even their handshake (`iroh.holdIncoming`), and those held.
#[derive(Default)]
struct Kept {
    mesh: mesh::Scopes,
    accepted: Accepted,
    keepers: Mutex<HashMap<String, tokio::task::JoinHandle<()>>>,
    /// The relays it was bound with, and those of them it is home on now (one removed is home no more: a keeper is
    /// wanted there once it is kept on it again, unless it is inserted again first, home again).
    bound: Vec<RelayUrl>,
    homes: Mutex<Vec<RelayUrl>>,
    held: Mutex<(u32, Vec<iroh::endpoint::Incoming>)>,
}

/// A socket's halves as the shell keeps them (`Handle::Tcp`).
type SocketRead = Arc<tokio::sync::Mutex<Box<dyn tokio::io::AsyncRead + Send + Unpin>>>;
type SocketWrite = Arc<tokio::sync::Mutex<Box<dyn tokio::io::AsyncWrite + Send + Unpin>>>;

/// A stream carried whole into a socket (`istream.pipe`): each piece of it as a frame, its length (4 bytes, big-endian)
/// then its bytes; its end, or what failed it (the frame's tag, then the words' length and the words), as one of these.
const PIPE_END: u32 = 0xFFFF_FFFE;
const PIPE_FAILED: u32 = 0xFFFF_FFFD;
/// A frame no longer than this (the longest a read gives, and what the other side sends).
const PIPE_MOST: u32 = 1 << 20;

/// A WebSocket frame as `ws.next` gives it and `ws.send` takes it.
enum WsFrame {
    Text(String),
    Binary(Vec<u8>),
}

#[derive(Clone)]
enum Handle {
    Response(Arc<tokio::sync::Mutex<reqwest::Response>>),
    Ws { incoming: Arc<tokio::sync::Mutex<tokio::sync::mpsc::UnboundedReceiver<Result<WsFrame, String>>>>, outgoing: tokio::sync::mpsc::UnboundedSender<WsFrame> },
    /// A socket to the device's own port, or a station's session on the phone's adb (`adb.open`).
    Tcp { read: Arc<tokio::sync::Mutex<Box<dyn tokio::io::AsyncRead + Send + Unpin>>>, write: Arc<tokio::sync::Mutex<Box<dyn tokio::io::AsyncWrite + Send + Unpin>>> },
    Endpoint(Endpoint, Arc<Kept>),
    Conn(Connection),
    /// A connection that closed, let go (its state, its streams), with what the core may still ask of it; `conn.close`
    /// with `forget: true` lets it go entirely, before or after it closed.
    Gone { remote: String, reason: Value, stats: Value },
    /// An endpoint closed (`iroh.close`), let go, with what the core may still ask of it: one bound anew in its place
    /// leaves a dial still under way on it asking its relays as it fails (mesh.ts `link`), as the station's addon answers.
    /// `iroh.close` with `forget: true` lets it go entirely, before or after it closed.
    Unbound { id: String },
    IStream(Arc<Halves>),
    /// A socket listening on this machine (`tcp.listen`, `unix.listen`): what a station's program serves (station/mb).
    Listener(Arc<Listener>),
    /// A zstd stream being taken apart (`zstd.open`).
    Unzstd(Arc<Mutex<Unzstd>>),
    /// A zstd stream being made (`zstd.stream`): each piece given flushed out whole (station/mesh/compress.ts's way).
    Zstd(Arc<Mutex<zstd::stream::raw::Encoder<'static>>>),
    /// A directory sync's sending (`pack.open`): each file's Git blob id as its pieces are packed (`zstd.pack`), by path,
    /// with where its next piece starts.
    Pack(Arc<Mutex<HashMap<String, (sha1::Sha1, u64)>>>),
}

/// A listening socket: TCP on this machine's loopback (one bound here, or one a launcher bound and handed down by its
/// descriptor), or a Unix socket by its path.
enum Listener {
    Tcp(tokio::net::TcpListener),
    #[cfg(unix)]
    Unix(tokio::net::UnixListener),
}

impl Listener {
    /// The next connection, as a socket read and written as `tcp.open`'s are, and who it came from.
    async fn accept(&self) -> Result<(Handle, String), String> {
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

/// A zstd stream being taken apart, a piece at a time as the core is given them: libzstd's streaming decoder (frames
/// one after another, a piece cut anywhere), and whether what it took so far ended a frame.
struct Unzstd {
    decoder: zstd::stream::raw::Decoder<'static>,
    whole: bool,
}

impl Unzstd {
    fn new() -> Result<Unzstd, String> {
        Ok(Unzstd { decoder: zstd::stream::raw::Decoder::new().map_err(err)?, whole: true })
    }

    /// `input` taken apart: all it makes, nothing held back.
    fn take(&mut self, input: &[u8]) -> Result<Vec<u8>, String> {
        use zstd::stream::raw::{InBuffer, Operation, OutBuffer};
        let mut out = Vec::new();
        let mut src = InBuffer::around(input);
        let mut buf = vec![0u8; 128 * 1024];
        loop {
            let mut dst = OutBuffer::around(&mut buf[..]);
            let hint = self.decoder.run(&mut src, &mut dst).map_err(err)?;
            let made = dst.pos();
            out.extend_from_slice(&buf[..made]);
            // (0: a frame ended and all of it is out; said only of what took something, an empty piece says nothing)
            if made > 0 || src.pos() > 0 {
                self.whole = hint == 0;
            }
            if src.pos() >= input.len() && made < buf.len() {
                return Ok(out);
            }
        }
    }
}

type Job = Box<dyn FnOnce() + Send>;

struct Inner {
    complete: Complete,
    ctx: Ctx,
    dir: PathBuf,
    /// One thread does every file and database job, in the order they were asked for (as the Rust core's did).
    disk: Mutex<mpsc::Sender<Job>>,
    db: Arc<Mutex<DbHandle>>,
    tls: Arc<rustls::ClientConfig>,
    http: Mutex<reqwest::Client>,
    /// A pool for each cloud entry requests go through (`entry`: station/AGENTS.md, Cloud TCP entries), by its host and port.
    entries: Mutex<HashMap<(String, u16), reqwest::Client>>,
    /// Fetch calls still owned by the core. Their exchange is dropped when its caller stops waiting, even between
    /// response headers and the body. Registered before spawning, so an immediate cancellation cannot miss it.
    fetches: Mutex<HashMap<u64, tokio::sync::oneshot::Sender<()>>>,
    handles: Mutex<HashMap<u64, Handle>>,
    next: AtomicU64,
    /// The accounts' databases open, by id, with their files.
    sqls: Mutex<HashMap<u64, (Option<PathBuf>, rusqlite::Connection)>>,
    /// Files being read a part at a time (`text.open`), by id.
    texts: Mutex<HashMap<u64, TextReader>>,
    /// How long an account's database is waited for as it is opened, while another process holds it (`open_wait`).
    open_wait: std::time::Duration,
    /// Where a message for the app goes straight from here (`sf_shell_set_say`): none, nothing is tapped.
    say: Mutex<Option<(Say, Ctx)>>,
    /// Where a tapped view's records are offered first (`sf_shell_set_media`): none, all are said.
    media: Mutex<Option<(Media, Ctx)>>,
    adb: adb::Adb,
}

pub struct Shell {
    runtime: tokio::runtime::Runtime,
    inner: Arc<Inner>,
}

/// The connection to `core.db`, opened on first use.
struct DbHandle {
    path: PathBuf,
    conn: Option<rusqlite::Connection>,
}

fn open_db(handle: &mut DbHandle) -> Result<&mut rusqlite::Connection, String> {
    if handle.conn.is_none() {
        let conn = rusqlite::Connection::open(&handle.path).map_err(err)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             CREATE TABLE IF NOT EXISTS records (tbl TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY (tbl, key)) WITHOUT ROWID;",
        )
        .map_err(err)?;
        handle.conn = Some(conn);
    }
    Ok(handle.conn.as_mut().expect("opened above"))
}

/// A statement's parameters as SQLite takes them: numbers (whole ones as integers), text, null; bytes as an array.
fn sql_params(a: &Value) -> Vec<rusqlite::types::Value> {
    use rusqlite::types::Value as V;
    a.get("params")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .map(|v| match v {
                    Value::Null => V::Null,
                    Value::Bool(b) => V::Integer(i64::from(*b)),
                    Value::Number(n) => n.as_i64().map(V::Integer).unwrap_or_else(|| V::Real(n.as_f64().unwrap_or(0.0))),
                    Value::String(s) => V::Text(s.clone()),
                    Value::Array(bytes) => V::Blob(bytes.iter().map(|b| b.as_u64().unwrap_or(0) as u8).collect()),
                    Value::Object(_) => V::Text(v.to_string()),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn tls_config() -> rustls::ClientConfig {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("ring supports the default protocol versions")
        .with_root_certificates(roots)
        .with_no_client_auth()
}

/// As the Rust core's native host had it: HTTP/2 pings and TCP keepalive find connections a sleep or a new network left dead.
fn http_client(tls: &rustls::ClientConfig) -> reqwest::Client {
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

/// File names hold only letters, digits, `-` and `_`; the rest is %XX (as the Rust core had them).
fn storage_path(dir: &std::path::Path, key: &str) -> PathBuf {
    let mut name = String::new();
    for byte in key.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' => name.push(byte as char),
            _ => name.push_str(&format!("%{byte:02X}")),
        }
    }
    dir.join(name)
}

/// A file to write a kept value in (`storage.set`: the partial one, renamed over the value once written). On Unix
/// its user's alone whatever the process's umask (0600, less what the umask takes of that): a value kept is a
/// device's key among others, and was readable by whomever the umask let (0644 under most), unless the program had
/// set the whole process's umask for it. What a crash left there is taken away first and the file made only if none
/// is there, so its mode is the one it is made with (none is set after: a filesystem may refuse that, where writing
/// did not fail before) and nothing is written through a link left in its place. One shell writes its values one
/// at a time (the disk thread). Two processes writing one key at once, which no program does, each write a file of
/// their own, and one of them fails (here, or at its rename), where their bytes went into one file before.
fn create_private(path: &std::path::Path) -> std::io::Result<std::fs::File> {
    #[cfg(unix)]
    {
        match std::fs::remove_file(path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
        let mut options = std::fs::OpenOptions::new();
        std::os::unix::fs::OpenOptionsExt::mode(options.write(true).create_new(true), 0o600);
        options.open(path)
    }
    #[cfg(not(unix))]
    {
        std::fs::File::create(path)
    }
}

fn headers_of(response: &reqwest::Response) -> Value {
    Value::Array(response.headers().iter().map(|(k, v)| json!([k.as_str(), String::from_utf8_lossy(v.as_bytes())])).collect())
}

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

/// A connection to the Unix socket at `path` that a stream is carried into, `head` written to it first (what tells the
/// other side which stream it is); an error where nothing listens there or it takes nothing.
async fn open_unix(path: &str, head: &[u8]) -> Result<(SocketRead, SocketWrite), String> {
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
async fn tell_unix(path: &str, bytes: &[u8]) -> Result<(), String> {
    #[cfg(unix)]
    {
        let mut socket = tokio::net::UnixStream::connect(path).await.map_err(err)?;
        socket.write_all(bytes).await.map_err(err)?;
        socket.shutdown().await.map_err(err)
    }
    #[cfg(not(unix))]
    {
        let _ = (path, bytes);
        Err("Unix sockets are Unix's".into())
    }
}

/// `fs.scan` of one path.
fn scan_one(path: &str, follow: bool, hash: bool, most: u64) -> Result<Value, String> {
    let Ok(m) = (if follow { std::fs::metadata(path) } else { std::fs::symlink_metadata(path) }) else { return Ok(Value::Null) };
    let kind = if m.file_type().is_symlink() { "link" } else if m.is_file() { "file" } else if m.is_dir() { "dir" } else { "other" };
    #[cfg(unix)]
    let (mode, dev) = {
        use std::os::unix::fs::MetadataExt;
        (m.mode(), m.dev())
    };
    #[cfg(not(unix))]
    let (mode, dev) = (if m.permissions().readonly() { 0o444 } else { 0o666 }, 0u64);
    let mut v = json!({ "kind": kind, "size": m.len(), "mode": mode, "dev": dev });
    if hash && kind == "link" {
        let target = std::fs::read_link(path).map_err(err)?;
        v["link"] = json!(target.to_string_lossy());
    } else if hash && kind == "file" && m.len() <= most {
        use sha1::Digest;
        use std::io::Read;
        let mut file = std::fs::File::open(path).map_err(err)?;
        let size = m.len();
        let mut h = sha1::Sha1::new();
        h.update(format!("blob {size}\0").as_bytes());
        let (mut buf, mut read) = (vec![0u8; 1 << 20], 0u64);
        loop {
            let n = file.read(&mut buf).map_err(err)?;
            if n == 0 {
                break;
            }
            read += n as u64;
            h.update(&buf[..n]);
        }
        if read != size {
            return Err(format!("{path} changed while it was read"));
        }
        v["hash"] = json!(hex::encode(h.finalize()));
    }
    Ok(v)
}

/// `zstd.pack`'s work: the pieces read, their ids checked, packed into `out`.
fn pack_pieces(ids: &Mutex<HashMap<String, (sha1::Sha1, u64)>>, out: &std::path::Path, level: i32, pieces: &[Value]) -> Result<Value, String> {
    use sha1::Digest;
    use std::io::{Read, Seek, SeekFrom, Write};
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut z = zstd::stream::write::Encoder::new(options.open(out).map_err(err)?, level).map_err(err)?;
    let mut raw = 0u64;
    let changed = |i: usize| Ok(json!({ "changed": i }));
    for (i, p) in pieces.iter().enumerate() {
        let (Some(path), Some(offset), Some(length), Some(size), Some(id)) = (p[0].as_str(), p[1].as_u64(), p[2].as_u64(), p[3].as_u64(), p[4].as_str()) else {
            return Err("bad piece".into());
        };
        let data = if p[5].as_bool().unwrap_or(false) {
            // (a link's target as Node's readlink gives it, its id that of its text)
            let Ok(target) = std::fs::read_link(path) else { return changed(i) };
            let bytes = target.to_string_lossy().into_owned().into_bytes();
            let mut h = sha1::Sha1::new();
            h.update(format!("blob {}\0", bytes.len()).as_bytes());
            h.update(&bytes);
            if offset != 0 || bytes.len() as u64 != length || hex::encode(h.finalize()) != id {
                return changed(i);
            }
            bytes
        } else {
            let mut data = vec![0u8; length as usize];
            // Still the regular file it was listed as, of the size it was: never through a link put in its place (the
            // file itself opened without following one where the system can), nor grown, whose first bytes alone
            // would hash as they did.
            let still = std::fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && m.len() == size);
            let read = still && {
                let mut o = std::fs::OpenOptions::new();
                o.read(true);
                #[cfg(unix)]
                std::os::unix::fs::OpenOptionsExt::custom_flags(&mut o, libc::O_NOFOLLOW | libc::O_NONBLOCK);
                o.open(path)
                    .and_then(|mut f| {
                        let m = f.metadata()?;
                        if !m.is_file() || m.len() != size {
                            return Ok(false);
                        }
                        f.seek(SeekFrom::Start(offset))?;
                        f.read_exact(&mut data)?;
                        Ok(true)
                    })
                    .unwrap_or(false)
            };
            if !read {
                return changed(i);
            }
            let mut ids = ids.lock().unwrap();
            // In order: from its start a new id, on from where it was; a piece read again (a request packed anew) or
            // after its id was checked already is not counted twice.
            match ids.get_mut(path) {
                Some((h, next)) if *next == offset => {
                    h.update(&data);
                    *next += length;
                }
                Some((_, next)) if offset > *next => return changed(i),
                Some(_) => {}
                None if offset == 0 => {
                    let mut h = sha1::Sha1::new();
                    h.update(format!("blob {size}\0").as_bytes());
                    h.update(&data);
                    ids.insert(path.to_string(), (h, length));
                }
                None => {}
            }
            if ids.get(path).is_some_and(|(_, next)| *next == size) {
                let (h, _) = ids.remove(path).expect("there");
                if hex::encode(h.finalize()) != id {
                    return changed(i);
                }
            }
            data
        };
        raw += data.len() as u64;
        z.write_all(&data).map_err(err)?;
    }
    let mut file = z.finish().map_err(err)?;
    file.flush().map_err(err)?;
    let packed = file.metadata().map_err(err)?.len();
    Ok(json!({ "raw": raw, "packed": packed }))
}

/// A file of the program's own made anew where it writes what no one else is to read: 0600.
fn own_file(path: &std::path::Path) -> Result<std::fs::File, String> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let file = options.open(path).map_err(err)?;
    // (made before, with other bits: as archive.ts's chmod)
    #[cfg(unix)]
    file.set_permissions(std::os::unix::fs::PermissionsExt::from_mode(0o600)).map_err(err)?;
    Ok(file)
}

/// Every zstd frame of the file at `path` as one stream, read whole: none at all, or one cut, fails.
fn unzstd_whole(path: &std::path::Path) -> Result<zstd::stream::read::Decoder<'static, std::io::BufReader<std::fs::File>>, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if file.metadata().map_err(err)?.len() == 0 {
        return Err(format!("{}: no zstd frame", path.display()));
    }
    zstd::stream::read::Decoder::new(file).map_err(err)
}

/// As much as `source` gives up to `buf`'s length (less only at its end).
fn read_up_to(source: &mut dyn std::io::Read, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut got = 0;
    while got < buf.len() {
        match source.read(&mut buf[got..]) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(got)
}

/// `zstd.segments`' work.
fn segment_into(path: &std::path::Path, unzstd: bool, out: &std::path::Path, segment: usize) -> Result<Value, String> {
    use std::io::Write;
    let mut source: Box<dyn std::io::Read> = if unzstd {
        Box::new(unzstd_whole(path)?)
    } else {
        Box::new(std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?)
    };
    let mut file = std::io::BufWriter::new(own_file(out)?);
    let mut z = zstd::bulk::Compressor::new(3).map_err(err)?;
    z.set_parameter(zstd::zstd_safe::CParameter::ChecksumFlag(true)).map_err(err)?;
    let mut frames: Vec<Value> = Vec::new();
    let mut frame = |raw: &[u8], file: &mut std::io::BufWriter<std::fs::File>| -> Result<(), String> {
        let bytes = z.compress(raw).map_err(err)?;
        file.write_all(&bytes).map_err(err)?;
        frames.push(json!([bytes.len(), raw.len()]));
        Ok(())
    };
    let mut held: Vec<u8> = Vec::with_capacity(segment + (1 << 20));
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = read_up_to(&mut *source, &mut buf).map_err(|e| format!("{}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        held.extend_from_slice(&buf[..n]);
        // (as zork's segment at a snapshot: what comes after its last line goes on in the next)
        while held.len() > segment {
            let cut = held[..segment].iter().rposition(|&b| b == b'\n').map_or(segment, |i| i + 1);
            frame(&held[..cut], &mut file)?;
            held.drain(..cut);
        }
    }
    frame(&held, &mut file)?;
    file.flush().map_err(err)?;
    Ok(json!({ "frames": frames }))
}

/// What `zstd.check` does with what the frames hold, a piece at a time.
struct Checked<'a> {
    hash: sha2::Sha256,
    size: u64,
    into: Option<std::io::BufWriter<std::fs::File>>,
    same: Option<(std::io::BufReader<std::fs::File>, Vec<u8>)>,
    path: &'a std::path::Path,
}

impl Checked<'_> {
    /// A piece taken: where the file it is compared with is not it, how ("shortened", "changed").
    fn take(&mut self, piece: &[u8]) -> Result<Option<&'static str>, String> {
        use sha2::Digest;
        use std::io::Write;
        self.hash.update(piece);
        self.size += piece.len() as u64;
        if let Some(into) = self.into.as_mut() {
            into.write_all(piece).map_err(err)?;
        }
        if let Some((file, mine)) = self.same.as_mut() {
            mine.resize(piece.len(), 0);
            let got = read_up_to(file, mine).map_err(err)?;
            if got < piece.len() {
                return Ok(Some("shortened"));
            }
            if mine.as_slice() != piece {
                return Ok(Some("changed"));
            }
        }
        Ok(None)
    }

    /// Everything of a zstd stream taken; how it differs, as `take`.
    fn drain(&mut self, mut from: impl std::io::Read) -> Result<Option<&'static str>, String> {
        let mut buf = vec![0u8; 256 * 1024];
        loop {
            let n = read_up_to(&mut from, &mut buf).map_err(|e| format!("{}: {e}", self.path.display()))?;
            if n == 0 {
                return Ok(None);
            }
            if let Some(differs) = self.take(&buf[..n])? {
                return Ok(Some(differs));
            }
        }
    }
}

/// `zstd.check`'s work.
fn check_frames(path: &std::path::Path, frames: Option<&[(u64, u64, u64)]>, into: Option<&std::path::Path>, same: Option<&std::path::Path>) -> Result<Value, String> {
    use sha2::Digest;
    use std::io::{Read, Seek, SeekFrom};
    let mut checked = Checked {
        hash: sha2::Sha256::new(),
        size: 0,
        into: into.map(own_file).transpose()?.map(std::io::BufWriter::new),
        same: same.map(|p| std::fs::File::open(p).map(|f| (std::io::BufReader::new(f), Vec::new()))).transpose().map_err(err)?,
        path,
    };
    let differs = match frames {
        None => checked.drain(unzstd_whole(path)?)?,
        Some(frames) => {
            let mut file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
            let mut differs = None;
            for &(at, packed, size) in frames {
                file.seek(SeekFrom::Start(at)).map_err(err)?;
                let before = checked.size;
                // (each frame alone, as a reader of a page decompresses it: one that ends early is cut, one with bytes
                // after its end is not one frame)
                let mut decoder = zstd::stream::read::Decoder::new((&mut file).take(packed)).map_err(err)?.single_frame();
                differs = checked.drain(&mut decoder)?;
                if differs.is_some() {
                    break;
                }
                let rest = decoder.finish();
                if !rest.buffer().is_empty() || rest.get_ref().limit() != 0 {
                    return Err("a put-away transcript frame has trailing bytes".into());
                }
                if checked.size - before != size {
                    return Err("a put-away transcript frame has the wrong size".into());
                }
            }
            differs
        }
    };
    if let Some(differs) = differs {
        return Ok(json!({ "differs": differs }));
    }
    if let Some((file, mine)) = checked.same.as_mut() {
        mine.resize(1, 0);
        if read_up_to(file, mine).map_err(err)? != 0 {
            return Ok(json!({ "differs": "changed" }));
        }
    }
    if let Some(into) = checked.into.take() {
        let file = into.into_inner().map_err(err)?;
        file.sync_all().map_err(err)?;
    }
    Ok(json!({ "size": checked.size, "sha256": hex::encode(checked.hash.finalize()) }))
}

/// A session's workspace put away (station/src/sessions/archive.ts `packWorkspaceIf`, `restoreWorkspace`,
/// `emptyWorkspace`, `workspaceFile`, which ask station/mb src/packed, which asks these: `tar.pack`, `tar.unpack`,
/// `tar.file`): a GNU tar as the tar crate wrote it for the Rust station (station/test/archive-rs), zstd level 3 with its
/// checksum, written and read here a block at a time, none of it through the program or the station's heap. What the
/// TypeScript it replaced did is station/test/reference/workspace-archive.ts, which station/test/mb-packed.test.ts holds
/// these to both ways, as station/test/cold-compat.test.ts holds them to the Rust station's.
mod tar {
    use super::{err, own_file, read_up_to};
    use serde_json::{Value, json};
    use std::collections::BTreeMap;
    use std::fs;
    use std::io::{self, Read, Seek, SeekFrom, Write};
    use std::path::{Path, PathBuf};

    const BLOCK: usize = 512;

    /// Its path said with what failed of it.
    fn at(path: &Path, e: impl std::fmt::Display) -> String {
        format!("{}: {e}", path.display())
    }

    // ── zstd ──

    /// The zstd frames of the file at `path` walked by their headers (RFC 8878: frame header, block headers, checksum;
    /// skippable frames passed over), failing unless each is there whole, nothing after the last: a cut archive is never
    /// read as one that ends there. Microseconds: only the headers are read.
    pub(super) fn whole_frames(path: &Path) -> Result<(), String> {
        let mut file = fs::File::open(path).map_err(|e| at(path, e))?;
        let size = file.metadata().map_err(err)?.len();
        let cut = || format!("{}: incomplete zstd frame", path.display());
        let mut bytes = |at: u64, buf: &mut [u8]| -> Result<(), String> {
            if at + buf.len() as u64 > size {
                return Err(cut());
            }
            file.seek(SeekFrom::Start(at)).map_err(err)?;
            file.read_exact(buf).map_err(|_| cut())
        };
        if size == 0 {
            return Err(format!("{}: no zstd frame", path.display()));
        }
        let mut at = 0u64;
        while at < size {
            let mut word = [0u8; 4];
            bytes(at, &mut word)?;
            let magic = u32::from_le_bytes(word);
            if magic & 0xffff_fff0 == 0x184d_2a50 {
                bytes(at + 4, &mut word)?;
                at += 8 + u32::from_le_bytes(word) as u64;
                if at > size {
                    return Err(cut());
                }
                continue;
            }
            if magic != 0xfd2f_b528 {
                return Err(format!("{}: not a zstd frame", path.display()));
            }
            let mut one = [0u8; 1];
            bytes(at + 4, &mut one)?;
            let descriptor = one[0];
            let size_flag = descriptor >> 6;
            let single = (descriptor >> 5) & 1;
            let checksummed = (descriptor >> 2) & 1;
            let dictionary = [0u64, 1, 2, 4][(descriptor & 3) as usize];
            let content = if size_flag == 0 { single as u64 } else { [0u64, 2, 4, 8][size_flag as usize] };
            at += 5 + if single == 1 { 0 } else { 1 } + dictionary + content;
            loop {
                let mut head = [0u8; 3];
                bytes(at, &mut head)?;
                let block = head[0] as u32 | (head[1] as u32) << 8 | (head[2] as u32) << 16;
                let kind = (block >> 1) & 3;
                if kind == 3 {
                    return Err(format!("{}: reserved zstd block type", path.display()));
                }
                at += 3 + if kind == 1 { 1 } else { (block >> 3) as u64 };
                if block & 1 == 1 {
                    break;
                }
            }
            if checksummed == 1 {
                at += 4;
            }
            if at > size {
                return Err(cut());
            }
        }
        Ok(())
    }

    /// What the archive at `path` holds, as it comes: its frames whole first, each checksum verified as it ends.
    fn unzstd(path: &Path) -> Result<zstd::stream::read::Decoder<'static, io::BufReader<fs::File>>, String> {
        whole_frames(path)?;
        let file = fs::File::open(path).map_err(|e| at(path, e))?;
        zstd::stream::read::Decoder::new(file).map_err(err)
    }

    /// Everything left of `from` read (the end of the zstd stream and its checksum).
    fn drain(from: &mut impl Read) -> Result<(), String> {
        io::copy(from, &mut io::sink()).map(|_| ()).map_err(err)
    }

    // ── numbers in headers ──

    /// A number into a header field: octal, zero-padded, NUL-ended; past what that holds, GNU's base-256.
    fn number_into(h: &mut [u8], at: usize, len: usize, value: u64) {
        let octal = format!("{value:o}");
        if octal.len() <= len - 1 {
            h[at..at + len - 1].copy_from_slice(format!("{octal:0>width$}", width = len - 1).as_bytes());
            h[at + len - 1] = 0;
            return;
        }
        let mut rest = value;
        for i in (1..len).rev() {
            h[at + i] = (rest & 0xff) as u8;
            rest >>= 8;
        }
        h[at] = 0x80;
    }

    /// A field's number: octal (spaces and NULs around it), or base-256 when its first byte's high bit is set.
    fn number_from(field: &[u8]) -> Result<u64, String> {
        if field[0] & 0x80 != 0 {
            let mut n = (field[0] & 0x7f) as u64;
            for &b in &field[1..] {
                n = n.checked_mul(256).and_then(|n| n.checked_add(b as u64)).ok_or("numeric field too large")?;
            }
            return Ok(n);
        }
        let text = String::from_utf8_lossy(nul_ended(field));
        let text = text.trim();
        if text.is_empty() {
            return Ok(0);
        }
        if !text.bytes().all(|b| (b'0'..=b'7').contains(&b)) {
            return Err(format!("numeric field was not a number: {text}"));
        }
        u64::from_str_radix(text, 8).map_err(|_| format!("numeric field was not a number: {text}"))
    }

    fn checksum(h: &[u8; BLOCK]) -> u64 {
        h.iter().enumerate().map(|(i, &b)| if (148..156).contains(&i) { 32 } else { b as u64 }).sum()
    }

    fn nul_ended(b: &[u8]) -> &[u8] {
        b.iter().position(|&x| x == 0).map_or(b, |n| &b[..n])
    }

    // ── writing ──

    struct Meta {
        mode: u64,
        uid: u64,
        gid: u64,
        mtime: u64,
        size: u64,
    }

    /// Header::new_gnu with its metadata (HeaderMode::Complete) and checksum.
    fn gnu_header(name: &[u8], kind: u8, meta: &Meta, link: Option<&[u8]>, device: Option<(u64, u64)>) -> [u8; BLOCK] {
        let mut h = [0u8; BLOCK];
        let n = name.len().min(100);
        h[..n].copy_from_slice(&name[..n]);
        number_into(&mut h, 100, 8, meta.mode);
        number_into(&mut h, 108, 8, meta.uid);
        number_into(&mut h, 116, 8, meta.gid);
        number_into(&mut h, 124, 12, meta.size);
        number_into(&mut h, 136, 12, meta.mtime);
        h[156] = kind;
        if let Some(link) = link {
            let n = link.len().min(100);
            h[157..157 + n].copy_from_slice(&link[..n]);
        }
        h[257..263].copy_from_slice(b"ustar ");
        h[263..265].copy_from_slice(b" \0");
        if let Some((major, minor)) = device {
            number_into(&mut h, 329, 8, major);
            number_into(&mut h, 337, 8, minor);
        }
        h[148..156].fill(b' ');
        let sum = checksum(&h);
        number_into(&mut h, 148, 8, sum);
        h
    }

    fn padding(size: u64) -> usize {
        (BLOCK - (size % BLOCK as u64) as usize) % BLOCK
    }

    /// prepare_header: a GNU long name ('L') or long link name ('K') entry, for what does not fit 100 bytes.
    fn long_entry(out: &mut dyn Write, kind: u8, value: &[u8]) -> io::Result<()> {
        let mut data = value.to_vec();
        data.push(0);
        let meta = Meta { mode: 0o644, uid: 0, gid: 0, mtime: 0, size: data.len() as u64 };
        out.write_all(&gnu_header(b"././@LongLink", kind, &meta, None, None))?;
        out.write_all(&data)?;
        out.write_all(&[0u8; BLOCK][..padding(data.len() as u64)])
    }

    /// The first 100 bytes of a name, cut back to whole UTF-8 characters (set_truncated_path_for_gnu_header).
    fn truncated(name: &[u8]) -> &[u8] {
        let mut end = name.len().min(100);
        while end > 0 && end < name.len() && name[end] & 0xc0 == 0x80 {
            end -= 1;
        }
        &name[..end]
    }

    #[cfg(unix)]
    fn name_bytes(name: &std::ffi::OsStr) -> Vec<u8> {
        std::os::unix::ffi::OsStrExt::as_bytes(name).to_vec()
    }
    #[cfg(not(unix))]
    fn name_bytes(name: &std::ffi::OsStr) -> Vec<u8> {
        name.to_string_lossy().into_owned().into_bytes()
    }

    /// The modification time in nanoseconds, as Node's `lstat(…, {bigint: true}).mtimeNs`.
    fn mtime_ns(meta: &fs::Metadata) -> i128 {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            meta.mtime() as i128 * 1_000_000_000 + meta.mtime_nsec() as i128
        }
        #[cfg(not(unix))]
        {
            match meta.modified().map(|t| t.duration_since(std::time::UNIX_EPOCH)) {
                Ok(Ok(d)) => d.as_nanos() as i128,
                Ok(Err(before)) => -(before.duration().as_nanos() as i128),
                Err(_) => 0,
            }
        }
    }

    /// Mode, owner and modification time as the tar crate's HeaderMode::Complete takes them (Node's lstat on Windows,
    /// which has no modes: 0o666, or 0o444 where read-only, with the kind's bits).
    fn meta_of(meta: &fs::Metadata, size: u64) -> Meta {
        let mtime = (mtime_ns(meta).div_euclid(1_000_000_000)).max(0) as u64;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            Meta { mode: meta.mode() as u64, uid: meta.uid() as u64, gid: meta.gid() as u64, mtime, size }
        }
        #[cfg(not(unix))]
        {
            let kind = if meta.file_type().is_symlink() { 0o120000 } else if meta.is_dir() { 0o040000 } else { 0o100000 };
            let bits = if meta.permissions().readonly() { 0o444 } else { 0o666 };
            Meta { mode: kind | bits, uid: 0, gid: 0, mtime, size }
        }
    }

    /// Builder::append_dir_all(".", dir) with follow_symlinks(false), then finish: `./` for the directory itself, then
    /// everything under it as `a/b` (directories before what is in them, each directory's names taken in reverse byte
    /// order, as the TypeScript walked them), links as links, special files as headers.
    fn write_tree(dir: &Path, out: &mut impl Write) -> Result<(), String> {
        let mut stack: Vec<(PathBuf, Vec<u8>)> = vec![(dir.to_path_buf(), Vec::new())];
        let mut buf = vec![0u8; 256 * 1024];
        while let Some((path, rel)) = stack.pop() {
            let meta = fs::symlink_metadata(&path).map_err(|e| at(&path, e))?;
            let name: &[u8] = if rel.is_empty() { b"./" } else { &rel };
            let head = |out: &mut dyn Write, kind: u8, size: u64, link: Option<&[u8]>, device: Option<(u64, u64)>| -> Result<(), String> {
                if name.len() > 100 {
                    long_entry(out, b'L', name).map_err(err)?;
                }
                let link = match link {
                    Some(l) if l.len() > 100 => {
                        long_entry(out, b'K', l).map_err(err)?;
                        Some(truncated(l))
                    }
                    other => other,
                };
                let shown = if name.len() > 100 { truncated(name) } else { name };
                out.write_all(&gnu_header(shown, kind, &meta_of(&meta, size), link, device)).map_err(err)
            };
            let kind = meta.file_type();
            if kind.is_dir() {
                let mut names = Vec::new();
                for entry in fs::read_dir(&path).map_err(|e| at(&path, e))? {
                    names.push(entry.map_err(|e| at(&path, e))?.file_name());
                }
                names.sort_by_key(|n| name_bytes(n));
                for child in names {
                    let mut r = rel.clone();
                    if !r.is_empty() {
                        r.push(b'/');
                    }
                    r.extend_from_slice(&name_bytes(&child));
                    stack.push((path.join(&child), r));
                }
                head(out, b'5', 0, None, None)?;
            } else if kind.is_symlink() {
                let target = fs::read_link(&path).map_err(|e| at(&path, e))?;
                head(out, b'2', 0, Some(&name_bytes(target.as_os_str())), None)?;
            } else if kind.is_file() {
                let size = meta.len();
                head(out, b'0', size, None, None)?;
                let mut file = fs::File::open(&path).map_err(|e| at(&path, e))?.take(size);
                let mut sent = 0u64;
                loop {
                    let n = read_up_to(&mut file, &mut buf).map_err(|e| at(&path, e))?;
                    if n == 0 {
                        break;
                    }
                    sent += n as u64;
                    out.write_all(&buf[..n]).map_err(err)?;
                }
                if sent != size {
                    return Err(format!("{} changed while archiving", path.display()));
                }
                out.write_all(&[0u8; BLOCK][..padding(size)]).map_err(err)?;
            } else {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::{FileTypeExt, MetadataExt};
                    if kind.is_socket() {
                        return Err(format!("{}: socket can not be archived", path.display()));
                    }
                    let code = if kind.is_fifo() {
                        b'6'
                    } else if kind.is_char_device() {
                        b'3'
                    } else if kind.is_block_device() {
                        b'4'
                    } else {
                        return Err(format!("{} has unknown file type", path.display()));
                    };
                    let dev = meta.rdev();
                    let major = ((dev >> 32) & 0xffff_f000) | ((dev >> 8) & 0x0000_0fff);
                    let minor = ((dev >> 12) & 0xffff_ff00) | (dev & 0x0000_00ff);
                    head(out, code, 0, None, Some((major, minor)))?;
                }
                #[cfg(not(unix))]
                return Err(format!("{} has unknown file type", path.display()));
            }
        }
        out.write_all(&[0u8; 2 * BLOCK]).map_err(err)
    }

    /// Every path under `dir` with its size and modification time, links not followed.
    fn snapshot(dir: &Path) -> Result<BTreeMap<PathBuf, (u64, i128)>, String> {
        let mut out = BTreeMap::new();
        let mut stack = vec![dir.to_path_buf()];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir).map_err(|e| at(&dir, e))? {
                let path = entry.map_err(|e| at(&dir, e))?.path();
                let meta = fs::symlink_metadata(&path).map_err(|e| at(&path, e))?;
                out.insert(path.clone(), (meta.len(), mtime_ns(&meta)));
                if meta.is_dir() {
                    stack.push(path);
                }
            }
        }
        Ok(out)
    }

    /// `tar.pack`'s work: the tree at `dir` into `out` (made anew, 0600, on disk), read back whole, and the tree found as
    /// it was before it was read.
    pub(super) fn pack(dir: &Path, out: &Path) -> Result<Value, String> {
        let before = snapshot(dir)?;
        let mut encoder = zstd::stream::write::Encoder::new(own_file(out)?, 3).map_err(err)?;
        encoder.include_checksum(true).map_err(err)?;
        let mut writer = io::BufWriter::with_capacity(1 << 20, encoder);
        write_tree(dir, &mut writer)?;
        let encoder = writer.into_inner().map_err(|e| err(e.error()))?;
        encoder.finish().map_err(err)?.sync_all().map_err(err)?;
        // Every entry read, to the end of the zstd stream and its checksum, before any original is touched.
        let mut check = unzstd(out)?;
        let mut entries = Entries::new(&mut check);
        while entries.next()?.is_some() {
            entries.skip()?;
        }
        drain(&mut check)?;
        if snapshot(dir)? != before {
            return Err("workspace changed while archiving; originals kept".into());
        }
        Ok(json!({}))
    }

    // ── reading ──

    #[derive(Clone, Copy, PartialEq)]
    enum Kind {
        File,
        Dir,
        Symlink,
        Hardlink,
        Char,
        Block,
        Fifo,
        Other,
    }

    struct Entry {
        /// The path's components ("." left out), and whether it began with "/".
        parts: Vec<Vec<u8>>,
        absolute: bool,
        kind: Kind,
        mode: u64,
        mtime: u64,
        size: u64,
        link: Option<Vec<u8>>,
    }

    /// Archive::entries: each entry named by the GNU long name or pax path before it, else its name (with the ustar
    /// prefix for a ustar header); headers' checksums checked; the archive ends at a zero block. An entry's body not
    /// read is skipped when the next is asked for.
    struct Entries<R: Read> {
        from: R,
        /// What is left unread of the entry given last: its body, then its padding.
        body: u64,
        pad: u64,
    }

    impl<R: Read> Entries<R> {
        fn new(from: R) -> Self {
            Entries { from, body: 0, pad: 0 }
        }

        fn skip_bytes(&mut self, mut n: u64) -> Result<(), String> {
            let mut buf = [0u8; 8192];
            while n > 0 {
                let want = n.min(buf.len() as u64) as usize;
                let got = read_up_to(&mut self.from, &mut buf[..want]).map_err(err)?;
                if got == 0 {
                    return Err("unexpected end of archive".into());
                }
                n -= got as u64;
            }
            Ok(())
        }

        /// The rest of the entry given last passed over.
        fn skip(&mut self) -> Result<(), String> {
            let n = self.body + self.pad;
            self.body = 0;
            self.pad = 0;
            self.skip_bytes(n)
        }

        /// The entry given last's body into `out`.
        fn body_into(&mut self, out: &mut impl Write) -> Result<(), String> {
            let mut buf = vec![0u8; 256 * 1024];
            while self.body > 0 {
                let want = self.body.min(buf.len() as u64) as usize;
                let got = read_up_to(&mut self.from, &mut buf[..want]).map_err(err)?;
                if got == 0 {
                    return Err("unexpected end of archive".into());
                }
                out.write_all(&buf[..got]).map_err(err)?;
                self.body -= got as u64;
            }
            Ok(())
        }

        /// A meta entry's data whole (a long name, pax records).
        fn data(&mut self, size: u64) -> Result<Vec<u8>, String> {
            let mut out = Vec::new();
            (&mut self.from).take(size).read_to_end(&mut out).map_err(err)?;
            if (out.len() as u64) < size {
                return Err("unexpected end of archive".into());
            }
            self.skip_bytes(padding(size) as u64)?;
            Ok(out)
        }

        fn next(&mut self) -> Result<Option<Entry>, String> {
            let (body, pad) = (self.body, self.pad);
            self.body = 0;
            self.pad = 0;
            self.skip_bytes(body + pad)?;
            let mut long_name: Option<Vec<u8>> = None;
            let mut long_link: Option<Vec<u8>> = None;
            let mut pax: Option<BTreeMap<Vec<u8>, Vec<u8>>> = None;
            loop {
                let mut h = [0u8; BLOCK];
                let got = read_up_to(&mut self.from, &mut h).map_err(err)?;
                if got == 0 || (got == BLOCK && h.iter().all(|&b| b == 0)) {
                    return Ok(None);
                }
                if got < BLOCK {
                    return Err("unexpected end of archive".into());
                }
                if number_from(&h[148..156])? != checksum(&h) {
                    return Err("archive header checksum mismatch".into());
                }
                let kind = h[156];
                let mut size = number_from(&h[124..136])?;
                if let Some(given) = pax.as_ref().and_then(|p| p.get(b"size".as_slice()))
                    && !matches!(kind, b'x' | b'g' | b'L' | b'K')
                {
                    let text = String::from_utf8_lossy(given);
                    size = text.trim().parse().map_err(|_| format!("pax size was not a number: {text}"))?;
                }
                match kind {
                    b'L' => {
                        long_name = Some(nul_ended(&self.data(size)?).to_vec());
                        continue;
                    }
                    b'K' => {
                        long_link = Some(nul_ended(&self.data(size)?).to_vec());
                        continue;
                    }
                    b'x' => {
                        pax = Some(pax_records(&self.data(size)?));
                        continue;
                    }
                    b'g' => {
                        self.data(size)?;
                        continue;
                    }
                    _ => {}
                }
                let prefix: &[u8] = if &h[257..263] == b"ustar\0" { nul_ended(&h[345..500]) } else { b"" };
                let name = nul_ended(&h[0..100]);
                let mut pax = pax.take().unwrap_or_default();
                let raw = long_name.take().or_else(|| pax.remove(b"path".as_slice())).unwrap_or_else(|| {
                    if prefix.is_empty() { name.to_vec() } else { [prefix, b"/", name].concat() }
                });
                let link = long_link.take().or_else(|| pax.remove(b"linkpath".as_slice())).unwrap_or_else(|| nul_ended(&h[157..257]).to_vec());
                let kind = match kind {
                    b'0' | 0 | b'7' => Kind::File,
                    b'5' => Kind::Dir,
                    b'2' => Kind::Symlink,
                    b'1' => Kind::Hardlink,
                    b'3' => Kind::Char,
                    b'4' => Kind::Block,
                    b'6' => Kind::Fifo,
                    _ => Kind::Other,
                };
                self.body = size;
                self.pad = padding(size) as u64;
                return Ok(Some(Entry {
                    parts: raw.split(|&b| b == b'/').filter(|p| !p.is_empty() && *p != b".").map(<[u8]>::to_vec).collect(),
                    absolute: raw.first() == Some(&b'/'),
                    kind,
                    mode: number_from(&h[100..108])?,
                    mtime: number_from(&h[136..148])?,
                    size,
                    link: matches!(kind, Kind::Symlink | Kind::Hardlink).then_some(link),
                }));
            }
        }
    }

    /// pax records ("<length> <key>=<value>\n") by key.
    fn pax_records(data: &[u8]) -> BTreeMap<Vec<u8>, Vec<u8>> {
        let mut out = BTreeMap::new();
        let mut rest = data;
        while !rest.is_empty() {
            let Some(space) = rest.iter().position(|&b| b == b' ') else { break };
            let Some(len) = std::str::from_utf8(&rest[..space]).ok().and_then(|s| s.trim().parse::<usize>().ok()) else { break };
            if len <= space + 1 || len > rest.len() {
                break;
            }
            let record = &rest[space + 1..len - 1];
            rest = &rest[len..];
            if let Some(eq) = record.iter().position(|&b| b == b'=') {
                out.insert(record[..eq].to_vec(), record[eq + 1..].to_vec());
            }
        }
        out
    }

    #[cfg(unix)]
    fn os(part: &[u8]) -> std::ffi::OsString {
        use std::os::unix::ffi::OsStrExt;
        std::ffi::OsStr::from_bytes(part).to_os_string()
    }
    #[cfg(not(unix))]
    fn os(part: &[u8]) -> std::ffi::OsString {
        String::from_utf8_lossy(part).into_owned().into()
    }

    fn joined(dest: &Path, parts: &[Vec<u8>]) -> PathBuf {
        let mut path = dest.to_path_buf();
        for p in parts {
            path.push(os(p));
        }
        path
    }

    /// A file's or directory's mode set: on Windows, which has none, read-only where its owner may not write (as Node's
    /// chmod there).
    fn set_mode(path: &Path, mode: u64) -> Result<(), String> {
        #[cfg(unix)]
        let permissions = std::os::unix::fs::PermissionsExt::from_mode((mode & 0o7777) as u32);
        #[cfg(not(unix))]
        let permissions = {
            let mut p = fs::metadata(path).map_err(|e| at(path, e))?.permissions();
            p.set_readonly(mode & 0o200 == 0);
            p
        };
        fs::set_permissions(path, permissions).map_err(|e| at(path, e))
    }

    /// `make` done at `path`, what was there first removed where it was already.
    fn replace<T>(path: &Path, make: impl Fn() -> io::Result<T>) -> Result<T, String> {
        match make() {
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                fs::remove_file(path).map_err(|e| at(path, e))?;
                make().map_err(|e| at(path, e))
            }
            other => other.map_err(|e| at(path, e)),
        }
    }

    /// A link at `path` to `target`; false where the machine refused it (Windows without the privilege: what stands in
    /// for it is made once the tree is at its final path, archive.ts `restoreWorkspace`).
    fn symlink(target: &[u8], path: &Path) -> Result<bool, String> {
        #[cfg(unix)]
        {
            replace(path, || std::os::unix::fs::symlink(os(target), path))?;
            Ok(true)
        }
        #[cfg(windows)]
        {
            let target = os(target);
            // (as Node's symlink with no type: a directory's where its target is one)
            let dir = path.parent().map(|p| p.join(&target)).is_some_and(|t| t.is_dir());
            let make = || if dir { std::os::windows::fs::symlink_dir(&target, path) } else { std::os::windows::fs::symlink_file(&target, path) };
            let made = match make() {
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    fs::remove_file(path).map_err(|e| at(path, e))?;
                    make()
                }
                other => other,
            };
            match made {
                Ok(()) => Ok(true),
                // (ERROR_PRIVILEGE_NOT_HELD: Node's EPERM, platform/windows.ts `linkRefused`)
                Err(e) if e.raw_os_error() == Some(1314) || e.kind() == io::ErrorKind::PermissionDenied => Ok(false),
                Err(e) => Err(at(path, e)),
            }
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (target, path);
            Ok(false)
        }
    }

    /// `tar.unpack`'s work: Archive::unpack with preserve_permissions: entries with `..` skipped, a leading `/` dropped,
    /// nothing written through a link out of `dest`; directories made last, deepest first, with their modes; files with
    /// their modes and modification times. With `prefix`, only the files and directories under that first name. The
    /// links refused, by their path and target.
    pub(super) fn unpack(path: &Path, dest: &Path, prefix: Option<&str>) -> Result<Value, String> {
        let mut stream = unzstd(path)?;
        let root = fs::canonicalize(dest).map_err(|e| at(dest, e))?;
        let inside = |dir: &Path| -> Result<(), String> {
            let real = fs::canonicalize(dir).map_err(|e| at(dir, e))?;
            if !real.starts_with(&root) {
                return Err(format!("trying to unpack outside of destination path: {}", root.display()));
            }
            Ok(())
        };
        let mut dirs: Vec<(PathBuf, Vec<u8>, u64)> = Vec::new();
        let mut refused: Vec<Value> = Vec::new();
        let mut links: Vec<(PathBuf, Vec<u8>)> = Vec::new();
        let mut entries = Entries::new(&mut stream);
        while let Some(entry) = entries.next()? {
            if let Some(prefix) = prefix
                && (entry.absolute || entry.parts.first().map(Vec::as_slice) != Some(prefix.as_bytes()) || !matches!(entry.kind, Kind::File | Kind::Dir))
            {
                continue;
            }
            if entry.parts.is_empty() || entry.parts.iter().any(|p| p == b"..") {
                continue;
            }
            let path = joined(dest, &entry.parts);
            let key = entry.parts.join(&b'/');
            if entry.kind == Kind::Dir {
                dirs.push((path, key, entry.mode));
                continue;
            }
            if entry.kind == Kind::Other {
                continue;
            }
            let parent = path.parent().unwrap_or(dest);
            fs::create_dir_all(parent).map_err(|e| at(parent, e))?;
            inside(parent)?;
            match entry.kind {
                Kind::File => {
                    let mut file = replace(&path, || {
                        let mut options = fs::OpenOptions::new();
                        options.write(true).create_new(true);
                        #[cfg(unix)]
                        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
                        options.open(&path)
                    })?;
                    let mut writer = io::BufWriter::with_capacity(256 * 1024, &mut file);
                    entries.body_into(&mut writer)?;
                    writer.flush().map_err(|e| at(&path, e))?;
                    drop(writer);
                    let when = std::time::UNIX_EPOCH + std::time::Duration::from_secs(if entry.mtime == 0 { 1 } else { entry.mtime });
                    file.set_times(fs::FileTimes::new().set_accessed(when).set_modified(when)).map_err(|e| at(&path, e))?;
                    drop(file);
                    set_mode(&path, entry.mode)?;
                }
                Kind::Symlink => {
                    let link = entry.link.as_deref().unwrap_or_default().to_vec();
                    // (On Windows a link is a file's or a directory's, by what it leads to: made once every directory of
                    // the archive is, a link to one written after it (the walk's reverse order: `z -> a`) or to an empty
                    // one is a directory's. Until then nothing is there to be written through: a later entry under its
                    // path makes a directory there, and the link is refused as the path is taken.)
                    if cfg!(windows) {
                        links.push((path, link));
                    } else if !symlink(&link, &path)? {
                        refused.push(json!([path.to_string_lossy(), String::from_utf8_lossy(&link)]));
                    }
                }
                Kind::Hardlink => {
                    let link = entry.link.as_deref().unwrap_or_default();
                    let target: Vec<Vec<u8>> = link.split(|&b| b == b'/').filter(|p| !p.is_empty() && *p != b".").map(<[u8]>::to_vec).collect();
                    if target.iter().any(|p| p == b"..") {
                        return Err(format!("hard link outside of destination path: {}", String::from_utf8_lossy(link)));
                    }
                    let from = joined(dest, &target);
                    inside(from.parent().unwrap_or(dest))?;
                    replace(&path, || fs::hard_link(&from, &path))?;
                }
                Kind::Fifo => {
                    #[cfg(unix)]
                    {
                        let c = std::ffi::CString::new(std::os::unix::ffi::OsStrExt::as_bytes(path.as_os_str())).map_err(err)?;
                        replace(&path, || {
                            // SAFETY: `c` is a NUL-ended path that lives through the call.
                            if unsafe { libc::mkfifo(c.as_ptr(), (entry.mode & 0o7777) as libc::mode_t) } == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
                        })?;
                        // (its mode as given, not as the umask leaves it: as `mkfifo -m`)
                        set_mode(&path, entry.mode)?;
                    }
                    #[cfg(not(unix))]
                    return Err(format!("cannot unpack a named pipe: {}", String::from_utf8_lossy(&key)));
                }
                _ => return Err(format!("cannot unpack a device file: {}", String::from_utf8_lossy(&key))),
            }
        }
        // (the rest of the stream, to the end of its zstd frame and its checksum)
        drop(entries);
        drain(&mut stream)?;
        dirs.sort_by(|a, b| b.1.cmp(&a.1));
        // Every directory there first, then the links held back (Windows'), then the directories' modes: a read-only one
        // written into no more after.
        for (path, key, _) in &dirs {
            match fs::symlink_metadata(path) {
                Ok(there) if !there.is_dir() => {
                    return Err(format!("{} is not a directory in the archive's tree", String::from_utf8_lossy(key)));
                }
                Ok(_) => {}
                Err(_) => {
                    let parent = path.parent().unwrap_or(dest);
                    fs::create_dir_all(parent).map_err(|e| at(parent, e))?;
                    inside(parent)?;
                    fs::create_dir(path).map_err(|e| at(path, e))?;
                }
            }
        }
        for (path, link) in links {
            inside(path.parent().unwrap_or(dest))?;
            if !symlink(&link, &path)? {
                refused.push(json!([path.to_string_lossy(), String::from_utf8_lossy(&link)]));
            }
        }
        for (path, _, mode) in &dirs {
            set_mode(path, *mode)?;
        }
        Ok(json!({ "refused": refused }))
    }

    /// `tar.file`'s work: the file at `wanted` (its path's components in the archive) written to `out` (made anew,
    /// 0600) where the archive has one; the archive's frames found whole first.
    pub(super) fn file(path: &Path, wanted: &[String], out: &Path) -> Result<Value, String> {
        let mut stream = unzstd(path)?;
        let mut entries = Entries::new(&mut stream);
        while let Some(entry) = entries.next()? {
            if !entry.absolute
                && entry.kind == Kind::File
                && entry.parts.len() == wanted.len()
                && entry.parts.iter().zip(wanted).all(|(p, w)| p.as_slice() == w.as_bytes())
            {
                let mut file = io::BufWriter::new(own_file(out)?);
                entries.body_into(&mut file)?;
                file.flush().map_err(|e| at(out, e))?;
                return Ok(json!({ "found": true, "size": entry.size }));
            }
        }
        Ok(json!({ "found": false }))
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn temp(what: &str) -> PathBuf {
            let dir = std::env::temp_dir().join(format!("sf-tar-{what}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            dir
        }

        /// A tar of `blocks` (and its end) in zstd at `out`, as another program writes one.
        fn archive_of(out: &Path, blocks: &[Vec<u8>]) {
            let mut z = zstd::stream::write::Encoder::new(fs::File::create(out).unwrap(), 3).unwrap();
            z.include_checksum(true).unwrap();
            for b in blocks {
                z.write_all(b).unwrap();
            }
            z.write_all(&[0u8; 2 * BLOCK]).unwrap();
            z.finish().unwrap();
        }

        fn entry(name: &[u8], kind: u8, body: &[u8], link: Option<&[u8]>) -> Vec<u8> {
            let meta = Meta { mode: 0o644, uid: 0, gid: 0, mtime: 1_700_000_000, size: body.len() as u64 };
            let mut out = gnu_header(name, kind, &meta, link, None).to_vec();
            out.extend_from_slice(body);
            out.extend(std::iter::repeat_n(0u8, padding(body.len() as u64)));
            out
        }

        #[test]
        fn numbers_octal_and_base_256() {
            let mut h = [0u8; 12];
            number_into(&mut h, 0, 12, 0o755);
            assert_eq!(&h, b"00000000755\0");
            assert_eq!(number_from(&h).unwrap(), 0o755);
            number_into(&mut h, 0, 12, 1 << 40);
            assert_eq!(h[0], 0x80);
            assert_eq!(number_from(&h).unwrap(), 1 << 40);
            assert_eq!(number_from(b" 17 \0\0").unwrap(), 0o17);
            assert!(number_from(b"9\0").is_err());
            assert_eq!(truncated("名".repeat(40).as_bytes()).len(), 99);
        }

        #[cfg(unix)]
        #[test]
        fn a_tree_packed_comes_back_as_it_was() {
            use std::os::unix::fs::{MetadataExt, PermissionsExt};
            let root = temp("round");
            let ws = root.join("ws");
            let deep = format!("{}/{}/{}.txt", "d".repeat(60), "e".repeat(60), "名".repeat(40));
            fs::create_dir_all(ws.join(&deep).parent().unwrap()).unwrap();
            fs::write(ws.join(&deep), "deep").unwrap();
            fs::write(ws.join("a"), "linked").unwrap();
            fs::hard_link(ws.join("a"), ws.join("b")).unwrap();
            std::os::unix::fs::symlink(format!("{}/target", "t".repeat(150)), ws.join("far")).unwrap();
            fs::create_dir_all(ws.join("ro/inner")).unwrap();
            fs::write(ws.join("ro/inner/f"), "x").unwrap();
            fs::set_permissions(ws.join("ro"), fs::Permissions::from_mode(0o500)).unwrap();
            let c = std::ffi::CString::new(ws.join("pipe").to_str().unwrap()).unwrap();
            assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o640) }, 0);
            let out = root.join("w.tar.zst");
            pack(&ws, &out).unwrap();
            assert_eq!(fs::metadata(&out).unwrap().mode() & 0o777, 0o600);
            let dest = root.join("dest");
            fs::create_dir(&dest).unwrap();
            assert_eq!(unpack(&out, &dest, None).unwrap(), json!({ "refused": [] }));
            assert_eq!(fs::read_to_string(dest.join(&deep)).unwrap(), "deep");
            assert_eq!(fs::read_to_string(dest.join("b")).unwrap(), "linked");
            assert_eq!(fs::read_link(dest.join("far")).unwrap(), PathBuf::from(format!("{}/target", "t".repeat(150))));
            assert_eq!(fs::metadata(dest.join("ro")).unwrap().mode() & 0o7777, 0o500);
            assert_eq!(fs::read_to_string(dest.join("ro/inner/f")).unwrap(), "x");
            assert!(std::os::unix::fs::FileTypeExt::is_fifo(&fs::symlink_metadata(dest.join("pipe")).unwrap().file_type()));
            assert_eq!(fs::symlink_metadata(dest.join("pipe")).unwrap().mode() & 0o777, 0o640);
            // A file read out of it, by its path's components; a directory is none, nor what is not there.
            let wanted: Vec<String> = deep.split('/').map(str::to_string).collect();
            assert_eq!(file(&out, &wanted, &root.join("one")).unwrap(), json!({ "found": true, "size": 4 }));
            assert_eq!(fs::read_to_string(root.join("one")).unwrap(), "deep");
            assert_eq!(file(&out, &["ro".to_string()], &root.join("two")).unwrap(), json!({ "found": false }));
            assert!(!root.join("two").exists());
            for dir in [ws.join("ro"), dest.join("ro")] {
                fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).unwrap();
            }
            fs::remove_dir_all(&root).unwrap();
        }

        #[test]
        fn a_cut_or_padded_archive_is_never_read_as_whole() {
            let root = temp("cut");
            let whole = root.join("whole.zst");
            archive_of(&whole, &[entry(b"uploads/a.txt", b'0', &vec![b'a'; 5000], None)]);
            let bytes = fs::read(&whole).unwrap();
            let wanted = ["uploads".to_string(), "a.txt".to_string()];
            assert_eq!(file(&whole, &wanted, &root.join("got")).unwrap()["found"], json!(true));
            for (what, b) in [
                ("cut", bytes[..bytes.len() - 1].to_vec()),
                ("cut in its header", bytes[..6].to_vec()),
                ("bytes after", [bytes.clone(), b"xx".to_vec()].concat()),
                ("not zstd", b"broken archive".to_vec()),
                ("empty", Vec::new()),
            ] {
                let path = root.join(what);
                fs::write(&path, &b).unwrap();
                assert!(file(&path, &wanted, &root.join("got")).is_err(), "{what}");
                let dest = root.join(format!("{what}.dest"));
                fs::create_dir(&dest).unwrap();
                assert!(unpack(&path, &dest, None).is_err(), "{what}");
            }
            // A header whose checksum is wrong.
            let mut bad = entry(b"x", b'0', b"", None);
            bad[0] = b'y';
            let path = root.join("sum.zst");
            archive_of(&path, &[bad]);
            assert_eq!(unpack(&path, &root, None).unwrap_err(), "archive header checksum mismatch");
            fs::remove_dir_all(&root).unwrap();
        }

        #[test]
        fn pax_ustar_prefixes_and_only_the_uploads() {
            let root = temp("pax");
            let path = root.join("a.zst");
            let record = |k: &str, v: &str| {
                let body = format!(" {k}={v}\n");
                let mut n = body.len() + 1;
                if format!("{n}{body}").len() != n {
                    n += 1;
                }
                format!("{n}{body}")
            };
            let pax = format!("{}{}", record("path", "uploads/由 pax 命名.txt"), record("size", "3"));
            let mut ustar = entry(b"b.txt", b'0', b"bbb", None);
            ustar[257..263].copy_from_slice(b"ustar\0");
            ustar[263..265].copy_from_slice(b"00");
            ustar[345..352].copy_from_slice(b"uploads");
            ustar[148..156].fill(b' ');
            let sum = checksum(ustar[..BLOCK].try_into().unwrap());
            number_into(&mut ustar, 148, 8, sum);
            archive_of(&path, &[
                entry(b"./", b'5', b"", None),
                entry(b"pax", b'x', pax.as_bytes(), None),
                [gnu_header(b"ignored", b'0', &Meta { mode: 0o600, uid: 0, gid: 0, mtime: 0, size: 99 }, None, None).to_vec(), b"ccc".to_vec(), vec![0; BLOCK - 3]].concat(),
                ustar,
                entry(b"uploads/sub", b'5', b"", None),
                entry(b"src/main.rs", b'0', b"fn main", None),
                entry(b"uploads/link", b'2', b"", Some(b"../../etc")),
            ]);
            let dest = root.join("dest");
            fs::create_dir(&dest).unwrap();
            unpack(&path, &dest, Some("uploads")).unwrap();
            assert_eq!(fs::read_to_string(dest.join("uploads/由 pax 命名.txt")).unwrap(), "ccc");
            assert_eq!(fs::read_to_string(dest.join("uploads/b.txt")).unwrap(), "bbb");
            assert!(dest.join("uploads/sub").is_dir());
            assert!(!dest.join("src").exists() && fs::symlink_metadata(dest.join("uploads/link")).is_err());
            fs::remove_dir_all(&root).unwrap();
        }

        #[cfg(unix)]
        #[test]
        fn nothing_is_written_outside_its_destination() {
            let root = temp("out");
            let dest = root.join("dest");
            fs::create_dir(&dest).unwrap();
            // `..` is passed over; a link made first leads out, and a file under it is refused.
            let up = root.join("up.zst");
            archive_of(&up, &[entry(b"../escaped", b'0', b"no", None), entry(b"/abs/ok", b'0', b"yes", None)]);
            unpack(&up, &dest, None).unwrap();
            assert!(!root.join("escaped").exists());
            assert_eq!(fs::read_to_string(dest.join("abs/ok")).unwrap(), "yes");
            let via = root.join("via.zst");
            archive_of(&via, &[entry(b"out", b'2', b"", Some(root.to_str().unwrap().as_bytes())), entry(b"out/escaped", b'0', b"no", None)]);
            assert!(unpack(&via, &dest, None).unwrap_err().starts_with("trying to unpack outside of destination path"));
            assert!(!root.join("escaped").exists());
            let hard = root.join("hard.zst");
            archive_of(&hard, &[entry(b"h", b'1', b"", Some(b"../x"))]);
            assert!(unpack(&hard, &dest, None).unwrap_err().starts_with("hard link outside of destination path"));
            let device = root.join("device.zst");
            archive_of(&device, &[entry(b"tty", b'3', b"", None)]);
            assert_eq!(unpack(&device, &dest, None).unwrap_err(), "cannot unpack a device file: tty");
            let clash = root.join("clash.zst");
            archive_of(&clash, &[entry(b"d", b'0', b"file", None), entry(b"d", b'5', b"", None)]);
            assert_eq!(unpack(&clash, &dest, None).unwrap_err(), "d is not a directory in the archive's tree");
            fs::remove_dir_all(&root).unwrap();
        }

        /// A link to a directory written before it (the walk's reverse order) or to an empty one is a directory's link on
        /// Windows, where the machine makes links at all.
        #[cfg(windows)]
        #[test]
        fn a_link_to_a_directory_after_it_is_a_directorys() {
            let root = temp("winlinks");
            let path = root.join("a.zst");
            archive_of(&path, &[
                entry(b"z_link", b'2', b"", Some(b"a_dir")),
                entry(b"to_empty", b'2', b"", Some(b"empty")),
                entry(b"a_dir/f.txt", b'0', b"in a", None),
                entry(b"a_dir", b'5', b"", None),
                entry(b"empty", b'5', b"", None),
            ]);
            let dest = root.join("dest");
            fs::create_dir(&dest).unwrap();
            let made = unpack(&path, &dest, None).unwrap();
            if made["refused"].as_array().unwrap().is_empty() {
                assert_eq!(fs::read_to_string(dest.join("z_link").join("f.txt")).unwrap(), "in a");
                assert!(fs::metadata(dest.join("to_empty")).unwrap().is_dir());
            } else {
                assert_eq!(made["refused"].as_array().unwrap().len(), 2);
            }
            fs::remove_dir_all(&root).unwrap();
        }

        #[cfg(unix)]
        #[test]
        fn a_socket_or_a_change_while_packing_keeps_the_originals() {
            let root = temp("sock");
            let ws = root.join("ws");
            fs::create_dir(&ws).unwrap();
            let _listener = std::os::unix::net::UnixListener::bind(ws.join("s")).unwrap();
            let err = pack(&ws, &root.join("o.zst")).unwrap_err();
            assert!(err.ends_with("socket can not be archived"), "{err}");
            fs::remove_dir_all(&root).unwrap();
        }
    }
}

fn str_of<'a>(v: &'a Value, k: &str) -> Result<&'a str, String> {
    v.get(k).and_then(Value::as_str).ok_or_else(|| format!("missing {k}"))
}

fn id_of(v: &Value) -> Result<u64, String> {
    v.get("id").and_then(Value::as_u64).ok_or_else(|| "missing id".to_string())
}

/// The connections' transport (the station's addon's `transport`): the congestion controller named, Cubic or BBR (opt
/// in), each with a 256 KiB initial window; each path kept alive each second and given up after 3 s of silence, so one
/// connection goes on through another relay as one goes; a link kept 10 minutes in silence (an app frozen in the
/// background past iroh's 30 s came back to every link timed out).
fn transport(congestion: &str) -> Result<QuicTransportConfig, String> {
    let controller: Arc<dyn noq_proto::congestion::ControllerFactory + Send + Sync> = match congestion {
        "cubic" => {
            let mut config = noq_proto::congestion::CubicConfig::default();
            config.initial_window(256 * 1024);
            Arc::new(config)
        }
        "bbr" => {
            let mut config = noq_proto::congestion::Bbr3Config::default();
            config.initial_window(256 * 1024);
            Arc::new(config)
        }
        _ => return Err("congestion: expected cubic or bbr".into()),
    };
    Ok(QuicTransportConfig::builder()
        .congestion_controller_factory(controller)
        .default_path_keep_alive_interval(std::time::Duration::from_secs(1))
        .default_path_max_idle_timeout(std::time::Duration::from_secs(3))
        .max_idle_timeout(Some(iroh::endpoint::VarInt::from_u32(10 * 60_000).into()))
        .build())
}

/// A way of finding stations (mDNS, the DHT) that could not be made leaves a station's endpoint without it, said, as
/// the station's addon has it: mDNS binds UDP 5353, which fails with no network up yet or the port held by another
/// program, and the endpoint failing left the station off the mesh until it was restarted.
#[derive(Debug)]
struct Optional<B>(&'static str, B);

#[derive(Debug)]
struct Unmade<L>(Option<L>);

impl<B: iroh::address_lookup::AddressLookupBuilder> iroh::address_lookup::AddressLookupBuilder for Optional<B> {
    fn into_address_lookup(self, endpoint: &Endpoint) -> Result<impl iroh::address_lookup::AddressLookup, iroh::address_lookup::AddressLookupBuilderError> {
        Ok(Unmade(match self.1.into_address_lookup(endpoint) {
            Ok(lookup) => Some(lookup),
            Err(error) => {
                crate::log::info(&format!("mesh: stations not found through {}: {error:#}", self.0));
                None
            }
        }))
    }
}

impl<L: iroh::address_lookup::AddressLookup> iroh::address_lookup::AddressLookup for Unmade<L> {
    fn publish(&self, data: &iroh::address_lookup::EndpointData) {
        if let Some(lookup) = &self.0 {
            lookup.publish(data);
        }
    }

    fn resolve(&self, endpoint_id: EndpointId) -> Option<n0_future::boxed::BoxStream<Result<iroh::address_lookup::Item, iroh::address_lookup::Error>>> {
        self.0.as_ref().and_then(|lookup| lookup.resolve(endpoint_id))
    }
}

fn bytes_of(b: &'static [u8]) -> bytes::Bytes {
    bytes::Bytes::from_static(b)
}

/// The DSCP (1 to 63) every iroh packet of this process is marked with from a bind on: a station's front's
/// (`STILLFAIL_MESH_DSCP`; station/native/mesh/src/dscp.rs says why), never an app's, whose packets stay as they were.
/// One out of range, or on a system where packets cannot be marked, fails the bind: never silently unmarked.
fn mark_with_dscp(dscp: Option<&Value>) -> Result<(), String> {
    let Some(dscp) = dscp.filter(|v| !v.is_null()) else { return Ok(()) };
    let dscp = dscp.as_u64().and_then(|d| u8::try_from(d).ok()).filter(|d| (1..=63).contains(d)).ok_or_else(|| format!("the DSCP to mark the mesh's packets with must be 1 to 63, not {dscp}"))?;
    if !cfg!(any(target_os = "linux", target_os = "android", target_os = "macos")) {
        return Err(format!("the mesh's packets cannot be marked with a DSCP ({dscp}) on this system"));
    }
    noq_udp::set_dscp(dscp);
    iroh::set_relay_dscp(dscp);
    Ok(())
}

fn relay_url(url: &str) -> Result<RelayUrl, String> {
    url.parse().map_err(err)
}

fn endpoint_addr(addr: &Value) -> Result<EndpointAddr, String> {
    let id = str_of(addr, "id")?;
    let bytes: [u8; 32] = hex::decode(id).map_err(err)?.try_into().map_err(|_| "the id is not 32 bytes".to_string())?;
    let mut out = EndpointAddr::new(EndpointId::from_bytes(&bytes).map_err(err)?);
    for url in addr.get("relays").and_then(Value::as_array).into_iter().flatten() {
        out = out.with_relay_url(relay_url(url.as_str().unwrap_or_default())?);
    }
    for ip in addr.get("ips").and_then(Value::as_array).into_iter().flatten() {
        out = out.with_ip_addr(ip.as_str().unwrap_or_default().parse::<std::net::SocketAddr>().map_err(err)?);
    }
    Ok(out)
}

fn close_info(error: &iroh::endpoint::ConnectionError) -> Value {
    use iroh::endpoint::ConnectionError;
    let mut info = match error {
        ConnectionError::ApplicationClosed(close) => json!({ "kind": "application", "reason": String::from_utf8_lossy(&close.reason) }),
        ConnectionError::LocallyClosed => json!({ "kind": "local", "reason": "" }),
        ConnectionError::TimedOut => json!({ "kind": "timeout", "reason": "" }),
        other => json!({ "kind": "other", "reason": other.to_string() }),
    };
    // (and in words, as the station's addon says it: its `closed`)
    info["text"] = json!(error.to_string());
    info
}

impl Handle {
    fn kind(&self) -> &'static str {
        match self {
            Handle::Response(_) => "response",
            Handle::Ws { .. } => "ws",
            Handle::Tcp { .. } => "tcp",
            Handle::Endpoint(..) => "endpoint",
            Handle::Conn(_) => "conn",
            Handle::Gone { .. } => "gone",
            Handle::Unbound { .. } => "unbound",
            Handle::IStream(_) => "stream",
            Handle::Listener(_) => "listener",
            Handle::Unzstd(_) => "unzstd",
            Handle::Zstd(_) => "zstd",
            Handle::Pack(_) => "pack",
        }
    }
}

/// What the shells have been asked, for when the app's memory runs away (the app's MemoryWatch.kt): the calls by
/// operation since the process started and those not answered yet, and the shells' handles by kind. A loop between the
/// core and the shell shows as one operation far ahead of the rest.
#[derive(Default)]
struct Stats {
    calls: HashMap<String, (u64, i64)>,
    shells: Vec<std::sync::Weak<Inner>>,
}

static STATS: std::sync::LazyLock<Mutex<Stats>> = std::sync::LazyLock::new(Mutex::default);

/// One more of `what` (the shell's own doings, beside the operations asked: `tap.video`, a remote screen's frame said to
/// the app), as counted operations are.
fn tally(what: &str) {
    let mut stats = STATS.lock().unwrap();
    // (no name made again for each: a screen's frames are counted a hundred times a second)
    match stats.calls.get_mut(what) {
        Some(c) => c.0 += 1,
        None => {
            stats.calls.insert(what.to_string(), (1, 0));
        }
    }
}

fn counted(op: &str, started: bool) {
    let mut stats = STATS.lock().unwrap();
    let c = stats.calls.entry(op.to_string()).or_default();
    if started {
        c.0 += 1;
        c.1 += 1;
    } else {
        c.1 -= 1;
    }
}

fn stats_json() -> Value {
    let mut stats = STATS.lock().unwrap();
    stats.shells.retain(|w| w.strong_count() > 0);
    let calls: serde_json::Map<String, Value> = stats.calls.iter().map(|(op, (n, open))| (op.clone(), json!([n, open]))).collect();
    let mut handles: HashMap<&'static str, u64> = HashMap::new();
    let mut sqls = 0;
    for inner in stats.shells.iter().filter_map(std::sync::Weak::upgrade) {
        for h in inner.handles.lock().unwrap().values() {
            *handles.entry(h.kind()).or_default() += 1;
        }
        sqls += inner.sqls.lock().unwrap().len();
    }
    json!({ "calls": calls, "handles": handles, "sqls": sqls })
}

impl Tell for Inner {
    fn media(&self, call: u64, kind: u8, key: bool, seq: u64, ts: u64, bytes: &[u8]) -> bool {
        let Some((media, ctx)) = &*self.media.lock().unwrap() else { return false };
        media(ctx.0, call, kind, key as u8, seq, ts, bytes.as_ptr(), bytes.len()) != 0
    }

    /// A message for the app said from here (`say`), as the core says one.
    fn say(&self, text: &[u8], bytes: Option<&[u8]>) {
        let Some((say, ctx)) = &*self.say.lock().unwrap() else { return };
        let (b, blen) = match bytes {
            Some(b) => (if b.is_empty() { [0u8; 1].as_ptr() } else { b.as_ptr() }, b.len()),
            None => (std::ptr::null(), 0),
        };
        say(ctx.0, text.as_ptr(), text.len(), b, blen);
    }
}

impl Inner {
    fn keep(&self, handle: Handle) -> u64 {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.handles.lock().unwrap().insert(id, handle);
        id
    }

    fn handle(&self, id: u64) -> Result<Handle, String> {
        self.handles.lock().unwrap().get(&id).cloned().ok_or_else(|| format!("no handle {id}"))
    }

    fn drop_handle(&self, id: u64) -> Option<Handle> {
        self.handles.lock().unwrap().remove(&id)
    }

    /// A connection kept for the core, and let go once it closes, however it does (closed here, by the other end, timed
    /// out): kept, a closed connection and the streams opened on it stayed in memory, iroh's tasks still going over
    /// them, and a phone whose links were replaced often held hundreds and grew gigabytes a minute (2026-10-19).
    fn keep_conn(self: &Arc<Self>, conn: Connection) -> u64 {
        let id = self.keep(Handle::Conn(conn.clone()));
        let inner = self.clone();
        tokio::spawn(async move {
            let reason = conn.closed().await;
            inner.release_conn(id, &reason);
        });
        id
    }

    /// A closed connection let go: what the core may still ask (`remoteId`, `closeReason`, `stats`) is kept, and its
    /// streams go, a read still waiting on one woken.
    fn release_conn(&self, id: u64, reason: &iroh::endpoint::ConnectionError) {
        let mut handles = self.handles.lock().unwrap();
        let gone = match handles.get(&id) {
            Some(Handle::Conn(conn)) => {
                let s = conn.stats();
                Handle::Gone { remote: hex::encode(conn.remote_id().as_bytes()), reason: close_info(reason), stats: json!({ "rxBytes": s.udp_rx.bytes, "txBytes": s.udp_tx.bytes }) }
            }
            _ => return,
        };
        handles.insert(id, gone);
        Self::release_streams(&mut handles, id);
    }

    /// Lets go of the streams of connection `id`, each reset for whoever still reads or writes it.
    fn release_streams(handles: &mut HashMap<u64, Handle>, id: u64) {
        let streams: Vec<u64> = handles.iter().filter_map(|(k, h)| matches!(h, Handle::IStream(halves) if halves.conn == id).then_some(*k)).collect();
        for k in streams {
            if let Some(Handle::IStream(halves)) = handles.remove(&k) {
                let _ = halves.reset.send(true);
            }
        }
    }

    /// A job for the disk thread, answered when done.
    async fn disk<T: Send + 'static>(&self, job: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
        let (done, answer) = tokio::sync::oneshot::channel();
        self.disk.lock().unwrap().send(Box::new(move || {
            let _ = done.send(job());
        })).map_err(|_| "the disk thread is gone".to_string())?;
        answer.await.map_err(|_| "the disk thread is gone".to_string())?
    }

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

    async fn run(self: &Arc<Self>, op: &str, a: Value, bytes: Option<Vec<u8>>) -> Done {
        match op {
            "fetch" => {
                let response = self.request(&a, bytes)?.send().await.map_err(http_error)?;
                let (status, headers) = (response.status().as_u16(), headers_of(&response));
                let body = response.bytes().await.map_err(http_error)?.to_vec();
                Ok(Answer::bytes(json!({ "status": status, "headers": headers }), body))
            }
            "stream.open" => {
                let response = self.request(&a, bytes)?.send().await.map_err(http_error)?;
                let (status, headers) = (response.status().as_u16(), headers_of(&response));
                let id = self.keep(Handle::Response(Arc::new(tokio::sync::Mutex::new(response))));
                Ok(Answer::json(json!({ "status": status, "headers": headers, "id": id })))
            }
            "stream.read" => {
                let Handle::Response(response) = self.handle(id_of(&a)?)? else { return Err("not a response".into()) };
                let chunk = response.lock().await.chunk().await.map_err(http_error)?;
                Ok(match chunk {
                    Some(c) => Answer::bytes(json!({}), c.to_vec()),
                    None => Answer::json(json!({ "end": true })),
                })
            }
            // `bytes` compressed whole at `level` with a window of 2^`window` (station/mesh/compress.ts's: what a station's
            // program answers a device that asks for zstd), off the caller's thread.
            "zstd.compress" => {
                let level = a.get("level").and_then(Value::as_i64).unwrap_or(3) as i32;
                let window = a.get("window").and_then(Value::as_u64).unwrap_or(20) as u32;
                let input = bytes.unwrap_or_default();
                let out = tokio::task::spawn_blocking(move || -> Result<Vec<u8>, String> {
                    let mut z = zstd::bulk::Compressor::new(level).map_err(err)?;
                    z.set_parameter(zstd::zstd_safe::CParameter::WindowLog(window)).map_err(err)?;
                    z.compress(&input).map_err(err)
                })
                .await
                .map_err(err)??;
                Ok(Answer::bytes(json!({}), out))
            }
            // What the zstd frames in `bytes` (or in the file at `path`) hold, `most` bytes of it at most: more is refused,
            // unpacked no further. A sync's pieces as another station sent them (station/mb src/reader/dirsync.mbt
            // `put_blobs`), off the caller's thread.
            "zstd.unpack" => {
                let most = a.get("most").and_then(Value::as_u64).ok_or("most is required")?;
                let path = a.get("path").and_then(Value::as_str).map(PathBuf::from);
                let input = bytes.unwrap_or_default();
                let out = tokio::task::spawn_blocking(move || -> Result<Vec<u8>, String> {
                    use std::io::Read;
                    let packed = match path {
                        Some(path) => std::fs::read(path).map_err(err)?,
                        None => input,
                    };
                    let mut out = Vec::new();
                    zstd::stream::read::Decoder::new(packed.as_slice()).map_err(err)?.take(most + 1).read_to_end(&mut out).map_err(err)?;
                    if out.len() as u64 > most {
                        return Err(format!("more than {most} bytes unpacked"));
                    }
                    Ok(out)
                })
                .await
                .map_err(err)??;
                Ok(Answer::bytes(json!({}), out))
            }
            // A zstd stream made of what is given it piece by piece (`zstd.push`), each piece flushed: what an event stream
            // a station's program answers goes out as (station/mesh/compress.ts `compressedStream`), `level` and a window of
            // 2^`window` its.
            "zstd.stream" => {
                let level = a.get("level").and_then(Value::as_i64).unwrap_or(3) as i32;
                let window = a.get("window").and_then(Value::as_u64).unwrap_or(20) as u32;
                let mut e = zstd::stream::raw::Encoder::new(level).map_err(err)?;
                e.set_parameter(zstd::zstd_safe::CParameter::WindowLog(window)).map_err(err)?;
                Ok(Answer::json(json!({ "id": self.keep(Handle::Zstd(Arc::new(Mutex::new(e)))) })))
            }
            // `bytes` written into the file at `path` (station/mb src/reader remote.mbt): at `offset` (none: appended),
            // made where it is not (`exclusive`: refused where it is), never through a link (`nofollow`), cut to what
            // ends there with `truncate`, synced to the disk with `sync`; a regular file only. How long it is then.
            "fs.put" => {
                let path = PathBuf::from(str_of(&a, "path")?);
                let input = bytes.unwrap_or_default();
                let offset = a.get("offset").and_then(Value::as_u64);
                let flag = |k: &str| a.get(k).and_then(Value::as_bool).unwrap_or(false);
                let (exclusive, nofollow, truncate, sync) = (flag("exclusive"), flag("nofollow"), flag("truncate"), flag("sync"));
                let mode = a.get("mode").and_then(Value::as_u64).unwrap_or(0o666) as u32;
                let size = tokio::task::spawn_blocking(move || -> Result<u64, String> {
                    use std::io::{Seek, SeekFrom, Write};
                    let mut o = std::fs::OpenOptions::new();
                    o.write(true);
                    if exclusive { o.create_new(true); } else { o.create(true); }
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::OpenOptionsExt;
                        o.mode(mode);
                        if nofollow { o.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK); }
                    }
                    #[cfg(not(unix))]
                    let _ = (mode, nofollow);
                    let mut file = o.open(&path).map_err(err)?;
                    if !file.metadata().map_err(err)?.is_file() {
                        return Err("only regular files can be transferred".into());
                    }
                    let at = match offset { Some(at) => at, None => file.seek(SeekFrom::End(0)).map_err(err)? };
                    file.seek(SeekFrom::Start(at)).map_err(err)?;
                    file.write_all(&input).map_err(err)?;
                    let end = at + input.len() as u64;
                    if truncate { file.set_len(end).map_err(err)?; }
                    if sync { file.sync_all().map_err(err)?; }
                    Ok(file.metadata().map_err(err)?.len())
                })
                .await
                .map_err(err)??;
                Ok(Answer::json(json!({ "size": size })))
            }
            "zstd.open" => Ok(Answer::json(json!({ "id": self.keep(Handle::Unzstd(Arc::new(Mutex::new(Unzstd::new()?)))) }))),
            "zstd.push" => {
                if let Handle::Zstd(z) = self.handle(id_of(&a)?)? {
                    use zstd::stream::raw::{InBuffer, Operation, OutBuffer};
                    let input = bytes.unwrap_or_default();
                    let mut z = z.lock().unwrap();
                    let mut out = Vec::with_capacity(input.len() / 2 + 64);
                    let mut chunk = vec![0u8; 64 * 1024];
                    let mut inb = InBuffer::around(&input);
                    while inb.pos() < input.len() {
                        let mut o = OutBuffer::around(&mut chunk[..]);
                        z.run(&mut inb, &mut o).map_err(err)?;
                        let n = o.pos();
                        out.extend_from_slice(&chunk[..n]);
                    }
                    loop {
                        let mut o = OutBuffer::around(&mut chunk[..]);
                        let left = z.flush(&mut o).map_err(err)?;
                        let n = o.pos();
                        out.extend_from_slice(&chunk[..n]);
                        if left == 0 {
                            break;
                        }
                    }
                    return Ok(Answer::bytes(json!({}), out));
                }
                let Handle::Unzstd(z) = self.handle(id_of(&a)?)? else { return Err("not a zstd stream".into()) };
                let input = bytes.unwrap_or_default();
                let mut z = z.lock().unwrap();
                let out = z.take(&input)?;
                Ok(Answer::bytes(json!({ "whole": z.whole }), out))
            }
            "pack.open" => Ok(Answer::json(json!({ "id": self.keep(Handle::Pack(Arc::new(Mutex::new(HashMap::new())))) }))),
            // Pieces of files packed into one zstd frame written to the file at `out` (its own, made anew), off the caller's
            // thread: what a directory sync sends in one request (station/mb src/reader/dirsync.mbt `send_blobs`), its
            // bytes never through the program. Each piece [path, offset, length, size, id, link]: `length` bytes of the
            // file from `offset` (`link`: the link's target, whole), each file's Git blob id worked out across the calls
            // of one `pack.open` as its pieces come in order and checked at its last. A piece that does not read as it
            // was listed (shorter, its id another, a link not there) stops it: {changed: its index}. Else {raw, packed}:
            // the bytes taken and the frame's.
            "zstd.pack" => {
                let Handle::Pack(ids) = self.handle(id_of(&a)?)? else { return Err("not a pack".into()) };
                let out = PathBuf::from(str_of(&a, "out")?);
                let level = a.get("level").and_then(Value::as_i64).unwrap_or(3) as i32;
                let pieces = a.get("pieces").and_then(Value::as_array).cloned().ok_or("pieces are required")?;
                let value = tokio::task::spawn_blocking(move || pack_pieces(&ids, &out, level, &pieces)).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            // A transcript put away (station/mb src/packed, as station/test/reference/packed.ts reads it): the file at
            // `path` (with `unzstd`, what its zstd frames hold, each whole and checksummed) cut into frames of at most
            // `segment` bytes, each ending at the end of its last line within them (none there: at `segment`), and a frame
            // made only once more than `segment` came, so the last is never empty but where the file is; each compressed
            // at level 3 with its checksum (as the Rust station's archive.rs, Node's ZSTD_c_checksumFlag) and written to
            // `out` (made anew, 0600), off the caller's thread, none of its bytes through the program. {frames: [[packed,
            // size]…]}: the table after them is the program's to write.
            "zstd.segments" => {
                let path = PathBuf::from(str_of(&a, "path")?);
                let out = PathBuf::from(str_of(&a, "out")?);
                let unzstd = a.get("unzstd").and_then(Value::as_bool).unwrap_or(false);
                let segment = a.get("segment").and_then(Value::as_u64).filter(|n| *n > 0).ok_or("segment is required")? as usize;
                let value = tokio::task::spawn_blocking(move || segment_into(&path, unzstd, &out, segment)).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            // The zstd frames of the file at `path` read through, off the caller's thread: each whole (a cut one fails, as
            // the Rust station's decoder's "incomplete frame") and its checksum verified; with `frames` ([[at, packed,
            // size]…], a put-away transcript's table), each on its own, holding `size` bytes. What they hold written to
            // `into` (made anew, 0600, on disk before this answers) where it says, compared byte for byte with the file
            // at `same` where it says ({differs: "shortened" | "changed"} where that file is not it, to its end). {size,
            // sha256} of what they hold.
            "zstd.check" => {
                let path = PathBuf::from(str_of(&a, "path")?);
                let frames = match a.get("frames") {
                    Some(Value::Array(fs)) => Some(
                        fs.iter()
                            .map(|f| match (f[0].as_u64(), f[1].as_u64(), f[2].as_u64()) {
                                (Some(at), Some(packed), Some(size)) => Ok((at, packed, size)),
                                _ => Err("bad frame".to_string()),
                            })
                            .collect::<Result<Vec<_>, _>>()?,
                    ),
                    _ => None,
                };
                let into = a.get("into").and_then(Value::as_str).map(PathBuf::from);
                let same = a.get("same").and_then(Value::as_str).map(PathBuf::from);
                let value = tokio::task::spawn_blocking(move || check_frames(&path, frames.as_deref(), into.as_deref(), same.as_deref())).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            // A workspace put away as a GNU tar in zstd (mod tar; station/mb src/packed for sessions/archive.ts), each off
            // the caller's thread, a block at a time. `tar.pack` {dir, out}: the tree at `dir` (no link followed) into
            // `out` (made anew, 0600, on disk), read back to its zstd checksum, and the tree found unchanged meanwhile.
            "tar.pack" => {
                let dir = PathBuf::from(str_of(&a, "dir")?);
                let out = PathBuf::from(str_of(&a, "out")?);
                let value = tokio::task::spawn_blocking(move || tar::pack(&dir, &out)).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            // `tar.unpack` {path, dest, prefix?}: the archive at `path` made in `dest` (only what is under `prefix`, its
            // files and directories, where given), read to its zstd checksum; {refused: [[path, target]…]}, the links the
            // machine refused (Windows without the privilege).
            "tar.unpack" => {
                let path = PathBuf::from(str_of(&a, "path")?);
                let dest = PathBuf::from(str_of(&a, "dest")?);
                let prefix = a.get("prefix").and_then(Value::as_str).map(str::to_string);
                let value = tokio::task::spawn_blocking(move || tar::unpack(&path, &dest, prefix.as_deref())).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            // `tar.file` {path, wanted, out}: the file named `wanted` (its path's components) in the archive at `path`
            // written to `out` (made anew, 0600) where it is there: {found, size}.
            "tar.file" => {
                let path = PathBuf::from(str_of(&a, "path")?);
                let out = PathBuf::from(str_of(&a, "out")?);
                let wanted = a
                    .get("wanted")
                    .and_then(Value::as_array)
                    .ok_or("wanted is required")?
                    .iter()
                    .map(|p| p.as_str().map(str::to_string).ok_or("wanted is a path's components"))
                    .collect::<Result<Vec<_>, _>>()?;
                let value = tokio::task::spawn_blocking(move || tar::file(&path, &wanted, &out)).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            "stream.close" | "ws.close" | "tcp.close" | "zstd.close" | "listen.close" | "pack.close" => {
                // Dropping the response, the socket's sender (its task ends) or the halves closes it.
                self.drop_handle(id_of(&a)?);
                Ok(Answer::json(json!({})))
            }
            "ws.open" => self.ws_open(&a).await,
            "ws.next" => {
                let Handle::Ws { incoming, .. } = self.handle(id_of(&a)?)? else { return Err("not a socket".into()) };
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
                let Handle::Ws { outgoing, .. } = self.handle(id_of(&a)?)? else { return Err("not a socket".into()) };
                // Bytes given: a binary frame; else `text`.
                let frame = match bytes { Some(b) => WsFrame::Binary(b), None => WsFrame::Text(str_of(&a, "text")?.to_string()) };
                outgoing.send(frame).map_err(|_| "the socket is closed".to_string())?;
                Ok(Answer::json(json!({})))
            }
            "storage.get" => {
                let path = storage_path(&self.dir, str_of(&a, "key")?);
                self.disk(move || match std::fs::read(&path) {
                    Ok(bytes) => Ok(Answer::bytes(json!({}), bytes)),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Answer::json(json!({ "none": true }))),
                    Err(e) => Err(err(e)),
                })
                .await
            }
            "storage.set" => {
                let path = storage_path(&self.dir, str_of(&a, "key")?);
                let value = bytes.unwrap_or_default();
                self.disk(move || {
                    // Written aside and renamed over: a crash leaves the old value or the new one, never half.
                    // Synced through the handle it was written with: Windows syncs only a handle that may write (one
                    // opened again to read, as this did, failed every storage.set there).
                    let partial = path.with_extension("partial");
                    let mut file = create_private(&partial).map_err(err)?;
                    std::io::Write::write_all(&mut file, &value).and_then(|()| file.sync_all()).map_err(err)?;
                    drop(file);
                    std::fs::rename(&partial, &path).map_err(err)?;
                    Ok(Answer::json(json!({})))
                })
                .await
            }
            "storage.delete" => {
                let path = storage_path(&self.dir, str_of(&a, "key")?);
                self.disk(move || match std::fs::remove_file(&path) {
                    Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(err(e)),
                    _ => Ok(Answer::json(json!({}))),
                })
                .await
            }
            "db.read" => {
                let (table, from, to) = (str_of(&a, "table")?.to_string(), str_of(&a, "from")?.to_string(), str_of(&a, "to")?.to_string());
                let db = self.db.clone();
                self.disk(move || {
                    let mut guard = db.lock().map_err(|_| "the database is gone".to_string())?;
                    let conn = open_db(&mut guard)?;
                    let mut query = conn.prepare_cached("SELECT key, value FROM records WHERE tbl = ?1 AND key >= ?2 AND key < ?3 ORDER BY key").map_err(err)?;
                    let rows = query
                        .query_map(rusqlite::params![table, from, to], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)))
                        .map_err(err)?
                        .collect::<Result<Vec<_>, _>>()
                        .map_err(err)?;
                    let keys: Vec<&String> = rows.iter().map(|(k, _)| k).collect();
                    let sizes: Vec<usize> = rows.iter().map(|(_, v)| v.len()).collect();
                    let json = json!({ "keys": keys, "sizes": sizes });
                    Ok(Answer::bytes(json, rows.iter().flat_map(|(_, v)| v.iter().copied()).collect()))
                })
                .await
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
                self.adb.pair(port, str_of(&a, "code")?).await?;
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
                    let path = str_of(&a, "path")?;
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
                async fn carry(from: Arc<tokio::sync::Mutex<Box<dyn tokio::io::AsyncRead + Send + Unpin>>>, to: Arc<tokio::sync::Mutex<Box<dyn tokio::io::AsyncWrite + Send + Unpin>>>) -> u64 {
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
                let Handle::Listener(listener) = self.handle(id_of(&a)?)? else { return Err("not a listening socket".into()) };
                let (conn, peer) = listener.accept().await?;
                Ok(Answer::json(json!({ "id": self.keep(conn), "peer": peer })))
            }
            "tcp.read" => {
                let Handle::Tcp { read, .. } = self.handle(id_of(&a)?)? else { return Err("not a tcp connection".into()) };
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
                let Handle::Tcp { write, .. } = self.handle(id_of(&a)?)? else { return Err("not a tcp connection".into()) };
                write.lock().await.write_all(&bytes.unwrap_or_default()).await.map_err(err)?;
                Ok(Answer::json(json!({})))
            }
            "tcp.end" => {
                let Handle::Tcp { write, .. } = self.handle(id_of(&a)?)? else { return Err("not a tcp connection".into()) };
                let _ = write.lock().await.shutdown().await;
                Ok(Answer::json(json!({})))
            }
            "reset" => {
                // Requests already on the old pool keep it until they end.
                *self.http.lock().unwrap() = http_client(&self.tls);
                self.entries.lock().unwrap().clear();
                Ok(Answer::json(json!({})))
            }
            "iroh.bind" => self.bind(&a, bytes.unwrap_or_default()).await,
            "iroh.meshSubscribe" | "iroh.meshUnsubscribe" => {
                let Handle::Endpoint(_, kept) = self.handle(id_of(&a)?)? else { return Err("not an endpoint".into()) };
                let socket = a.get("socket").and_then(Value::as_u64).ok_or("missing subscription socket")?;
                if op == "iroh.meshUnsubscribe" { kept.mesh.unsubscribe(socket); }
                else {
                    let Handle::Tcp { write, .. } = self.handle(socket)? else { return Err("not a control socket".into()) };
                    kept.mesh.subscribe(socket, write)?;
                }
                Ok(Answer::json(json!({})))
            }
            "iroh.meshAttachLeaf" | "iroh.meshUseLeaf" | "iroh.meshDetachLeaf" => {
                let Handle::Endpoint(endpoint,kept)=self.handle(id_of(&a)?)? else {return Err("not an endpoint".into())};
                if op=="iroh.meshAttachLeaf" {
                    let connection=a.get("connection").and_then(Value::as_u64).ok_or("missing leaf connection")?;
                    let Handle::Conn(connection)=self.handle(connection)? else {return Err("not a connection".into())};
                    Ok(Answer::json(kept.mesh.attach_leaf(&endpoint,connection,&a).await?))
                } else {
                    if op=="iroh.meshUseLeaf" {kept.mesh.use_leaf(&endpoint,&a).await?;} else {kept.mesh.detach_leaf(&a).await?;}
                    Ok(Answer::json(json!({})))
                }
            }
            "iroh.meshConfigure" | "iroh.meshRemove" => {
                let (endpoint,kept)=match self.handle(id_of(&a)?)? {
                    Handle::Endpoint(endpoint,kept)=>(endpoint,kept),
                    _=>return Err("not an endpoint".into()),
                };
                if op=="iroh.meshRemove" {
                    kept.mesh.remove(&a).await?;
                    Ok(Answer::json(json!({})))
                } else {
                    Ok(Answer::json(kept.mesh.configure_root(&endpoint,&a).await?))
                }
            }
            "iroh.connect" => {
                let (endpoint, kept) = match self.handle(id_of(&a)?)? {
                    Handle::Endpoint(endpoint, kept) => (endpoint, kept),
                    Handle::Unbound { .. } => return Err("the endpoint is closed".into()),
                    _ => return Err("not an endpoint".into()),
                };
                let additional: Vec<Vec<u8>> = a.get("additional").and_then(Value::as_array).into_iter().flatten().filter_map(|x| hex::decode(x.as_str()?).ok()).collect();
                let mut options = iroh::endpoint::ConnectOptions::new().with_additional_alpns(additional);
                let said = a.get("addr").ok_or("missing addr")?;
                // Relays it is not to be reached through, though Address Lookup names them (a station's workspaces
                // turned them off: station/src/mesh/relays.ts `stationAddr`).
                if let Some(disabled) = said.get("disabledRelays").and_then(Value::as_array) {
                    let disabled: Vec<RelayUrl> = disabled.iter().map(|u| relay_url(u.as_str().unwrap_or_default())).collect::<Result<_, _>>()?;
                    options = options.with_disabled_relays(disabled);
                }
                let mut addr = endpoint_addr(said)?;
                if let Some(scope) = said.get("meshScope").and_then(Value::as_str) {
                    addr.addrs.insert(kept.mesh.address(scope, addr.id).await?);
                }
                let connecting = endpoint.connect_with_opts(addr, &bytes.unwrap_or_default(), options).await.map_err(err)?;
                let conn = connecting.await.map_err(err)?;
                Ok(Answer::json(json!({ "id": self.keep_conn(conn) })))
            }
            // As the station's addon takes them: handshakes side by side, each on its own, so one never finished (a
            // device gone half way) holds up no other; one that fails is skipped.
            "iroh.accept" => {
                let (endpoint, kept) = match self.handle(id_of(&a)?)? {
                    Handle::Endpoint(endpoint, kept) => (endpoint, kept),
                    Handle::Unbound { .. } => return Ok(Answer::json(json!({ "end": true }))),
                    _ => return Err("not an endpoint".into()),
                };
                let mut accepted = kept.accepted.lock().await;
                let done = accepted.get_or_insert_with(|| {
                    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
                    let kept = kept.clone();
                    tokio::spawn(async move {
                        while let Some(incoming) = endpoint.accept().await {
                            {
                                let mut held = kept.held.lock().unwrap();
                                if held.0 > 0 {
                                    held.0 -= 1;
                                    held.1.push(incoming);
                                    continue;
                                }
                            }
                            let tx = tx.clone();
                            tokio::spawn(async move {
                                // One whose handshake fails is said, where it came from and how long it took (the
                                // station's addon's, which says why).
                                let from = incoming.remote_addr();
                                let started = std::time::Instant::now();
                                match incoming.await {
                                    Ok(conn) => {
                                        let _ = tx.send(conn);
                                    }
                                    Err(error) => crate::log::info(&format!("mesh: a connection's handshake failed from {from:?} after {} ms: {error:#}", started.elapsed().as_millis())),
                                }
                            });
                        }
                    });
                    rx
                });
                match done.recv().await {
                    Some(conn) => {
                        let alpn = hex::encode(conn.alpn());
                        Ok(Answer::json(json!({ "id": self.keep_conn(conn), "alpn": alpn })))
                    }
                    None => Ok(Answer::json(json!({ "end": true }))),
                }
            }
            "iroh.setRelayEntries" => {
                let endpoint = match self.handle(id_of(&a)?)? {
                    Handle::Endpoint(endpoint, _) => endpoint,
                    Handle::Unbound { .. } => return Ok(Answer::json(json!({}))),
                    _ => return Err("not an endpoint".into()),
                };
                let mut entries = BTreeMap::<RelayUrl, Vec<RelayUrl>>::new();
                for entry in a.get("entries").and_then(Value::as_array).into_iter().flatten() {
                    entries.entry(relay_url(str_of(entry, "relay")?)?).or_default().push(relay_url(str_of(entry, "entry")?)?);
                }
                endpoint.set_relay_entries(entries.into_iter().collect()).await;
                Ok(Answer::json(json!({})))
            }
            "iroh.networkChange" => {
                let endpoint = match self.handle(id_of(&a)?)? {
                    Handle::Endpoint(endpoint, _) => endpoint,
                    Handle::Unbound { .. } => return Ok(Answer::json(json!({}))),
                    _ => return Err("not an endpoint".into()),
                };
                endpoint.network_change().await;
                Ok(Answer::json(json!({})))
            }
            "iroh.close" => {
                let id = id_of(&a)?;
                if let Ok(Handle::Endpoint(_,kept))=self.handle(id) { kept.mesh.clear().await; }
                let forget = a.get("forget").and_then(Value::as_bool).unwrap_or(false);
                let endpoint = {
                    let mut handles = self.handles.lock().unwrap();
                    match handles.get(&id) {
                        // Let go entirely: nothing of it is asked after (the core's own endpoints, not a dial's).
                        Some(Handle::Endpoint(..)) if forget => {
                            let Some(Handle::Endpoint(endpoint, kept)) = handles.remove(&id) else { unreachable!() };
                            for (_, task) in kept.keepers.lock().unwrap().drain() {
                                task.abort();
                            }
                            Some(endpoint)
                        }
                        Some(Handle::Unbound { .. }) if forget => {
                            handles.remove(&id);
                            None
                        }
                        Some(Handle::Endpoint(endpoint, kept)) => {
                            for (_, task) in kept.keepers.lock().unwrap().drain() {
                                task.abort();
                            }
                            let endpoint = endpoint.clone();
                            handles.insert(id, Handle::Unbound { id: hex::encode(endpoint.id().as_bytes()) });
                            Some(endpoint)
                        }
                        _ => None,
                    }
                };
                if let Some(endpoint) = endpoint {
                    endpoint.close().await;
                }
                Ok(Answer::json(json!({})))
            }
            "conn.openBi" | "conn.openUni" | "conn.acceptBi" => {
                let on = id_of(&a)?;
                let conn = match self.handle(on)? {
                    Handle::Conn(conn) => conn,
                    Handle::Gone { .. } if op == "conn.acceptBi" => return Ok(Answer::json(json!({ "end": true }))),
                    Handle::Gone { reason, .. } => return Err(format!("connection closed: {}", reason["reason"].as_str().unwrap_or(""))),
                    _ => return Err("not a connection".into()),
                };
                let (send, recv) = match op {
                    "conn.openBi" => {
                        let (s, r) = conn.open_bi().await.map_err(err)?;
                        (Some(s), Some(r))
                    }
                    "conn.openUni" => (Some(conn.open_uni().await.map_err(err)?), None),
                    _ => match conn.accept_bi().await {
                        Ok((s, r)) => (Some(s), Some(r)),
                        Err(_) => return Ok(Answer::json(json!({ "end": true }))),
                    },
                };
                let halves = Halves {
                    conn: on,
                    ended: (recv.is_none()).into(),
                    finished: false.into(),
                    send: tokio::sync::Mutex::new(send),
                    recv: tokio::sync::Mutex::new(recv),
                    reset: tokio::sync::watch::channel(false).0,
                    tap: Mutex::default(),
                };
                Ok(Answer::json(json!({ "id": self.keep(Handle::IStream(Arc::new(halves))) })))
            }
            "conn.closed" => match self.handle(id_of(&a)?)? {
                Handle::Conn(conn) => Ok(Answer::json(close_info(&conn.closed().await))),
                Handle::Gone { reason, .. } => Ok(Answer::json(reason)),
                _ => Err("not a connection".into()),
            },
            "conn.close" => {
                let id = id_of(&a)?;
                let forget = a.get("forget").and_then(Value::as_bool).unwrap_or(false);
                let conn = if forget {
                    // Let go entirely, its streams with it: `keep_conn`'s wait on its close then finds nothing to keep.
                    let mut handles = self.handles.lock().unwrap();
                    match handles.get(&id) {
                        None => return Err(format!("no handle {id}")),
                        Some(Handle::Conn(_)) => {
                            let Some(Handle::Conn(conn)) = handles.remove(&id) else { unreachable!() };
                            Self::release_streams(&mut handles, id);
                            conn
                        }
                        Some(Handle::Gone { .. }) => {
                            handles.remove(&id);
                            Self::release_streams(&mut handles, id);
                            return Ok(Answer::json(json!({})));
                        }
                        Some(_) => return Err("not a connection".into()),
                    }
                } else {
                    match self.handle(id)? {
                        Handle::Conn(conn) => conn,
                        Handle::Gone { .. } => return Ok(Answer::json(json!({}))),
                        _ => return Err("not a connection".into()),
                    }
                };
                let code = a.get("code").and_then(Value::as_u64).unwrap_or(0) as u32;
                conn.close(code.into(), a.get("reason").and_then(Value::as_str).unwrap_or("").as_bytes());
                Ok(Answer::json(json!({})))
            }
            "istream.tap" => {
                // A remote screen's view (`call` the app's): its frames read here from now on, beginning with `bytes`
                // (what the core read past the stream's reply); false where nothing says to the app from here.
                let Handle::IStream(halves) = self.handle(id_of(&a)?)? else { return Err("not a stream".into()) };
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
                let id = id_of(&a)?;
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
                let Handle::IStream(halves) = self.handle(id_of(&a)?)? else { return Err("not a stream".into()) };
                let mut send = halves.send.lock().await;
                send.as_mut().ok_or("no sending half")?.write_all(&bytes.unwrap_or_default()).await.map_err(err)?;
                Ok(Answer::json(json!({})))
            }
            "istream.finish" => {
                let id = id_of(&a)?;
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
                let id = id_of(&a)?;
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
                let id = id_of(&a)?;
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
            // A station's endpoint (station/mb's front, which keeps it for the station's Node: the addon's `Endpoint`).
            // A station's peer's relays it is not to be reached through (`peer`, hex; `relays`; `public`: iroh's own
            // public relays too), in force once answered (iroh's `set_disabled_relays`): the addon's `disabled_relays`.
            "iroh.disabledRelays" => {
                let endpoint = match self.handle(id_of(&a)?)? {
                    Handle::Endpoint(endpoint, _) => endpoint,
                    Handle::Unbound { .. } => return Err("the endpoint is closed".into()),
                    _ => return Err("not an endpoint".into()),
                };
                let bytes: [u8; 32] = hex::decode(str_of(&a, "peer")?).map_err(err)?.try_into().map_err(|_| "the id is not 32 bytes".to_string())?;
                let peer = EndpointId::from_bytes(&bytes).map_err(err)?;
                let mut disabled: std::collections::BTreeSet<RelayUrl> = a.get("relays").and_then(Value::as_array).into_iter().flatten().map(|u| relay_url(u.as_str().unwrap_or_default())).collect::<Result<_, _>>()?;
                if a.get("public").and_then(Value::as_bool).unwrap_or(false) {
                    disabled.extend(iroh::defaults::prod::default_relay_map().relays::<Vec<_>>().iter().map(|c| c.url.clone()));
                }
                endpoint.set_disabled_relays(peer, disabled).await;
                Ok(Answer::json(json!({})))
            }
            "iroh.online" | "iroh.insertRelay" | "iroh.removeRelay" | "iroh.publicRelays" | "iroh.keep" | "iroh.setCongestion" | "iroh.setAlpns" | "iroh.holdIncoming" => {
                let (endpoint, kept) = match self.handle(id_of(&a)?)? {
                    Handle::Endpoint(endpoint, kept) => (endpoint, kept),
                    Handle::Unbound { .. } => return Err("the endpoint is closed".into()),
                    _ => return Err("not an endpoint".into()),
                };
                match op {
                    // Once it is on its home relay (at once with relays off).
                    "iroh.online" => endpoint.online().await,
                    "iroh.insertRelay" => {
                        let url = relay_url(str_of(&a, "url")?)?;
                        endpoint.insert_relay(url.clone(), Arc::new(iroh::RelayConfig::from(url.clone()))).await;
                        let mut homes = kept.homes.lock().unwrap();
                        if kept.bound.contains(&url) && !homes.contains(&url) {
                            homes.push(url);
                        }
                    }
                    // The protocols it takes from now on (`alpns`, hex), the connections it has kept: a binding that
                    // changes only these needs no endpoint of its own beside it (two of one key on the relays at once,
                    // the one closing refusing what comes to it).
                    "iroh.setAlpns" => {
                        let alpns: Vec<Vec<u8>> = a.get("alpns").and_then(Value::as_array).into_iter().flatten().map(|x| hex::decode(x.as_str().unwrap_or_default()).map_err(err)).collect::<Result<_, _>>()?;
                        endpoint.set_alpns(alpns);
                    }
                    // Off every relay transport: its connection there ended, no longer home there nor in its address.
                    "iroh.removeRelay" => {
                        let url = relay_url(str_of(&a, "url")?)?;
                        endpoint.remove_relay(&url).await;
                        kept.homes.lock().unwrap().retain(|r| r != &url);
                    }
                    // iroh's own public relays: added while none of still.fail's answers, removed once one does.
                    "iroh.publicRelays" => {
                        let on = a.get("on").and_then(Value::as_bool).unwrap_or(false);
                        for config in iroh::defaults::prod::default_relay_map().relays::<Vec<_>>() {
                            if on {
                                endpoint.insert_relay(config.url.clone(), config.clone()).await;
                            } else {
                                endpoint.remove_relay(&config.url).await;
                            }
                        }
                    }
                    // On exactly these relays besides those it is home on: a keeper for each new one, those of relays no
                    // longer named stopped.
                    "iroh.keep" => {
                        let mut relays: Vec<RelayUrl> = a.get("urls").and_then(Value::as_array).into_iter().flatten().map(|u| relay_url(u.as_str().unwrap_or_default())).collect::<Result<_, _>>()?;
                        let homes = kept.homes.lock().unwrap().clone();
                        relays.retain(|r| !homes.contains(r));
                        let urls: Vec<String> = relays.iter().map(ToString::to_string).collect();
                        let mut keepers = kept.keepers.lock().unwrap();
                        keepers.retain(|url, task| {
                            let named = urls.contains(url);
                            if !named {
                                task.abort();
                            }
                            named
                        });
                        for relay in relays {
                            let endpoint = endpoint.clone();
                            keepers.entry(relay.to_string()).or_insert_with(|| tokio::spawn(keep::keep(endpoint, relay)));
                        }
                    }
                    // The controller of the connections made from now on.
                    "iroh.setCongestion" => endpoint.set_transport_config(transport(str_of(&a, "congestion")?)?),
                    // The next `n` connections coming never answered, not even their handshake (tests: a device whose way
                    // here is gone).
                    _ => kept.held.lock().unwrap().0 = a.get("n").and_then(Value::as_u64).unwrap_or(0) as u32,
                }
                Ok(Answer::json(json!({})))
            }
            // Whether the other end is still there: asked with a datagram (which a live end acknowledges at once) a few
            // times within `within` ms, true as soon as anything is heard from it (the addon's `answers`, which says why).
            "conn.answers" => {
                let conn = match self.handle(id_of(&a)?)? {
                    Handle::Conn(conn) => conn,
                    Handle::Gone { .. } => return Ok(Answer::json(json!(false))),
                    _ => return Err("not a connection".into()),
                };
                let within = std::time::Duration::from_millis(a.get("within").and_then(Value::as_u64).unwrap_or(0));
                let heard = conn.stats().udp_rx.datagrams;
                let deadline = std::time::Instant::now() + within;
                let mut ask = std::time::Instant::now();
                let answers = loop {
                    if conn.close_reason().is_some() {
                        break false;
                    }
                    if conn.stats().udp_rx.datagrams > heard {
                        break true;
                    }
                    let now = std::time::Instant::now();
                    if now >= deadline {
                        break false;
                    }
                    if now >= ask {
                        match conn.send_datagram(bytes_of(&[0])) {
                            Ok(()) => {}
                            Err(iroh::endpoint::SendDatagramError::ConnectionLost(_)) => break false,
                            Err(_) => break true,
                        }
                        ask = now + within / 3;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                };
                Ok(Answer::json(json!(answers)))
            }
            // A Unix socket on this machine, read and written as `tcp.open`'s is.
            "unix.open" => {
                #[cfg(unix)]
                {
                    let (read, write) = tokio::net::UnixStream::connect(str_of(&a, "path")?).await.map_err(err)?.into_split();
                    let id = self.keep(Handle::Tcp { read: Arc::new(tokio::sync::Mutex::new(Box::new(read))), write: Arc::new(tokio::sync::Mutex::new(Box::new(write))) });
                    Ok(Answer::json(json!({ "id": id })))
                }
                // Windows: a named pipe (`\\.\pipe\…`, a runner's: station/native/runner), its instances one connection
                // each. All taken a moment (the runner makes its next as it takes one): waited for, up to a bound.
                #[cfg(windows)]
                {
                    use tokio::net::windows::named_pipe::ClientOptions;
                    const ERROR_PIPE_BUSY: i32 = 231;
                    let path = str_of(&a, "path")?;
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
            // A stream carried whole into a socket (`to`, taken), both ways, here: what comes on it written to the socket
            // in frames (PIPE_END its end, PIPE_FAILED what failed it), and the frames the socket sends written on it, its
            // PIPE_END finishing it; the socket ending without one resets it. What the station's Node reads and writes of
            // a stream the front keeps for it (station/mb's front), none of it through the front's program. Answered once
            // both ways are done; `istream.stopped` and `istream.reset` are asked of the stream meanwhile as before.
            "istream.pipe" => {
                let id = id_of(&a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                let to = a.get("to").and_then(Value::as_u64).ok_or("missing to")?;
                let Some(Handle::Tcp { read, write }) = self.drop_handle(to) else { return Err("not a socket".into()) };
                self.pipe(id, halves, read, write).await;
                Ok(Answer::json(json!({})))
            }
            // A stream given to the Unix socket at `path`: a connection to it, `bytes` written first (what tells the
            // other side which stream it is), then the stream carried into it as `istream.pipe` carries it.
            "istream.hand" => {
                let id = id_of(&a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                self.hand(id, halves, str_of(&a, "path")?, &bytes.unwrap_or_default()).await?;
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
                let on = id_of(&a)?;
                let path = str_of(&a, "path")?.to_string();
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
            // The filesystem's and a program's run, asked without waiting (`shell`, not `shell_sync`): done off the caller's
            // thread, so a program that serves many (station/mb's sessions) is not held by a big file or a slow `git`.
            op if op.starts_with("fs.") || op == "proc.run" => {
                let (inner, op, a) = (self.clone(), op.to_string(), a);
                let value = tokio::task::spawn_blocking(move || inner.run_sync(&op, &a)).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            other => Err(format!("no operation {other}")),
        }
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

    async fn bind(self: &Arc<Self>, a: &Value, key: Vec<u8>) -> Done {
        let bytes: [u8; 32] = key.as_slice().try_into().map_err(|_| "the key is not 32 bytes".to_string())?;
        let key = SecretKey::from_bytes(&bytes);
        let key_again = key.clone();
        let relays: Vec<RelayUrl> = a.get("relayUrls").and_then(Value::as_array).into_iter().flatten().map(|u| relay_url(u.as_str().unwrap_or_default())).collect::<Result<_, _>>()?;
        let entries: Vec<(RelayUrl, RelayUrl)> = a.get("relayEntries").and_then(Value::as_array).into_iter().flatten().map(|e| Ok((relay_url(str_of(e, "entry")?)?, relay_url(str_of(e, "relay")?)?))).collect::<Result<_, String>>()?;
        let relay_map = iroh::RelayMap::from_iter(relays.iter().map(|relay| {
            iroh::RelayConfig::from(relay.clone()).with_entries(entries.iter().filter(|(_, target)| target == relay).map(|(entry, _)| entry.clone()))
        }));
        let alpns: Vec<Vec<u8>> = a.get("alpns").and_then(Value::as_array).into_iter().flatten().map(|x| hex::decode(x.as_str().unwrap_or_default()).map_err(err)).collect::<Result<_, _>>()?;
        mark_with_dscp(a.get("dscp"))?;
        let kept = Arc::new(Kept { homes: Mutex::new(relays.clone()), bound: relays.clone(), ..Kept::default() });
        let mut builder = Endpoint::builder(Minimal)
            .add_custom_transport(kept.mesh.hub.clone())
            .path_selector(Arc::new(mesh_transport::selection::Selector::new(kept.mesh.hub.clone())))
            .secret_key(key)
            .alpns(alpns)
            .relay_mode(if relays.is_empty() { RelayMode::Disabled } else { RelayMode::Custom(relay_map) })
            // Home on every relay at once, each path kept alive each second and given up after 3 s of silence: one
            // connection to a station goes through every relay it is on, and on through another as one goes (the
            // station's mesh addon: PATH_KEEP_ALIVE, PATH_IDLE).
            .home_on_every_relay()
            .transport_config(transport(a.get("congestion").and_then(Value::as_str).unwrap_or("cubic"))?);
        // Where a station listens (its config's fixed port); any free port when not said.
        if let Some(addr) = a.get("bindAddr").and_then(Value::as_str) {
            builder = builder.bind_addr(addr.parse::<std::net::SocketAddr>().map_err(err)?).map_err(err)?;
        }
        if a.get("relayOnly").and_then(Value::as_bool).unwrap_or(false) {
            builder = builder.clear_ip_transports();
        }
        // Stations on the LAN (mDNS, never announced itself) and which relay they are on (the DHT), as client/core-ts's.
        if a.get("lookup").and_then(Value::as_bool).unwrap_or(false) && !relays.is_empty() {
            builder = builder
                .address_lookup(iroh_mdns_address_lookup::MdnsAddressLookup::builder().service_name(MDNS_SERVICE).advertise(false))
                .address_lookup(iroh_mainline_address_lookup::DhtAddressLookup::builder().dht_builder(dht()).no_publish());
        } else if a.get("discovery").and_then(Value::as_bool).unwrap_or(false) {
            // A station's: found on the LAN by mDNS and by its relay through the DHT, both announced (the station's
            // addon's `bind`), each left out, said, where it cannot be made (mDNS's port held, no network yet).
            builder = builder
                .address_lookup(Optional("mDNS", iroh_mdns_address_lookup::MdnsAddressLookup::builder().service_name(MDNS_SERVICE)))
                .address_lookup(Optional("the DHT", iroh_mainline_address_lookup::DhtAddressLookup::builder().dht_builder(dht()).secret_key(key_again)));
        }
        let endpoint = builder.bind().await.map_err(err)?;
        Ok(Answer::json(json!({ "id": self.keep(Handle::Endpoint(endpoint, kept)) })))
    }

    /// An account's database: opened, a statement run, its rows, closed, its file removed.
    fn sql(&self, op: &str, a: &Value) -> Result<Value, String> {
        let mut sqls = self.sqls.lock().map_err(|_| "the databases are gone".to_string())?;
        match op {
            "sql.open" => {
                let name = str_of(a, "name")?;
                let (path, conn) = if name == ":memory:" {
                    (None, rusqlite::Connection::open_in_memory().map_err(err)?)
                } else {
                    if name.contains('/') || name.contains('\\') || name.starts_with('.') {
                        return Err(format!("not a database name: {name}"));
                    }
                    let dir = self.dir.join("databases");
                    std::fs::create_dir_all(&dir).map_err(err)?;
                    let path = dir.join(format!("{name}.db"));
                    (Some(path.clone()), rusqlite::Connection::open(&path).map_err(err)?)
                };
                conn.busy_timeout(self.open_wait).map_err(err)?;
                conn.set_prepared_statement_cache_capacity(256);
                // One process at a time: another one finds it busy.
                conn.execute_batch("PRAGMA locking_mode = EXCLUSIVE; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;").map_err(err)?;
                conn.busy_timeout(DB_WAIT).map_err(err)?;
                let id = self.next.fetch_add(1, Ordering::Relaxed);
                sqls.insert(id, (path, conn));
                Ok(json!({ "id": id }))
            }
            // A database another process keeps (the station's, by its path) and writes as well: never made here (but with
            // `create`), never held for this process alone, waited for `wait` ms when it is busy.
            "sql.attach" => {
                let path = PathBuf::from(str_of(a, "path")?);
                let wait = a.get("wait").and_then(Value::as_u64).unwrap_or(0);
                let mut flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX | rusqlite::OpenFlags::SQLITE_OPEN_URI;
                // `create`: one of the program's own, made where it is not (station/mb src/replica's export.db).
                if a.get("create").and_then(Value::as_bool).unwrap_or(false) {
                    flags |= rusqlite::OpenFlags::SQLITE_OPEN_CREATE;
                }
                let conn = rusqlite::Connection::open_with_flags(&path, flags).map_err(err)?;
                conn.busy_timeout(std::time::Duration::from_millis(wait)).map_err(err)?;
                conn.set_prepared_statement_cache_capacity(256);
                conn.execute_batch("PRAGMA synchronous = NORMAL;").map_err(err)?;
                let id = self.next.fetch_add(1, Ordering::Relaxed);
                sqls.insert(id, (None, conn));
                Ok(json!({ "id": id }))
            }
            "sql.delete" => {
                let name = str_of(a, "name")?;
                let path = self.dir.join("databases").join(format!("{name}.db"));
                sqls.retain(|_, (p, _)| p.as_ref() != Some(&path));
                for end in ["", "-wal", "-shm", "-journal"] {
                    let file = PathBuf::from(format!("{}{end}", path.display()));
                    match std::fs::remove_file(&file) {
                        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(err(e)),
                        _ => {}
                    }
                }
                Ok(Value::Null)
            }
            _ => {
                let id = id_of(a)?;
                if op == "sql.close" {
                    sqls.remove(&id);
                    return Ok(Value::Null);
                }
                let (_, conn) = sqls.get(&id).ok_or_else(|| format!("no database {id}"))?;
                // Whether a transaction is open on it (node:sqlite's `isTransaction`: station/src/vault/schema-install.ts).
                if op == "sql.inTransaction" {
                    return Ok(json!(!conn.is_autocommit()));
                }
                let sql = str_of(a, "sql")?;
                match op {
                    "sql.exec" => {
                        conn.execute_batch(sql).map_err(err)?;
                        Ok(Value::Null)
                    }
                    "sql.run" => {
                        let mut statement = conn.prepare_cached(sql).map_err(err)?;
                        let n = statement.execute(rusqlite::params_from_iter(sql_params(a))).map_err(err)?;
                        Ok(json!(n))
                    }
                    "sql.all" => {
                        let mut statement = conn.prepare_cached(sql).map_err(err)?;
                        let columns = statement.column_count();
                        // `named`: the columns' names beside the rows ({columns, rows}), as the station's reads give them.
                        let names: Option<Vec<String>> = a.get("named").and_then(Value::as_bool).unwrap_or(false)
                            .then(|| statement.column_names().into_iter().map(String::from).collect());
                        let mut rows = statement.query(rusqlite::params_from_iter(sql_params(a))).map_err(err)?;
                        let mut out = Vec::new();
                        while let Some(row) = rows.next().map_err(err)? {
                            let mut values = Vec::with_capacity(columns);
                            for i in 0..columns {
                                values.push(match row.get_ref(i).map_err(err)? {
                                    rusqlite::types::ValueRef::Null => Value::Null,
                                    rusqlite::types::ValueRef::Integer(v) => json!(v),
                                    rusqlite::types::ValueRef::Real(v) => json!(v),
                                    rusqlite::types::ValueRef::Text(v) => Value::String(String::from_utf8_lossy(v).into_owned()),
                                    rusqlite::types::ValueRef::Blob(v) => Value::Array(v.iter().map(|b| json!(b)).collect()),
                                });
                            }
                            out.push(Value::Array(values));
                        }
                        Ok(match names {
                            Some(columns) => json!({ "columns": columns, "rows": out }),
                            None => Value::Array(out),
                        })
                    }
                    _ => Err(format!("no operation {op}")),
                }
            }
        }
    }

    fn run_sync(&self, op: &str, a: &Value) -> Result<Value, String> {
        // Whether a screen view's Opus sound is decoded here (ScreenTap): only where its tap says to the app, so the
        // core asks the station for Opus only then (client/core-ts hosts/bridge.ts `opus`), else PCM.
        if op == "tap.opus" {
            return Ok(json!(self.say.lock().unwrap().is_some()));
        }
        if op == "fetch.cancel" {
            let pending = self.fetches.lock().unwrap().remove(&id_of(a)?);
            return Ok(json!(pending.is_some_and(|cancel| cancel.send(()).is_ok())));
        }
        // The file a key's value is kept in, for what reads it there itself (a face's file: client/core-ts
        // font-files.ts); null while none is kept.
        if op == "storage.path" {
            let path = storage_path(&self.dir, str_of(a, "key")?);
            return Ok(if path.is_file() { json!(path.to_string_lossy()) } else { Value::Null });
        }
        // A path's kind as stat (links followed) says it: "file", "dir" or "other"; null when it cannot be (none there,
        // no right): what the station's programs ask of the filesystem (station/mb src/locate), as Node's statSync does.
        // With `lstat`, the path itself as lstat says it (a link "link", not followed).
        if op == "fs.stat" {
            let path = str_of(a, "path")?;
            let lstat = a.get("lstat").and_then(Value::as_bool).unwrap_or(false);
            return Ok(match if lstat { std::fs::symlink_metadata(path) } else { std::fs::metadata(path) } {
                Ok(m) if m.file_type().is_symlink() => json!("link"),
                Ok(m) if m.is_file() => json!("file"),
                Ok(m) if m.is_dir() => json!("dir"),
                Ok(_) => json!("other"),
                Err(_) => Value::Null,
            });
        }
        // A directory's names, with their kinds as the directory says them (`types`: [name, "file" | "dir" | "link" |
        // "other"], links not followed), in Node's readdirSync's order (libuv sorts them by their bytes, but on Windows);
        // null when it cannot be read.
        // `disk`: in the order the file system gives them (Node's opendirSync, Rust's read_dir), an entry that does not
        // read ending the list rather than failing it (station/src/read/machine.ts `readDir`).
        if op == "fs.readdir" {
            let Ok(entries) = std::fs::read_dir(str_of(a, "path")?) else { return Ok(Value::Null) };
            let disk = a.get("disk").and_then(Value::as_bool).unwrap_or(false);
            let mut out: Vec<(String, &str)> = Vec::new();
            for entry in entries {
                let Ok(entry) = entry else {
                    if disk {
                        break;
                    }
                    return Ok(Value::Null);
                };
                let kind = match entry.file_type() {
                    Ok(t) if t.is_symlink() => "link",
                    Ok(t) if t.is_dir() => "dir",
                    Ok(t) if t.is_file() => "file",
                    _ => "other",
                };
                out.push((entry.file_name().to_string_lossy().into_owned(), kind));
            }
            if !cfg!(windows) && !disk {
                out.sort_by(|x, y| x.0.as_bytes().cmp(y.0.as_bytes()));
            }
            let types = a.get("types").and_then(Value::as_bool).unwrap_or(false);
            return Ok(Value::Array(out.into_iter().map(|(name, kind)| if types { json!([name, kind]) } else { json!(name) }).collect()));
        }
        // A path with its links resolved as Node's realpathSync resolves them (each part looked at, a link's target put in
        // its place; the parts' names as given, not as the disk spells them); null when a part is not there.
        if op == "fs.realpath" {
            return Ok(node_realpath(str_of(a, "path")?).map_or(Value::Null, |p| json!(p)));
        }
        // A file's text: `strict` as a TextDecoder with `fatal` reads it (a leading byte order mark dropped, none when it
        // is not UTF-8), else as Node's readFileSync(path, "utf8") does (what is not UTF-8 replaced); null when it does
        // not read.
        // A transcript read a part at a time (station/src/usage/counter.ts `readFrom`, search/sources.ts `mentions`): the
        // file as long as it was when opened, or its `.zst` (every frame, the seek table passed over) when the file is
        // not there. Each `text.next` is the next part, decoded as Buffer.toString("utf8") does: `lines` whole lines of
        // at most about 8 MB (a last line without its end left out, as readFrom leaves it), else every byte, in pieces
        // cut where a character ends. Null at the end; `text.close` lets it go.
        if op == "text.open" {
            let path = PathBuf::from(str_of(a, "path")?);
            let lines = a.get("lines").and_then(Value::as_bool).unwrap_or(false);
            let packed = PathBuf::from(format!("{}.zst", path.display()));
            let source: Box<dyn std::io::Read + Send> = match std::fs::File::open(&path) {
                Ok(file) => {
                    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
                    Box::new(std::io::Read::take(file, size))
                }
                Err(_) => match std::fs::File::open(&packed) {
                    Ok(file) => match zstd::stream::read::Decoder::new(file) {
                        Ok(d) => Box::new(d),
                        Err(_) => return Ok(Value::Null),
                    },
                    Err(_) => return Ok(Value::Null),
                },
            };
            let id = self.next.fetch_add(1, Ordering::Relaxed);
            self.texts.lock().map_err(|_| "the readers are gone".to_string())?.insert(id, TextReader { source, held: Vec::new(), lines, done: false });
            return Ok(json!({ "id": id }));
        }
        if op == "text.next" {
            let id = id_of(a)?;
            let mut texts = self.texts.lock().map_err(|_| "the readers are gone".to_string())?;
            let reader = texts.get_mut(&id).ok_or_else(|| format!("no reader {id}"))?;
            return Ok(reader.next().map_or(Value::Null, Value::String));
        }
        if op == "text.close" {
            self.texts.lock().map_err(|_| "the readers are gone".to_string())?.remove(&id_of(a)?);
            return Ok(Value::Null);
        }
        // A path's size and when it was last written (ms, none before 1970), links followed, as Node's statSync with
        // `bigint` says them; null when it cannot be.
        if op == "fs.meta" {
            let Ok(meta) = std::fs::metadata(str_of(a, "path")?) else { return Ok(Value::Null) };
            let since = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok());
            let modified = since.map(|d| d.as_millis() as u64);
            // `mtime`: as Node's statSync (no `bigint`) says `mtimeMs`, its fraction of a millisecond kept.
            let mtime = since.map(|d| d.as_secs() as f64 * 1e3 + d.subsec_nanos() as f64 / 1e6);
            return Ok(json!({ "size": meta.len(), "mtimeMs": modified, "mtime": mtime, "dir": meta.is_dir() }));
        }
        // The end of a file, at most `bytes` of it (up to its size when opened), decoded as TextDecoder("utf-8") does
        // (what is not UTF-8 replaced, a leading byte order mark dropped); null when it does not open.
        if op == "fs.tail" {
            use std::io::{Read, Seek, SeekFrom};
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Value::Null) };
            let most = a.get("bytes").and_then(Value::as_u64).unwrap_or(64 * 1024);
            let size = file.metadata().map(|m| m.len()).unwrap_or(most);
            let from = size.saturating_sub(most);
            let mut bytes = Vec::new();
            if file.seek(SeekFrom::Start(from)).is_ok() {
                let _ = file.take(size - from).read_to_end(&mut bytes);
            }
            let body = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
            return Ok(json!(String::from_utf8_lossy(body)));
        }
        // Bytes of a file as hex, from byte `from` (0), `length` of them where it says (to its end where not), or with
        // `zstd` what the zstd frames there hold (station/mb src/history's transcripts read a piece at a time, a put-away
        // one a frame at a time); with `exact`, a file that ends before `length` is a failure. Null when it does not open.
        if op == "fs.bytes" {
            use std::io::{Read, Seek, SeekFrom};
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Value::Null) };
            let from = a.get("from").and_then(Value::as_u64).unwrap_or(0);
            let length = a.get("length").and_then(Value::as_u64);
            let mut bytes = Vec::new();
            file.seek(SeekFrom::Start(from)).map_err(err)?;
            match length {
                Some(n) => file.take(n).read_to_end(&mut bytes),
                None => file.read_to_end(&mut bytes),
            }
            .map_err(err)?;
            if a.get("exact").and_then(Value::as_bool).unwrap_or(false) && length.is_some_and(|n| (bytes.len() as u64) < n) {
                return Err("a put-away transcript ended early".into());
            }
            if a.get("zstd").and_then(Value::as_bool).unwrap_or(false) {
                bytes = zstd::decode_all(bytes.as_slice()).map_err(err)?;
            }
            return Ok(json!(hex::encode(bytes)));
        }
        // A program run to its end, as Node's execFileSync runs one (station/src/read/sessions.ts `inRepositories`: `git
        // ls-files`): `command` with `args`, nothing on its stdin and its stderr let go, its stdout decoded as
        // Buffer.toString("utf8") does; null where it did not end well: not started, ended by a signal or with a code
        // not 0, still running after `timeoutMs` (killed then), or writing more than `maxBytes`.
        if op == "proc.run" {
            use std::io::Read;
            use std::process::{Command, Stdio};
            let args: Vec<String> = a.get("args").and_then(Value::as_array).map(|v| v.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            let timeout = std::time::Duration::from_millis(a.get("timeoutMs").and_then(Value::as_u64).unwrap_or(5000));
            let most = a.get("maxBytes").and_then(Value::as_u64).unwrap_or(1 << 20) as usize;
            // `env`: variables set besides the station's; `hex`: its stdout as hex (bytes, not words: `git cat-file`);
            // `code`: {code, out} for any end it came to (`git check-ignore`'s 1 says something), null still where it did not.
            let mut command = Command::new(str_of(a, "command")?);
            command.args(&args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
            if let Some(env) = a.get("env").and_then(Value::as_object) {
                for (k, v) in env {
                    if let Some(v) = v.as_str() { command.env(k, v); }
                }
            }
            let Ok(mut child) = command.spawn() else {
                return Ok(Value::Null);
            };
            let mut stdout = child.stdout.take().expect("piped");
            let reading = std::thread::spawn(move || {
                let mut out = Vec::new();
                let over = (&mut stdout).take(most as u64 + 1).read_to_end(&mut out).is_err() || out.len() > most;
                (out, over)
            });
            let started = std::time::Instant::now();
            let status = loop {
                match child.try_wait() {
                    Ok(Some(status)) => break Some(status),
                    Ok(None) if started.elapsed() < timeout => std::thread::sleep(std::time::Duration::from_millis(2)),
                    _ => {
                        let _ = child.kill();
                        let _ = child.wait();
                        break None;
                    }
                }
            };
            let (out, over) = reading.join().unwrap_or((Vec::new(), true));
            let said = |out: &[u8]| if a.get("hex").and_then(Value::as_bool).unwrap_or(false) { json!(hex::encode(out)) } else { json!(String::from_utf8_lossy(out)) };
            if a.get("code").and_then(Value::as_bool).unwrap_or(false) {
                return Ok(match status.and_then(|s| s.code()) {
                    Some(code) if !over => json!({ "code": code, "out": said(&out) }),
                    _ => Value::Null,
                });
            }
            return Ok(match status {
                Some(s) if s.success() && !over => said(&out),
                _ => Value::Null,
            });
        }
        // What a link points to, as Node's readlinkSync gives it; null when the path is no link or cannot be read.
        if op == "fs.readlink" {
            return Ok(std::fs::read_link(str_of(a, "path")?).map_or(Value::Null, |p| json!(p.to_string_lossy())));
        }
        // A file from byte `from` to its end, decoded as Buffer.toString("utf8") does (what is not UTF-8 replaced, a byte
        // order mark kept); null when it does not open.
        if op == "fs.from" {
            use std::io::{Read, Seek, SeekFrom};
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Value::Null) };
            let from = a.get("from").and_then(Value::as_u64).unwrap_or(0);
            let mut bytes = Vec::new();
            if file.seek(SeekFrom::Start(from)).is_err() || file.read_to_end(&mut bytes).is_err() {
                return Ok(Value::Null);
            }
            return Ok(json!(String::from_utf8_lossy(&bytes)));
        }
        // A file's lines as Rust's BufRead::lines with map_while(Result::ok) reads them (station/src/read/machine.ts
        // `lines`): without their "\n" or "\r\n", each decoded strictly with a leading byte order mark dropped, ending at
        // the first that is not UTF-8 or at a read that fails; at most `limit`. A line longer than `max` bytes (its "\n"
        // counted) is read as "". None when the file does not open: an empty list.
        if op == "fs.lines" {
            use std::io::Read;
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(json!([])) };
            let limit = a.get("limit").and_then(Value::as_u64).map_or(usize::MAX, |n| n as usize);
            let max = a.get("max").and_then(Value::as_u64).map_or(usize::MAX, |n| n as usize);
            let mut out: Vec<Value> = Vec::new();
            let mut pending: Vec<u8> = Vec::new();
            let mut over = false;
            // Whether more are wanted.
            let take = |line: &[u8], over: &mut bool, out: &mut Vec<Value>| -> bool {
                if *over {
                    *over = false;
                    out.push(json!(""));
                    return out.len() < limit;
                }
                let mut line = line;
                if line.last() == Some(&b'\n') {
                    line = &line[..line.len() - 1];
                }
                if line.last() == Some(&b'\r') {
                    line = &line[..line.len() - 1];
                }
                let body = line.strip_prefix(b"\xef\xbb\xbf").unwrap_or(line);
                match std::str::from_utf8(body) {
                    Ok(text) => out.push(json!(text)),
                    Err(_) => return false,
                }
                out.len() < limit
            };
            let mut chunk = vec![0u8; 1 << 16];
            loop {
                let n = match file.read(&mut chunk) {
                    Ok(n) => n,
                    Err(_) => return Ok(Value::Array(out)),
                };
                if n == 0 {
                    break;
                }
                let mut start = 0;
                let keep = |part: &[u8], pending: &mut Vec<u8>, over: &mut bool| {
                    if *over {
                        return;
                    }
                    if pending.len() + part.len() > max {
                        *over = true;
                        pending.clear();
                    } else {
                        pending.extend_from_slice(part);
                    }
                };
                while let Some(nl) = chunk[start..n].iter().position(|&b| b == b'\n').map(|i| start + i) {
                    keep(&chunk[start..=nl], &mut pending, &mut over);
                    let line = std::mem::take(&mut pending);
                    start = nl + 1;
                    if !take(&line, &mut over, &mut out) {
                        return Ok(Value::Array(out));
                    }
                }
                if start < n {
                    keep(&chunk[start..n], &mut pending, &mut over);
                }
            }
            if !pending.is_empty() || over {
                take(&pending, &mut over, &mut out);
            }
            return Ok(Value::Array(out));
        }
        // What the station's programs write (station/mb src/replica, as station/src/replica/export.ts writes): `text`
        // as a whole file at `path`, zstd's frame of it with `zstd` (level 3, as Node's zstdCompressSync), written beside
        // it, synced and renamed into place, its folders made; the SHA-256 of the bytes written and how many.
        if op == "fs.write" {
            use sha2::Digest;
            use std::io::Write;
            let path = PathBuf::from(str_of(a, "path")?);
            let text = str_of(a, "text")?.as_bytes();
            let bytes = if a.get("zstd").and_then(Value::as_bool).unwrap_or(false) { zstd::encode_all(text, 3).map_err(err)? } else { text.to_vec() };
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(err)?;
            }
            let mut random = [0u8; 4];
            getrandom::fill(&mut random).map_err(err)?;
            let tmp = PathBuf::from(format!("{}.{}.{}.tmp", path.display(), std::process::id(), hex::encode(random)));
            let written = (|| {
                let mut file = std::fs::File::create(&tmp)?;
                file.write_all(&bytes)?;
                file.sync_all()
            })();
            if let Err(e) = written.and_then(|_| std::fs::rename(&tmp, &path)) {
                let _ = std::fs::remove_file(&tmp);
                return Err(err(e));
            }
            return Ok(json!({ "sha256": hex::encode(sha2::Sha256::digest(&bytes)), "size": bytes.len() }));
        }
        // A file's SHA-256 (hex), read a MiB at a time; null when it does not open.
        if op == "fs.hash" {
            use sha2::Digest;
            use std::io::Read;
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Value::Null) };
            let mut hash = sha2::Sha256::new();
            let mut buf = vec![0u8; 1 << 20];
            loop {
                let n = file.read(&mut buf).map_err(err)?;
                if n == 0 {
                    break;
                }
                hash.update(&buf[..n]);
            }
            return Ok(json!(hex::encode(hash.finalize())));
        }
        // What lstat says of `path` (links not followed), as Node's lstat gives it (station/mb src/reader/dirsync.mbt): its
        // kind, size, mode, inode, and mtime and ctime in ms (seconds and nanoseconds as Node joins them); null when
        // nothing is there.
        if op == "fs.lstat" {
            let Ok(m) = std::fs::symlink_metadata(str_of(a, "path")?) else { return Ok(Value::Null) };
            let kind = if m.file_type().is_symlink() { "link" } else if m.is_file() { "file" } else if m.is_dir() { "dir" } else { "other" };
            #[cfg(unix)]
            let (mode, ino, mtime, ctime) = {
                use std::os::unix::fs::MetadataExt;
                let ms = |s: i64, ns: i64| s as f64 * 1e3 + ns as f64 / 1e6;
                (m.mode(), m.ino(), ms(m.mtime(), m.mtime_nsec()), ms(m.ctime(), m.ctime_nsec()))
            };
            #[cfg(not(unix))]
            let (mode, ino, mtime, ctime) = {
                let ms = |t: std::io::Result<std::time::SystemTime>| t.ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0.0, |d| d.as_secs_f64() * 1e3);
                (if m.permissions().readonly() { 0o444 } else { 0o666 }, 0u64, ms(m.modified()), ms(m.modified()))
            };
            return Ok(json!({ "kind": kind, "size": m.len(), "mode": mode, "ino": ino, "mtimeMs": mtime, "ctimeMs": ctime }));
        }
        // A symbolic link at `path` naming `target`.
        if op == "fs.symlink" {
            let (target, path) = (str_of(a, "target")?, str_of(a, "path")?);
            #[cfg(unix)]
            std::os::unix::fs::symlink(target, path).map_err(err)?;
            #[cfg(windows)]
            std::os::windows::fs::symlink_file(target, path).map_err(err)?;
            return Ok(Value::Null);
        }
        // The permission bits of `path` set to `mode` (chmodSync); nothing where the system has none.
        if op == "fs.chmod" {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mode = a.get("mode").and_then(Value::as_u64).ok_or("mode is required")? as u32;
                std::fs::set_permissions(str_of(a, "path")?, std::fs::Permissions::from_mode(mode)).map_err(err)?;
            }
            return Ok(Value::Null);
        }
        // A hard link `to` of `from`: false when `to` is there already (EEXIST), true when made.
        if op == "fs.link" {
            return match std::fs::hard_link(str_of(a, "from")?, str_of(a, "to")?) {
                Ok(()) => Ok(json!(true)),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(json!(false)),
                Err(e) => Err(err(e)),
            };
        }
        // A file's content id as Git has it (sha1 of "blob <size>\0" and its bytes), read a MiB at a time; `size` is what
        // it is to be, refused when it reads otherwise (changed while read). Null when it does not open.
        if op == "fs.gitblob" {
            use sha1::Digest;
            use std::io::Read;
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Value::Null) };
            let size = a.get("size").and_then(Value::as_u64).ok_or("size is required")?;
            let mut hash = sha1::Sha1::new();
            hash.update(format!("blob {size}\0").as_bytes());
            let (mut buf, mut read) = (vec![0u8; 1 << 20], 0u64);
            loop {
                let n = file.read(&mut buf).map_err(err)?;
                if n == 0 {
                    break;
                }
                read += n as u64;
                hash.update(&buf[..n]);
            }
            if read != size {
                return Err(format!("{} changed while it was read", str_of(a, "path")?));
            }
            return Ok(json!(hex::encode(hash.finalize())));
        }
        // What lstat says of each of `paths` (`follow`: stat, a link followed), 8 at a time, in their order: null where
        // nothing is there, else {kind, size, mode, dev} (dev 0 where the system has none: Windows, where a folder
        // mounted in another is a link, not followed). With `hash`, a file's Git blob id too (`hash`, of one of `most`
        // bytes at most), a link's target (`link`): what a directory sync lists of the files it sends
        // (station/mb src/reader/dirsync.mbt `scan`). A file that reads otherwise than its size, or a link that does
        // not read, fails it.
        if op == "fs.scan" {
            let paths: Vec<String> = a.get("paths").and_then(Value::as_array).map(|v| v.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            let follow = a.get("follow").and_then(Value::as_bool).unwrap_or(false);
            let hash = a.get("hash").and_then(Value::as_bool).unwrap_or(false);
            let most = a.get("most").and_then(Value::as_u64).unwrap_or(u64::MAX);
            let next = std::sync::atomic::AtomicUsize::new(0);
            let mut out: Vec<Option<Result<Value, String>>> = (0..paths.len()).map(|_| None).collect();
            let slots: Vec<Mutex<&mut Option<Result<Value, String>>>> = out.iter_mut().map(Mutex::new).collect();
            std::thread::scope(|s| {
                for _ in 0..paths.len().min(8) {
                    s.spawn(|| loop {
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        if i >= paths.len() {
                            break;
                        }
                        **slots[i].lock().unwrap() = Some(scan_one(&paths[i], follow, hash, most));
                    });
                }
            });
            drop(slots);
            let mut values = Vec::with_capacity(out.len());
            for v in out {
                values.push(v.unwrap_or(Ok(Value::Null))?);
            }
            return Ok(Value::Array(values));
        }
        // A folder and those it is in, made where they are not (mkdirSync's `recursive`).
        if op == "fs.mkdir" {
            std::fs::create_dir_all(str_of(a, "path")?).map_err(err)?;
            return Ok(Value::Null);
        }
        // What is at `path` let go, a folder with all it holds with `recursive`; nothing there is no failure (rmSync's
        // `force`).
        if op == "fs.remove" {
            let path = PathBuf::from(str_of(a, "path")?);
            let recursive = a.get("recursive").and_then(Value::as_bool).unwrap_or(false);
            let gone = match std::fs::symlink_metadata(&path) {
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e),
                Ok(m) if m.is_dir() && recursive => std::fs::remove_dir_all(&path),
                Ok(m) if m.is_dir() => std::fs::remove_dir(&path),
                Ok(_) => std::fs::remove_file(&path),
            };
            return gone.map(|_| Value::Null).map_err(err);
        }
        if op == "fs.rename" {
            std::fs::rename(str_of(a, "from")?, str_of(a, "to")?).map_err(err)?;
            return Ok(Value::Null);
        }
        if op == "fs.copy" {
            std::fs::copy(str_of(a, "from")?, str_of(a, "to")?).map_err(err)?;
            return Ok(Value::Null);
        }
        // `bytes` random bytes (hex), from the system's source.
        if op == "crypto.random" {
            let mut bytes = vec![0u8; a.get("bytes").and_then(Value::as_u64).unwrap_or(0).min(1024) as usize];
            getrandom::fill(&mut bytes).map_err(err)?;
            return Ok(json!(hex::encode(bytes)));
        }
        if op == "fs.read" {
            let Ok(mut bytes) = std::fs::read(str_of(a, "path")?) else { return Ok(Value::Null) };
            // `zstd`: a file that is zstd's frames, read as what they hold (a copy's batch: station/mb src/replica).
            if a.get("zstd").and_then(Value::as_bool).unwrap_or(false) {
                bytes = zstd::decode_all(bytes.as_slice()).map_err(err)?;
            }
            if a.get("strict").and_then(Value::as_bool).unwrap_or(false) {
                let body = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
                return Ok(std::str::from_utf8(body).map_or(Value::Null, |s| json!(s)));
            }
            return Ok(json!(String::from_utf8_lossy(&bytes)));
        }
        // An Ed25519 key's public half and its signature of `message` (hex both ways): a lock claim's (client/core-ts
        // lock.ts), signed for each workspace and endpoint as the core connects. In Hermes (no JIT) the JS one took ~8 ms
        // each and longer the first time, on the core's thread before anything the UI had asked for.
        if op == "ed25519.sign" {
            let seed: [u8; 32] = hex::decode(str_of(a, "seed")?).map_err(err)?.try_into().map_err(|_| "the seed is not 32 bytes".to_string())?;
            let key = SecretKey::from_bytes(&seed);
            let message = hex::decode(str_of(a, "message")?).map_err(err)?;
            return Ok(json!({ "publicKey": hex::encode(key.public().as_bytes()), "signature": hex::encode(key.sign(&message).to_bytes()) }));
        }
        // Whether `signature` is `key`'s over `message` (hex all): Ed25519 (a 32-byte key, a 64-byte signature) or ECDSA
        // P-256 over SHA-256 (`ES256`: an uncompressed point and r‖s; `ES256-der`: the signature DER, as WebAuthn gives
        // it), by libcrux's formally verified implementations: what the core checks the lock's entries and the vault's
        // records by (client/core-ts vault/verified.ts) where the shell has it, not @noble's in JS.
        if op == "crypto.verify" {
            let key = hex::decode(str_of(a, "key")?).map_err(err)?;
            let signature = hex::decode(str_of(a, "signature")?).map_err(err)?;
            let message = hex::decode(str_of(a, "message")?).map_err(err)?;
            let ok = match str_of(a, "alg")? {
                "Ed25519" => match (<[u8; 32]>::try_from(key.as_slice()), <[u8; 64]>::try_from(signature.as_slice())) {
                    (Ok(k), Ok(s)) => libcrux_ed25519::verify(&message, &k, &s).is_ok(),
                    _ => false,
                },
                alg @ ("ES256" | "ES256-der") => {
                    use libcrux_ecdsa::p256::{PublicKey, Signature, verify};
                    let s = if alg == "ES256" { <[u8; 64]>::try_from(signature.as_slice()).ok().map(Signature::from_bytes) } else { Signature::from_der(&signature).ok() };
                    match (s, PublicKey::try_from(key.as_slice())) {
                        (Some(s), Ok(k)) if key.len() == 65 => verify(libcrux_ecdsa::DigestAlgorithm::Sha256, &message, &s, &k).is_ok(),
                        _ => false,
                    }
                }
                other => return Err(format!("no {other} here")),
            };
            return Ok(json!(ok));
        }
        // The vault's primitives (station/src/vault/crypto.ts: its seal, an item's ciphertext, the recovery key), hex
        // both ways, for the station's MoonBit (station/mb src/vault_crypto), which puts the formats together.
        if let Some(value) = vault_crypto(op, a)? {
            return Ok(value);
        }
        // What the DHT lookup's socket and lookups went through since the last take, while the core records (`keep`;
        // false: none kept from now on): the record's `dht:` lines (client/core-ts mesh.ts, vendor/n0-mainline's `stillfail`).
        if op == "dht.said" {
            let (lines, dropped) = n0_mainline::stillfail::said(a.get("keep").and_then(Value::as_bool).unwrap_or(false));
            return Ok(json!({ "lines": lines.into_iter().map(|s| json!({ "at": s.at_ms, "text": s.text })).collect::<Vec<_>>(), "dropped": dropped }));
        }
        let handle = self.handle(id_of(a)?)?;
        match (op, handle) {
            ("iroh.endpointId", Handle::Endpoint(e, _)) => Ok(json!(hex::encode(e.id().as_bytes()))),
            ("iroh.addAddr", Handle::Endpoint(e, _)) => {
                let addr = endpoint_addr(a.get("addr").ok_or("missing addr")?)?;
                e.address_lookup().map_err(err)?.add(iroh::address_lookup::MemoryLookup::from_endpoint_info([addr]));
                Ok(Value::Null)
            }
            ("iroh.sockets", Handle::Endpoint(e, _)) => Ok(json!(e.bound_sockets().iter().map(ToString::to_string).collect::<Vec<_>>())),
            ("iroh.sockets", Handle::Unbound { .. }) => Ok(json!([])),
            // How it runs now: "relay", "direct", or null while none is chosen.
            ("conn.via", Handle::Conn(c)) => Ok(c.paths().iter().find(|p| p.is_selected()).map(|p| json!(if p.is_relay() { "relay" } else { "direct" })).unwrap_or(Value::Null)),
            ("conn.via", Handle::Gone { .. }) => Ok(Value::Null),
            ("iroh.relayStatus", Handle::Endpoint(e, _)) => Ok(Value::Array(e.home_relay_status().get().iter().map(|s| json!({ "url": s.url().to_string(), "connected": s.is_connected(), "access": s.access_url().to_string(), "conflict": s.same_endpoint_id_connected() })).collect())),
            ("conn.alpn", Handle::Conn(c)) => Ok(json!(hex::encode(c.alpn()))),
            ("conn.remoteId", Handle::Conn(c)) => Ok(json!(hex::encode(c.remote_id().as_bytes()))),
            ("conn.closeReason", Handle::Conn(c)) => Ok(c.close_reason().map(|e| close_info(&e)).unwrap_or(Value::Null)),
            ("conn.paths", Handle::Conn(c)) => Ok(Value::Array(
                c.paths()
                    .iter()
                    .map(|p| {
                        let (relay, ip) = match p.remote_addr() {
                            iroh::TransportAddr::Relay(url) => (Some(url.to_string()), None),
                            iroh::TransportAddr::Ip(addr) => (None, Some(addr.to_string())),
                            _ => (None, None),
                        };
                        // Packets sent and lost on this way alone: the connection's counts take in every way it tried.
                        let stats = p.stats();
                        json!({ "id": p.id().to_string(), "selected": p.is_selected(), "relay": relay, "ip": ip, "rttMs": stats.same_path_rtt.map(|rtt| rtt.as_secs_f64() * 1000.0), "txPackets": stats.udp_tx.datagrams, "lostPackets": stats.lost_packets, "cwnd": stats.cwnd, "congestionEvents": stats.congestion_events })
                    })
                    .collect(),
            )),
            // What went over it since it opened (the addon's `stats`, which says what each is for).
            ("conn.stats", Handle::Conn(c)) => {
                let s = c.stats();
                let data = |f: &iroh::endpoint::FrameStats| f.stream + f.datagram + f.crypto;
                Ok(json!({
                    "rxBytes": s.udp_rx.bytes, "txBytes": s.udp_tx.bytes, "rxPackets": s.udp_rx.datagrams, "txPackets": s.udp_tx.datagrams,
                    "rxPings": s.frame_rx.ping, "txPings": s.frame_tx.ping, "rxAckRequests": s.frame_rx.immediate_ack, "txAckRequests": s.frame_tx.immediate_ack,
                    "rxAcks": s.frame_rx.acks + s.frame_rx.path_acks, "txAcks": s.frame_tx.acks + s.frame_tx.path_acks, "rxData": data(&s.frame_rx), "txData": data(&s.frame_tx),
                }))
            }
            ("conn.remoteId", Handle::Gone { remote, .. }) => Ok(json!(remote)),
            ("conn.closeReason", Handle::Gone { reason, .. }) => Ok(reason),
            ("conn.paths", Handle::Gone { .. }) => Ok(json!([])),
            ("conn.stats", Handle::Gone { stats, .. }) => Ok(stats),
            ("iroh.endpointId", Handle::Unbound { id }) => Ok(json!(id)),
            ("iroh.addAddr", Handle::Unbound { .. }) => Ok(Value::Null),
            ("iroh.relayStatus", Handle::Unbound { .. }) => Ok(json!([])),
            (op, _) => Err(format!("no operation {op} on that handle")),
        }
    }
}

/// How long a statement on an account's database waits while another connection holds it.
const DB_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

/// How long an account's database is waited for as it is opened: as long as a statement, but none in a window of the
/// app's own (MBUI_WINDOW: a run started beside the app's, which holds them all as long as it runs). That run keeps
/// them in memory at once (the core's data.ts), where it waited 5 s for each and every one before: its window showed
/// nothing for 15 s (2026-10-29 用户: 独立窗口要等很久才显示内容).
fn open_wait() -> std::time::Duration {
    if std::env::var_os("MBUI_WINDOW").is_some_and(|w| !w.is_empty()) {
        std::time::Duration::ZERO
    } else {
        DB_WAIT
    }
}

impl Shell {
    pub fn start(dir: PathBuf, complete: Complete, ctx: *mut c_void) -> std::io::Result<Shell> {
        Shell::start_waiting(dir, complete, ctx, open_wait())
    }

    fn start_waiting(dir: PathBuf, complete: Complete, ctx: *mut c_void, open_wait: std::time::Duration) -> std::io::Result<Shell> {
        std::fs::create_dir_all(&dir)?;
        // Two threads in an app; a station's program says how many it is to have (STILLFAIL_SHELL_THREADS: the station's
        // front, whose threads carry every byte of the station's iroh, its addon's on as many as the machine has cores).
        let threads = std::env::var("STILLFAIL_SHELL_THREADS").ok().and_then(|n| n.parse::<usize>().ok()).filter(|n| *n > 0).unwrap_or(2);
        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(threads).thread_name("stillfail-shell").enable_all().build()?;
        let (jobs, queue) = mpsc::channel::<Job>();
        std::thread::Builder::new().name("stillfail-disk".into()).spawn(move || {
            for job in queue {
                job();
            }
        })?;
        let tls = Arc::new(tls_config());
        let http = Mutex::new(http_client(&tls));
        let db = Arc::new(Mutex::new(DbHandle { path: dir.join("core.db"), conn: None }));
        let adb = adb::Adb::new(dir.clone());
        let inner = Arc::new(Inner { complete, ctx: Ctx(ctx), dir, disk: Mutex::new(jobs), db, tls, http, entries: Mutex::default(), fetches: Mutex::default(), handles: Mutex::default(), next: AtomicU64::new(1), sqls: Mutex::default(), texts: Mutex::default(), open_wait, say: Mutex::default(), media: Mutex::default(), adb });
        STATS.lock().unwrap().shells.push(Arc::downgrade(&inner));
        Ok(Shell { runtime, inner })
    }

    pub fn call(&self, id: u64, op: String, json: &[u8], bytes: Option<Vec<u8>>) {
        let inner = self.inner.clone();
        let args: Value = serde_json::from_slice(json).unwrap_or(Value::Null);
        // A fetch, and a dial's handshake (iroh.connect): given up when the core cancels the call, its connection dropped,
        // which closes it (a dial left going retransmitted its Initial for the connection's whole idle timeout: the
        // station addon's `dial`, station/native/mesh/src/lib.rs).
        let cancelled = if op == "fetch" || op == "iroh.connect" {
            let (cancel, cancelled) = tokio::sync::oneshot::channel();
            inner.fetches.lock().unwrap().insert(id, cancel);
            Some(cancelled)
        } else {
            None
        };
        counted(&op, true);
        self.runtime.spawn(async move {
            let done = if let Some(cancelled) = cancelled {
                let done = tokio::select! {
                    biased;
                    _ = cancelled => Err("cancelled".into()),
                    done = inner.run(&op, args, bytes) => done,
                };
                inner.fetches.lock().unwrap().remove(&id);
                done
            } else {
                inner.run(&op, args, bytes).await
            };
            counted(&op, false);
            let (json, error, bytes) = match done {
                Ok(answer) => (serde_json::to_vec(&answer.json).unwrap_or_default(), Vec::new(), answer.bytes),
                Err(e) => (Vec::new(), if e.is_empty() { b"failed".to_vec() } else { e.into_bytes() }, None),
            };
            let (b, blen, has) = match &bytes {
                Some(b) => (b.as_ptr(), b.len(), 1),
                None => (std::ptr::null(), 0, 0),
            };
            (inner.complete)(inner.ctx.0, id, json.as_ptr(), json.len(), error.as_ptr(), error.len(), b, blen, has);
        });
    }

    pub fn call_sync(&self, op: &str, json: &[u8]) -> Vec<u8> {
        let args: Value = serde_json::from_slice(json).unwrap_or(Value::Null);
        counted(op, true);
        counted(op, false);
        let done = if op.starts_with("sql.") { self.inner.sql(op, &args) } else { self.inner.run_sync(op, &args) };
        let out = match done {
            Ok(value) => json!({ "value": value }),
            Err(error) => json!({ "error": error }),
        };
        serde_json::to_vec(&out).unwrap_or_default()
    }
}

/// Starts a shell keeping its files in `data_dir`. Null when it cannot (the directory cannot be made).
///
/// # Safety
/// `data_dir` is a NUL-terminated string; `complete` may be called with `ctx` from any thread until `sf_shell_stop`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_start(data_dir: *const c_char, complete: Complete, ctx: *mut c_void) -> *mut Shell {
    // SAFETY: the caller gives a NUL-terminated string.
    let dir = unsafe { CStr::from_ptr(data_dir) }.to_string_lossy().into_owned();
    match Shell::start(PathBuf::from(dir), complete, ctx) {
        Ok(shell) => Box::into_raw(Box::new(shell)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Starts operation `id`.
///
/// # Safety
/// `shell` is from `sf_shell_start`; `op` NUL-terminated; `json`/`bytes` valid for their lengths (`bytes` read only
/// when `has_bytes`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_call(shell: *const Shell, id: u64, op: *const c_char, json: *const u8, json_len: usize, bytes: *const u8, bytes_len: usize, has_bytes: u8) {
    // SAFETY: as documented.
    let (shell, op, json) = unsafe { (&*shell, CStr::from_ptr(op).to_string_lossy().into_owned(), std::slice::from_raw_parts(json, json_len)) };
    let bytes = (has_bytes != 0).then(|| if bytes_len == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(bytes, bytes_len) }.to_vec() });
    shell.call(id, op, json, bytes);
}

/// An operation answered at once: its JSON (`{value}` or `{error}`), to be let go with `sf_free`.
///
/// # Safety
/// As `sf_shell_call`; `out_len` is written.
/// The vault's primitives (`crypto.*` in `sf_shell_call_sync`); None for an op not one of them. Every byte string is hex.
/// - `crypto.sha256` {data} -> digest; `crypto.hmacSha256` {key, data} -> tag
/// - `crypto.hkdfSha256` {ikm, salt, info, length} -> length bytes (at most 255 × 32)
/// - `crypto.x25519Public` {priv} -> its public half; `crypto.x25519` {priv, pub} -> the shared secret, an error where it
///   is all zeros (a low-order point), as node:crypto's diffieHellman refuses it
/// - `crypto.chachaSeal` {key, nonce, aad, plain} -> ciphertext ‖ 16-byte tag; `crypto.chachaOpen` {key, nonce, aad,
///   sealed} -> what it held, null where it does not open (ChaCha20-Poly1305, RFC 8439)
fn vault_crypto(op: &str, a: &Value) -> Result<Option<Value>, String> {
    use ring::{aead, digest, hkdf, hmac};
    let bytes = |k: &str| -> Result<Vec<u8>, String> { hex::decode(str_of(a, k)?).map_err(|e| format!("{k}: {e}")) };
    let fixed = |k: &str| -> Result<[u8; 32], String> { bytes(k)?.try_into().map_err(|_| format!("{k} is not 32 bytes")) };
    let aead_key = |k: &[u8; 32]| aead::LessSafeKey::new(aead::UnboundKey::new(&aead::CHACHA20_POLY1305, k).expect("32 bytes"));
    let nonce = || -> Result<aead::Nonce, String> {
        aead::Nonce::try_assume_unique_for_key(&bytes("nonce")?).map_err(|_| "nonce is not 12 bytes".to_string())
    };
    Ok(Some(match op {
        "crypto.sha256" => json!(hex::encode(digest::digest(&digest::SHA256, &bytes("data")?))),
        "crypto.hmacSha256" => {
            let key = hmac::Key::new(hmac::HMAC_SHA256, &bytes("key")?);
            json!(hex::encode(hmac::sign(&key, &bytes("data")?)))
        }
        "crypto.hkdfSha256" => {
            struct Len(usize);
            impl hkdf::KeyType for Len {
                fn len(&self) -> usize {
                    self.0
                }
            }
            let length = a.get("length").and_then(Value::as_u64).ok_or("length is a number")? as usize;
            if length == 0 || length > 255 * 32 {
                return Err("length is 1 to 8160".into());
            }
            let info = bytes("info")?;
            let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, &bytes("salt")?).extract(&bytes("ikm")?);
            let mut out = vec![0u8; length];
            prk.expand(&[&info], Len(length)).and_then(|okm| okm.fill(&mut out)).map_err(|_| "hkdf failed")?;
            json!(hex::encode(out))
        }
        "crypto.x25519Public" => json!(hex::encode(curve25519_dalek::MontgomeryPoint::mul_base_clamped(fixed("priv")?).to_bytes())),
        "crypto.x25519" => {
            let shared = curve25519_dalek::MontgomeryPoint(fixed("pub")?).mul_clamped(fixed("priv")?).to_bytes();
            if shared == [0u8; 32] {
                return Err("the shared secret is zero (a low-order point)".into());
            }
            json!(hex::encode(shared))
        }
        "crypto.chachaSeal" => {
            let mut io = bytes("plain")?;
            aead_key(&fixed("key")?).seal_in_place_append_tag(nonce()?, aead::Aad::from(bytes("aad")?), &mut io).map_err(|_| "seal failed")?;
            json!(hex::encode(io))
        }
        "crypto.chachaOpen" => {
            let mut io = bytes("sealed")?;
            match aead_key(&fixed("key")?).open_in_place(nonce()?, aead::Aad::from(bytes("aad")?), &mut io) {
                Ok(plain) => json!(hex::encode(plain)),
                Err(_) => Value::Null,
            }
        }
        _ => return Ok(None),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_call_sync(shell: *const Shell, op: *const c_char, json: *const u8, json_len: usize, out_len: *mut usize) -> *mut u8 {
    // SAFETY: as documented.
    let (shell, op, json) = unsafe { (&*shell, CStr::from_ptr(op).to_string_lossy().into_owned(), std::slice::from_raw_parts(json, json_len)) };
    let mut out = shell.call_sync(&op, json).into_boxed_slice();
    unsafe { *out_len = out.len() };
    let ptr = out.as_mut_ptr();
    std::mem::forget(out);
    ptr
}

/// What the shells have been asked so far (`{calls: {op: [started, unanswered]}, handles: {kind: n}, sqls}`), as JSON
/// to be let go with `sf_free`.
///
/// # Safety
/// `out_len` is written.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_stats(out_len: *mut usize) -> *mut u8 {
    let mut out = serde_json::to_vec(&stats_json()).unwrap_or_default().into_boxed_slice();
    unsafe { *out_len = out.len() };
    let ptr = out.as_mut_ptr();
    std::mem::forget(out);
    ptr
}

/// # Safety
/// `ptr`/`len` from `sf_shell_call_sync` or `sf_shell_stats`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        // SAFETY: made by `sf_shell_call_sync` from a boxed slice of this length.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}

/// Where a message for the app goes straight from the shell (a remote screen's frames, `istream.tap`): `say` with
/// `ctx`, from any of the shell's threads, until `sf_shell_stop`.
///
/// # Safety
/// `shell` from `sf_shell_start`; `say` may be called with `ctx` from any thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_set_say(shell: *const Shell, say: Say, ctx: *mut c_void) {
    // SAFETY: made by `sf_shell_start`.
    let shell = unsafe { &*shell };
    *shell.inner.say.lock().unwrap() = Some((say, Ctx(ctx)));
}

/// Where a tapped remote screen's records are offered before they are said to the app (`Media`): `media` with `ctx`,
/// from any of the shell's threads, until `sf_shell_stop`.
///
/// # Safety
/// `shell` from `sf_shell_start`; `media` may be called with `ctx` from any thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_set_media(shell: *const Shell, media: Media, ctx: *mut c_void) {
    // SAFETY: made by `sf_shell_start`.
    let shell = unsafe { &*shell };
    *shell.inner.media.lock().unwrap() = Some((media, Ctx(ctx)));
}

/// A remote screen's frame `ts` acknowledged by the app straight to the station, on the stream its view `call` is
/// tapped on (`istream.tap`), not through the core (an ack frame: screen-frames.ts ackFrame); 0 when no tapped stream
/// is that view's (the app asks the core then).
///
/// # Safety
/// `shell` from `sf_shell_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_screen_ack(shell: *const Shell, call: u64, ts: f64) -> u8 {
    // SAFETY: made by `sf_shell_start`.
    let shell = unsafe { &*shell };
    let halves = shell.inner.handles.lock().unwrap().values().find_map(|h| match h {
        Handle::IStream(halves) if halves.tap.lock().unwrap().as_ref().is_some_and(|t| t.call == call) => Some(halves.clone()),
        _ => None,
    });
    let Some(halves) = halves else { return 0 };
    let mut frame = vec![17u8, 0, 0, 0, 8];
    frame.extend_from_slice(&(ts.max(0.0).floor() as u64).to_be_bytes());
    tally("tap.acks");
    shell.runtime.spawn(async move {
        if let Some(send) = halves.send.lock().await.as_mut() {
            let _ = send.write_all(&frame).await;
        }
    });
    1
}

/// Stops a shell: what is under way is dropped, its answers never come.
///
/// # Safety
/// `shell` from `sf_shell_start`, not used after.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_stop(shell: *mut Shell) {
    if !shell.is_null() {
        // SAFETY: made by `sf_shell_start`.
        let shell = unsafe { Box::from_raw(shell) };
        shell.runtime.shutdown_background();
    }
}

/// The viewer's time zone at `at_ms` (minutes east of UTC), from the C library, which on Android follows the system's
/// zone setting and its DST rules (as the Rust core had them).
#[cfg(not(windows))]
#[unsafe(no_mangle)]
pub extern "C" fn sf_utc_offset_min(at_ms: f64) -> i32 {
    let at = (at_ms / 1000.0).floor() as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are valid for the call; localtime_r is the thread-safe variant.
    if unsafe { libc::localtime_r(&at, &mut tm) }.is_null() {
        return 0;
    }
    (tm.tm_gmtoff / 60) as i32
}

/// The same on Windows (the mbui app's core), whose C library has neither localtime_r nor tm_gmtoff: the local time the
/// CRT makes of `at_ms` (the system's zone and its DST rules, or $TZ when set), read back as if it were UTC, less
/// `at_ms`. 0 where the CRT has no local time (before 1970).
#[cfg(windows)]
#[unsafe(no_mangle)]
pub extern "C" fn sf_utc_offset_min(at_ms: f64) -> i32 {
    unsafe extern "C" {
        fn _localtime64_s(tm: *mut libc::tm, time: *const i64) -> i32;
        fn _mkgmtime64(tm: *mut libc::tm) -> i64;
    }
    let at = (at_ms / 1000.0).floor() as i64;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are valid for the calls.
    if unsafe { _localtime64_s(&mut tm, &at) } != 0 {
        return 0;
    }
    let local_as_utc = unsafe { _mkgmtime64(&mut tm) };
    if local_as_utc == -1 {
        return 0;
    }
    ((local_as_utc - at) / 60) as i32
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Condvar, Mutex as StdMutex};

    fn frame(kind: u8, body: &[u8]) -> Vec<u8> {
        let mut f = vec![kind];
        f.extend_from_slice(&(body.len() as u32).to_be_bytes());
        f.extend_from_slice(body);
        f
    }

    /// What a tapped view offered its host and said to the app; the host takes the kinds in `takes`.
    #[derive(Default)]
    struct Told {
        takes: Vec<u8>,
        offered: StdMutex<Vec<(u64, u8, bool, u64, u64, usize)>>,
        said: StdMutex<Vec<(Value, Option<Vec<u8>>)>>,
    }

    impl Tell for Told {
        fn media(&self, call: u64, kind: u8, key: bool, seq: u64, ts: u64, bytes: &[u8]) -> bool {
            self.offered.lock().unwrap().push((call, kind, key, seq, ts, bytes.len()));
            self.takes.contains(&kind)
        }
        fn say(&self, json: &[u8], bytes: Option<&[u8]>) {
            self.said.lock().unwrap().push((serde_json::from_slice(json).unwrap(), bytes.map(<[u8]>::to_vec)));
        }
    }

    fn screen_wire() -> (Vec<u8>, Vec<u8>) {
        let config = frame(FRAME_CONFIG, br#"{"codec":"h264","width":1919.6,"height":1080,"description":"AQID","region":{"x":0.5,"y":0,"w":0.5,"h":0.5}}"#);
        let mut video = vec![1u8];
        video.extend_from_slice(&5u64.to_be_bytes());
        video.extend_from_slice(b"pic");
        let mut later = vec![0u8];
        later.extend_from_slice(&6u64.to_be_bytes());
        later.extend_from_slice(b"pic2");
        let mut audio = 9u64.to_be_bytes().to_vec();
        audio.extend_from_slice(&[0u8; 3840]);
        let state = frame(3, br#"{"cursor":null}"#);
        let mut wire = config.clone();
        for f in [frame(FRAME_VIDEO, &video), frame(FRAME_VIDEO, &later), frame(FRAME_AUDIO, &audio), state.clone()] {
            wire.extend(f);
        }
        // the core's: the config, the first video frame's head alone, the state
        let mut core = config;
        core.extend(frame(FRAME_VIDEO, &video[..9]));
        core.extend(state);
        (wire, core)
    }

    #[test]
    fn a_tapped_screen_says_its_picture_and_sound_and_keeps_the_rest_for_the_core() {
        let told = Told::default();
        let mut tap = ScreenTap::new(7);
        let (wire, core) = screen_wire();
        // cut anywhere
        for piece in wire.chunks(7) {
            tap.take(piece, &told);
        }
        let said = told.said.into_inner().unwrap();
        let offered = told.offered.into_inner().unwrap();
        // each offered the host first, in order, numbered one after another; none taken there
        assert_eq!(offered.iter().map(|o| (o.0, o.1, o.2, o.4, o.5)).collect::<Vec<_>>(), vec![(7, FRAME_CONFIG, false, 0, 0), (7, FRAME_VIDEO, true, 5, 3), (7, FRAME_VIDEO, false, 6, 4), (7, FRAME_AUDIO, false, 9, 3840)]);
        let n: Vec<u64> = offered.iter().map(|o| o.3).collect();
        assert!(n.windows(2).all(|w| w[1] > w[0]));
        assert_eq!(said.len(), 4);
        assert_eq!(said[0].0, json!({ "id": 7, "value": { "config": { "codec": "h264", "width": 1920.0, "height": 1080.0, "region": { "x": 0.5, "y": 0.0, "w": 0.5, "h": 0.5 } } } }));
        assert_eq!(said[0].1.as_deref(), Some(&[1u8, 2, 3][..]));
        assert_eq!(said[1].0, json!({ "id": 7, "value": { "frame": { "key": true, "ts": 5, "n": n[1] } } }));
        assert_eq!(said[1].1.as_deref(), Some(&b"pic"[..]));
        assert_eq!(said[2].0, json!({ "id": 7, "value": { "frame": { "key": false, "ts": 6, "n": n[2] } } }));
        assert_eq!(said[3].0, json!({ "id": 7, "value": { "audio": { "ts": 9, "n": n[3] } } }));
        assert_eq!(said[3].1.as_ref().map(Vec::len), Some(3840));
        assert_eq!(tap.out, core);
        assert!(tap.pending.is_empty());
        // as it came whole, or a frame cut across two pieces: the same
        for cut in [wire.len(), wire.len() - 3] {
            let told = Told::default();
            let mut again = ScreenTap::new(7);
            again.take(&wire[..cut], &told);
            again.take(&wire[cut..], &told);
            assert_eq!((told.said.lock().unwrap().len(), &again.out, again.pending.len()), (4, &core, 0));
        }
    }

    #[test]
    fn what_the_host_takes_of_a_tapped_screen_is_not_said() {
        // the host decodes and plays the frames and the sound itself: only the config said, the core's kept the same
        let told = Told { takes: vec![FRAME_VIDEO, FRAME_AUDIO], ..Told::default() };
        let mut tap = ScreenTap::new(3);
        let (wire, core) = screen_wire();
        tap.take(&wire, &told);
        let said = told.said.into_inner().unwrap();
        assert_eq!(said.len(), 1);
        assert!(said[0].0["value"]["config"].is_object());
        assert_eq!(told.offered.lock().unwrap().len(), 4);
        assert_eq!(tap.out, core);
    }

    /// The first 80 ms of a tone (440 Hz and 1250 Hz on the left, 660 Hz on the right, 0.3 and 0.1 of full scale) as the
    /// Mac's helper encodes it (AudioToolbox, 64 kbit/s): one Opus packet each 20 ms.
    const TONE_OPUS: [&str; 4] = [
            "fc7efcfac83adf72422eb70639fd4e7994094ff81dca24140fcda72ab2837dafcb307757fd6f158807f14e5e02ba87d108d7bd98511d4749ba09a54029f42122017d75bb3f223221c5fca7b5cd5d7ea2a96148eb32fcc8e81946df99d205a49cd119fd285e189d81b698fe1eb8a4cea59aa6b594d60479250ecd7fcc39e8231dde329ac910ad059cc974b3dc9f2151d605aa2169f84ff7e1dbc00263e2c45f6243d8dad8ff115909f7c119fc6f003690930e4f7b70a549bf3fb41999da21cfa221cfa7445c5eea9f2dea8d6e4752a3a16abe4752a77619af9e3f8443068d0e8f4b3b67e429ea271c65f49d1280a1f826b8a6e4235d037e42f70b1b3def726cd85c5675900040f45954157bb1fed63d34848eb0c9061d95fa530354ab8f281430570d47f20f2e1ce4b8379de776c5758efa3b17e75eb7df13019e2eb8127e",
            "fcf01f552abac40cb85b1b9c453ab1c5c0efde6ee2a4abc433f8c758944a04de36245ed4673c74936b45224cd6674e8e979829b7673b8ee8d5faae9dfb85461dc85db4fcfe1ca13bf53a8e7d455427f10b9283f4e3969eaca97907055f74b4f3c68af224684fcea74a70759c10ce055a78da40cfe736edb1f06af2e1516d9c9b0596688961e12b253da1eb5255a67bb07d1b5bd61e2b25abbaab1cc4eed48e12cce89ccbf893d75f050cbf06e645c0d5cc8e",
            "fcf0533d61b4ccf9c20a05dd48d2b7a632b6b587bf7509d2330cbf4df6837f3fff1a8f72494cb696db3b4f99658c1997d9a4ad792c6ad90573eb04a8ba81ea16e73fe342e66946a731490469fd67f67cb28038aab73f603d03c51d9eba899826c31d1240e44aeb48a68649472d543c2b233cdd6908a1968506aaaa461321ac70e71855735019314fde063951e507e1f33e5883ba01f68ff0e094dde1ec8e",
            "fced3cd57d7aa6a3555bbe8628998d7798b5f24ff8b642112c57c81112f8b2b55d3d49112fd2e45042ae08e20c311cc5d634041eb70f9edee772340f4c0c4b37067ffc0378b1e7934408b5f67f1c18a2704671798a125eadce7ee7f6372126813aa7441d008cf744241e40631cbed650ac8ed66b3172863ef769665807743a9e63409d45846a5361e3926ce68773ceb4a34ff103e65fda8b9c924ae4d77c8e",
    ];

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    #[test]
    fn a_tapped_screens_opus_sound_is_said_as_the_pcm_it_decodes_to() {
        let told = Told::default();
        let mut tap = ScreenTap::new(4);
        let mut wire = frame(FRAME_AUDIO_CONFIG, br#"{"codec":"opus","sampleRate":48000,"channels":2}"#);
        for (i, packet) in TONE_OPUS.iter().enumerate() {
            let mut body = ((i as u64 + 1) * 20_000).to_be_bytes().to_vec();
            body.extend(unhex(packet));
            wire.extend(frame(FRAME_AUDIO, &body));
        }
        // one that is no Opus packet: left out, the sound going on with the next
        let mut broken = 100_000u64.to_be_bytes().to_vec();
        broken.extend_from_slice(&[0xff; 3]);
        wire.extend(frame(FRAME_AUDIO, &broken));
        // after a gap (and the packet not decoded): decoded by a decoder made anew
        let mut after = 1_000_000u64.to_be_bytes().to_vec();
        after.extend(unhex(TONE_OPUS[1]));
        wire.extend(frame(FRAME_AUDIO, &after));
        for piece in wire.chunks(13) {
            tap.take(piece, &told);
        }
        let said = told.said.into_inner().unwrap();
        // the app is told PCM: what it plays is the decoded sound
        assert_eq!(said[0].0, json!({ "id": 4, "value": { "audioConfig": { "codec": "pcm_s16le", "sampleRate": 48000, "channels": 2 } } }));
        let packets: Vec<&Vec<u8>> = said[1..].iter().map(|s| s.1.as_ref().unwrap()).collect();
        assert_eq!(packets.iter().map(|p| p.len()).collect::<Vec<_>>(), vec![PCM_PACKET; 5]);
        assert_eq!(said[1..].iter().map(|s| s.0["value"]["audio"]["ts"].as_u64().unwrap()).collect::<Vec<_>>(), vec![20_000, 40_000, 60_000, 80_000, 1_000_000]);
        // past the decoder's start, the tone: the left about 0.22 of full scale (RMS), the right about 0.21
        let rms = |p: &[u8], ch: usize| {
            let v: Vec<f64> = p.chunks_exact(4).map(|f| i16::from_le_bytes([f[ch * 2], f[ch * 2 + 1]]) as f64 / 32768.0).collect();
            (v.iter().map(|x| x * x).sum::<f64>() / v.len() as f64).sqrt()
        };
        let (left, right) = (rms(packets[3], 0), rms(packets[3], 1));
        assert!((0.19..0.26).contains(&left) && (0.18..0.25).contains(&right), "{left} {right}");
        assert!(tap.out.is_empty(), "nothing of it the core's");
    }

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
            let socket = inner.keep(Handle::Tcp { read: Arc::new(tokio::sync::Mutex::new(Box::new(read))), write: Arc::new(tokio::sync::Mutex::new(Box::new(write))) });
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

            // the socket ending without its end resets the stream; the other end's reset is said as what failed it
            let stream = inner.run("conn.openBi", json!({ "id": id }), None).await.unwrap().json["id"].as_u64().unwrap();
            let (ours, node) = tokio::net::UnixStream::pair().unwrap();
            let (read, write) = ours.into_split();
            let socket = inner.keep(Handle::Tcp { read: Arc::new(tokio::sync::Mutex::new(Box::new(read))), write: Arc::new(tokio::sync::Mutex::new(Box::new(write))) });
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
                    write.write_all(&out).await.unwrap();
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
            let socket = inner.keep(Handle::Tcp { read: Arc::new(tokio::sync::Mutex::new(Box::new(read))), write: Arc::new(tokio::sync::Mutex::new(Box::new(write))) });
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

    /// The vault's primitives put together as station/src/vault/crypto.ts does (its seal, an item's ciphertext, the
    /// recovery key), on the vectors the station and the core are tested on.
    #[test]
    fn makes_the_vaults_vectors() {
        let v: Value = serde_json::from_str(include_str!("../../../station/test/fixtures/vault-vectors.json")).unwrap();
        let op = |op: &str, a: Value| -> Result<Value, String> { super::vault_crypto(op, &a).map(Option::unwrap) };
        let h = |op_: &str, a: Value| -> Vec<u8> { hex::decode(op(op_, a).unwrap().as_str().unwrap()).unwrap() };
        const B64: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let b64url = |b: &[u8]| -> String {
            let mut out = String::new();
            for c in b.chunks(3) {
                let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
                for i in 0..=c.len() {
                    out.push(B64[(n >> (18 - 6 * i) & 63) as usize] as char);
                }
            }
            out
        };
        let unb64url = |s: &str| -> Vec<u8> {
            let mut bits = 0u32;
            let mut n = 0;
            let mut out = vec![];
            for ch in s.bytes() {
                bits = bits << 6 | B64.iter().position(|&x| x == ch).unwrap() as u32;
                n += 6;
                if n >= 8 {
                    n -= 8;
                    out.push((bits >> n) as u8);
                }
            }
            out
        };
        let s = |k: &Value| k.as_str().unwrap().to_string();
        let public = |priv_: &str| format!("x25519:{}", hex::encode(h("crypto.x25519Public", json!({ "priv": priv_ }))));
        // sealWith: eph's public half, then ChaCha20-Poly1305 under HKDF(shared, eph ‖ to, "stillfail-vault-seal/1"), a nonce of zeros
        let seal_with = |to: &str, plain: &[u8], context: &str, eph: &str| -> String {
            let to = to.strip_prefix("x25519:").unwrap();
            let eph_pub = h("crypto.x25519Public", json!({ "priv": eph }));
            let shared = h("crypto.x25519", json!({ "priv": eph, "pub": to }));
            let key = h("crypto.hkdfSha256", json!({ "ikm": hex::encode(&shared), "salt": format!("{}{to}", hex::encode(&eph_pub)), "info": hex::encode("stillfail-vault-seal/1"), "length": 32 }));
            let body = h("crypto.chachaSeal", json!({ "key": hex::encode(key), "nonce": "00".repeat(12), "aad": hex::encode(context), "plain": hex::encode(plain) }));
            b64url(&[eph_pub, body].concat())
        };
        let open_seal = |priv_: &str, sealed: &str, context: &str| -> Value {
            let b = unb64url(sealed);
            let (eph_pub, body) = b.split_at(32);
            let shared = h("crypto.x25519", json!({ "priv": priv_, "pub": hex::encode(eph_pub) }));
            let me = h("crypto.x25519Public", json!({ "priv": priv_ }));
            let key = h("crypto.hkdfSha256", json!({ "ikm": hex::encode(&shared), "salt": format!("{}{}", hex::encode(eph_pub), hex::encode(me)), "info": hex::encode("stillfail-vault-seal/1"), "length": 32 }));
            op("crypto.chachaOpen", json!({ "key": hex::encode(key), "nonce": "00".repeat(12), "aad": hex::encode(context), "sealed": hex::encode(body) })).unwrap()
        };
        let recovery = |entropy: &str| -> String {
            let p = h("crypto.hkdfSha256", json!({ "ikm": entropy, "salt": "", "info": hex::encode("stillfail-vault-recovery/1"), "length": 32 }));
            hex::encode(p)
        };
        let ws = s(&v["ws"]);
        let vault = s(&v["vault"]["id"]);
        let key_ctx = format!("stillfail-vault-key/1\0{ws}\0{vault}\00");
        let vault_key = hex::decode(s(&v["vaultKey"])).unwrap();
        assert_eq!(public(&s(&v["box"]["priv"])), s(&v["box"]["pub"]));
        assert_eq!(public(&s(&v["requestBox"]["priv"])), s(&v["requestBox"]["pub"]));
        for r in v["recovery"].as_array().unwrap() {
            assert_eq!(public(&recovery(&s(&r["entropy"]))), s(&r["pub"]));
        }
        assert_eq!(seal_with(&s(&v["box"]["pub"]), &vault_key, &key_ctx, &s(&v["eph"]["wrap"])), s(&v["vault"]["keys"][0]["wrapped"]));
        assert_eq!(seal_with(&public(&recovery(&s(&v["recovery"][1]["entropy"]))), &vault_key, &key_ctx, &s(&v["eph"]["recovery"])), s(&v["vault"]["recovery"]));
        let grant_ctx = format!("stillfail-vault-grant/1\0{ws}\0{}", s(&v["grant"]["request"]));
        assert_eq!(seal_with(&s(&v["requestBox"]["pub"]), s(&v["plain"]).as_bytes(), &grant_ctx, &s(&v["eph"]["grant"])), s(&v["grant"]["secret"]));
        // an item's ciphertext: its nonce, then ChaCha20-Poly1305 under the vault key with its context as additional data
        let item_ctx = format!("stillfail-vault-item/1\0{ws}\0{vault}\0{}\00\00", s(&v["item"]["id"]));
        let body = h("crypto.chachaSeal", json!({ "key": s(&v["vaultKey"]), "nonce": s(&v["nonce"]), "aad": hex::encode(&item_ctx), "plain": hex::encode(s(&v["plain"])) }));
        assert_eq!(b64url(&[hex::decode(s(&v["nonce"])).unwrap(), body].concat()), s(&v["item"]["ct"]));
        // opened under their contexts, and under no other
        assert_eq!(open_seal(&s(&v["box"]["priv"]), &s(&v["vault"]["keys"][0]["wrapped"]), &key_ctx), json!(s(&v["vaultKey"])));
        assert_eq!(open_seal(&s(&v["box"]["priv"]), &s(&v["vault"]["keys"][0]["wrapped"]), &key_ctx.replace("\00", "\01")), Value::Null);
        assert_eq!(open_seal(&s(&v["requestBox"]["priv"]), &s(&v["grant"]["secret"]), &grant_ctx), json!(hex::encode(s(&v["plain"]))));
        assert_eq!(open_seal(&s(&v["box"]["priv"]), &s(&v["grant"]["secret"]), &grant_ctx), Value::Null);
        let ct = unb64url(&s(&v["item"]["ct"]));
        let opened = |aad: &str| op("crypto.chachaOpen", json!({ "key": s(&v["vaultKey"]), "nonce": hex::encode(&ct[..12]), "aad": hex::encode(aad), "sealed": hex::encode(&ct[12..]) })).unwrap();
        assert_eq!(opened(&item_ctx), json!(hex::encode(s(&v["plain"]))));
        assert_eq!(opened(&item_ctx.replace("\00\00", "\01\00")), Value::Null);
    }

    /// Known answers: SHA-256 and HMAC-SHA256 (RFC 4231 case 2), HKDF-SHA256 (RFC 5869 case 1), X25519 (RFC 7748 §6.1),
    /// ChaCha20-Poly1305 (RFC 8439 §2.8.2); and what each refuses.
    #[test]
    fn the_vaults_primitives_answer_as_their_specs() {
        let op = |op: &str, a: Value| super::vault_crypto(op, &a).map(Option::unwrap);
        assert_eq!(op("crypto.sha256", json!({ "data": hex::encode("abc") })).unwrap(), json!("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
        assert_eq!(op("crypto.hmacSha256", json!({ "key": hex::encode("Jefe"), "data": hex::encode("what do ya want for nothing?") })).unwrap(), json!("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"));
        assert_eq!(
            op("crypto.hkdfSha256", json!({ "ikm": "0b".repeat(22), "salt": "000102030405060708090a0b0c", "info": "f0f1f2f3f4f5f6f7f8f9", "length": 42 })).unwrap(),
            json!("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        );
        assert!(op("crypto.hkdfSha256", json!({ "ikm": "00", "salt": "", "info": "", "length": 0 })).is_err());
        assert!(op("crypto.hkdfSha256", json!({ "ikm": "00", "salt": "", "info": "", "length": 8161 })).is_err());
        let alice = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a";
        let bob = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb";
        assert_eq!(op("crypto.x25519Public", json!({ "priv": alice })).unwrap(), json!("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"));
        let shared = json!("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");
        assert_eq!(op("crypto.x25519", json!({ "priv": alice, "pub": "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f" })).unwrap(), shared);
        assert_eq!(op("crypto.x25519", json!({ "priv": bob, "pub": "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" })).unwrap(), shared);
        assert!(op("crypto.x25519", json!({ "priv": alice, "pub": "00".repeat(32) })).is_err());
        assert!(op("crypto.x25519", json!({ "priv": "00", "pub": "00".repeat(32) })).is_err());
        let key = "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f";
        let nonce = "070000004041424344454647";
        let aad = "50515253c0c1c2c3c4c5c6c7";
        let plain = hex::encode("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.");
        let sealed = op("crypto.chachaSeal", json!({ "key": key, "nonce": nonce, "aad": aad, "plain": plain })).unwrap();
        let sealed = sealed.as_str().unwrap();
        assert!(sealed.starts_with("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"));
        assert!(sealed.ends_with("1ae10b594f09e26a7e902ecbd0600691"));
        assert_eq!(op("crypto.chachaOpen", json!({ "key": key, "nonce": nonce, "aad": aad, "sealed": sealed })).unwrap(), json!(plain));
        assert_eq!(op("crypto.chachaOpen", json!({ "key": key, "nonce": nonce, "aad": "", "sealed": sealed })).unwrap(), Value::Null);
        assert_eq!(op("crypto.chachaOpen", json!({ "key": key, "nonce": nonce, "aad": aad, "sealed": "00" })).unwrap(), Value::Null);
        assert!(op("crypto.chachaSeal", json!({ "key": "00", "nonce": nonce, "aad": aad, "plain": "" })).is_err());
        assert!(op("crypto.chachaSeal", json!({ "key": key, "nonce": "00", "aad": aad, "plain": "" })).is_err());
        assert_eq!(super::vault_crypto("crypto.none", &json!({})).unwrap(), None);
    }

}
