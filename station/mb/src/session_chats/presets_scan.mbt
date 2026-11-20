// The directories offered as a preset is made (station/src/sessions/presets.ts `candidates`, `repoIcon`, `RepoIndex`):
// the clones in the station's repository cache and the repositories found on the machine, each with its own picture
// where a project keeps one. The files are the station's (`fs.*`); names are put in order as the platform collates them
// (`dep.localeCompare`); the index's place is the station's (`repoIndex.*`).

///|
let icon_places : Array[String] = [
  "", "public", "static", "assets", "images", "img", "icons", "docs", ".github", "resources", "web/public", "app/public",
  "site/public", "src/assets", "public/icons", "assets/icons", "static/img", "docs/assets",
]

///|
let icon_most_bytes : Double = 24576.0

///|
let icon_names : Array[String] = ["favicon", "apple-touch-icon", "app-icon", "appicon", "icon", "logo"]

///|
let icon_ranks : Array[String] = ["apple-touch-icon", "app-icon", "appicon", "icon", "favicon", "logo"]

///|
fn word_unit(c : Int) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

///|
/// `/^(favicon|apple-touch-icon|app-icon|appicon|icon|logo)([-_.@][\w@.-]*)?\.(png|jpe?g)$/i`: (its name, its type).
fn icon_name(file : String) -> (String, String)? {
  let low = lower(file)
  let ext = if ends(low, ".png") {
    Some((4, "png"))
  } else if ends(low, ".jpg") {
    Some((4, "jpeg"))
  } else if ends(low, ".jpeg") {
    Some((5, "jpeg"))
  } else {
    None
  }
  guard ext is Some((n, kind)) else { return None }
  let body = slice(file, 0, b=file.length() - n)
  let low_body = lower(body)
  for name in icon_names {
    if !starts(low_body, name) {
      continue
    }
    let mid = slice(body, name.length())
    let ok = mid == "" ||
      (
        "-_.@".contains_char(mid.unsafe_charcode_at(0).unsafe_to_char()) &&
        {
          let mut all = true
          for i in 1..<mid.length() {
            let c = mid.unsafe_charcode_at(i)
            if !(word_unit(c) || c == '@' || c == '.' || c == '-') {
              all = false
              break
            }
          }
          all
        }
      )
    if ok {
      return Some((name, kind))
    }
  }
  None
}

///|
/// A repository's own picture, where projects keep one, as a data URL; None for none.
pub async fn repo_icon(w : World, root : String) -> String? {
  let found : Array[(String, Int, Int, Double, String)] = []
  for depth, place in icon_places {
    let dir = join_path([root, place])
    let entries = try {
      arr_of(Some(w.ask("fs.readdirTypes", [js(dir)]))).unwrap_or([])
    } catch {
      _ => []
    }
    for e in entries {
      if !(at(Some(e), "isFile") is Some(Bool(true))) {
        continue
      }
      let name = str_of(at(Some(e), "name")).unwrap_or("")
      guard icon_name(name) is Some((which, kind)) else { continue }
      let at_ = join_path([dir, name])
      let size = try {
        num_of(at(Some(w.ask("fs.stat", [js(at_)])), "size")).unwrap_or(0.0)
      } catch {
        _ => 0.0
      }
      if size == 0.0 || size > icon_most_bytes {
        continue
      }
      let rank = match icon_ranks.search(which) {
        Some(i) => i
        None => -1
      }
      found.push((at_, rank, depth, size, kind))
    }
  }
  let indexed = found.mapi((i, f) => (i, f))
  indexed.sort_by((a, b) => {
    let (x, y) = (a.1, b.1)
    if x.1 != y.1 {
      x.1 - y.1
    } else if x.2 != y.2 {
      x.2 - y.2
    } else if x.3 != y.3 {
      if x.3 < y.3 { -1 } else { 1 }
    } else {
      a.0 - b.0
    }
  })
  guard indexed.length() > 0 else { return None }
  let best = indexed[0].1
  let bytes = try {
    str_of(Some(w.ask("fs.readBase64", [js(best.0)])))
  } catch {
    _ => None
  }
  match bytes {
    Some(b) => Some("data:image/\{best.4};base64,\{b}")
    None => None
  }
}

