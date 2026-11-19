// What a gathering (carry.mbt) names, sent to another station a bounded batch at a time, and taken there by its hash
// (sending.ts): what a station retired and a chat handed over both send their files by.

///|
/// A file a batch names: its hash, where it is, how big, when it was written, the room it is of.
pub struct Sent {
  hash : String
  path : String
  size : Double
  mtime : J
  room : String?
}

///|
pub fn Sent::to_json(self : Sent) -> J {
  let fields = [("hash", js(self.hash)), ("path", js(self.path)), ("size", jn(self.size))]
  if !(self.mtime is Null) {
    fields.push(("mtimeMs", self.mtime))
  }
  match self.room {
    Some(r) => fields.push(("room", js(r)))
    None => ()
  }
  jo(fields)
}

///|
/// How a sending reaches the other station and says how far it went (sending.ts `Sending`).
pub struct Sending {
  lacking : async (Array[String], Array[Sent]) -> J
  put : async (String, Body, String, Double) -> J
  put_pack : (async (Array[PackEntry], Body, Bool) -> J)?
  took : ((PackEntry) -> Unit)?
  pack_files : Int?
  pack_bytes : Double?
  most : Int
  stopping : () -> Bool
  total : (Double) -> Unit
  done : (Double) -> Unit
  adds : (async (Double) -> Unit)?
}

///|
pub fn is_ask_again(e : Error) -> Bool {
  kind_of(e) == "AskAgain"
}

///|
fn lacking_set(answer : J, asked : Array[String]) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  match at(answer, "lacking") {
    Some(Arr(xs)) => for x in xs { if str_of(Some(x)) is Some(h) { out[h] = true } }
    _ => for h in asked { out[h] = true }
  }
  out
}

///|
/// Each session of `index` (and its agent home), with its room.
fn sessions_of(index : J) -> Array[(J, String?)] {
  let out = items(at(index, "sessions")).map(s => (s, str_at(s, "workspace")))
  match at(index, "agent") {
    Some(Obj(_) as a) => out.push((a, None))
    _ => ()
  }
  out
}

///|
/// A line of a session's list, as a batch takes it.
fn sent_of(line : String, room : String?) -> Sent? {
  if line == "" {
    return None
  }
  let f = parse(line) catch { _ => return None }
  guard str_at(f, "hash") is Some(hash) else { return None }
  Some({
    hash,
    path: text_at(f, "path"),
    size: num_at(f, "size").unwrap_or(0.0),
    mtime: at(f, "mtimeMs").unwrap_or(Null),
    room,
  })
}

///|
/// The bytes of what the other lacks of `index`'s sessions' files (each by its hash once), asked as the sending asks.
async fn lacking_bytes(fs : Fs, index : J, to : Sending) -> Double {
  let counted : Map[String, Bool] = {}
  let mut bytes = 0.0
  let ask = async fn(batch : Array[Sent]) -> Unit {
    if batch.length() == 0 {
      return
    }
    let asked = uniq(batch.map(f => f.hash))
    let lacking = lacking_set((to.lacking)(asked, batch), asked)
    for f in batch {
      if !lacking.contains(f.hash) || counted.contains(f.hash) {
        continue
      }
      counted[f.hash] = true
      bytes += f.size
    }
  }
  for s in sessions_of(index) {
    let batch = []
    for line in fs.lines(text_at(s.0, "at")) {
      if (to.stopping)() {
        return bytes
      }
      guard sent_of(line, s.1) is Some(f) else { continue }
      batch.push(f)
      if batch.length() >= to.most {
        ask(batch.copy())
        batch.clear()
      }
    }
    ask(batch)
  }
  bytes
}

