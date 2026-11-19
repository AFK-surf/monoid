// What a search finds on this station (station/src/search/module.ts, search/search.ts, search/tool.ts), as a part
// of the station: looked for by the MoonBit program (`--builder search`, station/mb src/search) started by the first
// search and let go once none was asked for IDLE_MS, its candidate scopes and session list prepared by their builders
// (`--builder search-scope`, `--builder session-list`) as it asks; GET /search, the agents' `search` tool, and what
// other stations of the workspace ask of it (`search.query` on the bus).

///|
let p53_search_idle_ms : Int = 60000

///|
let p53_search_query_ms : Int = 20000

///|
let p53_search_kinds : Array[String] = ["chat", "message", "history", "job", "skill", "memory", "profile", "file"]

///|
priv struct P53Search {
  bus : LiveBus
  mut proc : Proc?
  waiting : Map[Int, @effect.Deferred[Json]]
  mut next : Int
  mut asked_at : Double
  mut closed : Bool
  preparing : Map[String, Bool]
}

///|
fn P53Search::new(bus : LiveBus) -> P53Search {
  { bus, proc: None, waiting: Map([]), next: 0, asked_at: 0.0, closed: false, preparing: Map([]) }
}

///|
fn P53Search::attach(self : P53Search) -> Unit {
  let bus = self.bus
  bus.parts.routes([
    {
      meth: "GET",
      path: "/search",
      answer: async fn(r) {
        let q = jfield(r, "query")
        let kinds = match jtext(q, "kinds") {
          Some(k) if k != "" => Json::array(k.split(",").map(x => jstr(x.to_string())).to_array())
          _ => Json::null()
        }
        let viewer = jfield(r, "viewer")
        let ws = either(jtext(viewer, "workspace"), p53_home(bus)).unwrap_or("")
        self.query(
          jtext_or_empty(q, "q"),
          jobj_of([
            ("kinds", kinds),
            ("limit", match jtext(q, "limit") { Some(l) => jn(attempt(() => @string.parse_double(l)).unwrap_or(8.0)); None => Json::null() }),
            ("asker", jobj_of([("workspace", jstr(ws)), ("home", jb(Some(ws) == p53_home(bus) || ws == "")), ("scopes", Json::array([jstr("write")]))])),
          ]),
        )
      },
    },
  ])
  bus.on_peer("search.query", async fn(_peer, ws, request, _bytes) {
    let asked = match jfield(request, "kinds") {
      Array(xs) => xs.filter(x => x is String(_))
      _ => []
    }
    let home = p53_home(bus)
    let asker = jobj_of([
      ("workspace", jstr(either(ws, home).unwrap_or(""))),
      ("home", jb(ws is None || ws == home)),
      ("scopes", Json::array([jstr("write")])),
    ])
    let found = self.query(
      jtext_or_empty(request, "query"),
      jobj_of([
        ("kinds", Json::array(if asked.length() > 0 { asked } else { p53_search_kinds.map(jstr) })),
        ("limit", jn(jnum_of(request, "limit").unwrap_or(5.0))),
        ("asker", asker),
      ]),
    )
    (jobj_of([("groups", self.linked(jfield(found, "groups"))), ("building", jfield(found, "building"))]), None)
  })
  // (another station of the workspace reading a skill here: skills.ts `skillForPeer`)
  bus.on_peer("skill.read", async fn(_peer, ws, request, _bytes) {
    let (name, file) = p53_skill_selection(request)
    let home = p53_home(bus)
    let catalog = self.read_catalog(if ws is None || ws == home { None } else { ws })
    (jobj_of([("text", jstr(p53_format_skill(catalog, name, file)))]), None)
  })
  bus.parts.tools([self.tool(), self.skill_tool()])
}

///|
/// Each hit with the link of its chat, where it is in one (search/tool.ts `linked`).
async fn P53Search::linked(self : P53Search, groups : Json) -> Json {
  guard groups is Array(gs) else { return Json::array([]) }
  let out = []
  for g in gs {
    let hits = []
    match jfield(g, "hits") {
      Array(hs) =>
        for h in hs {
          match jtext(h, "chat") {
            Some(chat) => {
              let link = self.bus.hub_link(jstr(chat)) catch { _ => Json::null() }
              hits.push(if link is String(_) { jwith(h, "link", link) } else { h })
            }
            None => hits.push(h)
          }
        }
      _ => ()
    }
    out.push(jwith(g, "hits", Json::array(hits)))
  }
  Json::array(out)
}

