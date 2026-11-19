// A chat handed over, on the station it goes to (handover.ts, its second half): what this station answers of it
// (`handover.*`), its files placed and pruned, its rows put in through the store, hidden until it is shown, and what a
// hand-over that did not go put in, taken out. And the calls of chats handed away before their calls went with them.

///|
/// Whether this station holds hand-over `id`'s drop.
fn Handover::is_dropping(self : Handover, id : String) -> Bool {
  self.dropping.contains(id)
}

///|
fn Handover::ask_still(self : Handover, i : Rec) -> Unit {
  let id = i.s("id")
  if i.s("step") != "coming" || i.b("dropping") || self.asking.contains(id) || self.in_work.contains(id) {
    return
  }
  self.asking[id] = true
  self.w.go(async fn() {
    try {
      let a = self.w.ask(i.s("origin"), jo([("method", js("handover.still")), ("workspace", js(i.s("ws"))), ("origin", jopt((self.d.here)())), ("id", js(id))]))
      remove_str(self.unsure, id)
      if at(a, "going") is Some(Bool(false)) && i.s("step") == "coming" {
        self.w.info("handover", "a chat coming here no longer goes on where it came from: dropped here", jo([("id", js(id)), ("from", js(head_of(i.s("origin"), 12)))]))
        self.drop_soon(i).0.wait()
      }
    } catch {
      _ => ()
    }
    self.asking.remove(id)
  })
}

///|
/// What this station answers of it (`handover.*`), from stations of the chat's workspace, of their own chats.
pub async fn Handover::answer(self : Handover, in_workspace : (String, String) -> Bool, peer : String, request : J, body : Body?, workspace : String?) -> J {
  self.loaded_within()
  let fs = self.w.fs
  let d = self.d
  let ws = str_at(request, "workspace").unwrap_or("")
  let id = str_at(request, "id").unwrap_or("")
  if !is_workspace(ws) || (workspace is Some(w) && w != ws) || !in_workspace(peer, ws) || str_at(request, "origin") != Some(peer) {
    raise refused(self.why("notStationOfWs"))
  }
  if !is_handover_id(id) {
    raise refused(self.why("badRequest", args=[("detail", "not a hand-over")]))
  }
  let method = str_at(request, "method").unwrap_or("")
  if method == "handover.begin" {
    let t0 = self.w.now()
    let answer = self.begin(peer, ws, id, request)
    self.spent(self.ins.get(id), "begin", t0)
    return answer
  }
  if method == "handover.still" {
    let going = match self.outs.get(id) {
      Some(o) => o.s("to") == peer && o.s("step") != "failed"
      None => false
    }
    return jo([("going", jb(going))])
  }
  if method == "handover.held" {
    let held = match self.ins.get(id) {
      Some(i) => i.s("origin") == peer && i.s("step") != "dropped" && !i.b("dropping") && !self.is_dropping(id)
      None => false
    }
    return jo([("held", jb(held))])
  }
  if method == "handover.usage" {
    return self.take_usage(peer, ws, request)
  }
  let found = self.ins.get(id)
  if method == "handover.drop" {
    match found {
      None => return jo([("ok", jb(true))])
      Some(i) => {
        if i.s("step") == "dropped" {
          return jo([("ok", jb(true))])
        }
        if i.s("step") == "shown" {
          raise refused(self.why("shownHere"))
        }
        self.drop_soon(i).0.wait()
        return jo([("ok", jb(true))])
      }
    }
  }
  guard found is Some(i) && i.s("origin") == peer else {
    raise refused(self.why("badRequest", args=[("detail", "not begun: handover.begin first")]))
  }
  if i.s("step") == "dropped" || i.b("dropping") || self.is_dropping(i.s("id")) {
    raise refused(self.why("droppedThere"))
  }
  let t0 = self.w.now()
  let kind = if method.has_prefix("handover.") { method.unsafe_substring(start=9, end=method.length()) } else { method }
  let answer = async fn() -> J {
    match method {
      "handover.lacking" => {
        let hashes = items(at(request, "hashes"))
        let all = hashes.iter().all(h => match str_of(Some(h)) {
          Some(x) => is_hash(x)
          None => false
        })
        if hashes.length() > d.lack_most || !all {
          raise refused(self.why("badRequest", args=[("detail", "too many hashes")]))
        }
        let hs = strings_of(Some(Arr(hashes)))
        let lacking = lacking_in(fs, in_files(fs, d.data, id), hs)
        let older_out = self.ins_at(i.keys(), "lacking").iter().any(o => o.s("id") != i.s("id") && self.drops.contains(o.s("id")))
        let files_all = items(at(request, "files"))
        let files = if files_all.length() > d.lack_most { files_all[0:d.lack_most].to_array() } else { files_all }
        let rooms : Map[String, String] = {}
        let placed : Map[String, Bool] = {}
        let missing : Map[String, Bool] = {}
        let unchecked : Array[String] = []
        let budget = Ref(d.hash_most)
        let from_data = text_at(i.get("ctx").unwrap_or(Null), "fromData")
        for f in files {
          if older_out {
            break
          }
          let hash = text_at(f, "hash")
          if !lacking.contains(hash) || missing.contains(hash) || unchecked.contains(hash) {
            continue
          }
          guard str_at(f, "path") is Some(path) else { continue }
          let room = match str_at(f, "room") {
            Some(r) => {
              let real = match rooms.get(r) {
                Some(x) => x
                None => real_of_soon(fs, moved(fs, r, from_data, d.data))
              }
              rooms[r] = real
              Some(real)
            }
            None => None
          }
          let placed_is = in_place(fs, carried_to(fs, path, from_data, d.data, room), d.data, f, budget, d.hash_most)
          if placed_is == "yes" {
            placed[hash] = true
          } else if placed_is == "later" {
            unchecked.push(hash)
          } else {
            missing[hash] = true
          }
        }
        let out = [
          (
            "lacking",
            jstrs(hs.filter(h => lacking.contains(h) && (older_out || missing.contains(h) || unchecked.contains(h) || !placed.contains(h)))),
          ),
        ]
        if unchecked.length() > 0 {
          out.push(("unchecked", jstrs(uniq(unchecked).filter(h => !missing.contains(h)))))
        }
        out.push(("pack", js(pack_encoding)))
        jo(out)
      }
      "handover.prune" => self.step(peer, i, request, async fn() { self.serial_in(i, async fn() { self.prune(i) }) }, None)
      "handover.put" => {
        if text_at(request, "pack") == pack_encoding && at(request, "pack") is Some(Str(_)) {
          let named = match at(request, "name") {
            None => None
            v => Some(show_value(v))
          }
          if body is None || (named is Some(n) && !is_hash(n)) {
            raise refused(self.why("badRequest", args=[("detail", "not a pack")]))
          }
          receive_pack(fs, in_files(fs, d.data, id), body.unwrap(), {
            strict: !(at(request, "strict") is Some(Bool(false))),
            flush: d.flush is None,
            name: named,
            count: num_at(request, "count").map(n => n.to_int()),
            on_file: Some(async fn() { self.failing("put") }),
          })
          return jo([("ok", jb(true))])
        }
        let name = match at(request, "name") {
          None | Some(Null) => ""
          v => show_value(v)
        }
        if body is None || !is_hash(name) {
          raise refused(self.why("badRequest", args=[("detail", "not a file's hash")]))
        }
        self.failing("put")
        receive_file(fs, in_files(fs, d.data, id), name, body.unwrap(), flush=d.flush is None)
        jo([("ok", jb(true))])
      }
      "handover.place" => {
        let carry = match at(request, "carry") {
          None | Some(Null) => ""
          v => show_value(v)
        }
        if !is_hash(carry) {
          raise refused(self.why("badRequest", args=[("detail", "not a copy's name")]))
        }
        let place = async fn() -> J {
          self.serial_in(i, async fn() { self.place(i, carry) }) catch {
            e => raise self.carry_words(e)
          }
        }
        self.step(peer, i, request, place, Some(self.placing(i, carry)))
      }
      "handover.rows" => {
        let table = match at(request, "table") {
          None | Some(Null) => ""
          v => show_value(v)
        }
        if i.s("step") != "coming" && (i.s("step") != "shown" || !after_shown.contains(table)) {
          raise refused(self.why("shownAlready"))
        }
        let rows = match at(request, "rows") {
          Some(Arr(r)) => r
          _ => raise refused(self.why("badRequest", args=[("detail", "not a page of a chat's rows")]))
        }
        if !chat_tables.contains(table) || rows.length() > 500 {
          raise refused(self.why("badRequest", args=[("detail", "not a page of a chat's rows")]))
        }
        let page = str_at(request, "page")
        if page is Some(p) && i.so("page") == Some(p) {
          return jo([("ok", jb(true))])
        }
        self.failing("import")
        let ctx = self.store("importRows", [
          i.get("ctx").unwrap_or(Null),
          js(table),
          ja(rows),
          if i.s("step") == "coming" {
            js(i.s("id"))
          } else {
            Null
          },
        ])
        match ctx {
          Obj(_) => i.set("ctx", ctx)
          _ => ()
        }
        if i.s("step") == "shown" && usage_tables.contains(table) {
          self.usage_of(i.keys(), false)
        }
        self.failing("imported")
        match page {
          Some(p) => i.set("page", js(p))
          None => ()
        }
        self.save_in(i)
        jo([("ok", jb(true))])
      }
      "handover.counts" => {
        let homes = []
        for k in i.keys() {
          homes.push((k, at(self.store("homeChat", [js(k)]), "id").unwrap_or(Null)))
        }
        jo([("counts", merged(at(i.get("ctx").unwrap_or(Null), "counts").unwrap_or(jo([])), jo([("homes", jo(homes))])))])
      }
      "handover.show" => self.show(i, items(at(request, "sends")))
      _ => raise refused(self.why("badRequest", args=[("detail", "no such hand-over request")]))
    }
  }
  let out = answer() catch {
    e => {
      if kind != "show" {
        self.spent(Some(i), kind, t0)
      }
      raise self.written(i, e)
    }
  }
  if kind != "show" {
    self.spent(Some(i), kind, t0)
  }
  out
}