///|
/// The cache's clones' pictures as last looked for, by path and when the clone last changed.
let icons : Map[String, (Double, String?)] = {}

///|
async fn cached_icon(w : World, path : String, at_ : Double) -> String? {
  match icons.get(path) {
    Some((t, icon)) if t == at_ => return icon
    _ => ()
  }
  let icon = repo_icon(w, path)
  icons[path] = (at_, icon)
  icon
}

///|
/// `/[/\\]sessions[/\\][^/\\]+[/\\]([^/\\]+)[/\\]workspace[/\\]/`: the session a worktree's gitdir is of.
fn session_in(where_ : String) -> String? {
  let sep = (c : Int) => c == '/' || c == '\\'
  let n = where_.length()
  for i in 0..<n {
    if !sep(where_.unsafe_charcode_at(i)) || slice(where_, i + 1, b=i + 9) != "sessions" || i + 9 >= n || !sep(where_.unsafe_charcode_at(i + 9)) {
      continue
    }
    // [^/\\]+ then a separator, then the session, then a separator and "workspace" and a separator
    let mut j = i + 10
    let a = j
    while j < n && !sep(where_.unsafe_charcode_at(j)) {
      j += 1
    }
    if j == a || j >= n {
      continue
    }
    j += 1
    let b = j
    while j < n && !sep(where_.unsafe_charcode_at(j)) {
      j += 1
    }
    if j == b || j >= n {
      continue
    }
    let session = slice(where_, b, b=j)
    if slice(where_, j + 1, b=j + 10) == "workspace" && j + 10 < n && sep(where_.unsafe_charcode_at(j + 10)) {
      return Some(session)
    }
  }
  None
}