///|
/// The program looking, started where it is not (its answers each given to the search it is for).
fn P53Search::looker(self : P53Search) -> Proc raise P53Error {
  match self.proc {
    Some(p) => return p
    None => ()
  }
  if self.closed {
    raise P53Error("the search is stopped")
  }
  let data = self.bus.data
  let proc = spawn(
    self.bus.host,
    reader_program(self.bus),
    ["--builder", "search", "--db", @nodepath.join(sep(), [data, "stillfail.db"]), "--data", data, "--sep", sep()],
    stdin_piped=true,
    stdout=Piped,
    stderr=Ignored,
  ) catch {
    SysError(why) => raise P53Error(why)
  }
  self.proc = Some(proc)
  ignore(
    self.bus.host.rt.fork_daemon("the search's answers", on_error=e => @host.note("the search's answers failed: \{e}"), async fn() {
      let line = @buffer.Buffer()
      while true {
        match proc.events.take() {
          Out(b) =>
            for i in 0..<b.length() {
              if b[i] == b'\n' {
                self.answered(p53_utf8(line.to_bytes()))
                line.reset()
              } else {
                line.write_byte(b[i])
              }
            }
          Err(_) => ()
          Exit(_, _) => break
        }
      }
      if self.proc is Some(p) && physical_equal(p, proc) {
        self.proc = None
      }
      for id, w in self.waiting {
        ignore(w.fail(P53Error("the search stopped")))
        ignore(id)
      }
      self.waiting.clear()
    }),
  )
  // (let go once none was asked for IDLE_MS)
  ignore(
    self.bus.host.rt.fork_daemon("the search's idle", on_error=e => @host.note("the search's idle failed: \{e}"), async fn() {
      while self.proc is Some(p) && physical_equal(p, proc) {
        @effect.sleep(p53_search_idle_ms / 4) // timer: a deadline (an idle program's process let go)
        if self.waiting.length() == 0 && p53_clock() - self.asked_at >= p53_search_idle_ms.to_double() {
          proc.end_input()
          ignore(kill(proc.pid, "SIGTERM"))
          break
        }
      }
    }),
  )
  proc
}

///|
/// A line the program said: a search's answer, or that a builder is to prepare what it needs.
fn P53Search::answered(self : P53Search, line : String) -> Unit {
  guard attempt(() => @json.parse(line)) is Ok(answer) else { return }
  if jtrue(answer, "scopePending") {
    return self.prepare("search-scope")
  }
  if jtrue(answer, "sessionListPending") {
    return self.prepare("session-list")
  }
  guard jnum_of(answer, "id") is Some(id) else { return }
  match self.waiting.get(id.to_int()) {
    Some(w) => {
      self.waiting.remove(id.to_int())
      match jtext(answer, "error") {
        Some(e) => ignore(w.fail(P53Error(e)))
        None => ignore(w.succeed(answer))
      }
    }
    None => ()
  }
}

///|
/// A builder of what the search reads (its candidate scopes, the session list) run to its end, a step at a time
/// (read/requested-builder.ts), one of each at a time; the next search finds it ready.
fn P53Search::prepare(self : P53Search, builder : String) -> Unit {
  if self.preparing.contains(builder) || self.closed {
    return
  }
  self.preparing[builder] = true
  let bus = self.bus
  ignore(
    bus.host.rt.fork_daemon("search's builder", on_error=e => @host.note("search's builder failed: \{e}"), async fn() {
      defer self.preparing.remove(builder)
      let proc = spawn(
        bus.host,
        reader_program(bus),
        ["--builder", builder, "--db", @nodepath.join(sep(), [bus.data, "stillfail.db"])],
        stdin_piped=true,
        stdout=Piped,
        stderr=Ignored,
      ) catch {
        _ => return
      }
      let ask = (m : Json) => ignore(proc.write(@utf8.encode(m.stringify() + "\n")))
      ask(jobj_of([("scope", jstr("search"))]))
      let line = @buffer.Buffer()
      let mut going = true
      while going {
        match proc.events.take() {
          Out(b) =>
            for i in 0..<b.length() {
              if b[i] != b'\n' {
                line.write_byte(b[i])
                continue
              }
              let said = attempt(() => @json.parse(p53_utf8(line.to_bytes()))).unwrap_or(Json::null())
              line.reset()
              if jtrue(said, "take") {
                ask(jobj_of([("permit", jb(true))]))
              } else if jtrue(said, "done") || jtext(said, "error") is Some(_) || bus.stopped.is_done() {
                going = false
              } else {
                @effect.sleep(50) // timer: a pause between a builder's steps (REQUEST_BACKFILL_PAUSE_MS), yielding to writes
                ask(jobj_of([("scope", jstr("search"))]))
              }
            }
          Err(_) => ()
          Exit(_, _) => going = false
        }
      }
      proc.end_input()
      ignore(kill(proc.pid, "SIGTERM"))
    }),
  )
}