///|
/// What failed of hand-over `i` here as it is answered: this station's own disk failing what it is sent, the
/// hand-over dropped here and the asker told so in numbers; anything else as it is.
async fn Handover::written(self : Handover, i : Rec, e : Error) -> Error {
  let mut code = code_of(e)
  if code == "" {
    let m = message_of(e)
    for c in write_failed {
      if m.contains(c) {
        code = c
        break
      }
    }
  }
  if !write_failed.contains(code) {
    return e
  }
  self.w.warn("handover", "a chat coming here could not be written: dropped here", jo([("id", js(i.s("id"))), ("error", js(message_of(e)))]))
  let marked = self.drop_soon(i).0
  self.w.go(async fn() {
    marked.wait() catch {
      x => self.w.warn("handover", "a chat coming here not dropped after its write failed", jo([("id", js(i.s("id"))), ("error", js(message_of(x)))]))
    }
  })
  let free = try {
    (self.d.room)().0
  } catch {
    _ => None
  }
  let here = (self.d.here)()
  let name = match ((self.d.roster)(i.s("ws")), here) {
    (Some(r), Some(h)) =>
      match r.search_by(s => s.id == h) {
        Some(x) => r[x].name
        None => ""
      }
    _ => ""
  }
  let who = if name != "" { name } else { head_of(here.unwrap_or(""), 12) }
  refused(
    self.why("fullThere", args=[
      ("station", who),
      (
        "free",
        match free {
          Some(f) => gb(f)
          None => "?"
        },
      ),
      ("error", code),
    ]),
  )
}

///|
/// Work of hand-over `i` that grows with its chat, as `request` asks it: a told step, or by its result as before.
async fn Handover::step(self : Handover, peer : String, i : Rec, request : J, run : async () -> J, measure : (async () -> J)?) -> J {
  match told_key(request) {
    None => run()
    Some(key) => {
      let method = str_at(request, "method").unwrap_or("")
      let kind = method.unsafe_substring(start=9, end=method.length())
      (self.d.told.run)(
        peer,
        key,
        async fn() {
          let t0 = self.w.now()
          let out = run() catch {
            e => {
              self.spent(Some(i), kind, t0)
              raise self.written(i, e)
            }
          }
          self.spent(Some(i), kind, t0)
          out
        },
        measure,
      )
    }
  }
}

