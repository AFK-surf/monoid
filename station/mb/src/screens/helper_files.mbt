// The drive's folders macOS keeps from a station launchd runs (Documents, Desktop, Downloads, disks;
// src/helper/files.ts), reached through still.fail Helper (native/helper's Files.swift), which holds the grants for
// them: the drive's operations as the helper's `files.*` requests, each on a connection of its own, told the roots it
// may reach and what it may not. A file's bytes go over that connection as they are read or written, never a whole file
// at once: a read answers its head line, then the bytes; a write is answered once the file is open, then the station
// sends the bytes, then it answers again.
//
// Without the grant the helper refuses (`grant`) and touches nothing: the drive puts the helper's window up on this Mac
// for it (`ask`), once in AGAIN_MS. What is known of each folder's grant is kept (`known`), looked at in the background
// where it is not (`check`), and looked at again when the helper says a grant changed or comes back; the drive's roots
// are told again (`changed`) when it is not what it was.

///|
/// What a write sends at a time.
const CHUNK : Int = 262144

///|
/// The helper's window's words for the drive's folders, in `lang` (Permissions.swift).
pub fn files_words(io : Io, lang : String) -> J {
  let w = (key : String) => js(io.tr(lang, "station.helper.window.\{key}"))
  jo(
    [
      ("title", "filesTitle"),
      ("subtitle", "filesSubtitle"),
      ("documents", "documents"),
      ("documentsWhy", "documentsWhy"),
      ("desktop", "desktop"),
      ("desktopWhy", "desktopWhy"),
      ("downloads", "downloads"),
      ("downloadsWhy", "downloadsWhy"),
      ("removable", "removable"),
      ("removableWhy", "removableWhy"),
      ("network", "network"),
      ("networkWhy", "networkWhy"),
      ("deniedWhy", "deniedWhy"),
      ("allow", "allow"),
      ("done", "done"),
    ].map(p => (p.0, w(p.1))),
  )
}

///|
/// The helper's window's words when a person or an agent asks for a grant: any of its rows, the screen's and the
/// folders', under words that say it was asked for.
pub fn ask_words(io : Io, lang : String) -> J {
  spread(
    spread(window_words(io, lang), files_words(io, lang)),
    jo([
      ("title", js(io.tr(lang, "station.helper.window.askTitle"))),
      ("subtitle", js(io.tr(lang, "station.helper.window.askSubtitle"))),
    ]),
  )
}

///|
/// A folder's entry: whether it is a link, where it leads, and what is there (none: a link to nothing, gone).
pub(all) struct Listed {
  name : String
  link : Bool
  real : String
  stat : Stat?
}

///|
/// A part written: its offset, its bytes, whether the file is made, and the drive's conditions.
pub(all) struct Write {
  create : Bool
  offset : Double
  data : Bytes
  at_least : Double?
  truncate : Double?
  sync : Bool
}

///|
/// The drive's folders through the helper (files.ts `HelperFiles`).
pub struct HelperFiles {
  priv io : Io
  priv helper : HelperApp
  priv changed : () -> Unit
  priv lang : () -> String
  priv grant_of : Map[String, String]
  priv states : Map[String, String]
  priv checking : Array[String]
  priv grants : HelperGrants
}

///|
/// `grants`: the station's one look at the grants and its window for them (default: its own, with `reach`).
pub fn HelperFiles::new(
  io : Io,
  helper : HelperApp,
  changed : () -> Unit,
  reach : async () -> String?,
  lang? : (() -> String)? = None,
  now? : (() -> Double)? = None,
  grants? : HelperGrants? = None,
) -> HelperFiles {
  let f = {
    io,
    helper,
    changed,
    lang: lang.unwrap_or(() => (io.words.station_lang)()),
    grant_of: {},
    states: {},
    checking: [],
    // (made only where none is given: a grants made listens to the helper)
    grants: match grants {
      Some(g) => g
      None => HelperGrants::new(io, helper, reach, now~)
    },
  }
  // A grant changed (its window saw it), or the helper came back: what is known is looked at again.
  ignore(helper.listen(event => if text(get(Some(event), "event")) == Some("grants") { f.again() }))
  ignore(helper.on_back(() => f.again()))
  f
}

///|
pub fn HelperFiles::known(self : HelperFiles, top : String) -> (String, String)? {
  match self.grant_of.get(top) {
    Some(grant) =>
      match self.states.get(grant) {
        Some(state) => Some((grant, state))
        None => None
      }
    None => None
  }
}

///|
pub fn HelperFiles::check(self : HelperFiles, tops : Array[String]) -> Unit {
  let asking = tops.filter(t => !self.checking.contains(t))
  if asking.length() == 0 {
    return
  }
  for t in asking {
    self.checking.push(t)
  }
  self.io.go(async fn() {
    self.look(asking)
    for t in asking {
      remove_from(self.checking, t)
    }
  })
}

