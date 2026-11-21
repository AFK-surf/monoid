// Line-delimited JSON-RPC harness (`--builder harness-core-routes`) for client/core-ts/test/
// {board-drafts-carried,presets-carried}.test.ts: drives real `@api_routes.Admin` (board, presets, stars)
// backed by real `@session_chats.BoardDrafts` and `@session_chats` presets over `@host.Host` async shell IO.

///|
priv struct BoardSite {
  admin : @api_routes.Admin
  told : Array[String]
  now_ms : Ref[Double]
}

///|
priv struct PresetsSite {
  admin : @api_routes.Admin
  world : @session_chats.World
  told : Array[String]
  now_ms : Ref[Double]
  legacy : Bool
}

///|
priv enum CoreSite {
  Board(BoardSite)
  Presets(PresetsSite)
}

// ── async FS helpers over `host.shell("fs.*")` ──

///|
async fn cr_lstat(host : @host.Host, p : String) -> (String, Double, Double)? {
  let (said, _) = host.shell("fs.lstat", { "path": Json::string(p) }) catch {
    _ => return None
  }
  match said {
    { "kind": String(kind), "size": Number(size, ..), "mtimeMs": Number(mtime, ..), .. } =>
      Some((kind, size, mtime))
    _ => None
  }
}

///|
async fn cr_stat_follow(host : @host.Host, p : String) -> (String, Double, Double)? {
  match cr_lstat(host, p) {
    Some(("link", _, _)) =>
      match (host.shell("fs.realpath", { "path": Json::string(p) }) catch { _ => return None }) {
        (String(r), _) =>
          match cr_lstat(host, r) {
            Some(("link", _, _)) => None
            other => other
          }
        _ => None
      }
    other => other
  }
}

///|
async fn cr_mkdir(host : @host.Host, p : String) -> Unit {
  ignore(host.shell("fs.mkdir", { "path": Json::string(p), "recursive": Json::boolean(true) }))
}

///|
async fn cr_rename(host : @host.Host, from : String, to : String) -> Unit {
  ignore(host.shell("fs.rename", { "from": Json::string(from), "to": Json::string(to) }))
}

///|
async fn cr_remove_tree(host : @host.Host, p : String) -> Unit {
  ignore(
    host.shell("fs.remove", { "path": Json::string(p), "recursive": Json::boolean(true) }),
  ) catch {
    _ => ()
  }
}

///|
async fn cr_readdir_names(host : @host.Host, dir : String) -> Array[String]? {
  let (said, _) = host.shell("fs.readdir", { "path": Json::string(dir) }) catch {
    _ => return None
  }
  match said {
    Array(items) =>
      Some(
        items.filter_map(x => match x {
          String(s) => Some(s)
          _ => None
        }),
      )
    _ => None
  }
}

///|
async fn cr_read_bytes(host : @host.Host, p : String) -> Bytes {
  match host.read_bytes(p) {
    Some(b) => b
    None => fail("ENOENT: no such file '\{p}'")
  }
}

///|
async fn cr_read_text(host : @host.Host, p : String) -> String {
  match host.read_text(p) {
    Some(t) => t
    None => fail("ENOENT: no such file '\{p}'")
  }
}

///|
async fn cr_write_text(host : @host.Host, p : String, text : String) -> Unit {
  ignore(
    host.shell(
      "fs.put",
      {
        "path": Json::string(p),
        "offset": Json::number(0.0),
        "truncate": Json::boolean(true),
        "exclusive": Json::boolean(false),
        "mode": Json::number((0o644).to_double()),
      },
      bytes=@api_routes.utf8(text),
    ),
  )
}

///|
async fn cr_copy_over(host : @host.Host, from : String, to : String) -> Unit {
  let (kind, _) = host.shell("fs.stat", { "path": Json::string(from) })
  if kind is Null {
    fail("ENOENT: no such file '\{from}'")
  }
  if from == to {
    return
  }
  match cr_lstat(host, to) {
    Some((k, _, _)) if k != "dir" =>
      ignore(host.shell("fs.remove", { "path": Json::string(to) })) catch {
        _ => ()
      }
    _ => ()
  }
  ignore(host.shell("fs.copy", { "from": Json::string(from), "to": Json::string(to) }))
}

