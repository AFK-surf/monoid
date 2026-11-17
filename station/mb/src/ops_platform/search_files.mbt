// station/src/search/files.ts, skills.ts, search.ts and module.ts around the program's own search (station/search):
// the machine's files a search finds (Spotlight's query, or the home walked as a search comes), how they are ranked
// and shown, when a search of the machine is answered as it was, whose turn it is; a skill read by its name; the files
// put beside the rest of what a search finds.

///|
pub let search_short : Int = 3

///|
pub let search_most : Int = 1000

///|
pub let search_most_said : Int = 100

///|
pub let search_kept_ms : Double = 5000.0

///|
pub let search_asked_again_ms : Double = 60000.0

///|
pub let search_asked_again_guess_ms : Double = 20000.0

///|
pub let search_at_once : Int = 2

///|
pub let search_walk_ms : Double = 3000.0

///|
pub let search_walk_depth : Int = 16

///|
pub let search_walk_entries : Int = 200000

///|
let search_protected : Array[String] = ["Documents", "Desktop", "Downloads"]

///|
let search_apps : Array[String] = ["/Applications", "/System/Applications"]

///|
/// files.ts `PERSONAL`.
pub let search_personal : Array[String] = [
  "Library/Mail", "Library/Messages", "Library/Calendars", "Library/Application Support/AddressBook", "Library/Group Containers/group.com.apple.notes",
  "Library/Containers/com.apple.Notes", "Library/Metadata/CoreSpotlight", "Pictures/Photos Library.photoslibrary",
]

///|
/// files.ts `under`.
fn under_dir(path : String, dir : String) -> Bool {
  path == dir || starts(path, if ends(dir, "/") { dir } else { dir + "/" })
}

///|
/// files.ts `quoted`: a word as Spotlight's query language has it in a string.
fn md_quoted(word : String) -> String {
  let b = StringBuilder()
  for i in 0..<word.length() {
    let c = cu(word, i)
    if c == 92 || c == 34 || c == 42 || c == 63 {
      b.write_char('\\')
    }
    b.write_char(Int::unsafe_to_char(c))
  }
  b.to_string()
}

///|
/// files.ts `spotlightQuery`: names (`content`: and what files say); None for what files say where every word is short.
pub fn spotlight_query(words : Array[String], content : Bool) -> String? {
  if content && words.iter().all(w => w.length() < search_short) {
    return None
  }
  let name = (w : String) => if w.length() < search_short {
    "kMDItemFSName == \"\{md_quoted(w)}*\"cd"
  } else {
    "kMDItemFSName == \"*\{md_quoted(w)}*\"cd"
  }
  Some(
    words
    .map(w => if content && w.length() >= search_short {
      "(\{name(w)} || kMDItemTextContent == \"\{md_quoted(w)}*\"cdw)"
    } else {
      name(w)
    })
    .join(" && "),
  )
}

///|
let search_noise : Array[String] = [
  "node_modules", ".git", "venv", ".venv", "site-packages", "dist-packages", "__pycache__", "target", "Pods", "DerivedData", ".cache",
  ".Trash", ".npm", ".pnpm-store", ".cargo", ".rustup", ".gradle", ".m2",
]

///|
/// files.ts `noisy`: a path through what tools make and keep, or the home's Library.
pub fn noisy(path : String, home : String) -> Bool {
  let parts = split_on(path, "/")
  for i, p in parts {
    if search_noise.contains(p) {
      return true
    }
    // (`parts.indexOf(p)`: the first part of that name)
    if ends(p, ".app") && parts.search_by(x => x == p).unwrap_or(i) < parts.length() - 1 {
      return true
    }
  }
  under_dir(path, posix_join([home, "Library"]))
}

///|
/// files.ts `mdfind`'s arguments.
pub fn mdfind_args(query : String, within : Array[String]) -> Array[String] {
  let out = ["-0"]
  for w in within {
    out.push("-onlyin")
    out.push(w)
  }
  out.push(query)
  out
}