///|
/// What the helper says of `tops` now, kept; told when it is not what was known.
async fn HelperFiles::look(self : HelperFiles, tops : Array[String]) -> Unit {
  try {
    let answer = self.helper.request(jo([("op", js("files.access")), ("paths", jstrs(tops))]))
    let mut changed = false
    for a in arr(get(Some(answer), "access")).unwrap_or([]) {
      guard text(get(Some(a), "grant")) is Some(grant) else { continue }
      self.grant_of[js_string_opt(get(Some(a), "path"))] = grant
      changed = self.learn(grant, js_string_opt(get(Some(a), "state"))) || changed
    }
    if changed {
      (self.changed)()
    }
  } catch {
    e => self.io.log.warn("drive", "still.fail Helper did not say what it may open", fields=jo([("error", js(message_of(e)))]))
  }
}

///|
/// A grant's state as now known; whether that changed it.
fn HelperFiles::learn(self : HelperFiles, grant : String, state : String) -> Bool {
  if self.states.get(grant) == Some(state) {
    return false
  }
  self.states[grant] = state
  true
}

///|
/// A request done at `path`: the grant of the protected folder it is in is given.
fn HelperFiles::confirm(self : HelperFiles, path : String) -> Unit {
  let lower = path.to_lower()
  for top, grant in self.grant_of {
    let t = top.to_lower()
    if (lower == t || lower.has_prefix("\{t}/")) && self.learn(grant, "granted") {
      (self.changed)()
    }
  }
}

///|
fn HelperFiles::again(self : HelperFiles) -> Unit {
  if self.grant_of.length() > 0 {
    let tops = self.grant_of.keys().collect()
    self.io.go(async fn() { self.look(tops) })
  }
}

///|
pub async fn HelperFiles::ask(self : HelperFiles, grant : String, top : String) -> String {
  self.grant_of[top] = grant
  self.grants.show(grant, files_words(self.io, (self.lang)()), paths=Some(jo([(grant, js(top))])))
}

///|
/// What Spotlight finds under the protected folder `top` for `query`, asked as still.fail Helper: at most `most`.
pub async fn HelperFiles::search(
  self : HelperFiles,
  top : String,
  query : String,
  most : Double,
  protect : Array[String],
) -> Array[String] {
  let answer = self.request(
    jo([
      ("op", js("files.search")),
      ("path", js(top)),
      ("query", js(query)),
      ("most", jn(most)),
      ("roots", jstrs([top])),
      ("protect", jstrs(protect)),
    ]),
  )
  arr(get(Some(answer), "paths")).unwrap_or([]).filter_map(p => text(Some(p)))
}

///|
pub fn HelperFiles::fs(self : HelperFiles, roots : Array[String], protect : Array[String]) -> HelperFs {
  { files: self, scope: jo([("roots", jstrs(roots)), ("protect", jstrs(protect))]) }
}

///|
/// One request, its answer; a grant refused or given learnt on the way.
pub async fn HelperFiles::request(self : HelperFiles, op : J) -> J {
  self.learning(op, async fn() { self.helper.request(op) })
}

///|
/// A connection for a stream: its head line read (a refusal raised), the rest the caller's.
pub async fn HelperFiles::stream(self : HelperFiles, op : J) -> (J, Sock, Bytes) {
  self.learning(op, async fn() {
    let socket = self.helper.connect(op)
    let (head, rest) = line_of(socket)
    (head, socket, rest)
  })
}

///|
async fn[T] HelperFiles::learning(self : HelperFiles, op : J, ask : async () -> T) -> T {
  let mut attempt = 0
  while true {
    try {
      let answer = ask()
      // Done in a protected folder: its grant is there.
      let path = match text(get(Some(op), "path")) {
        Some(p) => Some(p)
        None => text(get(Some(op), "from"))
      }
      match path {
        Some(p) => self.confirm(p)
        None => ()
      }
      return answer
    } catch {
      e => {
        let code = text(field_of(e, "code"))
        match field_of(e, "pid") {
          Some(Num(pid)) if code == Some("restart") && attempt == 0 => {
            self.helper.restarted(pid)
            attempt += 1
            continue
          }
          _ => ()
        }
        if code == Some("grant") {
          match (text(field_of(e, "grant")), field_of(e, "state")) {
            (Some(grant), Some(state)) if grant != "" && truthy(Some(state)) => {
              match text(field_of(e, "top")) {
                Some(top) if top != "" => self.grant_of[top] = grant
                _ => ()
              }
              if self.learn(grant, js_string(state)) {
                (self.changed)()
              }
            }
            _ => ()
          }
        }
        raise e
      }
    }
  }
  panic()
}

///|
/// The helper went before it said all it had to: the drive's `io`.
fn ended_early() -> Failed {
  Failed("still.fail Helper ended before it answered", jo([("code", js("EIO"))]))
}