///|
/// The directories offered as a preset is made. `here`: whether a folder's station is this one.
pub async fn candidates(w : World, repos_dir : String, presets : Array[J], found : Array[J], here : async (String) -> Bool) -> Array[J] {
  let list = async fn(dir : String) -> Array[String] {
    try {
      arr_of(Some(w.ask("fs.readdir", [js(dir)]))).unwrap_or([]).map(x => str_of(Some(x)).unwrap_or(""))
    } catch {
      _ => []
    }
  }
  let cached : Array[J?] = []
  for name in list(repos_dir) {
    if starts(name, ".") {
      cached.push(None)
      continue
    }
    let path = join_path([repos_dir, name])
    let git = join_path([path, ".git"])
    let at_ = try {
      Some(w.ask("fs.stat", [js(git)]))
    } catch {
      _ => None
    }
    guard at_ is Some(st) && at(Some(st), "isDirectory") is Some(Bool(true)) else {
      cached.push(None)
      continue
    }
    let mut last_at = num_of(at(Some(st), "mtimeMs")).unwrap_or(0.0)
    let sessions : Array[String] = []
    for t in list(join_path([git, "worktrees"])) {
      let file = join_path([git, "worktrees", t, "gitdir"])
      let where_ = try {
        str_of(Some(w.ask("fs.readText", [js(file)]))).unwrap_or("")
      } catch {
        _ => ""
      }
      let when = try {
        Some(w.ask("fs.stat", [js(file)]))
      } catch {
        _ => None
      }
      match session_in(where_) {
        Some(s) if s != "" && !sessions.contains(s) => sessions.push(s)
        _ => ()
      }
      match when {
        Some(x) => last_at = @cmp.maximum(last_at, num_of(at(Some(x), "mtimeMs")).unwrap_or(0.0))
        None => ()
      }
    }
    let config = try {
      str_of(Some(w.ask("fs.readText", [js(join_path([git, "config"]))]))).unwrap_or("")
    } catch {
      _ => ""
    }
    let icon = cached_icon(w, path, last_at)
    let fields = [
      ("path", js(path)),
      ("name", js(name)),
      ("repo", jopt(origin_in(config))),
      ("chats", ji(sessions.length())),
      ("lastAt", jn(last_at.floor())),
    ]
    match icon {
      Some(i) if i != "" => fields.push(("icon", js(i)))
      _ => ()
    }
    cached.push(Some(jo(fields)))
  }
  let out : Array[(String, J)] = []
  let key_of = (c : J) => match str_of(at(Some(c), "repo")) {
    Some(r) => r
    None => str_of(at(Some(c), "path")).unwrap_or("")
  }
  let get = (k : String) => match out.search_by(x => x.0 == k) {
    Some(i) => Some(out[i].1)
    None => None
  }
  let put = (k : String, v : J) => match out.search_by(x => x.0 == k) {
    Some(i) => out[i] = (k, v)
    None => out.push((k, v))
  }
  for c in found {
    if get(key_of(c)) is None {
      put(key_of(c), set_field(c, "where", js(short_path(w, str_of(at(Some(c), "path")).unwrap_or("")))))
    }
  }
  for c in cached {
    guard c is Some(c) else { continue }
    match get(key_of(c)) {
      Some(mine) => {
        let mut v = set_field(mine, "chats", jn(num_of(at(Some(mine), "chats")).unwrap_or(0.0) + num_of(at(Some(c), "chats")).unwrap_or(0.0)))
        v = set_field(v, "lastAt", jn(@cmp.maximum(num_of(at(Some(mine), "lastAt")).unwrap_or(0.0), num_of(at(Some(c), "lastAt")).unwrap_or(0.0))))
        if !truthy(at(Some(mine), "icon")) && truthy(at(Some(c), "icon")) {
          v = set_field(v, "icon", at(Some(c), "icon").unwrap())
        }
        put(key_of(c), v)
      }
      None => {
        let where_ = match str_of(at(Some(c), "repo")) {
          Some(r) => r
          None => short_path(w, str_of(at(Some(c), "path")).unwrap_or(""))
        }
        put(key_of(c), spread(c, jo([("cached", jb(true)), ("where", js(where_))])))
      }
    }
  }
  for p in presets {
    for d in arr_of(at(Some(p), "dirs")).unwrap_or([]) {
      let station = str_of(at(Some(d), "station"))
      let mine = match station {
        None | Some("") => true
        Some(s) => here(s)
      }
      let k = key_of(d)
      if mine && get(k) is None {
        let path = str_of(at(Some(d), "path")).unwrap_or("")
        put(
          k,
          jo([
            ("path", js(path)),
            ("name", js(basename(path))),
            ("repo", at(Some(d), "repo").unwrap_or(Null)),
            ("chats", ji(0)),
            ("lastAt", at(Some(p), "updatedAt").unwrap_or(Null)),
            ("where", js(short_path(w, path))),
          ]),
        )
      }
    }
  }
  let all = out.map(x => x.1)
  // (insertion sort with the platform's collation for the names: an async comparison)
  let sorted : Array[J] = []
  for c in all {
    let mut i = sorted.length()
    while i > 0 {
      let b = sorted[i - 1]
      let d = num_of(at(Some(c), "chats")).unwrap_or(0.0) - num_of(at(Some(b), "chats")).unwrap_or(0.0)
      let order = if d != 0.0 {
        if d > 0.0 { -1.0 } else { 1.0 }
      } else {
        let l = num_of(at(Some(c), "lastAt")).unwrap_or(0.0) - num_of(at(Some(b), "lastAt")).unwrap_or(0.0)
        if l != 0.0 {
          if l > 0.0 { -1.0 } else { 1.0 }
        } else {
          @drive.collate(str_of(at(Some(b), "name")).unwrap_or(""), str_of(at(Some(c), "name")).unwrap_or("")).to_double() * -1.0
        }
      }
      if order < 0.0 {
        i -= 1
      } else {
        break
      }
    }
    sorted.insert(i, c)
  }
  sorted
}

///|
let index_depth : Int = 4

///|
let index_dirs_most : Int = 20000

///|
let index_fresh_ms : Double = 600000.0

///|
let index_skipped : Array[String] = [
  "node_modules", "Library", "Applications", "Pictures", "Movies", "Music", "Public", "Desktop", "Documents", "Downloads",
  "Pods", "target", "dist", "build", "vendor", "venv",
]

///|
/// The repositories on the machine, found by walking its home a few levels down, kept in the index's file.
pub struct RepoIndex {
  mut held : J?
  mut read : Bool
}