// ── error and argument helpers ──

///|
fn cr_routes_thrown(e : Error) -> Error {
  match e {
    @api_routes.Thrown(_, _) | @api_routes.Refused(_, _) => e
    @session_chats.Thrown(kind, msg) =>
      @api_routes.Thrown(
        if kind == "" { "Error" } else { kind },
        @api_routes.jobj([("message", @api_routes.js(msg))]),
      )
    other => @api_routes.Thrown("Error", @api_routes.jobj([("message", @api_routes.js(other.to_string()))]))
  }
}

///|
fn cr_jv_str(args : Array[@jsjson.JValue], i : Int) -> String {
  match args.get(i) {
    Some(Str(s)) => s
    _ => ""
  }
}

///|
fn cr_jv_arg(args : Array[@jsjson.JValue], i : Int) -> @jsjson.JValue {
  match args.get(i) {
    Some(v) if !@api_routes.is_undef(v) => v
    _ => @jsjson.JValue::Null
  }
}

///|
fn cr_jv_opt(args : Array[@jsjson.JValue], i : Int) -> @jsjson.JValue? {
  match args.get(i) {
    Some(v) if !@api_routes.is_undef(v) && !(v is Null) => Some(v)
    _ => None
  }
}

///|
fn cr_setup() -> @api_routes.Setup {
  @api_routes.Setup::new(
    @api_routes.Words::new(@jsjson.JValue::Obj([]), @jsjson.JValue::Obj([])),
    "test",
    [],
    false,
    None,
    b"",
    "en",
    [
      "store", "config", "cloud", "grants", "parts", "agents.config", "agents.xshare", "agents.accounts",
      "hub.clones", "hub.repoIndex",
    ],
  )
}

// ── stars helpers (preset-records.ts `starsOf`, `newerStar`, `mergeStars`) ──

///|
fn cr_stars_of(raw : @jsjson.JValue) -> @jsjson.JValue raise {
  let refuse = (m : String) => @api_routes.Thrown("RecordRefusal", @api_routes.jobj([("message", @api_routes.js(m))]))
  guard raw is Obj(fields) else { raise refuse("stars: an object of models' stars") }
  let seen : Map[String, @jsjson.JValue] = Map::new()
  for f in fields {
    seen[f.0] = f.1
  }
  if seen.length() > 200 {
    raise refuse("stars: 200 models at most")
  }
  let count = (v : @jsjson.JValue?, least : Double) => match v {
    Some(Num(n)) => !n.is_nan() && !n.is_inf() && n == n.floor() && n.abs() <= 9007199254740991.0 && n >= least
    _ => false
  }
  let out : Array[(String, @jsjson.JValue)] = []
  for k, s in seen {
    if k == "" || k.length() > 200 {
      raise refuse("stars: a model's key is 1 to 200 characters")
    }
    match s {
      Obj(_) if s.get("on") is Some(Bool(_)) && count(s.get("rev"), 1.0) && count(s.get("at"), 0.0) =>
        out.push(
          (
            k,
            @api_routes.jobj([
              ("on", s.get("on").unwrap()),
              ("rev", s.get("rev").unwrap()),
              ("at", s.get("at").unwrap()),
            ]),
          ),
        )
      _ => raise refuse("stars: \{k} is {on, rev, at}")
    }
  }
  @api_routes.jobj(out)
}

///|
fn cr_star_num(s : @jsjson.JValue, k : String) -> Double {
  match s.get(k) {
    Some(Num(n)) => n
    _ => 0.0
  }
}

///|
fn cr_star_on(s : @jsjson.JValue) -> Bool {
  s.get("on") is Some(Bool(true))
}

///|
fn cr_newer_star(a : @jsjson.JValue, b : @jsjson.JValue) -> @jsjson.JValue {
  if cr_star_num(a, "rev") != cr_star_num(b, "rev") {
    return if cr_star_num(a, "rev") > cr_star_num(b, "rev") { a } else { b }
  }
  if cr_star_on(a) != cr_star_on(b) {
    return if cr_star_on(a) { b } else { a }
  }
  if cr_star_num(b, "at") > cr_star_num(a, "at") {
    b
  } else {
    a
  }
}