///|
/// A connection's first line (a refusal raised), and what came after it; the socket paused, nobody listening.
async fn line_of(socket : Sock) -> (J, Bytes) {
  let d : @effect.Deferred[(J, Bytes)] = @effect.Deferred::new()
  let got = Buffer()
  let ids : Array[Int] = []
  let done = () => {
    for id in ids {
      socket.off(id)
    }
    socket.pause()
  }
  let take = () => {
    let all = got.to_bytes()
    let at = index_of_byte(all, b'\n')
    if at < 0 {
      return
    }
    done()
    match (try Ok(parse(@utf8.decode_lossy(all[0:at]))) catch { e => Err(e) }) {
      Err(e) => {
        socket.destroy()
        ignore(d.fail(fail(json_error_message(e))))
      }
      Ok(head) =>
        match get(Some(head), "error") {
          Some(Str(_) as m) => {
            socket.destroy()
            ignore(d.fail(Failed(text(Some(m)).unwrap_or(""), head)))
          }
          _ => ignore(d.succeed((head, Bytes::from_array(all[at + 1:].to_array()))))
        }
    }
  }
  ids.push(
    socket.on_data(chunk => {
      got.write_bytes(chunk)
      take()
    }),
  )
  ids.push(
    socket.on_close(() => {
      done()
      ignore(d.fail(ended_early()))
    }),
  )
  ids.push(socket.on_error(_ => ()))
  socket.flow_again()
  d.wait()
}

///|
/// The rest of a stream (`rest`, then all that comes) given to `take` as it comes, the socket held while `take` works;
/// its end said with how much came.
async fn drain(io : Io, socket : Sock, rest : Bytes, take : async (Bytes) -> Unit) -> Double {
  let d : @effect.Deferred[Double] = @effect.Deferred::new()
  let got = Ref(0.0)
  let chain = Chain::new()
  let failed : Ref[Error?] = Ref(None)
  let put = (chunk : Bytes) => {
    got.val = got.val + chunk.length().to_double()
    chain.after(io, async fn() {
      if failed.val is None {
        take(chunk) catch {
          e => {
            if failed.val is None {
              failed.val = Some(e)
            }
            socket.destroy()
          }
        }
      }
    })
  }
  if rest.length() > 0 {
    put(rest)
  }
  ignore(
    socket.on_data(chunk => {
      socket.pause()
      put(chunk)
      chain.after(io, async fn() { socket.flow_again() })
    }),
  )
  ignore(socket.on_error(_ => ()))
  ignore(
    socket.on_close(() => chain.after(io, async fn() {
      match failed.val {
        Some(e) => ignore(d.fail(e))
        None => ignore(d.succeed(got.val))
      }
    })),
  )
  socket.flow_again()
  d.wait()
}

///|
fn stat_of(a : J) -> Stat {
  {
    dir: get(Some(a), "dir") is Some(Bool(true)),
    file: get(Some(a), "file") is Some(Bool(true)),
    link: get(Some(a), "link") is Some(Bool(true)),
    size: number_or_zero(get(Some(a), "size")),
    mtime_ms: number_or_zero(get(Some(a), "mtime")),
  }
}

///|
/// The drive's operations as still.fail Helper's requests, in one scope (files.ts `HelperFs`).
pub struct HelperFs {
  priv files : HelperFiles
  priv scope : J
}

///|
async fn HelperFs::ask(self : HelperFs, op : String, fields : J) -> J {
  self.files.request(spread(spread(jo([("op", js(op))]), fields), self.scope))
}

///|
pub async fn HelperFs::list(self : HelperFs, dir : String, most : Double) -> (Array[Listed], Bool) {
  let a = self.ask("files.list", jo([("path", js(dir)), ("most", jn(most))]))
  let entries = arr(get(Some(a), "entries")).unwrap_or([]).map(e => {
    let name = js_string_opt(get(Some(e), "name"))
    {
      name,
      link: get(Some(e), "link") is Some(Bool(true)),
      real: match get(Some(e), "real") {
        None | Some(Null) => pj([dir, name])
        Some(r) => js_string(r)
      },
      stat: if truthy(get(Some(e), "gone")) { None } else { Some(stat_of(e)) },
    }
  })
  (entries, get(Some(a), "more") is Some(Bool(true)))
}

///|
pub async fn HelperFs::names(self : HelperFs, dir : String) -> Array[String] {
  arr(get(Some(self.ask("files.names", jo([("path", js(dir))]))), "names")).unwrap_or([]).map(js_string)
}

///|
pub async fn HelperFs::stat(self : HelperFs, path : String) -> Stat {
  stat_of(self.ask("files.stat", jo([("path", js(path)), ("follow", jb(true))])))
}