///|
/// How far hand-over `i`'s placing of `carry` is, as each beat of its step asks.
fn Handover::placing(self : Handover, i : Rec, carry : String) -> async () -> J {
  let fs = self.w.fs
  let path = fs.join([hdir(fs, self.d.data), "in", i.s("id"), "placed.txt"])
  let offset : Ref[Double?] = Ref(None)
  let done = Ref(0)
  let total : Ref[Double?] = Ref(None)
  async fn() {
    match offset.val {
      None =>
        offset.val = Some(
          match fs.stat(path) {
            Some((_, s, _)) => s
            None => 0.0
          },
        )
      Some(_) => ()
    }
    match total.val {
      None =>
        total.val = Some(
          match fs.read_json(fs.join([in_files(fs, self.d.data, i.s("id")), carry])) {
            Some(idx) =>
              match num_at(idx, "files") {
                Some(n) if n == n => n
                _ => 0.0
              }
            None => 0.0
          },
        )
      Some(_) => ()
    }
    let from = offset.val.unwrap_or(0.0)
    match fs.stat(path) {
      Some((_, size, _)) if size > from => {
        let bytes = fs.files.read_range(path, from, size - from) catch { _ => b"" }
        for k in 0..<bytes.length() {
          if bytes[k] == b'\n' {
            done.val += 1
          }
        }
        offset.val = Some(from + bytes.length().to_double())
      }
      _ => ()
    }
    jo([("done", ji(done.val)), ("total", jn(total.val.unwrap_or(0.0))), ("unit", js("files"))])
  }
}

///|
async fn Handover::begin(self : Handover, origin : String, ws : String, id : String, request : J) -> J {
  let was = self.ins.get(id)
  match was {
    Some(w) if w.s("step") != "coming" => raise refused(self.why("wasAlready", args=[("step", w.s("step"))]))
    Some(w) if w.b("dropping") => raise refused(self.why("droppedThere"))
    _ => ()
  }
  let keys = strings_of(at(request, "keys"))
  if keys.length() == 0 {
    raise refused(self.why("badRequest", args=[("detail", "no chat named")]))
  }
  let live = items(Some(self.store("liveOf", [jstrs(keys)])))
  if live.length() > 0 {
    let here = (self.d.here)()
    let name = match ((self.d.roster)(ws), here) {
      (Some(r), Some(h)) =>
        match r.search_by(s => s.id == h) {
          Some(x) => r[x].name
          None => ""
        }
      _ => ""
    }
    raise refused(self.why("liveThere", args=[("station", if name != "" { name } else { "this station" })]))
  }
  for old in self.ins_at(keys, "begin") {
    if old.s("id") != id && old.s("origin") == origin && old.s("step") == "coming" {
      self.drop_soon(old).0.wait()
    }
  }
  let profiles = []
  let missing = []
  let nowhere = strings_of(at(request, "nowhere"))
  for e in entries(at(request, "accounts")) {
    let (pid, a) = e
    let here = if a is Null {
      None
    } else {
      str_of(Some(self.w.part("accounts.here", [a])))
    }
    if here is None && nowhere.contains(pid) {
      continue
    }
    match here {
      None => missing.push(if text_at(a, "name") != "" { text_at(a, "name") } else { pid })
      Some(h) => profiles.push((pid, h))
    }
  }
  let stopped_for = match at(request, "stoppedFor") {
    Some(Obj(_) as s) =>
      match (str_at(s, "module"), str_at(s, "id")) {
        (Some(m), Some(sid)) => {
          let fields = [("module", js(m)), ("id", js(sid))]
          match str_at(s, "label") {
            Some(l) => fields.push(("label", js(l)))
            None => ()
          }
          jo(fields)
        }
        _ => Null
      }
    _ => Null
  }
  if missing.length() > 0 && stopped_for is Null {
    raise refused(self.why("accountsMissing", args=[("names", missing.join(", "))]))
  }
  if self.d.connects {
    for x in items(at(request, "described")) {
      match (at(x, "known"), at(x, "station"), at(x, "described")) {
        (Some(k), Some(Str(_) as st), Some(desc)) if !(k is Null) && !(desc is Null) =>
          ignore(self.w.part("connects.learnOf", [k, st, desc]))
        _ => ()
      }
    }
  }
  let connects = string_map(at(request, "connects"))
  let bindings = []
  for e in entries(at(request, "bindings")) {
    match e.1 {
      Str(u) => bindings.push((pair_get(connects, e.0).unwrap_or(e.0), @jsjson.sanitize_str(u)))
      _ => ()
    }
  }
  let i = match was {
    Some(w) => w
    None => {
      let ctx_fields = [("from", js(origin))]
      match (self.d.here)() {
        Some(h) => ctx_fields.push(("here", js(h)))
        None => ()
      }
      ctx_fields.push(("fromData", js(show_value(Some(at(request, "dataDir").unwrap_or(js("")))))))
      ctx_fields.push(("toData", js(self.d.data)))
      ctx_fields.push(("connects", pairs_json(connects)))
      ctx_fields.push(("profiles", pairs_json(profiles)))
      ctx_fields.push(("ws", js("coming:\{ws}")))
      {
        j: jo([
          ("id", js(id)),
          ("origin", js(origin)),
          ("keys", jstrs(keys)),
          ("ws", js(ws)),
          ("at", jn(self.w.now())),
          ("step", js("coming")),
          ("carry", Null),
          ("error", Null),
          ("stoppedFor", stopped_for),
          ("bindings", pairs_json(bindings)),
          ("boot", jn((self.d.boot)())),
          ("ctx", new_ctx(jo(ctx_fields))),
        ]),
      }
    }
  }
  self.keep_in(i)
  self.hold_in(i)
  self.save_in(i)
  let (free, total) = try {
    (self.d.room)()
  } catch {
    _ => (None, None)
  }
  let git = (self.d.has_git)() catch { _ => false }
  jo([("ok", jb(true)), ("free", opt_num(free)), ("total", opt_num(total)), ("git", jb(git)), ("usage", jb(true))])
}

///|
async fn Handover::place(self : Handover, i : Rec, carry : String) -> J {
  if !is_hash(carry) {
    raise refused(self.why("badRequest", args=[("detail", "not a copy's name")]))
  }
  let fs = self.w.fs
  let d = self.d
  let id = i.s("id")
  let files = in_files(fs, d.data, id)
  let index = fs.join([files, carry])
  let placed = (d.work.place)(
    d.data,
    index,
    files,
    Some(in_made(fs, d.data, id)),
    Some(in_aside(fs, d.data, id)),
    Some(fs.join([hdir(fs, d.data), "in", id, "placed.txt"])),
    true,
  )
  let c = parse(fs.read_text_strict(index))
  let gits = in_gits(fs, d.data, id)
  match d.git {
    Some(git) if items(at(c, "gits")).length() > 0 =>
      ignore(rebuild_gits(self.w, d.data, d.repos_dir, c, files, git, clone=false, made=Some(async fn(m) { fs.append(gits, "\{stringify(m.to_json())}\n") })))
    _ => ()
  }
  match d.flush {
    Some(f) => f(fs.join([hdir(fs, d.data), "in", id]))
    None => ()
  }
  i.set("carry", js(carry))
  self.save_in(i)
  jo([("ok", jb(true)), ("placed", at(placed, "placed").unwrap_or(Null)), ("missing", at(placed, "missing").unwrap_or(Null))])
}