///|
/// What `query` finds for its asker (`options.asker`: `{workspace, home, scopes}`): by kind, at most `limit` of each.
async fn P53Search::query(self : P53Search, query : String, options : Json) -> Json {
  let proc = self.looker()
  self.next += 1
  let id = self.next
  self.asked_at = p53_clock()
  let w : @effect.Deferred[Json] = @effect.Deferred::new()
  self.waiting[id] = w
  let m : Map[String, Json] = { "type": jstr("query"), "id": ji(id), "query": jstr(query) }
  m["asker"] = match jfield(options, "asker") {
    Null => {
      let home = p53_home(self.bus).unwrap_or("")
      jobj_of([("workspace", jstr(home)), ("home", jb(true)), ("scopes", Json::array([jstr("write")]))])
    }
    a => a
  }
  for k in ["kinds", "limit", "offset", "archived"] {
    match jfield(options, k) {
      Null => ()
      v => m[k] = v
    }
  }
  if !proc.write(@utf8.encode(Json::object(m).stringify() + "\n")) {
    self.waiting.remove(id)
    raise P53Error("the search stopped")
  }
  // (the machine's files beside the rest, where they are asked for: search.ts `query`)
  let kinds = match jfield(options, "kinds") {
    Array(xs) => xs.filter_map(x => if x is String(k) { Some(k) } else { None })
    _ => []
  }
  let wants_files = (kinds.length() == 0 || kinds.contains("file")) && jnum_of(options, "offset").unwrap_or(0.0) == 0.0
  let limit = jnum_of(options, "limit").unwrap_or(8.0)
  let files = if wants_files {
    let words = query.to_lower().split(" ").filter(w => w != "").map(w => w.to_string()).to_array()
    self.files(words, m["asker"], (if limit < 1.0 { 1.0 } else if limit > 200.0 { 200.0 } else { limit }).to_int()) catch {
      _ => Json::null()
    }
  } else {
    Json::null()
  }
  let only_files = kinds.length() > 0 && kinds.iter().all(k => k == "file")
  if only_files {
    self.waiting.remove(id)
    return jobj_of([("groups", Json::array(if files is Null { [] } else { [files] })), ("building", jb(false))])
  }
  match @effect.timeout(p53_search_query_ms, async fn() { w.wait() }) {
    Some(answer) => {
      let groups = match jfield(answer, "groups") {
        Array(g) => g.copy()
        _ => []
      }
      if !(files is Null) {
        groups.push(files)
      }
      jobj_of([("groups", Json::array(groups)), ("building", jb(false))])
    }
    None => {
      self.waiting.remove(id)
      ignore(proc.write(@utf8.encode(jobj_of([("type", jstr("cancel")), ("id", ji(id))]).stringify() + "\n")))
      raise P53Error("the search took too long")
    }
  }
}

///|
async fn P53Search::close(self : P53Search) -> Unit {
  self.closed = true
  match self.proc {
    Some(p) => {
      p.end_input()
      ignore(kill(p.pid, "SIGTERM"))
    }
    None => ()
  }
}

///|
/// What search/tool.ts says of a hit.
fn p53_hit_line(h : Json) -> String {
  let where_ = []
  match jtext(h, "chatTitle") {
    Some(t) if t != "" => where_.push("in “\{t}”")
    _ => ()
  }
  match jtext(h, "link") {
    Some(l) => where_.push(l)
    None => ()
  }
  match jnum_of(h, "seq") {
    Some(n) => where_.push("message #\{n.to_int()}")
    None => ()
  }
  match jnum_of(h, "index") {
    Some(n) => where_.push("history #\{n.to_int()}")
    None => ()
  }
  match jtext(h, "job") {
    Some(j) => where_.push("job \{j}\{match jnum_of(h, "port") { Some(p) => " (port \{p.to_int()})"; None => "" }}")
    None => ()
  }
  match jtext(h, "path") {
    Some(p) => where_.push(p)
    None => ()
  }
  if jtrue(h, "archived") {
    where_.push("archived")
  }
  let text = jtext_or_empty(h, "text").split(" ").flat_map(w => w.split("\n")).flat_map(w => w.split("\t")).filter(w => w != "").map(w => w.to_string()).to_array().join(" ")
  let text = if text.char_length() > 200 { String::from_array(text.to_array()[:200].to_array()) + "…" } else { text }
  let at = match jnum_of(h, "at") {
    Some(t) => {
      let iso = iso_time(t)
      " (\{iso[:16].to_owned().replace(old="T", new=" ")} UTC)"
    }
    None => ""
  }
  let title = match jtext(h, "title") {
    Some(t) if t != "" => "\{t}: "
    _ => ""
  }
  "- \{title}\{text}\{at}\{if where_.length() > 0 { " — " + where_.join(", ") } else { "" }}"
}