///|
fn cr_merge_stars(kept : @jsjson.JValue, given : @jsjson.JValue) -> @jsjson.JValue {
  let all : Map[String, @jsjson.JValue] = Map::new()
  match kept {
    Obj(fs) =>
      for f in fs {
        all[f.0] = f.1
      }
    _ => ()
  }
  match given {
    Obj(fs) =>
      for f in fs {
        all[f.0] = match all.get(f.0) {
          None => f.1
          Some(was) => cr_newer_star(was, f.1)
        }
      }
    _ => ()
  }
  let keys = all.keys().collect()
  keys.sort_by(@jsjson.js_compare)
  let mut kept_keys = keys
  if keys.length() > 200 {
    let going = keys.copy()
    going.sort_by((a, b) => {
      let on = (if cr_star_on(all[a]) { 1 } else { 0 }) - (if cr_star_on(all[b]) { 1 } else { 0 })
      if on != 0 {
        return on
      }
      let at = compare(cr_star_num(all[a], "at"), cr_star_num(all[b], "at"))
      if at != 0 {
        at
      } else {
        @jsjson.js_compare(a, b)
      }
    })
    let gone : Set[String] = Set::new()
    for k in going[:keys.length() - 200] {
      gone.add(k)
    }
    kept_keys = keys.filter(k => !gone.contains(k))
  }
  @api_routes.jobj(kept_keys.map(k => (k, all[k])))
}

// ── World & Site constructors ──

///|
fn cr_presets_world(
  host : @host.Host,
  id : String,
  workspace : String,
  home : String,
  now_ms : Ref[Double],
) -> @session_chats.World {
  let thrown : Ref[@jsjson.JValue] = Ref(@jsjson.JValue::Null)
  {
    call: async fn(op, args) {
      match op {
        "presets.home" => @api_routes.js(home)
        "presets.now" => @api_routes.jnum(now_ms.val)
        "presets.station" => @api_routes.js(id)
        "presets.workspace" => @api_routes.js(workspace)
        "presets.stationName" => @api_routes.js(cr_jv_str(args, 0))
        "fs.readText" => {
          let p = cr_jv_str(args, 0)
          let text = cr_read_text(host, p) catch {
            e => {
              thrown.val = @api_routes.jobj([("code", @api_routes.js("ENOENT"))])
              raise @session_chats.Thrown("Error", e.to_string())
            }
          }
          @api_routes.js(text)
        }
        "fs.writeFile" => {
          cr_write_text(host, cr_jv_str(args, 0), cr_jv_str(args, 1))
          @jsjson.JValue::Null
        }
        "fs.rename" => {
          cr_rename(host, cr_jv_str(args, 0), cr_jv_str(args, 1))
          @jsjson.JValue::Null
        }
        "fs.mkdir" => {
          cr_mkdir(host, cr_jv_str(args, 0))
          @jsjson.JValue::Null
        }
        "fs.stat" => {
          let p = cr_jv_str(args, 0)
          match cr_stat_follow(host, p) {
            Some((kind, size, mtime)) =>
              @api_routes.jobj([
                ("isFile", @api_routes.jbool(kind == "file")),
                ("isDirectory", @api_routes.jbool(kind == "dir")),
                ("size", @api_routes.jnum(size)),
                ("mtimeMs", @api_routes.jnum(mtime)),
              ])
            None => {
              thrown.val = @api_routes.jobj([("code", @api_routes.js("ENOENT"))])
              raise @session_chats.Thrown("Error", "ENOENT: no such file '\{p}'")
            }
          }
        }
        "fs.readdir" => {
          let p = cr_jv_str(args, 0)
          match cr_readdir_names(host, p) {
            Some(names) => @api_routes.jstrs(names)
            None => {
              thrown.val = @api_routes.jobj([("code", @api_routes.js("ENOENT"))])
              raise @session_chats.Thrown("Error", "ENOENT: no such dir '\{p}'")
            }
          }
        }
        _ => @jsjson.JValue::Null
      }
    },
    callback: _ => @jsjson.JValue::Null,
    words: @session_chats.Words::empty(),
    lang: Ref("en"),
    thrown,
    live: None,
  }
}

