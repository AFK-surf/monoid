// A pack (pack.ts): many files in one request, made as it is read and taken as it comes. In zstd: "SFP1", then each
// file as an entry (ENTRY and its hash's 32 bytes, its bytes in DATA frames of a u32be length and that many bytes, then
// COMMIT where they are what its name says, ABORT where not), then END. What is staged goes to the compressor as a
// frame of its own (the shell's `zstd.compress`): frames one after another are one zstd stream to what takes them.

///|
pub let went_words = "a file went as it was sent: gathered again"

///|
pub let changed_words = "a file changed as it was sent: gathered again"

///|
/// How a pack is said to be (`lacking`'s `pack`, a `put`'s).
pub let pack_encoding = "zstd"

///|
pub let pack_max_files = 500

///|
pub let pack_max_bytes : Double = 33554432.0

///|
/// A file of a pack: its hash, where it is here and its bytes.
pub struct PackEntry {
  hash : String
  path : String
  size : Double
}

///|
let tag_end : Byte = b'\x00'

///|
let tag_entry : Byte = b'\x01'

///|
let tag_data : Byte = b'\x02'

///|
let tag_commit : Byte = b'\x03'

///|
let tag_abort : Byte = b'\x04'

///|
let pack_piece : Double = 262144.0

///|
let frame_most = 4194304

///|
let stage_bytes = 262144

///|
fn hex_bytes(hex : String) -> Bytes {
  @hex.decode(hex) catch {
    _ => b""
  }
}

///|
/// The bytes of a pack of `entries`, read as they are sent (each file opened as its turn comes). `took`: each whose
/// bytes went whole and were what its name says. One gone or changed as it is read is called off and the rest go on,
/// not `strict`; `strict`, the bytes fail with it. `stopping`: no file more is begun.
pub fn pack_bytes(fs : Fs, entries : Array[PackEntry], strict : Bool, took : Array[PackEntry], stopping : () -> Bool) -> Body {
  let out : Array[Bytes] = []
  let staged = @buffer.new()
  staged.write_bytes(b"SFP1")
  let next_entry = Ref(0)
  let ended = Ref(false)
  let flush = async fn() {
    let all = staged.to_bytes()
    staged.reset()
    if all.length() > 0 {
      let (_, b) = fs.host.shell("zstd.compress", { "level": Json::number(1.0), "window": Json::number(20.0) }, bytes=all)
      match b {
        Some(x) => if x.length() > 0 { out.push(x) }
        None => ()
      }
    }
  }
  // One file at a time: what it reads staged, flushed as the stage fills.
  let one = async fn(f : PackEntry) -> Unit {
    let size = match fs.stat(f.path) {
      Some((_, s, _)) => Some(s)
      None => None
    }
    let open = match size {
      Some(_) =>
        if fs.files.lkind(f.path) is Some("file") {
          true
        } else if fs.files.lkind(f.path) is Some("link") {
          // (O_NOFOLLOW: a link is not read through)
          raise Thrown("Error", jo([("message", js("ELOOP: too many symbolic links encountered, open '\{f.path}'")), ("code", js("ELOOP"))]))
        } else {
          fs.there(f.path)
        }
      None => false
    }
    guard size is Some(size) && open else {
      if strict {
        raise failed(went_words)
      }
      return
    }
    staged.write_byte(tag_entry)
    staged.write_bytes(hex_bytes(f.hash))
    let h = @hash.Sha256::new()
    let mut at = 0.0
    while at < size {
      let n = if size - at < pack_piece { size - at } else { pack_piece }
      let data = fs.files.read_range(f.path, at, n) catch { _ => b"" }
      if data.length() == 0 {
        break
      }
      h.update(data)
      at += data.length().to_double()
      let len = data.length()
      staged.write_byte(tag_data)
      staged.write_byte((len >> 24).to_byte())
      staged.write_byte((len >> 16).to_byte())
      staged.write_byte((len >> 8).to_byte())
      staged.write_byte(len.to_byte())
      staged.write_bytes(data)
      if staged.length() >= stage_bytes {
        flush()
      }
    }
    if at < size || h.hex() != f.hash {
      if strict {
        raise failed(changed_words)
      }
      staged.write_byte(tag_abort)
      return
    }
    staged.write_byte(tag_commit)
    took.push({ hash: f.hash, path: f.path, size })
  }
  Stream(async fn() {
    while out.length() == 0 {
      if ended.val {
        return None
      }
      if next_entry.val < entries.length() && !stopping() {
        let f = entries[next_entry.val]
        next_entry.val += 1
        one(f)
      } else {
        staged.write_byte(tag_end)
        flush()
        ended.val = true
      }
    }
    Some(out.remove(0))
  })
}