///|
/// files.ts `mdfind`'s reading of its output: the paths as they come (NUL-separated), at most `most`; whether it was
/// stopped for that.
pub fn mdfind_paths(chunks : Array[String], most : Int) -> Array[String] {
  let paths = []
  let mut carry = ""
  for chunk in chunks {
    let parts = split_on(carry + chunk, "\u{0}")
    carry = parts.pop().unwrap_or("")
    for p in parts {
      if p != "" && paths.length() < most {
        paths.push(p)
      }
    }
    if paths.length() >= most {
      break
    }
  }
  paths
}

///|
let search_skipped : Array[String] = [
  "node_modules", "target", "dist", "build", ".git", "__pycache__", ".venv", "venv", "Pods", "DerivedData", ".cache", "Library", "AppData",
]

///|
let search_text_exts : Array[String] = [
  "md", "markdown", "txt", "text", "log", "csv", "tsv", "json", "jsonl", "yml", "yaml", "toml", "ini", "conf", "cfg", "xml", "htm",
  "html", "css", "scss", "less", "js", "jsx", "mjs", "cjs", "ts", "tsx", "py", "rb", "go", "rs", "java", "kt", "kts", "swift", "c",
  "cc", "cpp", "h", "hpp", "cs", "php", "sh", "bash", "zsh", "fish", "ps1", "sql", "r", "lua", "pl", "ex", "exs", "erl", "hs",
  "scala", "clj", "vue", "svelte", "tex", "rst", "org", "srt", "vtt",
]

///|
/// files.ts `TEXTS`: a text file by its name's extension (case aside).
pub fn text_name(name : String) -> Bool {
  let dot = last_index_of(name, ".")
  dot >= 0 && search_text_exts.contains(lower(sub(name, dot + 1, name.length())))
}

///|
pub let search_text_max : Double = 262144.0

///|
/// files.ts `walk`: the files and folders under `tops` whose name has every word, or (a small text file) whose name
/// and words have them; whether some were not reached (`left`).
pub fn search_walk(
  fs : Fs,
  tops : Array[String],
  words : Array[String],
  skip : Array[String],
  most : Int,
  ms : Double,
  now : () -> Double,
) -> (Array[String], Bool) raise {
  let has_all = (text : String) => {
    let low = lower(text)
    words.iter().all(w => has(low, w))
  }
  let paths = []
  let o = { ..WalkOptions::default(now), follow_root: true, max_depth: search_walk_depth, max_entries: search_walk_entries, max_duration_ms: ms }
  let walked = walk_bounded(
    fs,
    tops,
    d => {
      if d.depth == 0 {
        return Go
      }
      if paths.length() >= most {
        return Stop
      }
      if starts(d.name, ".") {
        return Skip
      }
      let path = d.path
      if skip.iter().any(s => under_dir(path, s)) {
        return Skip
      }
      if d.directory {
        if has_all(d.name) {
          paths.push(path)
        }
        return if search_skipped.contains(d.name) { Skip } else { Go }
      }
      if !d.file {
        return Go
      }
      if has_all(d.name) {
        paths.push(path)
        return Go
      }
      if !text_name(d.name) {
        return Go
      }
      let read = try {
        match fs.meta(path) {
          Some((size, _, _)) if size <= search_text_max => fs.read(path)
          _ => None
        }
      } catch {
        _ => None
      }
      match read {
        Some(text) => if has_all(d.name + "\n" + text) { paths.push(path) }
        None => ()
      }
      Go
    },
    o,
  )
  (paths, (walked.truncated && walked.reason != Some("depth")) || paths.length() >= most)
}

