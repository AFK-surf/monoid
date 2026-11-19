// A folder put into a zip (zip.ts), for a member to send it in a chat as one file (drive `stage`) or to download it
// (drive `zip`): every file under it, deflated, named by its path in the folder (under the folder's own name), with
// its time. Links are not followed, and what `skip` names (the station's own data, uploads not finished) is left out.
// No zip64: at most `most` bytes read in all, and at most MAX_ENTRIES entries. The folder is read as `fs` reaches it;
// the zip is the station's own file, written as it goes, a file's header filled in once the file is read. One that
// deflate does not make smaller is stored as it is: kept where it was one chunk, else read again.
//
// The deflate here is the program's own (LZ77 over a 32 KB window of each chunk, fixed Huffman codes), not zlib's: its
// bytes are not Node's deflateRaw's, but they inflate to the same, and the zip's structure, names, times, CRCs,
// methods (but where the two deflates disagree on whether a file shrinks) and stored files are the same, byte for byte.

///|
/// zip.ts `TooBig`.
pub(all) suberror TooBig

///|
pub impl Show for TooBig with output(_, logger) {
  logger.write_string("zip archive exceeds size limit")
}

///|
/// What one read of a file gives at most.
pub let zip_chunk : Int = 262144

///|
/// Folders below the top gone into at most.
pub let max_depth : Int = 64

///|
/// Entries at most (a zip without zip64 counts them in 16 bits).
pub let max_entries : Int = 65535

// ── CRC-32 ──────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// zlib's crc32(chunk, crc): `crc` rolled on over `b`.
pub fn crc32(b : Bytes, crc : UInt) -> UInt {
  @codec.crc32_update(crc, b[:])
}

// ── deflate ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// Bits written least first, as deflate packs them.
priv struct Bits {
  out : @buffer.Buffer
  mut acc : UInt
  mut n : Int
}

///|
fn Bits::put(self : Bits, value : UInt, count : Int) -> Unit {
  self.acc = self.acc | (value << self.n)
  self.n += count
  while self.n >= 8 {
    self.out.write_byte((self.acc & 0xFFU).to_byte())
    self.acc = self.acc >> 8
    self.n -= 8
  }
}

///|
/// A Huffman code, given most significant bit first, written as deflate wants it.
fn Bits::code(self : Bits, code : Int, len : Int) -> Unit {
  let mut r = 0
  for i = 0; i < len; i = i + 1 {
    r = (r << 1) | ((code >> i) & 1)
  }
  self.put(r.reinterpret_as_uint(), len)
}

///|
fn Bits::lit(self : Bits, c : Int) -> Unit {
  if c < 144 {
    self.code(0x30 + c, 8)
  } else if c < 256 {
    self.code(0x190 + c - 144, 9)
  } else if c < 280 {
    self.code(c - 256, 7)
  } else {
    self.code(0xC0 + c - 280, 8)
  }
}

///|
let len_base : Array[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let len_extra : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5,
  0,
]