///|
fn cr_create_board(host : @host.Host, data : String, initial_now : Double) -> BoardSite {
  let sep = @drive.sep()
  let rows : Map[String, String] = Map::new()
  let told : Array[String] = []
  let now_ms : Ref[Double] = Ref(initial_now)
  let drafts = @session_chats.BoardDrafts::new({
    read_store: (ws, sub) => rows.get("\{ws}/\{sub}"),
    write_store: (ws, sub, d) => rows["\{ws}/\{sub}"] = d,
    dir: () => @nodepath.join(sep, [data, "board-files"]),
    uploads: () => @nodepath.join(sep, [data, "uploads"]),
    now: () => now_ms.val,
    sep,
    resolve: p =>
      if @nodepath.is_absolute(sep, p) {
        @nodepath.join(sep, [p])
      } else {
        @nodepath.join(sep, [@drive.cwd(), p])
      },
    stat: async fn(p) {
      match cr_stat_follow(host, p) {
        Some((kind, size, mtime_ms)) => Some({ is_file: kind == "file", size, mtime_ms })
        None => None
      }
    },
    mkdir: async fn(p) { cr_mkdir(host, p) },
    rename: async fn(from, to) { cr_rename(host, from, to) },
    rm: async fn(p, _recursive) { cr_remove_tree(host, p) },
    readdir: async fn(p) { cr_readdir_names(host, p) },
    utimes: async fn(p, ms) {
      ignore(host.shell("fs.utimes", { "path": Json::string(p), "mtimeMs": Json::number(ms) })) catch {
        _ => ()
      }
    },
    read_bytes: async fn(p) { cr_read_bytes(host, p) },
    copy_file: async fn(from, to) { cr_copy_over(host, from, to) },
    random_hex6: () => @drive.hex(@drive.random_bytes(3)),
    log_warn: (_, _) => (),
  })
  let backend = @api_routes.Backend::new(async fn(op, args) {
    try {
      match op {
        "hub.boardDrafts.said" => drafts.said(cr_jv_str(args, 0), cr_jv_str(args, 1))
        "hub.boardDrafts.carry" => drafts.carry(cr_jv_str(args, 0), cr_jv_str(args, 1), cr_jv_arg(args, 2))
        "hub.boardDrafts.keep" =>
          drafts.keep(
            cr_jv_str(args, 0),
            cr_jv_str(args, 1),
            cr_jv_str(args, 2),
            cr_jv_str(args, 3),
            cr_jv_str(args, 4),
          )
        "hub.boardDrafts.bytes" =>
          match drafts.bytes(cr_jv_str(args, 0), cr_jv_str(args, 1), cr_jv_str(args, 2), cr_jv_str(args, 3)) {
            Some((mime, bytes)) =>
              @api_routes.jobj([("type", @api_routes.js(mime)), ("bytes", @api_routes.jbytes(bytes))])
            None => @jsjson.JValue::Null
          }
        "hub.boardDrafts.stage" =>
          match
            drafts.stage(
              cr_jv_str(args, 0),
              cr_jv_str(args, 1),
              cr_jv_str(args, 2),
              cr_jv_str(args, 3),
              cr_jv_str(args, 4),
            ) {
            Some(v) => v
            None => @jsjson.JValue::Null
          }
        "events.tell" => {
          let name = cr_jv_str(args, 0)
          if name != "" {
            told.push(name)
          }
          @jsjson.JValue::Null
        }
        "clock.currentTimeMillisUnsafe" => @api_routes.jnum(now_ms.val)
        _ => @jsjson.JValue::Null
      }
    } catch {
      e => raise cr_routes_thrown(e)
    }
  })
  { admin: @api_routes.Admin::new(backend, cr_setup()), told, now_ms }
}