///|
/// files.ts `#search`'s choice among what was found (each path with its stats: a folder, its size, its mtime; None
/// where it is gone): what is listed for the asker, ranked, the first `limit` as hits; None where there are none.
pub fn file_hits(
  found : Array[String],
  words : Array[String],
  home : String,
  writer : Bool,
  pinned : Array[String],
  protect : Array[String],
  personal_on : Bool,
  limit : Int,
  left : Bool,
  stat : (String) -> (Bool, Double, Double)?,
) -> Json {
  let own = search_personal.map(d => posix_join([home, d]))
  let unique = []
  for p in found {
    if !unique.contains(p) {
      unique.push(p)
    }
  }
  let kept = unique.filter(p => (personal_on && own.iter().any(d => under_dir(p, d))) || !noisy(p, home))
  let personal = if personal_on { [] } else { own }
  let listed = kept.filter(p => !protect.iter().any(d => under_dir(p, d)) &&
    !personal.iter().any(d => under_dir(p, d)) &&
    (writer || pinned.iter().any(r => under_dir(p, r))))
  let first = words[0]
  let named = (p : String) => has(lower(posix_basename(p)), first)
  let files = listed.filter_map(path => match stat(path) {
    Some((dir, size, at)) => Some((path, dir, size, at))
    None => None
  })
  let app = (p : String) => ends(p, ".app") && search_apps.iter().any(d => under_dir(p, d))
  let rank = (p : String) => (if named(p) { 0 } else { 4 }) + (if app(p) { 0 } else { 2 })
  let depth = (p : String) => split_on(p, "/").length()
  let sorted = stable_sort(files, (a, b) => {
    let r = rank(a.0) - rank(b.0)
    if r != 0 {
      return r
    }
    let d = depth(a.0) - depth(b.0)
    if d != 0 {
      return d
    }
    let t = b.3 - a.3
    if t > 0.0 {
      1
    } else if t < 0.0 {
      -1
    } else {
      0
    }
  })
  let shown = (dir : String) => if under_dir(dir, home) { "~" + sub(dir, home.length(), dir.length()) } else { dir }
  let hits = sorted[0:@cmp.minimum(limit, sorted.length())]
    .to_owned()
    .map(f => {
      let (path, dir, size, at) = f
      let root = if writer {
        None
      } else {
        match pinned.search_by(r => under_dir(path, r)) {
          Some(k) => Some(pinned[k])
          None => None
        }
      }
      let m : Map[String, Json] = {
        "kind": "file",
        "key": js("f:" + path),
        "title": js(posix_basename(path)),
        "text": js(shown(posix_dirname(path))),
        "at": jn(js_round(at)),
        "path": js(path),
      }
      match root {
        Some(r) => {
          m["root"] = js(r)
          let mut rel = sub(path, r.length(), path.length())
          while rel != "" && (cu(rel, 0) == 47 || cu(rel, 0) == 92) {
            rel = sub(rel, 1, rel.length())
          }
          m["rel"] = js(rel)
        }
        None => ()
      }
      m["dir"] = jb(dir)
      m["size"] = jn(size)
      Json::object(m)
    })
  if hits.is_empty() {
    Json::null()
  } else {
    { "kind": "file", "hits": Json::array(hits), "more": jb(sorted.length() > limit || left) }
  }
}

///|
/// files.ts `#search`'s asks of Spotlight: each a query, the folders it looks in and how many it gives (the writer's
/// three, a read-only member's one in what is pinned; the protected folders asked of still.fail Helper apart).
pub fn spotlight_asks(words : Array[String], writer : Bool, home : String, open_pinned : Array[String]) -> Array[Json] {
  let said = spotlight_query(words, true)
  let names = spotlight_query(words, false).unwrap()
  if writer {
    let out : Array[Json] = [{ "query": js(names), "within": jstrs([home]), "most": ji(search_most) }]
    match said {
      Some(s) => out.push({ "query": js(s), "within": jstrs([home]), "most": ji(search_most_said) })
      None => ()
    }
    out.push({ "query": js(names), "within": jstrs(search_apps), "most": ji(50) })
    out
  } else if open_pinned.length() > 0 {
    [{ "query": js(said.unwrap_or(names)), "within": jstrs(open_pinned), "most": ji(search_most) }]
  } else {
    []
  }
}

///|
/// files.ts `#search`: the folders a writer asks still.fail Helper about (the home's protected ones), a read-only
/// member's those of what is pinned that are kept.
pub fn guarded_tops(writer : Bool, home : String, kept_pinned : Array[String]) -> Array[String] {
  if writer {
    search_protected.map(n => posix_join([home, n]))
  } else {
    kept_pinned
  }
}