///|
/// What the chat's room here holds that the lists sent no longer name, removed (put aside).
async fn Handover::prune(self : Handover, i : Rec) -> J {
  guard i.so("carry") is Some(carry) else { return jo([("ok", jb(true)), ("removed", ji(0))]) }
  let fs = self.w.fs
  let d = self.d
  let id = i.s("id")
  let files = in_files(fs, d.data, id)
  let index = parse(fs.read_text_strict(fs.join([files, carry])))
  let index_data = text_at(index, "dataDir")
  let named : Map[String, Bool] = {}
  let mine = fs.join([hdir(fs, d.data), "in", id, "mine"])
  fs.mkdirs(fs.join([mine, "lists"]))
  for s in items(at(index, "sessions")) {
    let list = fs.read_text(fs.join([files, text_at(s, "list")])).unwrap_or("")
    let here = []
    let room_here = real_of_soon(fs, moved(fs, text_at(s, "workspace"), index_data, d.data))
    for line in list.split("\n") {
      let line = line.to_string()
      if line == "" {
        continue
      }
      let f = parse(line) catch { _ => continue }
      let path = carried_to(fs, text_at(f, "path"), index_data, d.data, Some(room_here))
      let f2 = set(f, "path", js(path))
      named[path] = true
      here.push(stringify(f2))
    }
    fs.write_text(list_file(fs, mine, text_at(s, "key")), if here.length() == 0 { "" } else { "\{here.join("\n")}\n" })
  }
  let g = (d.work.gather)(d.data, fs.join([d.data, "stillfail.db"]), i.s("ws"), false, mine, None, Some(i.keys()))
  let own = parse(fs.read_text_strict(text_at(g, "index")))
  let mut removed = 0
  let cli = (path : String) => {
    let rel = fs.relative(d.data, path)
    rel != "" && !rel.has_prefix("..") && !fs.is_absolute(rel) && cli_kept(rel.split(fs.sep).map(v => v.to_string()).collect())
  }
  let prune = async fn(path : String) {
    if !self.put_aside(i, path) {
      return
    }
    removed += 1
    if cli(path) {
      self.emptied(fs.dirname(path))
    }
  }
  for s in items(at(own, "sessions")) {
    let room = text_at(s, "room")
    for line in fs.read_text(text_at(s, "at")).unwrap_or("").split("\n") {
      let line = line.to_string()
      if line == "" {
        continue
      }
      let v = parse(line) catch { _ => continue }
      let path = text_at(v, "path")
      if named.contains(path) || !(path.has_prefix(room + fs.sep) || cli(path)) {
        continue
      }
      if fs.basename(path) == ".git" {
        continue
      }
      named[path] = true
      prune(path)
    }
  }
  let placed = fs.join([hdir(fs, d.data), "in", id, "placed.txt"])
  if fs.there(placed) {
    for line in fs.lines(placed) {
      let path = match line.find("\t") {
        Some(t) => line.unsafe_substring(start=0, end=t)
        None => line.unsafe_substring(start=0, end=line.length() - 1)
      }
      if path == "" || named.contains(path) || !cli(path) {
        continue
      }
      named[path] = true
      prune(path)
    }
  }
  fs.rm_rf(mine)
  jo([("ok", jb(true)), ("removed", ji(removed))])
}

///|
/// Shown: of its workspace here, its agents told once where it runs now.
async fn Handover::show(self : Handover, i : Rec, sends : Array[J]) -> J {
  let t0 = self.w.now()
  let fs = self.w.fs
  let keys = i.keys()
  let homes = []
  for k in keys {
    homes.push(at(self.store("homeChat", [js(k)]), "id"))
  }
  let kept = sends.filter(x => match at(x, "thread") {
    Some(Num(t)) => homes.iter().any(h => h is Some(Num(n)) && n == t)
    _ => false
  })
  ignore(self.w.part("keepSends", [ja(kept)]))
  if i.s("step") == "shown" {
    for k in keys {
      ignore(self.hub("wakeChat", [js(k)]))
    }
    return jo([("ok", jb(true))])
  }
  let home = (self.d.home)()
  match i.get("stoppedFor") {
    Some(Obj(_) as s) => ignore(self.w.part("arrivedStopped", [jstrs(keys), merged(s, jo([("at", js(i.s("origin")))])), js(i.s("ws"))]))
    _ => ()
  }
  for e in entries(i.get("bindings")) {
    if self.store("binding", [js(e.0)]) is Null {
      ignore(self.store("setBinding", [js(e.0), e.1]))
    }
  }
  self.usage_of(keys, true)
  ignore(self.store("showChat", [jstrs(keys), if Some(i.s("ws")) == home { Null } else { js(i.s("ws")) }]))
  let ctx = i.get("ctx").unwrap_or(Null)
  if num_at(at(at(ctx, "counts").unwrap_or(Null), "rows").unwrap_or(Null), "usage").unwrap_or(0.0) > 0.0 {
    ignore(self.store("usageChanged", [jstrs(keys)]))
  }
  self.end_outs(keys)
  self.trim_ins(i)
  let from = match (self.d.roster)(i.s("ws")) {
    Some(r) =>
      match r.search_by(s => s.id == i.s("origin")) {
        Some(x) if r[x].name != "" => r[x].name
        _ => head_of(i.s("origin"), 12)
      }
    None => head_of(i.s("origin"), 12)
  }
  for k in keys {
    let row = self.store("getSession", [js(k)])
    if row is Null {
      continue
    }
    ignore(self.store("setMovedNote", [js(k), js(moved_here(fs, from, text_at(row, "workspace"), text_at(ctx, "fromData"), self.d.data))]))
  }
  i.set("step", js("shown"))
  self.save_in(i)
  self.let_in(i.s("id"))
  ignore(self.store("forgetImport", [js(i.s("id"))]))
  let gone = fs.join([hdir(fs, self.d.data), "in", ".gone-\{i.s("id")}"])
  fs.rename(fs.join([hdir(fs, self.d.data), "in", i.s("id")]), gone) catch {
    _ => ()
  }
  self.w.go(async fn() {
    fs.rm_rf(gone) catch {
      _ => ()
    }
  })
  for k in keys {
    ignore(self.hub("wakeChat", [js(k)]))
  }
  ignore(self.w.part("shown", [jstrs(keys), js(i.s("origin"))]))
  self.spent(Some(i), "show", t0)
  let ms = i.get("spent").unwrap_or(jo([]))
  self.w.info(
    "handover",
    "a chat handed here goes on here",
    jo([
      ("id", js(i.s("id"))),
      ("origin", js(i.s("origin"))),
      ("keys", ji(keys.length())),
      ("ms", ms),
      ("total", jn(js_round(self.w.now() - i.n("at")))),
    ]),
  )
  jo([("ok", jb(true))])
}

