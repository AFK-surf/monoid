// Presets: what a chat starts knowing, chosen as it is opened (station/src/sessions/presets.ts). A preset names the
// directories its chats work with and what people want of them there. A workspace's presets are its agent home's
// presets.json; a chat opened with one keeps a copy in its session workspace (`.stillfail-preset.json`). A preset is
// its person's, carried by their devices (preset_records.mbt); a station changes a record itself only for an app from
// before. Its files are the station's (`fs.*`), its place (`presets.home`, `presets.now`, `presets.station`,
// `presets.workspace`, `presets.stationName`) and the machine's home and paths (`os.homedir`, `path.resolve`).

///|
let presets_file : String = "presets.json"

///|
let copy_file : String = ".stillfail-preset.json"

///|
pub let live_most : Int = 1000

///|
/// Why a chat asked for may not be opened with a preset that binds its model or stations, or None.
pub fn preset_refusal(words : Words, p : J, here : String?, asked : J, lang : String) -> String? {
  let m = at(Some(p), "model")
  let name = str_of(at(Some(p), "name")).unwrap_or("")
  match m {
    Some(Obj(_)) => {
      let model = at(m, "model").unwrap_or(Null)
      let runtime = at(m, "runtime")
      let asked_model = at(Some(asked), "model").unwrap_or(Null)
      let differs = !jeq(asked_model, model) ||
        (match runtime {
          Some(r) => !jeq(r, at(Some(asked), "runtime").unwrap_or(Null))
          None => false
        })
      if differs {
        return Some(words.tr(lang, "station.presets.modelBound", args=[("preset", name), ("model", js_string_of(Some(model)))]))
      }
    }
    _ => ()
  }
  let named = match str_of(at(Some(p), "station")) {
    Some(s) => [s]
    None => arr_of(at(Some(p), "stations")).unwrap_or([]).map(x => str_of(Some(x)).unwrap_or(""))
  }
  match here {
    Some(h) if named.length() > 0 && !named.iter().any(s => s == h || ends(s, "/\{h}")) =>
      Some(words.tr(lang, "station.presets.stationBound", args=[("preset", name)]))
    _ => None
  }
}

///|
fn dirs_of(v : J?) -> Array[J] {
  match v {
    Some(Arr(xs)) =>
      xs.filter_map(d => {
        guard str_of(at(Some(d), "path")) is Some(path) else { return None }
        let fields = [("path", js(path)), ("repo", jopt(str_of(at(Some(d), "repo"))))]
        for k in ["station", "stationName", "elsewhere"] {
          match str_of(at(Some(d), k)) {
            Some(s) if s != "" => fields.push((k, js(s)))
            _ => ()
          }
        }
        match at(Some(d), "guides") {
          Some(Arr(gs)) =>
            fields.push(
              (
                "guides",
                ja(
                  gs
                  .filter(g => at(Some(g), "file") is Some(Str(_)) && at(Some(g), "text") is Some(Str(_)))
                  .map(g => jo([
                    ("file", at(Some(g), "file").unwrap()),
                    ("text", at(Some(g), "text").unwrap()),
                    ("whole", jb(!(at(Some(g), "whole") is Some(Bool(false))))),
                  ])),
                ),
              ),
            )
          _ => ()
        }
        match at(Some(d), "skills") {
          Some(Arr(ss)) => fields.push(("skills", ja(ss.filter(n => n is Str(_)))))
          _ => ()
        }
        Some(jo(fields))
      })
    _ => []
  }
}

///|
fn preset_model_of(o : J?) -> J? {
  match model_of(at(o, "model")) {
    Some(m) => Some(m)
    None =>
      match at(o, "models") {
        Some(Obj(_) as ms) => model_of(at(Some(ms), "lead"))
        _ => None
      }
  }
}

///|
fn safe_int(v : J?) -> Bool {
  match v {
    Some(Num(d)) => !d.is_nan() && !d.is_inf() && d == d.floor() && d.abs() <= 9007199254740991.0
    _ => false
  }
}

///|
/// A preset as presets.json says it, `me` this station's id.
fn preset_of(v : J, me : String) -> J? {
  let o = Some(v)
  guard str_of(at(o, "id")) is Some(id) && str_of(at(o, "name")) is Some(name) else { return None }
  let st = stations_of(o)
  let model = preset_model_of(o)
  let fields = [
    ("id", js(id)),
    ("name", js(name)),
    ("dirs", ja(dirs_of(at(o, "dirs")))),
    ("instructions", js(str_of(at(o, "instructions")).unwrap_or(""))),
  ]
  for f in station_fields(st) {
    fields.push(f)
  }
  if model is Some(m) {
    fields.push(("model", m))
  }
  fields.push(("createdBy", js(str_of(at(o, "createdBy")).unwrap_or(""))))
  fields.push(("createdAt", match at(o, "createdAt") { Some(Num(_) as n) => n; _ => ji(0) }))
  fields.push(("updatedAt", match at(o, "updatedAt") { Some(Num(_) as n) => n; _ => ji(0) }))
  fields.push(("owner", js(str_of(at(o, "owner")).unwrap_or(""))))
  fields.push(("rev", if safe_int(at(o, "rev")) && num_of(at(o, "rev")).unwrap() >= 1.0 { at(o, "rev").unwrap() } else { ji(1) }))
  fields.push(("home", js(match str_of(at(o, "home")) { Some(h) if h != "" => h; _ => me })))
  Some(jo(fields))
}

