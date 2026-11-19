// The transcripts as the usage counter reads them (station/src/usage/counter.ts `readFrom`, `anchorAt`, `claudeFiles`,
// `codexMeta`): the filesystem asked through the shell (`fs.stat`, `fs.meta`, `fs.readdir`, `fs.realpath`, `fs.bytes`),
// a file put away read as its zstd frames hold it (read/packed.ts: a segment at a time by its table; one from before
// the table through the shell's streaming decoder), a part of whole lines at a time.

///|
/// counter.ts CHUNK: how much of a transcript is read and parsed at a time.
let chunk : Int = 1048576

///|
/// counter.ts ANCHOR: bytes before a saved position.
let anchor_bytes : Int = 256

///|
/// What a file read here gives when it does not read: the read stops, what it gave stays.
priv suberror Unread {
  Unread(String)
}

///|
/// Its words as they are where it is said (`to_string`), not its type's name.
impl Show for Unread with output(self, logger) {
  match self {
    Unread(m) => logger.write_string(m)
  }
}

///|
fn sync(host : @host.Host, op : String, args : Json) -> Json raise {
  host.shell_sync(op, args)
}

///|
/// What stat says a path is ("file", "dir", "other"), none when it cannot.
fn stat(host : @host.Host, path : String) -> String? {
  match (try { Ok(sync(host, "fs.stat", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok(String(kind)) => Some(kind)
    _ => None
  }
}

///|
fn is_file(host : @host.Host, path : String) -> Bool {
  stat(host, path) == Some("file")
}

///|
fn is_dir(host : @host.Host, path : String) -> Bool {
  stat(host, path) == Some("dir")
}

///|
fn exists(host : @host.Host, path : String) -> Bool {
  stat(host, path) is Some(_)
}

///|
/// counter.ts `canonical`: the path with its links resolved, or as it is.
fn canonical(host : @host.Host, path : String) -> String {
  match (try { Ok(sync(host, "fs.realpath", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok(String(p)) => p
    _ => path
  }
}

///|
/// A file's size as stat says it; none when it cannot.
fn size_of(host : @host.Host, path : String) -> Int64? {
  match (try { Ok(sync(host, "fs.meta", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok({ "size": Number(size, ..), .. }) => Some(size.to_int64())
    _ => None
  }
}

///|
/// Bytes of a file, `length` of them from `from` (fewer where it ends first, `exact`: a failure then).
fn bytes_of(host : @host.Host, path : String, from : Int64, length : Int64, exact? : Bool = false, zstd? : Bool = false) -> Bytes raise {
  let args : Map[String, Json] = {
    "path": Json::string(path),
    "from": Json::number(from.to_double()),
    "length": Json::number(length.to_double()),
  }
  if exact {
    args["exact"] = true
  }
  if zstd {
    args["zstd"] = true
  }
  match sync(host, "fs.bytes", Json::object(args)) {
    String(hex) => @hex.decode(hex)
    _ => raise Unread("not there")
  }
}

///|
/// archive.rs `packed`: where a file is once put away.
fn packed(path : String) -> String {
  path + ".zst"
}

///|
/// Whether a transcript is put away: only its `.zst` there.
fn put_away(host : @host.Host, path : String) -> Bool {
  !exists(host, path) && exists(host, packed(path))
}

///|
fn le32(b : BytesView, at : Int) -> Int64 {
  b[at].to_int64() | (b[at + 1].to_int64() << 8) | (b[at + 2].to_int64() << 16) | (b[at + 3].to_int64() << 24)
}

///|
/// read/packed.ts `Frame`.
priv struct Frame {
  at : Int64
  packed : Int64
  from : Int64
  size : Int64
}

///|
let skippable : Int64 = 0x184d2a5eL

///|
let seekable : Int64 = 0x8f92eab1L

///|
let footer_size : Int64 = 9L

///|
/// read/packed.ts `framesOf`: a put-away transcript's frames from its table; None without one, or one that does not add
/// up to the file. A file that does not read is a failure.
fn frames_of(host : @host.Host, path : String) -> Array[Frame]? raise {
  guard size_of(host, path) is Some(size) else { raise Unread("a put-away transcript is not there") }
  if size < 8L + footer_size {
    return None
  }
  let footer = bytes_of(host, path, size - footer_size, footer_size, exact=true)
  if le32(footer[:], 5) != seekable || (footer[4].to_int() & 0x7f) != 0 {
    return None
  }
  let entry = if (footer[4].to_int() & 0x80) != 0 { 12L } else { 8L }
  let length = 8L + le32(footer[:], 0) * entry + footer_size
  if length > size {
    return None
  }
  let table = bytes_of(host, path, size - length, length, exact=true)
  if le32(table[:], 0) != skippable || le32(table[:], 4) != length - 8L {
    return None
  }
  let count = (length - 8L - footer_size) / entry
  let frames = []
  let mut at = 0L
  let mut from = 0L
  for i = 0L; i < count; i = i + 1L {
    let packed = le32(table[:], (8L + i * entry).to_int())
    let each = le32(table[:], (12L + i * entry).to_int())
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
/// read/packed.ts `writtenLength`: how long a put-away transcript is as written, from its table; None without one.
fn written_length(host : @host.Host, path : String) -> Int64? raise {
  guard frames_of(host, path) is Some(frames) else { return None }
  let mut total = 0L
  for f in frames {
    total += f.size
  }
  Some(total)
}

///|
/// read/packed.ts `segmentsFrom`: what a put-away transcript with a table holds from `from` on, a segment at a time,
/// each given to `take` (which says false to stop); false without a table. A segment that does not read is a failure.
fn segments_from(host : @host.Host, path : String, from : Int64, take : (BytesView) -> Bool raise) -> Bool raise {
  guard frames_of(host, path) is Some(frames) else { return false }
  let mut lo = 0
  let mut hi = frames.length() - 1
  while lo < hi {
    let mid = (lo + hi + 1) >> 1
    if frames[mid].from <= from {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  for i = lo; i < frames.length(); i = i + 1 {
    let f = frames[i]
    if f.from + f.size <= from {
      continue
    }
    let bytes = bytes_of(host, path, f.at, f.packed, exact=true, zstd=true)
    if bytes.length().to_int64() != f.size {
      raise Unread("a put-away transcript frame has the wrong size")
    }
    let skip = if from > f.from { (from - f.from).to_int() } else { 0 }
    if skip < bytes.length() && !take(bytes[skip:]) {
      break
    }
  }
  true
}

///|
/// What the zstd frames of a file hold, from its start, given to `take` a piece at a time (which says false to stop):
/// a put-away transcript from before the table, decompressed as it is read (one is hundreds of MB).
async fn unpacked(host : @host.Host, path : String, take : (BytesView) -> Bool raise) -> Unit raise {
  guard size_of(host, path) is Some(size) else { raise Unread("a put-away transcript is not there") }
  let (opened, _) = host.shell("zstd.open", {})
  guard opened is { "id": id, .. } else { raise Unread("no zstd stream") }
  defer ignore((try Ok(host.shell_sync("zstd.close", { "id": id })) catch { e => Err(e) }))
  let mut pos = 0L
  while pos < size {
    let n = if size - pos < chunk.to_int64() { size - pos } else { chunk.to_int64() }
    let piece = bytes_of(host, path, pos, n)
    if piece.length() == 0 {
      break
    }
    pos += piece.length().to_int64()
    let (_, out) = host.shell("zstd.push", { "id": id }, bytes=piece)
    match out {
      Some(b) if b.length() > 0 => if !take(b[:]) { return }
      _ => ()
    }
  }
}

///|
/// A part of a transcript: its whole lines and their bounds in the file (counter.ts `Part`).
priv struct Part {
  bytes : BytesView
  from : Int64
  offset : Int64
}

///|
/// counter.ts `partsOf`: whole lines of `bytes` (what follows `from` in the file), a part at most CHUNK long each where
/// lines allow.
fn parts_of(bytes : BytesView, from : Int64, take : (Part) -> Unit raise) -> Unit raise {
  let mut at = 0
  while at < bytes.length() {
    let window = if bytes.length() < at + chunk { bytes.length() } else { at + chunk }
    let mut cut = window - 1
    while cut >= at && bytes[cut] != b'\n' {
      cut -= 1
    }
    if cut < at {
      cut = window
      while cut < bytes.length() && bytes[cut] != b'\n' {
        cut += 1
      }
      if cut >= bytes.length() {
        return
      }
    }
    take({ bytes: bytes[at:cut + 1], from: from + at.to_int64(), offset: from + (cut + 1).to_int64() })
    at = cut + 1
  }
}

///|
/// counter.ts `Lines`: unfinished lines kept until a newline comes, even across many pieces.
priv struct Lines {
  held : @buffer.Buffer
  mut start : Int64
}

///|
fn Lines::new(start : Int64) -> Lines {
  { held: @buffer.new(), start }
}

///|
fn Lines::add(self : Lines, piece : BytesView, take : (Part) -> Unit raise) -> Unit raise {
  let mut cut = piece.length() - 1
  while cut >= 0 && piece[cut] != b'\n' {
    cut -= 1
  }
  if cut < 0 {
    self.held.write_bytesview(piece)
    return
  }
  let whole = if self.held.length() == 0 {
    piece[0:cut + 1]
  } else {
    self.held.write_bytesview(piece[0:cut + 1])
    let b = self.held.to_bytes()
    self.held.reset()
    b[:]
  }
  parts_of(whole, self.start, take)
  self.start += whole.length().to_int64()
  self.held.write_bytesview(piece[cut + 1:])
}

///|
/// counter.ts `packedFrom`: a file put away, past `offset`; shorter than `offset`: read again from its start. What does
/// not read ends it (what it gave stays); what `take` raises goes on up.
async fn packed_from(host : @host.Host, path : String, offset : Int64, take : (Part) -> Unit raise) -> Unit raise {
  let length = (try Ok(written_length(host, packed(path))) catch { e => Err(e) })
  match length {
    Ok(Some(length)) => {
      if offset > length {
        packed_from(host, path, 0L, take)
        return
      }
      let lines = Lines::new(offset)
      // (what `take` raised, kept apart from what did not read)
      let mut failed : Error? = None
      let _ = (try Ok(segments_from(host, packed(path), offset, piece => {
        lines.add(piece, part => take(part) catch { e => { failed = Some(e); raise Unread("stopped") } })
        true
      })) catch { e => Err(e) })
      if failed is Some(e) {
        raise e
      }
    }
    _ => {
      let lines = Lines::new(offset)
      let mut total = 0L
      let mut failed : Error? = None
      let _ = (try Ok(unpacked(host, packed(path), piece => {
        let skip = if offset > total { offset - total } else { 0L }
        total += piece.length().to_int64()
        if skip >= piece.length().to_int64() {
          return true
        }
        lines.add(piece[skip.to_int():], part => take(part) catch { e => { failed = Some(e); raise Unread("stopped") } })
        true
      })) catch { e => Err(e) })
      if failed is Some(e) {
        raise e
      }
      if total < offset {
        packed_from(host, path, 0L, take)
      }
    }
  }
}

///|
/// counter.ts `readFrom`: what a file holds past `offset`, up to its last whole line, in parts; a file now shorter than
/// `offset` read from its start, one put away read decompressed.
async fn read_from(host : @host.Host, path : String, offset : Int64, take : (Part) -> Unit raise) -> Unit raise {
  if put_away(host, path) {
    packed_from(host, path, offset, take)
    return
  }
  guard size_of(host, path) is Some(size) else { return }
  let mut pos = if size < offset { 0L } else { offset }
  if pos == size {
    return
  }
  let lines = Lines::new(pos)
  while pos < size {
    let n = if size - pos < chunk.to_int64() { size - pos } else { chunk.to_int64() }
    let piece = ((try Ok(bytes_of(host, path, pos, n)) catch { e => Err(e) })).unwrap_or(b"")
    if piece.length() == 0 {
      break
    }
    pos += piece.length().to_int64()
    lines.add(piece[:], take)
  }
}

///|
/// counter.ts `unpackedLength`: an old single-frame archive's length, counted as it is decompressed; None when it does
/// not read.
async fn unpacked_length(host : @host.Host, path : String) -> Int64? {
  let mut size = 0L
  let read = (try Ok(unpacked(host, path, piece => {
    size += piece.length().to_int64()
    true
  })) catch { e => Err(e) })
  match read {
    Ok(_) => Some(size)
    Err(_) => None
  }
}

///|
/// counter.ts `anchorAt`: the bytes immediately before a saved offset, from the raw transcript or the segment holding
/// them; None when they do not read.
async fn anchor_at(host : @host.Host, path : String, offset : Int64, archived : Bool) -> Bytes? {
  let length = if offset < anchor_bytes.to_int64() { offset } else { anchor_bytes.to_int64() }
  if length == 0L {
    return Some(b"")
  }
  let start = offset - length
  if !archived {
    let got = (try Ok(bytes_of(host, path, start, length)) catch { e => Err(e) })
    return match got {
      Ok(b) if b.length().to_int64() == length => Some(b)
      _ => None
    }
  }
  let got = @buffer.new()
  let gather = (skip : Int64, piece : BytesView) => {
    let want = length.to_int() - got.length()
    if skip >= piece.length().to_int64() {
      return true
    }
    let from = skip.to_int()
    let end = if piece.length() - from < want { piece.length() } else { from + want }
    got.write_bytesview(piece[from:end])
    got.length().to_int64() < length
  }
  let tabled = (try Ok(segments_from(host, packed(path), start, piece => gather(0L, piece))) catch { e => Err(e) })
  match tabled {
    Ok(true) => ()
    Ok(false) => {
      let mut skip = start
      let whole = (try Ok(unpacked(host, packed(path), piece => {
        let s = skip
        skip = if skip > piece.length().to_int64() { skip - piece.length().to_int64() } else { 0L }
        gather(s, piece)
      })) catch { e => Err(e) })
      if whole is Err(_) {
        return None
      }
    }
    Err(_) => return None
  }
  if got.length().to_int64() == length {
    Some(got.to_bytes())
  } else {
    None
  }
}

///|
/// The first line of a file (or of its `.zst`), up to its end when it has no newline; None when it does not read.
async fn first_line(host : @host.Host, path : String) -> String? {
  let source = if exists(host, path) { path } else { packed(path) }
  if !exists(host, source) {
    return None
  }
  let got = @buffer.new()
  let mut ended = false
  let take = fn(piece : BytesView) -> Bool raise {
    let mut i = 0
    while i < piece.length() && piece[i] != b'\n' {
      i += 1
    }
    if i < piece.length() {
      got.write_bytesview(piece[0:i + 1])
      ended = true
      false
    } else {
      got.write_bytesview(piece)
      true
    }
  }
  if source == path {
    guard size_of(host, path) is Some(size) else { return None }
    let mut pos = 0L
    while pos < size && !ended {
      let n = if size - pos < 65536L { size - pos } else { 65536L }
      guard ((try Ok(bytes_of(host, path, pos, n)) catch { e => Err(e) })) is Ok(piece) else { return None }
      if piece.length() == 0 {
        break
      }
      pos += piece.length().to_int64()
      ignore(take(piece[:]))
    }
  } else {
    let read = (try Ok(unpacked(host, source, take)) catch { e => Err(e) })
    if read is Err(_) && !ended {
      return None
    }
  }
  Some(@utf8.decode_lossy(got.to_bytes()))
}

///|
/// counter.ts `codexMeta`: a Codex transcript's session id (and where it ran), from its first line.
async fn codex_meta(host : @host.Host, path : String) -> String? {
  guard first_line(host, path) is Some(line) else { return None }
  guard parse_line(line) is Some(r) else { return None }
  let p = get(Some(r), "payload")
  match (str(get(p, "id")), str(get(p, "cwd"))) {
    (Some(id), Some(_)) => Some(id)
    _ => None
  }
}

///|
/// Rust's Path::extension: after the name's last dot, none for a name that only begins with one.
fn extension(sep : String, path : String) -> String? {
  let name = basename(sep, path)
  match name.rev_find(".") {
    Some(dot) if dot > 0 => Some(name.view(start_offset=dot + 1).to_owned())
    _ => None
  }
}

///|
/// Node's path.basename of a path joined here.
fn basename(sep : String, path : String) -> String {
  let cut = last_sep(sep, path)
  if cut < 0 {
    path
  } else {
    path.view(start_offset=cut + 1).to_owned()
  }
}

///|
fn last_sep(sep : String, path : String) -> Int {
  let slash = path.rev_find("/").unwrap_or(-1)
  if sep == "\\" {
    let back = path.rev_find("\\").unwrap_or(-1)
    if back > slash {
      back
    } else {
      slash
    }
  } else {
    slash
  }
}

///|
/// Node's path.dirname of a path joined here (absolute, normalized).
fn dirname(sep : String, path : String) -> String {
  let cut = last_sep(sep, path)
  if cut < 0 {
    "."
  } else if cut == 0 {
    path.view(end_offset=1).to_owned()
  } else {
    path.view(end_offset=cut).to_owned()
  }
}

///|
/// Strings compared by their UTF-8 bytes (Buffer.compare).
fn byte_order(a : String, b : String) -> Int {
  let x = @utf8.encode(a)
  let y = @utf8.encode(b)
  let m = if x.length() < y.length() { x.length() } else { y.length() }
  for i in 0..<m {
    if x[i] != y[i] {
      return x[i].to_int() - y[i].to_int()
    }
  }
  x.length() - y.length()
}

///|
/// counter.ts `jsonlIn`: a directory's transcripts (`.jsonl`, or put away as `.jsonl.zst`), by their bytes.
fn jsonl_in(host : @host.Host, sep : String, dir : String) -> Array[String] {
  let names = match (try { Ok(sync(host, "fs.readdir", { "path": Json::string(dir) })) } catch { e => Err(e) }) {
    Ok(Array(names)) => names.filter_map(n => if n is String(s) { Some(s) } else { None })
    _ => return []
  }
  let seen : Set[String] = Set([])
  let paths = []
  for name in names {
    let p = @nodepath.join(sep, [dir, name])
    if !is_file(host, p) {
      continue
    }
    let q = if extension(sep, p) == Some("zst") { p.view(end_offset=p.length() - 4).to_owned() } else { p }
    if extension(sep, q) == Some("jsonl") && !seen.contains(q) {
      seen.add(q)
      paths.push(q)
    }
  }
  paths.sort_by(byte_order)
  paths
}

///|
/// counter.ts `claudeFiles`: a Claude Code session's transcripts in a project directory, its own and its sub-agents'
/// (`<id>/subagents/*.jsonl`), each with whether it is a sub-agent's; `only`: that runtime session's alone.
fn claude_files(host : @host.Host, sep : String, dir : String, only : String?) -> Array[(String, Bool)] {
  let own = match only {
    Some(id) => {
      let p = @nodepath.join(sep, [dir, id + ".jsonl"])
      if is_file(host, p) || (!exists(host, p) && is_file(host, packed(p))) {
        [p]
      } else {
        []
      }
    }
    None => jsonl_in(host, sep, dir)
  }
  let out = own.map(p => (p, false))
  for p in own {
    let name = basename(sep, p)
    let id = name.view(end_offset=name.length() - 6).to_owned()
    for s in jsonl_in(host, sep, @nodepath.join(sep, [dir, id, "subagents"])) {
      out.push((s, true))
    }
  }
  out
}

///|
/// counter.ts `claudeProject`: Claude Code's directory name for where a session runs (each character but an ASCII
/// letter or digit a dash, per code point as Array.from takes them).
fn claude_project(path : String) -> String {
  let out = StringBuilder::new()
  for c in path {
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
      out.write_char(c)
    } else {
      out.write_char('-')
    }
  }
  out.to_string()
}

///|
/// Bytes as lowercase hex (Buffer.toString("hex")).
fn hex_of(b : BytesView) -> String {
  @codec.hex_encode(b)
}
