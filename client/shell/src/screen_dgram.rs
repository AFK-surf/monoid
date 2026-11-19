//! A remote screen's picture and sound as QUIC datagrams beside its stream (client/core-ts screen-frames.ts, Wire):
//! each video and audio frame the station writes on a view's stream goes instead as datagrams on the stream's
//! connection, cut into shards with Reed-Solomon parity (GF(2^8), a systematic Cauchy code), so a shard lost on the way
//! is made again from the others at once instead of waiting a round trip for QUIC to send it again, and a frame that
//! cannot be made whole is passed over rather than holding every frame after it. The rest (configs, states, the
//! clipboard, what the client sends) stays on the stream, in order.
//!
//! Shared by the native shell (`istream.*`: the apps receive, a MoonBit station or front sends) and the station's
//! addon (station/native/mesh: a station in TypeScript sends, a Node client receives), which takes this file by path.
//!
//! Both ends agree on it in the view's head (client/core-ts station/mesh-wire.ts `screen`): the client offers a token it
//! already routes its connection's datagrams to (`datagrams`), and the station that sends its frames so says
//! `x-screen-dgram` with it in its reply. A client or a station from before, a way with no datagrams (the browser's
//! iroh) or with too small ones, goes on the stream as before.
//!
//! A datagram: `HEADER_LEN` bytes, then one shard.
//! - 0: `MAGIC` (other datagrams on the connection, `conn.answers`' one byte, are passed over)
//! - 1: the frame's kind (bits 0..2: 2 video, 6 audio), bit 3 a key frame, bit 4 the previous audio packet carried too
//! - 2..6: the view's token (u32, big-endian, not 0)
//! - 6: how many configs of its kind the stream had carried when it was sent (`FRAME_CONFIG`, `FRAME_AUDIO_CONFIG`)
//! - 7..11: the frame's number among its kind's, from 1
//! - 11, 12: which block of the frame, of how many (a frame of more than `MAX_K` shards is cut into blocks)
//! - 13, 14: the block's data shards (k, 1..=MAX_K) and parity shards (m, 0..=MAX_M)
//! - 15: which shard: below k the block's bytes (their length first, u16 big-endian), from k on its parity
//!
//! The receiving end gives a frame on only in an order the decoder can take: a frame of the configs the stream has
//! carried (one of a config still coming waits for it), a key frame as soon as it is whole (whatever came before it no
//! longer matters), a frame after it only once the one before it was given. One that cannot be had (more shards lost
//! than its parity makes again) is never given: the frames after it waiting on it are dropped with it and the station
//! asked for a key frame (`KEYFRAME`, on the stream) instead of a picture made of a frame's missing references.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, Mutex as StdMutex, OnceLock, Weak};
use std::time::Duration;

use bytes::Bytes;
use iroh::endpoint::{Connection, SendDatagramError, SendStream};
use tokio::sync::mpsc;
use tokio::time::Instant;

pub(crate) const MAGIC: u8 = 0x53;
pub(crate) const HEADER_LEN: usize = 16;
/// The most data and parity shards of a block.
pub(crate) const MAX_K: usize = 48;
pub(crate) const MAX_M: usize = 24;
/// The most bytes of a frame a shard carries: under every path's MTU with room to spare (a relay's way).
const SHARD_MOST: usize = 1120;
/// A connection whose datagrams are smaller than this sends its frames on the stream.
pub(crate) const DATAGRAM_LEAST: usize = 1024;

const FRAME_CONFIG: u8 = 1;
const FRAME_VIDEO: u8 = 2;
const FRAME_AUDIO_CONFIG: u8 = 5;
const FRAME_AUDIO: u8 = 6;
/// What the client asks of the station when a frame could not be had (client/core-ts screen-frames.ts KEYFRAME).
pub(crate) const KEYFRAME_FRAME: [u8; 5] = [18, 0, 0, 0, 0];
/// A frame longer than this is no frame (screen-frames.ts MAX_FRAME): the stream is out of step, nothing is taken off it.
const FRAME_MAX: usize = 64 * 1024 * 1024;

const FLAG_KEY: u8 = 0x08;
const FLAG_RED: u8 = 0x10;

/// Frames of a kind kept while not yet given (the newest; the oldest goes first).
const WINDOW: usize = 8;
/// How long a frame's successor waits, whole, for the frame before it before that one is given up.
const GAP_WAIT: Duration = Duration::from_millis(6);
/// How long a frame not yet whole is waited for at most when nothing after it came (its shards come within ~4 ms).
const STALE: Duration = Duration::from_millis(40);
/// Key frames asked for no more often than this.
const KEYFRAME_EVERY: Duration = Duration::from_millis(200);
/// A key frame asked for and not come whole this long after (lost itself, and the screen still: no frame after it to
/// ask again on) is asked for again.
const KEYFRAME_RETRY: Duration = Duration::from_millis(500);
/// A frame's datagrams go 8 at a time, 250 µs apart, no longer than 4 ms in all (a burst of a key frame's 80 at once
/// fills a shallow router's queue and loses its tail). tokio's timer counts whole milliseconds, so a pause is at least
/// one: the 4 ms bound holds a frame to four pauses.
const PACE_EVERY: usize = 8;
const PACE_GAP: Duration = Duration::from_micros(250);
const PACE_MOST: Duration = Duration::from_millis(4);
/// How often the link's loss is read again for the parity a frame gets.
const LOSS_EVERY: Duration = Duration::from_millis(200);

// ---- GF(2^8), the polynomial 0x11d ----

const fn gf_tables() -> ([u8; 512], [u8; 256]) {
    let mut exp = [0u8; 512];
    let mut log = [0u8; 256];
    let mut x: u16 = 1;
    let mut i = 0;
    while i < 255 {
        exp[i] = x as u8;
        log[x as usize] = i as u8;
        x <<= 1;
        if x & 0x100 != 0 {
            x ^= 0x11d;
        }
        i += 1;
    }
    while i < 512 {
        exp[i] = exp[i - 255];
        i += 1;
    }
    (exp, log)
}

static GF: ([u8; 512], [u8; 256]) = gf_tables();

fn gf_mul(a: u8, b: u8) -> u8 {
    if a == 0 || b == 0 {
        return 0;
    }
    GF.0[GF.1[a as usize] as usize + GF.1[b as usize] as usize]
}

/// `a`'s inverse (`a` not 0).
fn gf_inv(a: u8) -> u8 {
    GF.0[255 - GF.1[a as usize] as usize]
}

/// Every product, a row a factor: a shard multiplied by a lookup a byte.
fn mul_table() -> &'static [[u8; 256]; 256] {
    static TABLE: OnceLock<Box<[[u8; 256]; 256]>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut t = Box::new([[0u8; 256]; 256]);
        for a in 0..256 {
            for b in 0..256 {
                t[a][b] = gf_mul(a as u8, b as u8);
            }
        }
        t
    })
}

/// `dst += c * src`, byte by byte.
fn mul_acc(dst: &mut [u8], src: &[u8], c: u8) {
    match c {
        0 => {}
        1 => dst.iter_mut().zip(src).for_each(|(d, s)| *d ^= s),
        _ => {
            let row = &mul_table()[c as usize];
            dst.iter_mut().zip(src).for_each(|(d, s)| *d ^= row[*s as usize]);
        }
    }
}

/// Parity row `i`'s factor of data shard `j`, of a block of `k`: a Cauchy matrix's, 1 / (x_i + y_j) with x_i = k + i
/// and y_j = j (all different), so every square part of it, and so of the identity over it, can be inverted: any k of
/// the k + m shards make the block again.
fn cauchy(i: usize, j: usize, k: usize) -> u8 {
    gf_inv(((k + i) as u8) ^ (j as u8))
}