///|
/// files.ts `query`'s key: what a search is the same search by.
pub fn file_search_key(
  words : Array[String],
  workspace : String,
  home : Bool,
  writer : Bool,
  limit : Int,
  personal : Bool,
  roots : Array[String],
) -> String {
  js_stringify(Json::array([jstrs(words), js(workspace), jb(home), jb(writer), ji(limit), jb(personal), jstrs(roots)]))
}

///|
/// files.ts `query`'s choice: whether what was found `age` ago is given again (KEPT_MS; asked again as the chats
/// changed, ASKED_AGAIN_MS; a device that seems to ask again, ASKED_AGAIN_GUESS_MS).
pub fn file_search_reuse(age : Double?, again : Bool, guessed : Bool) -> Bool {
  match age {
    None => false
    Some(a) =>
      a <= search_kept_ms ||
      (again && a <= search_asked_again_ms) ||
      (guessed && a <= search_asked_again_guess_ms)
  }
}

///|
/// files.ts `#turn`'s `before`: a search of the same typist's typed on (one's words the start of the other's).
pub fn typed_on(typist : String?, typed : String, other_typist : String?, other_typed : String) -> Bool {
  match typist {
    None => false
    Some(t) => other_typist == Some(t) && (starts(typed, other_typed) || starts(other_typed, typed))
  }
}

///|
/// files.ts `FileSearch`'s searches going and waiting: whose turn each is.
pub struct Turns {
  going : Array[(Int, String?, String)]
  waiting : Array[(Int, String?, String)]
}

///|
pub fn Turns::new() -> Turns {
  { going: [], waiting: [] }
}

///|
/// A search asks its turn: those it types on stopped (going) or dropped (waiting); it goes, or waits. What each did.
pub fn Turns::ask(self : Turns, id : Int, typist : String?, typed : String) -> Json {
  let stopped = self.going.filter(g => typed_on(typist, typed, g.1, g.2)).map(g => ji(g.0))
  let dropped = self.waiting.filter(w => typed_on(typist, typed, w.1, w.2)).map(w => ji(w.0))
  let kept = self.waiting.filter(w => !typed_on(typist, typed, w.1, w.2))
  self.waiting.clear()
  self.waiting.push_iter(kept.iter())
  let goes = self.going.length() < search_at_once
  if goes {
    self.going.push((id, typist, typed))
  } else {
    self.waiting.push((id, typist, typed))
  }
  { "stopped": Json::array(stopped), "dropped": Json::array(dropped), "goes": jb(goes) }
}

///|
/// A search done (`#next`): the next waiting goes. Which.
pub fn Turns::done(self : Turns, id : Int) -> Int? {
  match self.going.search_by(g => g.0 == id) {
    None => None
    Some(k) => {
      self.going.remove(k) |> ignore
      if self.waiting.length() > 0 {
        let next = self.waiting.remove(0)
        self.going.push(next)
        Some(next.0)
      } else {
        None
      }
    }
  }
}

///|
/// A waiting search's turn over (TURN_MS): it finds no files.
pub fn Turns::expire(self : Turns, id : Int) -> Unit {
  let kept = self.waiting.filter(w => w.0 != id)
  self.waiting.clear()
  self.waiting.push_iter(kept.iter())
}

// ── skills.ts ────────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// skills.ts `selection`: a skill's name and file asked (Err the refusal).
pub fn skill_selection(args : Json) -> Result[(String, String), String] {
  let name = match field(args, "name") {
    Some(String(n)) if js_trim(n) != "" => n
    _ => return Err("name is required: use a skill name returned by search")
  }
  match field(args, "file") {
    None => Ok((name, "SKILL.md"))
    Some(String(f)) if f != "" => Ok((name, f))
    _ => Err("file must be a listed Markdown filename")
  }
}