///|
/// What a pack's taking is told to do.
pub struct PackOpts {
  strict : Bool
  flush : Bool
  name : String?
  count : Int?
  on_file : (async () -> Unit)?
}

///|
/// A pack's entries as its bytes come, a piece at a time.
priv struct Unpacking {
  fs : Fs
  files : String
  opts : PackOpts
  mut at : Int
  head : FixedArray[Byte]
  mut had : Int
  mut left : Int
  mut entries : Int
  mut ended : Bool
  mut entry : PackIn?
}

///|
priv struct PackIn {
  hash : String
  path : String
  bad : Bool
  tmp : String?
  mut size : Double
  h : @hash.Sha256?
}

///|
let unpack_magic = 0

///|
let unpack_tag = 1

///|
let unpack_hash = 2

///|
let unpack_length = 3

///|
let unpack_data = 4

///|
fn bad_pack(words : String) -> Thrown {
  refused("bad pack: \{words}")
}

///|
fn Unpacking::fill(self : Unpacking, b : Bytes, at : Int, n : Int) -> Int {
  let room = n - self.had
  let there = b.length() - at
  let take = if room < there { room } else { there }
  for i in 0..<take {
    self.head[self.had + i] = b[at + i]
  }
  self.had += take
  at + take
}

///|
async fn Unpacking::take(self : Unpacking, b : Bytes) -> Unit {
  let mut at = 0
  while at < b.length() {
    if self.at == unpack_magic {
      at = self.fill(b, at, 4)
      if self.had < 4 {
        continue
      }
      if !(self.head[0] == b'S' && self.head[1] == b'F' && self.head[2] == b'P' && self.head[3] == b'1') {
        raise bad_pack("not a pack")
      }
      self.had = 0
      self.at = unpack_tag
    } else if self.at == unpack_tag {
      let tag = b[at]
      at += 1
      if self.ended {
        raise bad_pack("more after its end")
      }
      if tag == tag_end {
        if self.entry is Some(_) {
          raise bad_pack("an entry not ended")
        }
        self.ended = true
      } else if tag == tag_entry {
        if self.entry is Some(_) {
          raise bad_pack("an entry not ended")
        }
        self.at = unpack_hash
      } else if tag == tag_data {
        if self.entry is None {
          raise bad_pack("bytes of no entry")
        }
        self.at = unpack_length
      } else if tag == tag_commit {
        self.commit()
      } else if tag == tag_abort {
        if self.entry is None {
          raise bad_pack("an end of no entry")
        }
        self.close()
      } else {
        raise bad_pack("an unknown frame")
      }
    } else if self.at == unpack_hash {
      at = self.fill(b, at, 32)
      if self.had < 32 {
        continue
      }
      self.had = 0
      self.at = unpack_tag
      let hex = StringBuilder::new()
      let digits = "0123456789abcdef"
      for i in 0..<32 {
        let x = self.head[i].to_int()
        hex.write_char(digits.unsafe_charcode_at(x >> 4).unsafe_to_char())
        hex.write_char(digits.unsafe_charcode_at(x & 15).unsafe_to_char())
      }
      self.begin(hex.to_string())
    } else if self.at == unpack_length {
      at = self.fill(b, at, 4)
      if self.had < 4 {
        continue
      }
      self.had = 0
      self.left = (self.head[0].to_int() << 24) |
        (self.head[1].to_int() << 16) |
        (self.head[2].to_int() << 8) |
        self.head[3].to_int()
      if self.left <= 0 || self.left > frame_most {
        raise bad_pack("a frame's length")
      }
      self.at = unpack_data
    } else {
      let there = b.length() - at
      let take = if self.left < there { self.left } else { there }
      self.write(b[at:at + take].to_bytes())
      at += take
      self.left -= take
      if self.left == 0 {
        self.at = unpack_tag
      }
    }
  }
}