///|
fn cr_create_presets(
  host : @host.Host,
  id : String,
  workspace : String,
  home : String,
  repos : String,
  legacy : Bool,
  initial_now : Double,
) -> PresetsSite {
  let stars : Map[String, String] = Map::new()
  let told : Array[String] = []
  let now_ms : Ref[Double] = Ref(initial_now)
  let world = cr_presets_world(host, id, workspace, home, now_ms)
  let backend = @api_routes.Backend::new(async fn(op, args) {
    try {
      match op {
        "hub.presets.list" => @api_routes.jarr(@session_chats.presets_list(world, cr_jv_arg(args, 0)))
        "hub.presets.listed" => @api_routes.jarr(@session_chats.presets_listed(world, cr_jv_arg(args, 0)))
        "hub.presets.kept" =>
          @api_routes.jarr(@session_chats.presets_kept(world, cr_jv_arg(args, 0), cr_jv_arg(args, 1)))
        "hub.presets.others" =>
          @api_routes.jarr(@session_chats.presets_others(world, cr_jv_arg(args, 0), cr_jv_arg(args, 1)))
        "hub.presets.carry" =>
          @session_chats.presets_carry(
            world,
            cr_jv_arg(args, 0),
            cr_jv_arg(args, 1),
            @api_routes.jitems(Some(cr_jv_arg(args, 2))),
          )
        "hub.presets.add" =>
          @session_chats.presets_add(
            world,
            cr_jv_arg(args, 0),
            cr_jv_arg(args, 1),
            cr_jv_str(args, 2),
            cr_jv_str(args, 3),
          )
        "hub.presets.put" =>
          @session_chats.presets_put(
            world,
            cr_jv_arg(args, 0),
            cr_jv_str(args, 1),
            cr_jv_arg(args, 2),
            cr_jv_opt(args, 3),
          )
        "hub.presets.delete" => {
          @session_chats.presets_delete(world, cr_jv_arg(args, 0), cr_jv_str(args, 1), cr_jv_opt(args, 2))
          @jsjson.JValue::Null
        }
        "hub.reposDir" => @api_routes.js(repos)
        "sessions/presets.candidates" =>
          @api_routes.jarr(
            @session_chats.candidates(
              world,
              cr_jv_str(args, 0),
              @api_routes.jitems(Some(cr_jv_arg(args, 1))),
              @api_routes.jitems(Some(cr_jv_arg(args, 2))),
              async fn(st) { @session_chats.presets_is_here(world, st) },
            ),
          )
        "hub.store.modelStars" => {
          let key = "\{cr_jv_str(args, 0)}/\{cr_jv_str(args, 1)}"
          match stars.get(key) {
            Some(t) => @api_routes.js(t)
            None => @jsjson.JValue::Null
          }
        }
        "hub.store.putModelStars" => {
          let key = "\{cr_jv_str(args, 0)}/\{cr_jv_str(args, 1)}"
          stars[key] = cr_jv_str(args, 2)
          @jsjson.JValue::Null
        }
        "core/preset-records.starsOf" => cr_stars_of(cr_jv_arg(args, 0))
        "core/preset-records.mergeStars" => cr_merge_stars(cr_jv_arg(args, 0), cr_jv_arg(args, 1))
        "core/preset-records.canonical" => @api_routes.js(@session_chats.canonical(cr_jv_arg(args, 0)))
        "events.presetsChanged" => {
          told.push("presets")
          @jsjson.JValue::Null
        }
        "events.tell" => {
          let name = cr_jv_str(args, 0)
          if name != "" {
            told.push(name)
          }
          @jsjson.JValue::Null
        }
        "clock.currentTimeMillisUnsafe" => @api_routes.jnum(now_ms.val)
        _ => @jsjson.JValue::Null
      }
    } catch {
      e => raise cr_routes_thrown(e)
    }
  })
  { admin: @api_routes.Admin::new(backend, cr_setup()), world, told, now_ms, legacy }
}

///|
fn cr_is_legacy_allowed(verb : String, path : String) -> Bool {
  if verb == "POST" && path == "/presets" {
    return true
  }
  if (verb == "PUT" || verb == "DELETE") && path.has_prefix("/presets/") {
    let rest = path.unsafe_substring(start=9, end=path.length())
    return rest != "" && rest != "kept" && !rest.contains("/")
  }
  false
}