///|
fn p53_search_said(name : String, groups : Json, station : String) -> String {
  guard groups is Array(gs) && gs.length() > 0 else { return "## \{name}\nNothing found." }
  let parts = gs.map(g => {
    let kind = jtext_or_empty(g, "kind")
    let hits = match jfield(g, "hits") {
      Array(hs) =>
        hs.map(h => p53_hit_line(h) + (if kind == "skill" && jtext(h, "skill") is Some(sk) { " — read with skill_read " + jobj_of([("station", jstr(station)), ("name", jstr(sk))]).stringify() } else { "" }))
      _ => []
    }
    let left = match jnum_of(g, "left") {
      Some(n) if n > 0.0 => "\n- … \{n.to_int()} older sessions' history not looked through (out of time): narrow the words, or ask this station alone"
      _ => ""
    }
    let more = if jtrue(g, "more") && left == "" { "\n- … more: ask with kinds=[\"\{kind}\"] and a higher limit" } else { "" }
    "### \{kind}\n\{hits.join("\n")}\{more}\{left}"
  })
  "## \{name}\n\{parts.join("\n")}"
}

///|
fn P53Search::tool(self : P53Search) -> PartTool {
  let bus = self.bus
  p53_tool(
    bus,
    "search",
    "Search everything in this workspace, on all its stations at once: chats (titles, archived ones too), every message, agents' execution histories, services and tasks, skills and memory, profiles, and the files on each station's machine (names and what they say). Words are matched anywhere in the text, case aside; every word must match. Results are grouped by station and kind, with chat links to give people or read with chat_read and session_history; a skill found is read in full with skill_read. Skill stillfail-chats says more.",
    jobj_of([
      ("type", jstr("object")),
      (
        "properties",
        jobj_of([
          ("query", jobj_of([("type", jstr("string")), ("description", jstr("The words to find (at most 200 characters)."))])),
          ("kinds", jobj_of([("type", jstr("array")), ("items", jobj_of([("enum", Json::array(p53_search_kinds.map(jstr)))])), ("description", jstr("Only these kinds. Left out: all."))])),
          ("limit", jobj_of([("type", jstr("integer")), ("description", jstr("At most this many of each kind on each station (default 5, at most 50)."))])),
          ("station", jobj_of([("type", jstr("string")), ("description", jstr("Only this station, by its name or id. Left out: every station of the workspace."))])),
        ]),
      ),
      ("required", Json::array([jstr("query")])),
      ("additionalProperties", jb(false)),
    ]),
    async fn(session, args) {
      let query = jtext_or_empty(args, "query").trim_space().to_string()
      if query == "" {
        raise P53Error("query is required")
      }
      if query.length() > 200 {
        raise P53Error("a search is at most 200 characters")
      }
      let asked = match jfield(args, "kinds") {
        Array(xs) => xs.filter(x => x is String(_))
        _ => []
      }
      let kinds = Json::array(if asked.length() > 0 { asked } else { p53_search_kinds.map(jstr) })
      let limit = match jnum_of(args, "limit") {
        Some(l) => if l < 1.0 { 1.0 } else if l > 50.0 { 50.0 } else { l.floor() }
        None => 5.0
      }
      let row = p53_session_row(bus, session)
      if row is Null {
        raise P53Error("unknown session")
      }
      let home = p53_home(bus)
      let ws = either(jtext(row, "ws"), home).unwrap_or("")
      let asker = jobj_of([("workspace", jstr(ws)), ("home", jb(jtext(row, "ws") is None || jtext(row, "ws") == home)), ("scopes", Json::array([jstr("write")]))])
      // (the workspace's other stations, as the mesh's roster names them: this one alone where it is in none's yet)
      let roster = (bus.peer_call.val)("", Some(ws), "peers", jobj_of([("method", jstr("peers")), ("workspace", jstr(ws))]), None) catch {
        _ => (Json::null(), None)
      }
      let here = p53_station_id(bus)
      let stations : Array[(String, String, Bool)] = match jfield(roster.0, "stations") {
        Array(xs) =>
          xs.filter_map(e => match jtext(e, "id") {
            Some(id) if id != "" => Some((id, jtext(e, "name").unwrap_or(id), id == here))
            _ => None
          })
        _ => []
      }
      if !stations.iter().any(s => s.2) {
        stations.insert(0, ("", "this station", true))
      }
      let only = match jtext(args, "station") {
        Some(s) => s.trim_space().to_string().to_lower()
        None => ""
      }
      let chosen = if only == "" { stations } else { stations.filter(s => s.0.to_lower() == only || s.1.to_lower() == only) }
      if chosen.length() == 0 {
        raise P53Error("no station \{jfield(args, "station").stringify()} in this workspace")
      }
      let parts = []
      for s in chosen {
        let name = if s.2 { "\{s.1} (this station)" } else { s.1 }
        let part = try {
          if s.2 {
            let found = self.query(query, jobj_of([("kinds", kinds), ("limit", jn(limit)), ("asker", asker)]))
            p53_search_said(name, self.linked(jfield(found, "groups")), if s.0 == "" { s.1 } else { s.0 })
          } else {
            let answer = @effect.timeout(p53_search_query_ms, async fn() {
              bus.call_peer(s.0, Some(ws), "search.query", jobj_of([("method", jstr("search.query")), ("session", jstr(session)), ("workspace", jstr(ws)), ("query", jstr(query)), ("kinds", kinds), ("limit", jn(limit))]))
            })
            match answer {
              Some((a, _)) => p53_search_said(name, jfield(a, "groups"), s.0)
              None => raise P53Error("did not answer within \{p53_search_query_ms / 1000} s")
            }
          }
        } catch {
          e => "## \{name}\nNot searched: \{p53_words(e)}"
        }
        parts.push(part)
      }
      "Search for \{jstr(query).stringify()}:\n\n\{parts.join("\n\n")}"
    },
  )
}