/// The `m` parity shards of `data` (shards of one length).
pub(crate) fn rs_encode(data: &[Vec<u8>], m: usize) -> Vec<Vec<u8>> {
    let (k, len) = (data.len(), data.first().map_or(0, Vec::len));
    (0..m)
        .map(|i| {
            let mut p = vec![0u8; len];
            for (j, d) in data.iter().enumerate() {
                mul_acc(&mut p, d, cauchy(i, j, k));
            }
            p
        })
        .collect()
}

/// The `k` data shards of a block of `k + m`, from those that came (`shards[i]`, each `len` long): None while fewer
/// than `k` came.
pub(crate) fn rs_decode(k: usize, shards: &[Option<Vec<u8>>], len: usize) -> Option<Vec<Vec<u8>>> {
    if shards.iter().take(k).all(Option::is_some) {
        return Some(shards[..k].iter().map(|s| s.clone().unwrap()).collect());
    }
    // k of them, data first
    let chosen: Vec<usize> = (0..shards.len()).filter(|&i| shards[i].is_some()).take(k).collect();
    if chosen.len() < k {
        return None;
    }
    // the rows of the chosen shards, inverted (Gauss-Jordan)
    let mut a: Vec<Vec<u8>> = chosen.iter().map(|&i| (0..k).map(|j| if i < k { (i == j) as u8 } else { cauchy(i - k, j, k) }).collect()).collect();
    let mut inv: Vec<Vec<u8>> = (0..k).map(|i| (0..k).map(|j| (i == j) as u8).collect()).collect();
    for col in 0..k {
        let pivot = (col..k).find(|&r| a[r][col] != 0)?;
        a.swap(col, pivot);
        inv.swap(col, pivot);
        let scale = gf_inv(a[col][col]);
        for j in 0..k {
            a[col][j] = gf_mul(a[col][j], scale);
            inv[col][j] = gf_mul(inv[col][j], scale);
        }
        for r in 0..k {
            let f = a[r][col];
            if r != col && f != 0 {
                for j in 0..k {
                    a[r][j] ^= gf_mul(f, a[col][j]);
                    inv[r][j] ^= gf_mul(f, inv[col][j]);
                }
            }
        }
    }
    let mut out = Vec::with_capacity(k);
    for j in 0..k {
        match &shards[j] {
            Some(s) => out.push(s.clone()),
            None => {
                let mut d = vec![0u8; len];
                for (c, &i) in chosen.iter().enumerate() {
                    mul_acc(&mut d, shards[i].as_ref().unwrap(), inv[j][c]);
                }
                out.push(d);
            }
        }
    }
    Some(out)
}

// ---- What is sent ----

/// A datagram's head.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Head {
    pub(crate) kind: u8,
    pub(crate) key: bool,
    pub(crate) red: bool,
    pub(crate) token: u32,
    pub(crate) epoch: u8,
    pub(crate) seq: u32,
    pub(crate) block: u8,
    pub(crate) blocks: u8,
    pub(crate) k: u8,
    pub(crate) m: u8,
    pub(crate) shard: u8,
}

impl Head {
    fn put(&self, out: &mut Vec<u8>) {
        out.push(MAGIC);
        out.push((self.kind & 7) | if self.key { FLAG_KEY } else { 0 } | if self.red { FLAG_RED } else { 0 });
        out.extend(self.token.to_be_bytes());
        out.push(self.epoch);
        out.extend(self.seq.to_be_bytes());
        out.extend([self.block, self.blocks, self.k, self.m, self.shard]);
    }

    /// One of this protocol's heads, sound (None: another datagram, or one that is not).
    pub(crate) fn of(d: &[u8]) -> Option<Head> {
        if d.len() <= HEADER_LEN || d[0] != MAGIC {
            return None;
        }
        let h = Head {
            kind: d[1] & 7,
            key: d[1] & FLAG_KEY != 0,
            red: d[1] & FLAG_RED != 0,
            token: u32::from_be_bytes([d[2], d[3], d[4], d[5]]),
            epoch: d[6],
            seq: u32::from_be_bytes([d[7], d[8], d[9], d[10]]),
            block: d[11],
            blocks: d[12],
            k: d[13],
            m: d[14],
            shard: d[15],
        };
        let sound = (h.kind == FRAME_VIDEO || h.kind == FRAME_AUDIO)
            && h.token != 0
            && h.seq != 0
            && h.blocks >= 1
            && h.block < h.blocks
            && (1..=MAX_K as u8).contains(&h.k)
            && h.m <= MAX_M as u8
            && h.shard < h.k + h.m;
        sound.then_some(h)
    }
}

/// The parity a block of `k` data shards gets on a link that loses `loss` of its packets lately: one at least
/// (a single loss on Wi-Fi made good at once), up to a third of `k` as the loss grows; a key frame two at least.
pub(crate) fn parity_for(k: usize, key: bool, loss: f64) -> usize {
    let m = if loss > 0.005 {
        let m = ((k as f64) * (loss * 2.0 + 0.12).clamp(0.15, 0.35)).ceil() as usize;
        if key { m.max(2) } else { m.max(1) }
    } else if k == 1 {
        usize::from(key || loss > 0.0)
    } else {
        1
    };
    m.min(MAX_M)
}

/// The datagrams frame `body` of `kind` goes as (`seq` its number, `epoch` the configs before it), shards no longer
/// than `max_datagram` allows; `prev`: the audio packet before it, carried along where both fit one datagram (RFC 2198's
/// way: a packet lost is had with the next). None where it is too long for any (255 blocks).
#[allow(clippy::too_many_arguments)]
pub(crate) fn datagrams_of(token: u32, kind: u8, key: bool, epoch: u8, seq: u32, body: &[u8], prev: Option<&[u8]>, max_datagram: usize, loss: f64) -> Option<Vec<Vec<u8>>> {
    let cap = max_datagram.saturating_sub(HEADER_LEN + 2).min(SHARD_MOST);
    if cap == 0 {
        return None;
    }
    let head = |block: u8, blocks: u8, k: u8, m: u8, shard: u8, red: bool| Head { kind, key, red, token, epoch, seq, block, blocks, k, m, shard };
    if kind == FRAME_AUDIO && body.len() <= cap {
        let red = prev.filter(|p| body.len() + p.len() <= cap);
        let mut d = Vec::with_capacity(HEADER_LEN + 2 + body.len() + red.map_or(0, <[u8]>::len));
        head(0, 1, 1, 0, 0, red.is_some()).put(&mut d);
        d.extend((body.len() as u16).to_be_bytes());
        d.extend_from_slice(body);
        if let Some(p) = red {
            d.extend_from_slice(p);
        }
        return Some(vec![d]);
    }
    let n = body.len().div_ceil(cap).max(1);
    let blocks = n.div_ceil(MAX_K);
    if blocks > 255 {
        return None;
    }
    let (base, extra) = (n / blocks, n % blocks);
    let mut out = Vec::new();
    let mut shard_at = 0usize;
    for b in 0..blocks {
        let k = base + usize::from(b < extra);
        let m = if kind == FRAME_AUDIO { 1 } else { parity_for(k, key, loss) };
        let pieces: Vec<&[u8]> = (shard_at..shard_at + k).map(|s| &body[(s * cap).min(body.len())..((s + 1) * cap).min(body.len())]).collect();
        shard_at += k;
        let len = 2 + pieces.iter().map(|p| p.len()).max().unwrap_or(0);
        let data: Vec<Vec<u8>> = pieces
            .iter()
            .map(|p| {
                let mut d = Vec::with_capacity(len);
                d.extend((p.len() as u16).to_be_bytes());
                d.extend_from_slice(p);
                d.resize(len, 0);
                d
            })
            .collect();
        let parity = rs_encode(&data, m);
        for (i, shard) in data.iter().chain(parity.iter()).enumerate() {
            let mut d = Vec::with_capacity(HEADER_LEN + shard.len());
            head(b as u8, blocks as u8, k as u8, m as u8, i as u8, false).put(&mut d);
            // (a data shard goes without its padding: the parity's length says it where it is needed)
            let used = if i < k { 2 + pieces[i].len() } else { shard.len() };
            d.extend_from_slice(&shard[..used]);
            out.push(d);
        }
    }
    Some(out)
}

