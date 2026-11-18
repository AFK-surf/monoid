//! Outer datagrams can be smaller than an inner QUIC packet plus its route.
use crate::routing::{MAX_PACKET, Node};
use std::collections::BTreeMap;

const HEADER: usize = 14;
const CHUNK: usize = 900;
pub const MAX_FRAME: usize = MAX_PACKET + 1024;
const MAX_PARTS: usize = MAX_FRAME.div_ceil(CHUNK);
const MAX_PENDING: usize = 128;
const EXPIRE_MS: u64 = 2_000;

pub fn split(id: u64, bytes: &[u8]) -> Vec<Vec<u8>> {
    if bytes.is_empty() || bytes.len() > MAX_FRAME {
        return vec![];
    }
    let count = bytes.len().div_ceil(CHUNK);
    bytes
        .chunks(CHUNK)
        .enumerate()
        .map(|(index, part)| {
            let mut out = Vec::with_capacity(HEADER + part.len());
            out.extend_from_slice(b"M1");
            out.extend_from_slice(&id.to_be_bytes());
            out.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
            out.push(index as u8);
            out.push(count as u8);
            out.extend_from_slice(part);
            out
        })
        .collect()
}

struct Partial {
    until: u64,
    total: usize,
    parts: Vec<Option<Vec<u8>>>,
}
#[derive(Default)]
pub struct Reassembly {
    pending: BTreeMap<(Node, u64), Partial>,
}
impl Reassembly {
    pub fn receive(&mut self, from: Node, bytes: &[u8], now: u64) -> Option<Vec<u8>> {
        self.pending.retain(|_, p| p.until > now);
        if bytes.len() < HEADER || bytes.len() > HEADER + CHUNK || &bytes[..2] != b"M1" {
            return None;
        }
        let id = u64::from_be_bytes(bytes[2..10].try_into().unwrap());
        let total = u16::from_be_bytes(bytes[10..12].try_into().unwrap()) as usize;
        let index = bytes[12] as usize;
        let count = bytes[13] as usize;
        if total == 0
            || total > MAX_FRAME
            || count == 0
            || count > MAX_PARTS
            || count != total.div_ceil(CHUNK)
            || index >= count
        {
            return None;
        }
        let expected = if index + 1 == count {
            total - index * CHUNK
        } else {
            CHUNK
        };
        if bytes.len() - HEADER != expected {
            return None;
        }
        let key = (from, id);
        if !self.pending.contains_key(&key) && self.pending.len() >= MAX_PENDING {
            return None;
        }
        let p = self.pending.entry(key).or_insert_with(|| Partial {
            until: now.saturating_add(EXPIRE_MS),
            total,
            parts: vec![None; count],
        });
        if p.total != total || p.parts.len() != count {
            return None;
        }
        p.parts[index] = Some(bytes[HEADER..].to_vec());
        if p.parts.iter().any(Option::is_none) {
            return None;
        }
        let p = self.pending.remove(&key).unwrap();
        Some(p.parts.into_iter().flat_map(Option::unwrap).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reordered_fragments_are_bounded_and_peer_specific() {
        let bytes = vec![13; MAX_FRAME];
        let parts = split(2, &bytes);
        let mut r = Reassembly::default();
        for p in parts.iter().skip(1).rev() {
            assert!(r.receive([1; 32], p, 0).is_none());
        }
        assert!(r.receive([2; 32], &parts[0], 0).is_none());
        assert_eq!(r.receive([1; 32], &parts[0], 1), Some(bytes));
    }
    #[test]
    fn expiry_and_invalid_counts() {
        let parts = split(1, &vec![1; 1200]);
        let mut r = Reassembly::default();
        assert!(r.receive([1; 32], &parts[0], 0).is_none());
        assert!(r.receive([1; 32], &parts[1], EXPIRE_MS).is_none());
        let mut bad = parts[0].clone();
        bad[13] = 255;
        assert!(r.receive([1; 32], &bad, 0).is_none());
        assert_eq!(r.pending.len(), 1);
    }
}
