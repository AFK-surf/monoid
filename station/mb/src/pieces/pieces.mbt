// A stream's lines put together from the pieces they come in (a runner's messages from the reads of its socket, a
// process's output from the runner's messages, station/mb/src/reader/agents.mbt), and what is written to a runner.

///|
/// What is held of a stream's line not ended yet, in the pieces it came in (a line of 34 MB comes from a runner as
/// 544 messages of 64 KB, and a runner's message in reads of any size): each piece looked through once for line ends,
/// and a line put together once, at its end. Joined again with each piece, a line of N bytes cost N²/64 KB of copying
/// and looking through (a station's reader at 8 GB for one such line, 2026-11-15).
pub(all) struct Pieces {
  parts : Array[Bytes]
  mut size : Int
}

///|
pub fn Pieces::new() -> Pieces {
  { parts: [], size: 0 }
}

///|
/// The lines `bytes` ends, each whole without its newline; what it does not end is held.
pub fn Pieces::lines(self : Pieces, bytes : Bytes) -> Array[Bytes] {
  let out = []
  let mut from = 0
  for i = 0; i < bytes.length(); i = i + 1 {
    if bytes[i] != b'\n' {
      continue
    }
    if self.parts.length() == 0 {
      out.push(bytes[from:i].to_bytes())
    } else {
      // (written once where it stays: no buffer copied again to be the line)
      let line = FixedArray::make(self.size + i - from, b'\x00')
      let mut at = 0
      for p in self.parts {
        line.blit_from_bytes(at, p, 0, p.length())
        at += p.length()
      }
      line.blit_from_bytes(at, bytes, from, i - from)
      self.parts.clear()
      self.size = 0
      out.push(line.unsafe_reinterpret_as_bytes())
    }
    from = i + 1
  }
  if from < bytes.length() {
    let rest = if from == 0 { bytes } else { bytes[from:].to_bytes() }
    self.parts.push(rest)
    self.size += rest.length()
  }
  out
}

///|
/// `bytes` then `tail` written to `out` as base64 (padded), as the bytes it is sent as: what a runner is given to write
/// (a prompt of MBs) not put together again as a string first.
pub fn base64_into(out : @buffer.Buffer, bytes : Bytes, tail : Bytes) -> Unit {
  let table = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  let n = bytes.length()
  let total = n + tail.length()
  let at = (i : Int) => (if i < n { bytes[i] } else { tail[i - n] }).to_int()
  let mut i = 0
  while i + 3 <= total {
    let v = (at(i) << 16) | (at(i + 1) << 8) | at(i + 2)
    out.write_byte(table[(v >> 18) & 63])
    out.write_byte(table[(v >> 12) & 63])
    out.write_byte(table[(v >> 6) & 63])
    out.write_byte(table[v & 63])
    i += 3
  }
  let left = total - i
  if left == 1 {
    let v = at(i) << 16
    out.write_byte(table[(v >> 18) & 63])
    out.write_byte(table[(v >> 12) & 63])
    out.write_byte(b'=')
    out.write_byte(b'=')
  } else if left == 2 {
    let v = (at(i) << 16) | (at(i + 1) << 8)
    out.write_byte(table[(v >> 18) & 63])
    out.write_byte(table[(v >> 12) & 63])
    out.write_byte(table[(v >> 6) & 63])
    out.write_byte(b'=')
  }
}