///|
pub fn RepoIndex::new() -> RepoIndex {
  { held: None, read: false }
}

///|
/// The repositories found, as the last pass found them; and whether a pass is due (none, or the last old).
pub async fn RepoIndex::repos(self : RepoIndex, w : World) -> (Array[J], Bool) {
  if !self.read {
    self.read = true
    try {
      let kept = parse_js(str_of(Some(w.ask("fs.readText", [w.ask("repoIndex.file", [])]))).unwrap_or(""))
      if at(Some(kept), "at") is Some(Num(_)) && at(Some(kept), "repos") is Some(Arr(_)) && self.held is None {
        self.held = Some(jo([("at", at(Some(kept), "at").unwrap()), ("repos", at(Some(kept), "repos").unwrap())]))
      }
    } catch {
      _ => ()
    }
  }
  let due = match self.held {
    None => true
    Some(h) => num_of(Some(w.ask("repoIndex.now", []))).unwrap_or(0.0) - num_of(at(Some(h), "at")).unwrap_or(0.0) > index_fresh_ms
  }
  let repos = match self.held {
    Some(h) => arr_of(at(Some(h), "repos")).unwrap_or([])
    None => []
  }
  (repos, due)
}

///|
/// One pass.
pub async fn RepoIndex::walk(self : RepoIndex, w : World) -> Unit {
  let found = []
  let skip = []
  for p in arr_of(Some(w.ask("repoIndex.besides", []))).unwrap_or([]) {
    skip.push(resolve_path([str_of(Some(p)).unwrap_or("")]))
  }
  let looked = Ref::new(0)
  for root in arr_of(Some(w.ask("repoIndex.roots", []))).unwrap_or([]) {
    let r = resolve_path([str_of(Some(root)).unwrap_or("")])
    walk_into(w, r, 0, looked, skip, found)
  }
  let held = jo([("at", w.ask("repoIndex.now", [])), ("repos", ja(found))])
  self.held = Some(held)
  try {
    w.ask("fs.writeFile", [w.ask("repoIndex.file", []), js(stringify(held) + "\n")]) |> ignore
  } catch {
    _ => ()
  }
}

///|
async fn walk_into(w : World, dir : String, depth : Int, looked : Ref[Int], skip : Array[String], found : Array[J]) -> Unit {
  let n = looked.val
  looked.val += 1
  if n >= index_dirs_most || skip.contains(dir) {
    return
  }
  if w.ask("repoIndex.guarded", [js(dir)]) is Bool(true) {
    return
  }
  let entries = try {
    arr_of(Some(w.ask("repoIndex.list", [js(dir)]))).unwrap_or([])
  } catch {
    _ => []
  }
  if entries.iter().any(e => str_of(at(Some(e), "name")) == Some(".git")) {
    let git = join_path([dir, ".git"])
    let config = try {
      str_of(Some(w.ask("fs.readText", [js(join_path([git, "config"]))]))).unwrap_or("")
    } catch {
      _ => ""
    }
    let head = try {
      Some(w.ask("fs.stat", [js(join_path([git, "index"]))]))
    } catch {
      _ =>
        try {
          Some(w.ask("fs.stat", [js(git)]))
        } catch {
          _ => None
        }
    }
    let icon = repo_icon(w, dir)
    let fields = [
      ("path", js(dir)),
      ("name", js(basename(dir))),
      ("repo", jopt(origin_in(config))),
      ("chats", ji(0)),
      ("lastAt", jn(match head { Some(h) => num_of(at(Some(h), "mtimeMs")).unwrap_or(0.0).floor(); None => 0.0 })),
    ]
    match icon {
      Some(i) if i != "" => fields.push(("icon", js(i)))
      _ => ()
    }
    found.push(jo(fields))
    return
  }
  if depth >= index_depth {
    return
  }
  for e in entries {
    let name = str_of(at(Some(e), "name")).unwrap_or("")
    if !(at(Some(e), "isDirectory") is Some(Bool(true))) || starts(name, ".") || index_skipped.contains(name) {
      continue
    }
    walk_into(w, join_path([dir, name]), depth + 1, looked, skip, found)
  }
}