///|
/// Sessions `keys`' usage as all their calls here say it.
async fn Handover::usage_of(self : Handover, keys : Array[String], quiet : Bool) -> Unit {
  for k in keys {
    if !(self.w.part("fn.hasUsage", [js(k)]) is Bool(true)) {
      continue
    }
    match self.w.part("fn.usageNow", [js(k)]) {
      Null => ()
      usage => ignore(self.store("setSessionUsage", [js(k), usage, jb(quiet)]))
    }
  }
}

// ── the calls of chats handed away before their calls went with them ──

///|
fn Handover::sync_handed_usage(self : Handover, station : String?) -> Unit {
  if self.closed || !self.ready {
    return
  }
  match station {
    Some(s) if self.usage_caught_up.contains(s) || self.usage_runs.contains(s) => return
    _ => ()
  }
  self.w.go(async fn() {
    let tos = match station {
      Some(s) => [s]
      None => strings_of(Some(self.w.part("fn.handedStations", [])))
    }
    for to in tos {
      if Some(to) == (self.d.here)() || self.usage_caught_up.contains(to) || self.usage_runs.contains(to) {
        continue
      }
      let run = self.w.run(async fn() {
        self.usage_with(to) catch {
          e => self.w.warn("handover", "the calls of chats handed before not sent", jo([("to", js(head_of(to, 12))), ("error", js(message_of(e)))]))
        }
        self.usage_runs.remove(to)
      })
      if !run.is_done() {
        self.usage_runs[to] = run
      }
    }
  })
}

///|
async fn Handover::usage_cursor(self : Handover) -> J {
  match self.usage_synced {
    Some(v) => v
    None => {
      let v = match self.w.fs.read_json(usage_synced_file(self.w.fs, self.d.data)) {
        Some(Obj(_) as o) => o
        _ => jo([])
      }
      match self.usage_synced {
        Some(x) => x
        None => {
          self.usage_synced = Some(v)
          v
        }
      }
    }
  }
}

///|
async fn Handover::save_usage_cursor(self : Handover, synced : J) -> Unit {
  self.usage_synced = Some(synced)
  let before = self.usage_saving
  let fs = self.w.fs
  let path = usage_synced_file(fs, self.d.data)
  let save = self.w.run(async fn() {
    before.settled()
    fs.write_json(path, synced)
  })
  self.usage_saving = save
  save.wait()
}

///|
/// A chat went to `to` without its calls: its chats looked at again from the first.
async fn Handover::usage_again_for(self : Handover, to : String) -> Unit {
  self.usage_caught_up.remove(to)
  self.usage_again[to] = true
  let synced = self.usage_cursor()
  if at(synced, to) is None {
    return
  }
  self.save_usage_cursor(unset(synced, to))
}

///|
async fn Handover::usage_with(self : Handover, to : String) -> Unit {
  let mut sent = 0
  while true {
    if self.closed {
      return
    }
    if self.usage_again.contains(to) {
      self.usage_again.remove(to)
      let synced = self.usage_cursor()
      if !(at(synced, to) is None) {
        self.save_usage_cursor(unset(synced, to))
      }
    }
    let cursor = str_at(self.usage_cursor(), to).unwrap_or("")
    let batch = items(Some(self.w.part("fn.handedWithUsage", [js(to), js(cursor), ji(10)])))
    if batch.length() == 0 {
      break
    }
    for h in batch {
      if self.closed {
        return
      }
      if !self.send_usage(h, to, at(h, "there").unwrap_or(Null), 0) {
        return
      }
      if self.usage_again.contains(to) {
        break
      }
      self.save_usage_cursor(set(self.usage_cursor(), to, at(h, "session").unwrap_or(Null)))
      sent += 1
      @effect.pause()
    }
  }
  self.usage_caught_up[to] = true
  if sent > 0 {
    self.w.info("handover", "the calls of chats handed before sent", jo([("to", js(head_of(to, 12))), ("chats", ji(sent))]))
  }
}