/// The share of packets a connection lost lately, across its paths (iroh's counters, read again each `LOSS_EVERY`).
#[derive(Default)]
pub(crate) struct LossMeter {
    last: Option<(Instant, u64, u64)>,
    rate: f64,
}

impl LossMeter {
    /// The rate from the counters now (`lost`, `sent`: totals since the connection opened).
    pub(crate) fn update(&mut self, now: Instant, lost: u64, sent: u64) -> f64 {
        match self.last {
            Some((at, _, _)) if now.duration_since(at) < LOSS_EVERY => {}
            Some((_, l, s)) => {
                let (dl, ds) = (lost.saturating_sub(l), sent.saturating_sub(s));
                if ds > 0 {
                    self.rate = (dl as f64 / ds as f64).min(1.0);
                }
                self.last = Some((now, lost, sent));
            }
            None => self.last = Some((now, lost, sent)),
        }
        self.rate
    }

    fn of(&mut self, conn: &Connection) -> f64 {
        let now = Instant::now();
        if matches!(self.last, Some((at, _, _)) if now.duration_since(at) < LOSS_EVERY) {
            return self.rate;
        }
        let (mut lost, mut sent) = (0u64, 0u64);
        for p in conn.paths().iter() {
            let s = p.stats();
            lost += s.lost_packets;
            sent += s.udp_tx.datagrams;
        }
        self.update(now, lost, sent)
    }
}

/// A view's stream, sending: what is written on it taken apart into its frames, its video and audio frames sent as
/// datagrams on its connection, the rest written on the stream as it came (the reply's head line first, whole).
pub(crate) struct MediaOut {
    token: u32,
    conn: Connection,
    line_done: bool,
    /// What came of a frame not whole yet.
    buf: Vec<u8>,
    /// Out of step (a frame no frame could be): everything on the stream from here.
    raw: bool,
    video_epoch: u8,
    audio_epoch: u8,
    video_seq: u32,
    audio_seq: u32,
    /// Its kind on the stream from now on (datagrams too small or refused): the client stops taking its datagrams.
    video_off: bool,
    audio_off: bool,
    prev_audio: Option<Vec<u8>>,
    loss: LossMeter,
    /// A test's: datagrams dropped before they go (each one with this chance, by a seeded draw), the loss the parity is
    /// made for, and no parity at all (to compare with).
    #[cfg(test)]
    pub(crate) lose: Option<(f64, u64)>,
    #[cfg(test)]
    pub(crate) assumed_loss: Option<f64>,
    #[cfg(test)]
    pub(crate) no_parity: bool,
}