///|
/// What the gathering `g` names that the other station lacks, sent: each session's list as it streams, then the list
/// itself (`strict`); the bundles; the index last (with `jobs` in it), its hash said back (None: stopped, or not
/// `strict` and not `indexed`).
pub async fn send_gathered(fs : Fs, g : J, to : Sending, strict : Bool, jobs? : Array[J] = [], indexed? : Bool = false) -> String? {
  let index = parse(fs.read_text_strict(text_at(g, "index")))
  match to.adds {
    Some(adds) => adds(lacking_bytes(fs, index, to))
    None => ()
  }
  (to.total)(num_at(index, "bytes").unwrap_or(0.0))
  for s in sessions_of(index) {
    let batch = []
    for line in fs.lines(text_at(s.0, "at")) {
      if (to.stopping)() {
        return None
      }
      guard sent_of(line, s.1) is Some(f) else { continue }
      batch.push(f)
      if batch.length() >= to.most {
        send_batch(fs, to, batch.copy(), strict)
        batch.clear()
      }
    }
    send_batch(fs, to, batch, strict)
    // (its list too where the index goes, so what was sent can be placed by it)
    if strict || indexed {
      send_batch(fs, to, [{ hash: text_at(s.0, "list"), path: text_at(s.0, "at"), size: 0.0, mtime: Null, room: None }], strict)
    }
  }
  send_batch(
    fs,
    to,
    entries(at(index, "bundles")).map(e => { hash: e.0, path: str_of(Some(e.1)).unwrap_or(""), size: 0.0, mtime: Null, room: None }),
    strict,
  )
  if (to.stopping)() || (!strict && !indexed) {
    return None
  }
  let text = @utf8.encode(stringify(set(index, "jobs", ja(jobs))))
  let hash = @memory.sha256_hex(text)
  let _ = (to.put)(hash, Whole(text), "", text.length().to_double()) catch {
    e => {
      if !is_ask_again(e) {
        raise e
      }
      (to.put)(hash, Whole(text), "", text.length().to_double())
    }
  }
  Some(hash)
}

///|
/// Of `batch`, what the other station lacks, sent.
async fn send_batch(fs : Fs, to : Sending, batch : Array[Sent], strict : Bool) -> Unit {
  if batch.length() == 0 {
    return
  }
  let asked = uniq(batch.map(f => f.hash))
  let answer = (to.lacking)(asked, batch)
  let lacking = lacking_set(answer, asked)
  if text_at(answer, "pack") == pack_encoding && to.put_pack is Some(_) {
    return send_packed(fs, to, batch, lacking, strict)
  }
  for f in batch {
    if (to.stopping)() {
      return
    }
    if lacking.contains(f.hash) {
      lacking.remove(f.hash)
      let size = match fs.stat(f.path) {
        Some((_, s, _)) => s
        None => {
          // (gone since it was gathered: left for the next gathering while the chats work)
          if strict {
            raise failed(went_words)
          }
          continue
        }
      }
      let put = async fn() {
        ignore((to.put)(f.hash, File(f.path, 0.0, size), f.path, size))
      }
      let ok = try {
        put() catch {
          e => {
            if !is_ask_again(e) {
              raise e
            }
            put()
          }
        }
        true
      } catch {
        e => {
          if code_of(e) == "ENOENT" {
            if strict {
              raise failed(went_words)
            }
            false
          } else if !(is_refused(e) && message_of(e).contains("changed")) && !message_of(e).contains("got shorter") {
            raise e
          } else if strict {
            raise failed(changed_words)
          } else {
            false
          }
        }
      }
      if !ok {
        continue
      }
    }
    (to.done)(f.size)
  }
}

