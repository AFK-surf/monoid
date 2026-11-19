//! Remote screen frame tap (`istream.tap`): splits video/audio frames off an iroh stream directly to the host/app,
//! decoding Opus audio packets to PCM16 so neither video nor audio traverses the core's JS thread.

use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};

use crate::tally;

/// Where a tapped view's records go (ScreenTap::said): offered to the host (`media`), said to the app.
pub(crate) trait Tell {
    /// Record `kind` of view `call` offered to the host: whether it took it.
    fn media(&self, call: u64, kind: u8, key: bool, seq: u64, ts: u64, bytes: &[u8]) -> bool;
    /// A message for the app (its JSON, the bytes beside it).
    fn say(&self, json: &[u8], bytes: Option<&[u8]>);
}

/// The number of the next record said of a tapped view (`Media`'s `seq`): one count for all, so a view tapped again on
/// another stream (`screen.bounds`) goes on from where it was.
static MEDIA_SEQ: AtomicU64 = AtomicU64::new(1);

/// A remote screen's stream read in the shell (docs/remote-screens.md, Wire; client/core-ts screen-frames.ts): its
/// frames taken apart as its pieces come; a config, a video frame, the sound's config and its packets said to the app at
/// once as the core's progress of the view's call (`{id, value}`, the bytes beside it: what screens.ts says of them),
/// so they go through neither the core's JS nor its thread; the rest (its state, a clipboard, what is not one of them)
/// kept, as they came, for the core's next read, with a video frame's head alone the first time one comes after a
/// config (what tells the core the picture is live). Sound that comes as Opus (a view asked it: client/core-ts mesh.ts
/// `decodesOpus`) is decoded here, each packet into the 20 ms of PCM16 the hosts play, and said to the app as PCM.
pub(crate) struct ScreenTap {
    /// the app's call the view is (its progress' id)
    pub(crate) call: u64,
    /// what came and is not a whole frame yet
    pub(crate) pending: Vec<u8>,
    /// frames for the core, whole
    pub(crate) out: Vec<u8>,
    /// a video frame's head given the core since the last config
    told_video: bool,
    /// the view's sound is Opus (its config said so): what decodes it, and the capture time the next packet follows
    /// on from (0: none decoded since it was made)
    opus: Option<Box<opus_rs::OpusDecoder>>,
    opus_next: u64,
    /// The page takes the pointer alone (`cursorUpdates`): each `cursor` frame said to it from here, as screens.ts says
    /// it, and only the newest kept for the core, given it just before whatever it is given next (its next whole state
    /// says where the pointer is now, not where it was when the core last heard of it), so a pointer moving wakes
    /// neither the core's JS nor its thread.
    cursor_updates: bool,
    last_cursor: Option<Vec<u8>>,
}