///|
fn gone_of(v : J) -> J? {
  let o = Some(v)
  if !(at(o, "gone") is Some(Bool(true))) || !(at(o, "id") is Some(Str(_))) || !safe_int(at(o, "rev")) {
    return None
  }
  Some(
    jo([
      ("id", at(o, "id").unwrap()),
      ("owner", js(str_of(at(o, "owner")).unwrap_or(""))),
      ("rev", at(o, "rev").unwrap()),
      ("gone", jb(true)),
      ("updatedAt", match at(o, "updatedAt") { Some(Num(_) as n) => n; _ => ji(0) }),
    ]),
  )
}

///|
/// A workspace's presets.json: its live presets and its deleted ones.
pub struct PresetsFile {
  presets : Array[J]
  gone : Array[J]
}

///|
/// The presets of the workspace whose agent home is `home`, as written; none when there is no file yet.
pub async fn read_presets_file(w : World, home : String, me : String) -> PresetsFile {
  try {
    let raw = parse_js(str_of(Some(w.ask("fs.readText", [js(join_path([home, presets_file]))]))).unwrap_or(""))
    let presets = arr_of(at(Some(raw), "presets")).unwrap_or([]).filter_map(p => preset_of(p, me))
    let gone = arr_of(at(Some(raw), "gone")).unwrap_or([]).filter_map(gone_of)
    { presets, gone }
  } catch {
    _ => { presets: [], gone: [] }
  }
}

///|
/// Written whole beside it and put in its place.
async fn write_presets(w : World, home : String, presets : Array[J], gone : Array[J]) -> Unit {
  w.ask("fs.mkdir", [js(home)]) |> ignore
  let path = join_path([home, presets_file])
  let temp = "\{path}.\{js_string_of(Some(w.ask("random.hex", [ji(4)])))}"
  let body = @jsjson.stringify_indent(jo([("presets", ja(presets)), ("gone", ja(gone_kept(gone)))]), 2)
  w.ask("fs.writeFile", [js(temp), js(body + "\n")]) |> ignore
  w.ask("fs.rename", [js(temp), js(path)]) |> ignore
}

///|
/// What a preset is said to be (POST, PUT /presets).
pub async fn preset_input(w : World, v : J) -> J {
  let o = match v {
    Null => J::Obj([])
    x => x
  }
  let name = trim(str_of(at(Some(o), "name")).unwrap_or(""))
  if name == "" {
    raise fail_("a preset needs a name")
  }
  if char_count(name) > name_max {
    raise fail_("a preset's name is \{name_max} characters at most")
  }
  let instructions = trim(str_of(at(Some(o), "instructions")).unwrap_or(""))
  if instructions.length() > instructions_max {
    raise fail_("its instructions are too long")
  }
  let raw_dirs = match at(Some(o), "dirs") {
    None | Some(Null) => []
    Some(Arr(xs)) => xs
    Some(_) => raise fail_("dirs: a list of directories")
  }
  let dirs : Array[J] = []
  for d in raw_dirs {
    let given = match d {
      Str(u) => Some(@jsjson.sanitize_str(u))
      _ => str_of(at(Some(d), "path"))
    }
    guard given is Some(given) && trim(given) != "" else { raise fail_("a directory needs a path") }
    let at_ = match d {
      Obj(_) => str_of(at(Some(d), "station"))
      _ => None
    }
    match at_ {
      Some(st) if st != "" => {
        let station_name = str_of(at(Some(d), "stationName")).unwrap_or("")
        if !dirs.iter().any(x => str_of(at(Some(x), "path")) == Some(given) && str_of(at(Some(x), "station")) == Some(st)) {
          let fields = [("path", js(given)), ("repo", jopt(str_of(at(Some(d), "repo")))), ("station", js(st))]
          if station_name != "" {
            fields.push(("stationName", js(station_name)))
          }
          dirs.push(jo(fields))
        }
        continue
      }
      _ => ()
    }
    let path = expand(w, trim(given))
    if !is_directory(w, path) {
      raise fail_("\{given} is no directory on this station")
    }
    if dirs.iter().any(x => str_of(at(Some(x), "path")) == Some(path) && at(Some(x), "station") is None) {
      continue
    }
    dirs.push(jo([("path", js(path)), ("repo", jopt(origin_of(w, path)))]))
  }
  if dirs.length() > dirs_max {
    raise fail_("a preset has \{dirs_max} directories at most")
  }
  let st = stations_of(Some(o))
  let model = preset_model_of(Some(o))
  let fields = [("name", js(name)), ("dirs", ja(dirs)), ("instructions", js(instructions))]
  for f in station_fields(st) {
    fields.push(f)
  }
  if model is Some(m) {
    fields.push(("model", m))
  }
  jo(fields)
}