///|
fn cr_strip_legacy_fields(p : @jsjson.JValue) -> @jsjson.JValue {
  @api_routes.jdel(@api_routes.jdel(@api_routes.jdel(p, "owner"), "rev"), "home")
}

///|
async fn cr_handle_request(site : CoreSite, ask : Json) -> Json {
  if sn_at(ask, "nowMs") is Some(Number(n, ..)) {
    match site {
      Board(b) => b.now_ms.val = n
      Presets(p) => p.now_ms.val = n
    }
  }
  let verb = sn_str(ask, "method")
  let raw_path = sn_str(ask, "path")
  let (path, parsed_query, search) = match raw_path.find("?") {
    Some(at) =>
      (
        raw_path.unsafe_substring(start=0, end=at),
        @api_routes.query_pairs(raw_path.unsafe_substring(start=at + 1, end=raw_path.length())),
        Some(raw_path.unsafe_substring(start=at, end=raw_path.length())),
      )
    None => (raw_path, [], None)
  }
  let query : Array[(String, String)] = match sn_at(ask, "query") {
    Some(Array(items)) =>
      items.filter_map(it => match it {
        [String(k), String(v), ..] => Some((k, v))
        _ => None
      })
    _ => parsed_query
  }
  let body : Bytes = match sn_at(ask, "bodyBase64") {
    Some(String(b64)) => @drive.from_base64(b64)
    _ =>
      match sn_at(ask, "body") {
        None | Some(Null) => b""
        Some(String(s)) => @api_routes.utf8(s)
        Some(other) => @api_routes.utf8(other.stringify())
      }
  }
  let viewer = @jsjson.JValue::of_json(sn_at(ask, "viewer").unwrap_or(Json::null()))
  let lang = match sn_at(ask, "lang") {
    Some(String(l)) if l != "" => l
    _ => "en"
  }
  let req = @api_routes.Request::new(verb, path, query, search, [], body, viewer, lang)
  let (ans, told_ref) = match site {
    Board(b) => {
      b.told.clear()
      (b.admin.handle(req), b.told)
    }
    Presets(p) => {
      p.told.clear()
      let a = if p.legacy {
        if verb == "GET" && path == "/presets" {
          let list = @session_chats.presets_list(p.world, @jsjson.JValue::Null).map(cr_strip_legacy_fields)
          @api_routes.ok(
            @api_routes.jobj([
              ("presets", @api_routes.jarr(list)),
              ("candidates", @api_routes.jarr([])),
              ("clones", @api_routes.jarr([])),
            ]),
          )
        } else if cr_is_legacy_allowed(verb, path) {
          p.admin.handle(req)
        } else {
          @api_routes.error(404, "no route \{verb} \{path}")
        }
      } else {
        p.admin.handle(req)
      }
      (a, p.told)
    }
  }
  let body_bytes = ans.bytes()
  let headers_map : Map[String, Json] = Map::new()
  for k, v in ans.headers {
    headers_map[k] = Json::string(v)
  }
  let told_out = told_ref.map(Json::string)
  told_ref.clear()
  Json::object({
    "status": Json::number(ans.status.to_double()),
    "headers": Json::object(headers_map),
    "bodyBase64": Json::string(@drive.base64(body_bytes)),
    "told": Json::array(told_out),
  })
}