///|
/// The calls of chat `h` handed from here sent to `to`, a page at a time.
async fn Handover::send_usage(self : Handover, h : J, to : String, there : J, hop : Int) -> Bool {
  let here = (self.d.here)()
  let session = text_at(h, "session")
  let ws = match str_at(h, "ws") {
    Some(w) => Some(w)
    None => (self.d.home)()
  }
  guard here is Some(here) && ws is Some(ws) && is_workspace(ws) else { return true }
  match self.outs_of.get(session) {
    Some(xs) if hop == 0 && xs.length() > 0 => {
      let latest = xs[0]
      if latest.s("to") == to && latest.b("usage") && (latest.s("step") == "gone" || latest.s("step") == "done") {
        return true
      }
    }
    _ => ()
  }
  let id = "usage-\{head_of(sha256_text(session), 32)}"
  let connect = text_at(self.store("getSession", [js(session)]), "connect")
  let mut usage_after = J::Null
  let mut files_after = J::Null
  let mut usage_done = false
  let mut files_done = false
  while true {
    let usage = if usage_done { [] } else { items(Some(self.store("chatPage", [js("usage"), js(session), usage_after, ji(500)]))) }
    let files = if files_done { [] } else { items(Some(self.store("chatPage", [js("usage_files"), js(session), files_after, ji(500)]))) }
    usage_done = usage.length() < 500
    files_done = files.length() < 500
    if usage.length() > 0 {
      usage_after = after_of("usage", usage[usage.length() - 1])
    }
    if files.length() > 0 {
      files_after = after_of("usage_files", files[files.length() - 1])
    }
    let last = usage_done && files_done
    let thread_ids = usage.filter_map(r => match at(r, "thread") {
      Some(Num(_) as n) => Some(n)
      _ => None
    })
    let threads = items(Some(self.w.part("fn.threadRefs", [js(session), ja(thread_ids)])))
    let used = uniq([connect, ..threads.map(t => text_at(t, "connect"))].filter(c => c != ""))
    let connects = connects_there(used.filter(c => !is_internal(c)), used, here, to)
    let profiles = uniq(usage.filter_map(r => str_at(r, "profile")))
    let accounts = []
    for p in profiles {
      accounts.push((p, self.w.part("accounts.of", [js(p)])))
    }
    let session_usage = if last {
      match items(Some(self.store("chatPage", [js("session_usage"), js(session), Null]))).get(0) {
        Some(row) =>
          match at(row, "usage") {
            Some(Str(_) as u) => u
            _ => J::Null
          }
        None => J::Null
      }
    } else {
      J::Null
    }
    let answer = self.w.ask(
      to,
      jo([
        ("method", js("handover.usage")),
        ("workspace", js(ws)),
        ("origin", js(here)),
        ("id", js(id)),
        ("session", js(session)),
        ("thread", at(h, "thread").unwrap_or(Null)),
        ("there", there),
        ("threads", ja(threads)),
        ("connects", pairs_json(connects)),
        ("accounts", jo(accounts)),
        ("dataDir", js(self.d.data)),
        ("usage", ja(usage)),
        ("files", ja(files)),
        ("sessionUsage", session_usage),
        ("last", jb(last)),
      ]),
    ) catch {
      e => {
        self.w.info("handover", "the calls of a chat handed before not taken there yet", jo([("to", js(head_of(to, 12))), ("error", js(message_of(e)))]))
        return false
      }
    }
    if yes_at(answer, "skipped") {
      let next = match str_at(answer, "forwardedTo") {
        Some(n) if is_station(n) => Some(n)
        _ => None
      }
      match next {
        Some(n) if n != here && hop < 2 => {
          let there2 = match at(answer, "there") {
            Some(Num(_) as t) => t
            _ => J::Null
          }
          if !self.send_usage(h, n, there2, hop + 1) {
            self.w.info("handover", "the calls of a chat handed on from where it went not sent", jo([("to", js(head_of(n, 12)))]))
          }
        }
        _ => ()
      }
      return true
    }
    if last {
      return true
    }
  }
  true
}

///|
/// A page of the calls of a chat handed here before they went with it, put in where the chat is this station's now.
async fn Handover::take_usage(self : Handover, peer : String, ws : String, request : J) -> J {
  let session = str_at(request, "session").unwrap_or("")
  let usage = items(at(request, "usage"))
  let files = items(at(request, "files"))
  let refs = items(at(request, "threads"))
  if session == "" || usage.length() > 500 || files.length() > 500 || refs.length() > 500 {
    raise refused(self.why("badRequest", args=[("detail", "not a page of a chat's calls")]))
  }
  let handed = self.store("handedTo", [js(session)])
  let live = items(Some(self.store("liveOf", [jstrs([session])])))
  let ws_of = str_of(Some(self.hub("wsOf", [js(session)])))
  if live.length() == 0 || !(handed is Null) || ws_of != Some(ws) {
    let fields = [("ok", jb(true)), ("skipped", jb(true))]
    if !(handed is Null) && text_at(handed, "station") != peer {
      fields.push(("forwardedTo", at(handed, "station").unwrap_or(Null)))
      fields.push(("there", at(handed, "there").unwrap_or(Null)))
    }
    return jo(fields)
  }
  let connects = string_map(at(request, "connects"))
  let threads = []
  for r in refs {
    match (at(r, "id"), at(r, "surface"), at(r, "channel"), at(r, "threadTs")) {
      (Some(Num(rid)), Some(Str(_)), Some(Str(_)), Some(Str(_))) => {
        let there = match (at(request, "thread"), at(request, "there")) {
          (Some(Num(t)), Some(Num(th))) if t == rid => jn(th)
          _ => self.w.part("fn.threadOfRef", [js(session), r, pairs_json(connects)])
        }
        threads.push((num_text(rid), there))
      }
      _ => ()
    }
  }
  let profiles = []
  for e in entries(at(request, "accounts")) {
    match e.1 {
      Obj(_) as a =>
        match self.w.part("accounts.here", [a]) {
          Str(u) => profiles.push((e.0, @jsjson.sanitize_str(u)))
          _ => ()
        }
      _ => ()
    }
  }
  let took = self.w.part("fn.importHandedUsage", [
    jo([
      ("session", js(session)),
      ("threads", jo(threads)),
      ("profiles", pairs_json(profiles)),
      ("fromData", js(show_value(Some(at(request, "dataDir").unwrap_or(js("")))))),
      ("toData", js(self.d.data)),
      ("usage", ja(usage)),
      ("files", ja(files)),
    ]),
  ])
  let added = num_at(took, "added").unwrap_or(0.0)
  let has = self.w.part("fn.hasUsage", [js(session)]) is Bool(true)
  if added > 0.0 || (yes_at(request, "last") && has) {
    self.usage_of([session], false)
    if added > 0.0 {
      ignore(self.store("usageChanged", [jstrs([session])]))
    }
    ()
  } else if at(request, "sessionUsage") is Some(Str(u)) && !has && self.store("sessionUsage", [js(session)]) is Null {
    let v = parse(@jsjson.sanitize_str(u)) catch { _ => J::Null }
    if !(v is Null) || @jsjson.sanitize_str(u) == "null" {
      ignore(self.store("setSessionUsage", [js(session), v]))
    }
  }
  jo([("ok", jb(true)), ("added", at(took, "added").unwrap_or(Null)), ("files", at(took, "files").unwrap_or(Null))])
}

///|
fn Handover::hold_in(self : Handover, i : Rec) -> Unit {
  if i.s("step") == "coming" && !self.in_held.contains(i.s("id")) {
    match self.d.hold {
      Some(h) => self.in_held[i.s("id")] = h()
      None => ()
    }
  }
}

///|
/// Chats `keys` came here: every hand-over of them from here before is over for good.
async fn Handover::end_outs(self : Handover, keys : Array[String]) -> Unit {
  let fs = self.w.fs
  let theirs = self.outs_at(keys, "end")
  for o in theirs {
    if o.b("ended") || (o.s("step") != "gone" && o.s("step") != "done") {
      continue
    }
    o.set("step", js("done"))
    o.set("ended", jb(true))
    match self.again.get(o.s("id")) {
      Some(f) => f()
      None => ()
    }
    self.again.remove(o.s("id"))
    self.save(o)
  }
  let ended = theirs.filter(o => o.b("ended"))
  for o in ended {
    let ok = o.keys()
    let newer = ended.iter().any(n => !physical_equal(n, o) &&
      n.n("at") >= o.n("at") &&
      n.s("id") != o.s("id") &&
      ok.iter().all(k => n.keys().contains(k)) &&
      (n.n("at") > o.n("at") || js_less(o.s("id"), n.s("id"))))
    if !newer {
      continue
    }
    self.forget_out(o)
    fs.rm_f(out_file(fs, self.d.data, o.s("id")))
    fs.rm_f(end_file(fs, self.d.data, o.s("id")))
  }
}