impl MediaOut {
    /// None where the connection's datagrams are too small to be worth it (or none).
    pub(crate) fn new(conn: Connection, token: u32) -> Option<MediaOut> {
        if token == 0 || conn.max_datagram_size().is_none_or(|n| n < DATAGRAM_LEAST) {
            return None;
        }
        Some(MediaOut { token, conn, line_done: false, buf: Vec::new(), raw: false, video_epoch: 0, audio_epoch: 0, video_seq: 0, audio_seq: 0, video_off: false, audio_off: false, prev_audio: None, loss: LossMeter::default(), #[cfg(test)] lose: None, #[cfg(test)] assumed_loss: None, #[cfg(test)] no_parity: false })
    }

    /// `bytes` written: on the stream, or as datagrams where they are a frame of a picture or of sound.
    pub(crate) async fn write(&mut self, send: &mut SendStream, mut bytes: &[u8]) -> Result<(), String> {
        if !self.line_done {
            match bytes.iter().position(|&b| b == b'\n') {
                Some(at) => {
                    send.write_all(&bytes[..=at]).await.map_err(|e| e.to_string())?;
                    self.line_done = true;
                    bytes = &bytes[at + 1..];
                }
                None => return send.write_all(bytes).await.map_err(|e| e.to_string()),
            }
        }
        if self.raw {
            return send.write_all(bytes).await.map_err(|e| e.to_string());
        }
        let owned;
        let data: &[u8] = if self.buf.is_empty() {
            bytes
        } else {
            self.buf.extend_from_slice(bytes);
            owned = std::mem::take(&mut self.buf);
            &owned
        };
        let mut at = 0;
        // stream bytes not written yet, from `plain` to `at`
        let mut plain = 0;
        while data.len() - at >= 5 {
            let len = u32::from_be_bytes([data[at + 1], data[at + 2], data[at + 3], data[at + 4]]) as usize;
            if len > FRAME_MAX {
                self.raw = true;
                at = data.len();
                break;
            }
            if data.len() - at < 5 + len {
                break;
            }
            let (kind, body) = (data[at], &data[at + 5..at + 5 + len]);
            let media = match kind {
                FRAME_VIDEO => !self.video_off && body.len() >= 9,
                FRAME_AUDIO => !self.audio_off && body.len() > 8,
                FRAME_CONFIG => {
                    self.video_epoch = self.video_epoch.wrapping_add(1);
                    false
                }
                FRAME_AUDIO_CONFIG => {
                    self.audio_epoch = self.audio_epoch.wrapping_add(1);
                    self.prev_audio = None;
                    false
                }
                _ => false,
            };
            if media {
                if plain < at {
                    send.write_all(&data[plain..at]).await.map_err(|e| e.to_string())?;
                }
                if !self.send_media(kind, body).await? {
                    send.write_all(&data[at..at + 5 + len]).await.map_err(|e| e.to_string())?;
                }
                plain = at + 5 + len;
            }
            at += 5 + len;
        }
        if self.raw {
            at = data.len();
        }
        if plain < at {
            send.write_all(&data[plain..at]).await.map_err(|e| e.to_string())?;
        }
        if at < data.len() {
            self.buf = data[at..].to_vec();
        }
        Ok(())
    }

    /// Frame `body` of `kind` sent as datagrams: false where it goes on the stream (and its kind from now on).
    async fn send_media(&mut self, kind: u8, body: &[u8]) -> Result<bool, String> {
        let video = kind == FRAME_VIDEO;
        let off = |me: &mut MediaOut| {
            if video {
                me.video_off = true;
            } else {
                me.audio_off = true;
            }
            crate::tally(if video { "dgram.video.off" } else { "dgram.audio.off" });
            Ok(false)
        };
        let Some(max) = self.conn.max_datagram_size().filter(|&n| n >= DATAGRAM_LEAST) else { return off(self) };
        let loss = self.loss.of(&self.conn);
        #[cfg(test)]
        let loss = self.assumed_loss.unwrap_or(loss);
        let (seq, epoch) = if video {
            self.video_seq = self.video_seq.wrapping_add(1).max(1);
            (self.video_seq, self.video_epoch)
        } else {
            self.audio_seq = self.audio_seq.wrapping_add(1).max(1);
            (self.audio_seq, self.audio_epoch)
        };
        let key = video && body[0] & 1 == 1;
        let prev = if video { None } else { self.prev_audio.as_deref() };
        let Some(datagrams) = datagrams_of(self.token, kind, key, epoch, seq, body, prev, max, loss) else { return off(self) };
        #[cfg(test)]
        let datagrams: Vec<Vec<u8>> = datagrams
            .into_iter()
            .filter(|d| !self.no_parity || Head::of(d).is_some_and(|h| h.shard < h.k))
            .filter(|_| match &mut self.lose {
                Some((chance, state)) => {
                    *state ^= *state << 13;
                    *state ^= *state >> 7;
                    *state ^= *state << 17;
                    (*state % 1_000_000) as f64 / 1_000_000.0 >= *chance
                }
                None => true,
            })
            .collect();
        if !video {
            self.prev_audio = Some(body.to_vec());
        }
        let (start, total) = (Instant::now(), datagrams.len());
        for (i, d) in datagrams.into_iter().enumerate() {
            if i > 0 && i % PACE_EVERY == 0 && total > PACE_EVERY && start.elapsed() < PACE_MOST {
                tokio::time::sleep(PACE_GAP).await;
            }
            match self.conn.send_datagram_wait(Bytes::from(d)).await {
                Ok(()) => {}
                Err(SendDatagramError::ConnectionLost(e)) => return Err(e.to_string()),
                Err(_) => return off(self),
            }
        }
        crate::tally(if video { "dgram.video" } else { "dgram.audio" });
        Ok(true)
    }
}

// ---- What is received ----

/// A block of a frame as its shards come.
struct Block {
    k: usize,
    m: usize,
    shards: Vec<Option<Vec<u8>>>,
    have: usize,
    /// The parity's length (every data shard's padded to it): 0 until a parity shard came.
    len: usize,
    /// Its bytes, once had.
    data: Option<Vec<u8>>,
}

/// A frame as its blocks come.
struct Pending {
    key: bool,
    epoch: u8,
    blocks: Vec<Option<Block>>,
    done: usize,
    first: Instant,
    whole: Option<(Vec<u8>, Instant)>,
    /// The audio packet before it, carried along.
    prev: Option<Vec<u8>>,
}

impl Pending {
    fn new(h: &Head, now: Instant) -> Pending {
        Pending { key: h.key, epoch: h.epoch, blocks: (0..h.blocks).map(|_| None).collect(), done: 0, first: now, whole: None, prev: None }
    }

    /// A shard taken in; whether the frame is whole now.
    fn take(&mut self, h: &Head, shard: &[u8], now: Instant) -> bool {
        if self.whole.is_some() || h.blocks as usize != self.blocks.len() || h.key != self.key || h.epoch != self.epoch {
            return false;
        }
        let (k, m) = (h.k as usize, h.m as usize);
        let block = self.blocks[h.block as usize].get_or_insert_with(|| Block { k, m, shards: vec![None; k + m], have: 0, len: 0, data: None });
        if block.k != k || block.m != m || block.data.is_some() || block.shards[h.shard as usize].is_some() || shard.len() < 2 {
            return false;
        }
        let i = h.shard as usize;
        if i >= k {
            if block.len != 0 && block.len != shard.len() {
                return false;
            }
            block.len = shard.len();
        } else if h.red && k == 1 {
            // the packet, then the one before it
            let n = u16::from_be_bytes([shard[0], shard[1]]) as usize;
            if 2 + n > shard.len() {
                return false;
            }
            if 2 + n < shard.len() {
                self.prev = Some(shard[2 + n..].to_vec());
            }
            block.shards[i] = Some(shard[..2 + n].to_vec());
            block.have += 1;
            return self.block_whole(h.block as usize, now);
        }
        block.shards[i] = Some(shard.to_vec());
        block.have += 1;
        self.block_whole(h.block as usize, now)
    }

    fn block_whole(&mut self, b: usize, now: Instant) -> bool {
        let block = self.blocks[b].as_mut().unwrap();
        if block.have < block.k {
            return false;
        }
        let all_data = block.shards[..block.k].iter().all(Option::is_some);
        let shards = if all_data {
            block.shards[..block.k].iter().map(|s| s.clone().unwrap()).collect()
        } else {
            let len = block.len;
            let padded: Vec<Option<Vec<u8>>> = block
                .shards
                .iter()
                .enumerate()
                .map(|(i, s)| {
                    s.as_ref().map(|s| {
                        let mut s = s.clone();
                        if i < block.k {
                            s.resize(len, 0);
                        }
                        s
                    })
                })
                .collect();
            match rs_decode(block.k, &padded, len) {
                Some(d) => d,
                None => return false,
            }
        };
        let mut data = Vec::new();
        for s in &shards {
            let n = u16::from_be_bytes([s[0], s[1]]) as usize;
            if 2 + n > s.len() {
                // not made again as it was sent: the frame cannot be had
                block.shards.iter_mut().for_each(|s| *s = None);
                block.have = 0;
                return false;
            }
            data.extend_from_slice(&s[2..2 + n]);
        }
        if !all_data {
            crate::tally("dgram.recovered");
        }
        block.data = Some(data);
        block.shards = Vec::new();
        self.done += 1;
        if self.done < self.blocks.len() {
            return false;
        }
        let mut frame = Vec::new();
        for b in self.blocks.iter_mut() {
            frame.append(b.as_mut().unwrap().data.as_mut().unwrap());
        }
        self.whole = Some((frame, now));
        true
    }
}

/// A view's frames of one kind as they come.
#[derive(Default)]
struct Kind {
    pending: BTreeMap<u32, Pending>,
    /// The last given (0: none yet).
    last: u32,
    /// A frame was given up: none given until a key frame (video).
    broken: bool,
    /// The stream carries this kind now: its datagrams are passed over.
    closed: bool,
    /// Frames given, of a config the stream has not carried yet: held for it.
    held: VecDeque<(u8, Vec<u8>)>,
}

/// What a view's receiving end counts (a test's, and the shell's tallies).
#[derive(Default, Debug, Clone, Copy, PartialEq)]
pub(crate) struct Counts {
    pub(crate) video: u64,
    pub(crate) audio: u64,
    pub(crate) red: u64,
    pub(crate) given_up: u64,
    pub(crate) keyframes: u64,
}

/// A view's stream, receiving: its frames that come as datagrams (`datagram`) made whole again and put in order, each
/// given (`ready`) where the stream is between two of its frames (`stream` follows what the stream carries: its
/// configs, and where its frames start and end).
pub(crate) struct MediaIn {
    token: u32,
    line_done: bool,
    head: [u8; 5],
    head_have: usize,
    kind: u8,
    rem: usize,
    out_of_step: bool,
    video_epoch: u8,
    audio_epoch: u8,
    video: Kind,
    audio: Kind,
    /// Frames to give, whole (`[kind, length, body]` each), in order.
    pub(crate) ready: VecDeque<(u8, Vec<u8>)>,
    want_keyframe: bool,
    asked_keyframe: Option<Instant>,
    wait_from: Option<Instant>,
    pub(crate) counts: Counts,
}

/// `[kind, length (u32, big-endian), body]`.
#[cfg(test)]
pub(crate) fn frame_bytes(kind: u8, body: &[u8]) -> Vec<u8> {
    let mut f = Vec::with_capacity(5 + body.len());
    f.push(kind);
    f.extend((body.len() as u32).to_be_bytes());
    f.extend_from_slice(body);
    f
}

impl MediaIn {
    /// `line`: the stream's first line (its reply's head) is still to come.
    pub(crate) fn new(token: u32, line: bool) -> MediaIn {
        MediaIn {
            token,
            line_done: !line,
            head: [0; 5],
            head_have: 0,
            kind: 0,
            rem: 0,
            out_of_step: false,
            video_epoch: 0,
            audio_epoch: 0,
            video: Kind::default(),
            audio: Kind::default(),
            ready: VecDeque::new(),
            want_keyframe: false,
            asked_keyframe: None,
            wait_from: None,
            counts: Counts::default(),
        }
    }

    /// Whether what the stream carried so far ends between two of its frames.
    pub(crate) fn at_boundary(&self) -> bool {
        self.line_done && !self.out_of_step && self.rem == 0 && self.head_have == 0
    }

    /// What came next on the stream, followed: where the last place in it is that is between two frames (the frames
    /// ready go there), None where there is none.
    pub(crate) fn stream(&mut self, chunk: &[u8]) -> Option<usize> {
        let mut at = 0;
        if !self.line_done {
            at = chunk.iter().position(|&b| b == b'\n')? + 1;
            self.line_done = true;
        }
        if self.out_of_step {
            return None;
        }
        let mut boundary = self.at_boundary().then_some(at);
        while at < chunk.len() {
            if self.rem > 0 {
                let take = self.rem.min(chunk.len() - at);
                at += take;
                self.rem -= take;
                if self.rem == 0 {
                    self.frame_done();
                    boundary = Some(at);
                }
                continue;
            }
            self.head[self.head_have] = chunk[at];
            self.head_have += 1;
            at += 1;
            if self.head_have == 5 {
                self.head_have = 0;
                self.kind = self.head[0];
                let len = u32::from_be_bytes([self.head[1], self.head[2], self.head[3], self.head[4]]) as usize;
                if len > FRAME_MAX {
                    self.out_of_step = true;
                    return None;
                }
                self.rem = len;
                if len == 0 {
                    self.frame_done();
                    boundary = Some(at);
                }
            }
        }
        boundary
    }

    fn frame_done(&mut self) {
        match self.kind {
            FRAME_CONFIG => {
                self.video_epoch = self.video_epoch.wrapping_add(1);
                Self::config_came(&mut self.video, self.video_epoch, &mut self.ready, FRAME_VIDEO);
                self.wait_from = None;
            }
            FRAME_AUDIO_CONFIG => {
                self.audio_epoch = self.audio_epoch.wrapping_add(1);
                Self::config_came(&mut self.audio, self.audio_epoch, &mut self.ready, FRAME_AUDIO);
            }
            // (the station sends this kind on the stream now: what came of it as datagrams is no longer to be given)
            FRAME_VIDEO => Self::close(&mut self.video),
            FRAME_AUDIO => Self::close(&mut self.audio),
            _ => {}
        }
    }

    fn close(kind: &mut Kind) {
        kind.closed = true;
        kind.pending.clear();
        kind.held.clear();
    }

    /// A config of `kind` came on the stream (its `epoch` now): what was held for it given, what was of the one before
    /// dropped.
    fn config_came(kind: &mut Kind, epoch: u8, ready: &mut VecDeque<(u8, Vec<u8>)>, which: u8) {
        kind.pending.retain(|_, p| (p.epoch.wrapping_sub(epoch) as i8) >= 0);
        while let Some((e, _)) = kind.held.front() {
            match e.wrapping_sub(epoch) as i8 {
                0 => ready.push_back((which, kind.held.pop_front().unwrap().1)),
                d if d < 0 => {
                    kind.held.pop_front();
                }
                _ => break,
            }
        }
    }

    /// A datagram that came on the connection for this view.
    pub(crate) fn datagram(&mut self, d: &[u8], now: Instant) {
        let Some(h) = Head::of(d) else { return };
        if h.token != self.token {
            return;
        }
        let shard = &d[HEADER_LEN..];
        let video = h.kind == FRAME_VIDEO;
        let kind = if video { &mut self.video } else { &mut self.audio };
        if kind.closed || h.seq <= kind.last {
            return;
        }
        let whole = kind.pending.entry(h.seq).or_insert_with(|| Pending::new(&h, now)).take(&h, shard, now);
        // the oldest let go past the window
        let mut lost_next = false;
        while kind.pending.len() > WINDOW {
            let (&oldest, _) = kind.pending.iter().next().unwrap();
            kind.pending.remove(&oldest);
            lost_next |= video && oldest == kind.last.wrapping_add(1) && !kind.broken;
        }
        if lost_next {
            self.give_up();
        }
        if whole {
            if video {
                self.advance(now);
                if self.video.broken {
                    self.want_keyframe = true;
                }
            } else {
                self.audio_whole(h.seq);
            }
        }
    }

    fn audio_whole(&mut self, seq: u32) {
        let Some(mut p) = self.audio.pending.remove(&seq) else { return };
        let (frame, _) = p.whole.take().unwrap();
        if let Some(prev) = p.prev.take() {
            if seq > 1 && seq - 1 > self.audio.last {
                self.counts.red += 1;
                crate::tally("dgram.audio.red");
                self.gate(false, p.epoch, prev);
            }
        }
        self.audio.last = seq;
        self.audio.pending.retain(|&s, _| s > seq);
        self.counts.audio += 1;
        self.gate(false, p.epoch, frame);
    }

    /// Video frames given as far as they can be: in order from the last given, or from a key frame that came whole.
    fn advance(&mut self, now: Instant) {
        loop {
            let next = self.video.last.wrapping_add(1);
            if !self.video.broken && self.video.pending.get(&next).is_some_and(|p| p.whole.is_some()) {
                let p = self.video.pending.remove(&next).unwrap();
                self.give_video(next, p);
                continue;
            }
            let key = self.video.pending.iter().find(|(s, p)| p.key && p.whole.is_some() && **s > self.video.last).map(|(s, _)| *s);
            match key {
                Some(s) => {
                    let p = self.video.pending.remove(&s).unwrap();
                    self.video.pending.retain(|&q, _| q > s);
                    self.video.broken = false;
                    self.give_video(s, p);
                }
                None => break,
            }
        }
        if self.video.broken {
            return;
        }
        let next = self.video.last.wrapping_add(1);
        let after = self.video.pending.iter().filter(|(s, p)| **s > next && p.whole.is_some()).map(|(s, p)| (*s, p.whole.as_ref().unwrap().1)).last();
        match after {
            Some((s, _)) if s >= next.wrapping_add(2) => self.give_up(),
            Some((_, at)) => {
                let from = *self.wait_from.get_or_insert(at);
                if now.duration_since(from) >= GAP_WAIT {
                    self.give_up();
                }
            }
            None => {
                self.wait_from = None;
                if self.video.pending.get(&next).is_some_and(|p| now.duration_since(p.first) >= STALE) {
                    self.give_up();
                }
            }
        }
    }

    fn give_video(&mut self, seq: u32, mut p: Pending) {
        self.video.last = seq;
        self.wait_from = None;
        self.counts.video += 1;
        let (frame, _) = p.whole.take().unwrap();
        self.gate(true, p.epoch, frame);
    }

    /// The frame waited on cannot be had: none given until a key frame, which the station is asked for.
    fn give_up(&mut self) {
        self.video.broken = true;
        self.video.pending.retain(|_, p| p.key);
        self.wait_from = None;
        self.want_keyframe = true;
        self.counts.given_up += 1;
        crate::tally("dgram.video.lost");
    }

    /// A frame given where the stream has carried its config; held for it where it has not yet.
    fn gate(&mut self, video: bool, epoch: u8, frame: Vec<u8>) {
        let (kind, seen, which) = if video { (&mut self.video, self.video_epoch, FRAME_VIDEO) } else { (&mut self.audio, self.audio_epoch, FRAME_AUDIO) };
        let overflow = match epoch.wrapping_sub(seen) as i8 {
            0 if kind.held.is_empty() => {
                self.ready.push_back((which, frame));
                false
            }
            d if d < 0 => false,
            _ => {
                kind.held.push_back((epoch, frame));
                let over = kind.held.len() > WINDOW;
                if over {
                    kind.held.clear();
                }
                over
            }
        };
        if overflow && video {
            self.give_up();
        }
    }

    /// When `tick` is to be called next (a frame waited on given up then), if ever.
    pub(crate) fn deadline(&self) -> Option<Instant> {
        if self.video.closed {
            return None;
        }
        if self.video.broken {
            return if self.want_keyframe { None } else { self.asked_keyframe.map(|at| at + KEYFRAME_RETRY) };
        }
        let wait = self.wait_from.map(|w| w + GAP_WAIT);
        let stale = self.video.pending.get(&self.video.last.wrapping_add(1)).filter(|p| p.whole.is_none()).map(|p| p.first + STALE);
        match (wait, stale) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    pub(crate) fn tick(&mut self, now: Instant) {
        if self.video.closed {
            return;
        }
        if self.video.broken {
            if !self.want_keyframe && self.asked_keyframe.is_some_and(|at| now.duration_since(at) >= KEYFRAME_RETRY) {
                self.want_keyframe = true;
            }
            return;
        }
        self.advance(now);
    }

    /// Whether the station is to be asked for a key frame now (`KEYFRAME_FRAME` on the stream).
    pub(crate) fn take_keyframe(&mut self, now: Instant) -> bool {
        if !self.want_keyframe {
            return false;
        }
        if self.asked_keyframe.is_some_and(|at| now.duration_since(at) < KEYFRAME_EVERY) {
            // (asked lately: asked again only while still broken, once that long has gone)
            return false;
        }
        self.want_keyframe = false;
        self.asked_keyframe = Some(now);
        self.counts.keyframes += 1;
        true
    }

    /// The frames ready, whole, appended to `out`.
    pub(crate) fn drain_into(&mut self, out: &mut Vec<u8>) {
        while let Some((kind, body)) = self.ready.pop_front() {
            out.push(kind);
            out.extend((body.len() as u32).to_be_bytes());
            out.extend(body);
        }
    }
}

// ---- A connection's datagrams, to the views they are for ----

/// The datagrams a view's token is given at most while not taken (a reader that stopped): the newest are dropped.
const ROUTE_QUEUE: usize = 4096;

/// A connection's datagrams read once views ask for them (`route`), each given to the view its token names; others
/// (`conn.answers`' one byte, a view's gone) passed over. Read until the last view lets go.
pub(crate) struct Demux {
    routes: StdMutex<HashMap<u32, mpsc::Sender<Bytes>>>,
    task: StdMutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for Demux {
    fn drop(&mut self) {
        if let Some(task) = self.task.lock().unwrap().take() {
            task.abort();
        }
    }
}

/// A view's datagrams, given to it till this is dropped.
pub(crate) struct Route {
    demux: Arc<Demux>,
    token: u32,
}

impl Drop for Route {
    fn drop(&mut self) {
        self.demux.routes.lock().unwrap().remove(&self.token);
    }
}

/// The datagrams of `conn` for `token` (its connection's reader started where none is: `slot` holds it): None where
/// another view of it has that token.
pub(crate) fn route(slot: &StdMutex<Weak<Demux>>, conn: &Connection, token: u32) -> Option<(Route, mpsc::Receiver<Bytes>)> {
    if token == 0 {
        return None;
    }
    let demux = {
        let mut slot = slot.lock().unwrap();
        match slot.upgrade() {
            Some(d) => d,
            None => {
                let d = Arc::new(Demux { routes: StdMutex::default(), task: StdMutex::default() });
                let (weak, conn) = (Arc::downgrade(&d), conn.clone());
                let task = tokio::spawn(async move {
                    while let Ok(datagram) = conn.read_datagram().await {
                        let Some(demux) = weak.upgrade() else { break };
                        let Some(h) = Head::of(&datagram) else { continue };
                        let to = demux.routes.lock().unwrap().get(&h.token).cloned();
                        if let Some(to) = to {
                            let _ = to.try_send(datagram);
                        }
                    }
                });
                *d.task.lock().unwrap() = Some(task);
                *slot = Arc::downgrade(&d);
                d
            }
        }
    };
    let (to, rx) = mpsc::channel(ROUTE_QUEUE);
    {
        let mut routes = demux.routes.lock().unwrap();
        if routes.contains_key(&token) {
            return None;
        }
        routes.insert(token, to);
    }
    Some((Route { demux, token }, rx))
}

/// A view's receiving end at the shell or the addon: what it follows, and its datagrams.
pub(crate) struct MediaRx {
    pub(crate) media: MediaIn,
    pub(crate) rx: mpsc::Receiver<Bytes>,
    /// The route's channel ended (its connection's reader stopped): only the stream from here.
    pub(crate) rx_done: bool,
    pub(crate) _route: Route,
}

impl MediaRx {
    /// Every datagram waiting taken in.
    pub(crate) fn take_waiting(&mut self, first: Option<Bytes>, now: Instant) {
        match first {
            Some(d) => self.media.datagram(&d, now),
            None => self.rx_done = true,
        }
        while let Ok(d) = self.rx.try_recv() {
            self.media.datagram(&d, now);
        }
    }

    /// The next datagram (pending forever once the route ended).
    pub(crate) async fn next(&mut self) -> Option<Bytes> {
        if self.rx_done {
            return std::future::pending().await;
        }
        self.rx.recv().await
    }
}

/// Until `at` (forever where it is none: `MediaIn::deadline`).
pub(crate) async fn until(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn video_body(key: bool, ts: u64, len: usize, fill: u8) -> Vec<u8> {
        let mut b = vec![key as u8];
        b.extend(ts.to_be_bytes());
        b.extend((0..len).map(|i| (i as u8).wrapping_mul(31).wrapping_add(fill)));
        b
    }

    fn config(n: u8) -> Vec<u8> {
        frame_bytes(FRAME_CONFIG, format!(r#"{{"codec":"h264","width":{n}}}"#).as_bytes())
    }

    fn stream_of(media: &mut MediaIn, bytes: &[u8]) -> Vec<u8> {
        // what a read gives: the stream's bytes with the frames ready put at its last boundary
        let mut out = Vec::new();
        match media.stream(bytes) {
            Some(b) => {
                out.extend_from_slice(&bytes[..b]);
                media.drain_into(&mut out);
                out.extend_from_slice(&bytes[b..]);
            }
            None => out.extend_from_slice(bytes),
        }
        out
    }

    fn given(media: &mut MediaIn) -> Vec<(u8, Vec<u8>)> {
        media.ready.drain(..).collect()
    }

    #[test]
    fn reed_solomon_makes_a_block_again_from_any_k_of_its_shards() {
        let mut seed = 7u32;
        let mut rand = || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed
        };
        for (k, m) in [(1, 1), (2, 1), (5, 3), (16, 4), (48, 24), (48, 1), (3, 0)] {
            let data: Vec<Vec<u8>> = (0..k).map(|_| (0..97).map(|_| rand() as u8).collect()).collect();
            let parity = rs_encode(&data, m);
            let all: Vec<Vec<u8>> = data.iter().chain(parity.iter()).cloned().collect();
            for _ in 0..40 {
                // drop m of them, at random
                let mut shards: Vec<Option<Vec<u8>>> = all.iter().cloned().map(Some).collect();
                let mut dropped = 0;
                while dropped < m {
                    let i = rand() as usize % (k + m);
                    if shards[i].is_some() {
                        shards[i] = None;
                        dropped += 1;
                    }
                }
                assert_eq!(rs_decode(k, &shards, 97).as_ref(), Some(&data), "k {k} m {m}");
                // one more lost: not to be had
                if let Some(i) = (0..k + m).find(|&i| shards[i].is_some()) {
                    shards[i] = None;
                    assert_eq!(rs_decode(k, &shards, 97), None);
                }
            }
        }
    }

    #[test]
    fn the_parity_grows_with_the_loss() {
        assert_eq!(parity_for(1, false, 0.0), 0);
        assert_eq!(parity_for(1, true, 0.0), 1);
        assert_eq!(parity_for(1, false, 0.001), 1);
        assert_eq!(parity_for(20, false, 0.0), 1);
        assert_eq!(parity_for(20, false, 0.02), 4); // 20 * 0.16
        assert_eq!(parity_for(20, false, 0.05), 5); // 20 * 0.22
        assert_eq!(parity_for(2, true, 0.01), 2);
        assert_eq!(parity_for(48, false, 0.5), 17); // 48 * 0.35
        let mut meter = LossMeter::default();
        let t0 = Instant::now();
        assert_eq!(meter.update(t0, 0, 0), 0.0);
        assert_eq!(meter.update(t0 + Duration::from_millis(250), 5, 100), 0.05);
        // (read again only once LOSS_EVERY has gone)
        assert_eq!(meter.update(t0 + Duration::from_millis(300), 100, 100), 0.05);
        assert_eq!(meter.update(t0 + Duration::from_millis(500), 100, 200), 0.95);
        assert_eq!(meter.update(t0 + Duration::from_millis(750), 100, 300), 0.0);
    }

    /// A sequence of frames as datagrams (`loss` 0: one parity shard).
    fn send(token: u32, frames: &[(u8, bool, Vec<u8>)], epoch: u8, loss: f64) -> Vec<Vec<Vec<u8>>> {
        let (mut vs, mut aus) = (0u32, 0u32);
        let mut prev: Option<Vec<u8>> = None;
        frames
            .iter()
            .map(|(kind, key, body)| {
                let seq = if *kind == FRAME_VIDEO {
                    vs += 1;
                    vs
                } else {
                    aus += 1;
                    aus
                };
                let d = datagrams_of(token, *kind, *key, epoch, seq, body, if *kind == FRAME_AUDIO { prev.as_deref() } else { None }, 1200, loss).unwrap();
                if *kind == FRAME_AUDIO {
                    prev = Some(body.clone());
                }
                d
            })
            .collect()
    }

    #[test]
    fn frames_come_whole_whatever_shards_of_them_were_lost_within_their_parity() {
        let t = Instant::now();
        let mut media = MediaIn::new(9, false);
        assert_eq!(stream_of(&mut media, &config(1)), config(1));
        let bodies: Vec<Vec<u8>> = (0..5).map(|i| video_body(i == 0, i as u64, [70_000, 3_000, 900, 120_000, 5][i], i as u8)).collect();
        let frames: Vec<(u8, bool, Vec<u8>)> = bodies.iter().enumerate().map(|(i, b)| (FRAME_VIDEO, i == 0, b.clone())).collect();
        let sent = send(9, &frames, 1, 0.05);
        for dgrams in &sent {
            // each block loses as many as its parity: the first of each
            let mut lost_in: HashMap<u8, usize> = HashMap::new();
            for d in dgrams {
                let h = Head::of(d).unwrap();
                let lost = lost_in.entry(h.block).or_default();
                if *lost < h.m as usize && h.shard % 2 == 0 {
                    *lost += 1;
                    continue;
                }
                media.datagram(d, t);
            }
        }
        let got = given(&mut media);
        assert_eq!(got, bodies.iter().map(|b| (FRAME_VIDEO, b.clone())).collect::<Vec<_>>());
        assert_eq!(media.counts.given_up, 0);
        assert!(!media.take_keyframe(t));
    }

    #[test]
    fn other_datagrams_on_the_connection_are_passed_over() {
        let t = Instant::now();
        let mut media = MediaIn::new(9, false);
        stream_of(&mut media, &config(1));
        // conn.answers' probe, another view's, one cut short, one that says nonsense
        media.datagram(&[0], t);
        let other = send(10, &[(FRAME_VIDEO, true, video_body(true, 1, 10, 0))], 1, 0.0);
        for d in &other[0] {
            media.datagram(d, t);
        }
        let mine = send(9, &[(FRAME_VIDEO, true, video_body(true, 1, 10, 0))], 1, 0.0);
        media.datagram(&mine[0][0][..HEADER_LEN], t);
        let mut bad = mine[0][0].clone();
        bad[13] = 0;
        media.datagram(&bad, t);
        assert!(media.ready.is_empty());
        assert!(Head::of(&[0]).is_none());
        media.datagram(&mine[0][0], t);
        assert_eq!(given(&mut media).len(), 1);
    }

    #[test]
    fn a_frame_of_a_config_still_coming_waits_for_it() {
        let t = Instant::now();
        let mut media = MediaIn::new(3, true);
        let line = b"{\"status\":200}\n";
        let key = video_body(true, 1, 2000, 1);
        let p = video_body(false, 2, 100, 2);
        // the key frame of the first config comes before the config (its stream retransmitted)
        for d in send(3, &[(FRAME_VIDEO, true, key.clone()), (FRAME_VIDEO, false, p.clone())], 1, 0.0).iter().flatten() {
            media.datagram(d, t);
        }
        assert!(media.ready.is_empty(), "held for the config");
        // the stream: the reply's line, then the config cut in two
        let mut wire = line.to_vec();
        wire.extend(config(1));
        assert_eq!(stream_of(&mut media, &wire[..wire.len() - 3]), wire[..wire.len() - 3].to_vec());
        let out = stream_of(&mut media, &wire[wire.len() - 3..]);
        let mut want = wire[wire.len() - 3..].to_vec();
        want.extend(frame_bytes(FRAME_VIDEO, &key));
        want.extend(frame_bytes(FRAME_VIDEO, &p));
        assert_eq!(out, want, "given right after the config");
        // a frame of the config before, late: dropped
        let old = datagrams_of(3, FRAME_VIDEO, false, 0, 3, &video_body(false, 3, 10, 3), None, 1200, 0.0).unwrap();
        media.datagram(&old[0], t);
        assert!(media.ready.is_empty());
    }

    #[test]
    fn frames_are_put_between_the_streams_frames_never_inside_one() {
        let t = Instant::now();
        let mut media = MediaIn::new(3, false);
        stream_of(&mut media, &config(1));
        let state = frame_bytes(3, br#"{"title":"a long state"}"#);
        // half a state came
        assert_eq!(stream_of(&mut media, &state[..7]), state[..7].to_vec());
        assert!(!media.at_boundary());
        let key = video_body(true, 1, 10, 1);
        for d in send(3, &[(FRAME_VIDEO, true, key.clone())], 1, 0.0).iter().flatten() {
            media.datagram(d, t);
        }
        assert_eq!(media.ready.len(), 1, "ready, not given inside the state");
        // the rest of it and the start of another: given between the two
        let mut rest = state[7..].to_vec();
        rest.extend(&state[..2]);
        let out = stream_of(&mut media, &rest);
        let mut want = state[7..].to_vec();
        want.extend(frame_bytes(FRAME_VIDEO, &key));
        want.extend(&state[..2]);
        assert_eq!(out, want);
    }

    #[test]
    fn a_frame_lost_past_its_parity_is_never_given_and_a_key_frame_is_asked_for() {
        let t = Instant::now();
        let mut media = MediaIn::new(5, false);
        stream_of(&mut media, &config(1));
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..6).map(|i| (FRAME_VIDEO, i == 0 || i == 5, video_body(i == 0 || i == 5, i, 3000, i as u8))).collect();
        let sent = send(5, &frames, 1, 0.0);
        let take = |media: &mut MediaIn, i: usize, at: Instant| sent[i].iter().for_each(|d| media.datagram(d, at));
        take(&mut media, 0, t);
        take(&mut media, 1, t);
        // frame 3 (seq 3) loses two shards with one parity
        for d in sent[2].iter().skip(2) {
            media.datagram(d, t);
        }
        // 4 comes whole: waited 6 ms for 3
        take(&mut media, 3, t + Duration::from_millis(1));
        assert_eq!(given(&mut media).len(), 2);
        assert_eq!(media.deadline(), Some(t + Duration::from_millis(7)));
        media.tick(t + Duration::from_millis(7));
        assert_eq!(media.counts.given_up, 1);
        assert!(media.take_keyframe(t + Duration::from_millis(7)));
        // (asked once in KEYFRAME_EVERY)
        take(&mut media, 4, t + Duration::from_millis(8));
        assert!(!media.take_keyframe(t + Duration::from_millis(8)));
        assert!(media.ready.is_empty(), "nothing given that lost its reference");
        // the key frame: given at once, and on from it
        take(&mut media, 5, t + Duration::from_millis(30));
        assert_eq!(given(&mut media), vec![(FRAME_VIDEO, frames[5].2.clone())]);
        assert!(!media.video.broken);
    }

    #[test]
    fn a_key_frame_lost_itself_on_a_still_screen_is_asked_for_again() {
        let t = Instant::now();
        let ms = |n: u64| t + Duration::from_millis(n);
        let mut media = MediaIn::new(5, false);
        stream_of(&mut media, &config(1));
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..5).map(|i| (FRAME_VIDEO, i == 0 || i >= 3, video_body(i == 0 || i >= 3, i, 3000, i as u8))).collect();
        let sent = send(5, &frames, 1, 0.0);
        sent[0].iter().for_each(|d| media.datagram(d, t));
        // 2 loses two shards with one parity, 3 comes whole: 2 given up 6 ms on, a key frame asked for
        sent[1].iter().skip(2).for_each(|d| media.datagram(d, t));
        sent[2].iter().for_each(|d| media.datagram(d, t));
        media.tick(ms(7));
        assert_eq!(media.counts.given_up, 1);
        assert!(media.take_keyframe(ms(7)));
        // the key frame sent for it loses past its parity too, and then the screen is still: nothing more comes
        for d in sent[3].iter().skip(2) {
            media.datagram(d, ms(20));
        }
        assert!(!media.take_keyframe(ms(20)));
        assert_eq!(media.deadline(), Some(ms(507)), "asked again KEYFRAME_RETRY after");
        media.tick(ms(400));
        assert!(!media.take_keyframe(ms(400)));
        media.tick(ms(507));
        assert_eq!(media.deadline(), None, "nothing waited for until it is asked");
        assert!(media.take_keyframe(ms(507)));
        assert_eq!(media.deadline(), Some(ms(1007)));
        // the next key frame comes whole: given, and nothing more to wait for
        sent[4].iter().for_each(|d| media.datagram(d, ms(530)));
        assert_eq!(given(&mut media).into_iter().map(|g| g.1).collect::<Vec<_>>(), vec![frames[0].2.clone(), frames[4].2.clone()]);
        assert_eq!(media.deadline(), None);
        assert!(!media.take_keyframe(ms(530)));
    }

    #[test]
    fn a_key_frame_whole_is_given_at_once_over_what_is_missing_before_it() {
        let t = Instant::now();
        let mut media = MediaIn::new(5, false);
        stream_of(&mut media, &config(1));
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..4).map(|i| (FRAME_VIDEO, i == 0 || i == 2, video_body(i == 0 || i == 2, i, 500, 0))).collect();
        let sent = send(5, &frames, 1, 0.0);
        sent[0].iter().for_each(|d| media.datagram(d, t));
        // 2 never comes; the key frame 3 does, and 4 after it
        sent[2].iter().for_each(|d| media.datagram(d, t));
        sent[3].iter().for_each(|d| media.datagram(d, t));
        assert_eq!(given(&mut media).into_iter().map(|g| g.1).collect::<Vec<_>>(), vec![frames[0].2.clone(), frames[2].2.clone(), frames[3].2.clone()]);
        assert_eq!(media.counts.given_up, 0);
    }

    #[test]
    fn two_frames_on_whole_before_the_one_waited_on_give_it_up_at_once() {
        let t = Instant::now();
        let mut media = MediaIn::new(5, false);
        stream_of(&mut media, &config(1));
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..4).map(|i| (FRAME_VIDEO, i == 0, video_body(i == 0, i, 500, 0))).collect();
        let sent = send(5, &frames, 1, 0.0);
        sent[0].iter().for_each(|d| media.datagram(d, t));
        sent[2].iter().for_each(|d| media.datagram(d, t));
        sent[3].iter().for_each(|d| media.datagram(d, t));
        assert_eq!(media.counts.given_up, 1);
        assert_eq!(given(&mut media).len(), 1);
        assert!(media.take_keyframe(t));
    }

    #[test]
    fn opus_carries_the_packet_before_it_so_one_lost_is_had_with_the_next() {
        let t = Instant::now();
        let mut media = MediaIn::new(4, false);
        let ac = frame_bytes(FRAME_AUDIO_CONFIG, br#"{"codec":"opus","sampleRate":48000,"channels":2}"#);
        stream_of(&mut media, &ac);
        let packets: Vec<(u8, bool, Vec<u8>)> = (0..5u64).map(|i| {
            let mut b = (i * 20_000).to_be_bytes().to_vec();
            b.extend(vec![i as u8; 160]);
            (FRAME_AUDIO, false, b)
        }).collect();
        let sent = send(4, &packets, 1, 0.0);
        assert!(sent.iter().all(|d| d.len() == 1), "one datagram each");
        for (i, d) in sent.iter().enumerate() {
            if i == 2 {
                continue;
            }
            media.datagram(&d[0], t);
        }
        assert_eq!(given(&mut media).into_iter().map(|g| g.1).collect::<Vec<_>>(), packets.iter().map(|p| p.2.clone()).collect::<Vec<_>>());
        assert_eq!(media.counts.red, 1);
        // PCM's packets: cut in four with a parity shard
        let mut pcm = 9u64.to_be_bytes().to_vec();
        pcm.extend(vec![7u8; 3840]);
        let d = datagrams_of(4, FRAME_AUDIO, false, 1, 6, &pcm, None, 1200, 0.0).unwrap();
        assert_eq!(d.len(), 5);
        for x in d.iter().skip(1) {
            media.datagram(x, t);
        }
        assert_eq!(given(&mut media), vec![(FRAME_AUDIO, pcm)]);
    }

    #[test]
    fn a_kind_the_stream_carries_again_is_no_longer_taken_as_datagrams() {
        let t = Instant::now();
        let mut media = MediaIn::new(4, false);
        stream_of(&mut media, &config(1));
        let sent = send(4, &[(FRAME_VIDEO, true, video_body(true, 1, 5000, 1))], 1, 0.0);
        media.datagram(&sent[0][0], t);
        let on_stream = frame_bytes(FRAME_VIDEO, &video_body(false, 2, 4, 0));
        assert_eq!(stream_of(&mut media, &on_stream), on_stream);
        for d in &sent[0] {
            media.datagram(d, t);
        }
        assert!(media.ready.is_empty());
    }
}
