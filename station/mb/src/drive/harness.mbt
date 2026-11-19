// The harness (reader `--builder harness-drive`): a case a line on stdin, its outcome a line on stdout, for
// station/test/mb-drive.test.ts to hold this package to station/src/drive on the same inputs: `{ok}` or `{error}`.
// A drive is made for each case from what it says (its roots, what is protected, its home, still.fail Helper's grants
// as a fake helper keeps them); a transfers case runs a world of stations to its end.

///|
fn hj(v : Json, name : String) -> Json? {
  match v {
    Object(o) => o.get(name)
    _ => None
  }
}

///|
fn hs(v : Json, name : String) -> String {
  match hj(v, name) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn hso(v : Json, name : String) -> String? {
  match hj(v, name) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn hn(v : Json, name : String) -> Double {
  match hj(v, name) {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
fn hno(v : Json, name : String) -> Double? {
  match hj(v, name) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn hb(v : Json, name : String) -> Bool {
  hj(v, name) is Some(True)
}

///|
fn hstrs(v : Json, name : String) -> Array[String] {
  match hj(v, name) {
    Some(Array(a)) =>
      a.filter_map(x => match x {
        String(s) => Some(s)
        _ => None
      })
    _ => []
  }
}

///|
/// Json as a JavaScript value (its keys in their order).
pub fn to_jv(v : Json) -> JV {
  @jsjson.JValue::of_json(v)
}

///|
/// A JavaScript value as Json.
pub fn of_jv(v : JV) -> Json {
  v.to_json_lossy()
}

///|
/// A refusal as the tests compare it.
fn error_json(e : Error) -> Json {
  match e {
    DriveError(d) => {
      let o : Map[String, Json] = { "code": j(d.code), "message": j(d.message) }
      if d.have is Some(h) {
        o.set("have", j(h))
      }
      if d.about is Some(a) {
        o.set("about", j(a))
      }
      if d.need is Some(n) {
        o.set("need", { "grant": j(n.grant), "top": j(n.top), "window": j(n.window) })
      }
      Json::object(o)
    }
    TooBig => { "code": j("TooBig") }
    Refused(m) => { "refused": j(m) }
    FsError(f) => { "fs": j(f.code), "message": j(f.message) }
    e => { "other": j(e.to_string()) }
  }
}

///|
/// What a fake still.fail Helper was asked (its windows, its looks).
priv struct HelperLog {
  asked : Array[Json]
  checked : Array[Json]
}

///|
/// Which grant opens a protected folder, as the fake helper names it.
fn grant_of_top(top : String) -> String {
  match basename(top).to_lower() {
    "documents" => "documents"
    "desktop" => "desktop"
    "downloads" => "downloads"
    _ => "removable"
  }
}

///|
/// A fake still.fail Helper (the test's own, the same on both sides): its operations the station's own, after the
/// helper's checks (out of the roots it is told, the station's own data, a folder whose grant it lacks).
fn fake_helper(
  grants : Map[String, String],
  home : String,
  mounts : Array[String],
  log : HelperLog,
) -> Protected {
  let d = direct()
  {
    fs: fn(roots, protect) {
      let check = (p : String) => {
        if !roots.iter().any(r => within(p, r)) {
          raise fs_error("outside", "out of the roots")
        }
        if protect.iter().any(x => within(p, x)) {
          raise fs_error("protected", "the station's own")
        }
        match protected_place(p, home, mounts) {
          Some({ helper: true, top }) if grants.get(top) != Some("granted") =>
            raise FsError({
              code: "grant",
              message: "no grant",
              grant: Some(grant_of_top(top)),
              top: Some(top),
            })
          _ => ()
        }
      }
      {
        helper: true,
        list: fn(p, most) {
          check(p)
          (d.list)(p, most)
        },
        names: fn(p) {
          check(p)
          (d.names)(p)
        },
        stat: fn(p) {
          check(p)
          (d.stat)(p)
        },
        lstat: fn(p) {
          check(p)
          (d.lstat)(p)
        },
        real: fn(p) {
          check(p)
          (d.real)(p)
        },
        read: fn(p, o, l) {
          check(p)
          (d.read)(p, o, l)
        },
        read_all: fn(p) {
          check(p)
          (d.read_all)(p)
        },
        copy_to: fn(p, to) {
          check(p)
          (d.copy_to)(p, to)
        },
        write: fn(p, w) {
          check(p)
          (d.write)(p, w)
        },
        rename: fn(a, b) {
          check(a)
          check(b)
          (d.rename)(a, b)
        },
        mkdir: fn(p, r) {
          check(p)
          (d.mkdir)(p, r)
        },
        remove: fn(p) {
          check(p)
          (d.remove)(p)
        },
        trash: fn(p, now, h) {
          check(p)
          (d.trash)(p, now, h)
        },
        unlink: fn(p) {
          check(p)
          (d.unlink)(p)
        },
      }
    },
    known: fn(top) {
      match grants.get(top) {
        Some(state) => Some((grant_of_top(top), state))
        None => None
      }
    },
    check: tops => log.checked.push(Json::array(tops.map(t => j(t)))),
    ask: fn(grant, top) {
      log.asked.push(Json::array([j(grant), j(top)]))
      "up"
    },
  }
}

///|
/// A drive as a case says it: `{config, protect, home, now?, mounts?, disks?, helper?: {grants}}`.
fn drive_of(spec : Json, log : HelperLog) -> Drive {
  let config = hj(spec, "config").unwrap_or(Json::object({}))
  let protect = hstrs(spec, "protect")
  let home = hso(spec, "home")
  let mounts = hstrs(spec, "mounts")
  let files = match hj(spec, "helper") {
    Some(h) => {
      let grants = Map::new()
      match hj(h, "grants") {
        Some(Object(o)) =>
          for p in o.to_array() {
            if p.1 is String(s) {
              grants.set(p.0, s)
            }
          }
        _ => ()
      }
      Some(fake_helper(grants, home.unwrap_or(homedir()), mounts, log))
    }
    None => None
  }
  let given_disks = match hj(spec, "disks") {
    Some(Array(a)) =>
      Some(
        a.filter_map(x => match x {
          Array([String(n), String(p)]) => Some((n, p))
          _ => None
        }),
      )
    _ => None
  }
  let now = hno(spec, "now")
  Drive::new({
    config: () => config,
    protect: () => protect,
    now: match now {
      Some(n) => Some(() => n)
      None => None
    },
    files,
    home,
    mounts: () => mounts,
    disks: fn(h) {
      match given_disks {
        Some(d) => d
        None => disks(h)
      }
    },
  })
}

///|
fn entry_list(es : Array[Entry]) -> Json {
  Json::array(es.map(e => e.to_json()))
}

///|
/// One operation of a drive (`op`), its outcome as Json.
fn drive_case(c : Json) -> Json raise {
  let log : HelperLog = { asked: [], checked: [] }
  let spec = hj(c, "drive").unwrap_or(Json::null())
  let base = drive_of(spec, log)
  let drive = match hso(c, "scoped") {
    Some(ws) => base.scoped(ws)
    None => base
  }
  let root = hs(c, "root")
  let path = hs(c, "path")
  let anywhere = hb(c, "anywhere")
  let outcome : Map[String, Json] = try {
    let ok : Json = match hs(c, "op") {
      "roots" => Json::array(drive.roots().map(r => r.to_json()))
      "rootView" => drive.root_view(path).to_json()
      "place" => {
        let p = drive.place(root, path, anywhere)
        {
          "root": j(p.root),
          "top": j(p.top),
          "asked": j(p.asked),
          "found": j(p.found),
          "entry": j(p.entry),
          "parts": Json::array(p.parts.map(x => j(x))),
          "helper": j(p.fs.helper),
          "scope": j(p.scope),
        }
      }
      "locate" => {
        let (found, entry) = drive.locate(root, path, anywhere)
        { "found": j(found), "entry": j(entry) }
      }
      "list" => {
        let (p, es, more) = drive.list(root, path, anywhere)
        { "path": j(p), "entries": entry_list(es), "truncated": j(more) }
      }
      "stat" => drive.stat(root, path, anywhere).to_json()
      "read" => {
        let r = drive.read(root, path, hn(c, "offset"), hn(c, "length"), anywhere)
        {
          "bytes": j(base64(r.bytes)),
          "total": j(r.total),
          "mtime": j(r.mtime),
          "type": j(r.type_),
        }
      }
      "file" => {
        let f = drive.file(root, path, anywhere)
        match (f.copy, hso(c, "copyTo")) {
          (Some(copy), Some(to)) => copy(to)
          _ => ()
        }
        {
          "found": j(f.found),
          "name": j(f.name),
          "size": j(f.size),
          "mtime": j(f.mtime),
          "copy": j(f.copy is Some(_)),
        }
      }
      "upload" => {
        let body = from_base64(hs(c, "body"))
        let (have, entry) = drive.upload(
          root,
          path,
          hs(c, "id"),
          hn(c, "offset"),
          hn(c, "total"),
          body,
          hb(c, "replace"),
          anywhere,
        )
        {
          "have": j(have),
          "entry": match entry {
            Some(e) => e.to_json()
            None => Json::null()
          },
        }
      }
      "mkdir" => drive.mkdir(root, path, anywhere).to_json()
      "rename" => drive.rename(root, path, hs(c, "to"), anywhere).to_json()
      "remove" => {
        drive.remove(root, path, anywhere, hb(c, "permanent"))
        Json::null()
      }
      "stage" => {
        let into = hs(c, "into")
        let (name, to, size) = drive.stage(
          root,
          path,
          n => (n, join([into, n])),
          hn(c, "most"),
          anywhere,
          hb(c, "zip"),
        )
        { "name": j(name), "path": j(to), "size": j(size) }
      }
      "zip" => {
        let (r, p, n, size) = drive.zip(root, path, hn(c, "most"), anywhere)
        { "root": j(r), "path": j(p), "name": j(n), "size": j(size) }
      }
      "folderToWatch" => j(drive.folder_to_watch(root, path, anywhere))
      "folders" => drive.folders(path, hs(c, "home"), hs(c, "lang"))
      "checkRoot" => j(drive.check_root(path))
      op => raise Failure("no op \{op}")
    }
    { "ok": ok }
  } catch {
    e => { "error": error_json(e) }
  }
  outcome.set("asked", Json::array(log.asked))
  outcome.set("checked", Json::array(log.checked))
  Json::object(outcome)
}

///|
/// What pure functions say.
fn pure_case(c : Json) -> Json raise {
  match hs(c, "fn") {
    "typeOf" => Json::array(hstrs(c, "names").map(n => j(type_of(n))))
    "rootsOf" =>
      Json::array(
        roots_of(hj(c, "raw").unwrap_or(Json::null()), workspace?=hso(c, "workspace")).map(r => j(
          r,
        )),
      )
    "rootName" => Json::array(hstrs(c, "paths").map(p => j(root_name(p))))
    "collate" =>
      Json::array(
        match hj(c, "pairs") {
          Some(Array(ps)) =>
            ps.map(p => match p {
              Array([String(a), String(b)]) => j(collate(a, b))
              _ => Json::null()
            })
          _ => []
        },
      )
    "sort" => Json::array(stable_sort(hstrs(c, "names"), collate).map(n => j(n)))
    "free" => {
      let taken = hstrs(c, "taken")
      j(free(hs(c, "name"), hb(c, "dir"), n => taken.contains(n)))
    }
    "shown" => of_jv(shown(to_jv(hj(c, "t").unwrap_or(Json::null()))))
    "covers" => {
      let g = to_jv(hj(c, "grant").unwrap_or(Json::null()))
      Json::array(hstrs(c, "paths").map(p => j(covers(g, p))))
    }
    "sign" =>
      j(sign(unhex(hs(c, "key")), to_jv(hj(c, "grant").unwrap_or(Json::null()))))
    "verify" => {
      let g = verify(
        unhex(hs(c, "key")),
        match hj(c, "grant") {
          Some(v) => Some(to_jv(v))
          None => None
        },
        hso(c, "workspace"),
        hn(c, "now"),
      ) catch {
        e => return { "refused": error_json(e) }
      }
      of_jv(g)
    }
    "encodeURI" => Json::array(hstrs(c, "texts").map(t => j(encode_uri(t))))
    "dos" =>
      Json::array(
        match hj(c, "times") {
          Some(Array(ts)) =>
            ts.map(t => match t {
              Number(ms, ..) => {
                let (time, date) = dos(ms)
                Json::array([j(time), j(date)])
              }
              _ => Json::null()
            })
          _ => []
        },
      )
    "crc32" => {
      let mut crc = 0U
      for piece in hstrs(c, "pieces") {
        crc = crc32(from_base64(piece), crc)
      }
      j(crc.to_double())
    }
    "idOf" => Json::array(hstrs(c, "paths").map(p => j(id_of(p))))
    "wanted" =>
      Json::array(
        hstrs(c, "names").map(n => Json::array([j(image_wanted(n)), j(video_wanted(n))])),
      )
    "posterPath" => j(poster_path(hs(c, "video"), hs(c, "thumbs")))
    "protectedPlace" => {
      let w = protected_place_soon(hs(c, "path"), hs(c, "home"), hstrs(c, "mounts"))
      match w {
        Some(w) => { "top": j(w.top), "helper": j(w.helper) }
        None => Json::null()
      }
    }
    "isPart" => Json::array(hstrs(c, "names").map(n => j(is_part(n))))
    "codeStatus" => Json::array(hstrs(c, "codes").map(n => j(code_status(n))))
    "placeWord" =>
      Json::array(
        hstrs(c, "names").map(n => j(place_word(hs(c, "lang"), n))),
      )
    "rootView" => root_view(hs(c, "path")).to_json()
    "dropFolder" => j(drop_folder(hs(c, "home")))
    "disks" =>
      Json::array(disks(hs(c, "home")).map(d => Json::array([j(d.0), j(d.1)])))
    "hmac" => j(hex(hmac_sha256(unhex(hs(c, "key")), from_base64(hs(c, "data")))))
    "base64" => Json::array([j(base64(from_base64(hs(c, "data")))), j(base64url(from_base64(hs(c, "data"))))])
    "grantKey" => j(hex(grant_key(hs(c, "data"))))
    "safeInteger" =>
      Json::array(
        match hj(c, "values") {
          Some(Array(vs)) =>
            vs.map(v => match v {
              Number(n, ..) => j(safe_integer(n))
              _ => j(false)
            })
          _ => []
        },
      )
    f => raise Failure("no fn \{f}")
  }
}

///|
/// A folder zipped (zip.ts `zipFolder`): its size, or TooBig.
fn zip_case(c : Json) -> Json {
  let skip_names = hstrs(c, "skip")
  try {
    let size = zip_folder(
      hs(c, "dir"),
      hs(c, "to"),
      hn(c, "most"),
      (_, n) => skip_names.contains(n),
      direct(),
    )
    { "ok": j(size) }
  } catch {
    e => { "error": error_json(e) }
  }
}

///|
/// trash.ts `toTrash`.
fn trash_case(c : Json) -> Json {
  try {
    match to_trash(hs(c, "entry"), hso(c, "trash"), hn(c, "now"), hso(c, "home")) {
      Some(p) => { "ok": j(p) }
      None => { "ok": Json::null() }
    }
  } catch {
    e => { "error": error_json(e) }
  }
}

///|
/// thumbs.ts `kept`, `thumbnail` and `keep` with codecs that say what the case gives (a thumbnail named
/// `<id>.jpg` written where asked; a hash of the file's name).
async fn thumbs_case(c : Json) -> Json {
  let thumbs = hs(c, "thumbs")
  let codecs : Codecs? = if hb(c, "noCodecs") {
    None
  } else {
    Some({
      thumbnail: fn(image, dir) {
        if !image_wanted(image) {
          return None
        }
        let path = join([dir, "\{id_of(image)}.jpg"])
        write_private(path, "thumb of \{image}")
        Some({ path, type_: "image/jpeg" })
      },
      thumbhash: fn(image, _dir) {
        if basename(image).has_prefix("bad") {
          raise fs_error("EIO", "not an image")
        }
        Some(("hash:\{basename(image)}", 4.0, 3.0))
      },
    })
  }
  try {
    match hs(c, "op") {
      "kept" => {
        let k = kept(thumbs, hs(c, "id"), since?=hno(c, "since"))
        match k {
          Some(t) => { "ok": { "path": j(t.path), "type": j(t.type_) } }
          None => { "ok": Json::null() }
        }
      }
      "thumbnail" => {
        let t = thumbnail(hs(c, "image"), thumbs, codecs, since?=hno(c, "since"))
        match t {
          Some(t) => { "ok": { "path": j(t.path), "type": j(t.type_) } }
          None => { "ok": Json::null() }
        }
      }
      "keep" =>
        match hj(c, "files") {
          Some(Array(fs)) =>
            {
              "ok": Json::array(
                keep(fs.map(to_jv), thumbs, codecs).map(of_jv),
              ),
            }
          _ => { "ok": Json::array([]) }
        }
      "poster" => {
        // Programs that make nothing: what posters.ts finds without making one.
        let makers : Makers = { quicklook: false, run: async fn(_, _) { false } }
        match poster(hs(c, "video"), thumbs, makers, since?=hno(c, "since")) {
          Some(p) => { "ok": j(p) }
          None => { "ok": Json::null() }
        }
      }
      op => { "error": j("no op \{op}") }
    }
  } catch {
    e => { "error": error_json(e) }
  }
}

///|
/// A peer's request of a drive (module.ts `driveForPeer`): its JSON and the bytes after it (base64), or its refusal.
async fn peer_case(c : Json) -> Json {
  let log : HelperLog = { asked: [], checked: [] }
  let drive = drive_of(hj(c, "drive").unwrap_or(Json::null()), log)
  try {
    let a = drive_for_peer(
      drive,
      unhex(hs(c, "key")),
      to_jv(hj(c, "request").unwrap_or(Json::null())),
      hso(c, "workspace"),
      hn(c, "now"),
    )
    let o : Map[String, Json] = { "json": of_jv(a.json) }
    if a.bytes is Some((next, _)) {
      let all = @buffer.new()
      let pieces = []
      while true {
        match next() {
          Some(b) => {
            all.write_bytes(b)
            pieces.push(j(b.length()))
          }
          None => break
        }
      }
      o.set("bytes", j(base64(all.to_bytes())))
      o.set("pieces", Json::array(pieces))
    }
    { "ok": Json::object(o) }
  } catch {
    e => { "error": error_json(e) }
  }
}

///|
/// A clock of the harness's own (watch cases): timers fired in their order as it is moved on.
priv struct FakeClock {
  mut now : Double
  timers : Array[(Int, Double, () -> Unit)]
  mut next : Int
}

///|
fn FakeClock::clock(self : FakeClock) -> Clock {
  {
    now: () => self.now,
    after: fn(ms, f) {
      self.next += 1
      let id = self.next
      self.timers.push((id, self.now + ms, f))
      fn() {
        for i, t in self.timers {
          if t.0 == id {
            self.timers.remove(i) |> ignore
            return
          }
        }
      }
    },
  }
}

///|
fn FakeClock::advance(self : FakeClock, ms : Double) -> Unit {
  let until = self.now + ms
  while true {
    let mut best = -1
    for i, t in self.timers {
      if t.1 <= until && (best < 0 || t.1 < self.timers[best].1) {
        best = i
      }
    }
    if best < 0 {
      break
    }
    let t = self.timers.remove(best)
    self.now = t.1
    (t.2)()
  }
  self.now = until
}

///|
/// A script of folder watches (watch.ts `FolderWatches`) on a clock of its own: what each asking was told and when,
/// and how many watches were opened, closed and are open.
fn watch_case(c : Json) -> Json {
  let fake : FakeClock = { now: 0.0, timers: [], next: 0 }
  let handlers : Map[String, (() -> Unit, () -> Unit)] = {}
  let mut opened = 0
  let mut closed = 0
  let refuse = hstrs(c, "refuse")
  let watches = FolderWatches::new(
    held=hn(c, "held"),
    kept=hn(c, "kept"),
    fake.clock(),
    fn(dir, change, error) {
      if refuse.contains(dir) {
        raise fs_error("ENOENT", "no such folder")
      }
      opened += 1
      handlers.set(dir, (change, error))
      { close: () => closed += 1 }
    },
  )
  let log : Array[Json] = []
  let stops : Map[String, () -> Unit] = {}
  let steps = match hj(c, "steps") {
    Some(Array(s)) => s
    _ => []
  }
  for s in steps {
    match hs(s, "do") {
      "changed" => {
        let tag = hs(s, "tag")
        watches.changed(hs(s, "dir"), hs(s, "id"), yes => log.push(
          Json::array([j(tag), j(yes), j(fake.now)]),
        ))
      }
      "follow" => {
        let tag = hs(s, "tag")
        match watches.follow(hs(s, "dir"), () => log.push(Json::array([j(tag), j("told"), j(fake.now)]))) {
          Some(stop) => stops.set(tag, stop)
          None => log.push(Json::array([j(tag), Json::null(), j(fake.now)]))
        }
      }
      "emit" =>
        match handlers.get(hs(s, "dir")) {
          Some((change, error)) => if hs(s, "ev") == "error" { error() } else { change() }
          None => ()
        }
      "advance" => fake.advance(hn(s, "ms"))
      "stop" =>
        match stops.get(hs(s, "tag")) {
          Some(f) => f()
          None => ()
        }
      "close" => watches.close()
      _ => ()
    }
  }
  {
    "ok": {
      "log": Json::array(log),
      "opened": j(opened),
      "closed": j(closed),
      "open": j(watches.size()),
    },
  }
}

///|
/// A world of stations a transfers case runs (transfers.ts with module.ts): `{stations: {name: drive}, into, key,
/// now, steps, hooks}`; what each transfer came to, what was told, and each one's kept file.
async fn transfers_case(c : Json) -> Json {
  let log : HelperLog = { asked: [], checked: [] }
  let key = unhex(hs(c, "key"))
  let now = hn(c, "now")
  let drives : Map[String, Drive] = {}
  match hj(c, "stations") {
    Some(Object(o)) => for p in o.to_array() {
      drives.set(p.0, drive_of(p.1, log))
    }
    _ => ()
  }
  let into = drives.get(hs(c, "into")).unwrap()
  let dir = hs(c, "dir")
  let hooks = hj(c, "hooks").unwrap_or(Json::object({}))
  let tags : Map[String, String] = {}
  let ids : Map[String, String] = {}
  let told : Array[Json] = []
  let away : Ref[Bool] = { val: hb(hooks, "away") }
  let tag_of = (id : String) => ids.get(id).unwrap_or("<started>")
  let ask = async fn(station : String, request : JV) -> Answer {
    let drive = drives.get(station)
    guard drive is Some(drive) else { raise Failure("no such station") }
    let req = @jsjson.parse(@jsjson.stringify(request))
    let got = drive_for_peer(drive, key, req, ostr(req, "workspace"), now)
    match (got.bytes, away.val) {
      (Some((next, stop)), true) => {
        let mut gave = false
        let more = async fn() -> Bytes? {
          if gave {
            raise Failure("station is not reachable")
          }
          match next() {
            Some(b) => {
              gave = true
              Some(b[0:if b.length() > 262144 { 262144 } else { b.length() }].to_bytes())
            }
            None => None
          }
        }
        { json: got.json, bytes: Some((more, stop)) }
      }
      _ => got
    }
  }
  let transfers_ref : Ref[Transfers?] = { val: None }
  let fake_source = hso(hooks, "source")
  let remote = (t : JV) => match fake_source {
    Some("cancelAt4") => {
      let tid = ostr(t, "id").unwrap_or("")
      {
        station: Some("A"),
        part: 4.0,
        walk: async fn(_) { [item("f.txt", false, 12.0)] },
        read: async fn(_, offset, _) {
          if offset == 4.0 {
            transfers_ref.val.unwrap().cancel("a@x", tid) |> ignore
          }
          let text = "abcdefghijkl"
          let o = offset.to_int()
          let e = if o + 4 > text.length() { text.length() } else { o + 4 }
          (@utf8.encode(text.unsafe_substring(start=o, end=e)), 12.0, 5.0)
        },
        release: async fn(_) {  },
      }
    }
    Some("changed") => {
      let mtime : Ref[Double] = { val: 1.0 }
      let content = () => if mtime.val == 1.0 {
        "old-old-old!"
      } else {
        "new-new-new-new!"
      }
      {
        station: Some("A"),
        part: 4.0,
        walk: async fn(_) { [item("f.txt", false, 12.0)] },
        read: async fn(_, offset, _) {
          let text = content()
          let o = offset.to_int()
          let e = if o + 4 > text.length() { text.length() } else { o + 4 }
          let got = (
            @utf8.encode(text.unsafe_substring(start=o, end=e)),
            text.length().to_double(),
            mtime.val,
          )
          if offset == 4.0 {
            mtime.val = 2.0
          }
          got
        },
        release: async fn(_) {  },
      }
    }
    _ => peer_source(ask, t)
  }
  let make = () => {
    let t = Transfers::new({
      dir,
      drive_for: _ => into,
      remote,
      now: () => now,
      changed: t => {
        let id = ostr(t, "id").unwrap_or("")
        told.push(Json::array([j(tag_of(id)), j(ostr(t, "state").unwrap_or(""))]))
      },
      rt: @effect.runtime(),
    })
    transfers_ref.val = Some(t)
    t
  }
  let grant_for = (spec : Json) => {
    let s = to_jv(spec)
    match oget(oget(s, "from").unwrap_or(Null), "grant") {
      Some(Obj(_) as g) => {
        let from = oget(s, "from").unwrap()
        oset(from, "grant", jvs(sign(key, g)))
      }
      _ => ()
    }
    s
  }
  let start = (tag : String, spec : Json) => {
    let t = transfers_ref.val.unwrap().start(grant_for(spec))
    let id = ostr(t, "id").unwrap_or("")
    tags.set(tag, id)
    ids.set(id, tag)
  }
  make() |> ignore
  // The listing hooks: one cut short (`truncate`), one during which a transfer is cancelled and another started.
  match hj(hooks, "truncate") {
    Some(tr) => {
      let at = drives.get(hs(tr, "station")).unwrap()
      let path = hs(tr, "path")
      let drop = hs(tr, "drop")
      at.set_shape(
        Some(fn(p, got) {
          if p == path {
            (got.0, got.1.filter(e => e.name != drop), true)
          } else {
            got
          }
        }),
      )
    }
    None => ()
  }
  match hj(hooks, "cancelOnList") {
    Some(h) => {
      let path = hs(h, "path")
      let mut held = false
      into.set_shape(
        Some(fn(p, got) {
          if p == path && !held {
            held = true
            let tr = transfers_ref.val.unwrap()
            tr.cancel("a@x", tags.get(hs(h, "tag")).unwrap_or("")) |> ignore
            start(hs(h, "thenTag"), hj(h, "then").unwrap_or(Json::null())) catch {
              _ => ()
            }
          }
          got
        }),
      )
    }
    None => ()
  }
  let steps = match hj(c, "steps") {
    Some(Array(s)) => s
    _ => []
  }
  let errors : Array[Json] = []
  for s in steps {
    let tr = transfers_ref.val.unwrap()
    try {
      match hs(s, "do") {
        "start" => start(hs(s, "tag"), hj(s, "spec").unwrap_or(Json::null()))
        "idle" => tr.idle()
        "retry" => tr.retry("a@x", tags.get(hs(s, "tag")).unwrap_or("")) |> ignore
        "cancel" => tr.cancel("a@x", tags.get(hs(s, "tag")).unwrap_or("")) |> ignore
        "away" => away.val = hb(s, "value")
        "unhook" =>
          for d in drives.values() {
            d.set_shape(None)
          }
        "reopen" => {
          tr.close()
          make() |> ignore
        }
        _ => ()
      }
    } catch {
      e => errors.push(Json::array([j(hs(s, "do")), error_json(e)]))
    }
  }
  let tr = transfers_ref.val.unwrap()
  let out : Map[String, Json] = {}
  let files : Map[String, Json] = {}
  for p in tags.to_array() {
    let (tag, id) = p
    match tr.get(id) {
      Some(t) => out.set(tag, of_jv(t))
      None => out.set(tag, Json::null())
    }
    files.set(
      tag,
      match attempt(() => read_all(join([dir, "\{id}.json"]))) {
        Ok(b) => j(@utf8.decode_lossy(b).replace_all(old=id, new="<\{tag}>"))
        Err(_) => Json::null()
      },
    )
  }
  tr.close()
  {
    "ok": {
      "transfers": Json::object(out),
      "told": Json::array(told),
      "files": Json::object(files),
      "errors": Json::array(errors),
    },
  }
}

///|
async fn harness_case(c : Json) -> Json {
  wall_now.val = () => hno(c, "wall").unwrap_or(wall_clock())
  match hs(c, "kind") {
    "drive" => drive_case(c) catch { e => { "error": error_json(e) } }
    "zip" => zip_case(c)
    "trash" => trash_case(c)
    "thumbs" => thumbs_case(c)
    "peer" => peer_case(c)
    "watch" => watch_case(c)
    "transfers" => transfers_case(c)
    _ =>
      try { { "ok": pure_case(c) } } catch {
        e => { "error": error_json(e) }
      }
  }
}

///|
/// The harness: cases a line each, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  while true {
    guard host.line() is Some(line) else { break }
    let answer = match (try Some(@json.parse(line)) catch { _ => None }) {
      Some(c) => harness_case(c)
      None => { "error": "not JSON" }
    }
    host.say(answer.stringify())
  }
}