///|
/// The program let go where no search waits on it (the station short of memory): 1, else 0.
async fn P53Search::trim_idle(self : P53Search) -> Int {
  match self.proc {
    Some(p) if self.waiting.length() == 0 => {
      p.end_input()
      ignore(kill(p.pid, "SIGTERM"))
      self.proc = None
      1
    }
    _ => 0
  }
}

///|
/// Its program's pid, where one runs.
fn P53Search::pid(self : P53Search) -> Int? {
  self.proc.map(p => p.pid)
}

// ── the machine's files (search/files.ts `FileSearch`, its walk) ──

///|
/// How long, how deep and over how many entries the machine's files are walked for a search (files.ts WALK_MS,
/// WALK_DEPTH, WALK_ENTRIES), how many found at most (MOST), and the most of a text read for its words (TEXT_MAX).
let p53_walk_ms : Double = 3000.0

///|
let p53_walk_depth : Int = 16

///|
let p53_walk_entries : Int = 200000

///|
let p53_walk_most : Int = 1000

///|
let p53_text_max : Double = 262144.0

///|
/// What a walk does not go into (files.ts SKIPPED).
let p53_walk_skipped : Array[String] = [
  "node_modules", "target", "dist", "build", ".git", "__pycache__", ".venv", "venv", "Pods", "DerivedData", ".cache",
  "Library", "AppData",
]

///|
/// What is read for its words: a text by its name (files.ts TEXTS).
let p53_text_kinds : Array[String] = [
  "md", "markdown", "txt", "text", "log", "csv", "tsv", "json", "jsonl", "yml", "yaml", "toml", "ini", "conf", "cfg",
  "xml", "html", "htm", "css", "scss", "less", "js", "jsx", "mjs", "cjs", "ts", "tsx", "py", "rb", "go", "rs", "java",
  "kt", "kts", "swift", "c", "cc", "cpp", "h", "hpp", "cs", "php", "sh", "bash", "zsh", "fish", "ps1", "sql", "r", "lua",
  "pl", "ex", "exs", "erl", "hs", "scala", "clj", "vue", "svelte", "tex", "rst", "org", "srt", "vtt",
]

///|
fn p53_under(path : String, dir : String) -> Bool {
  path == dir || path.has_prefix(if dir.has_suffix(sep()) { dir } else { dir + sep() })
}

///|
/// What `fs.scan` says of each of `paths` (`{kind, size, mode, dev}`, null where nothing is there).
async fn p53_scan(host : @host.Host, paths : Array[String]) -> Array[Json] {
  if paths.length() == 0 {
    return []
  }
  match (try { Ok(host.shell("fs.scan", { "paths": Json::array(paths.map(jstr)) })) } catch { e => Err(e) }) {
    Ok((Array(xs), _)) => xs
    _ => paths.map(_ => Json::null())
  }
}