const FRAME_CONFIG: u8 = 1;
const FRAME_VIDEO: u8 = 2;
const FRAME_AUDIO_CONFIG: u8 = 5;
const FRAME_AUDIO: u8 = 6;
const FRAME_CURSOR: u8 = 7;
/// A `cursor` frame's shape, at most (screen-frames.ts CURSOR_SHAPE_MAX).
const CURSOR_SHAPE_MAX: usize = 64;
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
    pub(crate) fn new(call: u64, cursor_updates: bool) -> Self {
        ScreenTap { call, pending: Vec::new(), out: Vec::new(), told_video: false, opus: None, opus_next: 0, cursor_updates, last_cursor: None }
    }

    /// Bytes for the core: the newest pointer not yet given it first.
    fn keep(&mut self, bytes: &[u8]) {
        if let Some(cursor) = self.last_cursor.take() {
            self.out.extend_from_slice(&cursor);
        }
        self.out.extend_from_slice(bytes);
    }

    /// A whole frame that came apart from the stream (as a datagram: screen_dgram.rs), said or kept as one on it is.
    pub(crate) fn whole(&mut self, kind: u8, body: &[u8], tell: &dyn Tell) {
        if !self.said(kind, body, tell) {
            let mut head = [kind, 0, 0, 0, 0];
            head[1..].copy_from_slice(&(body.len() as u32).to_be_bytes());
            self.keep(&head);
            self.out.extend_from_slice(body);
        }
    }

    /// What came next: its whole frames said or kept.
    pub(crate) fn take(&mut self, chunk: &[u8], tell: &dyn Tell) {
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
                self.keep(rest);
                at = data.len();
                break;
            }
            if rest.len() < 5 + len {
                break;
            }
            let (kind, body) = (rest[0], &rest[5..5 + len]);
            if !self.said(kind, body, tell) {
                self.keep(&rest[..5 + len]);
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
                    self.keep(&[FRAME_VIDEO, 0, 0, 0, 9]);
                    self.out.extend_from_slice(&body[..9]);
                }
                true
            }
            FRAME_CURSOR if self.cursor_updates => {
                // read as screen-frames.ts reads it, said as screens.ts says it
                let text = if body.is_empty() {
                    format!(r#"{{"id":{id},"value":{{"cursor":null}}}}"#)
                } else if (4..=4 + CURSOR_SHAPE_MAX).contains(&body.len()) {
                    let at = |hi: usize| ((u16::from_be_bytes([body[hi], body[hi + 1]]) as f64 / 65535.0) * 10000.0).round() / 10000.0;
                    let mut cursor = json!({ "x": at(0), "y": at(2) });
                    if body.len() > 4 {
                        let Ok(shape) = std::str::from_utf8(&body[4..]) else { return false };
                        cursor["shape"] = json!(shape);
                    }
                    serde_json::to_string(&json!({ "id": id, "value": { "cursor": cursor } })).unwrap_or_default()
                } else {
                    // (a length no station sends: passed over, as the core passes it over)
                    return true;
                };
                tell.say(text.as_bytes(), None);
                tally("tap.cursor");
                let mut kept = vec![FRAME_CURSOR];
                kept.extend((body.len() as u32).to_be_bytes());
                kept.extend_from_slice(body);
                self.last_cursor = Some(kept);
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

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
        let mut tap = ScreenTap::new(7, false);
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
            let mut again = ScreenTap::new(7, false);
            again.take(&wire[..cut], &told);
            again.take(&wire[cut..], &told);
            assert_eq!((told.said.lock().unwrap().len(), &again.out, again.pending.len()), (4, &core, 0));
        }
    }

    #[test]
    fn what_the_host_takes_of_a_tapped_screen_is_not_said() {
        // the host decodes and plays the frames and the sound itself: only the config said, the core's kept the same
        let told = Told { takes: vec![FRAME_VIDEO, FRAME_AUDIO], ..Told::default() };
        let mut tap = ScreenTap::new(3, false);
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
        let mut tap = ScreenTap::new(4, false);
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

    fn cursor(x: u16, y: u16, shape: &[u8]) -> Vec<u8> {
        let mut b = x.to_be_bytes().to_vec();
        b.extend(y.to_be_bytes());
        b.extend_from_slice(shape);
        frame(FRAME_CURSOR, &b)
    }

    #[test]
    fn a_pointer_moving_is_said_to_the_page_and_only_its_newest_kept_for_the_core() {
        let told = Told::default();
        let mut tap = ScreenTap::new(5, true);
        let mut wire = Vec::new();
        for i in 0..120u16 {
            wire.extend(cursor(i * 500, 65535 - i, if i % 2 == 0 { b"arrow" } else { b"" }));
        }
        wire.extend(frame(FRAME_CURSOR, &[]));
        wire.extend(cursor(32768, 13107, "手".as_bytes()));
        for piece in wire.chunks(5) {
            tap.take(piece, &told);
        }
        // the pointer alone moving: nothing for the core, so it is woken for none of it
        assert!(tap.out.is_empty());
        let said = told.said.lock().unwrap().clone();
        assert_eq!(said.len(), 122);
        assert_eq!(said[0].0, json!({ "id": 5, "value": { "cursor": { "x": 0.0, "y": 1.0, "shape": "arrow" } } }));
        assert_eq!(said[1].0, json!({ "id": 5, "value": { "cursor": { "x": 0.0076, "y": 1.0 } } }));
        assert_eq!(said[120].0, json!({ "id": 5, "value": { "cursor": null } }));
        assert_eq!(said[121].0, json!({ "id": 5, "value": { "cursor": { "x": 0.5, "y": 0.2, "shape": "手" } } }));
        assert!(said.iter().all(|s| s.1.is_none()));
        // a state comes: the core given the newest pointer just before it, and nothing older
        let state = frame(3, br#"{"title":"t"}"#);
        tap.take(&state, &told);
        let mut core = cursor(32768, 13107, "手".as_bytes());
        core.extend(&state);
        assert_eq!(tap.out, core);
        // a shape that is not UTF-8: the core's to pass over; a length no station sends: passed over here
        tap.out.clear();
        tap.take(&cursor(1, 1, &[0xff, 0xfe]), &told);
        tap.take(&frame(FRAME_CURSOR, &[1, 2]), &told);
        assert_eq!(tap.out, cursor(1, 1, &[0xff, 0xfe]));
        // a page that does not take it alone: every cursor frame the core's, as before
        let mut old = ScreenTap::new(6, false);
        old.take(&cursor(1, 2, b""), &told);
        assert_eq!(old.out, cursor(1, 2, b""));
    }
}