///|
/// Of a chat's arrivals here the newest record is kept.
async fn Handover::trim_ins(self : Handover, i : Rec) -> Unit {
  let judged = (k : String) => self.outs_at([k], "trimJudged").iter().any(o => o.n("v") != 2.0 && !o.b("ended"))
  for old in self.ins_at(i.keys(), "trim") {
    if old.s("id") == i.s("id") || old.s("step") == "coming" || !old.keys().iter().all(k => i.keys().contains(k)) || old.keys().iter().any(judged) {
      continue
    }
    self.forget_in(old)
    self.w.fs.rm_f(in_file(self.w.fs, self.d.data, old.s("id")))
  }
}

///|
fn Handover::let_in(self : Handover, id : String) -> Unit {
  match self.in_held.get(id) {
    Some(f) => f()
    None => ()
  }
  self.in_held.remove(id)
  for f in self.settled_in.get(id).unwrap_or([]) {
    f()
  }
  self.settled_in.remove(id)
}

///|
/// The chats of workspace `ws` coming here now (by their keys, sorted).
pub fn Handover::coming_in(self : Handover, ws : String) -> Array[Array[String]] {
  self.look("comingIn", self.coming_ins.length())
  self.coming_ins
  .filter(i => i.s("step") == "coming" && i.s("ws") == ws)
  .map(i => {
    let k = i.keys().copy()
    k.sort_by(js_cmp)
    k
  })
}

///|
/// The station chat `key` is coming here from now.
pub fn Handover::coming_from(self : Handover, key : String) -> String? {
  self.ins_at([key], "comingFrom").iter().find_first(i => i.s("step") == "coming").map(i => i.s("origin"))
}

///|
/// Once no hand-over of chat `key` coming here is still coming.
pub async fn Handover::arrived(self : Handover, key : String, within_ms? : Double? = None) -> Bool {
  for i in self.ins_at([key], "arrived") {
    if i.s("step") != "coming" || self.closed {
      continue
    }
    let shown : Later[Bool] = Later::new()
    let list = self.settled_in.get(i.s("id")).unwrap_or([])
    list.push(() => shown.resolve(true))
    self.settled_in[i.s("id")] = list
    let late = match within_ms {
      // timer: the most a move back waits for its chat to be shown
      Some(ms) => Some(self.w.after(ms, () => shown.resolve(false)))
      None => None
    }
    let ok = shown.wait()
    call_opt(late)
    if !ok {
      return false
    }
  }
  true
}

///|
/// The directories a placing made, left empty as what it put is taken out: removed, up to the rooms' roots.
async fn Handover::emptied(self : Handover, from : String) -> Unit {
  let fs = self.w.fs
  let mut d = from
  while true {
    let rel = fs.relative(self.d.data, d)
    let parts = rel.split(fs.sep).map(v => v.to_string()).collect()
    let first = parts[0]
    let least = if first.has_prefix("transcripts") { 2 } else if first == "homes" { 6 } else { 1 }
    if first == "" || first == ".." || fs.is_absolute(first) || parts.length() <= least {
      return
    }
    if !fs.rmdir(d) {
      return
    }
    d = fs.dirname(d)
  }
}

///|
/// `path`, replaced or pruned by hand-over `i`, moved aside the first time. Whether there was one.
async fn Handover::put_aside(self : Handover, i : Rec, path : String) -> Bool {
  let fs = self.w.fs
  if !fs.lthere(path) {
    return false
  }
  let aside = in_aside(fs, self.d.data, i.s("id"))
  let list = fs.join([aside, "list.txt"])
  let had = fs.read_text(list).unwrap_or("")
  let made = fs.read_text(in_made(fs, self.d.data, i.s("id"))).unwrap_or("")
  let in_list = had.split("\n").any(l => {
    let l = l.to_string()
    match l.find("\t") {
      Some(t) => l.unsafe_substring(start=0, end=t) == path
      None => l == path
    }
  })
  if in_list || made.split("\n").any(l => l.to_string() == path) {
    fs.rm_f(path)
    return true
  }
  fs.mkdirs(aside)
  let name = "\{head_of(sha256_text(path), 32)}-\{fs.random_hex(4)}"
  fs.rename(path, fs.join([aside, name])) catch {
    e => {
      if code_of(e) == "ENOENT" || !fs.lthere(path) {
        return false
      }
      raise e
    }
  }
  fs.append(list, "\{path}\t\{name}\n")
  true
}

///|
/// Hand-over `i` dropped: its rows out and its record saying so (the first), then its files taken out once what it
/// was doing to them ended (the second).
fn Handover::drop_soon(self : Handover, i : Rec) -> (Run, Run) {
  let id = i.s("id")
  match self.drops.get(id) {
    Some(d) => return d
    None => ()
  }
  self.dropping[id] = true
  let marked = if !i.b("dropping") {
    let ctx = i.get("ctx").unwrap_or(Null)
    i.set("dropping", jb(true))
    self.w.run(async fn() {
      ignore(self.store("dropImport", [ctx]))
      ignore(self.store("forgetImport", [js(id)]))
      self.save_in(i)
    })
  } else {
    Run::over()
  }
  let mine : Ref[Run?] = Ref(None)
  let files = self.w.run(async fn() {
    try {
      marked.wait()
      ignore(self.serial_in(i, async fn() { self.drop_in(i) }, drop=true))
      self.dropping.remove(id)
    } catch {
      e =>
        self.w.warn("handover", "a chat coming here not all taken out: its next start takes out the rest", jo([("id", js(id)), ("error", js(message_of(e)))]))
    }
    match (self.drops.get(id), mine.val) {
      (Some(d), Some(m)) if physical_equal(d.1, m) => self.drops.remove(id)
      _ => ()
    }
  })
  mine.val = Some(files)
  let drop = (marked, files)
  if !files.is_done() {
    self.drops[id] = drop
  }
  drop
}

