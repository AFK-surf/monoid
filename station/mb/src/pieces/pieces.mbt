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
/// What is held of a line its stream ended without its newline (a process's last words, ended before it wrote one),
/// taken: None where nothing is held.
pub fn Pieces::rest(self : Pieces) -> Bytes? {
  if self.parts.length() == 0 {
    return None
  }
  let line = FixedArray::make(self.size, b'\x00')
  let mut at = 0
  for p in self.parts {
    line.blit_from_bytes(at, p, 0, p.length())
    at += p.length()
  }
  self.parts.clear()
  self.size = 0
  Some(line.unsafe_reinterpret_as_bytes())
}

///|
/// `bytes` then `tail` written to `out` as base64 (padded), as the bytes it is sent as: what a runner is given to write
/// (a prompt of MBs) not put together again as a string first.
pub fn base64_into(out : @buffer.Buffer, bytes : Bytes, tail : Bytes) -> Unit {
  // (`bytes` a whole number of 3s at a time, 48 KiB each, so no piece's base64 has padding; what is left of it with
  // `tail` last)
  let put = (text : String) => for c in text {
    out.write_byte(c.to_int().to_byte())
  }
  let whole = bytes.length() / 3 * 3
  let mut i = 0
  while i < whole {
    let end = if whole - i < 49152 { whole } else { i + 49152 }
    put(@codec.base64_encode(bytes[i:end]))
    i = end
  }
  let rest = Buffer(capacity=bytes.length() - whole + tail.length())
  rest.write_bytesview(bytes[whole:])
  rest.write_bytes(tail)
  put(@codec.base64_encode(rest.to_bytes()))
}