///|
async fn homedir(w : World) -> String {
  str_of(Some(w.ask("os.homedir", []))).unwrap_or("")
}

///|
async fn expand(w : World, path : String) -> String {
  if path == "~" {
    return homedir(w)
  }
  if starts(path, "~/") {
    return join_path([homedir(w), slice(path, 2)])
  }
  if is_absolute(path) {
    str_of(Some(w.ask("path.resolve", [js(path)]))).unwrap_or(path)
  } else {
    str_of(Some(w.ask("path.resolve", [js(homedir(w)), js(path)]))).unwrap_or(path)
  }
}

///|
async fn is_directory(w : World, path : String) -> Bool {
  try {
    at(Some(w.ask("fs.stat", [js(path)])), "isDirectory") is Some(Bool(true))
  } catch {
    _ => {
      let code = str_of(at(Some(w.thrown.val), "code"))
      code == Some("EPERM") || code == Some("EACCES")
    }
  }
}

///|
/// The repository a clone at `path` is of, if it is one.
pub async fn origin_of(w : World, path : String) -> String? {
  let dir = match git_dir(w, path) {
    Some(d) => d
    None => join_path([path, ".git"])
  }
  let config = try {
    str_of(Some(w.ask("fs.readText", [js(join_path([dir, "config"]))]))).unwrap_or("")
  } catch {
    _ => return None
  }
  origin_in(config)
}

///|
/// The origin a git config names, as `host/owner/name`.
pub fn origin_in(config : String) -> String? {
  let at_ = index_of(config, "[remote \"origin\"]")
  if at_ < 0 {
    return None
  }
  let rest = slice(config, at_)
  // /^\s*url\s*=\s*(.+)$/m
  let mut start = 0
  while start <= rest.length() {
    let line_start = start == 0 || line_end_char(rest.unsafe_charcode_at(start - 1))
    if line_start {
      match url_line(rest, start) {
        Some(u) => {
          let t = trim(u)
          return if t == "" { None } else { Some(repo_name(t)) }
        }
        None => ()
      }
    }
    start += 1
  }
  None
}

///|
/// `^\s*url\s*=\s*(.+)$` at `p` (multiline): the value, or None.
fn url_line(s : String, p : Int) -> String? {
  let n = s.length()
  // \s* may cross lines: try each place the spaces can end
  let mut i = p
  while i <= n {
    if i + 3 <= n && slice(s, i, b=i + 3) == "url" {
      // \s*= (the spaces may cross lines too; `=` is none of them, so it comes right after them)
      let mut k = i + 3
      while k < n && is_js_space(s.unsafe_charcode_at(k)) {
        k += 1
      }
      if k < n && s.unsafe_charcode_at(k) == '=' {
        let j = k + 1
        // \s*(.+)$: the value runs to the line's end; spaces before it taken greedily but leaving at least one char
        let mut v = j
        while v < n && is_js_space(s.unsafe_charcode_at(v)) {
          v += 1
        }
        // back off until (.+)$ matches: (.+) is non-terminators to a line end
        let mut start = v
        while start >= j {
          let mut e = start
          while e < n && !line_end_char(s.unsafe_charcode_at(e)) {
            e += 1
          }
          if e > start {
            return Some(slice(s, start, b=e))
          }
          start -= 1
        }
      }
    }
    if i < n && is_js_space(s.unsafe_charcode_at(i)) {
      i += 1
      continue
    }
    break
  }
  None
}

///|
/// A worktree's `.git` is a file naming its directory in the clone it was made from: the clone's own then.
async fn git_dir(w : World, path : String) -> String? {
  try {
    let dot_git = join_path([path, ".git"])
    if at(Some(w.ask("fs.stat", [js(dot_git)])), "isDirectory") is Some(Bool(true)) {
      return Some(dot_git)
    }
    let text = str_of(Some(w.ask("fs.readText", [js(dot_git)]))).unwrap_or("")
    guard gitdir_line(text) is Some(named) && named != "" else { return None }
    let dir = str_of(Some(w.ask("path.resolve", [js(path), js(named)]))).unwrap_or("")
    let parts = split(dir, "/")
    let mut i = -1
    for k, p in parts {
      if p == "worktrees" {
        i = k
      }
    }
    if i > 0 {
      Some(parts[0:i].to_array().join("/"))
    } else {
      Some(dir)
    }
  } catch {
    _ => None
  }
}

///|
/// `/^gitdir:\s*(.+)$/m`, trimmed.
fn gitdir_line(text : String) -> String? {
  let mut p = 0
  while p < text.length() {
    if (p == 0 || line_end_char(text.unsafe_charcode_at(p - 1))) && slice(text, p, b=p + 7) == "gitdir:" {
      let mut v = p + 7
      while v < text.length() && is_js_space(text.unsafe_charcode_at(v)) {
        v += 1
      }
      let mut start = v
      while start >= p + 7 {
        let mut e = start
        while e < text.length() && !line_end_char(text.unsafe_charcode_at(e)) {
          e += 1
        }
        if e > start {
          return Some(trim(slice(text, start, b=e)))
        }
        start -= 1
      }
    }
    p += 1
  }
  None
}

