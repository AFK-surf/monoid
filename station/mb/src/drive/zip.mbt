// A folder put into a zip (zip.ts), for a member to send it in a chat as one file (drive `stage`) or to download it
// (drive `zip`): every file under it, deflated, named by its path in the folder (under the folder's own name), with
// its time. Links are not followed, and what `skip` names (the station's own data, uploads not finished) is left out.
// No zip64: at most `most` bytes read in all, and at most MAX_ENTRIES entries. The folder is read as `fs` reaches it;
// the zip is the station's own file, written as it goes, a file's header filled in once the file is read. One that
// deflate does not make smaller is stored as it is: kept where it was one chunk, else read again.
//
// The deflate here is base/flate's (LZ77 over a 32 KB window kept across chunks, fixed Huffman codes), not zlib's: its
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
/// A raw deflate stream made a chunk at a time (base/flate's), the stream ended by an empty last block.
pub struct Deflater {
  priv inner : @flate.Deflater
}

///|
pub fn Deflater::new() -> Deflater {
  { inner: @flate.Deflater::new() }
}

///|
/// `data` deflated as a block of the stream; what of the stream is made by now.
pub fn Deflater::push(self : Deflater, data : Bytes) -> Bytes {
  self.inner.push(data)
}

///|
/// The stream ended: an empty last block, its last byte.
pub fn Deflater::finish(self : Deflater) -> Bytes {
  self.inner.finish()
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