///|
/// The machine's files whose name, or whose text, has every word (files.ts `walk`), walked as `walkBounded` walks:
/// from `tops`, on each top's own file system, no link followed, hidden names and SKIPPED left out, bounded in depth,
/// entries and time; nothing under `skip` (the station's own). The paths found, and whether some was left.
async fn p53_walk(host : @host.Host, tops : Array[String], words : Array[String], skip : Array[String]) -> (Array[String], Bool) {
  let started = p53_clock()
  let found = []
  let has = (text : String) => {
    let lower = text.to_lower()
    words.iter().all(w => lower.contains(w))
  }
  let mut entries = 0
  let mut left = false
  for top in tops {
    let root = p53_scan(host, [top])
    guard root.length() == 1 && jtext(root[0], "kind") == Some("dir") else { continue }
    let dev = jfield(root[0], "dev")
    let queue = [(top, 0)]
    while queue.length() > 0 {
      let (dir, depth) = queue.remove(0)
      if found.length() >= p53_walk_most || p53_clock() - started > p53_walk_ms || entries > p53_walk_entries {
        left = true
        break
      }
      let listed = p53_readdir_types(host, dir)
      let dirs = []
      let files = []
      for e in listed {
        let (name, kind) = e
        entries += 1
        if name.has_prefix(".") {
          continue
        }
        let path = @nodepath.join(sep(), [dir, name])
        if skip.iter().any(d => p53_under(path, d)) {
          continue
        }
        match kind {
          "dir" => {
            if has(name) {
              found.push(path)
            }
            if !p53_walk_skipped.contains(name) {
              dirs.push(path)
            }
          }
          "file" => {
            if has(name) {
              found.push(path)
            } else {
              let ext = match name.rev_find(".") {
                Some(i) => name[i + 1:].to_owned().to_lower()
                None => ""
              }
              if p53_text_kinds.contains(ext) {
                files.push((path, name))
              }
            }
          }
          // (a link is never followed, nor read)
          _ => ()
        }
      }
      // (a directory on another file system than its top's is not gone into)
      if depth + 1 < p53_walk_depth {
        let seen = p53_scan(host, dirs)
        for i, d in dirs {
          if i < seen.length() && jfield(seen[i], "dev") == dev {
            queue.push((d, depth + 1))
          }
        }
      } else if dirs.length() > 0 {
        left = true
      }
      let sizes = p53_scan(host, files.map(f => f.0))
      for i, f in files {
        if i < sizes.length() && jnum_of(sizes[i], "size").unwrap_or(p53_text_max + 1.0) <= p53_text_max {
          match shell_read_text(host, f.0) {
            Some(text) if has("\{f.1}\n\{text}") => found.push(f.0)
            _ => ()
          }
        }
      }
    }
  }
  (found, left || found.length() >= p53_walk_most)
}

///|
/// The drive's roots of a workspace (drive/drive.ts `rootsOf`: config.json's `drive.roots`, a joined workspace's
/// `drive.workspaces[<ws>]`).
fn p53_roots_of(raw : Json, workspace : String?) -> Array[String] {
  let roots = match workspace {
    None => jfield(jfield(raw, "drive"), "roots")
    Some(ws) => jfield(jfield(jfield(raw, "drive"), "workspaces"), ws)
  }
  match roots {
    Array(xs) => xs.filter_map(r => match r { String(p) if p.has_prefix("/") || (p.length() > 2 && p[1:3] == ":\\") => Some(p); _ => None })
    _ => []
  }
}