///|
/// `git@github.com:o/r.git`, `https://github.com/o/r.git` → `github.com/o/r`.
pub fn repo_name(url : String) -> String {
  let mut u = trim(url)
  if ends(u, ".git") {
    u = slice(u, 0, b=u.length() - 4)
  }
  while ends(u, "/") {
    u = slice(u, 0, b=u.length() - 1)
  }
  // /^[^@/]+@([^:/]+):(.+)$/
  let atp = index_of(u, "@")
  if atp > 0 && !slice(u, 0, b=atp).contains("/") {
    let rest = slice(u, atp + 1)
    let colon = index_of(rest, ":")
    if colon > 0 && !slice(rest, 0, b=colon).contains("/") && colon + 1 < rest.length() {
      let tail = slice(rest, colon + 1)
      if !tail.contains("\n") {
        return "\{slice(rest, 0, b=colon)}/\{tail}"
      }
    }
  }
  // ^[a-z+]+:\/\/ (any case)
  let mut i = 0
  while i < u.length() {
    let c = u.unsafe_charcode_at(i)
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '+' {
      i += 1
    } else {
      break
    }
  }
  if i > 0 && slice(u, i, b=i + 3) == "://" {
    u = slice(u, i + 3)
  }
  // ^[^@/]+@
  let a2 = index_of(u, "@")
  if a2 > 0 && !slice(u, 0, b=a2).contains("/") {
    u = slice(u, a2 + 1)
  }
  u
}

///|
fn same_email(a : String, b : String) -> Bool {
  a != "" && lower(a) == lower(b)
}

///|
/// This station's id ("" before it has one).
pub async fn presets_me(w : World) -> String {
  str_of(Some(w.ask("presets.station", []))).unwrap_or("")
}

///|
/// Whether a folder's `station` (an address, or an id) is this station.
pub async fn presets_is_here(w : World, station : String) -> Bool {
  let me = presets_me(w)
  me != "" && (station == me || ends(station, "/\{me}"))
}

///|
/// The name a folder's station is told by.
pub async fn presets_name_of(w : World, station : String, said : String?) -> String {
  let id = slice(station, last_index_of(station, "/") + 1)
  match str_of(Some(w.ask("presets.stationName", [js(id)]))) {
    Some(n) if n != "" => n
    _ =>
      match said {
        Some(s) if s != "" => s
        _ => id
      }
  }
}

///|
async fn presets_address(w : World, ws : J) -> String {
  let given = w.ask_u("presets.workspace", [ws])
  let wsid = match given {
    Some(Null) | None => str_of(Some(ws))
    Some(v) => str_of(Some(v))
  }
  match wsid {
    Some(x) if x != "" => "\{x}/\{presets_me(w)}"
    _ => presets_me(w)
  }
}

///|
async fn presets_home(w : World, ws : J) -> String {
  str_of(Some(w.ask("presets.home", [ws]))).unwrap_or("")
}

///|
async fn presets_file_of(w : World, ws : J) -> PresetsFile {
  read_presets_file(w, presets_home(w, ws), presets_me(w))
}

///|
pub async fn presets_list(w : World, ws : J) -> Array[J] {
  presets_file_of(w, ws).presets
}

///|
pub async fn presets_listed(w : World, ws : J) -> Array[J] {
  let me = presets_me(w)
  presets_list(w, ws).filter(p => str_of(at(Some(p), "home")) == Some(me))
}

///|
pub async fn presets_get(w : World, ws : J, id : String) -> J {
  match presets_list(w, ws).search_by(p => str_of(at(Some(p), "id")) == Some(id)) {
    Some(i) => presets_list(w, ws)[i]
    None => Null
  }
}

///|
fn no_preset(id : String) -> Thrown {
  Thrown("NoPreset", "no preset \{id}")
}

///|
/// A preset made by an app from before (POST /presets).
pub async fn presets_add(w : World, ws : J, input : J, by : String, owner : String) -> J {
  let given = preset_input(w, input)
  let file = presets_file_of(w, ws)
  let now = w.ask("presets.now", [])
  let id = "p-\{js_string_of(Some(w.ask("random.hex", [ji(5)])))}"
  let preset = spread(
    spread(jo([("id", js(id))]), given),
    jo([("createdBy", js(by)), ("createdAt", now), ("updatedAt", now), ("owner", js(owner)), ("rev", ji(1)), ("home", js(presets_me(w)))]),
  )
  write_presets(w, presets_home(w, ws), file.presets + [preset], file.gone)
  preset
}