///|
/// What `lacking` says of `batch`, sent a pack at a time: each file by its hash once, the batch's order kept.
async fn send_packed(fs : Fs, to : Sending, batch : Array[Sent], lacking : Map[String, Bool], strict : Bool) -> Unit {
  let sending : Array[PackEntry] = []
  let of : Map[String, Array[Double]] = {}
  for f in batch {
    if lacking.contains(f.hash) {
      lacking.remove(f.hash)
      // (a list's or a bundle's size is not in the gathering: its own, to bound its pack by)
      let size = if f.size > 0.0 {
        f.size
      } else {
        match fs.stat(f.path) {
          Some((_, s, _)) => s
          None => 0.0
        }
      }
      sending.push({ hash: f.hash, path: f.path, size })
      of[f.hash] = []
    }
    match of.get(f.hash) {
      Some(waiting) => waiting.push(f.size)
      None => (to.done)(f.size)
    }
  }
  let files = @cmp.maximum(1, to.pack_files.unwrap_or(pack_max_files))
  let most = @cmp.maximum(1.0, to.pack_bytes.unwrap_or(pack_max_bytes))
  let mut i = 0
  while i < sending.length() {
    if (to.stopping)() {
      return
    }
    let mut j = i + 1
    let mut bytes = sending[i].size
    while j < sending.length() && j - i < files && bytes + sending[j].size <= most {
      bytes += sending[j].size
      j += 1
    }
    let pack = sending[i:j].to_array()
    i = j
    let took = send_pack(fs, to, pack, strict)
    // (one left, changed or gone as it was read: for the next gathering, not counted done)
    for e in pack {
      if took.contains(e.hash) {
        for size in of.get(e.hash).unwrap_or([]) {
          (to.done)(size)
        }
      }
    }
  }
}

///|
/// One pack sent, the hashes of what is there now said back.
async fn send_pack(fs : Fs, to : Sending, pack : Array[PackEntry], strict : Bool) -> Map[String, Bool] {
  guard to.put_pack is Some(put_pack) else { return {} }
  let put = async fn(entries : Array[PackEntry]) -> Array[PackEntry] {
    let took = []
    ignore(put_pack(entries, pack_bytes(fs, entries, strict, took, to.stopping), strict))
    took
  }
  let took = put(pack) catch {
    e => {
      if !is_ask_again(e) {
        raise e
      }
      let took = []
      let mut rest = pack
      if pack.length() > 1 {
        let hashes = pack.map(f => f.hash)
        let lacking = lacking_set(
          (to.lacking)(hashes, pack.map(f => { hash: f.hash, path: f.path, size: f.size, mtime: Null, room: None })),
          hashes,
        )
        rest = pack.filter(f => lacking.contains(f.hash))
        took.push_iter(pack.filter(f => !lacking.contains(f.hash)).iter())
      }
      if rest.length() > 0 {
        took.push_iter(put(rest).iter())
      }
      took
    }
  }
  let out : Map[String, Bool] = {}
  for f in took {
    match to.took {
      Some(t) => t(f)
      None => ()
    }
    out[f.hash] = true
  }
  out
}

///|
/// A file sent, taken into `files` by its hash: written beside, its bytes' hash checked as they come, then put in
/// place; one whose bytes are not what its name says refused. `flush`: written out to the drive before it is in place.
pub async fn receive_file(fs : Fs, files : String, hash : String, body : Body, flush? : Bool = true) -> Unit {
  let path = fs.join([files, hash])
  let next = body.reader(fs)
  if fs.there(path) {
    while next() is Some(_) {

    }
    return
  }
  fs.mkdirs(files)
  let tmp = "\{path}.\{fs.random_hex(4)}.tmp"
  let h = @hash.Sha256::new()
  let mut at = 0.0
  try {
    fs.files.write(tmp, b"")
    while next() is Some(piece) {
      h.update(piece)
      ignore(fs.host.shell("fs.put", { "path": Json::string(tmp), "offset": Json::number(at) }, bytes=piece))
      at += piece.length().to_double()
    }
    if flush {
      ignore(fs.host.shell("fs.put", { "path": Json::string(tmp), "offset": Json::number(at), "sync": Json::boolean(true) }, bytes=b""))
    }
  } catch {
    e => {
      fs.rm_f(tmp)
      raise e
    }
  }
  if h.hex() != hash {
    fs.rm_f(tmp)
    raise refused("changed: its bytes are not what its name says")
  }
  fs.rename(tmp, path)
}