///|
/// What the machine's files found for `words` as the asker may see them (files.ts `#search`): a member who writes, from
/// the home directory; one who only reads, within the drive's roots of the workspace; never what is the station's own,
/// nor what is a person's own (mail, messages, photos…) unless config.json's `search.personal` says so.
async fn P53Search::files(self : P53Search, words : Array[String], asker : Json, limit : Int) -> Json {
  if words.length() == 0 {
    return Json::null()
  }
  let bus = self.bus
  let raw = (bus.config_raw.val)()
  let writer = match jfield(asker, "scopes") {
    Array(xs) => xs.contains(jstr("write"))
    _ => false
  }
  let pinned = p53_roots_of(raw, if jtrue(asker, "home") { None } else { jtext(asker, "workspace") })
  if !writer && pinned.length() == 0 {
    return Json::null()
  }
  let home = homedir()
  let own = ["Library/Mail", "Library/Messages", "Library/Calendars", "Library/Application Support/AddressBook", "Library/Group Containers/group.com.apple.notes", "Library/Containers/com.apple.Notes", "Library/Metadata/CoreSpotlight", "Pictures/Photos Library.photoslibrary"].map(d => @nodepath.join(sep(), [home, d]))
  let personal = jtrue(jfield(raw, "search"), "personal")
  let skip = (bus.own_paths.val)() + (if personal { [] } else { own })
  let (paths, left) = p53_walk(bus.host, if writer { [home] } else { pinned }, words, skip)
  let listed = paths.filter(p => writer || pinned.iter().any(r => p53_under(p, r)))
  let first = words[0]
  let known = []
  let scanned = p53_scan(bus.host, listed)
  for i, p in listed {
    if i >= scanned.length() || scanned[i] is Null {
      continue
    }
    let st = p53_lstat(bus.host, p)
    known.push((p, jtext(scanned[i], "kind") == Some("dir"), jnum_of(scanned[i], "size").unwrap_or(0.0), jnum_of(st, "mtimeMs").unwrap_or(0.0)))
  }
  let rank = (p : String) => if @nodepath.basename(sep(), p).to_lower().contains(first) { 0 } else { 4 }
  let depth = (p : String) => p.split(sep()).count()
  known.sort_by((a, b) => {
    let r = rank(a.0).compare(rank(b.0))
    if r != 0 {
      return r
    }
    let d = depth(a.0).compare(depth(b.0))
    if d != 0 { d } else { b.3.compare(a.3) }
  })
  let shown = (dir : String) => if p53_under(dir, home) { "~" + dir[home.length():].to_owned() } else { dir }
  let hits = known[:if known.length() > limit { limit } else { known.length() }].to_array().map(f => {
    let fields : Array[(String, Json)] = [
      ("kind", jstr("file")),
      ("key", jstr("f:\{f.0}")),
      ("title", jstr(@nodepath.basename(sep(), f.0))),
      ("text", jstr(shown(@nodepath.dirname(sep(), f.0)))),
      ("at", jn(f.3.round())),
      ("path", jstr(f.0)),
      ("dir", jb(f.1)),
      ("size", jn(f.2)),
    ]
    if !writer {
      match pinned.search_by(r => p53_under(f.0, r)) {
        Some(i) => {
          fields.push(("root", jstr(pinned[i])))
          let rel = f.0[pinned[i].length():].to_owned()
          fields.push(("rel", jstr(if rel.has_prefix(sep()) { rel[1:].to_owned() } else { rel })))
        }
        None => ()
      }
    }
    jobj_of(fields)
  })
  if hits.length() == 0 {
    Json::null()
  } else {
    jobj_of([("kind", jstr("file")), ("hits", Json::array(hits)), ("more", jb(known.length() > limit || left))])
  }
}

// ── skills read by their name (search/skills.ts) ──

///|
/// What GET /memory answers (the readers' `memory`) of a workspace (None: the home one's): the catalog a skill is
/// read from. Where no readers are attached to the bus (a station run alone), read here by the same code.
async fn P53Search::read_catalog(self : P53Search, workspace : String?) -> Json {
  let args = match workspace {
    Some(w) => jobj_of([("workspace", jstr(w))])
    None => jobj_of([])
  }
  let read = (self.bus.reader_ask.val)("memory", args, "zh") catch { _ => Json::null() }
  match read {
    String(t) => (try { Ok(@json.parse(t)) } catch { e => Err(e) }).unwrap_or(Json::null())
    Object(_) as o => o
    _ => @readops.memory(self.bus.host, self.bus.data, sep(), args) catch { _ => Json::null() }
  }
}

///|
/// skills.ts `selection`: the skill's name and the file of it asked for.
fn p53_skill_selection(args : Json) -> (String, String) raise P53Error {
  let name = match jfield(args, "name") {
    String(n) if n.trim_space().to_string() != "" => n
    _ => raise P53Error("name is required: use a skill name returned by search")
  }
  let file = match jfield(args, "file") {
    Null => "SKILL.md"
    String(f) if f != "" => f
    _ => raise P53Error("file must be a listed Markdown filename")
  }
  (name, file)
}

///|
/// skills.ts `formatSkillFromCatalog`: a skill's file as `skill_read` gives it.
fn p53_format_skill(catalog : Json, name : String, file : String) -> String raise P53Error {
  let skills = match jfield(catalog, "skills") {
    Array(xs) => xs
    _ => []
  }
  guard skills.iter().find_first(s => jtext(s, "name") == Some(name)) is Some(skill) else {
    raise P53Error("No skill \{jstr(name).stringify()} in this workspace on this station")
  }
  let files = match jfield(skill, "files") {
    Array(xs) => xs
    _ => []
  }
  let text = if file == "SKILL.md" {
    jtext(skill, "text")
  } else {
    match files.iter().find_first(f => jtext(f, "name") == Some(file)) {
      Some(f) => jtext(f, "text")
      None => None
    }
  }
  guard text is Some(text) else {
    raise P53Error("No file \{jstr(file).stringify()} in skill \{jstr(name).stringify()}; read SKILL.md for the available files")
  }
  let names = ["SKILL.md", ..files.map(f => jtext_or_empty(f, "name"))]
  "Skill \{jstr(name).stringify()}, file \{jstr(file).stringify()}\nAvailable files: \{names.map(n => jstr(n).stringify()).join(", ")}\n\n\{text}"
}