///|
fn owner_after(prev : J, who : J?) -> String {
  let owner = str_of(at(Some(prev), "owner")).unwrap_or("")
  match who {
    None => owner
    Some(wh) => {
      let sub = str_of(at(Some(wh), "sub")).unwrap_or("")
      if owner != "" || sub == "" {
        owner
      } else if same_email(str_of(at(Some(prev), "createdBy")).unwrap_or(""), str_of(at(Some(wh), "email")).unwrap_or("")) {
        sub
      } else {
        ""
      }
    }
  }
}

///|
/// A preset changed by an app from before (PUT /presets/:id): one change more.
pub async fn presets_put(w : World, ws : J, id : String, input : J, who : J?) -> J {
  let file = presets_file_of(w, ws)
  let all = file.presets.copy()
  guard all.search_by(p => str_of(at(Some(p), "id")) == Some(id)) is Some(i) else { raise no_preset(id) }
  let prev = all[i]
  let given = preset_input(w, input)
  let preset = spread(
    spread(jo([("id", at(Some(prev), "id").unwrap())]), given),
    jo([
      ("createdBy", at(Some(prev), "createdBy").unwrap_or(Null)),
      ("createdAt", at(Some(prev), "createdAt").unwrap_or(Null)),
      ("updatedAt", w.ask("presets.now", [])),
      ("owner", js(owner_after(prev, who))),
      ("rev", jn(num_of(at(Some(prev), "rev")).unwrap_or(1.0) + 1.0)),
      ("home", at(Some(prev), "home").unwrap_or(Null)),
    ]),
  )
  all[i] = preset
  write_presets(w, presets_home(w, ws), all, file.gone)
  preset
}

///|
/// A preset deleted by an app from before (DELETE /presets/:id): kept deleted, one change more.
pub async fn presets_delete(w : World, ws : J, id : String, who : J?) -> Unit {
  let file = presets_file_of(w, ws)
  guard file.presets.search_by(p => str_of(at(Some(p), "id")) == Some(id)) is Some(i) else { raise no_preset(id) }
  let prev = file.presets[i]
  let gone = jo([
    ("id", js(id)),
    ("owner", js(owner_after(prev, who))),
    ("rev", jn(num_of(at(Some(prev), "rev")).unwrap_or(1.0) + 1.0)),
    ("gone", jb(true)),
    ("updatedAt", w.ask("presets.now", [])),
  ])
  write_presets(
    w,
    presets_home(w, ws),
    file.presets.filter(p => str_of(at(Some(p), "id")) != Some(id)),
    file.gone.filter(g => str_of(at(Some(g), "id")) != Some(id)) + [gone],
  )
}

///|
/// A preset as it is carried: every folder naming its station.
pub async fn presets_record(w : World, ws : J, p : J) -> J {
  let here = presets_address(w, ws)
  record_with(p, here)
}

///|
fn record_with(p : J, here : String) -> J {
  let o = Some(p)
  let dirs = arr_of(at(o, "dirs")).unwrap_or([]).map(d => jo([
    ("path", at(Some(d), "path").unwrap_or(Null)),
    ("repo", at(Some(d), "repo").unwrap_or(Null)),
    ("station", match at(Some(d), "station") { Some(s) => s; None => js(here) }),
  ]))
  let fields = [
    ("id", at(o, "id").unwrap_or(Null)),
    ("name", at(o, "name").unwrap_or(Null)),
    ("dirs", ja(dirs)),
    ("instructions", at(o, "instructions").unwrap_or(Null)),
  ]
  if at(o, "autoStation") is Some(Bool(true)) {
    fields.push(("autoStation", jb(true)))
  }
  match str_of(at(o, "station")) {
    Some(s) if s != "" => fields.push(("station", js(s)))
    _ => ()
  }
  match at(o, "stations") {
    Some(Arr(_) as ss) => fields.push(("stations", ss))
    _ => ()
  }
  match at(o, "model") {
    Some(Obj(_) as m) => fields.push(("model", m))
    _ => ()
  }
  for k in ["createdBy", "createdAt", "updatedAt", "owner", "rev", "home"] {
    fields.push((k, at(o, k).unwrap_or(Null)))
  }
  jo(fields)
}

///|
async fn presets_records(w : World, ws : J, file : PresetsFile) -> Array[(String, J)] {
  let here = presets_address(w, ws)
  let out : Array[(String, J)] = []
  for r in file.presets.map(p => record_with(p, here)) + file.gone {
    let id = str_of(at(Some(r), "id")).unwrap_or("")
    match out.search_by(x => x.0 == id) {
      Some(i) => out[i] = (id, newer_record(out[i].1, r))
      None => out.push((id, r))
    }
  }
  out
}

///|
/// The order an object keeps its keys in: integer-like ones first, ascending.
fn integer_keys_first(pairs : Array[(String, J)]) -> Array[(String, J)] {
  let index = (k : String) => {
    if k == "" || k.length() > 10 || (k.length() > 1 && starts(k, "0")) || !all_digits(k) {
      None
    } else {
      let d = @jsjson.parse(k) catch { _ => J::Null }
      match d {
        Num(x) if x <= 4294967294.0 => Some(x)
        _ => None
      }
    }
  }
  let ints = pairs.filter(p => index(p.0) is Some(_))
  ints.sort_by((a, b) => {
    let x = index(a.0).unwrap()
    let y = index(b.0).unwrap()
    if x < y { -1 } else if x > y { 1 } else { 0 }
  })
  ints + pairs.filter(p => index(p.0) is None)
}

