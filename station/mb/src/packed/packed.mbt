// A transcript put away (station/src/sessions/archive.ts `packFile`, which asks this program, `--builder packed`,
// station/src/sessions/packed-mb.ts) is in segments as zork keeps a session's sealed events (HOOLC/zork
// docs/design/agent-runtime.md, SEGMENT-01): each about `segment` bytes of it, ending at the end of a line, compressed
// once. They are zstd frames of the one file the transcript is put away as (every reader finds it as `<file>.zst`), then
// a table of the frames' sizes (zstd's seekable format: a skippable frame, which zstd readers pass over). A page of a
// history, read from the mark before it, decompresses the segment or two it is in: not the whole transcript (one is 150
// MB) each time. One put away before the table (2026-11), or with its last segment stored as it is (0.1.6800 to 0.1.6802:
// most transcripts are one segment, so they were not compressed at all), is put away again (`segment`, sessions/cold.ts
// `segmentHistories`). What this file says is the format, byte for byte as station/test/reference/packed.ts (the
// TypeScript it replaced) writes and reads it, which station/test/mb-packed.test.ts holds it to; the bytes themselves
// are cut, compressed and read back by the shell (client/shell `zstd.segments`, `zstd.check`), never through here.

///|
/// How much of a transcript a frame holds.
pub let segment : Int = 16 << 20

///|
let frame_magic : Int64 = 0xfd2fb528L

///|
/// The frame header descriptor of a segment stored as it is (0.1.6800–0.1.6802): content size in 8 bytes, one segment.
let stored_descriptor : Int = 0xe0

///|
let skippable : Int64 = 0x184d2a5eL

///|
let seekable : Int64 = 0x8f92eab1L

///|
/// How long the table's footer is: the frames' count, its descriptor, the seekable magic.
pub let footer : Int = 9

///|
/// A frame of a put-away transcript: where it is in the file (`at`, `packed` bytes) and what it holds of the transcript
/// (`size` bytes from `from`).
priv struct Frame {
  at : Int64
  packed : Int64
  from : Int64
  size : Int64
}

///|
fn le32(b : BytesView, at : Int) -> Int64 {
  b[at].to_int64() | (b[at + 1].to_int64() << 8) | (b[at + 2].to_int64() << 16) | (b[at + 3].to_int64() << 24)
}

///|
fn put32(out : FixedArray[Byte], at : Int, v : Int64) -> Unit {
  for i in 0..<4 {
    out[at + i] = ((v >> (8 * i)) & 0xffL).to_byte()
  }
}

///|
/// The table that ends a put-away transcript: each frame's size in the file and of the transcript (`packed`, `size`).
pub fn seek_table(frames : Array[(Int64, Int64)]) -> Bytes {
  let length = 8 + frames.length() * 8 + footer
  let out = FixedArray::make(length, b'\x00')
  put32(out, 0, skippable)
  put32(out, 4, (length - 8).to_int64())
  for i, f in frames {
    put32(out, 8 + i * 8, f.0)
    put32(out, 12 + i * 8, f.1)
  }
  let end = 8 + frames.length() * 8
  put32(out, end, frames.length().to_int64())
  put32(out, end + 5, seekable)
  Bytes::from_array(out)
}

///|
/// How long the table at the end of a put-away transcript of `size` bytes is, and each entry of it, from its last
/// `footer` bytes: None without one.
pub fn table_length(size : Int64, foot : BytesView) -> (Int64, Int64)? {
  if size < 8L + footer.to_int64() ||
    foot.length() < footer ||
    le32(foot, 5) != seekable ||
    (foot[4].to_int() & 0x7f) != 0 {
    return None
  }
  let entry = if (foot[4].to_int() & 0x80) != 0 { 12L } else { 8L }
  let length = 8L + le32(foot, 0) * entry + footer.to_int64()
  if length > size {
    None
  } else {
    Some((length, entry))
  }
}

///|
/// The frames a table lists: None when they do not add up to the file of `size` bytes.
fn frames_in(size : Int64, table : BytesView, entry : Int64) -> Array[Frame]? {
  let length = table.length().to_int64()
  if length < 8L + footer.to_int64() ||
    le32(table, 0) != skippable ||
    le32(table, 4) != length - 8L {
    return None
  }
  let n = (length - 8L - footer.to_int64()) / entry
  let frames = []
  let mut at = 0L
  let mut from = 0L
  for i = 0L; i < n; i = i + 1L {
    let packed = le32(table, (8L + i * entry).to_int())
    let each = le32(table, (12L + i * entry).to_int())
    frames.push({ at, packed, from, size: each })
    at += packed
    from += each
  }
  if at == size - length {
    Some(frames)
  } else {
    None
  }
}

///|
/// Whether a frame whose first 5 bytes are `head` is a segment stored as it is (its header says one segment with its
/// content size and nothing else): one put away by 0.1.6800–0.1.6802, to be put away again compressed.
pub fn stored(head : BytesView) -> Bool {
  head.length() >= 5 && le32(head, 0) == frame_magic && head[4].to_int() == stored_descriptor
}