///|
pub async fn HelperFs::lstat(self : HelperFs, path : String) -> Stat {
  stat_of(self.ask("files.stat", jo([("path", js(path)), ("follow", jb(false))])))
}

///|
pub async fn HelperFs::real(self : HelperFs, path : String) -> String {
  js_string_opt(get(Some(self.ask("files.real", jo([("path", js(path))]))), "path"))
}

///|
pub async fn HelperFs::read(self : HelperFs, path : String, offset : Double, length : Double) -> (Bytes, Double, Double) {
  let (head, socket, rest) = self.files.stream(
    spread(jo([("op", js("files.read")), ("path", js(path)), ("offset", jn(offset)), ("length", jn(length))]), self.scope),
  )
  let want = number_or_zero(get(Some(head), "length")).to_int()
  let bytes = FixedArray::make(if want > 0 { want } else { 0 }, b'\x00')
  let at = Ref(0)
  ignore(
    drain(self.files.io, socket, rest, async fn(chunk) {
      for i in 0..<chunk.length() {
        if at.val < bytes.length() {
          bytes[at.val] = chunk[i]
          at.val += 1
        }
      }
    }),
  )
  if at.val < want {
    raise ended_early()
  }
  (Bytes::from_array(bytes), number_or_zero(get(Some(head), "size")), number_or_zero(get(Some(head), "mtime")))
}

///|
pub async fn HelperFs::read_all(self : HelperFs, path : String) -> Bytes {
  let s = self.stat(path)
  self.read(path, 0.0, s.size).0
}

///|
pub async fn HelperFs::copy_to(self : HelperFs, path : String, to : String) -> Unit {
  let io = self.files.io
  (io.fs.create)(to)
  try {
    let s = self.stat(path)
    let (head, socket, rest) = self.files.stream(
      spread(jo([("op", js("files.read")), ("path", js(path)), ("offset", jn(0.0)), ("length", jn(s.size))]), self.scope),
    )
    let got = drain(io, socket, rest, async fn(chunk) { (io.fs.append)(to, chunk) })
    if got < number_or_zero(get(Some(head), "length")) {
      raise ended_early()
    }
  } catch {
    e => {
      (io.fs.unlink)(to) catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
pub async fn HelperFs::write(self : HelperFs, path : String, w : Write) -> (Double, Bool) {
  let fields = jsome([
    ("path", Some(js(path))),
    ("offset", Some(jn(w.offset))),
    ("length", Some(ji(w.data.length()))),
    ("create", Some(jb(w.create))),
    ("truncate", w.truncate.map(jn)),
    ("sync", if w.sync { Some(jb(true)) } else { None }),
  ])
  let (head, socket, _) = self.files.stream(spread(spread(jo([("op", js("files.write"))]), fields), self.scope))
  // Smaller than asked: nothing written (the helper sees the connection end before any byte).
  match w.at_least {
    Some(least) if js_number_of(get(Some(head), "size")) < least => {
      socket.destroy()
      return (js_number_of(get(Some(head), "size")), true)
    }
    _ => ()
  }
  let answer : @effect.Deferred[(J, Bytes)] = @effect.Deferred::new()
  let io = self.files.io
  io.go(async fn() {
    match (try Ok(line_of(socket)) catch { e => Err(e) }) {
      Ok(a) => ignore(answer.succeed(a))
      Err(e) => ignore(answer.fail(e))
    }
  })
  ignore(socket.on_error(_ => ()))
  let mut at = 0
  while at < w.data.length() {
    if socket.destroyed() {
      break
    }
    let end = if at + CHUNK < w.data.length() { at + CHUNK } else { w.data.length() }
    socket.write(Bytes::from_array(w.data[at:end].to_array()))
    at += CHUNK
  }
  let (done, _) = answer.wait()
  socket.destroy()
  (js_number_of(get(Some(done), "size")), false)
}

///|
pub async fn HelperFs::rename(self : HelperFs, from : String, to : String) -> Unit {
  ignore(self.ask("files.rename", jo([("from", js(from)), ("to", js(to))])))
}

///|
pub async fn HelperFs::mkdir(self : HelperFs, path : String, recursive : Bool) -> Unit {
  ignore(self.ask("files.mkdir", jo([("path", js(path)), ("recursive", jb(recursive))])))
}

///|
pub async fn HelperFs::remove(self : HelperFs, path : String) -> Unit {
  ignore(self.ask("files.remove", jo([("path", js(path))])))
}

///|
pub async fn HelperFs::trash(self : HelperFs, path : String) -> String? {
  match get(Some(self.ask("files.trash", jo([("path", js(path))]))), "to") {
    None | Some(Null) => None
    Some(t) => Some(js_string(t))
  }
}

///|
pub async fn HelperFs::unlink(self : HelperFs, path : String) -> Unit {
  ignore(self.ask("files.unlink", jo([("path", js(path))])))
}