///|
/// Whether `r` is `who`'s.
pub fn presets_theirs(r : J, who : J) -> Bool {
  let sub = str_of(at(Some(who), "sub")).unwrap_or("")
  if sub == "" {
    return false
  }
  let owner = str_of(at(Some(r), "owner")).unwrap_or("")
  if owner == sub {
    return true
  }
  owner == "" && !is_gone(r) && same_email(str_of(at(Some(r), "createdBy")).unwrap_or(""), str_of(at(Some(who), "email")).unwrap_or(""))
}

///|
/// What GET /presets/kept answers.
pub async fn presets_kept(w : World, ws : J, who : J) -> Array[J] {
  let sub = str_of(at(Some(who), "sub")).unwrap_or("")
  presets_records(w, ws, presets_file_of(w, ws))
  .map(x => x.1)
  .filter(r => presets_theirs(r, who) || (is_gone(r) && str_of(at(Some(r), "owner")) == Some("") && sub != ""))
}

///|
/// What GET /presets/others answers.
pub async fn presets_others(w : World, ws : J, who : J) -> Array[J] {
  presets_records(w, ws, presets_file_of(w, ws)).map(x => x.1).filter(r => !is_gone(r) && !presets_theirs(r, who))
}

///|
/// Records `who`'s device brings (PUT /presets/kept).
pub async fn presets_carry(w : World, ws : J, who : J, given : Array[J]) -> J {
  let file = presets_file_of(w, ws)
  let was = presets_records(w, ws, file)
  let all = was.copy()
  let refused = []
  let asked : Array[String] = []
  let sub = str_of(at(Some(who), "sub")).unwrap_or("")
  let mut live = all.filter(r => !is_gone(r.1)).length()
  let find = (id : String) => match all.search_by(x => x.0 == id) {
    Some(i) => Some(all[i].1)
    None => None
  }
  for i, raw in given {
    let id = match at(Some(raw), "id") {
      Some(Str(_) as s) => s
      _ => J::Null
    }
    let refuse = (error : String) => refused.push(jo([("at", ji(i)), ("id", id), ("error", js(error))]))
    let r = try {
      record_of(raw)
    } catch {
      e => {
        refuse(thrown_message(e))
        continue
      }
    }
    let rid = str_of(at(Some(r), "id")).unwrap_or("")
    if sub == "" || str_of(at(Some(r), "owner")) != Some(sub) {
      refuse("a record is taken only from its owner's devices (owner: their sub)")
      continue
    }
    let held = find(rid)
    match held {
      Some(h) => {
        let howner = str_of(at(Some(h), "owner")).unwrap_or("")
        if howner != "" && howner != sub {
          refuse("preset \{rid} is someone else's")
          continue
        }
        if howner == "" && !is_gone(h) && !presets_theirs(h, who) {
          refuse("preset \{rid} was made by someone else")
          continue
        }
      }
      None => ()
    }
    if !asked.contains(rid) {
      asked.push(rid)
    }
    match held {
      Some(h) => if jeq(newer_record(h, r), h) || canonical(h) == canonical(r) { continue }
      None => ()
    }
    let now_live = !is_gone(r) && (match held { None => true; Some(h) => is_gone(h) })
    if now_live && live >= live_most {
      refuse("this station keeps \{live_most} presets of a workspace at most")
      continue
    }
    if now_live {
      live += 1
    } else if is_gone(r) && (match held { Some(h) => !is_gone(h); None => false }) {
      live -= 1
    }
    match all.search_by(x => x.0 == rid) {
      Some(k) => all[k] = (rid, r)
      None => all.push((rid, r))
    }
  }
  let before = records_kept(integer_keys_first(was))
  let after = records_kept(integer_keys_first(all))
  let ids : Array[String] = []
  for p in before + after {
    if !ids.contains(p.0) {
      ids.push(p.0)
    }
  }
  let get = (xs : Array[(String, J)], id : String) => match xs.search_by(x => x.0 == id) {
    Some(i) => Some(xs[i].1)
    None => None
  }
  let changed = ids.iter().any(id => match (get(before, id), get(after, id)) {
    (Some(a), Some(b)) => !jeq(a, b)
    (None, None) => false
    _ => true
  })
  if changed {
    presets_write(w, ws, file, after)
  }
  let records = asked.filter_map(id => get(after, id))
  jo([("records", ja(records)), ("refused", ja(refused)), ("changed", jb(changed))])
}

///|
async fn presets_write(w : World, ws : J, file : PresetsFile, all : Array[(String, J)]) -> Unit {
  let here = presets_address(w, ws)
  let presets = []
  let gone = []
  for p in all {
    let r = p.1
    if is_gone(r) {
      gone.push(r)
    } else {
      let held = file.presets.search_by(x => str_of(at(Some(x), "id")) == Some(p.0))
      match held {
        Some(i) if canonical(record_with(file.presets[i], here)) == canonical(r) => presets.push(file.presets[i])
        _ => presets.push(r)
      }
    }
  }
  write_presets(w, presets_home(w, ws), presets, gone)
}

