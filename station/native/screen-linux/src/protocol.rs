// Binary pipe protocol shared with `station/src/screens/desktop.ts` (`HelperView`).
// Each message in either direction is a 5-byte big-endian header: `kind: u8`, `len: u32be`, followed by `len` payload bytes.

use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

// Messages from station -> helper
pub const IN_NEXT: u8 = 1;
pub const IN_KEYFRAME: u8 = 2;
pub const IN_INPUT: u8 = 3;
pub const IN_RATE: u8 = 7;
pub const IN_BOUNDS: u8 = 8;

// Messages from helper -> station
pub const OUT_INFO: u8 = 1;
pub const OUT_CONFIG: u8 = 2;
pub const OUT_FRAME: u8 = 3;
#[allow(dead_code)]
pub const OUT_EVENT: u8 = 4;
pub const OUT_CURSOR: u8 = 6;
pub const OUT_REGION: u8 = 7;
pub const OUT_CURSOR_IMAGE: u8 = 11;

pub const MAX_IN_MESSAGE: usize = 4 * 1024 * 1024;

/// Thread-safe writer for outbound protocol messages on stdout.
#[derive(Clone)]
pub struct Out(Arc<Mutex<std::io::Stdout>>);

impl Out {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(std::io::stdout())))
    }

    pub fn send(&self, kind: u8, payload: &[u8]) {
        let mut head = [0u8; 5];
        head[0] = kind;
        head[1..5].copy_from_slice(&(payload.len() as u32).to_be_bytes());
        let out = self.0.lock().unwrap();
        let mut out = out.lock();
        let _ = out
            .write_all(&head)
            .and_then(|_| out.write_all(payload))
            .and_then(|_| out.flush());
    }

    pub fn json(&self, kind: u8, value: serde_json::Value) {
        self.send(kind, value.to_string().as_bytes());
    }
}

/// Encode a `config` (kind 2) payload: `width (u32be) + height (u32be) + extra (avcC or empty for JPEG)`.
pub fn encode_config(width: u32, height: u32, extra: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + extra.len());
    out.extend_from_slice(&width.to_be_bytes());
    out.extend_from_slice(&height.to_be_bytes());
    out.extend_from_slice(extra);
    out
}

/// Encode a `frame` (kind 3) payload: `flags (u8, bit 0 = key) + ts_us (u64be) + data`.
pub fn encode_frame(key: bool, ts_us: u64, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(9 + data.len());
    out.push(if key { 1 } else { 0 });
    out.extend_from_slice(&ts_us.to_be_bytes());
    out.extend_from_slice(data);
    out
}

/// Read the next message `(kind, payload)` from `input`, or `None` on EOF or length > `limit`.
pub fn read_message(input: &mut impl Read, limit: usize) -> Option<(u8, Vec<u8>)> {
    let mut head = [0u8; 5];
    input.read_exact(&mut head).ok()?;
    let length = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
    if length > limit {
        return None;
    }
    let mut payload = vec![0u8; length];
    input.read_exact(&mut payload).ok()?;
    Some((head[0], payload))
}

/// Read the initial single-line JSON request from stdin.
pub fn request_line(input: &mut impl Read) -> Option<serde_json::Value> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        input.read_exact(&mut byte).ok()?;
        if byte[0] == b'\n' {
            break;
        }
        line.push(byte[0]);
        if line.len() > 64 * 1024 {
            return None;
        }
    }
    serde_json::from_slice(&line).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_request_and_messages() {
        let mut bytes = b"{\"codec\":\"h264\",\"maxWidth\":1280,\"maxHeight\":720}\n".to_vec();
        bytes.extend_from_slice(&[IN_NEXT, 0, 0, 0, 0]);
        bytes.extend_from_slice(&[IN_RATE, 0, 0, 0, 4, 0, 0x1e, 0x84, 0x80]);
        bytes.extend_from_slice(&[IN_INPUT, 0, 0, 0, 2, b'{', b'}']);
        let mut input = &bytes[..];
        let req = request_line(&mut input).unwrap();
        assert_eq!(req["codec"], "h264");
        assert_eq!(req["maxWidth"], 1280);
        assert_eq!(read_message(&mut input, 64), Some((IN_NEXT, vec![])));
        assert_eq!(
            read_message(&mut input, 64),
            Some((IN_RATE, vec![0, 0x1e, 0x84, 0x80]))
        );
        assert_eq!(read_message(&mut input, 64), Some((IN_INPUT, b"{}".to_vec())));
        assert_eq!(read_message(&mut input, 64), None);
    }

    #[test]
    fn rejects_oversized_message() {
        let bytes = [IN_INPUT, 0, 0, 1, 0];
        assert_eq!(read_message(&mut &bytes[..], 10), None);
    }

    #[test]
    fn encodes_config_and_frame() {
        let cfg = encode_config(1920, 1080, &[1, 2, 3]);
        assert_eq!(&cfg[..4], &1920u32.to_be_bytes());
        assert_eq!(&cfg[4..8], &1080u32.to_be_bytes());
        assert_eq!(&cfg[8..], &[1, 2, 3]);

        let frame = encode_frame(true, 123_456, &[0xaa, 0xbb]);
        assert_eq!(frame[0], 1);
        assert_eq!(&frame[1..9], &123_456u64.to_be_bytes());
        assert_eq!(&frame[9..], &[0xaa, 0xbb]);
    }
}