///|
/// A session's place (search/module.ts `workspaceOf`): its workspace, and whether that is the home one.
fn p53_place_of(bus : LiveBus, session : String) -> Json {
  let row = p53_session_row(bus, session)
  if row is Null {
    return Json::null()
  }
  let home = p53_home(bus)
  let ws = jtext(row, "ws")
  jobj_of([("workspace", jstr(either(ws, home).unwrap_or(""))), ("home", jb(ws is None || ws == home))])
}

///|
/// The workspace's stations (search/module.ts `stations`): each one's id, name, and whether it is this one.
async fn p53_stations_of(bus : LiveBus, workspace : String) -> Array[Json] {
  let (roster, _) = (bus.peer_call.val)("", Some(workspace), "peers", jobj_of([("method", jstr("peers")), ("workspace", jstr(workspace))]), None) catch {
    _ => (Json::null(), None)
  }
  let here = p53_station_id(bus)
  match jfield(roster, "stations") {
    Array(xs) =>
      xs.filter_map(e => match jtext(e, "id") {
        Some(id) if id != "" => Some(jobj_of([("id", jstr(id)), ("name", jstr(jtext(e, "name").unwrap_or(id))), ("here", jb(id == here))]))
        _ => None
      })
    _ => [jobj_of([("id", jstr(here)), ("name", jfield(p53_cloud(bus), "name")), ("here", jb(true))])]
  }
}

///|
/// A skill read here (search/module.ts `readSkill`): of the session's workspace (None: the home one).
async fn P53Search::read_skill(self : P53Search, workspace : String?, name : String, file : String) -> String {
  p53_format_skill(self.read_catalog(workspace), name, file)
}

///|
/// skill_read (search/skills.ts `skillTools`).
fn P53Search::skill_tool(self : P53Search) -> PartTool {
  let bus = self.bus
  p53_tool(
    bus,
    "skill_read",
    "Read a skill in full by its exact name: one a tool's description or your instructions name, when you do not have its file, or one found by search, with its station where that is another station of the workspace. With file, one of the Markdown reference files the reply lists. It only reads this workspace's skill catalog: nothing is installed, shared or run.",
    jobj_of([
      ("type", jstr("object")),
      (
        "properties",
        jobj_of([
          ("name", jobj_of([("type", jstr("string")), ("description", jstr("The skill's exact name."))])),
          ("station", jobj_of([("type", jstr("string")), ("description", jstr("The station's id or unique name from search. Omit for this station."))])),
          ("file", jobj_of([("type", jstr("string")), ("description", jstr("A Markdown filename listed by this skill (default SKILL.md)."))])),
        ]),
      ),
      ("required", Json::array([jstr("name")])),
      ("additionalProperties", jb(false)),
    ]),
    async fn(session, args) {
      let (name, file) = p53_skill_selection(args)
      let place = p53_place_of(bus, session)
      if place is Null {
        raise P53Error("unknown session")
      }
      let ws = if jtrue(place, "home") { None } else { jtext(place, "workspace") }
      let only = match jtext(args, "station") {
        Some(s) => s.trim_space().to_string().to_lower()
        None => ""
      }
      if only == "" || only == "this station" {
        return self.read_skill(ws, name, file)
      }
      let workspace = jtext_or_empty(place, "workspace")
      let chosen = p53_stations_of(bus, workspace).filter(s => jtext_or_empty(s, "id").to_lower() == only || jtext_or_empty(s, "name").to_lower() == only)
      if chosen.length() != 1 {
        raise P53Error(if chosen.length() > 0 { "Station name is ambiguous; use the station id from search" } else { "No such station in this workspace" })
      }
      if jtrue(chosen[0], "here") {
        return self.read_skill(ws, name, file)
      }
      let station = jtext_or_empty(chosen[0], "id")
      let answer = @effect.timeout(p53_search_query_ms, async fn() {
        bus.call_peer(station, Some(workspace), "skill.read", jobj_of([("method", jstr("skill.read")), ("workspace", jstr(workspace)), ("session", jstr(session)), ("name", jstr(name)), ("file", jstr(file))]))
      })
      match answer {
        None => raise P53Error("Station did not answer skill.read within 20 s")
        Some((a, _)) =>
          match jtext(a, "text") {
            Some(t) => t
            None => raise P53Error("Station did not return a skill; it may need an update to support skill.read")
          }
      }
    },
  )
}