///|
/// Keeps what a chat in `workspace` is opened with: preset `id` as it is now.
pub async fn presets_keep_for(w : World, workspace : String, ws : J, id : String) -> J {
  let p = presets_get(w, ws, id)
  if p is Null {
    raise no_preset(id)
  }
  let dirs = []
  for d in arr_of(at(Some(p), "dirs")).unwrap_or([]) {
    let station = str_of(at(Some(d), "station"))
    let rest = without(d, ["station", "stationName"])
    match station {
      None => dirs.push(rest)
      Some(s) =>
        if presets_is_here(w, s) {
          dirs.push(rest)
        } else {
          dirs.push(set_field(rest, "elsewhere", js(presets_name_of(w, s, str_of(at(Some(d), "stationName"))))))
        }
    }
  }
  keep_copy(
    w,
    workspace,
    jo([("id", at(Some(p), "id").unwrap_or(Null)), ("name", at(Some(p), "name").unwrap_or(Null)), ("dirs", ja(dirs)), ("instructions", at(Some(p), "instructions").unwrap_or(Null))]),
  )
}

///|
let guides : Array[String] = ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md"]

///|
let skill_homes : Array[String] = [".claude/skills", ".agents/skills"]

///|
let guide_most : Int = 16384

///|
/// Keeps `copy` as what a chat in `workspace` is opened with: its folders' instruction files kept with it, their skills
/// linked into the chat's workspace.
pub async fn keep_copy(w : World, workspace : String, copy : J) -> J {
  let linked : Array[String] = []
  let dirs = []
  for d in arr_of(at(Some(copy), "dirs")).unwrap_or([]) {
    if at(Some(d), "elsewhere") is Some(_) {
      dirs.push(d)
      continue
    }
    let path = str_of(at(Some(d), "path")).unwrap_or("")
    let found = []
    for file in guides {
      match guide_of(w, join_path([path, file])) {
        Some((text, whole)) => found.push(jo([("file", js(file)), ("text", js(text)), ("whole", jb(whole))]))
        None => ()
      }
    }
    let skills = []
    for home in skill_homes {
      let names = try {
        arr_of(Some(w.ask("fs.readdir", [js(join_path([path, home]))]))).unwrap_or([]).map(x => str_of(Some(x)).unwrap_or(""))
      } catch {
        _ => []
      }
      for n in names {
        let from = join_path([path, home, n])
        let has = try {
          w.ask("fs.stat", [js(join_path([from, "SKILL.md"]))]) |> ignore
          true
        } catch {
          _ => false
        }
        if !has {
          continue
        }
        let name = if linked.contains(n) { "\{basename(path)}-\{n}" } else { n }
        if linked.contains(name) {
          continue
        }
        linked.push(name)
        skills.push(js(name))
        for to in skill_homes {
          w.ask("fs.mkdir", [js(join_path([workspace, to]))]) |> ignore
          try {
            w.ask("fs.symlink", [js(from), js(join_path([workspace, to, name])), js("dir")]) |> ignore
          } catch {
            _ => ()
          }
        }
      }
    }
    let mut kept = d
    if found.length() > 0 {
      kept = set_field(kept, "guides", ja(found))
    }
    if skills.length() > 0 {
      kept = set_field(kept, "skills", ja(skills))
    }
    dirs.push(kept)
  }
  let kept = set_field(copy, "dirs", ja(dirs))
  let path = join_path([workspace, copy_file])
  let temp = "\{path}.\{js_string_of(Some(w.ask("random.hex", [ji(4)])))}"
  w.ask("fs.writeFile", [js(temp), js(@jsjson.stringify_indent(kept, 2) + "\n")]) |> ignore
  w.ask("fs.rename", [js(temp), js(path)]) |> ignore
  kept
}

///|
/// A folder's instruction file as a chat is told it: its first bytes, and whether that is all of it.
async fn guide_of(w : World, path : String) -> (String, Bool)? {
  try {
    let head = w.ask("fs.readHead", [js(path), ji(guide_most + 1), ji(guide_most)])
    let got = num_of(at(Some(head), "got")).unwrap_or(0.0)
    Some((trim(str_of(at(Some(head), "text")).unwrap_or("")), got <= guide_most.to_double()))
  } catch {
    _ => None
  }
}