///|
async fn harness_core_routes(host : @host.Host) -> Unit {
  let sites : Map[Int, CoreSite] = Map::new()
  let mut next_handle = 0

  fn get_site(ask : Json) -> CoreSite raise Failure {
    let h = sn_int(ask, "handle", -1)
    match sites.get(h) {
      Some(s) => s
      None => fail("no site handle \{h}")
    }
  }

  fn get_presets(ask : Json) -> PresetsSite raise Failure {
    match get_site(ask) {
      Presets(p) => {
        if sn_at(ask, "nowMs") is Some(Number(n, ..)) {
          p.now_ms.val = n
        }
        p
      }
      Board(_) => fail("handle is not a presets site")
    }
  }

  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = @json.parse(line) catch { _ => Json::null() }
    let id = sn_at(ask, "id").unwrap_or(Json::null())
    let op = sn_str(ask, "op")
    let reply : Result[Json, String] = try {
      match op {
        "createBoard" => {
          let now_ms = match sn_at(ask, "nowMs") {
            Some(Number(n, ..)) => n
            _ => 0.0
          }
          next_handle += 1
          sites[next_handle] = Board(cr_create_board(host, sn_str(ask, "data"), now_ms))
          Ok(Json::object({ "handle": Json::number(next_handle.to_double()) }))
        }
        "createPresets" => {
          let now_ms = match sn_at(ask, "nowMs") {
            Some(Number(n, ..)) => n
            _ => 0.0
          }
          next_handle += 1
          sites[next_handle] = Presets(
            cr_create_presets(
              host,
              sn_str(ask, "stationId"),
              sn_str(ask, "workspace"),
              sn_str(ask, "home"),
              sn_str(ask, "repos"),
              sn_bool(ask, "legacy"),
              now_ms,
            ),
          )
          Ok(Json::object({ "handle": Json::number(next_handle.to_double()) }))
        }
        "request" => Ok(cr_handle_request(get_site(ask), ask))
        "presetsKept" => {
          let p = get_presets(ask)
          let ws = @jsjson.JValue::of_json(sn_at(ask, "ws").unwrap_or(Json::null()))
          let who = @jsjson.JValue::of_json(sn_at(ask, "who").unwrap_or(Json::null()))
          Ok(Json::array(@session_chats.presets_kept(p.world, ws, who).map(@jsjson.JValue::to_json)))
        }
        "presetsList" => {
          let p = get_presets(ask)
          let ws = @jsjson.JValue::of_json(sn_at(ask, "ws").unwrap_or(Json::null()))
          Ok(Json::array(@session_chats.presets_list(p.world, ws).map(@jsjson.JValue::to_json)))
        }
        "presetsGet" => {
          let p = get_presets(ask)
          let ws = @jsjson.JValue::of_json(sn_at(ask, "ws").unwrap_or(Json::null()))
          Ok(@session_chats.presets_get(p.world, ws, sn_str(ask, "presetId")).to_json())
        }
        "presetsAdd" => {
          let p = get_presets(ask)
          let ws = @jsjson.JValue::of_json(sn_at(ask, "ws").unwrap_or(Json::null()))
          let input = @jsjson.JValue::of_json(sn_at(ask, "input").unwrap_or(Json::null()))
          let email = sn_str(ask, "email")
          let sub = sn_str(ask, "sub")
          Ok(@session_chats.presets_add(p.world, ws, input, email, sub).to_json())
        }
        "presetsDelete" => {
          let p = get_presets(ask)
          let ws = @jsjson.JValue::of_json(sn_at(ask, "ws").unwrap_or(Json::null()))
          let who = match sn_at(ask, "who") {
            Some(Null) | None => None
            Some(v) => Some(@jsjson.JValue::of_json(v))
          }
          @session_chats.presets_delete(p.world, ws, sn_str(ask, "presetId"), who)
          Ok(Json::boolean(true))
        }
        "readPresetsFile" => {
          let world = cr_presets_world(host, sn_str(ask, "station"), "", sn_str(ask, "home"), Ref(0.0))
          let file = @session_chats.read_presets_file(world, sn_str(ask, "home"), sn_str(ask, "station"))
          Ok(
            Json::object({
              "presets": Json::array(file.presets.map(@jsjson.JValue::to_json)),
              "gone": Json::array(file.gone.map(@jsjson.JValue::to_json)),
            }),
          )
        }
        "close" => {
          let h = sn_int(ask, "handle", -1)
          sites.remove(h)
          Ok(Json::boolean(true))
        }
        _ => Err("unknown op \{op}")
      }
    } catch {
      e => Err(e.to_string())
    }
    match reply {
      Ok(v) => host.say(Json::object({ "id": id, "ok": v }).stringify())
      Err(m) => host.say(Json::object({ "id": id, "error": Json::string(m) }).stringify())
    }
  }
}