///|
/// skills.ts `formatSkillFromCatalog` (Err the refusal).
pub fn format_skill(catalog : Json, name : String, file : String) -> Result[String, String] {
  let skills = match field(catalog, "skills") {
    Some(Array(a)) => a
    _ => []
  }
  guard skills.search_by(s => str_field(s, "name") == Some(name)).map(i => skills[i]) is Some(skill) else {
    return Err("No skill \{js_stringify(js(name))} in this workspace on this station")
  }
  let files = match field(skill, "files") {
    Some(Array(a)) => a
    _ => []
  }
  let text = if file == "SKILL.md" {
    field(skill, "text")
  } else {
    match files.search_by(f => str_field(f, "name") == Some(file)) {
      Some(k) => field(files[k], "text")
      None => None
    }
  }
  guard text is Some(String(t)) else {
    return Err(
      "No file \{js_stringify(js(file))} in skill \{js_stringify(js(name))}; read SKILL.md for the available files",
    )
  }
  let listed = ["SKILL.md", ..files.map(f => match field(f, "name") { Some(String(n)) => n; Some(v) => arg_text(v); None => "undefined" })]
  Ok(
    "Skill \{js_stringify(js(name))}, file \{js_stringify(js(file))}\nAvailable files: \{listed.map(f => js_stringify(js(f))).join(", ")}\n\n\{t}",
  )
}

///|
/// skills.ts `skillForPeer`'s catalog: the workspace's (None: the home one's).
pub fn skill_workspace(workspace : String?, home : String?) -> String? {
  match workspace {
    None => None
    Some(w) => if Some(w) == home { None } else { Some(w) }
  }
}

///|
/// skills.ts `skillTools`'s choice of where a skill is read: here (`here`), at a station of the workspace (its id), or
/// refused, by the station asked and the stations listed (id, name, whether this one).
pub fn skill_station(asked : String?, stations : Array[(String, String, Bool)]) -> Result[String, String] {
  let only = match asked {
    Some(s) => lower(js_trim(s))
    None => ""
  }
  if only == "" || only == "this station" {
    return Ok("here")
  }
  let chosen = stations.filter(s => lower(s.0) == only || lower(s.1) == only)
  if chosen.length() != 1 {
    return Err(
      if chosen.length() > 0 {
        "Station name is ambiguous; use the station id from search"
      } else {
        "No such station in this workspace"
      },
    )
  }
  if chosen[0].2 {
    Ok("here")
  } else {
    Ok(chosen[0].0)
  }
}

// ── search.ts and module.ts ──────────────────────────────────────────────────────────────────────────────────────

///|
/// search.ts `query`: whether the machine's files are searched beside the rest, the kinds the program is asked (None:
/// all; `[]`: none, the program not asked), and the files' limit.
pub fn search_plan(files : Bool, kinds : Array[String]?, limit : Int?, offset : Int?) -> Json {
  let wants_files = files &&
    (match kinds {
      None => true
      Some(k) => k.is_empty() || k.contains("file")
    }) &&
    offset.unwrap_or(0) == 0
  let program = match kinds {
    Some(k) if k.length() > 0 && k.filter(x => x != "file").is_empty() => false
    _ => true
  }
  let l = limit.unwrap_or(8)
  {
    "files": jb(wants_files),
    "program": jb(program),
    "filesLimit": ji(@cmp.maximum(1, @cmp.minimum(l, 200))),
  }
}

///|
/// module.ts's stations of a workspace as `peers` lists them: each with an id, its name (else its id), whether it is
/// this one.
pub fn search_stations(roster : Json, station : String) -> Json {
  let list = match field(roster, "stations") {
    Some(Array(a)) => a
    _ => []
  }
  Json::array(
    list
    .filter(e => match field(e, "id") { Some(String(i)) => i != ""; _ => false })
    .map(e => {
      let id = str_or(e, "id", "")
      { "id": js(id), "name": js(match field(e, "name") { Some(String(n)) => n; _ => id }), "here": jb(id == station) }
    }),
  )
}

///|
/// module.ts `workspaceOf`: a session's workspace, and whether it is the home one, by its row's `ws`.
pub fn search_workspace_of(ws : String?, home : String?) -> Json {
  {
    "workspace": js(
      match ws {
        Some(w) => w
        None => home.unwrap_or("")
      },
    ),
    "home": jb(ws is None || ws == home),
  }
}