///|
/// A preset of another station's as the asking app gives it, taken as said.
pub fn preset_copy_input(v : J) -> J raise Thrown {
  let o = Some(match v { Null => J::Obj([]); x => x })
  let name = trim(str_of(at(o, "name")).unwrap_or(""))
  if name == "" || char_count(name) > name_max {
    raise fail_("presetCopy: a preset needs a name")
  }
  let dirs = dirs_of(at(o, "dirs"))
  let dirs = dirs[0:@cmp.minimum(dirs_max, dirs.length())].to_array()
  let instructions = slice(str_of(at(o, "instructions")).unwrap_or(""), 0, b=instructions_max)
  let model = model_of(at(o, "model"))
  let st = stations_of(Some(jo([("stations", at(o, "stations").unwrap_or(jo([("$u", ji(1))])))])))
  let st = if at(o, "stations") is None { stations_of(Some(J::Obj([]))) } else { st }
  let stations = match st.1 {
    Some(s) => Some([s])
    None => st.2
  }
  let fields = [
    ("id", js(str_of(at(o, "id")).unwrap_or(""))),
    ("name", js(name)),
    ("dirs", ja(dirs.map(d => without(d, ["station", "stationName", "guides", "skills"])))),
    ("instructions", js(instructions)),
  ]
  if model is Some(m) {
    fields.push(("model", m))
  }
  if stations is Some(ss) {
    fields.push(("stations", jsa(ss)))
  }
  jo(fields)
}

///|
/// What a chat whose session workspace is `workspace` was opened with, if anything.
pub async fn preset_copy_of(w : World, workspace : String) -> J {
  try {
    let v = parse_js(str_of(Some(w.ask("fs.readText", [js(join_path([workspace, copy_file]))]))).unwrap_or(""))
    guard str_of(at(Some(v), "id")) is Some(id) && str_of(at(Some(v), "name")) is Some(name) else { return Null }
    jo([("id", js(id)), ("name", js(name)), ("dirs", ja(dirs_of(at(Some(v), "dirs")))), ("instructions", js(str_of(at(Some(v), "instructions")).unwrap_or("")))])
  } catch {
    _ => Null
  }
}

///|
/// What the agent of a chat opened with `copy` is told of it, after the station's own instructions.
pub fn preset_instructions(copy : J) -> String {
  let cdirs = arr_of(at(Some(copy), "dirs")).unwrap_or([])
  let dirs = cdirs.map(d => {
    let path = str_of(at(Some(d), "path")).unwrap_or("")
    let repo = match str_of(at(Some(d), "repo")) {
      Some(r) if r != "" => Some(r)
      _ => None
    }
    match str_of(at(Some(d), "elsewhere")) {
      None =>
        "  - \{path}" +
        (match repo {
          Some(r) => " (a clone of \{r}: change it in a worktree of your own, as with any repository)"
          None => ""
        })
      Some(e) =>
        match repo {
          Some(r) =>
            "  - \{r}: this station's clone of it (in the repository cache; clone it there if it is not yet), a worktree of your own to change it (on \{e} it is \{path})"
          None =>
            "  - \{path} on station \{e}: read it there with the station tools (station_task, station_file), not copied here"
        }
    }
  })
  let name = str_of(at(Some(copy), "name")).unwrap_or("")
  let lines = [
    "",
    "",
    "This chat was opened with the preset \"\{name}\": what people set up for this kind of work. It does not change for this chat.",
  ]
  let skills_of = (d : J) => arr_of(at(Some(d), "skills")).unwrap_or([]).map(x => js_string(x))
  if dirs.length() > 0 {
    lines.push(
      "- The directories it works with (no need to ask which; you still run in your session workspace and may go anywhere):",
    )
    for l in dirs {
      lines.push(l)
    }
    if cdirs.iter().any(d => skills_of(d).length() > 0) {
      let all = []
      for d in cdirs {
        for s in skills_of(d) {
          all.push(s)
        }
      }
      lines.push(
        "  Their skills are linked into your workspace (.claude/skills, .agents/skills): \{all.join(", ")}; use them as your own.",
      )
    }
    for d in cdirs {
      for g in arr_of(at(Some(d), "guides")).unwrap_or([]) {
        lines.push(
          "<folder-instructions path=\"\{join_path([str_of(at(Some(d), "path")).unwrap_or(""), str_of(at(Some(g), "file")).unwrap_or("")])}\">",
        )
        lines.push(str_of(at(Some(g), "text")).unwrap_or(""))
        if !(at(Some(g), "whole") is Some(Bool(true))) {
          lines.push("(only its start: read the rest there)")
        }
        lines.push("</folder-instructions>")
      }
    }
    if cdirs.iter().any(d => at(Some(d), "elsewhere") is Some(_)) {
      lines.push(
        "  For those on other stations, read their AGENTS.md, CLAUDE.md and skills there before the first task.",
      )
    }
  }
  let instructions = str_of(at(Some(copy), "instructions")).unwrap_or("")
  if instructions != "" {
    lines.push("- What people want of chats with this preset (theirs to change, not yours):")
    lines.push("<preset-instructions>")
    lines.push(instructions)
    lines.push("</preset-instructions>")
  }
  lines.join("\n")
}

///|
/// A path as people read it: under the home, `~/…`.
pub async fn short_path(w : World, path : String) -> String {
  let home = homedir(w)
  if path == home {
    "~"
  } else if starts(path, home + "/") {
    "~" + slice(path, home.length())
  } else {
    path
  }
}