///|
async fn Unpacking::begin(self : Unpacking, hash : String) -> Unit {
  if self.opts.count is Some(most) {
    self.entries += 1
    if self.entries > most {
      raise bad_pack("more files than it said")
    }
  }
  match self.opts.on_file {
    Some(f) => f()
    None => ()
  }
  let path = self.fs.join([self.files, hash])
  let bad = match self.opts.name {
    Some(n) => hash != n
    None => false
  }
  if self.fs.there(path) {
    self.entry = Some({ hash, path, bad, tmp: None, size: 0.0, h: None })
    return
  }
  let tmp = "\{path}.\{self.fs.random_hex(4)}.tmp"
  self.fs.files.write(tmp, b"")
  self.entry = Some({ hash, path, bad, tmp: Some(tmp), size: 0.0, h: Some(@hash.Sha256::new()) })
}

///|
async fn Unpacking::write(self : Unpacking, piece : Bytes) -> Unit {
  guard self.entry is Some(e) && e.tmp is Some(tmp) && e.h is Some(h) else { return }
  h.update(piece)
  ignore(self.fs.host.shell("fs.put", { "path": Json::string(tmp), "offset": Json::number(e.size) }, bytes=piece))
  e.size += piece.length().to_double()
}

///|
async fn Unpacking::commit(self : Unpacking) -> Unit {
  guard self.entry is Some(e) else { raise bad_pack("an end of no entry") }
  if e.tmp is Some(tmp) && self.opts.flush {
    ignore(self.fs.host.shell("fs.put", { "path": Json::string(tmp), "offset": Json::number(e.size), "sync": Json::boolean(true) }, bytes=b""))
  }
  let mismatch = match e.h {
    Some(h) => h.hex() != e.hash
    None => false
  }
  if e.bad || mismatch {
    match e.tmp {
      Some(tmp) => self.fs.rm_f(tmp)
      None => ()
    }
    self.entry = None
    if self.opts.strict || e.bad {
      raise refused("changed: its bytes are not what its name says")
    }
    return
  }
  match e.tmp {
    Some(tmp) => self.fs.rename(tmp, e.path)
    None => ()
  }
  self.entry = None
}

///|
/// The entry under way let go: what it wrote taken out.
async fn Unpacking::close(self : Unpacking) -> Unit {
  guard self.entry is Some(e) else { return }
  self.entry = None
  match e.tmp {
    Some(tmp) => self.fs.rm_f(tmp)
    None => ()
  }
}

///|
/// A pack sent, taken into `files` by each file's hash as `receive_file` takes one.
pub async fn receive_pack(fs : Fs, files : String, body : Body, opts : PackOpts) -> Unit {
  fs.mkdirs(files)
  let (made, _) = fs.host.shell("zstd.open", Json::object({}))
  let id = match made {
    Object(o) => o.get("id").unwrap_or(Json::null())
    _ => Json::null()
  }
  let u : Unpacking = {
    fs,
    files,
    opts,
    at: unpack_magic,
    head: FixedArray::make(32, b'\x00'),
    had: 0,
    left: 0,
    entries: 0,
    ended: false,
    entry: None,
  }
  let close = async fn() {
    ignore(fs.host.shell("zstd.close", { "id": id })) catch {
      _ => ()
    }
    u.close() catch {
      _ => ()
    }
  }
  try {
    let next = body.reader(fs)
    let mut whole = true
    while next() is Some(piece) {
      let (said, out) = fs.host.shell("zstd.push", { "id": id }, bytes=piece) catch {
        e => raise failed(message_of(e))
      }
      whole = match said {
        Object(o) => !(o.get("whole") is Some(False))
        _ => true
      }
      match out {
        Some(b) => if b.length() > 0 { u.take(b) }
        None => ()
      }
    }
    if !whole {
      // (zlib's words for a stream cut short)
      raise failed("unexpected end of file")
    }
    if !u.ended {
      raise bad_pack("it ended before its end")
    }
  } catch {
    e => {
      close()
      raise e
    }
  }
  close()
}

///|
/// `stat(path).then(() => true, () => false)`.
pub async fn there(fs : Fs, path : String) -> Bool {
  fs.there(path)
}

///|
/// Of `hashes`, those not in `files`.
pub async fn lacking_in(fs : Fs, files : String, hashes : Array[String]) -> Array[String] {
  let out = []
  for h in hashes {
    if !fs.there(fs.join([files, h])) {
      out.push(h)
    }
  }
  out
}