///|
/// `f`, after what hand-over `i` was doing to its files here ended, and (but for a drop's own) after the drops of
/// older hand-overs of its chat under way here.
async fn Handover::serial_in(self : Handover, i : Rec, f : async () -> J, drop? : Bool = false) -> J {
  let id = i.s("id")
  let older = if drop {
    []
  } else {
    self.ins_at(i.keys(), "serial").filter_map(o => if o.s("id") != id { self.drops.get(o.s("id")).map(d => d.1) } else { None })
  }
  let before = self.in_work.get(id)
  let result : Later[Result[J, Error]] = Later::new()
  let run = self.w.run(async fn() {
    match before {
      Some(b) => b.settled()
      None => ()
    }
    for o in older {
      o.settled()
    }
    let out = try f() catch {
      e => Err(e)
    } noraise {
      v => Ok(v)
    }
    result.resolve(out)
  })
  self.in_work[id] = run
  self.w.go(async fn() {
    run.settled()
    match self.in_work.get(id) {
      Some(r) if physical_equal(r, run) => self.in_work.remove(id)
      _ => ()
    }
  })
  match result.wait() {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
async fn Handover::drop_in(self : Handover, i : Rec) -> J {
  if i.s("step") == "dropped" {
    return jo([("ok", jb(true))])
  }
  if i.s("step") == "shown" {
    raise refused(self.why("shownHere"))
  }
  let fs = self.w.fs
  let d = self.d
  let id = i.s("id")
  match d.work.drop {
    Some(f) => f(id)
    None => ()
  }
  let gits : Array[(String, MadeGit)] = []
  for line in fs.read_text(in_gits(fs, d.data, id)).unwrap_or("").split("\n") {
    let m = parse(line.to_string()) catch { _ => continue }
    let dir = text_at(m, "dir")
    let was = gits.search_by(g => g.0 == dir).map(x => gits[x].1)
    let made : MadeGit = {
      dir,
      repo: text_at(m, "repo"),
      branch: match str_at(m, "branch") {
        Some(b) => Some(b)
        None => was.bind(w => w.branch)
      },
      ref_: match str_at(m, "ref") {
        Some(r) => Some(r)
        None => was.bind(w => w.ref_)
      },
    }
    match gits.search_by(g => g.0 == dir) {
      Some(x) => gits[x] = (dir, made)
      None => gits.push((dir, made))
    }
  }
  for g in gits {
    let m = g.1
    guard d.git is Some(git) && carried_place(fs, d.data, fs.join([m.dir, ".git"])) else { continue }
    for place in [fs.join([m.dir, ".git"]), fs.join(["\{m.dir}.git-carrying", ".git"])] {
      let text = fs.read_text(place).unwrap_or("")
      let named = gitdir_of(text)
      let ours = match named {
        None => false
        Some(n) => {
          let a = fs.realpath(fs.dirname(n)).unwrap_or("")
          let b = fs.realpath(fs.join([m.repo, ".git", "worktrees"]))
          b == Some(a)
        }
      }
      if ours {
        fs.rm_rf(named.unwrap()) catch {
          _ => ()
        }
      }
      fs.rm_f(place) catch {
        _ => ()
      }
    }
    fs.rm_rf("\{m.dir}.git-carrying") catch {
      _ => ()
    }
    match m.branch {
      Some(b) =>
        ignore(git(m.repo, ["branch", "-D", b])) catch {
          _ => ()
        }
      None => ()
    }
    match m.ref_ {
      Some(r) =>
        ignore(git(m.repo, ["update-ref", "-d", r])) catch {
          _ => ()
        }
      None => ()
    }
    self.emptied(m.dir)
  }
  for path in fs.read_text(in_made(fs, d.data, id)).unwrap_or("").split("\n") {
    let path = path.to_string()
    if path == "" {
      continue
    }
    fs.rm_f(path) catch {
      _ => ()
    }
    self.emptied(fs.dirname(path))
  }
  let aside = in_aside(fs, d.data, id)
  for line in fs.read_text(fs.join([aside, "list.txt"])).unwrap_or("").split("\n") {
    let line = line.to_string()
    guard line.find("\t") is Some(t) else { continue }
    let path = line.unsafe_substring(start=0, end=t)
    let rest = line.unsafe_substring(start=t + 1, end=line.length())
    let name = match rest.find("\t") {
      Some(u) => rest.unsafe_substring(start=0, end=u)
      None => rest
    }
    if path == "" {
      continue
    }
    fs.rm_rf(path) catch {
      _ => ()
    }
    fs.mkdirs(fs.dirname(path)) catch {
      _ => ()
    }
    fs.rename(fs.join([aside, name]), path) catch {
      _ => ()
    }
  }
  i.set("step", js("dropped"))
  self.let_in(id)
  self.save_in(i)
  fs.rm_rf(fs.join([hdir(fs, d.data), "in", id]))
  jo([("ok", jb(true))])
}

///|
/// `/^gitdir: (.+)$/m` of a `.git` file, trimmed.
fn gitdir_of(text : String) -> String? {
  for line in text.split("\n") {
    let l = line.to_string()
    if l.has_prefix("gitdir: ") && l.length() > 8 {
      return Some(js_trim(l.unsafe_substring(start=8, end=l.length())))
    }
  }
  None
}

///|
/// `path`'s real path, the part of it not there yet as it is.
pub async fn real_of_soon(fs : Fs, path : String) -> String {
  let rest = []
  let mut at = path
  while true {
    match fs.realpath(at) {
      Some(real) => {
        rest.rev_in_place()
        return fs.join([real, ..rest])
      }
      None => ()
    }
    if fs.dirname(at) == at {
      return path
    }
    rest.push(fs.basename(at))
    at = fs.dirname(at)
  }
  path
}

///|
/// Whether the file at `path` is the one described already: "yes", "no", or "later" (past the budget).
async fn in_place(fs : Fs, path : String, data : String, f : J, budget : Ref[Double], most : Double) -> String {
  if !carried_place(fs, data, path) {
    return "no"
  }
  guard fs.stat(path) is Some((kind, size, mtime)) && kind == "file" && size == num_at(f, "size").unwrap_or(-1.0) else { return "no" }
  match at(f, "mtimeMs") {
    Some(Num(m)) if js_trunc(mtime) == js_trunc(m) => return "yes"
    _ => ()
  }
  if size > most {
    return "no"
  }
  if size > budget.val {
    return "later"
  }
  budget.val -= size
  if fs.hash(path) == Some(text_at(f, "hash")) {
    "yes"
  } else {
    "no"
  }
}