///|
let dist_base : Array[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
  1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let dist_extra : Array[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
fn Bits::length_dist(self : Bits, len : Int, dist : Int) -> Unit {
  let mut i = 28
  while len_base[i] > len {
    i -= 1
  }
  self.lit(257 + i)
  if len_extra[i] > 0 {
    self.put((len - len_base[i]).reinterpret_as_uint(), len_extra[i])
  }
  let mut d = 29
  while dist_base[d] > dist {
    d -= 1
  }
  self.code(d, 5)
  if dist_extra[d] > 0 {
    self.put((dist - dist_base[d]).reinterpret_as_uint(), dist_extra[d])
  }
}

///|
/// A raw deflate stream made a chunk at a time: each chunk a block of fixed codes, the stream ended by an empty one.
pub struct Deflater {
  priv bits : Bits
}

///|
pub fn Deflater::new() -> Deflater {
  { bits: { out: @buffer.new(), acc: 0U, n: 0 } }
}

///|
/// What was made of it so far (taken).
fn Deflater::take(self : Deflater) -> Bytes {
  let b = self.bits.out.to_bytes()
  self.bits.out.reset()
  b
}

///|
/// `data` deflated as one block; what of the stream is made by now.
pub fn Deflater::push(self : Deflater, data : Bytes) -> Bytes {
  let bits = self.bits
  bits.put(0U, 1) // not the last
  bits.put(1U, 2) // fixed codes
  let n = data.length()
  let hash_size = 1 << 15
  let head = FixedArray::make(hash_size, -1)
  let prev = FixedArray::make(n, -1)
  let hash = (i : Int) => ((data[i].to_int() << 10) ^
    (data[i + 1].to_int() << 5) ^
    data[i + 2].to_int()) &
    (hash_size - 1)
  let mut i = 0
  while i < n {
    let mut best_len = 0
    let mut best_dist = 0
    if i + 2 < n {
      let h = hash(i)
      let mut cand = head[h]
      let mut chain = 128
      while cand >= 0 && i - cand <= 32768 && chain > 0 {
        let mut l = 0
        let most = if n - i < 258 { n - i } else { 258 }
        while l < most && data[cand + l] == data[i + l] {
          l += 1
        }
        if l > best_len {
          best_len = l
          best_dist = i - cand
          if l == most {
            break
          }
        }
        cand = prev[cand]
        chain -= 1
      }
      prev[i] = head[h]
      head[h] = i
    }
    if best_len >= 3 {
      bits.length_dist(best_len, best_dist)
      for k = i + 1; k < i + best_len; k = k + 1 {
        if k + 2 < n {
          let h = hash(k)
          prev[k] = head[h]
          head[h] = k
        }
      }
      i += best_len
    } else {
      bits.lit(data[i].to_int())
      i += 1
    }
  }
  bits.lit(256)
  self.take()
}

///|
/// The stream ended: an empty last block, its last byte.
pub fn Deflater::finish(self : Deflater) -> Bytes {
  let bits = self.bits
  bits.put(1U, 1)
  bits.put(1U, 2)
  bits.lit(256)
  if bits.n > 0 {
    bits.out.write_byte((bits.acc & 0xFFU).to_byte())
    bits.acc = 0U
    bits.n = 0
  }
  self.take()
}

// ── the zip ─────────────────────────────────────────────────────────────────────────────────────────────────────

///|
priv struct ZipEntry {
  name : Bytes
  mut crc : UInt
  mut size : Double
  mut packed : Double
  mut method : Int
  at : Double
  time : Int
  date : Int
}

///|
/// A time as DOS has it (2-second steps, local time, 1980 through 2107).
pub fn dos(ms : Double) -> (Int, Int) {
  let first = local_midnight(1980, 0, 1)
  let last = local_midnight(2108, 0, 1) - 1.0
  let d = if ms < first {
    first
  } else if ms > last {
    last
  } else {
    ms
  }
  let (y, mo, day, h, mi, s) = local_time(d)
  ((h << 11) | (mi << 5) | (s / 2), ((y - 1980) << 9) | ((mo + 1) << 5) | day)
}

///|
fn le16(b : @buffer.Buffer, v : Int) -> Unit {
  b.write_byte((v & 0xFF).to_byte())
  b.write_byte(((v >> 8) & 0xFF).to_byte())
}

///|
fn le32(b : @buffer.Buffer, v : UInt) -> Unit {
  b.write_byte((v & 0xFFU).to_byte())
  b.write_byte(((v >> 8) & 0xFFU).to_byte())
  b.write_byte(((v >> 16) & 0xFFU).to_byte())
  b.write_byte(((v >> 24) & 0xFFU).to_byte())
}

///|
fn u32(d : Double) -> UInt {
  d.to_uint64().to_uint()
}

///|
fn local_header(e : ZipEntry) -> Bytes {
  let h = @buffer.new()
  le32(h, 0x04034b50U)
  le16(h, 20)
  le16(h, 0x0800)
  le16(h, e.method)
  le16(h, e.time)
  le16(h, e.date)
  le32(h, e.crc)
  le32(h, u32(e.packed))
  le32(h, u32(e.size))
  le16(h, e.name.length())
  le16(h, 0)
  h.to_bytes()
}

///|
/// The zip file being written: bytes at a place.
priv struct Out {
  path : String
}

///|
fn Out::at(self : Out, b : Bytes, at : Double) -> Unit raise {
  write_part(self.path, {
    create: false,
    offset: at,
    data: b,
    at_least: None,
    truncate: None,
    sync: false,
  })
  |> ignore
}

///|
fn Out::truncate(self : Out, at : Double) -> Unit raise {
  write_part(self.path, {
    create: false,
    offset: at,
    data: b"",
    at_least: None,
    truncate: Some(at),
    sync: false,
  })
  |> ignore
}

///|
fn Out::sync(self : Out, at : Double) -> Unit raise {
  write_part(self.path, {
    create: false,
    offset: at,
    data: b"",
    at_least: None,
    truncate: None,
    sync: true,
  })
  |> ignore
}

///|
priv struct Frame {
  path : String
  name : String
  names : Array[String]
  mut next : Int
}

///|
/// zip.ts `zipFolder`: `dir` as a zip at `to` (made new; it must not be there). Answers the zip's size.
pub fn zip_folder(
  dir : String,
  to : String,
  most : Double,
  skip : (String, String) -> Bool raise,
  fs : Fs,
) -> Double raise {
  create_excl(to, "")
  let out : Out = { path: to }
  let mut at = 0.0
  let mut read = 0.0
  let entries : Array[ZipEntry] = []
  let write = (b : Bytes) => {
    out.at(b, at)
    at = at + b.length().to_double()
  }
  let entry = (name : String, mtime : Double) => {
    if entries.length() >= max_entries {
      raise TooBig
    }
    let (time, date) = dos(mtime)
    let e : ZipEntry = {
      name: @utf8.encode(name),
      crc: 0U,
      size: 0.0,
      packed: 0.0,
      method: 0,
      at,
      time,
      date,
    }
    e
  }
  let folder = (name : String, mtime : Double) => {
    let e = entry(name, mtime)
    write(local_header(e))
    write(e.name)
    entries.push(e)
  }
  /// A file's chunks, counted against `most`, its CRC rolled on; `each` given each.
  let counted = (path : String, each : (Bytes) -> Unit raise) => {
    let mut crc = 0U
    let mut size = 0.0
    let mut first : Bytes? = None
    let mut off = 0.0
    while true {
      let (bytes, _, _) = (fs.read)(path, off, zip_chunk.to_double())
      if bytes.length() > 0 {
        read = read + bytes.length().to_double()
        if read > most {
          raise TooBig
        }
        crc = crc32(bytes, crc)
        first = if size == 0.0 { Some(bytes) } else { None }
        size = size + bytes.length().to_double()
        each(bytes)
      }
      if bytes.length() < zip_chunk {
        break
      }
      off = off + bytes.length().to_double()
    }
    (crc, size, first)
  }
  let file = (name : String, path : String, mtime : Double) => {
    let e = entry(name, mtime)
    let data = at + 30.0 + e.name.length().to_double()
    at = data
    let before = read
    let mut packed = 0.0
    let d = Deflater::new()
    let put = (b : Bytes) => {
      if b.length() > 0 {
        out.at(b, data + packed)
        packed = packed + b.length().to_double()
      }
    }
    let (crc, size, first) = counted(path, b => put(d.push(b)))
    put(d.finish())
    e.crc = crc
    e.size = size
    if size > 0.0 && packed < size {
      e.method = 8
      e.packed = packed
    } else {
      out.truncate(data)
      match first {
        Some(b) => out.at(b, data)
        None =>
          if size > 0.0 {
            read = before
            let mut put_at = 0.0
            let (crc2, size2, _) = counted(path, b => {
              out.at(b, data + put_at)
              put_at = put_at + b.length().to_double()
            })
            e.crc = crc2
            e.size = size2
          }
      }
      e.packed = e.size
    }
    out.at(local_header(e), e.at)
    out.at(e.name, e.at + 30.0)
    at = data + e.packed
    entries.push(e)
  }
  let base = basename(dir)
  let top = if base == "" { "folder" } else { base }
  let s = (fs.lstat)(dir)
  folder("\{top}/", s.mtime_ms)
  let stack : Array[Frame] = [
    {
      path: dir,
      name: top,
      names: stable_sort((fs.names)(dir), units_compare),
      next: 0,
    },
  ]
  while stack.length() > 0 {
    let f = stack[stack.length() - 1]
    if f.next >= f.names.length() {
      stack.pop() |> ignore
      continue
    }
    let child = f.names[f.next]
    f.next += 1
    let full = join([f.path, child])
    if skip(full, child) {
      continue
    }
    let c = match attempt(() => (fs.lstat)(full)) {
      Ok(c) => c
      Err(_) => continue
    }
    if c.link {
      continue
    }
    let in_zip = "\{f.name}/\{child}"
    if c.dir {
      if stack.length() > max_depth {
        raise TooBig
      }
      folder("\{in_zip}/", c.mtime_ms)
      stack.push({
        path: full,
        name: in_zip,
        names: stable_sort((fs.names)(full), units_compare),
        next: 0,
      })
    } else if c.file {
      if read + c.size > most {
        raise TooBig
      }
      file(in_zip, full, c.mtime_ms)
    }
  }
  let start = at
  for e in entries {
    let c = @buffer.new()
    le32(c, 0x02014b50U)
    le16(c, 0x031e)
    le16(c, 20)
    le16(c, 0x0800)
    le16(c, e.method)
    le16(c, e.time)
    le16(c, e.date)
    le32(c, e.crc)
    le32(c, u32(e.packed))
    le32(c, u32(e.size))
    le16(c, e.name.length())
    le16(c, 0)
    le16(c, 0)
    le16(c, 0)
    le16(c, 0)
    let is_folder = e.name[e.name.length() - 1] == b'/'
    let attrs = ((if is_folder { 0o40755 } else { 0o100644 }).reinterpret_as_uint() <<
      16) |
      (if is_folder { 0x10U } else { 0U })
    le32(c, attrs)
    le32(c, u32(e.at))
    write(c.to_bytes())
    write(e.name)
  }
  let end = @buffer.new()
  le32(end, 0x06054b50U)
  le16(end, 0)
  le16(end, 0)
  le16(end, entries.length())
  le16(end, entries.length())
  le32(end, u32(at - start))
  le32(end, u32(start))
  le16(end, 0)
  write(end.to_bytes())
  out.sync(at)
  at
}
